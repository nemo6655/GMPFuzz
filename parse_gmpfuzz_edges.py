import tarfile
import glob
import os
import re

tar_files = glob.glob('preset/mqtt/gen*/aflnetout/*.tar.gz')
max_edges = 0

for tar_path in tar_files:
    base = os.path.basename(tar_path).replace('.tar.gz', '')
    try:
        with tarfile.open(tar_path, 'r:gz') as tar:
            member_name = f"{base}/plot_data"
            if member_name in tar.getnames():
                f = tar.extractfile(member_name)
                lines = f.read().decode('utf-8').strip().split('\n')
                if not lines: continue
                # find the last line
                last = lines[-1]
                if last.startswith('#'): continue
                
                parts = last.split(',')
                if len(parts) > 6:
                    map_pct = float(parts[6].replace('%', '').strip())
                    edges = int(map_pct * 65536 / 100)
                    if edges > max_edges:
                        max_edges = edges
    except Exception as e:
        print(e)
        pass

print(f"GMPFuzz Max Edges: {max_edges}")
