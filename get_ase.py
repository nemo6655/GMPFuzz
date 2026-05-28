import os, glob
dirs = [
    "Mosquito_results_20260402_173153",
    "Nanomq_results_20260506_174234",
    "Flashmq_results_20260417_174913",
    "mongoose_results_20260416_085721"
]
for d in dirs:
    path = f"evaluation/{d}/gmpfuzz/instance_1/gmpfuzz_run.log"
    if os.path.exists(path):
        with open(path, "r") as f:
            lines = [l for l in f.readlines() if "[ASE]" in l]
            if lines:
                print(d)
                print(lines[-5:])
