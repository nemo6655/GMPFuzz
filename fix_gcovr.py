import re
import sys

files = [
    '/home/pzst/mqtt_fuzz/GMPFuzz/benchmark/mpfuzz_mqtt/run_mpfuzz.sh',
    '/home/pzst/mqtt_fuzz/GMPFuzz/benchmark/mpfuzz_nanomq/run_mpfuzz.sh',
    '/home/pzst/mqtt_fuzz/GMPFuzz/benchmark/mpfuzz_flashmq/run_mpfuzz.sh'
]

for f in files:
    with open(f, 'r') as fh:
        content = fh.read()

    # Fix header
    content = content.replace('echo "Time,Coverage" > "${GCOVR_CSV}"', 'echo "Time,l_per,l_abs,b_per,b_abs" > "${GCOVR_CSV}"')

    # Fix Phase 3b Extraction block
    # Note: different targets have different paths in the gcovr command, e.g. /home/ubuntu/experiments/nanomq-src/
    # So we'll find the line matching coverage=$(gcovr ...)
    pattern_cov_loop = re.compile(
        r'(coverage=\(gcovr -r (.*?) --gcov-executable "llvm-cov gcov" -s (?:2>/dev/null )?\| grep lines.*?\))\s*'
        r'if \[ ! -z "\$coverage" \]; then\s*'
        r'echo "\$\{elapsed\},\$\{coverage\}" >> "\$\{GCOVR_CSV\}"\s*'
        r'fi', re.DOTALL | re.MULTILINE
    )

    def repl_loop(m):
        target_path = m.group(2)
        return (f'gcovr_out=$(gcovr -r {target_path} --gcov-executable "llvm-cov gcov" -s 2>/dev/null)\n'
                f'        lines_info=$(echo "$gcovr_out" | grep "lines:")\n'
                f'        branches_info=$(echo "$gcovr_out" | grep "branches:")\n'
                f'        l_per=$(echo "$lines_info" | awk \'{{print $2}}\' | tr -d \'%\')\n'
                f'        l_abs=$(echo "$lines_info" | sed -n \'s/.*(\([0-9]*\) out of.*/\\1/p\')\n'
                f'        b_per=$(echo "$branches_info" | awk \'{{print $2}}\' | tr -d \'%\')\n'
                f'        b_abs=$(echo "$branches_info" | sed -n \'s/.*(\([0-9]*\) out of.*/\\1/p\')\n'
                f'        if [ -n "$l_per" ]; then\n'
                f'            echo "${{elapsed}},${{l_per}},${{l_abs:-0}},${{b_per:-0}},${{b_abs:-0}}" >> "${{GCOVR_CSV}}"\n'
                f'        fi')

    content = pattern_cov_loop.sub(repl_loop, content)

    # Fix Phase 8 final collection
    pattern_cov_final = re.compile(
        r'(coverage=\(gcovr -r \$\{TARGET_SRC\} --gcov-executable "llvm-cov gcov" -s 2>/dev/null \| grep lines.*?\))\s*'
        r'if \[ ! -z "\$coverage" \]; then\s*'
        r'ts=\$\(date \+\%s\)\s*'
        r'# Output final coverage point to CSV\s*'
        r'echo "\$ts,\$coverage" >> "\$\{GCOVR_CSV\}"\s*'
        r'echo "\[\$\(date \'\+\%H:\%M:\%S\'\)\] gcovr collection complete: L=\$\{coverage\}\%"', re.DOTALL | re.MULTILINE
    )

    def repl_final(m):
        return (f'gcovr_out=$(gcovr -r ${{TARGET_SRC}} --gcov-executable "llvm-cov gcov" -s 2>/dev/null)\n'
                f'    lines_info=$(echo "$gcovr_out" | grep "lines:")\n'
                f'    branches_info=$(echo "$gcovr_out" | grep "branches:")\n'
                f'    l_per=$(echo "$lines_info" | awk \'{{print $2}}\' | tr -d \'%\')\n'
                f'    l_abs=$(echo "$lines_info" | sed -n \'s/.*(\([0-9]*\) out of.*/\\1/p\')\n'
                f'    b_per=$(echo "$branches_info" | awk \'{{print $2}}\' | tr -d \'%\')\n'
                f'    b_abs=$(echo "$branches_info" | sed -n \'s/.*(\([0-9]*\) out of.*/\\1/p\')\n'
                f'    if [ -n "$l_per" ]; then\n'
                f'        ts=$(date +%s)\n'
                f'        echo "$ts,${{l_per}},${{l_abs:-0}},${{b_per:-0}},${{b_abs:-0}}" >> "${{GCOVR_CSV}}"\n'
                f'        echo "[$(date \'+%H:%M:%S\')] gcovr collection complete: L=${{l_per}}% B=${{b_per}}%"')

    content = pattern_cov_final.sub(repl_final, content)

    with open(f, 'w') as fh:
        fh.write(content)

print("Done modification.")
