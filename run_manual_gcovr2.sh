#!/bin/bash
BASE_RESULT_DIR="evaluation/mongoose_ablation_supplement_20260524_172824"
EVAL_DIR="$(ls -d ${BASE_RESULT_DIR}/gmpfuzz_mongoose_mongoose_ablation_no-llm_* 2>/dev/null | head -n 1)"
LAST_GEN=""
for gen in $(ls -d ${EVAL_DIR}/gen*/ | sort -rV); do
    if ls "$gen/aflnetout"/aflnetout_*.tar.gz 1> /dev/null 2>&1; then
        LAST_GEN="$gen"
        break
    fi
done
MERGED_REPLAY_DIR=$(mktemp -d)
for tarball in "${LAST_GEN}aflnetout"/aflnetout_*.tar.gz; do
    [ -f "$tarball" ] || continue
    TARBALL_TMP=$(mktemp -d)
    tar -xzf "$tarball" -C "$TARBALL_TMP" 2>/dev/null || true
    find "$TARBALL_TMP" -path '*/replayable-queue/*' -type f -exec cp {} "$MERGED_REPLAY_DIR/" \; 2>/dev/null || true
    MERGED_FILE_COUNT=$(ls -A "$MERGED_REPLAY_DIR" 2>/dev/null | wc -l)
    if [ "$MERGED_FILE_COUNT" -eq 0 ]; then
        find "$TARBALL_TMP" -path '*/queue/id:*' -type f -exec cp {} "$MERGED_REPLAY_DIR/" \; 2>/dev/null || true
    fi
    rm -rf "$TARBALL_TMP"
done

cat << 'INNER_EOF' > "${MERGED_REPLAY_DIR}/ultra_replay_mongoose.sh"
#!/bin/bash
cd /home/ubuntu/experiments/mongoose-gcov
gcovr -r /home/ubuntu/experiments/mongoose-src --object-directory /home/ubuntu/experiments/mongoose-gcov -s -d > /dev/null 2>&1 || true
for f in /mnt/inputs/*; do
     pkill -f "./mongoose_mqtt_broker" 2>/dev/null || true
     sleep 0.05
     ./mongoose_mqtt_broker mqtt://0.0.0.0:1883 > /dev/null 2>&1 &
     SERVER_PID=$!
     sleep 0.05
     aflnet-replay "$f" MQTT 1883 1 > /dev/null 2>&1 || true
     kill -TERM $SERVER_PID 2>/dev/null || true
     wait $SERVER_PID 2>/dev/null || true
done
echo "===GCOV==="
gcovr -r /home/ubuntu/experiments/mongoose-src --object-directory /home/ubuntu/experiments/mongoose-gcov -s || true
INNER_EOF

chmod +x "${MERGED_REPLAY_DIR}/ultra_replay_mongoose.sh"
docker run --rm --cpus=1 -v "${MERGED_REPLAY_DIR}:/mnt/inputs:ro" gmpfuzz/mongoose /bin/bash -c "/mnt/inputs/ultra_replay_mongoose.sh" > "${EVAL_DIR}/gcovr_output.txt" 2>&1 || true
rm -rf "$MERGED_REPLAY_DIR"
grep 'branches:' "${EVAL_DIR}/gcovr_output.txt"
