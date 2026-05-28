#!/usr/bin/env bash
set -eu

# Robust replay script for Mosquitto repros
# Usage: run from repository root. Writes summary to /tmp/mosq_asan_debug_repro_summary.tsv

ROOT_DIR="$(pwd)"
OUT_SUM="/tmp/mosq_asan_debug_repro_summary.tsv"
echo -e "sample	attempts	send_status	start_status	asan_present	notes" > "$OUT_SUM"

PORT_BASE=42000
idx=0

for d in crash/Mosquitto_vuln_*; do
  if [ ! -d "$d" ]; then
    continue
  fi
  idx=$((idx+1))
  D="$ROOT_DIR/$d"
  RAW="$D/poc.raw"
  sample_name=$(basename "$d")
  if [ ! -f "$RAW" ]; then
    echo -e "$sample_name	0	-	-	no	missing_raw" >> "$OUT_SUM"
    continue
  fi

  attempts=0
  asan_present=no
  send_status=not_sent
  start_status=not_started
  notes=""

  for attempt in 1 2 3; do
    attempts=$attempt
    PORT=$((PORT_BASE + idx + attempt))

    # find an available port (simple increment)
    tries=0
    while ss -ltn "sport = :$PORT" >/dev/null 2>&1; do
      PORT=$((PORT+1))
      tries=$((tries+1))
      if [ $tries -gt 50 ]; then
        break
      fi
    done

    CONTAINER_ID=$(docker run -d --rm -u "$(id -u):$(id -g)" -p ${PORT}:1883 -v "$D":/out -e ASAN_OPTIONS="verbosity=1:detect_stack_use_after_return=1:detect_leaks=0" mosquitto:asan-debug sh -c 'mosquitto -v > /out/broker_stdout.log 2>&1' 2>/dev/null || true
    if [ -z "$CONTAINER_ID" ]; then
      start_status=start_failed
      notes="docker_run_failed"
      sleep 1
      continue
    else
      start_status=started
    fi

    # wait for broker port
    ready=0
    for i in {1..15}; do
      if timeout 1 bash -c "</dev/tcp/127.0.0.1/${PORT}" >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    if [ $ready -eq 0 ]; then
      notes="port_not_ready"
      docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
      start_status=port_not_ready
      sleep 1
      continue
    fi

    # send payload
    python3 - <<PY > "$D/send.log" 2>&1 || true
import socket,sys
try:
    s=socket.create_connection(('127.0.0.1', $PORT), timeout=5)
    with open('$RAW','rb') as f:
        s.sendall(f.read())
    s.close()
    print('sent')
except Exception as e:
    print('send_error:', e)
    sys.exit(2)
PY
    if grep -q "^sent" "$D/send.log" 2>/dev/null; then
      send_status=sent
    else
      send_status=send_failed
    fi

    sleep 2
    docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true

    # inspect logs for ASAN evidence
    if [ -f "$D/broker_stdout.log" ] && grep -q -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/broker_stdout.log"; then
      asan_present=yes
      notes="found_in_broker_stdout"
      grep -n -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/broker_stdout.log" | sed -n '1,200p' > "$D/asan_snippet.txt" || true
    elif [ -f "$D/asan_full.log" ] && grep -q -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/asan_full.log"; then
      asan_present=yes
      notes="found_in_asan_full"
      grep -n -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/asan_full.log" | sed -n '1,200p' > "$D/asan_snippet.txt" || true
    else
      asan_present=no
    fi

    if [ "$asan_present" = "yes" ]; then
      break
    fi

    sleep 1
  done

  echo -e "$sample_name	$attempts	$send_status	$start_status	$asan_present	$notes" >> "$OUT_SUM"
  echo "Processed $sample_name: asan_present=$asan_present, attempts=$attempts"
done

echo "Summary written to $OUT_SUM"
#!/usr/bin/env bash
set -eu

# Robust replay script for Mosquitto repros
# Usage: run from repository root. Writes summary to /tmp/mosq_asan_debug_repro_summary.tsv

ROOT_DIR="$(pwd)"
OUT_SUM="/tmp/mosq_asan_debug_repro_summary.tsv"
echo -e "sample\tattempts\tsend_status\tstart_status\tasan_present\tnotes" > "$OUT_SUM"

PORT_BASE=42000
idx=0

for d in crash/Mosquitto_vuln_*; do
  if [ ! -d "$d" ]; then
    continue
  fi
  idx=$((idx+1))
  D="$ROOT_DIR/$d"
  RAW="$D/poc.raw"
  sample_name=$(basename "$d")
  if [ ! -f "$RAW" ]; then
    echo -e "$sample_name\t0\t-\t-\tno\tmissing_raw" >> "$OUT_SUM"
    continue
  fi

  attempts=0
  asan_present=no
  send_status=not_sent
  start_status=not_started
  notes=""

  for attempt in 1 2 3; do
    attempts=$attempt
    PORT=$((PORT_BASE + idx + attempt))

    # find an available port (simple increment)
    tries=0
    while ss -ltn "sport = :$PORT" >/dev/null 2>&1; do
      PORT=$((PORT+1))
      tries=$((tries+1))
      if [ $tries -gt 50 ]; then
        break
      fi
    done

    CONTAINER_ID=$(docker run -d --rm -u "$(id -u):$(id -g)" -p ${PORT}:1883 -v "$D":/out -e ASAN_OPTIONS="verbosity=1:detect_stack_use_after_return=1:detect_leaks=0" mosquitto:asan-debug sh -c 'mosquitto -v > /out/broker_stdout.log 2>&1' 2>/dev/null || true
    if [ -z "$CONTAINER_ID" ]; then
      start_status=start_failed
      notes="docker_run_failed"
      sleep 1
      continue
    else
      start_status=started
    fi

    # wait for broker port
    ready=0
    for i in {1..15}; do
      if timeout 1 bash -c "</dev/tcp/127.0.0.1/${PORT}" >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    if [ $ready -eq 0 ]; then
      notes="port_not_ready"
      docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
      start_status=port_not_ready
      sleep 1
      continue
    fi

    # send payload
    python3 - <<PY > "$D/send.log" 2>&1 || true
import socket,sys
try:
    s=socket.create_connection(('127.0.0.1', $PORT), timeout=5)
    with open('$RAW','rb') as f:
        s.sendall(f.read())
    s.close()
    print('sent')
except Exception as e:
    print('send_error:', e)
    sys.exit(2)
PY
    if grep -q "^sent" "$D/send.log" 2>/dev/null; then
      send_status=sent
    else
      send_status=send_failed
    fi

    sleep 2
    docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true

    # inspect logs for ASAN evidence
    if [ -f "$D/broker_stdout.log" ] && grep -q -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/broker_stdout.log"; then
      asan_present=yes
      notes="found_in_broker_stdout"
      grep -n -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/broker_stdout.log" | sed -n '1,200p' > "$D/asan_snippet.txt" || true
    elif [ -f "$D/asan_full.log" ] && grep -q -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/asan_full.log"; then
      asan_present=yes
      notes="found_in_asan_full"
      grep -n -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/asan_full.log" | sed -n '1,200p' > "$D/asan_snippet.txt" || true
    else
      asan_present=no
    fi

    if [ "$asan_present" = "yes" ]; then
      break
    fi

    sleep 1
  done

  echo -e "$sample_name\t$attempts\t$send_status\t$start_status\t$asan_present\t$notes" >> "$OUT_SUM"
  echo "Processed $sample_name: asan_present=$asan_present, attempts=$attempts"
done

echo "Summary written to $OUT_SUM"
#!/usr/bin/env bash
set -eu

# Robust replay script for Mosquitto repros
# Usage: run from repository root. Writes summary to /tmp/mosq_asan_debug_repro_summary.tsv

ROOT_DIR="$(pwd)"
OUT_SUM="/tmp/mosq_asan_debug_repro_summary.tsv"
echo -e "sample\tattempts\tsend_status\tstart_status\tasan_present\tnotes" > "$OUT_SUM"

PORT_BASE=42000
idx=0

for d in crash/Mosquitto_vuln_*; do
  if [ ! -d "$d" ]; then
    continue
  fi
  idx=$((idx+1))
  D="$ROOT_DIR/$d"
  RAW="$D/poc.raw"
  sample_name=$(basename "$d")
  if [ ! -f "$RAW" ]; then
    echo -e "$sample_name\t0\t-\t-\tno\tmissing_raw" >> "$OUT_SUM"
    continue
  fi

  attempts=0
  asan_present=no
  send_status=not_sent
  start_status=not_started
  notes=""

  for attempt in 1 2 3; do
    attempts=$attempt
    PORT=$((PORT_BASE + idx + attempt))

    # find an available port (simple increment)
    tries=0
    while ss -ltn "sport = :$PORT" >/dev/null 2>&1; do
      PORT=$((PORT+1))
      tries=$((tries+1))
      if [ $tries -gt 50 ]; then
        break
      fi
    done

    CONTAINER_ID=$(docker run -d --rm -u "$(id -u):$(id -g)" -p ${PORT}:1883 -v "$D":/out -e ASAN_OPTIONS="verbosity=1:detect_stack_use_after_return=1:detect_leaks=0" mosquitto:asan-debug sh -c 'mosquitto -v > /out/broker_stdout.log 2>&1' 2>/dev/null || true
    if [ -z "$CONTAINER_ID" ]; then
      start_status=start_failed
      notes="docker_run_failed"
      sleep 1
      continue
    else
      start_status=started
    fi

    # wait for broker port
    ready=0
    for i in {1..15}; do
      if timeout 1 bash -c "</dev/tcp/127.0.0.1/${PORT}" >/dev/null 2>&1; then
        ready=1
        break
      fi
      sleep 1
    done
    if [ $ready -eq 0 ]; then
      notes="port_not_ready"
      docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true
      start_status=port_not_ready
      sleep 1
      continue
    fi

    # send payload
    python3 - <<PY > "$D/send.log" 2>&1 || true
import socket,sys
try:
    s=socket.create_connection(('127.0.0.1', $PORT), timeout=5)
    with open('$RAW','rb') as f:
        s.sendall(f.read())
    s.close()
    print('sent')
except Exception as e:
    print('send_error:', e)
    sys.exit(2)
PY
    if grep -q "^sent" "$D/send.log" 2>/dev/null; then
      send_status=sent
    else
      send_status=send_failed
    fi

    sleep 2
    docker stop "$CONTAINER_ID" >/dev/null 2>&1 || true

    # inspect logs for ASAN evidence
    if [ -f "$D/broker_stdout.log" ] && grep -q -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/broker_stdout.log"; then
      asan_present=yes
      notes="found_in_broker_stdout"
      grep -n -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/broker_stdout.log" | sed -n '1,200p' > "$D/asan_snippet.txt" || true
    elif [ -f "$D/asan_full.log" ] && grep -q -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/asan_full.log"; then
      asan_present=yes
      notes="found_in_asan_full"
      grep -n -E "AddressSanitizer|heap-buffer-overflow|DEADLYSIGNAL|ERROR: AddressSanitizer" "$D/asan_full.log" | sed -n '1,200p' > "$D/asan_snippet.txt" || true
    else
      asan_present=no
    fi

    if [ "$asan_present" = "yes" ]; then
      break
    fi

    sleep 1
  done

  echo -e "$sample_name\t$attempts\t$send_status\t$start_status\t$asan_present\t$notes" >> "$OUT_SUM"
  echo "Processed $sample_name: asan_present=$asan_present, attempts=$attempts"
done

echo "Summary written to $OUT_SUM"
