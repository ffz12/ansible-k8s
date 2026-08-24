#!/bin/bash

# ================= 配置区域 =================
# 定义你想下载的软件包，专门针对离线部署 Ansible 自身及必要环境
OFFLINE_PKGS="ansible"

# 最终存放最新版 Ansible TAR 包的根目录（按脚本所在目录定位, 不依赖 CWD）
BASE_OUT_DIR="$(cd "$(dirname "$0")/../../offline" && pwd)/ansible-pkg-install"

# 架构选择(默认双架构; 单架构指定一个即可)。arch:tag_name 成对: amd64->x86_64, arm64->arm64
case "${1:-all}" in
  amd64) ARCH_PAIRS="amd64:x86_64" ;;
  arm64) ARCH_PAIRS="arm64:arm64" ;;
  all)   ARCH_PAIRS="amd64:x86_64 arm64:arm64" ;;
  *) echo "用法: bash $0 [amd64|arm64|all]  (默认 all)"; exit 1 ;;
esac
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

            echo ' -> 正在下载 ansible 及其【缺失依赖】...'
            # 只下 ansible + 容器(基础镜像)里没有的依赖, 用 --download-only 让 apt 只补差量。
            # 不用 apt-cache depends --recurse: 那会把整棵依赖树(含节点本就自带的 libc6/python3 等)全拉下来, 徒增体积。
            apt-get install -y --download-only $OFFLINE_PKGS 2>errors.txt
            # apt 把 deb 下到缓存目录, 平铺搬到打包目录
            cp -f /var/cache/apt/archives/*.deb /tmp/download/ 2>>errors.txt

            echo ' -> 正在生成本地 Packages 离线索引...'
            apt-ftparchive packages . > Packages
        "

    # 宿主机平铺打包并清理垃圾
    if [ $? -eq 0 ] && [ -f "$tmp_save_dir/Packages" ]; then
        echo " -> 容器内下载最新版完成，开始在宿主机进行单文件打包..."
        
        # 打包成【带顶层目录】的 tar(解压出 ansible_ubuntuXX_xxx/, 内网 apt/dpkg 直接指向该目录)
        local pkg_dir="ansible_ubuntu${major_version}_${tag_name}"
        rm -rf "$BASE_OUT_DIR/$pkg_dir"
        mv "$tmp_save_dir" "$BASE_OUT_DIR/$pkg_dir"
        tar -czf "$BASE_OUT_DIR/$tar_name" -C "$BASE_OUT_DIR" "$pkg_dir"
        rm -rf "$BASE_OUT_DIR/$pkg_dir"
        echo " 🌟 [ 成功 ] 最新版离线 Tar 包已就位: $BASE_OUT_DIR/$tar_name (含顶层目录 $pkg_dir/)"
    else
        echo " ❌ [ 失败 ] Ubuntu $ubuntu_version 下载或注册 PPA 失败，请检查报错。"
        rm -rf "$tmp_save_dir"
    fi
}

# ================= 执行矩阵下载并打包 =================

# 1. 最新版 Ansible 适配 Ubuntu 22.04
for pair in $ARCH_PAIRS; do
    download_ubuntu_ansible "22.04" "${pair%%:*}" "${pair##*:}"
done

echo -e "\n"

# 2. 最新版 Ansible 适配 Ubuntu 24.04
for pair in $ARCH_PAIRS; do
    download_ubuntu_ansible "24.04" "${pair%%:*}" "${pair##*:}"
done

echo -e "\n=========================================================="
echo " 最新版 Ansible 离线全架构包制作结束！"
echo " 成果目录: $BASE_OUT_DIR"
echo "=========================================================="
