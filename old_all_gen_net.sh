#!/bin/bash
# all_gen_net.sh - Main orchestration script for GMPFuzz.
#
# Usage: ./all_gen_net.sh <rundir> [start_gen]
#
# This script:
# 1. Reads config from <rundir>/config.yaml
# 2. Builds the Docker image (gmpfuzz/mqtt)
# 3. Creates initial seeds from raw files using seed_gen_mqtt.py
# 4. Runs do_gen_net.sh for each generation (initial -> gen0 -> gen1 -> ...)
# 5. Runs do_gen_net_finial.sh for the last generation
#
# Each generation:
#   - Selects best seeds (lattice/elite/best_of_gen)
#   - Generates variants via LLM
#   - Runs aflnet in parallel Docker containers
#   - Collects coverage

set -euo pipefail

if [ "$#" -eq 1 ]; then
    start_gen=-1
elif [ "$#" -eq 2 ]; then
    start_gen=$2
else
    echo "Usage: $0 rundir [start_gen]"
    exit 1
fi

# ELMFUZZ_RUNDIR is used by elmconfig.py to find config.yaml
export ELMFUZZ_RUNDIR="$1"
export ELMFUZZ_RUN_NAME=$(basename "$ELMFUZZ_RUNDIR")

seeds=$(./elmconfig.py get run.seeds)
if [ -n "${NUM_GENERATIONS:-}" ]; then
    max_gens=${NUM_GENERATIONS}
else
    max_gens=$(./elmconfig.py get run.max_generations 2>/dev/null || ./elmconfig.py get run.num_generations 2>/dev/null || echo 20)
fi

# ASE-driven dynamic generation count
# max_gens is now a HARD UPPER LIMIT, not the target count.
# The actual number of generations is decided by ASE's should_continue().
GMPFUZZ_ASE="${GMPFUZZ_ASE:-1}"
ASE_STATE_FILE="${ELMFUZZ_RUNDIR}/ase_state.json"

# For backward compat: last_gen is used in cleanup logic below
last_gen=$((max_gens - 1))

genout_dir=$(./elmconfig.py get run.genoutput_dir -s GEN=. -s MODEL=.)
export ENDPOINTS=$(./elmconfig.py get model.endpoints)
export TYPE=$(./elmconfig.py get type)
export PROJECT_NAME=$(./elmconfig.py get project_name)

# Normalize the path
genout_dir=$(realpath -m "$genout_dir")

# Check if we should remove the output dirs if they exist
should_clean=$(./elmconfig.py get run.clean)
if [ -d "$genout_dir" ]; then
    if [ "$should_clean" == "True" ]; then
        echo "Removing generated outputs in $genout_dir"
        rm -rf "$genout_dir"
    else
        echo "Generated output directory $genout_dir already exists; exiting."
        echo "Set run.clean to True to remove existing rundirs."
        exit 1
    fi
fi

# Clean up existing gen*, initial, stamps directories if starting fresh
if [ $start_gen -eq -1 ]; then
    for pat in "gen*" "initial" "stamps"; do
        if compgen -G "$ELMFUZZ_RUNDIR"/$pat > /dev/null; then
            if [ "$should_clean" == "True" ]; then
                echo "Removing existing rundir(s):" "$ELMFUZZ_RUNDIR"/$pat
                rm -rf "$ELMFUZZ_RUNDIR"/$pat
            else
                echo "Found existing rundir(s):" "$ELMFUZZ_RUNDIR"/$pat
                echo "Set run.clean to True to remove existing rundirs."
                exit 1
            fi
        fi
    done
else
    for g in $(seq $start_gen $((last_gen+1))); do
        if [ -d "$ELMFUZZ_RUNDIR/gen$g" ]; then
            if [ "$should_clean" == "True" ]; then
                echo "Removing existing rundir(s):" "$ELMFUZZ_RUNDIR/gen$g"
                rm -rf "$ELMFUZZ_RUNDIR/gen$g"
            else
                echo "Found existing rundir(s):" "$ELMFUZZ_RUNDIR/gen$g"
                echo "Set run.clean to True to remove existing rundirs."
                exit 1
            fi
        fi
        if [ -f "$ELMFUZZ_RUNDIR/stamps/gen$g.stamp" ]; then
            if [ "$should_clean" == "True" ]; then
                rm -rf "$ELMFUZZ_RUNDIR/stamps/gen$g.stamp"
            fi
        fi
    done
fi

# Reset ASE state when starting fresh (prevents stale budget from previous runs)
if [ $start_gen -eq -1 ] && [ "$should_clean" == "True" ] && [ -f "$ASE_STATE_FILE" ]; then
    echo "Removing stale ASE state: $ASE_STATE_FILE"
    rm -f "$ASE_STATE_FILE"
fi

# Step 1: Build the Docker image
if [ "$TYPE" == "profuzzbench" ]; then
    python prepare_fuzzbench_net.py -t profuzzbench
elif [ "$TYPE" == "docker" ]; then
    python prepare_fuzzbench_net.py -t docker
fi

# Step 2: Run generations (dynamic count driven by ASE budget)
if [ $start_gen -eq -1 ]; then
    # Create initial directory structure
    mkdir -p "$ELMFUZZ_RUNDIR"/initial/{variants,seeds,logs,aflnetout}
    mkdir -p "$ELMFUZZ_RUNDIR"/stamps
    mkdir -p "$ELMFUZZ_RUNDIR"/initial/seeds/0000
    mkdir -p "$ELMFUZZ_RUNDIR"/initial/variants/0000

    # Copy raw seeds to initial/seeds/0000/
    cp -r $seeds/* "${ELMFUZZ_RUNDIR}/initial/seeds/0000/" 2>/dev/null || true

    # Convert raw seeds to Python generator files
    PROTOCOL_TYPE=$(./elmconfig.py get protocol_type)
    python "$ELMFUZZ_RUNDIR"/seed_gen_${PROTOCOL_TYPE}.py \
        --input_seeds "$ELMFUZZ_RUNDIR"/initial/seeds/0000/ \
        --init_variants "$ELMFUZZ_RUNDIR"/initial/variants/0000/

    # Run initial -> gen0
    ./do_gen_net.sh initial gen0

    # Dynamic generation loop: continue as long as ASE says budget remains
    current_gen=0
    while true; do
        next_gen=$((current_gen + 1))

        # Check if ASE says we should continue (budget-aware)
        if [ "$GMPFUZZ_ASE" != "0" ] && [ -f "$ASE_STATE_FILE" ]; then
            ASE_RESULT=$(python ase.py should-continue \
                --current-gen "$current_gen" \
                --max-gens "$max_gens" \
                --state-file "$ASE_STATE_FILE" 2>&1) || {
                echo "[ASE] Budget exhausted or max generations reached."
                echo "$ASE_RESULT"
                break
            }
            echo "[ASE] $ASE_RESULT"
        else
            # No ASE: use fixed max_gens
            if [ "$current_gen" -ge "$last_gen" ]; then
                break
            fi
        fi

        # Run gen{current} -> gen{next}
        ./do_gen_net.sh gen${current_gen} gen${next_gen}
        current_gen=$next_gen
    done

    # Final generation: collect & merge queue
    final_gen=$current_gen
    final_next=$((final_gen + 1))
    ./do_gen_net_finial.sh gen${final_gen} gen${final_next}

    actual_gens=$final_gen
else
    if [ $start_gen -eq 0 ]; then
        real_start_gen=0
        ./do_gen_net.sh initial gen0
    else
        real_start_gen=$((start_gen-1))
    fi

    # Dynamic loop from resume point
    current_gen=$real_start_gen
    while true; do
        next_gen=$((current_gen + 1))

        # Check ASE budget
        if [ "$GMPFUZZ_ASE" != "0" ] && [ -f "$ASE_STATE_FILE" ]; then
            ASE_RESULT=$(python ase.py should-continue \
                --current-gen "$current_gen" \
                --max-gens "$max_gens" \
                --state-file "$ASE_STATE_FILE" 2>&1) || {
                echo "[ASE] Budget exhausted or max generations reached."
                echo "$ASE_RESULT"
                break
            }
            echo "[ASE] $ASE_RESULT"
        else
            if [ "$current_gen" -ge "$last_gen" ]; then
                break
            fi
        fi

        ./do_gen_net.sh gen${current_gen} gen${next_gen}
        current_gen=$next_gen
    done

    actual_gens=$current_gen
fi

echo "==============================================="
echo "GMPFuzz run completed: ${actual_gens} generations (max: ${max_gens})"
echo "Results in: $ELMFUZZ_RUNDIR"
echo "==============================================="
