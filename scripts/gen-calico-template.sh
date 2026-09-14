#!/usr/bin/env bash
# =============================================================================
#  gen-calico-template.sh —— 从上游官方 manifest 生成 calico.yaml.j2
#
#  为什么要这个脚本:
#    calico.yaml.j2 是 7400+ 行 vendored 上游 manifest, 只在 5 处做了参数化。
#    升级版本时"只改镜像 tag"会漏掉上游新增的 CRD 与 ClusterRole 规则 ——
#    3.27 -> 3.31 那次就漏了 9 个 CRD、2 条 ClusterRole 规则, 症状是 felix 反复
#      cannot list resource ... forbidden  -> readiness 503 -> calico-node 起不来。
#    残留到现在还被发现一条: policy.networking.k8s.io 那条只补了
#    adminnetworkpolicies/baselineadminnetworkpolicies, 漏了 clusternetworkpolicies;
#    kubevirt.io 那条整条没有。手工比对 7400 行不可靠, 故脚本化。
#
#  用法:
#    scripts/gen-calico-template.sh 3.32.2              # 生成并 diff, 不覆盖
#    scripts/gen-calico-template.sh 3.32.2 --apply      # 通过检查后覆盖模板
#    scripts/gen-calico-template.sh 3.32.2 --from /path/to/calico.yaml   # 用本地文件(离线)
#
#  做什么:
#    1. 取上游 v<版本> 的 manifest(curl 或 --from 指定本地文件)
#    2. 施加 5 处参数化(镜像 x3 / 封装模式 / bandwidth / NO_DEFAULT_POOLS / IP 自动探测)
#    3. 与现有模板做结构化 diff: 按 kind+name 比对资源清单, 单独列出
#       CRD 增减、各 ClusterRole 的 rules 增减 —— 这两类是历史上真正踩过的坑
#    4. 校验生成结果: Jinja 能渲染 + 渲染后是合法 YAML + 5 处参数化都在
#
#  ⚠ 不自动改 calico_version。确认 diff 无异常后, 自己改 env.yaml 的 calico_version,
#    并确保离线物料里有该版本的镜像(offline/artifacts/cni/calico/v<版本>/)。
# =============================================================================
set -euo pipefail

VER="${1:-}"
APPLY=0
FROM=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --from)  shift; FROM="${1:-}" ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$VER" ]; then
  echo "用法: $0 <calico 版本, 如 3.32.2> [--apply] [--from /path/to/calico.yaml]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 解释器探测: 交付机是 python3; 某些开发机(Windows/Git-Bash)只有 python。
# 同时校验 yaml / jinja2 可用 —— 缺了后面三段 python 都跑不了。
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml, jinja2' >/dev/null 2>&1; then
    PY="$c"; break
  fi
done
if [ -z "$PY" ]; then
  echo "❌ 找不到带 pyyaml + jinja2 的 python。装一下再跑:" >&2
  echo "     pip3 install pyyaml jinja2      # 或 apt install python3-yaml python3-jinja2" >&2
  exit 1
fi
# 模板【按版本存放】(2026-09-11 改): templates/calico/<版本>.yaml.j2
# 原先是单一 calico.yaml.j2, 一份入库模板只能服务一个版本, 导致所有站点必须同时换版本
# (详见 roles/cni/tasks/calico.yaml 里那段说明)。现在每个版本一个文件, 互不影响。
TPL_DIR="$REPO_ROOT/playbook/roles/cni/templates/calico"
TPL="$TPL_DIR/${VER}.yaml.j2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UPSTREAM="$WORK/upstream.yaml"
GENERATED="$WORK/generated.j2"

# diff 的基准: 目标版本已存在就跟它自己比(重新生成同版本, 应无差异);
# 不存在(新增版本)就跟【现有最高版本】比 —— 那才是"这次升级改了什么"的有效信息。
# 一个都没有时跳过 diff。sort -V 按版本号排序(GNU coreutils, 交付机有)。
mkdir -p "$TPL_DIR"
if [ -f "$TPL" ]; then
  DIFF_BASE="$TPL"
  DIFF_BASE_VER="$VER"
else
  DIFF_BASE_VER="$(ls -1 "$TPL_DIR" 2>/dev/null | sed -n 's/\.yaml\.j2$//p' | sort -V | tail -1)"
  if [ -n "$DIFF_BASE_VER" ]; then
    DIFF_BASE="$TPL_DIR/${DIFF_BASE_VER}.yaml.j2"
  else
    DIFF_BASE=""
  fi
fi

# ---------- 1. 取上游 manifest ----------
if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || { echo "❌ --from 指定的文件不存在: $FROM" >&2; exit 1; }
  cp "$FROM" "$UPSTREAM"
  echo "[1/4] 使用本地 manifest: $FROM"
else
  URL="https://raw.githubusercontent.com/projectcalico/calico/v${VER}/manifests/calico.yaml"
  echo "[1/4] 下载上游 manifest: $URL"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$UPSTREAM" "$URL" || {
    echo "❌ 下载失败。离线环境请先在有网机器上取到文件, 再用 --from 指定:" >&2
    echo "     curl -O $URL" >&2
    echo "     scripts/gen-calico-template.sh $VER --from ./calico.yaml" >&2
    exit 1
  }
fi
echo "     上游 $(wc -l < "$UPSTREAM") 行"

# ---------- 2. 施加 5 处参数化 ----------
echo "[2/4] 施加参数化"
"$PY" - "$UPSTREAM" "$GENERATED" "$VER" <<'PYEOF'
import re, sys
src, dst, ver = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding='utf-8').read()
counts = {}

# 上游是否【自带】conflist 里的 bandwidth 段: 3.28~3.31 有, 3.32.2 起上游删了。
# 宽松子串判断(不看缩进/字段写法), 只用来决定下面 (e) 那处参数化是否为必需项:
#   有 -> 严格正则必须命中; 命不中说明结构变了, 必须停(见 (e) 处注释)
#   无 -> 本就没东西要包, 期望置 0, 不再误报"未命中"
HAS_UPSTREAM_BANDWIDTH = '"type": "bandwidth"' in text

def sub(pat, repl, key, flags=0):
    global text
    text, n = re.subn(pat, repl, text, flags=flags)
    counts[key] = counts.get(key, 0) + n

# (a) 三处镜像 -> calico_images.*
#     上游形如:  image: docker.io/calico/cni:v3.32.2
for short, var in (('cni', 'cni'), ('node', 'node'), ('kube-controllers', 'kube_controllers')):
    sub(r'(?m)^(\s*image:\s*)\S*calico/%s:\S+\s*$' % re.escape(short),
        lambda m, v=var: '%s{{ calico_images.%s }}' % (m.group(1), v),
        'image:'+short)

# (b) 封装模式: CALICO_IPV4POOL_IPIP / _VXLAN 的 value 由 calico_encapsulation 派生
IPIP_EXPR = ("\"{{ 'Always' if calico_encapsulation | default('none') == 'ipip' "
             "else ('CrossSubnet' if calico_encapsulation | default('none') == 'crosssubnet' else 'Never') }}\"")
VXLAN_EXPR = "\"{{ 'Always' if calico_encapsulation | default('none') == 'vxlan' else 'Never' }}\""
sub(r'(?ms)(- name: CALICO_IPV4POOL_IPIP\n\s*value:\s*)"[^"]*"',
    lambda m: m.group(1) + IPIP_EXPR, 'CALICO_IPV4POOL_IPIP')
sub(r'(?ms)(- name: CALICO_IPV4POOL_VXLAN\n\s*value:\s*)"[^"]*"',
    lambda m: m.group(1) + VXLAN_EXPR, 'CALICO_IPV4POOL_VXLAN')

# (c) IP_AUTODETECTION_METHOD: 上游默认没有这一项, 插在 `- name: IP` / value: "autodetect" 之后
AUTODETECT_BLOCK = '''\\g<0>
            # 用哪种方式自动探测本机 IP(BGP 对端地址 / 隧道源地址)。
            # 默认 first-found = calico 上游默认: 按网卡顺序取第一个非本地地址 ——
            #   多网卡机器上很容易挑错(挑到管理网/存储网), 表现为跨节点 Pod 不通或
            #   走错网卡跑流量, 而 kubelet 那层已用 kube_node_ip 钉成 ansible_host,
            #   两层不一致时排查很费劲。
            # 多网卡站点建议在 env.yaml 设 calico_ip_autodetection_method: kubernetes-internal-ip
            #   —— 直接跟随 Node 的 InternalIP(= kubelet 上报的那个), 两层自动对齐。
            # 其它可选: interface=bond0 / can-reach=<网关IP> / cidr=10.14.64.0/24
            # ⚠ 改这个会让 calico-node 重启并重新选址; 已跑的集群若当前挑对了就别动。
            - name: IP_AUTODETECTION_METHOD
              value: "{{ calico_ip_autodetection_method | default('first-found') }}"'''
sub(r'(?m)^\s*- name: IP\n\s*value:\s*"autodetect"$', AUTODETECT_BLOCK, 'IP_AUTODETECTION_METHOD')

# (d) NO_DEFAULT_POOLS: 双池模式下阻止 calico-node 自建默认池。
#     插在被注释掉的 CALICO_IPV4POOL_CIDR 之后(上游那两行是注释)
NODEFAULT_BLOCK = '''\\g<0>
{% if calico_dual_ippool_enabled | default(false) | bool %}
            # 双 IPPool 模式: 分池由 calico-ippools.yaml.j2 里那两个 IPPool 资源接管
            # (单独 apply, 因为 CRD 与引用它的 CR 同文件会撞 apiserver 异步注册竞态),
            # 这里阻止 calico-node 启动时按 podSubnet 再自建默认池(否则会和那两个池冲突/抢占)。
            - name: NO_DEFAULT_POOLS
              value: "true"
{% endif %}'''
sub(r'(?m)^\s*#\s*-\s*name:\s*CALICO_IPV4POOL_CIDR\n\s*#\s*value:\s*"[^"]*"$',
    NODEFAULT_BLOCK, 'NO_DEFAULT_POOLS')

# (e) conflist 的 bandwidth 段: 上游 3.28~3.31 默认写了这段, 但 calico-cni 镜像不含该
#     插件二进制(它属于 containernetworking/plugins), 裸着写进去会让全节点 Pod 建不了
#     sandbox。故用 calico_enable_bandwidth(默认 false)把它包起来。
#     3.32.2 起上游【自己删掉了这段】—— 那时无需包装, 跳过即可(HAS_UPSTREAM_BANDWIDTH=False)。
if HAS_UPSTREAM_BANDWIDTH:
    sub(r'(?ms)(\}),\n(\s*\{\n\s*"type": "bandwidth",\n\s*"capabilities": \{"bandwidth": true\}\n\s*\})',
        lambda m: '%s{%% if calico_enable_bandwidth | default(false) | bool %%},\n%s{%% endif %%}'
                  % (m.group(1), m.group(2)), 'bandwidth')

# ---------------------------------------------------------------------------
# (f) 注入踩坑注释。
#
# 为什么需要: 本脚本是"上游 manifest -> 模板"的纯生成器, 生成结果里【只有上游的注释】。
# 而某些 RBAC 规则为什么必须存在, 是我们踩坑踩出来的知识(见下面每条的 why), 上游注释
# 一个字都不会提。历史上这些说明是【手工写在模板里】的, 于是每次 --apply 就被冲掉一次,
# 下个人重新踩坑或重新怀疑。改成由脚本注入: 生成多少次都在, 且随上游变化自动跟随。
#
# 匹配策略: 按 apiGroups 行定位, 把注释插在它【前面】。
#   · 上游删了对应规则 -> 匹配不到 -> 该条注释不注入(不报错)。这是有意的: 规则都没了,
#     注释留着只会误导。ANP/BANP 在 3.32.2 就是这个情况。
#   · 不校验 verbs/resources 细节 —— 上游可能扩权(3.32.2 给 kubevirt 那条加了 get),
#     注释讲的是"为什么要有这条规则", 与具体 verb 无关。
# 每条都不计入 expect(不是参数化点), 只在下面单独打印命中情况, 便于发现"上游改结构了"。
NOTES = [
    ('note:policy.networking',
     r'(?m)^(\s*)(- apiGroups: \["policy\.networking\.k8s\.io"\])',
     '''# ⚠ 这条(尤其 clusternetworkpolicies)曾整条漏掉 —— 与本文件头部提到的
# 9 个 CRD/2 条 ClusterRole 规则是同一次遗漏。现象:
#   felix 反复 "cannot list resource clusternetworkpolicies ... forbidden"
#   -> Connection to datastore has failed -> CalculationGraph 永远 not ready
#   -> readiness 503, calico-node 一直 NotReady, 整个集群没网络。
# 即便集群里【没有】该 CRD 也必须授权: felix 无条件 watch 它, 拿不到权限就报
# forbidden; 而 CRD 不存在只会返回空列表(不报错)。所以不能"没装就不授权"。
# 注: 3.32.2 起上游删了 adminnetworkpolicies/baselineadminnetworkpolicies 两个 CRD
#     及其授权(CRD 与 RBAC 一起删, 自洽), 只保留 clusternetworkpolicies。'''),
    # ⚠ kubevirt.io 在 3.32.2 里出现 3 次(另两处是 VM/VMI 的 IPAM 垃圾回收, 语义不同),
    #   所以必须用 lookahead 限定"紧跟的 resources 块里含 virtualmachineinstancemigrations",
    #   否则注释会被插到无关的两处上。resources 顺序不固定, 故扫到 verbs 之前都算。
    ('note:kubevirt',
     r'(?m)^(\s*)(- apiGroups: \["kubevirt\.io"\])'
     r'(?=(?:\n\s*(?:resources:|-\s+\w+))*?\n\s*-\s+virtualmachineinstancemigrations\b)',
     '''# KubeVirt: 虚拟机热迁移期间 felix 需要感知迁移状态。未装 KubeVirt 时该 CRD 不
# 存在, 授权后 list 返回空, 不再刷 forbidden 噪音 —— 同上, 不能"没装就不授权"。
# 这条原本是我们手工补的, 3.32.2 起上游已自带(并多给了 get)。'''),
]
for key, pat, note in NOTES:
    def _ins(m, note=note):
        indent = m.group(1)
        body = '\n'.join(indent + ln for ln in note.split('\n'))
        return body + '\n' + m.group(1) + m.group(2)
    sub(pat, _ins, key)

HEADER = '''# =============================================================================
#  calico.yaml.j2 —— 由 Calico 官方 v%s manifest 对齐生成, 仅做以下参数化:
#    · 3 处镜像 -> calico_images.node/.cni/.kube_controllers(走自建 Harbor, 见 defaults.yaml)
#    · CALICO_IPV4POOL_IPIP / _VXLAN -> 由 env.yaml 的 calico_encapsulation 派生
#    · IP_AUTODETECTION_METHOD -> 由 calico_ip_autodetection_method 派生(默认 first-found)
#    · conflist 末尾的 bandwidth 段 -> 由 calico_enable_bandwidth 控制(默认 false)
#      【仅当上游自带该段时才有这处参数化】: 3.28~3.31 上游写了它, 3.32.2 起上游删了 ——
#      本模板若由 3.32.2+ 生成, conflist 里就没有 bandwidth, calico_enable_bandwidth
#      置 true 也不产生任何效果(不报错, 但也不限速)。要在 3.32.2+ 上做 Pod 限速,
#      得另行往 conflist 里加该段, 本脚本不做。
#      ⚠ calico-cni 镜像【不含】bandwidth 二进制: 该插件属于上游 containernetworking/plugins。
#        裸着写进 conflist 但没装插件 -> 全节点 Pod 建不了 sandbox:
#          plugin type="bandwidth" failed (add): failed to find plugin "bandwidth"
#        这正是 3.28~3.31 需要把它包进 if 的原因。需要限速时先让 kube-common 装
#        cni-plugins 包(见 cni_plugins_* 变量)再置 true。
#    · calico_dual_ippool_enabled(默认 false)-> 按硬件类型(GPU/CPU)分两个 IPPool。
#      关闭时行为不变: calico 用 CALICO_IPV4POOL_CIDR/podSubnet 自建单个默认池。
#      开启时: 加 NO_DEFAULT_POOLS=true, 分池由 calico-ippools.yaml.j2 那两个 IPPool
#      资源接管(单独 apply, 见 roles/cni/tasks/calico.yaml 的 CRD 竞态说明)。
#
#  另外注入两段【踩坑注释】(policy.networking.k8s.io / kubevirt.io 两条 RBAC 规则的
#  why)。它们讲的是"这条规则为什么必须存在", 上游注释一个字都不提, 而这类知识是踩坑
#  踩出来的。以前手工写在模板里, 每次重新生成就被冲掉一次; 现在由脚本注入, 生成多少
#  次都在。上游若删了对应规则, 该段注释自动不注入(规则都没了, 留着只会误导)。
#
#  ⚠ 本文件由 scripts/gen-calico-template.sh 生成, 【不要手工改】。
#    升级 calico 版本: scripts/gen-calico-template.sh <新版本> 先看 diff, 再 --apply。
#    手工只改镜像 tag 会漏掉上游新增的 CRD 与 ClusterRole 规则 —— 3.27->3.31 就因此
#    漏了 9 个 CRD、2 条 ClusterRole 规则, 导致 felix 反复
#    "cannot list resource ... forbidden" 而 readiness 503。
#
#  下面这行是【机器可读】的版本标记, roles/cni/tasks/calico.yaml 会 grep 它并与
#  env.yaml 的 calico_version 比对, 不一致就 fail —— 把"镜像版本与 manifest 版本错配"
#  这类静默故障变成部署时的显式报错。改版本请重跑本脚本, 不要手工改这一行。
# CALICO_TEMPLATE_VERSION=%s
# =============================================================================
''' % (ver, ver)

open(dst, 'w', encoding='utf-8', newline='').write(HEADER + text)

print('     参数化结果:')
expect = {'image:cni': 2, 'image:node': 2, 'image:kube-controllers': 1,
          'CALICO_IPV4POOL_IPIP': 1, 'CALICO_IPV4POOL_VXLAN': 1,
          'IP_AUTODETECTION_METHOD': 1, 'NO_DEFAULT_POOLS': 1,
          # bandwidth 是【条件必需】: 上游自带才要求命中(3.28~3.31), 上游没有就不该要求
          # (3.32.2 起)。写死成 1 会让 3.32.2 永远"未命中"而无法 --apply。
          'bandwidth': 1 if HAS_UPSTREAM_BANDWIDTH else 0}
bad = 0
for k, want in expect.items():
    got = counts.get(k, 0)
    if want == 0:
        flag = 'SKIP(上游无此段)'
    elif got >= 1:
        flag = 'OK'
    else:
        flag = '❌ 未命中'
        bad += 1
    print('       %-26s 替换 %d 处 (上游预期约 %d) %s' % (k, got, want, flag))

# 踩坑注释的注入情况: 【不计入 bad】, 也不 sys.exit ——
# 注释是"锦上添花", 上游删了对应规则时不注入才是正确行为(规则没了, 注释留着会误导)。
# 但要把命中数打出来, 否则"上游改了 apiGroups 写法导致注释静默丢失"没人会发现。
print('     踩坑注释注入:')
for key, _pat, _note in NOTES:
    got = counts.get(key, 0)
    print('       %-26s 注入 %d 处 %s' % (
        key, got, 'OK' if got >= 1 else '未注入(上游已无对应规则, 或写法变了 —— 请核对)'))

if bad:
    print('     ❌ 有 %d 处参数化未命中 —— 上游 manifest 结构可能变了, 需人工核对正则' % bad)
    sys.exit(3)
PYEOF

# ---------- 3. 结构化 diff ----------
if [ -z "$DIFF_BASE" ]; then
  echo "[3/4] 跳过结构化比对 —— 仓库里还没有任何版本的模板, 没有可比的基准"
else
  if [ "$DIFF_BASE_VER" = "$VER" ]; then
    echo "[3/4] 与同版本现有模板比对(重新生成 v$VER, 正常应无差异)"
  else
    echo "[3/4] 与现有最高版本 v$DIFF_BASE_VER 比对(CRD / ClusterRole rules 是重点)"
  fi
"$PY" - "$DIFF_BASE" "$GENERATED" <<'PYEOF'
import sys, re, yaml

def load(path):
    """把 .j2 里的 Jinja 去掉后按多文档解析; 双池块按'启用'展开以便比对完整资源集"""
    txt = open(path, encoding='utf-8').read()
    txt = re.sub(r'(?m)^\{%\s*(if|endif|else).*%\}\s*$', '', txt)   # 整行控制块
    txt = re.sub(r'\{%.*?%\}', '', txt, flags=re.S)                  # 行内控制块
    txt = re.sub(r'\{\{.*?\}\}', 'JINJA', txt, flags=re.S)           # 表达式 -> 占位
    out = {}
    for doc in yaml.safe_load_all(txt):
        if not doc or 'kind' not in doc:
            continue
        out[(doc['kind'], doc.get('metadata', {}).get('name', '?'))] = doc
    return out

old, new = load(sys.argv[1]), load(sys.argv[2])

def rules_of(d):
    s = set()
    for r in (d.get('rules') or []):
        for g in (r.get('apiGroups') or ['']):
            for res in (r.get('resources') or []):
                s.add('%s/%s [%s]' % (g or 'core', res, ','.join(sorted(r.get('verbs') or []))))
    return s

print()
print('     现有模板 %d 个资源, 新生成 %d 个' % (len(old), len(new)))

added   = sorted(set(new) - set(old))
removed = sorted(set(old) - set(new))

def show(title, items, mark):
    if not items:
        return
    print()
    print('     %s (%d):' % (title, len(items)))
    for kind, name in items:
        print('       %s %-34s %s' % (mark, kind, name))

show('新增资源', added, '+')
show('消失资源 ⚠ 需确认是上游删了还是正则漏了', removed, '-')

# CRD 单独强调 —— 历史上漏 CRD 是踩过的坑
crd_added   = [n for k, n in added if k == 'CustomResourceDefinition']
crd_removed = [n for k, n in removed if k == 'CustomResourceDefinition']
if crd_added or crd_removed:
    print()
    print('     ── CRD 变化(重点) ──')
    for n in crd_added:   print('       + %s' % n)
    for n in crd_removed: print('       - %s  ⚠' % n)

# ClusterRole rules 逐条对比 —— clusternetworkpolicies 那次就是这里漏的
print()
print('     ── ClusterRole 权限变化(重点) ──')
any_rule_change = False
for key in sorted(set(old) & set(new)):
    if key[0] != 'ClusterRole':
        continue
    a, b = rules_of(old[key]), rules_of(new[key])
    plus, minus = sorted(b - a), sorted(a - b)
    if plus or minus:
        any_rule_change = True
        print('       %s:' % key[1])
        for r in plus:  print('         + %s' % r)
        for r in minus: print('         - %s  ⚠(现有模板有、上游没有: 可能是我们补的, 别丢)' % r)
if not any_rule_change:
    print('       无变化')
PYEOF
fi

# ---------- 4. 校验生成结果 ----------
echo
echo "[4/4] 校验生成的模板(Jinja 渲染 + YAML 合法性)"
"$PY" - "$GENERATED" <<'PYEOF'
import sys, re, yaml
from jinja2 import Environment, FileSystemLoader
import os
path = sys.argv[1]
env = Environment(loader=FileSystemLoader(os.path.dirname(path)), keep_trailing_newline=True)
env.filters['bool'] = lambda v: v if isinstance(v, bool) else str(v).strip().lower() in ('true','yes','on','1')
env.filters['regex_replace'] = lambda s, p, r='': re.sub(p, r, str(s))

V = dict(calico_images={'cni':'h/calico-cni:v0','node':'h/calico-node:v0','kube_controllers':'h/calico-kc:v0'},
         calico_encapsulation='ipip', calico_enable_bandwidth=False,
         calico_ip_autodetection_method='interface=bond0',
         calico_dual_ippool_enabled=True, veth_mtu=1440)
ok = True
for dual in (True, False):
    V['calico_dual_ippool_enabled'] = dual
    try:
        out = env.get_template(os.path.basename(path)).render(**V)
        docs = [d for d in yaml.safe_load_all(out) if d]
        # 解析 DaemonSet 的 env 来数 —— 不能用 out.count(): 文件头注释里也提到这个名字,
        # 原始字符串计数会把注释算进去(自测时 dual=False 明明没渲染却数到 1)。
        nodefault = 0
        for d in docs:
            if d.get('kind') == 'DaemonSet' and d['metadata']['name'] == 'calico-node':
                for c in d['spec']['template']['spec'].get('containers', []):
                    for e in (c.get('env') or []):
                        if e.get('name') == 'NO_DEFAULT_POOLS':
                            nodefault += 1
        ippool = sum(1 for d in docs if d.get('kind') == 'IPPool')
        print('     双池=%-5s 渲染 OK, %3d 个文档, NO_DEFAULT_POOLS=%d, IPPool=%d %s'
              % (dual, len(docs), nodefault, ippool,
                 '' if (nodefault == (1 if dual else 0) and ippool == 0) else '⚠'))
        if nodefault != (1 if dual else 0) or ippool != 0:
            ok = False
    except Exception as e:
        ok = False
        print('     双池=%-5s ❌ %s' % (dual, str(e)[:160]))
# 参数化点是否都在
txt = open(path, encoding='utf-8').read()
for token in ('calico_images.cni','calico_images.node','calico_images.kube_controllers',
              'calico_encapsulation','calico_ip_autodetection_method',
              'calico_enable_bandwidth','calico_dual_ippool_enabled'):
    if token not in txt:
        ok = False
        print('     ❌ 缺参数化点: %s' % token)
sys.exit(0 if ok else 4)
PYEOF

echo
if [ "$APPLY" = "1" ]; then
  # 只有重新生成【同一个版本】时才需要备份(会覆盖已有文件);
  # 新增版本是写一个新文件, 旧版本文件原样不动, 没什么可备份的。
  if [ -f "$TPL" ]; then
    cp "$TPL" "${TPL}.bak-$(date +%Y%m%dT%H%M%S)"
    cp "$GENERATED" "$TPL"
    echo "✅ 已覆盖 $TPL (原文件已备份为 ${TPL}.bak-*)"
  else
    cp "$GENERATED" "$TPL"
    echo "✅ 已新增 $TPL (未触碰其它版本的模板)"
  fi
  echo
  echo "接下来:"
  echo "  1. git diff 复核上面 diff 里的 CRD / ClusterRole 变化"
  echo "  2. 若基准模板有'我们补的'规则(diff 里带 ⚠ 的 - 行), 确认是否需要加回新模板"
  echo "     已知: policy.networking.k8s.io 的 clusternetworkpolicies、kubevirt.io 的"
  echo "           virtualmachineinstancemigrations —— 上游若仍未包含就必须保留"
  echo "     ⚠ 但 verb 集合变化会同时产生一条 - 和一条 +(同资源不同 verbs), 那是误报,"
  echo "       先在 + 行里找同名资源再判断"
  echo "  3. 改 env.yaml 的 calico_version: $VER  (其它站点不用动, 各自的旧模板还在)"
  echo "  4. 确认离线物料: ls offline/artifacts/cni/calico/v$VER/"
else
  cp "$GENERATED" "$REPO_ROOT/calico-${VER}.yaml.j2.new"
  echo "✅ 已生成 $REPO_ROOT/calico-${VER}.yaml.j2.new (未写入模板目录)"
  echo "   确认上面 diff 无异常后, 重跑加 --apply 写入 $TPL"
fi
