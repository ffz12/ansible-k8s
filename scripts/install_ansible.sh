#!/bin/bash
# ==========================================================
# 离线安装 Ansible: 在目标主机上自动识别【系统 + 架构】, 选对应离线包安装
#   支持: Kylin V10 / openEuler / Ubuntu 22.04 / Ubuntu 24.04, x86_64 / arm64
#   用法: bash install_ansible.sh [离线包目录]
#         不给目录时, 自动在以下位置找 ansible_*.tar.gz:
#           脚本同级/ansible-pkg-install、仓库 offline/ansible-pkg-install、脚本同级
# ==========================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=========================================================="
echo " 离线安装 Ansible (自动识别系统 + 架构)"
echo "=========================================================="

# ---------- 1. 识别架构 ----------
case "$(uname -m)" in
    x86_64|amd64)   ARCH="x86_64" ;;
    aarch64|arm64)  ARCH="arm64"  ;;
    *) echo " ❌ 不支持的架构: $(uname -m)"; exit 1 ;;
esac

# ---------- 2. 识别系统 ----------
if [ ! -r /etc/os-release ]; then
    echo " ❌ 读不到 /etc/os-release, 无法识别系统"; exit 1
fi
. /etc/os-release
OS_ID="$(echo "${ID:-}" | tr 'A-Z' 'a-z')"

case "$OS_ID" in
    kylin)     PKG_PREFIX="ansible_kylin_${ARCH}";    FAMILY="rhel" ;;
    openeuler) PKG_PREFIX="ansible_openeuler_${ARCH}"; FAMILY="rhel" ;;
    ubuntu)
        MAJOR="${VERSION_ID%%.*}"
        PKG_PREFIX="ansible_ubuntu${MAJOR}_${ARCH}"
        FAMILY="debian" ;;
    *) echo " ❌ 暂不支持的系统: ID=${ID:-未知} (仅支持 kylin/openEuler/ubuntu)"; exit 1 ;;
esac

echo " -> 系统: ${PRETTY_NAME:-$ID}   架构: $ARCH"
echo " -> 匹配离线包前缀: ${PKG_PREFIX}.tar.gz"

# ---------- 3. 定位离线包 ----------
PKG_DIR="$1"
if [ -z "$PKG_DIR" ]; then
    for d in "$SCRIPT_DIR/ansible-pkg-install" "$SCRIPT_DIR/../offline/ansible-pkg-install" "$SCRIPT_DIR"; do
        if [ -f "$d/${PKG_PREFIX}.tar.gz" ]; then PKG_DIR="$d"; break; fi
    done
fi
TARBALL="$PKG_DIR/${PKG_PREFIX}.tar.gz"
if [ -z "$PKG_DIR" ] || [ ! -f "$TARBALL" ]; then
    echo " ❌ 没找到离线包 ${PKG_PREFIX}.tar.gz"
    echo "    请把离线包放到脚本同级(或其 ansible-pkg-install/ 子目录), 或用: bash $0 <离线包目录>"
    exit 1
fi
echo " -> 使用离线包: $TARBALL"

# ---------- 4. 解压 (兼容带顶层目录 / 平铺两种打包方式) ----------
WORK_DIR="$(mktemp -d /tmp/ansible-offline.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
tar -xzf "$TARBALL" -C "$WORK_DIR" || { echo " ❌ 解压失败"; exit 1; }

# ---------- 5. 安装 ----------
if [ "$FAMILY" = "rhel" ]; then
    mapfile -t RPMS < <(find "$WORK_DIR" -name '*.rpm')
    if [ "${#RPMS[@]}" -eq 0 ]; then echo " ❌ 包内没有 rpm"; exit 1; fi
    echo " -> 离线安装 ${#RPMS[@]} 个 rpm ..."
    # 只用本地文件, 禁用一切网络 repo; localinstall 会自动处理安装顺序
    if command -v yum >/dev/null 2>&1; then
        yum localinstall -y --disablerepo='*' "${RPMS[@]}" || rpm -Uvh --force "${RPMS[@]}"
    else
        rpm -Uvh --force "${RPMS[@]}"
    fi
else
    mapfile -t DEBS < <(find "$WORK_DIR" -name '*.deb')
    if [ "${#DEBS[@]}" -eq 0 ]; then echo " ❌ 包内没有 deb"; exit 1; fi
    echo " -> 离线安装 ${#DEBS[@]} 个 deb ..."
    export DEBIAN_FRONTEND=noninteractive
    # dpkg 不解析顺序, 跑两遍让互相依赖的包补齐
    dpkg -i "${DEBS[@]}" >/dev/null 2>&1
    dpkg -i "${DEBS[@]}"
fi

# ---------- 6. 验证 ----------
echo "----------------------------------------------------------"
if command -v ansible >/dev/null 2>&1; then
    echo " 🌟 [ 成功 ] $(ansible --version | head -n1)"
else
    echo " ❌ [ 失败 ] 未检测到 ansible 命令, 请查看上面的安装报错"
    exit 1
fi
