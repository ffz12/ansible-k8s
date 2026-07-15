#/bin/bash
disk=/dev/sdb 

datadir=/tikv-data/
rm -rf $datadir

mkdir $datadir

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

systemctl enable mount-remote-tikv-data.service --now
