#!/bin/bash
# =============================================================================
#  download-harbor-k8s-offline.sh —— 在【有网】机器上拉 k8s 版 Harbor 的离线物料,
#  存进 offline/artifacts/harbor-k8s/。
#
#  产物(与 roles/harbor-k8s 对齐):
#    offline/artifacts/harbor-k8s/harbor-<chart版本>.tgz          helm chart
#    offline/artifacts/harbor-k8s/images/<架构>/<镜像名>.tar.gz   9 个组件镜像
#  这些文件不进 git, 换机器用 rsync 拷 offline/ 过去。
#
#  用法: bash scripts/offline/download-harbor-k8s-offline.sh [chart版本] [镜像tag]
#        默认 1.15.2 / v2.11.2(与 role 默认值一致, 改版本要两边一起改)
#        架构由 ARCH 控制: ARCH=amd64 bash ...(默认 amd64; Harbor 上游 arm64 镜像不全)
#  依赖: skopeo、helm
# =============================================================================
set -e

CHART_VER="${1:-1.15.2}"
IMG_TAG="${2:-v2.11.2}"
# 国内拉不动时换成镜像代理, 如 docker.m.daocloud.io/goharbor
SRC_REPO="${SRC_REPO:-docker.io/goharbor}"

IMAGES="nginx-photon harbor-portal harbor-core harbor-jobservice registry-photon
        harbor-registryctl harbor-db redis-photon harbor-exporter"

OFFLINE="$(cd "$(dirname "$0")/../../offline" && pwd)"
DST="$OFFLINE/artifacts/harbor-k8s"

case "${ARCH:-amd64}" in
  all)   ARCHS="amd64 arm64" ;;
  amd64) ARCHS="amd64" ;;
  arm64) ARCHS="arm64" ;;
  *)     echo "ARCH 只能是 all / amd64 / arm64, 当前: $ARCH"; exit 1 ;;
esac

for c in skopeo helm; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺 $c, 请先安装"; exit 1; }
done

say() { echo -e "\n>>> $*"; }
mkdir -p "$DST"

say "helm chart harbor $CHART_VER"
if [ -f "$DST/harbor-$CHART_VER.tgz" ]; then
  echo "已存在, 跳过: harbor-$CHART_VER.tgz"
else
  helm repo add harbor https://helm.goharbor.io --force-update >/dev/null
  helm repo update harbor >/dev/null
  helm pull harbor/harbor --version "$CHART_VER" -d "$DST"
fi

# skopeo 存的是未压缩 tar, 再 gzip 省空间(docker load 能直接读 .tar.gz)
for a in $ARCHS; do
  mkdir -p "$DST/images/$a"
  for img in $IMAGES; do
    out="$DST/images/$a/$img.tar.gz"
    if [ -f "$out" ]; then
      echo "已存在, 跳过: $a/$img.tar.gz  (要重新拉就先删掉它)"
      continue
    fi
    say "skopeo copy $SRC_REPO/$img:$IMG_TAG ($a)"
    skopeo copy --override-os linux --override-arch "$a" \
      "docker://$SRC_REPO/$img:$IMG_TAG" "docker-archive:${out%.gz}:goharbor/$img:$IMG_TAG"
    gzip -f "${out%.gz}"
  done
done

say "完成, 产物:"
find "$DST" -name '*.tgz' -o -name '*.tar.gz' | xargs ls -lh
cat <<EOF

下一步:
  1) 把 offline/ 目录 rsync 到控制机(或本机就是控制机则跳过)
  2) env.yaml 配 harbor_k8s_domain / harbor_k8s_storage_class
  3) ansible-playbook playbook/harbor-k8s.yaml
EOF
