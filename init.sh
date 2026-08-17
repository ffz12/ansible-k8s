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

# ---------------------------------------------------------------------------
#  安装 pre-commit 钩子: 拦住明文密码 / 私钥进库
#  .git/hooks 不受版本控制, 所以钩子源文件放在 scripts/git-hooks/, 这里装进去。
#  每次跑 init.sh 都会覆盖安装(保证是最新版); 不想要就 git config qdlt.skipSecretScan true
# ---------------------------------------------------------------------------
if [ -d .git ] && [ -f scripts/git-hooks/pre-commit ]; then
    HOOKDIR="$(git rev-parse --git-path hooks 2>/dev/null || echo .git/hooks)"
    mkdir -p "$HOOKDIR"
    if cp scripts/git-hooks/pre-commit "$HOOKDIR/pre-commit" 2>/dev/null; then
        chmod +x "$HOOKDIR/pre-commit"
        echo -e "${GREEN}[成功]${NC} 已安装 pre-commit 钩子 (拦明文密码/私钥进库)"
    else
        echo -e "${RED}[警告]${NC} pre-commit 钩子安装失败, 请手工: cp scripts/git-hooks/pre-commit $HOOKDIR/ && chmod +x $HOOKDIR/pre-commit"
    fi
fi

echo "初始化完成。请根据实际环境修改 inventory/ 目录下的配置文件。"

# 青岛联通交付项目额外提醒: 密码走环境变量, GPU 节点要逐台填 SU 号
if [ -d playbook/roles/qdlt-init ]; then
    echo
    echo -e "${RED}[待办]${NC} 跑青岛联通交付(qdlt-*)前还需要:"
    echo "  vim inventory/hosts                # 填 [qdlt_cpu]/[qdlt_gpu]; GPU 必须逐台填 qdlt_su"
    echo "  export QDLT_USER_PASSWORD='密码'   # 统一登录账号 wwxq 的密码, 不落文件"
    echo
    echo "  密码走【环境变量】, 不再有 secrets 文件 —— 不落盘、不进 git。"
    echo "  ${RED}别用 sudo ansible-playbook${NC} —— sudo 默认清环境变量, 密码会取不到。"
    echo "  playbook 自带 become: yes, 普通用户直接跑即可; 非要 sudo 就用 sudo -E。"
    # 历史遗留: 旧版 init.sh 生成过 secrets 文件, 里面是明文密码, 提醒删掉
    if [ -f inventory/qdlt-secrets.yml ]; then
        echo
        echo -e "${RED}[清理]${NC} 发现旧版遗留的 inventory/qdlt-secrets.yml(明文密码)。"
        echo "  现在密码走环境变量, 该文件已不再使用, 建议删除:"
        echo "    rm inventory/qdlt-secrets.yml"
        echo "  ⚠ 它在 inventory/ 目录下, ansible 会把它当 YAML inventory 一并解析(留着有副作用)。"
        if git -C . ls-files --error-unmatch inventory/qdlt-secrets.yml >/dev/null 2>&1; then
            echo -e "  ${RED}[严重]${NC} 且它已被 git 跟踪! 明文密码进库了。"
            echo "    git rm --cached inventory/qdlt-secrets.yml && git commit"
        fi
    fi
fi
