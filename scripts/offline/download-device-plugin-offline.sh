#!/bin/bash
# =============================================================================
#  download-device-plugin-offline.sh —— 在【有网】机器上拉 device plugin 镜像,
#  存进 offline/artifacts/device-plugin/images/。
#
#  约定(与 roles/device-plugin 对齐):
#    · tar 文件名固定, 由 role 的 nvidia_device_plugin_tar / rdma_device_plugin_tar 读取
#    · 只拉 amd64(GPU/RDMA 节点都是 x86)
#    · 这些 tar 不进 git, 换机器用 rsync 拷 offline/ 过去
#
#  用法: bash scripts/offline/download-device-plugin-offline.sh [nvidia版本] [rdma版本]
#        默认 v0.17.1 / v1.5.3(与 role 默认值一致)
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
mkdir -p "$DST"

command -v skopeo >/dev/null 2>&1 || {
  echo "缺 skopeo, 请先装: apt install -y skopeo  或  yum install -y skopeo"; exit 1; }

say() { echo -e "\n>>> $*"; }

# skopeo 存的是未压缩 tar, 再 gzip 省空间(docker load 能直接读 .tar.gz)
pull() {
  local src="$1" file="$2"
  if [ -f "$DST/$file" ]; then
    echo "已存在, 跳过: $file  (要重新拉就先删掉它)"
    return 0
  fi
  say "skopeo copy $src (amd64) -> $file"
  skopeo copy --override-os linux --override-arch amd64 \
    "docker://$src" "docker-archive:$DST/${file%.gz}:$src"
  gzip -f "$DST/${file%.gz}"
}

pull "$NVIDIA_SRC" "k8s-device-plugin.tar.gz"
pull "$RDMA_SRC"   "k8s-rdma-shared-dev-plugin.tar.gz"

say "完成, 产物:"
ls -lh "$DST"
cat <<EOF

下一步:
  1) 把 offline/ 目录 rsync 到控制机(或本机就是控制机则跳过)
  2) ansible-playbook playbook/device-plugin.yaml -e is_offline=true
     (装哪些按 inventory 的 accelerator_type 自动判断; rdma 默认也装, 没 RDMA 网卡时置 device_plugin_rdma: false)
EOF
