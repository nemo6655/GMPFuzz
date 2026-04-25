#!/usr/bin/env bash
# Clean generated preset artifacts for all targets.
#
# This will remove the following within each subfolder of preset/:
#   - gen* (any folder/file starting with "gen")
#   - initial
#   - stamps
#
# Usage:
#   ./clean_preset.sh            # clean all targets (default)
#   ./clean_preset.sh all        # clean all targets
#   ./clean_preset.sh mqtt       # clean only preset/mqtt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESET_DIR="${SCRIPT_DIR}/../preset"

if [ ! -d "$PRESET_DIR" ]; then
    echo "ERROR: preset directory not found: $PRESET_DIR"
    exit 1
fi

if [ "$#" -eq 0 ] || [ "$1" = "all" ]; then
    TARGETS=("$(ls -1 "$PRESET_DIR" | tr '\n' ' ')")
else
    TARGETS=()
    for arg in "$@"; do
        TARGETS+=("$arg")
    done
fi

echo "Cleaning preset directory: $PRESET_DIR"

shopt -s nullglob
for target in "${TARGETS[@]}"; do
    target_dir="$PRESET_DIR/$target"
    if [ ! -d "$target_dir" ]; then
        echo "- Skipping: target directory not found: $target"
        continue
    fi

    echo "- Processing: $target"
    rm -rf "$target_dir"/gen* "$target_dir"/initial "$target_dir"/stamps "$target_dir"/ase*
done
shopt -u nullglob

echo "Done."
