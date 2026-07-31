# Ceph 安装与配置手册

## 目录

- [环境准备](#环境准备)
  - [配置主机名](#配置主机名)
  - [BIOS 调优](#bios-调优)
  - [服务器初始化及内核升级](#服务器初始化及内核升级)
  - [硬盘调优](#硬盘调优)
- [Ceph 安装](#ceph-安装)
  - [安装 cephadm](#安装-cephadm)
  - [引导集群](#引导集群)
  - [部署 OSD](#部署-osd)
- [集群管理](#集群管理)
  - [添加节点](#添加节点)
- [性能测试](#性能测试)
  - [单盘性能测试](#单盘性能测试)
  - [Ceph 性能测试](#ceph-性能测试)
  - [网络带宽测试](#网络带宽测试)
- [调优配置](#调优配置)
  - [OSD 恢复速度设置](#osd-恢复速度设置)
- [操作技巧](#操作技巧)
  - [查看 OSD 与硬盘关系](#查看-osd-与硬盘关系)
  - [换盘操作](#换盘操作)

## 环境准备

### 配置主机名

```bash
192.168.1.214 ceph214
192.168.1.215 ceph215
192.168.1.216 ceph216
```

### BIOS 调优

```bash
# 设置功耗为性能模式
# 目的：设置 CPU 为性能模式，提高主频，发挥 CPU 最大性能。
# 方法：进入 BIOS，依次选择 "Advanced > Performance Config > Power Policy"，将 "Power Policy" 修改为 "Performance"。

# 关闭 SMMU
# 目的：关闭 SMMU，防止其对性能造成影响。
# 方法：进入 BIOS，依次选择 "Advanced > MISC Config > Support Smmu"，将 "Support Smmu" 修改为 "Disabled"。

# 关闭 CPU Prefetching
# 目的：关闭 CPU Prefetching，防止其对性能造成影响。
# 方法：进入 BIOS，依次选择 "Advanced > MISC Config > CPU Prefetching Configuration"，将 "CPU Prefetching Configuration" 修改为 "Disabled"。

# 内存刷新速率设为 64ms
# 目的：内存刷新速率设为 64ms，提升时延性能。
# 方法：进入 BIOS，依次选择 "Advanced > Memory Config > Custom Refresh Rate"，将 "Custom Refresh Rate" 修改为 "64ms"。
```

### 服务器初始化及内核升级

```bash
# 关闭防火墙
systemctl disable --now firewalld

# 关闭 SELinux
setenforce 0
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

# 安装 Python3
yum install -y epel-release
yum install python3 -y

# 配置时间同步
yum install -y chrony
systemctl enable --now chronyd

# 安装 Docker（略）

# 内核升级
# 清华 RPM 镜像源：https://mirrors.tuna.tsinghua.edu.cn/elrepo/kernel/el7/x86_64/RPMS/

yum -y install gcc build-essential make gcc-c++

# 下载内核包
wget https://mirrors.tuna.tsinghua.edu.cn/elrepo/kernel/el7/x86_64/RPMS/kernel-lt-devel-5.4.260-1.el7.elrepo.x86_64.rpm --no-check-certificate
wget https://mirrors.tuna.tsinghua.edu.cn/elrepo/kernel/el7/x86_64/RPMS/kernel-lt-5.4.260-1.el7.elrepo.x86_64.rpm --no-check-certificate
wget https://mirrors.tuna.tsinghua.edu.cn/elrepo/kernel/el7/x86_64/RPMS/kernel-lt-headers-5.4.260-1.el7.elrepo.x86_64.rpm --no-check-certificate

# 内核相关命令
# 设置系统默认启动内核（注：根据 grub.cfg 中的具体情况设置内核，以下命令仅为参考）
awk -F\' '$1=="menuentry " {print i++ ":"$2}' /etc/grub2.cfg
grub2-set-default '5.4.272-1.el7.elrepo.x86_64'

# 生成启动文件
grub2-mkconfig -o /boot/grub2/grub.cfg

# 查看默认启动内核
grub2-editenv list
```

### 硬盘调优

**注意：** CPU 超线程打开。部署之前需要先测出集群的单盘的性能，例如单盘 200MB/s，那 36 盘位就是 7.2GB/s 的带宽，100Gb/s 的 IB 网卡流量满。

参考文档：[Ceph Hardware Recommendations](https://docs.ceph.com/en/latest/start/hardware-recommendations/)

```bash
# 关闭写入缓冲
yum install hdparm -y

# 查看写入缓冲是否开启
hdparm -W /dev/sda

# 关闭写入缓冲
hdparm -W0 /dev/sda

# 关闭写入缓冲脚本
cat > hdparm.sh << 'EOF'
#!/bin/bash
for i in sda sdb sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr sds sdt sdu sdv sdw sdx sdy sdz sdaa sdab sdac sdad sdae sdaf sdag sdah sdai sdaj
do
     hdparm -W0 /dev/$i
done
EOF
```

## Ceph 安装

### 安装 cephadm

```bash
# 下载 cephadm
wget https://download.ceph.com/rpm-15.2.17/el7/noarch/cephadm --no-check-certificate
chmod +x cephadm

# 确认 cephadm 是否正确安装
./cephadm add-repo --release octopus

# 设置阿里云 yum 源
sed -i 's/download.ceph.com/mirrors.aliyun.com\/ceph/g' /etc/yum.repos.d/ceph.repo

./cephadm install

# 确保 cephadm 已经安装
which cephadm
# /usr/sbin/cephadm

cephadm --help
cephadm version
```

### 引导集群

```bash
# 创建目录
mkdir -p /etc/ceph

# 引导集群
cephadm bootstrap --mon-ip 192.168.1.214 --initial-dashboard-password '<PASSWORD>' --dashboard-password-noupdate

# 安装 ceph-common 包
# 部署节点安装
cephadm install ceph-common ceph

# 其他节点安装
yum install ceph-common ceph -y

# 添加节点
ssh-copy-id -f -i /etc/ceph/ceph.pub root@ceph215
ssh-copy-id -f -i /etc/ceph/ceph.pub root@ceph216
ssh-copy-id -f -i /etc/ceph/ceph.pub root@ceph217

ceph orch host add ceph215
ceph orch host add ceph216
ceph orch host add ceph217

# cephadm 会在执行 bootstrap 的节点部署 mgr 跟 mon 服务，当添加其他节点的时候，会自动在其中一台部署 mgr 管理节点，
# 一般推荐最少 2 个管理节点，3 个监控节点。下面的命令会将 mon 服务部署在 ceph215,ceph216,ceph217 节点
ceph orch apply mon ceph215,ceph216,ceph217

# 开辟 SSH 隧道
ssh -N -L 10.10.20.215:18443:10.10.30.214:8443 root@10.10.30.214 -f

# 关闭写入缓冲脚本
yum install hdparm -y

# 查看写入缓冲是否开启
hdparm -W /dev/sda

# 关闭写入缓冲
hdparm -W0 /dev/sda

# 脚本示例
cat > hdparm.sh << 'EOF'
#!/bin/bash
for i in sda sdb sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr sds sdt sdu sdv sdw sdx sdy sdz sdaa sdab sdac sdad sdae sdaf sdag sdah sdai sdaj
do
     hdparm -W0 /dev/$i
done
EOF
```

### 部署 OSD

```bash
# 存储设备清单可以显示为：
ceph orch device ls

# 自动添加 OSD
ceph orch apply osd --all-available-devices

# 添加 OSD
ceph orch daemon add osd ceph214:/dev/sda

# 脚本示例
cat > add_osd.sh << 'EOF'
#!/bin/bash
for j in ceph214 ceph215 ceph216 ceph217
do
  for i in sda sdb sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr sds sdt sdu sdv sdw sdx sdy sdz sdaa sdab sdac sdad sdae sdaf sdag sdah sdai sdaj
   do ceph orch daemon add osd $j:/dev/$i
   done
done
EOF

# 创建 pool 并设置 PG
# Total PGs = OSDs × 100 / pool_size
# 参考：https://docs.ceph.com/en/latest/rados/operations/placement-groups/#choosing-the-number-of-placement-groups
# 目前集群有 144 个 OSD，那么 Total PGs = 144 × 100 / 3 = 4800，最接近 2 的幂次方 4096

# 首先需要关闭自动调整 PG 的功能
ceph config set global osd_pool_default_pg_autoscale_mode off
ceph osd pool create ceph_data 4096 4096

# 在关闭完自动调整 PG 功能后，还可以手动设置 pool 的 PG 值
ceph osd pool set ceph_data pg_num 4096
ceph osd pool set ceph_data pgp_num 4096

# Ceph OSD 支持 io_uring
for i in {1..143}; do ceph config set osd.$i bluestore_ioring true; done
for i in {1..143}; do ceph config show osd.$i | grep ioring; done
```

## 集群管理

### 添加节点

```bash
# 初始化步骤（参考上面的操作）
# 在 ceph214 节点操作

# 添加主机
ssh-copy-id -f -i /etc/ceph/ceph.pub root@ceph218
ceph orch host add ceph218

# 添加 OSD，以如下指令依次添加 36 块硬盘
ceph orch daemon add osd ceph218:/dev/sda

# 脚本示例
cat > add_osd_ceph218.sh << 'EOF'
#!/bin/bash
for i in sda sdb sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr sds sdt sdu sdv sdw sdx sdy sdz sdaa sdab sdac sdad sdae sdaf sdag sdah sdai sdaj
do
   ceph orch daemon add osd ceph218:/dev/$i
done
EOF

# 重新设置 OSD
# Total PGs = OSDs × 100 / pool_size
# 参考：https://docs.ceph.com/en/latest/rados/operations/placement-groups/#choosing-the-number-of-placement-groups
# 目前集群有 180 个 OSD，那么 Total PGs = 180 × 100 / 3 = 6000，最接近 2 的幂次方 8192

# 手动设置 pool 的 PG 值
ceph osd pool set ceph_data pg_num 8192
ceph osd pool set ceph_data pgp_num 8192

# Ceph OSD 支持 io_uring
for i in {144..179}; do ceph config set osd.$i bluestore_ioring true; done
for i in {144..179}; do ceph config show osd.$i | grep ioring; done
```

## 性能测试

### 单盘性能测试

参考链接：[腾讯云 Ceph 性能测试](https://cloud.tencent.com/developer/article/1923628)

```bash
# 测试写（随机写）
fio -filename=/dev/sdb -iodepth=1 -direct=1 -bs=512K -size=10g --rw=randwrite -thread -time_based -runtime=30 -ioengine=libaio -group_reporting -name=test

# 测试读（随机读）
fio -filename=/dev/sdb -iodepth=1 -direct=1 -bs=512K -size=10g --rw=randread -thread -time_based -runtime=30 -ioengine=libaio -group_reporting -name=test

# 使用 hdparm 测试
hdparm -t /dev/sda
```

### Ceph 性能测试

```bash
# rados 测试写
# 如果加上可选参数 --no-cleanup，那么测试完之后，不会删除该池里面的数据。里面的数据可以继续用于测试集群的读性能
rados bench -p ceph_data 60 write --no-cleanup

# rados 测试读
rados bench -p ceph_data 60 rand

# rados 清除测试数据
rados -p ceph_data cleanup
```

### 网络带宽测试

```bash
# 服务端
ib_write_bw -d mlx5_0 -s 65536 --report_gbits -p 8 -F

# 客户端
ib_write_bw -d mlx5_0 -s 65536 --report_gbits -p 8 192.168.1.214
```

## 调优配置

### OSD 恢复速度设置

一般情况下可以操作以下参数实现速度控制，但是要留意，速度越快对集群性能的影响越大；可以动态的调整参数值，观察 recovery 对集群性能影响情况，找到合适自己的值，即不会对 client 请求造成过大影响的同时保障最优的 recovery 速度。

- `osd_recovery_max_single_start`：指示每个可同时启动多少线程实现 recovery，默认值 5。这个值限定了每个 PG 可以启动 recovery 操作的最大数。
  - 第一种情况，配置 `osd_recovery_max_single_start=1`，`osd_recovery_max_active=3`，这代表每个 OSD 在某个时间会为一个 PG 最多启动 1 个恢复操作，并且最多可以由 3 个恢复操作处于活跃状态。
  - 第二种情况，配置 `osd_recovery_max_single_start=2`，`osd_recovery_max_active=3`，这代表某个时间点 OSD 会为一个 PG 启动 2 个恢复操作，并且最多能有 3 个恢复操作处于活跃状态。
- `osd_backfill_retry_interval`：OSD 在重试回填请求之前等待的秒数（默认 30 秒）
- `osd_recovery_sleep_hdd`：指示 HDD 磁盘在恢复过程中的休眠时间
- `osd_recovery_sleep_ssd`：指示 SSD 磁盘在恢复过程中的休眠时间
- `osd_max_backfills`：允许进出 OSD 的最大回填操作数。数字越大，恢复越快。设置 10
- `osd_recovery_max_active`：OSD 恢复请求的数量。数字越大，恢复越快。设置 10
- `osd_recovery_op_priority`：恢复操作优先级，取值 1-63，值越高占用资源越高，恢复越快。设置 20
- `osd_recovery_priority`：同上，恢复操作的优先级，如果不希望影响业务，设置优先级低一些，数字越小，性能影响越小。

```bash
# 查看 ceph 配置文件的新方法
ceph-conf --show-config | egrep "osd_recovery_max_active|osd_recovery_op_priority|osd_max_backfills"

# 调整 OSD 参数
ceph config set osd osd_recovery_op_priority 20       # 默认 3
ceph config set osd osd_max_backfills 10             # 默认 1
ceph config set osd osd_recovery_max_active 10       # 默认 0
ceph config set osd osd_recovery_max_single_start 5  # 默认 1

# 恢复 OSD 参数
ceph config set osd osd_recovery_op_priority 3
ceph config set osd osd_max_backfills 1
ceph config set osd osd_recovery_max_active 0
ceph config set osd osd_recovery_max_single_start 1

# 用于设置单个 OSD 同时进行的最大 scrub 操作数量，默认值 1
ceph config set osd osd_max_scrubs 3
ceph config get osd osd_max_scrubs

# 清理 Ceph OSD 守护进程时的最大间隔，以秒为单位，默认值 604800
ceph config set osd osd_scrub_max_interval 1209600
ceph config get osd osd_scrub_max_interval

# 深度清理 Ceph OSD 守护进程时的最大间隔，以秒为单位，默认值 604800
ceph config set osd osd_deep_scrub_interval 1209600
ceph config get osd osd_deep_scrub_interval

# 浅度清理时间查看
ceph pg dump | awk '$1 ~/[0-9a-f]+\.[0-9a-f]+/ {print $25, $26, $1}' | sort -rn

# 查询 OSD 空间使用大于 84%
ceph osd df | awk '$17>84{print}'
```

## 操作技巧

### 查看 OSD 与硬盘关系

```bash
# 查看 OSD 与硬盘以及硬盘槽位的关系
ceph-volume lvm list

# 查看故障盘信息
smartctl -a /dev/sdc

# 在 IPMI 查看对应的槽位
```

### 换盘操作

```bash
# 在 ceph01 节点进行操作（硬件损坏，更换磁盘）
ceph osd out osd.46
ceph osd rm osd.46
ceph osd crush rm osd.46
ceph -s
```
ceph auth del osd.46
 
 
#在 ceph03 节点操作（硬件未损坏，磁盘格式化）
#格式化盘也可以在 ceph01 执行这个 ceph orch device zap  caspain-ceph03 /dev/sdc  --force
ceph-volume lvm zap /dev/sdc
#如果报错则执行
dd if=/dev/zero of=/dev/sdc bs=512K count=1
  
#然后在 ceph01 节点执行
ceph orch daemon add osd caspain-ceph03:/dev/sdc



```

### ceph 报错full ratios(s) out of order 
```bash
原因：osd_failsafe_full_ratio 小于 full_ratio

解决方法：设置full_ratio小于等于osd_failsafe_full_ratio

ceph osd set-full-ratio 0.97


```
### 报错OSD_SCRUB_ERRORS: 55 scrub errors ，多个pg出现在了同一块盘上
```bash
#通过命令随机查询pg不一致对象列表：
  
rados list-inconsistent-obj  2.1fd0  --format=json-pretty
 
rados list-inconsistent-obj  2.1960  --format=json-pretty |tail -30
  
rados list-inconsistent-obj  2.fa8 --format=json-pretty |tail -30

ceph osd find 79
 
 
#寻找osd79对应的盘
ceph-volume lvm list |grep  -A20 osd.79
 
  
#搜寻到osd79对应盘为sdj
  
smartctl -l error /dev/sdj 

smartctl -i /dev/sdj
  
#磁盘sn为ZVT8MRWW
smartctl 7.0 2018-12-30 r4883 [x86_64-linux-5.4.260-1.el7.elrepo.x86_64] (local build)
Copyright (C) 2002-18, Bruce Allen, Christian Franke, www.smartmontools.org
 
=== START OF INFORMATION SECTION ===
Device Model:     ST20000NM007D-3DJ103
Serial Number:    ZVT8MRWW
LU WWN Device Id: 5 000c50 0e66b16f6
Firmware Version: SB2A
User Capacity:    20,000,588,955,648 bytes [20.0 TB]
Sector Sizes:     512 bytes logical, 4096 bytes physical
Rotation Rate:    7200 rpm
Form Factor:      3.5 inches
Device is:        Not in smartctl database [for details use: -P showall]
ATA Version is:   ACS-4 (minor revision not indicated)
SATA Version is:  SATA 3.3, 6.0 Gb/s (current: 6.0 Gb/s)
Local Time is:    Mon Oct 14 10:20:18 2024 CST
SMART support is: Available - device has SMART capability.
SMART support is: Enabled
1、上传storcli64到OS
 
2、Chmod +x
storcli64 #赋予工具文件执行权限
 
 
3、./storcli64 /c0 show all #查看硬盘背板号


#c0查看控制器0号控制器的，e8代表背板号，s1代表硬盘号
  
./storcli64 /c0/e8/s12 show all |grep -i SN

#给slot7的硬盘打开定位灯
./storcli64 /c0/e8/s12 start locate
 
 
#给slot7的硬盘关闭定位灯
./storcli64 /c0/e8/s12 stop locate
  
#观察硬盘灯闪烁情况，灯与其他闪烁不一样
  
#坏盘移除从ceph集群当中
  
ceph osd stop osd.79
 
ceph osd crush remove osd.79
 
ceph osd rm osd.79
 
ceph auth del osd.79
 
 
#硬盘更换后，重新添加osd：
ceph orch daemon add osd ceph214:/dev/sdal

```

### ceph配置
``` bash

ceph pg set-nearfull-ratio 0.85
 
ceph pg set_full_ratio 0.95
 
 
backfillfull_ratio 0.9
nearfull_ratio 0.9
 
ceph osd set-nearfull-ratio 0.9
ceph osd set-backfillfull-ratio 0.95

 
mon_osd_nearfull_ratio = 0.850000
mon_osd_nearfull_ratio = 0.9
 
ceph pg set_nearfull_ratio 0.92
 
ceph pg set_full_ratio 0.95
```

### ceph  pg balancer
```bash
#启用balancer模块
  
ceph mgr module enable balancer
  
#告知集群只需要支持 luminous 或更新的客户端
 
 
ceph osd set-require-min-compat-client luminous
 
 
#可以检查哪些客户端版本被用于：
 
ceph features
 
 
#默认模式为 none。可使用以下方法更改模式:
  
ceph balancer mode upmap
  
#启用balancer 模块
  
ceph balancer on
  
#查看balancer状态
  
ceph balancer status

ceph balancer eval

参考链接：

https://www.hikunpeng.com/document/detail/zh/kunpengsdss/ecosystemEnable/Ceph/kunpengcephfile_05_0008.html

https://docs.redhat.com/zh-cn/documentation/red_hat_ceph_storage/4/html/operations_guide/using-the-ceph-manager-balancer-module_ops#using-the-ceph-manager-balancer-module_ops
```

### ceph  dashboard修改密码
```bash
#查看用户
  
 ceph dashboard ac-user-show
  
 #将密码存放到1.txt
  
 echo XXXX >1.xt
  
 #修改密码
  
 ceph dashboard ac-user-set-password admin --force-password -i 1.txt
  
 #删除1.txt
  
 rm -rf 1.txt
```

