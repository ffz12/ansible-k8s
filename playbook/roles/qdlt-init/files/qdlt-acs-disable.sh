#!/bin/bash
# ============================================================================
#  qdlt-acs-disable.sh —— 关闭所有 PCIe 设备的 ACSCtl
#
#  交付标准要求「确认所有 PCIe 设备的 ACSCtl 均已关闭」。
#  ACS(Access Control Services)开启时, PCIe switch 会把 P2P 流量强制上送到
#  Root Complex 再转回来, GPU 之间的 P2P DMA 直通被打断 → NCCL / GPUDirect
#  带宽显著下降。关掉 ACSCtl 让 P2P 走 switch 直连。
#
#  实现方式: setpci 把 ACS 扩展能力(ECAP_ACS, ID 000d)里的
#            ACS Control Register(偏移 0x06, 16 位)整体写 0。
#            位定义: bit0 SrcValid / bit1 TransBlocking / bit2 P2P Req Redirect
#                    bit3 P2P Cpl Redirect / bit4 Upstream Fwd
#                    bit5 P2P Egress Ctrl / bit6 Direct Translated P2P
#            全写 0 即全部关闭, 与体检项「SrcValid+ 计数 = 0」一致。
#
#  ⚠ 这是对 PCI 配置空间的直接写入, 且【重启后失效】(BIOS/固件会重新置位),
#    所以需要配套的 systemd 服务在每次开机后重新执行。
#  ⚠ 关闭 ACS 会降低设备间隔离性。若要做 VFIO 直通并依赖 IOMMU 分组隔离,
#    不应关闭。交付标准同时要求关闭 vt-d/IOMMU, 两者是一致的(都为了 P2P 性能)。
#
#  用法:
#    qdlt-acs-disable.sh dryrun    只打印会改哪些设备, 不写入
#    qdlt-acs-disable.sh apply     执行关闭(会先备份原值)
#    qdlt-acs-disable.sh restore   从备份恢复原值
#    qdlt-acs-disable.sh status    只统计当前状态
# ============================================================================
set -u

MODE="${1:-status}"
BACKUP_DIR=/var/lib/qdlt
BACKUP="$BACKUP_DIR/acs-backup.txt"

command -v setpci >/dev/null 2>&1 || { echo "缺少 setpci, 请安装 pciutils"; exit 1; }
command -v lspci  >/dev/null 2>&1 || { echo "缺少 lspci, 请安装 pciutils"; exit 1; }

# 列出所有暴露了 ACS 能力的设备(域:总线:设备.功能)
acs_devices() {
  local dev
  for dev in $(lspci -D | awk '{print $1}'); do
    # 能力不存在时 setpci 报错并返回非 0; 存在才输出
    if setpci -s "$dev" ECAP_ACS+0x6.w >/dev/null 2>&1; then
      echo "$dev"
    fi
  done
}

case "$MODE" in

  status)
    total=0; on=0
    for dev in $(acs_devices); do
      total=$((total+1))
      val=$(setpci -s "$dev" ECAP_ACS+0x6.w 2>/dev/null)
      # 非 0 即有 ACS 控制位处于开启
      [ "$((0x${val:-0}))" -ne 0 ] && on=$((on+1))
    done
    echo "有 ACS 能力的设备: $total 个; ACSCtl 非 0(仍有控制位开启)的: $on 个"
    [ "$on" -eq 0 ] && exit 0 || exit 2
    ;;

  dryrun)
    n=0
    for dev in $(acs_devices); do
      val=$(setpci -s "$dev" ECAP_ACS+0x6.w 2>/dev/null)
      if [ "$((0x${val:-0}))" -ne 0 ]; then
        n=$((n+1))
        printf '将修改 %s : ACSCtl 0x%s → 0x0000  (%s)\n' \
          "$dev" "$val" "$(lspci -s "$dev" | cut -d' ' -f2- | head -c 70)"
      fi
    done
    echo "共 $n 个设备需要修改(dryrun, 未写入)"
    ;;

  apply)
    mkdir -p "$BACKUP_DIR"
    # 备份只做一次: 保留【最初】的原始值, 重跑不要用已清零的值覆盖备份
    if [ ! -f "$BACKUP" ]; then
      : > "$BACKUP"
      for dev in $(acs_devices); do
        val=$(setpci -s "$dev" ECAP_ACS+0x6.w 2>/dev/null)
        printf '%s %s\n' "$dev" "${val:-0000}" >> "$BACKUP"
      done
      echo "原始 ACSCtl 值已备份到 $BACKUP"
    fi

    changed=0; failed=0
    for dev in $(acs_devices); do
      val=$(setpci -s "$dev" ECAP_ACS+0x6.w 2>/dev/null)
      [ "$((0x${val:-0}))" -eq 0 ] && continue
      if setpci -s "$dev" ECAP_ACS+0x6.w=0000 2>/dev/null; then
        new=$(setpci -s "$dev" ECAP_ACS+0x6.w 2>/dev/null)
        if [ "$((0x${new:-ffff}))" -eq 0 ]; then
          changed=$((changed+1))
          printf 'OK   %s : 0x%s → 0x%s\n' "$dev" "$val" "$new"
        else
          failed=$((failed+1))
          printf 'FAIL %s : 写入后回读仍为 0x%s(可能被固件锁定)\n' "$dev" "$new"
        fi
      else
        failed=$((failed+1))
        printf 'FAIL %s : setpci 写入失败\n' "$dev"
      fi
    done
    echo "已关闭 $changed 个设备的 ACSCtl; 失败 $failed 个"
    [ "$failed" -gt 0 ] && exit 3 || exit 0
    ;;

  restore)
    [ -f "$BACKUP" ] || { echo "找不到备份 $BACKUP, 无法恢复"; exit 1; }
    n=0
    while read -r dev val; do
      [ -z "${dev:-}" ] && continue
      setpci -s "$dev" ECAP_ACS+0x6.w="$val" 2>/dev/null && n=$((n+1))
    done < "$BACKUP"
    echo "已从备份恢复 $n 个设备的 ACSCtl 原值"
    ;;

  *)
    echo "用法: $0 {status|dryrun|apply|restore}"; exit 1
    ;;
esac
