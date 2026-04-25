#!/bin/bash
# ============================================================
# fix_and_rerun_mpfuzz_peach.sh
#
# 修复 mpfuzz/peach 的 FlashMQ 配置 bug 并重新运行 24h 测试，
# 补充数据到 results_20260417_174913 实验目录。
#
# Bug: flashmq.conf 中 "inet4-bind-address"（连字符）应为
#      "inet4_bind_address"（下划线），导致 FlashMQ 配置解析
#      失败、立即退出，fuzzer 无法连接 broker，edge 覆盖率为 0。
#
# 资源使用:
#   - MPFuzz:  1 容器, --cpus=4
#   - Peach:   4 容器, --cpus=1 each
#   - 总计:    8 CPU cores
#   消融实验可同时运行（消融使用 gmpfuzz/ 镜像，不同容器/端口）
#
# 用法: bash fix_and_rerun_mpfuzz_peach.sh
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/evaluation/results_20260417_174913"
TIMEOUT=86400   # 24 hours
FIXED_CONF="${SCRIPT_DIR}/benchmark/mpfuzz_flashmq/flashmq.conf"
IMAGE="mpfuzz/flashmq"
RUN_MPFUZZ_SH="${SCRIPT_DIR}/benchmark/mpfuzz_flashmq/run_mpfuzz.sh"

# ============================================================
# 0. Preflight checks
# ============================================================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  MPFuzz/Peach FlashMQ 补充实验                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Bug: flashmq.conf inet4-bind-address -> inet4_bind_   ║"
echo "║       address (连字符->下划线)                          ║"
echo "║  Timeout: ${TIMEOUT}s (24h)                             ║"
echo "║  CPU: MPFuzz 4c + Peach 4x1c = 8 cores (of 24)         ║"
echo "║  消融实验可同时安全运行（不同镜像/端口）                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Check config fix
if grep -q "inet4-bind-address" "$FIXED_CONF"; then
    echo "ERROR: flashmq.conf 仍包含 'inet4-bind-address'（连字符）！"
    echo "请先修复: sed -i 's/inet4-bind-address/inet4_bind_address/' $FIXED_CONF"
    exit 1
fi
echo "✓ flashmq.conf 已修复 (inet4_bind_address)"

# Check image
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "ERROR: Docker image '$IMAGE' not found."
    exit 1
fi
echo "✓ Docker image $IMAGE 存在"

# Verify fix works in container
echo -n "✓ 验证修复后 FlashMQ 启动... "
TEST_RESULT=$(docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -v "${FIXED_CONF}:/home/ubuntu/experiments/flashmq.conf:ro" \
    "$IMAGE" /bin/bash -c "
    /home/ubuntu/experiments/flashmq-instr/build/flashmq \
        --config-file /home/ubuntu/experiments/flashmq.conf &
    sleep 2
    netstat -tlnp 2>/dev/null | grep -q 1883 && echo OK || echo FAIL
    kill %1 2>/dev/null
" 2>&1 | tail -1)

if [ "$TEST_RESULT" != "OK" ]; then
    echo "FAILED! FlashMQ 仍无法监听 1883 端口"
    exit 1
fi
echo "OK (port 1883)"

# Check results dir
if [ ! -d "$RESULTS_DIR" ]; then
    echo "ERROR: Results dir not found: $RESULTS_DIR"
    exit 1
fi
echo "✓ Results dir: $RESULTS_DIR"
echo ""

# ============================================================
# 1. Clean old invalid data
# ============================================================
echo "[$(date '+%H:%M:%S')] 清理旧的无效 mpfuzz/peach 数据..."

for fuzzer in mpfuzz peach; do
    FDIR="${RESULTS_DIR}/${fuzzer}"
    if [ -d "$FDIR" ]; then
        # Backup old data
        mv "$FDIR" "${FDIR}_invalid_$(date +%Y%m%d%H%M%S)"
        echo "  已备份旧数据: ${fuzzer} -> ${fuzzer}_invalid_*"
    fi
done

# ============================================================
# 2. Launch MPFuzz (1 container, 4 CPUs)
# ============================================================
echo ""
echo "[$(date '+%H:%M:%S')] 启动 MPFuzz (1 container, --cpus=4)..."

MPFUZZ_DIR="${RESULTS_DIR}/mpfuzz"
mkdir -p "${MPFUZZ_DIR}/instance_1"

MPFUZZ_CID=$(docker run --cap-add=NET_ADMIN --cap-add=NET_RAW --cpus=4 -d \
    -v "${RUN_MPFUZZ_SH}:/home/ubuntu/experiments/run_mpfuzz:ro" \
    -v "${FIXED_CONF}:/home/ubuntu/experiments/flashmq.conf:ro" \
    "$IMAGE" \
    /bin/bash -c "cd /home/ubuntu/experiments && run_mpfuzz ${TIMEOUT} /home/ubuntu/experiments/mpfuzz_output")
MPFUZZ_CID="${MPFUZZ_CID:0:12}"
echo "  MPFuzz container: ${MPFUZZ_CID}"
echo "${MPFUZZ_CID}" > "${MPFUZZ_DIR}/container_ids.txt"

cat > "${MPFUZZ_DIR}/mpfuzz_config.json" << EOF
{
    "target": "flashmq",
    "image": "${IMAGE}",
    "instances": 1,
    "internal_agents": 4,
    "timeout": ${TIMEOUT},
    "coverage_type": "edge_bitmap",
    "fix_applied": "inet4-bind-address -> inet4_bind_address",
    "start_time": "$(date -Iseconds)"
}
EOF

# ============================================================
# 3. Launch Peach (4 containers, 1 CPU each)
# ============================================================
echo "[$(date '+%H:%M:%S')] 启动 Peach (4 containers, --cpus=1 each)..."

PEACH_DIR="${RESULTS_DIR}/peach"
mkdir -p "$PEACH_DIR"

PEACH_CIDS=()
for i in 1 2 3 4; do
    CID=$(docker run --cap-add=NET_ADMIN --cap-add=NET_RAW --cpus=1 -d \
        -v "${RUN_MPFUZZ_SH}:/home/ubuntu/experiments/run_mpfuzz:ro" \
        -v "${FIXED_CONF}:/home/ubuntu/experiments/flashmq.conf:ro" \
        "$IMAGE" \
        /bin/bash -c "cd /home/ubuntu/experiments && run_mpfuzz ${TIMEOUT} /home/ubuntu/experiments/peach_output")
    CID="${CID:0:12}"
    PEACH_CIDS+=("$CID")
    mkdir -p "${PEACH_DIR}/instance_${i}"
    echo "  Peach instance_${i}: ${CID}"
done
echo "${PEACH_CIDS[*]}" > "${PEACH_DIR}/container_ids.txt"

cat > "${PEACH_DIR}/peach_config.json" << EOF
{
    "target": "flashmq",
    "image": "${IMAGE}",
    "instances": 4,
    "timeout": ${TIMEOUT},
    "coverage_type": "edge_bitmap",
    "fix_applied": "inet4-bind-address -> inet4_bind_address",
    "start_time": "$(date -Iseconds)"
}
EOF

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  所有容器已启动！                                        ║"
echo "║  MPFuzz:  ${MPFUZZ_CID}  (4 CPUs)                       ║"
printf "║  Peach:   %s  (4x1 CPU)      ║\n" "${PEACH_CIDS[*]}"
echo "║  总 CPU:  8 / 24 cores                                  ║"
echo "║  消融实验可安全并行运行（剩余 16 cores）                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Quick sanity check: verify FlashMQ started inside containers
sleep 10
echo "[$(date '+%H:%M:%S')] 10秒后 sanity check..."
for cid in "$MPFUZZ_CID" "${PEACH_CIDS[0]}"; do
    LOG_SNIPPET=$(docker logs "$cid" 2>&1 | grep -E "listening|WARNING|All instances")
    if echo "$LOG_SNIPPET" | grep -q "listening"; then
        echo "  ✓ ${cid}: FlashMQ listening on 1883"
    elif echo "$LOG_SNIPPET" | grep -q "WARNING"; then
        echo "  ⚠ ${cid}: WARNING - FlashMQ 可能未就绪（但脚本继续运行中）"
    else
        echo "  ? ${cid}: $(docker logs "$cid" 2>&1 | tail -3)"
    fi
done

# ============================================================
# 4. Monitor loop (every 30min)
# ============================================================
echo ""
echo "[$(date '+%H:%M:%S')] 开始监控（每30分钟报告）..."
echo "  按 Ctrl+C 可安全中断监控（不影响容器运行）"
echo ""

START_TIME=$(date +%s)
ALL_CIDS=("$MPFUZZ_CID" "${PEACH_CIDS[@]}")

while true; do
    sleep 1800

    NOW=$(date +%s)
    ELAPSED=$(( NOW - START_TIME ))
    ELAPSED_H=$(echo "scale=1; $ELAPSED/3600" | bc)

    RUNNING=0
    for cid in "${ALL_CIDS[@]}"; do
        STATE=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
        [ "$STATE" = "true" ] && RUNNING=$((RUNNING + 1))

        # Force kill if timeout + grace exceeded
        if [ "$STATE" = "true" ] && [ $ELAPSED -ge $((TIMEOUT + 300)) ]; then
            echo "  Killing overtime container $cid"
            docker kill "$cid" >/dev/null 2>&1 || true
        fi
    done

    echo "[$(date '+%H:%M:%S')] Elapsed: ${ELAPSED_H}h | Running: ${RUNNING}/${#ALL_CIDS[@]}"

    if [ "$RUNNING" -eq 0 ]; then
        echo "[$(date '+%H:%M:%S')] 所有容器完成！"
        break
    fi
done

# ============================================================
# 5. Collect results
# ============================================================
echo ""
echo "[$(date '+%H:%M:%S')] 收集结果..."

# --- MPFuzz ---
echo "  收集 MPFuzz..."
docker cp "${MPFUZZ_CID}:/home/ubuntu/experiments/mpfuzz_output/" \
    "${MPFUZZ_DIR}/instance_1/mpfuzz_output" 2>/dev/null || true

if [ -f "${MPFUZZ_DIR}/instance_1/mpfuzz_output/edge_coverage.csv" ]; then
    cp "${MPFUZZ_DIR}/instance_1/mpfuzz_output/edge_coverage.csv" \
        "${MPFUZZ_DIR}/instance_1/edge_coverage.csv"
    MPFUZZ_EDGES=$(tail -1 "${MPFUZZ_DIR}/instance_1/edge_coverage.csv" | cut -d',' -f2 | tr -d ' ')
    echo "    ✓ MPFuzz edge_coverage.csv (final edges: ${MPFUZZ_EDGES:-N/A})"
else
    echo "    ✗ MPFuzz edge_coverage.csv NOT FOUND"
fi
docker logs "$MPFUZZ_CID" > "${MPFUZZ_DIR}/instance_1/container.log" 2>&1 || true
docker rm "$MPFUZZ_CID" 2>/dev/null || true

# --- Peach ---
for i in 1 2 3 4; do
    CID="${PEACH_CIDS[$((i-1))]}"
    INST_DIR="${PEACH_DIR}/instance_${i}"
    echo "  收集 Peach instance_${i} (${CID})..."

    docker cp "${CID}:/home/ubuntu/experiments/peach_output/" \
        "${INST_DIR}/peach_output" 2>/dev/null || true

    if [ -f "${INST_DIR}/peach_output/edge_coverage.csv" ]; then
        cp "${INST_DIR}/peach_output/edge_coverage.csv" "${INST_DIR}/edge_coverage.csv"
        PEACH_EDGES=$(tail -1 "${INST_DIR}/edge_coverage.csv" | cut -d',' -f2 | tr -d ' ')
        echo "    ✓ Peach instance_${i} edge_coverage.csv (final edges: ${PEACH_EDGES:-N/A})"
    else
        echo "    ✗ Peach instance_${i} edge_coverage.csv NOT FOUND"
    fi
    docker logs "$CID" > "${INST_DIR}/container.log" 2>&1 || true
    docker rm "$CID" 2>/dev/null || true
done

# ============================================================
# 6. Update coverage_summary.csv
# ============================================================
echo ""
echo "[$(date '+%H:%M:%S')] 更新 coverage_summary.csv..."

SUMMARY="${RESULTS_DIR}/coverage_summary.csv"

# Remove old mpfuzz/peach lines, keep header + aflnet + gmpfuzz
grep -v "^mpfuzz\|^peach" "$SUMMARY" > "${SUMMARY}.tmp" || true

# Add MPFuzz
MPFUZZ_CSV="${MPFUZZ_DIR}/instance_1/edge_coverage.csv"
if [ -f "$MPFUZZ_CSV" ]; then
    MPFUZZ_FINAL=$(tail -1 "$MPFUZZ_CSV" | cut -d',' -f2 | tr -d ' ')
    MPFUZZ_POINTS=$(wc -l < "$MPFUZZ_CSV")
    echo "mpfuzz,1,N/A,N/A,${MPFUZZ_FINAL:-0},${MPFUZZ_POINTS}" >> "${SUMMARY}.tmp"
else
    echo "mpfuzz,1,N/A,N/A,0,0" >> "${SUMMARY}.tmp"
fi

# Add Peach instances
for i in 1 2 3 4; do
    PEACH_CSV="${PEACH_DIR}/instance_${i}/edge_coverage.csv"
    if [ -f "$PEACH_CSV" ]; then
        PEACH_FINAL=$(tail -1 "$PEACH_CSV" | cut -d',' -f2 | tr -d ' ')
        PEACH_POINTS=$(wc -l < "$PEACH_CSV")
        echo "peach,${i},N/A,N/A,${PEACH_FINAL:-0},${PEACH_POINTS}" >> "${SUMMARY}.tmp"
    else
        echo "peach,${i},N/A,N/A,0,0" >> "${SUMMARY}.tmp"
    fi
done

mv "${SUMMARY}.tmp" "$SUMMARY"
echo "  ✓ coverage_summary.csv 已更新："
cat "$SUMMARY"

# ============================================================
# 7. Regenerate plots
# ============================================================
echo ""
echo "[$(date '+%H:%M:%S')] 重新生成图表..."
cd "$SCRIPT_DIR"
python3 experiments/plot_results.py "$RESULTS_DIR" --format pdf 2>&1 || true

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  补充实验完成！                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Results:  ${RESULTS_DIR}                                ║"
echo "║  Summary:  coverage_summary.csv                          ║"
echo "║  Plots:    plots/edge_coverage_over_time.pdf             ║"
echo "║            plots/gcovr_coverage_bar.pdf                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
