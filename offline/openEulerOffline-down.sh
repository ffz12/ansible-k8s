#!/bin/bash

osVersion=`awk '{print $3}' /etc/openEuler-release`
offlineDir=/tmp/openEuler-pkg

#offlinePkg="createrepo wget net-tools  lrzsz gcc gcc-c++ make cmake libxml2-devel openssl-devel curl curl-devel unzip sudo ntp libaio-devel  vim* ncurses-devel autoconf automake zlib-devel   openssh-server socat iotop sysstat nfs* ipvsadm conntrack ebtables g++  vim  lvm2 chrony  ipset  git  elfutils-libelf-devel   htop  tar tmux rsync authconfig   nss-pam-ldapd pam_ldap openldap-clients oddjob oddjob-mkhomedir"
offlinePkg=ansible


if [ ! -d "$offlineDir" ]; then
    mkdir $offlineDir -p
fi




yum install --downloadonly --downloaddir=$offlineDir  $offlinePkg  -y

echo "请将 $offlineDir 移动到 /root/ansible-pro/playbook/roles/offline-init/files 下"

