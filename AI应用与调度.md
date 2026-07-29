# AI 应用与调度手册（ansible-k8s）

> 本手册收录**集群装好之后**的上层 AI 应用、调度策略与运维脚本。
> 集群本身的部署（init/containerd/docker/harbor/LB/etcd/k8s/CNI/离线）见 [部署说明.md](部署说明.md)；
> GPU/IB 驱动见 [gpu-ib-install.md](gpu-ib-install.md)。
>
> ⚠️ 文中示例仓库地址 `harbor.unisound.ai`、镜像/凭据等请按你自己的环境替换；**切勿把真实密码/Token 提交进仓库**。

## 目录

- [监控与插件](#监控与插件)（GPU device-plugin / Prometheus / registry 代理 / network-operator）
- [MPI Job](#mpi-job)
- [k8s 原生调度器支持 binpack](#k8s-原生调度器支持-binpack)
- [Volcano 设置调度策略 binpack](#volcano-设置调度策略-binpack)
- [Volcano](#volcano)
- [Rayjob](#rayjob)
- [nsight-operator](#nsight-operator)
- [镜像备份 / 同步脚本（skopeo）](#镜像备份--同步脚本skopeo)

## 监控与插件

### GPU 设备插件

```bash
cd monitor/k8s-device-plugin
./setup
```

### Prometheus

```bash
curl -k -X POST "https://${HARBOR_URL}/api/v2.0/projects" \
  -u "admin:<HARBOR_PASSWORD>" \
  -H "Content-Type: application/json" \
  -d '{
    "project_name": "'"${HARBOR_PROJECT}"'",
    "public": false
  }'
cd /monitor/prometheus-install
./upload_to_harbor.sh
./set.sh
cd /monitor/
sed -i 's/harbor.unify.ai/harbor.unisound.ai/g' *.yaml
kubectl apply -f prometheus-rule/
```
### registry部署
```bash
 cat /data1/docker-compose.yml
services:
  registry-proxy:
    image: registry:2
    ports:
      - "5000:5000"
    environment:
      # 代理缓存核心配置
      - REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io

      # 网络代理配置（建议大小写全写，增强兼容性）
      - http_proxy=http://10.10.20.200:3129
      - https_proxy=http://10.10.20.200:3129
      - no_proxy=localhost,127.0.0.1

      # 可选：如果 Docker Hub 频繁触发频率限制，可以配置账号
      - REGISTRY_PROXY_USERNAME=<DOCKERHUB_USER>
      - REGISTRY_PROXY_PASSWORD=<DOCKERHUB_TOKEN>
    volumes:
      - ./config.yml:/etc/docker/registry/config.yml
      - /data1/registry:/var/lib/registry
    deploy:
      resources:
        limits:
          cpus: '36'
          memory: 256G
    restart: always

```
```bash
 cat /data1/config.yml
version: 0.1
log:
  level: info
  formatter: text
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :5000
  headers:
    X-Content-Type-Options: [nosniff]
proxy:
  remoteurl: https://registry-1.docker.io
  username: <DOCKERHUB_USER>
  password: <DOCKERHUB_TOKEN>

```
```bash
docker compose up -d 
```

### NVIDIA network-operator

```bash
#新版本
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm search  repo   network-operator
helm pull  nvidia/network-operator --untar  --version 26.1.0
#去空行
grep -vE '^\s*(#|$)' network-operator/values.yaml

#旧版本
cd network 
tree -L 1  network
network
├── download.sh                    #从harbor.unisound.ai/unisund 拷贝脚本
├── network-operator
├── network_operator_images.tar    #镜像包
└── upload.sh                      #上传harbor.unisound.ai/unisund 
#原版本
grep -vE '^\s*(#|$)' values.yaml
nfd:
  enabled: true
psp:
  enabled: false
sriovNetworkOperator:
  enabled: false
node-feature-discovery:
  image:
    pullPolicy: IfNotPresent
  nodeFeatureRule:
    createCRD: false
  master:
    instance: "nvidia.networking"
  worker:
    tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "present"
        effect: "NoSchedule"
    config:
      sources:
        pci:
          deviceClassWhitelist:
            - "02"
            - "0200"
            - "0207"
          deviceLabelFields:
            - vendor
sriov-network-operator:
  operator:
    tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
    nodeSelector: {}
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: "node-role.kubernetes.io/master"
                  operator: In
                  values: [ "" ]
            - matchExpressions:
                - key: "node-role.kubernetes.io/control-plane"
                  operator: In
                  values: [ "" ]
    nameOverride: ""
    fullnameOverride: ""
    resourcePrefix: "nvidia.com"
    enableAdmissionController: false
    cniBinPath: "/opt/cni/bin"
    clusterType: "kubernetes"
  images:
    operator: nvcr.io/nvidia/mellanox/sriov-network-operator:network-operator-1.4.0
    sriovConfigDaemon: nvcr.io/nvidia/mellanox/sriov-network-operator-config-daemon:network-operator-1.4.0
    sriovCni: ghcr.io/k8snetworkplumbingwg/sriov-cni:v2.6.3
    ibSriovCni: ghcr.io/k8snetworkplumbingwg/ib-sriov-cni:848e3b4c97c17d8cb0fcf09aa1358edd0354db4f
    sriovDevicePlugin: ghcr.io/k8snetworkplumbingwg/sriov-network-device-plugin:v3.5.1
    resourcesInjector: ghcr.io/k8snetworkplumbingwg/network-resources-injector:v1.4
    webhook: ghcr.io/k8snetworkplumbingwg/sriov-network-operator-webhook:v1.1.0
operator:
  tolerations:
    - key: "node-role.kubernetes.io/master"
      operator: "Equal"
      value: ""
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Equal"
      value: ""
      effect: "NoSchedule"
  nodeSelector: {}
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 1
          preference:
            matchExpressions:
              - key: "node-role.kubernetes.io/master"
                operator: In
                values: [""]
        - weight: 1
          preference:
            matchExpressions:
              - key: "node-role.kubernetes.io/control-plane"
                operator: In
                values: [ "" ]
  repository: nvcr.io/nvidia/cloud-native
  image: network-operator
  nameOverride: ""
  fullnameOverride: ""
imagePullSecrets: []
deployCR: false
ofedDriver:
  deploy: false
  image: mofed
  repository: nvcr.io/nvidia/mellanox
  version: 5.9-0.5.6.0
  terminationGracePeriodSeconds: 300
  repoConfig:
    name: ""
  certConfig:
    name: ""
  startupProbe:
    initialDelaySeconds: 10
    periodSeconds: 20
  livenessProbe:
    initialDelaySeconds: 30
    periodSeconds: 30
  readinessProbe:
    initialDelaySeconds: 10
    periodSeconds: 30
  upgradePolicy:
    autoUpgrade: false
    maxParallelUpgrades: 0
    drain:
      enable: true
      force: false
      podSelector: ""
      timeoutSeconds: 300
      deleteEmptyDir: false
nvPeerDriver:
  deploy: false
  image: nv-peer-mem-driver
  repository: mellanox
  version: 1.1-0
  gpuDriverSourcePath: /run/nvidia/driver
rdmaSharedDevicePlugin:
  deploy: true
  image: k8s-rdma-shared-dev-plugin
  repository: nvcr.io/nvidia/cloud-native
  version: v1.3.2
  resources:
    - name: rdma_shared_device_a
      vendors: [15b3]
sriovDevicePlugin:
  deploy: true
  image: sriov-network-device-plugin
  repository: ghcr.io/k8snetworkplumbingwg
  version: v3.5.1
  resources:
    - name: hostdev
      vendors: [15b3]
ibKubernetes:
  deploy: false
  image: ib-kubernetes
  repository: ghcr.io/mellanox
  version: v1.0.2
  periodicUpdateSeconds: 5
  pKeyGUIDPoolRangeStart: "02:00:00:00:00:00:00:00"
  pKeyGUIDPoolRangeEnd: "02:FF:FF:FF:FF:FF:FF:FF"
  ufmSecret: # specify the secret name here
secondaryNetwork:
  deploy: true
  cniPlugins:
    deploy: true
    image: plugins
    repository: ghcr.io/k8snetworkplumbingwg
    version: v0.8.7-amd64
  multus:
    deploy: false
    image: multus-cni
    repository: ghcr.io/k8snetworkplumbingwg
    version: v3.8
    config: ''
  ipoib:
    deploy: false
    image: ipoib-cni
    repository: nvcr.io/nvidia/cloud-native
    version: v1.1.0
  ipamPlugin:
    deploy: true
    image: whereabouts
    repository: ghcr.io/k8snetworkplumbingwg
    version: v0.5.4-amd64
test:
  pf: ens2f0

#network-operator/values.yaml以下是做了私有仓库的版本

grep -vE '^\s*(#|$)' network-operator/values.yaml
nfd:
  enabled: true
psp:
  enabled: false
sriovNetworkOperator:
  enabled: false
node-feature-discovery:
  image:
    pullPolicy: IfNotPresent
  nodeFeatureRule:
    createCRD: false
  master:
    instance: "nvidia.networking"
  worker:
    tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Equal"
        value: ""
        effect: "NoSchedule"
      - key: "nvidia.com/gpu"
        operator: "Equal"
        value: "present"
        effect: "NoSchedule"
    config:
      sources:
        pci:
          deviceClassWhitelist:
            - "02"
            - "0200"
            - "0207"
          deviceLabelFields:
            - vendor
sriov-network-operator:
  operator:
    tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
    nodeSelector: {}
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: "node-role.kubernetes.io/master"
                  operator: In
                  values: [ "" ]
            - matchExpressions:
                - key: "node-role.kubernetes.io/control-plane"
                  operator: In
                  values: [ "" ]
    nameOverride: ""
    fullnameOverride: ""
    resourcePrefix: "nvidia.com"
    enableAdmissionController: false
    cniBinPath: "/opt/cni/bin"
    clusterType: "kubernetes"
  images:
    operator: harbor.unisound.ai/unisound/mellanox/sriov-network-operator:network-operator-1.4.0
    sriovConfigDaemon: harbor.unisound.ai/unisound/sriov-network-operator-config-daemon:network-operator-1.4.0
    sriovCni: harbor.unisound.ai/unisound/sriov-cni:v2.6.3
    ibSriovCni:  harbor.unisound.ai/unisound/ib-sriov-cni:848e3b4c97c17d8cb0fcf09aa1358edd0354db4f
    sriovDevicePlugin: harbor.unisound.ai/unisound/sriov-network-device-plugin:v3.5.1
    resourcesInjector:  harbor.unisound.ai/unisound/network-resources-injector:v1.4
    webhook:  harbor.unisound.ai/unisound/sriov-network-operator-webhook:v1.1.0
operator:
  tolerations:
    - key: "node-role.kubernetes.io/master"
      operator: "Equal"
      value: ""
      effect: "NoSchedule"
    - key: "node-role.kubernetes.io/control-plane"
      operator: "Equal"
      value: ""
      effect: "NoSchedule"
  nodeSelector: {}
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 1
          preference:
            matchExpressions:
              - key: "node-role.kubernetes.io/master"
                operator: In
                values: [""]
        - weight: 1
          preference:
            matchExpressions:
              - key: "node-role.kubernetes.io/control-plane"
                operator: In
                values: [ "" ]
  repository: harbor.unisound.ai/unisound/cloud-native
  image: network-operator
  nameOverride: "v23.1.0"
  fullnameOverride: ""
imagePullSecrets: []
deployCR: true
ofedDriver:
  deploy: false
  image: mofed
  repository: nvcr.io/nvidia/mellanox
  version: 5.9-0.5.6.0
  terminationGracePeriodSeconds: 300
  repoConfig:
    name: ""
  certConfig:
    name: ""
  startupProbe:
    initialDelaySeconds: 10
    periodSeconds: 20
  livenessProbe:
    initialDelaySeconds: 30
    periodSeconds: 30
  readinessProbe:
    initialDelaySeconds: 10
    periodSeconds: 30
  upgradePolicy:
    autoUpgrade: false
    maxParallelUpgrades: 0
    drain:
      enable: true
      force: false
      podSelector: ""
      timeoutSeconds: 300
      deleteEmptyDir: false
nvPeerDriver:
  deploy: false
  image: nv-peer-mem-driver
  repository: mellanox
  version: 1.1-0
  gpuDriverSourcePath: /run/nvidia/driver
rdmaSharedDevicePlugin:
  deploy: true
  image: k8s-rdma-shared-dev-plugin
  repository: harbor.unisound.ai/unisound
  version: v1.3.2
  resources:
    - name: rdma_shared_device_a
      vendors: [15b3]
sriovDevicePlugin:
  deploy: true
  image: sriov-network-device-plugin
  repository: harbor.unisound.ai/unisound
  version: v3.5.1
  resources:
    - name: hostdev
      vendors: [15b3]
ibKubernetes:
  deploy: false
  image: ib-kubernetes
  repository: harbor.unisound.ai/unisound/mellanox
  version: v1.0.2
  periodicUpdateSeconds: 5
  pKeyGUIDPoolRangeStart: "02:00:00:00:00:00:00:00"
  pKeyGUIDPoolRangeEnd: "02:FF:FF:FF:FF:FF:FF:FF"
  ufmSecret: ""
secondaryNetwork:
  deploy: true
  cniPlugins:
    deploy: true
    image: plugins
    repository: harbor.unisound.ai/unisound/k8snetworkplumbingwg
    version: v0.8.7-amd64
  multus:
    deploy: false
    image: multus-cni
    repository: ghcr.io/k8snetworkplumbingwg
    version: v3.8
    config: ''
  ipoib:
    deploy: false
    image: ipoib-cni
    repository: nvcr.io/nvidia/cloud-native
    version: v1.1.0
  ipamPlugin:
    deploy: true
    image: whereabouts
    repository:  harbor.unisound.ai/unisound
    version: v0.5.4-amd64
test:
  pf: ens2f0

#使用helm安装
helm upgrade --install network-operator ./network-operator -n network-operator --create-namespace

#配置HostDeviceNetwork网络
tee mell.yml <<eof
apiVersion: mellanox.com/v1alpha1
kind: HostDeviceNetwork
metadata:
  name: hostdev-net
  namespace: default
spec:
  networkNamespace: "default"
  resourceName: "nvidia.com/hostdev"
  ipam: |
    {
      "type": "whereabouts",
      "datastore": "kubernetes",
      "kubernetes": {
        "kubeconfig": "/etc/cni/net.d/whereabouts.d/whereabouts.kubeconfig"
      },
      "range": "192.168.3.0/24",
      "log_file": "/var/log/whereabouts.log",
      "log_level": "info"
    }
eof

k apply -f ./network-operator/mell.yml
#gpu卡已经安装
k get no  jzgpu17 -ojson |grep nvidia.com
            "network.nvidia.com/operator.mofed.wait": "false",
            "nvidia.com/gpu": "8",
            "nvidia.com/hostdev": "10",
            "nvidia.com/gpu": "8",
            "nvidia.com/hostdev": "10",

    

```

## MPI Job

```bash
#在线安装，也可将其下载下来后，安装
kubectl apply --server-side -f https://raw.githubusercontent.com/kubeflow/mpi-operator/master/deploy/v2beta1/mpi-operator.yaml

```

```Dockerfile
#nccl测试容器构建
FROM nvcr.io/nvidia/pytorch:24.03-py3
USER root

# 1. 安装基础依赖及编译工具
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
# 增加 build-essential 和 mpi 相关的开发库
RUN apt-get update && apt-get install -y --no-install-recommends \
    pciutils iproute2 pdsh vim wget htop git \
    language-pack-zh-hans openssh-server openssh-client sudo \
    build-essential libopenmpi-dev libopenmpi-dev \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd

# 2. 配置 SSH 权限（跨机 MPI 通信必须）
RUN sed -i 's/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g' /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    sed -i 's/#\(StrictModes \).*/\1no/g' /etc/ssh/sshd_config

# 3. 创建测试用户（UID/GID 可根据实际宿主机调整）
RUN groupadd -f -g 2005 nlp && \
    groupadd -f -g 2011 mpitest && \
    useradd -m -u 2011 -g mpitest -G nlp -s /bin/bash mpitest && \
    echo "mpitest:<CONTAINER_USER_PASSWORD>" | chpasswd && \
    echo 'mpitest ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

# 4. 自动克隆并编译 nccl-tests
# 设置工作目录
WORKDIR /home/mpitest

# 下载并编译 MPI 版本
# MPI=1: 启用多机 MPI 支持
# CUDA_HOME: 指向镜像内默认的 CUDA 路径
#RUN git clone https://github.com/NVIDIA/nccl-tests.git && \
#    cd nccl-tests && \
#    make MPI=1 CUDA_HOME=/usr/local/cuda -j$(nproc)
COPY --chown=mpitest:mpitest nccl-tests ./nccl-tests
RUN cd nccl-tests && \
    make MPI=1 CUDA_HOME=/usr/local/cuda -j$(nproc)


# 设置环境变量，方便直接调用
ENV PATH="/home/mpitest/nccl-tests/build:${PATH}"

WORKDIR /home/mpitest
USER root
```
```shell
#镜像构建

docker build -t harbor.unisound.ai/unisound/h100-nccl-test:v1 .
#下面警告可用忽略
WARNING: current commit information was not captured by the build: failed to read current commit information with git rev-parse --is-inside-work-tree

#单卡测试
docker run --gpus all --net=host -it harbor.unisound.ai/unisound/h100-nccl-test:v1 all_reduce_perf_mpi -b 8 -e 128M -f 2 -g 8
#结果如下：
#       size         count      type   redop    root     time   algbw   busbw  #wrong     time   algbw   busbw  #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)             (us)  (GB/s)  (GB/s)
           8             2     float     sum      -1   103.85    0.00    0.00       0    66.04    0.00    0.00       0
          16             4     float     sum      -1    66.03    0.00    0.00       0    61.75    0.00    0.00       0
          32             8     float     sum      -1    60.80    0.00    0.00       0    59.25    0.00    0.00       0
          64            16     float     sum      -1    56.40    0.00    0.00       0    56.30    0.00    0.00       0
         128            32     float     sum      -1    57.17    0.00    0.00       0    53.77    0.00    0.00       0
         256            64     float     sum      -1    83.48    0.00    0.01       0    54.86    0.00    0.01       0
         512           128     float     sum      -1    54.77    0.01    0.02       0    55.14    0.01    0.02       0
        1024           256     float     sum      -1    54.61    0.02    0.03       0    54.30    0.02    0.03       0
        2048           512     float     sum      -1    54.40    0.04    0.07       0    55.27    0.04    0.06       0
        4096          1024     float     sum      -1    55.22    0.07    0.13       0    55.49    0.07    0.13       0
        8192          2048     float     sum      -1    55.62    0.15    0.26       0    57.67    0.14    0.25       0
       16384          4096     float     sum      -1    56.86    0.29    0.50       0    54.36    0.30    0.53       0
       32768          8192     float     sum      -1    54.54    0.60    1.05       0    53.90    0.61    1.06       0
       65536         16384     float     sum      -1    56.55    1.16    2.03       0    56.19    1.17    2.04       0
      131072         32768     float     sum      -1    61.77    2.12    3.71       0    65.17    2.01    3.52       0
      262144         65536     float     sum      -1    72.39    3.62    6.34       0    70.74    3.71    6.49       0
      524288        131072     float     sum      -1    83.96    6.24   10.93       0    83.92    6.25   10.93       0
     1048576        262144     float     sum      -1    83.24   12.60   22.05       0    83.39   12.57   22.01       0
     2097152        524288     float     sum      -1    84.16   24.92   43.61       0    85.53   24.52   42.91       0
     4194304       1048576     float     sum      -1    85.42   49.10   85.93       0    86.65   48.40   84.71       0
     8388608       2097152     float     sum      -1    91.08   92.10  161.17       0    92.32   90.86  159.01       0
    16777216       4194304     float     sum      -1   131.52  127.56  223.23       0   131.06  128.01  224.02       0
    33554432       8388608     float     sum      -1   206.51  162.48  284.34       0   206.28  162.66  284.66       0
    67108864      16777216     float     sum      -1   330.64  202.97  355.19       0   329.24  203.83  356.70       0
   134217728      33554432     float     sum      -1   590.31  227.37  397.89       0   589.61  227.64  398.37       0


```



```Dockerfile
#mpijob 调试容器
FROM nvcr.io/nvidia/pytorch:24.03-py3

#安装软件包（必须安装）
RUN apt update \
    && apt install -y pciutils  iproute2 pdsh vim wget htop git  language-pack-zh-hans openssh-server sudo openssh-client openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd

#设置sshd配置文件

RUN sed -i 's/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g' /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    sed -i 's/#\(StrictModes \).*/\1no/g' /etc/ssh/sshd_config

# update language settings
# RUN for i in `locale | awk -F'=' '{print $1}'` ; do export  $i="zh_CN.UTF-8"; done

# 此处应按照具体情况进行修改：填入使用者host机器的uid、gid、组名、用户名（必须操作）

RUN groupadd -f -g 2005 nlp && groupadd -f -g 2011 mpitest && useradd -m -u 2011 -g mpitest -G nlp -s /bin/bash mpitest \
    && echo 'mpitest ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers && echo "mpitest:<CONTAINER_USER_PASSWORD>" | chpasswd 

# COPY initialize_env.sh /home/mpitest
USER root
```

```bash
docker build -t  harbor.unisound.ai/unisound/pytorch:24.03-py3 . -f Dockerfile
docker push harbor.unisound.ai/unisound/pytorch:24.03-py3 
```
```yaml
apiVersion: kubeflow.org/v2beta1
kind: MPIJob
metadata:
  name: zff-test-v1
spec:
  slotsPerWorker: 8
  runPolicy:
    cleanPodPolicy: Running
  # 关键：保留你原来的自动 SSH 挂载
  #sshAuthMountPath: /home/sunjian/.ssh
  mpiReplicaSpecs:
    Launcher:
      replicas: 1
      template:
        spec:
          volumes:
          - name: data-volume
            hostPath: { path: /fs, type: Directory }
          - name: dshm
            emptyDir: { medium: Memory, sizeLimit: 256Gi }
          containers:
          - name: mpi-launcher
            image: harbor.unisound.ai/unisound/pytorch:24.03-py3
            lifecycle:
               postStart:
                exec:
                 command:
                 - /bin/bash
                 - -c
                 -  sudo /etc/init.d/ssh start
            volumeMounts:
            - { name: data-volume, mountPath: /fs }
            - { name: dshm, mountPath: /dev/shm }
            command: ["/bin/bash", "-c"]
            args:
            - |
              sleep 30d
            resources:
              limits: { cpu: 16, memory: 32Gi }
    Worker:
      replicas: 2
      template:
        metadata:
          labels:
            slime-group: colocate
            nsight.nvidia.com/profile: "true"
        spec:
          affinity:
            podAffinity:
          # 使用 preferred（软亲和），如果一台机器实在塞不下，也会调度到第二台，不会卡住
              preferredDuringSchedulingIgnoredDuringExecution:
              - weight: 100
                podAffinityTerm:
                  labelSelector:
                    matchLabels:
                       slime-group: colocate
                  topologyKey: "kubernetes.io/hostname"
          hostNetwork: false
          #nodeName: gpu24
          dnsConfig:
            nameservers:
            - 223.5.5.5
            - 114.114.114.114
          volumes:
          - name: data-volume
            hostPath: { path: /fs, type: Directory }
          - name: dshm
            emptyDir: { medium: Memory, sizeLimit: 128Gi }
            # hostPath: { path: /dev/shm, type: Directory }  # ← 改用 hostPath
          containers:
          - name: mpi-worker
            lifecycle:
              postStart:
                exec:
                 command:
                 - /bin/bash
                 - -c
                 -  sudo /etc/init.d/ssh start
            image: harbor.unisound.ai/unisound/pytorch:24.03-py3
            securityContext:
              privileged: true
            volumeMounts:
            - { name: data-volume, mountPath: /fs }
            - { name: dshm, mountPath: /dev/shm }
            command: ["/bin/bash", "-c"]
            args:
            - |
              # 自动安装 numactl (如果镜像没带)
              sleep 30d
            resources:
              limits:
                nvidia.com/gpu: 8
                cpu: 64
                memory: 1024Gi
                nvidia.com/hostdev: 10
```
```bash
#执行命令
kubectl apply -f sft6.yml
#检查pod
root@jzcpu101:/fs/atlas/zhaofengfeng_new/mpijob# k get po
NAME                         READY   STATUS    RESTARTS   AGE
zff-test-v1-launcher-4zjvr   1/1     Running   0          14m
zff-test-v1-worker-0         1/1     Running   0          14m
zff-test-v1-worker-1         1/1     Running   0          14m
root@jzcpu101:/fs/atlas/zhaofengfeng_new/mpijob# k exec -it zff-test-v1-launcher-4zjvr -- bash
#进入调试目录
cd /fs/atlas/liuqs
```

```shell
#!/bin/bash
# --- 1. 加载 CUDA 12.8 环境 ---
export CUDA_HOME=/fs/atlas/liuqs/cuda-12.8
export PATH=$CUDA_HOME/bin:$PATH
export LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH

# 验证 CUDA 版本 (可选，调试用)
echo "Current CUDA Version:"
nvcc --version | grep release


# --- NCCL 配置 ---
export NCCL_IB_IFNAME="ib7s400p0,ib7s400p1,ib7s400p2,ib7s400p3,ib7s400p4,ib7s400p5,ib7s400p6,ib7s400p7"
export NCCL_IB_DISABLE=0
export NCCL_NET_GDR_LEVEL=PHB
export NCCL_SOCKET_IFNAME=eth0

# --- MPI Root 权限覆盖 (必须同时设置这两个变量) ---
export OMPI_ALLOW_RUN_AS_ROOT=1
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
# --- 运行命令 ---
# 注意：多机测试时，-g 8 表示每个进程组(即每台机器)有8张卡
# -np 16 表示总共启动16个进程 (2台机器 x 8卡)
NNODES=$(wc -l < /etc/mpi/hostfile)
MASTER_ADDR=$(head -1 /etc/mpi/hostfile | cut -d' ' -f1)

# 自动获取以 ib7s 开头的设备名 (针对你的硬件环境)
HCA_LIST=$(ls /sys/class/infiniband | grep '^ib7s400' | tr '\n' ',' | sed 's/,$//')
echo "Detected IB HCAs: $HCA_LIST"

mpirun --allow-run-as-root \
    -np $NNODES \
    --hostfile /etc/mpi/hostfile \
    --map-by ppr:1:node \
    -mca plm_rsh_args "-i /tmp/.ssh/id_rsa -o StrictHostKeyChecking=no" \
    -x MASTER_ADDR=$MASTER_ADDR \
    -x MASTER_PORT=29503 \
    -x NCCL_DEBUG=INFO \
    -x NCCL_IB_DISABLE=0 \
    -x NCCL_IB_HCA="$HCA_LIST" \
    -x NCCL_IB_GID_INDEX=3 \
    -x NCCL_IB_CUDA_SUPPORT=1 \
    -x NCCL_NET_GDR_LEVEL=2 \
    -x NCCL_SOCKET_IFNAME=bond0,eth0 \
    bash -c '
    echo "Hello from $(hostname), I am process"
    '
```
```bash
sh 4.sh
#以下结果表示调试环境正常
Current CUDA Version:
Cuda compilation tools, release 12.8, V12.8.93
Detected IB HCAs: ib7s400p0,ib7s400p1,ib7s400p2,ib7s400p3,ib7s400p4,ib7s400p5,ib7s400p6,ib7s400p7
Warning: Identity file /tmp/.ssh/id_rsa not accessible: No such file or directory.
Warning: Identity file /tmp/.ssh/id_rsa not accessible: No such file or directory.
Warning: Permanently added 'zff-test-v1-worker-0.zff-test-v1.default.svc' (ED25519) to the list of known hosts.
Warning: Permanently added 'zff-test-v1-worker-1.zff-test-v1.default.svc' (ED25519) to the list of known hosts.
Hello from zff-test-v1-worker-0, I am process
Hello from zff-test-v1-worker-1, I am process
#nccl-test 地址： https://github.com/NVIDIA/nccl-tests
#编译需要cuda环境，以下是在docker里面编译
```


```shell

#!/bin/bash
#我这里命名为5.sh
unset LD_LIBRARY_PATH
export CUDA_HOME=/fs/atlas/liuqs/cuda-12.8
export PATH=$CUDA_HOME/bin:$PATH
export LD_LIBRARY_PATH=$CUDA_HOME/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64

echo "[DEBUG] LD_LIBRARY_PATH is: $LD_LIBRARY_PATH"
echo "[DEBUG] Checking Driver..."
nvidia-smi

# --- 网络配置 ---
export NCCL_IB_IFNAME="ib7s400p0,ib7s400p1,ib7s400p2,ib7s400p3,ib7s400p4,ib7s400p5,ib7s400p6,ib7s400p7"

# --- MPI Root 权限 ---
export OMPI_ALLOW_RUN_AS_ROOT=1
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

# --- 1. 在 Launcher 端解析 hostfile ---
if [ ! -f /etc/mpi/hostfile ]; then
    echo "Error: /etc/mpi/hostfile not found on Launcher!"
    exit 1
fi

NNODES=$(wc -l < /etc/mpi/hostfile)
MASTER_ADDR=$(head -1 /etc/mpi/hostfile | awk '{print $1}')

# 自动获取 IB 设备
HCA_LIST=$(ls /sys/class/infiniband | grep '^ib7s400' | tr '\n' ',' | sed 's/,$//')
echo "Detected IB HCAs: $HCA_LIST"
echo "Total Nodes: $NNODES, Master Addr: $MASTER_ADDR"

# --- 2. 启动 MPI (修复了换行符问题) ---
# 注意：每一行末尾的 \ 后面不能有空格！
mpirun --allow-run-as-root \
    -np "$NNODES" \
    --hostfile /etc/mpi/hostfile \
    --map-by ppr:1:node \
    -x CUDA_HOME \
    -x LD_LIBRARY_PATH \
    -x PATH \
    -x PYTHONPATH \
    -x NCCL_DEBUG=INFO \
    -x NCCL_IB_DISABLE=0 \
    -x NCCL_IB_HCA="$HCA_LIST" \
    -x NCCL_IB_GID_INDEX=3 \
    -x NCCL_IB_CUDA_SUPPORT=1 \
    -x NCCL_NET_GDR_LEVEL=2 \
    -x NCCL_SOCKET_IFNAME=bond0,eth0 \
    -x MASTER_ADDR="$MASTER_ADDR" \
    -x MASTER_PORT=29503 \
    -x OMPI_ALLOW_RUN_AS_ROOT=1 \
    -x OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1 \
    bash -c './nccl-tests/build/all_reduce_perf_mpi -b 256K -e 1024M -f 1.5 -g 8 -n 20 -w 5  -c 1'
echo "MPI Job Finished."
```



```bash
# 解释：
#测试命令：all_reduce_perf_mpi -b 256K -e 1024M -f 1.5 -g 8 -n 20 -w 5 -c 1

#-b 256K: 起始数据量（主要测试小包延迟）。

#-e 1024M: 结束数据量（主要压测大包带宽吞吐）。

#-f 1.5: 数据量增长倍数（每次测试增加 50%）。

#-g 8: 每台机器参与测试的 GPU 数量（H100 为 8 卡）。

#-n 20: 每次测试重复迭代 20 次取平均值。

#-w 5: 预热 5 次（排除初次启动的硬件延迟抖动）。

#-c 1: 开启计算结果校验（确保数据传输 100% 正确）
#预期性能参考 (H100 + 400G NIC)
#在您的环境下，当数据量超过 128MB 后，应观察到以下数值：
#Bus BW: 稳定在 410 - 430 GB/s 左右。
#Alg BW: 稳定在 210 - 230 GB/s 左右。

sh 5.sh 
#测试结果如下：
#                                                              out-of-place                       in-place
#       size         count      type   redop    root     time   algbw   busbw  #wrong     time   algbw   busbw  #wrong
#        (B)    (elements)                               (us)  (GB/s)  (GB/s)             (us)  (GB/s)  (GB/s)

   558104576     139526144     float     sum      -1  2595.80  215.00  403.13       0  2586.87  215.74  404.52       0
   559153152     139788288     float     sum      -1  2582.15  216.55  406.02       0  2590.30  215.86  404.75       0
   560201728     140050432     float     sum      -1  2593.45  216.01  405.01       0  2595.18  215.86  404.74       0
   561250304     140312576     float     sum      -1  2588.58  216.82  406.53       0  2614.50  214.67  402.50       0
   562298880     140574720     float     sum      -1  2592.75  216.87  406.64       0  2664.89  211.00  395.63       0
   563347456     140836864     float     sum      -1  2592.08  217.33  407.50       0  2594.74  217.11  407.08       0
   564396032     141099008     float     sum      -1  2605.10  216.65  406.22       0  2620.07  215.41  403.90       0
   565444608     141361152     float     sum      -1  2609.32  216.70  406.32       0  2600.47  217.44  407.70       0
   566493184     141623296     float     sum      -1  2618.47  216.35  405.65       0  2603.33  217.60  408.01       0
   567541760     141885440     float     sum      -1  2629.78  215.81  404.65       0  2643.04  214.73  402.62       0
   568590336     142147584     float     sum      -1  2659.87  213.77  400.81       0  2624.37  216.66  406.23       0
   569638912     142409728     float     sum      -1  2626.96  216.84  406.58       0  2621.95  217.26  407.36       0
   570687488     142671872     float     sum      -1  2627.71  217.18  407.21       0  2634.93  216.59  406.10       0
   571736064     142934016     float     sum      -1  2642.42  216.37  405.69       0  2643.02  216.32  405.60       0
   572784640     143196160     float     sum      -1  2632.71  217.56  407.93       0  2631.48  217.67  408.12       0
   573833216     143458304     float     sum      -1  2712.74  211.53  396.62       0  2656.63  216.00  405.00       0
   574881792     143720448     float     sum      -1  2648.58  217.05  406.97       0  2659.95  216.12  405.23       0
   575930368     143982592     float     sum      -1  2655.49  216.88  406.66       0  2637.91  218.33  409.37       0
   576978944     144244736     float     sum      -1  2652.35  217.53  407.88       0  2666.81  216.36  405.67       0
   578027520     144506880     float     sum      -1  2650.14  218.11  408.96       0  2659.17  217.37  407.57       0

```
## k8s 原生调度器支持 binpack
在 kube-scheduler 的调度插件 NodeResourcesFit 中存在两种支持资源装箱（bin packing）的策略：MostAllocated 和 RequestedToCapacityRatio

在本次方案我们主要通过设置 RequestedToCapacityRatio 策略来启用资源装箱
```bash
mkdir /etc/kubernetes/scheduler
tee /etc/kubernetes/scheduler/kube-scheduler.yaml <<eof
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
leaderElection:
  leaderElect: true
clientConnection:
  kubeconfig: /etc/kubernetes/scheduler.conf
profiles:
  - schedulerName: default-scheduler
    pluginConfig:
      - name: NodeResourcesFit
        args:
          scoringStrategy:
            type: RequestedToCapacityRatio
            resources:
              - name: nvidia.com/gpu
                weight: 3
            requestedToCapacityRatio:
              shape:
                - utilization: 0
                  score: 0
                - utilization: 100
                  score: 10
eof

#修改/etc/kubernetes/manifests/kube-scheduler.yaml
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    component: kube-scheduler
    tier: control-plane
  name: kube-scheduler
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-scheduler
    - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
    - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
    - --bind-address=127.0.0.1
    #- --kubeconfig=/etc/kubernetes/scheduler.conf
    #- --leader-elect=true
    - --config=/etc/kubernetes/scheduler/kube-scheduler.yaml
    - --v=1
    image: harbor.unisound.ai/unisound/kube-scheduler:v1.32.10
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-scheduler
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /readyz
        port: 10259
        scheme: HTTPS
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 100m
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: 10259
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /etc/kubernetes/scheduler.conf
      name: kubeconfig
      readOnly: true
    - mountPath: /etc/kubernetes/scheduler/kube-scheduler.yaml
      name: config
      readOnly: true

  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /etc/kubernetes/scheduler.conf
      type: FileOrCreate
    name: kubeconfig
  - hostPath:
      path: /etc/kubernetes/scheduler/kube-scheduler.yaml
    name: config

#查看scheduler状态
  
k get po -n kube-system | grep sch
kube-scheduler-m1                          1/1     Running   0                23h
kube-scheduler-m2                          1/1     Running   0                23h
kube-scheduler-node16                      1/1     Running   0                23h
 
 
#重启scheduler相关pod
  
k delete po -n kube-system  kube-scheduler-m1  
  
#查询pod是否正常
  
k get po -n kube-system | grep sch
kube-scheduler-m1                          1/1     Running   0                23h
kube-scheduler-m2                          1/1     Running   0                23h
kube-scheduler-node16                      1/1     Running   0                23h
 
 
测试mpi-job每个任务分配1个GPU
  
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

tee deploy3.yaml <<eof
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-3
spec:
  selector:
    matchLabels:
      app: demo-3
  replicas: 1
  template:
    metadata:
      labels:
        app: demo-3
    spec:
      containers:
      - name: demo-3
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


#安装arena ，服务器若没有代理只能去github下载了
#下载链接 https://github.com/kubeflow/arena/releases
wget https://github.com/kubeflow/arena/releases/download/v0.15.4/arena-installer-0.15.4-linux-amd64.tar.gz
tar xvf arena-installer-0.15.4-linux-amd64.tar.gz
cd ~/arena-installer-0.15.4-linux-amd64/
./install.sh

arena top node
NAME    IPADDRESS      ROLE           STATUS                    GPU(Total)  GPU(Allocated)
cpu101  172.19.12.101  control-plane  Ready,SchedulingDisabled  0           0
cpu102  172.19.12.102  control-plane  Ready,SchedulingDisabled  0           0
cpu103  172.19.12.103  control-plane  Ready,SchedulingDisabled  0           0
gpu24   172.19.12.24   <none>         Ready                     8           4
gpu25   172.19.12.25   <none>         Ready                     8           8
gpu26   172.19.12.26   <none>         Ready                     8           8
gpu27   172.19.12.27   <none>         Ready                     8           8
gpu28   172.19.12.28   <none>         Ready                     8           8
gpu30   172.19.12.30   <none>         Ready                     8           8
gpu31   172.19.12.31   <none>         Ready                     8           0
gpu36   172.19.12.36   <none>         Ready                     8           0
gpu37   172.19.12.37   <none>         Ready                     8           8
gpu38   172.19.12.38   <none>         Ready                     8           8
gpu39   172.19.12.39   <none>         Ready                     8           4
gpu41   172.19.12.41   <none>         Ready                     8           8
gpu43   172.19.12.43   <none>         Ready                     8           8
gpu44   172.19.12.44   <none>         Ready                     8           8
gpu45   172.19.12.45   <none>         Ready                     8           8
gpu52   172.19.12.52   <none>         Ready                     8           4
gpu53   172.19.12.53   <none>         Ready                     8           8
---------------------------------------------------------------------------------------------------

观察调度情况
k apply -f deploy1.yaml
k apply -f deploy3.yaml
arena top node
NAME    IPADDRESS      ROLE           STATUS                    GPU(Total)  GPU(Allocated)
cpu101  172.19.12.101  control-plane  Ready,SchedulingDisabled  0           0
cpu102  172.19.12.102  control-plane  Ready,SchedulingDisabled  0           0
cpu103  172.19.12.103  control-plane  Ready,SchedulingDisabled  0           0
gpu24   172.19.12.24   <none>         Ready                     8           4
gpu25   172.19.12.25   <none>         Ready                     8           8
gpu26   172.19.12.26   <none>         Ready                     8           8
gpu27   172.19.12.27   <none>         Ready                     8           8
gpu28   172.19.12.28   <none>         Ready                     8           8
gpu30   172.19.12.30   <none>         Ready                     8           8
gpu31   172.19.12.31   <none>         Ready                     8           0
gpu36   172.19.12.36   <none>         Ready                     8           0
gpu37   172.19.12.37   <none>         Ready                     8           8
gpu38   172.19.12.38   <none>         Ready                     8           8
gpu39   172.19.12.39   <none>         Ready                     8           4
gpu41   172.19.12.41   <none>         Ready                     8           8
gpu43   172.19.12.43   <none>         Ready                     8           8
gpu44   172.19.12.44   <none>         Ready                     8           8
gpu45   172.19.12.45   <none>         Ready                     8           8
gpu52   172.19.12.52   <none>         Ready                     8           6
gpu53   172.19.12.53   <none>         Ready                     8           8
---------------------------------------------------------------------------------------------------
#两个1卡任务已经调度到一台设备
k get po -owide
NAME                      READY   STATUS    RESTARTS   AGE   IP              NODE    NOMINATED NODE   READINESS GATES
demo-1-86559d56c-jtbhs    1/1     Running   0          38s   10.245.57.230   gpu52   <none>           <none>
demo-3-74b9987f75-xv2n2   1/1     Running   0          31s   10.245.57.217   gpu52   <none>           <none>
  
```

## Volcano 设置调度策略 binpack
```bash
# 修改 volcano-scheduler 相关 ConfigMap
k edit cm -n volcano-system volcano-scheduler-configmap
  
      - name: binpack
        arguments:
          binpack.weight: 10   # binpack插件的权重（allocate action有许多计算插件，可以把某个插件权重调大，作为主要计算标准）
          binpack.cpu: 1       #binpack计算时，gpu使用权重
          binpack.memory: 1    #binpack计算时，内存使用权重
          binpack.resources: nvidia.com/gpu
          binpack.resources.nvidia.com/gpu: 8

#修改完成后重启volcano-scheduler相关pod
k get po -n volcano-system
NAME                                   READY   STATUS      RESTARTS   AGE
volcano-admission-f8c5f5c6-9ls9f       1/1     Running     0          34m
volcano-admission-init-qdflg           0/1     Completed   0          24h
volcano-controllers-864d8fbc6c-9ftzl   1/1     Running     0          34m
volcano-scheduler-559849644-276km      1/1     Running     0          30s
 
k delete po volcano-scheduler-559849644-276km  -n volcano-system

#测试binpack插件是否启用

#以1卡gpu任务进行测试
  
#查看现有集群空闲的服务器（node19 有空余4张）
  
atlasctl top node | egrep -v "8/8|SchedulingDisabled |0/0 "
NAME    IPADDRESS   STATUS                    ROLE                              USED-GPU  USED-CPU
node19  10.1.0.28   Ready                     A800,CPU,worker                   4/8       0.86/64
node37  10.1.0.46   Ready                     A800,worker                       0/8       0.86/64
node44  10.1.0.53   Ready                     A800,CPU,worker                   0/8       0.96/64
node47  10.1.0.56   Ready                     A800,CPU,worker                   0/8       0.86/64
-----------------------------------------------------------------------------------------
Allocated/Total GPUs In Cluster:
268/320 (83%)
 
 
 
#执行多个1卡任务
  
 atlasctl create --name=test --image=harbor.unijn.cn/zhaofengfeng/dev:v1    --gpu=1 --addShareNamespace=zhaofengfeng  --pull=true  --args="sleep 1d"
 
 atlasctl create --name=test1 --image=harbor.unijn.cn/zhaofengfeng/dev:v1    --gpu=1 --addShareNamespace=zhaofengfeng  --pull=true  --args="sleep 1d"
  
 atlasctl create --name=test2 --image=harbor.unijn.cn/zhaofengfeng/dev:v1    --gpu=1 --addShareNamespace=zhaofengfeng  --pull=true  --args="sleep 1d"
  
任务调到了node19
  
 k get po -n zhaofengfeng -owide
NAME        READY   STATUS    RESTARTS   AGE   IP             NODE     NOMINATED NODE   READINESS GATES
test-0-0    1/1     Running   0          33s   10.233.95.49   node19   <none>           <none>
test1-0-0   1/1     Running   0          33s   10.233.95.48   node19   <none>           <none>
test2-0-0   1/1     Running   0          32s   10.233.95.50   node19   <none>           <none>


#源码参考地址：https://github.com/volcano-sh/volcano/blob/master/pkg/scheduler/plugins/binpack/binpack.go

```


## Volcano

```bash
kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/master/installer/volcano-development.yaml

```
## Rayjob

```bash

#在线下载到本地
helm repo add kuberay https://ray-project.github.io/kuberay-helm/
helm repo update
  
helm pull kuberay/kuberay-operator --untar  --version 1.6.0
  
docker pull quay.io/kuberay/operator:v1.6.0
  
docker push  harbor.unisound.ai/unisound/kuberay/operator:v1.6.0
  
修改 kuberay-operator/values.yaml
image:
  repository:  harbor.unisound.ai/unisound/kuberay/operator
  tag: v1.6.0
  pullPolicy: IfNotPresent
 
- name: ENABLE_INIT_CONTAINER_INJECTION
  value: "false"
 
#安装
helm install -n  kuberay-operator  --create-namespace kuberay-operator ./kuberay-operator
  
#测试使用官网示例即可

#参考地址：

https://github.com/ray-project/kuberay

```
## nsight-operator

```bash
#下载helm包
 
wget https://helm.ngc.nvidia.com/nvidia/devtools/charts/nsight-operator-1.3.0.tgz
 
tar xvf nsight-operator-1.3.0.tgz
 
#安装
 
helm install nsight-operator nsight-operator   --namespace nsight-operator   --create-namespace   --wait
     
k get po -n  nsight-operator
 
#修改配置,我这里对接的gpfs存储类
 
grep -A4 persistentStorage nsight-operator/values.yaml
  persistentStorage:
    enabled: true
    size: "10Gi"
    storageClassName: "ibm-spectrum-scale-csi-fileset-sc"  # Use cluster default if not specified

 
#更新helm
 
helm upgrade --install nsight-operator nsight-operator   --namespace nsight-operator   -f nsight-operator/values.yaml
 

# Example for a deployment named "my-deployment"
kubectl patch deployment my-deployment -p '{"spec":{"template":{"metadata":{"labels":{"nvidia-nsight-profile":"enabled"}}}}}'
# Wait for the deployment to be ready
kubectl rollout status deployment/my-deployment
 
# Example for a statefulset named "my-statefulset"
kubectl patch statefulset my-statefulset -p '{"spec":{"template":{"metadata":{"labels":{"nvidia-nsight-profile":"enabled"}}}}}'
# Wait for the statefulset to be ready
kubectl rollout status statefulset/my-statefulset

#参考地址：https://catalog.ngc.nvidia.com/orgs/nvidia/teams/devtools/helm-charts/nsight-operator?version=1.3.0

#安装Nsight Systems 
sudo apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu1804/x86_64/7fa2af80.pub
sudo add-apt-repository "deb https://developer.download.nvidia.com/devtools/repos/ubuntu$(source /etc/lsb-release; echo "$DISTRIB_RELEASE" | tr -d .)/$(dpkg --print-architecture)/ /"
sudo apt install nsight-systems nsight-compute  nsight-systems-cli  -y

#参考地址：https://docs.nvidia.com/nsight-systems/InstallationGuide/index.html

```


## 镜像备份 / 同步脚本（skopeo）

```bash
apt install skopeo -y
skopeo login harbor.unisound.ai

```
#镜像下载脚本
```bash
#!/bin/bash

# --- 配置区 ---
DOMAIN="harbor.unisound.ai"
PROJECT="unisound"
USER_PASS="admin:<HARBOR_PASSWORD>"  # 刚才测试成功的账号密码
LOCAL_BACKUP_DIR="./local_backup"
CONCURRENCY=5
# --------------

mkdir -p "$LOCAL_BACKUP_DIR"

echo "正在从 Harbor 获取仓库列表..."
# 获取所有仓库名，并去掉 "unisound/" 前缀
REPOS=$(for p in 1 2 3; do
    curl -s -k -u "$USER_PASS" "https://$DOMAIN/api/v2.0/projects/$PROJECT/repositories?page=$p&page_size=100" | grep -Po '"name":\s*"\K[^"]+'
done | sed "s|^$PROJECT/||")

export DOMAIN PROJECT USER_PASS LOCAL_BACKUP_DIR

process_repo() {
    REPO_SHORT=$1
    # 转换本地存储目录名：将 rayproject/ray 变为 unisound_rayproject_ray
    SAFE_NAME="${PROJECT}_$(echo "$REPO_SHORT" | sed 's/\//_/g')"

    # 对仓库名进行 URL 编码 (处理斜杠 / 为 %252f)
    REPO_ENCODED=$(echo "$REPO_SHORT" | sed 's/\//%252f/g')

    echo "[LIST] 正在获取仓库 $REPO_SHORT 的标签..."

    # 请求 API 获取标签
    TAGS=$(curl -s -k -u "$USER_PASS" "https://$DOMAIN/api/v2.0/projects/$PROJECT/repositories/$REPO_ENCODED/artifacts?page_size=100" | grep -Po '"name":\s*"\K[^"]+' | sort -u)

    if [ -z "$TAGS" ]; then
        echo "[SKIP] $REPO_SHORT 未发现标签或请求失败"
        return
    fi

    for TAG in $TAGS; do
        TARGET_PATH="$LOCAL_BACKUP_DIR/$SAFE_NAME/$TAG"

        # 断点续传逻辑
        if [ -d "$TARGET_PATH" ] && [ "$(ls -A $TARGET_PATH 2>/dev/null)" ]; then
            echo "[EXIST] 跳过: $REPO_SHORT:$TAG"
            continue
        fi

        echo "[SYNC] 正在同步: $REPO_SHORT:$TAG"
        mkdir -p "$TARGET_PATH"

        # 执行拷贝
        skopeo copy --src-tls-verify=false \
            --src-creds "$USER_PASS" \
            "docker://$DOMAIN/$PROJECT/$REPO_SHORT:$TAG" \
            "dir:$TARGET_PATH"

        if [ $? -ne 0 ]; then
            echo "[ERROR] 同步失败: $REPO_SHORT:$TAG"
            rm -rf "$TARGET_PATH"
        fi
    done
}

export -f process_repo

echo "找到仓库，准备并行处理..."
echo "$REPOS" | xargs -I {} -P "$CONCURRENCY" bash -c "process_repo {}"

echo "✅ 全部镜像打包完成，存放在 $LOCAL_BACKUP_DIR 目录下。"

```
镜像上传脚本
```bash
#!/bin/bash

# --- 配置区 ---
NEW_DOMAIN="harbor.unisound.ai"
NEW_PROJECT="unisound"
NEW_USER_PASS="admin:<HARBOR_PASSWORD>"
# 自动获取当前目录下 local_backup 的绝对路径
LOCAL_BACKUP_DIR="$(pwd)/local_backup"
CONCURRENCY=5
# --------------

if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
    echo "❌ 错误: 找不到目录 $LOCAL_BACKUP_DIR"
    exit 1
fi

export NEW_DOMAIN NEW_PROJECT NEW_USER_PASS LOCAL_BACKUP_DIR

push_logic() {
    SAFE_NAME=$1
    # 还原仓库名：去掉前面的 unisound_，并把下划线换回斜杠
    # 例如: unisound_rayproject_ray -> rayproject/ray
    REPO_NAME=$(echo "$SAFE_NAME" | sed 's/^unisound_//' | sed 's/_/\//g')

    REPO_PATH="$LOCAL_BACKUP_DIR/$SAFE_NAME"

    # 遍历该镜像目录下的所有 Tag 文件夹（如 v1, latest 等）
    for TAG in $(ls "$REPO_PATH"); do
        TAG_PATH="$REPO_PATH/$TAG"

        # 确认目录下是否存在 manifest.json (dir 格式的标志)
        if [ ! -f "$TAG_PATH/manifest.json" ]; then
            continue
        fi

        TARGET_IMAGE="$NEW_DOMAIN/$NEW_PROJECT/$REPO_NAME:$TAG"

        echo "[PUSHING] $TARGET_IMAGE ..."

        # 执行从本地 dir 到 远程 docker 的拷贝
        skopeo copy --dest-tls-verify=false \
            --dest-creds "$NEW_USER_PASS" \
            "dir:$TAG_PATH" \
            "docker://$TARGET_IMAGE"

        if [ $? -eq 0 ]; then
            echo "[SUCCESS] 完成: $TARGET_IMAGE"
        else
            echo "[FAILED] 失败: $TARGET_IMAGE"
        fi
    done
}

export -f push_logic

echo "🚀 开始同步镜像到新仓库 $NEW_DOMAIN ..."

# 获取 local_backup 下的所有文件夹并开始并行处理
ls "$LOCAL_BACKUP_DIR" | xargs -I {} -P "$CONCURRENCY" bash -c "push_logic {}"

echo "✅ 所有同步任务已完成。"

```
