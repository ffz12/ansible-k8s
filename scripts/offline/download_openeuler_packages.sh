#!/bin/bash

# ================= 配置区域 =================
# 要打包的 RPM(用户指定 + 常用基础依赖); dnf 会自动带上全部依赖
# 注: 不含 ansible —— ansible 只装在控制机, 由 download-ansible-offline.sh 单独打包(避免重复)
# 注: haproxy keepalived 只有 LB 节点用 —— 放进同一次 dnf 解析(--resolve --alldeps)不会重复(公共依赖去重),
#     与基础包合成一个 tar; init 只装显式列表(euler_offline_pkgs, 不含 LB), 故非 LB 节点只存不装;
#     haproxy-ha 在 LB 节点从同一本地源按名安装。改这里需同步 roles/init/tasks/openEuler.yaml 的 euler_offline_pkgs。
OFFLINE_PKGS="openssl-libs pcre zlib socat chrony ipvsadm conntrack-tools nfs-utils unzip wget net-tools lrzsz vim tar rsync sshpass tmux htop bash-completion curl gcc gcc-c++ make cmake git ipset ebtables libseccomp bzip2 sysstat iotop lsof psmisc nmap-ncat telnet jq device-mapper-persistent-data lvm2 python3 haproxy keepalived"

# openEuler 容器镜像(多架构); 若拉不到可换成实际可用 tag,如 22.03-lts-sp4
EULER_IMAGE="openeuler/openeuler:22.03-lts"
EULER_MAJOR="22"   # 输出文件名用: openEuler22_<arch>.tar.gz

# 架构过滤(prefetch 按 env.yaml 的 offline_arch export ARCH; 直接跑不设=all=双架构, 与旧行为一致)
ARCH="${ARCH:-all}"
# 可选: 容器解析官方源抖动时指定 DNS, 不设则与现状完全一致
DOCKER_DNS="${DOCKER_DNS:-}"
# 体积兜底: 基础依赖 tar 正常几十~上百 MB, 小于此值(默认 1MB)判打包异常; 特殊场景可 MIN_TAR_BYTES= 调
MIN_TAR_BYTES="${MIN_TAR_BYTES:-1048576}"

# 最终存放 TAR 包的根目录 (对齐 ubuntu 脚本)
BASE_OUT_DIR="$(cd "$(dirname "$0")/../../offline" && pwd)/artifacts/ios-offline"
# ============================================
RC=0   # 任一架构失败置 1, 脚本末尾据此非零退出(不再静默)

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

download_euler_pkg() {
    local arch=$1       # amd64 或 arm64
    local tag_name=$2   # x86_64 或 arm64

    local tmp_save_dir="$BASE_OUT_DIR/openEuler${EULER_MAJOR}_tmp"
    local tar_name="openEuler${EULER_MAJOR}_${tag_name}.tar.gz"

    echo "=========================================================="
    echo " 开始下载 openEuler ${EULER_MAJOR}.03 [ 架构: $arch -> $tag_name ]"
    echo "=========================================================="

    rm -rf "$tmp_save_dir"
    mkdir -p "$tmp_save_dir"
    mkdir -p "$BASE_OUT_DIR"

    local img
    if ! img="$(ensure_image "$EULER_IMAGE" "$arch")"; then
        echo " ❌ [ 失败 ] openEuler [$arch] 镜像拉取失败(网络/DNS?)。"
        rm -rf "$tmp_save_dir"; RC=1; return
    fi

    docker run --rm ${DOCKER_DNS:+--dns "$DOCKER_DNS"} \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        "$img" \
        bash -c "
            set -e
            # dnf download 需要插件; createrepo_c 生成离线 repo 索引
            dnf install -y dnf-plugins-core createrepo_c >/dev/null 2>&1 || yum install -y yum-utils createrepo >/dev/null 2>&1 || true

            cd /tmp/download
            echo ' -> 正在下载包及全部依赖(含已装依赖)...'
            dnf download --resolve --alldeps --destdir /tmp/download $OFFLINE_PKGS 2>errors.txt

            echo ' -> 正在生成 repodata 离线索引...'
            (createrepo_c . || createrepo .) >/dev/null 2>&1 || true
        "

    local rc=$?
    # 容器退出码 + 实际下到的 rpm 数, 都过才算成功(防「下 0 个包却打印成功」的静默空包)
    local rpm_cnt
    rpm_cnt=$(ls -1 "$tmp_save_dir"/*.rpm 2>/dev/null | wc -l)
    if [ "$rc" -ne 0 ] || [ "$rpm_cnt" -eq 0 ]; then
        echo " ❌ [ 失败 ] openEuler $arch 下载异常(退出码=$rc, 下到 rpm=$rpm_cnt),请检查镜像 tag / 包名 / errors.txt; 保留 $tmp_save_dir 供排查。"
        RC=1; return
    fi

    echo " -> 容器内下载完成($rpm_cnt 个 rpm),开始在宿主机打包..."
    # 用 -C 进目录打包(含 rpm + repodata), 比 cd + ./* 稳(避免 glob/cwd 出错只打进 repodata)
    tar -C "$tmp_save_dir" -czf "$BASE_OUT_DIR/$tar_name" .
    local in_tar
    in_tar=$(tar tzf "$BASE_OUT_DIR/$tar_name" 2>/dev/null | grep -c '\.rpm$')
    if [ "$in_tar" -ne "$rpm_cnt" ]; then
        echo " ❌ [ 失败 ] 打包后 rpm 数不符(源 $rpm_cnt / tar $in_tar); 保留 $tmp_save_dir 供排查。"
        rm -f "$BASE_OUT_DIR/$tar_name"; RC=1; return
    fi
    # 体积兜底: 数量对得上但 tar 异常小(损坏/内容不全)也判失败
    local tar_bytes
    tar_bytes=$(stat -c%s "$BASE_OUT_DIR/$tar_name" 2>/dev/null || echo 0)
    if [ "$tar_bytes" -lt "$MIN_TAR_BYTES" ]; then
        echo " ❌ [ 失败 ] tar 体积异常偏小(${tar_bytes}B < ${MIN_TAR_BYTES}B), 疑似打包不全; 保留 $tmp_save_dir 供排查。"
        rm -f "$BASE_OUT_DIR/$tar_name"; RC=1; return
    fi
    rm -rf "$tmp_save_dir"
    echo " 🌟 [ 成功 ] 离线 Tar 包已生成($in_tar 个 rpm, $((tar_bytes/1024/1024))MB): $BASE_OUT_DIR/$tar_name"
}

# 执行矩阵下载(按 ARCH 过滤: 声明单架构就只下那个)
case "$ARCH" in amd64|all) download_euler_pkg "amd64" "x86_64"; echo -e "\n" ;; esac
case "$ARCH" in arm64|all) download_euler_pkg "arm64" "arm64" ;; esac

echo
echo "=============================================="
echo " 完成。产物: $BASE_OUT_DIR/openEuler${EULER_MAJOR}_{x86_64,arm64}.tar.gz"
echo " 注意: arm64 在 x86 主机上下载需要 qemu binfmt (与 ubuntu 脚本同样前提)。"
echo "=============================================="
exit $RC
