#!/bin/bash
# =============================================================================
#  download-docker-offline.sh —— 在【有网】机器上把底座运行时 + docker 层离线物料一次下齐(双架构)。
#  下载: containerd + runc + docker 静态包 + buildx 插件 + compose 插件 + cri-dockerd。
#  文件名严格对齐 ansible 角色期望(docker_arch_map / cri_dockerd_* / containerd_version / runc_version), 拷回内网即用。
#  ★ containerd/runc 是底座运行时(docker 复用 containerd, harbor 节点也需要), 故归本脚本;
#    这样"只离线装底座(不上 k8s)"也自洽, 无需先跑 download-k8s-offline.sh。
#
#  源: docker 静态包走 download.docker.com; buildx/compose/cri-dockerd 走 daocloud 的
#      github 代理(files.m.daocloud.io/github.com, 国内快)。
#  特性: 双架构(amd64/arm64) + curl 重试 + 远端大小校验(残缺自动重下) + 已完整则跳过。
#
#  用法: bash scripts/offline/download-docker-offline.sh [amd64|arm64|all]   (默认 all=双架构)
#        集群是纯 amd64 或纯 arm64 时, 指定单架构可省一半体积/时间。
#  依赖: curl
# =============================================================================
set -e

# -------- 架构选择(默认双架构; 单架构集群指定一个即可省一半) --------
case "${1:-all}" in
  amd64) ARCHES="amd64" ;;
  arm64) ARCHES="arm64" ;;
  all)   ARCHES="amd64 arm64" ;;
  *) echo "用法: bash $0 [amd64|arm64|all]  (默认 all)"; exit 1 ;;
esac

# -------- 版本(单一源) --------
# 优先 source 由 gen-offline-versions.yaml 从 ansible 变量生成的 versions.env(与部署同源);
# 没有该文件时用下面 :=兜底默认, 脚本仍可脱离 ansible 独立跑。
# 文件名/tag 与 defaults.yaml 的 docker_arch_map / cri_dockerd_* / containerd_version / runc_version 一致。
[ -f "$(dirname "$0")/versions.env" ] && . "$(dirname "$0")/versions.env"
: "${DOCKER:=29.4.2}"        # docker 静态二进制包 -> {amd,arm}-docker-$DOCKER.tgz
: "${BUILDX:=0.32.1}"        # docker/buildx        -> buildx-v$BUILDX.linux-{amd64,arm64}
: "${COMPOSE:=2.32.4}"       # docker/compose       -> docker-compose-linux-{x86_64,aarch64}(换版本核对 releases)
: "${CRIDOCKERD:=0.3.16}"    # Mirantis/cri-dockerd -> cri-dockerd-$CRIDOCKERD.{amd64,arm64}.tgz
: "${CONTAINERD:=1.7.32}"    # containerd 静态包(与 env.yaml containerd_version 一致; 换 2.2.3 改那里重生成)
: "${RUNC:=1.1.12}"          # runc(containerd 依赖; 官方 containerd 包不含 runc, 单独下)

# -------- 源 --------
# docker 静态包多源: 国内镜像优先, 官方兜底。
# ⚠ download.docker.com 在国内常被限速/重置(实测 17KB/s 甚至 connection reset),
#   82M 的包能拖一小时以上; 阿里云/清华/中科大镜像通常几十 MB/s。
DOCKER_STATIC_MIRRORS="https://mirrors.aliyun.com/docker-ce/linux/static/stable https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/static/stable https://mirrors.ustc.edu.cn/docker-ce/linux/static/stable https://download.docker.com/linux/static/stable"
DAO="https://files.m.daocloud.io"
GH="$DAO/github.com"
CONTAINERD_BIN="$GH/containerd/containerd/releases/download"
RUNC_BIN="$GH/opencontainers/runc/releases/download"

OFFLINE="$(cd "$(dirname "$0")/../../offline" && pwd)"   # scripts/offline/ -> offline/(物料仍落 offline)
A="$OFFLINE/artifacts"; mkdir -p "$A"            # offline/artifacts (containerd/runc 落这层)
D="$A/docker"                                    # offline/artifacts/docker
mkdir -p "$D"
say(){ echo -e "\033[0;32m[+] $*\033[0m"; }

command -v curl >/dev/null 2>&1 || { echo "缺 curl"; exit 1; }

# 远端 Content-Length(跟随重定向)
rsize(){ curl -sIL -m 15 "$1" 2>/dev/null | awk 'BEGIN{IGNORECASE=1}/^content-length:/{v=$2}END{gsub(/\r/,"",v);print v}'; }
# 下载 + 大小校验; 残缺/不符自动重下. $1=url $2=dest
dl(){
  local url="$1" dest="$2" i r l
  if [ -s "$dest" ]; then
    r=$(rsize "$url"); l=$(stat -c%s "$dest" 2>/dev/null || wc -c <"$dest")
    if [ -z "$r" ] || [ "$r" = "$l" ]; then say "跳过(完整) $(basename "$dest")"; return; fi
    say "已存在但大小不符($l/$r), 重下 $(basename "$dest")"; rm -f "$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  for i in 1 2 3 4 5; do
    say "curl $url"
    curl -fSL --retry 3 -o "$dest" "$url" || { echo "  下载失败,第 $i 次重试"; sleep 5; continue; }
    r=$(rsize "$url"); l=$(stat -c%s "$dest" 2>/dev/null || wc -c <"$dest")
    { [ -z "$r" ] || [ "$r" = "$l" ]; } && return
    echo "  大小不符($l/$r),第 $i 次重下"; rm -f "$dest"; sleep 3
  done
  echo "✗ 下载/校验失败: $url"; exit 1
}

# 多源下载: 依次试各镜像, 第一个成功即返回。$1=相对路径 $2=目标文件 $3...=源列表
dl_multi(){
  local rel="$1" dest="$2"; shift 2
  local base r l
  if [ -s "$dest" ]; then say "跳过(已存在) $(basename "$dest")"; return; fi
  for base in "$@"; do
    say "curl $base/$rel"
    if curl -fSL --retry 2 --connect-timeout 15 --speed-time 30 --speed-limit 10240          -o "$dest" "$base/$rel"; then
      r=$(rsize "$base/$rel"); l=$(stat -c%s "$dest" 2>/dev/null || wc -c <"$dest")
      if [ -z "$r" ] || [ "$r" = "$l" ]; then return; fi
      echo "  大小不符($l/$r), 换下一个源"
    else
      echo "  该源失败/过慢(<10KB/s 持续 30s), 换下一个源"
    fi
    rm -f "$dest"
  done
  echo "✗ 所有源均失败: $rel"; exit 1
}

for GOARCH in $ARCHES; do
  case $GOARCH in
    amd64) DK="x86_64";  PFX="amd"; COMP="x86_64" ;;
    arm64) DK="aarch64"; PFX="arm"; COMP="aarch64" ;;
  esac
  echo "========== 架构 $GOARCH =========="
  # 1) docker 静态包(-> amd/arm-docker-$DOCKER.tgz, 对齐 docker_arch_map[].pkg)
  dl_multi "$DK/docker-$DOCKER.tgz" "$D/$PFX-docker-$DOCKER.tgz" $DOCKER_STATIC_MIRRORS
  # 2) buildx 插件(-> buildx-v$BUILDX.linux-$GOARCH, 对齐 docker_arch_map[].buildx)
  dl "$GH/docker/buildx/releases/download/v$BUILDX/buildx-v$BUILDX.linux-$GOARCH"   "$D/buildx-v$BUILDX.linux-$GOARCH"
  # 3) compose 插件(-> docker-compose-linux-$COMP, 对齐 docker_arch_map[].compose)
  dl "$GH/docker/compose/releases/download/v$COMPOSE/docker-compose-linux-$COMP"    "$D/docker-compose-linux-$COMP"
  # 4) cri-dockerd(-> cri-dockerd-$CRIDOCKERD.$GOARCH.tgz, 对齐 cri_dockerd_{x86,aarch64})
  dl "$GH/Mirantis/cri-dockerd/releases/download/v$CRIDOCKERD/cri-dockerd-$CRIDOCKERD.$GOARCH.tgz" "$D/cri-dockerd-$CRIDOCKERD.$GOARCH.tgz"
  # 5) containerd 静态包(底座运行时, docker 复用它; -> artifacts/containerd/v$CONTAINERD/$GOARCH/)
  dl "$CONTAINERD_BIN/v$CONTAINERD/containerd-$CONTAINERD-linux-$GOARCH.tar.gz" "$A/containerd/v$CONTAINERD/$GOARCH/containerd-$CONTAINERD-linux-$GOARCH.tar.gz"
  # 6) runc(containerd 依赖; -> artifacts/runc/v$RUNC/$GOARCH/runc.$GOARCH)
  dl "$RUNC_BIN/v$RUNC/runc.$GOARCH" "$A/runc/v$RUNC/$GOARCH/runc.$GOARCH"; chmod +x "$A/runc/v$RUNC/$GOARCH/runc.$GOARCH"
done

echo -e "\n=========================================================="
echo " 底座运行时 + docker 层离线物料下载完成!"
echo "   docker 层:      $D"
echo "   containerd/runc: $A/containerd , $A/runc"
ls -1 "$D"
echo "=========================================================="
