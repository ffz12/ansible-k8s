#!/bin/bash
apt-get remove -y ansible ansible-core
apt-get update
apt-get install -y software-properties-common
add-apt-repository -y ppa:ansible/ansible
apt-get install -y ansible
