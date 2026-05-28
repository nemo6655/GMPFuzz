import re
import matplotlib.pyplot as plt

dirs = {
    "Mosquitto": "evaluation/Mosquito_results_20260402_173153/gmpfuzz/instance_1/gmpfuzz_run.log",
    "NanoMQ": "evaluation/Nanomq_results_20260506_174234/gmpfuzz/instance_1/gmpfuzz_run.log",
    "FlashMQ": "evaluation/Flashmq_results_20260417_174913/gmpfuzz/instance_1/gmpfuzz_run.log",
    "Mongoose": "evaluation/mongoose_results_20260416_085721/gmpfuzz/instance_1/gmpfuzz_run.log"
}

target_gen_times = {}

for name, path in dirs.items():
    gens = {}
    current_gen = None
    with open(path) as f:
        for line in f:
            m = re.search(r"Predicted epoch: \d+s for (gen\d+)", line)
            if m:
                current_gen = m.group(1)
                if current_gen == "gen0":
                    gens = {} # Reset to collect only the last run's generations (e.g. for FlashMQ)
            
            if "Epoch complete" in line and current_gen is not None:
                m2 = re.search(r"Epoch complete: (\d+)s", line)
                if m2:
                    gens[current_gen] = int(m2.group(1))
                current_gen = None
    target_gen_times[name] = gens

fig, axes = plt.subplots(2, 2, figsize=(14, 12))
axes = axes.flatten()

colors = plt.cm.Set3.colors  # better distinct colors

for idx, (name, gens) in enumerate(target_gen_times.items()):
    ax = axes[idx]
    values = list(gens.values())
    
    total_sec = sum(values)
    
    labels = [f"{g}\n({v/3600:.1f}h)" for g, v in gens.items()]
    
    ax.pie(values, labels=labels, autopct='%1.1f%%', startangle=90, colors=colors)
    ax.set_title(f"{name} ASE Distribution\n(Total Fuzz: {total_sec/3600:.1f}h)")

plt.tight_layout()
plt.savefig("ase_usage_time.pdf", format="pdf")
print("Successfully saved 4 pie charts to ase_usage_time.pdf")
