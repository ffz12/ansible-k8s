#!/bin/bash
# =============================================================================
#  download-gpu-offline.sh —— 在【有网】机器上下载 nvidia-container-toolkit 的
#  离线安装包(rpm + deb), 存进 offline/artifacts/nvidia-gpu/。
#  对齐 container-toolkit 角色: rhel-gpu/*.rpm(yum install)、debian-gpu/*.deb(dpkg -i)。
#
#  ⚠️ 只覆盖 NVIDIA。DCU(海光)/ NPU(华为昇腾 .run)是厂商私有包, 公网无法自动下载,
#     请从厂商渠道获取后手动放到 offline/artifacts/dcu/{rhel,debian}-dcu/ 与 offline/artifacts/npu/。
#
#  仅 amd64: GPU 节点基本都是 x86。arm64 + N 卡(GH200/Grace-Hopper、Jetson)是少数平台,
#            本项目不覆盖; 真要用时把 RPM_BASE/DEB_BASE 的 x86_64/amd64 与文件后缀改 arm64/aarch64。
#
#  只抓 nvidia 源里的 4 个核心包(不含系统依赖, 目标机自带):
#    nvidia-container-toolkit / nvidia-container-toolkit-base
#    libnvidia-container-tools / libnvidia-container1
#
#  实现: 不走 yum/apt 源(github.io 拉 repodata 索引易超时), 直接按 URL curl 单个包,
#        curl 带重试 + 断点续传, 比走源稳。
#  用法: bash offline/download-gpu-offline.sh [版本]   # 默认 1.19.0-1
#  依赖: curl
# =============================================================================
set -e

VER="${1:-1.19.0-1}"                                        # 包版本, 如 1.19.0-1

GPU="$(cd "$(dirname "$0")/artifacts" && pwd)/nvidia-gpu"   # offline/artifacts/nvidia-gpu
RHEL_DIR="$GPU/rhel-gpu"
DEB_DIR="$GPU/debian-gpu"
mkdir -p "$RHEL_DIR" "$DEB_DIR"

command -v curl >/dev/null 2>&1 || { echo "缺 curl, 请先安装"; exit 1; }

NV_REPO="https://nvidia.github.io/libnvidia-container/stable"
RPM_BASE="$NV_REPO/rpm/x86_64"       # rpm 直链目录($basearch=x86_64)
DEB_BASE="$NV_REPO/deb/amd64"        # deb 直链目录(flat repo, $(ARCH)=amd64)
PKGS="nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1"

CURL="curl -fL --retry 5 --retry-delay 3 --retry-connrefused -C -"

# ---------- RHEL 系 (rpm) ----------
echo "========== 下载 nvidia-container-toolkit RPM [amd64] v$VER =========="
rpm_ok=0
for p in $PKGS; do
    f="$p-$VER.x86_64.rpm"
    echo " -> $f"
    if $CURL -o "$RHEL_DIR/$f" "$RPM_BASE/$f"; then rpm_ok=$((rpm_ok+1)); else
        echo "    ❌ 下载失败: $RPM_BASE/$f"; rm -f "$RHEL_DIR/$f"
    fi
done
echo " RPM: $rpm_ok/4 就位 -> $RHEL_DIR/"

# ---------- Debian 系 (deb) ----------
echo "========== 下载 nvidia-container-toolkit DEB [amd64] v$VER =========="
deb_ok=0
for p in $PKGS; do
    f="${p}_${VER}_amd64.deb"
    echo " -> $f"
    if $CURL -o "$DEB_DIR/$f" "$DEB_BASE/$f"; then deb_ok=$((deb_ok+1)); else
        echo "    ❌ 下载失败: $DEB_BASE/$f"; rm -f "$DEB_DIR/$f"
    fi
done
echo " DEB: $deb_ok/4 就位 -> $DEB_DIR/"

echo -e "\n=========================================================="
if [ "$rpm_ok" -eq 4 ] && [ "$deb_ok" -eq 4 ]; then
    echo " 🌟 NVIDIA GPU 离线包下载完成 [amd64] v$VER (rpm 4 + deb 4)。"
else
    echo " ⚠️  未全部就位(rpm $rpm_ok/4, deb $deb_ok/4)。"
    echo "     若报 404: 该版本可能不在 stable, 换个版本号重跑, 如: bash $0 1.17.8-1"
    echo "     若一直超时: github.io 被限流, 多试几次或换网络。"
fi
echo " DCU/NPU 请手动放包(见脚本头注释)。"
echo "=========================================================="
