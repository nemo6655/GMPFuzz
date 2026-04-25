import os
import sys
import glob
import pandas as pd
import matplotlib.pyplot as plt

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 plot_ablation.py <target> <result_dir1> <result_dir2> ...")
        sys.exit(1)

    target = sys.argv[1]
    dirs = sys.argv[2:]

    # Prepare data structures
    edge_data = {}
    gcovr_data = []

    for d in dirs:
        # Extract mode from directory name, assuming format: evaluation/gmpfuzz_<target>_ablation_<timestamp>_<mode>
        # or simple ablation_<mode>
        parts = d.split('_')
        mode = parts[-1] if not parts[-1].isdigit() else parts[-2]
        
        edge_file = os.path.join(d, "edge_coverage.csv")
        if os.path.exists(edge_file):
            try:
                df_edge = pd.read_csv(edge_file)
                if not df_edge.empty:
                    # Normalize time to hours
                    t0 = df_edge['timestamp'].iloc[0]
                    df_edge['hours'] = (df_edge['timestamp'] - t0) / 3600.0
                    edge_data[mode] = df_edge
            except Exception as e:
                print(f"Error reading {edge_file}: {e}")

        gcov_file = os.path.join(d, "gcovr_coverage.csv")
        if os.path.exists(gcov_file):
            try:
                df_gcov = pd.read_csv(gcov_file)
                if not df_gcov.empty:
                    last_row = df_gcov.iloc[-1]
                    gcovr_data.append({
                        "Mode": mode,
                        "Line (%)": last_row.get("line_percent", 0),
                        "Branch (%)": last_row.get("branch_percent", 0)
                    })
            except Exception as e:
                print(f"Error reading {gcov_file}: {e}")

    # Plot Edge Coverage over Time
    if edge_data:
        plt.figure(figsize=(10, 6))
        
        # Calculate global max hours for flatline
        max_h = max([df['hours'].max() for df in edge_data.values() if not df.empty])
        
        for mode, df in edge_data.items():
            if df.empty: continue
            h = list(df['hours'])
            e = list(df['edge_count'])
            if h[-1] < max_h:
                h.append(max_h)
                e.append(e[-1])
            plt.plot(h, e, label=mode, linewidth=2)
            
        plt.title(f"Ablation Edge Coverage Over Time - {target.capitalize()}")
        plt.xlabel("Time (Hours)")
        plt.ylabel("Edge Count (Bitmap)")
        plt.legend()
        plt.grid(True)
        out_pdf = f"ablation_edge_{target}.pdf"
        plt.savefig(out_pdf, format='pdf', bbox_inches='tight')
        plt.close()
        print(f"Saved edge coverage plot to {out_pdf}")

    # Output Summary Table and Bar Chart
    if gcovr_data:
        df_summary = pd.DataFrame(gcovr_data).sort_values(by="Line (%)", ascending=False)
        out_csv = f"ablation_summary_{target}.csv"
        df_summary.to_csv(out_csv, index=False)
        print(f"\nCoverage Summary for {target}:")
        print(df_summary.to_string(index=False))
        print(f"Saved summary to {out_csv}")
        
        # Plot Bar Chart
        df_summary.plot(x="Mode", y=["Line (%)", "Branch (%)"], kind="bar", figsize=(10, 6))
        plt.title(f"Ablation Gcovr Coverage - {target.capitalize()}")
        plt.ylabel("Coverage (%)")
        plt.xticks(rotation=45)
        plt.grid(axis='y')
        out_bar = f"ablation_gcovr_{target}.pdf"
        plt.savefig(out_bar, format='pdf', bbox_inches='tight')
        plt.close()
        print(f"Saved gcovr plot to {out_bar}")

if __name__ == "__main__":
    main()
