#!/bin/bash

# ================= 配置区域 =================
# 注: haproxy keepalived 只有 LB 节点用 —— 放进同一次 yum 解析(下面 --downloadonly)不会重复(公共依赖去重),
#     与基础包合成一个 tar; init 只装显式列表(kylin_offline_pkgs, 不含 LB), 故非 LB 节点只存不装;
#     haproxy-ha 在 LB 节点从同一本地源按名安装。改这里需同步 roles/init/tasks/kylinsp3.yaml 的 kylin_offline_pkgs。
OFFLINE_PKGS="openssl-libs pcre zlib socat chrony ipvsadm conntrack ipset ebtables nfs* rsync sshpass vim haproxy keepalived"
KYLIN_IMAGE="hxsoong/kylin:v10-sp3"

# 架构过滤(prefetch 按 env.yaml 的 offline_arch export ARCH; 直接跑不设=all=双架构, 与旧行为一致)
ARCH="${ARCH:-all}"
# 可选: 容器解析发行版官方源抖动时(如麒麟 update.cs2c.com.cn)指定 DNS, 不设则与现状完全一致
DOCKER_DNS="${DOCKER_DNS:-}"
# 体积兜底: 基础依赖 tar 正常几十~上百 MB, 小于此值(默认 1MB)判打包异常; 特殊场景可 MIN_TAR_BYTES= 调
MIN_TAR_BYTES="${MIN_TAR_BYTES:-1048576}"

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
            # ⚠ 工具必须在【下包之前】装好 —— dnf 提示 'saved in cache until the next successful
            #   transaction': --downloadonly 下的包(含 --downloaddir 里的)会被【下一次成功的
            #   transaction】清空。先下包再装 createrepo, 正好把刚下的 235 个 rpm 全清掉, 只剩 repodata。
            dnf install -y dnf-plugins-core createrepo_c >/dev/null 2>&1 || yum install -y yum-utils createrepo >/dev/null 2>&1 || true

            echo ' -> 下载包及全部依赖(含已装依赖)...'
            # 首选 dnf download --resolve --alldeps(不产生 transaction, 不会被清; 与 openEuler 脚本一致);
            # 老环境无该插件时回退 --downloadonly(此时工具已装完, 后续无 transaction 可清它)
            dnf download --resolve --alldeps --destdir /tmp/download $OFFLINE_PKGS 2>/dev/null \
                || yum install --downloadonly --downloaddir=/tmp/download $OFFLINE_PKGS -y

            # 兜底: 万一 dnf 把包留在 cache 而非 destdir, 全盘捞回 downloaddir(排除自身)
            find / -name '*.rpm' ! -path '/tmp/download/*' -exec cp -n {} /tmp/download/ \; 2>/dev/null || true

            cd /tmp/download
            # 生成 repodata 离线索引(纯本地命令, 不产生 dnf transaction, 不会再清包)
            echo ' -> 生成 repodata 离线索引...'
            createrepo_c . >/dev/null 2>&1 || createrepo . >/dev/null 2>&1 || echo ' ⚠️  createrepo 不可用, tar 无 repodata(init 会回退 localinstall)'
        "

    local rc=$?
    # 容器退出码 + 实际下到的 rpm 数, 两者都过才算成功(防「下 0 个包却打印成功」的静默空包)
    local rpm_cnt
    rpm_cnt=$(ls -1 "$tmp_save_dir"/*.rpm 2>/dev/null | wc -l)
    if [ "$rc" -ne 0 ] || [ "$rpm_cnt" -eq 0 ]; then
        echo " ❌ [ 失败 ] $tag_name 架构下载异常(容器退出码=$rc, 下到 rpm=$rpm_cnt); 保留 $tmp_save_dir 供排查。"
        RC=1; return
    fi

    echo " -> 容器内下载完成($rpm_cnt 个 rpm)，开始在宿主机打包..."
    # 用 -C 进目录打包(含 rpm + repodata), 比 cd + ./* 稳(避免 glob/cwd 出错只打进 repodata)
    tar -C "$tmp_save_dir" -czf "$BASE_DIR/$tar_name" .
    # 打包后回读校验: tar 里 rpm 数须与源一致, 否则判失败并保留 tmp
    local in_tar
    in_tar=$(tar tzf "$BASE_DIR/$tar_name" 2>/dev/null | grep -c '\.rpm$')
    if [ "$in_tar" -ne "$rpm_cnt" ]; then
        echo " ❌ [ 失败 ] 打包后 rpm 数不符(源 $rpm_cnt / tar $in_tar); 保留 $tmp_save_dir 供排查。"
        rm -f "$BASE_DIR/$tar_name"; RC=1; return
    fi
    # 体积兜底: 数量对得上但 tar 异常小(损坏/内容不全)也判失败
    local tar_bytes
    tar_bytes=$(stat -c%s "$BASE_DIR/$tar_name" 2>/dev/null || echo 0)
    if [ "$tar_bytes" -lt "$MIN_TAR_BYTES" ]; then
        echo " ❌ [ 失败 ] tar 体积异常偏小(${tar_bytes}B < ${MIN_TAR_BYTES}B), 疑似打包不全; 保留 $tmp_save_dir 供排查。"
        rm -f "$BASE_DIR/$tar_name"; RC=1; return
    fi
    rm -rf "$tmp_save_dir"
    echo " 🌟 [ 成功 ] 麒麟离线 Tar 包已生成($in_tar 个 rpm, $((tar_bytes/1024/1024))MB): $BASE_DIR/$tar_name"
}

# 执行下载(按 ARCH 过滤: 声明单架构就只下那个)
case "$ARCH" in amd64|all) download_by_arch "amd64" "x86_64"; echo -e "\n" ;; esac
case "$ARCH" in arm64|all) download_by_arch "arm64" "arm64" ;; esac
exit $RC
