#!/bin/bash
set -e

DATA_DIR="/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/results_20260427_095826"
IMAGE="gmpfuzz/mosquitto"
GCOV_TARGET_DIR="mosquitto-gcov"
GCOV_ROOT="/home/ubuntu/experiments/mosquitto-gcov/src/.."
GCOV_SRC_DIR="/home/ubuntu/experiments/mosquitto-gcov/src"
GCOV_CONF="/home/ubuntu/experiments/mosquitto.conf"
GCOV_BIN="./mosquitto"
GCOV_PORT=1883

echo "=== Recovering AFLNet for Mosquitto Latest ==="
AFLNET_DIR="${DATA_DIR}/aflnet"
for i in 1 2 3 4; do
    echo "Recovering AFLNet instance $i..."
    REPLAY_SRC="${AFLNET_DIR}/instance_${i}/out-mosquitto-aflnet/replayable-queue"
    MERGED_AFLNET_DIR=$(mktemp -d)
    
    if [ -d "$REPLAY_SRC" ]; then
        for f in "${REPLAY_SRC}"/*; do
            [ -f "$f" ] && cp "$f" "${MERGED_AFLNET_DIR}/$(basename "$f")"
        done
    fi
    
    if [ "$(ls -A "$MERGED_AFLNET_DIR" | wc -l)" -eq 0 ]; then
        echo "No replayable files found for AFLNet instance $i."
        rm -rf "$MERGED_AFLNET_DIR"
        continue
    fi
    
    GCOV_CID_AFL=$(docker run -d --cpus=2 -v "${MERGED_AFLNET_DIR}:/tmp/replay_inputs:ro" "$IMAGE" /bin/bash -c "
        cd /home/ubuntu/experiments/mosquitto-gcov
        gcovr -r . -s -d > /dev/null 2>&1
        cd /home/ubuntu/experiments/mosquitto-gcov/src
        for f in /tmp/replay_inputs/*id*; do
            [ -f \"\$f\" ] || continue
            pkill -f \"$GCOV_TARGET_DIR\" 2>/dev/null || true
            timeout -k 0 -s SIGTERM 3s $GCOV_BIN -c $GCOV_CONF > /dev/null 2>&1 &
            MOSQ_PID=\\$!
            sleep 0.1
            aflnet-replay \"\$f\" MQTT $GCOV_PORT 1 > /dev/null 2>&1
            kill -TERM \$MOSQ_PID 2>/dev/null
            wait \$MOSQ_PID 2>/dev/null || true
        done
        cd /home/ubuntu/experiments/mosquitto-gcov
        echo '=== GCOVR_TEXT_START ==='
        gcovr -r . -s 2>/dev/null || echo 'no data'
        echo '=== GCOVR_TEXT_END ==='
    ")
    
    docker wait "$GCOV_CID_AFL" > /dev/null
    GCOV_LOG=$(docker logs "$GCOV_CID_AFL" 2>&1)
    GCOV_TEXT=$(echo "$GCOV_LOG" | sed -n '/=== GCOVR_TEXT_START ===/,/=== GCOVR_TEXT_END ===/p')
    
    L_PER=$(echo "$GCOV_TEXT" | grep -i 'lines:' | head -1 | sed 's/.*lines: *\([0-9.]*\)%.*/\1/')
    L_ABS=$(echo "$GCOV_TEXT" | grep -i 'lines:' | head -1 | sed 's/.*(\([0-9]*\) out of.*/\1/')
    B_PER=$(echo "$GCOV_TEXT" | grep -i 'branch' | head -1 | sed 's/.*branches: *\([0-9.]*\)%.*/\1/')
    B_ABS=$(echo "$GCOV_TEXT" | grep -i 'branch' | head -1 | sed 's/.*(\([0-9]*\) out of.*/\1/')
    
    echo "AFLNet instance $i recovered: Lines=${L_PER:-0}%, Branches=${B_PER:-0}%"
    
    cat << IN_EOF > "${AFLNET_DIR}/instance_${i}/cov_over_time.csv"
Time,l_per,l_abs,b_per,b_abs
0,${L_PER:-0},${L_ABS:-0},${B_PER:-0},${B_ABS:-0}
IN_EOF

    docker rm -f "$GCOV_CID_AFL" > /dev/null
    rm -rf "$MERGED_AFLNET_DIR"
done

echo "=== Recovering GMPFuzz for Mosquitto Latest ==="
EVAL_DIR="${DATA_DIR}/gmpfuzz/instance_1"
LAST_GEN_DIR=$(ls -d "${EVAL_DIR}"/gen*/aflnetout 2>/dev/null | sort -V | tail -1)

while [ -n "$LAST_GEN_DIR" ] && [ "$(ls -A "$LAST_GEN_DIR" 2>/dev/null | wc -l)" -eq 0 ]; do
    LAST_GEN_DIR=$(ls -d "${EVAL_DIR}"/gen*/aflnetout 2>/dev/null | sort -V | grep -v "$(basename "$(dirname "$LAST_GEN_DIR")")" | tail -1)
done
if [ -n "$LAST_GEN_DIR" ]; then
    LAST_GEN_NAME=$(basename "$(dirname "$LAST_GEN_DIR")")
    echo "GMPFuzz latest valid gen: $LAST_GEN_NAME"

    MERGED_GMP_DIR=$(mktemp -d)
    for tarball in "${LAST_GEN_DIR}"/aflnetout_*.tar.gz; do
        [ -f "$tarball" ] || continue
        base=$(basename "$tarball" .tar.gz)
        TARBALL_TMP=$(mktemp -d)
        tar -xzf "$tarball" -C "$TARBALL_TMP" 2>/dev/null || true
        for f in "$TARBALL_TMP"/*/replayable-queue/*; do
            [ -f "$f" ] && cp "$f" "${MERGED_GMP_DIR}/${base}_$(basename "$f")"
        done
        rm -rf "$TARBALL_TMP"
    done

    GMP_COUNT=$(ls -A "$MERGED_GMP_DIR" | wc -l)
    echo "GMPFuzz merged cases: $GMP_COUNT"

    GCOV_CID_GMP=$(docker run -d --cpus=2 -v "${MERGED_GMP_DIR}:/tmp/replay_inputs:ro" "$IMAGE" /bin/bash -c "
        cd /home/ubuntu/experiments/mosquitto-gcov
        gcovr -r . -s -d > /dev/null 2>&1
        cd /home/ubuntu/experiments/mosquitto-gcov/src
        for f in /tmp/replay_inputs/*id*; do
            [ -f \"\$f\" ] || continue
            pkill -f \"mosquitto-gcov\" 2>/dev/null || true
            timeout -k 0 -s SIGTERM 3s ./mosquitto -c $GCOV_CONF > /dev/null 2>&1 &
            MOSQ_PID=\\$!
            sleep 0.1
            aflnet-replay \"\$f\" MQTT $GCOV_PORT 1 > /dev/null 2>&1
            kill -TERM \$MOSQ_PID 2>/dev/null
            wait \$MOSQ_PID 2>/dev/null || true
        done
        cd /home/ubuntu/experiments/mosquitto-gcov
        echo '=== GCOVR_TEXT_START ==='
        gcovr -r . -s 2>/dev/null || echo 'no data'
        echo '=== GCOVR_TEXT_END ==='
    ")

    docker wait "$GCOV_CID_GMP" > /dev/null
    GCOV_LOG_G=$(docker logs "$GCOV_CID_GMP" 2>&1)
    GCOV_TEXT_G=$(echo "$GCOV_LOG_G" | sed -n '/=== GCOVR_TEXT_START ===/,/=== GCOVR_TEXT_END ===/p')

    L_PER_G=$(echo "$GCOV_TEXT_G" | grep -i 'lines:' | head -1 | sed 's/.*lines: *\([0-9.]*\)%.*/\1/')
    L_ABS_G=$(echo "$GCOV_TEXT_G" | grep -i 'lines:' | head -1 | sed 's/.*(\([0-9]*\) out of.*/\1/')
    B_PER_G=$(echo "$GCOV_TEXT_G" | grep -i 'branch' | head -1 | sed 's/.*branches: *\([0-9.]*\)%.*/\1/')
    B_ABS_G=$(echo "$GCOV_TEXT_G" | grep -i 'branch' | head -1 | sed 's/.*(\([0-9]*\) out of.*/\1/')

    echo "GMPFuzz recovered: Lines=${L_PER_G:-0}%, Branches=${B_PER_G:-0}%"

    cat << IN_EOF > "${EVAL_DIR}/cov_over_time.csv"
Time,l_per,l_abs,b_per,b_abs
0,${L_PER_G:-0},${L_ABS_G:-0},${B_PER_G:-0},${B_ABS_G:-0}
IN_EOF

    docker rm -f "$GCOV_CID_GMP" > /dev/null
    rm -rf "$MERGED_GMP_DIR"
fi

echo "=== Updating Summary ==="
bash experiments/collect_coverage.sh $DATA_DIR
