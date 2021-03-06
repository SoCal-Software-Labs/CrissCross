#!/bin/bash

# trap for SIGTERM and set RET_VALUE to false
trap "RET_VAL=false" SIGTERM

MY_PID=$$
# Initialize RET_VALUE to true
RET_VAL=true

BLUE=$(tput setaf 4)
GREEN=$(tput setaf 2)
NONE=$(tput op)

COMMAND=docker



if [[ ! -z "${IPV4}" ]]; then
  BIND_IP="0.0.0.0"
else
  BIND_IP="::0"
fi

if ! command -v docker &> /dev/null
then
    echo "You must have podman or docker installed"
    exit
fi

echo "$STORAGE_BACKEND"

IMAGE=hansonkd/crisscross:v0.0.4c
CRISSCROSS_IMAGE="${CRISSCROSS_IMAGE:-crisscross}"
INTERNAL_TCP_PORT="${INTERNAL_TCP_PORT:-11111}"
EXTERNAL_PORT="${EXTERNAL_PORT:-22222}"
CLUSTER_DIR="${CLUSTER_DIR:-$(pwd)/clusters}"
DATA_DIR="${DATA_DIR:-$(pwd)/data}"
KEY_DIR="${KEY_DIR:-$(pwd)/keys}"
STORAGE_BACKEND="${STORAGE_BACKEND:-sled:///data}"
EXTERNAL_IP="${EXTERNAL_IP:-$(dig @resolver4.opendns.com myip.opendns.com +short)}"

mkdir -p $DATA_DIR
mkdir -p $KEY_DIR

echo "Killing old container..."
$COMMAND container stop crisscross 2> /dev/null
$COMMAND container rm crisscross 2> /dev/null


($COMMAND run \
    --rm \
    -it \
    -u `id -u`:`id -g` \
    -v $DATA_DIR:/data \
    -v $CLUSTER_DIR:/app/clusters \
    -v $KEY_DIR:/app/keys \
    -e "INTERNAL_TCP_PORT=$INTERNAL_TCP_PORT" \
    -e "BIND_IP=$BIND_IP" \
    -e "EXTERNAL_IP=$EXTERNAL_IP" \
    -e "STORAGE_BACKEND=$STORAGE_BACKEND" \
    -e "LOCAL_AUTH=$LOCAL_AUTH" \
    -e "TUNNEL_TOKEN" \
    -e "EXTERNAL_PORT" \
    -e "BOOTSTRAP_NODES" \
    --name crisscross \
    -p "$EXTERNAL_PORT:$EXTERNAL_PORT/UDP" \
    $IMAGE
)


echo "Cleaning up old container..."

docker container stop crisscross 2> /dev/null
docker container rm crisscross 2> /dev/null

$RET_VAL
