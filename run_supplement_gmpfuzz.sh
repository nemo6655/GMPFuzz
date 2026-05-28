#!/bin/bash
set -x

WORKDIR="/home/pzst/mqtt_fuzz/GMPFuzz"
RESULT_DIR="${WORKDIR}/evaluation/results_20260502_022943"

cd $WORKDIR
source .venv/bin/activate || true

# 1. 运行 GMPFuzz (自动提取覆盖率已经在 run_gmpfuzz_bench.sh 中修复完毕)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 正在开始补充 GMPFuzz 的 Mongoose 实验..."
bash experiments/run_gmpfuzz_bench.sh -t mongoose -o "${RESULT_DIR}/gmpfuzz"

# 2. 从新生成的数据中提取统一覆盖率数据并追加/更新 coverage_summary.csv
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 重新收录并合并所有覆盖率数据..."
bash experiments/collect_coverage.sh -t mongoose "${RESULT_DIR}"

# 3. 再次调用绘图脚本，将包括 GMPFuzz 在内的四种工具的结果绘制在一起
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 正在重新绘制横向对比图表..."
python3 experiments/plot_results.py "${RESULT_DIR}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 补充实验与统计全部完成。"
