import re

files = [
    ('benchmark/mpfuzz_mqtt/run_mpfuzz.sh', '/home/ubuntu/experiments/mosquitto-2.0.18', 'mosquitto'),
    ('benchmark/mpfuzz_nanomq/run_mpfuzz.sh', '/home/ubuntu/experiments/nanomq-src/', 'nanomq'),
    ('benchmark/mpfuzz_flashmq/run_mpfuzz.sh', '/home/ubuntu/experiments/FlashMQ', 'flashmq')
]

for f, src, target in files:
    with open(f, 'r') as fh:
        text = fh.read()
    
    # Header
    text = re.sub(r'echo "Time,Coverage" > "\$\{GCOVR_CSV\}"', 'echo "Time,l_per,l_abs,b_per,b_abs" > "${GCOVR_CSV}"', text)
    
    # Phase 3b block: from `        # NOTE:` to `        sleep 5`
    p3b = re.compile(r'        # NOTE: Using llvm-cov gcov.*?sleep 5\n', re.DOTALL)
    r3b = f"""        # NOTE: extracting both line and branch coverage
        gcovr_out=$(gcovr -r {src} --gcov-executable "llvm-cov gcov" -s 2>/dev/null)
        lines_info=$(echo "$gcovr_out" | grep "lines:")
        branches_info=$(echo "$gcovr_out" | grep "branches:")
        l_per=$(echo "$lines_info" | awk '{{print $2}}' | tr -d "%" | awk '{{print $1}}')
        l_abs=$(echo "$lines_info" | awk -F'(' '{{print $2}}' | awk '{{print $1}}')
        b_per=$(echo "$branches_info" | awk '{{print $2}}' | tr -d "%" | awk '{{print $1}}')
        b_abs=$(echo "$branches_info" | awk -F'(' '{{print $2}}' | awk '{{print $1}}')
        if [ -n "$l_per" ] && [ "$l_per" != "0" ]; then
            echo "${{elapsed}},${{l_per}},${{l_abs:-0}},${{b_per:-0}},${{b_abs:-0}}" >> "${{GCOVR_CSV}}"
        fi
        
        sleep 5\n"""
    text = p3b.sub(r3b, text, count=1)
    
    # Phase 8 block: from `# Use llvm-cov gcov` to `echo "\$ts,\$coverage"`
    # Wait, my previous mess-up left duplicate phase 8 in nanomq! Let's clean it aggressively:
    # Look for "Running final gcovr collection..." and replace everything until "# ============================================================\n# Print summary"
    
    p8 = re.compile(r'# 8\. Collect final gcovr coverage directly from target.*?# ============================================================\n# Print summary', re.DOTALL)
    r8 = f"""# 8. Collect final gcovr coverage directly from target
# ============================================================
echo "[$(date '+%H:%M:%S')] Running final gcovr collection..."
TARGET_SRC="{src}"
if [ -d "${{TARGET_SRC}}" ]; then
    cd "${{TARGET_SRC}}"
    # flashmq and others may be in build-instr
    if [ -d "build-instr" ]; then cd "build-instr"; fi
    
    echo "[$(date '+%H:%M:%S')] Collecting gcov from: ${{TARGET_SRC}}"
    
    gcovr_out=$(gcovr -r ${{TARGET_SRC}} --gcov-executable "llvm-cov gcov" -s 2>/dev/null)
    lines_info=$(echo "$gcovr_out" | grep "lines:")
    branches_info=$(echo "$gcovr_out" | grep "branches:")
    l_per=$(echo "$lines_info" | awk '{{print $2}}' | tr -d "%" | awk '{{print $1}}')
    l_abs=$(echo "$lines_info" | awk -F'(' '{{print $2}}' | awk '{{print $1}}')
    b_per=$(echo "$branches_info" | awk '{{print $2}}' | tr -d "%" | awk '{{print $1}}')
    b_abs=$(echo "$branches_info" | awk -F'(' '{{print $2}}' | awk '{{print $1}}')
    
    if [ -n "$l_per" ]; then
        ts=$(date +%s)
        echo "$ts,${{l_per}},${{l_abs:-0}},${{b_per:-0}},${{b_abs:-0}}" >> "${{GCOVR_CSV}}"
        echo "[$(date '+%H:%M:%S')] gcovr collection complete: L=${{l_per}}% B=${{b_per}}%"
    else
        echo "[$(date '+%H:%M:%S')] WARNING: No coverage data generated/found in ${{TARGET_SRC}}"
    fi
else
    echo "[$(date '+%H:%M:%S')] WARNING: Skipping final gcovr (target src missing)"
fi

# ============================================================
# Print summary"""

    text = p8.sub(r8, text, count=1)
    
    with open(f, 'w') as fh:
        fh.write(text)

