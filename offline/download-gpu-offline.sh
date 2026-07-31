#!/bin/bash
# =============================================================================
#  download-gpu-offline.sh —— 在【有网 + 有 docker】机器上下载 nvidia-container-toolkit
#  的离线安装包(rpm + deb, 含全量依赖), 存进 offline/artifacts/nvidia-gpu/。
#  对齐 container-toolkit 角色: rhel-gpu/*.rpm(yum install)、debian-gpu/*.deb(dpkg -i)。
#
#  ⚠️ 只覆盖 NVIDIA。DCU(海光)/ NPU(华为昇腾 .run)是厂商私有包, 公网无法自动下载,
#     请从厂商渠道获取后手动放到 offline/artifacts/dcu/{rhel,debian}-dcu/ 与 offline/artifacts/npu/。
#
#  ⚠️ 本脚本接 NVIDIA 官方源(nvidia.github.io), 未在国内网络实测; 若源路径/包名有变,
#     按容器内报错微调下方 repo 配置即可(思路同 download_*_ansible.sh)。
#
#  仅 amd64: GPU 节点基本都是 x86。arm64 + N 卡(GH200/Grace-Hopper、Jetson)是少数平台,
#            本项目不覆盖; 真要用时把两处 --platform 改 linux/arm64 重跑即可。
#  用法: bash offline/download-gpu-offline.sh
#  依赖: docker(按架构精确拉包)
#  注意: 角色按【单一目录扁平读取 *.rpm/*.deb】。
# =============================================================================
set -e

GPU="$(cd "$(dirname "$0")/artifacts" && pwd)/nvidia-gpu"    # offline/artifacts/nvidia-gpu
RHEL_DIR="$GPU/rhel-gpu"
DEB_DIR="$GPU/debian-gpu"

command -v docker >/dev/null 2>&1 || { echo "缺 docker(脚本用容器按架构精确拉包), 请先安装"; exit 1; }

NV_BASE="https://nvidia.github.io/libnvidia-container"
NV_REPO="$NV_BASE/stable"

# ---------- RHEL 系 (rpm) ----------
echo "========== 下载 nvidia-container-toolkit RPM [amd64] =========="
tmp_rpm="$RHEL_DIR/_tmp"; rm -rf "$tmp_rpm"; mkdir -p "$tmp_rpm"
docker run --rm --platform linux/amd64 -v "$tmp_rpm":/tmp/download rockylinux:8 sh -c "
    set -e
    curl -s -L $NV_REPO/rpm/nvidia-container-toolkit.repo -o /etc/yum.repos.d/nvidia-container-toolkit.repo
    yum install -y -q yum-utils >/dev/null
    cd /tmp/download
    echo ' -> yumdownloader 递归抓 nvidia-container-toolkit 全量依赖...'
    yumdownloader --resolve --alldeps --destdir=/tmp/download nvidia-container-toolkit -y -q >/dev/null 2>&1
    yum install --downloadonly --downloaddir=/tmp/download nvidia-container-toolkit -y -q >/dev/null 2>&1 || true
"
if [ "$(ls -A "$tmp_rpm" 2>/dev/null)" ]; then
    rm -f "$RHEL_DIR"/*.rpm 2>/dev/null || true
    mv "$tmp_rpm"/*.rpm "$RHEL_DIR"/ 2>/dev/null || true
    rm -rf "$tmp_rpm"
    echo " 🌟 [ 成功 ] RPM 已就位: $RHEL_DIR/ ($(ls -1 "$RHEL_DIR"/*.rpm 2>/dev/null | wc -l) 个)"
else
    rm -rf "$tmp_rpm"; echo " ❌ [ 失败 ] RPM 下载目录为空, 检查 nvidia repo 是否可达/包名"
fi

# ---------- Debian 系 (deb) ----------
echo "========== 下载 nvidia-container-toolkit DEB [amd64] =========="
tmp_deb="$DEB_DIR/_tmp"; rm -rf "$tmp_deb"; mkdir -p "$tmp_deb"
docker run --rm --platform linux/amd64 -v "$tmp_deb":/tmp/download ubuntu:22.04 sh -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl gnupg ca-certificates >/dev/null
    curl -fsSL $NV_BASE/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L $NV_REPO/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    cd /tmp/download
    echo ' -> apt 递归抓 nvidia-container-toolkit 全量依赖...'
    apt-get download \$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances nvidia-container-toolkit | grep '^\w' | sort -u) 2>/dev/null || true
    apt-get download nvidia-container-toolkit 2>/dev/null || true
"
if [ "$(ls -A "$tmp_deb" 2>/dev/null)" ]; then
    rm -f "$DEB_DIR"/*.deb 2>/dev/null || true
    mv "$tmp_deb"/*.deb "$DEB_DIR"/ 2>/dev/null || true
    rm -rf "$tmp_deb"
    echo " 🌟 [ 成功 ] DEB 已就位: $DEB_DIR/ ($(ls -1 "$DEB_DIR"/*.deb 2>/dev/null | wc -l) 个)"
else
    rm -rf "$tmp_deb"; echo " ❌ [ 失败 ] DEB 下载目录为空, 检查 nvidia repo 是否可达/包名"
fi

echo -e "\n=========================================================="
echo " NVIDIA GPU 离线包下载结束 [amd64]。DCU/NPU 请手动放包(见脚本头注释)。"
echo "=========================================================="
