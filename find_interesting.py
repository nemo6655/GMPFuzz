import sys
import glob
import os

def parse_mqtt(file_path):
    with open(file_path, "rb") as f:
        data = f.read()

    seq = []
    idx = 0
    while idx < len(data):
        if idx >= len(data):
            break
        header = data[idx]
        idx += 1

        packet_type = (header >> 4) & 0x0f
        flags = header & 0x0f

        multiplier = 1
        value = 0
        while idx < len(data):
            encoded_byte = data[idx]
            idx += 1
            value += (encoded_byte & 127) * multiplier
            if (encoded_byte & 128) == 0:
                break
            multiplier *= 128
        
        types = {
            1: "CONNECT", 2: "CONNACK", 3: "PUBLISH", 4: "PUBACK",
            5: "PUBREC", 6: "PUBREL", 7: "PUBCOMP", 8: "SUBSCRIBE",
            9: "SUBACK", 10: "UNSUBSCRIBE", 11: "UNSUBACK", 12: "PINGREQ",
            13: "PINGRESP", 14: "DISCONNECT", 15: "AUTH"
        }
        name = types.get(packet_type, str(packet_type))
        seq.append(name)
        idx += value
    return seq

best_seq = []
best_p = ""
for root, dirs, files in os.walk("/tmp/aflout"):
    for f in files:
        if 'id:' in f:
            p = os.path.join(root, f)
            try:
                seq = parse_mqtt(p)
                if 'PUBREL' in seq or 'PUBREC' in seq or 'PUBCOMP' in seq:
                    if len(seq) > len(best_seq):
                        best_seq = seq
                        best_p = p
            except Exception as e:
                pass

print(f"Found best sequence in {best_p}")
print(" -> ".join(best_seq))
