#!/bin/bash
set -e

TARGET="mqtt"
NUM_GENS=2
ABLATION_MODE="full"
SESSION_ID="ablation_20260420_101938_full"
RUNDIR="preset/${TARGET}"
EVAL_DIR="evaluation/gmpfuzz_${TARGET}_${SESSION_ID}"

# Define the missing variables so the rest of the script works
GCOV_IMAGE="gmpfuzz/mqtt"
GCOV_TARGET_DIR="mosquitto-gcov"
GCOV_SRC_DIR="/home/ubuntu/experiments/mosquitto-gcov/src"
GCOV_ROOT="/home/ubuntu/experiments/mosquitto-gcov"
GCOV_CONF="/home/ubuntu/experiments/mosquitto.conf"
GCOV_BIN="./mosquitto"
GCOV_BIN_ARGS="start --conf ${GCOV_CONF}"
GCOV_PORT=1883

ARCHIVE_NAME="gmpfuzz_mqtt_ablation_20260420_101938_full.tar.gz"

echo "Running recovery for $EVAL_DIR..."

cat recover.sh >> run_recover.tmp.sh
source run_recover.tmp.sh
