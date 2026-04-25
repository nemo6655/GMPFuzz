#!/bin/bash
set -eo pipefail

EVAL_DIR="/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/results_20260416_085721"

for TARGET in mpfuzz peach; do
    echo "=== Recovering $TARGET (nanomq) for $EVAL_DIR ==="
    for i in {1..4}; do
        INSTANCE_DIR="${EVAL_DIR}/${TARGET}/instance_${i}"
        [ -d "$INSTANCE_DIR" ] || continue
        echo "Processing $INSTANCE_DIR..."
        
        # mpfuzz and peach just run and generate coverage. If they don't have it, we might need to recreate them or just say we can't recover if we don't have their test cases.
        # But wait, peach and mpfuzz don't store queue/replayable files... wait, yes they do?
        ls "${INSTANCE_DIR}" || true
    done
done
