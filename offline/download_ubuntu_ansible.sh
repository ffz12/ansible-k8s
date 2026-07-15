#!/bin/bash

# ================= 配置区域 =================
# 定义你想下载的软件包，专门针对离线部署 Ansible 自身及必要环境
OFFLINE_PKGS="ansible"

# 最终存放最新版 Ansible TAR 包的根目录
BASE_OUT_DIR="$(pwd)/ansible-pkg-install"
# ============================================

# 封装 Ubuntu 下载最新 Ansible 与打包核心函数
download_ubuntu_ansible() {
    local ubuntu_version=$1  # 目标系统版本：22.04 或 24.04
    local arch=$2            # 目标架构：amd64 或 arm64
    local tag_name=$3        # 习惯的系统架构：x86_64 或 arm64
    
    # 提取主版本号：22.04 -> 22
    local major_version=$(echo "$ubuntu_version" | cut -d'.' -f1)
    
    # 临时存放离线 deb 碎文件的目录
    local tmp_save_dir="$BASE_OUT_DIR/ansible_ubuntu${major_version}_tmp"
    # 最终的压缩包名称
    local tar_name="ansible_ubuntu${major_version}_${tag_name}.tar.gz"

    echo "=========================================================="
    echo " 开始下载 Ubuntu $ubuntu_version 最新版 Ansible [ 架构: $arch -> $tag_name ]"
    echo "=========================================================="

    # 创建干净的目录
    rm -rf "$tmp_save_dir"
    mkdir -p "$tmp_save_dir"
    mkdir -p "$BASE_OUT_DIR"

    # 核心：使用指定 platform 镜像，并在内部注入官方最新 Ansible PPA 源
    docker run --rm \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        ubuntu:"$ubuntu_version" \
        sh -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            # 必须先装上软件源管理工具
            apt-get install -y -qq apt-utils dpkg-dev software-properties-common >/dev/null

            echo ' -> 正在接入官方最新 Ansible 专属 PPA 仓库...'
            # 关键步骤：强行塞入最新版源，不需要人肉确认
            add-apt-repository --yes ppa:ansible/ansible >/dev/null
            apt-get update -qq

            cd /tmp/download

            echo ' -> 正在分析最新版依赖并递归下载（请稍候）...'
            # 采用你原本强大的依赖追踪能力，递归抓取该系统最新版核心依赖
            apt-get download \$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances $OFFLINE_PKGS | grep '^\w' | sort -u) 2>errors.txt

            # 确保最新版包本身强制下载
            apt-get download $OFFLINE_PKGS 2>>errors.txt

            echo ' -> 正在生成本地 Packages 离线索引...'
            apt-ftparchive packages . > Packages
        "

    # 宿主机平铺打包并清理垃圾
    if [ $? -eq 0 ] && [ -f "$tmp_save_dir/Packages" ]; then
        echo " -> 容器内下载最新版完成，开始在宿主机进行单文件打包..."
        
        cd "$tmp_save_dir"
        tar -czf "$BASE_OUT_DIR/$tar_name" ./*
        cd - > /dev/null
        
        rm -rf "$tmp_save_dir"
        echo " 🌟 [ 成功 ] 最新版离线 Tar 包已就位: $BASE_OUT_DIR/$tar_name"
    else
        echo " ❌ [ 失败 ] Ubuntu $ubuntu_version 下载或注册 PPA 失败，请检查报错。"
        rm -rf "$tmp_save_dir"
    fi
}

# ================= 执行矩阵下载并打包 =================

# 1. 最新版 Ansible 适配 Ubuntu 22.04
download_ubuntu_ansible "22.04" "amd64" "x86_64"
download_ubuntu_ansible "22.04" "arm64" "arm64"

echo -e "\n"

# 2. 最新版 Ansible 适配 Ubuntu 24.04
download_ubuntu_ansible "24.04" "amd64" "x86_64"
download_ubuntu_ansible "24.04" "arm64" "arm64"

echo -e "\n=========================================================="
echo " 最新版 Ansible 离线全架构包制作结束！"
echo " 成果目录: $BASE_OUT_DIR"
echo "=========================================================="
