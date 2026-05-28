#!/bin/bash

# ==============================================================================
# mosquitto_replay_clean.sh
# 
# Replay Mosquitto crash payloads against mosquitto:asan-debug docker container
# ==============================================================================

set -u

# --- CONFIGuration ---
CRASH_DIR="crash"
IMAGE_NAME="mosquitto:asan-debug"
SUMMARY_FILE="/tmp/mosq_asan_debug_repro_summary.tsv"
TIMEOUT_SECS=3
MAX_RETRIES=3

# Initialize summary file
echo -e "sample\tattempts\tsend_status\tstart_status\tasan_present\tnotes" > "$SUMMARY_FILE"

# Make sure we have the required directory
if [ ! -d "$CRASH_DIR" ]; then
    echo "Error: Directory $CRASH_DIR does not exist."
    exit 1
fi

# Find all Mosquitto vulnerability directories
VULN_DIRS=$(find "$CRASH_DIR" -maxdepth 1 -type d -name "Mosquitto_vuln_*")

if [ -z "$VULN_DIRS" ]; then
    echo "No Mosquitto vulnerability directories found matching 'crash/Mosquitto_vuln_*'."
    exit 0
fi

# Iterate over each vulnerability directory
for VULN_DIR in $VULN_DIRS; do
    SAMPLE_NAME=$(basename "$VULN_DIR")
    echo "======================================================================"
    echo "Processing sample: $SAMPLE_NAME"
    echo "Directory: $VULN_DIR"
    echo "======================================================================"

    PAYLOAD_FILE=""
    if [ -f "$VULN_DIR/crash.bin" ]; then
        PAYLOAD_FILE="$VULN_DIR/crash.bin"
    elif [ -f "$VULN_DIR/payload.bin" ]; then
        PAYLOAD_FILE="$VULN_DIR/payload.bin"
    elif [ -f "$VULN_DIR/poc.raw" ]; then
        PAYLOAD_FILE="$VULN_DIR/poc.raw"
    else
        PAYLOAD_FILE=$(find "$VULN_DIR" -maxdepth 1 -type f \( -name "id*" -o -name "crash-*" \) | head -n 1)
        if [ -z "$PAYLOAD_FILE" ]; then
            # fallback to ANY file that is not a directory, python script, shell script, or markdown, and not log/md/id files
            PAYLOAD_FILE=$(find "$VULN_DIR" -maxdepth 1 -type f -not -name "*.py" -not -name "*.sh" -not -name "*.md" -not -name "*.log" -not -name "*.txt" -not -name "container.id" | head -n 1)
        fi
    fi

    if [ -z "$PAYLOAD_FILE" ] || [ ! -f "$PAYLOAD_FILE" ]; then
        echo "[-] Could not find a payload file in $VULN_DIR"
        echo -e "${SAMPLE_NAME}\t0\tN/A\tN/A\tN/A\tNo payload found" >> "$SUMMARY_FILE"
        continue
    fi

    echo "[+] Found payload: $PAYLOAD_FILE"
    
    # Prepare absolute paths for docker mounting
    ABS_VULN_DIR=$(realpath "$VULN_DIR")
    ABS_PAYLOAD_FILE=$(realpath "$PAYLOAD_FILE")

    SUCCESS=0
    ATTEMPT=1
    
    # Retry loop
    while [ $ATTEMPT -le $MAX_RETRIES ] && [ $SUCCESS -eq 0 ]; do
        echo "--- Attempt $ATTEMPT of $MAX_RETRIES ---"

        # Start the container
        echo "[1] Starting mosquitto container..."
        CONTAINER_ID=$(docker run -d --rm \
            --expose 1883 -P \
            -e ASAN_OPTIONS="verbosity=1:detect_stack_use_after_return=1:detect_leaks=0" \
            -v "${ABS_VULN_DIR}:/out" \
            "$IMAGE_NAME")

        if [ -z "$CONTAINER_ID" ]; then
            echo "[-] Failed to start container."
            if [ $ATTEMPT -eq $MAX_RETRIES ]; then
                 echo -e "${SAMPLE_NAME}\t${ATTEMPT}\tN/A\tFAIL\tN/A\tDocker start failed" >> "$SUMMARY_FILE"
            fi
            ((ATTEMPT++))
            continue
        fi

        # Find mapped port
        HOST_PORT=$(docker port "$CONTAINER_ID" 1883/tcp | awk -F ':' '{print $NF}' | head -n 1)
        
        if [ -z "$HOST_PORT" ]; then
            echo "[-] Failed to determine mapped port."
            docker stop "$CONTAINER_ID" >/dev/null 2>&1
            if [ $ATTEMPT -eq $MAX_RETRIES ]; then
                 echo -e "${SAMPLE_NAME}\t${ATTEMPT}\tN/A\tFAIL\tN/A\tPort mapping failed" >> "$SUMMARY_FILE"
            fi
            ((ATTEMPT++))
            continue
        fi
        
        echo "[+] Container running. ID: ${CONTAINER_ID:0:8}, Mapped Port: $HOST_PORT"

        # Wait for broker to be ready
        echo "[2] Waiting for port $HOST_PORT to become ready..."
        READY=0
        for i in {1..10}; do
            if ss -ltn | grep -q ":$HOST_PORT "; then
                READY=1
                break
            fi
            sleep 0.5
        done

        if [ $READY -eq 0 ]; then
             echo "[-] Port $HOST_PORT not ready in time."
             docker logs "$CONTAINER_ID" > "${ABS_VULN_DIR}/broker_stdout_attempt${ATTEMPT}.log" 2>&1
             docker stop "$CONTAINER_ID" >/dev/null 2>&1
             if [ $ATTEMPT -eq $MAX_RETRIES ]; then
                 echo -e "${SAMPLE_NAME}\t${ATTEMPT}\tN/A\tTIMEOUT\tN/A\tBroker not ready" >> "$SUMMARY_FILE"
             fi
             ((ATTEMPT++))
             continue
        fi

        # Send the payload using Python
        echo "[3] Sending payload..."
        python3 -c "
import socket
import sys

try:
    with open('${ABS_PAYLOAD_FILE}', 'rb') as f:
        payload = f.read()
        
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2.0)
    s.connect(('127.0.0.1', int(${HOST_PORT})))
    s.sendall(payload)
    print('Payload sent successfully.')
except Exception as e:
    print(f'Error sending payload: {e}')
    sys.exit(1)
" > "${ABS_VULN_DIR}/send_attempt${ATTEMPT}.log" 2>&1
        
        SEND_RESULT=$?
        
        # Wait a brief moment for broker to process and potentially crash/log ASAN
        sleep 1

        # Collect logs
        echo "[4] Collecting logs..."
        docker logs "$CONTAINER_ID" > "${ABS_VULN_DIR}/broker_stdout.log" 2>&1

        # Stop the container (it might already be stopped if it crashed)
        docker stop "$CONTAINER_ID" >/dev/null 2>&1

        # Check for ASAN output
        ASAN_PRESENT="NO"
        if grep -q "AddressSanitizer" "${ABS_VULN_DIR}/broker_stdout.log"; then
             ASAN_PRESENT="YES"
             grep -A 20 "AddressSanitizer" "${ABS_VULN_DIR}/broker_stdout.log" > "${ABS_VULN_DIR}/asan_snippet.txt"
             echo "[+] ASAN trace found!"
             SUCCESS=1
             echo -e "${SAMPLE_NAME}\t${ATTEMPT}\tOK\tOK\tYES\tASAN trace generated" >> "$SUMMARY_FILE"
        else
             echo "[-] No ASAN trace found."
             if [ $ATTEMPT -eq $MAX_RETRIES ]; then
                 SEND_STR="OK"
                 if [ $SEND_RESULT -ne 0 ]; then SEND_STR="FAIL"; fi
                 echo -e "${SAMPLE_NAME}\t${ATTEMPT}\t${SEND_STR}\tOK\tNO\tNo ASAN output" >> "$SUMMARY_FILE"
             fi
        fi

        ((ATTEMPT++))
    done
    
    echo "Done with $SAMPLE_NAME"
    echo ""
done

echo "======================================================================"
echo "Verification complete. Summary file: $SUMMARY_FILE"
cat "$SUMMARY_FILE"
