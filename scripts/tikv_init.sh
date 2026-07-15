#!/bin/bash

#待数据存放磁盘
disk=/dev/sdb

#磁盘挂载目录
datadir=/tikv-data/

#关闭交换区
swapoff -a

#磁盘挂载目录创建

rm -rf $datadir

mkdir $datadir

#磁盘开机自动挂载脚本

tee /etc/systemd/system/mount-remote-tikv-data.service <<eof
[Unit]
Description=Wait until NM actually online
After=NetworkManager-wait-online.service

[Service]
Type=oneshot
ExecStart=/usr/bin/mount  -t ext4  -o defaults,nodelalloc,noatime  $disk $datadir
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
eof

#启动挂载服务

systemctl enable mount-remote-tikv-data.service --now

#安装tuned

yum install tuned numactl -y

#创建新的 tuned 策略

mkdir /etc/tuned/balanced-tidb-optimal/ -p

diskid=`udevadm info --name=$disk | grep ID_SERIAL=|awk -F":" '{print $2}'`

tee /etc/tuned/balanced-tidb-optimal/tuned.conf <<eof
[main]
include=balanced

[cpu]
governor=performance

[vm]
transparent_hugepages=never

[disk]
devices_udev_regex=($diskid)
elevator=noop
eof

#应用新的 tuned 策略。
tuned-adm profile balanced-tidb-optimal

#修改 sysctl 参数
tee /etc/sysctl.conf <<eof
fs.file-max = 1000000
net.core.somaxconn = 32768
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_syncookies = 0
vm.overcommit_memory = 1
vm.swappiness = 0
eof

sysctl -p

#配置用户的 limits.conf
cat << EOF >>/etc/security/limits.conf
tidb           soft    nofile          1000000
tidb           hard    nofile          1000000
tidb           soft    stack          32768
tidb           hard    stack          32768
EOF

