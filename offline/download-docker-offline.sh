#!/bin/bash
# =============================================================================
#  download-docker-offline.sh —— 在【有网】机器上把 docker 层离线物料一次下齐(双架构)。
#  下载: docker 静态包 + buildx 插件 + compose 插件 + cri-dockerd, 存进 offline/artifacts/docker/。
#  文件名严格对齐 ansible 角色期望(docker_arch_map / cri_dockerd_*), 拷回内网即用。
#  containerd/runc 不在这里(已由 download-k8s-offline.sh 下)。
#
#  源: docker 静态包走 download.docker.com; buildx/compose/cri-dockerd 走 daocloud 的
#      github 代理(files.m.daocloud.io/github.com, 国内快)。
#  特性: 双架构(amd64/arm64) + curl 重试 + 远端大小校验(残缺自动重下) + 已完整则跳过。
#
#  用法: bash offline/download-docker-offline.sh
#  依赖: curl
# =============================================================================
set -e

# -------- 版本(与 inventory/group_vars/all/defaults.yaml 的 docker_arch_map / cri_dockerd_* 对齐) --------
DOCKER="29.4.2"        # docker 静态二进制包 -> {amd,arm}-docker-$DOCKER.tgz
BUILDX="0.32.1"        # docker/buildx        -> buildx-v$BUILDX.linux-{amd64,arm64}
COMPOSE="2.32.4"       # docker/compose       -> docker-compose-linux-{x86_64,aarch64}(换版本核对 releases)
CRIDOCKERD="0.3.16"    # Mirantis/cri-dockerd -> cri-dockerd-$CRIDOCKERD.{amd64,arm64}.tgz

# -------- 源 --------
DOCKER_STATIC="https://download.docker.com/linux/static/stable"
DAO="https://files.m.daocloud.io"
GH="$DAO/github.com"

D="$(cd "$(dirname "$0")/artifacts" && pwd)/docker"    # offline/artifacts/docker
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

for GOARCH in amd64 arm64; do
  case $GOARCH in
    amd64) DK="x86_64";  PFX="amd"; COMP="x86_64" ;;
    arm64) DK="aarch64"; PFX="arm"; COMP="aarch64" ;;
  esac
  echo "========== 架构 $GOARCH =========="
  # 1) docker 静态包(-> amd/arm-docker-$DOCKER.tgz, 对齐 docker_arch_map[].pkg)
  dl "$DOCKER_STATIC/$DK/docker-$DOCKER.tgz"                                  "$D/$PFX-docker-$DOCKER.tgz"
  # 2) buildx 插件(-> buildx-v$BUILDX.linux-$GOARCH, 对齐 docker_arch_map[].buildx)
  dl "$GH/docker/buildx/releases/download/v$BUILDX/buildx-v$BUILDX.linux-$GOARCH"   "$D/buildx-v$BUILDX.linux-$GOARCH"
  # 3) compose 插件(-> docker-compose-linux-$COMP, 对齐 docker_arch_map[].compose)
  dl "$GH/docker/compose/releases/download/v$COMPOSE/docker-compose-linux-$COMP"    "$D/docker-compose-linux-$COMP"
  # 4) cri-dockerd(-> cri-dockerd-$CRIDOCKERD.$GOARCH.tgz, 对齐 cri_dockerd_{x86,aarch64})
  dl "$GH/Mirantis/cri-dockerd/releases/download/v$CRIDOCKERD/cri-dockerd-$CRIDOCKERD.$GOARCH.tgz" "$D/cri-dockerd-$CRIDOCKERD.$GOARCH.tgz"
done

echo -e "\n=========================================================="
echo " docker 层离线物料下载完成! 目录: $D"
ls -1 "$D"
echo "=========================================================="
