#!/bin/bash
# ============================================================
# clean_experiments.sh - 清理实验环境
#
# 功能:
#   1. 停止并删除所有 fuzzer 相关 Docker 容器
#   2. 可选: 删除实验结果目录
#   3. 可选: 删除 Docker 镜像（重建前使用）
#
# 用法:
#   ./clean_experiments.sh                  # 仅清理容器
#   ./clean_experiments.sh --results        # 同时删除结果目录
#   ./clean_experiments.sh --results DIR    # 删除指定结果目录
#   ./clean_experiments.sh --images         # 同时删除 Docker 镜像
#   ./clean_experiments.sh --all            # 全部清理
#   ./clean_experiments.sh --dry-run        # 仅显示会做什么，不执行
# ============================================================
set -uo pipefail

CLEAN_RESULTS=false
CLEAN_IMAGES=false
DRY_RUN=false
RESULTS_DIR=""

# 相关 Docker 镜像
IMAGES=("gmpfuzz/mqtt" "gmpfuzz/mongoose" "gmpfuzz/nanomq"
        "mpfuzz/mqtt" "mpfuzz/mongoose" "mpfuzz/nanomq")

show_help() {
    sed -n '2,16p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --results)
            CLEAN_RESULTS=true
            # 如果下一个参数不以 -- 开头且存在，视为目录
            if [[ "${2:-}" != "" && "${2:0:2}" != "--" ]]; then
                RESULTS_DIR="$2"; shift
            fi
            shift ;;
        --images)   CLEAN_IMAGES=true; shift ;;
        --all)      CLEAN_RESULTS=true; CLEAN_IMAGES=true; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        -h|--help)  show_help ;;
        *)          echo "Unknown: $1"; show_help ;;
    esac
done

run_cmd() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

echo "========================================================"
echo "  实验环境清理"
echo "========================================================"
if $DRY_RUN; then
    echo "  模式: DRY RUN (不实际执行)"
fi
echo ""

# ---------------------------------------------------------
# 1. 停止并删除 fuzzer 容器
# ---------------------------------------------------------
echo "[Step 1] 清理 Docker 容器..."

# 查找所有使用相关镜像的容器
CONTAINERS=()
for img in "${IMAGES[@]}"; do
    while IFS= read -r cid; do
        [ -n "$cid" ] && CONTAINERS+=("$cid")
    done < <(docker ps -a --filter "ancestor=$img" -q 2>/dev/null)
done

if [ ${#CONTAINERS[@]} -eq 0 ]; then
    echo "  没有找到 fuzzer 相关容器。"
else
    echo "  找到 ${#CONTAINERS[@]} 个容器，正在清理..."
    for cid in "${CONTAINERS[@]}"; do
        NAME=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's/^\///')
        IMG=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)
        STATE=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)
        echo "  ${cid:0:12} (${IMG:-?}) [${STATE:-?}] ${NAME}"
        if [ "$STATE" = "running" ]; then
            run_cmd docker kill "$cid" >/dev/null 2>&1 || true
            sleep 1
        fi
        run_cmd docker rm -f "$cid" >/dev/null 2>&1 || true
    done
    echo "  容器清理完成。"
fi

# ---------------------------------------------------------
# 2. 清理结果目录
# ---------------------------------------------------------
if $CLEAN_RESULTS; then
    echo ""
    echo "[Step 2] 清理实验结果..."

    if [ -n "$RESULTS_DIR" ]; then
        DIRS_TO_CLEAN=("$RESULTS_DIR")
    else
        # 默认清理常见结果目录
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        DIRS_TO_CLEAN=()
        for d in "$SCRIPT_DIR"/results_* "$(pwd)"/results "$(pwd)"/evaluation "$SCRIPT_DIR"/../evaluation; do
            [ -d "$d" ] && DIRS_TO_CLEAN+=("$d")
        done
    fi

    if [ ${#DIRS_TO_CLEAN[@]} -eq 0 ]; then
        echo "  没有找到结果目录。"
    else
        for d in "${DIRS_TO_CLEAN[@]}"; do
            SIZE=$(du -sh "$d" 2>/dev/null | cut -f1)
            echo "  删除: $d ($SIZE)"
            run_cmd rm -rf "$d"
        done
    fi
else
    echo ""
    echo "[Step 2] 跳过结果清理 (使用 --results 启用)"
fi

# ---------------------------------------------------------
# 3. 清理 Docker 镜像
# ---------------------------------------------------------
if $CLEAN_IMAGES; then
    echo ""
    echo "[Step 3] 清理 Docker 镜像..."
    for img in "${IMAGES[@]}"; do
        if docker image inspect "$img" >/dev/null 2>&1; then
            echo "  删除镜像: $img"
            run_cmd docker rmi -f "$img" 2>/dev/null || true
        fi
    done
    # 清理悬空镜像
    DANGLING=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    if [ "$DANGLING" -gt 0 ]; then
        echo "  清理 $DANGLING 个悬空镜像..."
        run_cmd docker image prune -f >/dev/null 2>&1 || true
    fi
    echo "  镜像清理完成。"
else
    echo ""
    echo "[Step 3] 跳过镜像清理 (使用 --images 启用)"
fi

# ---------------------------------------------------------
# 4. 清理临时文件
# ---------------------------------------------------------
echo ""
echo "[Step 4] 清理临时文件..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 清理 preset 下的生成目录（如果存在）
CLEANED=0
for d in "$PROJECT_DIR"/preset/*/gen* "$PROJECT_DIR"/preset/*/stamps; do
    if [ -d "$d" ]; then
        echo "  删除: $d"
        run_cmd rm -rf "$d"
        CLEANED=$((CLEANED + 1))
    fi
done
# 清理 .bak 文件
while IFS= read -r f; do
    echo "  删除: $f"
    run_cmd rm -f "$f"
    CLEANED=$((CLEANED + 1))
done < <(find "$PROJECT_DIR" -name "*.bak" -type f 2>/dev/null)

if [ $CLEANED -eq 0 ]; then
    echo "  没有临时文件需要清理。"
fi

# ---------------------------------------------------------
# 汇总
# ---------------------------------------------------------
echo ""
echo "========================================================"
echo "  清理完成!"
if $DRY_RUN; then
    echo "  (DRY RUN - 未实际执行任何操作)"
fi
echo "========================================================"
