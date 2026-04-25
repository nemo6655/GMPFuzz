#!/usr/bin/env bash
## Extract replayable-crashes (MQTT) from evaluation tarballs and replay them
## Usage: sudo ./scripts/extract_and_replay_replayable_mqtt.sh [timeout_seconds]
set -euo pipefail

TIMEOUT=${1:-10}
ROOT_DIR=$(pwd)
OUT_DIR=/tmp/repro_samples_replayable
RESULT_DIR=/tmp/repro_results_replayable
MANIFEST="$OUT_DIR/manifest.csv"
PROGRESS_LOG="$OUT_DIR/extract_progress.log"

mkdir -p "$OUT_DIR" "$RESULT_DIR"
[ -f "$MANIFEST" ] || echo 'sample_file,tarball,internal_path,inferred_target,size_bytes' > "$MANIFEST"

echo "Starting extraction+replay (timeout=${TIMEOUT}s)" | tee -a "$PROGRESS_LOG"

# Helper: sanitize id to safe dir name
sanitize_id() {
  local bn="$1"
  # replace ':' with '_' and commas/spaces
  echo "$bn" | sed -e 's/:/_/g' -e 's/,.*//' -e 's/[^A-Za-z0-9_\.-]/_/g'
}

# Iterate tarballs and handle only MQTT-related ones
while IFS= read -r -d $'\0' tarball; do
  # quick filter to mqtt-related archives
  case "$tarball" in
    *mqtt*|*mosquitto*|*out-mqtt*|*gmpfuzz*) : ;;
    *) continue ;;
  esac

  echo "Processing tarball: $tarball" | tee -a "$PROGRESS_LOG"
  # list entries under replayable-crashes
  mapfile -t entries < <(tar -tzf "$tarball" 2>/dev/null | grep -E '/replayable-crashes/' || true)
  if [ ${#entries[@]} -eq 0 ]; then
    echo "  no replayable-crashes entries" >> "$PROGRESS_LOG"
    continue
  fi

  for entry in "${entries[@]}"; do
    bn=$(basename "$entry")
    # skip directories and README
    if [ -z "$bn" ] || [ "$bn" = "README.txt" ] || [[ "$entry" =~ /$ ]]; then
      continue
    fi

    tarbase=$(basename "$tarball")
    safe_tar=$(echo "$tarbase" | sed 's/[^A-Za-z0-9._-]/_/g')
    outname="${safe_tar}__${bn}"
    outpath="$OUT_DIR/$outname"

    if [ -f "$outpath" ]; then
      echo "  already extracted: $outname" >> "$PROGRESS_LOG"
    else
      if ! tar -xzf "$tarball" -O "$entry" > "$outpath" 2>/tmp/extract_err.log; then
        echo "  FAILED extract $entry from $tarball" >> "$PROGRESS_LOG"
        cat /tmp/extract_err.log >> "$PROGRESS_LOG" || true
        rm -f /tmp/extract_err.log || true
        continue
      fi
      rm -f /tmp/extract_err.log || true
      sz=$(stat -c%s "$outpath" 2>/dev/null || echo 0)
      echo "${outname},${tarball},${entry},mqtt,${sz}" >> "$MANIFEST"
      echo "  extracted $outname (size=${sz})" >> "$PROGRESS_LOG"
    fi

    # Replay the single sample inside the container (no wildcard)
    echo "  replaying $outname (timeout ${TIMEOUT}s)" >> "$PROGRESS_LOG"
    docker run --rm -v "$OUT_DIR":/tmp/replay_inputs -v "$RESULT_DIR":/tmp/repro_results_replayable gmpfuzz/mqtt bash -lc \
      "timeout ${TIMEOUT}s /home/ubuntu/aflnet/aflnet-replay /tmp/replay_inputs/${outname} MQTT 1883 1 > /tmp/repro_results_replayable/${outname}.log 2>&1 || true"

    # Inspect replay output for crash indicators
    logpath="$RESULT_DIR/${outname}.log"
    if [ -f "$logpath" ] && grep -Eqi 'AddressSanitizer|==ABORTING==|segmentation fault|segfault|Aborted|core dumped|SIG' "$logpath" >/dev/null 2>&1; then
      echo "  CRASH-DETECTED for $outname" | tee -a "$PROGRESS_LOG"
      idpart=$(sanitize_id "$bn")
      crashdir="crash/mosquitto-${idpart}"
      mkdir -p "$crashdir"
      cp -a "$outpath" "$crashdir/" || true
      cp -a "$logpath" "$crashdir/" || true
      printf 'Source-Tar: %s\nInternal-Path: %s\nExtracted-At: %s\nTimeout: %ss\n' "$tarball" "$entry" "$(date -Is)" "$TIMEOUT" > "$crashdir/README.txt"
    else
      echo "  OK: $outname" >> "$PROGRESS_LOG"
    fi

    # small sleep to avoid hammering the system
    sleep 0.1
  done
done < <(find evaluation -type f -name '*.tar.gz' -print0)

echo "Extraction+replay finished" | tee -a "$PROGRESS_LOG"
echo "Manifest lines: $(wc -l < "$MANIFEST")" | tee -a "$PROGRESS_LOG"
echo "Samples dir listing:" | tee -a "$PROGRESS_LOG"
ls -la "$OUT_DIR" | tee -a "$PROGRESS_LOG"
echo "Results dir listing:" | tee -a "$PROGRESS_LOG"
ls -la "$RESULT_DIR" | tee -a "$PROGRESS_LOG"

exit 0
