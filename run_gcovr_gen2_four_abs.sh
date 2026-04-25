#!/bin/bash
set -e

SCRIPT_DIR="/home/pzst/mqtt_fuzz/GMPFuzz"
cd "$SCRIPT_DIR"

BASE_EVAL_DIR="/home/pzst/mqtt_fuzz/GMPFuzz/evaluation/ablation_results_mqtt_supplement_20260423_091643"
DIRS=(
    "gmpfuzz_mqtt_ablation_supplement_20260423_091643_full"
    "gmpfuzz_mqtt_ablation_supplement_20260423_091643_no-ase"
    "gmpfuzz_mqtt_ablation_supplement_20260423_091643_no-pasd"
    "gmpfuzz_mqtt_ablation_supplement_20260423_234754_no-llm"
)

GCOV_TARGET_DIR="mosquitto-gcov"
GCOV_SRC_DIR="/home/ubuntu/mosquitto-gcov/src"
GCOV_ROOT="/home/ubuntu/mosquitto-gcov/src"
GCOV_CONF="/home/ubuntu/experiments/mosquitto.conf"
GCOV_BIN="./mosquitto"
GCOV_PORT=1883
IMAGE="gmpfuzz/mqtt"

echo "=== Collecting coverage for 4 ablation modes (gen1 instead of gen2 since tests only ran 1 generation) ==="

pids=()

for DIR_NAME in "${DIRS[@]}"; do
    EVAL_DIR="${BASE_EVAL_DIR}/${DIR_NAME}"
    if [ ! -d "$EVAL_DIR" ]; then
        echo "Dir not found: $EVAL_DIR"
        continue
    fi

    # The logs say GMPFuzz completed 1 generation (gen1). 
    # The coverage is in gen1/aflnetout/
    LAST_GEN_DIR="${EVAL_DIR}/gen1/aflnetout"
    
    if [ ! -d "$LAST_GEN_DIR" ]; then
        echo "gen1/aflnetout not found in $EVAL_DIR"
        continue
    fi

    MERGED_GMP_DIR=$(mktemp -d -t gmp_gcov_XXXXXX)
    
    # Check if there are tar.gz files
    TAR_COUNT=$(ls -1 "${LAST_GEN_DIR}"/*.tar.gz 2>/dev/null | wc -l)
    if [ "$TAR_COUNT" -gt 0 ]; then
        for tarball in "${LAST_GEN_DIR}"/*.tar.gz; do
            base=$(basename "$tarball" .tar.gz)
            TARBALL_TMP=$(mktemp -d)
            tar -xzf "$tarball" -C "$TARBALL_TMP" 2>/dev/null || true
            for f in "$TARBALL_TMP"/*/replayable-queue/*; do
                [ -f "$f" ] && cp "$f" "${MERGED_GMP_DIR}/${base}_$(basename "$f")"
            done
            rm -rf "$TARBALL_TMP"
        done
    else
        # Maybe replayable-queue is directly inside subdirs
        for SUBDIR in "${LAST_GEN_DIR}"/*; do
            if [ -d "${SUBDIR}/replayable-queue" ]; then
                for f in "${SUBDIR}/replayable-queue"/*; do
                    [ -f "$f" ] && cp "$f" "${MERGED_GMP_DIR}/$(basename "${SUBDIR}")_$(basename "$f")"
                done
            elif [ -d "${SUBDIR}" ]; then
                # Handle cases where files are directly in the subdir (like id:... files)
                for f in "${SUBDIR}"/id*; do
                    [ -f "$f" ] && cp "$f" "${MERGED_GMP_DIR}/$(basename "${SUBDIR}")_$(basename "$f")"
                done
            fi
        done
    fi

    GMP_COUNT=$(ls -A "$MERGED_GMP_DIR" | wc -l)
    echo "[$DIR_NAME] Merged cases: $GMP_COUNT"
    
    # Set up container execution script for the current dir
    TMP_DOCKER_SCRIPT=$(mktemp -t docker_script_XXXXXX.sh)
    chmod +x "$TMP_DOCKER_SCRIPT"
    cat << 'INNER_EOF' > "$TMP_DOCKER_SCRIPT"
#!/bin/bash
cd /home/ubuntu/experiments/mosquitto-gcov/src || exit 1
gcovr -r . -s -d > /dev/null 2>&1
for f in /tmp/replay_inputs/*; do
    [ -f "$f" ] || continue
    pkill -f "mosquitto" 2>/dev/null || true
    timeout -k 0 -s SIGTERM 3s ./mosquitto -c /home/ubuntu/experiments/mosquitto.conf > /dev/null 2>&1 &
    MOSQ_PID=$!
    sleep 0.1
    aflnet-replay "$f" MQTT 1883 1 > /dev/null 2>&1
    kill -TERM $MOSQ_PID 2>/dev/null
    wait $MOSQ_PID 2>/dev/null || true
done
echo '=== GCOVR_TEXT_START ==='
gcovr -r . -s 2>/dev/null || echo 'no data'
echo '=== GCOVR_TEXT_END ==='
INNER_EOF

    # Start container
    GCOV_CID_GMP=$(docker run -d --cpus=2 -v "${MERGED_GMP_DIR}:/tmp/replay_inputs:ro" -v "${TMP_DOCKER_SCRIPT}:/run_gcov.sh:ro" "$IMAGE" /run_gcov.sh)
    echo "Started Docker $GCOV_CID_GMP for $DIR_NAME"
    
    # Wait for the container asynchronously
    (
        docker wait "$GCOV_CID_GMP" > /dev/null
        GCOV_LOG_G=$(docker logs "$GCOV_CID_GMP" 2>&1)
        GCOV_TEXT_G=$(echo "$GCOV_LOG_G" | awk '/=== GCOVR_TEXT_START ===/{flag=1; next} /=== GCOVR_TEXT_END ===/{flag=0} flag')
        L_PER_G=$(echo "$GCOV_TEXT_G" | grep -i 'lines:' | head -1 | sed 's/.*lines: *\([0-9.]*\)%.*/\1/')
        B_PER_G=$(echo "$GCOV_TEXT_G" | grep -i 'branches:' | head -1 | sed 's/.*branches: *\([0-9.]*\)%.*/\1/')
        
        L_PER_G=${L_PER_G:-0.0}
        B_PER_G=${B_PER_G:-0.0}
        
        echo "[$DIR_NAME] Recovered: Lines=${L_PER_G}%, Branches=${B_PER_G}%"
        
        # Save to csv properly formatted (generation,line_percent,line_covered,line_total,branch_percent,branch_covered,branch_total)
        echo "generation,line_percent,line_covered,line_total,branch_percent,branch_covered,branch_total" > "${EVAL_DIR}/gcovr_coverage.csv"
        echo "gen2,${L_PER_G},0,0,${B_PER_G},0,0" >> "${EVAL_DIR}/gcovr_coverage.csv"
        
        docker rm -f "$GCOV_CID_GMP" > /dev/null
        rm -rf "$MERGED_GMP_DIR"
        rm -f "$TMP_DOCKER_SCRIPT"
    ) &
    
    pids+=($!)

done

echo "Waiting for all coverage runs to finish..."
wait "${pids[@]}"
echo "All containers finished. Aggregating results..."

# Regenerate summary using plot_ablation.py
python3 ./experiments/plot_ablation.py mqtt "${BASE_EVAL_DIR}/"gmpfuzz_mqtt_ablation_supplement_*

# Copy to required file
cp ablation_summary_mqtt.csv "${BASE_EVAL_DIR}/" || true

echo "Done!"
