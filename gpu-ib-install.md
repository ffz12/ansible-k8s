# IB 网卡驱动安装

## 目录

- [IB 网卡驱动安装](#ib-网卡驱动安装)
  - [CentOS 版本](#centos-版本)
  - [Ubuntu 版本](#ubuntu-版本)
- [GPU 驱动安装](#gpu-驱动安装)
  - [下载链接](#下载链接)
  - [Ubuntu 20.04 GCC 多版本管理](#ubuntu-2004-gcc-多版本管理)

下载地址：https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/

## CentOS 版本

```bash
# 挂载 ISO 文件
mount -o loop /opt/MLNX_OFED_LINUX-5.8-3.0.7.0-rhel7.9-x86_64.iso /mnt

# 安装驱动
/mnt/mlnxofedinstall --add-kernel-support

# 安装驱动（忽略设备检测）
/mnt/mlnxofedinstall --add-kernel-support --skip-unsupported-devices-check

# 安装完成后重启,使 OFED 驱动加载生效
reboot

# 若 cx3 不识别，加载模块，然后重启试试
echo "mlx4_core" >> /etc/modules
echo "mlx4_en" >> /etc/modules

# 配置 IP（CentOS 版本）
vim /etc/sysconfig/network-scripts/ifcfg-ib0
NAME="ib0"
DEVICE="ib0"
DEFROUTE="no"
ONBOOT=yes
NETBOOT=yes
IPV6INIT=yes
BOOTPROTO=none
TYPE=Ethernet
IPADDR=10.10.30.214
NETMASK=255.255.255.0
GATEWAY=10.10.30.254

# 关闭 NetworkManager
systemctl disable NetworkManager --now

# 重启网络
systemctl restart network

# 查看 IB 网卡
ifconfig ib0
```

## Ubuntu 版本

```yaml
# /etc/netplan/ib-config.yaml
network:
  ethernets:
    ibp194s0:
      addresses: [10.10.30.21/24]
  version: 2
  renderer: networkd

# 应用配置
netplan apply
```

# GPU 驱动安装

## 下载链接

```bash
# 驱动下载地址（所有版本）
https://www.nvidia.cn/drivers/lookup/

# PCIe 设备查看
https://admin.pci-ids.ucw.cz/mods/PC/10de/2702
```

## Ubuntu 20.04 GCC 多版本管理

```bash
# 检查 GCC 版本
ls -l /usr/bin/gcc*

# 示例输出（可能因系统而异）
# lrwxrwxrwx 1 root root  5 3月  20  2020 /usr/bin/gcc -> gcc-9
# lrwxrwxrwx 1 root root 23 7月   9  2023 /usr/bin/gcc-10 -> x86_64-linux-gnu-gcc-10
# ...

# 切换到 GCC-9
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-9 90
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-9 90

# 切换到 GCC-10
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 100
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-10 100
```
```

##  centos 7.9  版本安装新驱动
```bash
#需要的依赖:
kernel-ml kernel-ml-devel kernel-ml-headers  gcc-9 

#内核下载地址：https://dl.lamp.sh/kernel/el7/
 
wget https://dl.lamp.sh/kernel/el7/kernel-ml-6.2.13-1.el7.x86_64.rpm
wget https://dl.lamp.sh/kernel/el7/kernel-ml-devel-6.2.13-1.el7.x86_64.rpm
wget https://dl.lamp.sh/kernel/el7/kernel-ml-headers-6.2.13-1.el7.x86_64.rpm

awk -F\' '$1=="menuentry " {print i++ ":"$2}' /etc/grub2.cfg
grub2-set-default 6.2.13-1.el7.x86_64
grub2-mkconfig -o /boot/grub2/grub.cfg
 
 
# 下载阿里云的 SCL 源配置文件
cat << 'EOF' > /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo
[centos-sclo-rh]
name=CentOS-7 - SCLo rh
baseurl=https://mirrors.aliyun.com/centos/7/sclo/x86_64/rh/
gpgcheck=0
enabled=1
EOF

#安装gcc环境
yum install devtoolset-9-gcc devtoolset-9-gcc-c++ devtoolset-9-binutils -y

#临时生效
source /opt/rh/devtoolset-9/enable

#安装NVIDIA驱动
sh NVIDIA-Linux-x86_64-570.211.01.run
```
## 默认rhel系列环境准备
```bash
#安装依赖

yum install gcc kernel-devel kernel-headers kernel-tools pciutils  tar unzip -y
  
yum update kernel -y

#nouveau模块检查
lsmod | grep nouveau
#禁用nouveau模块
tee /etc/modprobe.d/blacklist.conf <<eof
blacklist nouveau
options nouveau modeset=0
eof
 
#备份当前镜像
mv /boot/initramfs-$(uname -r).img /boot/initramfs-$(uname -r)-nouveau.img
建立新镜像
dracut /boot/initramfs-$(uname -r).img
重启
reboot
查看nouveau是否加载
lsmod | grep nouveau
```
## debian系列
```bash
lsmod | grep nouveau
 
#禁用nouveau模块
tee /etc/modprobe.d/blacklist.conf <<eof
blacklist nouveau
options nouveau modeset=0
eof
  
#更新initramfs
update-initramfs -u
 
 
重启系统
sudo reboot
重新进入系统后，检验nouveau是否被禁用
lsmod | grep nouveau
```

## 查看gpu
```bash
yum install pciutils -y
lspci | grep -i nvidia
sh NVIDIA-Linux-x86_64-570.211.01.run

#如果中间缺包使用以下地址下载：

阿里云软件包下载地址：https://developer.aliyun.com/mirror/
```

## 开启 GPU Persistent Mode 
```bash
tee /etc/systemd/system/gpu-persistent-mode.service <<eof
[Unit]
Description=Wait until NM actually online
   
   
[Service]
Type=forking
Restart=always
ExecStart=/usr/bin/nvidia-persistenced  --persistence-mode
   
[Install]
WantedBy=multi-user.target
eof
   
   
systemctl  daemon-reload
systemctl  enable  gpu-persistent-mode.service  --now
systemctl  status gpu-persistent-mode.service

```

## 查看GPU进程
```bash
fuser -v /dev/nvidia*
```


## 永久关闭mig功能
```bash
for GPU_ID in $(nvidia-smi --query-gpu=index --format=csv,noheader,nounits); do
nvidia-smi -i ${GPU_ID} -mig 0
done

```

## cuda安装
```bash
cuda下载地址：

https://developer.nvidia.com/cuda-downloads?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=20.04&target_type=runfile_local

#环境变量配置
echo 'export PATH=/usr/local/cuda-11.7/bin:$PATH' >> /etc/profile
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-11.7/lib64:$LD_LIBRARY_PATH' >> /etc/profile
source  /etc/profile
nvcc --version
  
sudo bash -c "echo /usr/local/cuda/lib64/ > /etc/ld.so.conf.d/cuda.conf"
sudo ldconfig -v 

```
## 安装nvidia-docker
```bash

apt相关：
 
#有网服务器安装
apt install curl sudo gpg -y
 
#设置apt源
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
     
sed -i -e '/experimental/ s/^#//g' /etc/apt/sources.list.d/nvidia-container-toolkit.list
 
 
#更新源
 
sudo apt-get update
 
#在线安装方法：
sudo apt-get install -y nvidia-container-toolkit
 
#离线安装方法：
 
1、创建离线软件包存放目录在有网服务器
mkdir nvidia-docker
 
2、进入目录
cd nvidia-docker
 
3、下载软件包及依赖
apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances nvidia-container-toolkit | grep "^\w" | sort -u)
 
4、安装
dpkg -i nvidia-docker/*dep
 
 
 
yum/dnf:
 
 
#下载repo
 
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
  sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
   
#设置repo源
   
sudo yum-config-manager --enable nvidia-container-toolkit-experimental
 
#在线安装方法：
yum install -y nvidia-container-toolkit
 
 
离线安装方法：
1、创建离线软件包存放目录在有网服务器
 
mdkir nvidia-docker
 
2、下载软件包
 
#安装yum相关必要软件包
 
yum  install -y yum-utils createrepo  -y
 
#离线软件包
 
yum install --downloadonly --downloaddir=./nvidia-docker   nvidia-container-toolkit -y
 
3、离线安装
 
yum localinstall -y ./nvidia-docker/*rpm
  
  
  
检查是否可以正常输出
docker run -it --rm --gpus all ubuntu nvidia-smi
docker run -it --gpus all --rm harbor.unisound.ai/zhouyuqiu/tensorflow_py2:shiqiang-1.7.0-gpu-py nvidia-smi

nvidia-docker 官网安装参考：
https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
```

## Nvidia-smi命令详解
```bash
nvidia-container-cli list | grep libnvidia-ml.so

#docker配置文件错误
cat /etc/docker/daemon.json
{
    "exec-opts": [
        "native.cgroupdriver=systemd"
    ],
    "runtimes": {
        "nvidia": {
            "path": "/usr/bin/nvidia-container-runtime",
            "runtimeArgs": []
        }
    },
    "default-runtime": "nvidia",
    "insecure-registries": [
        "harbor.unidev.ai"
    ],
    "live-restore": true
}
 
 
systemctl reload docker
```

## GPU驱动升级后，docker挂载GPU报错
```bash

#卸载旧包
rpm -e `rpm -qa |grep nvidia`
#离线升级命令
yum localinstall ./*rpm -y


```

## 关闭L40 ECC 执行以下命令然后重启
```bash
nvidia-smi  --ecc-config=0
  
reboot
```

## 设置GPU频率
```bash
#设置0卡GPU频率
nvidia-smi -i 0 -lgc <频率>
  
#查看支持的时钟频率
 
sudo nvidia-smi -q -d CLOCK
```
## ECC有计数"2700" 是异常值，表示ECC状态信息读取错误。
```bash
✅ 检测和纠正显存错误

✅ 提高计算精度和稳定性

✅ 防止数据损坏

nvidia-smi -i 5 --reset-ecc-errors=0

```


## gpu卡LRO问题，导致gpu卡通信异常
```bash
dmesg -t 

ethtool -K <interface> lro off

```
##
```bash
为了解决 GPU 卡之间 P2P 的问题，AMD 平台需要再 bios 里面的高级选型里面把 iommu （Intel 平台的话需要关闭 VT-d ）跟 ACS 关闭

(Path: Advanced -> Chipset Configuration -> North Bridge -> IIO Configuration -> Intel VT for Directed I/O (VT-d) -> ACS Control -> Enable / Disable.)
执行lspci -vvv | grep -I acsctl 如果全显示SrcValid-说明已关闭ACS功能；使用dmesg | grep -e DMAR -e IOMMU，查看IOMMU是否启用
建议把 GPU卡的风扇调到全速，不然 GPU 频率会跳变
```

## gpu burn测试
```bash
wget https://github.com/wilicc/gpu-burn/tree/master
  
cd gpu-burn-master
 
 
cat Dockerfile
ARG CUDA_VERSION=11.8.0
ARG IMAGE_DISTRO=ubi8
ARG HRI="registry.cn-hangzhou.aliyuncs.com/zff_registry"
 
FROM $HRI/cuda:${CUDA_VERSION}-devel-${IMAGE_DISTRO} AS builder
 
WORKDIR /build
 
COPY . /build/
 
RUN make
 
FROM $HRI/cuda:${CUDA_VERSION}-runtime-${IMAGE_DISTRO}
 
COPY --from=builder /build/gpu_burn /app/
COPY --from=builder /build/compare.ptx /app/
 
WORKDIR /app
 
CMD ["./gpu_burn", "60"]
 
 
docker build -t gpu_burn .

docker run --rm --gpus '"device=6,7"' bash
 
docker run --rm --gpus '"device=6,7"' gpu_burn  /app/gpu_burn 120
 
```

## python判断cuda是否可用
```bash
#导入torch模块
import torch
#最后通过以下指令查看cuda是否可用即可
print(torch.cuda.is_available())   
查看可行的cuda数目
print(torch.cuda.device_count())
查看torch版本
torch.version.cuda
查看cuda是否可用
torch.cuda.is_available()
```


# ubuntu2204.4优化
```bash
#!/bin/bash
set -e

image="5.15.0-122"
kernel_full="${image}-generic"

echo "安装内核包: $kernel_full ..."
sudo apt update
sudo apt install -y \
  linux-image-$kernel_full \
  linux-headers-$kernel_full \
  linux-modules-$kernel_full \
  linux-modules-extra-$kernel_full

echo "锁定内核版本..."
sudo apt-mark hold \
  linux-image-$kernel_full \
  linux-headers-$kernel_full \
  linux-modules-$kernel_full \
  linux-modules-extra-$kernel_full \
  linux-image-generic \
  linux-headers-generic

# === 自动配置 GRUB 默认启动项 ===
echo "配置 GRUB 默认启动内核为: $kernel_full ..."

# 构造 menuentry 字符串（必须与 grub.cfg 中完全一致）
menuentry_title="Ubuntu, with Linux ${kernel_full}"
submenu_name="Advanced options for Ubuntu"
grub_default_value="${submenu_name}>${menuentry_title}"

# 备份原始 grub 配置
sudo cp /etc/default/grub /etc/default/grub.bak.$(date +%Y%m%d_%H%M%S)

# 替换 GRUB_DEFAULT 行：先删除旧的（如果存在），再添加新的
sudo sed -i '/^GRUB_DEFAULT=/d' /etc/default/grub
echo "GRUB_DEFAULT=\"${grub_default_value}\"" | sudo tee -a /etc/default/grub

# 确保 GRUB_TIMEOUT 可见（方便调试，可选）
if ! grep -q "^GRUB_TIMEOUT=" /etc/default/grub; then
    echo 'GRUB_TIMEOUT=5' | sudo tee -a /etc/default/grub
else
    sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
fi

# 更新 GRUB 配置
echo "更新 GRUB 配置..."
sudo update-grub

echo ""
echo "✅ 安装与 GRUB 配置完成！"
echo "当前运行内核: $(uname -r)"
echo "目标内核（重启后生效）: $kernel_full"
echo ""
echo "已安装的内核列表:"
dpkg -l | grep 'linux-image-[0-9]' | awk '{print $2, $3}'
echo ""
echo "请重启系统以使用新内核: sudo reboot"
```



---

# NVIDIA fabricmanager / peermem（HGX/NVLink 节点必配）

> 适用于 HGX（如 H100/A100 8 卡 NVSwitch）节点。装完 GPU 驱动后需再装
> **fabricmanager**（NVSwitch 拓扑管理）并加载 **nvidia-peermem**（GPUDirect RDMA），否则
> `nvidia-smi topo -m` 看不到 NVLink、或 GPU 无法互联。

## 安装 fabricmanager

> **下载地址**（NVIDIA 官方 CUDA 仓库，按系统/架构换目录）：
> - Ubuntu 22.04 / x86_64：<https://developer.download.nvidia.cn/compute/cuda/repos/ubuntu2204/x86_64/>
> - 其它系统在 `repos/` 下换对应目录（如 `rhel9`、`ubuntu2404`、`sbsa`(arm64)）
> - 包名：`nvidia-fabricmanager_<驱动版本>_amd64.deb` / `nvidia-fabric-manager-<驱动版本>.rpm`
>
> ⚠️ **fabricmanager 版本必须与 NVIDIA 驱动版本严格一致**（如驱动 580.126.09 → fabricmanager 580.126.09），否则服务起不来。

- Red Hat / CentOS:

```bash
rpm -ivh nvidia-fabric-manager-535.104.12-1.x86_64.rpm
```

- Debian / Ubuntu:

```bash
dpkg -i nvidia-fabricmanager_580.126.09-1_amd64.deb
```

## 启动并检查服务

```bash
systemctl enable nvidia-fabricmanager.service --now
systemctl status nvidia-fabricmanager.service
```

## 验证 GPU 拓扑

```bash
nvidia-smi topo -m
```

## 启用 nvidia-peermem（GPUDirect RDMA）

```bash
lsmod | grep nvidia_peermem
echo "nvidia-peermem" | sudo tee /etc/modules-load.d/nvidia-peermem.conf
modprobe -v nvidia-peermem
```

## 批量检查（ansible）

```bash
# fabricmanager 状态 / 开机自启
ansible gpu -m shell -a "systemctl status nvidia-fabricmanager.service"
ansible gpu -m shell -a "systemctl is-enabled nvidia-fabricmanager.service"
# nvidia-peermem 是否加载
ansible gpu -m shell -a "lsmod | grep nvidia_peermem"
# nvidia-container-toolkit 是否安装（deb / rpm）
ansible gpu -m shell -a "dpkg -l | grep nvidia-container-toolkit"
ansible gpu -m shell -a "rpm -qa | grep nvidia-container-toolkit"
```
