#!/bin/bash
# ============================================================
# run_experiment.sh - Multi-Target MQTT Fuzzer Comparison Experiment
#
# Launches up to 4 fuzzers in parallel targeting MQTT brokers.
# GMPFuzz and MPFuzz each have internal parallelism (4 agents),
# so they run a single instance. AFLNet and Peach are single-
# threaded, so they run N independent containers (default 4).
#
# Fuzzers:
#   1. GMPFuzz (ours)  - Docker gmpfuzz/<target>, 1 run (4 internal pools)
#   2. AFLNet          - Docker ProFuzzBench images (mosquitto/mongoose/nanomq), N containers
#   3. MPFuzz          - Docker mpfuzz/<target>, 1 run (4 internal agents)
#   4. Peach           - Docker mpfuzz/<target>, N containers
#
# Coverage:
#   AFLNet & GMPFuzz: gcov line/branch coverage (via cov_script inside container)
#   MPFuzz & Peach:   gcov line/branch coverage (via tcpdump pcap replay post-fuzzing)
#                     + edge count as secondary metric
#
# Usage:
#   ./run_experiment.sh [options]
#
# Options:
#   -t, --target TARGET  Fuzzing target: mqtt, mongoose, nanomq (default: mqtt)
#   --timeout SEC        Fuzzing timeout in seconds (default: 86400 = 24h)
#   -n, --num-inst N     AFLNet/Peach instances (default: 4)
#   -o, --output DIR     Output directory (default: results_YYYYMMDD_HHMMSS)
#   -s, --skip FUZZER    Skip specific fuzzer (can repeat: -s peach -s mpfuzz)
#   --only FUZZER        Run only this fuzzer (aflnet|gmpfuzz|mpfuzz|peach)
#   --no-plot            Skip plot generation
#   --dry-run            Print what would be done without executing
#   -h, --help           Show this help
#
# Examples:
#   ./run_experiment.sh                                # mqtt, full 24h
#   ./run_experiment.sh -t mongoose --timeout 3600     # mongoose, 1h test
#   ./run_experiment.sh -t nanomq --only aflnet -n 2   # nanomq, AFLNet only
#   ./run_experiment.sh -s peach -s mpfuzz             # mqtt, skip Peach+MPFuzz
# ============================================================
set -uo pipefail
# Note: -e is intentionally NOT set. Individual fuzzer failures should
# not abort the entire experiment orchestrator.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =====================================================================
# Parse arguments
# =====================================================================
TARGET="mqtt"
TIMEOUT=86400
NUM_INSTANCES=4
OUTPUT_DIR=""
SKIP_FUZZERS=()
ONLY_FUZZER=""
NO_PLOT=0
DRY_RUN=0

show_help() {
    sed -n '2,39p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)     TARGET="$2"; shift 2 ;;
        --timeout)       TIMEOUT="$2"; shift 2 ;;
        -n|--num-inst)   NUM_INSTANCES="$2"; shift 2 ;;
        -o|--output)     OUTPUT_DIR="$2"; shift 2 ;;
        -s|--skip)       SKIP_FUZZERS+=("$2"); shift 2 ;;
        --only)          ONLY_FUZZER="$2"; shift 2 ;;
        --no-plot)       NO_PLOT=1; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       show_help ;;
        *)               echo "Unknown option: $1"; show_help ;;
    esac
done

# Target description
case "$TARGET" in
    mqtt)      TARGET_DESC="Mosquitto v1.5.5" ;;
    mongoose)  TARGET_DESC="Mongoose v7.20" ;;
    nanomq)    TARGET_DESC="NanoMQ v0.21.10" ;;
    *)
        echo "ERROR: Unknown target '${TARGET}'. Supported: mqtt, mongoose, nanomq"
        exit 1
        ;;
esac

# MPFuzz and Peach now support all targets (mqtt, mongoose, nanomq)

# Default output directory with timestamp
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="${SCRIPT_DIR}/../evaluation/results_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"
# Ensure absolute path so child scripts that cd elsewhere still work
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# Determine which fuzzers to run
should_run() {
    local fuzzer=$1
    if [ -n "$ONLY_FUZZER" ]; then
        [ "$fuzzer" = "$ONLY_FUZZER" ] && return 0 || return 1
    fi
    for skip in "${SKIP_FUZZERS[@]+"${SKIP_FUZZERS[@]}"}"; do
        [ "$fuzzer" = "$skip" ] && return 1
    done
    return 0
}

# Calculate resource usage
TIMEOUT_H=$(echo "scale=1; $TIMEOUT/3600" | bc)
TOTAL_CONTAINERS=0
FUZZERS_TO_RUN=()
for f in gmpfuzz aflnet mpfuzz peach; do
    if should_run "$f"; then
        FUZZERS_TO_RUN+=("$f")
        case "$f" in
            gmpfuzz) TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + 4)) ;;
            mpfuzz)  TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + 1)) ;;
            aflnet|peach) TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + NUM_INSTANCES)) ;;
        esac
    fi
done

# =====================================================================
# Print experiment plan
# =====================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Multi-Target MQTT Fuzzer Comparison Experiment          ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                             ║"
printf "║  %-57s  ║\n" "Target:     ${TARGET} (${TARGET_DESC})"
printf "║  %-57s  ║\n" "Duration:   ${TIMEOUT}s (${TIMEOUT_H}h)"
printf "║  %-57s  ║\n" "AFLNet/Peach: ${NUM_INSTANCES} instances; GMPFuzz/MPFuzz: 1 run (4 internal)"
printf "║  %-57s  ║\n" "Fuzzers:    ${FUZZERS_TO_RUN[*]}"
printf "║  %-57s  ║\n" "Containers: ~${TOTAL_CONTAINERS} Docker containers"
printf "║  %-57s  ║\n" "Output:     ${OUTPUT_DIR}"
printf "║  %-57s  ║\n" "Start:      $(date '+%Y-%m-%d %H:%M:%S')"
echo "║                                                             ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Fuzzer     | Image              | Coverage                 ║"
echo "║  -----------|--------------------|------------------------- ║"
printf "║  GMPFuzz    | gmpfuzz/%-10s | gcov (line+branch)       ║\n" "${TARGET}"

# AFLNet uses ProFuzzBench images: mqtt->mosquitto, mongoose->mongoose, nanomq->nanomq
case "$TARGET" in
    mqtt)     AFLNET_IMAGE="mosquitto" ;;
    mongoose) AFLNET_IMAGE="mongoose" ;;
    nanomq)   AFLNET_IMAGE="nanomq" ;;
esac
printf "║  AFLNet     | %-18s | gcov (line+branch)       ║\n" "${AFLNET_IMAGE}"
printf "║  MPFuzz     | mpfuzz/%-11s | edge only                ║\n" "${TARGET}"
printf "║  Peach      | mpfuzz/%-11s | edge only                ║\n" "${TARGET}"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY RUN] Would execute the following:"
    for f in "${FUZZERS_TO_RUN[@]}"; do
        case "$f" in
            gmpfuzz)
                echo "  - ${f}: 1 run (4 internal pools), ${TIMEOUT}s, target=${TARGET}"
                echo "    bash ${SCRIPT_DIR}/run_gmpfuzz_bench.sh -t ${TARGET} -o ${OUTPUT_DIR}/gmpfuzz"
                ;;
            aflnet)
                echo "  - ${f}: ${NUM_INSTANCES} containers, ${TIMEOUT}s, target=${TARGET}"
                echo "    bash ${SCRIPT_DIR}/run_aflnet.sh -t ${TARGET} -n ${NUM_INSTANCES} --timeout ${TIMEOUT} -o ${OUTPUT_DIR}/aflnet"
                ;;
            mpfuzz)
                echo "  - ${f}: 1 run (4 internal agents), ${TIMEOUT}s, target=${TARGET}"
                echo "    bash ${SCRIPT_DIR}/run_mpfuzz_bench.sh -t ${TARGET} --timeout ${TIMEOUT} -o ${OUTPUT_DIR}/mpfuzz"
                ;;
            peach)
                echo "  - ${f}: ${NUM_INSTANCES} containers, ${TIMEOUT}s, target=${TARGET}"
                echo "    bash ${SCRIPT_DIR}/run_peach.sh -t ${TARGET} -n ${NUM_INSTANCES} --timeout ${TIMEOUT} -o ${OUTPUT_DIR}/peach"
                ;;
        esac
    done
    exit 0
fi

# =====================================================================
# Preflight checks
# =====================================================================
echo "[Preflight] Checking Docker images..."
MISSING=0
IMAGES_TO_CHECK=("gmpfuzz/${TARGET}")

# AFLNet uses ProFuzzBench images
case "$TARGET" in
    mqtt)     IMAGES_TO_CHECK+=("mosquitto") ;;
    mongoose) IMAGES_TO_CHECK+=("mongoose") ;;
    nanomq)   IMAGES_TO_CHECK+=("nanomq") ;;
esac

for f in "${FUZZERS_TO_RUN[@]}"; do
    case "$f" in
        mpfuzz|peach)
            if [[ ! " ${IMAGES_TO_CHECK[*]} " =~ " mpfuzz/${TARGET} " ]]; then
                IMAGES_TO_CHECK+=("mpfuzz/${TARGET}")
            fi
            ;;
    esac
done

for img in "${IMAGES_TO_CHECK[@]}"; do
    if docker image inspect "$img" > /dev/null 2>&1; then
        echo "  ✓ $img"
    else
        echo "  ✗ $img (MISSING)"
        MISSING=1
    fi
done

if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "ERROR: Some Docker images are missing. Build them first."
    echo "  GMPFuzz:      cd $(dirname $SCRIPT_DIR)/fuzzbench/${TARGET} && docker build -t gmpfuzz/${TARGET} ."
    echo "  AFLNet (PFB): cd \$PFBENCH/subjects/MQTT/<Target> && bash sync-aflnet.sh && docker build -t <image> ."
    echo "  MPFuzz:       cd $(dirname $SCRIPT_DIR)/benchmark/mpfuzz_${TARGET} && docker build -t mpfuzz/${TARGET} ."
    exit 1
fi

echo "[Preflight] Checking system resources..."
NCPU=$(nproc)
MEM_GB=$(free -g | awk '/Mem:/{print $7}')
echo "  CPUs: ${NCPU} | Available RAM: ${MEM_GB}GB"
echo "  Estimated CPU need: ~${TOTAL_CONTAINERS} cores"
if [ "$TOTAL_CONTAINERS" -gt "$NCPU" ]; then
    echo "  WARNING: More containers than CPUs. Performance may degrade."
fi

# Save experiment config
cat > "${OUTPUT_DIR}/experiment_config.json" << EOF
{
    "start_time": "$(date -Iseconds)",
    "target": "${TARGET}",
    "target_description": "${TARGET_DESC}",
    "timeout_seconds": ${TIMEOUT},
    "aflnet_peach_instances": ${NUM_INSTANCES},
    "gmpfuzz_internal_pools": 4,
    "mpfuzz_internal_agents": 4,
    "fuzzers": [$(printf '"%s",' "${FUZZERS_TO_RUN[@]}" | sed 's/,$//')],
    "protocol": "MQTT",
    "host_cpus": ${NCPU},
    "host_mem_gb": ${MEM_GB}
}
EOF

# =====================================================================
# Launch all fuzzers in parallel
# =====================================================================
MAIN_START=$(date +%s)
PIDS=()
FUZZER_PIDS=()

launch_fuzzer() {
    local fuzzer=$1
    local log="${OUTPUT_DIR}/${fuzzer}_runner.log"

    echo "[$(date '+%H:%M:%S')] Launching ${fuzzer}..."

    case "$fuzzer" in
        gmpfuzz)
            bash "${SCRIPT_DIR}/run_gmpfuzz_bench.sh" \
                -t "$TARGET" -o "${OUTPUT_DIR}/gmpfuzz" \
                > "$log" 2>&1 &
            ;;
        aflnet)
            bash "${SCRIPT_DIR}/run_aflnet.sh" \
                -t "$TARGET" -n "$NUM_INSTANCES" --timeout "$TIMEOUT" \
                -o "${OUTPUT_DIR}/aflnet" \
                > "$log" 2>&1 &
            ;;
        mpfuzz)
            bash "${SCRIPT_DIR}/run_mpfuzz_bench.sh" \
                -t "$TARGET" --timeout "$TIMEOUT" -o "${OUTPUT_DIR}/mpfuzz" \
                > "$log" 2>&1 &
            ;;
        peach)
            bash "${SCRIPT_DIR}/run_peach.sh" \
                -t "$TARGET" -n "$NUM_INSTANCES" --timeout "$TIMEOUT" \
                -o "${OUTPUT_DIR}/peach" \
                > "$log" 2>&1 &
            ;;
    esac

    local pid=$!
    PIDS+=($pid)
    FUZZER_PIDS+=("${fuzzer}:${pid}")
    echo "  ${fuzzer} PID: ${pid} | Log: ${log}"
}

for f in "${FUZZERS_TO_RUN[@]}"; do
    launch_fuzzer "$f"
    sleep 5  # Stagger by 5 seconds
done

echo ""
echo "All fuzzers launched. PIDs: ${PIDS[*]}"
echo "Monitoring progress... (Ctrl+C to cancel)"
echo ""

# =====================================================================
# Monitor progress
# =====================================================================
monitor_interval=1800  # Every 30 minutes

while true; do
    sleep $monitor_interval

    ELAPSED=$(( $(date +%s) - MAIN_START ))
    ELAPSED_H=$(echo "scale=1; $ELAPSED/3600" | bc)

    echo ""
    echo "━━━━━ Progress Report (${ELAPSED_H}h elapsed) ━━━━━"

    ALL_DONE=true
    for fp in "${FUZZER_PIDS[@]}"; do
        fname="${fp%%:*}"
        fpid="${fp##*:}"
        if kill -0 "$fpid" 2>/dev/null; then
            ALL_DONE=false
            echo "  ${fname}: RUNNING (PID ${fpid})"
        else
            wait "$fpid" 2>/dev/null
            EXIT=$?
            echo "  ${fname}: FINISHED (exit=${EXIT})"
        fi
    done

    if $ALL_DONE; then
        echo ""
        echo "All fuzzers have completed!"
        break
    fi
done

# =====================================================================
# Post-processing
# =====================================================================
MAIN_ELAPSED=$(( $(date +%s) - MAIN_START ))
MAIN_ELAPSED_H=$(echo "scale=1; $MAIN_ELAPSED/3600" | bc)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Experiment Complete - Collecting Coverage"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Collect unified coverage summary
echo ""
echo "[$(date '+%H:%M:%S')] Running unified coverage collection..."
bash "${SCRIPT_DIR}/collect_coverage.sh" -t "$TARGET" "$OUTPUT_DIR" \
    > "${OUTPUT_DIR}/coverage_collection.log" 2>&1 || true

# Generate plots
if [ "$NO_PLOT" -eq 0 ]; then
    echo "[$(date '+%H:%M:%S')] Generating result plots..."
    python3 "${SCRIPT_DIR}/plot_results.py" "$OUTPUT_DIR" \
        > "${OUTPUT_DIR}/plot_generation.log" 2>&1 || true
fi

# Save end time
cat > "${OUTPUT_DIR}/experiment_complete.json" << EOF
{
    "end_time": "$(date -Iseconds)",
    "target": "${TARGET}",
    "total_elapsed_seconds": ${MAIN_ELAPSED},
    "total_elapsed_hours": ${MAIN_ELAPSED_H}
}
EOF

# =====================================================================
# Final Summary
# =====================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  Experiment Complete                        ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-57s  ║\n" "Target:      ${TARGET} (${TARGET_DESC})"
printf "║  %-57s  ║\n" "Total Time:  ${MAIN_ELAPSED}s (${MAIN_ELAPSED_H}h)"
printf "║  %-57s  ║\n" "Output:      ${OUTPUT_DIR}"
echo "║                                                             ║"
echo "║  Results:                                                   ║"

for f in "${FUZZERS_TO_RUN[@]}"; do
    FDIR="${OUTPUT_DIR}/${f}"
    if [ -d "$FDIR" ]; then
        INST_COUNT=$(find "$FDIR" -maxdepth 1 -name "instance_*" -type d | wc -l)
        printf "║    %-55s  ║\n" "${f}: ${INST_COUNT} instances collected"
    fi
done

echo "║                                                             ║"
if [ -f "${OUTPUT_DIR}/coverage_summary.csv" ]; then
    printf "║  %-57s  ║\n" "Coverage CSV: coverage_summary.csv"
fi
if [ -d "${OUTPUT_DIR}/plots" ]; then
    printf "║  %-57s  ║\n" "Plots:       plots/"
fi

echo "║                                                             ║"
echo "║  To regenerate plots:                                       ║"
printf "║    %-55s  ║\n" "python3 experiments/plot_results.py ${OUTPUT_DIR}"
echo "╚══════════════════════════════════════════════════════════════╝"
