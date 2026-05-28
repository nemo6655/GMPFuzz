#!/bin/bash
CID="05df18319184"
INSTANCE_DIR="/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/results_20260502_022943/gmpfuzz/instance_1"

GCOV_TEXT=$(docker logs $CID 2>&1)
L_PER=$(echo "$GCOV_TEXT" | grep -i 'lines:' | head -1 | sed 's/.*lines: *\([0-9.]*\)%.*/\1/')
L_ABS=$(echo "$GCOV_TEXT" | grep -i 'lines:' | head -1 | sed 's/.*(\([0-9]*\) out of.*/\1/')
B_PER=$(echo "$GCOV_TEXT" | grep -i 'branch' | head -1 | sed 's/.*branches: *\([0-9.]*\)%.*/\1/')
B_ABS=$(echo "$GCOV_TEXT" | grep -i 'branch' | head -1 | sed 's/.*(\([0-9]*\) out of.*/\1/')

echo "Time,l_per,l_abs,b_per,b_abs" > "$INSTANCE_DIR/cov_over_time.csv"
echo "86400,${L_PER:-0},${L_ABS:-0},${B_PER:-0},${B_ABS:-0}" >> "$INSTANCE_DIR/cov_over_time.csv"

echo "Fixed cov for mongoose."
