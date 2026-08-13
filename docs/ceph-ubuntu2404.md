# Ceph Ubuntu 24.04 部署手册 (Squid 19.2.x)

## 目录

- [环境说明](#环境说明)
- [环境准备](#环境准备)
- [安装 cephadm](#安装-cephadm)
- [关键问题：cephadm OSD Permission Denied 修复](#关键问题cephadm-osd-permission-denied-修复)
- [引导集群](#引导集群)
- [添加节点](#添加节点)
- [部署 OSD](#部署-osd)
- [部署 Mon](#部署-mon)
- [网络配置](#网络配置)
- [CephFS 部署](#cephfs-部署)
- [客户端挂载](#客户端挂载)
- [Rook-Ceph 对接（推荐）](#rook-ceph-对接推荐)
- [扩容新节点](#扩容新节点)
- [服务管理](#服务管理)
- [常见问题](#常见问题)

---

## 环境说明

| 项目 | 值 |
|------|-----|
| 操作系统 | Ubuntu 24.04 (Noble) |
| Ceph 版本 | 19.2.x (Squid) |
| 容器运行时 | Docker |
| cgroup 版本 | v2 |
| 节点角色 | Kubernetes + Ceph 混部 |

节点规划：

| 节点 | IP | 角色 | 盘 |
|------|----|------|----|
| cpu03 | 172.18.0.67 | mon/mgr/osd | nvme0n1, nvme1n1 |
| cpu05 | 172.18.1.65 | mon/mgr/osd | nvme0n1, nvme1n1 |
| cpu07 | 172.18.1.67 | mon/mgr/osd | nvme0n1, nvme1n1 |
| cpu08 | 172.18.1.68 | osd | nvme0n1, nvme1n1 |

---

## 环境准备

### 安装依赖

```bash
ansible cluster -m shell -a "apt install -y sshpass python3 chrony lvm2"
```

### 配置时间同步

```bash
ansible cluster -m shell -a "systemctl enable --now chrony"
```

### 禁用 fstab 中旧存储挂载

```bash
# 注释掉旧的 minio 或其他存储挂载
ansible cluster -m shell -a "sed -i '/minio/s/^/#/' /etc/fstab"
ansible cluster -m shell -a "umount /data/minio/disk0 /data/minio/disk1 2>/dev/null; echo done"
```

### NVMe 写缓存检查

```bash
# 查看写缓存状态（NVMe 不支持 hdparm，用 nvme 命令）
ansible cluster -m shell -a "nvme id-ctrl /dev/nvme0n1 | grep -i 'vwc'"
# vwc: 0 表示已关闭，vwc: 0x6 表示开启

# 尝试关闭（部分型号不支持）
ansible cluster -m shell -a "nvme set-feature /dev/nvme0n1 -f 0x06 -v 0"
```

> **注意**：Intel 企业级 NVMe（如 SSDPF2KX038T1O）内置掉电保护电容，写缓存开启也安全。

### 锁定包版本

```bash
apt-mark hold cephadm containerd runc
apt-mark showhold
```

---

## 安装 cephadm

```bash
apt install -y cephadm
cephadm version
```

---

## 关键问题：cephadm OSD Permission Denied 修复

> **必须在所有 OSD 节点执行，否则 cephadm 无法创建 OSD。**

### 问题现象

`ceph orch daemon add osd` 报错：

```
bdev open open got: (13) Permission denied
OSD::mkfs: ObjectStore::mkfs failed with error (13) Permission denied
```

### 根因

- cephadm 容器镜像内 `ceph` 用户 UID/GID 为 **167**
- 宿主机旧 udev 规则 `95-ceph-osd-lvm.rules` 按用户名解析 `ceph`，与容器内 UID 不匹配
- 导致 dm 设备权限错误，ceph-osd 进程无法打开块设备

### 解决方案（所有 OSD 节点执行）

```bash
# 禁用旧规则
ln -sfn /dev/null /etc/udev/rules.d/95-ceph-osd-lvm.rules

# 创建新规则，固定 UID/GID 为 167
cat > /etc/udev/rules.d/99-cephadm-osd-lvm.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", \
  ENV{DEVTYPE}=="disk", \
  ENV{DM_LV_NAME}=="osd-*", \
  ENV{DM_VG_NAME}=="ceph-*", \
  OWNER:="167", GROUP:="167", MODE:="0660"
EOF

# 重载规则
udevadm control --reload-rules
udevadm control --ping
```

### Ansible 批量推送

```bash
ansible 'cpu03,cpu05,cpu07,cpu08' -m shell -a \
  "ln -sfn /dev/null /etc/udev/rules.d/95-ceph-osd-lvm.rules"

ansible 'cpu03,cpu05,cpu07,cpu08' -m copy -a \
  "src=/etc/udev/rules.d/99-cephadm-osd-lvm.rules \
   dest=/etc/udev/rules.d/99-cephadm-osd-lvm.rules"

ansible 'cpu03,cpu05,cpu07,cpu08' -m shell -a \
  "udevadm control --reload-rules && udevadm control --ping"
```

> **注意**：新增 OSD 节点时必须同步部署此规则。

---

## 引导集群

```bash
cephadm bootstrap \
  --mon-ip 172.18.0.67 \
  --initial-dashboard-password 'YourPassword@2026' \
  --dashboard-password-noupdate
```

bootstrap 完成后修正 public_network 范围（多子网环境）：

```bash
ceph config set global public_network 172.18.0.0/16
ceph config set mon public_network 172.18.0.0/16
```

---

## 添加节点

```bash
# 分发 SSH 公钥
ssh-copy-id -f -i /etc/ceph/ceph.pub root@cpu05
ssh-copy-id -f -i /etc/ceph/ceph.pub root@cpu07
ssh-copy-id -f -i /etc/ceph/ceph.pub root@cpu08

# 添加节点
ceph orch host add cpu05 172.18.1.65
ceph orch host add cpu07 172.18.1.67
ceph orch host add cpu08 172.18.1.68

# 验证
ceph orch host ls
```

---

## 部署 OSD

### 清理磁盘（如有旧数据）

```bash
ceph orch device zap cpu05 /dev/nvme0n1 --force
ceph orch device zap cpu05 /dev/nvme1n1 --force
# ... 其他节点同理
```

验证磁盘可用：

```bash
ceph orch device ls
# AVAILABLE 列显示 Yes 即可
```

### 添加 OSD

确保 udev 规则已部署后执行：

```bash
ceph orch daemon add osd cpu03:/dev/nvme0n1
ceph orch daemon add osd cpu03:/dev/nvme1n1
ceph orch daemon add osd cpu05:/dev/nvme0n1
ceph orch daemon add osd cpu05:/dev/nvme1n1
ceph orch daemon add osd cpu07:/dev/nvme0n1
ceph orch daemon add osd cpu07:/dev/nvme1n1
ceph orch daemon add osd cpu08:/dev/nvme0n1
ceph orch daemon add osd cpu08:/dev/nvme1n1
```

验证：

```bash
ceph osd tree
ceph -s
```

---

## 部署 Mon

```bash
# 指定 mon 节点（需添加 mon label）
ceph orch apply mon "cpu03,cpu05,cpu07"

# 验证
ceph orch ps --daemon-type mon
ceph mon stat
```

---

## 网络配置

### public_network 配置

```bash
# 多子网环境用 /16
ceph config set global public_network 172.18.0.0/16
ceph config set mon public_network 172.18.0.0/16
```

### cluster_network（IB 网络）

如果有 InfiniBand 网卡用于 OSD 间复制：

```bash
# 查看 IB 网卡 IP
ansible cluster -m shell -a "ip addr show ib0 | grep 'inet '"

# 配置 cluster_network
ceph config set global cluster_network <IB网段/掩码>
```

### node-exporter 端口冲突

Kubernetes 节点通常占用 9100 端口，修改 Ceph 的 node-exporter 端口：

```bash
cat <<EOF | ceph orch apply -i -
service_type: node-exporter
service_name: node-exporter
spec:
  port: 9101
EOF
```

---

## CephFS 部署

### 创建 CephFS

```bash
ceph fs volume create cephfs --placement="cpu03,cpu05,cpu07"
```

### 查看状态

```bash
ceph fs ls
ceph fs status cephfs
ceph orch ps --daemon-type mds
ceph osd pool ls detail
```

### 启用 bulk 模式（大容量池）

```bash
ceph osd pool set cephfs.cephfs.data bulk true
```

### 调整副本数

```bash
ceph osd pool set cephfs.cephfs.meta size 2
ceph osd pool set cephfs.cephfs.data size 2
ceph osd pool set cephfs.cephfs.meta min_size 1
ceph osd pool set cephfs.cephfs.data min_size 1
```

---

## 客户端挂载

### 创建专用用户

```bash
# 创建只对 cephfs 有权限的用户
ceph fs authorize cephfs client.cephfsuser / rw

# 获取 key
ceph auth get client.cephfsuser
```

### 客户端配置

```bash
# 生成 keyring 文件
cat > /etc/ceph/ceph.client.cephfsuser.keyring <<'EOF'
[client.cephfsuser]
    key = AQCBC1Bq/ADnLxAAno5es125ok1+bCca2vqpOg==
EOF

chmod 600 /etc/ceph/ceph.client.cephfsuser.keyring

# 内核挂载
mount -t ceph 172.18.0.67,172.18.1.65,172.18.1.67:/ /mnt/cephfs \
  -o name=cephfsuser
```

> **注意**：客户端只需安装 `ceph-common`，不要安装 `ceph-osd`，避免与 cephadm 容器管理冲突。

```bash
apt install -y ceph-common
```

---

## Rook-Ceph 对接（推荐）

> Kubernetes 环境推荐使用 Rook 对接外部 Ceph 集群，天然兼容 cgroup v2，自动提供 StorageClass。

### 1. 预加载镜像（离线环境）

```bash
# 在管理节点导出镜像
podman save -o ceph-all-images.tar quay.io/ceph/ceph:v19

# 分发到所有 k8s 节点
scp ceph-all-images.tar root@<节点IP>:/root/

# 各节点导入
ctr -n k8s.io images import ceph-all-images.tar
```

### 2. 获取 Rook

```bash
git clone --single-branch --branch v1.17.6 https://github.com/rook/rook.git
cd /root/rook/deploy/examples/
```

### 3. 生成外部集群资源脚本

```bash
python3 create-external-cluster-resources.py \
  --rbd-data-pool-name replicapool \
  --cephfs-filesystem-name cephfs \
  --namespace rook-ceph \
  --format bash > external.sh
```

### 4. 安装 Rook Operator

```bash
helm repo add rook-release https://charts.rook.io/release

clusterNamespace=rook-ceph
operatorNamespace=rook-ceph

cd /root/rook/deploy/charts/rook-ceph-cluster

# 部署 Operator
helm install --create-namespace --namespace $clusterNamespace \
  rook-ceph rook-release/rook-ceph -f values.yaml

# 部署外部集群
helm install --create-namespace --namespace $clusterNamespace \
  rook-ceph-cluster \
  --set operatorNamespace=$operatorNamespace \
  rook-release/rook-ceph-cluster -f values-external.yaml
```

### 5. 导入外部集群配置

```bash
. external.sh
. import-external-cluster.sh
```

### 6. 测试 PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cephfs-pvc-test
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: ceph-csi-cephfs
```

---

## 扩容新节点

### 1. 新节点基础环境

```bash
apt install -y chrony lvm2
systemctl enable --now chrony
systemctl is-active chrony

# 确认系统环境一致
cat /etc/os-release | grep VERSION
uname -r
systemctl is-active apparmor
```

> **重要**：只安装 `ceph-common`，不要安装 `ceph-osd`。

```bash
apt install -y ceph-common
```

### 2. 部署 udev 规则（必须）

```bash
ln -sfn /dev/null /etc/udev/rules.d/95-ceph-osd-lvm.rules

cat > /etc/udev/rules.d/99-cephadm-osd-lvm.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="block", \
  ENV{DEVTYPE}=="disk", \
  ENV{DM_LV_NAME}=="osd-*", \
  ENV{DM_VG_NAME}=="ceph-*", \
  OWNER:="167", GROUP:="167", MODE:="0660"
EOF

udevadm control --reload-rules && udevadm control --ping
```

### 3. 分发 SSH 公钥（在管理节点执行）

```bash
ceph cephadm get-pub-key > ~/ceph.pub
ssh-copy-id -f -i ~/ceph.pub root@<新节点IP>
ssh root@<新节点IP>  # 验证免密登录
```

### 4. 预加载镜像（离线环境）

```bash
# 管理节点导出
podman save -o ceph-v19.tar quay.io/ceph/ceph:v19
scp ceph-v19.tar root@<新节点IP>:/root/

# 新节点导入
podman load -i /root/ceph-v19.tar
podman images | grep ceph  # 确认 tag 完整
```

### 5. 加入集群

```bash
ceph orch host add <新节点名> <新节点IP>
ceph orch host ls
ceph cephadm check-host <新节点名> <新节点IP>
```

### 6. 添加 OSD

```bash
ceph orch device ls <新节点名>  # 确认磁盘可用
ceph orch daemon add osd <新节点名>:/dev/nvme0n1
ceph orch daemon add osd <新节点名>:/dev/nvme1n1
```

### 7. 验证

```bash
ceph orch ps <新节点名>
ceph osd tree
ceph -s
```

---

## 服务管理

```bash
# 查看所有服务
ceph orch ls
ceph orch ps

# 重启单个 daemon
ceph orch daemon restart osd.0

# 重新部署 daemon
ceph orch daemon redeploy ceph-exporter.cpu08

# 查看集群状态
ceph -s
ceph health detail
ceph osd tree
```

---

## 常见问题

### 1. OSD 地址不在 public_network 子网

```
osd.2's public address is not in '172.18.0.0/24' subnet
```

解决：

```bash
ceph config set global public_network 172.18.0.0/16
ceph config set mon public_network 172.18.0.0/16
```

### 2. node-exporter 9100 端口被 k8s 占用

```
Cannot bind to IP 0.0.0.0 port 9100: Address already in use
```

解决：修改端口为 9101（见[网络配置](#网络配置)）

### 3. Mon 无法部署到其他节点

检查 public_network 是否覆盖目标节点 IP，以及节点是否有 mon label：

```bash
ceph orch host ls
ceph config get mon public_network
```

### 4. ceph-exporter / crash 服务 error

```bash
ceph orch daemon redeploy ceph-exporter.cpu08
ceph orch daemon redeploy crash.cpu08
```

### 5. NVMe 写缓存无法关闭

部分企业级 NVMe（如 Intel P5520）固件不支持通过命令修改写缓存，但内置掉电保护电容，数据安全有保障，无需处理。
