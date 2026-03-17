#!/bin/bash
# ============================================================
# supplement_instance.sh - 为已有实验目录补充一个 aflnet 实例
#
# 针对 results_20260312_155733 实验，该次实验原计划 4 个 aflnet 实例，
# 但只收集到 instance_1/2/3，本脚本补充运行并收集 instance_4。
#
# Usage: ./supplement_instance.sh [options]
#   -t, --target TARGET      目标：mqtt, mongoose, nanomq（默认：mqtt）
#   --timeout SEC            模糊测试时长，秒（默认：86400 = 24h）
#   --instance-num N         补充的实例编号（默认：4）
#   -r, --result-dir DIR     已有实验结果目录（默认：results_20260312_155733）
#   --skip-cov               跳过 gcov 覆盖率收集
#   -h, --help               显示帮助
#
# Examples:
#   ./supplement_instance.sh
#   ./supplement_instance.sh -t mqtt --timeout 86400 --instance-num 4
#   ./supplement_instance.sh -r ../evaluation/results_20260312_155733
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_BASE="$(dirname "$SCRIPT_DIR")/evaluation"

# =====================================================================
# 默认参数
# =====================================================================
TARGET="mqtt"
TIMEOUT=86400
INSTANCE_NUM=4
RESULT_DIR="${EVAL_BASE}/results_20260312_155733"
SKIPCOUNT=5
SKIP_COV=0

OPTIONS="-P MQTT -D 10000 -q 3 -s 3 -E -K -R"

# =====================================================================
# 解析参数
# =====================================================================
show_help() {
    sed -n '2,16p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)       TARGET="$2"; shift 2 ;;
        --timeout)         TIMEOUT="$2"; shift 2 ;;
        --instance-num)    INSTANCE_NUM="$2"; shift 2 ;;
        -r|--result-dir)   RESULT_DIR="$2"; shift 2 ;;
        --skip-cov)        SKIP_COV=1; shift ;;
        -h|--help)         show_help ;;
        *) echo "Unknown option: $1"; show_help ;;
    esac
done

# =====================================================================
# Target 配置
# =====================================================================
case "$TARGET" in
    mqtt)
        IMAGE="mosquitto"
        TARGET_DESC="Mosquitto v1.5.5"
        OUTDIR_NAME="out-mqtt-aflnet"
        FALLBACK_PATH="mosquitto/src"
        ;;
    mongoose)
        IMAGE="mongoose"
        TARGET_DESC="Mongoose v7.20"
        OUTDIR_NAME="out-mongoose-aflnet"
        FALLBACK_PATH="mongoose"
        ;;
    nanomq)
        IMAGE="nanomq"
        TARGET_DESC="NanoMQ v0.21.10"
        OUTDIR_NAME="out-nanomq-aflnet"
        FALLBACK_PATH="nanomq/build-afl"
        ;;
    *)
        echo "ERROR: Unknown target '${TARGET}'. Supported: mqtt, mongoose, nanomq"
        exit 1
        ;;
esac

AFLNET_DIR="${RESULT_DIR}/aflnet"
INSTANCE_DIR="${AFLNET_DIR}/instance_${INSTANCE_NUM}"

echo "========================================================"
echo "  AFLNet 补充实例"
echo "========================================================"
echo "  目标:         ${TARGET} (${TARGET_DESC})"
echo "  镜像:         ${IMAGE}"
echo "  超时:         ${TIMEOUT}s ($(echo "scale=1; $TIMEOUT/3600" | bc)h)"
echo "  实例编号:     instance_${INSTANCE_NUM}"
echo "  结果目录:     ${RESULT_DIR}"
echo "  输出目录:     ${INSTANCE_DIR}"
echo "  SkipCount:    ${SKIPCOUNT}"
echo "  SKIP_COV:     ${SKIP_COV}"
echo "  开始时间:     $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"

# =====================================================================
# 前置检查
# =====================================================================
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "ERROR: Docker 镜像 '${IMAGE}' 不存在，请先构建。"
    exit 1
fi

if [ ! -d "$RESULT_DIR" ]; then
    echo "ERROR: 实验目录不存在: ${RESULT_DIR}"
    exit 1
fi

if [ -d "$INSTANCE_DIR" ]; then
    echo "WARNING: instance_${INSTANCE_NUM} 目录已存在: ${INSTANCE_DIR}"
    read -r -p "是否覆盖？[y/N] " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        exit 0
    fi
fi

mkdir -p "$INSTANCE_DIR"

# =====================================================================
# 启动容器
# =====================================================================
echo "[$(date '+%H:%M:%S')] 启动 Docker 容器..."

CID=$(docker run --cpus=1 -d -it \
    -e SKIP_COV=${SKIP_COV} \
    "$IMAGE" \
    /bin/bash -c "cd /home/ubuntu/experiments && \
        run aflnet /home/ubuntu/experiments/in-mqtt ${OUTDIR_NAME} '${OPTIONS}' ${TIMEOUT} ${SKIPCOUNT}")

CID_SHORT="${CID:0:12}"
echo "[$(date '+%H:%M:%S')] 容器已启动: ${CID_SHORT}"
echo "$CID_SHORT" > "${INSTANCE_DIR}/container_id.txt"

# 追加到 aflnet 目录的 container_ids.txt
if [ -f "${AFLNET_DIR}/container_ids.txt" ]; then
    # 检查是否已存在，避免重复追加
    if ! grep -q "$CID_SHORT" "${AFLNET_DIR}/container_ids.txt"; then
        # 在末尾追加（同行用空格分隔，保持原格式）
        sed -i "s/$/ $CID_SHORT/" "${AFLNET_DIR}/container_ids.txt"
        echo "[$(date '+%H:%M:%S')] 已追加容器 ID 到 container_ids.txt"
    fi
fi

echo ""
echo "等待容器完成（约 $(echo "scale=1; $TIMEOUT/3600" | bc) 小时）..."
echo "可通过以下命令监控进度："
echo "  docker logs -f ${CID_SHORT}"
echo ""

# =====================================================================
# 等待容器结束
# =====================================================================
START_TIME=$(date +%s)
while true; do
    sleep 600
    ELAPSED=$(( $(date +%s) - START_TIME ))
    STATE=$(docker inspect -f '{{.State.Running}}' "$CID_SHORT" 2>/dev/null || echo "false")
    echo "[$(date '+%H:%M:%S')] 已运行 ${ELAPSED}s | 容器状态: ${STATE}"
    if [ "$STATE" != "true" ]; then
        echo "[$(date '+%H:%M:%S')] 容器已结束。"
        break
    fi
done

# =====================================================================
# 收集结果
# =====================================================================
echo ""
echo "[$(date '+%H:%M:%S')] 开始收集结果..."

# 保存容器日志
docker logs "$CID_SHORT" > "${INSTANCE_DIR}/container.log" 2>&1 || true
echo "  容器日志已保存: container.log"

# 拷贝 tar.gz
if docker cp "${CID_SHORT}:/home/ubuntu/experiments/${OUTDIR_NAME}.tar.gz" \
        "${INSTANCE_DIR}/${OUTDIR_NAME}.tar.gz" 2>/dev/null; then
    echo "  tar.gz 拷贝成功"
    cd "$INSTANCE_DIR"
    tar -xzf "${OUTDIR_NAME}.tar.gz" 2>/dev/null || true

    # 提取覆盖率 CSV
    if [ -f "${OUTDIR_NAME}/cov_over_time.csv" ]; then
        cp "${OUTDIR_NAME}/cov_over_time.csv" "${INSTANCE_DIR}/cov_over_time.csv"
        FINAL_LINE=$(tail -1 "${INSTANCE_DIR}/cov_over_time.csv")
        L_PER=$(echo "$FINAL_LINE" | cut -d',' -f2)
        B_PER=$(echo "$FINAL_LINE" | cut -d',' -f4)
        echo "  覆盖率 CSV: OK (L=${L_PER}% B=${B_PER}%)"
    else
        echo "  WARNING: cov_over_time.csv 未找到"
    fi
    cd - > /dev/null
else
    # 回退：直接 cp 输出目录
    echo "  WARNING: tar.gz 未找到，尝试直接拷贝输出目录..."
    docker cp "${CID_SHORT}:/home/ubuntu/experiments/${FALLBACK_PATH}/${OUTDIR_NAME}" \
        "${INSTANCE_DIR}/" 2>/dev/null || \
    docker cp "${CID_SHORT}:/home/ubuntu/experiments/${OUTDIR_NAME}" \
        "${INSTANCE_DIR}/" 2>/dev/null || true

    if [ -d "${INSTANCE_DIR}/${OUTDIR_NAME}" ]; then
        echo "  回退拷贝成功"
        if [ -f "${INSTANCE_DIR}/${OUTDIR_NAME}/cov_over_time.csv" ]; then
            cp "${INSTANCE_DIR}/${OUTDIR_NAME}/cov_over_time.csv" \
               "${INSTANCE_DIR}/cov_over_time.csv"
            echo "  cov_over_time.csv 已恢复"
        fi
    else
        echo "  ERROR: 结果拷贝失败，请手动检查容器 ${CID_SHORT}"
    fi
fi

# 统计 replayable-queue
if [ -d "${INSTANCE_DIR}/${OUTDIR_NAME}/replayable-queue" ]; then
    RQUEUE=$(ls "${INSTANCE_DIR}/${OUTDIR_NAME}/replayable-queue/" 2>/dev/null | wc -l)
    echo "  Replayable queue: ${RQUEUE} 条"
fi

# 清理容器
docker rm "$CID_SHORT" 2>/dev/null || true
echo "  容器已清理: ${CID_SHORT}"

# =====================================================================
# 汇总
# =====================================================================
TOTAL_TIME=$(( $(date +%s) - START_TIME ))
echo ""
echo "========================================================"
echo "  补充实例完成"
echo "========================================================"
echo "  目标:         ${TARGET} (${TARGET_DESC})"
echo "  实例编号:     instance_${INSTANCE_NUM}"
echo "  总耗时:       ${TOTAL_TIME}s ($(echo "scale=1; $TOTAL_TIME/3600" | bc)h)"
echo "  结果路径:     ${INSTANCE_DIR}"
echo "  结束时间:     $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
