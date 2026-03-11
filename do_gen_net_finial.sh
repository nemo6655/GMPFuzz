#!/bin/bash
# do_gen_net_finial.sh - Execute the final generation (selection only, no new variants).
#
# Usage: ./do_gen_net_finial.sh <prev_gen> <next_gen>
#
# This is the final step of the evolutionary loop. It performs seed selection
# from the last generation to produce the final optimized seed corpus,
# but does NOT generate new LLM variants or run aflnet again.

set -euo pipefail

prev_gen="$1"
next_gen="$2"

num_gens=$(./elmconfig.py get run.num_generations)

MODELS=$(./elmconfig.py get model.names)
NUM_VARIANTS=$(./elmconfig.py get cli.genvariants_parallel.num_variants)
LOGDIR=$(./elmconfig.py get run.logdir -s GEN=${next_gen})
NUM_SELECTED=$(./elmconfig.py get run.num_selected)
STATE_POOLS=($(./elmconfig.py get run.state_pools))
PROTOCOL_TYPE=$(./elmconfig.py get protocol_type)
GMPFUZZ_FORBIDDEN="${GMPFUZZ_FORBIDDEN:-}"
GMPFUZZ_ASE="${GMPFUZZ_ASE:-1}"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_RESET='\033[0m'

printf "$COLOR_GREEN"'============> %s: %6s -> %6s of %3d Final Selection <============'"$COLOR_RESET"'\n' \
    $ELMFUZZ_RUN_NAME $prev_gen $next_gen $num_gens
echo "Final generation $next_gen - performing seed selection only"

# Create the next generation directory structure
mkdir -p "$ELMFUZZ_RUNDIR"/${next_gen}/{variants,seeds,logs,aflnetout}
AFLNET_OUT="$ELMFUZZ_RUNDIR"/${next_gen}/aflnetout

# Create state pool subdirectories
for pool in "${STATE_POOLS[@]}"; do
    echo "Creating state pool directories for '$pool' in generation ${next_gen}"
    mkdir -p "$ELMFUZZ_RUNDIR"/${next_gen}/seeds/${pool}
    mkdir -p "$ELMFUZZ_RUNDIR"/${next_gen}/variants/${pool}
done

seed_num=1

# =====================================================================
# Seed Selection (same logic as do_gen_net.sh)
# =====================================================================
if [ "$prev_gen" == "initial" ]; then
    echo "First generation; using initial seed(s)"
    STATE_POOLS=('0000')
else
    if [ -n "${SELECTION_STRATEGY:-}" ]; then
        selection_strategy="$SELECTION_STRATEGY"
    else
        selection_strategy=$(./elmconfig.py get run.selection_strategy)
    fi

    if [ "$selection_strategy" == "elites" ]; then
        echo "$selection_strategy: Selecting best seeds from all generations"
        cov_files=("$ELMFUZZ_RUNDIR"/*/logs/coverage.json)
    elif [ "$selection_strategy" == "best_of_generation" ]; then
        echo "$selection_strategy: Selecting best seeds from previous generation"
        cov_files=("$ELMFUZZ_RUNDIR/${prev_gen}/logs/coverage.json")
    elif [ "$selection_strategy" == "lattice" ]; then
        echo "$selection_strategy: Selecting seeds from the lattice"
    else
        echo "Unknown selection strategy $selection_strategy; exiting"
        exit 1
    fi

    if [ "$selection_strategy" == "lattice" ]; then
        if [[ "${prev_gen}" == "gen0" ]]; then
            prev_prev_gen="$prev_gen"
        else
            prev_num=${prev_gen#gen}
            prev_prev_gen="gen$((prev_num - 1))"
        fi
        echo "Using prev_prev_gen: $prev_prev_gen"

        cov_file="${ELMFUZZ_RUNDIR}/${prev_gen}/logs/coverage.json"
        input_elite_file="${ELMFUZZ_RUNDIR}/${prev_prev_gen}/logs/elites.json"
        output_elite_file="${ELMFUZZ_RUNDIR}/${prev_gen}/logs/elites.json"

        if [ ! -f "$input_elite_file" ]; then
            mkdir -p "$(dirname "$input_elite_file")"
            : > "$input_elite_file"
        fi

        python select_seeds_net.py -u -g $prev_gen -n $NUM_SELECTED \
            -c $cov_file -i $input_elite_file -o $output_elite_file

        if [[ "$GMPFUZZ_FORBIDDEN" == *"NOSS"* ]]; then
            python select_states_net.py -c $cov_file -e $output_elite_file \
                -g $prev_gen --noss
        elif [[ "$GMPFUZZ_FORBIDDEN" == *"NOMQTT"* ]]; then
            python select_states_net.py -c $cov_file -e $output_elite_file \
                -g $prev_gen --ss
        else
            python select_states_net.py -c $cov_file -e $output_elite_file \
                -g $prev_gen --mqtt
        fi
    else
        python analyze_cov.py "${cov_files[@]}" | sort -n | tail -n $NUM_SELECTED | \
            while read cov gen model generator; do
                echo "Selecting $generator from $gen/$model with $cov edges covered"
                cp "$ELMFUZZ_RUNDIR"/${gen}/variants/${model}/${generator}.py \
                   "$ELMFUZZ_RUNDIR"/${next_gen}/seeds/${gen}_${model}_${generator}.py
            done
    fi
    seed_num="$(find "${ELMFUZZ_RUNDIR}/${next_gen}/seeds" -maxdepth 1 -type f -printf x | wc -c)"
fi

echo "==============================================="
echo "Final selection completed for generation ${next_gen}"
echo "Selected $seed_num seeds"
echo "==============================================="
