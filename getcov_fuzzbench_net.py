#!/usr/bin/env python3
"""
getcov_fuzzbench_net.py - Launch parallel Docker containers running aflnet
against the MQTT target and collect coverage results.

Each subdirectory under --input is treated as a separate "state pool" job.
For each job, a Docker container is started with the appropriate seed files,
running aflnet against Mosquitto. After all containers finish, the coverage
results are extracted and aggregated into a JSON coverage file.
"""

import click
import tempfile
import shutil
import sys
import subprocess
import os
import os.path
import re
import tarfile
import time
from util import *
import logging
import json

logger = logging.getLogger(__file__)


@click.command()
@click.option('--image', type=str, required=True, help='Docker image name (e.g., gmpfuzz/mqtt)')
@click.option('--input', type=str, required=True, help='Input directory containing seed subdirectories')
@click.option('--output', type=str, required=False, help='Output directory for aflnet results')
@click.option('--persist/--no-persist', type=bool, default=False)
@click.option('--covfile', type=str, default='./cov.json', help='Path to output coverage JSON file')
@click.option('--next_gen', type=int, default=1, help='Generation number')
@click.option('-j', 'parallel_num', type=int, default=64, required=False, help='Max parallel containers')
@click.option('--ase-state', type=str, default='', help='Path to ASE state file (empty = fixed timeout)')
@click.option('--num-total-gens', type=int, default=5, help='Total number of generations (for ASE)')
@click.option('--gen-start-time', type=int, default=0, help='Wall-clock epoch timestamp when this generation started (for ASE budgeting)')
def main(image: str, input: str, output: str, persist: bool, covfile: str,
         parallel_num: int, next_gen: int, ase_state: str, num_total_gens: int,
         gen_start_time: int):
    options = get_config('target.options')
    # Normalize options to a single string for command-line usage
    if isinstance(options, list):
        options = ' '.join(options)
    if options is None:
        options = ''

    prefix = '/tmp/gmpfuzz_fuzzdata/'
    os.makedirs(prefix, exist_ok=True)

    dest_dir = output if output else '/tmp/gmpfuzz_out'
    os.makedirs(dest_dir, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=prefix) as tmpdir:
        target_dir = os.path.join(tmpdir, 'input')
        os.makedirs(target_dir, exist_ok=True)

        # Build worklist: if input dir has subdirectories, treat each subdir as a separate job
        worklist = []
        use_0000 = False
        if os.path.isdir(input):
            entries = [os.path.join(input, name) for name in os.listdir(input)]
            subdirs = [p for p in entries if os.path.isdir(p)]
            if subdirs:
                worklist = subdirs
            else:
                # no subdirs: use the whole input dir as single job
                worklist = [input]
                use_0000 = True
        else:
            worklist = [input]

        from concurrent.futures import ThreadPoolExecutor, as_completed

        # ============================================================
        # ASE: Compute adaptive epoch timeout
        # ============================================================
        ase_scheduler = None
        if ase_state:
            try:
                from ase import ASEScheduler, ASEConfig
                ase_scheduler = ASEScheduler.load(ase_state)
                epoch_timeout = ase_scheduler.predict_epoch(
                    gen=next_gen, num_total_gens=num_total_gens)
                print(f"[ASE] Predicted epoch: {epoch_timeout}s for gen{next_gen}")
                print(f"[ASE] {ase_scheduler.get_summary()}")
            except Exception as e:
                print(f"[ASE] Warning: failed to load ASE, using default: {e}")
                epoch_timeout = 1800
                ase_scheduler = None
        else:
            epoch_timeout = 1800

        def start_container_for_job(job_path, idx):
            """Start a Docker container for a single job (state pool)."""
            run_tmp = os.path.join(tmpdir, f'run_{idx}')
            os.makedirs(run_tmp, exist_ok=True)
            # Copy job input into work tmp input
            dest_input = os.path.join(run_tmp, 'input')
            os.makedirs(dest_input, exist_ok=True)
            if os.path.isdir(job_path):
                for name in os.listdir(job_path):
                    s = os.path.join(job_path, name)
                    d = os.path.join(dest_input, name)
                    if os.path.isdir(s):
                        shutil.copytree(s, d)
                    else:
                        shutil.copy2(s, d)
            else:
                shutil.copy2(job_path, os.path.join(dest_input, os.path.basename(job_path)))

            # Sanitize job name to produce a safe artifact name
            job_base = os.path.basename(job_path.rstrip(os.path.sep))
            safe_job = re.sub(r'[^A-Za-z0-9_.-]', '_', job_base)
            output_base = f'aflnetout_{safe_job}'

            # Timeout: use ASE if available, else fixed 1800s
            timeout_seconds = epoch_timeout
            skipcount = (next_gen + 1) * 20

            cmd = [
                'docker', 'run', '-d',
                '--cpus=1',
                '-v', f'{run_tmp}:/tmp',
                image,
                '/bin/bash', '-c',
                f'cd /home/ubuntu/experiments && run aflnet /tmp/input {output_base} "{options}" {timeout_seconds} {skipcount}'
            ]
            # Start and return container id and run_tmp
            res = subprocess.run(cmd, capture_output=True, text=True, check=True)
            cid = res.stdout.strip()
            print(f"Started container for job {idx} (job={job_base}): {cid}")
            return cid, run_tmp, output_base, idx

        # Start all jobs in parallel
        futures = []
        cids = []
        runmap = {}
        with ThreadPoolExecutor(max_workers=min(len(worklist), parallel_num or len(worklist))) as ex:
            for i, job in enumerate(worklist, start=1):
                futures.append(ex.submit(start_container_for_job, job, i))
            for fut in as_completed(futures):
                cid, run_tmp, output_base, idx = fut.result()
                cids.append(cid)
                runmap[cid] = (run_tmp, output_base)

        # Wait for all containers to finish (with optional ASE monitoring)
        if cids:
            if ase_scheduler:
                # ASE monitoring loop: periodically sample coverage from containers
                print(f"[ASE] Monitoring {len(cids)} containers (interval={ase_scheduler.cfg.delta}s)...")
                epoch_start_time = time.time()
                start_cov_sampled = False
                start_cov_total = 0.0
                pool_covs = {}  # Initialize before loop to avoid UnboundLocalError

                while True:
                    time.sleep(ase_scheduler.cfg.delta)
                    t_elapsed = time.time() - epoch_start_time

                    # Check if containers are still running
                    still_running = []
                    for cid in cids:
                        res = subprocess.run(
                            ['docker', 'inspect', '-f', '{{.State.Running}}', cid],
                            capture_output=True, text=True)
                        if res.returncode == 0 and res.stdout.strip() == 'true':
                            still_running.append(cid)

                    if not still_running:
                        print(f"[ASE] All containers finished at t={t_elapsed:.0f}s")
                        break

                    # Sample coverage from each running container via fuzzer_stats
                    pool_covs = {}
                    for cid in still_running:
                        run_tmp, output_base = runmap.get(cid, (None, None))
                        if not output_base:
                            continue
                        # Read bitmap_cvg from AFL fuzzer_stats inside container
                        # Try multiple possible paths for different targets:
                        #   mqtt:     mosquitto/src/<outdir>/fuzzer_stats
                        #   mongoose: mongoose/<outdir>/fuzzer_stats
                        #   nanomq:   nanomq/build-afl/<outdir>/fuzzer_stats
                        res = subprocess.run(
                            ['docker', 'exec', cid, 'bash', '-c',
                             f'cat /home/ubuntu/experiments/mosquitto/src/{output_base}/fuzzer_stats 2>/dev/null'
                             f' || cat /home/ubuntu/experiments/mongoose/{output_base}/fuzzer_stats 2>/dev/null'
                             f' || cat /home/ubuntu/experiments/nanomq/build-afl/{output_base}/fuzzer_stats 2>/dev/null'
                             f' || cat /home/ubuntu/experiments/{output_base}/fuzzer_stats 2>/dev/null'
                             ' || echo ""'],
                            capture_output=True, text=True, timeout=10)
                        if res.returncode == 0:
                            for line in res.stdout.splitlines():
                                if 'paths_total' in line:
                                    try:
                                        val = float(line.split(':')[1].strip())
                                        pool_covs[cid[:12]] = val
                                    except (ValueError, IndexError):
                                        pass

                    if pool_covs:
                        total_cov = sum(pool_covs.values())
                        if not start_cov_sampled:
                            start_cov_total = total_cov
                            start_cov_sampled = True

                        action = ase_scheduler.check(t_elapsed, pool_covs)
                        cov_str = ", ".join(f"{k}={v:.0f}" for k, v in pool_covs.items())
                        print(f"[ASE] t={t_elapsed:.0f}s cov=[{cov_str}] "
                              f"rho={ase_scheduler._rho_bar:.4f} action={action}")

                        if action == "stop":
                            print(f"[ASE] Early stopping at t={t_elapsed:.0f}s (saturated)")
                            for cid in still_running:
                                subprocess.run(['docker', 'kill', cid],
                                               capture_output=True, timeout=10)
                            break
                        elif action == "extend":
                            new_limit = ase_scheduler.get_current_epoch_limit()
                            print(f"[ASE] Extended epoch to {new_limit:.0f}s (still productive)")

                    # Hard limit: if we exceed T_max, force stop
                    if t_elapsed >= ase_scheduler.cfg.T_max:
                        print(f"[ASE] Hard limit T_max={ase_scheduler.cfg.T_max}s reached")
                        for cid in still_running:
                            subprocess.run(['docker', 'kill', cid],
                                           capture_output=True, timeout=10)
                        break

                # Record ASE history
                actual_time = time.time() - epoch_start_time
                # Compute wall-clock time for the entire generation (LLM + fuzz)
                if gen_start_time > 0:
                    wall_clock_total = time.time() - gen_start_time
                else:
                    wall_clock_total = 0.0  # fallback to estimate
                end_cov_total = sum(pool_covs.values()) if pool_covs else start_cov_total
                ase_scheduler.record(
                    gen=next_gen,
                    start_cov=start_cov_total,
                    end_cov=end_cov_total,
                    actual_time=actual_time,
                    wall_clock_total=wall_clock_total,
                )
                ase_scheduler.save(ase_state)
                print(f"[ASE] Epoch complete: {actual_time:.0f}s, "
                      f"cov {start_cov_total:.0f} -> {end_cov_total:.0f}")
                print(f"[ASE] {ase_scheduler.get_summary()}")

                # Wait for any remaining containers
                time.sleep(2)
                for cid in cids:
                    subprocess.run(['docker', 'wait', cid],
                                   capture_output=True, timeout=30)
            else:
                # No ASE: simple wait
                print(f"Waiting for {len(cids)} containers to finish...")
                subprocess.run(['docker', 'wait'] + cids, check=True)

        all_cov_data = {str(next_gen): {}}

        # Collect outputs from each container
        for cid in cids:
            run_tmp, output_base = runmap.get(cid)
            os.makedirs(dest_dir, exist_ok=True)
            aflout_path = os.path.join(dest_dir, f'{output_base}.tar.gz')
            try:
                subprocess.run(
                    ['docker', 'cp', f'{cid}:/home/ubuntu/experiments/{output_base}.tar.gz', aflout_path],
                    check=True
                )
            except subprocess.CalledProcessError:
                print(f"Warning: could not copy {output_base}.tar.gz from container {cid}")

            # Extract files from tarball
            if os.path.exists(aflout_path):
                try:
                    safe_job = output_base[len('aflnetout_'):] if output_base.startswith('aflnetout_') else output_base
                    if use_0000:
                        safe_job = '0000'
                    extract_root = os.path.join(dest_dir, safe_job)
                    os.makedirs(extract_root, exist_ok=True)

                    with tarfile.open(aflout_path, 'r:*') as tf:
                        for member in tf.getmembers():
                            name = member.name.lstrip('./')
                            parts = name.split('/')

                            target_path = None
                            if '.state' in parts and 'seed_cov' in parts:
                                si = parts.index('seed_cov')
                                rel_parts = parts[si + 1:]
                                if rel_parts:
                                    target_path = os.path.join(extract_root, 'seed_cov', *rel_parts)
                            elif 'queue' in parts:
                                if '.state' in parts:
                                    continue
                                qi = parts.index('queue')
                                rel_parts = parts[qi + 1:]
                                if rel_parts:
                                    target_path = os.path.join(extract_root, *rel_parts)

                            if target_path:
                                parent = os.path.dirname(target_path)
                                if parent:
                                    os.makedirs(parent, exist_ok=True)
                                if member.isdir():
                                    os.makedirs(target_path, exist_ok=True)
                                else:
                                    f = tf.extractfile(member)
                                    if f is None:
                                        continue
                                    with open(target_path, 'wb') as out_f:
                                        shutil.copyfileobj(f, out_f)

                    # Process coverage files
                    seed_cov_dir = os.path.join(extract_root, 'seed_cov')
                    job_cov = {}
                    if os.path.exists(seed_cov_dir):
                        for cov_file in os.listdir(seed_cov_dir):
                            cov_path = os.path.join(seed_cov_dir, cov_file)
                            if os.path.isfile(cov_path):
                                with open(cov_path, 'r', encoding='utf-8', errors='ignore') as f:
                                    content = [line.strip() for line in f if line.strip()]
                                job_cov[cov_file] = content

                    # Save per-job json
                    with open(os.path.join(dest_dir, f'cov_{safe_job}.json'), 'w') as f:
                        json.dump(job_cov, f)

                    if safe_job not in all_cov_data[str(next_gen)]:
                        all_cov_data[str(next_gen)][safe_job] = {}

                    for k, v in job_cov.items():
                        edges_only = []
                        state_info = "unknown"
                        for item in v:
                            if '::::' in item:
                                try:
                                    state_info = item.split("state:", 1)[1].split("::::", 1)[0]
                                except IndexError:
                                    pass
                                continue
                            edges_only.append(item.split(':')[0])

                        all_cov_data[str(next_gen)][safe_job][k] = {state_info: edges_only}

                except Exception as e:
                    print(f"Warning: failed to extract/process files from {aflout_path}: {e}")

            # Cleanup container
            try:
                subprocess.run(['docker', 'rm', '-f', cid], capture_output=True)
            except Exception:
                pass

        # Write aggregated coverage to covfile
        if all_cov_data:
            os.makedirs(os.path.dirname(os.path.abspath(covfile)), exist_ok=True)
            with open(covfile, 'w') as f:
                json.dump(all_cov_data, f, indent=2)
            print(f"Coverage data written to {covfile}")

    # Cleanup tmpdir if it persists
    if os.path.exists(tmpdir):
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    main()
