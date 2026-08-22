#!/bin/bash
# ⚠ 不用 ANSI 颜色: 重定向/不认转义的终端里会变乱码, 靠 [成功]/[跳过]/[待办] 标签区分。

echo "开始初始化项目配置文件..."

# 源文件:目标文件 (已存在则跳过, 不覆盖已填好的配置)
files=(
    "./tmp/hosts.example:inventory/hosts"
    "./tmp/env.yaml.example:inventory/group_vars/all/env.yaml"
)

for pair in "${files[@]}"; do
    SRC="${pair%%:*}"; DST="${pair##*:}"
    [ -f "$SRC" ] || { echo "[错误] 找不到模板: $SRC"; continue; }
    mkdir -p "$(dirname "$DST")"
    if [ -f "$DST" ]; then
        # 模板新增的变量老文件不会有, 需要时自己比: diff "$DST" "$SRC"
        echo "[跳过] $DST 已存在, 不覆盖。"
    else
        cp "$SRC" "$DST"; echo "[成功] 已生成 $DST"
    fi
done

# 安装 pre-commit 钩子 (拦明文密码/私钥进库)。每次覆盖安装, 改钩子要改 scripts/git-hooks/
# 那份(否则下次被冲掉); 不想要: git config secretscan.skip true
if [ -d .git ] && [ -f scripts/git-hooks/pre-commit ]; then
    HOOKDIR="$(git rev-parse --git-path hooks 2>/dev/null || echo .git/hooks)"
    mkdir -p "$HOOKDIR"
    if cp scripts/git-hooks/pre-commit "$HOOKDIR/pre-commit" 2>/dev/null; then
        chmod +x "$HOOKDIR/pre-commit"
        echo "[成功] 已安装 pre-commit 钩子"
    else
        echo "[警告] 钩子安装失败, 手工: cp scripts/git-hooks/pre-commit $HOOKDIR/ && chmod +x $HOOKDIR/pre-commit"
    fi
fi

echo "初始化完成。请按实际环境修改 inventory/ 下的配置。"

# os-init 待办提醒
if [ -d playbook/roles/os-init ]; then
    cat <<'TIP'

[待办] 跑 os-init / os-account 前:
  vim inventory/hosts                    # 机器写进 [cluster]; 有 GPU 单列 [gpu] 并逐台填 osinit_su
  vim inventory/group_vars/all/env.yaml  # ①连接(未免密才填 bootstrap_*) ②osacct_user_password(账号名默认 osadmin, 青岛 wwxq) ③离线置 is_offline: true

  密码只写一处: env.yaml 优先级 > 角色默认; 走 export OSACCT_USER_PASSWORD 时别用 sudo(会清环境变量), 用 sudo -E。
TIP
fi
