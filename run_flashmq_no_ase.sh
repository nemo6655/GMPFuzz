#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TARGET="flashmq"
MODE="no-ase"
NUM_GENS=3 
START_TIME="20260519_180731"
BASE_RESULT_DIR="evaluation/flashmq_ablation_supplement_${START_TIME}"
mkdir -p "$BASE_RESULT_DIR"

SESSION_ID="flashmq_ablation_${MODE}_${START_TIME}"
LOG="${BASE_RESULT_DIR}/${SESSION_ID}.log"

echo "----------------------------------------------------------"
echo "[*] Mode: ${MODE} | Starting at $(date '+%H:%M:%S')"
echo "    Logging to: ${LOG}"

bash ./gmpfuzz_exec.sh -t "$TARGET" -a "$MODE" -n "$NUM_GENS" "$SESSION_ID" > "$LOG" 2>&1

echo "[✓] Mode: ${MODE} completed at $(date '+%H:%M:%S')."
