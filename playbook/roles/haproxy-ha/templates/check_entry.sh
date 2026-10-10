#!/bin/bash
# keepalived 健康检查: 本机 apiserver 入口是否可用(由 roles/haproxy-ha 渲染)。
#   lb_proxy=haproxy          -> 探 {{ apiserver_lb_port }}(haproxy 前端)
#   lb_proxy=keepalived-only  -> 探 {{ apiserver_port }}(apiserver 自己)
# 探 127.0.0.1 不探 VIP: 要判断的是本机该不该持 VIP。
# 用 HTTP 探 /livez 而不是看端口: 服务卡死时端口照样在听。拿到任何 HTTP 状态码都算通过
# (401/403 也说明 apiserver 在应答)。curl 不存在时才退回看端口。

set -u
PORT="{{ _lb_entry_port }}"

{% if (lb_vrrp_preempt_mode | default('delay')) == 'nopreempt' and ('k8s_master' in group_names or 'k8s_node' in group_names) %}
# 冷启动兜底: nopreempt 下检查失败会进 FAULT, 建集群时 apiserver 还不存在, 不放行就没人持 VIP、
# 集群建不出来。kubelet.conf 不存在 = 还没 join 过 = 建集群阶段, 直接放行。
# 只对 master/worker 渲染: 独立 LB 节点永远没有 kubelet.conf, 会永久放行(tasks 里已拦下这种组合)。
if [ ! -f /etc/kubernetes/kubelet.conf ]; then
    exit 0
fi
{% endif %}

if command -v curl >/dev/null 2>&1; then
    # 别写 `|| echo 000`: 连不上时 curl 自己就输出 000, 再拼会变成 000000。
    # 正向匹配三位状态码, 只有真拿到状态码才算通过。
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
