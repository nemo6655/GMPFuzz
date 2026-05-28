#!/bin/bash
IMAGE="mosquitto-replay"
BASE_DIR=$(pwd)
CRASH_DIR="$BASE_DIR/crash"

SUMMARY_FILE="/tmp/mosq_asan_docker_repro_summary.tsv"
echo -e "Crash_Dir\tStatus\tASAN_Type" > "$SUMMARY_FILE"

for DIR in $CRASH_DIR/Mosquitto_vuln_*; do
    if [ ! -d "$DIR" ]; then continue; fi
    echo "============================================"
    echo "Processing $(basename "$DIR")"
    cd "$DIR"

    rm -f asan_*.log broker_*.log send*.log asan_snippet.txt inner_replay.sh mosquitto.conf

    # Create config file explicitly allowing anonymous and listening on 1883
    cat << 'CONFE' > mosquitto.conf
listener 1883
allow_anonymous true
log_type all
CONFE

    cat << 'INNEREOF' > inner_replay.sh
#!/bin/bash
export ASAN_OPTIONS="detect_leaks=0,abort_on_error=1,symbolize=1,log_path=asan_custom.log"
/opt/mosquitto/src/mosquitto -c mosquitto.conf > broker_stdout.log 2>&1 &
BROKER_PID=$!

sleep 1
# Run aflnet-replay inside container loop through sizes if needed or just pass directly
/home/ubuntu/aflnet/aflnet-replay poc.raw MQTT 1883 > send.log 2>&1

sleep 2
kill -9 $BROKER_PID 2>/dev/null
wait $BROKER_PID 2>/dev/null

cat asan_custom.log.* >> broker_stdout.log 2>/dev/null
chmod 666 broker_stdout.log send.log asan_custom.log* 2>/dev/null || true
exit 0
INNEREOF
    chmod +x inner_replay.sh

    docker run --rm -v "$DIR:/crash_dir" -w /crash_dir -u root "$IMAGE" ./inner_replay.sh

    if grep -q "ERROR: AddressSanitizer:" broker_stdout.log; then
        echo "  => [SUCCESS] ASAN Crash Triggered!"
        awk '/ERROR: AddressSanitizer:/, /SUMMARY:/' broker_stdout.log > asan_snippet.txt
        TYPE=$(grep "ERROR: AddressSanitizer:" broker_stdout.log | head -n 1 | sed 's/.*ERROR: AddressSanitizer: //')
        echo -e "$(basename "$DIR")\tConfirmed\t$TYPE" >> "$SUMMARY_FILE"
        
        echo "# ASAN Crash Report" > report.md
        echo "Status: Confirmed" >> report.md
        echo '```' >> report.md
        cat asan_snippet.txt >> report.md
        echo '```' >> report.md
    else
        echo "  => [FAIL] No ASAN crash triggered."
        echo -e "$(basename "$DIR")\tUnconfirmed\tN/A" >> "$SUMMARY_FILE"
    fi
    
    cd "$BASE_DIR"
done

echo "============================================"
echo "Replay Summary:"
column -t "$SUMMARY_FILE"
