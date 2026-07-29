# ansible-k8s

[![Ansible](https://img.shields.io/badge/Ansible-2.8.8+-blue.svg)](https://www.ansible.com/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.28%20%7C%201.34-326ce5.svg)](https://kubernetes.io/)

## 项目简介

`ansible-k8s` 是一套用 Ansible 部署 Kubernetes 及其底座的工具集，覆盖从**系统初始化 → 数据盘挂载 → containerd → docker/harbor → 负载均衡 → 外置 etcd → k8s 控制面/worker → CNI（calico/flannel/cilium）** 的全链路，支持**在线/离线**两套物料路径与**双架构（amd64/arm64）**。

核心特性：

- **在线/离线双支持**：一个 `is_offline` 开关切换——在线直连公共 mirror，离线全走本地 Harbor + bundled tar。
- **多 CNI 可插拔**：`kube_network_plugin` 一个变量切 `calico` / `flannel` / `cilium`。
- **多版本 K8s**：`k8s_version` 单一真源，配套组件自动派生（当前在用 1.28 / 1.34）。
- **外置二进制 etcd**、apiserver 高可用（haproxy / nginx-ha + keepalived）、集群 root 免密一键互信。
- **Ansible 2.8.8 兼容**（Kylin V10 SP3）：全短模块名，按 `ansible_distribution` 判族。

## 文档导航

| 文档 | 内容 |
|---|---|
| **[部署说明.md](部署说明.md)** | **主部署手册**：inventory / 变量 / SSH 免密 / init / 挂盘 / containerd / docker / harbor / LB / etcd / k8s / CNI 切换 / 离线部署 / 常见问题排查 |
| [AI应用与调度.md](AI应用与调度.md) | 集群装好后的上层：GPU device-plugin / Prometheus / network-operator(RDMA) / MPI Job(nccl) / 调度器 binpack / Volcano / Rayjob / nsight / 镜像同步脚本 |
| [gpu-ib-install.md](gpu-ib-install.md) | IB 网卡驱动 / GPU 驱动 / nvidia-container-toolkit / fabricmanager / peermem |
| [containerd.md](containerd.md) | containerd 手工安装、crictl、GPU 运行时、device-plugin、RuntimeClass 调度 |
| [ceph.md](ceph.md) | Ceph 安装与配置（含 BIOS 调优、内核升级） |
| [系统维护相关.md](系统维护相关.md) | Ubuntu 网络/apt/内核锁定、NFS、OpenELB、Docker Rootless、Jenkins、K8s 问题汇总 |
| [docker-user.md](docker-user.md) | Docker 调试方法 |
| [git操作说明.md](git操作说明.md) | Git / Git LFS 操作（克隆、按需拉大文件、提交、分支、回滚） |

## 目录结构

- `playbook/`：Ansible Playbook + roles
- `inventory/`：主机清单 `hosts`（由 `init.sh` 生成）与组变量 `group_vars/all/`（`defaults.yaml` 提交、`env.yaml` 本地私有）
- `offline/`：离线物料下载脚本与 `artifacts/`（大文件走 Git LFS，见 [git操作说明.md](git操作说明.md)）
- `scripts/`：单机初始化等辅助脚本
- `tmp/hosts.example`：inventory 模板

## 快速上手

```bash
# 1. 克隆（日常开发可只取代码、按需再拉 LFS 大文件，见 git操作说明.md）
git clone git@codeup.aliyun.com:68e89ecdf9c52e7d8c269ad7/ansible-k8s.git
cd ansible-k8s

# 2. 生成 inventory 骨架并填主机清单/变量
./init.sh
vim inventory/hosts                       # 参考 tmp/hosts.example
vim inventory/group_vars/all/env.yaml     # 域名/密码/版本/CNI/is_offline 等

# 3. 配置集群 root 免密互信（首次带 -k 输密码）
ansible-playbook playbook/ssh-passwordless.yaml -k

# 4. 按《部署说明.md》整体流程走：init → 挂盘 → containerd → docker/harbor → etcd → k8s → CNI
```

> 完整分步命令、在线/离线差异、单/多 master、CNI 切换、离线打包与排错，全部见 **[部署说明.md](部署说明.md)**。

## 前置条件

- 控制节点已装 Ansible（2.8.8+；Kylin V10 SP3 用系统自带 2.8.8）
- 目标节点已装 Python 3、SSH 可达（免密由 `ssh-passwordless.yaml` 一键配）
- 离线场景：先按《部署说明.md》「离线部署」在联网机打包物料

## 许可证

本项目采用 MIT 许可证。详情见 [LICENSE](LICENSE)。
