import sys

files = [
    ('/home/pzst/mqtt_fuzz/GMPFuzz/benchmark/mpfuzz_mqtt/run_mpfuzz.sh', '/home/ubuntu/experiments/mosquitto-2.0.18'),
    ('/home/pzst/mqtt_fuzz/GMPFuzz/benchmark/mpfuzz_nanomq/run_mpfuzz.sh', '/home/ubuntu/experiments/nanomq-src/'),
    ('/home/pzst/mqtt_fuzz/GMPFuzz/benchmark/mpfuzz_flashmq/run_mpfuzz.sh', '/home/ubuntu/experiments/FlashMQ')
]

for f, target_path in files:
    with open(f, 'r') as fh:
        content = fh.read()

    # Part 1: Phase 3b
    # Target string:
    # coverage=$(gcovr -r {path} --gcov-executable "llvm-cov gcov" -s | grep lines | awk '{print $2}' | tr -d '%')
    # if [ ! -z "$coverage" ]; then
    #     echo "${elapsed},${coverage}" >> "${GCOVR_CSV}"
    # fi
    
    # We will just replace "coverage=$(gcovr -r ... fi" with our code block
    import re
    # We can match from 'coverage=$(gcovr ' to 'fi'
    pattern1 = re.compile(r'coverage=\$\(gcovr -r .*? gcov" -s.*?fi', re.DOTALL)
    
    repl1 = (f'gcovr_out=$(gcovr -r {target_path} --gcov-executable "llvm-cov gcov" -s 2>/dev/null)\n'
             f'        lines_info=$(echo "$gcovr_out" | grep "lines:")\n'
             f'        branches_info=$(echo "$gcovr_out" | grep "branches:")\n'
             f'        l_per=$(echo "$lines_info" | awk \'{{print $2}}\' | tr -d \'%\' || echo "0")\n'
             f'        l_abs=$(echo "$lines_info" | sed -n \'s/.*(\\([0-9]*\\) out of.*/\\1/p\' || echo "0")\n'
             f'        b_per=$(echo "$branches_info" | awk \'{{print $2}}\' | tr -d \'%\' || echo "0")\n'
             f'        b_abs=$(echo "$branches_info" | sed -n \'s/.*(\\([0-9]*\\) out of.*/\\1/p\' || echo "0")\n'
             f'        if [ -n "$l_per" ]; then\n'
             f'            echo "${{elapsed}},${{l_per}},${{l_abs:-0}},${{b_per:-0}},${{b_abs:-0}}" >> "${{GCOVR_CSV}}"\n'
             f'        fi')

    content = pattern1.sub(repl1, content, count=1)

    # Part 2: Phase 8
    pattern2 = re.compile(r'coverage=\$\(gcovr -r \$\{TARGET_SRC\}.*?echo "\[\$\(date.*?\%\s*"?else', re.DOTALL)
    repl2 = (f'gcovr_out=$(gcovr -r ${{TARGET_SRC}} --gcov-executable "llvm-cov gcov" -s 2>/dev/null)\n'
             f'    lines_info=$(echo "$gcovr_out" | grep "lines:")\n'
             f'    branches_info=$(echo "$gcovr_out" | grep "branches:")\n'
             f'    l_per=$(echo "$lines_info" | awk \'{{print $2}}\' | tr -d \'%\' || echo "0")\n'
             f'    l_abs=$(echo "$lines_info" | sed -n \'s/.*(\\([0-9]*\\) out of.*/\\1/p\' || echo "0")\n'
             f'    b_per=$(echo "$branches_info" | awk \'{{print $2}}\' | tr -d \'%\' || echo "0")\n'
             f'    b_abs=$(echo "$branches_info" | sed -n \'s/.*(\\([0-9]*\\) out of.*/\\1/p\' || echo "0")\n'
             f'    if [ -n "$l_per" ]; then\n'
             f'        ts=$(date +%s)\n'
             f'        echo "$ts,${{l_per}},${{l_abs:-0}},${{b_per:-0}},${{b_abs:-0}}" >> "${{GCOVR_CSV}}"\n'
             f'        echo "[$(date \'+%H:%M:%S\')] gcovr collection complete: L=${{l_per}}% B=${{b_per}}%"\n    else')
    
    content = pattern2.sub(repl2, content, count=1)

    with open(f, 'w') as fh:
        fh.write(content)

