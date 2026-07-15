#!/bin/bash

user=$1
# 生成随机密码（8字符，包含大小写字母、数字和特殊符号）
generate_password() {
    chars="ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz123456789!@#$%^&*()_+"
    password=$(cat /dev/urandom | tr -dc "$chars" | head -c 12)

    # 检查密码复杂度
    while true; do
        if echo "$password" | grep -q '[A-Z]' && \
           echo "$password" | grep -q '[a-z]' && \
           echo "$password" | grep -q '[0-9]' && \
           echo "$password" | grep -q '[!@#$%^&*()_+]'; then
            break
        else
            password=$(cat /dev/urandom | tr -dc "$chars" | head -c 12)
        fi
    done

    echo "$password"
}

# 设置 root 密码（绕过 cracklib 检查）
set_root_password() {
    local new_password="$1"
    echo "$user:$new_password" | sudo chpasswd --crypt-method SHA512
    echo "$user 密码已更新！"
}

# 主程序
main() {
    echo "正在生成随机密码..."
    new_password=$(generate_password)
    echo "生成的密码: $new_password"
    set_root_password "$new_password"
    echo "请务必保存此密码，因为它是 $user 账户的登录凭证！"
}

main

