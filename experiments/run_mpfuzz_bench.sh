#!/bin/bash
# ============================================================
# run_mpfuzz_bench.sh - Run MPFuzz for benchmark comparison
#
# MPFuzz = Peach Fuzzer v3.0 + parallel field pool + edge coverage.
# A single MPFuzz container internally runs 4 fuzz agents
# (2 pub + 2 sub), so only ONE container is needed.
#
# NOTE: MPFuzz does NOT save replayable test cases. It collects
# edge coverage via shared memory instrumentation only.
# gcov-based line/branch coverage is NOT available for MPFuzz.
#
# Usage: ./run_mpfuzz_bench.sh [options]
#   -t, --target TARGET    Fuzzing target: mqtt, mongoose, nanomq (default: mqtt)
#   --timeout SEC          Fuzzing duration in seconds (default: 86400 = 24h)
#   -o, --output DIR       Host directory for results
#   -h, --help             Show this help
#
# Legacy positional usage (backward compatible):
#   ./run_mpfuzz_bench.sh <timeout_sec> <output_dir>
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
        --timeout)        TIMEOUT="$2"; shift 2 ;;
        -o|--output)      OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)        show_help ;;
        *)
            # Legacy positional args: <timeout> <output_dir>
            if [ -z "${_LP1:-}" ]; then _LP1=1; TIMEOUT="$1"; shift
            elif [ -z "${_LP2:-}" ]; then _LP2=1; OUTPUT_DIR="$1"; shift
            else echo "Unknown option: $1"; show_help; fi
            ;;
    esac
done

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(pwd)/results/mpfuzz"
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
echo "  MPFuzz Benchmark - MQTT (${TARGET_DESC})"
echo "========================================================"
echo "  Target:     ${TARGET} (${TARGET_DESC})"
echo "  Parallelism: 4 internal agents (2 pub + 2 sub)"
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

OUTDIR="/home/ubuntu/experiments/mpfuzz_output"
CID=$(docker run --cap-add=NET_ADMIN --cap-add=NET_RAW --cpus=4 -d -it \
    "$IMAGE" \
    /bin/bash -c "cd /home/ubuntu/experiments && run_mpfuzz ${TIMEOUT} ${OUTDIR}")
CID_SHORT="${CID:0:12}"
echo "[$(date '+%H:%M:%S')] MPFuzz container: ${CID_SHORT}"

# Save metadata
echo "$CID_SHORT" > "${OUTPUT_DIR}/container_ids.txt"
cat > "${OUTPUT_DIR}/mpfuzz_config.json" << EOF
{
    "target": "${TARGET}",
    "image": "${IMAGE}",
    "instances": 1,
    "internal_agents": 4,
    "timeout": ${TIMEOUT},
    "coverage_type": "edge_and_gcov",
    "start_time": "$(date -Iseconds)"
}
EOF

# ============================================================
# Periodic status monitoring (with timeout enforcement)
# ============================================================
START_TIME=$(date +%s)
while true; do
    sleep 600
    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TIME ))
    ELAPSED_H=$(echo "scale=1; $ELAPSED/3600" | bc)

    STATE=$(docker inspect -f '{{.State.Running}}' "$CID_SHORT" 2>/dev/null || echo "false")
    if [ "$STATE" = "true" ]; then
        echo "[$(date '+%H:%M:%S')] Elapsed: ${ELAPSED_H}h | MPFuzz: RUNNING"
        # if we've exceeded user timeout, kill container
        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "[$(date '+%H:%M:%S')] Timeout exceeded (${TIMEOUT}s); killing MPFuzz container"
            docker kill "$CID_SHORT" >/dev/null 2>&1 || true
            # allow a moment for the container to exit
            sleep 5
            continue
        fi
    else
        echo "[$(date '+%H:%M:%S')] Elapsed: ${ELAPSED_H}h | MPFuzz: FINISHED"
        break
    fi
done

# ============================================================
# Collect results
# ============================================================
echo "[$(date '+%H:%M:%S')] Collecting results..."

INSTANCE_DIR="${OUTPUT_DIR}/instance_1"
mkdir -p "$INSTANCE_DIR"

echo "  Collecting from container ${CID_SHORT} -> instance_1"

docker cp "${CID_SHORT}:/home/ubuntu/experiments/mpfuzz_output/" \
    "${INSTANCE_DIR}/mpfuzz_output" 2>/dev/null || true

# Copy edge coverage CSV
if [ -f "${INSTANCE_DIR}/mpfuzz_output/edge_coverage.csv" ]; then
    cp "${INSTANCE_DIR}/mpfuzz_output/edge_coverage.csv" "${INSTANCE_DIR}/edge_coverage.csv"
    FINAL_EDGES=$(tail -1 "${INSTANCE_DIR}/edge_coverage.csv" | cut -d',' -f2 | tr -d ' ')
    echo "    Edge coverage: OK (final edges: ${FINAL_EDGES:-N/A})"
else
    echo "    WARNING: edge_coverage.csv not found"
fi

# Copy gcov coverage CSV (line/branch coverage from pcap replay)
if [ -f "${INSTANCE_DIR}/mpfuzz_output/cov_over_time.csv" ]; then
    cp "${INSTANCE_DIR}/mpfuzz_output/cov_over_time.csv" "${INSTANCE_DIR}/cov_over_time.csv"
    GCOV_FINAL=$(tail -1 "${INSTANCE_DIR}/cov_over_time.csv")
    GCOV_L=$(echo "$GCOV_FINAL" | cut -d',' -f2)
    GCOV_B=$(echo "$GCOV_FINAL" | cut -d',' -f4)
    echo "    gcov coverage: OK (lines: ${GCOV_L}%, branches: ${GCOV_B}%)"
else
    echo "    WARNING: cov_over_time.csv not found (gcov coverage unavailable)"
fi

docker logs "$CID_SHORT" > "${INSTANCE_DIR}/container.log" 2>&1 || true
docker rm "$CID_SHORT" 2>/dev/null || true

TOTAL_TIME=$(( $(date +%s) - START_TIME ))
echo ""
echo "========================================================"
echo "  MPFuzz Complete"
echo "========================================================"
echo "  Parallelism:  4 internal agents (2 pub + 2 sub)"
echo "  Total Time:   ${TOTAL_TIME}s ($(echo "scale=1; $TOTAL_TIME/3600" | bc)h)"
echo "  Output:       ${OUTPUT_DIR}"
echo "  End:          $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
