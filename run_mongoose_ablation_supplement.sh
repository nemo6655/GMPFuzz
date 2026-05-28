#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET="mongoose"
MODES=("full" "no-pasd" "no-llm" "no-ase")

NUM_GENS=20
START_TIME=$(date '+%Y%m%d_%H%M%S')
BASE_RESULT_DIR="evaluation/mongoose_ablation_supplement_${START_TIME}"
mkdir -p "$BASE_RESULT_DIR"

echo "=========================================================="
echo " Starting Mongoose Ablation Supplement Study with GCOVR"
echo " Target: ${TARGET}"
echo " Modes: ${MODES[*]}"
echo " Generations Limit: ${NUM_GENS}"
echo " Results will be aggregated in: ${BASE_RESULT_DIR}"
echo "=========================================================="

for MODE in "${MODES[@]}"; do
    SESSION_ID="mongoose_ablation_${MODE}_${START_TIME}"
    EVAL_DIR="evaluation/gmpfuzz_${TARGET}_${SESSION_ID}"
    LOG="${BASE_RESULT_DIR}/${SESSION_ID}.log"
    
    echo "----------------------------------------------------------"
    echo "[*] Mode: ${MODE} | Starting at $(date '+%H:%M:%S')"
    echo "    Logging to: ${LOG}"
    
    set +e
    bash ./gmpfuzz_exec.sh -t "$TARGET" -a "$MODE" -n "$NUM_GENS" "$SESSION_ID" > "$LOG" 2>&1
    GUMPFUZZ_EXIT_CODE=$?
    set -e

    if [ "$GUMPFUZZ_EXIT_CODE" -ne 0 ]; then
        echo "[!] Mode: ${MODE} failed with exit code ${GUMPFUZZ_EXIT_CODE}. See ${LOG} for details."
        echo "[!] Mode: ${MODE} failed with exit code ${GUMPFUZZ_EXIT_CODE}." >> "${BASE_RESULT_DIR}/supplement_errors.log"
    else
        echo "[✓] Mode: ${MODE} completed at $(date '+%H:%M:%S')."
    fi
    
    # After generation loop completes for this variant, compute Gcovr coverage
    echo "[*] Mode: ${MODE} | Running Gcovr evaluation"
    
    # We will pick the last generation
    LAST_GEN=$(ls -d ${EVAL_DIR}/gen*/ 2>/dev/null | sort -V | tail -n 1)
    if [ -z "$LAST_GEN" ] || [ ! -d "${LAST_GEN}/aflnetout" ]; then
        echo "No aflnetout found for $MODE. Skipping gcovr."
        continue
    fi
    
    LAST_GEN_NAME=$(basename "$LAST_GEN")
    MERGED_REPLAY_DIR=$(mktemp -d /tmp/gmpfuzz_mongoose_merged_XXXXXX)
    TARBALL_COUNT=0
    
    for tarball in "${LAST_GEN}/aflnetout"/aflnetout_*.tar.gz; do
        [ -f "$tarball" ] || continue
        base=$(basename "$tarball" .tar.gz)
        TARBALL_TMP=$(mktemp -d)
        tar -xzf "$tarball" -C "$TARBALL_TMP" 2>/dev/null || true
        
        find "$TARBALL_TMP" -path '*/replayable-queue/*' -type f -exec cp {} "$MERGED_REPLAY_DIR/" \; 2>/dev/null || true
        MERGED_FILE_COUNT=$(ls -A "$MERGED_REPLAY_DIR" 2>/dev/null | wc -l)
        if [ "$MERGED_FILE_COUNT" -eq 0 ]; then
            find "$TARBALL_TMP" -path '*/queue/id:*' -type f -exec cp {} "$MERGED_REPLAY_DIR/" \; 2>/dev/null || true
        fi
        rm -rf "$TARBALL_TMP"
        TARBALL_COUNT=$((TARBALL_COUNT+1))
    done
    
    MERGED_FILE_COUNT=$(ls -A "$MERGED_REPLAY_DIR" 2>/dev/null | wc -l)
    echo "Merged files: $MERGED_FILE_COUNT"
    
    if [ "$MERGED_FILE_COUNT" -gt 0 ]; then
        cat << 'INNER_EOF' > "${MERGED_REPLAY_DIR}/ultra_replay_mongoose.sh"
#!/bin/bash
cd /home/ubuntu/experiments/mongoose-gcov

# Reset counters
gcovr -r /home/ubuntu/experiments/mongoose-src --object-directory /home/ubuntu/experiments/mongoose-gcov -s -d > /dev/null 2>&1 || true

for f in /mnt/inputs/*; do
     [ -f "$f" ] || continue
     
     pkill -f "./mongoose_mqtt_broker" 2>/dev/null || true
     sleep 0.1
     
     ./mongoose_mqtt_broker mqtt://0.0.0.0:1883 > /dev/null 2>&1 &
     SERVER_PID=$!
     sleep 0.1
     
     aflnet-replay "$f" MQTT 1883 1 > /dev/null 2>&1 || true
     
     kill -TERM $SERVER_PID 2>/dev/null || true
     wait $SERVER_PID 2>/dev/null || true
done

echo "===GCOV==="
gcovr -r /home/ubuntu/experiments/mongoose-src --object-directory /home/ubuntu/experiments/mongoose-gcov -s || true
INNER_EOF
        
        chmod +x "${MERGED_REPLAY_DIR}/ultra_replay_mongoose.sh"
        COV_OUTPUT="${EVAL_DIR}/gcovr_output.txt"
        
        docker run --rm --cpus=1 \
            -v "${MERGED_REPLAY_DIR}:/mnt/inputs:ro" \
            gmpfuzz/mongoose \
            /bin/bash -c "/mnt/inputs/ultra_replay_mongoose.sh" > "$COV_OUTPUT" 2>&1 || true
            
        if [ -f "$COV_OUTPUT" ]; then
            L_PER=$(grep 'lines:' "$COV_OUTPUT" | awk '{print $2}' | tr -d '%' || echo "0")
            L_COV=$(grep 'lines:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $3}' || echo "0")
            L_TOT=$(grep 'lines:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $6}' || echo "0")
            
            B_PER=$(grep 'branches:' "$COV_OUTPUT" | awk '{print $2}' | tr -d '%' || echo "0")
            B_COV=$(grep 'branches:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $3}' || echo "0")
            B_TOT=$(grep 'branches:' "$COV_OUTPUT" | awk -F'[)( ]+' '{print $6}' || echo "0")
            
            echo "generation,line_percent,line_covered,line_total,branch_percent,branch_covered,branch_total" > "${EVAL_DIR}/gcovr_coverage.csv"
            echo "${LAST_GEN_NAME},${L_PER},${L_COV},${L_TOT},${B_PER},${B_COV},${B_TOT}" >> "${EVAL_DIR}/gcovr_coverage.csv"
            echo "Branch coverage extracted: ${B_COV}"
        fi
    fi
    
    rm -rf "$MERGED_REPLAY_DIR"
    
    # Store evaluated folder properly in the base result dir
    cp -r "$EVAL_DIR" "$BASE_RESULT_DIR/"
done

echo "=========================================================="
echo " All Mongoose ablation supplementary experiments finished."
echo " Replotting mongoose ablation data"
RESULT_DIRS=($BASE_RESULT_DIR/gmpfuzz_${TARGET}_*)
python3 ./experiments/plot_ablation.py "$TARGET" "${RESULT_DIRS[@]}"

mv "ablation_edge_${TARGET}.pdf"    "$BASE_RESULT_DIR/" 2>/dev/null || true
mv "ablation_summary_${TARGET}.csv" "$BASE_RESULT_DIR/" 2>/dev/null || true
mv "ablation_gcovr_${TARGET}.pdf"   "$BASE_RESULT_DIR/" 2>/dev/null || true

echo " Outputs saved to: ${BASE_RESULT_DIR}"
echo "=========================================================="
