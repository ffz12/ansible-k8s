#!/bin/bash

VERSION="29.4.2"
TGZ_NAME="docker-$VERSION.tgz"

# --- ARM 版本 (aarch64) ---
# 注意路径中的 aarch64
echo "正在下载 ARM 版本..."
wget -O arm-docker-$VERSION.tgz \
  https://download.docker.com/linux/static/stable/aarch64/$TGZ_NAME \
  --no-check-certificate

# --- AMD 版本 (x86_64) ---
# 注意路径中的 x86_64
echo "正在下载 AMD 版本..."
wget -O amd-docker-$VERSION.tgz \
  https://download.docker.com/linux/static/stable/x86_64/$TGZ_NAME \
  --no-check-certificate

echo "检查下载结果:"
ls -lh *-docker-$VERSION.tgz
