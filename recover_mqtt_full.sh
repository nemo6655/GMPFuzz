#!/bin/bash
set -e
export TARGET="mqtt"
export TEST_NUMBER="ablation_20260420_101938_full"
export ABLATION_MODE="full"
export NUM_GENS=2
export CURRENT_DATE=$(date +%Y%m%d_%H%M%S)
export ARCHIVE_NAME="gmpfuzz_${TARGET}_${TEST_NUMBER}_${CURRENT_DATE}.tar.xz"

export RUNDIR="preset/${TARGET}"
export EVAL_DIR="evaluation/gmpfuzz_mqtt_${TEST_NUMBER}"
export LOG_FILE="${EVAL_DIR}/recovery_${CURRENT_DATE}.log"

# Extract post-processing logic exactly from line 263 to end of gmpfuzz_exec.sh
tail -n +263 gmpfuzz_exec.sh > _tmp_post.sh
chmod +x _tmp_post.sh
./_tmp_post.sh 2>&1 | tee "${LOG_FILE}"
rm _tmp_post.sh

# Copy to base dir
BASE_RESULT_DIR="evaluation/ablation_results_20260420_101938"
mkdir -p "$BASE_RESULT_DIR"
cp -r "$EVAL_DIR" "$BASE_RESULT_DIR/"

echo "✅ MQTT 'full' mode recovery and packaging completed successfully!"
