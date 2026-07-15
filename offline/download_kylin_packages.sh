#!/bin/bash

# ================= 配置区域 =================
OFFLINE_PKGS="openssl-libs pcre zlib socat chrony ipvsadm conntrack ipset ebtables nfs*"
KYLIN_IMAGE="hxsoong/kylin:v10-sp3"

# 最终存放 TAR 包的根目录 (对齐你的现状)
BASE_DIR="$(pwd)/binaries/ios-offline"
# ============================================

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

    docker run --rm \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        "$KYLIN_IMAGE" \
        sh -c "yum install --downloadonly --downloaddir=/tmp/download $OFFLINE_PKGS -y"

    if [ $? -eq 0 ]; then
        echo " -> 容器内下载完成，开始在宿主机打包..."
        cd "$tmp_save_dir"
        tar -czf "$BASE_DIR/$tar_name" ./*
        cd - > /dev/null
        rm -rf "$tmp_save_dir"
        echo " 🌟 [ 成功 ] 麒麟离线 Tar 包已生成: $BASE_DIR/$tar_name"
    else
        echo " ❌ [ 失败 ] $tag_name 架构下载失败。"
        rm -rf "$tmp_save_dir"
    fi
}

# 执行下载
download_by_arch "amd64" "x86_64"
echo -e "\n"
download_by_arch "arm64" "arm64"
