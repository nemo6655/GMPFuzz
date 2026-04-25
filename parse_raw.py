import sys

def parse_mqtt(data):
    i = 0
    seq = []
    while i < len(data):
        if i >= len(data): break
        header = data[i]
        pkt_type = header >> 4
        flags = header & 0x0F
        i += 1
        
        # parse length (varint)
        multiplier = 1
        val = 0
        while i < len(data):
            b = data[i]
            val += (b & 127) * multiplier
            multiplier *= 128
            i += 1
            if (b & 128) == 0:
                break
        seq.append((pkt_type, flags, val, data[i:i+val]))
        i += val
    return seq

types = {1:'CONNECT', 2:'CONNACK', 3:'PUBLISH', 4:'PUBACK', 5:'PUBREC', 6:'PUBREL', 7:'PUBCOMP', 8:'SUBSCRIBE', 9:'SUBACK', 10:'UNSUBSCRIBE', 11:'UNSUBACK', 12:'PINGREQ', 13:'PINGRESP', 14:'DISCONNECT', 15:'AUTH'}

for f in sys.argv[1:]:
    with open(f, 'rb') as fp:
        data = fp.read()
    print(f"File {f} ({len(data)} bytes):")
    try:
        seq = parse_mqtt(data)
        for pkt_type, flags, length, payload in seq:
            print(f"  {types.get(pkt_type, pkt_type)} (Flags: {flags}, Len: {length}): {payload[:20].hex()}...")
    except Exception as e:
        print("  Parse error:", e)

