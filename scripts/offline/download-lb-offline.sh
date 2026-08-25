#!/bin/bash
# =============================================================================
#  download-lb-offline.sh —— 下载 haproxy + keepalived(及全量依赖)离线包,
#  供 haproxy-ha 角色在【离线】环境安装 LB 高可用。
#
#  背景: 两条 LB 路径的离线方式不同——
#    - nginx-ha  : nginx/keepalived 走【bundled 二进制】(offline/artifacts/nginx-ha/bin/...), 不用本脚本;
#    - haproxy-ha: 用 yum/apt 装 haproxy+keepalived, 离线时需要本地有这两个包 -> 本脚本负责下载。
#  这两个包只有 LB 节点需要, 故【单独打包】, 不混进所有节点都装的基础包(ios-offline)。
#
#  产物: offline/artifacts/lb-offline/lb_<发行版><版本>_<arch>.tar.gz  (amd64 + arm64)
#    麒麟       lb_kylin_x86_64.tar.gz      / lb_kylin_arm64.tar.gz
#    Ubuntu     lb_ubuntu22_x86_64.tar.gz   / lb_ubuntu24_*  ...
#    openEuler  lb_openEuler22_x86_64.tar.gz / ...
#
#  依赖: docker; arm64 在 x86 主机上需先装一次 qemu binfmt:
#          docker run --privileged --rm tonistiigi/binfmt --install arm64
#  用法: bash scripts/offline/download-lb-offline.sh [kylin|ubuntu|openeuler|all] [amd64|arm64|all]
#        (默认 all all; 单架构集群指定一个可省一半)
#  镜像源不可达(docker.io 拉不动)时, 用环境变量指向内网 mirror:
#        UBUNTU_IMAGE_PREFIX=dce-boot.io/library/ubuntu \
#        EULER_IMAGE=dce-boot.io/openeuler/openeuler:22.03-lts-sp4 \
#        bash scripts/offline/download-lb-offline.sh
#        某发行版镜像拉不到只会跳过并提示, 不影响其它发行版继续。
# =============================================================================
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OFFLINE="$(cd "$DIR/../../offline" && pwd)"   # scripts/offline/ -> offline/
OUT="$OFFLINE/artifacts/lb-offline"
mkdir -p "$OUT"

TARGET="${1:-all}"
ARCH_ARG="${2:-all}"
case "$ARCH_ARG" in amd64|arm64|all) ;; *) echo "架构参数须为 amd64|arm64|all"; exit 1 ;; esac

LB_PKGS="haproxy keepalived"
# 镜像源可用环境变量覆盖(内网/docker.io 不可达时指向可达 mirror, 如 dce-boot.io/...):
#   KYLIN_IMAGE=... EULER_IMAGE=... UBUNTU_IMAGE_PREFIX=dce-boot.io/library/ubuntu bash offline/download-lb-offline.sh
KYLIN_IMAGE="${KYLIN_IMAGE:-hxsoong/kylin:v10-sp3}"
EULER_IMAGE="${EULER_IMAGE:-openeuler/openeuler:22.03-lts-sp4}"
UBUNTU_IMAGE_PREFIX="${UBUNTU_IMAGE_PREFIX:-ubuntu}"   # 拼成 <prefix>:22.04 / <prefix>:24.04

command -v docker >/dev/null 2>&1 || { echo "缺 docker(脚本用容器按架构精确拉包), 请先安装"; exit 1; }

# 按 ARCH_ARG 得到 "arch:tag" 对: amd64->x86_64, arm64->arm64
arch_pairs() {
  case "$ARCH_ARG" in
    amd64) echo "amd64:x86_64" ;;
    arm64) echo "arm64:arm64" ;;
    all)   echo "amd64:x86_64 arm64:arm64" ;;
  esac
}

# 打包临时目录到 tar 并清理: $1=tmp 目录  $2=目标 tar
pack() {
  if [ "$(ls -A "$1" 2>/dev/null)" ]; then
    tar -czf "$2" -C "$1" .
    echo " 🌟 [ 成功 ] $(basename "$2") ($(ls -1 "$1" | wc -l) 个包)"
  else
    echo " ❌ [ 失败 ] 下载目录为空: $(basename "$2") (检查源/包名/网络)"
  fi
  rm -rf "$1"
}

# RPM 系(麒麟/openEuler): $1=镜像 $2=arch $3=tag $4=文件名标签
dl_rpm() {
  local out="$OUT/lb_${4}_${3}.tar.gz"
  if [ -s "$out" ]; then echo "========== $4 [$2 -> $3] 跳过(已存在 $(basename "$out"),删了可重下) =========="; return; fi
  local tmp="$OUT/.tmp_${4}_${3}"; rm -rf "$tmp"; mkdir -p "$tmp"
  echo "========== $4 [$2 -> $3] haproxy+keepalived =========="
  docker run --rm --platform "linux/$2" -v "$tmp":/tmp/download "$1" sh -c "
    yum install -y -q dnf-plugins-core >/dev/null 2>&1 || true
    yum config-manager --set-enabled EPOL >/dev/null 2>&1 || true
    yum install --downloadonly --downloaddir=/tmp/download $LB_PKGS -y >/dev/null 2>&1 || true
  " || echo " ⚠️  $4 [$3] 容器运行失败(镜像拉取/网络?), 跳过 —— 见文末 mirror 说明"
  pack "$tmp" "$out"
}

# DEB 系(Ubuntu): $1=ubuntu 版本 $2=arch $3=tag $4=主版本号
dl_deb() {
  local out="$OUT/lb_ubuntu${4}_${3}.tar.gz"
  if [ -s "$out" ]; then echo "========== ubuntu$4 [$2 -> $3] 跳过(已存在 $(basename "$out"),删了可重下) =========="; return; fi
  local tmp="$OUT/.tmp_ubuntu${4}_${3}"; rm -rf "$tmp"; mkdir -p "$tmp"
  echo "========== ubuntu$4 [$2 -> $3] haproxy+keepalived =========="
  docker run --rm --platform "linux/$2" -v "$tmp":/tmp/download "${UBUNTU_IMAGE_PREFIX}":"$1" sh -c "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq apt-utils >/dev/null
    cd /tmp/download
    apt-get download \$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances $LB_PKGS | grep '^\w' | sort -u) 2>/dev/null || true
    apt-get download $LB_PKGS 2>/dev/null || true
  " || echo " ⚠️  ubuntu$4 [$3] 容器运行失败(镜像拉取/网络?), 跳过 —— 见文末 mirror 说明"
  pack "$tmp" "$out"
}

do_kylin()     { for p in $(arch_pairs); do dl_rpm "$KYLIN_IMAGE" "${p%%:*}" "${p##*:}" kylin;        done; }
do_openeuler() { for p in $(arch_pairs); do dl_rpm "$EULER_IMAGE" "${p%%:*}" "${p##*:}" openEuler22;  done; }
do_ubuntu()    {
  for p in $(arch_pairs); do dl_deb 22.04 "${p%%:*}" "${p##*:}" 22; done
  for p in $(arch_pairs); do dl_deb 24.04 "${p%%:*}" "${p##*:}" 24; done
}

case "$TARGET" in
  kylin)     do_kylin ;;
  ubuntu)    do_ubuntu ;;
  openeuler) do_openeuler ;;
  all)       do_kylin; do_ubuntu; do_openeuler ;;
  *) echo "用法: bash $0 [kylin|ubuntu|openeuler|all] [amd64|arm64|all]"; exit 1 ;;
esac

echo -e "\n=========================================================="
echo " 完成! haproxy/keepalived 离线包在: $OUT/"
echo " 供 haproxy-ha 角色离线安装(nginx-ha 走 bundled 二进制, 与此无关)。"
echo "----------------------------------------------------------"
echo " 若某发行版显示 ⚠️ 跳过, 多半是该基础镜像 docker.io 不可达。可:"
echo "   - 只下你集群用到的发行版:  bash $0 kylin"
echo "   - 或用可达 mirror 覆盖镜像源, 例如:"
echo "       UBUNTU_IMAGE_PREFIX=dce-boot.io/library/ubuntu \\"
echo "       EULER_IMAGE=dce-boot.io/openeuler/openeuler:22.03-lts-sp4 \\"
echo "       bash $0"
echo "=========================================================="
