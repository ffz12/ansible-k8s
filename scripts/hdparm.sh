#!/bin/bash
for i in sda sdb sdc sdd sde sdf sdg sdh sdi sdj sdk sdl sdm sdn sdo sdp sdq sdr sds sdt sdu sdv sdw sdx sdy sdz sdaa sdab sdac sdad sdae sdaf sdag sdah sdai sdaj
do
     hdparm -W0 /dev/$i
done
