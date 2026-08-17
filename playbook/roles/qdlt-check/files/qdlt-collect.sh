#!/bin/bash
# ============================================================================
#  qdlt-collect.sh —— 青岛联通交付标准 只读体检采集器
#
#  只读: 全程不修改任何系统配置, 只执行查询命令。
#  输出: 单行 JSON 到 stdout(供 Ansible 解析); 也可单机直接执行查看。
#
#  用法: sudo bash qdlt-collect.sh
# ============================================================================
set -u

# JSON 字符串转义
#  ⚠ 换行必须先折成空格再删控制字符 —— 否则任何多行输出都会把单行 JSON 撑破。
#    典型来源: `grep -c xxx || echo 0`(grep 无匹配时既打印 0 又返回码 1, 于是
#    echo 0 也执行, 输出变成两行), 以及一个字段里跑多条命令的情况。
esc() {
  printf '%s' "${1-}" \
    | tr '\n\r\t' '   ' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | tr -d '\000-\037' \
    | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}
kv()  { printf '"%s":"%s",' "$1" "$(esc "${2-}")"; }
# 计数专用: 只取第一行、且只保留数字, 避免 grep -c 的双输出问题
kvn() { printf '"%s":"%s",' "$1" "$(printf '%s' "${2-}" | head -1 | tr -cd '0-9')"; }

printf '{'

# ---------------- 操作系统 ----------------
kv os_pretty     "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}")"
kv os_version    "$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
kv os_point      "$(lsb_release -ds 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
kv kernel        "$(uname -r)"
kv install_date  "$(stat -c %y /var/log/installer 2>/dev/null || stat -c %y / 2>/dev/null)"
kv hostname      "$(hostname)"
kv uptime_days   "$(awk '{printf "%.1f", $1/86400}' /proc/uptime 2>/dev/null)"

# ---------------- 时间 ----------------
kv timezone      "$(timedatectl show -p Timezone --value 2>/dev/null)"
kv time_utc      "$(date -u '+%Y-%m-%d %H:%M:%S')"
kv time_epoch    "$(date -u +%s)"
kv ntp_sync      "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
kv chrony_active "$(systemctl is-active chrony 2>/dev/null)"
kv chrony_offset "$(chronyc tracking 2>/dev/null | awk -F': *' '/System time/{print $2}')"
kv chrony_source "$(chronyc sources 2>/dev/null | awk 'NR>2{printf "%s ", $2}')"

# ---------------- cloud-init / apt 自动更新 ----------------
if [ -x /usr/bin/cloud-init ]; then
  if [ -f /etc/cloud/cloud-init.disabled ]; then
    kv cloudinit "disabled(标记文件存在)"
  else
    CI_EN=$(systemctl is-enabled cloud-init.service 2>/dev/null | head -1)
    kv cloudinit "${CI_EN:-unknown}"
  fi
else
  kv cloudinit "not-installed"
fi
kvn apt_timers   "$(systemctl list-timers --all 2>/dev/null | grep -c 'apt-daily')"
kv apt_periodic  "$(grep -hoE '"[01]"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null | tr -d '"' | tr '\n' ' ')"
# ⚠ is-enabled 在 disabled 时也返回非 0 码, 直接 `|| echo absent` 会两条都输出
#   (变成 "disabled absent"), 故只在完全无输出时才补 absent。
UNATT=$(systemctl is-enabled unattended-upgrades 2>/dev/null | head -1)
kv unattended    "${UNATT:-absent}"

# ---------------- 用户 ----------------
kv normal_users  "$(awk -F: '$3>=1000 && $3<65534 {printf "%s ", $1}' /etc/passwd)"

# ---------------- CPU / 供电 / Boost ----------------
kv cpu_model     "$(lscpu 2>/dev/null | awk -F': *' '/Model name/{print $2; exit}')"
kv cpu_sockets   "$(lscpu 2>/dev/null | awk -F': *' '/^Socket\(s\)/{print $2}')"
kv cpu_cores     "$(nproc 2>/dev/null)"
kv cpu_threads_per_core "$(lscpu 2>/dev/null | awk -F': *' '/Thread\(s\) per core/{print $2}')"
kv numa_nodes    "$(lscpu 2>/dev/null | awk -F': *' '/NUMA node\(s\)/{print $2}')"
kv gov_available "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null)"
kv gov_current   "$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ',')"
kv boost_no_turbo "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo NA)"
kv boost_flag     "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo NA)"
kv cstate_disabled "$(cat /sys/module/intel_idle/parameters/max_cstate 2>/dev/null || echo NA)"
kv cpu_mhz_now    "$(awk -F': *' '/cpu MHz/{s+=$2; n++} END{if(n)printf "%.0f", s/n}' /proc/cpuinfo 2>/dev/null)"

# ---------------- 内存 ----------------
kv mem_total_gb  "$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null)"
kvn mem_dimms    "$(dmidecode -t memory 2>/dev/null | grep -c '^\s*Size:.*[0-9]\+ *[MG]B')"
kv mem_vendor    "$(dmidecode -t memory 2>/dev/null | awk -F': *' '/Manufacturer/{if($2!="NO DIMM" && $2!="")print $2}' | sort -u | tr '\n' ',')"
kv mem_speed     "$(dmidecode -t memory 2>/dev/null | awk -F': *' '/Configured Memory Speed|Configured Clock Speed/{if($2!="Unknown")print $2}' | sort -u | tr '\n' ',')"
kv swap_on       "$(swapon --show=NAME --noheadings 2>/dev/null | tr '\n' ',')"
# 永久性判定: fstab 里未注释的 swap 条目(第3列=swap) + swap unit 是否 masked
#   只看 swapon 会误判 —— 手工 swapoff -a 后当前是空的, 但重启就回来了。
kvn swap_fstab   "$(awk '$1 !~ /^#/ && $1 != "" && $3 == "swap"' /etc/fstab 2>/dev/null | wc -l)"
kv swap_units    "$(systemctl list-unit-files --type=swap --no-legend 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')"
kv swap_target   "$(systemctl is-enabled swap.target 2>/dev/null | head -1)"
kv swappiness    "$(cat /proc/sys/vm/swappiness 2>/dev/null)"
kvn swappiness_persisted "$(grep -rlsE '^\s*vm\.swappiness' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null | wc -l)"

# ---------------- BIOS / 整机 ----------------
kv bios_vendor   "$(dmidecode -s bios-vendor 2>/dev/null)"
kv bios_version  "$(dmidecode -s bios-version 2>/dev/null)"
kv sys_product   "$(dmidecode -s system-product-name 2>/dev/null)"
kv sys_vendor    "$(dmidecode -s system-manufacturer 2>/dev/null)"
kv sys_sn        "$(dmidecode -s system-serial-number 2>/dev/null)"
# vt-d/iommu 应关闭
kvn iommu_dmar   "$(dmesg 2>/dev/null | grep -ci 'DMAR: IOMMU enabled')"
kvn iommu_groups "$(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)"
kv cmdline       "$(cat /proc/cmdline 2>/dev/null)"

# ---------------- 磁盘 ----------------
kv sys_disk_root "$(findmnt -no SOURCE,FSTYPE,SIZE / 2>/dev/null | tr '\n' ' ')"
kv root_fstype   "$(findmnt -no FSTYPE / 2>/dev/null)"
kv raid_ctrl     "$(lspci 2>/dev/null | grep -iE 'raid|MegaRAID|PERC' | head -3 | tr '\n' ';')"
kv md_raid       "$(awk '/^md/{printf "%s ", $0}' /proc/mdstat 2>/dev/null)"
kv lvm_pv        "$(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ' | tr '\n' ',')"
# 全部块设备: 名称/大小/类型/挂载/文件系统 —— 用于判定数据盘是否裸盘
kv blockdevs     "$(lsblk -dn -o NAME,SIZE,TYPE,MODEL 2>/dev/null | tr '\n' ';')"
kv parts_all     "$(lsblk -n -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null | tr '\n' ';')"
# 数据盘(非系统盘)上若有任何分区/文件系统/raid 成员, 即不符合"裸盘"要求
ROOTDISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE / 2>/dev/null)" 2>/dev/null | head -1)
[ -z "$ROOTDISK" ] && ROOTDISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /boot 2>/dev/null)" 2>/dev/null | head -1)
kv root_disk "$ROOTDISK"
DIRTY=""
for d in $(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
  case "$d" in "$ROOTDISK"|"") continue;; esac
  info=$(lsblk -n -o FSTYPE,TYPE "/dev/$d" 2>/dev/null | awk 'NR>1 || $1!=""')
  if echo "$info" | grep -qE '[a-z]'; then DIRTY="$DIRTY $d"; fi
done
kv data_disk_dirty "$DIRTY"

# ---------------- 网卡(只读采集, 不做任何修改) ----------------
kv nics          "$(ip -o link show 2>/dev/null | awk -F': ' '{printf "%s ", $2}')"
kv bond_list     "$(ls /proc/net/bonding 2>/dev/null | tr '\n' ',')"
BONDINFO=""
for b in $(ls /proc/net/bonding 2>/dev/null); do
  m=$(awk -F': ' '/Bonding Mode/{print $2; exit}' "/proc/net/bonding/$b")
  h=$(awk -F': ' '/Transmit Hash Policy/{print $2; exit}' "/proc/net/bonding/$b")
  s=$(awk -F': ' '/Slave Interface/{printf "%s+", $2}' "/proc/net/bonding/$b")
  l=$(awk -F': ' '/^\s*Partner Mac Address|Aggregator ID/{printf "%s;", $2}' "/proc/net/bonding/$b" | head -c 60)
  BONDINFO="${BONDINFO}${b}[mode=${m}|hash=${h}|slaves=${s}] "
done
kv bond_detail   "$BONDINFO"
kv vlan_ifaces   "$(ip -o link show type vlan 2>/dev/null | awk -F': ' '{printf "%s ", $2}')"
kv default_route "$(ip route show default 2>/dev/null | tr '\n' ';')"
kv ip_addrs      "$(ip -o -4 addr show 2>/dev/null | awk '{printf "%s=%s ", $2, $4}')"
kvn rule_count   "$(ip rule show 2>/dev/null | grep -vc '^\(0\|32766\|32767\):')"
kv route_tables  "$(ip rule show 2>/dev/null | tr '\n' ';')"

# ---------------- RDMA ----------------
kv rdma_devs     "$(ls /sys/class/infiniband 2>/dev/null | sort -V | tr '\n' ',')"
RDMAINFO=""
for d in $(ls /sys/class/infiniband 2>/dev/null | sort -V); do
  # 网卡型号 + 固件 + 链路层 + 速率
  fw=$(cat "/sys/class/infiniband/$d/fw_ver" 2>/dev/null)
  ll=$(cat "/sys/class/infiniband/$d/ports/1/link_layer" 2>/dev/null)
  rt=$(cat "/sys/class/infiniband/$d/ports/1/rate" 2>/dev/null)
  st=$(awk '{print $2}' "/sys/class/infiniband/$d/ports/1/state" 2>/dev/null)
  nd=$(cat "/sys/class/infiniband/$d/device/net"/*/device/../../uevent 2>/dev/null | head -0)
  RDMAINFO="${RDMAINFO}${d}[fw=${fw}|${ll}|${rt}|${st}] "
done
kv rdma_detail   "$RDMAINFO"
kv rdma_link     "$(ibstat -l 2>/dev/null | tr '\n' ',')"
kv mlnx_nics     "$(lspci 2>/dev/null | grep -i mellanox | sed 's/^/ /' | tr '\n' ';')"

# ---------------- OFED / DOCA ----------------
kv ofed_version  "$(ofed_info -s 2>/dev/null | head -1)"
kv doca_version  "$(dpkg -l 2>/dev/null | awk '/doca-(host|ofed)/{print $2"="$3}' | head -3 | tr '\n' ',')"
kv mlx_pkg       "$(dpkg -l 2>/dev/null | awk '/mlnx-ofed|mlnx-tools/{print $2"="$3}' | head -3 | tr '\n' ',')"

# ---------------- GPU ----------------
if command -v nvidia-smi >/dev/null 2>&1; then
  kv gpu_driver  "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  kvn gpu_count  "$(nvidia-smi -L 2>/dev/null | wc -l)"
  kv gpu_model   "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ',')"
  kv gpu_vbios   "$(nvidia-smi --query-gpu=vbios_version --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ',')"
  kv gpu_persist "$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ',')"
  kv gpu_ecc_err "$(nvidia-smi --query-gpu=ecc.errors.uncorrected.volatile.total --format=csv,noheader 2>/dev/null | sort -u | tr '\n' ',')"
  kv gpu_topo    "$(nvidia-smi topo -m 2>/dev/null | head -20 | tr '\n' ';' | tr -s ' ')"
  kv fabricmgr   "svc=$(systemctl is-active nvidia-fabricmanager 2>/dev/null || echo unknown) pkg=$(dpkg -l 2>/dev/null | awk '/nvidia-fabricmanager/{print $3; exit}')"
  kv persistenced "$(systemctl is-active nvidia-persistenced 2>/dev/null)"
else
  kv gpu_driver "not-installed"
  kv gpu_count  "0"
fi
kv cuda_toolkit  "$(dpkg -l 2>/dev/null | awk '/^ii +cuda-toolkit/{print $2"="$3}' | head -1)"

# ---------------- PCIe: ACSCtl 必须全关 ----------------
ACS_ON=$(lspci -vvv 2>/dev/null | grep ACSCtl | grep -c 'SrcValid+')
ACS_TOTAL=$(lspci -vvv 2>/dev/null | grep -c ACSCtl)
kvn acs_enabled_count "$ACS_ON"
kvn acs_total_count   "$ACS_TOTAL"
# PCIe 链路速率(Gen5 = 32GT/s)
kvn pcie_gen5_x16 "$(lspci -vvv 2>/dev/null | grep -c 'LnkSta:.*32GT/s.*Width x16')"
kvn pcie_downgrade "$(lspci -vvv 2>/dev/null | grep -c 'LnkSta:.*(downgraded)')"

# ---------------- 共享存储挂载 ----------------
kv mounts_shared "$(findmnt -rn -t gpfs,nfs,nfs4,lustre,fuse.glusterfs,ceph -o TARGET,SOURCE,FSTYPE 2>/dev/null | tr '\n' ';')"
kv fstab_shared  "$(grep -vE '^\s*#|^\s*$' /etc/fstab 2>/dev/null | grep -E 'gpfs|nfs|lustre|ceph' | tr '\n' ';')"
kv gpfs_client   "$(dpkg -l 2>/dev/null | awk '/gpfs/{print $2"="$3}' | head -3 | tr '\n' ',')"

# ---------------- 其他交付项 ----------------
kv ipmitool      "$(command -v ipmitool >/dev/null 2>&1 && ipmitool -V 2>/dev/null | head -1 || echo not-installed)"
kv ipmi_lan      "$(ipmitool lan print 2>/dev/null | awk -F': *' '/IP Address  /{print $2}' | head -1)"
kv ufw_state     "$(systemctl is-active ufw 2>/dev/null)"
kv selinux       "$(getenforce 2>/dev/null || echo NA)"
kv kernel_hold   "$(apt-mark showhold 2>/dev/null | tr '\n' ',')"
kv grub_default  "$(grep -E '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | head -1 | cut -d= -f2-)"
kv limits_nofile "$(grep -hE '^\*.*nofile' /etc/security/limits.conf 2>/dev/null | tr '\n' ';')"

# 末尾补一个哨兵键, 消除最后的逗号
printf '"_collected":"ok"}'
