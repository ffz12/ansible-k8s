#!/bin/bash
# =============================================================================
#  prefetch-all.sh —— 一键预取全部离线物料(在【有网】节点上跑)。
#  依次调用 scripts/offline/download-*-offline.sh, 物料统一落到 offline/artifacts/。
#  跑完可选自动 rsync 回控制机(设 PREFETCH_DEST), 否则手动拷回。
#
#  ★ 各下载脚本参数不统一, 本脚本按层分派:
#      k8s / docker   : 吃 arch (amd64|arm64|all)
#      lb             : 吃 distro + arch
#      packages       : 吃 distro
#      harbor / gpu   : 仅 amd64, 无 arch 参数(gpu 的 $1 是版本, 用脚本默认)
#
#  用法(arch/distro/回传目标走环境变量, 层名走位置参):
#    bash scripts/prefetch-all.sh [layer ...]           # 默认层: k8s docker
#    ARCH=amd64 bash scripts/prefetch-all.sh            # 纯单架构省一半(默认 all 双架构)
#    ARCH=amd64 bash scripts/prefetch-all.sh k8s docker harbor lb gpu packages   # 全量
#    DISTRO=ubuntu bash scripts/prefetch-all.sh lb packages     # lb/packages 只下 ubuntu(默认 all)
#    PREFETCH_DEST=root@10.0.0.2:/root/ansible-k8s/offline/artifacts \
#      ARCH=amd64 bash scripts/prefetch-all.sh          # 跑完自动 rsync 回控制机
#
#  可选层: k8s docker harbor lb gpu packages   (与 download-<层>-offline.sh 对应)
# =============================================================================
set -e
# 本脚本在 scripts/ 顶层, 下载分层脚本在 scripts/offline/ —— cd 进去后
# download-*-offline.sh(相对名)与 REPO=../.. 全部原样成立, 无需再改别处。
cd "$(dirname "$0")/offline"

ARCH="${ARCH:-all}"
DISTRO="${DISTRO:-all}"
case "$ARCH" in amd64|arm64|all) ;; *) echo "ARCH 须为 amd64|arm64|all"; exit 1 ;; esac

LAYERS="${*:-k8s docker}"

say(){ echo -e "\033[0;32m[prefetch] $*\033[0m"; }

run_layer(){
  local L="$1" s="download-$1-offline.sh"
  [ -f "$s" ] || { echo "✗ 找不到 $s (未知层: $L)"; exit 1; }
  say "==== $s (arch=$ARCH distro=$DISTRO) ===="
  case "$L" in
    k8s|docker) bash "$s" "$ARCH" ;;
    lb)         bash "$s" "$DISTRO" "$ARCH" ;;
    packages)   bash "$s" "$DISTRO" ;;
    harbor|gpu) bash "$s" ;;              # 仅 amd64; gpu 的 $1 是版本, 走脚本默认
    *)          bash "$s" ;;
  esac
}

# 依赖自检(镜像层要 skopeo, 二进制要 curl; tar/gzip 打包用)
for c in curl tar gzip; do command -v "$c" >/dev/null 2>&1 || { echo "✗ 缺 $c, 先装"; exit 1; }; done
case " $LAYERS " in *" k8s "*|*" docker "*|*" harbor "*)
  command -v skopeo >/dev/null 2>&1 || { echo "✗ 拉镜像需 skopeo: yum install -y skopeo 或 apt install -y skopeo"; exit 1; } ;;
esac

# -------- 版本单一源: 先用 ansible 把部署侧解析后的版本 dump 成 versions.env --------
# 有 ansible + inventory 就刷新(保证下载版本 == 部署版本); 没有则用各脚本内置兜底默认。
REPO="$(cd ../.. && pwd)"
if command -v ansible-playbook >/dev/null 2>&1 && [ -f "$REPO/inventory/hosts" ]; then
  say "生成 versions.env(与 ansible 部署同源)"
  ansible-playbook -i "$REPO/inventory/hosts" "$REPO/playbook/gen-offline-versions.yaml"
else
  say "⚠ 无 ansible-playbook 或 inventory/hosts, 跳过版本生成, 下载脚本用内置兜底默认版本"
fi

for L in $LAYERS; do run_layer "$L"; done

ART="$REPO/offline/artifacts"
say "全部下载完成, 物料在 $ART"
if [ -n "$PREFETCH_DEST" ]; then
  command -v rsync >/dev/null 2>&1 || { echo "✗ 缺 rsync, 无法自动回传; 请手动拷 $ART 回控制机"; exit 1; }
  say "rsync 回控制机: $PREFETCH_DEST"
  rsync -a --info=progress2 "$ART/" "$PREFETCH_DEST/"
  say "已汇到 $PREFETCH_DEST ; 部署时 is_offline=true"
else
  say "如需汇控制机: rsync -a $ART/ <控制机>:<repo>/offline/artifacts/  (或设 PREFETCH_DEST 自动传)"
  say "部署时 is_offline=true"
fi
