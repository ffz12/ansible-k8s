#!/bin/bash

# ================= 配置区域 =================
# 注: haproxy keepalived 只有 LB 节点用 —— 放进同一次 yum 解析(下面 --downloadonly)不会重复(公共依赖去重),
#     与基础包合成一个 tar; init 只装显式列表(kylin_offline_pkgs, 不含 LB), 故非 LB 节点只存不装;
#     haproxy-ha 在 LB 节点从同一本地源按名安装。改这里需同步 roles/init/tasks/kylinsp3.yaml 的 kylin_offline_pkgs。
OFFLINE_PKGS="openssl-libs pcre zlib socat chrony ipvsadm conntrack ipset ebtables nfs* haproxy keepalived"
KYLIN_IMAGE="hxsoong/kylin:v10-sp3"

# 架构过滤(prefetch 按 env.yaml 的 offline_arch export ARCH; 直接跑不设=all=双架构, 与旧行为一致)
ARCH="${ARCH:-all}"
# 可选: 容器解析发行版官方源抖动时(如麒麟 update.cs2c.com.cn)指定 DNS, 不设则与现状完全一致
DOCKER_DNS="${DOCKER_DNS:-}"

# 最终存放 TAR 包的根目录 (对齐你的现状)
BASE_DIR="$(cd "$(dirname "$0")/../../offline" && pwd)/artifacts/ios-offline"
# ============================================
RC=0   # 任一架构失败置 1, 脚本末尾据此非零退出(不再静默 return 0)

# 拉一次镜像就按架构打本地缓存标签, 之后复用不再重复拉。
# (docker 同一 tag 本地只能存一个平台的镜像, 双架构会互相顶掉 -> 每次都重拉; 故各架构存独立缓存标签)
ensure_image() {   # $1=镜像 $2=arch -> stdout 回显可直接 docker run 的本地缓存标签; 失败 return 1
    local image="$1" arch="$2"
    local cache="pkgcache/$(echo "${image}__${arch}" | tr '/:' '__')"
    if docker image inspect "$cache" >/dev/null 2>&1; then
        echo " -> 复用本地镜像缓存 $cache(跳过拉取)" >&2
    else
        echo " -> 首次拉取 $image [$arch] 并打本地缓存标签 $cache ..." >&2
        docker pull --platform "linux/$arch" "$image" >&2 || return 1
        docker tag "$image" "$cache" >&2 || return 1
    fi
    echo "$cache"
}

download_by_arch() {
    local arch=$1        # amd64 或 arm64
    local tag_name=$2    # x86_64 或 arm64
    
    local tmp_save_dir="$BASE_DIR/kylin_${tag_name}_tmp"
    local tar_name="kylin_${tag_name}.tar.gz"

    echo "=========================================================="
    echo " 开始下载麒麟 V10 SP3 [ 架构: $arch -> $tag_name ]"
    echo "=========================================================="

    rm -rf "$tmp_save_dir"
    mkdir -p "$tmp_save_dir"
    mkdir -p "$BASE_DIR"

    local img
    if ! img="$(ensure_image "$KYLIN_IMAGE" "$arch")"; then
        echo " ❌ [ 失败 ] $tag_name 架构镜像拉取失败(网络/DNS?)。"
        rm -rf "$tmp_save_dir"; RC=1; return
    fi

    docker run --rm ${DOCKER_DNS:+--dns "$DOCKER_DNS"} \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        "$img" \
        sh -c "
            set -e
            yum install --downloadonly --downloaddir=/tmp/download $OFFLINE_PKGS -y
            cd /tmp/download
            # 生成 repodata 离线索引(供 init 作本地 yum 源 + 显式列表安装; 拿不到 createrepo 就跳过, init 回退 localinstall)
            if yum install -y createrepo_c >/dev/null 2>&1 || yum install -y createrepo >/dev/null 2>&1; then
                createrepo_c . >/dev/null 2>&1 || createrepo . >/dev/null 2>&1 || echo ' ⚠️  createrepo 执行失败, tar 无 repodata(init 会回退 localinstall)'
            else
                echo ' ⚠️  容器内装不到 createrepo, tar 无 repodata(init 会回退 localinstall)'
            fi
        "

    if [ $? -eq 0 ]; then
        echo " -> 容器内下载完成，开始在宿主机打包..."
        cd "$tmp_save_dir"
        tar -czf "$BASE_DIR/$tar_name" ./*
        cd - > /dev/null
        rm -rf "$tmp_save_dir"
        echo " 🌟 [ 成功 ] 麒麟离线 Tar 包已生成: $BASE_DIR/$tar_name"
    else
        echo " ❌ [ 失败 ] $tag_name 架构下载失败。"
        rm -rf "$tmp_save_dir"; RC=1
    fi
}

# 执行下载(按 ARCH 过滤: 声明单架构就只下那个)
case "$ARCH" in amd64|all) download_by_arch "amd64" "x86_64"; echo -e "\n" ;; esac
case "$ARCH" in arm64|all) download_by_arch "arm64" "arm64" ;; esac
exit $RC
