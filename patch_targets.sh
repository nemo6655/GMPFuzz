#!/bin/bash
for target in mqtt nanomq flashmq; do
    file="benchmark/mpfuzz_${target}/run_mpfuzz.sh"
    
    # Header
    sed -i 's/echo "Time,Coverage" > "${GCOVR_CSV}"/echo "Time,l_per,l_abs,b_per,b_abs" > "${GCOVR_CSV}"/' "$file"
    
    if [ "$target" = "mqtt" ]; then target_src="/home/ubuntu/experiments/mosquitto-2.0.18"; fi
    if [ "$target" = "nanomq" ]; then target_src="/home/ubuntu/experiments/nanomq-src/"; fi
    if [ "$target" = "flashmq" ]; then target_src="/home/ubuntu/experiments/FlashMQ"; fi

    # Phase 3b
    awk -v t="$target_src" '
    BEGIN { inside=0 }
    /coverage=\$\(gcovr -r .*grep lines/ {
        print "        gcovr_out=$(gcovr -r " t " --gcov-executable \"llvm-cov gcov\" -s 2>/dev/null)"
        print "        lines_info=$(echo \"$gcovr_out\" | grep \"lines:\")"
        print "        branches_info=$(echo \"$gcovr_out\" | grep \"branches:\")"
        print "        l_per=$(echo \"$lines_info\" | awk \047{print $2}\047 | tr -d \042%\042 || echo \"0\")"
        print "        l_abs=$(echo \"$lines_info\" | sed -n \047s/.*(\\([0-9]*\\) out of.*/\\1/p\047 || echo \"0\")"
        print "        b_per=$(echo \"$branches_info\" | awk \047{print $2}\047 | tr -d \042%\042 || echo \"0\")"
        print "        b_abs=$(echo \"$branches_info\" | sed -n \047s/.*(\\([0-9]*\\) out of.*/\\1/p\047 || echo \"0\")"
        print "        if [ -n \"$l_per\" ]; then"
        print "            echo \"${elapsed},${l_per},${l_abs:-0},${b_per:-0},${b_abs:-0}\" >> \"${GCOVR_CSV}\""
        print "        fi"
        inside=1
        next
    }
    /if \[ ! -z "\$coverage" \]; then/ && inside { next }
    /echo "\$\{elapsed\},\$\{coverage\}" >> "\$\{GCOVR_CSV\}"/ && inside { next }
    /fi/ && inside { inside=0; next }
    { print $0 }
    ' "$file" > "${file}.tmp1"
    
    # Phase 8
    awk '
    BEGIN { inside=0 }
    /coverage=\$\(gcovr -r \$\{TARGET_SRC\}.*grep lines/ {
        print "    gcovr_out=$(gcovr -r ${TARGET_SRC} --gcov-executable \"llvm-cov gcov\" -s 2>/dev/null)"
        print "    lines_info=$(echo \"$gcovr_out\" | grep \"lines:\")"
        print "    branches_info=$(echo \"$gcovr_out\" | grep \"branches:\")"
        print "    l_per=$(echo \"$lines_info\" | awk \047{print $2}\047 | tr -d \042%\042 || echo \"0\")"
        print "    l_abs=$(echo \"$lines_info\" | sed -n \047s/.*(\\([0-9]*\\) out of.*/\\1/p\047 || echo \"0\")"
        print "    b_per=$(echo \"$branches_info\" | awk \047{print $2}\047 | tr -d \042%\042 || echo \"0\")"
        print "    b_abs=$(echo \"$branches_info\" | sed -n \047s/.*(\\([0-9]*\\) out of.*/\\1/p\047 || echo \"0\")"
        print "    if [ -n \"$l_per\" ]; then"
        print "        ts=$(date +%s)"
        print "        echo \"$ts,${l_per},${l_abs:-0},${b_per:-0},${b_abs:-0}\" >> \"${GCOVR_CSV}\""
        print "        echo \"[$(date \047+%H:%M:%S\047)] gcovr collection complete: L=${l_per}% B=${b_per}%\""
        inside=1
        next
    }
    /if \[ ! -z "\$coverage" \]; then/ && inside { next }
    /ts=\$\(date \+%s\)/ && inside { next }
    /echo "\$ts,\$coverage" >> "\$\{GCOVR_CSV\}"/ && inside { next }
    /echo "\[.*gcovr collection complete/ && inside { next }
    /else/ && inside { inside=0; print "    else"; next }
    { print $0 }
    ' "${file}.tmp1" > "${file}.tmp2"
    
    mv "${file}.tmp2" "$file"
    rm -f "${file}.tmp1"
    echo "$target done"
done
