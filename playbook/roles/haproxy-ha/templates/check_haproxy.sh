#!/bin/bash
ss -lntp | grep -q haproxy
if [ $? -ne 0 ]; then
   exit 1
else
   exit 0
fi