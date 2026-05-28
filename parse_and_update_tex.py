import os

d = "evaluation/Nanomq_results_20260506_174234"
def get_b_abs(file_path):
    try:
        with open(file_path, "r") as f:
            lines = f.readlines()
            if len(lines) > 1:
                return float(lines[-1].strip().split(',')[4])
    except:
        pass
    return 0

gmp = get_b_abs(os.path.join(d, "gmpfuzz/instance_1/cov_over_time.csv"))
afl_vals = [get_b_abs(os.path.join(d, f"aflnet/instance_{i}/cov_over_time.csv")) for i in range(1, 5)]
afl = sum(v for v in afl_vals if v) / sum(1 for v in afl_vals if v) if afl_vals else 0
mp = get_b_abs(os.path.join(d, "mpfuzz/instance_1/cov_over_time.csv"))
peach_vals = [get_b_abs(os.path.join(d, f"peach/instance_{i}/cov_over_time.csv")) for i in range(1, 5)]
peach = sum(v for v in peach_vals if v) / sum(1 for v in peach_vals if v) if peach_vals else 0

print("NanoMQ branches:", {"gmpfuzz": round(gmp), "aflnet": round(afl), "mpfuzz": round(mp), "peach": round(peach)})

