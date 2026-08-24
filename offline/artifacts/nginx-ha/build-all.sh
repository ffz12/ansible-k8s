#!/bin/bash
set -e

NGINX_TAR="nginx-1.24.0.tar.gz"
KEEPALIVED_TAR="keepalived-2.3.4.tar.gz"
OUTPUT="./bin"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

build() {
    local os=$1
    local arch=$2
    echo "📦 构建 $os/$arch ..."
    echo "DEBUG: OS arg = '$os'"
    mkdir -p "$OUTPUT/$os/$arch"

    # 构建 nginx
    docker buildx build \
        --platform "linux/${arch}" \
        --output "type=local,dest=/tmp/out" \
        --build-arg OS="$os" \
        --build-arg NGINX_VERSION="1.24.0" \
        -f Dockerfile.nginx.unified \
        --target=final \
        . > /dev/null
    mv /tmp/out/nginx "$OUTPUT/$os/$arch/nginx"

    # 构建 keepalived
    docker buildx build \
        --platform "linux/${arch}" \
        --output "type=local,dest=/tmp/out" \
        --build-arg OS="$os" \
        --build-arg KEEPALIVED_VERSION="2.3.4" \
        -f Dockerfile.keepalived.unified \
        --target=final \
        . > /dev/null
    mv /tmp/out/keepalived/keepalived "$OUTPUT/$os/$arch/keepalived"

    chmod +x "$OUTPUT/$os/$arch/nginx" "$OUTPUT/$os/$arch/keepalived"
}

# 检查源码
[[ -f "$NGINX_TAR" && -f "$KEEPALIVED_TAR" ]] || { echo "❌ 缺少源码"; exit 1; }

# ---- 幂等配置 buildx: 交叉构建 arm64 需 binfmt(qemu) + docker-container 驱动的 builder ----
# 原来这步(binfmt 注册 + docker buildx create --driver docker-container)得手动跑 buildx-env.sh,
# 且下面若只 `docker buildx create --use` 用的是默认 docker 驱动, 交叉构建 arm 会失败。
# 这里做成幂等自动执行: 已注册/已存在就跳过, 没有才建。构建机需在线(拉 tonistiigi/binfmt + moby/buildkit)。
BUILDER="mybuilder"
# 镜像加速前缀: binfmt/buildkit 这两个镜像由 docker daemon 直接拉(不走 buildkitd.toml 的 mirror),
# 直连 docker.io 常慢/失败, 这里显式加国内 mirror 前缀。留空(BUILDX_MIRROR=)则走原始 docker.io。
MIRROR="${BUILDX_MIRROR:-docker.m.daocloud.io}"
BINFMT_IMG="${MIRROR:+$MIRROR/}tonistiigi/binfmt"
BUILDKIT_IMG="${MIRROR:+$MIRROR/}moby/buildkit:latest"
setup_buildx(){
  # 1) binfmt: 没有 arm 模拟就装(把 qemu-aarch64 等注册进内核 binfmt_misc)
  if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "🔧 注册 binfmt(qemu) 以支持交叉架构 (镜像 $BINFMT_IMG) ..."
    docker run --privileged --rm "$BINFMT_IMG" --install all
  else
    echo "✅ binfmt 已注册 qemu-aarch64, 跳过"
  fi
  # 2) builder: 没有 mybuilder(docker-container 驱动)就建, 有就直接切换使用
  if docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    echo "✅ buildx builder $BUILDER 已存在, 切换使用"
    docker buildx use "$BUILDER"
  else
    echo "🔧 创建 buildx builder $BUILDER (docker-container 驱动, buildkit 镜像 $BUILDKIT_IMG) ..."
    docker buildx create \
      --name "$BUILDER" \
      --use \
      --bootstrap \
      --driver docker-container \
      --driver-opt image="$BUILDKIT_IMG" \
      --driver-opt network=host \
      --buildkitd-flags '--allow-insecure-entitlement network.host' \
      --config ./buildkitd.toml
  fi
}
setup_buildx

#for os in ubuntu22 rocky8 rocky9; do
for os in ubuntu22 rocky8 ubuntu24 ; do
    for arch in amd64 arm64; do
        build "$os" "$arch"
    done
done

echo "✅ 完成！二进制在: $OUTPUT"
find "$OUTPUT" -type f | sort
