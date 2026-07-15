#!/bin/bash
set -e

# 创建输出目录
mkdir -p bin/amd64 bin/arm64

# 构建函数：支持 nginx / keepalived
build_component() {
  local name=$1
  echo "📦 Building $name for linux/amd64 and linux/arm64..."

  tmp_out=$(mktemp -d)
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --output "type=local,dest=$tmp_out" \
    -f "Dockerfile.$name" \
    .

  # 提取二进制
  if [ "$name" = "nginx" ]; then
    mv "$tmp_out/linux_amd64/data/nginx/sbin/nginx" bin/amd64/nginx
    mv "$tmp_out/linux_arm64/data/nginx/sbin/nginx" bin/arm64/nginx
  elif [ "$name" = "keepalived" ]; then
    mv "$tmp_out/linux_amd64/usr/local/sbin/keepalived/keepalived" bin/amd64/keepalived
    mv "$tmp_out/linux_arm64/usr/local/sbin/keepalived/keepalived" bin/arm64/keepalived
  fi

  rm -rf "$tmp_out"
  echo "✅ $name built successfully."
}

# 并行构建（可选：加快速度）
build_component nginx
build_component keepalived

echo
echo "🎉 All binaries ready!"
tree bin/

