#!/bin/bash

# ================= 配置区域 =================
# 要打包的 RPM(用户指定 + 常用基础依赖); dnf 会自动带上全部依赖
# 注: 不含 ansible —— ansible 只装在控制机, 由 download-ansible-offline.sh 单独打包(避免重复)
OFFLINE_PKGS="openssl-libs pcre zlib socat chrony ipvsadm conntrack-tools nfs-utils unzip wget net-tools lrzsz vim tar rsync tmux htop bash-completion curl gcc gcc-c++ make cmake git ipset ebtables libseccomp bzip2 sysstat iotop lsof psmisc nmap-ncat telnet jq device-mapper-persistent-data lvm2 python3"

# openEuler 容器镜像(多架构); 若拉不到可换成实际可用 tag,如 22.03-lts-sp4
EULER_IMAGE="openeuler/openeuler:22.03-lts"
EULER_MAJOR="22"   # 输出文件名用: openEuler22_<arch>.tar.gz

# 最终存放 TAR 包的根目录 (对齐 ubuntu 脚本)
BASE_OUT_DIR="$(cd "$(dirname "$0")/../../offline" && pwd)/artifacts/ios-offline"
# ============================================

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

    docker run --rm \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        "$EULER_IMAGE" \
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

    # 成功判据: 目录里有 rpm
    if [ $? -eq 0 ] && ls "$tmp_save_dir"/*.rpm >/dev/null 2>&1; then
        echo " -> 容器内下载完成($(ls -1 "$tmp_save_dir"/*.rpm | wc -l) 个 rpm),开始在宿主机打包..."
        cd "$tmp_save_dir"
        tar -czf "$BASE_OUT_DIR/$tar_name" ./*
        cd - > /dev/null
        rm -rf "$tmp_save_dir"
        echo " 🌟 [ 成功 ] 离线 Tar 包已生成: $BASE_OUT_DIR/$tar_name"
    else
        echo " ❌ [ 失败 ] openEuler $arch 下载失败,请检查镜像 tag / 包名 / errors.txt。"
        rm -rf "$tmp_save_dir"
    fi
}

# 执行矩阵下载(两架构,和 ubuntu 保持一致)
download_euler_pkg "amd64" "x86_64"
echo -e "\n"
download_euler_pkg "arm64" "arm64"

echo
echo "=============================================="
echo " 完成。产物: $BASE_OUT_DIR/openEuler${EULER_MAJOR}_{x86_64,arm64}.tar.gz"
echo " 注意: arm64 在 x86 主机上下载需要 qemu binfmt (与 ubuntu 脚本同样前提)。"
echo "=============================================="
