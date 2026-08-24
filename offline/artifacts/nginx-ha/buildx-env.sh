#!/bin/bash
# =============================================================================
#  buildx-env.sh —— 手动跑一次, 配置 buildx 交叉构建环境(binfmt + docker-container builder)。
#  交叉构建 arm64(在 amd64 机器上)需要它; 配好后再跑 build-all.sh / build-ub.sh。
#
#  镜像加速: tonistiigi/binfmt 与 moby/buildkit 由 docker daemon 直接拉, 不走 buildkitd.toml
#    的 mirror, 直连 docker.io 常慢/失败, 故这里给这两个镜像加国内 mirror 前缀。
#    默认 docker.m.daocloud.io; 用 BUILDX_MIRROR=其它 覆盖, 或 BUILDX_MIRROR= 置空回退 docker.io。
# =============================================================================
set -e
cd "$(dirname "$0")"   # 确保能读到同目录 buildkitd.toml

BUILDER="${BUILDX_BUILDER:-mybuilder}"
MIRROR="${BUILDX_MIRROR-docker.m.daocloud.io}"      # 单横线: 置空(BUILDX_MIRROR=)则不加前缀
BINFMT_IMG="${MIRROR:+$MIRROR/}tonistiigi/binfmt"
BUILDKIT_IMG="${MIRROR:+$MIRROR/}moby/buildkit:latest"

# 1) binfmt: 内核没注册 qemu-aarch64 才装, 否则跳过(可重复跑)
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  echo "🔧 注册 binfmt(qemu) 支持交叉架构 (镜像 $BINFMT_IMG) ..."
  docker run --privileged --rm "$BINFMT_IMG" --install all
else
  echo "✅ binfmt 已注册 qemu-aarch64, 跳过"
fi

# 2) builder: mybuilder 已存在则切换使用, 否则以 docker-container 驱动创建(可重复跑)
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

echo "🎉 buildx 交叉构建环境就绪, 可跑 build-all.sh / build-ub.sh"
