#!/bin/bash

# ================= 配置区域 =================
# 注: haproxy keepalived 只有 LB 节点用 —— 但放进同一次解析(下面 apt-cache depends --recurse | sort -u)
#     不会重复(公共依赖去重),LB 包与基础包合成一个 tar; init 只装显式列表(debian_offline_pkgs),
#     不含 haproxy/keepalived, 故非 LB 节点只存不装; haproxy-ha 在 LB 节点从同一本地源按名安装。
#     改这里的包名需同步 playbook/roles/init/tasks/debian.yaml 的 debian_offline_pkgs(不含 LB 那两个)。
OFFLINE_PKGS="socat ebtables ipset iotop sysstat ipvsadm conntrack net-tools nfs-common nfs-kernel-server libseccomp2 netcat-openbsd ca-certificates bash-completion apt-transport-https software-properties-common gcc make bzip2 unzip freeipa-client chrony haproxy keepalived"

# 最终存放 TAR 包的根目录 (对齐你的现状)
BASE_OUT_DIR="$(cd "$(dirname "$0")/../../offline" && pwd)/artifacts/ios-offline"
# ============================================

download_ubuntu_pkg() {
    local ubuntu_version=$1  # 22.04 或 24.04
    local arch=$2            # amd64 或 arm64
    local tag_name=$3        # x86_64 或 arm64
    
    # 提取主版本号：22.04 -> 22
    local major_version=$(echo "$ubuntu_version" | cut -d'.' -f1)
    local tmp_save_dir="$BASE_OUT_DIR/ubuntu${major_version}_tmp"
    local tar_name="ubuntu${major_version}_${tag_name}.tar.gz"

    echo "=========================================================="
    echo " 开始下载 Ubuntu $ubuntu_version [ 架构: $arch -> $tag_name ]"
    echo "=========================================================="

    rm -rf "$tmp_save_dir"
    mkdir -p "$tmp_save_dir"
    mkdir -p "$BASE_OUT_DIR"

    docker run --rm \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        ubuntu:"$ubuntu_version" \
        sh -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq apt-utils dpkg-dev >/dev/null

            cd /tmp/download
            echo ' -> 正在分析依赖并下载包...'
            apt-get download \$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances $OFFLINE_PKGS | grep '^\w' | sort -u) 2>errors.txt
            apt-get download $OFFLINE_PKGS 2>>errors.txt

            echo ' -> 正在生成 Packages 离线索引...'
            apt-ftparchive packages . > Packages
        "

    if [ $? -eq 0 ] && [ -f "$tmp_save_dir/Packages" ]; then
        echo " -> 容器内下载完成，开始在宿主机打包..."
        cd "$tmp_save_dir"
        tar -czf "$BASE_OUT_DIR/$tar_name" ./*
        cd - > /dev/null
        rm -rf "$tmp_save_dir"
        echo " 🌟 [ 成功 ] 离线 Tar 包已生成: $BASE_OUT_DIR/$tar_name"
    else
        echo " ❌ [ 失败 ] Ubuntu $ubuntu_version 下载失败。"
        rm -rf "$tmp_save_dir"
    fi
}

# 执行矩阵下载
download_ubuntu_pkg "22.04" "amd64" "x86_64"
download_ubuntu_pkg "22.04" "arm64" "arm64"
echo -e "\n"
download_ubuntu_pkg "24.04" "amd64" "x86_64"
download_ubuntu_pkg "24.04" "arm64" "arm64"
