import socket
import struct
import time
import sys

if len(sys.argv) < 2:
    print("usage: python aflnet_replay.py <poc.raw>")
    sys.exit(1)

with open(sys.argv[1], 'rb') as f:
    data = f.read()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('127.0.0.1', 1883))
s.settimeout(0.5)

offset = 0
msg_count = 0
while offset < len(data):
    if offset + 4 > len(data):
        break
    length = struct.unpack('<I', data[offset:offset+4])[0]
    offset += 4
    if offset + length > len(data):
        payload = data[offset:]
    else:
        payload = data[offset:offset+length]
    
    print(f"Sending msg {msg_count} of length {len(payload)}")
    try:
        s.sendall(payload)
        
        # Try to read responses before next send
        while True:
            try:
                resp = s.recv(4096)
                if not resp: break
            except socket.timeout:
                break
    except Exception as e:
        print(f"Exception: {e}")
        break

    offset += length
    msg_count += 1
    # time.sleep(0.01)

time.sleep(0.1)
s.close()
