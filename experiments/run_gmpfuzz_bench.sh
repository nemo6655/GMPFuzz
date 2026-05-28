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
    mosquitto) TARGET_DESC="Mosquitto Latest" ;;
    mongoose)  TARGET_DESC="Mongoose v7.20" ;;
    nanomq)    TARGET_DESC="NanoMQ v0.21.10" ;;
    flashmq)   TARGET_DESC="FlashMQ" ;;
    *)
        echo "ERROR: Unknown target '${TARGET}'. Supported: mqtt, mosquitto, mongoose, nanomq, flashmq"
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
else
    # Auto-recover coverage for the target
    echo "[$(date '+%H:%M:%S')] Auto-recovering coverage for GMPFuzz (${TARGET})..."
    
    TARGET_DOCKER="gmpfuzz/${TARGET}"
    case "$TARGET" in
        mqtt)
            GCOV_DIR="/home/ubuntu/experiments/mosquitto-gcov"
            GCOV_SRC="/home/ubuntu/experiments/mosquitto-gcov/src"
            GCOVR_CLEAR_CMD="gcovr -r .. -s -d"
            TARGET_CMD="timeout -k 0 -s SIGTERM 3s ./mosquitto -c /home/ubuntu/experiments/mosquitto.conf"
            GCOVR_CMD="gcovr -r .. -s"
            ;;
        mosquitto)
            GCOV_DIR="/home/ubuntu/experiments/mosquitto-gcov"
            GCOV_SRC="/home/ubuntu/experiments/mosquitto-gcov/src"
            GCOVR_CLEAR_CMD="gcovr -r . -s -d"
            TARGET_CMD="timeout -k 0 -s SIGTERM 3s ./mosquitto -c /home/ubuntu/experiments/mosquitto.conf"
            GCOVR_CMD="gcovr -r . -s"
            ;;
        mongoose)
            GCOV_DIR="/home/ubuntu/experiments/mongoose-gcov"
            GCOV_SRC="/home/ubuntu/experiments/mongoose-gcov"
            GCOVR_CLEAR_CMD="gcovr -r /home/ubuntu/experiments/mongoose-src --object-directory /home/ubuntu/experiments/mongoose-gcov -s -d"
            TARGET_CMD="timeout -k 0 -s SIGTERM 3s ./mongoose_mqtt_broker"
            GCOVR_CMD="gcovr -r /home/ubuntu/experiments/mongoose-src --object-directory /home/ubuntu/experiments/mongoose-gcov -s"
            ;;
        nanomq)
            GCOV_DIR="/home/ubuntu/experiments/nanomq/build-gcov/nanomq"
            GCOV_SRC="/home/ubuntu/experiments/nanomq/build-gcov/nanomq"
            GCOVR_CLEAR_CMD="gcovr -r /home/ubuntu/experiments/nanomq --object-directory /home/ubuntu/experiments/nanomq/build-gcov -s -d"
            TARGET_CMD="timeout -k 0 -s SIGTERM 3s ./nanomq start --conf /home/ubuntu/experiments/nanomq.conf"
            GCOVR_CMD="gcovr -r /home/ubuntu/experiments/nanomq --object-directory /home/ubuntu/experiments/nanomq/build-gcov -s"
            ;;
        flashmq)
            GCOV_DIR="/home/ubuntu/experiments/flashmq-src/build-gcov"
            GCOV_SRC="/home/ubuntu/experiments/flashmq-src/build-gcov"
            GCOVR_CLEAR_CMD="gcovr -r /home/ubuntu/experiments/flashmq-src --object-directory /home/ubuntu/experiments/flashmq-src/build-gcov -s -d"
            TARGET_CMD="timeout -k 0 -s SIGTERM 3s ./flashmq --config-file /home/ubuntu/experiments/flashmq.conf"
            GCOVR_CMD="gcovr -r /home/ubuntu/experiments/flashmq-src --object-directory /home/ubuntu/experiments/flashmq-src/build-gcov -s"
            ;;
        *)
            echo "Skipping auto-recovery for unknown target $TARGET"
            LAST_GEN_DIR=""
            ;;
    esac

    if [ -n "${GCOV_DIR:-}" ]; then
        LAST_GEN_DIR=$(ls -d "${INSTANCE_DIR}"/gen*/aflnetout 2>/dev/null | sort -V | tail -1)
        while [ -n "$LAST_GEN_DIR" ] && [ "$(ls -A "$LAST_GEN_DIR" 2>/dev/null | wc -l)" -eq 0 ]; do
            LAST_GEN_DIR=$(ls -d "${INSTANCE_DIR}"/gen*/aflnetout 2>/dev/null | sort -V | grep -v "$(basename "$(dirname "$LAST_GEN_DIR")")" | tail -1)
        done
        if [ -n "$LAST_GEN_DIR" ]; then
            MERGED_GMP_DIR=$(mktemp -d)
            for tarball in "${LAST_GEN_DIR}"/aflnetout_*.tar.gz; do
                [ -f "$tarball" ] || continue
                TARBALL_TMP=$(mktemp -d)
                tar -xzf "$tarball" -C "$TARBALL_TMP" 2>/dev/null || true
                for f in "$TARBALL_TMP"/*/replayable-queue/*; do
                    [ -f "$f" ] && cp "$f" "${MERGED_GMP_DIR}/$(basename "$tarball" .tar.gz)_$(basename "$f")"
                done
                rm -rf "$TARBALL_TMP"
            done
            if [ "$(ls -A "$MERGED_GMP_DIR" | wc -l)" -gt 0 ]; then
                GCOV_CID_GMP=$(docker run -d --cpus=2 -v "${MERGED_GMP_DIR}:/tmp/replay_inputs:ro" "${TARGET_DOCKER}" /bin/bash -c "
                    cd ${GCOV_DIR}
                    ${GCOVR_CLEAR_CMD} > /dev/null 2>&1
                    cd ${GCOV_SRC}
                    for f in /tmp/replay_inputs/*id*; do
                        [ -f \"\$f\" ] || continue
                        pkill -f "${TARGET}" 2>/dev/null || true
                        ${TARGET_CMD} > /dev/null 2>&1 &
                        TARGET_PID=\$!
                        sleep 0.1
                        aflnet-replay \"\$f\" MQTT 1883 1 > /dev/null 2>&1
                        kill -TERM \$TARGET_PID 2>/dev/null
                        wait \$TARGET_PID 2>/dev/null || true
                    done
                    cd ${GCOV_DIR}
                    ${GCOVR_CMD} 2>/dev/null || echo 'no data'
                ")
                docker wait "$GCOV_CID_GMP" > /dev/null
                GCOV_TEXT_G=$(docker logs "$GCOV_CID_GMP" 2>&1)
                
                L_PER_G=$(echo "$GCOV_TEXT_G" | grep -i 'lines:' | head -1 | sed 's/.*lines: *\([0-9.]*\)%.*/\1/')
                L_ABS_G=$(echo "$GCOV_TEXT_G" | grep -i 'lines:' | head -1 | sed 's/.*(\([0-9]*\) out of.*/\1/')
                B_PER_G=$(echo "$GCOV_TEXT_G" | grep -i 'branch' | head -1 | sed 's/.*branches: *\([0-9.]*\)%.*/\1/')
                B_ABS_G=$(echo "$GCOV_TEXT_G" | grep -i 'branch' | head -1 | sed 's/.*(\([0-9]*\) out of.*/\1/')
                
                cat << IN_EOF > "${INSTANCE_DIR}/cov_over_time.csv"
Time,l_per,l_abs,b_per,b_abs
0,${L_PER_G:-0},${L_ABS_G:-0},${B_PER_G:-0},${B_ABS_G:-0}
IN_EOF
                docker rm -f "$GCOV_CID_GMP" > /dev/null
            fi
            rm -rf "$MERGED_GMP_DIR"
        fi
    fi
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
