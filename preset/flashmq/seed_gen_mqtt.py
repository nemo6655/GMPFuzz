import os
import glob
import re
import argparse
import struct
import sys

# ========================================================================
# MQTT Packet Type Constants
# ========================================================================
MQTT_CONNECT     = 1
MQTT_CONNACK     = 2
MQTT_PUBLISH     = 3
MQTT_PUBACK      = 4
MQTT_PUBREC      = 5
MQTT_PUBREL      = 6
MQTT_PUBCOMP     = 7
MQTT_SUBSCRIBE   = 8
MQTT_SUBACK      = 9
MQTT_UNSUBSCRIBE = 10
MQTT_UNSUBACK    = 11
MQTT_PINGREQ     = 12
MQTT_PINGRESP    = 13
MQTT_DISCONNECT  = 14

PACKET_TYPE_NAMES = {
    MQTT_CONNECT:     "CONNECT",
    MQTT_CONNACK:     "CONNACK",
    MQTT_PUBLISH:     "PUBLISH",
    MQTT_PUBACK:      "PUBACK",
    MQTT_PUBREC:      "PUBREC",
    MQTT_PUBREL:      "PUBREL",
    MQTT_PUBCOMP:     "PUBCOMP",
    MQTT_SUBSCRIBE:   "SUBSCRIBE",
    MQTT_SUBACK:      "SUBACK",
    MQTT_UNSUBSCRIBE: "UNSUBSCRIBE",
    MQTT_UNSUBACK:    "UNSUBACK",
    MQTT_PINGREQ:     "PINGREQ",
    MQTT_PINGRESP:    "PINGRESP",
    MQTT_DISCONNECT:  "DISCONNECT",
}

# ========================================================================
# Known MQTT Packet Templates (binary)
# These are well-formed MQTT v3.1.1 packets used for synthetic seed generation
# ========================================================================
KNOWN_MQTT_PACKETS = {
    # CONNECT: protocol=MQTT, version=4, clean session, keepalive=60, client_id="gmpfuzz-client"
    "CONNECT": (
        b'\x10\x20'                   # Fixed header: CONNECT, remaining=32
        b'\x00\x04MQTT'               # Protocol Name
        b'\x04'                        # Protocol Level (4 = v3.1.1)
        b'\x02'                        # Connect Flags (Clean Session)
        b'\x00\x3c'                    # Keep Alive = 60
        b'\x00\x0egmpfuzz-client'     # Client Identifier
    ),

    # CONNECT with will message
    "CONNECT_WILL": (
        b'\x10\x3a'
        b'\x00\x04MQTT'
        b'\x04'
        b'\x26'                        # Connect Flags: Clean Session + Will Flag + Will QoS 1
        b'\x00\x3c'
        b'\x00\x0egmpfuzz-client'
        b'\x00\x0awill/topic'         # Will Topic
        b'\x00\x0cwill message'       # Will Message
    ),

    # CONNECT with username/password
    "CONNECT_AUTH": (
        b'\x10\x2c'
        b'\x00\x04MQTT'
        b'\x04'
        b'\xc2'                        # Connect Flags: Clean Session + Username + Password
        b'\x00\x3c'
        b'\x00\x0egmpfuzz-client'
        b'\x00\x04user'               # Username
        b'\x00\x04pass'               # Password
    ),

    # PUBLISH QoS 0: topic="test/topic", payload="hello mqtt"
    "PUBLISH_QOS0": (
        b'\x30\x16'                    # Fixed header: PUBLISH QoS 0
        b'\x00\x0atest/topic'         # Topic Name
        b'hello mqtt'                  # Payload
    ),

    # PUBLISH QoS 1: topic="test/topic", packet_id=1, payload="hello qos1"
    "PUBLISH_QOS1": (
        b'\x32\x19'                    # Fixed header: PUBLISH QoS 1
        b'\x00\x0atest/topic'         # Topic Name
        b'\x00\x01'                    # Packet Identifier = 1
        b'hello qos1'                  # Payload
    ),

    # PUBLISH QoS 2: topic="test/topic", packet_id=2, payload="hello qos2"
    "PUBLISH_QOS2": (
        b'\x34\x19'                    # Fixed header: PUBLISH QoS 2
        b'\x00\x0atest/topic'         # Topic Name
        b'\x00\x02'                    # Packet Identifier = 2
        b'hello qos2'                  # Payload
    ),

    # PUBLISH with retain flag
    "PUBLISH_RETAIN": (
        b'\x31\x16'                    # Fixed header: PUBLISH QoS 0, Retain=1
        b'\x00\x0atest/topic'
        b'hello mqtt'
    ),

    # SUBSCRIBE: packet_id=1, topic="test/topic", QoS 1
    "SUBSCRIBE": (
        b'\x82\x0f'                    # Fixed header: SUBSCRIBE
        b'\x00\x01'                    # Packet Identifier = 1
        b'\x00\x0atest/topic'         # Topic Filter
        b'\x01'                        # QoS 1
    ),

    # SUBSCRIBE wildcard: topic="#", QoS 0
    "SUBSCRIBE_WILDCARD": (
        b'\x82\x06'
        b'\x00\x02'
        b'\x00\x01#'
        b'\x00'
    ),

    # SUBSCRIBE multi-level wildcard: topic="test/+/data", QoS 2
    "SUBSCRIBE_MULTI": (
        b'\x82\x10'
        b'\x00\x03'
        b'\x00\x0btest/+/data'
        b'\x02'
    ),

    # UNSUBSCRIBE: packet_id=1, topic="test/topic"
    "UNSUBSCRIBE": (
        b'\xa2\x0e'                    # Fixed header: UNSUBSCRIBE
        b'\x00\x01'                    # Packet Identifier = 1
        b'\x00\x0atest/topic'         # Topic Filter
    ),

    # PINGREQ
    "PINGREQ": b'\xc0\x00',

    # DISCONNECT
    "DISCONNECT": b'\xe0\x00',

    # PUBACK: packet_id=1
    "PUBACK": b'\x40\x02\x00\x01',

    # PUBREC: packet_id=1
    "PUBREC": b'\x50\x02\x00\x01',

    # PUBREL: packet_id=1
    "PUBREL": b'\x62\x02\x00\x01',

    # PUBCOMP: packet_id=1
    "PUBCOMP": b'\x70\x02\x00\x01',
}

# Logical MQTT packet type order for protocol flows
MQTT_TYPE_ORDER = [
    "CONNECT", "CONNECT_WILL", "CONNECT_AUTH",
    "SUBSCRIBE", "SUBSCRIBE_WILDCARD", "SUBSCRIBE_MULTI",
    "PUBLISH_QOS0", "PUBLISH_QOS1", "PUBLISH_QOS2", "PUBLISH_RETAIN",
    "PUBACK", "PUBREC", "PUBREL", "PUBCOMP",
    "UNSUBSCRIBE",
    "PINGREQ",
    "DISCONNECT",
]


def decode_remaining_length(data, offset):
    """Decode MQTT variable-length encoding for remaining length field."""
    multiplier = 1
    value = 0
    idx = offset
    while idx < len(data):
        encoded_byte = data[idx]
        value += (encoded_byte & 0x7F) * multiplier
        idx += 1
        if (encoded_byte & 0x80) == 0:
            break
        multiplier *= 128
        if multiplier > 128 * 128 * 128:
            break
    return value, idx


def parse_mqtt_packets(raw_data):
    """Parse raw binary data into individual MQTT packets.
    
    Returns a list of (packet_type_name, packet_bytes) tuples.
    """
    packets = []
    offset = 0
    
    while offset < len(raw_data):
        if offset >= len(raw_data):
            break
            
        # Read fixed header byte
        first_byte = raw_data[offset]
        packet_type = (first_byte >> 4) & 0x0F
        
        if packet_type < 1 or packet_type > 14:
            # Invalid packet type, skip one byte
            offset += 1
            continue
        
        # Decode remaining length
        remaining_length, length_end = decode_remaining_length(raw_data, offset + 1)
        
        # Total packet length = fixed header (1 byte) + length bytes + remaining length
        total_length = length_end - offset + remaining_length
        
        if offset + total_length > len(raw_data):
            # Incomplete packet; take remaining data
            packet_bytes = raw_data[offset:]
            type_name = PACKET_TYPE_NAMES.get(packet_type, f"UNKNOWN_{packet_type}")
            packets.append((type_name, packet_bytes))
            break
        
        packet_bytes = raw_data[offset:offset + total_length]
        type_name = PACKET_TYPE_NAMES.get(packet_type, f"UNKNOWN_{packet_type}")
        packets.append((type_name, packet_bytes))
        
        offset += total_length
    
    return packets


def generate_files(seeds_dir, output_dir):
    """Convert raw MQTT seed files into Python generator scripts.
    
    Each .raw file is parsed into MQTT packets and converted to a Python file
    containing functions that return each packet's bytes, plus a __mqtt_gen__
    dispatcher function.
    """
    try:
        if not os.path.exists(seeds_dir):
            os.makedirs(seeds_dir)
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)
    except OSError as e:
        print(f"Error creating directories: {e}", file=sys.stderr)
        sys.exit(1)

    # Collect all files under seeds_dir
    all_entries = sorted(glob.glob(os.path.join(seeds_dir, "*")))
    raw_files = [os.path.basename(p) for p in all_entries if os.path.isfile(p)]

    all_funcs_code_for_all_py = []
    seen_types = set()

    # Common __mqtt_gen__ function code
    mqtt_gen_code = '''def __mqtt_gen__(rng, f):
    import inspect
    def encode_remaining_length(length):
        encoded = bytearray()
        while True:
            encoded_byte = length % 128
            length = length // 128
            if length > 0:
                encoded_byte |= 0x80
            encoded.append(encoded_byte)
            if length == 0:
                break
        return bytes(encoded)

    def decode_remaining_length(data, offset):
        multiplier = 1
        value = 0
        idx = offset
        while idx < len(data):
            if idx >= len(data):
                break
            encoded_byte = data[idx]
            value += (encoded_byte & 0x7F) * multiplier
            idx += 1
            if (encoded_byte & 0x80) == 0:
                break
            multiplier *= 128
            if multiplier > 128 * 128 * 128:
                break
        return value, idx

    def fix_packet(packet):
        if not isinstance(packet, bytes) or len(packet) < 2:
            return packet
        packet_type = (packet[0] >> 4) & 0x0F
        if packet_type < 1 or packet_type > 14:
            return packet
        try:
            old_len, length_end = decode_remaining_length(packet, 1)
            actual_payload = packet[length_end:]
            actual_len = len(actual_payload)
            return bytes([packet[0]]) + encode_remaining_length(actual_len) + actual_payload
        except Exception:
            return packet

    try:
        g = globals()
        funcs = []
        this_lineno = __mqtt_gen__.__code__.co_firstlineno if hasattr(__mqtt_gen__, '__code__') else 999999
        for name, obj in g.items():
            if callable(obj) and getattr(obj, '__module__', '') == __name__:
                if name not in ('__mqtt_gen__', 'main') and not name.startswith('__mqtt_'):
                    if hasattr(obj, '__code__') and obj.__code__.co_firstlineno < this_lineno:
                        funcs.append(obj)
        funcs.sort(key=lambda f: f.__code__.co_firstlineno if hasattr(f, '__code__') else 0)
        for func in funcs:
            try:
                sig = inspect.signature(func)
                res = func(rng) if len(sig.parameters) > 0 else func()
                
                if isinstance(res, bytes):
                    f.write(fix_packet(res))
                elif isinstance(res, str):
                    f.write(fix_packet(res.encode('utf-8')))
            except Exception:
                pass
    except Exception:
        pass
'''

    for file_idx, raw_name in enumerate(raw_files):
        filename = raw_name
        file_stem = os.path.splitext(filename)[0]
        raw_file = os.path.join(seeds_dir, filename)

        with open(raw_file, "rb") as f:
            content = f.read()

        # Parse MQTT packets from raw binary
        packets = parse_mqtt_packets(content)
        
        if not packets:
            print(f"Warning: No MQTT packets found in {filename}", file=sys.stderr)
            continue

        file_funcs_code = []

        for pkt_idx, (pkt_type, pkt_bytes) in enumerate(packets):
            seen_types.add(pkt_type)
            
            # Function name
            func_name = f"{file_stem}_{pkt_idx:03d}_{pkt_type}"
            # Sanitize function name
            func_name = re.sub(r'[^a-zA-Z0-9_]', '_', func_name)

            # Create one-line function returning the raw bytes
            func_code = f"def {func_name}(): return {repr(pkt_bytes)}"

            file_funcs_code.append(func_code)
            all_funcs_code_for_all_py.append(func_code)

        # Generate individual seed python file
        py_filename = f"mqtt_seeds_{file_stem}.py"
        py_filepath = os.path.join(output_dir, py_filename)

        file_content = "import os\n\n"
        file_content += "\n".join(file_funcs_code)
        file_content += "\n\n"
        file_content += mqtt_gen_code
        file_content += "\n"
        file_content += "def main():\n"
        file_content += f'    with open("{filename}", "wb") as f:\n'
        file_content += '        with open("/dev/urandom", "rb") as rng:\n'
        file_content += '            __mqtt_gen__(rng, f)\n'
        file_content += "\nif __name__ == '__main__':\n    main()\n"

        with open(py_filepath, "w") as f:
            f.write(file_content)

    # Generate synthetic seeds for missing MQTT packet types
    missing_types = set(KNOWN_MQTT_PACKETS.keys()) - seen_types
    if missing_types:
        print(f"Adding synthetic seeds for missing types: {missing_types}")
        synthetic_funcs_code = []

        sorted_missing = sorted(list(missing_types),
                                key=lambda m: MQTT_TYPE_ORDER.index(m) if m in MQTT_TYPE_ORDER else 999)

        for pkt_type in sorted_missing:
            payload = KNOWN_MQTT_PACKETS[pkt_type]
            func_name = f"synthetic_000_{pkt_type}"
            func_code = f"def {func_name}(): return {repr(payload)}"
            synthetic_funcs_code.append(func_code)
            all_funcs_code_for_all_py.append(func_code)

        # Generate synthetic python file
        py_filename = "mqtt_synthetic.py"
        py_filepath = os.path.join(output_dir, py_filename)
        file_content = "import os\n\n"
        file_content += "\n".join(synthetic_funcs_code)
        file_content += "\n\n"
        file_content += mqtt_gen_code
        file_content += "\n"
        file_content += "def main():\n"
        file_content += '    with open("synthetic.raw", "wb") as f:\n'
        file_content += '        with open("/dev/urandom", "rb") as rng:\n'
        file_content += '            __mqtt_gen__(rng, f)\n'
        file_content += "\nif __name__ == '__main__':\n    main()\n"

        with open(py_filepath, "w") as f:
            f.write(file_content)

    # Generate valid business flow seeds
    MQTT_FLOWS = {
        # Basic connect-subscribe-publish-disconnect
        "basic_pubsub": ["CONNECT", "SUBSCRIBE", "PUBLISH_QOS0", "DISCONNECT"],
        
        # QoS 1 publish flow
        "qos1_pubsub": ["CONNECT", "SUBSCRIBE", "PUBLISH_QOS1", "PUBACK", "DISCONNECT"],
        
        # QoS 2 publish flow (full handshake)
        "qos2_pubsub": ["CONNECT", "SUBSCRIBE", "PUBLISH_QOS2", "PUBREC", "PUBREL", "PUBCOMP", "DISCONNECT"],
        
        # Subscribe with wildcard topics
        "wildcard_sub": ["CONNECT", "SUBSCRIBE_WILDCARD", "PUBLISH_QOS0", "DISCONNECT"],
        
        # Multi-level wildcard subscribe
        "multilevel_sub": ["CONNECT", "SUBSCRIBE_MULTI", "PUBLISH_QOS0", "DISCONNECT"],
        
        # Connect with will message
        "will_message": ["CONNECT_WILL", "SUBSCRIBE", "DISCONNECT"],
        
        # Connect with authentication
        "auth_connect": ["CONNECT_AUTH", "SUBSCRIBE", "PUBLISH_QOS0", "DISCONNECT"],
        
        # Publish with retain flag
        "retain_publish": ["CONNECT", "PUBLISH_RETAIN", "SUBSCRIBE", "DISCONNECT"],
        
        # Unsubscribe flow
        "sub_unsub": ["CONNECT", "SUBSCRIBE", "UNSUBSCRIBE", "DISCONNECT"],
        
        # Keepalive with PINGREQ
        "keepalive": ["CONNECT", "PINGREQ", "PINGREQ", "DISCONNECT"],
        
        # Multiple publish messages
        "multi_publish": ["CONNECT", "SUBSCRIBE", "PUBLISH_QOS0", "PUBLISH_QOS1", "PUBACK", "PUBLISH_QOS0", "DISCONNECT"],
        
        # Subscribe then publish multiple QoS levels
        "mixed_qos": ["CONNECT", "SUBSCRIBE", "PUBLISH_QOS0", "PUBLISH_QOS1", "PUBACK", "PUBLISH_QOS2", "PUBREC", "PUBREL", "PUBCOMP", "DISCONNECT"],
        
        # Invalid: Publish before Connect
        "invalid_publish_noconnect": ["PUBLISH_QOS0"],
        
        # Invalid: Subscribe before Connect
        "invalid_subscribe_noconnect": ["SUBSCRIBE"],
        
        # Double connect (protocol violation)
        "double_connect": ["CONNECT", "CONNECT", "DISCONNECT"],
        
        # Disconnect and reconnect
        "reconnect": ["CONNECT", "SUBSCRIBE", "DISCONNECT", "CONNECT", "PUBLISH_QOS0", "DISCONNECT"],
        
        # Long-lived session with pings
        "long_session": ["CONNECT", "SUBSCRIBE", "PUBLISH_QOS0", "PINGREQ", "PUBLISH_QOS1", "PUBACK", "PINGREQ", "UNSUBSCRIBE", "DISCONNECT"],
    }

    for flow_name, packet_types in MQTT_FLOWS.items():
        flow_funcs_code = []
        for i, pkt_type in enumerate(packet_types):
            if pkt_type in KNOWN_MQTT_PACKETS:
                payload = KNOWN_MQTT_PACKETS[pkt_type]
                func_name = f"flow_{i:03d}_{pkt_type}"
                func_code = f"def {func_name}(): return {repr(payload)}"
                flow_funcs_code.append(func_code)

        if not flow_funcs_code:
            continue

        py_filename = f"mqtt_flow_{flow_name}.py"
        py_filepath = os.path.join(output_dir, py_filename)

        file_content = "import os\n\n"
        file_content += "\n".join(flow_funcs_code)
        file_content += "\n\n"
        file_content += mqtt_gen_code
        file_content += "\n"
        file_content += "def main():\n"
        file_content += f'    with open("{flow_name}.raw", "wb") as f:\n'
        file_content += '        with open("/dev/urandom", "rb") as rng:\n'
        file_content += '            __mqtt_gen__(rng, f)\n'
        file_content += "\nif __name__ == '__main__':\n    main()\n"

        with open(py_filepath, "w") as f:
            f.write(file_content)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert MQTT raw seeds to Python generator files")
    parser.add_argument('--input_seeds', default='seeds', help='Input seeds directory (contains .raw files)')
    parser.add_argument('--init_variants', default='initial/variants', help='Output Python file directory')
    args = parser.parse_args()
    generate_files(args.input_seeds, args.init_variants)
