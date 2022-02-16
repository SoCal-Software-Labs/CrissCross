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


KEYDB_IMAGE="${KEYDB_IMAGE:-'eqalpha/keydb:alpine_x86_64_v6.2.2'}"
INTERNAL_TCP_PORT="${INTERNAL_TCP_PORT:-11111}"
EXTERNAL_TCP_PORT="${EXTERNAL_TCP_PORT:-22222}"
EXTERNAL_UDP_PORT="${EXTERNAL_UDP_PORT:-33333}"
CLUSTER_DIR="${CLUSTER_DIR:-$(pwd)/clusters}"
DATA_DIR="${DATA_DIR:-$(pwd)/data}"
EXTERNAL_IP=$(dig @resolver4.opendns.com myip.opendns.com +short)

echo $CLUSTER_DIR
echo $DATA_DIR

echo "Killing old containers..."
docker container stop keydb 2> /dev/null
docker container rm keydb 2> /dev/null
docker container stop crisscross 2> /dev/null
docker container rm crisscross 2> /dev/null
docker network create crisscrossnet 2> /dev/null

if [[ "$(docker images -q $KEYDB_IMAGE 2> /dev/null)" == "" ]]; then
  docker pull $KEYDB_IMAGE
fi


# docker pull crisscross

thread_listener() {
    ($COMMAND run \
        --rm \
        -t \
        --net crisscrossnet \
        --name keydb \
        -v $DATA_DIR:/data \
        $KEYDB_IMAGE \
        keydb-server /etc/keydb/keydb.conf --appendonly yes \
        | sed -e 's/^\(.*\)$/'"$BLUE"'[KeyDB]      \1'"$NONE"'/') &
    PID=$!
    # trap for sigterm and kill the long time process
    trap "kill $PID" SIGTERM

    wait $PID
}


# Runs thread listener in a separate job
thread_listener &
PID1=$!

($COMMAND run \
    --rm \
    -it \
    -v $CLUSTER_DIR:/app/clusters \
    -e "REDIS_URL=redis://keydb.crisscrossnet" \
    -e "INTERNAL_TCP_PORT=$INTERNAL_TCP_PORT" \
    -e "EXTERNAL_TCP_PORT=$EXTERNAL_TCP_PORT" \
    -e "EXTERNAL_UDP_PORT=$EXTERNAL_UDP_PORT" \
    -e "EXTERNAL_IP=$EXTERNAL_IP" \
    -e "LOCAL_AUTH=$LOCAL_AUTH" \
    --net crisscrossnet \
    --name crisscross \
    -p $INTERNAL_TCP_PORT:$INTERNAL_TCP_PORT \
    -p $EXTERNAL_TCP_PORT:$EXTERNAL_TCP_PORT \
    -p "$EXTERNAL_UDP_PORT:$EXTERNAL_UDP_PORT/UDP" \
    crisscross 2>&1 | sed -e 's/^\(.*\)$/'"$GREEN"'[CrissCross] \1'"$NONE"'/'
) \
    || kill $PID1


echo "Cleaning up old containers..."

docker container stop keydb 2> /dev/null
docker container rm keydb 2> /dev/null
docker container stop crisscross 2> /dev/null
docker container rm crisscross 2> /dev/null

docker network rm crisscrossnet

$RET_VAL
