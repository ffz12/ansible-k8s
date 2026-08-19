#!/bin/bash

# ⚠ 不用 ANSI 颜色 —— tee/重定向到文件、以及不认转义的终端里全是乱码, 漏写 echo -e
#   的那行还会打出字面转义码。靠 [成功]/[跳过]/[待办]/[警告] 方括号标签区分就够了。

echo "开始初始化项目配置文件..."

# 定义需要初始化的文件对 (源文件:目标文件)
# 注: hosts.example 里机器写在 [cluster], [qdlt:children] 引用它, 不另发模板。
files=(
    "./tmp/hosts.example:inventory/hosts"
    "./tmp/env.yaml.example:inventory/group_vars/all/env.yaml"
)

for pair in "${files[@]}"; do
    SRC="${pair%%:*}"
    DST="${pair##*:}"

    if [ ! -f "$SRC" ]; then
        echo "[错误] 找不到模板文件: $SRC"
        continue
    fi

    mkdir -p "$(dirname "$DST")"

    if [ -f "$DST" ]; then
        echo "[跳过] $DST 已经存在，不会覆盖。"
        # ⚠ 「已存在就跳过」是对的(不能覆盖别人填好的配置), 但副作用是: 模板
        #   【后来新增】的变量, 老环境的这份文件里永远不会有。差异自己比一下:
        #     diff inventory/group_vars/all/env.yaml tmp/env.yaml.example
    else
        cp "$SRC" "$DST"
        echo "[成功] 已生成 $DST"
    fi
done

# ---------------------------------------------------------------------------
#  安装 pre-commit 钩子: 拦住明文密码 / 私钥进库
#  .git/hooks 不受版本控制, 所以钩子源文件放在 scripts/git-hooks/, 这里装进去。
#  每次跑 init.sh 都会覆盖安装(保证是最新版); 不想要就 git config qdlt.skipSecretScan true
#  ⚠ 覆盖安装意味着: 手工改了 .git/hooks/pre-commit 而没同步回 scripts/git-hooks/,
#    下次跑 init.sh 就会被冲掉。改钩子必须改 scripts/git-hooks/ 那份。
# ---------------------------------------------------------------------------
if [ -d .git ] && [ -f scripts/git-hooks/pre-commit ]; then
    HOOKDIR="$(git rev-parse --git-path hooks 2>/dev/null || echo .git/hooks)"
    mkdir -p "$HOOKDIR"
    if cp scripts/git-hooks/pre-commit "$HOOKDIR/pre-commit" 2>/dev/null; then
        chmod +x "$HOOKDIR/pre-commit"
        echo "[成功] 已安装 pre-commit 钩子 (拦明文密码/私钥进库)"
    else
        echo "[警告] pre-commit 钩子安装失败, 请手工: cp scripts/git-hooks/pre-commit $HOOKDIR/ && chmod +x $HOOKDIR/pre-commit"
    fi
fi

echo "初始化完成。请根据实际环境修改 inventory/ 目录下的配置文件。"

# 青岛联通交付项目额外提醒: 密码写在 env.yaml 里, GPU 节点要逐台填 SU 号
if [ -d playbook/roles/qdlt-init ]; then
    echo
    echo "[待办] 跑青岛联通交付(qdlt-*)前还需要:"
    echo "  vim inventory/hosts                        # 填 [cluster] 节点; GPU 必须逐台填 qdlt_su"
    echo "  vim inventory/group_vars/all/env.yaml      # 取消注释填 qdlt_user_password(统一账号 wwxq 的密码)"
    echo
    echo "  该文件已 gitignore 不入库, 和已有的 harbor_admin_password 放一处, 配好直接跑:"
    echo "    ansible-playbook playbook/qdlt-init.yaml"
    echo "  ⚠ 也可以走 export QDLT_USER_PASSWORD='密码', 但两处【只写一处】——"
    echo "    env.yaml 优先级高于角色默认值, 都写时环境变量永远不生效。"
    echo "    走环境变量时别用 sudo(会清环境变量), playbook 自带 become: yes。"
fi
