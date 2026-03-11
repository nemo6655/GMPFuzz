#!/usr/bin/env python3
"""Generate simple plots or summaries from experiment results.

This script is intentionally lightweight: it reads the
"coverage_summary.csv" file produced by the run_experiment.sh driver
and emits a few diagnostic plots (one per column) into the
`<output_dir>/plots/` directory.  It uses the ``plotext`` text-
plotting library (already listed in requirements.txt) so that the
code does not require large dependencies like matplotlib.

Usage: python3 experiments/plot_results.py <output_dir>
"""

import csv
import os
import sys

try:
    import plotext as plt
except ImportError:
    plt = None


def main(outdir):
    csv_path = os.path.join(outdir, "coverage_summary.csv")
    if not os.path.isfile(csv_path):
        print("coverage_summary.csv not found in", outdir)
        return

    with open(csv_path, newline='') as f:
        reader = csv.DictReader(f)
        times = []
        data = {}
        for row in reader:
            # assume first column is time or elapsed
            t = float(row.get('time', row.get('elapsed', 0)))
            times.append(t)
            for k, v in row.items():
                if k in ('time', 'elapsed'):
                    continue
                try:
                    data.setdefault(k, []).append(float(v))
                except Exception:
                    # ignore non-numeric fields
                    pass

    plots_dir = os.path.join(outdir, "plots")
    os.makedirs(plots_dir, exist_ok=True)

    if not data:
        print("No numeric coverage columns found in CSV.")
        return

    print("Generating plots for columns:", ", ".join(data.keys()))
    for name, values in data.items():
        if plt is None:
            # fallback: write simple text file with numbers
            fname = os.path.join(plots_dir, f"{name}.txt")
            with open(fname, 'w') as outf:
                outf.write("time," + name + "\n")
                for t, v in zip(times, values):
                    outf.write(f"{t},{v}\n")
            print(f"  wrote data to {fname}")
            continue

        plt.clear_figure()
        plt.plot(times, values, label=name)
        plt.title(name)
        # export to text file as ascii image
        txtfile = os.path.join(plots_dir, f"{name}.txt")
        with open(txtfile, 'w') as outf:
            outf.write(plt.build())
        print(f"  ascii plot saved to {txtfile}")
        # also save as PNG if the backend supports it
        try:
            pngfile = os.path.join(plots_dir, f"{name}.png")
            plt.savefig(pngfile)
            print(f"  png plot saved to {pngfile}")
        except Exception:
            pass


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1])
