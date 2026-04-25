#!/bin/bash
# ============================================================
# rerun_mpfuzz_peach.sh
#
# Re-run MPFuzz + Peach for target configs
# Usage: bash rerun_mpfuzz_peach.sh [TIMEOUT]
#   Default timeout: 300 (5 minutes)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMEOUT=${1:-300}
BUILD_DIR="${SCRIPT_DIR}/benchmark"
NUM_PEACH_INSTANCES=4

TASKS=(
    
    
    "flashmq:mpfuzz/flashmq:${SCRIPT_DIR}/evaluation/results_20260417_174913"
)

for task in "${TASKS[@]}"; do
(
    IFS=':' read -r TARGET IMAGE RESULTS_DIR <<< "$task"

    echo "========================================================"
    echo "  Re-run MPFuzz + Peach (${TARGET}) with gcovr"
    echo "========================================================"
    echo "  Timeout:      ${TIMEOUT}s ($(echo "scale=1; $TIMEOUT/3600" | bc)h)"
    echo "  Results dir:  ${RESULTS_DIR}"
    echo "  Image:        ${IMAGE}"
    echo "  Start:        $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================================"

    # Step 0: Verify image
    if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
        echo "ERROR: Docker image '${IMAGE}' not found."; exit 1
    fi
    docker run --rm "$IMAGE" bash -c 'which tcpdump && which gcovr' > /dev/null 2>&1 || {
        echo "ERROR: Image lacks tcpdump/gcovr. Rebuild first."; exit 1
    }
    echo "[OK] Image ${IMAGE} verified."

    # Step 1: Backup old data
    BACKUP_TS=$(date '+%Y%m%d_%H%M%S')
    for subdir in mpfuzz peach; do
        if [ -d "${RESULTS_DIR}/${subdir}" ]; then
            BACKUP="${RESULTS_DIR}/${subdir}.bak_${BACKUP_TS}"
            echo "[Backup] ${subdir} -> $(basename ${BACKUP})"
            mv "${RESULTS_DIR}/${subdir}" "${BACKUP}"
        fi
    done
    mkdir -p "${RESULTS_DIR}/mpfuzz" "${RESULTS_DIR}/peach"

    # Step 2: Run MPFuzz (1 container, 4 internal agents)
    echo ""
    echo "========== MPFuzz (4 internal agents) =========="
    MPFUZZ_OUTDIR="/home/ubuntu/experiments/mpfuzz_output"
    MPFUZZ_CID=$(docker run --user root --cap-add=NET_ADMIN --cap-add=NET_RAW --cpus=4 -d -it \
        -v "${BUILD_DIR}/mpfuzz_${TARGET}/run_mpfuzz.sh:/home/ubuntu/experiments/run_mpfuzz:ro" \
        "$IMAGE" \
        /bin/bash -c "cd /home/ubuntu/experiments && bash run_mpfuzz ${TIMEOUT} ${MPFUZZ_OUTDIR}")
    MPFUZZ_CID="${MPFUZZ_CID:0:12}"
    echo "[$(date '+%H:%M:%S')] MPFuzz container: ${MPFUZZ_CID}"
    echo "${MPFUZZ_CID}" > "${RESULTS_DIR}/mpfuzz/container_ids.txt"

    cat > "${RESULTS_DIR}/mpfuzz/mpfuzz_config.json" << INNER_EOF
{
    "target": "${TARGET}",
    "image": "${IMAGE}",
    "instances": 1,
    "internal_agents": 4,
    "timeout": ${TIMEOUT},
    "coverage_type": "edge_bitmap+gcovr",
    "start_time": "$(date -Iseconds)",
    "note": "Re-run with gcovr via pcap replay"
}
INNER_EOF

    # Step 3: Run Peach (4 separate containers)
    echo ""
    echo "========== Peach (${NUM_PEACH_INSTANCES} instances) =========="
    PEACH_CIDS=()
    for i in $(seq 1 "$NUM_PEACH_INSTANCES"); do
        PEACH_OUTDIR="/home/ubuntu/experiments/peach_output"
        CID=$(docker run --user root --cap-add=NET_ADMIN --cap-add=NET_RAW --cpus=1 -d -it \
            -v "${BUILD_DIR}/mpfuzz_${TARGET}/run_mpfuzz.sh:/home/ubuntu/experiments/run_mpfuzz:ro" \
            "$IMAGE" \
            /bin/bash -c "cd /home/ubuntu/experiments && bash run_mpfuzz ${TIMEOUT} ${PEACH_OUTDIR}")
        CID="${CID:0:12}"
        PEACH_CIDS+=("$CID")
        echo "[$(date '+%H:%M:%S')] Peach instance ${i}: ${CID}"
    done
    echo "${PEACH_CIDS[*]}" > "${RESULTS_DIR}/peach/container_ids.txt"

    cat > "${RESULTS_DIR}/peach/peach_config.json" << INNER_EOF
{
    "target": "${TARGET}",
    "image": "${IMAGE}",
    "instances": ${NUM_PEACH_INSTANCES},
    "timeout": ${TIMEOUT},
    "coverage_type": "edge_bitmap+gcovr",
    "start_time": "$(date -Iseconds)",
    "note": "Re-run with gcovr via pcap replay"
}
INNER_EOF

    # Step 4: Monitor
    echo ""
    echo "[$(date '+%H:%M:%S')] All containers started. Monitoring..."
    ALL_CIDS=("${MPFUZZ_CID}" "${PEACH_CIDS[@]}")
    START_TIME=$(date +%s)

    while true; do
        sleep 30
        NOW=$(date +%s)
        ELAPSED=$(( NOW - START_TIME ))
        ELAPSED_H=$(echo "scale=1; $ELAPSED/3600" | bc)

        RUNNING=0
        for cid in "${ALL_CIDS[@]}"; do
            STATE=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
            if [ "$STATE" = "true" ]; then
                RUNNING=$((RUNNING + 1))
                # Grace period: timeout + slightly more
                if [ $ELAPSED -ge $((TIMEOUT + 600)) ]; then
                    echo "[$(date '+%H:%M:%S')] Force-killing $cid (timeout grace exceeded)"
                    docker kill "$cid" >/dev/null 2>&1 || true
                fi
            fi
        done

        echo "[$(date '+%H:%M:%S')] Elapsed: ${ELAPSED}s | Running: ${RUNNING}/${#ALL_CIDS[@]}"
        
        if [ "$RUNNING" -eq 0 ]; then
            echo "[$(date '+%H:%M:%S')] All containers finished."
            break
        fi
    done

    # Step 5: Collect MPFuzz results
    echo ""
    echo "[$(date '+%H:%M:%S')] Collecting MPFuzz results..."
    INST_DIR="${RESULTS_DIR}/mpfuzz/instance_1"
    mkdir -p "$INST_DIR"
    docker cp "${MPFUZZ_CID}:/home/ubuntu/experiments/mpfuzz_output/" "${INST_DIR}/mpfuzz_output" 2>/dev/null || true
    for f in edge_coverage.csv cov_over_time.csv; do
        if [ -f "${INST_DIR}/mpfuzz_output/${f}" ]; then
            cp "${INST_DIR}/mpfuzz_output/${f}" "${INST_DIR}/${f}"
            echo "  MPFuzz ${f}: $(tail -1 "${INST_DIR}/${f}")"
        else
            echo "  WARNING: MPFuzz ${f} not found"
        fi
    done
    if [ -f "${INST_DIR}/mpfuzz_output/traffic.pcap" ]; then
        cp "${INST_DIR}/mpfuzz_output/traffic.pcap" "${INST_DIR}/traffic.pcap"
        echo "  MPFuzz traffic.pcap: $(du -sh "${INST_DIR}/traffic.pcap" | cut -f1)"
    fi
    docker logs "${MPFUZZ_CID}" > "${INST_DIR}/container.log" 2>&1 || true
    docker rm "${MPFUZZ_CID}" 2>/dev/null || true
    #sudo chown -R $USER:$USER "${INST_DIR}" 2>/dev/null || true

    # Step 6: Collect Peach results
    echo "[$(date '+%H:%M:%S')] Collecting Peach results..."
    IDX=1
    for cid in "${PEACH_CIDS[@]}"; do
        INST_DIR="${RESULTS_DIR}/peach/instance_${IDX}"
        mkdir -p "$INST_DIR"
        docker cp "${cid}:/home/ubuntu/experiments/peach_output/" "${INST_DIR}/peach_output" 2>/dev/null || true
        for f in edge_coverage.csv cov_over_time.csv; do
            if [ -f "${INST_DIR}/peach_output/${f}" ]; then
                cp "${INST_DIR}/peach_output/${f}" "${INST_DIR}/${f}"
                echo "  Peach #${IDX} ${f}: $(tail -1 "${INST_DIR}/${f}")"
            else
                echo "  WARNING: Peach #${IDX} ${f} not found"
            fi
        done
        if [ -f "${INST_DIR}/peach_output/traffic.pcap" ]; then
            cp "${INST_DIR}/peach_output/traffic.pcap" "${INST_DIR}/traffic.pcap"
        fi
        docker logs "$cid" > "${INST_DIR}/container.log" 2>&1 || true
        docker rm "$cid" 2>/dev/null || true
        #sudo chown -R $USER:$USER "${INST_DIR}" 2>/dev/null || true
        IDX=$((IDX + 1))
    done

    # Step 7: Update coverage_summary.csv
    echo ""
    echo "[$(date '+%H:%M:%S')] Updating coverage_summary.csv..."
    SUMMARY="${RESULTS_DIR}/coverage_summary.csv"
    if [ -f "$SUMMARY" ]; then
        head -1 "$SUMMARY" > "${SUMMARY}.tmp"
        sed '1d' "$SUMMARY" | grep -v '^mpfuzz,\|^peach,' >> "${SUMMARY}.tmp" || true

        # Helper: extract final gcovr + edge data from instance dir
        add_summary_row() {
            local FUZZER=$1 L_IDX=$2 IDIR=$3
            local EDGES=0 POINTS=0 LP="N/A" BP="N/A"
            if [ -f "${IDIR}/edge_coverage.csv" ]; then
                EDGES=$(tail -1 "${IDIR}/edge_coverage.csv" | cut -d',' -f2 | tr -d ' ')
                POINTS=$(( $(wc -l < "${IDIR}/edge_coverage.csv") - 1 ))
            fi
            if [ -f "${IDIR}/cov_over_time.csv" ]; then
                local LAST=$(tail -1 "${IDIR}/cov_over_time.csv")
                LP=$(echo "$LAST" | cut -d',' -f2)
                BP=$(echo "$LAST" | cut -d',' -f4)
            fi
            echo "${FUZZER},${L_IDX},${LP},${BP},${EDGES},${POINTS}" >> "${SUMMARY}.tmp"
        }

        add_summary_row "mpfuzz" "1" "${RESULTS_DIR}/mpfuzz/instance_1"
        for i in $(seq 1 "$NUM_PEACH_INSTANCES"); do
            add_summary_row "peach" "$i" "${RESULTS_DIR}/peach/instance_${i}"
        done

        mv "${SUMMARY}.tmp" "$SUMMARY"
        echo "  Updated: $SUMMARY"
        cat "$SUMMARY"
    fi

    # Step 8: Re-plot (edge + gcovr time series + bar charts)
    echo ""
    echo "[$(date '+%H:%M:%S')] Generating plots for ${TARGET}..."
    cd "${SCRIPT_DIR}"
    python3 experiments/plot_results.py "${RESULTS_DIR}" --format pdf 2>&1 || \
        echo "WARNING: plot generation failed"

    echo "########################################################"
    echo "  Finished tracking ${TARGET}"
    echo "########################################################"
    echo ""

) &
done

wait

echo "========================================================"
echo "  All Re-runs Complete!"
echo "========================================================"
echo "  End:         $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
