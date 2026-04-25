#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 测试目标（mqtt, nanomq, flashmq 三个目标并行执行）
TARGETS=("mqtt" "nanomq" "flashmq")
# 所有的消融实验模式
MODES=("full" "no-pasd" "no-ase" "no-llm")
NUM_GENS=2

START_TIME=$(date '+%Y%m%d_%H%M%S')
BASE_RESULT_DIR="evaluation/ablation_results_${START_TIME}"
mkdir -p "$BASE_RESULT_DIR"

echo "=========================================================="
echo " Starting Global Ablation Study (Parallel Targets)"
echo " Targets: ${TARGETS[*]}"
echo " Modes: ${MODES[*]}"
echo " Generations Limit: ${NUM_GENS}"
echo " Execution: 3 targets staggered parallel (50min apart), modes serial per target"
echo " Results will be aggregated in: ${BASE_RESULT_DIR}"
echo "=========================================================="

# ----------------------------------------------------------------
# run_target_ablation: run all ablation modes for a single target
#   Runs serially within each target so Docker/GPU resources
#   per-mode don't conflict.  Three targets run in parallel.
# ----------------------------------------------------------------
run_target_ablation() {
    local TARGET=$1
    local LOG="${BASE_RESULT_DIR}/${TARGET}_ablation.log"
    local RESULT_DIRS_FOR_TARGET=()

    echo "[${TARGET}] Starting ablation (logging to ${LOG})"

    for MODE in "${MODES[@]}"; do
        echo "[${TARGET}] Mode: ${MODE} | Starting"

        SESSION_ID="ablation_${START_TIME}_${MODE}"
        EVAL_DIR="evaluation/gmpfuzz_${TARGET}_${SESSION_ID}"

        # 运行 GMPFuzz 实验 (每个仅限 NUM_GENS gens)
        bash ./gmpfuzz_exec.sh -t "$TARGET" -a "$MODE" -n "$NUM_GENS" "${SESSION_ID}" \
            >> "$LOG" 2>&1

        echo "[${TARGET}] ✓ Finished Mode: ${MODE}"
        sleep 2

        RESULT_DIRS_FOR_TARGET+=("$EVAL_DIR")

        # 把文件夹复制到统一的归档目录中
        if [ -d "$EVAL_DIR" ]; then
            cp -r "$EVAL_DIR" "$BASE_RESULT_DIR/"
        fi
    done

    # 绘制当前 Target 下所有模式的对比图和数据表
    echo "[${TARGET}] Plotting and aggregating data..."
    python3 ./experiments/plot_ablation.py "$TARGET" "${RESULT_DIRS_FOR_TARGET[@]}" \
        >> "$LOG" 2>&1 || true

    # 移动生成的表格和图片到归档目录
    mv "ablation_edge_${TARGET}.pdf"    "$BASE_RESULT_DIR/" 2>/dev/null || true
    mv "ablation_summary_${TARGET}.csv" "$BASE_RESULT_DIR/" 2>/dev/null || true
    mv "ablation_gcovr_${TARGET}.pdf"   "$BASE_RESULT_DIR/" 2>/dev/null || true

    echo "=========================================================="
    echo " [${TARGET}] All ablation modes completed"
    echo "=========================================================="
}

# ----------------------------------------------------------------
# Launch all targets in parallel, staggered to avoid LLM contention
#
# Each generation has two phases:
#   LLM phase  (~40-60 min): genvariants + genoutputs (uses LLM endpoint)
#   Fuzz phase (~30-40 min): getcov in Docker containers (no LLM)
#
# By staggering target launches by ~50 minutes, each target's LLM phase
# overlaps with other targets' fuzz phases, effectively serialising LLM
# access while keeping fuzzing parallel.
# ----------------------------------------------------------------
LLM_STAGGER_SECS=$((50 * 60))   # 50 minutes between launches

TARGET_PIDS=()
for i in "${!TARGETS[@]}"; do
    TARGET="${TARGETS[$i]}"
    if [ "$i" -gt 0 ]; then
        echo "[main] Waiting ${LLM_STAGGER_SECS}s ($(( LLM_STAGGER_SECS / 60 ))min) before launching ${TARGET} to stagger LLM usage..."
        sleep "$LLM_STAGGER_SECS"
    fi
    run_target_ablation "$TARGET" &
    TARGET_PIDS+=($!)
    echo "[main] Launched ${TARGET} ablation (PID $!) at $(date '+%H:%M:%S')"
done

echo "[main] Waiting for all ${#TARGETS[@]} targets to finish..."
echo "  PIDs: ${TARGET_PIDS[*]}"

# Wait for all and collect exit codes
FAILED=0
for i in "${!TARGETS[@]}"; do
    if wait "${TARGET_PIDS[$i]}"; then
        echo "[main] ✓ ${TARGETS[$i]} completed successfully"
    else
        echo "[main] ✗ ${TARGETS[$i]} failed (exit $?)"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "🎉 All ablation experiments finished successfully."
else
    echo "⚠️  ${FAILED}/${#TARGETS[@]} targets had failures. Check logs in ${BASE_RESULT_DIR}/"
fi
echo "📈 Extracted CSV tables and PDF plots can be found in: ${BASE_RESULT_DIR}"
