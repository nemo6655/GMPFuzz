import click
import json
import os
import shutil
import subprocess
import sys
import math
import struct
from collections import defaultdict

# ============================================================================
# MQTT Protocol State Model
# ============================================================================
# MQTT has a well-defined state machine. We classify seeds based on which
# "functional zone" of the MQTT protocol they exercise:
#
#   Zone 0 (SESSION):     CONNECT/CONNACK handshake, auth, will messages
#   Zone 1 (PUB_SIMPLE):  QoS 0 publish, basic subscribe/unsubscribe
#   Zone 2 (PUB_ACKED):   QoS 1 publish with PUBACK, retain handling
#   Zone 3 (PUB_ASSURED): QoS 2 four-phase handshake (PUBREC/PUBREL/PUBCOMP)
#   Zone 4 (LIFECYCLE):   PINGREQ/PINGRESP keepalive, DISCONNECT, reconnect
#   Zone 5 (EDGE_CASE):   Protocol violations, malformed packets, boundary
#
# Pool assignment strategy (MQTT-aware):
#   0000 = All elites (full set, same as before)
#   0001 = SESSION-heavy seeds      → focus fuzzing on connection/auth paths
#   0002 = PUB_SIMPLE + PUB_ACKED  → focus on basic pub/sub + QoS 1
#   0003 = PUB_ASSURED + LIFECYCLE → focus on QoS 2 handshake + session mgmt
#
# Seeds with "rare" transitions or edge cases are distributed with boosted
# priority across all pools to ensure maximum state exploration.
# ============================================================================

# MQTT packet type constants (from fixed header byte >> 4)
MQTT_PKT_CONNECT     = 1
MQTT_PKT_CONNACK     = 2
MQTT_PKT_PUBLISH     = 3
MQTT_PKT_PUBACK      = 4
MQTT_PKT_PUBREC      = 5
MQTT_PKT_PUBREL      = 6
MQTT_PKT_PUBCOMP     = 7
MQTT_PKT_SUBSCRIBE   = 8
MQTT_PKT_SUBACK      = 9
MQTT_PKT_UNSUBSCRIBE = 10
MQTT_PKT_UNSUBACK    = 11
MQTT_PKT_PINGREQ     = 12
MQTT_PKT_PINGRESP    = 13
MQTT_PKT_DISCONNECT  = 14

MQTT_PKT_NAMES = {
    1: "CONNECT", 2: "CONNACK", 3: "PUBLISH", 4: "PUBACK",
    5: "PUBREC", 6: "PUBREL", 7: "PUBCOMP", 8: "SUBSCRIBE",
    9: "SUBACK", 10: "UNSUBSCRIBE", 11: "UNSUBACK",
    12: "PINGREQ", 13: "PINGRESP", 14: "DISCONNECT",
}

# Mapping: MQTT packet type -> functional zone name
MQTT_ZONE_MAP = {
    MQTT_PKT_CONNECT:     "SESSION",
    MQTT_PKT_CONNACK:     "SESSION",
    MQTT_PKT_PUBLISH:     None,         # Determined by QoS level
    MQTT_PKT_PUBACK:      "PUB_ACKED",
    MQTT_PKT_PUBREC:      "PUB_ASSURED",
    MQTT_PKT_PUBREL:      "PUB_ASSURED",
    MQTT_PKT_PUBCOMP:     "PUB_ASSURED",
    MQTT_PKT_SUBSCRIBE:   "PUB_SIMPLE",
    MQTT_PKT_SUBACK:      "PUB_SIMPLE",
    MQTT_PKT_UNSUBSCRIBE: "PUB_SIMPLE",
    MQTT_PKT_UNSUBACK:    "PUB_SIMPLE",
    MQTT_PKT_PINGREQ:     "LIFECYCLE",
    MQTT_PKT_PINGRESP:    "LIFECYCLE",
    MQTT_PKT_DISCONNECT:  "LIFECYCLE",
}

# Zone to pool mapping (configurable, these are defaults for 4-pool setup)
DEFAULT_ZONE_POOL_MAP = {
    "SESSION":      "0001",   # Pool 1: Connection & auth exploration
    "PUB_SIMPLE":   "0002",   # Pool 2: Basic pub/sub, QoS 0
    "PUB_ACKED":    "0002",   # Pool 2: QoS 1 publish
    "PUB_ASSURED":  "0003",   # Pool 3: QoS 2 four-phase handshake
    "LIFECYCLE":    "0003",   # Pool 3: Keepalive + disconnect
    "EDGE_CASE":    None,     # Distributed across all pools
}


def parse_mqtt_seed_zones(seed_path):
    """Parse a binary MQTT seed file and determine which functional zones it exercises.
    
    Returns:
        dict: {zone_name: weight} where weight reflects how heavily
              the seed exercises that zone (based on packet count).
        list: List of (packet_type_id, qos_level_or_None) for each packet found.
    """
    zone_weights = defaultdict(float)
    packet_info = []
    
    try:
        with open(seed_path, 'rb') as f:
            data = f.read()
    except (IOError, OSError):
        return zone_weights, packet_info
    
    offset = 0
    while offset < len(data):
        if offset >= len(data):
            break
        
        first_byte = data[offset]
        pkt_type = (first_byte >> 4) & 0x0F
        
        if pkt_type < 1 or pkt_type > 14:
            # Malformed → edge case
            zone_weights["EDGE_CASE"] += 1.0
            packet_info.append((0, None))
            offset += 1
            continue
        
        # Decode remaining length (variable-length encoding)
        multiplier = 1
        remaining_len = 0
        idx = offset + 1
        while idx < len(data):
            encoded_byte = data[idx]
            remaining_len += (encoded_byte & 0x7F) * multiplier
            idx += 1
            if (encoded_byte & 0x80) == 0:
                break
            multiplier *= 128
            if multiplier > 128 ** 3:
                break
        
        total_len = idx - offset + remaining_len
        
        # Determine QoS for PUBLISH packets
        qos = None
        if pkt_type == MQTT_PKT_PUBLISH:
            qos = (first_byte >> 1) & 0x03
            if qos == 0:
                zone = "PUB_SIMPLE"
            elif qos == 1:
                zone = "PUB_ACKED"
            else:  # qos == 2
                zone = "PUB_ASSURED"
        else:
            zone = MQTT_ZONE_MAP.get(pkt_type, "EDGE_CASE")
        
        zone_weights[zone] += 1.0
        packet_info.append((pkt_type, qos))
        
        if offset + total_len <= offset:
            offset += 1  # Prevent infinite loop
        else:
            offset += max(total_len, 1)
    
    # Bonus: seeds that start without CONNECT are protocol violations → edge case
    if packet_info and packet_info[0][0] != MQTT_PKT_CONNECT:
        zone_weights["EDGE_CASE"] += 2.0
    
    # Bonus: seeds with QoS 2 full handshake (PUBREC+PUBREL+PUBCOMP sequence)
    pkt_types_seen = set(p[0] for p in packet_info)
    if {MQTT_PKT_PUBREC, MQTT_PKT_PUBREL, MQTT_PKT_PUBCOMP}.issubset(pkt_types_seen):
        zone_weights["PUB_ASSURED"] += 3.0  # Boost for complete QoS2 handshake
    
    # Normalize weights
    total = sum(zone_weights.values())
    if total > 0:
        for z in zone_weights:
            zone_weights[z] /= total
    
    return dict(zone_weights), packet_info


def classify_seed_primary_zone(zone_weights):
    """Determine the primary functional zone for a seed based on its zone weights.
    
    Returns the zone name with the highest weight, or "EDGE_CASE" if empty.
    """
    if not zone_weights:
        return "EDGE_CASE"
    return max(zone_weights.items(), key=lambda x: x[1])[0]


def compute_mqtt_transition_signature(state_data):
    """Extract a transition signature from coverage state data.
    
    The state data is {state_sequence: [edges]} from coverage JSON.
    We extract all state transitions and compute a signature tuple.
    
    Returns:
        set: Set of transition strings like "__TRANS_1_2__"
        str: Longest state sequence found (indicates protocol depth)
        int: Max state ID seen (indicates how far into the protocol we got)
    """
    transitions = set()
    max_depth = 0
    max_state_id = 0
    
    if not isinstance(state_data, dict):
        return transitions, 0, 0
    
    for state_seq_str, edges in state_data.items():
        parts = str(state_seq_str).split('-')
        max_depth = max(max_depth, len(parts))
        
        for i, p in enumerate(parts):
            try:
                sid = int(p)
                max_state_id = max(max_state_id, sid)
            except ValueError:
                pass
        
        if len(parts) > 1:
            for i in range(len(parts) - 1):
                transitions.add(f"__TRANS_{parts[i]}_{parts[i+1]}__")
    
    return transitions, max_depth, max_state_id


def get_state_pools():
    try:
        # Call elmconfig.py to get the state pools
        script_dir = os.path.dirname(os.path.abspath(__file__))
        elmconfig_path = os.path.join(script_dir, 'elmconfig.py')
        
        result = subprocess.run(
            [sys.executable, elmconfig_path, 'get', 'run.state_pools'],
            capture_output=True, text=True, check=True
        )
        # Output should be space-separated list
        pools = result.stdout.strip().split()
        return pools
    except Exception as e:
        print(f"Error getting state pools: {e}", file=sys.stderr)
        return []

def get_seed_map(base_dir):
    """
    Returns a dictionary mapping seed prefixes (e.g., id:000001) to full paths.
    Scans both base_dir and base_dir/queue.
    """
    seed_map = {}
    
    dirs_to_check = [base_dir]
    queue_dir = os.path.join(base_dir, 'queue')
    if os.path.exists(queue_dir):
        dirs_to_check.append(queue_dir)
        
    for d in dirs_to_check:
        if os.path.exists(d):
            try:
                for f in os.listdir(d):
                    full_path = os.path.join(d, f)
                    if os.path.isfile(full_path):
                        # prefix is usually id:xxxxxx
                        prefix = f.split(',')[0]
                        # If duplicate prefixes exist, last one wins (should be fine for this purpose)
                        seed_map[prefix] = full_path
            except OSError:
                pass
    return seed_map



def resolve_gen_dir(elmfuzz_rundir, gen_name):
    """
    Resolves the directory name for a generation (e.g., '1' -> 'gen1' or '1').
    """
    if os.path.exists(os.path.join(elmfuzz_rundir, gen_name)):
        return gen_name
    
    if not gen_name.startswith('gen'):
        candidate = 'gen' + gen_name
        if os.path.exists(os.path.join(elmfuzz_rundir, candidate)):
            return candidate
            
    return gen_name # Default fallback

def select_states_noss(cov_file, elites_file, gen, elmfuzz_rundir):
    print(f"Loading coverage file: {cov_file}")
    with open(cov_file, 'r') as f:
        cov_data = json.load(f)
    
    print(f"Loading elites file: {elites_file}")
    with open(elites_file, 'r') as f:
        elites_data = json.load(f)

    # Cache for seed maps: (gen_dir_name, pool) -> seed_map
    seed_map_cache = {} 
    global_seed_map = {}
    global_scan_done = False

    def get_cached_seed_path(gen_dir, pool, seed_prefix):
        nonlocal global_scan_done
        key = (gen_dir, pool)
        if key not in seed_map_cache:
             base_dir = os.path.join(elmfuzz_rundir, gen_dir, 'aflnetout', pool)
             seed_map_cache[key] = get_seed_map(base_dir)
        
        path = seed_map_cache[key].get(seed_prefix)
        if path:
            return path
            
        # Fallback: Scan everything if not done yet
        if not global_scan_done:
            print("Scanning all aflnetout directories for missing seeds...", file=sys.stderr)
            all_dirs = get_all_aflnet_dirs(elmfuzz_rundir)
            for d in all_dirs:
                try:
                    for f in os.listdir(d):
                        if f.startswith("id:"):
                            prefix = f.split(',')[0]
                            if prefix not in global_seed_map:
                                global_seed_map[prefix] = os.path.join(d, f)
                except OSError:
                    pass
            global_scan_done = True
            
        return global_seed_map.get(seed_prefix)

    # 1. Copy Elite Seeds to 0000
    dest_0000 = os.path.join(elmfuzz_rundir, gen, 'seeds', '0000')
    os.makedirs(dest_0000, exist_ok=True)
    
    elite_seeds_copied = []

    # elites_data structure: prev_gen -> state_pool -> filename -> edges
    for prev_gen, states in elites_data.items():
        gen_dir_name = resolve_gen_dir(elmfuzz_rundir, prev_gen)

        for state_pool, files in states.items():
            for filename_key in files.keys():
                # filename_key format: seed_name:state:transition_info
                if ':state:' in filename_key:
                    seed_name_full = filename_key.split(':state:')[0]
                else:
                    seed_name_full = filename_key
                
                seed_id_prefix = seed_name_full.split(',')[0]
                
                src_path = get_cached_seed_path(gen_dir_name, state_pool, seed_id_prefix)
                
                if src_path:
                    shutil.copy(src_path, dest_0000)
                    elite_seeds_copied.append(seed_name_full)
                else:
                    print(f"Warning: Elite seed not found: {seed_name_full} (prefix {seed_id_prefix}) in {state_pool}", file=sys.stderr)

    print(f"Copied {len(elite_seeds_copied)} elite seeds to {dest_0000}")

    # 2. Identify Missing Transitions and Copy to respective pools
    dest_0001 = os.path.join(elmfuzz_rundir, gen, 'seeds', '0001')
    os.makedirs(dest_0001, exist_ok=True)

    # Calculate generation string for JSON lookup (e.g., gen2 -> 1)
    try:
        gen_num = int(gen.replace('gen', '')) - 1
        gen_str = str(gen_num)
    except ValueError:
        print(f"Error: Could not parse generation number from {gen}", file=sys.stderr)
        sys.exit(1)

    # Collect covered transitions from elites
    covered_transitions = set()
    if gen_str in elites_data:
        for state, seeds in elites_data[gen_str].items():
            for seed_name, val in seeds.items():
                edges = []
                if isinstance(val, list) and len(val) == 2:
                    edges = val[0]
                elif isinstance(val, dict) and 'edges' in val:
                    edges = val['edges']
                
                for e in edges:
                    if isinstance(e, str) and e.startswith('__TRANS_'):
                        covered_transitions.add(e)

    # Extract all transitions from coverage and map them to seeds
    all_transitions = set()
    transition_to_seeds = {} # Map transition -> list of seed paths

    if gen_str in cov_data:
        gen_dir_name = resolve_gen_dir(elmfuzz_rundir, gen_str)
        
        for job, seeds in cov_data[gen_str].items():
            for seed_name, state_data in seeds.items():
                if isinstance(state_data, dict):
                    # Resolve seed path once per seed
                    seed_id_prefix = seed_name.split(',')[0]
                    src_path = get_cached_seed_path(gen_dir_name, job, seed_id_prefix)
                    
                    if src_path:
                        for state, edges in state_data.items():
                            parts = state.split('-')
                            if len(parts) > 1:
                                for i in range(len(parts) - 1):
                                    src = parts[i]
                                    dst = parts[i+1]
                                    trans = f"__TRANS_{src}_{dst}__"
                                    all_transitions.add(trans)
                                    
                                    if trans not in transition_to_seeds:
                                        transition_to_seeds[trans] = []
                                    # Avoid duplicates if possible, or just append
                                    transition_to_seeds[trans].append(src_path)

    missing_transitions = all_transitions - covered_transitions
    print(f"Found {len(missing_transitions)} missing transitions.")

    missing_seeds_copied = 0
    seeds_to_copy_for_missing = set() # Set of src_path
    
    for t in missing_transitions:
        candidates = transition_to_seeds.get(t)
        if candidates:
            # Add all candidates covering this missing transition
            seeds_to_copy_for_missing.update(candidates)
    
    for src_path in seeds_to_copy_for_missing:
        # Copy to gen/seeds/0001
        shutil.copy(src_path, dest_0001)
        missing_seeds_copied += 1
        
    print(f"Copied {missing_seeds_copied} seeds covering missing transitions to {dest_0001}")

    # 3. Distribute to other pools
    state_pools = get_state_pools()
    # Filter out 0000 and 0001
    if missing_seeds_copied > 0:
        target_pools = [p for p in state_pools if p not in ['0000', '0001']]
    else:
        target_pools = [p for p in state_pools if p not in ['0000']]
    
    distribution_results = {}

    if target_pools:
        # Get list of seeds in 0000 (the elites)
        seeds_in_0000 = [os.path.join(dest_0000, f) for f in os.listdir(dest_0000) if os.path.isfile(os.path.join(dest_0000, f))]
        num_seeds = len(seeds_in_0000)
        num_targets = len(target_pools)
        
        if num_seeds > 0:
            print(f"Distributing {num_seeds} seeds from 0000 to {num_targets} pools: {target_pools}")
            
            # Average distribution (splitting the set)
            chunk_size = math.ceil(num_seeds / num_targets)
            
            for i, pool in enumerate(target_pools):
                dest_pool = os.path.join(elmfuzz_rundir, gen, 'seeds', pool)
                os.makedirs(dest_pool, exist_ok=True)
                
                start_idx = i * chunk_size
                end_idx = min((i + 1) * chunk_size, num_seeds)
                
                chunk = seeds_in_0000[start_idx:end_idx]
                distribution_results[pool] = [os.path.basename(s) for s in chunk]
                
                if not chunk:
                    print(f"  Pool {pool}: No seeds assigned (ran out of seeds).")
                    continue

                for seed_path in chunk:
                    shutil.copy(seed_path, dest_pool)
                    
                print(f"  Pool {pool}: Copied {len(chunk)} seeds.")
        else:
            print("No seeds in 0000 to distribute.")
    else:
        print("No other state pools to distribute to.")

    # 4. Write selection results to log file
    log_dir = os.path.join(elmfuzz_rundir, gen, 'logs')
    os.makedirs(log_dir, exist_ok=True)
    state_log_path = os.path.join(log_dir, 'state.log')
    
    with open(state_log_path, 'a') as f:
        f.write(f"\n=== Generation {gen} (NOSS) ===\n")
        f.write("Pool 0000 (Elites):\n")
        for seed in sorted(elite_seeds_copied):
            f.write(f"{seed}\n")
            
        f.write("\nPool 0001 (Missing Transitions):\n")
        for seed_path in sorted(seeds_to_copy_for_missing):
            f.write(f"{os.path.basename(seed_path)}\n")
            
        f.write("\nDistribution:\n")
        if distribution_results:
            for pool, seeds in sorted(distribution_results.items()):
                f.write(f"Pool {pool}:\n")
                for s in sorted(seeds):
                    f.write(f"{s}\n")
        else:
            f.write("No distribution performed.\n")

def select_states_ss(cov_file, elites_file, gen, elmfuzz_rundir):
    print(f"Loading coverage file: {cov_file}")
    with open(cov_file, 'r') as f:
        cov_data = json.load(f)
    
    print(f"Loading elites file: {elites_file}")
    with open(elites_file, 'r') as f:
        elites_data = json.load(f)

    # Cache for seed maps: (gen_dir_name, pool) -> seed_map
    seed_map_cache = {} 
    global_seed_map = {}
    global_scan_done = False

    def get_cached_seed_path(gen_dir, pool, seed_prefix):
        nonlocal global_scan_done
        key = (gen_dir, pool)
        if key not in seed_map_cache:
             base_dir = os.path.join(elmfuzz_rundir, gen_dir, 'aflnetout', pool)
             seed_map_cache[key] = get_seed_map(base_dir)
        
        path = seed_map_cache[key].get(seed_prefix)
        if path:
            return path
            
        # Fallback: Scan everything if not done yet
        if not global_scan_done:
            print("Scanning all aflnetout directories for missing seeds...", file=sys.stderr)
            all_dirs = get_all_aflnet_dirs(elmfuzz_rundir)
            for d in all_dirs:
                try:
                    for f in os.listdir(d):
                        if f.startswith("id:"):
                            prefix = f.split(',')[0]
                            if prefix not in global_seed_map:
                                global_seed_map[prefix] = os.path.join(d, f)
                except OSError:
                    pass
            global_scan_done = True
            
        return global_seed_map.get(seed_prefix)

    # 1. Identify and Copy Elite Seeds (Pool 0000)
    dest_0000 = os.path.join(elmfuzz_rundir, gen, 'seeds', '0000')
    os.makedirs(dest_0000, exist_ok=True)
    
    elite_seeds_info = [] # List of {'path': str, 'transitions': set(), 'name': str}
    
    # Parse Elites
    for prev_gen, states in elites_data.items():
        gen_dir_name = resolve_gen_dir(elmfuzz_rundir, prev_gen)
        for state_pool, files in states.items():
            for filename_key, val in files.items():
                # Extract seed info
                if ':state:' in filename_key:
                    seed_name_full = filename_key.split(':state:')[0]
                else:
                    seed_name_full = filename_key
                seed_id_prefix = seed_name_full.split(',')[0]
                
                src_path = get_cached_seed_path(gen_dir_name, state_pool, seed_id_prefix)
                
                if src_path:
                    # Extract transitions for this elite seed
                    transitions = set()
                    edges = []
                    if isinstance(val, list) and len(val) == 2:
                        edges = val[0]
                    elif isinstance(val, dict) and 'edges' in val:
                        edges = val['edges']
                    
                    for e in edges:
                        if isinstance(e, str) and e.startswith('__TRANS_'):
                            transitions.add(e)
                            
                    elite_seeds_info.append({
                        'path': src_path,
                        'name': seed_name_full,
                        'transitions': transitions,
                        'origin_gen': prev_gen
                    })
                    
                    shutil.copy(src_path, dest_0000)
                else:
                    print(f"Warning: Elite seed not found: {seed_name_full} (prefix {seed_id_prefix}) in {state_pool}", file=sys.stderr)

    print(f"Copied {len(elite_seeds_info)} elite seeds to {dest_0000}")

    # 2. Analyze Transitions (Global vs Elite)
    elite_covered_transitions = set()
    transition_counts = {} # transition -> count in elites
    
    for seed in elite_seeds_info:
        for t in seed['transitions']:
            elite_covered_transitions.add(t)
            transition_counts[t] = transition_counts.get(t, 0) + 1

    # Parse Coverage Data to find missing transitions
    # We need to map transitions to candidate seeds (path, size)
    missing_transition_candidates = {} # transition -> list of {'path': str, 'size': int}
    
    # Calculate generation string
    try:
        gen_num = int(gen.replace('gen', '')) - 1
        gen_str = str(gen_num)
    except ValueError:
        gen_str = "0" # Fallback

    if gen_str in cov_data:
        gen_dir_name = resolve_gen_dir(elmfuzz_rundir, gen_str)
        for job, seeds in cov_data[gen_str].items():
            for seed_name, state_data in seeds.items():
                if isinstance(state_data, dict):
                    seed_id_prefix = seed_name.split(',')[0]
                    src_path = get_cached_seed_path(gen_dir_name, job, seed_id_prefix)
                    
                    if src_path:
                        try:
                            size = os.path.getsize(src_path)
                        except OSError:
                            size = float('inf')

                        # Extract transitions for this seed
                        seed_transitions = set()
                        for state, edges in state_data.items():
                            parts = state.split('-')
                            if len(parts) > 1:
                                for i in range(len(parts) - 1):
                                    src = parts[i]
                                    dst = parts[i+1]
                                    trans = f"__TRANS_{src}_{dst}__"
                                    seed_transitions.add(trans)
                        
                        # Check if any are missing from elites
                        for t in seed_transitions:
                            if t not in elite_covered_transitions:
                                if t not in missing_transition_candidates:
                                    missing_transition_candidates[t] = []
                                missing_transition_candidates[t].append({'path': src_path, 'size': size})

    # 3. Determine Distribution Strategy
    state_pools = get_state_pools()
    # Filter out 0000
    all_target_pools = sorted([p for p in state_pools if p != '0000'])
    
    seeds_to_rescue = set()
    for t, candidates in missing_transition_candidates.items():
        # Pick smallest
        best_candidate = min(candidates, key=lambda x: x['size'])
        seeds_to_rescue.add(best_candidate['path'])

    dist_pools = []
    
    if seeds_to_rescue:
        # Case A: Missing transitions exist -> 0001 gets rescue seeds
        dest_0001 = os.path.join(elmfuzz_rundir, gen, 'seeds', '0001')
        os.makedirs(dest_0001, exist_ok=True)
        for src_path in seeds_to_rescue:
            shutil.copy(src_path, dest_0001)
        print(f"Copied {len(seeds_to_rescue)} seeds covering {len(missing_transition_candidates)} missing transitions to 0001")
        
        # Distribute elites to remaining pools
        dist_pools = [p for p in all_target_pools if p != '0001']
    else:
        # Case B: No missing transitions -> 0001 joins distribution
        print("No missing transitions found. 0001 joins the distribution pool.")
        dist_pools = all_target_pools

    # 4. Distribute Elites to Target Pools (Sorted by Rarity)
    if dist_pools:
        # Calculate Rarity Score for each Elite Seed
        # Score = Sum(1 / count) for each transition
        # Higher score = More rare (fewer counts)
        for seed in elite_seeds_info:
            score = 0
            for t in seed['transitions']:
                count = transition_counts.get(t, 1)
                score += 1.0 / count
            seed['score'] = score
            
        # Sort by score descending (most rare/unique first)
        sorted_elites = sorted(elite_seeds_info, key=lambda x: x['score'], reverse=True)
        
        num_pools = len(dist_pools)
        num_seeds = len(sorted_elites)
        
        print(f"Distributing {num_seeds} elite seeds to {num_pools} pools: {dist_pools}")
        
        # Split into chunks (Slicing instead of Round Robin)
        chunk_size = math.ceil(num_seeds / num_pools)
        
        distribution_results = {}

        for i, pool in enumerate(dist_pools):
            start_idx = i * chunk_size
            end_idx = min((i + 1) * chunk_size, num_seeds)
            
            chunk = sorted_elites[start_idx:end_idx]
            
            dest_pool = os.path.join(elmfuzz_rundir, gen, 'seeds', pool)
            os.makedirs(dest_pool, exist_ok=True)
            
            distribution_results[pool] = []
            for s in chunk:
                shutil.copy(s['path'], dest_pool)
                distribution_results[pool].append(s['name'])
            
            print(f"  Pool {pool}: Copied {len(chunk)} seeds (Rarity Rank {i+1}/{num_pools}).")
            
    else:
        print("No other state pools to distribute to.")
        distribution_results = {}

    # 5. Write selection results to log file
    log_dir = os.path.join(elmfuzz_rundir, gen, 'logs')
    os.makedirs(log_dir, exist_ok=True)
    state_log_path = os.path.join(log_dir, 'state.log')
    
    with open(state_log_path, 'a') as f:
        f.write(f"\n=== Generation {gen} (SS) ===\n")
        f.write("Pool 0000 (Elites):\n")
        for seed in sorted(elite_seeds_info, key=lambda x: x['name']):
            f.write(f"{seed['name']} (Source: {seed['origin_gen']} Path:{seed['path']})\n")
            
        if seeds_to_rescue:
            f.write("\nPool 0001 (Missing Transitions):\n")
            for seed_path in sorted(seeds_to_rescue):
                f.write(f"{os.path.basename(seed_path)}\n")
            
        f.write("\nDistribution:\n")
        if distribution_results:
            for pool, seeds in sorted(distribution_results.items()):
                f.write(f"Pool {pool}:\n")
                for s in sorted(seeds):
                    f.write(f"{s}\n")
        else:
            f.write("No distribution performed.\n")

def select_states_mqtt(cov_file, elites_file, gen, elmfuzz_rundir):
    """MQTT protocol-aware state distribution strategy.

    Instead of distributing seeds by rarity score + uniform slicing (like --ss),
    this strategy parses each seed's binary content to identify which MQTT
    functional zone it primarily exercises, then routes it to a dedicated pool:

        0000  All elites (complete set for baseline coverage)
        0001  SESSION zone: CONNECT variants, auth, will messages
                → focus AFL on connection handshake code paths
        0002  PUB/SUB zone: SUBSCRIBE, UNSUBSCRIBE, QoS 0/1 PUBLISH, PUBACK
                → focus AFL on message routing & QoS 1 ack paths
        0003  ADVANCED zone: QoS 2 handshake (PUBREC/PUBREL/PUBCOMP),
              PINGREQ/DISCONNECT keepalive, plus protocol violations
                → focus AFL on complex state machines & edge cases

    For each seed we compute a composite score that combines:
      - MQTT zone weight from binary packet parsing
      - State depth from coverage data (deeper = more interesting)
      - Transition rarity from elite statistics

    Seeds covering missing transitions are always rescued into every pool
    to avoid losing hard-won protocol exploration progress.
    """
    print(f"[MQTT] Loading coverage file: {cov_file}")
    with open(cov_file, 'r') as f:
        cov_data = json.load(f)

    print(f"[MQTT] Loading elites file: {elites_file}")
    with open(elites_file, 'r') as f:
        elites_data = json.load(f)

    # ---- seed path cache (same pattern as select_states_ss) ----
    seed_map_cache = {}
    global_seed_map = {}
    global_scan_done = False

    def get_cached_seed_path(gen_dir, pool, seed_prefix):
        nonlocal global_scan_done
        key = (gen_dir, pool)
        if key not in seed_map_cache:
            base_dir = os.path.join(elmfuzz_rundir, gen_dir, 'aflnetout', pool)
            seed_map_cache[key] = get_seed_map(base_dir)
        path = seed_map_cache[key].get(seed_prefix)
        if path:
            return path
        if not global_scan_done:
            print("[MQTT] Scanning all aflnetout directories for missing seeds...",
                  file=sys.stderr)
            for d in get_all_aflnet_dirs(elmfuzz_rundir):
                try:
                    for f in os.listdir(d):
                        if f.startswith("id:"):
                            prefix = f.split(',')[0]
                            if prefix not in global_seed_map:
                                global_seed_map[prefix] = os.path.join(d, f)
                except OSError:
                    pass
            global_scan_done = True
        return global_seed_map.get(seed_prefix)

    # ================================================================
    # Step 1: Collect elite seeds → pool 0000, enriched with metadata
    # ================================================================
    dest_0000 = os.path.join(elmfuzz_rundir, gen, 'seeds', '0000')
    os.makedirs(dest_0000, exist_ok=True)

    elite_seeds = []  # list of dicts with rich metadata

    for prev_gen_key, states in elites_data.items():
        gen_dir_name = resolve_gen_dir(elmfuzz_rundir, prev_gen_key)
        for state_pool, files in states.items():
            for filename_key, val in files.items():
                if ':state:' in filename_key:
                    seed_name = filename_key.split(':state:')[0]
                else:
                    seed_name = filename_key
                seed_prefix = seed_name.split(',')[0]

                src_path = get_cached_seed_path(gen_dir_name, state_pool, seed_prefix)
                if not src_path:
                    print(f"[MQTT] Warning: elite seed not found: {seed_name}",
                          file=sys.stderr)
                    continue

                # Extract covered edges / transitions from elites JSON
                transitions = set()
                edges = []
                if isinstance(val, list) and len(val) == 2:
                    edges = val[0]
                elif isinstance(val, dict) and 'edges' in val:
                    edges = val['edges']
                for e in edges:
                    if isinstance(e, str) and e.startswith('__TRANS_'):
                        transitions.add(e)

                # Parse binary content to get MQTT zone profile
                zone_weights, pkt_info = parse_mqtt_seed_zones(src_path)
                primary_zone = classify_seed_primary_zone(zone_weights)

                shutil.copy(src_path, dest_0000)

                elite_seeds.append({
                    'path': src_path,
                    'name': seed_name,
                    'transitions': transitions,
                    'edges': edges,
                    'origin_gen': prev_gen_key,
                    'zone_weights': zone_weights,
                    'primary_zone': primary_zone,
                    'pkt_info': pkt_info,
                })

    print(f"[MQTT] Copied {len(elite_seeds)} elite seeds to 0000")

    # ================================================================
    # Step 2: Compute transition statistics across elites
    # ================================================================
    elite_transitions = set()
    transition_counts = defaultdict(int)
    for s in elite_seeds:
        for t in s['transitions']:
            elite_transitions.add(t)
            transition_counts[t] += 1

    # ================================================================
    # Step 3: Find missing transitions from coverage data
    # ================================================================
    try:
        gen_num = int(gen.replace('gen', '')) - 1
        gen_str = str(gen_num)
    except ValueError:
        gen_str = "0"

    # missing transition → best candidate seed path (smallest file)
    missing_trans_seeds = {}   # transition_str → src_path
    all_cov_transitions = set()

    if gen_str in cov_data:
        gen_dir_name = resolve_gen_dir(elmfuzz_rundir, gen_str)
        for job, seeds in cov_data[gen_str].items():
            for seed_name, state_data in seeds.items():
                if not isinstance(state_data, dict):
                    continue
                seed_prefix = seed_name.split(',')[0]
                src_path = get_cached_seed_path(gen_dir_name, job, seed_prefix)
                if not src_path:
                    continue
                try:
                    fsize = os.path.getsize(src_path)
                except OSError:
                    fsize = float('inf')

                for state_seq, _edges in state_data.items():
                    parts = str(state_seq).split('-')
                    for i in range(len(parts) - 1):
                        trans = f"__TRANS_{parts[i]}_{parts[i+1]}__"
                        all_cov_transitions.add(trans)
                        if trans not in elite_transitions:
                            cur = missing_trans_seeds.get(trans)
                            if cur is None or fsize < cur[1]:
                                missing_trans_seeds[trans] = (src_path, fsize)

    rescue_paths = set(v[0] for v in missing_trans_seeds.values())
    print(f"[MQTT] {len(missing_trans_seeds)} missing transitions, "
          f"{len(rescue_paths)} rescue seeds identified")

    # ================================================================
    # Step 4: Enrich elite seeds with coverage depth info
    # ================================================================
    # For each elite seed, find its state depth from coverage data
    seed_depth = {}  # seed_name → max_depth
    if gen_str in cov_data:
        for job, seeds in cov_data[gen_str].items():
            for seed_name, state_data in seeds.items():
                if isinstance(state_data, dict):
                    _, depth, max_sid = compute_mqtt_transition_signature(state_data)
                    cur = seed_depth.get(seed_name, 0)
                    seed_depth[seed_name] = max(cur, depth)

    for s in elite_seeds:
        s['depth'] = seed_depth.get(s['name'], 1)

    # ================================================================
    # Step 5: MQTT-aware pool assignment
    # ================================================================
    state_pools = get_state_pools()
    target_pools = sorted([p for p in state_pools if p != '0000'])

    if len(target_pools) < 1:
        print("[MQTT] No target pools besides 0000; skipping distribution.")
        _write_mqtt_log(elmfuzz_rundir, gen, elite_seeds, {}, rescue_paths, {})
        return

    # Build zone → pool mapping, adapting to actual number of pools
    if len(target_pools) >= 3:
        # 3+ pools: full zone specialization
        zone_pool = {
            "SESSION":     target_pools[0],
            "PUB_SIMPLE":  target_pools[1],
            "PUB_ACKED":   target_pools[1],
            "PUB_ASSURED": target_pools[2],
            "LIFECYCLE":   target_pools[2],
            "EDGE_CASE":   None,  # distributed to all
        }
    elif len(target_pools) == 2:
        # 2 pools: session+lifecycle vs pub/*
        zone_pool = {
            "SESSION":     target_pools[0],
            "LIFECYCLE":   target_pools[0],
            "EDGE_CASE":   target_pools[0],
            "PUB_SIMPLE":  target_pools[1],
            "PUB_ACKED":   target_pools[1],
            "PUB_ASSURED": target_pools[1],
        }
    else:
        # 1 pool: everything goes there
        zone_pool = {z: target_pools[0] for z in
                     ["SESSION","PUB_SIMPLE","PUB_ACKED","PUB_ASSURED","LIFECYCLE","EDGE_CASE"]}

    # Initialize per-pool seed buckets
    pool_buckets = {p: [] for p in target_pools}

    # Compute composite score for each elite seed:
    #   score = rarity_component + depth_bonus + zone_diversity_bonus
    for s in elite_seeds:
        # Rarity: sum(1/count) for each transition
        rarity = sum(1.0 / transition_counts.get(t, 1) for t in s['transitions'])
        # Depth bonus: deeper state sequences indicate more interesting protocol paths
        depth_bonus = math.log2(1 + s['depth'])
        # QoS2 completeness bonus
        pkt_types_seen = set(p[0] for p in s['pkt_info'])
        qos2_bonus = 2.0 if {MQTT_PKT_PUBREC, MQTT_PKT_PUBREL, MQTT_PKT_PUBCOMP}.issubset(pkt_types_seen) else 0.0
        s['score'] = rarity + depth_bonus + qos2_bonus

    # --- Primary assignment: route each seed to its zone's pool ---
    for s in elite_seeds:
        pzone = s['primary_zone']
        dest_pool = zone_pool.get(pzone)

        if dest_pool is None:
            # EDGE_CASE or unmapped → goes to the pool with fewest seeds so far
            min_pool = min(pool_buckets, key=lambda p: len(pool_buckets[p]))
            pool_buckets[min_pool].append(s)
        else:
            pool_buckets[dest_pool].append(s)

    # --- Balance pass: if any pool is severely under-populated, steal from largest ---
    total_seeds = len(elite_seeds)
    if total_seeds > 0 and len(target_pools) > 1:
        ideal = total_seeds / len(target_pools)
        min_threshold = max(1, int(ideal * 0.25))  # at least 25% of ideal

        for _ in range(3):  # max 3 rebalancing rounds
            sizes = {p: len(pool_buckets[p]) for p in target_pools}
            starved = [p for p in target_pools if sizes[p] < min_threshold]
            if not starved:
                break
            fattest = max(target_pools, key=lambda p: sizes[p])
            if sizes[fattest] <= min_threshold + 1:
                break
            for starved_pool in starved:
                # Move lowest-score seeds from fattest to starved
                pool_buckets[fattest].sort(key=lambda s: s['score'], reverse=True)
                while len(pool_buckets[starved_pool]) < min_threshold and len(pool_buckets[fattest]) > min_threshold:
                    moved = pool_buckets[fattest].pop()
                    pool_buckets[starved_pool].append(moved)

    # --- Sort each pool by score descending (AFL will process in order) ---
    for p in target_pools:
        pool_buckets[p].sort(key=lambda s: s['score'], reverse=True)

    # ================================================================
    # Step 6: Copy seeds to pool directories
    # ================================================================
    distribution_results = {}

    for pool in target_pools:
        dest_pool = os.path.join(elmfuzz_rundir, gen, 'seeds', pool)
        os.makedirs(dest_pool, exist_ok=True)
        distribution_results[pool] = []

        for s in pool_buckets[pool]:
            shutil.copy(s['path'], dest_pool)
            distribution_results[pool].append(s['name'])

        # Also copy rescue seeds (missing transitions) into every pool
        for rpath in rescue_paths:
            fname = os.path.basename(rpath)
            dest = os.path.join(dest_pool, fname)
            if not os.path.exists(dest):
                shutil.copy(rpath, dest_pool)

        pool_total = len(distribution_results[pool]) + len(rescue_paths)
        zone_summary = defaultdict(int)
        for s in pool_buckets[pool]:
            zone_summary[s['primary_zone']] += 1
        zone_str = ", ".join(f"{z}={c}" for z, c in sorted(zone_summary.items()))
        print(f"  Pool {pool}: {len(pool_buckets[pool])} elites + "
              f"{len(rescue_paths)} rescue = ~{pool_total} seeds "
              f"[{zone_str}]")

    # ================================================================
    # Step 7: Write detailed log
    # ================================================================
    _write_mqtt_log(elmfuzz_rundir, gen, elite_seeds, pool_buckets,
                    rescue_paths, distribution_results)


def _write_mqtt_log(elmfuzz_rundir, gen, elite_seeds, pool_buckets,
                    rescue_paths, distribution_results):
    """Write detailed MQTT state selection log."""
    log_dir = os.path.join(elmfuzz_rundir, gen, 'logs')
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, 'state.log')

    with open(log_path, 'a') as f:
        f.write(f"\n{'='*60}\n")
        f.write(f"=== Generation {gen} (MQTT-aware) ===\n")
        f.write(f"{'='*60}\n\n")

        # Zone distribution summary
        zone_counter = defaultdict(int)
        for s in elite_seeds:
            zone_counter[s['primary_zone']] += 1
        f.write("MQTT Zone Distribution of Elites:\n")
        for z in ["SESSION", "PUB_SIMPLE", "PUB_ACKED", "PUB_ASSURED",
                   "LIFECYCLE", "EDGE_CASE"]:
            f.write(f"  {z:14s}: {zone_counter.get(z, 0):4d} seeds\n")
        f.write(f"  {'TOTAL':14s}: {len(elite_seeds):4d} seeds\n\n")

        # Pool 0000
        f.write("Pool 0000 (All Elites):\n")
        for s in sorted(elite_seeds, key=lambda x: x['name']):
            f.write(f"  {s['name']}  zone={s['primary_zone']}  "
                    f"depth={s['depth']}  score={s.get('score',0):.3f}\n")
        f.write("\n")

        # Rescue seeds
        if rescue_paths:
            f.write(f"Rescue Seeds ({len(rescue_paths)}, copied to ALL pools):\n")
            for p in sorted(rescue_paths):
                f.write(f"  {os.path.basename(p)}\n")
            f.write("\n")

        # Per-pool details
        for pool in sorted(pool_buckets.keys()):
            bucket = pool_buckets[pool]
            f.write(f"Pool {pool} ({len(bucket)} elites):\n")
            for s in bucket:
                pkts = ",".join(MQTT_PKT_NAMES.get(p[0], '?') for p in s['pkt_info'][:8])
                if len(s['pkt_info']) > 8:
                    pkts += f"...+{len(s['pkt_info'])-8}"
                f.write(f"  {s['name']}  zone={s['primary_zone']}  "
                        f"score={s.get('score',0):.3f}  pkts=[{pkts}]\n")
            f.write("\n")


def get_all_aflnet_dirs(elmfuzz_rundir):
    dirs = []
    # Search in root aflnetout
    root_aflnet = os.path.join(elmfuzz_rundir, 'aflnetout')
    if os.path.exists(root_aflnet):
        try:
            for d in os.listdir(root_aflnet):
                full_d = os.path.join(root_aflnet, d)
                if os.path.isdir(full_d):
                    dirs.append(full_d)
                    queue_d = os.path.join(full_d, 'queue')
                    if os.path.isdir(queue_d):
                        dirs.append(queue_d)
        except OSError:
            pass
    
    # Search in gen*/aflnetout
    if os.path.exists(elmfuzz_rundir):
        try:
            for item in os.listdir(elmfuzz_rundir):
                if (item.startswith('gen') or item.isdigit()) and os.path.isdir(os.path.join(elmfuzz_rundir, item)):
                    gen_aflnet = os.path.join(elmfuzz_rundir, item, 'aflnetout')
                    if os.path.exists(gen_aflnet):
                        try:
                            for d in os.listdir(gen_aflnet):
                                full_d = os.path.join(gen_aflnet, d)
                                if os.path.isdir(full_d):
                                    dirs.append(full_d)
                                    queue_d = os.path.join(full_d, 'queue')
                                    if os.path.isdir(queue_d):
                                        dirs.append(queue_d)
                        except OSError:
                            pass
        except OSError:
            pass
    return dirs

@click.command()
@click.option('--cov_file', '-c', type=click.Path(exists=True), required=True, help='Previous generation coverage file')
@click.option('--elites_file', '-e', type=click.Path(exists=True), required=True, help='Current generation elite seeds file')
@click.option('--gen', '-g', type=str, required=True, help='Next generation name')
@click.option('--noss', is_flag=True, default=False, help='No state selection (uniform distribution)')
@click.option('--ss', '-ss', is_flag=True, default=False, help='State selection with rarity-based distribution')
@click.option('--mqtt', is_flag=True, default=False, help='MQTT protocol-aware state distribution')
def main(cov_file, elites_file, gen, noss, ss, mqtt):
    elmfuzz_rundir = os.environ.get('ELMFUZZ_RUNDIR')
    if not elmfuzz_rundir:
        print("Error: ELMFuzz_RUNDIR environment variable not set.", file=sys.stderr)
        sys.exit(1)

    if mqtt:
        select_states_mqtt(cov_file, elites_file, gen, elmfuzz_rundir)
    elif ss:
        select_states_ss(cov_file, elites_file, gen, elmfuzz_rundir)
    else:
        select_states_noss(cov_file, elites_file, gen, elmfuzz_rundir)

if __name__ == '__main__':
    main()
