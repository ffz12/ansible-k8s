#!/bin/bash
# =============================================================================
#  prefetch-all.sh —— 一键预取全部离线物料(在【有网】节点上跑)。
#  依次调用 scripts/offline/download-*-offline.sh, 物料统一落到 offline/artifacts/。
#  跑完可选自动 rsync 回控制机(设 PREFETCH_DEST), 否则手动拷回。
#
#  ★ 各下载脚本参数不统一, 本脚本按层分派:
#      k8s / docker   : 吃 arch (amd64|arm64|all)
#      packages       : 吃 distro 列表 (含 haproxy/keepalived —— LB 包已并入基础包, 不再单独下)
#      ansible        : 吃 distro + arch (控制机离线装 ansible 用; 逐个发行版调用, 产物落 offline/ansible-pkg-install/)
#      harbor / gpu   : 仅 amd64, 无 arch 参数(gpu 的 $1 是版本, 用脚本默认)
#
#  ★ 架构/发行版「声明一次」(学 kk): 在 env.yaml 写 offline_arch / offline_distros,
#    经 gen-offline-versions.yaml → versions.env 自动带出, 不用每次手打 ARCH=/DISTRO=。
#    优先级(高覆低): 环境变量 ARCH=/DISTRO=  >  env.yaml(offline_arch/offline_distros)  >  all。
#
#  用法(层名走位置参; 架构/发行版优先读 env.yaml, 环境变量可临时覆盖):
#    bash scripts/prefetch-all.sh                       # 默认全量: k8s docker harbor gpu packages ansible
#    bash scripts/prefetch-all.sh k8s docker            # 只跑指定层(如仅镜像/二进制)
#    ARCH=amd64 bash scripts/prefetch-all.sh            # 临时只下单架构(压过 env.yaml)
#    DISTRO=ubuntu bash scripts/prefetch-all.sh packages        # 临时 packages 只下 ubuntu
#    PREFETCH_DEST=root@10.0.0.2:/root/ansible-k8s/offline/artifacts \
#      ARCH=amd64 bash scripts/prefetch-all.sh          # 跑完自动 rsync 回控制机
#    DOCKER_DNS=223.5.5.5 bash scripts/prefetch-all.sh packages  # 容器解析发行版官方源抖动时指定 DNS
#
#  ★ 下载失败不再静默: 某发行版/架构下崩 → 末尾红字汇总 + 非零退出(不会「直接下一步了」)。
#
#  可选层: k8s docker harbor gpu packages ansible   (与 download-<层>-offline.sh 对应)
# =============================================================================
set -e
# 本脚本在 scripts/ 顶层, 下载分层脚本在 scripts/offline/ —— cd 进去后
# download-*-offline.sh(相对名)与 REPO=../.. 全部原样成立, 无需再改别处。
cd "$(dirname "$0")/offline"

# 先记下显式环境变量覆盖(生成/source versions.env 后再按优先级定值)
_ARCH_OV="${ARCH:-}"
_DISTRO_OV="${DISTRO:-}"

LAYERS="${*:-k8s docker harbor gpu packages ansible}"   # 不带参数 = 全量; 只想跑部分就显式列层

say(){ echo -e "\033[0;32m[prefetch] $*\033[0m"; }

run_layer(){
  local L="$1" s="download-$1-offline.sh"
  [ -f "$s" ] || { echo "✗ 找不到 $s (未知层: $L)"; exit 1; }
  say "==== $s (arch=$ARCH distro=$DISTRO) ===="
  case "$L" in
    k8s|docker) bash "$s" "$ARCH" ;;
    packages)   bash "$s" $DISTRO ;;         # 有意分词: DISTRO 可为多发行版列表(如 "ubuntu kylin")
    ansible)    for d in $DISTRO; do bash "$s" "$d" "$ARCH"; done ;;  # ansible 脚本收单发行版, 逐个调用; 传架构
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

# -------- 架构/发行版按优先级定值: 环境变量 > env.yaml(versions.env) > all --------
# versions.env 由上一步生成, 里面带出 env.yaml 声明的 ARCH= / DISTROS=(offline_arch/offline_distros)。
[ -f versions.env ] && . ./versions.env
ARCH="${_ARCH_OV:-${ARCH:-all}}"          # 显式环境变量 > versions.env 的 ARCH > all
DISTRO="${_DISTRO_OV:-${DISTROS:-all}}"   # 显式环境变量 > versions.env 的 DISTROS > all
case "$ARCH" in amd64|arm64|all) ;; *) echo "ARCH 须为 amd64|arm64|all(当前: $ARCH)"; exit 1 ;; esac
export ARCH                               # 让 packages 各 builder 也能读到架构(按声明只下该架构)
say "预取范围: arch=$ARCH  distro=$DISTRO  layers=$LAYERS"

for L in $LAYERS; do run_layer "$L"; done

ART="$REPO/offline/artifacts"
say "全部下载完成, 物料在 $ART"
case " $LAYERS " in *" ansible "*) say "离线 ansible 安装包在 $REPO/offline/ansible-pkg-install/(控制机本地装)";; esac
if [ -n "$PREFETCH_DEST" ]; then
  command -v rsync >/dev/null 2>&1 || { echo "✗ 缺 rsync, 无法自动回传; 请手动拷 $ART 回控制机"; exit 1; }
  say "rsync 回控制机: $PREFETCH_DEST"
  rsync -a --info=progress2 "$ART/" "$PREFETCH_DEST/"
  say "已汇到 $PREFETCH_DEST ; 部署时 is_offline=true"
else
  REPO_PARENT="$(dirname "$REPO")"; REPO_NAME="$(basename "$REPO")"
  say "如需汇控制机(二选一):"
  say "  ① 整仓拷贝(控制机还没有本仓库时, 推荐): cd $REPO_PARENT && rsync -a ./$REPO_NAME <控制机>:<目标父目录>/"
  say "     (无 rsync 用: scp -r ./$REPO_NAME <控制机>:<目标父目录>/)"
  say "  ② 只回物料(控制机已有本仓库): rsync -a $ART/ <控制机>:<repo>/offline/artifacts/"
  say "  (或设 PREFETCH_DEST 环境变量, 跑完自动传物料)"
  say "部署时 is_offline=true"
fi
