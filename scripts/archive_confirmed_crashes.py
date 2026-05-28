#!/usr/bin/env python3
"""
Scan extraction_manifest and /tmp/repro_results_replayable for ASAN/SEGV evidence,
then archive confirmed crashes under `crash/<target>-<safe_name>/`.

Outputs a summary `/tmp/repro_samples_replayable/archived_summary.tsv`.
"""

import os
import sys
import json
from pathlib import Path
import shutil
import re

ROOT = Path('/home/pzst/mqtt_fuzz/GMPFuzz')
EXTRACTION_MANIFEST = Path('/tmp/repro_samples_replayable/extraction_manifest.tsv')
RESULTS_DIR = Path('/tmp/repro_results_replayable')
OUT_SUMMARY = Path('/tmp/repro_samples_replayable/archived_summary.tsv')

CRASH_ROOT = ROOT / 'crash'
CRASH_ROOT.mkdir(exist_ok=True)

if not EXTRACTION_MANIFEST.exists():
    print('extraction manifest missing:', EXTRACTION_MANIFEST)
    sys.exit(1)

lines = EXTRACTION_MANIFEST.read_text().splitlines()
out_lines = []

def find_experiment_config(tarball_path: Path):
    p = tarball_path.parent
    for _ in range(6):
        cfg = p / 'experiment_config.json'
        if cfg.exists():
            return cfg
        p = p.parent
    return None

def find_result_logs_for_sid(sid):
    # sid is like 'id:000001'
    matches = list(RESULTS_DIR.glob(f'*{sid}*'))
    return matches

def extract_evidence(logpath: Path):
    txt = logpath.read_text(errors='ignore')
    # look for ASAN block or segfault lines
    m = re.search(r'(AddressSanitizer:[\s\S]{0,800})', txt)
    if m:
        return m.group(1)
    # fallback lines
    lines = []
    for L in txt.splitlines():
        if re.search(r'AddressSanitizer|DEADLYSIGNAL|segmentation fault|SIG', L, re.I):
            lines.append(L)
    return '\n'.join(lines)[:2000]

for ln in lines:
    if not ln.strip():
        continue
    # fields: sid \t tarball \t internal_path \t extracted_path_or_status \t target \t size
    parts = ln.split('\t')
    if len(parts) < 6:
        continue
    sid, tarball_p, internal_path, extracted_path, target, size = parts[:6]
    tarball = Path(tarball_p)
    extracted = Path(extracted_path) if Path(extracted_path).exists() else None

    # find result logs
    logs = find_result_logs_for_sid(sid)
    evidence = ''
    evidence_log = None
    for lg in logs:
        e = extract_evidence(lg)
        if e:
            evidence = e
            evidence_log = lg
            break

    if not evidence:
        # no crash evidence found
        continue

    # determine canonical target from experiment_config.json
    cfg = find_experiment_config(tarball)
    target_name = target
    if cfg:
        try:
            j = json.loads(cfg.read_text())
            if 'target' in j:
                target_name = j['target']
        except Exception:
            pass

    safe_id = re.sub(r'[^A-Za-z0-9._-]', '_', sid)
    safe_tar = re.sub(r'[^A-Za-z0-9._-]', '_', tarball.name)
    crash_dir = CRASH_ROOT / f"{target_name}-{safe_tar}__{safe_id}"
    crash_dir.mkdir(parents=True, exist_ok=True)

    # copy extracted sample
    if extracted and extracted.exists():
        shutil.copy2(extracted, crash_dir / extracted.name)

    # copy all matching logs
    for lg in logs:
        try:
            shutil.copy2(lg, crash_dir / lg.name)
        except Exception:
            pass

    # write README
    rd = crash_dir / 'README.txt'
    with open(rd, 'w') as f:
        f.write(f"Source-Tar: {tarball}\n")
        f.write(f"Internal-Path: {internal_path}\n")
        f.write(f"Extracted-At: {extracted if extracted else 'MISSING'}\n")
        f.write(f"Result-Log: {evidence_log}\n")
        f.write(f"Target: {target_name}\n")
        f.write('\n--- Evidence excerpt ---\n')
        f.write(evidence)

    out_lines.append('\t'.join([str(crash_dir), sid, str(tarball), str(evidence_log)]))

OUT_SUMMARY.write_text('\n'.join(out_lines))
print('Archived', len(out_lines), 'crashes. Summary at', OUT_SUMMARY)
