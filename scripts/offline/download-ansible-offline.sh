#!/bin/bash
# =============================================================================
#  download-ansible-offline.sh —— 一键下载各发行版的【离线 ansible 安装包】
#  用途: 内网机器没有 ansible 时, 先在联网机上把 ansible 及其全量依赖打成离线 tar,
#        拷进内网解压后本地安装(见每个包解压出的顶层目录), 再跑本项目的 playbook。
#
#  产物: offline/ansible-pkg-install/ansible_<发行版><版本>_<arch>.tar.gz (双架构 amd64/arm64)
#        每个 tar 解压后带顶层目录, 例:
#          麒麟   ansible_kylin_x86_64.tar.gz    -> ansible_kylin_x86_64/*.rpm
#          Ubuntu ansible_ubuntu22_x86_64.tar.gz -> ansible_ubuntu22_x86_64/*.deb + Packages
#
#  版本: 全部取该系统当前【可得的最新版】(Ubuntu 走官方 PPA; 麒麟走 EPEL + 默认源)。
#
#  依赖: docker(用多架构镜像拉包, 需能 --platform linux/arm64)。
#  用法: bash scripts/offline/download-ansible-offline.sh [kylin|ubuntu|openeuler|all] [amd64|arm64|all]
#        第 1 参数 = 发行版(默认 all);  第 2 参数 = 架构(默认 all=双架构, 单架构集群指定一个省一半)。
# =============================================================================
set -e

SELF="$(cd "$(dirname "$0")" && pwd)"
OFFLINE="$(cd "$SELF/../../offline" && pwd)"   # scripts/offline/ -> offline/(产物落 offline)
TARGET="${1:-all}"
ARCH_ARG="${2:-all}"
case "$ARCH_ARG" in amd64|arm64|all) ;; *) echo "架构参数须为 amd64|arm64|all"; exit 1 ;; esac

command -v docker >/dev/null 2>&1 || { echo "缺 docker(脚本用容器按架构精确拉包), 请先安装"; exit 1; }

run() {
  local script="$1"
  echo "=========================================================="
  echo " 调用 $script  (架构: $ARCH_ARG)"
  echo "=========================================================="
  bash "$SELF/$script" "$ARCH_ARG"
}

case "$TARGET" in
  kylin)    run download_kylin_ansible.sh ;;
  ubuntu)   run download_ubuntu_ansible.sh ;;
  openeuler) run download_openeuler_ansible.sh ;;
  all)
    run download_kylin_ansible.sh
    run download_ubuntu_ansible.sh
    run download_openeuler_ansible.sh
    ;;
  *)
    echo "用法: bash $0 [kylin|ubuntu|openeuler|all] [amd64|arm64|all]"; exit 1 ;;
esac

echo -e "\n=========================================================="
echo " 全部完成! 离线 ansible 安装包在: $OFFLINE/ansible-pkg-install/"
echo " 内网安装示例:"
echo "   麒麟/openEuler:  tar xzf ansible_kylin_x86_64.tar.gz && cd ansible_kylin_x86_64 && rpm -Uvh --force ./*.rpm"
echo "   Ubuntu:          tar xzf ansible_ubuntu22_x86_64.tar.gz && cd ansible_ubuntu22_x86_64 && dpkg -i ./*.deb || apt -f install"
echo "=========================================================="
