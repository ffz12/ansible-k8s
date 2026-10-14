#!/bin/bash
# =============================================================================
#  download-monitor-offline.sh —— 在【有网】机器上拉监控组件镜像,
#  存进 offline/artifacts/monitor/images/<架构>/。
#
#  约定(与 roles/monitor 对齐, 同 download-device-plugin-offline.sh):
#    · tar 按架构放子目录, 文件名固定(由 role 的 dcgm_exporter_tar 等读取)
#    · 这些 tar 不进 git, 换机器用 rsync 拷 offline/ 过去
#
#  用法: bash scripts/offline/download-monitor-offline.sh [dcgm版本]
#        默认 4.5.2-4.8.1-ubuntu22.04(与 role 默认值一致)
#        架构由 ARCH 控制: ARCH=amd64 bash ...(默认 all = amd64 + arm64)
#  依赖: skopeo(按架构精确拉, 不依赖 docker daemon)
# =============================================================================
set -e

DCGM_VER="${1:-4.5.2-4.8.1-ubuntu22.04}"

# 上游地址。国内拉不动时换成镜像代理(如 docker.m.daocloud.io/<原路径>)
DCGM_SRC="nvcr.io/nvidia/k8s/dcgm-exporter:${DCGM_VER}"

OFFLINE="$(cd "$(dirname "$0")/../../offline" && pwd)"
DST="$OFFLINE/artifacts/monitor/images"

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
  pull "$DCGM_SRC" "dcgm-exporter.tar.gz" "$a"
done

say "完成, 产物:"
find "$DST" -name '*.tar.gz' -exec ls -lh {} \;
cat <<EOF

下一步:
  1) 把 offline/ 目录 rsync 到控制机(或本机就是控制机则跳过)
  2) ansible-playbook playbook/monitor.yaml
     (抓取方式自动探测: 有 ServiceMonitor CRD 就生成 ServiceMonitor, 否则走 Pod 注解)
EOF
