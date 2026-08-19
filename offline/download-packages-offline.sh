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
#  说明: 各 *_packages.sh 固定下载 amd64+arm64 双架构(不接架构参数), 故本入口只选发行版。
#  用法: bash offline/download-packages-offline.sh [kylin|ubuntu|openeuler|all]   (默认 all)
# =============================================================================
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"                    # 使各脚本的 $(pwd)/artifacts/ios-offline 稳定落到 offline/ 下, 不随调用目录漂移
TARGET="${1:-all}"

command -v docker >/dev/null 2>&1 || { echo "缺 docker(脚本用容器按架构精确拉包), 请先安装"; exit 1; }

run() {
  local script="$1"
  echo "=========================================================="
  echo " 调用 $script"
  echo "=========================================================="
  bash "$DIR/$script"
}

case "$TARGET" in
  kylin)     run download_kylin_packages.sh ;;
  ubuntu)    run download_ubuntu_packages.sh ;;
  openeuler) run download_openeuler_packages.sh ;;
  all)
    run download_kylin_packages.sh
    run download_ubuntu_packages.sh
    run download_openeuler_packages.sh
    ;;
  *)
    echo "用法: bash $0 [kylin|ubuntu|openeuler|all]"; exit 1 ;;
esac

echo -e "\n=========================================================="
echo " 全部完成! 离线 OS 依赖包在: $DIR/artifacts/ios-offline/"
echo "=========================================================="
