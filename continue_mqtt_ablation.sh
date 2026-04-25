#!/bin/bash
TARGET="mqtt"
START_TIME="20260420_101938"
NUM_GENS=2
BASE_RESULT_DIR="evaluation/ablation_results_${START_TIME}"
LOG="${BASE_RESULT_DIR}/${TARGET}_ablation_resume.log"

echo "[${TARGET}] Resuming ablation (logging to ${LOG})"
echo "Note: 'full' mode was completed via recovery. Resuming with the rest..."

MODES=("baseline" "no-pasd" "no-mqtt" "no-ase" "no-llm" "no-pasd-ase")
RESULT_DIRS_FOR_TARGET=("evaluation/gmpfuzz_mqtt_ablation_${START_TIME}_full")

for MODE in "${MODES[@]}"; do
    echo "[${TARGET}] Mode: ${MODE} | Starting"
    SESSION_ID="ablation_${START_TIME}_${MODE}"
    EVAL_DIR="evaluation/gmpfuzz_${TARGET}_${SESSION_ID}"
    
    bash ./gmpfuzz_exec.sh -t "$TARGET" -a "$MODE" -n "$NUM_GENS" "${SESSION_ID}" >> "$LOG" 2>&1
    echo "[${TARGET}] ✓ Finished Mode: ${MODE}"
    sleep 2

    RESULT_DIRS_FOR_TARGET+=("$EVAL_DIR")
    if [ -d "$EVAL_DIR" ]; then
        cp -r "$EVAL_DIR" "$BASE_RESULT_DIR/"
    fi
done

echo "[${TARGET}] Plotting and aggregating data..."
python3 ./experiments/plot_ablation.py "$TARGET" "${RESULT_DIRS_FOR_TARGET[@]}" >> "$LOG" 2>&1 || true

mv "ablation_edge_${TARGET}.pdf"    "$BASE_RESULT_DIR/" 2>/dev/null || true
mv "ablation_summary_${TARGET}.csv" "$BASE_RESULT_DIR/" 2>/dev/null || true
mv "ablation_gcovr_${TARGET}.pdf"   "$BASE_RESULT_DIR/" 2>/dev/null || true

echo "[${TARGET}] All resumed ablation modes completed!"
