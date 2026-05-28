#!/bin/bash
IMAGE="gmpfuzz/mqtt"
DIR="$(pwd)/crash/Mosquitto_vuln_Mosquitto-mqtt-aflnetout_0000.tar.gz__id_000001"

cat << 'INNEREOF' > "$DIR/test_run.sh"
#!/bin/bash
export ASAN_OPTIONS="detect_leaks=0,abort_on_error=1,symbolize=1"

# create a basic mosquitto conf allowing root
cat << 'CONFE' > mosquitto_test.conf
user root
allow_anonymous true
CONFE

/home/ubuntu/experiments/mosquitto/src/mosquitto -c mosquitto_test.conf -v &
BROKER_PID=$!
sleep 1
echo "Running aflnet-replay directly"
/home/ubuntu/aflnet/aflnet-replay poc.raw MQTT 1883
kill -9 $BROKER_PID 2>/dev/null
INNEREOF
chmod +x "$DIR/test_run.sh"
docker run --rm -v "$DIR:/crash_dir" -w /crash_dir -u root "$IMAGE" ./test_run.sh
