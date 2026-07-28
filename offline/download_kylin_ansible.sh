#!/bin/bash

# ================= 配置区域 =================
# 定义你想下载的软件包（主要针对离线部署 Ansible 自身）
OFFLINE_PKGS="ansible"

# 基础镜像：社区支持多架构的麒麟 V10 SP3 镜像
KYLIN_IMAGE="hxsoong/kylin:v10-sp3"

# 最终存放最新版 Ansible TAR 包的根目录（完美对齐 Ubuntu 的路径；按脚本所在目录定位, 不依赖 CWD）
BASE_DIR="$(cd "$(dirname "$0")" && pwd)/ansible-pkg-install"
# ============================================

# 封装一个下载与打包函数
download_by_arch() {
    local arch=$1        # 目标架构：amd64 或 arm64
    local tag_name=$2    # 习惯的系统架构：x86_64 或 arm64
    
    # 临时存放 rpm 碎文件的目录
    local tmp_save_dir="$BASE_DIR/ansible_kylin_${tag_name}_tmp"
    # 最终的压缩包名称（与 ansible_ubuntuXX_xxx.tar.gz 风格一致）
    local tar_name="ansible_kylin_${tag_name}.tar.gz"

    echo "=========================================================="
    echo " 开始下载麒麟 V10 SP3 Ansible 及其全量依赖 [ 架构: $arch -> $tag_name ]"
    echo "=========================================================="

    # 创建干净的目录
    rm -rf "$tmp_save_dir"
    mkdir -p "$tmp_save_dir"
    mkdir -p "$BASE_DIR"

    # 核心：使用指定 platform 镜像，并在内部注入 EPEL 扩展源，使用 yumdownloader 强行抓全量依赖
    docker run --rm \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        "$KYLIN_IMAGE" \
        sh -c "
            # 1. 尝试接入 EPEL 源以获取可能更新的组件（即便不可用也会平滑切回默认源）
            yum install epel-release -y -q >/dev/null 2>&1
            
            # 2. 安装 yum-utils，我们需要里面的 yumdownloader 工具
            yum install yum-utils -y -q >/dev/null

            cd /tmp/download

            echo ' -> 正在分析依赖并进行【全量递归下载】（防止离线时缺包）...'
            # --resolve 解析依赖，--alldeps 强制把容器已有的包也下载一份，--destdir 指定目录
            yumdownloader --resolve --alldeps --destdir=/tmp/download $OFFLINE_PKGS -y -q >/dev/null 2>&1
            
            # 双重保险，防止个别包漏掉
            yum install --downloadonly --downloaddir=/tmp/download $OFFLINE_PKGS -y -q >/dev/null 2>&1
        "

    # 宿主机平铺打包并清理临时文件
    if [ $? -eq 0 ]; then
        echo " -> 容器内下载完成，开始在宿主机进行单文件打包..."
        
        # 打包成【带顶层目录】的 tar(解压出 ansible_kylin_xxx/, 内网直接 cd 进去 rpm -Uvh ./*.rpm)
        local pkg_dir="ansible_kylin_${tag_name}"
        # 确保目录不为空才进行打包
        if [ "$(ls -A "$tmp_save_dir")" ]; then
            rm -rf "$BASE_DIR/$pkg_dir"
            mv "$tmp_save_dir" "$BASE_DIR/$pkg_dir"
            tar -czf "$BASE_DIR/$tar_name" -C "$BASE_DIR" "$pkg_dir"
            rm -rf "$BASE_DIR/$pkg_dir"
            echo " 🌟 [ 成功 ] 麒麟 Ansible 离线 Tar 包已就位: $BASE_DIR/$tar_name (含顶层目录 $pkg_dir/)"
        else
            echo " ❌ [ 失败 ] 下载目录为空，请检查容器源或包名是否正确。"
            rm -rf "$tmp_save_dir"
        fi
    else
        echo " ❌ [ 失败 ] $tag_name 架构下载过程中似乎遇到了问题。"
        rm -rf "$tmp_save_dir"
    fi
}

# ================= 执行矩阵下载并打包 =================

# 1. 下载并打包 x86_64 架构的 Ansible 离线包
download_by_arch "amd64" "x86_64"

echo -e "\n"

# 2. 下载并打包 ARM64 架构的 Ansible 离线包
download_by_arch "arm64" "arm64"

echo -e "\n=========================================================="
echo " 麒麟 Ansible 离线全架构包制作结束！"
echo " 成果目录: $BASE_DIR"
echo "=========================================================="
