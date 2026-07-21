#!/bin/bash

# 定义颜色，方便报错提示
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "开始初始化项目配置文件..."

# 定义需要初始化的文件对 (源文件:目标文件)
files=(
    "./tmp/hosts.example:inventory/hosts"
    "./tmp/env.yaml.example:inventory/group_vars/all/env.yaml"
)

for pair in "${files[@]}"; do
    SRC="${pair%%:*}"
    DST="${pair##*:}"

    if [ ! -f "$SRC" ]; then
        echo -e "${RED}[错误]${NC} 找不到模板文件: $SRC"
        continue
    fi

    if [ -f "$DST" ]; then
        echo -e "[跳过] $DST 已经存在，不会覆盖。"
    else
        cp "$SRC" "$DST"
        echo -e "${GREEN}[成功]${NC} 已生成 $DST"
    fi
done

echo "初始化完成。请根据实际环境修改 inventory/ 目录下的配置文件。"
