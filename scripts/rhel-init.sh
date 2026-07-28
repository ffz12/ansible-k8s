#!/bin/bash
# =============================================================================
#  rhel-init.sh —— RHEL 系(CentOS/RHEL/Rocky/Alma · 银河麒麟 Kylin · openEuler)
#                  单机系统环境初始化(在线)
#
#  等价于本项目 ansible init 角色对红帽系做的事(redhat.yaml / kylinsp3.yaml /
#  openEuler.yaml + common.yaml), 抽成【单台直接跑】的脚本。
#
#  做的事:
#    1) 主机名(可选) + 时区 Asia/Shanghai + 加载持久化 br_netfilter/overlay
#    2) 内核参数调优(sysctl drop-in) + 文件描述符/内存锁 limits
#    3) 关 swap(含 fstab)
#    4) 关 firewalld + 关 SELinux(永久+临时)
#    5) 装基础依赖包(按发行版分流清单; yum/dnf --skip-broken 防单包缺失中断)
#    6) chrony 时间同步(可选指定上游 NTP)
#
#  用法:
#    sudo bash scripts/rhel-init.sh
#    sudo bash scripts/rhel-init.sh -H k8s-master1
#    sudo CHRONY_IP=10.0.0.1 bash scripts/rhel-init.sh
#
#  说明: 面向【在线】单机(能直连 yum/dnf 源)。离线批量请用 ansible init 角色
#        (它会拷 /opt/*-pkgs 本地 localinstall)。
#        sysctl 写入 /etc/sysctl.d/99-k8s.conf(drop-in, 比覆盖 /etc/sysctl.conf 安全等效)。
# =============================================================================
set -u

# -------- 参数 --------
NEW_HOSTNAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H|--hostname) NEW_HOSTNAME="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done
CHRONY_IP="${CHRONY_IP:-}"

log(){ echo -e "\033[0;32m[+] $*\033[0m"; }
warn(){ echo -e "\033[0;33m[!] $*\033[0m"; }

# -------- 前置检查: root + 红帽系 --------
[ "$(id -u)" = "0" ] || { echo "请用 root 运行(sudo bash $0)"; exit 1; }
. /etc/os-release 2>/dev/null || true

# 归一化发行版族: kylin / openeuler / rhel(含 centos/rocky/alma/redhat)
FAMILY=""
case "${ID:-}" in
  kylin)      FAMILY="kylin" ;;
  openEuler)  FAMILY="openeuler" ;;
  centos|rhel|rocky|almalinux|anolis) FAMILY="rhel" ;;
  *)
    case "${ID_LIKE:-}" in
      *rhel*|*centos*|*fedora*) FAMILY="rhel" ;;
      *) echo "无法识别的红帽系发行版(ID=${ID:-未知}); 如确为红帽系可手动改 FAMILY"; exit 1 ;;
    esac ;;
esac

# 包管理器: 优先 dnf
if command -v dnf >/dev/null 2>&1; then PM="dnf"; else PM="yum"; fi
log "系统: ${PRETTY_NAME:-$ID $VERSION_ID}  族=$FAMILY  包管理器=$PM"

# =============================================================================
# 1) 主机名(可选) + 时区 + br_netfilter
# =============================================================================
if [ -n "$NEW_HOSTNAME" ]; then
  log "设置主机名 -> $NEW_HOSTNAME"
  hostnamectl set-hostname "$NEW_HOSTNAME" || warn "设置主机名失败"
fi

if [ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "Asia/Shanghai" ]; then
  log "设置时区 Asia/Shanghai"
  timedatectl set-timezone Asia/Shanghai || warn "设置时区失败"
else
  log "时区已是 Asia/Shanghai, 跳过"
fi

log "加载并持久化 br_netfilter/overlay"
modprobe br_netfilter 2>/dev/null || warn "modprobe br_netfilter 失败(内核可能已内建)"
modprobe overlay 2>/dev/null || true
cat > /etc/modules-load.d/k8s.conf <<'EOF'
br_netfilter
overlay
EOF

# =============================================================================
# 2) 内核参数调优 + limits
# =============================================================================
log "写入内核参数 /etc/sysctl.d/99-k8s.conf"
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
# 由 rhel-init.sh 写入, 对齐 ansible init 角色 files/sysctl.conf
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-arptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_local_reserved_ports = 30000-32767
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 1048576
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_max_orphans = 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.conf.all.arp_accept = 1
net.ipv4.conf.default.arp_accept = 1
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
vm.max_map_count = 262144
vm.swappiness = 0
vm.overcommit_memory = 0
fs.inotify.max_user_instances = 524288
fs.inotify.max_user_watches = 524288
fs.pipe-max-size = 4194304
fs.aio-max-nr = 262144
kernel.pid_max = 1000001
kernel.watchdog_thresh = 5
net.ipv4.tcp_tw_reuse = 1
kernel.hung_task_timeout_secs = 30
EOF
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-k8s.conf || warn "sysctl 应用有报错(部分内核不支持的项可忽略)"

log "配置 limits(nofile/memlock/stack)"
LIMITS_MARK="# rhel-init.sh block"
if ! grep -q "$LIMITS_MARK" /etc/security/limits.conf 2>/dev/null; then
  cp -a /etc/security/limits.conf "/etc/security/limits.conf.bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
  cat >> /etc/security/limits.conf <<EOF

$LIMITS_MARK BEGIN
root soft memlock unlimited
root hard memlock unlimited
root soft stack unlimited
root hard stack unlimited
root soft nofile  1000001
root hard nofile  1000001
* soft memlock unlimited
* hard memlock unlimited
* soft stack unlimited
* hard stack unlimited
* soft nofile 1000001
* hard nofile 1000001
$LIMITS_MARK END
EOF
else
  log "limits 已配置过, 跳过"
fi

# =============================================================================
# 3) 关 swap
# =============================================================================
log "关闭 swap 并从 fstab 摘除"
swapoff -a 2>/dev/null || true
sysctl -w vm.swappiness=0 >/dev/null 2>&1 || true
sed -i.bak -E '/\sswap\s/ s/^/#/' /etc/fstab 2>/dev/null || true

# =============================================================================
# 4) 关 firewalld + 关 SELinux
#    注: openEuler 的 ansible 角色未做这两步, 但对 k8s 节点是推荐且幂等安全的,
#        故本脚本统一处理(与 redhat/kylin 一致)。
# =============================================================================
log "关闭 firewalld 防火墙"
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

if [ -f /etc/selinux/config ]; then
  if grep -q '^SELINUX=disabled' /etc/selinux/config; then
    log "SELinux 已是 disabled, 跳过"
  else
    log "关闭 SELinux(永久+临时)"
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0 2>/dev/null || true
  fi
else
  log "无 /etc/selinux/config, 跳过 SELinux"
fi

# =============================================================================
# 5) 安装基础依赖包(按族分流; --skip-broken 防个别包在某发行版不存在而整体中断)
# =============================================================================
# 红帽/openEuler 大清单(对齐 redhat.yaml / openEuler.yaml 在线段)
PKGS_RHEL="createrepo wget net-tools lrzsz gcc gcc-c++ make cmake libxml2-devel \
openssl-devel curl curl-devel unzip sudo libaio-devel vim ncurses-devel autoconf \
automake zlib-devel openssh-server socat ipvsadm conntrack ebtables ipset git \
elfutils-libelf-devel htop tar tmux rsync authconfig nss-pam-ldapd pam_ldap \
openldap-clients oddjob oddjob-mkhomedir chrony python3"
# 麒麟小清单(对齐 kylinsp3.yaml 在线段)
PKGS_KYLIN="socat ipset conntrack ipvsadm ebtables chrony rsync tar unzip vim net-tools wget"

case "$FAMILY" in
  kylin)     PKGS="$PKGS_KYLIN" ;;
  *)         PKGS="$PKGS_RHEL"
             # rhel-like 上大清单里的 htop/tmux 常需 EPEL, 尽力启用(openEuler 自带 EPOL 不需要)
             [ "$FAMILY" = "rhel" ] && $PM install -y epel-release >/dev/null 2>&1 || true ;;
esac

log "更新缓存并安装基础依赖(--skip-broken)"
$PM makecache >/dev/null 2>&1 || warn "makecache 有报错(检查网络/源)"
$PM install -y --skip-broken $PKGS || warn "部分包安装失败(--skip-broken 已尽量装齐), 请检查上方输出"

# =============================================================================
# 6) chrony 时间同步(RHEL 系: /etc/chrony.conf + chronyd)
# =============================================================================
log "配置 chrony 时间同步"
if [ -n "$CHRONY_IP" ]; then
  cp -a /etc/chrony.conf "/etc/chrony.conf.bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
  cat > /etc/chrony.conf <<EOF
server $CHRONY_IP iburst prefer
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
  log "chrony 上游设为 $CHRONY_IP"
else
  warn "未指定 CHRONY_IP, 保留系统默认 chrony 源(如需内网 NTP: CHRONY_IP=x.x.x.x 重跑)"
fi
systemctl enable chronyd >/dev/null 2>&1 || true
systemctl restart chronyd 2>/dev/null || warn "chronyd 重启失败(确认 chrony 是否装上)"

echo
log "=========================================================="
log " RHEL 系($FAMILY)环境初始化完成!"
warn " 建议重启一次使内核参数/limits 完全生效: reboot"
log "=========================================================="
