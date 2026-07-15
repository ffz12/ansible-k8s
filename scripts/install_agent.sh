#!/bin/bash

#专线ip，控制台上获取
vip=""
#安装token，控制台上获取
token=""

log()
{
  tm=$(date +'%F %T')
  echo "$tm $@"
}

#卸载京东云
uninst_jdyun()
{
    if [ ! -d /usr/local/share/jcloud/jdog-monitor ]; then
        return
    fi
    log "uninstall jdyun agent..."
    ps -ef | grep /usr/local/share/jcloud/jdog-monitor | grep -v grep | awk '{print $2}' | xargs kill -9 2>&1 >/dev/null
    if [ -f /usr/local/share/jcloud/jdog-monitor/scripts/jdog_service ]; then
        bash /usr/local/share/jcloud/jdog-monitor/scripts/jdog_service stop 2>&1 >/dev/null
        bash /usr/local/share/jcloud/jdog-monitor/scripts/jdog_service uninstall 2>&1 >/dev/null
    fi
    rm -rf /usr/local/share/jcloud/jdog-monitor 2>&1 >/dev/null
}

#卸载阿里云agent
uninst_aliyun()
{
    #若已经开启自保护，请先阿里云控制台关闭自保护后再操作
    if [ ! -d /usr/local/aegis ]; then
        return
    fi
    log "uninstall aliyun agent..."
    wget "http://update2.aegis.aliyun.com/download/uninstall.sh" && chmod +x uninstall.sh && ./uninstall.sh
}

#安装主机安全agent
install_yunjing()
{
    log "install yunjing agent..."
    if [ ! -z "$vip" ]; then
        wget http://$vip/ydeyes_linux64.tar.gz -O ydeyes_linux64.tar.gz && tar -zxvf ydeyes_linux64.tar.gz &&
            ./self_cloud_install_linux64_mix -mix=default -k=$token -ip=$vip
    else
        wget --no-check-certificate https://up.yd.qcloud.com/ydeyes_linux64.tar.gz -O ydeyes_linux64.tar.gz &&
            tar -zxvf ydeyes_linux64.tar.gz && ./self_cloud_install_linux64_mix -mix=default -k=$token
    fi
}

install()
{
    uninst_jdyun
    uninst_aliyun
    install_yunjing
}

while [[ $# -gt 0 ]]
do
    case "$1" in
        -vip)
            vip="$2"
            shift
            ;;
        -token)
            token="$2"
            shift
            ;;
        *)
            echo "Unsupported instruction: $1, Expecting one of [ vip | token]"
            exit 1
            ;;
    esac
    shift
done

if [ -z "$vip" -a -z "$token" ]; then
   echo "Usage: $0 -vip 1.1.1.1 -token 7fb294cdf6a4"
   exit 1
fi

install


