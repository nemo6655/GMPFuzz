#!/usr/bin/env python3
"""
Fix crash archive directory names to include canonical target names.

For each directory under `crash/`, the script attempts to find a source tarball
path either from `README.txt` (if present) or by matching the directory name
against entries in `/tmp/repro_samples_replayable/extraction_manifest.tsv`.

It then looks for `experiment_config.json` near the tarball to read the
`target` field. If found, the crash dir is renamed to `<Target>-<safe_name>`.
If not found, the script tries to infer the target from the tarball path or
from keywords in the directory name.

The script updates/creates `README.txt` in each crash dir with a `Target:` line.

Run without arguments. Prints summary of renames.
"""

import json
import re
from pathlib import Path
import shutil
import sys

ROOT = Path('/home/pzst/mqtt_fuzz/GMPFuzz')
CRASH_DIR = ROOT / 'crash'
EXTRACTION_MANIFEST = Path('/tmp/repro_samples_replayable/extraction_manifest.tsv')

def read_readme_target(d: Path):
    rd = d / 'README.txt'
    if not rd.exists():
        return None
    txt = rd.read_text(errors='ignore')
    m = re.search(r'^Target:\s*(\S+)', txt, re.M)
    if m:
        return m.group(1)
    # try to find Source-Tar
    m = re.search(r'^Source-Tar:\s*(\S+)', txt, re.M)
    if m:
        return ('__SRC__', m.group(1))
    return None

def find_manifest_entry_for_name(name):
    if not EXTRACTION_MANIFEST.exists():
        return None
    for ln in EXTRACTION_MANIFEST.read_text().splitlines():
        if not ln.strip():
            continue
        parts = ln.split('\t')
        if len(parts) < 2:
            continue
        sid = parts[0]
        tarball = parts[1]
        extracted = parts[3] if len(parts) > 3 else ''
        # match by sid or by tar+id fragment
        if sid in name or (Path(extracted).name and Path(extracted).name in name):
            return {'sid': sid, 'tarball': tarball, 'extracted': extracted}
    return None

def find_experiment_config(tarball_path: Path):
    p = tarball_path.parent
    for _ in range(8):
        cfg = p / 'experiment_config.json'
        if cfg.exists():
            return cfg
        p = p.parent
    return None

def infer_target_from_path(p: str):
    low = p.lower()
    if 'mosquitto' in low or 'mosquito' in low or 'mosq' in low:
        return 'Mosquitto'
    if 'nanomq' in low or 'nano' in low:
        return 'Nanomq'
    if 'flashmq' in low or 'flash' in low:
        return 'Flashmq'
    if 'mongoose' in low or 'mongoose-os' in low or 'mongoose' in low:
        return 'Mongoose'
    # generic mqtt -> Mosquitto
    if 'mqtt' in low:
        return 'Mosquitto'
    return None

def safe_name(s: str):
    return re.sub(r'[^A-Za-z0-9._-]', '_', s)

renamed = []
for item in sorted(CRASH_DIR.iterdir()):
    if not item.is_dir():
        continue
    name = item.name
    # skip known non-archive files
    if name in ('gen_report.py', 'report.md', 'test_gmp_crashes.sh', 'verify.sh', 'vuln_oob_read', 'vuln_stack_smashing'):
        continue

    # if already starts with a known target prefix, skip
    if re.match(r'^(Mosquitto|Nanomq|Flashmq|Mongoose)-', name):
        continue

    target = None
    # 1) read README
    rd = item / 'README.txt'
    if rd.exists():
        txt = rd.read_text(errors='ignore')
        m = re.search(r'^Target:\s*(\S+)', txt, re.M)
        if m:
            target = m.group(1)
        else:
            m = re.search(r'^Source-Tar:\s*(\S+)', txt, re.M)
            if m:
                tar_s = m.group(1)
                cfg = find_experiment_config(Path(tar_s))
                if cfg:
                    try:
                        j = json.loads(cfg.read_text())
                        if 'target' in j:
                            target = j['target']
                    except Exception:
                        pass

    # 2) try manifest lookup
    if target is None:
        me = find_manifest_entry_for_name(name)
        if me:
            tar_s = me.get('tarball')
            if tar_s:
                cfg = find_experiment_config(Path(tar_s))
                if cfg:
                    try:
                        j = json.loads(cfg.read_text())
                        if 'target' in j:
                            target = j['target']
                    except Exception:
                        pass
            if target is None:
                # infer from tarball path string
                tgt = infer_target_from_path(tar_s or '')
                if tgt:
                    target = tgt

    # 3) infer from directory name
    if target is None:
        tgt = infer_target_from_path(name)
        if tgt:
            target = tgt

    if target is None:
        # leave UnknownTarget prefix
        newname = f"UnknownTarget-{safe_name(name)}"
    else:
        # normalize capitalization
        target_map = {
            'mosquitto':'Mosquitto', 'mosq':'Mosquitto', 'mqtt':'Mosquitto',
            'nanomq':'Nanomq', 'flashmq':'Flashmq', 'mongoose':'Mongoose'
        }
        tlow = str(target).lower()
        new_target = target_map.get(tlow, str(target).capitalize())
        newname = f"{new_target}-{safe_name(name)}"

    if newname == name:
        continue
    newpath = CRASH_DIR / newname
    if newpath.exists():
        # if target dir exists, merge contents
        for src in item.iterdir():
            dest = newpath / src.name
            if src.is_dir():
                shutil.copytree(src, dest, dirs_exist_ok=True)
            else:
                shutil.copy2(src, dest)
        # remove old
        try:
            shutil.rmtree(item)
        except Exception:
            pass
        renamed.append((str(item), str(newpath), 'merged'))
    else:
        try:
            item.rename(newpath)
            renamed.append((str(item), str(newpath), 'renamed'))
        except Exception as e:
            renamed.append((str(item), str(newpath), f'FAILED: {e}'))

    # ensure README has Target line
    final_rd = (CRASH_DIR / newname) / 'README.txt'
    if final_rd.exists():
        txt = final_rd.read_text(errors='ignore')
        if 'Target:' not in txt:
            with open(final_rd, 'a') as f:
                f.write(f"\nTarget: {target if target else 'Unknown'}\n")
    else:
        with open(final_rd, 'w') as f:
            f.write(f"Target: {target if target else 'Unknown'}\n")

print('Renames / merges:')
for a,b,c in renamed:
    print(a, '->', b, '(', c, ')')
