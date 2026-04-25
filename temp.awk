BEGIN {
    in_loop=0; in_p8=0;
    loop_code="\
        gcovr_out=$(gcovr -r %TARGET_SRC% --gcov-executable \"llvm-cov gcov\" -s 2>/dev/null)\n\
        lines_info=$(echo \"$gcovr_out\" | grep \"lines:\")\n\
        branches_info=$(echo \"$gcovr_out\" | grep \"branches:\")\n\
        l_per=$(echo \"$lines_info\" | awk '{print $2}' | tr -d '%' || echo \"0\")\n\
        l_abs=$(echo \"$lines_info\" | awk '{print $3}' | cut -c2- || echo \"0\")\n\
        b_per=$(echo \"$branches_info\" | awk '{print $2}' | tr -d '%' || echo \"0\")\n\
        b_abs=$(echo \"$branches_info\" | awk '{print $3}' | cut -c2- || echo \"0\")\n\
        if [ -n \"$l_per\" ] && [ \"$l_per\" != \"0\" ]; then\n\
            echo \"${elapsed},${l_per},${l_abs:-0},${b_per:-0},${b_abs:-0}\" >> \"${GCOVR_CSV}\"\n\
        fi\n\
        sleep 5\n\
"
    p8_code="\
echo \"[$(date '+%H:%M:%S')] Running final gcovr collection...\"\n\
TARGET_SRC=\"%TARGET_SRC%\"\n\
if [ -d \"${TARGET_SRC}\" ]; then\n\
    cd \"${TARGET_SRC}/build-instr\" 2>/dev/null || cd \"${TARGET_SRC}\" 2>/dev/null\n\
    echo \"[$(date '+%H:%M:%S')] Collecting gcov from: ${TARGET_SRC}\"\n\
    gcovr_out=$(gcovr -r ${TARGET_SRC} --gcov-executable \"llvm-cov gcov\" -s 2>/dev/null)\n\
    lines_info=$(echo \"$gcovr_out\" | grep \"lines:\")\n\
    branches_info=$(echo \"$gcovr_out\" | grep \"branches:\")\n\
    l_per=$(echo \"$lines_info\" | awk '{print $2}' | tr -d '%' || echo \"0\")\n\
    l_abs=$(echo \"$lines_info\" | awk '{print $3}' | cut -c2- || echo \"0\")\n\
    b_per=$(echo \"$branches_info\" | awk '{print $2}' | tr -d '%' || echo \"0\")\n\
    b_abs=$(echo \"$branches_info\" | awk '{print $3}' | cut -c2- || echo \"0\")\n\
    if [ -n \"$l_per\" ] && [ \"$l_per\" != \"0\" ]; then\n\
        ts=$(date +%s)\n\
        echo \"$ts,${l_per},${l_abs:-0},${b_per:-0},${b_abs:-0}\" >> \"${GCOVR_CSV}\"\n\
        echo \"[$(date '+%H:%M:%S')] gcovr collection complete: L=${l_per}% B=${b_per}%\"\n\
    else\n\
        echo \"[$(date '+%H:%M:%S')] WARNING: No coverage data generated/found in ${TARGET_SRC}\"\n\
    fi\n\
else\n\
    echo \"[$(date '+%H:%M:%S')] WARNING: Skipping final gcovr (target src missing)\"\n\
fi\n\
\n\
# Print summary\n\
CRASH_COUNT=$(find \"${OUTDIR}/crashes\" -type f 2>/dev/null | wc -l)\n\
EDGE_COUNT=$(tail -1 \"${COV_FILE}\" 2>/dev/null | cut -d',' -f2 | tr -d ' ')\n\
\n\
echo \"\"\n\
echo \"============================================================\"\n\
echo \"MPFuzz Fuzzing Complete\"\n\
echo \"============================================================\"\n\
echo \"  Duration:    ${TIMEOUT}s\"\n\
echo \"  Crashes:     ${CRASH_COUNT}\"\n\
echo \"  Edge count:  ${EDGE_COUNT:-N/A}\"\n\
echo \"  Output:      ${OUTDIR}\"\n\
echo \"  Edge CSV:    ${COV_FILE}\"\n\
echo \"  Gcovr CSV:   ${GCOVR_CSV}\"\n\
echo \"============================================================\"\n\
"
}

/echo "Time,.*GCOVR_CSV/ {
    print "echo \"Time,l_per,l_abs,b_per,b_abs\" > \"${GCOVR_CSV}\""
    next
}

/gcovr_out=.*gcovr -r/ && in_loop==0 && in_p8==0 {
    in_loop=1
    loop=loop_code
    gsub("%TARGET_SRC%", target_src, loop)
    printf "%s", loop
    next
}

/sleep 5/ && in_loop==1 {
    in_loop=0
    next
}

/^echo "\[.*Running final gcovr collection/ && in_p8==0 {
    in_p8=1
    p8=p8_code
    gsub("%TARGET_SRC%", target_src, p8)
    printf "%s", p8
    next
}

in_loop==1 { next }
in_p8==1 { next }

{ print $0 }
