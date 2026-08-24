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
# 私有 harbor 免 TLS 域名(可多个, 空格/逗号分隔); 默认当前 harbor, 换环境用 HARBOR_INSECURE=覆盖
HARBOR_INSECURE="${HARBOR_INSECURE:-harbor.local.clusters}"

# buildkitd 配置来源:
#   自带一份完整 toml → BUILDKITD_CONFIG=/path/to/你的.toml 直接用它(想写什么写什么, 脚本不再生成);
#   没设 → 用下面的 mirror + HARBOR_INSECURE 变量拼一份临时 toml。
if [ -n "${BUILDKITD_CONFIG:-}" ]; then
  [ -f "$BUILDKITD_CONFIG" ] || { echo "✗ BUILDKITD_CONFIG 指定的文件不存在: $BUILDKITD_CONFIG"; exit 1; }
  TOML="$BUILDKITD_CONFIG"
  echo "📄 使用自定义 buildkitd 配置: $TOML"
else
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
EOF
  # 追加私有 harbor insecure(变量驱动, 支持多域名)
  for h in ${HARBOR_INSECURE//,/ }; do
    printf '[registry."%s"]\n  insecure = true\n' "$h" >> "$TOML"
  done
fi

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
