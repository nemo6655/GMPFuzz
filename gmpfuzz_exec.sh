#!/bin/bash
# gmpfuzz_exec.sh - GMPFuzz entry point script.
#
# Usage: ./gmpfuzz_exec.sh [options] <test_number>
#
# Arguments:
#   test_number   Test run identifier (e.g., 1, 2, 3)
#
# Options:
#   -t, --target TARGET     Fuzzing target: mqtt, mongoose, nanomq (default: mqtt)
#   -n, --num-gens NUM      Number of generations (default: 5)
#   -a, --ablation MODE     Ablation mode for experiments:
#                             full      - All features enabled (default)
#                             no-pasd   - Disable PASD (uniform state distribution)
#                             no-mqtt   - Disable MQTT-aware zones (rarity-only SS)
#                             no-ase    - Disable ASE (fixed 1800s timeout)
#                             no-llm    - Disable LLM variant generation
#                             no-pasd-ase - Disable both PASD and ASE
#                             baseline  - Disable PASD + ASE + LLM (pure AFLNet)
#
# Examples:
#   ./gmpfuzz_exec.sh 1                              # mqtt target, full mode, 5 gens
#   ./gmpfuzz_exec.sh -t mongoose 1                   # mongoose target
#   ./gmpfuzz_exec.sh -t nanomq -n 3 1                # nanomq, 3 gens
#   ./gmpfuzz_exec.sh -a no-pasd 2                    # Ablation: no PASD
#   ./gmpfuzz_exec.sh -a no-ase 3                     # Ablation: no ASE
#   ./gmpfuzz_exec.sh -t mongoose -a baseline 4       # mongoose, pure AFLNet
#
# Output is stored in: evaluation/gmpfuzz_<target>_<test_number>/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# =====================================================================
# Parse arguments
# =====================================================================
NUM_GENS=20
ABLATION_MODE="full"

TARGET="mqtt"

show_usage() {
    echo "Usage: $0 [options] <test_number>"
    echo ""
    echo "Options:"
    echo "  -t, --target TARGET     Fuzzing target (default: mqtt)"
    echo "                            mqtt      - Mosquitto v1.5.5"
    echo "                            mongoose  - Mongoose v7.20"
    echo "                            nanomq    - NanoMQ v0.21.10"
    echo "  -n, --num-gens NUM      Number of generations (default: 5)"
    echo "  -a, --ablation MODE     Ablation experiment mode:"
    echo "                            full      - All features (default)"
    echo "                            no-pasd   - Disable PASD (uniform distribution)"
    echo "                            no-mqtt   - Disable MQTT zones (rarity-only)"
    echo "                            no-ase    - Disable ASE (fixed 1800s timeout)"
    echo "                            no-llm    - Disable LLM variant generation"
    echo "                            no-pasd-ase - Disable both PASD and ASE"
    echo "                            baseline  - Disable PASD + ASE + LLM"
    echo ""
    echo "Output: evaluation/gmpfuzz_<target>_<test_number>/"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            TARGET="$2"; shift 2 ;;
        -n|--num-gens)
            NUM_GENS="$2"; shift 2 ;;
        -a|--ablation)
            ABLATION_MODE="$2"; shift 2 ;;
        -h|--help)
            show_usage ;;
        -*)
            echo "Unknown option: $1"; show_usage ;;
        *)
            TEST_NUMBER="$1"; shift ;;
    esac
done

if [ -z "${TEST_NUMBER:-}" ]; then
    echo "Error: test_number is required"
    show_usage
fi

# Validate target
if [ ! -d "preset/${TARGET}" ]; then
    echo "Error: Unknown target '${TARGET}' (preset/${TARGET} not found)"
    echo "Available targets:"
    ls -d preset/*/ 2>/dev/null | xargs -I{} basename {}
    show_usage
fi

# =====================================================================
# Map ablation mode to environment variables
# =====================================================================
# GMPFUZZ_FORBIDDEN: controls PASD/LLM in do_gen_net.sh
#   ""       -> full MQTT-aware PASD
#   "NOSS"   -> no state selection (uniform)
#   "NOMQTT" -> rarity-only SS (no MQTT zones)
#   "NOSM"   -> no LLM variant generation
# GMPFUZZ_ASE: controls ASE in do_gen_net.sh
#   "1" -> ASE enabled
#   "0" -> ASE disabled (fixed 1800s)

export GMPFUZZ_FORBIDDEN=""
export GMPFUZZ_ASE="1"

case "$ABLATION_MODE" in
    full)
        GMPFUZZ_FORBIDDEN=""
        GMPFUZZ_ASE="1"
        ;;
    no-pasd)
        GMPFUZZ_FORBIDDEN="NOSS"
        GMPFUZZ_ASE="1"
        ;;
    no-mqtt)
        GMPFUZZ_FORBIDDEN="NOMQTT"
        GMPFUZZ_ASE="1"
        ;;
    no-ase)
        GMPFUZZ_FORBIDDEN=""
        GMPFUZZ_ASE="0"
        ;;
    no-llm)
        GMPFUZZ_FORBIDDEN="NOSM"
        GMPFUZZ_ASE="1"
        ;;
    no-pasd-ase)
        GMPFUZZ_FORBIDDEN="NOSS"
        GMPFUZZ_ASE="0"
        ;;
    baseline)
        GMPFUZZ_FORBIDDEN="NOSS,NOSM"
        GMPFUZZ_ASE="0"
        ;;
    *)
        echo "Error: Unknown ablation mode '$ABLATION_MODE'"
        show_usage
        ;;
esac

RUNDIR="preset/${TARGET}"
PROJECT_NAME="${TARGET}"
IMAGE_NAME="gmpfuzz/${TARGET}"
CURRENT_DATE=$(date +%Y%m%d_%H%M%S)

# =====================================================================
# Setup directories
# =====================================================================
EVAL_DIR="${SCRIPT_DIR}/evaluation/gmpfuzz_${TARGET}_${TEST_NUMBER}"
LOG_FILE="${EVAL_DIR}/run_${CURRENT_DATE}.log"

mkdir -p "${EVAL_DIR}"

# Determine human-readable algorithm status
if [ -z "$GMPFUZZ_FORBIDDEN" ]; then
    PASD_STATUS="MQTT-aware (full)"
elif [[ "$GMPFUZZ_FORBIDDEN" == *"NOSS"* ]]; then
    PASD_STATUS="DISABLED (uniform)"
elif [ "$GMPFUZZ_FORBIDDEN" = "NOMQTT" ]; then
    PASD_STATUS="Rarity-only (no MQTT zones)"
else
    PASD_STATUS="Custom ($GMPFUZZ_FORBIDDEN)"
fi

if [ "$GMPFUZZ_ASE" = "1" ]; then
    ASE_STATUS="ENABLED (adaptive)"
else
    ASE_STATUS="DISABLED (fixed 1800s)"
fi

if [[ "$GMPFUZZ_FORBIDDEN" == *"NOSM"* ]]; then
    LLM_STATUS="DISABLED"
else
    LLM_STATUS="ENABLED (CodeLlama-13b)"
fi

echo "========================================================"
echo "     GMPFuzz - MQTT Protocol Fuzzer"
echo "========================================================"
echo "Test Number:     ${TEST_NUMBER}"
echo "Target:          ${TARGET}"
echo "Max Generations: ${NUM_GENS}"
echo "Ablation Mode:   ${ABLATION_MODE}"
echo "  PASD (Alg.1):  ${PASD_STATUS}"
echo "  ASE  (Alg.2):  ${ASE_STATUS}"
echo "  LLM Variants:  ${LLM_STATUS}"
echo "Run Directory:   ${RUNDIR}"
echo "Image:           ${IMAGE_NAME}"
echo "Output:          ${EVAL_DIR}"
echo "Log:             ${LOG_FILE}"
echo "Start Time:      $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"

# =====================================================================
# Step 1: Run the GMPFuzz evolutionary loop
# =====================================================================
echo "[$(date '+%H:%M:%S')] Starting GMPFuzz with max ${NUM_GENS} generations (dynamic)..."

export NUM_GENERATIONS="${NUM_GENS}"

# Run all generations, tee output to log file
./all_gen_net.sh "$RUNDIR" 2>&1 | tee "${LOG_FILE}"
EXIT_CODE=${PIPESTATUS[0]}

if [ "$EXIT_CODE" -ne 0 ]; then
    echo "[$(date '+%H:%M:%S')] ERROR: GMPFuzz exited with code ${EXIT_CODE}"
    echo "Check log: ${LOG_FILE}"
    exit $EXIT_CODE
fi

echo "[$(date '+%H:%M:%S')] GMPFuzz evolutionary loop completed successfully."

# =====================================================================
# Step 2: Collect results into evaluation directory
# =====================================================================
echo "[$(date '+%H:%M:%S')] Collecting results..."

# Copy coverage data from each generation
for gen_dir in "${RUNDIR}"/gen*/; do
    gen_name=$(basename "$gen_dir")
    dest="${EVAL_DIR}/${gen_name}"
    mkdir -p "${dest}"

    # Copy coverage JSON
    if [ -f "${gen_dir}/logs/coverage.json" ]; then
        cp "${gen_dir}/logs/coverage.json" "${dest}/"
        echo "  Copied ${gen_name}/coverage.json"
    fi

    # Copy elites JSON
    if [ -f "${gen_dir}/logs/elites.json" ]; then
        cp "${gen_dir}/logs/elites.json" "${dest}/"
        echo "  Copied ${gen_name}/elites.json"
    fi

    # Copy aflnet output archives
    if [ -d "${gen_dir}/aflnetout" ]; then
        cp -r "${gen_dir}/aflnetout" "${dest}/"
        echo "  Copied ${gen_name}/aflnetout/"
    fi
done

# Copy initial seeds info
if [ -d "${RUNDIR}/initial" ]; then
    mkdir -p "${EVAL_DIR}/initial"
    cp -r "${RUNDIR}/initial/seeds" "${EVAL_DIR}/initial/" 2>/dev/null || true
fi

# =====================================================================
# Step 3: Extract replayable-queue from all generations
# =====================================================================
echo "[$(date '+%H:%M:%S')] Extracting replayable-queue from all generations..."
MERGED_QUEUE="${EVAL_DIR}/merged_queue"
mkdir -p "$MERGED_QUEUE/replayable-queue"
QUEUE_COUNT=0

for gen_dir in "${EVAL_DIR}"/gen*/aflnetout; do
    if [ ! -d "$gen_dir" ]; then continue; fi
    gen_name=$(basename "$(dirname "$gen_dir")")
    for tarball in "${gen_dir}"/aflnetout_*.tar.gz; do
        if [ ! -f "$tarball" ]; then continue; fi
        base=$(basename "$tarball" .tar.gz)

        # Extract replayable-queue from tarball into merged directory
        tar -xzf "$tarball" -C "$MERGED_QUEUE/replayable-queue" \
            --strip-components=2 "${base}/replayable-queue" 2>/dev/null || true
    done
    count=$(find "$MERGED_QUEUE/replayable-queue" -maxdepth 1 -type f 2>/dev/null | wc -l)
    echo "  After ${gen_name}: ${count} total queue entries"
done

QUEUE_COUNT=$(find "$MERGED_QUEUE/replayable-queue" -maxdepth 1 -type f 2>/dev/null | wc -l)
echo "  Total merged queue entries: ${QUEUE_COUNT}"

# =====================================================================
# Step 4: Collect final code coverage via gcov replay
# =====================================================================
if [ -d "$MERGED_QUEUE/replayable-queue" ] && [ "$QUEUE_COUNT" -gt 0 ]; then
    echo "[$(date '+%H:%M:%S')] Collecting final code coverage from merged queue..."
    COV_CSV="${EVAL_DIR}/cov_over_time_${TARGET}_${TEST_NUMBER}.csv"

    # Remove stale CSV from previous runs (prevent contamination)
    rm -f "${MERGED_QUEUE}/cov_over_time.csv"

    # Use a named container to prevent duplicate concurrent runs
    COV_CONTAINER="gmpfuzz_cov_${TARGET}_${TEST_NUMBER}"
    docker rm -f "$COV_CONTAINER" 2>/dev/null || true

    # Run cov_script inside Docker: replay all test cases through gcov-instrumented target
    COV_CID=$(docker run -d \
        --name "$COV_CONTAINER" \
        -v "${MERGED_QUEUE}":/home/ubuntu/input \
        --entrypoint /bin/bash \
        "${IMAGE_NAME}" \
        -c "cov_script /home/ubuntu/input 1883 30 /home/ubuntu/input/cov_over_time.csv 1")

    if [ -n "$COV_CID" ]; then
        echo "  Coverage container started: ${COV_CID:0:12}"
        echo "  Replaying ${QUEUE_COUNT} test cases through gcov-instrumented ${TARGET}..."
        docker wait "$COV_CID" 2>/dev/null || true

        # Show container output
        echo "  --- cov_script output ---"
        docker logs "$COV_CID" 2>&1 | tail -5
        echo "  --- end ---"

        # Copy coverage CSV back from the bind mount
        if [ -f "${MERGED_QUEUE}/cov_over_time.csv" ]; then
            cp "${MERGED_QUEUE}/cov_over_time.csv" "$COV_CSV"
            echo "  Coverage CSV: ${COV_CSV}"

            # Print final coverage summary
            LAST_LINE=$(tail -1 "$COV_CSV")
            if [ -n "$LAST_LINE" ] && [ "$LAST_LINE" != "Time,l_per,l_abs,b_per,b_abs" ]; then
                L_PER=$(echo "$LAST_LINE" | cut -d',' -f2)
                L_ABS=$(echo "$LAST_LINE" | cut -d',' -f3)
                B_PER=$(echo "$LAST_LINE" | cut -d',' -f4)
                B_ABS=$(echo "$LAST_LINE" | cut -d',' -f5)
                echo ""
                echo "  ┌─────────────────────────────────────┐"
                echo "  │       Final Coverage Summary        │"
                echo "  ├─────────────────────────────────────┤"
                echo "  │  Line Coverage:   ${L_PER}% (${L_ABS} lines)  "
                echo "  │  Branch Coverage: ${B_PER}% (${B_ABS} branches)"
                echo "  │  Queue Entries:   ${QUEUE_COUNT}              "
                echo "  └─────────────────────────────────────┘"
                echo ""
            fi
        else
            echo "  WARNING: Coverage CSV not found after container run."
            echo "  Container logs:"
            docker logs "$COV_CID" 2>&1 | tail -20
        fi

        docker rm "$COV_CONTAINER" 2>/dev/null || true
    else
        echo "  ERROR: Failed to start coverage container."
    fi
else
    echo "[$(date '+%H:%M:%S')] Skipping coverage collection (no queue entries)."
fi

# =====================================================================
# Step 5: Create archive
# =====================================================================
echo "[$(date '+%H:%M:%S')] Creating archive..."
ARCHIVE_NAME="gmpfuzz_${TARGET}_${TEST_NUMBER}_${CURRENT_DATE}.tar.xz"
tar -cJf "${EVAL_DIR}/${ARCHIVE_NAME}" \
    -C "${EVAL_DIR}" \
    --exclude="*.tar.xz" \
    --exclude="*.tar.gz" \
    . 2>/dev/null || true
echo "  Archive: ${EVAL_DIR}/${ARCHIVE_NAME}"

# =====================================================================
# Summary
# =====================================================================
echo ""
echo "========================================================"
echo "     GMPFuzz Run Complete"
echo "========================================================"
echo "Test Number:     ${TEST_NUMBER}"
echo "Ablation Mode:   ${ABLATION_MODE}"
echo "Generations:     ${NUM_GENS}"
echo "Queue Entries:   ${QUEUE_COUNT}"
echo "End Time:        $(date '+%Y-%m-%d %H:%M:%S')"
echo "Evaluation Dir:  ${EVAL_DIR}"
echo "Archive:         ${EVAL_DIR}/${ARCHIVE_NAME}"
echo "Log:             ${LOG_FILE}"
if [ -f "${EVAL_DIR}/cov_over_time_${TARGET}_${TEST_NUMBER}.csv" ]; then
    echo "Coverage CSV:    ${EVAL_DIR}/cov_over_time_${TARGET}_${TEST_NUMBER}.csv"
fi
echo "========================================================"
