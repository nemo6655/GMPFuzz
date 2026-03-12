#!/bin/bash
# ============================================================
# run_peach.sh - Run standalone Peach/MPFuzz instances
#
# Uses the 'mpfuzz/<target>' Docker image (Peach Fuzzer v3.0 variant).
# Each instance runs in its own container with --cpus=1.
#
# NOTE: Peach (like MPFuzz) does NOT save replayable test cases.
# Only edge coverage via shared memory is available.
#
# Usage: ./run_peach.sh [options]
#   -t, --target TARGET    Fuzzing target: mqtt, mongoose, nanomq (default: mqtt)
#   -n, --num-inst N       Number of parallel containers (default: 4)
#   --timeout SEC          Fuzzing duration in seconds (default: 86400 = 24h)
#   -o, --output DIR       Host directory for results
#   -h, --help             Show this help
#
# Legacy positional usage (backward compatible):
#   ./run_peach.sh <num_instances> <timeout_sec> <output_dir>
#
# Targets:
#   mqtt      - Mosquitto v1.5.5  (mpfuzz/mqtt image)
#   mongoose  - Mongoose v7.20    (mpfuzz/mongoose image)
#   nanomq    - NanoMQ v0.21.10   (mpfuzz/nanomq image)
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =====================================================================
# Defaults
# =====================================================================
TARGET="mqtt"
NUM_INSTANCES=4
TIMEOUT=86400
OUTPUT_DIR=""
IMAGE=""

# =====================================================================
# Parse arguments
# =====================================================================
show_help() {
    sed -n '2,23p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)      TARGET="$2"; shift 2 ;;
        -n|--num-inst)    NUM_INSTANCES="$2"; shift 2 ;;
        --timeout)        TIMEOUT="$2"; shift 2 ;;
        -o|--output)      OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)        show_help ;;
        *)
            # Legacy positional args: <num_instances> <timeout> <output_dir>
            if [ -z "${_LP1:-}" ]; then _LP1=1; NUM_INSTANCES="$1"; shift
            elif [ -z "${_LP2:-}" ]; then _LP2=1; TIMEOUT="$1"; shift
            elif [ -z "${_LP3:-}" ]; then _LP3=1; OUTPUT_DIR="$1"; shift
            else echo "Unknown option: $1"; show_help; fi
            ;;
    esac
done

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(pwd)/results/peach"
fi

# Map target to Docker image and description
case "$TARGET" in
    mqtt)
        IMAGE="mpfuzz/mqtt"
        TARGET_DESC="Mosquitto v1.5.5"
        BUILD_DIR="benchmark/mpfuzz_mqtt"
        ;;
    mongoose)
        IMAGE="mpfuzz/mongoose"
        TARGET_DESC="Mongoose v7.20"
        BUILD_DIR="benchmark/mpfuzz_mongoose"
        ;;
    nanomq)
        IMAGE="mpfuzz/nanomq"
        TARGET_DESC="NanoMQ v0.21.10"
        BUILD_DIR="benchmark/mpfuzz_nanomq"
        ;;
    *)
        echo "ERROR: Unknown target '${TARGET}'. Supported: mqtt, mongoose, nanomq"
        exit 1
        ;;
esac

mkdir -p "$OUTPUT_DIR"

echo "========================================================"
echo "  Peach (MPFuzz) Standalone - MQTT (${TARGET_DESC})"
echo "========================================================"
echo "  Target:     ${TARGET} (${TARGET_DESC})"
echo "  Instances:  ${NUM_INSTANCES}"
echo "  Timeout:    ${TIMEOUT}s ($(echo "scale=1; $TIMEOUT/3600" | bc)h)"
echo "  Image:      ${IMAGE}"
echo "  Output:     ${OUTPUT_DIR}"
echo "  Coverage:   Edge + gcov (tcpdump pcap replay)"
echo "  Start:      $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"

# Preflight: check image exists
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "ERROR: Docker image '${IMAGE}' not found."
    echo "Build it: cd $(dirname $SCRIPT_DIR)/${BUILD_DIR} && docker build -t ${IMAGE} ."
    exit 1
fi

CIDS=()

for i in $(seq 1 "$NUM_INSTANCES"); do
    OUTDIR="/home/ubuntu/experiments/peach_output"
    CID=$(docker run --cap-add=NET_ADMIN --cap-add=NET_RAW --cpus=1 -d -it \
        "$IMAGE" \
        /bin/bash -c "cd /home/ubuntu/experiments && run_mpfuzz ${TIMEOUT} ${OUTDIR}")
    CID_SHORT="${CID:0:12}"
    CIDS+=("$CID_SHORT")
    echo "[$(date '+%H:%M:%S')] Instance ${i}: container ${CID_SHORT}"
done

echo ""
echo "All ${NUM_INSTANCES} containers started. Waiting for completion..."
echo "Container IDs: ${CIDS[*]}"

# Save metadata
echo "${CIDS[*]}" > "${OUTPUT_DIR}/container_ids.txt"
cat > "${OUTPUT_DIR}/peach_config.json" << EOF
{
    "target": "${TARGET}",
    "image": "${IMAGE}",
    "instances": ${NUM_INSTANCES},
    "timeout": ${TIMEOUT},
    "coverage_type": "edge_and_gcov",
    "start_time": "$(date -Iseconds)"
}
EOF

# ============================================================
# Periodic status monitoring with timeout enforcement
# ============================================================
START_TIME=$(date +%s)
while true; do
    sleep 600

    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TIME ))
    ELAPSED_H=$(echo "scale=1; $ELAPSED/3600" | bc)

    STILL_RUNNING=0
    for cid in "${CIDS[@]}"; do
        STATE=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
        if [ "$STATE" = "true" ]; then
            STILL_RUNNING=$((STILL_RUNNING + 1))
            # enforce timeout per-container
            if [ $ELAPSED -ge $TIMEOUT ]; then
                echo "[$(date '+%H:%M:%S')] Timeout exceeded; killing $cid"
                docker kill "$cid" >/dev/null 2>&1 || true
            fi
        fi
    done

    echo "[$(date '+%H:%M:%S')] Elapsed: ${ELAPSED_H}h | Running: ${STILL_RUNNING}/${NUM_INSTANCES}"

    if [ "$STILL_RUNNING" -eq 0 ]; then
        echo "[$(date '+%H:%M:%S')] All containers finished."
        break
    fi
done

# ============================================================
# Collect results
# ============================================================
echo ""
echo "[$(date '+%H:%M:%S')] Collecting results..."

INDEX=1
for cid in "${CIDS[@]}"; do
    INSTANCE_DIR="${OUTPUT_DIR}/instance_${INDEX}"
    mkdir -p "$INSTANCE_DIR"

    echo "  Collecting from container ${cid} -> instance_${INDEX}"

    # Copy MPFuzz/Peach output directory
    docker cp "${cid}:/home/ubuntu/experiments/peach_output/" \
        "${INSTANCE_DIR}/peach_output" 2>/dev/null || true

    # Copy edge coverage CSV
    if [ -f "${INSTANCE_DIR}/peach_output/edge_coverage.csv" ]; then
        cp "${INSTANCE_DIR}/peach_output/edge_coverage.csv" "${INSTANCE_DIR}/edge_coverage.csv"
        FINAL_EDGES=$(tail -1 "${INSTANCE_DIR}/edge_coverage.csv" | cut -d',' -f2 | tr -d ' ')
        echo "    Edge coverage CSV: OK (final edges: ${FINAL_EDGES:-N/A})"
    else
        echo "    WARNING: edge_coverage.csv not found"
    fi

    # Copy gcov coverage CSV (line/branch coverage from pcap replay)
    if [ -f "${INSTANCE_DIR}/peach_output/cov_over_time.csv" ]; then
        cp "${INSTANCE_DIR}/peach_output/cov_over_time.csv" "${INSTANCE_DIR}/cov_over_time.csv"
        GCOV_FINAL=$(tail -1 "${INSTANCE_DIR}/cov_over_time.csv")
        GCOV_L=$(echo "$GCOV_FINAL" | cut -d',' -f2)
        GCOV_B=$(echo "$GCOV_FINAL" | cut -d',' -f4)
        echo "    gcov coverage: OK (lines: ${GCOV_L}%, branches: ${GCOV_B}%)"
    else
        echo "    WARNING: cov_over_time.csv not found (gcov coverage unavailable)"
    fi

    # Copy crash logs
    if [ -d "${INSTANCE_DIR}/peach_output/crashes" ]; then
        CRASH_N=$(find "${INSTANCE_DIR}/peach_output/crashes" -type f | wc -l)
        echo "    Crashes: ${CRASH_N}"
    fi

    # Save container logs
    docker logs "$cid" > "${INSTANCE_DIR}/container.log" 2>&1 || true

    # Remove container
    docker rm "$cid" 2>/dev/null || true

    INDEX=$((INDEX + 1))
done

# ============================================================
# Summary
# ============================================================
TOTAL_TIME=$(( $(date +%s) - START_TIME ))
echo ""
echo "========================================================"
echo "  Peach (MPFuzz) Complete"
echo "========================================================"
echo "  Instances:    ${NUM_INSTANCES}"
echo "  Total Time:   ${TOTAL_TIME}s ($(echo "scale=1; $TOTAL_TIME/3600" | bc)h)"
echo "  Output:       ${OUTPUT_DIR}"
echo "  End:          $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
