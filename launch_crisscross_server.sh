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

if ! command -v docker &> /dev/null
then
    echo "You must have podman or docker installed"
    exit
fi

echo "$STORAGE_BACKEND"

CRISSCROSS_IMAGE="${CRISSCROSS_IMAGE:-crisscross}"
INTERNAL_TCP_PORT="${INTERNAL_TCP_PORT:-11111}"
EXTERNAL_TCP_PORT="${EXTERNAL_TCP_PORT:-22222}"
EXTERNAL_UDP_PORT="${EXTERNAL_UDP_PORT:-33333}"
CLUSTER_DIR="${CLUSTER_DIR:-$(pwd)/clusters}"
DATA_DIR="${DATA_DIR:-$(pwd)/data}"
STORAGE_BACKEND="${STORAGE_BACKEND:-sled:///data}"
EXTERNAL_IP="${EXTERNAL_IP:-$(dig @resolver4.opendns.com myip.opendns.com +short)}"

mkdir -p $DATA_DIR

echo "Killing old container..."
docker container stop crisscross 2> /dev/null
docker container rm crisscross 2> /dev/null

# if [[ "$(docker images -q $CRISSCROSS_IMAGE 2> /dev/null)" == "" ]]; then
#   docker pull $CRISSCROSS_IMAGE
# fi


($COMMAND run \
    --rm \
    -it \
    --user 1000:1000 \
    -v $DATA_DIR:/data \
    -v $CLUSTER_DIR:/app/clusters \
    -e "INTERNAL_TCP_PORT=$INTERNAL_TCP_PORT" \
    -e "EXTERNAL_TCP_PORT=$EXTERNAL_TCP_PORT" \
    -e "EXTERNAL_UDP_PORT=$EXTERNAL_UDP_PORT" \
    -e "EXTERNAL_IP=$EXTERNAL_IP" \
    -e "STORAGE_BACKEND=$STORAGE_BACKEND" \
    -e "LOCAL_AUTH=$LOCAL_AUTH" \
    --name crisscross \
    -p $INTERNAL_TCP_PORT:$INTERNAL_TCP_PORT \
    -p $EXTERNAL_TCP_PORT:$EXTERNAL_TCP_PORT \
    -p "$EXTERNAL_UDP_PORT:$EXTERNAL_UDP_PORT/UDP" \
    crisscross 2>&1 | sed -e 's/^\(.*\)$/'"$GREEN"'[CrissCross] \1'"$NONE"'/'
)


echo "Cleaning up old container..."

docker container stop crisscross 2> /dev/null
docker container rm crisscross 2> /dev/null

$RET_VAL
