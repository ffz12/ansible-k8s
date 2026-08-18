# 仓库合并盘点：ansible-ai → ansible-k8s

> 2026-08-18 盘点。结论：**以 ansible-k8s 为主库**，把 ansible-ai 独有内容并进来。
> 合库动作本身**等青岛联通验收签字之后**再做，理由见文末「为什么不现在动」。

## 一、为什么要合

维护两个仓库的成本在这两周里已经实测出来了：

- 每个改动要 **两次 commit + 两次 push**，commit message 还得手改交叉引用
- 钩子有 **4 份** 要同步（两仓库 × `scripts/git-hooks/` 源文件 + `.git/hooks/` 已安装）
- 出过一次真实事故：镜像 `tmp/env.yaml.example` 时整文件 `cp` 覆盖，**删掉了 ansible-k8s 独有的 139 行**（`is_offline` / `k8s_version` / CNI / etcd 段），靠暂存后 diffstat 的 `-139` 才发现
- 出过一次「改了但没交付」：`pre-commit` 的占位符修复只改了 `.git/hooks/`，没改入库源文件 `scripts/git-hooks/`，而 `init.sh` 每次都从后者**覆盖安装** —— 跑一次 `init.sh` 修复就被冲回旧版

失败方式是**静默删除 / 静默失效**，不是报错。这是必须合的理由。

## 二、为什么主库是 ansible-k8s，不是 ansible-ai

一度判断该用 ansible-ai，因为「docker / containerd 相关都在 ansible-ai，只差 k8s 离线」。
盘点后发现这个前提不成立：**ansible-k8s 两样都有，而且组织得更好**。

平铺 `ls roles` 对比会得出「有 5 个 role 只在 ansible-ai 有」，这是**误导性的** ——
其中 4 个 k8s 侧都有，只是被收进分组目录并改成连字符命名，所以平铺看不见：

| ansible-ai（顶层散放，下划线） | ansible-k8s（分组目录，连字符） | 内容核对 |
|---|---|---|
| `docker` | `docker/docker-install` | `files/` 下 5 个文件 **md5 逐一相同** |
| `cri-dockerd` | `docker/cri-dockerd` | — |
| `update-docker-daemon` | `docker/docker-daemon` | — |
| `update-docker-gpu` | `docker/docker-gpu` | — |
| `containerd_install` | `containerd/containerd-install` | 文件名逐个对得上 |
| `containerd_setup` | `containerd/containerd-setup` | 4 个 `.j2` 模板全在 |

ansible-k8s 领先的四点：

1. **命名已统一** 成 `<对象>-<动作>.yaml`，全连字符 —— 这是之前在 ansible-k8s 侧**专门做过一次的重命名**，
   现在 `playbook/` 下 **0 个 `.yml`、0 个带下划线**的文件。而 ansible-ai 还留着 12 个旧名：
   `add-control-key.yml`、`deploy-cfss.yml`、`deploy-trust-harbor.yml`、`remove-control-key.yml`、
   `set_root_password.yml`、`ssh-passwordless{,-remove}.yml`、`test-offline-path.yml`、
   `change_yum.yaml`、`install_ceph.yaml`、`mount_nvme{,_lvm}.yaml`。
   → 拿 ansible-ai 当主库，等于把这次重命名的成果作废重做一遍
2. **playbook 入口 37 个 vs 23 个**，多出的是完整 k8s 链：`k8s-init-master`、`k8s-add-master`、`k8s-add-node`、`k8s-del-node`、`k8s-cni` / `k8s-cni-switch`、`k8s-reset`、`etcd-deploy` / `etcd-scale-up` / `etcd-scale-down` / `etcd-destroy`
3. **有 `docs/` 目录**（ceph、containerd、minio-csi-s3、gpu-ib-install、系统维护相关 等 10 篇）；ansible-ai 的文档散在仓库根目录
4. 补齐了删除类 role：`containerd/containerd-remove`、`docker/docker-remove`、`remove/remove-haproxy-ha`

反向做（拿 ansible-ai 当主库）的代价：要把 37 个入口和分组结构**倒着搬回**顶层散放 + 混合命名，
等于主动放弃已经做完的规范化；或者搬完再统一改名 —— 那就是把 ansible-ai 改造成 ansible-k8s，不如直接用后者。

## 三、ansible-ai 独有、必须搬过去的内容

只有两类，都不是 k8s/qdlt 主线代码：

**1）二进制内核包（8 个 rpm）**

```
kernel/files/update_kernel/kernel-lt{,-devel,-headers}-5.4.272-1.el7.elrepo.x86_64.rpm      # CentOS 7
gpu-init/files/openEuler-kernel-pkg/kernel{,-devel,-headers,-tools,-tools-devel}-5.10.0-182.0.0.95.oe2203sp3.x86_64.rpm
```

⚠ 这是 CentOS 7 / openEuler 的包，**和青岛的 Ubuntu 22.04 无关**，不影响 qdlt 交付。
搬之前先确认还有没有在用的存量环境 —— 如果没有，更该考虑的是删掉而不是搬（仓库里放二进制会一直背着体积）。

**2）两个 remove role（同功能，k8s 侧已改名，核对后大概率不用搬）**

| ansible-ai | ansible-k8s 对应 |
|---|---|
| `remove/remove-containerd` | `containerd/containerd-remove` |
| `remove/remove-docker` | `docker/docker-remove` |

## 四、playbook 入口的改名对照

合库时最容易搞错的地方：两边**同功能不同文件名**，`ls` 对比会显示成「各有独有文件」，
实际是同一个入口改过名。核对时按功能对，不要按文件名对。

| 功能 | ansible-ai（旧名） | ansible-k8s（现名） |
|---|---|---|
| 下发控制机公钥 | `add-control-key.yml` | `add-control-key.yaml` |
| 移除控制机公钥 | `remove-control-key.yml` | `remove-control-key.yaml` |
| 装 ceph | `install_ceph.yaml` | `ceph-install.yaml` |
| 换 yum 源 | `change_yum.yaml` | `change-yum.yaml` |
| 删 containerd | `containerd-rm.yaml` | `containerd-remove.yaml` |
| 删 docker | `docker-rm.yaml` | `docker-remove.yaml` |
| 删 harbor | `harbor-rm.yaml` | `harbor-remove.yaml` |
| 改 docker 配置 | `update-docker-file.yaml` | `docker-config-update.yaml` |
| 更新 GPU | `update-gpu.yaml` | `gpu-update.yaml` |
| 信任 harbor CA | `deploy-trust-harbor.yml` | `harbor-trust.yaml` |
| 挂 NVMe | `mount_nvme.yaml` / `mount_nvme_lvm.yaml` | `mount-nvme.yaml` / `mount-nvme-lvm.yaml` |
| 离线初始化 | `offline-init.yaml` | `init-offline.yaml` |
| 改 root 密码 | `set_root_password.yml` | `set-root-password.yaml` |
| haproxy LB | `haproxy-ha-install.yaml` | `lb-haproxy-install.yaml` |
| nginx LB | `nginx-ha-install.yaml` / `remove-nginx-ha.yaml` | `lb-nginx-install.yaml` / `lb-nginx-remove.yaml` |
| LB 扩缩容 | `scale-lb.yaml` / `scale-lb-remove.yaml` | `lb-scale.yaml` / `lb-scale-remove.yaml` |

ansible-ai 侧**真正没有对应物**的入口（合库时要判断是否还需要）：
`install.yaml`、`deploy-cfss.yml`、`test-offline-path.yml`。

## 五、共有 role 的漂移清单（合库时必须逐个核对）

15 个共有 role 里，**12 个文件** md5 不同。这是唯一需要人工判断「取哪一边」的部分：

| role | 内容不同的文件数 | 备注 |
|---|---|---|
| `certs` | 2 | k8s 侧多一个 `files/.gitkeep` |
| `container-toolkit` | 1 | |
| `haproxy-ha` | 2 | |
| `harbor` | 3 | |
| `init` | 3 | |
| `nginx-ha` | 2 | |
| `docker` → `docker/docker-install` | 1 | 仅 `tasks/main.yml` 不同，`files/` 5 个全同 |

**完全一致、不用管的**：`ceph`、`gpu-init`（除 rpm）、`kernel`（除 rpm）、`trust-harbor-ca`、
以及青岛交付三件套 **`qdlt-init`（19 个文件）、`qdlt-check`、`qdlt-report`** —— 这三个 role 两边逐字节相同，
说明「改一处、镜像另一处、各自提交」的纪律是有效的，只是成本高。

## 六、绝对不能整文件覆盖的文件

镜像时这几个必须**只改目标段落**，`cp` 覆盖会静默删内容：

| 文件 | 为什么 |
|---|---|
| `tmp/env.yaml.example` | **结构性不同**：k8s 侧多 `is_offline` / `harbor_project` / `k8s_version` / `kube_network_plugin` / calico & cilium 参数 / `etcd_version` / `etcd_install_dir` / `etcd_data_dir` 等约 139 行。已经误删过一次 |
| `tmp/hosts.example` | 同理，k8s 侧有 `[k8slb]`、etcd、master/node 分组 |
| `inventory/group_vars/all/defaults.yaml` | 未逐行核对，合库前必须先 diff |
| `ansible.cfg` | 未逐行核对，合库前必须先 diff |

## 七、合库步骤（验收之后再执行）

1. 在 ansible-k8s 开分支 `merge/from-ansible-ai`，**不要直接推 master**
2. 逐行 diff 第六节那 4 个文件，把 ansible-ai 侧的有效差异并进来
3. 核对第五节那 12 个漂移文件，逐个决定取哪一边（取 ansible-ai 版的要在 commit message 里说明理由）
4. 搬第三节的 8 个 rpm —— 或确认无存量环境后**不搬**
5. ansible-ai 根目录的文档并进 `docs/`；`青岛联通交付-系统初始化.md` 已在 `docs/` 下，无需动
6. 全量 `--check` 跑一遍每个入口，确认没有断掉的 role 引用
7. 合进 master 后，**ansible-ai 转为只读归档**（README 首行写明「已合并至 ansible-k8s，不再维护」），**不要删**
8. 删掉这两周为镜像而生的约定：不再需要「两次 commit」、四份钩子同步

## 八、为什么不现在动

青岛联通的 governor 修复**还没落到任何一台机器上**（`--tags cpu` 至今一次都没跑成功过），
重启后 6 台里有 4 台 governor 仍会掉回 `ondemand`。

合库要动 `defaults.yaml` / `env.yaml` / `inventory` 三处的变量合流，还要改分支和路径引用。
这时候合，出问题会和验收问题混在一起，分不清是谁造成的。

**时机：青岛验收签字之后。** 在那之前继续按「改一处、镜像另一处、各自提交」执行。
