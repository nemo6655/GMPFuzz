#!/bin/bash
# ============================================================
# collect_coverage.sh - Unified coverage collection & summary
#
# For AFLNet/GMPFuzz: cov_over_time.csv is already generated inside
#   the container via cov_script (ProFuzzBench 3-step pattern).
#   This script just extracts final values.
#
# For MPFuzz/Peach: gcov coverage is collected via tcpdump pcap replay
#   (post-fuzzing). Edge coverage is also available as a secondary metric.
#
# Usage: ./collect_coverage.sh [options]
#   -t, --target TARGET    Fuzzing target (for display, default: mqtt)
#   <results_dir>          Base results directory (positional)
#   -h, --help             Show this help
#
# Output: <results_dir>/coverage_summary.csv
# ============================================================
set -euo pipefail

TARGET="mqtt"
RESULTS_DIR=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)  TARGET="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            RESULTS_DIR="$1"; shift ;;
    esac
done

if [ -z "$RESULTS_DIR" ]; then
    RESULTS_DIR="$(pwd)/results"
fi

SUMMARY_CSV="${RESULTS_DIR}/coverage_summary.csv"

echo "========================================================"
echo "  Unified Coverage Collection"
echo "========================================================"
echo "  Target:      ${TARGET}"
echo "  Results dir: ${RESULTS_DIR}"
echo "  Start:       $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"

# Header for summary CSV
echo "fuzzer,instance,l_per,l_abs,b_per,b_abs,extra_info" > "$SUMMARY_CSV"

# ============================================================
# Helper: Extract gcov coverage from cov_over_time.csv
#   (Already generated inside Docker by cov_script)
# ============================================================
extract_gcov_coverage() {
    local FUZZER_NAME=$1
    local INSTANCE_DIR=$2
    local INSTANCE_IDX=$3

    # Find cov_over_time.csv
    local COV_CSV=$(find "$INSTANCE_DIR" -name "cov_over_time.csv" 2>/dev/null | head -1)

    if [ -n "$COV_CSV" ] && [ -f "$COV_CSV" ]; then
        local LINE_COUNT=$(wc -l < "$COV_CSV")
        if [ "$LINE_COUNT" -le 1 ]; then
            echo "    WARNING: cov_over_time.csv has no data rows"
            return
        fi

        local LAST_LINE=$(tail -1 "$COV_CSV")
        local L_PER=$(echo "$LAST_LINE" | cut -d',' -f2)
        local L_ABS=$(echo "$LAST_LINE" | cut -d',' -f3)
        local B_PER=$(echo "$LAST_LINE" | cut -d',' -f4)
        local B_ABS=$(echo "$LAST_LINE" | cut -d',' -f5)
        local DATA_ROWS=$((LINE_COUNT - 1))

        echo "${FUZZER_NAME},${INSTANCE_IDX},${L_PER},${L_ABS},${B_PER},${B_ABS},gcov_${DATA_ROWS}_testcases" >> "$SUMMARY_CSV"
        echo "    gcov: L=${L_PER}% (${L_ABS}) B=${B_PER}% (${B_ABS}) [${DATA_ROWS} data points]"
    else
        echo "    WARNING: No cov_over_time.csv found"

        # Try to find replayable-queue count for info
        local RQUEUE=$(find "$INSTANCE_DIR" -name "replayable-queue" -type d 2>/dev/null | head -1)
        if [ -n "$RQUEUE" ]; then
            local QCOUNT=$(find "$RQUEUE" -maxdepth 1 -type f | wc -l)
            echo "    (replayable-queue has ${QCOUNT} entries but no coverage was collected)"
        fi
    fi
}

# ============================================================
# Helper: Extract MPFuzz/Peach edge coverage
# ============================================================
extract_edge_coverage() {
    local FUZZER_NAME=$1
    local INSTANCE_DIR=$2
    local INSTANCE_IDX=$3

    local EDGE_CSV=$(find "$INSTANCE_DIR" -name "edge_coverage.csv" 2>/dev/null | head -1)
    if [ -n "$EDGE_CSV" ] && [ -f "$EDGE_CSV" ]; then
        local FINAL_EDGES=$(tail -1 "$EDGE_CSV" | cut -d',' -f2 | tr -d ' ')
        # MPFuzz/Peach: no gcov data, record edge count in extra_info
        echo "${FUZZER_NAME},${INSTANCE_IDX},N/A,N/A,N/A,N/A,edges_${FINAL_EDGES:-0}" >> "$SUMMARY_CSV"
        echo "    Edge coverage: ${FINAL_EDGES:-N/A} edges (no gcov available)"
    else
        echo "    WARNING: No edge_coverage.csv found"
    fi
}

# ============================================================
# Process each fuzzer's results
# ============================================================

# --- AFLNet ---
if [ -d "${RESULTS_DIR}/aflnet" ]; then
    echo ""
    echo "[AFLNet] Processing..."
    for inst_dir in "${RESULTS_DIR}/aflnet"/instance_*; do
        [ -d "$inst_dir" ] || continue
        idx=$(basename "$inst_dir" | sed 's/instance_//')
        echo "  Instance ${idx}:"
        extract_gcov_coverage "aflnet" "$inst_dir" "$idx"
    done
fi

# --- GMPFuzz ---
if [ -d "${RESULTS_DIR}/gmpfuzz" ]; then
    echo ""
    echo "[GMPFuzz] Processing..."
    for inst_dir in "${RESULTS_DIR}/gmpfuzz"/instance_*; do
        [ -d "$inst_dir" ] || continue
        idx=$(basename "$inst_dir" | sed 's/instance_//')
        echo "  Instance ${idx}:"
        extract_gcov_coverage "gmpfuzz" "$inst_dir" "$idx"
    done
fi

# --- MPFuzz ---
if [ -d "${RESULTS_DIR}/mpfuzz" ]; then
    echo ""
    echo "[MPFuzz] Processing..."
    for inst_dir in "${RESULTS_DIR}/mpfuzz"/instance_*; do
        [ -d "$inst_dir" ] || continue
        idx=$(basename "$inst_dir" | sed 's/instance_//')
        echo "  Instance ${idx}:"
        # Try gcov coverage first (from pcap replay), fall back to edge-only
        local_cov=$(find "$inst_dir" -name "cov_over_time.csv" 2>/dev/null | head -1)
        if [ -n "$local_cov" ] && [ -f "$local_cov" ] && [ "$(wc -l < "$local_cov")" -gt 1 ]; then
            extract_gcov_coverage "mpfuzz" "$inst_dir" "$idx"
        else
            echo "    (gcov not available, using edge coverage)"
            extract_edge_coverage "mpfuzz" "$inst_dir" "$idx"
        fi
    done
fi

# --- Peach ---
if [ -d "${RESULTS_DIR}/peach" ]; then
    echo ""
    echo "[Peach] Processing..."
    for inst_dir in "${RESULTS_DIR}/peach"/instance_*; do
        [ -d "$inst_dir" ] || continue
        idx=$(basename "$inst_dir" | sed 's/instance_//')
        echo "  Instance ${idx}:"
        # Try gcov coverage first (from pcap replay), fall back to edge-only
        local_cov=$(find "$inst_dir" -name "cov_over_time.csv" 2>/dev/null | head -1)
        if [ -n "$local_cov" ] && [ -f "$local_cov" ] && [ "$(wc -l < "$local_cov")" -gt 1 ]; then
            extract_gcov_coverage "peach" "$inst_dir" "$idx"
        else
            echo "    (gcov not available, using edge coverage)"
            extract_edge_coverage "peach" "$inst_dir" "$idx"
        fi
    done
fi

# ============================================================
# Print summary table
# ============================================================
echo ""
echo "========================================================"
echo "  Coverage Summary"
echo "========================================================"
echo ""
echo "  Note: All fuzzers use gcov (line/branch coverage) when available."
echo "  MPFuzz/Peach gcov is collected via tcpdump pcap replay post-fuzzing."
echo "  Edge coverage is shown as fallback if gcov data is unavailable."
echo ""
column -t -s',' "$SUMMARY_CSV" 2>/dev/null || cat "$SUMMARY_CSV"
echo ""
echo "  Summary CSV: ${SUMMARY_CSV}"
echo "========================================================"
