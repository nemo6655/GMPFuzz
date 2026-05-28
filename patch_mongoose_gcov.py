import re

file_path = '/home/pzst/mqtt_fuzz/GMPFuzz/benchmark/mpfuzz_mongoose/run_mpfuzz.sh'

with open(file_path, 'r') as fh:
    content = fh.read()

# Replace part 3b tcpdump with dual-compile and periodic gcovr
pattern_tcpdump = re.compile(
    r'# ============================================================\n'
    r'# 3b\. Start tcpdump to capture traffic for gcovr replay\n'
    r'# ============================================================\n'
    r'PCAP_FILE="\$\{OUTDIR\}/traffic\.pcap"\n'
    r'tcpdump -i lo -w "\$\{PCAP_FILE\}" tcp port 1883 > /dev/null 2>&1 &\n'
    r'TCPDUMP_PID=\$!\n'
    r'echo "  tcpdump PID: \$\{TCPDUMP_PID\}"\n'
)

replacement_3b = '''# ============================================================
# 3b. Build double-instrumented binary inside target directory
# ============================================================
TARGET_SRC="/home/ubuntu/experiments/mongoose-instr"
GCOVR_ROOT="/home/ubuntu/experiments/mongoose-instr"

echo "[$(date '+%H:%M:%S')] Re-compiling mongoose-instr with double instrumentation (AFL + gcov)..."
(
    cd "${GCOVR_ROOT}"
    rm -f mqtt_broker > /dev/null 2>&1
    /home/ubuntu/mpfuzz-compiler/MPFuzz-clang-fast \\
        -W -Wall -Wextra -g -O2 -fprofile-arcs -ftest-coverage --coverage \\
        -DMG_ENABLE_LINES \\
        -o mqtt_broker \\
        main.c mongoose.c > /dev/null 2>&1
)
echo "[$(date '+%H:%M:%S')] Dual instrumentation build complete."

# ============================================================
# 3c. Start periodic gcovr collection
# ============================================================
GCOVR_CSV="$(cd "${OUTDIR}" && pwd)/cov_over_time.csv"
(
  echo "Time,l_per,l_abs,b_per,b_abs" > "${GCOVR_CSV}"
  TARGET_SRC="/home/ubuntu/experiments/mongoose-instr"
  GCOVR_ROOT="/home/ubuntu/experiments/mongoose-instr"

  if [ -z "$(find ${GCOVR_ROOT} -name '*.gcno' 2>/dev/null | head -n 1)" ]; then
      TARGET_SRC="/home/ubuntu/experiments/mongoose-gcov"
      GCOVR_ROOT="/home/ubuntu/experiments/mongoose-gcov"
  fi
  
  while true; do
      sleep 60
      if [ -d "${TARGET_SRC}" ]; then
          cd "${TARGET_SRC}"
          ts=$(date +%s)
          gcovr_out=$(gcovr --gcov-executable "llvm-cov gcov" -r ${TARGET_SRC} --object-directory ${GCOVR_ROOT} -s 2>/dev/null)
          if [ -n "$gcovr_out" ]; then
              lines_info=$(echo "$gcovr_out" | grep "lines:")
              branches_info=$(echo "$gcovr_out" | grep "branches:")
              l_per=$(echo "$lines_info" | awk '{print $2}' | tr -d '%' || echo "0")
              l_abs=$(echo "$lines_info" | sed -n 's/.*\\([0-9]*\\) out of.*/\\1/p' || echo "0")
              b_per=$(echo "$branches_info" | awk '{print $2}' | tr -d '%' || echo "0")
              b_abs=$(echo "$branches_info" | sed -n 's/.*\\([0-9]*\\) out of.*/\\1/p' || echo "0")
              
              if [ -n "$l_per" ]; then
                  echo "$ts,$l_per,$l_abs,$b_per,$b_abs" >> "${GCOVR_CSV}"
              else
                  echo "$ts,0.0,0,0.0,0" >> "${GCOVR_CSV}"
              fi
          else
              echo "$ts,0.0,0,0.0,0" >> "${GCOVR_CSV}"
          fi
      fi
  done
) &
GCOVR_PID=$!
echo "  Periodic gcovr collection PID: ${GCOVR_PID} (target=${TARGET_SRC})"
'''

content = pattern_tcpdump.sub(replacement_3b, content)

# Replace cleanup (tcpdump -> gcovr)
pattern_cleanup = re.compile(
    r'# Stop tcpdump\n'
    r'kill \$TCPDUMP_PID 2>/dev/null\n'
    r'wait \$TCPDUMP_PID 2>/dev/null \|\| true\n'
    r'echo "\[\$\(date \'\+\%H:\%M:\%S\'\)\] tcpdump stopped, pcap: \$\{PCAP_FILE\}"\n'
)

replacement_cleanup = '''# Stop periodic gcovr
kill $GCOVR_PID 2>/dev/null
wait $GCOVR_PID 2>/dev/null || true
echo "[$(date '+%H:%M:%S')] Periodic gcovr sampler stopped."
'''

content = pattern_cleanup.sub(replacement_cleanup, content)

# Replace part 8 pcap replay with final gcovr collection
pattern_8 = re.compile(
    r'# ============================================================\n'
    r'# 8\. Collect gcovr coverage by replaying pcap\n'
    r'# ============================================================\n'
    r'GCOVR_CSV="\$\{OUTDIR\}/cov_over_time\.csv"\n'
    r'if \[ -f "\$\{PCAP_FILE\}" \] && \[ -x "\$\{WORKDIR\}/cov_script" \]; then\n'
    r'    echo "\[\$\(date \'\+\%H:\%M:\%S\'\)\] Running gcovr coverage collection\.\.\."\n'
    r'    bash "\$\{WORKDIR\}/cov_script" "\$\{PCAP_FILE\}" 1883 5 "\$\{GCOVR_CSV\}" 1\n'
    r'    echo "\[\$\(date \'\+\%H:\%M:\%S\'\)\] gcovr collection complete: \$\{GCOVR_CSV\}"\n'
    r'else\n'
    r'    echo "\[\$\(date \'\+\%H:\%M:\%S\'\)\] WARNING: Skipping gcovr \(pcap or cov_script missing\)"\n'
    r'fi\n'
)

replacement_8 = '''# ============================================================
# 8. Collect final gcovr coverage directly from target
# ============================================================
echo "[$(date '+%H:%M:%S')] Running final gcovr collection..."
TARGET_SRC="/home/ubuntu/experiments/mongoose-instr"
GCOVR_ROOT="/home/ubuntu/experiments/mongoose-instr"

if [ -z "$(find ${GCOVR_ROOT} -name '*.gcno' 2>/dev/null | head -n 1)" ]; then
    TARGET_SRC="/home/ubuntu/experiments/mongoose-gcov"
    GCOVR_ROOT="/home/ubuntu/experiments/mongoose-gcov"
fi

if [ -d "${TARGET_SRC}" ]; then
    cd "${TARGET_SRC}"
    echo "[$(date '+%H:%M:%S')] Collecting gcov from: ${TARGET_SRC}"
    gcovr_out=$(gcovr --gcov-executable "llvm-cov gcov" -r ${TARGET_SRC} --object-directory ${GCOVR_ROOT} -s 2>/dev/null)
    
    if [ -n "$gcovr_out" ]; then
        lines_info=$(echo "$gcovr_out" | grep "lines:")
        branches_info=$(echo "$gcovr_out" | grep "branches:")
        l_per=$(echo "$lines_info" | awk '{print $2}' | tr -d '%' || echo "0")
        l_abs=$(echo "$lines_info" | sed -n 's/.*\\([0-9]*\\) out of.*/\\1/p' || echo "0")
        b_per=$(echo "$branches_info" | awk '{print $2}' | tr -d '%' || echo "0")
        b_abs=$(echo "$branches_info" | sed -n 's/.*\\([0-9]*\\) out of.*/\\1/p' || echo "0")
        
        if [ -n "$l_per" ]; then
            ts=$(date +%s)
            echo "$ts,$l_per,$l_abs,$b_per,$b_abs" >> "${GCOVR_CSV}"
            echo "[$(date '+%H:%M:%S')] gcovr collection complete: L=${l_per}% B=${b_per}%"
        else
            echo "[$(date '+%H:%M:%S')] WARNING: No coverage extractable in ${TARGET_SRC}"
            echo "$(date +%s),0.0,0,0.0,0" >> "${GCOVR_CSV}"
        fi
    else
        echo "[$(date '+%H:%M:%S')] WARNING: No coverage data generated/found in ${TARGET_SRC}"
        echo "$(date +%s),0.0,0,0.0,0" >> "${GCOVR_CSV}"
    fi
else
    echo "[$(date '+%H:%M:%S')] WARNING: Skipping final gcovr (target src missing)"
fi
'''

content = pattern_8.sub(replacement_8, content)

with open(file_path, 'w') as fh:
    fh.write(content)

print("Mongoose run_mpfuzz patched.")
