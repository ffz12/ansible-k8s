#!/bin/bash
# =============================================================================
#  download-device-plugin-offline.sh —— 在【有网】机器上拉 device plugin 镜像,
#  存进 offline/artifacts/device-plugin/images/。
#
#  约定(与 roles/device-plugin 对齐):
#    · tar 按架构放子目录: images/<amd64|arm64>/<文件名>, role 自己探测有哪些架构
#    · 文件名固定, 由 role 的 nvidia_device_plugin_tar / rdma_device_plugin_tar 读取
#    · 这些 tar 不进 git, 换机器用 rsync 拷 offline/ 过去
#
#  用法: bash scripts/offline/download-device-plugin-offline.sh [nvidia版本] [rdma版本]
#        默认 v0.17.1 / v1.5.3(与 role 默认值一致)
#        架构由 ARCH 控制: ARCH=amd64 bash ...(默认 all = amd64 + arm64)
#  依赖: skopeo(按架构精确拉, 不依赖 docker daemon)
# =============================================================================
set -e

NVIDIA_VER="${1:-v0.17.1}"
RDMA_VER="${2:-v1.5.3}"

# 上游地址。国内拉不动时换成镜像代理(如 docker.m.daocloud.io/<原路径>)
NVIDIA_SRC="nvcr.io/nvidia/k8s-device-plugin:${NVIDIA_VER}"
RDMA_SRC="ghcr.io/mellanox/k8s-rdma-shared-dev-plugin:${RDMA_VER}"

OFFLINE="$(cd "$(dirname "$0")/../../offline" && pwd)"
DST="$OFFLINE/artifacts/device-plugin/images"

# 架构: all(默认) / amd64 / arm64。两个上游镜像都是双架构。
case "${ARCH:-all}" in
  all)   ARCHS="amd64 arm64" ;;
  amd64) ARCHS="amd64" ;;
  arm64) ARCHS="arm64" ;;
  *)     echo "ARCH 只能是 all / amd64 / arm64, 当前: $ARCH"; exit 1 ;;
esac
for a in $ARCHS; do mkdir -p "$DST/$a"; done

command -v skopeo >/dev/null 2>&1 || {
  echo "缺 skopeo, 请先装: apt install -y skopeo  或  yum install -y skopeo"; exit 1; }

say() { echo -e "\n>>> $*"; }

# skopeo 存的是未压缩 tar, 再 gzip 省空间(docker load 能直接读 .tar.gz)
pull() {
  local src="$1" file="$2" arch="$3"
  local out="$DST/$arch/$file"
  if [ -f "$out" ]; then
    echo "已存在, 跳过: $arch/$file  (要重新拉就先删掉它)"
    return 0
  fi
  say "skopeo copy $src ($arch) -> $arch/$file"
  skopeo copy --override-os linux --override-arch "$arch" \
    "docker://$src" "docker-archive:${out%.gz}:$src"
  gzip -f "${out%.gz}"
}

for a in $ARCHS; do
  pull "$NVIDIA_SRC" "k8s-device-plugin.tar.gz"          "$a"
  pull "$RDMA_SRC"   "k8s-rdma-shared-dev-plugin.tar.gz" "$a"
done

say "完成, 产物:"
find "$DST" -name '*.tar.gz' -exec ls -lh {} \;
cat <<EOF

下一步:
  1) 把 offline/ 目录 rsync 到控制机(或本机就是控制机则跳过)
  2) ansible-playbook playbook/device-plugin.yaml
     (装哪些按 inventory 的 accelerator_type 自动判断; rdma 默认也装, 没 RDMA 网卡时置 device_plugin_rdma: false)
EOF
