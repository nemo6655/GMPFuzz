#!/bin/bash
# ============================================================
# run_aflnet.sh - Run standalone AFLNet instances
#
# Uses the ProFuzzBench Docker images (mosquitto/mongoose/nanomq).
# Each instance runs in its own container with --cpus=1.
# Coverage is collected inside the container via cov_script (ProFuzzBench
# 3-step pattern: fuzz → cov_script → tar).
#
# Usage: ./run_aflnet.sh [options]
#   -t, --target TARGET    Fuzzing target: mqtt, mongoose, nanomq (default: mqtt)
#   -n, --num-inst N       Number of parallel containers (default: 4)
#   --timeout SEC          Fuzzing duration in seconds (default: 86400 = 24h)
#   -o, --output DIR       Host directory for results
#   -h, --help             Show this help
#
# Legacy positional usage (backward compatible):
#   ./run_aflnet.sh <num_instances> <timeout_sec> <output_dir>
#
# Examples:
#   ./run_aflnet.sh                                    # mqtt, 4 inst, 24h
#   ./run_aflnet.sh -t mongoose -n 2 --timeout 3600
#   ./run_aflnet.sh -t nanomq --timeout 7200
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
SKIPCOUNT=5

# AFLNet options for MQTT protocol
OPTIONS="-P MQTT -D 10000 -q 3 -s 3 -E -K -R -m none"

# =====================================================================
# Parse arguments
# =====================================================================
show_help() {
    sed -n '2,24p' "$0" | sed 's/^# \?//'
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
    OUTPUT_DIR="$(pwd)/evaluation/aflnet"
fi

# =====================================================================
# Target-specific configuration
# Uses ProFuzzBench Docker image names (not gmpfuzz/* images)
# =====================================================================
case "$TARGET" in
    mqtt)
        IMAGE="mosquitto"
        TARGET_DESC="Mosquitto v1.5.5"
        OUTDIR_NAME="out-mqtt-aflnet"
        ;;
    mongoose)
        IMAGE="mongoose"
        TARGET_DESC="Mongoose v7.20"
        OUTDIR_NAME="out-mongoose-aflnet"
        ;;
    nanomq)
        IMAGE="nanomq"
        TARGET_DESC="NanoMQ v0.21.10"
        OUTDIR_NAME="out-nanomq-aflnet"
        ;;
    *)
        echo "ERROR: Unknown target '${TARGET}'. Supported: mqtt, mongoose, nanomq"
        exit 1
        ;;
esac

mkdir -p "$OUTPUT_DIR"

echo "========================================================"
echo "  AFLNet Standalone - ${TARGET_DESC}"
echo "========================================================"
echo "  Target:     ${TARGET} (${TARGET_DESC})"
echo "  Instances:  ${NUM_INSTANCES}"
echo "  Timeout:    ${TIMEOUT}s ($(echo "scale=1; $TIMEOUT/3600" | bc)h)"
echo "  Image:      ${IMAGE}"
echo "  Output:     ${OUTPUT_DIR}"
echo "  SkipCount:  ${SKIPCOUNT}"
echo "  Start:      $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"

# Preflight: check image exists
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "ERROR: Docker image '${IMAGE}' not found."
    echo "Build it from ProFuzzBench:"
    echo "  cd \$PFBENCH/subjects/MQTT/$(echo ${TARGET} | sed 's/mqtt/Mosquitto/;s/mongoose/Mongoose/;s/nanomq/NanoMQ/') && bash sync-aflnet.sh && docker build -t ${IMAGE} ."
    exit 1
fi

# Track container IDs
CIDS=()

for i in $(seq 1 "$NUM_INSTANCES"); do
    # ProFuzzBench run.sh takes 5 args (standard format):
    #   <fuzzer> <outdir> <options> <timeout> <skipcount>
    CID=$(docker run --cpus=1 -d -it \
        "$IMAGE" \
        /bin/bash -c "cd /home/ubuntu/experiments && \
            run aflnet ${OUTDIR_NAME} '${OPTIONS}' ${TIMEOUT} ${SKIPCOUNT}")
    CID_SHORT="${CID:0:12}"
    CIDS+=("$CID_SHORT")
    echo "[$(date '+%H:%M:%S')] Instance ${i}: container ${CID_SHORT}"
done

echo ""
echo "All ${NUM_INSTANCES} containers started. Waiting for completion..."
echo "Container IDs: ${CIDS[*]}"

# Save metadata
echo "${CIDS[*]}" > "${OUTPUT_DIR}/container_ids.txt"
cat > "${OUTPUT_DIR}/aflnet_config.json" << EOF
{
    "target": "${TARGET}",
    "image": "${IMAGE}",
    "instances": ${NUM_INSTANCES},
    "timeout": ${TIMEOUT},
    "skipcount": ${SKIPCOUNT},
    "options": "${OPTIONS}",
    "start_time": "$(date -Iseconds)"
}
EOF

# ============================================================
# Periodic status monitoring (every 10 minutes)
# ============================================================
START_TIME=$(date +%s)
while true; do
    sleep 600

    ELAPSED=$(( $(date +%s) - START_TIME ))
    ELAPSED_H=$(echo "scale=1; $ELAPSED/3600" | bc)

    STILL_RUNNING=0
    for cid in "${CIDS[@]}"; do
        STATE=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
        if [ "$STATE" = "true" ]; then
            STILL_RUNNING=$((STILL_RUNNING + 1))
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

    # Copy the tar.gz result (contains: fuzzing output + cov_over_time.csv + cov_html/)
    docker cp "${cid}:/home/ubuntu/experiments/${OUTDIR_NAME}.tar.gz" \
        "${INSTANCE_DIR}/${OUTDIR_NAME}.tar.gz" 2>/dev/null || true

    # Extract
    if [ -f "${INSTANCE_DIR}/${OUTDIR_NAME}.tar.gz" ]; then
        cd "$INSTANCE_DIR"
        tar -xzf "${OUTDIR_NAME}.tar.gz" 2>/dev/null || true

        # Copy coverage CSV to standard location
        if [ -f "${OUTDIR_NAME}/cov_over_time.csv" ]; then
            cp "${OUTDIR_NAME}/cov_over_time.csv" "${INSTANCE_DIR}/cov_over_time.csv"
            FINAL_LINE=$(tail -1 "${INSTANCE_DIR}/cov_over_time.csv")
            L_PER=$(echo "$FINAL_LINE" | cut -d',' -f2)
            B_PER=$(echo "$FINAL_LINE" | cut -d',' -f4)
            echo "    Coverage CSV: OK (L=${L_PER}% B=${B_PER}%)"
        else
            echo "    WARNING: cov_over_time.csv not found"
        fi
        cd - > /dev/null
    else
        echo "    WARNING: tar.gz not found"
    fi

    # Count replayable-queue entries
    if [ -d "${INSTANCE_DIR}/${OUTDIR_NAME}/replayable-queue" ]; then
        RQUEUE=$(ls "${INSTANCE_DIR}/${OUTDIR_NAME}/replayable-queue/" 2>/dev/null | wc -l)
        echo "    Replayable queue: ${RQUEUE} entries"
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
echo "  AFLNet Complete - ${TARGET_DESC}"
echo "========================================================"
echo "  Target:       ${TARGET}"
echo "  Instances:    ${NUM_INSTANCES}"
echo "  Total Time:   ${TOTAL_TIME}s ($(echo "scale=1; $TOTAL_TIME/3600" | bc)h)"
echo "  Output:       ${OUTPUT_DIR}"
echo "  End:          $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
