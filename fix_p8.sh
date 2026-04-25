#!/bin/bash

# NanoMQ phase 8 fix
sed -i '233,248d' benchmark/mpfuzz_nanomq/run_mpfuzz.sh
cat << 'INNER_EOF' >> benchmark/mpfuzz_nanomq/run_mpfuzz.sh
    gcovr_out=$(gcovr -r ${TARGET_SRC} --gcov-executable "llvm-cov gcov" -s 2>/dev/null)
    lines_info=$(echo "$gcovr_out" | grep "lines:")
    branches_info=$(echo "$gcovr_out" | grep "branches:")
    l_per=$(echo "$lines_info" | awk '{print $2}' | tr -d "%" || echo "0")
    l_abs=$(echo "$lines_info" | sed -n 's/.*(\([0-9]*\) out of.*/\1/p' || echo "0")
    b_per=$(echo "$branches_info" | awk '{print $2}' | tr -d "%" || echo "0")
    b_abs=$(echo "$branches_info" | sed -n 's/.*(\([0-9]*\) out of.*/\1/p' || echo "0")
    if [ -n "$l_per" ]; then
        ts=$(date +%s)
        echo "$ts,${l_per},${l_abs:-0},${b_per:-0},${b_abs:-0}" >> "${GCOVR_CSV}"
        echo "[$(date '+%H:%M:%S')] gcovr collection complete: L=${l_per}% B=${b_per}%"
    else
        echo "[$(date '+%H:%M:%S')] WARNING: No coverage data generated/found in ${TARGET_SRC}"
    fi
else
    echo "[$(date '+%H:%M:%S')] WARNING: Skipping final gcovr (target src missing)"
fi

# ============================================================
# Print summary
CRASH_COUNT=$(find "${OUTDIR}/crashes" -type f 2>/dev/null | wc -l)
EDGE_COUNT=$(tail -1 "${COV_FILE}" 2>/dev/null | cut -d',' -f2 | tr -d ' ')

echo ""
echo "============================================================"
echo "MPFuzz MQTT Fuzzing (NanoMQ) Complete"
echo "============================================================"
echo "  Duration:    ${TIMEOUT}s"
echo "  Crashes:     ${CRASH_COUNT}"
echo "  Edge count:  ${EDGE_COUNT:-N/A}"
echo "  Output:      ${OUTDIR}"
echo "  Edge CSV:    ${COV_FILE}"
echo "  Gcovr CSV:   ${GCOVR_CSV}"
echo "============================================================"
INNER_EOF
