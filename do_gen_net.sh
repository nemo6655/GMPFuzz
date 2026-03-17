#!/bin/bash
# do_gen_net.sh - Execute a single generation of the GMPFuzz evolutionary loop.
#
# Usage: ./do_gen_net.sh <prev_gen> <next_gen>
#
# This script:
# 1. Selects seeds from the previous generation (lattice/elite/best_of_gen)
# 2. Converts raw seeds to Python generators via seed_gen_mqtt.py
# 3. Generates LLM variants via genvariants_parallel_net.py
# 4. Executes variants to produce raw outputs via genoutputs_net.py
# 5. Launches parallel Docker containers with aflnet via getcov_fuzzbench_net.py
# 6. Collects and plots coverage

set -euo pipefail

prev_gen="$1"
next_gen="$2"

seeds=$(./elmconfig.py get run.seeds)
num_gens=$(./elmconfig.py get run.max_generations 2>/dev/null || ./elmconfig.py get run.num_generations 2>/dev/null || echo 20)

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
COLOR_YELLOW='\033[0;33m'
COLOR_RESET='\033[0m'

printf "$COLOR_GREEN"'============> %s: %6s -> %6s of %3d <============'"$COLOR_RESET"'\n' \
    $ELMFUZZ_RUN_NAME $prev_gen $next_gen $num_gens
echo "Running generation $next_gen using $MODELS with $NUM_VARIANTS variants per seed"
if [ -n "$GMPFUZZ_FORBIDDEN" ]; then
    printf "${COLOR_YELLOW}Ablation: FORBIDDEN=%s ASE=%s${COLOR_RESET}\n" "$GMPFUZZ_FORBIDDEN" "$GMPFUZZ_ASE"
fi

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
# Step 1: Select seeds for the next generation
# =====================================================================
if [ "$prev_gen" == "initial" ]; then
    echo "First generation; using initial seed(s):" "$ELMFUZZ_RUNDIR"/init_seeds/*.raw 2>/dev/null || echo "(from preset)"
    STATE_POOLS=('0000')
else
    # Determine selection strategy
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
        # Compute prev_prev_gen for lattice strategy
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

        # Ensure input elites file exists
        if [ ! -f "$input_elite_file" ]; then
            mkdir -p "$(dirname "$input_elite_file")"
            : > "$input_elite_file"
        fi

        # Run ILP/greedy seed selection
        python select_seeds_net.py -u -g $prev_gen -n $NUM_SELECTED \
            -c $cov_file -i $input_elite_file -o $output_elite_file

        # Run state-aware selection (PASD algorithm)
        # GMPFUZZ_FORBIDDEN may be comma-separated (e.g., "NOSS,NOSM")
        if [[ "$GMPFUZZ_FORBIDDEN" == *"NOSS"* ]]; then
            echo "[PASD] Disabled → uniform distribution (--noss)"
            python select_states_net.py -c $cov_file -e $output_elite_file \
                -g $prev_gen --noss
        elif [[ "$GMPFUZZ_FORBIDDEN" == *"NOMQTT"* ]]; then
            echo "[PASD] MQTT zones disabled → rarity-only (--ss)"
            python select_states_net.py -c $cov_file -e $output_elite_file \
                -g $prev_gen --ss
        else
            echo "[PASD] Full MQTT-aware distribution (--mqtt)"
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

VARIANT_ARGS="-n ${NUM_VARIANTS}"

echo "Generating next generation: ${NUM_VARIANTS} variants for each seed with each model"

# =====================================================================
# Step 2: For each model and state pool, generate variants and outputs
# =====================================================================
for model_name in $MODELS; do
    for state_name in "${STATE_POOLS[@]}"; do
        MODEL=$(basename "$model_name")
        GVLOG="${LOGDIR}/meta"
        GOLOG="${LOGDIR}/outputgen_${MODEL}.jsonl"
        GVOUT=$(./elmconfig.py get run.genvariant_dir -s MODEL=${MODEL} -s GEN=${prev_gen})
        GOOUT=$(./elmconfig.py get run.genoutput_dir -s MODEL=${MODEL} -s GEN=${prev_gen})

        echo "====================== $model_name:$state_name ======================"

        # Convert raw seeds to Python generators
        python "$ELMFUZZ_RUNDIR"/seed_gen_${PROTOCOL_TYPE}.py \
            --input_seeds "${GOOUT}/${state_name}/" \
            --init_variants "${GVOUT}/${state_name}/"

        # Count existing seed generator files
        count=$(find "${GVOUT}/${state_name}/" -name "${PROTOCOL_TYPE}_*.py" ! -name "*seed*" 2>/dev/null | wc -l)

        # Execute seed generators to produce raw outputs
        (echo "$count"; find "${GVOUT}/${state_name}/" -name "${PROTOCOL_TYPE}_*.py" ! -name "*seed*" 2>/dev/null) | \
            python genoutputs_net.py \
                -L "${GOLOG}_init" \
                -O "${GOOUT}/${state_name}/" \
                -g "${prev_gen}"

        # Generate LLM variants (skip if NOSM in GMPFUZZ_FORBIDDEN)
        if [[ "$GMPFUZZ_FORBIDDEN" != *"NOSM"* ]]; then
            # Use 'timeout' to prevent indefinitely hanging due to pipe deadlocks or unclosed sockets
            timeout -k 60 3600 bash -c "python genvariants_parallel_net.py \
                $VARIANT_ARGS \
                -M \"${model_name}\" \
                -O \"${GVOUT}/${state_name}/\" \
                -L \"${GVLOG}\" \
                \"${GVOUT}\"/${state_name}/*.py \
            | python genoutputs_net.py \
                -L \"${GOLOG}\" \
                -O \"${GOOUT}/${state_name}/\" \
                -g \"${prev_gen}\"" || echo "[WARN] Timeout evaluating LLM generations for pool ${state_name}!"
        fi

        # Copy original raw seeds to output directory
        cp -r $seeds/* "${GOOUT}/${state_name}/" 2>/dev/null || true
    done
done

# =====================================================================
# Step 3: Collect coverage via parallel Docker containers
# =====================================================================
echo "Collecting coverage of the generators"
all_models_genout_dir=$(realpath -m "$GOOUT")

# Record start time immediately before aflnet launch (LLM time excluded)
GEN_START_EPOCH=$(date +%s)

case "$TYPE" in
    profuzzbench|docker)
        # Build ASE arguments if state file exists or ASE is enabled
        ASE_ARGS=""
        ASE_STATE_FILE="${ELMFUZZ_RUNDIR}/ase_state.json"
        if [ "$GMPFUZZ_ASE" != "0" ]; then
            ASE_ARGS="--ase-state ${ASE_STATE_FILE} --num-total-gens ${num_gens}"
            echo "[ASE] Adaptive epoch scheduling enabled (state: ${ASE_STATE_FILE})"
        fi

        python getcov_fuzzbench_net.py \
            --image gmpfuzz/"$PROJECT_NAME" \
            --input "$all_models_genout_dir" \
            --output "${AFLNET_OUT}" \
            --covfile "${LOGDIR}/coverage.json" \
            --next_gen "${next_gen#gen}" \
            --gen-start-time "${GEN_START_EPOCH}" \
            ${ASE_ARGS}
        ;;
    *)
        echo "Unknown type: $TYPE"
        exit 1
        ;;
esac

# Plot coverage
python analyze_cov.py -m $num_gens -p "$ELMFUZZ_RUNDIR"/*/logs/coverage.json 2>/dev/null || true

# Mark this generation as finished
touch "$ELMFUZZ_RUNDIR"/stamps/${next_gen}.stamp
echo "Generation ${next_gen} completed."
