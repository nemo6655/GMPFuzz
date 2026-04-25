#!/bin/bash
set -eo pipefail

EVAL_BASE="/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/ablation_results_20260422_170850"

cd /home/pzst/mqtt_fuzz/GMPFuzz

echo "=== Recovering missing gcovr data for flashmq ablation ==="

# We iterate over all flashmq ablation directories in that test suite
for GMPFUZZ_DIR in $EVAL_BASE/gmpfuzz_flashmq_ablation_*; do
    [ -d "$GMPFUZZ_DIR" ] || continue
    
    MODE_NAME=$(basename "$GMPFUZZ_DIR")
    echo "Processing $MODE_NAME..."
    
    # Check if we already have gen1/aflnetout
    if [ ! -d "${GMPFUZZ_DIR}/gen1/aflnetout" ]; then
        echo "No gen1/aflnetout found. Skipping."
        continue
    fi
    
    LAST_GEN_NAME="gen1"
    
    MERGED_REPLAY_DIR=$(mktemp -d /tmp/gmpfuzz_gcovr_merged_XXXXXX)

    TARBALL_COUNT=0
    for tarball in "${GMPFUZZ_DIR}/${LAST_GEN_NAME}/aflnetout"/aflnetout_*.tar.gz; do
        [ -f "$tarball" ] || continue
        base=$(basename "$tarball" .tar.gz)
        TARBALL_TMP=$(mktemp -d)
        tar -xzf "$tarball" -C "$TARBALL_TMP" 2>/dev/null || true
        
        # 寻找replayable队列
        find "$TARBALL_TMP" -path '*/replayable-queue/*' -type f -exec cp {} "$MERGED_REPLAY_DIR/" \; 2>/dev/null || true
        # 如果没有replayable-queue，寻找普通的queue
        MERGED_FILE_COUNT=$(ls -A "$MERGED_REPLAY_DIR" 2>/dev/null | wc -l)
        if [ "$MERGED_FILE_COUNT" -eq 0 ]; then
            find "$TARBALL_TMP" -path '*/queue/id:*' -type f -exec cp {} "$MERGED_REPLAY_DIR/" \; 2>/dev/null || true
        fi
        
        rm -rf "$TARBALL_TMP"
        TARBALL_COUNT=$((TARBALL_COUNT+1))
    done
    
    MERGED_FILE_COUNT=$(ls -A "$MERGED_REPLAY_DIR" 2>/dev/null | wc -l)
    echo "Merged replayable files: $MERGED_FILE_COUNT from $TARBALL_COUNT tarballs"
    
    if [ "$MERGED_FILE_COUNT" -eq 0 ]; then
        echo "No replayable files found for $MODE_NAME."
        rm -rf "$MERGED_REPLAY_DIR"
        continue
    fi

cat << 'INNER_EOF' > "${MERGED_REPLAY_DIR}/ultra_replay.sh"
#!/bin/bash
cd /home/ubuntu/experiments/flashmq-src/build-gcov

# Reset counters
gcovr -r /home/ubuntu/experiments/flashmq-src --object-directory /home/ubuntu/experiments/flashmq-src/build-gcov -s -d > /dev/null 2>&1 || true

for f in /mnt/inputs/*; do
     [ -f "$f" ] || continue
     
     # terminate any running server
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
gcovr -r /home/ubuntu/experiments/flashmq-src --object-directory /home/ubuntu/experiments/flashmq-src/build-gcov -s || true
INNER_EOF

    chmod +x "${MERGED_REPLAY_DIR}/ultra_replay.sh"
    
    COV_OUTPUT="${GMPFUZZ_DIR}/ultra_cov_output.txt"
    echo "Running Docker to compute coverage (takes a few minutes)..."
    docker run --rm --cpus=1 \
        -v "${MERGED_REPLAY_DIR}:/mnt/inputs:ro" \
        gmpfuzz/flashmq \
        /bin/bash -c "/mnt/inputs/ultra_replay.sh" > "$COV_OUTPUT" 2>&1 || true
        
    if [ -f "$COV_OUTPUT" ]; then
        L_PER=$(grep 'lines:' "$COV_OUTPUT" | awk '{print $2}' | tr -d '%' || echo "0")
        L_COV=$(grep 'lines:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $3}' || echo "0")
        L_TOT=$(grep 'lines:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $6}' || echo "0")
        
        B_PER=$(grep 'branches:' "$COV_OUTPUT" | awk '{print $2}' | tr -d '%' || echo "0")
        B_COV=$(grep 'branches:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $3}' || echo "0")
        B_TOT=$(grep 'branches:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $6}' || echo "0")

        echo "Result: lines=${L_PER}% (${L_COV}/${L_TOT}) branches=${B_PER}% (${B_COV}/${B_TOT})"
        
        # 覆盖重新写入 gcovr_coverage.csv
        echo "generation,line_percent,line_covered,line_total,branch_percent,branch_covered,branch_total" > "${GMPFUZZ_DIR}/gcovr_coverage.csv"
        echo "${LAST_GEN_NAME},${L_PER},${L_COV},${L_TOT},${B_PER},${B_COV},${B_TOT}" >> "${GMPFUZZ_DIR}/gcovr_coverage.csv"
        echo "Updated ${GMPFUZZ_DIR}/gcovr_coverage.csv"
    else
        echo "Failed to generate coverage."
    fi
    
    rm -rf "$MERGED_REPLAY_DIR"
done

echo "=== All coverage data recovered! Now replotting flashmq ablation ==="
cd /home/pzst/mqtt_fuzz/GMPFuzz
RESULT_DIRS=($EVAL_BASE/gmpfuzz_flashmq_ablation_*)
python3 ./experiments/plot_ablation.py "flashmq" "${RESULT_DIRS[@]}"

mv "ablation_edge_flashmq.pdf"    "$EVAL_BASE/" 2>/dev/null || true
mv "ablation_summary_flashmq.csv" "$EVAL_BASE/" 2>/dev/null || true
mv "ablation_gcovr_flashmq.pdf"   "$EVAL_BASE/" 2>/dev/null || true

echo "Done! The plots and summary csv in $EVAL_BASE have been updated."