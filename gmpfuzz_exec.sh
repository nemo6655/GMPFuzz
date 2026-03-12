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
    echo "[$(date '+%H:%M:%S')] WARNING: GMPFuzz evolutionary loop exited with code ${EXIT_CODE}"
    echo "  This may be expected (budget exhaustion, ASE stop, etc.)"
    echo "  Continuing to collect results from completed generations..."
else
    echo "[$(date '+%H:%M:%S')] GMPFuzz evolutionary loop completed successfully."
fi

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
# Step 3: Extract edge coverage from all generations' plot_data
# =====================================================================
echo "[$(date '+%H:%M:%S')] Extracting edge coverage from AFLNet plot_data..."
EDGE_CSV="${EVAL_DIR}/edge_coverage.csv"
echo "timestamp,edge_count" > "$EDGE_CSV"

TARBALL_COUNT=0
for gen_dir in "${EVAL_DIR}"/gen*/aflnetout; do
    if [ ! -d "$gen_dir" ]; then continue; fi
    gen_name=$(basename "$(dirname "$gen_dir")")
    for tarball in "${gen_dir}"/aflnetout_*.tar.gz; do
        if [ ! -f "$tarball" ]; then continue; fi
        base=$(basename "$tarball" .tar.gz)
        TARBALL_COUNT=$((TARBALL_COUNT + 1))

        # Extract plot_data from tarball and convert map_size% to edge count
        # plot_data format: timestamp, cycles, cur_path, paths_total, pending, pending_favs, map_size%, crashes, hangs, depth, execs
        tar -xzf "$tarball" -O "${base}/plot_data" 2>/dev/null | \
            grep -v "^#" | while IFS=',' read -r ts cycles cur_path paths pending pfavs map_pct rest; do
                ts=$(echo "$ts" | tr -d ' ')
                map_pct=$(echo "$map_pct" | tr -d ' %')
                if [ -n "$ts" ] && [ -n "$map_pct" ]; then
                    # Convert map_size percentage to absolute edge count (bitmap size = 65536)
                    edges=$(echo "$map_pct * 65536 / 100" | bc 2>/dev/null | cut -d'.' -f1)
                    echo "${ts},${edges:-0}" >> "$EDGE_CSV"
                fi
            done
        echo "  ${gen_name}/${base}: extracted plot_data"
    done
done

# Sort by timestamp and deduplicate (keep max edge count per timestamp)
if [ "$TARBALL_COUNT" -gt 0 ]; then
    TMPCSV=$(mktemp)
    head -1 "$EDGE_CSV" > "$TMPCSV"
    tail -n +2 "$EDGE_CSV" | sort -t',' -k1,1n | \
        awk -F',' 'NR==1{print; next} $2>max{max=$2; print}' >> "$TMPCSV"
    mv "$TMPCSV" "$EDGE_CSV"
fi

EDGE_LINES=$(($(wc -l < "$EDGE_CSV") - 1))
FINAL_EDGES=$(tail -1 "$EDGE_CSV" | cut -d',' -f2)
echo "  Total data points: ${EDGE_LINES}"
echo "  Final edge count: ${FINAL_EDGES:-N/A}"
echo ""
echo "  ┌─────────────────────────────────────┐"
echo "  │       Edge Coverage Summary         │"
echo "  ├─────────────────────────────────────┤"
echo "  │  Final edges:    ${FINAL_EDGES:-N/A} (of 65536)     "
echo "  │  Map density:    $(echo "scale=2; ${FINAL_EDGES:-0} * 100 / 65536" | bc 2>/dev/null || echo "N/A")%           "
echo "  │  Tarballs:       ${TARBALL_COUNT}                "
echo "  │  Data points:    ${EDGE_LINES}                "
echo "  └─────────────────────────────────────┘"
echo ""

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
echo "End Time:        $(date '+%Y-%m-%d %H:%M:%S')"
echo "Evaluation Dir:  ${EVAL_DIR}"
echo "Archive:         ${EVAL_DIR}/${ARCHIVE_NAME}"
echo "Log:             ${LOG_FILE}"
if [ -f "${EVAL_DIR}/edge_coverage.csv" ]; then
    echo "Edge CSV:        ${EVAL_DIR}/edge_coverage.csv"
fi
echo "========================================================"
