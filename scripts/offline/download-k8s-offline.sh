#!/bin/bash
# =============================================================================
#  download-k8s-offline.sh —— 在【有网】的机器上跑(装 skopeo + curl, 无需 docker daemon),
#  把 k8s 层所有离线物料(双架构)下好并存成 tar,
#  按 offline/artifacts/ 版本目录摆好, 镜像 tag 严格对齐 ansible sync 的期望。
#  拷回内网后, 部署时 -e is_offline=true 即可。
#
#  用法: bash scripts/offline/download-k8s-offline.sh [amd64|arm64|all]   (默认 all=双架构)
#        集群是纯 amd64 或纯 arm64 时, 指定单架构可省一半体积/时间(镜像大头)。
#  依赖: skopeo(拉镜像,按架构精确)、curl、tar
# =============================================================================
set -e

# -------- 架构选择(默认双架构; 单架构集群指定一个即可省一半) --------
case "${1:-all}" in
  amd64) ARCHES="amd64" ;;
  arm64) ARCHES="arm64" ;;
  all)   ARCHES="amd64 arm64" ;;
  *) echo "用法: bash $0 [amd64|arm64|all]  (默认 all)"; exit 1 ;;
esac

# -------- 版本(单一源) --------
# 优先 source 由 gen-offline-versions.yaml 从 ansible 变量生成的 versions.env(与部署同源);
# 没有该文件时用下面 :=兜底默认, 脚本仍可脱离 ansible 独立跑。
[ -f "$(dirname "$0")/versions.env" ] && . "$(dirname "$0")/versions.env"
: "${K8S:=1.34.3}"                 # kubeadm/kubectl/kubelet + 组件镜像
# COREDNS/PAUSE 还会在下完 kubeadm 后由 `kubeadm config images list` 自动校准(见 1.5 段),
# 查得到以 kubeadm 为准; versions.env / 下面兜底只是查不到时用。
: "${COREDNS:=1.12.1}"
: "${PAUSE:=3.10.1}"               # 注意 pause tag 无 v 前缀
: "${CRICTL:=1.34.0}"
: "${ETCD:=3.6.8}"
: "${CALICO:=3.27.5}"
: "${FLANNEL:=0.26.7}"
: "${FLANNEL_CNI:=1.6.2-flannel1}"
: "${CILIUM:=1.16.5}"
: "${HELM:=3.16.4}"

CNIS="calico flannel cilium"   # 只打包用得到的可删减, 如 CNIS="calico"

# -------- 源(国内 mirror;受限自行改。skopeo 直接从这些地址拉,不走 docker daemon 加速) --------
IMG_MIRROR="registry.aliyuncs.com/google_containers"    # k8s 组件/pause/coredns
CALICO_SRC="docker.m.daocloud.io/calico"                # = docker.io/calico(daocloud 加速)
FLANNEL_SRC="docker.m.daocloud.io/flannel"              # = docker.io/flannel
CILIUM_SRC="quay.m.daocloud.io/cilium"                  # = quay.io/cilium(daocloud 加速)
# -------- 二进制源: daocloud 通用文件代理(国内快, 一个源代理 dl.k8s.io/github/get.helm.sh) --------
DAO="https://files.m.daocloud.io"
K8S_BIN="$DAO/dl.k8s.io/release"
CRICTL_BIN="$DAO/github.com/kubernetes-sigs/cri-tools/releases/download"
ETCD_BIN="$DAO/github.com/etcd-io/etcd/releases/download"
HELM_BIN="$DAO/get.helm.sh"
CILIUM_HELM_REPO="https://helm.cilium.io"

OFFLINE="$(cd "$(dirname "$0")/../../offline" && pwd)"   # scripts/offline/ -> offline/(物料仍落 offline)
B="$OFFLINE/artifacts"; mkdir -p "$B"           # offline/artifacts
say(){ echo -e "\033[0;32m[+] $*\033[0m"; }

# 依赖检查: skopeo(镜像) + curl(二进制)
command -v skopeo >/dev/null 2>&1 || { echo "缺 skopeo, 请先装: yum install -y skopeo  或  apt install -y skopeo"; exit 1; }
command -v curl   >/dev/null 2>&1 || { echo "缺 curl"; exit 1; }

# 用 skopeo 按架构精确拉取并存成 docker-archive(避开 docker save 多架构毛病), 再 gzip 压缩省空间
# $1=源(不含协议,含tag) $2=目标 docker load 名模板(含 __ARCH__) $3=目标目录 $4=文件名(无扩展, 落盘为 .tar.gz)
save_img(){
  local src="$1" tmpl="$2" dir="$3" name="$4" a load i
  for a in $ARCHES; do
    if [ -s "$dir/$a/$name.tar.gz" ]; then say "跳过(已存在) $name.tar.gz ($a)"; continue; fi
    load="${tmpl/__ARCH__/$a}"
    mkdir -p "$dir/$a"
    for i in 1 2 3 4 5; do
      say "skopeo copy $src ($a)"
      if skopeo copy --override-os linux --override-arch "$a" \
        "docker://$src" "docker-archive:$dir/$a/$name.tar:$load"; then
        # skopeo 存的是未压缩 tar, 再 gzip 省空间(docker load 会自动解压 .tar.gz)
        say "gzip $name.tar -> $name.tar.gz ($a)"
        gzip -f "$dir/$a/$name.tar"
        break
      fi
      echo "  失败, 第 $i 次重试..."; rm -f "$dir/$a/$name.tar" "$dir/$a/$name.tar.gz"; sleep 5
      [ "$i" = 5 ] && { echo "  ✗ $src ($a) 多次失败"; exit 1; }
    done
  done
}
# 远端 Content-Length(跟随重定向)
rsize(){ curl -sIL -m 15 "$1" 2>/dev/null | awk 'BEGIN{IGNORECASE=1}/^content-length:/{v=$2}END{gsub(/\r/,"",v);print v}'; }
# 下载 + 大小校验; 残缺/不符自动重下. $1=url $2=dest
dl(){
  local url="$1" dest="$2" i r l
  if [ -s "$dest" ]; then
    r=$(rsize "$url"); l=$(stat -c%s "$dest" 2>/dev/null || wc -c <"$dest")
    if [ -z "$r" ] || [ "$r" = "$l" ]; then say "跳过(完整) $dest"; return; fi
    say "已存在但大小不符($l/$r), 重下"; rm -f "$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  for i in 1 2 3 4 5; do
    say "curl $url"
    curl -fSL --retry 3 -o "$dest" "$url" || { echo "  下载失败,第 $i 次重试"; sleep 5; continue; }
    r=$(rsize "$url"); l=$(stat -c%s "$dest" 2>/dev/null || wc -c <"$dest")
    { [ -z "$r" ] || [ "$r" = "$l" ]; } && return
    echo "  大小不符($l/$r),第 $i 次重下"; rm -f "$dest"; sleep 3
  done
  echo "✗ 下载/校验失败: $url"; exit 1
}

# ========== 1. k8s 二进制 (kubeadm/kubectl/kubelet/crictl) ==========
for a in $ARCHES; do
  for bin in kubeadm kubectl kubelet; do
    dl "$K8S_BIN/v$K8S/bin/linux/$a/$bin" "$B/kubernetes/v$K8S/bin/$a/$bin"
    chmod +x "$B/kubernetes/v$K8S/bin/$a/$bin"
  done
  # crictl: cri-tools tar -> 取 crictl 二进制放同目录
  tmp="$(mktemp -d)"
  dl "$CRICTL_BIN/v$CRICTL/crictl-v$CRICTL-linux-$a.tar.gz" "$tmp/crictl.tgz"
  tar -xzf "$tmp/crictl.tgz" -C "$tmp"
  cp "$tmp/crictl" "$B/kubernetes/v$K8S/bin/$a/crictl"; chmod +x "$B/kubernetes/v$K8S/bin/$a/crictl"
  rm -rf "$tmp"
done

# ========== 1.5 用 kubeadm 校准镜像/etcd tag(消除 pause/coredns/etcd 手写漂移) ==========
# kubeadm config images list 按 k8s 版本给出权威 tag; 取到就覆盖上面的默认。
# 需要一个本机架构可跑的 kubeadm(上面按 ARCHES 已下, 本机架构不在 ARCHES 时临时补下一个)。
host_arch(){ case "$(uname -m)" in x86_64) echo amd64;; aarch64|arm64) echo arm64;; *) echo amd64;; esac; }
HA="$(host_arch)"; KUBEADM="$B/kubernetes/v$K8S/bin/$HA/kubeadm"
if [ ! -x "$KUBEADM" ]; then
  dl "$K8S_BIN/v$K8S/bin/linux/$HA/kubeadm" "$KUBEADM"; chmod +x "$KUBEADM"
fi
IMG_LIST="$("$KUBEADM" config images list --kubernetes-version "v$K8S" 2>/dev/null || true)"
if [ -n "$IMG_LIST" ]; then
  get_tag(){ echo "$IMG_LIST" | grep -E "$1" | head -1 | sed 's/.*://'; }
  CD="$(get_tag '/coredns')"; [ -n "$CD" ] && COREDNS="${CD#v}"
  PZ="$(get_tag '/pause')";   [ -n "$PZ" ] && PAUSE="${PZ#v}"
  # etcd: kubeadm 给的是镜像 tag(如 3.6.4-0), 剥掉 -N 构建后缀得二进制版本
  ET="$(get_tag '/etcd')";    [ -n "$ET" ] && { ET="${ET%-*}"; ETCD="${ET#v}"; }
  say "kubeadm 校准: coredns=v$COREDNS pause=$PAUSE etcd=v$ETCD (k8s v$K8S)"
else
  say "⚠ kubeadm 未给出镜像清单, 沿用默认 coredns=v$COREDNS pause=$PAUSE etcd=v$ETCD"
fi

# ========== 2. k8s 组件镜像 + pause + coredns ==========
KIMG="$B/kubernetes/v$K8S/images"
for c in kube-apiserver kube-controller-manager kube-scheduler kube-proxy; do
  save_img "$IMG_MIRROR/$c:v$K8S" "registry.k8s.io/$c-__ARCH__:v$K8S" "$KIMG" "$c"
done
save_img "$IMG_MIRROR/pause:$PAUSE"     "registry.k8s.io/pause-__ARCH__:$PAUSE"     "$KIMG" "pause"
save_img "$IMG_MIRROR/coredns:v$COREDNS" "registry.k8s.io/coredns-__ARCH__:v$COREDNS" "$KIMG" "coredns"

# ========== 3. etcd (containerd/runc 已挪到 download-docker-offline.sh 的底座层) ==========
for a in $ARCHES; do
  dl "$ETCD_BIN/v$ETCD/etcd-v$ETCD-linux-$a.tar.gz" "$B/etcd/v$ETCD/$a/etcd-v$ETCD-linux-$a.tar.gz"
done

# ========== 4. CNI 镜像(按 CNIS 选) ==========
for cni in $CNIS; do case $cni in
  calico)
    for c in cni node kube-controllers; do
      save_img "$CALICO_SRC/$c:v$CALICO" "calico/$c:v$CALICO-__ARCH__" "$B/cni/calico/v$CALICO/images" "$c"
    done ;;
  flannel)
    save_img "$FLANNEL_SRC/flannel:v$FLANNEL" "flannel/flannel:v$FLANNEL-__ARCH__" "$B/cni/flannel/v$FLANNEL/images" "flannel"
    save_img "$FLANNEL_SRC/flannel-cni-plugin:v$FLANNEL_CNI" "flannel/flannel-cni-plugin:v$FLANNEL_CNI-__ARCH__" "$B/cni/flannel/v$FLANNEL/images" "flannel-cni-plugin" ;;
  cilium)
    save_img "$CILIUM_SRC/cilium:v$CILIUM" "quay.io/cilium/cilium:v$CILIUM-__ARCH__" "$B/cni/cilium/v$CILIUM/images" "cilium"
    save_img "$CILIUM_SRC/operator-generic:v$CILIUM" "quay.io/cilium/operator-generic:v$CILIUM-__ARCH__" "$B/cni/cilium/v$CILIUM/images" "operator-generic"
    # helm 二进制 + cilium chart
    for a in $ARCHES; do
      tmp="$(mktemp -d)"; dl "$HELM_BIN/helm-v$HELM-linux-$a.tar.gz" "$tmp/helm.tgz"
      tar -xzf "$tmp/helm.tgz" -C "$tmp"; mkdir -p "$B/helm/v$HELM/$a"; cp "$tmp/linux-$a/helm" "$B/helm/v$HELM/$a/helm"; chmod +x "$B/helm/v$HELM/$a/helm"; rm -rf "$tmp"
    done
    # cilium chart: 直接下 tgz(无需本机 helm), 对齐 cilium_chart_src
    dl "$CILIUM_HELM_REPO/cilium-$CILIUM.tgz" "$B/cni/cilium/v$CILIUM/cilium-$CILIUM.tgz" ;;
esac; done

say "全部完成! 物料在 $B ; 拷回内网后 -e is_offline=true 部署。"
