#!/bin/bash

VERSION="v1.32.0"

# --- ARM 版本 (aarch64) ---
# 注意路径中的 aarch64
echo "正在下载 ARM 版本..."
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-arm64.tar.gz 
# --- AMD 版本 (x86_64) ---
# 注意路径中的 x86_64
echo "正在下载 AMD 版本..."
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz

echo "检查下载结果:"
ls -lh *crictl-*"

