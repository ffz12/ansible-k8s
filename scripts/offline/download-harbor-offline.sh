#!/bin/bash
# =============================================================================
#  download-harbor-offline.sh —— 在【有网】机器上把 Harbor 离线物料下齐(仅 amd64)。
#  下载: 12 个 goharbor 组件镜像(存成 docker load 可用的 .tar.gz) + docker-compose 二进制。
#  文件名严格对齐 ansible harbor 角色期望(group_vars 的 harbor_offline_images + x86.yaml),
#  落到 offline/artifacts/harbor/x86/ , 拷回内网即用。
#
#  ★ 为什么只有 amd64: goharbor 官方镜像仅 amd64, Docker Hub 无任何版本的官方 arm64
#    (多架构 PR goharbor/harbor#21825 至今 stalled)。arm64(harbor_images_aarch64, v2.13.0)
#    来自 octohelm/harbor 的现成多架构镜像(ghcr.io/octohelm/harbor/<组件>:v2.13.0,
#    国内可走 ghcr.m.daocloud.io), 复用已做好的那批 tar 即可, 本脚本只管 amd64。
#
#  源: goharbor 镜像走 daocloud 加速(docker.m.daocloud.io/goharbor = docker.io/goharbor);
#      docker-compose 走 daocloud 的 github 代理。skopeo 直接拉, 不依赖 docker daemon。
#  依赖: skopeo、curl、gzip、tar
#  用法: bash scripts/offline/download-harbor-offline.sh
# =============================================================================
set -e

# -------- 版本(harbor 与 group_vars/all/defaults.yaml 的 harbor_offline_images 对齐) --------
HARBOR="2.11.2"        # goharbor 组件镜像 tag -> <组件>-v$HARBOR.tar.gz
COMPOSE="2.32.4"       # 与 docker_arch_map[].compose 保持一致(换版本核对 releases)

# 12 个组件(= harbor_offline_images 去掉 -v$HARBOR.tar.gz;也 == goharbor/<组件> 镜像名)
COMPONENTS="harbor-exporter redis-photon trivy-adapter-photon harbor-registryctl \
registry-photon nginx-photon harbor-log harbor-jobservice harbor-core harbor-portal \
harbor-db prepare"

# -------- 源 --------
HARBOR_SRC="docker.m.daocloud.io/goharbor"                  # = docker.io/goharbor(daocloud 加速)
DAO="https://files.m.daocloud.io"
COMPOSE_BIN="$DAO/github.com/docker/compose/releases/download"

OFFLINE="$(cd "$(dirname "$0")/../../offline" && pwd)"   # scripts/offline/ -> offline/
A="$OFFLINE/artifacts"                            # offline/artifacts
D="$A/harbor/x86"                                # 角色 x86.yaml 从这里取
mkdir -p "$D"
say(){ echo -e "\033[0;32m[+] $*\033[0m"; }

command -v skopeo >/dev/null 2>&1 || { echo "缺 skopeo, 请先装: yum install -y skopeo  或  apt install -y skopeo"; exit 1; }
command -v curl   >/dev/null 2>&1 || { echo "缺 curl"; exit 1; }

# 远端 Content-Length(跟随重定向)
rsize(){ curl -sIL -m 15 "$1" 2>/dev/null | awk 'BEGIN{IGNORECASE=1}/^content-length:/{v=$2}END{gsub(/\r/,"",v);print v}'; }

# ========== 1. 12 个 harbor 组件镜像 ==========
# skopeo 按 amd64 精确拉取存成 docker-archive(load 名 = goharbor/<组件>:v$HARBOR, 供 harbor compose 识别),
# 再 gzip 省空间(harbor install.sh 里 docker load 会自动解压 .tar.gz)。
for c in $COMPONENTS; do
  file="$c-v$HARBOR.tar.gz"
  if [ -s "$D/$file" ]; then say "跳过(已存在) $file"; continue; fi
  for i in 1 2 3 4 5; do
    say "skopeo copy $HARBOR_SRC/$c:v$HARBOR (amd64) -> $file"
    if skopeo copy --override-os linux --override-arch amd64 \
        "docker://$HARBOR_SRC/$c:v$HARBOR" "docker-archive:$D/$c-v$HARBOR.tar:goharbor/$c:v$HARBOR"; then
      say "gzip $c-v$HARBOR.tar -> $file"
      gzip -f "$D/$c-v$HARBOR.tar"
      break
    fi
    echo "  失败, 第 $i 次重试..."; rm -f "$D/$c-v$HARBOR.tar" "$D/$file"; sleep 5
    [ "$i" = 5 ] && { echo "  ✗ $c:v$HARBOR 多次失败"; exit 1; }
  done
done

# ========== 2. docker-compose 二进制(-> docker-compose.x86, 对齐 x86.yaml) ==========
dest="$D/docker-compose.x86"
if [ -s "$dest" ]; then
  say "跳过(已存在) docker-compose.x86"
else
  url="$COMPOSE_BIN/v$COMPOSE/docker-compose-linux-x86_64"
  for i in 1 2 3 4 5; do
    say "curl $url"
    if curl -fSL --retry 3 -o "$dest" "$url"; then
      r=$(rsize "$url"); l=$(stat -c%s "$dest" 2>/dev/null || wc -c <"$dest")
      { [ -z "$r" ] || [ "$r" = "$l" ]; } && { chmod +x "$dest"; break; }
      echo "  大小不符($l/$r),第 $i 次重下"
    else
      echo "  下载失败,第 $i 次重试"
    fi
    rm -f "$dest"; sleep 5
    [ "$i" = 5 ] && { echo "  ✗ docker-compose 多次失败"; exit 1; }
  done
fi

# ========== 3. harbor 安装程序目录(prepare / install.sh / common.sh / compose 模板) ==========
# ⚠ 镜像只是「运行时」, 装 harbor 还需官方安装包里的脚本目录 —— x86.yaml 的「拷贝文件」那步
#   copy src=.../harbor/x86/harbor 取的就是它。缺了它 install.sh 会报
#   "./install.sh: line 67: ./prepare: No such file or directory" (rc=127)。
# 取 harbor-offline-installer(含全部脚本), 解出 harbor/ 目录; 里面自带的镜像 tar 不需要
# (镜像已由上面 skopeo 单独拉好), 解完删掉省空间。
if [ -x "$D/harbor/install.sh" ] && [ -x "$D/harbor/prepare" ]; then
  say "跳过(已存在) harbor 安装程序目录"
else
  installer="harbor-offline-installer-v$HARBOR.tgz"
  url="$DAO/github.com/goharbor/harbor/releases/download/v$HARBOR/$installer"
  for i in 1 2 3 4 5; do
    say "curl $url"
    if curl -fSL --retry 3 -o "$D/$installer" "$url"; then
      say "解出 harbor/ 安装程序目录"
      rm -rf "$D/harbor"
      tar xzf "$D/$installer" -C "$D"
      # 安装包自带的镜像 tar 很大且已单独拉过, 删掉
      rm -f "$D/harbor"/*.tar.gz "$D/harbor"/*.tar
      rm -f "$D/$installer"
      break
    fi
    echo "  下载失败, 第 $i 次重试..."; rm -f "$D/$installer"; sleep 5
    [ "$i" = 5 ] && { echo "  ✗ harbor 安装程序多次失败"; exit 1; }
  done
fi

# 校验: 角色依赖的关键文件必须在, 否则现在就报错(而不是部署到节点上才 rc=127)
for f in harbor/install.sh harbor/prepare harbor/common.sh; do
  [ -e "$D/$f" ] || { echo "✗ 缺 $D/$f —— harbor 安装程序目录不完整, 部署会失败"; exit 1; }
done
say "harbor 安装程序目录校验通过(install.sh / prepare / common.sh 均在)"

echo -e "\n=========================================================="
echo " Harbor(amd64)离线物料下载完成! 物料在 $D"
ls -1 "$D"
echo
echo " 提示: arm64 用 octohelm/harbor 的现成多架构镜像(ghcr.io/octohelm/harbor/<组件>:v2.13.0),复用已做好的 tar。"
echo " 拷回内网后, 部署时 -e is_offline=true 即可。"
echo "=========================================================="
