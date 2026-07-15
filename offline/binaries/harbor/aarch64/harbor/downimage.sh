 docker save -o harbor.v2.13.0aarch64.tar.gz  `docker images |grep v2.13.0-aarch64 | awk 'BEGIN{OFS=":";ORS=" "}{print $1,$2}'`
