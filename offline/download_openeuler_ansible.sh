#!/bin/bash

# ================= 配置区域 =================
# 定义你想下载的软件包（主要针对离线部署 Ansible 自身）
OFFLINE_PKGS="ansible"

# 基础镜像：openEuler 官方多架构镜像(22.03 LTS SP4)
OPENEULER_IMAGE="openeuler/openeuler:22.03-lts-sp4"

# 最终存放最新版 Ansible TAR 包的根目录（与 kylin/ubuntu 对齐；按脚本所在目录定位, 不依赖 CWD）
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
    local tmp_save_dir="$BASE_DIR/ansible_openeuler_${tag_name}_tmp"
    # 最终的压缩包名称（与 ansible_kylin_xxx.tar.gz / ansible_ubuntuXX_xxx.tar.gz 风格一致）
    local tar_name="ansible_openeuler_${tag_name}.tar.gz"

    echo "=========================================================="
    echo " 开始下载 openEuler 22.03 LTS SP4 Ansible 及其全量依赖 [ 架构: $arch -> $tag_name ]"
    echo "=========================================================="

    # 创建干净的目录
    rm -rf "$tmp_save_dir"
    mkdir -p "$tmp_save_dir"
    mkdir -p "$BASE_DIR"

    # 核心：用指定 platform 镜像, 开 EPOL 源(openEuler 的 ansible 在此), yumdownloader 抓全量依赖
    docker run --rm \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        "$OPENEULER_IMAGE" \
        sh -c "
            # 1. 开启 EPOL 源(openEuler 的 ansible 在 EPOL 里; 已开启则忽略报错)
            yum install -y -q dnf-plugins-core >/dev/null 2>&1
            yum config-manager --set-enabled EPOL >/dev/null 2>&1 || true

            # 2. 安装 yum-utils, 取里面的 yumdownloader 工具
            yum install yum-utils -y -q >/dev/null

            cd /tmp/download

            echo ' -> 正在分析依赖并进行【全量递归下载】（防止离线时缺包）...'
            # --resolve 解析依赖，--alldeps 强制把容器已有的包也下载一份，--destdir 指定目录
            yumdownloader --resolve --alldeps --destdir=/tmp/download $OFFLINE_PKGS -y -q >/dev/null 2>&1

            # 双重保险，防止个别包漏掉
            yum install --downloadonly --downloaddir=/tmp/download $OFFLINE_PKGS -y -q >/dev/null 2>&1
        "

    # 宿主机打包并清理临时文件
    if [ $? -eq 0 ]; then
        echo " -> 容器内下载完成，开始在宿主机打包..."

        # 打包成【带顶层目录】的 tar(解压出 ansible_openeuler_xxx/, 内网直接 cd 进去 rpm -Uvh ./*.rpm)
        local pkg_dir="ansible_openeuler_${tag_name}"
        # 确保目录不为空才进行打包
        if [ "$(ls -A "$tmp_save_dir")" ]; then
            rm -rf "$BASE_DIR/$pkg_dir"
            mv "$tmp_save_dir" "$BASE_DIR/$pkg_dir"
            tar -czf "$BASE_DIR/$tar_name" -C "$BASE_DIR" "$pkg_dir"
            rm -rf "$BASE_DIR/$pkg_dir"
            echo " 🌟 [ 成功 ] openEuler Ansible 离线 Tar 包已就位: $BASE_DIR/$tar_name (含顶层目录 $pkg_dir/)"
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
echo " openEuler Ansible 离线全架构包制作结束！"
echo " 成果目录: $BASE_DIR"
echo "=========================================================="
