#!/usr/bin/env python3
"""
prepare_fuzzbench_net.py - Build the Docker image for the MQTT fuzzing target.

Copies fuzzbench/<project_name>/ contents to a build directory and runs
docker build to create the gmpfuzz/<project_name> image.
"""

import click
import os
import os.path
import subprocess
import sys
import shutil
from util import get_config

ELMFUZZ_RUNDIR = os.environ.get('ELMFUZZ_RUNDIR', 'preset/mqtt')


def make_build_dir_net(fuzzbench_dir: str) -> str:
    """Create a build directory for network-oriented fuzzbench projects.

    Copies all files from fuzzbench/<project_name>/ into the build directory
    and writes an elm.Dockerfile (copy of Dockerfile) for building.
    """
    project_name = get_config('project_name')

    # The source directory with Dockerfile, run.sh, seeds, etc.
    src_dir = os.path.join('.', 'fuzzbench', project_name)
    # The build directory where docker build will run
    project_dir = os.path.join(fuzzbench_dir, project_name)

    if not os.path.exists(src_dir):
        raise FileNotFoundError(f"Source fuzzbench directory not found: {src_dir}")
    dockerfile_src = os.path.join(src_dir, 'Dockerfile')
    if not os.path.exists(dockerfile_src):
        raise FileNotFoundError(f"Dockerfile not found: {dockerfile_src}")

    # Ensure project_dir exists
    os.makedirs(project_dir, exist_ok=True)

    # Copy all files from fuzzbench/<project_name> into build dir
    for root, dirs, files in os.walk(src_dir):
        rel = os.path.relpath(root, src_dir)
        dst_dir = os.path.join(project_dir, rel) if rel != '.' else project_dir
        os.makedirs(dst_dir, exist_ok=True)
        for f in files:
            if f.startswith('template'):
                continue
            src_path = os.path.join(root, f)
            dst_path = os.path.join(dst_dir, f)
            shutil.copy2(src_path, dst_path)

    # Write elm.Dockerfile (a copy of the source Dockerfile)
    with open(dockerfile_src, 'r') as df_src:
        content = df_src.read()
    elm_dockerfile = os.path.join(project_dir, 'elm.Dockerfile')
    with open(elm_dockerfile, 'w') as df_dst:
        df_dst.write(content)

    return project_dir


def build_image(project_dir: str):
    """Build the Docker image using elm.Dockerfile."""
    project_name = get_config('project_name')

    cmd = [
        'docker', 'build',
        '--progress', 'plain',
        '-f', './elm.Dockerfile',
        '-t', f'gmpfuzz/{project_name}',
        '.'
    ]
    print(f"Building Docker image gmpfuzz/{project_name} in {project_dir}...")
    subprocess.run(cmd, check=True, stdout=sys.stdout, stderr=sys.stderr,
                   cwd=project_dir)
    print(f"Docker image gmpfuzz/{project_name} built successfully.")


@click.command()
@click.option('--fuzzbench-dir', '-d', 'fuzzbench_dir', type=str,
              default='/tmp/gmpfuzz_build',
              help='Directory where the Docker build context will be prepared')
@click.option('--preset-type', '-t', 'preset_type', type=str,
              default='profuzzbench',
              help='Preset type (profuzzbench, docker)')
def main(fuzzbench_dir: str, preset_type: str):
    global ELMFUZZ_RUNDIR

    if preset_type == 'profuzzbench':
        project_dir = make_build_dir_net(fuzzbench_dir)
        build_image(project_dir)
    elif preset_type == 'docker':
        build_image(ELMFUZZ_RUNDIR)
    else:
        print(f"Unknown preset type: {preset_type}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    ELMFUZZ_RUNDIR = os.environ.get('ELMFUZZ_RUNDIR', 'preset/mqtt')
    main()
