#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CRASH_DIR="$REPO_ROOT/crash"
IMG="mosquitto:asan"

mkdir -p "$CRASH_DIR"
echo "Generating repro dirs for Mosquitto crash archives..."

for src in "$CRASH_DIR"/Mosquitto-*; do
  [ -d "$src" ] || continue
  base=$(basename "$src")
  target_dir="$CRASH_DIR/Mosquitto_vuln_${base}"
  if [ -e "$target_dir" ]; then
    echo "Target exists, skipping: $target_dir"
    continue
  fi
  mkdir -p "$target_dir"

  # copy largest raw as poc.raw
  raw=$(ls -S -- "$src"/*.raw 2>/dev/null | head -n1 || true)
  if [ -n "$raw" ]; then
    cp -a "$raw" "$target_dir/poc.raw"
  fi

  # copy ASAN log if present
  if ls "$src"/asan_full.log* >/dev/null 2>&1; then
    cp -a "$src"/asan_full.log* "$target_dir/asan_full.log" || true
  fi

  # create replay.sh
  cat > "$target_dir/replay.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# run the ASAN mosquitto image with host networking so we can send to 127.0.0.1:1883
docker run --rm --network host -v "$HERE":/out mosquitto:asan /usr/local/sbin/mosquitto -v > /out/broker_stdout.log 2>&1 &
pid=$!
echo $pid > /out/broker.pid
sleep 1
# send the poc
if [ -f /out/poc.raw ]; then
  python3 - <<PY > /out/send.log 2>&1 || true
import socket,sys
s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',1883)); s.sendall(open('/out/poc.raw','rb').read()); s.close(); print('sent')
PY
else
  echo "poc.raw not found" > /out/send.log
fi
sleep 2
if ps -p $pid >/dev/null 2>&1; then
  kill $pid || true; sleep 1; kill -9 $pid || true
fi
echo "Replayed; logs: broker_stdout.log send.log asan_full.log" 
SH
  chmod +x "$target_dir/replay.sh"

  # create report.md
  cat > "$target_dir/report.md" <<REPORT
# Mosquitto vulnerability reproduction

- Source archive: $base
- Repro script: `replay.sh`
- Poc: `poc.raw`

## Evidence

ASAN log (if present) is saved as `asan_full.log` in this directory. See it for AddressSanitizer output and stack traces.

REPORT

  echo "Created repro dir: $target_dir"
done

echo "Done. Review created dirs under: $CRASH_DIR"
