#!/bin/bash
set -e
cd /home/pzst/mqtt_fuzz/GMPFuzz

RESULTS_DIR="/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/results_20260502_022943"

echo "[1/4] 清理上次失败留下的残留..."
rm -rf "${RESULTS_DIR}/gmpfuzz/instance_1"
rm -rf "/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/gmpfuzz_mongoose_101"
rm -rf "preset/mongoose/gen"* "preset/mongoose/ase_state.json" "preset/mongoose/stamps" "preset/mongoose/initial"

echo "[2/4] 正在重新拉起针对 mongoose 的 GMPFuzz 测试，包含最终的 gcovr 采集..."
bash experiments/run_gmpfuzz_bench.sh -t mongoose -o "${RESULTS_DIR}/gmpfuzz"

echo "[3/4] 测试完成，重新收集所有工具的数据并统计覆盖率..."
bash experiments/collect_coverage.sh "${RESULTS_DIR}"

echo "[4/4] 最终重绘完整的对比图表..."
python3 experiments/plot_results.py "${RESULTS_DIR}"

echo "================ 全流程完成 ================"
