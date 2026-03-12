#!/bin/bash
# collect_coverage.sh - Unified edge coverage collection & summary
# All fuzzers use bitmap/edge coverage as the unified metric.
set -euo pipefail

TARGET="mqtt"
RESULTS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target) TARGET="$2"; shift 2 ;;
        -h|--help) echo "Usage: $0 [-t target] <results_dir>"; exit 0 ;;
        *) RESULTS_DIR="$1"; shift ;;
    esac
done
[ -z "$RESULTS_DIR" ] && RESULTS_DIR="$(pwd)/evaluation"

SUMMARY_CSV="${RESULTS_DIR}/coverage_summary.csv"
echo "========================================================"
echo "  Edge Coverage Collection (Unified)"
echo "  Target: ${TARGET} | Dir: ${RESULTS_DIR}"
echo "========================================================"
echo "fuzzer,instance,final_edges,data_points" > "$SUMMARY_CSV"

# Extract from edge_coverage.csv (GMPFuzz/MPFuzz/Peach)
extract_edge_csv() {
    local FUZZER=$1 DIR=$2 IDX=$3
    local CSV=$(find "$DIR" -maxdepth 1 -name "edge_coverage.csv" 2>/dev/null | head -1)
    if [ -n "$CSV" ] && [ -f "$CSV" ]; then
        local N=$(wc -l < "$CSV")
        local FINAL=$(tail -1 "$CSV" | cut -d',' -f2 | tr -d ' ')
        echo "${FUZZER},${IDX},${FINAL:-0},${N}" >> "$SUMMARY_CSV"
        echo "    Edges: ${FINAL:-0} (${N} data points)"
    else
        echo "    WARNING: edge_coverage.csv not found"
        echo "${FUZZER},${IDX},0,0" >> "$SUMMARY_CSV"
    fi
}

# Extract from AFLNet plot_data (map_size% * 65536)
extract_aflnet_edges() {
    local FUZZER=$1 DIR=$2 IDX=$3
    local PD=$(find "$DIR" -name "plot_data" 2>/dev/null | head -1)
    if [ -z "$PD" ] || [ ! -f "$PD" ]; then
        echo "    WARNING: plot_data not found"
        echo "${FUZZER},${IDX},0,0" >> "$SUMMARY_CSV"
        return
    fi
    local N=$(grep -cv "^#" "$PD" 2>/dev/null || echo 0)
    local LAST=$(grep -v "^#" "$PD" | tail -1)
    local PCT=$(echo "$LAST" | cut -d',' -f7 | tr -d ' %')
    if [ -n "$PCT" ]; then
        local EDGES=$(echo "$PCT * 65536 / 100" | bc 2>/dev/null | cut -d. -f1)
        echo "${FUZZER},${IDX},${EDGES:-0},${N}" >> "$SUMMARY_CSV"
        echo "    Edges: ${EDGES:-0} (map=${PCT}%, ${N} points)"
    else
        echo "${FUZZER},${IDX},0,${N}" >> "$SUMMARY_CSV"
    fi
}

for fuzzer in aflnet gmpfuzz mpfuzz peach; do
    [ -d "${RESULTS_DIR}/${fuzzer}" ] || continue
    echo ""
    echo "[${fuzzer}] Processing..."
    for inst in "${RESULTS_DIR}/${fuzzer}"/instance_*; do
        [ -d "$inst" ] || continue
        idx=$(basename "$inst" | sed 's/instance_//')
        echo "  Instance ${idx}:"
        case "$fuzzer" in
            aflnet) extract_aflnet_edges "$fuzzer" "$inst" "$idx" ;;
            *)      extract_edge_csv "$fuzzer" "$inst" "$idx" ;;
        esac
    done
done

echo ""
echo "========================================================"
echo "  Edge Coverage Summary"
echo "========================================================"
column -t -s',' "$SUMMARY_CSV" 2>/dev/null || cat "$SUMMARY_CSV"
echo ""
echo "  CSV: ${SUMMARY_CSV}"
echo "========================================================"
