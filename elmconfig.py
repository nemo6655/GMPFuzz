#!/usr/bin/env python3
"""
elmconfig.py - Configuration management for GMPFuzz.

Reads config.yaml from the ELMFUZZ_RUNDIR directory and provides
a CLI interface to get/list/dump configuration values.

Compatible with TDPFuzz's elmconfig.py interface:
  ./elmconfig.py get <key>
  ./elmconfig.py get <key> -s VAR=VAL
  ./elmconfig.py list [prefix]
  ./elmconfig.py dumpconfig
"""

import argparse
import os
import sys
from pathlib import Path
from collections.abc import Sequence as SequenceABC

try:
    from ruamel.yaml import YAML
except ImportError:
    # Fallback to PyYAML
    import yaml as pyyaml

    class YAML:
        def __init__(self, *args, **kwargs):
            pass
        def load(self, stream):
            if isinstance(stream, (str, Path)):
                with open(stream) as f:
                    return pyyaml.safe_load(f)
            return pyyaml.safe_load(stream)


def load_config():
    """Load config from ELMFUZZ_RUNDIR/config.yaml or fallback locations."""
    yaml = YAML(typ='safe')
    config_files = []

    # Check script directory
    script_dir = os.path.dirname(os.path.realpath(__file__))
    config_files.append(os.path.join(script_dir, 'config.yaml'))

    # Check CWD
    config_files.append('config.yaml')

    # Check ELMFUZZ_RUNDIR
    rundir = os.environ.get('ELMFUZZ_RUNDIR', '')
    if rundir:
        config_files.append(os.path.join(rundir, 'config.yaml'))

    # Check ELMFUZZ_CONFIG
    if 'ELMFUZZ_CONFIG' in os.environ:
        config_files.append(os.environ['ELMFUZZ_CONFIG'])

    # Load the last existing config file (highest priority)
    conf = {}
    for cf in config_files:
        if os.path.exists(cf):
            with open(cf) as f:
                loaded = yaml.load(f)
                if loaded:
                    deep_merge(conf, loaded)
    return conf


def deep_merge(base, override):
    """Recursively merge override into base."""
    for k, v in override.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            deep_merge(base[k], v)
        else:
            base[k] = v


def flatten_dict(d, prefix=''):
    """Flatten a nested dict with dot-separated keys."""
    items = {}
    for k, v in d.items():
        full_key = f'{prefix}{k}' if not prefix else f'{prefix}.{k}'
        if isinstance(v, dict):
            items.update(flatten_dict(v, full_key))
        else:
            items[full_key] = v
    return items


def mget(d, keys):
    """Navigate into a nested dict using a list of keys."""
    current = d
    for key in keys:
        if isinstance(current, dict):
            if key in current:
                current = current[key]
            else:
                return None
        elif isinstance(current, list):
            try:
                current = current[int(key)]
            except (ValueError, IndexError):
                return None
        else:
            return None
    return current


def format_value(val):
    """Format a value for output."""
    if isinstance(val, list):
        return ' '.join(str(v) for v in val)
    elif isinstance(val, dict):
        # Format dict as space-separated key:value pairs
        return ' '.join(f'{k}:{v}' for k, v in val.items())
    elif isinstance(val, bool):
        return str(val)
    else:
        return str(val)


def get_cmd(args, conf):
    """Get a config value by key."""
    keys = args.key.split('.')
    val = mget(conf, keys)
    if val is None:
        print(f"Error: {args.key} is not a valid key", file=sys.stderr)
        sys.exit(1)

    result = format_value(val)

    # Apply substitutions
    if not args.no_subst:
        subst_dict = {}
        for s in (args.substitutions or []):
            k, v = s.split('=', 1)
            subst_dict[k] = v
        # Also expand environment variables
        if not args.no_env:
            subst_dict.update(os.environ)
        try:
            result = result.format(**subst_dict)
        except KeyError:
            pass  # If substitution fails, leave as-is

    print(result)


def list_cmd(args, conf):
    """List config keys matching a prefix."""
    flat = flatten_dict(conf)
    prefix = args.prefix or ''
    matching = [k for k in sorted(flat.keys()) if k.startswith(prefix)]
    if not matching:
        print(f"{prefix} does not match any keys", file=sys.stderr)
        sys.exit(0)
    for k in matching:
        print(k)


def dumpconfig_cmd(args, conf):
    """Dump the full config."""
    yaml = YAML()
    yaml.dump(conf, sys.stdout)


def main():
    parser = argparse.ArgumentParser(description="GMPFuzz configuration utility")
    parser.add_argument('--config', type=Path,
                        help="Path to config file (overrides default search)")
    parser.add_argument('-p', '--prog', type=str, action='append',
                        dest='progs', default=None,
                        help="Select programs")

    subparsers = parser.add_subparsers(dest='subcommand', required=True)

    # get command
    cmd_get = subparsers.add_parser('get', help="Get the value of a config option")
    cmd_get.add_argument('key', type=str,
                         help="Config option to get, e.g. model.endpoints.codellama")
    cmd_get.add_argument('--no-subst', action='store_true',
                         help="Don't do any substitutions")
    cmd_get.add_argument('--no-expand', action='store_true',
                         help="Don't expand ~ in paths")
    cmd_get.add_argument('--no-env', action='store_true',
                         help="Don't expand environment variables")
    cmd_get.add_argument('-s', '--substitute', type=str, action='append',
                         dest='substitutions', default=[],
                         metavar="VAR=VAL",
                         help="Substitute VAR with VAL in strings")

    # list command
    cmd_list = subparsers.add_parser('list', help="List config options")
    cmd_list.add_argument('prefix', type=str, nargs='?', default='',
                          help="Prefix to filter options")

    # dumpconfig command
    subparsers.add_parser('dumpconfig', help="Dump full config to YAML")

    args = parser.parse_args()

    # Load config
    conf = load_config()

    # If --config specified, load from that
    if args.config and args.config.exists():
        yaml = YAML(typ='safe')
        with open(args.config) as f:
            override = yaml.load(f)
            if override:
                deep_merge(conf, override)

    if args.subcommand == 'get':
        get_cmd(args, conf)
    elif args.subcommand == 'list':
        list_cmd(args, conf)
    elif args.subcommand == 'dumpconfig':
        dumpconfig_cmd(args, conf)


if __name__ == "__main__":
    main()
