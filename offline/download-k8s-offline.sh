#!/bin/bash
# =============================================================================
#  download-k8s-offline.sh —— 在【有网 + 有 docker】的机器上跑,
#  把 k8s 层所有离线物料(双架构)下好并 docker save 成 tar,
#  按 offline/binaries/ 版本目录摆好, 镜像 tag 严格对齐 ansible sync 的期望。
#  拷回内网后, 部署时 -e is_offline=true 即可。
#
#  用法: bash download-k8s-offline.sh
#  依赖: docker(支持 --platform 拉多架构)、curl、tar、helm(拉 cilium chart 时;脚本会自动下)
# =============================================================================
set -e

# -------- 版本(与 inventory/group_vars/all/env.yaml 保持一致) --------
K8S="1.34.3"                 # kubeadm/kubectl/kubelet + 组件镜像
COREDNS="1.12.1"             # 对着 `kubeadm config images list --kubernetes-version v$K8S` 核对
PAUSE="3.10.1"               # 同上(注意 pause tag 无 v 前缀)
CRICTL="1.34.0"
ETCD="3.6.8"
CONTAINERD="1.7.32"
RUNC="1.1.12"
CALICO="3.27.5"
FLANNEL="0.26.7"
FLANNEL_CNI="1.6.2-flannel1"
CILIUM="1.16.5"
HELM="3.16.4"

ARCHES="amd64 arm64"
CNIS="calico flannel cilium"   # 只打包用得到的可删减, 如 CNIS="calico"

# -------- 源(国内 mirror;受限自行改) --------
IMG_MIRROR="registry.aliyuncs.com/google_containers"    # k8s 组件/pause/coredns
CALICO_SRC="docker.io/calico"
FLANNEL_SRC="docker.io/flannel"
CILIUM_SRC="quay.io/cilium"
# -------- 二进制源: daocloud 通用文件代理(国内快, 一个源代理 dl.k8s.io/github/get.helm.sh) --------
DAO="https://files.m.daocloud.io"
K8S_BIN="$DAO/dl.k8s.io/release"
CRICTL_BIN="$DAO/github.com/kubernetes-sigs/cri-tools/releases/download"
ETCD_BIN="$DAO/github.com/etcd-io/etcd/releases/download"
CONTAINERD_BIN="$DAO/github.com/containerd/containerd/releases/download"
RUNC_BIN="$DAO/github.com/opencontainers/runc/releases/download"
HELM_BIN="$DAO/get.helm.sh"
CILIUM_HELM_REPO="https://helm.cilium.io"

B="$(cd "$(dirname "$0")/binaries" && pwd)"    # offline/binaries
say(){ echo -e "\033[0;32m[+] $*\033[0m"; }

# 拉镜像→按 arch 重命名→save. $1=源(含tag) $2=目标模板(含 __ARCH__) $3=目标目录 $4=文件名(无扩展)
save_img(){
  local src="$1" tmpl="$2" dir="$3" name="$4" a t i
  for a in $ARCHES; do
    if [ -s "$dir/$a/$name.tar" ]; then say "跳过(已存在) $name.tar ($a)"; continue; fi
    say "pull $src ($a)"
    # docker.io/quay 偶发 EOF, 重试几次
    for i in 1 2 3 4 5; do
      docker pull --platform "linux/$a" "$src" && break
      echo "  pull 失败, 第 $i 次重试..."; sleep 5
      [ "$i" = 5 ] && { echo "  ✗ $src ($a) 多次失败, 建议配 docker 镜像加速后重跑"; exit 1; }
    done
    t="${tmpl/__ARCH__/$a}"
    docker tag "$src" "$t"
    mkdir -p "$dir/$a"
    docker save "$t" -o "$dir/$a/$name.tar"
    # 校验保存的 tar 完整(能列表), 损坏则删掉报错
    if ! tar -tf "$dir/$a/$name.tar" >/dev/null 2>&1; then
      rm -f "$dir/$a/$name.tar"; echo "  ✗ 保存的 $name.tar($a) 损坏, 请重跑"; exit 1
    fi
    docker rmi "$t" >/dev/null 2>&1 || true
  done
  docker rmi "$src" >/dev/null 2>&1 || true
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

# ========== 2. k8s 组件镜像 + pause + coredns ==========
KIMG="$B/kubernetes/v$K8S/images"
for c in kube-apiserver kube-controller-manager kube-scheduler kube-proxy; do
  save_img "$IMG_MIRROR/$c:v$K8S" "registry.k8s.io/$c-__ARCH__:v$K8S" "$KIMG" "$c"
done
save_img "$IMG_MIRROR/pause:$PAUSE"     "registry.k8s.io/pause-__ARCH__:$PAUSE"     "$KIMG" "pause"
save_img "$IMG_MIRROR/coredns:v$COREDNS" "registry.k8s.io/coredns-__ARCH__:v$COREDNS" "$KIMG" "coredns"

# ========== 3. etcd / containerd / runc ==========
for a in $ARCHES; do
  dl "$ETCD_BIN/v$ETCD/etcd-v$ETCD-linux-$a.tar.gz" "$B/etcd/v$ETCD/$a/etcd-v$ETCD-linux-$a.tar.gz"
  dl "$CONTAINERD_BIN/v$CONTAINERD/containerd-$CONTAINERD-linux-$a.tar.gz" "$B/containerd/v$CONTAINERD/$a/containerd-$CONTAINERD-linux-$a.tar.gz"
  dl "$RUNC_BIN/v$RUNC/runc.$a" "$B/runc/v$RUNC/$a/runc.$a"; chmod +x "$B/runc/v$RUNC/$a/runc.$a"
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
    if command -v helm >/dev/null 2>&1; then
      helm repo add cilium "$CILIUM_HELM_REPO" >/dev/null 2>&1 || true; helm repo update >/dev/null 2>&1 || true
      helm pull cilium/cilium --version "$CILIUM" -d "$B/cni/cilium/v$CILIUM/"
    else
      echo "  ⚠ 本机无 helm,cilium chart 未下; 手动: helm pull cilium/cilium --version $CILIUM -d $B/cni/cilium/v$CILIUM/"
    fi ;;
esac; done

say "全部完成! 物料在 $B ; 拷回内网后 -e is_offline=true 部署。"
