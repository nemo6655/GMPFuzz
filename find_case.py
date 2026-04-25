import json

base_dir = '/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/results_20260402_173153/gmpfuzz/instance_1/'
with open(f"{base_dir}/gen4/elites.json", "r") as f:
    elites = json.load(f)["gen4"]

# Find the item with the most complex history (e.g., longest format)
candidates = []
for seed_id, data in elites.items():
    history = data.get("format", [])
    if isinstance(history, list):
        # Calculate some metric of complexity: number of packets, number of distinct packet types
        types = [p.get("type", "") for p in history if isinstance(p, dict)]
        if len(types) > 0:
            candidates.append({
                "id": seed_id,
                "len": len(types),
                "distinct_types": len(set(types)),
                "types": types,
                "history": data.get("history", [])
            })

candidates.sort(key=lambda x: (x["distinct_types"], x["len"]), reverse=True)

print("Top 5 complex seeds:")
for c in candidates[:5]:
    print(f"Seed {c['id']}: len={c['len']}, distinct={c['distinct_types']}, types={c['types']}")
    print(f"History IDs: {c['history'][-5:]}")
    print("---")

