import re

files = [
    '/home/pzst/mqtt_fuzz/GMPFuzz/benchmark/mpfuzz_mosquitto/run_mpfuzz.sh'
]

for f in files:
    with open(f, 'r') as fh:
        content = fh.read()

    # Replace part 1
    pattern_cov_loop = re.compile(
        r'cov_data=\$\(gcovr --gcov-executable "llvm-cov gcov" -r \$\{TARGET_SRC\}/\.\. .*? \| grep "\^\[a-z\]\*:"\)\s*'
        r'if \[ ! -z "\$cov_data" \]; then\s*'
        r'l_per=\$\(echo "\$cov_data" \| grep lines \| cut -d" " -f2 \| rev \| cut -c2- \| rev\)\s*'
        r'l_abs=\$\(echo "\$cov_data" \| grep lines \| cut -d" " -f3 \| cut -c2-\)\s*'
        r'b_per=\$\(echo "\$cov_data" \| grep branch \| cut -d" " -f2 \| rev \| cut -c2- \| rev\)\s*'
        r'b_abs=\$\(echo "\$cov_data" \| grep branch \| cut -d" " -f3 \| cut -c2-\)\s*'
        r'echo "\$ts,\$l_per,\$l_abs,\$b_per,\$b_abs" >> "\$\{GCOVR_CSV\}"\s*'
        r'else\s*'
        r'# Even if no new coverage yet, output 0 to keep time series aligned\s*'
        r'echo "\$ts,0\.0,0,0\.0,0" >> "\$\{GCOVR_CSV\}"\s*'
        r'fi', re.DOTALL | re.MULTILINE
    )

    def repl_loop(m):
        return (f'gcovr_out=$(gcovr --gcov-executable "llvm-cov gcov" -r ${{TARGET_SRC}}/.. --object-directory ${{GCOVR_ROOT}} -s 2>/dev/null)\n'
                f'          lines_info=$(echo "$gcovr_out" | grep "lines:")\n'
                f'          branches_info=$(echo "$gcovr_out" | grep "branches:")\n'
                f'          l_per=$(echo "$lines_info" | awk \'{{print $2}}\' | tr -d \'%\' || echo "0")\n'
                f'          l_abs=$(echo "$lines_info" | sed -n \'s/.*(\\([0-9]*\\) out of.*/\\1/p\' || echo "0")\n'
                f'          b_per=$(echo "$branches_info" | awk \'{{print $2}}\' | tr -d \'%\' || echo "0")\n'
                f'          b_abs=$(echo "$branches_info" | sed -n \'s/.*(\\([0-9]*\\) out of.*/\\1/p\' || echo "0")\n'
                f'          if [ -n "$l_per" ]; then\n'
                f'              echo "$ts,$l_per,$l_abs,$b_per,$b_abs" >> "${{GCOVR_CSV}}"\n'
                f'          else\n'
                f'              echo "$ts,0.0,0,0.0,0" >> "${{GCOVR_CSV}}"\n'
                f'          fi')

    content = pattern_cov_loop.sub(repl_loop, content)

    # replace part 2
    pattern_cov_final = re.compile(
        r'cov_data=\$\(gcovr --gcov-executable "llvm-cov gcov" -r \$\{TARGET_SRC\}/\.\. .*? \| grep "\^\[a-z\]\*:"\)\s*'
        r'if \[ ! -z "\$cov_data" \]; then\s*'
        r'ts=\$\(date \+\%s\)\s*'
        r'l_per=\$\(echo "\$cov_data" \| grep lines \| cut -d" " -f2 \| rev \| cut -c2- \| rev\)\s*'
        r'l_abs=\$\(echo "\$cov_data" \| grep lines \| cut -d" " -f3 \| cut -c2-\)\s*'
        r'b_per=\$\(echo "\$cov_data" \| grep branch \| cut -d" " -f2 \| rev \| cut -c2- \| rev\)\s*'
        r'b_abs=\$\(echo "\$cov_data" \| grep branch \| cut -d" " -f3 \| cut -c2-\)\s*'
        r'# Output final coverage point to CSV so analyze_cov\.py/summary scripts can read it\s*'
        r'echo "\$ts,\$l_per,\$l_abs,\$b_per,\$b_abs" >> "\$\{GCOVR_CSV\}"\s*'
        r'echo "\[\$\(date \'\+\%H:\%M:\%S\'\)\] gcovr collection complete: L=\$\{l_per\}\% B=\$\{b_per\}\%"\s*'
        r'else\s*'
        r'echo "\[\$\(date \'\+\%H:\%M:\%S\'\)\] WARNING: No coverage data generated\/found in \$\{TARGET_SRC\}"\s*'
        r'# Fallback empty coverage\s*'
        r'echo "\$\(date \+\%s\),0\.0,0,0\.0,0" >> "\$\{GCOVR_CSV\}"\s*'
        r'fi', re.DOTALL | re.MULTILINE
    )

    def repl_final(m):
        return (f'gcovr_out=$(gcovr --gcov-executable "llvm-cov gcov" -r ${{TARGET_SRC}}/.. --object-directory ${{GCOVR_ROOT}} -s 2>/dev/null)\n'
                f'    lines_info=$(echo "$gcovr_out" | grep "lines:")\n'
                f'    branches_info=$(echo "$gcovr_out" | grep "branches:")\n'
                f'    l_per=$(echo "$lines_info" | awk \'{{print $2}}\' | tr -d \'%\' || echo "0")\n'
                f'    l_abs=$(echo "$lines_info" | sed -n \'s/.*(\\([0-9]*\\) out of.*/\\1/p\' || echo "0")\n'
                f'    b_per=$(echo "$branches_info" | awk \'{{print $2}}\' | tr -d \'%\' || echo "0")\n'
                f'    b_abs=$(echo "$branches_info" | sed -n \'s/.*(\\([0-9]*\\) out of.*/\\1/p\' || echo "0")\n'
                f'    if [ -n "$l_per" ]; then\n'
                f'        ts=$(date +%s)\n'
                f'        echo "$ts,$l_per,$l_abs,$b_per,$b_abs" >> "${{GCOVR_CSV}}"\n'
                f'        echo "[$(date \'+%H:%M:%S\')] gcovr collection complete: L=${{l_per}}% B=${{b_per}}%"\n'
                f'    else\n'
                f'        echo "[$(date \'+%H:%M:%S\')] WARNING: No coverage data generated/found in ${{TARGET_SRC}}"\n'
                f'        echo "$(date +%s),0.0,0,0.0,0" >> "${{GCOVR_CSV}}"\n'
                f'    fi')
    
    content = pattern_cov_final.sub(repl_final, content)

    with open(f, 'w') as fh:
        fh.write(content)

