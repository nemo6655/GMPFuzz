#!/usr/bin/env python3
"""
plot_results.py - 绘制实验结果图表 (统一 edge coverage)

从实验结果目录中读取各 fuzzer 的时序覆盖率数据和汇总数据，
生成 edge coverage 随时间变化曲线 和 最终 edge 数柱状图。

数据来源:
  - AFLNet:       <dir>/aflnet/instance_*/out-*/plot_data   (col 7 = map_size%)
  - GMPFuzz:      <dir>/gmpfuzz/instance_*/edge_coverage.csv
  - MPFuzz:       <dir>/mpfuzz/instance_*/edge_coverage.csv
  - Peach:        <dir>/peach/instance_*/edge_coverage.csv
  - Summary CSV:  <dir>/coverage_summary.csv  (由 collect_coverage.sh 生成)

用法:
  python3 experiments/plot_results.py <results_dir>
  python3 experiments/plot_results.py experiments/results_mqtt_24h

可选参数:
  --no-show       不弹出窗口，只保存文件
  --format FMT    图片格式: png (默认), pdf, svg
"""

import argparse
import csv
import glob
import os
import sys
from collections import defaultdict

# ---------------------------------------------------------------------------
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    HAS_MPL = True
except ImportError:
    HAS_MPL = False

COLORS = {
    "aflnet":  "#1f77b4",
    "gmpfuzz": "#d62728",
    "mpfuzz":  "#2ca02c",
    "peach":   "#ff7f0e",
}
LABELS = {
    "aflnet":  "AFLNet",
    "gmpfuzz": "GMPFuzz",
    "mpfuzz":  "MPFuzz",
    "peach":   "Peach",
}
MAP_SIZE = 65536


# ===================================================================
# 数据加载
# ===================================================================
def load_aflnet_plot_data(filepath):
    """解析 AFLNet plot_data -> [(elapsed_h, edge_count), ...]"""
    rows = []
    t0 = None
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 7:
                continue
            try:
                ts = int(parts[0])
                pct = float(parts[6].replace("%", "").strip())
                edges = int(pct * MAP_SIZE / 100)
            except (ValueError, IndexError):
                continue
            if t0 is None:
                t0 = ts
            rows.append(((ts - t0) / 3600.0, edges))
    return rows


def load_edge_csv(filepath):
    """解析 edge_coverage.csv -> [(elapsed_h, edge_count), ...]"""
    rows = []
    t0 = None
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) < 2:
                continue
            try:
                ts = int(parts[0])
                edges = int(parts[1])
            except ValueError:
                continue
            if t0 is None:
                t0 = ts
            rows.append(((ts - t0) / 3600.0, edges))
    return rows


def find_timeseries(results_dir):
    """扫描结果目录 -> { fuzzer: { inst_id: [(h, edges)] } }"""
    data = defaultdict(dict)
    for fuzzer in ("aflnet", "gmpfuzz", "mpfuzz", "peach"):
        fdir = os.path.join(results_dir, fuzzer)
        if not os.path.isdir(fdir):
            continue
        for inst in sorted(glob.glob(os.path.join(fdir, "instance_*"))):
            idx = os.path.basename(inst).replace("instance_", "")
            if fuzzer == "aflnet":
                pds = glob.glob(os.path.join(inst, "**/plot_data"), recursive=True)
                if pds:
                    ts = load_aflnet_plot_data(pds[0])
                    if ts:
                        data[fuzzer][idx] = ts
            else:
                csvs = glob.glob(os.path.join(inst, "**/edge_coverage.csv"), recursive=True)
                if csvs:
                    ts = load_edge_csv(csvs[0])
                    if ts:
                        data[fuzzer][idx] = ts
    return data


def load_summary_csv(results_dir):
    """读取 coverage_summary.csv -> { fuzzer: [(inst, edges)] }"""
    csv_path = os.path.join(results_dir, "coverage_summary.csv")
    if not os.path.isfile(csv_path):
        return {}
    summary = defaultdict(list)
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            fuzzer = row.get("fuzzer", "").strip()
            inst = row.get("instance", "").strip()
            try:
                edges = int(float(row.get("final_edges", "0").strip()))
            except ValueError:
                edges = 0
            summary[fuzzer].append((inst, edges))
    return summary


# ===================================================================
# matplotlib 绘图
# ===================================================================
def plot_timeseries_mpl(data, out_path, fmt):
    fig, ax = plt.subplots(figsize=(10, 6))
    for fuzzer in ("aflnet", "gmpfuzz", "mpfuzz", "peach"):
        if fuzzer not in data:
            continue
        instances = data[fuzzer]
        for idx, ts in sorted(instances.items()):
            h = [p[0] for p in ts]
            e = [p[1] for p in ts]
            ax.plot(h, e, color=COLORS.get(fuzzer, "gray"), alpha=0.25, linewidth=0.8)
        # 第一个实例作为代表（粗线+标签）
        first = sorted(instances.items())[0][1]
        ax.plot([p[0] for p in first], [p[1] for p in first],
                color=COLORS.get(fuzzer, "gray"), linewidth=2,
                label=LABELS.get(fuzzer, fuzzer))
    ax.set_xlabel("Time (hours)", fontsize=12)
    ax.set_ylabel("Edge Coverage (bitmap edges)", fontsize=12)
    ax.set_title("Edge Coverage Over Time", fontsize=14)
    ax.legend(fontsize=11)
    ax.grid(True, alpha=0.3)
    outfile = os.path.join(out_path, f"edge_coverage_over_time.{fmt}")
    fig.tight_layout()
    fig.savefig(outfile, dpi=150)
    plt.close(fig)
    print(f"  时序图: {outfile}")


def plot_bar_mpl(summary, out_path, fmt):
    fig, ax = plt.subplots(figsize=(8, 5))
    bar_data, bar_labels, bar_colors = [], [], []
    for fuzzer in ("aflnet", "gmpfuzz", "mpfuzz", "peach"):
        if fuzzer not in summary:
            continue
        edges_list = [e for _, e in summary[fuzzer]]
        if not edges_list:
            continue
        avg = sum(edges_list) / len(edges_list)
        bar_data.append(avg)
        bar_labels.append(f"{LABELS.get(fuzzer, fuzzer)}\n(n={len(edges_list)})")
        bar_colors.append(COLORS.get(fuzzer, "gray"))
    if not bar_data:
        return
    bars = ax.bar(bar_labels, bar_data, color=bar_colors, edgecolor="black", linewidth=0.5)
    for bar, val in zip(bars, bar_data):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 20,
                f"{int(val)}", ha="center", va="bottom", fontsize=11, fontweight="bold")
    ax.set_ylabel("Final Edge Count (avg)", fontsize=12)
    ax.set_title("Final Edge Coverage Comparison", fontsize=14)
    ax.grid(True, axis="y", alpha=0.3)
    outfile = os.path.join(out_path, f"edge_coverage_bar.{fmt}")
    fig.tight_layout()
    fig.savefig(outfile, dpi=150)
    plt.close(fig)
    print(f"  柱状图: {outfile}")


# ===================================================================
# 纯文本回退
# ===================================================================
def text_summary(data, summary, out_path):
    outfile = os.path.join(out_path, "coverage_report.txt")
    lines = ["=" * 60, "  Edge Coverage Report (text mode)", "=" * 60, ""]
    if summary:
        lines.append("Final Edge Coverage:")
        lines.append(f"  {'Fuzzer':<10} {'Inst':<6} {'Avg':<10} {'Max':<10}")
        lines.append("  " + "-" * 36)
        for fuzzer in ("aflnet", "gmpfuzz", "mpfuzz", "peach"):
            if fuzzer not in summary:
                continue
            el = [e for _, e in summary[fuzzer]]
            avg = sum(el) / len(el) if el else 0
            mx = max(el) if el else 0
            lines.append(f"  {LABELS.get(fuzzer, fuzzer):<10} {len(el):<6} {avg:<10.0f} {mx:<10}")
    if data:
        lines.append("")
        lines.append("Time Series:")
        for fuzzer in ("aflnet", "gmpfuzz", "mpfuzz", "peach"):
            if fuzzer not in data:
                continue
            for idx, ts in sorted(data[fuzzer].items()):
                if ts:
                    lines.append(f"  {LABELS.get(fuzzer,fuzzer)} #{idx}: "
                                 f"{len(ts)} pts, {ts[-1][0]:.1f}h, final={ts[-1][1]}")
    lines += ["", "=" * 60, "提示: pip install matplotlib 可生成图表", "=" * 60]
    text = "\n".join(lines)
    with open(outfile, "w") as f:
        f.write(text + "\n")
    print(text)
    print(f"\n  报告: {outfile}")


# ===================================================================
def main():
    parser = argparse.ArgumentParser(description="绘制 edge coverage 实验结果")
    parser.add_argument("results_dir", help="实验结果目录")
    parser.add_argument("--no-show", action="store_true")
    parser.add_argument("--format", default="png", choices=["png", "pdf", "svg"])
    args = parser.parse_args()
    if not os.path.isdir(args.results_dir):
        print(f"ERROR: {args.results_dir} 不存在"); sys.exit(1)
    print(f"扫描: {args.results_dir}")
    data = find_timeseries(args.results_dir)
    summary = load_summary_csv(args.results_dir)
    if not data and not summary:
        print("未找到覆盖率数据。先运行 collect_coverage.sh"); sys.exit(1)
    plots_dir = os.path.join(args.results_dir, "plots")
    os.makedirs(plots_dir, exist_ok=True)
    if HAS_MPL:
        print(f"matplotlib 输出 -> {plots_dir}/")
        if data:
            plot_timeseries_mpl(data, plots_dir, args.format)
        if summary:
            plot_bar_mpl(summary, plots_dir, args.format)
        print("完成!")
    else:
        print("无 matplotlib，输出文本报告")
        text_summary(data, summary, plots_dir)

if __name__ == "__main__":
    main()
