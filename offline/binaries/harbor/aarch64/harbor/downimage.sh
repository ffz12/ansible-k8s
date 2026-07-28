# docker save -o 不压缩; 用管道走 gzip 才是真正的 .tar.gz (install.sh 里 docker load 会自动解压)
docker save `docker images |grep v2.13.0-aarch64 | awk 'BEGIN{OFS=":";ORS=" "}{print $1,$2}'` | gzip > harbor.v2.13.0aarch64.tar.gz
