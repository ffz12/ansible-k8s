#!/bin/bash
#配置安装 docker 和 containerd 的需要的阿里云 yum 源

yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo

#安装containerd

yum install containerd.io-1.6.22 -y

#生成配置文件

containerd config default > /etc/containerd/config.toml

#修改containerd配置文件

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

sed -i 's#sandbox_image = "registry.k8s.io/pause:3.6"#sandbox_image = "k8s.m.daocloud.io/pause:3.9"#g' /etc/containerd/config.toml

#设置开机启动

systemctl enable containerd --now

#设置crictl容器运行时

crictl config runtime-endpoint unix:///run/containerd/containerd.sock

#重启

systemctl daemon-reload

systemctl restart containerd

