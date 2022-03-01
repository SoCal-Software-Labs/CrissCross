#!/bin/bash


(docker run \
    --restart=always \
    -u `id -u`:`id -g` \
    -v /root/data:/data \
    -v /root/clusters:/app/clusters \
    -v /root/keys:/app/keys \
    -e "BIND_IP=0.0.0.0" \
    -e "EXTERNAL_IP=$(dig @resolver4.opendns.com myip.opendns.com +short)" \
    -e "STORAGE_BACKEND=sled:///data" \
    -e "BOOTSTRAP_NODES=" \
    --name crisscross \
    -p "$EXTERNAL_PORT:22222/UDP" \
    -d \
    hansonkd/crisscross:v0.0.3
)
