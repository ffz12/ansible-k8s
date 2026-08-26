#!/bin/bash
# =============================================================================
#  download-packages-offline.sh —— 一键下载各发行版的【离线 OS 依赖包】
#  用途: 内网离线部署前, 先在联网机把各系统基础依赖(socat/conntrack/nfs/chrony/ipvsadm...)
#        及其全量依赖打成离线 tar, 拷进内网本地安装。与 download-ansible-offline.sh 配套
#        (那个只打 ansible 本身, 装在控制机; 本脚本打各节点要用的系统依赖)。
#
#  产物: offline/artifacts/ios-offline/<发行版><版本>_<arch>.tar.gz  (amd64 + arm64 双份)
#          麒麟       kylin_x86_64.tar.gz     / kylin_arm64.tar.gz
#          Ubuntu     ubuntu22_x86_64.tar.gz  / ubuntu22_arm64.tar.gz / ubuntu24_*
#          openEuler  openEuler22_x86_64.tar.gz / openEuler22_arm64.tar.gz
#
#  依赖: docker; arm64 在 x86 主机上下载需先装一次 qemu binfmt:
#          docker run --privileged --rm tonistiigi/binfmt --install arm64
#
#  说明: 各 *_packages.sh 默认下 amd64+arm64 双架构; 若设环境变量 ARCH=amd64|arm64 则只下该架构
#        (prefetch-all.sh 会按 env.yaml 的 offline_arch 自动 export ARCH)。
#  用法: bash scripts/offline/download-packages-offline.sh [kylin|ubuntu|openeuler|all ...]   (默认 all)
#        可一次给多个发行版; 某个下崩不静默跳过 —— 跑完其余后末尾红字汇总并【非零退出】。
# =============================================================================
set -e

SELF="$(cd "$(dirname "$0")" && pwd)"
OFFLINE="$(cd "$SELF/../../offline" && pwd)"   # scripts/offline/ -> offline/(各子脚本自锚定到此, 产物落 offline)

command -v docker >/dev/null 2>&1 || { echo "缺 docker(脚本用容器按架构精确拉包), 请先安装"; exit 1; }

# 参数 -> 发行版列表(默认 all; all 展开为三者; 大小写/openEuler 别名归一)
[ $# -eq 0 ] && set -- all
DISTROS=""
for a in "$@"; do
  case "$(echo "$a" | tr 'A-Z' 'a-z')" in
    all)                 DISTROS="kylin ubuntu openeuler" ;;
    kylin)               DISTROS="$DISTROS kylin" ;;
    ubuntu)              DISTROS="$DISTROS ubuntu" ;;
    openeuler|openEuler) DISTROS="$DISTROS openeuler" ;;
    *) echo "未知发行版: $a (可选 kylin|ubuntu|openeuler|all)"; exit 1 ;;
  esac
done

run() {
  local script="$1"
  echo "=========================================================="
  echo " 调用 $script"
  echo "=========================================================="
  bash "$SELF/$script"
}

FAILS=""
for d in $DISTROS; do
  case "$d" in
    kylin)     run download_kylin_packages.sh     || FAILS="$FAILS kylin" ;;
    ubuntu)    run download_ubuntu_packages.sh    || FAILS="$FAILS ubuntu" ;;
    openeuler) run download_openeuler_packages.sh || FAILS="$FAILS openeuler" ;;
  esac
done

if [ -n "$FAILS" ]; then
  echo -e "\n\033[0;31m==========================================================\033[0m"
  echo -e "\033[0;31m ❌ 以下发行版下载失败(未静默跳过):$FAILS\033[0m"
  echo -e "\033[0;31m    多为联网机容器解析/路由不到发行版官方源(如麒麟 update.cs2c.com.cn)。\033[0m"
  echo -e "\033[0;31m    可: 重试 / 设 DOCKER_DNS=223.5.5.5 / 或在 env.yaml 的 offline_distros 里剔除它。\033[0m"
  echo -e "\033[0;31m==========================================================\033[0m"
  exit 1
fi

echo -e "\n=========================================================="
echo " 全部完成! 离线 OS 依赖包在: $OFFLINE/artifacts/ios-offline/"
echo "=========================================================="
