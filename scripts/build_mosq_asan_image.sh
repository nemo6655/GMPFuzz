#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DOCKER_DIR="$HERE/docker/mosquitto-asan"
IMAGE_NAME="mosquitto:asan"

echo "Building Docker image $IMAGE_NAME from $DOCKER_DIR"
docker build -t "$IMAGE_NAME" "$DOCKER_DIR"
echo "Docker image built: $IMAGE_NAME"
