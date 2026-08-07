#!/bin/bash

# ================= 配置区域 =================
# 定义你想下载的软件包（主要针对离线部署 Ansible 自身）
OFFLINE_PKGS="ansible"

# 基础镜像：社区支持多架构的麒麟 V10 SP3 镜像
KYLIN_IMAGE="hxsoong/kylin:v10-sp3"

# 最终存放最新版 Ansible TAR 包的根目录（完美对齐 Ubuntu 的路径；按脚本所在目录定位, 不依赖 CWD）
BASE_DIR="$(cd "$(dirname "$0")" && pwd)/ansible-pkg-install"

# 架构选择(默认双架构; 单架构指定一个即可)。arch:tag_name 成对: amd64->x86_64, arm64->arm64
case "${1:-all}" in
  amd64) ARCH_PAIRS="amd64:x86_64" ;;
  arm64) ARCH_PAIRS="arm64:arm64" ;;
  all)   ARCH_PAIRS="amd64:x86_64 arm64:arm64" ;;
  *) echo "用法: bash $0 [amd64|arm64|all]  (默认 all)"; exit 1 ;;
esac
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

    # 核心：使用指定 platform 镜像，并在内部注入 EPEL 扩展源，用 yum install --downloadonly 下载 ansible 及缺失依赖
    docker run --rm \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        "$KYLIN_IMAGE" \
        sh -c "
            # 安装 dnf-plugins-core，麒麟 V10(dnf 体系)下载相关插件由它提供(不是 yum-utils)
            yum install dnf-plugins-core -y -q >/dev/null

            cd /tmp/download

            echo ' -> 正在解析并下载 ansible 及其【缺失依赖】...'
            # 只用 yum install --downloadonly: 下 ansible + 容器里没有的依赖。
            # 不加 --alldeps, 免得把节点本就自带的 glibc/python3 等基础库也拉进来(徒增体积、还可能顺带升级基础库)。
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

for pair in $ARCH_PAIRS; do
    download_by_arch "${pair%%:*}" "${pair##*:}"
    echo -e "\n"
done

echo -e "\n=========================================================="
echo " 麒麟 Ansible 离线全架构包制作结束！"
echo " 成果目录: $BASE_DIR"
echo "=========================================================="
