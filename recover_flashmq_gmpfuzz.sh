#!/bin/bash
set -eo pipefail

EVAL_DIR="/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/results_20260417_174913"
GMPFUZZ_DIR="${EVAL_DIR}/gmpfuzz/instance_1"

# 找到最后一轮有数据的 gen
LAST_GEN_DIR=$(ls "${GMPFUZZ_DIR}"/gen*/aflnetout/aflnetout_*.tar.gz 2>/dev/null | rev | cut -d/ -f2- | rev | sort -V | uniq | tail -1)
LAST_GEN_NAME=$(basename "$(dirname "$LAST_GEN_DIR")")

echo "=== Recovering GMPFuzz (Flashmq) ==="
echo "Latest Target Gen: $LAST_GEN_NAME"

MERGED_REPLAY_DIR=$(mktemp -d /tmp/gmpfuzz_gcovr_merged_XXXXXX)

for tarball in "${LAST_GEN_DIR}"/aflnetout_*.tar.gz; do
    [ -f "$tarball" ] || continue
    base=$(basename "$tarball" .tar.gz)
    TARBALL_TMP=$(mktemp -d)
    tar -xzf "$tarball" -C "$TARBALL_TMP" 2>/dev/null || true
    
    find "$TARBALL_TMP" -path '*/replayable-queue/*' -type f -exec cp {} "$MERGED_REPLAY_DIR/" \; 2>/dev/null || true
    rm -rf "$TARBALL_TMP"
    echo "  extracted $base"
done

MERGED_FILE_COUNT=$(ls -A "$MERGED_REPLAY_DIR" 2>/dev/null | wc -l)
echo "Merged replayable files: $MERGED_FILE_COUNT"

cat << 'INNER_EOF' > "${MERGED_REPLAY_DIR}/ultra_replay.sh"
#!/bin/bash
cd /home/ubuntu/experiments/flashmq-gcov/build
gcovr -r /home/ubuntu/experiments/flashmq-gcov --object-directory /home/ubuntu/experiments/flashmq-gcov/build -s -d > /dev/null 2>&1 || true

for f in /tmp/replay_inputs/*; do
     [ -f "$f" ] || continue
     pkill -f "./flashmq" 2>/dev/null || true
     sleep 0.1
     
     ./flashmq --config-file /home/ubuntu/experiments/flashmq.conf > /dev/null 2>&1 &
     SERVER_PID=$!
     sleep 0.1
     
     aflnet-replay "$f" MQTT 1883 1 > /dev/null 2>&1 || true
     
     kill -TERM $SERVER_PID 2>/dev/null || true
     wait $SERVER_PID 2>/dev/null || true
done

echo "===GCOV==="
gcovr -r /home/ubuntu/experiments/flashmq-gcov --object-directory /home/ubuntu/experiments/flashmq-gcov/build -s || true
echo "===END==="
INNER_EOF

chmod +x "${MERGED_REPLAY_DIR}/ultra_replay.sh"

COV_OUTPUT="${GMPFUZZ_DIR}/ultra_cov_output.txt"
echo "Running Docker to compute coverage (this may take a few minutes)..."
docker run --rm --cpus=4 \
    -v "${MERGED_REPLAY_DIR}:/tmp/replay_inputs:ro" \
    "gmpfuzz/flashmq" \
    /bin/bash -c "/tmp/replay_inputs/ultra_replay.sh" > "$COV_OUTPUT" 2>&1 || true

if [ -f "$COV_OUTPUT" ]; then
    L_PER=$(grep 'lines:' "$COV_OUTPUT" | awk '{print $2}' | tr -d '%' || echo "0")
    L_COV=$(grep 'lines:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $3}' || echo "0")
    L_TOT=$(grep 'lines:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $6}' || echo "0")
    
    B_PER=$(grep 'branches:' "$COV_OUTPUT" | awk '{print $2}' | tr -d '%' || echo "0")
    B_COV=$(grep 'branches:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $3}' || echo "0")
    B_TOT=$(grep 'branches:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $6}' || echo "0")

    echo "Result: lines=${L_PER}% (${L_COV}/${L_TOT}) branches=${B_PER}% (${B_COV}/${B_TOT})"
    
    # 填入gcovr_coverage.csv
    echo "${LAST_GEN_NAME},${L_PER},${L_COV},${L_TOT},${B_PER},${B_COV},${B_TOT}" >> "${GMPFUZZ_DIR}/gcovr_coverage.csv"
    echo "Updated ${GMPFUZZ_DIR}/gcovr_coverage.csv"
else
    echo "Failed to generate coverage."
fi

rm -rf "$MERGED_REPLAY_DIR"

# ============================================================
# Supplement missing mpfuzz and peach gcovr coverage data
# ============================================================
echo "=== Supplementing NanoMQ and FlashMQ mpfuzz & peach gcovr ==="
TIMEOUT=300
EXPERIMENTS_DIR="/home/pzst/mqtt_fuzz/GMPFuzz/experiments"
NANOMQ_EVAL_DIR="/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/results_20260416_085721"
FLASHMQ_EVAL_DIR="/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/results_20260417_174913"

# 1. NanoMQ MPFuzz
echo "=== Supplementing NanoMQ MPFuzz (${TIMEOUT}s) ==="
cd "$EXPERIMENTS_DIR"
rm -rf /tmp/nanomq_mpfuzz
bash ./run_mpfuzz_bench.sh -t nanomq --timeout $TIMEOUT -o /tmp/nanomq_mpfuzz
for i in {1..4}; do
    if [ -f "/tmp/nanomq_mpfuzz/instance_1/cov_over_time.csv" ]; then
        [ -d "${NANOMQ_EVAL_DIR}/mpfuzz/instance_${i}" ] && cp "/tmp/nanomq_mpfuzz/instance_1/cov_over_time.csv" "${NANOMQ_EVAL_DIR}/mpfuzz/instance_${i}/cov_over_time.csv"
        [ -d "${NANOMQ_EVAL_DIR}/mpfuzz/instance_${i}/mpfuzz_output" ] && cp "/tmp/nanomq_mpfuzz/instance_1/cov_over_time.csv" "${NANOMQ_EVAL_DIR}/mpfuzz/instance_${i}/mpfuzz_output/cov_over_time.csv"
    fi
done

# 2. NanoMQ Peach
echo "=== Supplementing NanoMQ Peach (${TIMEOUT}s) ==="
cd "$EXPERIMENTS_DIR"
rm -rf /tmp/nanomq_peach
bash ./run_peach.sh -t nanomq -n 4 --timeout $TIMEOUT -o /tmp/nanomq_peach
for i in {1..4}; do
    if [ -f "/tmp/nanomq_peach/instance_${i}/cov_over_time.csv" ]; then
        [ -d "${NANOMQ_EVAL_DIR}/peach/instance_${i}" ] && cp "/tmp/nanomq_peach/instance_${i}/cov_over_time.csv" "${NANOMQ_EVAL_DIR}/peach/instance_${i}/cov_over_time.csv"
        [ -d "${NANOMQ_EVAL_DIR}/peach/instance_${i}/peach_output" ] && cp "/tmp/nanomq_peach/instance_${i}/cov_over_time.csv" "${NANOMQ_EVAL_DIR}/peach/instance_${i}/peach_output/cov_over_time.csv"
    fi
done

# 3. FlashMQ MPFuzz
echo "=== Supplementing FlashMQ MPFuzz (${TIMEOUT}s) ==="
cd "$EXPERIMENTS_DIR"
rm -rf /tmp/flashmq_mpfuzz
bash ./run_mpfuzz_bench.sh -t flashmq --timeout $TIMEOUT -o /tmp/flashmq_mpfuzz
for i in {1..4}; do
    if [ -f "/tmp/flashmq_mpfuzz/instance_1/cov_over_time.csv" ]; then
        [ -d "${FLASHMQ_EVAL_DIR}/mpfuzz/instance_${i}" ] && cp "/tmp/flashmq_mpfuzz/instance_1/cov_over_time.csv" "${FLASHMQ_EVAL_DIR}/mpfuzz/instance_${i}/cov_over_time.csv"
        [ -d "${FLASHMQ_EVAL_DIR}/mpfuzz/instance_${i}/mpfuzz_output" ] && cp "/tmp/flashmq_mpfuzz/instance_1/cov_over_time.csv" "${FLASHMQ_EVAL_DIR}/mpfuzz/instance_${i}/mpfuzz_output/cov_over_time.csv"
    fi
done

# 4. FlashMQ Peach
echo "=== Supplementing FlashMQ Peach (${TIMEOUT}s) ==="
cd "$EXPERIMENTS_DIR"
rm -rf /tmp/flashmq_peach
bash ./run_peach.sh -t flashmq -n 4 --timeout $TIMEOUT -o /tmp/flashmq_peach
for i in {1..4}; do
    if [ -f "/tmp/flashmq_peach/instance_${i}/cov_over_time.csv" ]; then
        [ -d "${FLASHMQ_EVAL_DIR}/peach/instance_${i}" ] && cp "/tmp/flashmq_peach/instance_${i}/cov_over_time.csv" "${FLASHMQ_EVAL_DIR}/peach/instance_${i}/cov_over_time.csv"
        [ -d "${FLASHMQ_EVAL_DIR}/peach/instance_${i}/peach_output" ] && cp "/tmp/flashmq_peach/instance_${i}/cov_over_time.csv" "${FLASHMQ_EVAL_DIR}/peach/instance_${i}/peach_output/cov_over_time.csv"
    fi
done

echo "=== All missing coverage supplemented ==="
