#!/bin/bash
# keepalived 的 vrrp_script —— 判断【本机】的 apiserver 入口是否可用。
# 由 roles/haproxy-ha 渲染, 端口随 lb_proxy 变:
#   lb_proxy=haproxy          -> {{ apiserver_lb_port }}(haproxy 前端)
#   lb_proxy=keepalived-only  -> {{ apiserver_port }}(apiserver 自己)
#
# 为什么探 127.0.0.1 而不是 VIP: keepalived 要判断的是"本机这个服务好不好", 据此决定自己
# 该不该持 VIP。探 VIP 只能反映当前持有者的状态 —— 本机没持 VIP 时探到的是别人, 逻辑上错。
#
# 为什么用 HTTP 探测而不是看端口在听:
#   ss/nc 只能确认 socket 绑上了。apiserver 卡死时内核照样 accept 连接 -> 端口"在听"但服务
#   已不可用, 而这恰恰是 HA 要切走的场景。原 check_haproxy.sh 更弱: 它是
#   `ss -lntp | grep -q haproxy`, 只看【进程名】—— 8443 前端绑失败但 1080 stats 起来了也算通过。
#   curl 走完整路径: haproxy 模式下同时验证 haproxy 与"至少一个后端 apiserver 可达"。
#
# /livez 默认允许匿名访问(system:public-info-viewer)。但即使返回 401/403 也说明 apiserver
# 在应答 —— 本脚本因此只要拿到【任何 HTTP 状态码】就算通过, 不校验状态码内容。
#
# ⚠ 退化路径: curl 不存在时(某些精简发行版)回落到看端口在听。那样探不出"卡死但在听",
#   属于已知弱化 —— 只在 curl 缺失时发生, 不是默认路径。
#   注意只有"curl 这个命令不存在"才回落; curl 存在但探测失败【不】回落(否则会把真实故障
#   掩盖成健康)。

set -u
PORT="{{ _lb_entry_port }}"

if command -v curl >/dev/null 2>&1; then
    # ⚠ 不要写 `|| echo 000`: curl 连不上时 -w '%{http_code}' 【自己就输出 000】, 再叠一个
    #   echo 000 会拼成 "000000"。配上原先反向的判断 `[ "$code" != "000" ]`, 000000 != 000
    #   为真 -> apiserver 已死却报告健康。2026-09-16 现网 cpu200 上实测踩到(apiserver 停了,
    #   脚本仍 exit=0, VIP 不漂)。
    # ⚠ 判断改为【正向匹配三位 HTTP 状态码】而非反向排除某个值: 反向排除只挡得住你想到的
    #   那一种坏值(000), 挡不住 000000 / 空串 / curl 的错误文本; 正向匹配则只有真拿到状态码
    #   才算通过。
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 2 \
            "https://127.0.0.1:${PORT}/livez" 2>/dev/null)"
    case "$code" in
        [1-5][0-9][0-9]) exit 0 ;;   # 200/401/403/500... 都算在应答
        *)               exit 1 ;;   # 000(连不上) / 空 / 任何非状态码
    esac
fi

# curl 缺失时的退化路径
if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | grep -q ":${PORT} " && exit 0
    exit 1
fi

# 连 ss 都没有: 用 bash 的 /dev/tcp 兜底
timeout 2 bash -c "true </dev/tcp/127.0.0.1/${PORT}" 2>/dev/null && exit 0
exit 1
