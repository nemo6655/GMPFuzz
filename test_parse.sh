gcovr_out="lines: 15.1% (1234 out of 8172)
branches: 10.2% (567 out of 5555)"
lines_info=$(echo "$gcovr_out" | grep "lines:")
l_per=$(echo "$lines_info" | awk '{print $2}' | tr -d '%')
l_abs=$(echo "$lines_info" | awk -F'(' '{print $2}' | awk '{print $1}')
branches_info=$(echo "$gcovr_out" | grep "branches:")
b_per=$(echo "$branches_info" | awk '{print $2}' | tr -d '%')
b_abs=$(echo "$branches_info" | awk -F'(' '{print $2}' | awk '{print $1}')
echo "Time,l_per,l_abs,b_per,b_abs"
echo "12345,${l_per},${l_abs:-0},${b_per},${b_abs:-0}"
