# containerd 安装
## 下载安装

```bash
wget https://github.com/containerd/containerd/releases/download/v2.2.3/containerd-2.2.3-linux-amd64.tar.gz
tar xvf containerd-2.2.3-linux-amd64.tar.gz 
cp bin/*  /usr/local/bin/
```
```bash
tee /usr/lib/systemd/system/containerd.service <<eof
# Copyright The containerd Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
# Comment TasksMax if your systemd version does not supports it.
# Only systemd 226 and above support this version.
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
eof
```
## 环境配置
```bash
 mkdir -p /etc/containerd
 containerd config default > /etc/containerd/config.toml
 
 1.SystemdCgroup
 [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
  SystemdCgroup = true
 
 2.Sandbox Image 
 [plugins."io.containerd.cri.v1.images".pinned_images]
  sandbox = "registry.aliyuncs.com/google_containers/pause:3.10"
 
 3.Registry Config Path
 [plugins."io.containerd.cri.v1.images".registry]
  config_path = "/etc/containerd/certs.d" 
  
 mkdir -p /etc/containerd/certs.d/docker.io 

 cat > /etc/containerd/certs.d/docker.io/hosts.toml <<EOF
server = "https://docker.io"

[host."https://docker.hlmirror.com"]
  capabilities = ["pull", "resolve"]

[host."https://docker.1ms.run"]
  capabilities = ["pull", "resolve"]

[host."https://proxy.1panel.live"]
  capabilities = ["pull", "resolve"]

[host."https://docker.m.daocloud.io"]
  capabilities = ["pull", "resolve"]

[host."https://hub1.nat.tf"]
  capabilities = ["pull", "resolve"]

[host."https://hub2.nat.tf"]
  capabilities = ["pull", "resolve"]

[host."https://docker.ketches.cn"]
  capabilities = ["pull", "resolve"]
EOF

system restart containerd

```
## crictl配置
```bash
# 下载针对 Linux AMD64 的 1.32.0 版本
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.32.0/crictl-v1.32.0-linux-amd64.tar.gz

# 解压并安装
tar zxvf crictl-v1.32.0-linux-amd64.tar.gz -C /usr/local/bin
rm -f crictl-v1.32.0-linux-amd64.tar.gz

# 验证版本
crictl --version
# 预期输出: crictl version v1.32.0


tee /etc/crictl.yaml <<eof
runtime-endpoint: "unix:///run/containerd/containerd.sock"
image-endpoint: "unix:///run/containerd/containerd.sock"
timeout: 10
debug: false
pull-image-on-create: false
eof

time crictl pull nginx:latest
```
## 配置gpu驱动
```bash
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk cdi list

nvidia-ctk runtime configure --runtime=containerd
systemctl restart containerd

#修改containerd默认运行时
grep -r default_runtime_name /etc/containerd/
/etc/containerd/conf.d/99-nvidia.toml:      default_runtime_name = "runc"
/etc/containerd/config.toml:      default_runtime_name = "nvidia"

sed -i 's/default_runtime_name = "runc"/default_runtime_name = "nvidia"/g' /etc/containerd/conf.d/99-nvidia.toml

systemctl restart containerd 

#检查默认runc
containerd config dump | grep "default_runtime_name"
      default_runtime_name = 'nvidia'

```

## 测试
```bash
ctr -n k8s.io run --rm --device nvidia.com/gpu=0 \
docker.io/library/python:3.11-slim \
test-device nvidia-smi
```
## 部署nvidia-device-plugin插件
```bash
vim nvidia-device-plugin.yaml
```
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      priorityClassName: "system-node-critical"
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: gpu
                operator: In
                values:
                - "true"
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
      containers:
      - image: nvcr.io/nvidia/k8s-device-plugin:v0.19.0
        name: nvidia-device-plugin-ctr
        securityContext:
          privileged: true
        env:
          - name: FAIL_ON_INIT_ERROR
            value: "false"
          - name: NVIDIA_CTK_PATH
            value: "none"
          # 关键 1：明确告诉容器去哪里找 NVML 库
          - name: LD_LIBRARY_PATH
            value: "/usr/lib/x86_64-linux-gnu"
        args:
          - "--device-discovery-strategy=nvml"
          - "--fail-on-init-error=false"
          # 关键 2：既然你已经有 CDI 文件了，这里用 envvar 保持纯净
          - "--device-list-strategy=envvar"
        volumeMounts:
          - name: device-plugin
            mountPath: /var/lib/kubelet/device-plugins
          # 关键 3：只挂载库文件目录，不挂载任何 /etc 里的东西
          - name: host-libs
            mountPath: /usr/lib/x86_64-linux-gnu
            readOnly: true
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
        - name: host-libs
          hostPath:
            path: /usr/lib/x86_64-linux-gnu

```
```bash
k apply -f nvidia-device-plugin.yaml

k get po -n kube-sysetm

#部署容器运行时类
tee nvidia-RuntimeClass.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
eof

k apply -f nvidia-RuntimeClass.yaml
```
## pod调度指定运行时类
```bash
tee deploy1.yaml <<eof
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-1
spec:
  selector:
    matchLabels:
      app: demo-1
  replicas: 1
  template:
    metadata:
      labels:
        app: demo-1
    spec:
      runtimeClassName: nvidia
      containers:
      - name: demo-1
        image: nginx:latest
        command:
        - sleep
        - 10m
        resources:
          limits:
            cpu: 4
            memory: 32Gi
            nvidia.com/gpu: 1
eof

k apply -f deploy1.yaml
```
## pod调度不指定运行时类
```bash
tee deploy2.yaml <<eof
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-2
spec:
  selector:
    matchLabels:
      app: demo-2
  replicas: 1
  template:
    metadata:
      labels:
        app: demo-2
    spec:
      containers:
      - name: demo-2
        image: nginx:latest
        command:
        - sleep
        - 10m
        resources:
          limits:
            cpu: 4
            memory: 32Gi
            nvidia.com/gpu: 1
eof

k apply -f deploy2.yaml

k exec -it `k get po  |awk '/demo/{print $1}'` -- nvidia-smi
Thu Apr 23 08:07:09 2026
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 570.124.06             Driver Version: 570.124.06     CUDA Version: 12.8     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA TITAN Xp                On  |   00000000:04:00.0 Off |                  N/A |
| 23%   21C    P8              7W /  250W |       2MiB /  12288MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|  No running processes found                                                             |
+-----------------------------------------------------------------------------------------+
```