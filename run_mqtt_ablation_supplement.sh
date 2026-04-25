#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET="mqtt"
MODES=("no-llm")
NUM_GENS=2

# 使用新的时间戳来保存本次补跑的结果
START_TIME=$(date '+%Y%m%d_%H%M%S')
BASE_RESULT_DIR="evaluation/ablation_results_mqtt_supplement_${START_TIME}"
mkdir -p "$BASE_RESULT_DIR"

LOG="${BASE_RESULT_DIR}/${TARGET}_supplement.log"

echo "=========================================================="
echo " Starting Supplemental Ablation Study for [ ${TARGET} ]"
echo " Modes: ${MODES[*]}"
echo " Generations Limit: ${NUM_GENS}"
echo " Results will be aggregated in: ${BASE_RESULT_DIR}"
echo "=========================================================="

RESULT_DIRS_FOR_TARGET=()

for MODE in "${MODES[@]}"; do
    echo "[${TARGET}] Mode: ${MODE} | Starting (logging to ${LOG})"
    
    SESSION_ID="ablation_supplement_${START_TIME}_${MODE}"
    EVAL_DIR="evaluation/gmpfuzz_${TARGET}_${SESSION_ID}"

    # 运行对应的消融实验
    bash ./gmpfuzz_exec.sh -t "$TARGET" -a "$MODE" -n "$NUM_GENS" "${SESSION_ID}" >> "$LOG" 2>&1
    
    echo "[${TARGET}] ✓ Finished Mode: ${MODE}"
    sleep 2

    RESULT_DIRS_FOR_TARGET+=("$EVAL_DIR")

    # 复制结果到归档目录
    if [ -d "$EVAL_DIR" ]; then
        cp -r "$EVAL_DIR" "$BASE_RESULT_DIR/"
    fi
done

echo "[${TARGET}] Plotting and aggregating data..."
python3 ./experiments/plot_ablation.py "$TARGET" "${RESULT_DIRS_FOR_TARGET[@]}" >> "$LOG" 2>&1 || true

# 转移生成的图片和数据表到统一目录
mv "ablation_edge_${TARGET}.pdf"    "$BASE_RESULT_DIR/" 2>/dev/null || true
mv "ablation_summary_${TARGET}.csv" "$BASE_RESULT_DIR/" 2>/dev/null || true
mv "ablation_gcovr_${TARGET}.pdf"   "$BASE_RESULT_DIR/" 2>/dev/null || true

echo "=========================================================="
echo " [${TARGET}] Supplemental ablation completed!"
echo " Results and plots are located in: ${BASE_RESULT_DIR}"
echo "=========================================================="
