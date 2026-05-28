#!/usr/bin/env python3
"""
Parse `/tmp/repro_samples_replayable/manifest.csv`, enumerate tar contents,
and extract the replayable sample blobs to `/tmp/repro_samples_replayable/extracted/`.

This script is defensive about the non-quoted CSV: it rsplit()s the last two
fields (target, size) then finds the tarball path by locating 'evaluation/' and
the trailing '.tar.gz'. If the exact `internal_path` extraction fails, it will
search the tar listing for an entry that contains the sample id (e.g. 'id:000123')
and extract that instead.

It writes an output TSV at `/tmp/repro_samples_replayable/extraction_manifest.tsv`
with: sample_id<TAB>tarball_path<TAB>internal_path<TAB>extracted_path<TAB>target<TAB>size
"""

import os
import sys
import subprocess
from pathlib import Path

ROOT = Path('/home/pzst/mqtt_fuzz/GMPFuzz')
MANIFEST = Path('/tmp/repro_samples_replayable/manifest.csv')
OUT_DIR = Path('/tmp/repro_samples_replayable/extracted')
OUT_DIR.mkdir(parents=True, exist_ok=True)
OUT_MANIFEST = Path('/tmp/repro_samples_replayable/extraction_manifest.tsv')

def run(cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return p

def list_tar(tarpath):
    p = run(['tar','-tzf', tarpath])
    if p.returncode != 0:
        return None
    return p.stdout.splitlines()

def extract_to_file(tarpath, member, dest):
    # dest: Path
    try:
        with open(dest, 'wb') as f:
            p = subprocess.run(['tar','-xOf', tarpath, member], stdout=f, stderr=subprocess.PIPE)
        return p.returncode == 0
    except Exception:
        return False

def sanitize_name(s):
    return s.replace('/', '_').replace(':', '_').replace(',', '_').replace(' ', '_')

if not MANIFEST.exists():
    print('manifest not found:', MANIFEST, file=sys.stderr)
    sys.exit(1)

lines = MANIFEST.read_text().splitlines()
if not lines:
    print('manifest empty', file=sys.stderr); sys.exit(1)

header = lines[0]
entries = lines[1:]

out_lines = []

for i,line in enumerate(entries, start=1):
    line = line.strip()
    if not line:
        continue
    # split last two columns (target,size)
    try:
        rest, target, size = line.rsplit(',', 2)
    except ValueError:
        print('cannot parse line (rsplit fail):', line[:200])
        continue

    # find tarball path starting with 'evaluation/' (relative to ROOT)
    tar_idx = rest.find('evaluation/')
    if tar_idx == -1:
        # try absolute path
        tar_idx = rest.find('/home/')
        if tar_idx == -1:
            print('cannot find tarball path in line:', rest[:120])
            continue

    # tarball ends with .tar.gz
    gz_idx = rest.find('.tar.gz', tar_idx)
    if gz_idx == -1:
        print('no .tar.gz found after tar_idx in rest:', rest[tar_idx:tar_idx+200])
        continue
    gz_end = gz_idx + len('.tar.gz')
    tarball_rel = rest[tar_idx:gz_end]
    tarball_path = (ROOT / tarball_rel).resolve()

    # sample_file is everything before the comma that precedes tar_idx
    sample_file = rest[:tar_idx].rstrip(',')
    # internal_path is everything after the tarball (skip the comma)
    internal_path = rest[gz_end+1:]

    # sample id heuristic: look for 'id:000' in internal_path
    sid = None
    import re
    m = re.search(r'id:0+\d+', internal_path)
    if m:
        sid = m.group(0)
    else:
        # fallback use sanitized sample_file
        sid = sanitize_name(sample_file)

    extracted_name = f"{sanitize_name(sample_file)}.raw"
    extracted_path = OUT_DIR / extracted_name

    if not tarball_path.exists():
        print(f'[{i}] tarball not found: {tarball_path} (from manifest)')
        out_lines.append(f"{sid}\t{tarball_path}\t{internal_path}\tMISSING_TARBALL\t{target}\t{size}")
        continue

    # try direct extraction using provided internal_path
    ok = extract_to_file(str(tarball_path), internal_path, extracted_path)
    if not ok:
        # list tar and try to find a best-match entry containing id:xxxx and 'replayable-crashes'
        entries = list_tar(str(tarball_path))
        if entries is None:
            print(f'[{i}] failed tar -tzf for {tarball_path}')
            out_lines.append(f"{sid}\t{tarball_path}\t{internal_path}\tTARLIST_FAIL\t{target}\t{size}")
            continue
        candidate = None
        for e in entries:
            if 'replayable-crashes' in e and sid in e:
                candidate = e
                break
        if candidate is None:
            # last resort: try to match the tail 'replayable-crashes/id:' prefix plus id number
            for e in entries:
                if 'replayable-crashes' in e and 'id:' in e and e.endswith('.raw') is False:
                    if sid.split(':')[-1] in e:
                        candidate = e
                        break
        if candidate:
            ok = extract_to_file(str(tarball_path), candidate, extracted_path)
            if ok:
                internal_path_used = candidate
                print(f'[{i}] extracted via candidate {candidate} -> {extracted_path}')
                out_lines.append(f"{sid}\t{tarball_path}\t{internal_path_used}\t{extracted_path}\t{target}\t{size}")
                continue
            else:
                print(f'[{i}] candidate extraction failed for {candidate}')
                out_lines.append(f"{sid}\t{tarball_path}\t{internal_path}\tEXTRACT_FAIL\t{target}\t{size}")
                continue
        else:
            print(f'[{i}] no candidate found in tar for id {sid} (tar: {tarball_path})')
            out_lines.append(f"{sid}\t{tarball_path}\t{internal_path}\tNO_MATCH\t{target}\t{size}")
            continue
    else:
        out_lines.append(f"{sid}\t{tarball_path}\t{internal_path}\t{extracted_path}\t{target}\t{size}")
        print(f'[{i}] extracted {extracted_path.name}')

OUT_MANIFEST.write_text('\n'.join(out_lines))
print('\nExtraction complete. Wrote:', OUT_MANIFEST)
