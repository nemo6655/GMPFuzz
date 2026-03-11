#!/usr/bin/env python3
"""
genoutputs_net.py - Execute Python variant scripts to produce raw MQTT output files.

Reads module paths from stdin (preceded by a count), runs each module's
__mqtt_gen__ function via driver_net.py, and produces .raw output files
that can be used as seeds for aflnet.
"""

import argparse
from collections import OrderedDict, defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
import glob
import json
import logging
import os
import re
import shutil
import subprocess
import sys
from typing import BinaryIO, Optional
import random

from driver_net import ExceptionInfo, Result, ResultInfo, GenResult
from util import get_config

logger = logging.getLogger(__name__)

# ANSI colors
COLOR_GREEN = '\033[92m'
COLOR_RED = '\033[91m'
COLOR_YELLOW = '\033[93m'
COLOR_END = '\033[0m'

gentype_re = re.compile(r'var_\d{4}\.(?P<gentype>[a-z]+)\.')


def get_gentype(module_path):
    basename = os.path.basename(module_path)
    match = gentype_re.search(basename)
    if match:
        return match.group('gentype')
    return "0initial"


def generate_stats(logfile):
    """Print generation statistics from the log file."""
    running_stats = defaultdict(lambda: defaultdict(int))
    with open(logfile) as f:
        first_line = f.readline()
        try:
            original_args = json.loads(first_line)['data']['args']
        except (json.JSONDecodeError, KeyError):
            return
        for line in f:
            try:
                result = json.loads(line)
                module_path = result.get('module_path', 'unknown')
                running_stats[get_gentype(module_path)][result['result_type']] += 1
            except (json.JSONDecodeError, KeyError):
                continue

    combined = {}
    for k in running_stats:
        for rtype, count in running_stats[k].items():
            combined[rtype] = combined.get(rtype, 0) + count

    print(f"Stats:", file=sys.stderr)
    for k in sorted(running_stats.keys()):
        print(f"  {k}: {dict(running_stats[k])}", file=sys.stderr)
    print(f"  combined: {combined}", file=sys.stderr)

    total = sum(combined.values())
    success = combined.get('Success', 0)
    print(f"     total: {total} files attempted", file=sys.stderr)
    print(f"   success: {success} files generated", file=sys.stderr)
    if total != 0:
        print(f"  success%: {success / total * 100:.2f}%", file=sys.stderr)


def generate_corpus(module_path, input_seeds, worker_dir, args):
    """Run a single generator module and collect its outputs."""
    module_name = os.path.basename(module_path)
    copied_module_name = os.path.join(worker_dir, module_name)
    shutil.copyfile(module_path, copied_module_name)
    actual_module_name = os.path.join(worker_dir, module_name)

    # Force single iteration
    num_iterations = 1

    # Flat output structure
    module_base = os.path.splitext(module_name)[0]
    outdir = os.path.join(args.output_dir, module_base)

    logfile_name = 'logfile.json'
    actual_logfile_name = os.path.join(worker_dir, logfile_name)

    cmd = [
        sys.executable, 'driver_net.py',
        '-n', str(num_iterations),
        '-o', outdir,
        '-L', actual_logfile_name,
        '-t', str(args.driver_timeout),
        '-S', str(args.driver_size_limit),
        '-M', str(args.driver_max_mem),
        '-s', args.driver_output_suffix,
        '-i', input_seeds,
        actual_module_name, args.driver_function_name,
    ]

    logger.debug(f"Running: {' '.join(cmd)}")
    input_seed_num = max(1, len(input_seeds.split(';')))
    result = None
    try:
        timeout = 0.5 * args.driver_timeout * input_seed_num * num_iterations * 0.5
        subprocess.run(cmd, check=True, text=True, timeout=max(timeout, 30), capture_output=True)
    except subprocess.TimeoutExpired:
        pass
    except subprocess.CalledProcessError as e:
        result = Result(
            error=ExceptionInfo.from_exception(e, module_path),
            data=ResultInfo(
                time_taken=None,
                memory_used=None,
                stdout=e.stderr or '',
                stderr=e.stdout or '',
            ),
            module_path=module_path,
            result_type=GenResult.RunError,
            function_name=args.driver_function_name,
            args=args,
        )

    # Remove the module from the output directory
    try:
        os.remove(copied_module_name)
    except FileNotFoundError:
        pass

    gen_results = []
    try:
        with open(os.path.join(worker_dir, logfile_name)) as f:
            for line in f:
                gen_results.append(json.loads(line))
        os.remove(os.path.join(worker_dir, logfile_name))
    except FileNotFoundError:
        result = Result(
            error=None,
            data=None,
            module_path=module_path,
            result_type=GenResult.NoLogErr,
            function_name=args.driver_function_name,
            args=args,
        )

    if len(gen_results) == 1 and gen_results[0].get('result_type') == 'ImportError':
        return gen_results

    if len(gen_results) != num_iterations:
        if result is None:
            result = Result(
                error=None,
                data=None,
                module_path=module_path,
                result_type=GenResult.UnknownErr,
                function_name=args.driver_function_name,
                args=args,
            )
        for _ in range(num_iterations - len(gen_results)):
            gen_results.append(json.loads(result.json()))
    return gen_results


def make_parser():
    parser = argparse.ArgumentParser(
        description='Create raw MQTT outputs using generated Python programs'
    )
    parser.add_argument('-O', '--output-dir', type=str, default='.',
                        help='Output directory for raw files')
    parser.add_argument('-j', '--jobs', type=int, default=None,
                        help='Maximum number of parallel jobs (default: ncpu)')
    parser.add_argument('--raise-errors', action='store_true',
                        help="Don't catch exceptions in the main driver loop")
    parser.add_argument('-L', '--logfile', type=str, default=None,
                        help='Log file for JSON results')
    parser.add_argument('-f', '--driver-function-name', type=str,
                        default='__mqtt_gen__',
                        help='The function to run in each module')
    parser.add_argument('-t', '--driver-timeout', type=int, default=2,
                        help='Timeout for each function run (in seconds)')
    parser.add_argument('-S', '--driver-size-limit', type=int, default=50 * 1024,
                        help='Maximum size of the output file (in bytes)')
    parser.add_argument('-M', '--driver-max-mem', type=int, default=1024 * 1024 * 1024,
                        help='Maximum memory usage (in bytes)')
    parser.add_argument('-s', '--driver-output-suffix', type=str, default='.raw',
                        help='Suffix for output files')
    parser.add_argument('-g', '--generation', type=str, default='initial',
                        help='Current generation name')
    return parser


def main():
    parser = make_parser()
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)

    if args.logfile is not None:
        output_log = open(args.logfile, 'w')
    else:
        output_log = sys.stdout

    # Record the arguments we're using in the log
    print(json.dumps(
        {'error': None, 'data': {'args': args.__dict__}},
        default=lambda x: x.__dict__ if hasattr(x, '__dict__') else str(x),
    ), file=output_log)

    # The first line sent by genvariants (or the shell) is the number of modules
    module_count = int(sys.stdin.readline())

    input_seeds_str = ""

    # Call generate_corpus on each module in parallel
    with ProcessPoolExecutor(max_workers=args.jobs) as executor:
        futures_to_paths = OrderedDict()
        processed = 0

        for module_path in sys.stdin:
            module_path = module_path.strip()
            if not module_path:
                continue

            module_base = os.path.splitext(os.path.basename(module_path))[0]
            worker_dir = os.path.join(args.output_dir, ".work", module_base)
            os.makedirs(worker_dir, exist_ok=True)

            future = executor.submit(
                generate_corpus,
                module_path, input_seeds_str, worker_dir, args
            )
            futures_to_paths[future] = (module_path, worker_dir)

        for future in as_completed(futures_to_paths):
            module_path, worker_dir = futures_to_paths[future]
            processed += 1
            try:
                result = future.result()
                for res in result:
                    if isinstance(res, dict):
                        print(json.dumps(res), file=output_log)
                    else:
                        print(res.json() if hasattr(res, 'json') else json.dumps(res), file=output_log)
            except Exception as e:
                if args.raise_errors:
                    raise
                res = Result(
                    error=ExceptionInfo.from_exception(e, module_path),
                    data=None,
                    module_path=module_path,
                    result_type=GenResult.Error,
                    function_name=args.driver_function_name,
                )
                print(res.json(), file=output_log)

            # Clean up worker dir
            shutil.rmtree(worker_dir, ignore_errors=True)

            if processed % 10 == 0:
                print(f"  Progress: {processed}/{module_count} modules processed", file=sys.stderr)

    # Clean up the .work directory
    shutil.rmtree(os.path.join(args.output_dir, ".work"), ignore_errors=True)

    if output_log != sys.stdout:
        output_log.close()

    # Collect statistics if we have a log
    if args.logfile is not None:
        generate_stats(args.logfile)


if __name__ == '__main__':
    main()
