#!/bin/bash

# 定义颜色，方便报错提示
RED='[0;31m'
GREEN='[0;32m'
NC='[0m' # No Color

echo "开始初始化项目配置文件..."

# 定义需要初始化的文件对 (源文件:目标文件)
# 注: hosts.example 里已含青岛联通交付用的 [qdlt_cpu]/[qdlt_gpu] 分组, 不另发模板。
files=(
    "./tmp/hosts.example:inventory/hosts"
    "./tmp/env.yaml.example:inventory/group_vars/all/env.yaml"
    "./tmp/qdlt-secrets.yml.example:inventory/qdlt-secrets.yml"
)

for pair in "${files[@]}"; do
    SRC="${pair%%:*}"
    DST="${pair##*:}"

    if [ ! -f "$SRC" ]; then
        echo -e "${RED}[错误]${NC} 找不到模板文件: $SRC"
        continue
    fi

    mkdir -p "$(dirname "$DST")"

    if [ -f "$DST" ]; then
        echo -e "[跳过] $DST 已经存在，不会覆盖。"
    else
        cp "$SRC" "$DST"
        echo -e "${GREEN}[成功]${NC} 已生成 $DST"
    fi
done

# 体检报告落地目录(qdlt-check 生成 md/csv), 已在 .gitignore 中排除
if [ ! -d reports ]; then
    mkdir -p reports
    echo -e "${GREEN}[成功]${NC} 已创建 reports/"
else
    echo -e "[跳过] reports/ 已经存在。"
fi

echo "初始化完成。请根据实际环境修改 inventory/ 目录下的配置文件。"

# 青岛联通交付项目额外提醒: 密码文件必须加密, 且 GPU 节点要逐台填 SU 号
if [ -f inventory/qdlt-secrets.yml ] && ! head -1 inventory/qdlt-secrets.yml | grep -q '^\$ANSIBLE_VAULT'; then
    echo
    echo -e "${RED}[待办]${NC} 跑青岛联通交付(qdlt-*)前还需要:"
    echo "  vim inventory/hosts                          # 填 [qdlt_cpu]/[qdlt_gpu]; GPU 必须逐台填 qdlt_su"
    echo "  vim inventory/qdlt-secrets.yml               # 填统一登录账号 wwxq 的密码"
    echo "  ansible-vault encrypt inventory/qdlt-secrets.yml   # ⚠ 明文密码不得入库"
fi
