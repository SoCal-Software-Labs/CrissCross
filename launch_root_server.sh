#!/bin/bash


(docker run \
    --restart=always \
    -u `id -u`:`id -g` \
    -v /root/data:/data \
    -v /root/clusters:/app/clusters \
    -v /root/keys:/app/keys \
    -e "BIND_IP=::0" \
    -e "STORAGE_BACKEND=sled:///data" \
    -e "BOOTSTRAP_NODES=" \
    --name crisscross \
    --network host \
    -d \
    hansonkd/crisscross:v0.0.4c
)
