#!/bin/bash
# ============================================================
# run_gmpfuzz_bench.sh - Run GMPFuzz for benchmark comparison
#
# Wraps gmpfuzz_exec.sh for the benchmark experiment.
# Runs full-mode GMPFuzz with dynamic generations (ASE-driven).
# GMPFuzz internally runs 4 parallel fuzzer instances (4 state
# pools x jobs=4 Docker containers), so only ONE run is needed.
#
# Usage: ./run_gmpfuzz_bench.sh [options]
#   -t, --target TARGET    Fuzzing target: mqtt, mongoose, nanomq (default: mqtt)
#   -o, --output DIR       Base directory for results
#   -h, --help             Show this help
#
# Legacy positional usage (backward compatible):
#   ./run_gmpfuzz_bench.sh <output_dir>
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GMPFUZZ_DIR="$(dirname "$SCRIPT_DIR")"

# =====================================================================
# Defaults
# =====================================================================
TARGET="mqtt"
OUTPUT_DIR=""

# =====================================================================
# Parse arguments
# =====================================================================
show_help() {
    sed -n '2,16p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)   TARGET="$2"; shift 2 ;;
        -o|--output)   OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)     show_help ;;
        *)
            # Legacy positional: <output_dir>
            if [ -z "${_LP1:-}" ]; then _LP1=1; OUTPUT_DIR="$1"; shift
            else echo "Unknown option: $1"; show_help; fi
            ;;
    esac
done

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(dirname "$SCRIPT_DIR")/evaluation/gmpfuzz"
fi

# Convert to absolute path (script will cd to GMPFUZZ_DIR later)
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUTPUT_DIR")"
mkdir -p "$OUTPUT_DIR"

# Target description
case "$TARGET" in
    mqtt)      TARGET_DESC="Mosquitto v1.5.5" ;;
    mongoose)  TARGET_DESC="Mongoose v7.20" ;;
    nanomq)    TARGET_DESC="NanoMQ v0.21.10" ;;
    *)
        echo "ERROR: Unknown target '${TARGET}'. Supported: mqtt, mongoose, nanomq"
        exit 1
        ;;
esac

echo "========================================================"
echo "  GMPFuzz Benchmark - ${TARGET_DESC}"
echo "========================================================"
echo "  Target:     ${TARGET} (${TARGET_DESC})"
echo "  Parallelism: 4 state pools × jobs=4 (internal)"
echo "  Mode:       full (PASD + ASE + LLM)"
echo "  Generations: dynamic (ASE budget-driven, max 20)"
echo "  GMPFuzz Dir: ${GMPFUZZ_DIR}"
echo "  Output:     ${OUTPUT_DIR}"
echo "  Start:      $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"

START_TIME=$(date +%s)

INSTANCE_DIR="${OUTPUT_DIR}/instance_1"
mkdir -p "$INSTANCE_DIR"
LOG_FILE="${INSTANCE_DIR}/gmpfuzz_run.log"

echo "[$(date '+%H:%M:%S')] Starting GMPFuzz -t ${TARGET} (4 internal parallel fuzzers)..."

cd "$GMPFUZZ_DIR"
TEST_NUM=101

# Run GMPFuzz - a single run already has 4 parallel state pools
if bash gmpfuzz_exec.sh -t "$TARGET" -a full "$TEST_NUM" > "$LOG_FILE" 2>&1; then
    echo "[$(date '+%H:%M:%S')] GMPFuzz completed successfully"
    FAIL=0
else
    EXIT_CODE=$?
    echo "[$(date '+%H:%M:%S')] GMPFuzz failed (exit=$EXIT_CODE)"
    FAIL=1
fi

# Copy evaluation results to instance dir
EVAL_SRC="${GMPFUZZ_DIR}/evaluation/gmpfuzz_${TARGET}_${TEST_NUM}"
if [ -d "$EVAL_SRC" ]; then
    cp -r "$EVAL_SRC"/* "$INSTANCE_DIR/" 2>/dev/null || true
    echo "  Results copied to ${INSTANCE_DIR}"
fi

# Also copy cov_over_time CSV to standard location
COV_CSV=$(find "$EVAL_SRC" -name "cov_over_time*.csv" 2>/dev/null | head -1)
if [ -n "$COV_CSV" ]; then
    cp "$COV_CSV" "${INSTANCE_DIR}/cov_over_time.csv" 2>/dev/null || true
fi

TOTAL_TIME=$(( $(date +%s) - START_TIME ))
echo ""
echo "========================================================"
echo "  GMPFuzz Benchmark Complete - ${TARGET_DESC}"
echo "========================================================"
echo "  Target:       ${TARGET}"
echo "  Parallelism:  4 state pools (internal)"
echo "  Failed:       ${FAIL}"
echo "  Total Time:   ${TOTAL_TIME}s ($(echo "scale=1; $TOTAL_TIME/3600" | bc)h)"
echo "  Output:       ${OUTPUT_DIR}"
echo "  End:          $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
