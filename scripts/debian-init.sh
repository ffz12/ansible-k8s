#!/bin/bash
# =============================================================================
#  debian-init.sh —— Debian/Ubuntu 单机系统环境初始化(在线)
#
#  等价于本项目 ansible init 角色对 Debian 系做的事(debian.yaml + common.yaml),
#  抽成一个可【单台直接跑】的脚本: 装 k8s/容器所需系统环境时不想起 ansible 就用它。
#
#  做的事:
#    1) 时区 Asia/Shanghai; 加载并持久化 br_netfilter
#    2) 内核参数调优(sysctl, k8s/高并发所需) + 文件描述符/内存锁 limits
#    3) 关 swap(含 fstab)
#    4) apt 非交互/关自动更新/关 needrestart/关 cloud-init 网络接管/hold 当前内核
#    5) 关 ufw、编辑器设 vim、locale 时间格式、分页关闭
#    6) 装基础依赖包(socat/ipset/conntrack/ipvsadm/ebtables/nfs 等)
#    7) chrony 时间同步(可选指定上游 NTP)
#
#  用法:
#    sudo bash scripts/debian-init.sh                 # 用默认(不改主机名, chrony 用系统默认源)
#    sudo bash scripts/debian-init.sh -H k8s-master1  # 顺便设主机名
#    sudo CHRONY_IP=10.0.0.1 bash scripts/debian-init.sh   # 指定内网 NTP 上游
#
#  说明: 面向【在线】单机(能直连 apt 源)。离线批量场景请用 ansible 的 init 角色。
#        sysctl 写入 /etc/sysctl.d/99-k8s.conf(drop-in, 比覆盖 /etc/sysctl.conf 更安全, 等效)。
# =============================================================================
set -u

# -------- 参数 --------
NEW_HOSTNAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H|--hostname) NEW_HOSTNAME="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done
CHRONY_IP="${CHRONY_IP:-}"

log(){ echo -e "\033[0;32m[+] $*\033[0m"; }
warn(){ echo -e "\033[0;33m[!] $*\033[0m"; }

# -------- 前置检查: root + Debian/Ubuntu --------
[ "$(id -u)" = "0" ] || { echo "请用 root 运行(sudo bash $0)"; exit 1; }
. /etc/os-release 2>/dev/null || true
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) ;;
  *) echo "本脚本仅适用于 Debian/Ubuntu(检测到 ID=${ID:-未知}), 退出"; exit 1 ;;
esac
VER_MAJOR="$(echo "${VERSION_ID:-0}" | cut -d. -f1)"
log "系统: ${PRETTY_NAME:-$ID $VERSION_ID}  (主版本 $VER_MAJOR)"
export DEBIAN_FRONTEND=noninteractive

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

log "加载并持久化 br_netfilter"
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
# 由 debian-init.sh 写入, 对齐 ansible init 角色 files/sysctl.conf
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
LIMITS_MARK="# debian-init.sh block"
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
# 4) apt 非交互 / 关自动更新 / needrestart / cloud-init / hold 内核
# =============================================================================
log "apt 非交互与防卡死设置"
cat > /etc/apt/apt.conf.d/70debconf <<'EOF'
DPkg::Pre-Install-Pkgs { "/usr/sbin/dpkg-preconfigure --apt || true"; };
Debconf::Frontend "Noninteractive";
EOF
grep -q '^export DEBIAN_FRONTEND=noninteractive' /etc/profile || echo 'export DEBIAN_FRONTEND=noninteractive' >> /etc/profile
rm -f /etc/apt/apt.conf.d/99needrestart

log "关闭系统自动更新"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
cat > /etc/apt/apt.conf.d/10periodic <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
EOF
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true

log "禁用 cloud-init 网络接管(防重启覆盖静态网络)"
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
# 由 debian-init.sh 写入: 禁用 cloud-init 网络配置管理
network: {config: disabled}
EOF

log "锁定当前内核版本防误升级"
CUR_KV="$(uname -r | cut -d'-' -f1,2)"
HOLD_PKGS="$(dpkg --get-selections 2>/dev/null | awk '$2=="install"{print $1}' | grep -E "^linux-(headers|image|modules|modules-extra)-${CUR_KV}" || true)"
if [ -n "$HOLD_PKGS" ]; then
  apt-mark hold $HOLD_PKGS >/dev/null 2>&1 && log "已 hold: $HOLD_PKGS" || warn "hold 内核失败"
else
  warn "未找到匹配当前内核($CUR_KV)的组件包, 跳过 hold"
fi

# =============================================================================
# 5) ufw / 编辑器 / locale / 分页
# =============================================================================
log "关闭 ufw 防火墙"
systemctl stop ufw 2>/dev/null || true
systemctl disable ufw 2>/dev/null || true

grep -q '^export SYSTEMD_PAGER=' /etc/profile || echo 'export SYSTEMD_PAGER=""' >> /etc/profile
grep -q '^LC_TIME=' /etc/default/locale 2>/dev/null || echo 'LC_TIME=en_DK.UTF-8' >> /etc/default/locale

# =============================================================================
# 6) 修复 apt 状态并安装基础依赖包
# =============================================================================
log "修复 apt 状态"
apt-get install -f -y >/dev/null 2>&1 || true
dpkg --configure -a >/dev/null 2>&1 || true

# pcre 包名随版本: >=24 用 libpcre2-8-0, 否则 libpcre3(对齐 ansible)
if [ "${VER_MAJOR:-0}" -ge 24 ] 2>/dev/null; then PCRE_PKG="libpcre2-8-0"; else PCRE_PKG="libpcre3"; fi

PKGS="socat ipset conntrack ipvsadm ebtables libseccomp2 netcat-openbsd ca-certificates \
nfs-common nfs-kernel-server bash-completion apt-transport-https software-properties-common \
bzip2 unzip chrony libssl3 zlib1g $PCRE_PKG"

log "更新缓存并安装基础依赖: $PKGS"
apt-get update -y >/dev/null 2>&1 || warn "apt update 有报错(检查网络/源)"
apt-get install -y $PKGS || warn "部分包安装失败, 请检查上方输出"

# 设默认编辑器为 vim(若已装 vim)
if update-alternatives --list editor 2>/dev/null | grep -q 'vim.basic'; then
  update-alternatives --set editor /usr/bin/vim.basic >/dev/null 2>&1 || true
fi

# =============================================================================
# 7) chrony 时间同步
# =============================================================================
log "配置 chrony 时间同步"
if [ -n "$CHRONY_IP" ]; then
  cp -a /etc/chrony/chrony.conf "/etc/chrony/chrony.conf.bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
  cat > /etc/chrony/chrony.conf <<EOF
server $CHRONY_IP iburst prefer
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
  log "chrony 上游设为 $CHRONY_IP"
else
  warn "未指定 CHRONY_IP, 保留系统默认 chrony 源(如需内网 NTP: CHRONY_IP=x.x.x.x 重跑)"
fi
systemctl enable chrony >/dev/null 2>&1 || true
systemctl restart chrony 2>/dev/null || warn "chrony 重启失败(确认服务名是否为 chrony)"

echo
log "=========================================================="
log " Debian/Ubuntu 环境初始化完成!"
warn " 建议重启一次使内核参数/limits 完全生效: reboot"
log "=========================================================="
