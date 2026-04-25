import sys
import glob
import os

def parse_mqtt(file_path):
    with open(file_path, "rb") as f:
        data = f.read()

    seq = []
    idx = 0
    while idx < len(data):
        header = data[idx]
        idx += 1

        packet_type = (header >> 4) & 0x0f
        
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
            9: "SUBSCRIBE", 10: "UNSUBSCRIBE"
        }
        if packet_type in types:
            seq.append(types[packet_type])
        else:
            seq.append(str(packet_type))
        idx += value
    return seq

count = 0
for root, dirs, files in os.walk("/tmp/aflout"):
    for f in files:
        if 'id:' in f and 'queue' in root:
            p = os.path.join(root, f)
            try:
                seq = parse_mqtt(p)
                if 'PUBREL' in seq or 'PUBREC' in seq or 'PUBCOMP' in seq:
                    count += 1
                    if count < 5:
                        print(p, "->", seq)
            except:
                pass
print("Total found:", count)
