#!/bin/bash
mkdir /etc/tuned/balanced-tidb-optimal/
tee /etc/tuned/balanced-tidb-optimal/tuned.conf <<eof
[main]
include=balanced
[cpu]
governor=performance
eof

tuned-adm profile balanced-tidb-optimal

