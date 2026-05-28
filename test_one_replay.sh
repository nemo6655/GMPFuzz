#!/bin/bash
DIR=$1
if [ -z "$DIR" ]; then echo "Needs dir"; exit 1; fi

cd $DIR
echo "Testing in $DIR"
docker run --rm -d --network host --name mqtt-test-broker mosquitto:asan > /dev/null
sleep 1

python3 ../../aflnet_replay.py poc.raw > test_replay.log

sleep 2
docker logs mqtt-test-broker > broker_docker.log
docker stop mqtt-test-broker > /dev/null

cat broker_docker.log | grep -A 20 "ERROR: AddressSanitizer"
