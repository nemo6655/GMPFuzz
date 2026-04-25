#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS=(
    "mqtt:mpfuzz/mqtt:${SCRIPT_DIR}/evaluation/results_20260402_173153"
    "nanomq:mpfuzz/nanomq:${SCRIPT_DIR}/evaluation/results_20260416_085721"
    "flashmq:mpfuzz/flashmq:${SCRIPT_DIR}/evaluation/results_20260417_174913"
)
NUM_PEACH_INSTANCES=4

for task in "${TASKS[@]}"; do
    IFS=':' read -r TARGET IMAGE RESULTS_DIR <<< "$task"
    echo "Processing $TARGET from $RESULTS_DIR"

    MPFUZZ_CID=$(cat "${RESULTS_DIR}/mpfuzz/container_ids.txt" 2>/dev/null || echo "")
    PEACH_CIDS=($(cat "${RESULTS_DIR}/peach/container_ids.txt" 2>/dev/null || echo ""))

    # MPFuzz
    if [ -n "$MPFUZZ_CID" ]; then
        INST_DIR="${RESULTS_DIR}/mpfuzz/instance_1"
        mkdir -p "$INST_DIR"
        docker cp "${MPFUZZ_CID}:/home/ubuntu/experiments/mpfuzz_output/" "${INST_DIR}/mpfuzz_output" 2>/dev/null || true
        for f in edge_coverage.csv cov_over_time.csv; do
            if [ -f "${INST_DIR}/mpfuzz_output/${f}" ]; then
                cp "${INST_DIR}/mpfuzz_output/${f}" "${INST_DIR}/${f}"
            fi
        done
        if [ -f "${INST_DIR}/mpfuzz_output/traffic.pcap" ]; then
            cp "${INST_DIR}/mpfuzz_output/traffic.pcap" "${INST_DIR}/traffic.pcap"
        fi
        docker logs "${MPFUZZ_CID}" > "${INST_DIR}/container.log" 2>&1 || true
        docker rm "${MPFUZZ_CID}" 2>/dev/null || true
    fi

    # Peach
    IDX=1
    for cid in "${PEACH_CIDS[@]}"; do
        if [ -n "$cid" ]; then
            INST_DIR="${RESULTS_DIR}/peach/instance_${IDX}"
            mkdir -p "$INST_DIR"
            docker cp "${cid}:/home/ubuntu/experiments/peach_output/" "${INST_DIR}/peach_output" 2>/dev/null || true
            for f in edge_coverage.csv cov_over_time.csv; do
                if [ -f "${INST_DIR}/peach_output/${f}" ]; then
                    cp "${INST_DIR}/peach_output/${f}" "${INST_DIR}/${f}"
                fi
            done
            if [ -f "${INST_DIR}/peach_output/traffic.pcap" ]; then
                cp "${INST_DIR}/peach_output/traffic.pcap" "${INST_DIR}/traffic.pcap"
            fi
            docker logs "$cid" > "${INST_DIR}/container.log" 2>&1 || true
            docker rm "$cid" 2>/dev/null || true
        fi
        IDX=$((IDX + 1))
    done

    # Summary
    SUMMARY="${RESULTS_DIR}/coverage_summary.csv"
    if [ -f "$SUMMARY" ]; then
        head -1 "$SUMMARY" > "${SUMMARY}.tmp"
        grep -v '^mpfuzz,\|^peach,' "$SUMMARY" >> "${SUMMARY}.tmp" || true

        add_summary_row() {
            local FUZZER=$1 L_IDX=$2 IDIR=$3
            local EDGES=0 POINTS=0 LP="N/A" BP="N/A"
            if [ -f "${IDIR}/edge_coverage.csv" ]; then
                EDGES=$(tail -1 "${IDIR}/edge_coverage.csv" | cut -d',' -f2 | tr -d ' ')
                POINTS=$(( $(wc -l < "${IDIR}/edge_coverage.csv") - 1 ))
                if [ "$POINTS" -lt 0 ]; then POINTS=0; fi
            fi
            if [ -f "${IDIR}/cov_over_time.csv" ]; then
                local LAST=$(tail -1 "${IDIR}/cov_over_time.csv")
                LP=$(echo "$LAST" | cut -d',' -f2)
                BP=$(echo "$LAST" | cut -d',' -f4)
                if [ -z "$BP" ]; then BP="N/A"; fi
            fi
            echo "${FUZZER},${L_IDX},${LP},${BP},${EDGES},${POINTS}" >> "${SUMMARY}.tmp"
        }

        add_summary_row "mpfuzz" "1" "${RESULTS_DIR}/mpfuzz/instance_1"
        for i in $(seq 1 "$NUM_PEACH_INSTANCES"); do
            add_summary_row "peach" "$i" "${RESULTS_DIR}/peach/instance_${i}"
        done

        mv "${SUMMARY}.tmp" "$SUMMARY"
        chown -R $USER:$USER "${RESULTS_DIR}"
        echo "  Updated: $SUMMARY"
        cat "$SUMMARY"
    fi

    # Plot
    cd "${SCRIPT_DIR}"
    python3 experiments/plot_results.py "${RESULTS_DIR}" --format pdf 2>&1 || true

done
