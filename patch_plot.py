import re

with open("experiments/plot_results.py", "r") as f:
    content = f.read()

# Patch load_summary_csv
new_load_summary = """def load_summary_csv(results_dir):
    \"\"\"读取 coverage_summary.csv -> { fuzzer: [{'inst': inst, 'edges': edges, 'line_per': line_per, 'branch_per': branch_per}] }\"\"\"
    csv_path = os.path.join(results_dir, "coverage_summary.csv")
    if not os.path.isfile(csv_path):
        return {}
    summary = defaultdict(list)
    import csv
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            fuzzer = row.get("fuzzer", "").strip()
            inst = row.get("instance", "").strip()
            if not fuzzer or fuzzer == "fuzzer":
                continue
            try:
                edges = int(float(row.get("final_edges", "0").strip()))
            except ValueError:
                edges = 0
            
            try:
                l_pStr = row.get("line_percent", "0").replace('%', '').strip()
                line_per = float(l_pStr) if l_pStr and l_pStr != 'N/A' else 0.0
            except ValueError:
                line_per = 0.0
                
            try:
                b_pStr = row.get("branch_percent", "0").replace('%', '').strip()
                branch_per = float(b_pStr) if b_pStr and b_pStr != 'N/A' else 0.0
            except ValueError:
                branch_per = 0.0
                
            summary[fuzzer].append({
                "inst": inst,
                "edges": edges,
                "line_per": line_per,
                "branch_per": branch_per
            })
    return summary"""

content = re.sub(r'def load_summary_csv\(results_dir\):.*?(?=\n\n# ===================================================================)', new_load_summary, content, flags=re.DOTALL)

# Patch plot_bar_mpl edges_list
content = content.replace("edges_list = [e for _, e in summary[fuzzer]]", 'edges_list = [i["edges"] for i in summary[fuzzer]]')

# Patch text_summary
content = content.replace("el = [e for _, e in summary[fuzzer]]", 'el = [i["edges"] for i in summary[fuzzer]]')

# Add plot_gcovr_bar_mpl
new_plot_gcovr = """
def plot_gcovr_bar_mpl(summary, out_path, fmt):
    fig, ax = plt.subplots(figsize=(8, 5))
    bar_labels = []
    line_data = []
    branch_data = []
    for fuzzer in ("aflnet", "gmpfuzz", "mpfuzz", "peach"):
        if fuzzer not in summary:
            continue
        items = summary[fuzzer]
        if not items:
            continue
        
        avg_line = sum(i["line_per"] for i in items) / len(items)
        avg_branch = sum(i["branch_per"] for i in items) / len(items)
        
        line_data.append(avg_line)
        branch_data.append(avg_branch)
        bar_labels.append(f"{LABELS.get(fuzzer, fuzzer)}\\n(n={len(items)})")
        
    if not line_data:
        return
    
    import numpy as np
    x = np.arange(len(bar_labels))
    width = 0.35
    
    bars1 = ax.bar(x - width/2, line_data, width, label='Line Coverage %', color="#5D9CEC", edgecolor="black", linewidth=0.5)
    bars2 = ax.bar(x + width/2, branch_data, width, label='Branch Coverage %', color="#48C9B0", edgecolor="black", linewidth=0.5)
    
    for bar in bars1:
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
                f"{bar.get_height():.1f}%", ha="center", va="bottom", fontsize=10, fontweight="bold")
    for bar in bars2:
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
                f"{bar.get_height():.1f}%", ha="center", va="bottom", fontsize=10, fontweight="bold")
                
    ax.set_ylabel("Coverage (%)", fontsize=12)
    ax.set_title("Gcovr Coverage Comparison", fontsize=14)
    ax.set_xticks(x)
    ax.set_xticklabels(bar_labels)
    ax.legend(fontsize=11)
    ymax = max(max(line_data), max(branch_data))
    ax.set_ylim(0, ymax * 1.2 if ymax > 0 else 100)
    ax.grid(True, axis="y", alpha=0.3)
    
    outfile = os.path.join(out_path, f"gcovr_coverage_bar.{fmt}")
    fig.tight_layout()
    fig.savefig(outfile, dpi=150)
    plt.close(fig)
    print(f"  gcovr 柱状图: {outfile}")

def plot_bar_mpl"""
content = content.replace("def plot_bar_mpl", new_plot_gcovr)

# Add to main
content = content.replace("plot_bar_mpl(summary, plots_dir, args.format)", "plot_bar_mpl(summary, plots_dir, args.format)\n            plot_gcovr_bar_mpl(summary, plots_dir, args.format)")

with open("experiments/plot_results.py", "w") as f:
    f.write(content)
