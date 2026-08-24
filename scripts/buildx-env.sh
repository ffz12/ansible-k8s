#!/bin/bash
# =============================================================================
#  buildx-env.sh —— 配置 buildx 交叉构建环境(binfmt + docker-container builder)。
#  自包含: buildkitd 配置(registry mirror / 私有 harbor insecure)内联在本脚本, 跑时写临时文件,
#  不依赖任何外部 buildkitd.toml。手动跑一次即可, 之后再跑 nginx-ha 的 build-all.sh / build-ub.sh。
#
#  用法: bash scripts/buildx-env.sh        # 从任意目录都能跑
#  镜像加速: tonistiigi/binfmt 与 moby/buildkit 由 docker daemon 直接拉(不吃 buildkit 内部
#    的 registry mirror), 故这里给这两个镜像加国内 mirror 前缀。默认 docker.m.daocloud.io;
#    BUILDX_MIRROR=其它 覆盖, BUILDX_MIRROR= 置空回退 docker.io。
# =============================================================================
set -e

BUILDER="${BUILDX_BUILDER:-mybuilder}"
MIRROR="${BUILDX_MIRROR-docker.m.daocloud.io}"      # 单横线: 置空(BUILDX_MIRROR=)则不加前缀
BINFMT_IMG="${MIRROR:+$MIRROR/}tonistiigi/binfmt"
BUILDKIT_IMG="${MIRROR:+$MIRROR/}moby/buildkit:latest"

# buildkitd 配置内联生成到临时文件(Dockerfile 内引用的镜像走这些 mirror; 私有 harbor 免 TLS)
TOML="$(mktemp)"
trap 'rm -f "$TOML"' EXIT
cat > "$TOML" <<'EOF'
[registry."docker.io"]
  mirrors = [
     "https://docker.m.daocloud.io",
     "https://docker.1ms.run",
     "https://proxy.1panel.live",
     "https://hub1.nat.tf",
     "https://hub2.nat.tf",
     "https://docker.ketches.cn",
     "https://docker.hlmirror.com"
  ]
[registry."harbor.local.clusters"]
  insecure = true
[registry."harbor.unisound.ai"]
  insecure = true
[registry."harbor.unidev.ai"]
  insecure = true
EOF

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
    --config "$TOML"
fi

echo "🎉 buildx 交叉构建环境就绪, 可跑 nginx-ha 的 build-all.sh / build-ub.sh"
