#!/usr/bin/env python3
"""
ase.py - Adaptive Synchronization Epoch (ASE) algorithm for GMPFuzz.

This module computes the optimal epoch duration for each generation's
parallel fuzzing phase, replacing the fixed 1800s timeout.

Design goals:
  1. Ensure sufficient fuzzing time per generation (no premature stopping)
  2. Fairly distribute the total time budget across all generations
  3. Allow dynamic extension when coverage is still growing productively
  4. Track actual wall-clock time (including LLM) for accurate budgeting

Key design decisions:
  - T_min is a HARD floor: no epoch can run less than T_min seconds
  - Early stopping requires BOTH sustained stall AND minimum elapsed time
  - The "budget fairness" guarantee ensures each generation gets at least
    a proportional share of the remaining fuzzing budget
  - total_elapsed tracks real wall-clock time, not just fuzzing time

Usage:
    # At the start of a generation:
    ase = ASEScheduler.load(state_file)
    T_epoch = ase.predict_epoch(gen=2, num_total_gens=5)

    # During fuzzing (called periodically by the monitor):
    action = ase.check(t_elapsed, coverage_readings)
    # action is "continue", "stop", or "extend"

    # After epoch ends:
    ase.record(gen=2, delta_cov=150, actual_time=1200,
               wall_clock_total=2400)
    ase.save(state_file)
"""

import json
import math
import os
import sys
import time
from dataclasses import dataclass, field, asdict
from typing import List, Dict, Optional, Tuple


@dataclass
class ASEConfig:
    """ASE algorithm parameters."""
    T_min: int = 1800         # Minimum epoch (seconds) - 30 min floor for meaningful fuzzing
    T_max: int = 36000        # Maximum epoch (seconds) - 10 hours cap per generation
    T_default: int = 3600     # Default epoch when no history (1 hour)
    T_budget: int = 86400     # Total time budget (24h default)
    tau_stall: int = 300      # Stall tolerance window (5 minutes)
    delta: int = 30           # Monitoring sample interval (seconds)
    alpha: float = 0.2        # EWMA decay factor (slower smoothing = less jumpy)
    beta: float = 0.02        # Growth rate threshold (much lower = harder to trigger early stop)
    gamma: float = 0.15       # LLM evolution boost coefficient
    T_llm_estimate: int = 2400  # Estimated LLM time per gen (40 min, realistic)
    min_fuzzing_ratio: float = 0.5  # At least 50% of budget should be fuzzing time
    T_increment: int = 3600   # Minimum time increment per generation (1 hour)


@dataclass
class ASEHistory:
    """Per-generation history record."""
    gen: int
    delta_cov: float       # Coverage gain (edges)
    actual_time: float     # Actual fuzzing epoch time (seconds)
    start_cov: float       # Coverage at epoch start
    end_cov: float         # Coverage at epoch end
    was_early_stopped: bool
    was_extended: bool
    wall_clock_total: float  # Total wall-clock time for this gen (LLM + fuzz)


@dataclass
class ASEState:
    """Persistent state for ASE across generations."""
    config: dict = field(default_factory=dict)
    history: List[dict] = field(default_factory=list)
    total_elapsed: float = 0.0    # Total wall-clock time consumed (LLM + fuzz)
    total_fuzz_time: float = 0.0  # Total fuzzing-only time consumed

    @classmethod
    def from_file(cls, path: str) -> 'ASEState':
        if os.path.exists(path):
            try:
                with open(path, 'r') as f:
                    content = f.read().strip()
                if not content:
                    return cls()
                data = json.loads(content)
                return cls(
                    config=data.get('config', {}),
                    history=data.get('history', []),
                    total_elapsed=data.get('total_elapsed', 0.0),
                    total_fuzz_time=data.get('total_fuzz_time', 0.0),
                )
            except (json.JSONDecodeError, ValueError, KeyError) as e:
                print(f"[ASE] Warning: corrupted state file {path}, starting fresh: {e}")
                return cls()
        return cls()

    def save(self, path: str):
        os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
        with open(path, 'w') as f:
            json.dump({
                'config': self.config,
                'history': self.history,
                'total_elapsed': self.total_elapsed,
                'total_fuzz_time': self.total_fuzz_time,
            }, f, indent=2)


class ASEScheduler:
    """Adaptive Synchronization Epoch scheduler."""

    def __init__(self, config: Optional[ASEConfig] = None, state: Optional[ASEState] = None):
        self.cfg = config or ASEConfig()
        self.state = state or ASEState()
        # Runtime monitoring state (reset each epoch)
        self._rho_bar: float = 1.0       # Smoothed growth rate
        self._stall_count: int = 0        # Consecutive stall periods
        self._prev_cov: Dict[str, float] = {}  # pool_id -> last coverage reading
        self._current_T: float = 0.0      # Current epoch target
        self._extended: bool = False
        self._extend_count: int = 0       # How many times extended
        self._t_start: float = 0.0
        self._peak_cov: float = 0.0       # Peak coverage seen this epoch
        self._last_improvement_t: float = 0.0  # Last time coverage improved

    @classmethod
    def load(cls, state_file: str, config: Optional[ASEConfig] = None) -> 'ASEScheduler':
        st = ASEState.from_file(state_file)
        cfg = config or ASEConfig()
        # Override config from state if present
        if st.config:
            for k, v in st.config.items():
                if hasattr(cfg, k):
                    setattr(cfg, k, type(getattr(cfg, k))(v))
        return cls(config=cfg, state=st)

    def save(self, state_file: str):
        self.state.config = asdict(self.cfg)
        self.state.save(state_file)

    # ================================================================
    # Phase A: Inter-generation scheduling (predict initial T)
    # ================================================================

    def predict_epoch(self, gen: int, num_total_gens: int = 0) -> int:
        """Predict the optimal epoch duration for generation `gen`.

        Follows TDPFuzz's design: later generations produce more seeds from
        LLM evolution and need progressively more time for thorough fuzzing.
        Each generation's epoch is guaranteed to be at least T_increment
        longer than the previous generation's actual fuzzing time.

        The algorithm uses a triangular-number allocation scheme:
          - gen0 gets weight 1, gen1 gets weight 2, ..., genN gets weight N+1
          - This naturally allocates more time to later generations
          - A hard floor ensures at least prev_time + T_increment per gen

        Returns:
            Epoch duration in seconds, clipped to [T_min, T_max].
        """
        cfg = self.cfg
        history = self.state.history

        # --- Remaining fuzzing budget ---
        T_remain = max(cfg.T_budget - self.state.total_elapsed, 0)

        if not history:
            # First generation: use T_default as the baseline
            T = max(cfg.T_default, cfg.T_min)
        else:
            # --- Monotonic increasing with guaranteed increment ---
            # Get the MAXIMUM epoch time from all previous generations.
            # Use max(actual_time, predicted_epoch) per gen to prevent
            # regression when early-stop causes actual << predicted.
            prev_max_time = max(
                max(h.get('actual_time', cfg.T_min),
                    h.get('predicted_epoch', h.get('actual_time', cfg.T_min)))
                for h in history
            )

            # Hard floor: at least prev_max_time + T_increment
            T_floor = prev_max_time + cfg.T_increment

            # --- Triangular budget-proportional allocation ---
            # Weight for each generation = gen_index + 1
            # This gives later generations proportionally more time
            gens_left = self._estimate_remaining_gens(gen, num_total_gens)
            total_future_gens = gens_left  # including current gen

            # Triangular weight for current gen relative to remaining gens
            # Current gen is the first of the remaining, so weight = gen + 1
            current_weight = gen + 1
            # Sum of weights for all remaining gens: sum(gen+1 .. gen+gens_left)
            total_weight = sum(range(gen + 1, gen + 1 + total_future_gens))
            total_weight = max(total_weight, 1)

            T_proportional = T_remain * (current_weight / total_weight)

            # Take the maximum of proportional allocation and the increment floor
            T = max(T_proportional, T_floor)

            # Coverage efficiency boost: if recent gen was highly productive,
            # give extra time
            recent = history[-1]
            if recent.get('delta_cov', 0) > 0 and recent.get('actual_time', 0) > 0:
                recent_efficiency = recent['delta_cov'] / recent['actual_time']
                avg_efficiency = sum(
                    h.get('delta_cov', 0) / max(h.get('actual_time', 1), 1)
                    for h in history
                ) / len(history)

                if recent_efficiency > avg_efficiency * 1.2:
                    T = T * 1.1

        # Final clipping: T_min floor and T_max cap
        # Also ensure we don't exceed remaining budget
        T = int(max(cfg.T_min, min(T, cfg.T_max, T_remain)))

        # FINAL SAFETY: enforce monotonic increase over previous gen
        # Even after clipping, T must be > prev_max_time (if budget allows)
        if history:
            prev_max_time = max(
                max(h.get('actual_time', cfg.T_min),
                    h.get('predicted_epoch', h.get('actual_time', cfg.T_min)))
                for h in history
            )
            min_required = prev_max_time + cfg.T_increment
            if T < min_required and T_remain >= min_required:
                T = int(min(min_required, cfg.T_max, T_remain))

        # Store for monitoring phase
        self._current_T = T
        self._rho_bar = 1.0
        self._stall_count = 0
        self._prev_cov = {}
        self._extended = False
        self._extend_count = 0
        self._t_start = time.time()
        self._peak_cov = 0.0
        self._last_improvement_t = 0.0

        return T

    def _estimate_remaining_gens(self, current_gen: int, max_gens: int = 0) -> int:
        """Estimate how many more generations can fit in the remaining budget.

        Accounts for the increasing time per generation: each future gen
        will need at least T_increment more than the previous one.
        Uses a triangular-sum approach to estimate how many generations
        can fit in the remaining budget.
        """
        cfg = self.cfg
        T_remain = max(cfg.T_budget - self.state.total_elapsed, 0)
        history = self.state.history

        # Determine the baseline time for the next generation
        if history:
            prev_max_time = max(
                max(h.get('actual_time', cfg.T_min),
                    h.get('predicted_epoch', h.get('actual_time', cfg.T_min)))
                for h in history
            )
            next_base = prev_max_time + cfg.T_increment
        else:
            next_base = cfg.T_default

        next_base = max(next_base, cfg.T_min)

        # Count how many generations fit with increasing time:
        # gen_k needs next_base + k * T_increment seconds
        # Total for N gens = N * next_base + T_increment * N*(N-1)/2
        gens_left = 0
        cumulative = 0.0
        for k in range(100):  # safety upper bound
            t_gen = next_base + k * cfg.T_increment
            if cumulative + t_gen > T_remain:
                break
            cumulative += t_gen
            gens_left += 1

        gens_left = max(gens_left, 1)

        # Apply max_gens cap if specified (remaining from max)
        if max_gens > 0:
            gens_cap = max(max_gens - current_gen, 1)
            gens_left = min(gens_left, gens_cap)

        return gens_left

    def should_continue(self, current_gen: int, max_gens: int = 0) -> bool:
        """Decide whether there is enough budget to run another generation.

        Returns True if the remaining budget can accommodate at least:
        - One LLM phase (T_llm_estimate)
        - One fuzzing phase (T_min)
        - Some overhead (300s)

        Also respects max_gens as a hard upper limit if > 0.

        Args:
            current_gen: The generation number that JUST completed.
            max_gens: Hard upper limit on generation count (0 = unlimited).

        Returns:
            True if another generation should be started.
        """
        cfg = self.cfg

        # Hard cap on generations
        if max_gens > 0 and (current_gen + 1) >= max_gens:
            return False

        T_remain = max(cfg.T_budget - self.state.total_elapsed, 0)

        # Minimum cost for one more generation: must be at least
        # prev_max_time + T_increment (monotonic increasing requirement)
        history = self.state.history
        if history:
            prev_max_time = max(
                max(h.get('actual_time', cfg.T_min),
                    h.get('predicted_epoch', h.get('actual_time', cfg.T_min)))
                for h in history
            )
            T_min_gen = prev_max_time + cfg.T_increment + 300
            # Also check: if the required epoch exceeds T_max, we can no
            # longer guarantee monotonic increase, so stop.
            if prev_max_time + cfg.T_increment > cfg.T_max:
                return False
        else:
            T_min_gen = cfg.T_min + 300  # fuzz floor + overhead

        return T_remain >= T_min_gen

    # ================================================================
    # Phase B: Intra-generation monitoring (early stop / extend)
    # ================================================================

    def check(self, t_elapsed: float, pool_coverages: Dict[str, float]) -> str:
        """Check whether to continue, stop early, or extend the current epoch.

        Early stop conditions (ALL must be true):
          1. t_elapsed >= T_min (hard floor, no early stop before this)
          2. t_elapsed >= 0.6 * current_T (at least 60% of predicted time)
          3. Sustained stall: no coverage improvement for tau_stall seconds
          4. Growth rate rho_bar < beta for sustained period

        Extension conditions:
          - t_elapsed >= 0.85 * current_T AND still productive
          - Can extend multiple times up to T_max

        Args:
            t_elapsed: Seconds elapsed since epoch start.
            pool_coverages: {pool_id: current_edge_count} for each container.

        Returns:
            "continue" - keep running
            "stop"     - early termination (truly saturated)
            "extend"   - epoch limit reached but still productive
        """
        cfg = self.cfg

        if not pool_coverages:
            return "continue"

        # Compute per-pool growth rate
        total_cov = sum(pool_coverages.values())
        rho_max = 0.0
        any_improved = False

        for pool_id, cov in pool_coverages.items():
            prev = self._prev_cov.get(pool_id, cov)
            if prev > 0:
                rho = (cov - prev) / (prev + 1e-9)
            else:
                rho = 1.0 if cov > 0 else 0.0
            rho_max = max(rho_max, rho)

            if cov > prev:
                any_improved = True

        # Track peak coverage and last improvement time
        if total_cov > self._peak_cov:
            self._peak_cov = total_cov
            self._last_improvement_t = t_elapsed

        # Update previous readings
        self._prev_cov = dict(pool_coverages)

        # EWMA smoothing (slower alpha = less reactive to noise)
        self._rho_bar = cfg.alpha * rho_max + (1.0 - cfg.alpha) * self._rho_bar

        # --- Early stop: much stricter conditions ---
        # Must satisfy ALL conditions:
        #   1. Past T_min (hard floor)
        #   2. Past 60% of predicted time
        #   3. Growth rate below threshold for sustained period
        #   4. No coverage improvement for tau_stall seconds
        can_early_stop = (
            t_elapsed >= cfg.T_min and
            t_elapsed >= 0.6 * self._current_T
        )

        if can_early_stop:
            time_since_improvement = t_elapsed - self._last_improvement_t

            if self._rho_bar < cfg.beta and time_since_improvement >= cfg.tau_stall:
                self._stall_count += 1
                stall_threshold = math.ceil(cfg.tau_stall / cfg.delta)
                if self._stall_count >= stall_threshold:
                    return "stop"
            elif any_improved:
                # Reset stall counter on any improvement
                self._stall_count = 0

        # --- Dynamic extension: can extend multiple times ---
        if t_elapsed >= 0.85 * self._current_T and self._current_T < cfg.T_max:
            if self._rho_bar > cfg.beta or any_improved:
                # Still productive: extend
                extension = min(cfg.tau_stall, cfg.T_max - self._current_T)
                if extension > 0:
                    self._current_T += extension
                    self._extended = True
                    self._extend_count += 1
                    return "extend"

        return "continue"

    def get_current_epoch_limit(self) -> float:
        """Return the current (possibly extended) epoch time limit."""
        return self._current_T

    # ================================================================
    # Phase C: History update
    # ================================================================

    def record(self, gen: int, start_cov: float, end_cov: float,
               actual_time: float, wall_clock_total: float = 0.0):
        """Record the results of a completed epoch.

        Args:
            gen: Generation number.
            start_cov: Coverage at epoch start.
            end_cov: Coverage at epoch end.
            actual_time: Actual fuzzing time in seconds (aflnet only).
            wall_clock_total: Total wall-clock time for this generation
                              (including LLM, seed selection, etc.).
                              Stored for reference but NOT used for budget
                              accounting; budget is tracked by fuzzing time only.
        """
        delta = end_cov - start_cov
        was_early = actual_time < (self._current_T * 0.95) if self._current_T > 0 else False
        was_ext = self._extended

        entry = {
            'gen': gen,
            'predicted_epoch': self._current_T,  # Save predicted T for monotonic floor
            'delta_cov': delta,
            'actual_time': actual_time,
            'start_cov': start_cov,
            'end_cov': end_cov,
            'was_early_stopped': was_early,
            'was_extended': was_ext,
            'extend_count': self._extend_count,
            'wall_clock_total': wall_clock_total if wall_clock_total > 0
                                else actual_time + self.cfg.T_llm_estimate,
        }
        self.state.history.append(entry)

        # Budget accounting: only count actual aflnet fuzzing time.
        # LLM / seed-selection time is excluded so it does not consume
        # the fuzzing budget.
        self.state.total_elapsed += actual_time
        self.state.total_fuzz_time += actual_time

    def get_summary(self) -> str:
        """Return a human-readable summary of ASE history."""
        lines = ["ASE History:"]
        for h in self.state.history:
            flags = []
            if h.get('was_early_stopped'):
                flags.append("EARLY")
            if h.get('was_extended'):
                flags.append(f"EXT*{h.get('extend_count', 1)}")
            flag_str = f" [{','.join(flags)}]" if flags else ""
            lines.append(
                f"  gen{h['gen']}: T={h['actual_time']:.0f}s, "
                f"cov={h['start_cov']:.0f}->{h['end_cov']:.0f} "
                f"(+{h['delta_cov']:.0f}){flag_str}"
            )
        if not self.state.history:
            lines.append("  (no history)")
        lines.append(f"  Total fuzz budget used: {self.state.total_elapsed:.0f}s "
                      f"/ {self.cfg.T_budget}s budget")
        lines.append(f"  Total fuzz time: {self.state.total_fuzz_time:.0f}s "
                      f"(LLM time excluded from budget accounting)")
        return "\n".join(lines)


# ================================================================
# CLI interface for testing
# ================================================================
if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='ASE Scheduler CLI')
    sub = parser.add_subparsers(dest='cmd')

    p_predict = sub.add_parser('predict', help='Predict epoch for a generation')
    p_predict.add_argument('--gen', type=int, required=True)
    p_predict.add_argument('--total-gens', type=int, required=True)
    p_predict.add_argument('--state-file', type=str, default='ase_state.json')
    p_predict.add_argument('--T-budget', type=int, default=86400)
    p_predict.add_argument('--T-min', type=int, default=1800)
    p_predict.add_argument('--T-max', type=int, default=36000)
    p_predict.add_argument('--T-default', type=int, default=3600)
    p_predict.add_argument('--T-increment', type=int, default=3600)

    p_record = sub.add_parser('record', help='Record epoch results')
    p_record.add_argument('--gen', type=int, required=True)
    p_record.add_argument('--start-cov', type=float, required=True)
    p_record.add_argument('--end-cov', type=float, required=True)
    p_record.add_argument('--actual-time', type=float, required=True)
    p_record.add_argument('--wall-clock', type=float, default=0.0)
    p_record.add_argument('--state-file', type=str, default='ase_state.json')

    p_continue = sub.add_parser('should-continue', help='Check if another generation should run')
    p_continue.add_argument('--current-gen', type=int, required=True)
    p_continue.add_argument('--max-gens', type=int, default=0)
    p_continue.add_argument('--state-file', type=str, default='ase_state.json')

    p_summary = sub.add_parser('summary', help='Print ASE history summary')
    p_summary.add_argument('--state-file', type=str, default='ase_state.json')

    args = parser.parse_args()

    if args.cmd == 'predict':
        cfg = ASEConfig(
            T_budget=args.T_budget,
            T_min=args.T_min,
            T_max=args.T_max,
            T_default=args.T_default,
            T_increment=args.T_increment,
        )
        ase = ASEScheduler.load(args.state_file, config=cfg)
        T = ase.predict_epoch(gen=args.gen, num_total_gens=args.total_gens)
        ase.save(args.state_file)
        print(T)

    elif args.cmd == 'record':
        ase = ASEScheduler.load(args.state_file)
        ase.record(
            gen=args.gen,
            start_cov=args.start_cov,
            end_cov=args.end_cov,
            actual_time=args.actual_time,
            wall_clock_total=args.wall_clock,
        )
        ase.save(args.state_file)
        print(ase.get_summary())

    elif args.cmd == 'should-continue':
        ase = ASEScheduler.load(args.state_file)
        result = ase.should_continue(
            current_gen=args.current_gen,
            max_gens=args.max_gens,
        )
        T_remain = max(ase.cfg.T_budget - ase.state.total_elapsed, 0)
        print(f"# Remaining budget: {T_remain:.0f}s ({T_remain/3600:.1f}h), "
              f"completed gens: {len(ase.state.history)}")
        if result:
            print("CONTINUE")
        else:
            print("STOP")
        # Exit code: 0 = continue, 1 = stop (for shell scripting)
        sys.exit(0 if result else 1)

    elif args.cmd == 'summary':
        ase = ASEScheduler.load(args.state_file)
        print(ase.get_summary())

    else:
        parser.print_help()
