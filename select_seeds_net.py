import click
import json
import sys
import os
import time
from typing import Union, Literal, Optional
import random
from tqdm import tqdm
import heapq
import util

MODEL = 'CodeLlama-13b-hf'

def superior_than(edge_coverage1: set[str], edge_coverage2: set[str]) -> bool:
    return len(edge_coverage1) > len(edge_coverage2) and ((not edge_coverage2) or edge_coverage2.issubset(edge_coverage1))

def inferior_than(edge_coverage1: set[str], edge_coverage2: set[str]) -> bool:
    return len(edge_coverage1) < len(edge_coverage2) and ((not edge_coverage1) or edge_coverage1.issubset(edge_coverage2))

def equal_to(edge_coverage1: set[str], edge_coverage2: set[str]) -> bool:
    return edge_coverage1 == edge_coverage2

def greedy_search(set_family: list[tuple[str, set[str], int]], num: int, baseline: set[str] = set()) -> list[tuple[str, set[str], int]]:
    baseline_edges = set(baseline) if baseline else set()
    current_covered = set(baseline_edges)
    selected = []
    
    # Candidates: list of (key, edges, size)
    remaining = []
    for key, edges, size in set_family:
        remaining.append((key, edges, size))
    
    # CELF (Lazy Greedy) Optimization
    pq = []
    for key, edges, size in remaining:
        gain = len(edges.difference(current_covered))
        # Heap stores (-gain, size, key, edges)
        # We use key as tie breaker for stability
        heapq.heappush(pq, (-gain, size, key, edges))
        
    for _ in tqdm(range(num), desc='Greedy Selecting'):
        if not pq:
            break
            
        while pq:
            neg_gain, size, key, edges = heapq.heappop(pq)
            gain = -neg_gain
            
            # Re-evaluate gain
            real_gain = len(edges.difference(current_covered))
            
            if real_gain == gain:
                # Found the best
                selected.append((key, edges, size))
                current_covered.update(edges)
                break
            else:
                # Push back with updated gain
                heapq.heappush(pq, (-real_gain, size, key, edges))
                
    return selected

def ilp_set_cover(set_family: list[tuple[str, set[str], int]], baseline: set[str] = set()) -> list[tuple[str, set[str], int]]:
    # Try using OR-Tools first (faster)
    try:
        from ortools.sat.python import cp_model
        use_ortools = True
    except ImportError:
        use_ortools = False

    baseline_edges = set(baseline) if baseline else set()
    
    # 1. Identify the Universe (all edges covered by candidates, minus baseline)
    universe = set()
    for _, edges, _ in set_family:
        universe.update(edges)
    
    universe.difference_update(baseline_edges)
    
    if not universe:
        return []

    if use_ortools:
        print(f"ILP (OR-Tools): Solving Set Cover for {len(universe)} edges using {len(set_family)} candidates...", file=sys.stderr)
        model = cp_model.CpModel()
        
        # Variables: x[i] = 1 if candidate i is selected
        x = [model.NewBoolVar(f'x_{i}') for i in range(len(set_family))]
        
        # Objective: Minimize total number of selected seeds
        model.Minimize(sum(x))
        
        # Constraints
        edge_to_indices = {e: [] for e in universe}
        for idx, (_, edges, _) in enumerate(set_family):
            for e in edges:
                if e in edge_to_indices:
                    edge_to_indices[e].append(idx)
        
        for e in universe:
            model.Add(sum(x[i] for i in edge_to_indices[e]) >= 1)
            
        solver = cp_model.CpSolver()
        solver.parameters.max_time_in_seconds = 300.0
        status = solver.Solve(model)
        
        if status in (cp_model.OPTIMAL, cp_model.FEASIBLE):
            selected = [set_family[i] for i in range(len(set_family)) if solver.Value(x[i])]
            print(f"ILP (OR-Tools): Reduced from {len(set_family)} to {len(selected)} seeds.", file=sys.stderr)
            return selected
        else:
            print("ILP (OR-Tools) failed to find solution. Returning original set.", file=sys.stderr)
            return set_family

    # Fallback to PuLP
    try:
        import pulp
    except ImportError:
        print("Neither ortools nor pulp found. Please install 'ortools' or 'pulp'.", file=sys.stderr)
        return set_family

    print(f"ILP (PuLP): Solving Set Cover for {len(universe)} edges using {len(set_family)} candidates...", file=sys.stderr)

    # 2. Setup ILP Problem
    prob = pulp.LpProblem("MinSeedSetCover", pulp.LpMinimize)
    
    # Variables: x[i] = 1 if candidate i is selected
    x = pulp.LpVariable.dicts("x", range(len(set_family)), cat='Binary')
    
    # Objective: Minimize total number of selected seeds
    prob += pulp.lpSum([x[i] for i in range(len(set_family))])

    # Constraints: Every edge in the universe must be covered by at least one selected seed
    # Optimization: Build an inverted index first
    edge_to_indices = {e: [] for e in universe}
    for idx, (_, edges, _) in enumerate(set_family):
        for e in edges:
            if e in edge_to_indices:
                edge_to_indices[e].append(idx)
    
    for e in universe:
        prob += pulp.lpSum([x[i] for i in edge_to_indices[e]]) >= 1

    # 3. Solve
    # 5 minute timeout
    solver = pulp.PULP_CBC_CMD(msg=False, timeLimit=300) 
    prob.solve(solver)
    
    # 4. Extract Result
    status = pulp.LpStatus[prob.status]
    print(f"ILP Status: {status}", file=sys.stderr)
    
    selected = []
    if status in ['Optimal', 'Feasible']:
        for i in range(len(set_family)):
            if pulp.value(x[i]) > 0.5: # Floating point tolerance
                selected.append(set_family[i])
        print(f"ILP: Reduced from {len(set_family)} to {len(selected)} seeds.", file=sys.stderr)
        return selected
    else:
        print("ILP failed to find a solution. Returning original set.", file=sys.stderr)
        return set_family

def get_transitions_from_state_string(state_str: str) -> set[str]:
    pseudo_edges = set()
    if not state_str or state_str == "unknown":
        return pseudo_edges
    
    try:
        if 'end-at-' in state_str:
            state_str = state_str.split('end-at-', 1)[0]
            if state_str.endswith('-'):
                state_str = state_str[:-1]
        
        states = state_str.split('-')
        # Filter out empty strings and non-numeric states
        states = [s for s in states if s.isdigit()]
        
        if len(states) >= 2:
            for i in range(len(states) - 1):
                pseudo_edges.add(f"__TRANS_{states[i]}_{states[i+1]}__")
    except Exception:
        pass
    return pseudo_edges

def extract_state_pseudo_edges(filename: str) -> set[str]:
    # Legacy support for filename-based extraction
    if ':state:' in filename:
        try:
            state_part = filename.split(':state:', 1)[1]
            return get_transitions_from_state_string(state_part)
        except Exception:
            pass
    return set()

@click.command()
@click.option('--generation', '-g', type=str)
@click.option('--current-covfile', '-c', 'current_covfile', type=click.Path(exists=False), help='Current coverage file')
@click.option('--max-elites', '-n', 'max_elites', type=int)
@click.option('--input-elite-file', '-i', 'input_elite_file', type=click.Path(exists=False), help='Elite seeds file')
@click.option('--output-elite-file', '-o', 'output_elite_file', type=click.Path(writable=True, dir_okay=False), help='Elite seeds file')
@click.option('--baseline', '-b', type=click.Path(exists=False), default=None)
@click.option('--use-ilp', '-u', is_flag=True, help='Use ILP to find the minimum set of seeds covering all edges')
@click.option('--rescue-missing', '-r', type=bool, default=None, help='Rescue missing edges after ILP using greedy set cover')
def main(generation: str, current_covfile, max_elites: int, input_elite_file, output_elite_file, baseline, use_ilp, rescue_missing):
    if generation.startswith('gen'):
        try:
            gen_num = int(generation[3:])
            initial_max_elites = max_elites
            harmonic_sum = sum(1/i for i in range(1, gen_num + 1))
            max_elites = int(initial_max_elites * (1 + harmonic_sum))
            print(f"DEBUG: Adjusted max_elites to {max_elites} for generation {generation} (Harmonic factor: {1 + harmonic_sum:.2f})", file=sys.stderr)
        except ValueError:
            pass

    if generation == 'initial':
        coverage_raw = dict()
    else:
        with open(click.format_filename(current_covfile), 'r') as f:
            coverage_raw = json.loads(f.read())
    ELMFUZZ_RUNDIR = os.environ.get('ELMFUZZ_RUNDIR')
    
    if rescue_missing is None:
        try:
            config_value = util.get_config('run.rescue')
            if isinstance(config_value, str):
                rescue_missing = config_value.lower() == 'true'
            else:
                rescue_missing = True  # 如果是list，默认True
        except Exception as e:
            print(f"Error getting rescue_missing from config: {e}", file=sys.stderr)
            rescue_missing = True  # 默认值
    
    
    if baseline is not None:
        with open(click.format_filename(baseline)) as base_edges_f:
            base_edges: set[str] = set()
            for l in base_edges_f:
                if not l.strip():
                    continue
                base_edges.add(l.strip())
    
    # Reconstruct coverage dict
    coverage: dict[str, dict[str, set[str]]] = {}
    
    if coverage_raw:
        first_val = next(iter(coverage_raw.values()))
        if isinstance(first_val, dict):
            for gen, states in coverage_raw.items():
                for state, files in states.items():
                    if state not in coverage:
                        coverage[state] = {}
                    for filename, val in files.items():
                        edge_set = set()
                        state_str = "unknown"
                        
                        if isinstance(val, dict):
                            # New format: {"state_str": [edges]}
                            for s, e in val.items():
                                state_str = s
                                edge_set.update(map(lambda x: x.split(':')[0], e))
                        elif isinstance(val, list):
                            # Old format: [edges]
                            edge_set.update(map(lambda x: x.split(':')[0], val))
                        
                        # Add pseudo edges from state string
                        edge_set.update(get_transitions_from_state_string(state_str))
                        
                        # Fallback to filename if state_str is unknown
                        if state_str == "unknown":
                            edge_set.update(extract_state_pseudo_edges(filename))
                            
                        coverage[state][filename] = edge_set
        else:
            for full_key, edges_list in coverage_raw.items():
                if ':' in full_key:
                    state, rest = full_key.split(':', 1)
                else:
                    state = "unknown"
                    rest = full_key
                filename = rest
                if state not in coverage:
                    coverage[state] = {}
                edge_set = set(map(lambda x: x.split(':')[0], edges_list))
                coverage[state][filename] = edge_set

    # Dynamic adjustment of max_elites based on total coverage
    # if coverage:
    #     all_edges_found = set()
    #     for s_map in coverage.values():
    #         for e_set in s_map.values():
    #             all_edges_found.update(e_set)
        
    #     num_edges = len(all_edges_found)
        
    #     # Strategy: Allow 1 elite seed for every 20 unique edges found.
    #     # This scales the population size linearly with the complexity of the explored state space.
    #     # Adjust the divisor (20) to control density:
    #     # - Larger divisor (e.g. 50) -> Fewer seeds, more aggressive pruning
    #     # - Smaller divisor (e.g. 10) -> More seeds, higher diversity
    #     density_factor = 20
    #     dynamic_limit = int(num_edges / density_factor)
        
    #     if dynamic_limit > 0:
    #         print(f"DEBUG: Dynamic adjustment: Found {num_edges} unique edges. Setting max_elites to {dynamic_limit} (configured: {max_elites}).", file=sys.stderr)
    #         max_elites = dynamic_limit
    
    if generation == 'initial' or generation == 'gen0':
        elites = dict()
    else:
        if input_elite_file is None:
            elites = dict()
        else:
            with open(click.format_filename(input_elite_file), 'r') as f:
                elites_raw = json.loads(f.read())

            elites = {}
            if elites_raw:
                first_val = next(iter(elites_raw.values()))
                if isinstance(first_val, dict):
                    for gen, states in elites_raw.items():
                        for state, files in states.items():
                            for filename, val in files.items():
                                key = f"{gen}-{state}/{filename}"
                                if isinstance(val, list) and len(val) == 2 and isinstance(val[1], int):
                                    edges, size = val
                                else:
                                    edges = val
                                    size = float('inf')
                                
                                current_edges = set(edges)
                                # current_edges.update(extract_state_pseudo_edges(filename))
                                elites[key] = (current_edges, size)
                else:
                    elites = {}
                    for key, (edges, size) in elites_raw.items():
                        filename = key.split('/')[-1] if '/' in key else key
                        current_edges = set(edges)
                        # current_edges.update(extract_state_pseudo_edges(filename))
                        elites[key] = (current_edges, size)
    
    start_time = time.time()
    
    elite_filtering_record: dict[frozenset[str], tuple[str, int]] = dict()
    skipped_files_count = 0
    
    for state, seeds in coverage.items():
        for descendant_key, descendant_edges_raw in seeds.items():
            # Edges already include pseudo-edges from loading phase
            descendant_edges = frozenset(descendant_edges_raw)
            
            if ':state:' in descendant_key:
                real_filename = descendant_key.split(':state:', 1)[0]
            else:
                real_filename = descendant_key

            # Improved file finding logic
            found_path = None
            
            # 1. Try direct paths (assuming state is valid directory)
            candidates = [
                os.path.join(ELMFUZZ_RUNDIR, generation, 'aflnetout', state, 'queue', real_filename),
                os.path.join(ELMFUZZ_RUNDIR, generation, 'aflnetout', state, real_filename),
                os.path.join(ELMFUZZ_RUNDIR, 'aflnetout', state, 'queue', real_filename),
                os.path.join(ELMFUZZ_RUNDIR, 'aflnetout', state, real_filename)
            ]
            
            for p in candidates:
                if os.path.exists(p):
                    found_path = p
                    break
            
            # 2. Search in all aflnetout subdirectories if not found
            if not found_path:
                if not hasattr(main, 'aflnet_dirs_cache'):
                    main.aflnet_dirs_cache = []
                    possible_roots = [
                        os.path.join(ELMFUZZ_RUNDIR, generation, 'aflnetout'),
                        os.path.join(ELMFUZZ_RUNDIR, 'aflnetout')
                    ]
                    for root in possible_roots:
                        if os.path.exists(root):
                            try:
                                for d in os.listdir(root):
                                    full_d = os.path.join(root, d)
                                    if os.path.isdir(full_d):
                                        main.aflnet_dirs_cache.append(full_d)
                                        queue_d = os.path.join(full_d, 'queue')
                                        if os.path.isdir(queue_d):
                                            main.aflnet_dirs_cache.append(queue_d)
                            except OSError:
                                pass
                
                for d in main.aflnet_dirs_cache:
                    p = os.path.join(d, real_filename)
                    if os.path.exists(p):
                        found_path = p
                        break
                
                # If still not found, try fuzzy match in cached dirs
                if not found_path and real_filename.startswith("id:"):
                     seed_id = real_filename.split(',')[0]
                     for d in main.aflnet_dirs_cache:
                         try:
                             for f in os.listdir(d):
                                 if f.startswith(seed_id + ","):
                                     found_path = os.path.join(d, f)
                                     break
                         except OSError:
                             pass
                         if found_path:
                             break

            if found_path:
                descendant_size = os.path.getsize(found_path)
            else:
                skipped_files_count += 1
                continue

            unique_key = f"{state}/{descendant_key}"
            
            if descendant_edges in elite_filtering_record:
                record_key, record_size = elite_filtering_record[descendant_edges]
                if descendant_size < record_size:
                    elite_filtering_record[descendant_edges] = (unique_key, descendant_size)
            else:
                elite_filtering_record[descendant_edges] = (unique_key, descendant_size)
    
    print(f"DEBUG: Skipped {skipped_files_count} files because they were not found on disk.", file=sys.stderr)
    
    filtered_descendants0: dict[str, tuple[set[str], int]] = dict()
    for descendant_edges, (descendant_key, descendant_size) in elite_filtering_record.items():
        filtered_descendants0[descendant_key] = (set(descendant_edges), descendant_size)

    # Optimized filtering 1
    sorted_candidates = sorted(
        filtered_descendants0.items(),
        key=lambda x: (len(x[1][0]), -x[1][1]),
        reverse=True
    )

    selected_keys = set()
    kept_edges = [] 

    for key, (edges, size) in sorted_candidates:
        is_inferior = False
        for k_edges in kept_edges:
            if edges.issubset(k_edges):
                is_inferior = True
                break
        
        if not is_inferior:
            selected_keys.add(key)
            kept_edges.append(edges)
            
    filtered_descendants = {k: filtered_descendants0[k] for k in selected_keys}
    
    replace: dict[str, str] = dict()
    newly_added = set()
    failed_descendant = set()
    if not elites:
        newly_added.update(filtered_descendants.keys())
    else:
        for elite_key, (elite_edges, elite_size) in elites.items():
            for descendant_key, (descendant_edges, descendant_size) in filtered_descendants.items():
                if descendant_key in failed_descendant:
                    continue
                if equal_to(descendant_edges, elite_edges):
                    if descendant_size < elite_size:
                        replace[elite_key] = descendant_key
                    else:
                        failed_descendant.add(descendant_key)
                elif superior_than(descendant_edges, elite_edges):
                    replace[elite_key] = descendant_key
                elif inferior_than(descendant_edges, elite_edges):
                    failed_descendant.add(descendant_key)
                else:
                    newly_added.add(descendant_key)
    
    new_elites: dict[str, tuple[list[str], int]] = dict()
    
    for elite_key, (elite_edges, elite_size) in elites.items():
        if elite_key in replace:
            replaced_by = replace[elite_key]
            s, sz = filtered_descendants[replaced_by]
            new_elites[f'{generation}-{replaced_by}'] = (list(s), sz)
        else:
            new_elites[elite_key] = (list(elite_edges), elite_size)
    
    for n in newly_added:
        s, sz = filtered_descendants[n]
        new_elites[f'{generation}-{n}'] = (list(s), sz)

    if baseline is not None:
        max_interesting_edges = 0
        interesting = set()
        for elite_key, (elite_edges, _) in new_elites.items():
            edge_set = set(elite_edges)
            if not inferior_than(edge_set, base_edges):
                interesting.add(elite_key)
                interesting_edges = len(edge_set.difference(base_edges))
                max_interesting_edges = max(max_interesting_edges, interesting_edges)
        if interesting:
            print(f'Found {len(interesting)} interesting elites with max interesting edges {max_interesting_edges}', file=sys.stderr)
    
    THRESHOLD_FACTOR = 1
    if baseline is not None and len(interesting) > THRESHOLD_FACTOR * max_elites:
        print(f'WARNING: The number of interesting elites {len(interesting)} exceeds the limit {max_elites} x {THRESHOLD_FACTOR}', file=sys.stderr)
        
        new_elites_filtering: dict[frozenset[str], tuple[str, int]] = dict()

        for elite_key, (elite_edges_raw, elite_size) in new_elites.items():
            elite_edges = frozenset(set(elite_edges_raw).union(base_edges))
            if elite_edges in new_elites_filtering:
                record_key, record_size = new_elites_filtering[elite_edges]
                if elite_size < record_size:
                    new_elites_filtering[elite_edges] = (elite_key, elite_size)
            else:
                new_elites_filtering[elite_edges] = (elite_key, elite_size)
        
        filtered_new_elites0: dict[str, tuple[set[str], int]] = dict()
        for elite_edges, (elite_key, elite_size) in new_elites_filtering.items():
            filtered_new_elites0[elite_key] = (set(elite_edges), elite_size)
        
        # Optimized filtering 2
        sorted_candidates = sorted(
            filtered_new_elites0.items(),
            key=lambda x: (len(x[1][0].union(base_edges)), -x[1][1]),
            reverse=True
        )
        
        selected_keys = set()
        kept_edges = [] 
        
        for key, (edges_raw, size) in sorted_candidates:
            effective_edges = edges_raw.union(base_edges)
            is_inferior = False
            for k_edges in kept_edges:
                if effective_edges.issubset(k_edges):
                    is_inferior = True
                    break
            
            if not is_inferior:
                selected_keys.add(key)
                kept_edges.append(effective_edges)
        
        tmp = dict()
        for s in selected_keys:
            tmp[s] = new_elites[s]
        new_elites = tmp
    
    
    print(f"DEBUG: new_elites size: {len(new_elites)}", file=sys.stderr)
    
    if len(new_elites.items()) > max_elites:
        if len(new_elites) > THRESHOLD_FACTOR * max_elites:
            print(f'WARNING: The number of elites {len(new_elites)} exceeds the limit {max_elites} x {THRESHOLD_FACTOR}', file=sys.stderr)
            
            if baseline is None:
                # 1. Identify all edges we COULD cover
                all_possible_edges = set()
                for _, (edges, _) in new_elites.items():
                    all_possible_edges.update(edges)

                # 2. Run Greedy Search to get the best 'max_elites' seeds
                almost_best = greedy_search(
                    list(map(lambda item: (item[0], set(item[1][0]), item[1][1]), new_elites.items())),
                    max_elites
                )
                
                # 3. Check what we missed
                covered_edges = set()
                for _, edges, _ in almost_best:
                    covered_edges.update(edges)
                
                missing_edges = all_possible_edges - covered_edges
                
                # 4. Rescue missing edges
                if missing_edges:
                    print(f"WARNING: Greedy search missed {len(missing_edges)} edges. Rescuing...", file=sys.stderr)
                    
                    # Filter candidates to those that cover at least one missing edge
                    rescue_candidates = []
                    selected_keys = set(k for k, _, _ in almost_best)
                    
                    for key, (edges, size) in new_elites.items():
                        if key not in selected_keys:
                            relevant_edges = set(edges).intersection(missing_edges)
                            if relevant_edges:
                                rescue_candidates.append((key, relevant_edges, size))
                    
                    # Use greedy set cover for rescue
                    rescue_selected = greedy_search(rescue_candidates, len(rescue_candidates))
                    
                    print(f"Rescued {len(rescue_selected)} additional seeds to cover missing edges.", file=sys.stderr)
                    almost_best.extend(rescue_selected)

                tmp = dict()
                for key, edges, size in almost_best:
                    # Retrieve original full edge set
                    original_edges, original_size = new_elites[key]
                    tmp[key] = (original_edges, original_size)
                new_elites = tmp
            else:
                if len(interesting) < max_elites:
                    interesting_items = []
                    trivial_items = []
                    for k, item in new_elites.items():
                        if k in interesting:
                            interesting_items.append((k, item))
                        elif len(interesting) < max_elites:
                            trivial_items.append((k, item))
                    almost_best = greedy_search(
                        list(map(lambda item: (item[0], set(item[1][0]), item[1][1]), trivial_items)), 
                        max_elites - len(interesting)
                    )
                    tmp = dict()
                    for key, edges, size in almost_best:
                        tmp[key] = (list(edges), size)
                    for item in interesting_items:
                        tmp[item[0]] = item[1]
                    new_elites = tmp
                else:
                    almost_best = greedy_search(
                        list(map(lambda item: (item[0], set(item[1][0]), item[1][1]), new_elites.items())), 
                        max_elites, 
                        base_edges
                    )
                    tmp = dict()
                    for key, edges, size in almost_best:
                        tmp[key] = (list(edges), size)
                    new_elites = tmp
        else:
            print(f'WARNING: The number of elites {len(new_elites)} exceeds the limit {max_elites}', file=sys.stderr)
            if baseline is not None:
                interesting_items = []
                trivial_items = []
                for k, item in new_elites.items():
                    if k in interesting:
                        interesting_items.append((k, item))
                    elif len(interesting) < max_elites:
                        trivial_items.append((k, item))
                sorted_intrested = sorted(interesting_items, key=lambda item: (-len(set(item[1][0]).union(base_edges)), item[1][1]))
                if len(interesting) >= max_elites:
                    new_elites = dict(sorted_intrested[:max_elites])
                else:
                    sorted_trivial = sorted(trivial_items, key=lambda item: (-len(item[1][0]), item[1][1]))
                    new_elites = dict(sorted_intrested + sorted_trivial[:max_elites - len(sorted_intrested)])
            else:
                new_elites = dict(sorted(new_elites.items(), key=lambda item: (-len(item[1][0]), item[1][1]))[:max_elites])
    
    if set(new_elites.keys()) != set(elites.keys()):
        print('Elites updated', file=sys.stderr)
    
    if use_ilp:
        print("Running ILP optimization...", file=sys.stderr)
        candidates = []
        for key, (edges, size) in new_elites.items():
            candidates.append((key, set(edges), size))
        
        base_edges_set = base_edges if baseline is not None else set()
        ilp_selected = ilp_set_cover(candidates, base_edges_set)
        elmfuzz_rundir = os.environ.get('ELMFUZZ_RUNDIR')
        if not elmfuzz_rundir:
            print("Error: ELMFUZZ_RUNDIR environment variable not set.", file=sys.stderr)
            sys.exit(1)
        log_dir = os.path.join(elmfuzz_rundir, generation, 'logs')
        os.makedirs(log_dir, exist_ok=True)
        seeds_log_path = os.path.join(log_dir, 'seeds.log')
        with open(seeds_log_path, 'a') as f:
            f.write(f"ILP Selected Seeds: {len(ilp_selected)}\n")
            for key, edges, size in ilp_selected:
                f.write(f"{key}: {len(edges)} edges, size {size}\n")
            
        # Hybrid Strategy: Fill up to max_elites
        if rescue_missing:
            if len(ilp_selected) < max_elites:
                print(f"ILP selected {len(ilp_selected)} seeds. Filling up to {max_elites}...", file=sys.stderr)
                selected_keys = set(k for k, _, _ in ilp_selected)
                
                # Sort remaining candidates by coverage size (descending)
                remaining = []
                for key, edges, size in candidates:
                    if key not in selected_keys:
                        remaining.append((key, edges, size))
                
                remaining.sort(key=lambda x: len(x[1]), reverse=True)
                
                # Add top remaining seeds
                num_to_add = max_elites - len(ilp_selected)
                for i in range(min(num_to_add, len(remaining))):
                    ilp_selected.append(remaining[i])
            
        new_elites = {}
        for key, edges, size in ilp_selected:
            new_elites[key] = (list(edges), size)

    end_time = time.time()
    print(f'Selection time: {end_time - start_time:.4f} seconds', file=sys.stderr)
    
    final_output = {}
    for key, (edges, size) in new_elites.items():
        try:
            gen_part, rest = key.split('-', 1)
            if '/' in rest:
                state, filename = rest.split('/', 1)
            else:
                state = "unknown"
                filename = rest
        except ValueError:
             gen_part = "unknown"
             state = "unknown"
             filename = key

        if gen_part not in final_output:
            final_output[gen_part] = {}
        if state not in final_output[gen_part]:
            final_output[gen_part][state] = {}
        
        final_output[gen_part][state][filename] = [edges, size]
        
    with open(output_elite_file, 'w') as f:
        f.write(json.dumps(final_output))
    
    for elite_key, (elite_edges, _) in sorted(new_elites.items(), key=lambda item: (len(item[1][0]), -item[1][1])):
        try:
            parts = elite_key.split('-')
            if len(parts) >= 2:
                gen = parts[0]
                rest = '-'.join(parts[1:])
                if '/' in rest:
                    state, generator = rest.split('/', 1)
                else:
                    state = MODEL
                    generator = rest
            else:
                gen = generation
                state = MODEL
                generator = elite_key
        except:
            print(f'DEBUG: elite_key = {elite_key}', file=sys.stderr, flush=True)
            raise
        # print(f'{len(elite_edges)} {gen} {state} {generator}', flush=True)
    
if __name__ == '__main__':
    main()
