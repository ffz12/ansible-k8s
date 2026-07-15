#!/bin/bash
set -e

# 输出目录（相对于脚本位置）
OUTPUT_DIR="offline/binaries/nginx-ha/deps"

DEB_PKGS=(
    libssl3
    libpcre3
    zlib1g
)

RPM_PKGS=(
    openssl-libs
    pcre
    zlib
)

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
# 标准化架构名
if [[ "$ARCH" == "x86_64" ]]; then
    ARCH="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    ARCH="arm64"
fi

echo "检测到系统架构: $ARCH"

# 判断发行版
if command -v apt &> /dev/null; then
    echo "检测到 Debian/Ubuntu 系统"
    DEPS_DIR="$OUTPUT_DIR/debian"
    mkdir -p "$DEPS_DIR"

    echo "正在下载 .deb 依赖包..."
    # 创建临时目录
    TEMP_DEB=$(mktemp -d)
    cd "$TEMP_DEB"

    # 下载指定包
    apt download "${DEB_PKGS[@]}"

    # 下载完整依赖链（关键！）
    DEPENDS=$(apt-cache depends --recurse --no-recommends --no-suggests \
        "${DEB_PKGS[@]}" 2>/dev/null | grep "^\w" | sort -u)
    if [ -n "$DEPENDS" ]; then
        apt download $DEPENDS 2>/dev/null || true
    fi

    # 移动所有 .deb 到输出目录
    mv *.deb "$DEPS_DIR/" 2>/dev/null || true
    cd - > /dev/null
    rm -rf "$TEMP_DEB"

    echo "✅ Debian 依赖已保存到: $DEPS_DIR"

elif command -v dnf &> /dev/null || command -v yum &> /dev/null; then
    echo "检测到 RHEL/Rocky/openEuler 系统"
    DEPS_DIR="$OUTPUT_DIR/rhel"
    mkdir -p "$DEPS_DIR"

    # 安装 yum-utils（提供 yumdownloader）
    if ! command -v yumdownloader &> /dev/null; then
        echo "安装 yum-utils..."
        if command -v dnf &> /dev/null; then
            dnf install -y yum-utils
        else
            yum install -y yum-utils
        fi
    fi

    echo "正在下载 .rpm 依赖包..."
    TEMP_RPM=$(mktemp -d)
    cd "$TEMP_RPM"

    # 下载包及其依赖
    if command -v dnf &> /dev/null; then
        dnf download --resolve "${RPM_PKGS[@]}"
    else
        yumdownloader --resolve "${RPM_PKGS[@]}"
    fi

    # 移动所有 .rpm 到输出目录
    mv *.rpm "$DEPS_DIR/" 2>/dev/null || true
    cd - > /dev/null
    rm -rf "$TEMP_RPM"

    echo "✅ RHEL 依赖已保存到: $DEPS_DIR"

else
    echo "❌ 不支持的发行版！仅支持 Debian/Ubuntu 或 RHEL 系列。"
    exit 1
fi

echo
echo "💡 提示：请将整个 offline/ 目录同步到 Ansible 控制机，用于离线部署。"
