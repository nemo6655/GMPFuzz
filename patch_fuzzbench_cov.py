file_path = "/home/pzst/mqtt_fuzz/GMPFuzz/fuzzbench/mosquitto/cov_script.sh"

orig_gcovr_d = "gcovr -r .. -s -d > /dev/null 2>&1"
new_gcovr_d = 'gcovr --gcov-executable "llvm-cov gcov" -r .. --object-directory .. -s -d > /dev/null 2>&1'

orig_block = """  cov_data=$(gcovr -r .. -s | grep "[lb][a-z]*:")
  l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
  l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
  b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
  b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)"""

new_block = """  gcovr_out=$(gcovr --gcov-executable "llvm-cov gcov" -r .. --object-directory .. -s 2>/dev/null)
  lines_info=$(echo "$gcovr_out" | grep "lines:")
  branches_info=$(echo "$gcovr_out" | grep "branches:")
  l_per=$(echo "$lines_info" | awk '{print $2}' | tr -d '%' || echo "0")
  l_abs=$(echo "$lines_info" | sed -n 's/.*(\\([0-9]*\\) out of.*/\\1/p' || echo "0")
  b_per=$(echo "$branches_info" | awk '{print $2}' | tr -d '%' || echo "0")
  b_abs=$(echo "$branches_info" | sed -n 's/.*(\\([0-9]*\\) out of.*/\\1/p' || echo "0")"""

with open(file_path, "r") as f:
    content = f.read()

content = content.replace(orig_gcovr_d, new_gcovr_d)
content = content.replace(orig_block, new_block)

with open(file_path, "w") as f:
    f.write(content)
