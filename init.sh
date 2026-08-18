#!/bin/bash

# ⚠ 不用 ANSI 颜色 —— 原来定义了 RED/GREEN/NC, 靠 echo -e 输出, 但漏 -e 的那一行
#   会打出字面的转义码; 而且 tee/重定向到文件、以及不认转义的终端里全是乱码。
#   靠 [成功]/[跳过]/[待办]/[警告] 这些方括号标签区分就够了, 不依赖终端能力。

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
        echo "[错误] 找不到模板文件: $SRC"
        continue
    fi

    mkdir -p "$(dirname "$DST")"

    if [ -f "$DST" ]; then
        echo "[跳过] $DST 已经存在，不会覆盖。"
        # ⚠ 「已存在就跳过」是对的(不能覆盖别人填好的配置), 但副作用是:
        #   模板【后来新增】的变量, 老环境的 env.yaml 里永远不会有。
        #   qdlt_user_password 就是这么一个 —— 它是后加的, 老 env.yaml 里没有,
        #   人照着提示去 vim 会找不到那一行, 以为哪里出错了。这里明确指出来。
        if [ "$DST" = "inventory/group_vars/all/env.yaml" ] \
           && ! grep -q 'qdlt_user_password' "$DST" 2>/dev/null \
           && grep -q 'qdlt_user_password' "$SRC" 2>/dev/null; then
            echo "  ⚠ 这份 env.yaml 是旧版生成的, 里面【没有】qdlt_user_password 那一段。"
            echo "    跑 qdlt-init 前手工加一行(和已有的 harbor_admin_password 放一起即可):"
            echo "      qdlt_user_password: '统一登录密码'"
            echo "    完整说明见 tmp/env.yaml.example 末尾的「统一登录密码」一节。"
        fi
    else
        cp "$SRC" "$DST"
        echo "[成功] 已生成 $DST"
    fi
done

# 体检报告落地目录(qdlt-check 生成 md/csv), 已在 .gitignore 中排除
if [ ! -d reports ]; then
    mkdir -p reports
    echo "[成功] 已创建 reports/"
else
    echo "[跳过] reports/ 已经存在。"
fi

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
    echo "  vim inventory/hosts                        # 填 [qdlt_cpu]/[qdlt_gpu]; GPU 必须逐台填 qdlt_su"
    echo "  vim inventory/group_vars/all/env.yaml      # 取消注释填 qdlt_user_password(统一账号 wwxq 的密码)"
    echo
    echo "  密码就写在 env.yaml 里, 和已有的 harbor_admin_password / bootstrap_ssh_pass 放一处 ——"
    echo "  该文件已 gitignore 不入库, 配好之后直接跑, 不用每次 export:"
    echo "    ansible-playbook playbook/qdlt-init.yaml"
    echo
    echo "  不想让密码落到任何文件时, 也可以改走环境变量(角色默认值就是取它):"
    echo "    export QDLT_USER_PASSWORD='密码'"
    echo "    ⚠ 别用 sudo ansible-playbook —— sudo 默认清环境变量, 密码会取不到。"
    echo "      playbook 自带 become: yes, 普通用户直接跑即可; 非要 sudo 就用 sudo -E。"
    echo "  ⚠ 两处只写一处 —— env.yaml 优先级高于角色默认值, 都写时环境变量【永远不生效】。"
    # 历史遗留: 旧版 init.sh 生成过 secrets 文件, 里面是明文密码, 提醒删掉
    if [ -f inventory/qdlt-secrets.yml ]; then
        echo
        echo "[清理] 发现旧版遗留的 inventory/qdlt-secrets.yml(明文密码)。"
        echo "  现在密码写在 env.yaml 里(或走环境变量), 该文件已不再使用, 建议删除:"
        echo "    rm inventory/qdlt-secrets.yml"
        echo "  ⚠ 它在 inventory/ 目录下, ansible 会把它当 YAML inventory 一并解析(留着有副作用)。"
        if git -C . ls-files --error-unmatch inventory/qdlt-secrets.yml >/dev/null 2>&1; then
            echo "  [严重] 且它已被 git 跟踪! 明文密码进库了。"
            echo "    git rm --cached inventory/qdlt-secrets.yml && git commit"
        fi
    fi
fi
