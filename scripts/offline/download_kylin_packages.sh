#!/bin/bash

# ================= 配置区域 =================
# 注: haproxy keepalived 只有 LB 节点用 —— 放进同一次 yum 解析(下面 --downloadonly)不会重复(公共依赖去重),
#     与基础包合成一个 tar; init 只装显式列表(kylin_offline_pkgs, 不含 LB), 故非 LB 节点只存不装;
#     haproxy-ha 在 LB 节点从同一本地源按名安装。改这里需同步 roles/init/tasks/kylinsp3.yaml 的 kylin_offline_pkgs。
OFFLINE_PKGS="openssl-libs pcre zlib socat chrony ipvsadm conntrack ipset ebtables nfs* haproxy keepalived"
KYLIN_IMAGE="hxsoong/kylin:v10-sp3"

# 最终存放 TAR 包的根目录 (对齐你的现状)
BASE_DIR="$(cd "$(dirname "$0")/../../offline" && pwd)/artifacts/ios-offline"
# ============================================

download_by_arch() {
    local arch=$1        # amd64 或 arm64
    local tag_name=$2    # x86_64 或 arm64
    
    local tmp_save_dir="$BASE_DIR/kylin_${tag_name}_tmp"
    local tar_name="kylin_${tag_name}.tar.gz"

    echo "=========================================================="
    echo " 开始下载麒麟 V10 SP3 [ 架构: $arch -> $tag_name ]"
    echo "=========================================================="

    rm -rf "$tmp_save_dir"
    mkdir -p "$tmp_save_dir"
    mkdir -p "$BASE_DIR"

    docker run --rm \
        --platform "linux/$arch" \
        -v "$tmp_save_dir":/tmp/download \
        "$KYLIN_IMAGE" \
        sh -c "
            set -e
            yum install --downloadonly --downloaddir=/tmp/download $OFFLINE_PKGS -y
            cd /tmp/download
            # 生成 repodata 离线索引(供 init 作本地 yum 源 + 显式列表安装; 拿不到 createrepo 就跳过, init 回退 localinstall)
            if yum install -y createrepo_c >/dev/null 2>&1 || yum install -y createrepo >/dev/null 2>&1; then
                createrepo_c . >/dev/null 2>&1 || createrepo . >/dev/null 2>&1 || echo ' ⚠️  createrepo 执行失败, tar 无 repodata(init 会回退 localinstall)'
            else
                echo ' ⚠️  容器内装不到 createrepo, tar 无 repodata(init 会回退 localinstall)'
            fi
        "

    if [ $? -eq 0 ]; then
        echo " -> 容器内下载完成，开始在宿主机打包..."
        cd "$tmp_save_dir"
        tar -czf "$BASE_DIR/$tar_name" ./*
        cd - > /dev/null
        rm -rf "$tmp_save_dir"
        echo " 🌟 [ 成功 ] 麒麟离线 Tar 包已生成: $BASE_DIR/$tar_name"
    else
        echo " ❌ [ 失败 ] $tag_name 架构下载失败。"
        rm -rf "$tmp_save_dir"
    fi
}

# 执行下载
download_by_arch "amd64" "x86_64"
echo -e "\n"
download_by_arch "arm64" "arm64"
