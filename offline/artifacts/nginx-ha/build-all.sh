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

docker buildx create --use --name mybuilder 2>/dev/null || true

#for os in ubuntu22 rocky8 rocky9; do
for os in ubuntu22 rocky8 ubuntu24 ; do
    for arch in amd64 arm64; do
        build "$os" "$arch"
    done
done

echo "✅ 完成！二进制在: $OUTPUT"
find "$OUTPUT" -type f | sort
