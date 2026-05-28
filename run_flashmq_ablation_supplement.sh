#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET="flashmq"
MODES=("full" "no-pasd" "no-llm" "no-ase")

# NUM_GENS 只是一个保险，主要是靠6小时的budget来停止。
# 比如6小时平均能跑6-10代左右，我们给个稍微大一点的数字限制，主要是让它自己因为budget停止
NUM_GENS=20 
START_TIME=$(date '+%Y%m%d_%H%M%S')
BASE_RESULT_DIR="evaluation/flashmq_ablation_supplement_${START_TIME}"
mkdir -p "$BASE_RESULT_DIR"

echo "=========================================================="
echo " Starting FlashMQ Ablation Supplement Study"
echo " Target: ${TARGET}"
echo " Modes: ${MODES[*]}"
echo " Generations Limit: ${NUM_GENS}"
echo " Results will be aggregated in: ${BASE_RESULT_DIR}"
echo "=========================================================="

for MODE in "${MODES[@]}"; do
    SESSION_ID="flashmq_ablation_${MODE}_${START_TIME}"
    LOG="${BASE_RESULT_DIR}/${SESSION_ID}.log"
    
    echo "----------------------------------------------------------"
    echo "[*] Mode: ${MODE} | Starting at $(date '+%H:%M:%S')"
    echo "    Logging to: ${LOG}"
    
    bash ./gmpfuzz_exec.sh -t "$TARGET" -a "$MODE" -n "$NUM_GENS" "$SESSION_ID" > "$LOG" 2>&1
    
    echo "[✓] Mode: ${MODE} completed at $(date '+%H:%M:%S')."
done

echo "=========================================================="
echo " All FlashMQ ablation supplementary experiments finished."
echo " Outputs saved to: ${BASE_RESULT_DIR}"
echo "=========================================================="
