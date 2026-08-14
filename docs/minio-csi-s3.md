# MinIO 分布式集群 + csi-s3 存储类部署文档

| 项目 | 内容 |
|---|---|
| 集群 | kubekey 部署，K8s v1.34.3 |
| MinIO 节点 | cpu03 / cpu05 / cpu07 / cpu08 = 172.18.0.67 / 172.18.1.65 / .67 / .68 |
| 硬件 | 每节点 2 块 3.5TB NVMe，共 8 drives |
| 版本 | MinIO `RELEASE.2025-04-22T22-12-26Z`，csi-s3 `0.43.7` |
| 网络 | 400G RoCE，Pod 网络为 Calico IPIP |
| 部署日期 | 2026-08-12 |

---

## 一、MinIO 集群

### 1.1 容量与纠删码

8 drives 组成单个 erasure set，裸容量 28TB。

| 纠删码 | 可用容量 | 容忍故障 | 备注 |
|---|---|---|---|
| **EC:4**（采用） | 14 TiB | 任意 4 块盘 = 2 个节点 | 默认值 |
| EC:2 | 21 TiB | 任意 2 块盘 = 1 个节点 | 需在**首次初始化前**设置 |

> `MINIO_STORAGE_CLASS_STANDARD=EC:2` 只在首次格式化时生效，已有数据的集群改了不会重新编码。

### 1.2 磁盘准备

每节点两块盘必须是**独立物理盘的挂载点**，不能是同一文件系统下的两个目录 —— 否则纠删码失去意义。

```bash
# 确认磁盘干净:FSTYPE 为空、无 UUID、mdstat 里没有
ansible minio -i hosts -m shell -a "lsblk -f /dev/nvme0n1 /dev/nvme1n1; cat /proc/mdstat"

# 格式化 + 挂载(注意用单引号,防止 $U0 被本地 shell 提前展开)
ansible minio -i hosts -m shell -a '
mkfs.xfs -f /dev/nvme0n1 && mkfs.xfs -f /dev/nvme1n1
mkdir -p /data/minio/disk0 /data/minio/disk1
U0=$(blkid -s UUID -o value /dev/nvme0n1)
U1=$(blkid -s UUID -o value /dev/nvme1n1)
grep -q "$U0" /etc/fstab || echo "UUID=$U0 /data/minio/disk0 xfs defaults,noatime 0 2" >> /etc/fstab
grep -q "$U1" /etc/fstab || echo "UUID=$U1 /data/minio/disk1 xfs defaults,noatime 0 2" >> /etc/fstab
mount -a
chown -R 1000:1000 /data/minio
df -h /data/minio/disk0 /data/minio/disk1
'
```

验证要点：

- 两行 `Filesystem` 列**必须不同**（`/dev/nvme0n1` 与 `/dev/nvme1n1`）
- 属主 `1000:1000`，对应容器 `runAsUser: 1000`
- 用 UUID 写 fstab，避免重启后 nvme 编号漂移

### 1.3 镜像版本选择

```bash
docker pull minio/minio:RELEASE.2025-04-22T22-12-26Z
docker tag  minio/minio:RELEASE.2025-04-22T22-12-26Z harbor.local.clusters/minio/minio:RELEASE.2025-04-22T22-12-26Z
docker push harbor.local.clusters/minio/minio:RELEASE.2025-04-22T22-12-26Z
```

> **版本锁在 `RELEASE.2025-04-22`。** 2025-05-24 之后的版本把 Web 控制台功能砍到只剩登录页和基础信息，桶管理、用户管理全部移到商业版。只用 S3 API 的话新版无所谓。

### 1.4 StatefulSet 的三个必需项

```yaml
spec:
  podManagementPolicy: Parallel     # 必需:串行启动会互相等待形成死锁
  template:
    spec:
      containers:
      - args:
        - |
          exec minio server \
            http://minio-{0...3}.minio-hl.minio-system.svc.cluster.local/data{0...1} \
            --console-address ":9001"
```

```yaml
# Headless Service
spec:
  clusterIP: None
  publishNotReadyAddresses: true    # 必需:启动阶段各节点未 Ready 时也要能互相解析
```

**探针一律用 `/minio/health/live`**，它只检查本进程。不要用 `/health/cluster` 做 liveness —— 滚动更新期间集群短暂不满仲裁，会引发所有 Pod 连环重启。

### 1.5 启动期的正常现象

首次启动时日志会刷：

```
grid: ... re-connecting to http://minio-2...: lookup ... no such host
INFO: Unable to use the drive http://minio-2.../data0: drive not found, will be retried
INFO: Waiting for all other servers to be online to format the drives (elapses 24s)
```

这是各节点拉镜像、启动速度不一致导致的，**先起来的会等后面的**。看到下面这两行就说明成功了：

```
INFO: Formatting 1st pool, 1 set(s), 8 drives per set.
MinIO Object Storage Server
```

### 1.6 资源配置

节点规格 128 核 / 256G。MinIO 写入路径是 CPU 密集的（Reed-Solomon 编码），**limit 给多少就吃多少**，见 2.3 的 A/B 数据。

```yaml
resources:
  requests: { cpu: "4", memory: 8Gi }    # 不要留 1 核 —— QoS 会变 Burstable
  limits:   { cpu: "8", memory: 64Gi }
```

选 8 核而不是 32 核的理由：本集群 MinIO 面向的是 MySQL/Redis 备份、模型权重、日志归档这类负载，8 核对应的 ~4.4 GB/s 混合吞吐已经远超实际需求；把 CPU 让给同节点的业务（**cpu03 上还跑着 etcd**）比多榨几 GB/s 更划算。需要极限吞吐时临时改大 limit 即可，不用重建。

> requests 设得过低（如 1 核）时 QoS 为 Burstable，调度器按 1 核算容量，节点压力大时会被优先压制或驱逐。

---

## 二、性能实测

### 2.1 测试方式对结果影响极大

| 方式 | 吞吐 | 说明 |
|---|---|---|
| `mc cp` 单文件 | 152 MiB/s | 单 TCP 流 + 单线程 EC 编码，**测不出集群能力** |
| `warp mixed` 64 并发 64MiB | 2,138 / 4,385 MiB/s | 取决于 CPU limit（4 核 / 8 核），见 2.3 |
| `warp put` 128 并发 256MiB | **5,717 MiB/s** | 纯写压测，32 核 limit |
| `warp get` 未清缓存 | 15,417 MiB/s | **假象**，数据在 page cache，见 2.3 |
| `warp get` 清缓存后 | 6,353 MiB/s | 真实冷读基准 |

### 2.2 最终数据

| 场景 | 吞吐 | 换算 | 条件 |
|---|---|---|---|
| 纯写 (PUT) | 5,717 MiB/s | 46 Gb/s | 256MiB × 128 并发，32 核 limit |
| 纯读·**冷缓存** | 6,353 MiB/s | 51 Gb/s | TTFB 中位 **195ms**，`drop_caches` 后 |
| 纯读·热缓存 | ~15,400 MiB/s | 123 Gb/s | TTFB 中位 **5ms**，数据在 page cache |
| 混合 @ 8 核 | 4,385 MiB/s | 35 Gb/s | 64MiB × 64 并发 |
| 混合 @ 4 核 | 2,138 MiB/s | 17 Gb/s | 同参数对照组 |

四节点负载偏差 < 7%，无热点。

**以 6.35 GB/s 作为读的稳态基准，不要用 15.4 GB/s 报数。** 冷读与写基本持平（约 1.1:1），符合 EC:4 的物理预期：写要算 4 个校验块并跨节点分发，读要从 4 块数据盘拉齐再拼装，两边都受网络和磁盘约束。

### 2.3 两个容易测错的地方

**① page cache 制造的假象**

第一轮 GET 测出 15,417 MiB/s、TTFB 5ms；之后重复三次都只有 5,700~6,500 MiB/s、TTFB 200ms 上下。

排查过程中先后怀疑过后台 scanner、对象堆积，都被证伪（`mc du` 只有 8.6GiB / 138 objects）。真正的原因是 **前一轮 `put --noclear` 刚写完的数据还在各节点 page cache 里**，GET 直接命中内存。`free -h` 的 buff/cache 分布极不均匀是决定性线索：

```
cpu07 122Gi   cpu05 63Gi   cpu03 10Gi   cpu08 8.7Gi
```

清缓存后复测，得到稳定的冷读基准：

```bash
ansible minio -i hosts -m shell -a "sync; echo 3 > /proc/sys/vm/drop_caches"
# → GET 6,353 MiB/s，TTFB Avg 195ms
```

TTFB 是最灵敏的判别指标：**5ms 说明在读内存，200ms 说明在读盘**。测读性能前务必先 `drop_caches`，或者用一份写入后已经过了足够长时间的数据集。

**② CPU limit 直接线性决定吞吐**

同参数（64MiB × 64 并发）混合测试，只改 limit：

| limit | 混合总吞吐 |
|---|---|
| 4 核 | 2,138 MiB/s |
| 8 核 | **4,385 MiB/s** |

**几乎正好翻倍**，GET 和 PUT 各自等比例提升。说明在这个区间 MinIO 完全受 CPU 约束，没有到拐点——之前"4→32 核只提升 9%"的结论是错的，那两次测试的并发和对象大小并不相同，不构成对照。

想要更高吞吐直接加 limit 即可，代价是抢占同节点业务的 CPU。本环境按需求定在 8 核（见 1.6）。

Calico IPIP 封装的影响没有单独量化，但热缓存下能跑到 123 Gb/s，说明 overlay 不是主要瓶颈。**不建议为此改 CNI 或重建成 hostNetwork**，收益不确定而风险实在。

### 2.4 warp 压测命令

```bash
# 镜像的 ENTRYPOINT 已经是 warp,参数不要重复写 warp

# 纯写
kubectl -n minio-system run warp --rm -it --restart=Never \
  --image=harbor.local.clusters/minio/warp:latest -- \
  put --host=minio-{0...3}.minio-hl.minio-system.svc.cluster.local:9000 \
    --access-key=minioadmin --secret-key='<密码>' \
    --obj.size=256MiB --concurrent=128 --duration=60s --noclear

# 混合(读写比例由 warp 内部决定,GET 约 45%、PUT 约 15%)
kubectl -n minio-system run warp --rm -it --restart=Never \
  --image=harbor.local.clusters/minio/warp:latest -- \
  mixed --host=minio-{0...3}.minio-hl.minio-system.svc.cluster.local:9000 \
    --access-key=minioadmin --secret-key='<密码>' \
    --obj.size=64MiB --concurrent=64 --duration=60s --autoterm
```

几个坑：

- `--noclear` 会把测试对象留在桶里，下一轮读测试直接命中 page cache（见 2.3）。测完记得 `mc rm --recursive --force local/warp-benchmark-bucket/`
- warp 的 Preparing 阶段（上传测试对象）也会显示 PUT 速率，那**不是**测试结果，别看错
- 小对象测试（如 4KiB）的 Preparing 阶段极慢，2500 个对象可能要几分钟，属正常

---

## 三、用户与权限

### 3.1 mc 使用的两个坑

**① alias 存在容器内，Pod 重建就丢**

`mc alias set` 写入容器的 `~/.mc/config.json`。MinIO StatefulSet 滚动更新后 alias 消失，表现为 `Access Denied` —— 而且 **`mc alias set` 密码错了不会当场报错**，要到实际操作时才暴露。

推荐用环境变量，一条命令内完成：

```bash
kubectl -n minio-system exec minio-0 -- sh -c '
mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc ls local
'
```

**② `MC_HOST_` 形式需要 URL 编码**

密码含 `@` 时必须编码成 `%40`，否则解析出错：

```bash
kubectl -n minio-system run mc --restart=Never \
  --image=harbor.local.clusters/minio/minio:RELEASE.2025-04-22T22-12-26Z \
  --env='MC_HOST_local=http://minioadmin:Infrawaves%40123@minio.minio-system.svc.cluster.local:9000' \
  --command -- sleep infinity
```

minio 镜像是精简的，**没有 `sed`**，不能用它做 URL 编码。用 shell 内建替换 `${VAR//@/%40}`（需 bash）。

> 建议给业务账号设不含特殊字符的密码，省掉这一层麻烦。

### 3.2 创建 CSI 专用凭据

```bash
kubectl -n minio-system exec minio-0 -- sh -c '
mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

# 自定义策略:s3:* + admin:*
cat > /tmp/k8s-rw.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:*"],    "Resource": ["arn:aws:s3:::*"] },
    { "Effect": "Allow", "Action": ["admin:*"], "Resource": ["arn:aws:s3:::*"] }
  ]
}
EOF
mc admin policy create local k8s-rw /tmp/k8s-rw.json

mc admin user add local k8s-user <密码>
mc admin policy attach local k8s-rw --user k8s-user
mc mb local/k8s

# 生成 Service Account(可单独吊销,权限继承父用户)
mc admin user svcacct add local k8s-user
'
```

> **provisioner 需要 `s3:CreateBucket` 权限** —— 内置的 `readwrite` 策略不含建桶权限，必须用 `consoleAdmin` 或自定义策略。

验证（建桶那步必须过）：

```bash
kubectl -n minio-system exec minio-0 -- sh -c '
mc alias set t http://127.0.0.1:9000 <AK> <SK> >/dev/null
mc ls t
mc mb t/perm-check && mc rb t/perm-check && echo "CreateBucket OK"
'
```

### 3.3 策略绑定是替换不是追加

`mc admin policy attach` 会**替换**用户已有的策略绑定，不是追加。给同一用户先后 attach 两个策略，只有后一个生效。

---

## 四、csi-s3 存储类

### 4.1 核心坑：endpoint 不能用 Service DNS 名

这是排查耗时最长的一个问题。现象是 **PVC 能 Bound 但 Pod 挂载超时**：

```
MountVolume.MountDevice failed: rpc error: code = Unknown desc = Timeout waiting for mount
```

驱动日志里的关键行：

```
Starting geesefs using systemd: /var/lib/kubelet/plugins/ru.yandex.s3.csi/geesefs \
  --endpoint http://minio.minio-system.svc.cluster.local:9000 ...
```

**geesefs 不在容器里跑，而是由宿主机 systemd 启动**（这样容器重启挂载不会断）。宿主机用自己的 `/etc/resolv.conf`，不走 CoreDNS，解析不了 `*.svc.cluster.local`。

两个组件的执行环境完全不同：

| 阶段 | 执行者 | 网络环境 | DNS |
|---|---|---|---|
| 建 PVC / 建桶 | provisioner Pod | Pod 网络 | CoreDNS ✅ |
| **节点挂载** | **geesefs（宿主机 systemd）** | **宿主机网络** | **宿主机 resolv.conf ❌** |

所以 provisioner 用同一个 endpoint 没问题，geesefs 却连不上 —— 这就是「能建不能挂」的原因。

**可用的 endpoint 形式：**

| 形式 | 可用 | 缺点 |
|---|---|---|
| `minio.minio-system.svc.cluster.local:9000` | ❌ | 宿主机解析不了 |
| NodePort `<节点IP>:30900` | ✅ | endpoint 写死某台节点 IP，那台故障则挂载全断 |
| ClusterIP（随机分配） | ✅ | Service 重建后 IP 变，已有挂载全失效 |
| **固定 ClusterIP `10.233.46.93:9000`（写死在 Service）** | ✅ **推荐** | 见下 |

**推荐固定 ClusterIP，不需要 keepalived/VIP**：geesefs 虽由宿主机 systemd 启动，但**宿主机本身就是 k8s 节点**，kube-proxy 已在本机把每个 ClusterIP 编进 ipvs/iptables，宿主机能直接连 `ClusterIP:9000`（和节点能 ping 通 kube-dns 的 ClusterIP 同理）。只要在 `minio` Service 里把 `clusterIP` **写死**（见 minio.yaml 的 `clusterIP: 10.233.46.93`），它就不再随 Service 重建漂移，也无需额外 NodePort、无需 keepalived；跨节点冗余由 kube-proxy 负责（转发到任一 MinIO Pod）。

> 仅当 geesefs 宿主机**不是** k8s 节点时 ClusterIP 才不可达（本环境不是这种），那时才退回 NodePort；要避免 NodePort 绑死单节点，可再叠加 VIP/外部 LB。本环境用固定 ClusterIP 即可。

### 4.2 mounter 与 options 必须匹配

另一个踩过的坑：StorageClass 重建时 `mounter` 参数丢失，默认回落到 s3fs，但 `options` 仍是 geesefs 的参数：

```
Error fuseMount command: s3fs
args: [... --memory-limit 4000 --dir-mode 0777 --file-mode 0755]
output:            ← s3fs 不认这些 flag,直接失败
```

三种 mounter 对比：

| mounter | 性能 | 特点 |
|---|---|---|
| **geesefs** | 最快 | 并发预读 + 写缓冲，推荐 |
| s3fs | 慢 | 兼容性稍好 |
| rclone | 最慢 | — |

### 4.3 镜像同步

三个镜像**全部只在 `cr.yandex`**，daocloud 不代理该仓库：

```bash
skopeo login harbor.local.clusters

skopeo copy --all --dest-tls-verify=false \
  docker://cr.yandex/crp9ftr22d26age3hulg/csi-s3:0.43.7 \
  docker://harbor.local.clusters/minio/csi-s3:0.43.7

skopeo copy --all --dest-tls-verify=false \
  docker://cr.yandex/crp9ftr22d26age3hulg/yandex-cloud/csi-s3/csi-node-driver-registrar:v2.16.0 \
  docker://harbor.local.clusters/minio/csi-node-driver-registrar:v2.16.0

skopeo copy --all --dest-tls-verify=false \
  docker://cr.yandex/crp9ftr22d26age3hulg/yandex-cloud/csi-s3/csi-provisioner:v6.2.0 \
  docker://harbor.local.clusters/minio/csi-provisioner:v6.2.0
```

注意事项：

- **三个镜像都是 amd64 单架构**，`skopeo copy --all` 变不出 arm64。arm 节点要用得自己编译（仓库有 Dockerfile）
- yandex 的 sidecar tag（`v2.16.0` / `v6.2.0`）是他们自己的编号，**上游 sig-storage 没有这些版本**，不能直接换源
- 替换镜像地址时**长前缀必须先 sed**，否则短前缀会先匹配掉：

```bash
sed -i \
  -e 's|cr.yandex/crp9ftr22d26age3hulg/yandex-cloud/csi-s3/|harbor.local.clusters/minio/|g' \
  -e 's|cr.yandex/crp9ftr22d26age3hulg/|harbor.local.clusters/minio/|g' \
  *.yaml
```

### 4.4 Secret

**必须与 StorageClass 里 `*-secret-namespace` 指定的 namespace 一致**（本环境装在 `minio-system`，不是默认的 `kube-system`）。

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: csi-s3-secret
  namespace: minio-system
type: Opaque
stringData:
  accessKeyID: <AK>
  secretAccessKey: <SK>
  # 不能用 Service DNS 名 —— geesefs 由宿主机 systemd 启动,不走 CoreDNS;用写死的 ClusterIP(见 4.1)
  endpoint: http://10.233.46.93:9000
  region: ""
```

### 4.5 StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: csi-s3
provisioner: ru.yandex.s3.csi
parameters:
  mounter: geesefs                    # 必须与 options 匹配
  bucket: k8s                         # 所有 PVC 共用此桶,各占一个子目录
  options: "--memory-limit 4000 --dir-mode 0777 --file-mode 0755"
  csi.storage.k8s.io/provisioner-secret-name: csi-s3-secret
  csi.storage.k8s.io/provisioner-secret-namespace: minio-system
  csi.storage.k8s.io/controller-publish-secret-name: csi-s3-secret
  csi.storage.k8s.io/controller-publish-secret-namespace: minio-system
  csi.storage.k8s.io/node-stage-secret-name: csi-s3-secret
  csi.storage.k8s.io/node-stage-secret-namespace: minio-system
  csi.storage.k8s.io/node-publish-secret-name: csi-s3-secret
  csi.storage.k8s.io/node-publish-secret-namespace: minio-system
reclaimPolicy: Retain
volumeBindingMode: Immediate
```

几点说明：

- **StorageClass 的 parameters 不可变**，改任何参数都要 `kubectl delete sc` 后重建
- `bucket: k8s` 让所有 PVC 共用一个桶（各占 `pvc-xxxx/` 子目录）。去掉这个参数则每个 PVC 建一个新桶
- `volumeBindingMode: Immediate` 更适合 S3 —— 桶不绑定节点，没必要等调度器。用 `WaitForFirstConsumer` 时 PVC 会一直 Pending 直到有 Pod 引用（这是正常行为，不是故障）
- `reclaimPolicy: Retain` 删 PVC 不删数据，但会留下 `Released` 的 PV 和 MinIO 里的目录，需**手工双向清理**

### 4.6 换 endpoint 后必须重建 PV

挂载参数在 NodeStageVolume 时读取并缓存，改 Secret 后旧 PV 仍指向旧地址：

```bash
kubectl delete pod <pod> --ignore-not-found
kubectl delete pvc <pvc> --ignore-not-found
kubectl get pv | grep csi-s3          # Released 的手工删
kubectl delete pv <pv-name>

# MinIO 侧的残留目录也要清
kubectl -n minio-system exec minio-0 -- sh -c '
mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc rm --recursive --force local/k8s/<pvc-uid>/
'
```

### 4.7 验证

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: csi-s3-pvc
spec:
  accessModes: [ReadWriteMany]
  storageClassName: csi-s3
  resources: { requests: { storage: 5Gi } }
---
apiVersion: v1
kind: Pod
metadata:
  name: csi-s3-test
spec:
  containers:
  - name: t
    image: harbor.local.clusters/minio/minio:RELEASE.2025-04-22T22-12-26Z
    command: ["sh","-c","sleep 3600"]
    volumeMounts:
    - { name: d, mountPath: /data }
  volumes:
  - name: d
    persistentVolumeClaim: { claimName: csi-s3-pvc }
EOF

sleep 30
kubectl get pvc,pod | grep csi-s3
kubectl exec csi-s3-test -- sh -c 'df -h /data; echo hello > /data/a && cat /data/a'
```

成功输出：

```
Filesystem      Size  Used Avail Use% Mounted on
k8s             1.0P     0  1.0P   0% /data
hello
```

`Size 1.0P` 是 S3 常态 —— 对象存储无固定容量概念，geesefs 报虚拟值。

MinIO 侧确认：

```bash
kubectl -n minio-system exec minio-0 -- sh -c '
mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc ls --recursive local/k8s/'
```

---

## 五、适用场景与限制

### 5.1 csi-s3 的语义限制

S3 后端通过 FUSE 模拟 POSIX，**不具备完整文件系统语义**：

| 数据库依赖的能力 | S3 + FUSE 现实 |
|---|---|
| 原地修改（改一个 16KB 页） | 只能重传整个对象 |
| `flock` / `fcntl` 文件锁 | 不支持 |
| `fsync` 落盘保证 | FUSE 层语义不可靠 |
| `O_DIRECT` | 不支持 |
| rename | 复制 + 删除 |
| 随机小 I/O | 每次一次 HTTP 往返 |

### 5.2 选型建议

| 场景 | 建议 |
|---|---|
| 模型权重、数据集（大文件、整读整写） | ✅ csi-s3 合适 |
| 日志归档、备份 | ✅ csi-s3 合适 |
| 应用能改用 S3 SDK | ✅ **优先直接用 SDK**，性能最好 |
| 大量小文件 | ⚠️ 性能很差，考虑 NFS |
| MySQL / Redis / 任何数据库 | ❌ **实测不可用**，见下 |

### 5.3 MySQL 实测结论：不能用

2026-08-13 在 csi-s3 PVC 上实际起 MySQL，**验证失败**，与 5.1 的语义限制预期一致。此前只是"社区共识不建议"，现在是本环境的实测结论。

不要再在 csi-s3 上尝试任何数据库的数据目录（MySQL / PostgreSQL / Redis AOF-RDB / etcd / ClickHouse），失败模式包括启动时文件锁失败、运行中数据文件损坏、崩溃后无法恢复，而且**损坏往往不是立即暴露的** —— 跑通一次不代表可用。

数据库该用什么：

| 需求 | 方案 |
|---|---|
| 单实例数据目录 | local PV（NVMe，同 MinIO 的做法：手工 PV + `nodeAffinity`） |
| 需要跨节点漂移 | 块存储 CSI，或 NFS（性能一般但语义完整） |
| **备份** | ✅ **推 MinIO 的 S3 接口**，这才是 MinIO 在数据库场景的正确位置 |

```bash
mysqldump --all-databases --single-transaction | gzip | \
  mc pipe local/backup/mysql-$(date +%F-%H%M).sql.gz
```

### 5.4 DirectPV 不是本方案的替代品

容易混淆：**MinIO DirectPV 管理的是节点裸盘，给 Pod 提供 local PV，与访问 MinIO 数据无关。** 它是部署 MinIO 时用来替代手工 local PV 的工具，不能用来"通过 PVC 访问 MinIO 里的数据"。

---

## 六、访问方式汇总

| 用途 | 地址 |
|---|---|
| 控制台 | `http://<节点IP>:30901` |
| 集群内 S3 | `http://minio.minio-system.svc.cluster.local:9000` |
| 集群外 S3 | `http://<节点IP>:30900` |
| **CSI 驱动用** | `http://10.233.46.93:9000`（写死的 ClusterIP，见 4.1） |

> CSI 的 endpoint 与其他用途不同 —— 它由宿主机进程访问，不能用 Service DNS 名，用写死的 ClusterIP。

---

## 七、运维检查项

### 7.1 日常巡检

```bash
E="--endpoints=https://172.18.0.67:2379,... --cacert=... --cert=... --key=..."

# MinIO 集群健康
kubectl -n minio-system exec minio-0 -- sh -c '
mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc admin info local'
# 关注: "8 drives online, 0 drives offline"

# CSI 组件
kubectl -n minio-system get pod | grep csi
kubectl get sc csi-s3
kubectl get pv | grep csi-s3
```

### 7.2 cpu03 混部的持续观察

MinIO 与 etcd 同节点（不同物理盘：etcd 在 `/dev/sda2`，MinIO 在两块 NVMe）。压测期间（5.7 GB/s 持续 1 分钟）未出现 etcd 告警，但需持续关注：

```bash
journalctl -u etcd --since "1 hour ago" --no-pager | grep -icE 'took too long|slow|leader changed'
```

输出非 0 时的处理顺序：降低 MinIO `limits.cpu`（8 → 4，吞吐会等比例减半，见 2.3）→ 提高 requests 保障 QoS → 考虑迁走 MinIO。

### 7.3 待办

| 优先级 | 事项 |
|---|---|
| 高 | ✅ 已做：`minio` Service 的 `clusterIP` 已写死（`10.233.46.93`）——它是 CSI 的 endpoint（4.1），防重建后漂移 |
| 高 | 提高 MinIO `requests`（cpu 1 → 4，memory 4Gi → 8Gi），`limits.cpu` 定为 8 |
| 中 | 空间浪费监控，75% 告警、85% 扩容（扩容方式是加新 server pool，不能给现有 pool 加盘） |
| 中 | 定期 `mc admin` 快照 / 备份策略 |
| 中 | 清理 warp 压测残留（`local/warp-benchmark-bucket/`） |
| 低 | defrag（碎片率高时逐台执行，先 follower 后 leader） |
| 低 | 清理 `Released` 状态的孤儿 PV 及 MinIO 里的残留目录 |

---

## 附录 A — 排查速查

```bash
# ===== MinIO =====
kubectl -n minio-system logs minio-0 | grep -E 'Online|Offline'
kubectl -n minio-system exec minio-0 -- sh -c '
  mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc admin info local'

# ===== CSI 驱动(定位到具体节点) =====
POD=$(kubectl -n minio-system get pod -o wide --no-headers | awk '/csi-s3/ && $7=="<节点名>" {print $1}')
kubectl -n minio-system logs $POD --all-containers --tail=80

# 容器内环境自检
kubectl -n minio-system exec $POD -c csi-s3 -- sh -c '
  ls -l /usr/bin/geesefs /dev/fuse
  getent hosts minio.minio-system.svc.cluster.local
  wget -qO- --timeout=5 http://<endpoint>/minio/health/live'

# 宿主机侧(geesefs 实际运行环境)
ssh <节点> 'journalctl -u "geesefs*" -n 60 --no-pager'
ssh <节点> 'curl -s -m 5 http://<endpoint>/minio/health/live && echo OK'

# ===== PVC 卡住 =====
kubectl describe pvc <pvc> | tail -20
kubectl -n minio-system logs -l app=csi-provisioner-s3 --all-containers --tail=40
kubectl get sc csi-s3 -o jsonpath='{.parameters}' | tr ',' '\n'
```

## 附录 B — 故障现象对照

| 现象 | 原因 | 处理 |
|---|---|---|
| PVC Pending，`WaitForFirstConsumer` | 正常行为 | 建 Pod 引用它，或改 `Immediate` |
| PVC Bound 但 `Timeout waiting for mount` | endpoint 用了 Service DNS 名 | 改 ClusterIP / NodePort / VIP |
| `Error fuseMount command: s3fs` | mounter 与 options 不匹配 | 重建 SC，确认 `mounter: geesefs` |
| `mc` 操作 Access Denied | alias 凭据错或 Pod 重建后丢失 | 一条命令内重设 alias |
| MinIO 启动刷 `no such host` | 各节点启动速度不一致 | 正常，等待 `Formatting 1st pool` |
| `provisioner` 报建桶失败 | 凭据缺 `s3:CreateBucket` | 换 consoleAdmin 或自定义策略 |
| ImagePullBackOff | yaml 里 tag 与 harbor 中不一致 | `grep -h 'image:' *.yaml \| sort -u` 核对 |
| GET 测出 15 GB/s、TTFB 5ms | 命中 page cache，不是真实性能 | 各节点 `drop_caches` 后复测 |
| GET 忽快忽慢 | 各节点 buff/cache 不均 | `free -h` 看分布，清缓存后再比 |
| 吞吐比预期低一半 | `limits.cpu` 被改小 | 吞吐与 CPU limit 近似线性，见 2.3 |
| MySQL 在 csi-s3 PVC 上起不来/损坏 | S3+FUSE 无完整 POSIX 语义 | 不要用，改 local PV，见 5.3 |

---

## 附录 C — MinIO 部署 YAML 全文

源文件 `minio.yaml`。整份直接 `kubectl apply -f minio.yaml` 即可，前置条件是四台节点的磁盘已按 1.2 格式化挂载好。

> **应用前必改两处**：`minio-creds` 里的账号密码；`MINIO_BROWSER_REDIRECT_URL` 里的节点名。
> PV 容量按盘格式化后的实际可用量填（`df -h` 确认），本环境 3.5TB 盘填 `3500Gi`。

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: minio-system
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
  namespace: minio-system
type: Opaque
stringData:
  # 部署前务必改掉,密码至少 8 位
  MINIO_ROOT_USER: "minioadmin"
  MINIO_ROOT_PASSWORD: "ChangeMe-MinIO-2026"
---
# no-provisioner + WaitForFirstConsumer:
# 让调度器先选节点再绑 PV,避免 Pod 调度到没有对应 PV 的节点
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: minio-local
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
# ==================== PV: cpu03 -> minio-0 ====================
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-cpu03-disk0
spec:
  capacity: { storage: 3500Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: minio-local
  local: { path: /data/minio/disk0 }
  claimRef: { namespace: minio-system, name: data0-minio-0 }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: kubernetes.io/hostname, operator: In, values: [cpu03] }
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-cpu03-disk1
spec:
  capacity: { storage: 3500Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: minio-local
  local: { path: /data/minio/disk1 }
  claimRef: { namespace: minio-system, name: data1-minio-0 }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: kubernetes.io/hostname, operator: In, values: [cpu03] }
---
# ==================== PV: cpu05 -> minio-1 ====================
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-cpu05-disk0
spec:
  capacity: { storage: 3500Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: minio-local
  local: { path: /data/minio/disk0 }
  claimRef: { namespace: minio-system, name: data0-minio-1 }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: kubernetes.io/hostname, operator: In, values: [cpu05] }
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-cpu05-disk1
spec:
  capacity: { storage: 3500Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: minio-local
  local: { path: /data/minio/disk1 }
  claimRef: { namespace: minio-system, name: data1-minio-1 }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: kubernetes.io/hostname, operator: In, values: [cpu05] }
---
# ==================== PV: cpu07 -> minio-2 ====================
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-cpu07-disk0
spec:
  capacity: { storage: 3500Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: minio-local
  local: { path: /data/minio/disk0 }
  claimRef: { namespace: minio-system, name: data0-minio-2 }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: kubernetes.io/hostname, operator: In, values: [cpu07] }
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-cpu07-disk1
spec:
  capacity: { storage: 3500Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: minio-local
  local: { path: /data/minio/disk1 }
  claimRef: { namespace: minio-system, name: data1-minio-2 }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: kubernetes.io/hostname, operator: In, values: [cpu07] }
---
# ==================== PV: cpu08 -> minio-3 ====================
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-cpu08-disk0
spec:
  capacity: { storage: 3500Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: minio-local
  local: { path: /data/minio/disk0 }
  claimRef: { namespace: minio-system, name: data0-minio-3 }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: kubernetes.io/hostname, operator: In, values: [cpu08] }
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio-cpu08-disk1
spec:
  capacity: { storage: 3500Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: minio-local
  local: { path: /data/minio/disk1 }
  claimRef: { namespace: minio-system, name: data1-minio-3 }
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - { key: kubernetes.io/hostname, operator: In, values: [cpu08] }
---
# Headless Service:给每个 Pod 稳定 DNS,MINIO_VOLUMES 靠它做节点发现
apiVersion: v1
kind: Service
metadata:
  name: minio-hl
  namespace: minio-system
  labels: { app: minio }
spec:
  clusterIP: None
  # 关键:集群启动时各节点尚未 Ready,需要能互相解析,否则死锁
  publishNotReadyAddresses: true
  selector: { app: minio }
  ports:
  - { name: api, port: 9000, targetPort: 9000, protocol: TCP }
  - { name: console, port: 9001, targetPort: 9001, protocol: TCP }
---
# 集群内业务访问入口
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio-system
  labels: { app: minio }
spec:
  type: ClusterIP
  # 写死 ClusterIP:csi-s3 的 endpoint 直接用它(见 4.1),重建不漂移、不需要 keepalived/VIP。
  # 换环境改成你集群 service-CIDR 内的空闲 IP。
  clusterIP: 10.233.46.93
  selector: { app: minio }
  ports:
  - { name: api, port: 9000, targetPort: 9000, protocol: TCP }
  - { name: console, port: 9001, targetPort: 9001, protocol: TCP }
---
# 集群外访问。有 MetalLB 的话把 type 改成 LoadBalancer 并删掉 nodePort
apiVersion: v1
kind: Service
metadata:
  name: minio-np
  namespace: minio-system
  labels: { app: minio }
spec:
  type: NodePort
  selector: { app: minio }
  ports:
  - { name: api, port: 9000, targetPort: 9000, nodePort: 30900, protocol: TCP }
  - { name: console, port: 9001, targetPort: 9001, nodePort: 30901, protocol: TCP }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: minio
  namespace: minio-system
spec:
  minAvailable: 3        # EC:4 下最多同时下线 1 个节点
  selector:
    matchLabels: { app: minio }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: minio
  namespace: minio-system
  labels: { app: minio }
spec:
  serviceName: minio-hl
  replicas: 4
  # 分布式模式必须并行启动 —— 串行会互相等待形成死锁
  podManagementPolicy: Parallel
  updateStrategy:
    type: RollingUpdate
  selector:
    matchLabels: { app: minio }
  template:
    metadata:
      labels: { app: minio }
    spec:
      # local PV 已把 Pod 钉死在各自节点,这里是双保险
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: { app: minio }
            topologyKey: kubernetes.io/hostname
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - name: minio
        image: harbor.local.clusters/minio/minio:RELEASE.2025-04-22T22-12-26Z
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-c"]
        args:
        - |
          exec minio server \
            http://minio-{0...3}.minio-hl.minio-system.svc.cluster.local/data{0...1} \
            --console-address ":9001"
        env:
        - name: MINIO_ROOT_USER
          valueFrom: { secretKeyRef: { name: minio-creds, key: MINIO_ROOT_USER } }
        - name: MINIO_ROOT_PASSWORD
          valueFrom: { secretKeyRef: { name: minio-creds, key: MINIO_ROOT_PASSWORD } }
        # 控制台经 NodePort 访问时需要,否则登录后跳转地址错误
        - name: MINIO_BROWSER_REDIRECT_URL
          value: "http://cpu03:30901"
        - name: MINIO_PROMETHEUS_AUTH_TYPE
          value: "public"
        # 想要 EC:2(可用 21TB,容忍 1 节点)就取消下面两行注释。
        # 注意:只在首次初始化时生效,已有数据的集群改了不会重新编码
        # - name: MINIO_STORAGE_CLASS_STANDARD
        #   value: "EC:2"
        ports:
        - { name: api, containerPort: 9000 }
        - { name: console, containerPort: 9001 }
        volumeMounts:
        - { name: data0, mountPath: /data0 }
        - { name: data1, mountPath: /data1 }
        # 吞吐与 limits.cpu 近似线性(见 2.3):8 核约 4.4 GB/s 混合吞吐。
        # requests 不要留 1 核 —— QoS 会变 Burstable,cpu03 上还跑着 etcd
        resources:
          requests: { cpu: "4", memory: 8Gi }
          limits:   { cpu: "8", memory: 64Gi }
        # 探针一律用 /health/live —— 它只看本进程。
        # 不要用 /health/cluster 做 liveness:滚动更新期间集群短暂不满仲裁,
        # 会导致所有 Pod 被连环重启
        livenessProbe:
          httpGet: { path: /minio/health/live, port: 9000 }
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 5
        readinessProbe:
          httpGet: { path: /minio/health/live, port: 9000 }
          initialDelaySeconds: 20
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 3
        startupProbe:
          httpGet: { path: /minio/health/live, port: 9000 }
          periodSeconds: 10
          failureThreshold: 30
  volumeClaimTemplates:
  - metadata: { name: data0 }
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: minio-local
      resources: { requests: { storage: 3500Gi } }
  - metadata: { name: data1 }
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: minio-local
      resources: { requests: { storage: 3500Gi } }
```

### 改这份 YAML 时的注意事项

| 字段 | 能否事后改 | 说明 |
|---|---|---|
| `volumeClaimTemplates` | ❌ | StatefulSet 不可变，要改必须先 `kubectl delete sts minio --cascade=orphan` |
| `MINIO_STORAGE_CLASS_STANDARD` | ❌ | 只在首次格式化生效，已有数据不会重新编码 |
| PV 的 `capacity` / `claimRef` | ❌ | 已 Bound 的 PV 改不动，要删 PVC+PV 重建 |
| `resources` | ✅ | 滚动更新，注意 PDB `minAvailable: 3` 会一台一台来 |
| `replicas` | ⚠️ | **不能直接加**，扩容要加新 server pool（改 `minio server` 的 URL 参数） |
| Service / PDB | ✅ | 随便改，但 ClusterIP 变了会导致已有 csi-s3 挂载失效（见 4.1） |

---

## 附录 D — csi-s3 驱动安装清单（v0.43.7）

驱动本体来自 [yandex-cloud/k8s-csi-s3](https://github.com/yandex-cloud/k8s-csi-s3) 的 `deploy/kubernetes/`，git tag **v0.43.7**（镜像 tag 是 `0.43.7`，无 `v`）。下面三份是**已按本环境改好**的：命名空间 `kube-system` → `minio-system`（与 4.4 的 Secret、附录 A 的 `kubectl -n minio-system ...` 巡检命令对齐），三处镜像按 [4.3](#43-镜像同步) 的 sed 规则换成 `harbor.local.clusters/minio/…`。配合 4.4 的 Secret + 4.5 的 StorageClass 一起用。

> **镜像同步**（三个都只在 `cr.yandex`，skopeo 拉到 harbor，均为 amd64 单架构）：
> `csi-provisioner:v6.2.0` / `csi-s3:0.43.7` / `csi-node-driver-registrar:v2.16.0`。
> **apply 顺序**：`driver.yaml`（CSIDriver）→ `provisioner.yaml` → `csi-s3.yaml`（DaemonSet）→ 再建 Secret / StorageClass / PVC。

### D.1 CSIDriver（driver.yaml）

```yaml
apiVersion: storage.k8s.io/v1
kind: CSIDriver
metadata:
  name: ru.yandex.s3.csi
spec:
  attachRequired: false
  podInfoOnMount: true
```

### D.2 provisioner（provisioner.yaml，建桶/建 PVC，跑在 Pod 网络里，用 CoreDNS 没问题）

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: csi-s3-provisioner-sa
  namespace: minio-system
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: csi-s3-external-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "patch", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["list", "watch", "create", "update", "patch"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: csi-s3-provisioner-role
subjects:
  - kind: ServiceAccount
    name: csi-s3-provisioner-sa
    namespace: minio-system
roleRef:
  kind: ClusterRole
  name: csi-s3-external-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
kind: Service
apiVersion: v1
metadata:
  name: csi-s3-provisioner
  namespace: minio-system
  labels:
    app: csi-s3-provisioner
spec:
  selector:
    app: csi-s3-provisioner
  ports:
    - name: csi-s3-dummy
      port: 65535
---
kind: StatefulSet
apiVersion: apps/v1
metadata:
  name: csi-s3-provisioner
  namespace: minio-system
spec:
  serviceName: "csi-provisioner-s3"
  replicas: 1
  selector:
    matchLabels:
      app: csi-s3-provisioner
  template:
    metadata:
      labels:
        app: csi-s3-provisioner
    spec:
      serviceAccount: csi-s3-provisioner-sa
      tolerations:
        - key: node-role.kubernetes.io/master
          operator: Exists
        - key: CriticalAddonsOnly
          operator: Exists
      containers:
        - name: csi-provisioner
          image: harbor.local.clusters/minio/csi-provisioner:v6.2.0
          args:
            - "--csi-address=$(ADDRESS)"
            - "--v=4"
          env:
            - name: ADDRESS
              value: /var/lib/kubelet/plugins/ru.yandex.s3.csi/csi.sock
          imagePullPolicy: "IfNotPresent"
          volumeMounts:
            - name: socket-dir
              mountPath: /var/lib/kubelet/plugins/ru.yandex.s3.csi
        - name: csi-s3
          image: harbor.local.clusters/minio/csi-s3:0.43.7
          imagePullPolicy: IfNotPresent
          args:
            - "--endpoint=$(CSI_ENDPOINT)"
            - "--nodeid=$(NODE_ID)"
            - "--v=4"
          env:
            - name: CSI_ENDPOINT
              value: unix:///var/lib/kubelet/plugins/ru.yandex.s3.csi/csi.sock
            - name: NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: socket-dir
              mountPath: /var/lib/kubelet/plugins/ru.yandex.s3.csi
      volumes:
        - name: socket-dir
          emptyDir: {}
```

### D.3 node driver（csi-s3.yaml，DaemonSet，每节点一个；geesefs 实际由它在宿主机拉起）

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: csi-s3
  namespace: minio-system
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: csi-s3
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["volumeattachments"]
    verbs: ["get", "list", "watch"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: csi-s3
subjects:
  - kind: ServiceAccount
    name: csi-s3
    namespace: minio-system
roleRef:
  kind: ClusterRole
  name: csi-s3
  apiGroup: rbac.authorization.k8s.io
---
kind: DaemonSet
apiVersion: apps/v1
metadata:
  name: csi-s3
  namespace: minio-system
spec:
  selector:
    matchLabels:
      app: csi-s3
  template:
    metadata:
      labels:
        app: csi-s3
    spec:
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
        - operator: Exists
          effect: NoExecute
          tolerationSeconds: 300
      serviceAccount: csi-s3
      containers:
        - name: driver-registrar
          image: harbor.local.clusters/minio/csi-node-driver-registrar:v2.16.0
          args:
            - "--kubelet-registration-path=$(DRIVER_REG_SOCK_PATH)"
            - "--v=4"
            - "--csi-address=$(ADDRESS)"
          env:
            - name: ADDRESS
              value: /csi/csi.sock
            - name: DRIVER_REG_SOCK_PATH
              value: /var/lib/kubelet/plugins/ru.yandex.s3.csi/csi.sock
            - name: KUBE_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: plugin-dir
              mountPath: /csi
            - name: registration-dir
              mountPath: /registration/
        - name: csi-s3
          securityContext:
            privileged: true
            capabilities:
              add: ["SYS_ADMIN"]
            allowPrivilegeEscalation: true
          image: harbor.local.clusters/minio/csi-s3:0.43.7
          imagePullPolicy: IfNotPresent
          args:
            - "--endpoint=$(CSI_ENDPOINT)"
            - "--nodeid=$(NODE_ID)"
            - "--v=4"
          env:
            - name: CSI_ENDPOINT
              value: unix:///csi/csi.sock
            - name: NODE_ID
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: plugin-dir
              mountPath: /csi
            - name: stage-dir
              mountPath: /var/lib/kubelet/plugins/kubernetes.io/csi
              mountPropagation: "Bidirectional"
            - name: pods-mount-dir
              mountPath: /var/lib/kubelet/pods
              mountPropagation: "Bidirectional"
            - name: fuse-device
              mountPath: /dev/fuse
            - name: systemd-control
              mountPath: /run/systemd
      volumes:
        - name: registration-dir
          hostPath:
            path: /var/lib/kubelet/plugins_registry/
            type: DirectoryOrCreate
        - name: plugin-dir
          hostPath:
            path: /var/lib/kubelet/plugins/ru.yandex.s3.csi
            type: DirectoryOrCreate
        - name: stage-dir
          hostPath:
            path: /var/lib/kubelet/plugins/kubernetes.io/csi
            type: DirectoryOrCreate
        - name: pods-mount-dir
          hostPath:
            path: /var/lib/kubelet/pods
            type: Directory
        - name: fuse-device
          hostPath:
            path: /dev/fuse
        - name: systemd-control
          hostPath:
            path: /run/systemd
            type: DirectoryOrCreate
```

### D.4 与上游的差异 / 注意

- **命名空间统一 `minio-system`**（SA / StatefulSet / DaemonSet / Service + ClusterRoleBinding 的 `subjects.namespace`），与 4.4 Secret、附录 A 的 `kubectl -n minio-system ...` 对齐。上游默认 `kube-system`，想放回去也行，但 Secret 和巡检命令要跟着改。
- **三处镜像**按 4.3 的 sed 映射改成 `harbor.local.clusters/minio/…`。
- **Pod 标签**：provisioner 是 `app=csi-s3-provisioner`，node driver 是 `app=csi-s3`。定位日志：
  `kubectl -n minio-system logs -l app=csi-s3-provisioner --all-containers` /
  `kubectl -n minio-system logs -l app=csi-s3 -c csi-s3`。
- **DaemonSet 的 `privileged` + `SYS_ADMIN` + `/dev/fuse` + `/run/systemd` + `mountPropagation: Bidirectional` 不能删** —— 这些是 geesefs 由宿主机 systemd 起、挂载点双向传播回宿主机的前提（也是本文档为什么 endpoint 不能用 Service DNS 名的根因，见 4.1）。
- `kubelet` 根目录按默认 `/var/lib/kubelet`；若集群改过（少见），上面所有 `hostPath` 和 socket 路径要跟着改。
