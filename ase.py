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
    T_max: int = 7200         # Maximum epoch (seconds) - 2 hours cap per generation
    T_default: int = 3600     # Default epoch when no history (1 hour)
    T_budget: int = 86400     # Total time budget (24h default)
    tau_stall: int = 300      # Stall tolerance window (5 minutes)
    delta: int = 30           # Monitoring sample interval (seconds)
    alpha: float = 0.2        # EWMA decay factor (slower smoothing = less jumpy)
    beta: float = 0.02        # Growth rate threshold (much lower = harder to trigger early stop)
    gamma: float = 0.15       # LLM evolution boost coefficient
    T_llm_estimate: int = 2400  # Estimated LLM time per gen (40 min, realistic)
    min_fuzzing_ratio: float = 0.5  # At least 50% of budget should be fuzzing time


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
            with open(path, 'r') as f:
                data = json.load(f)
            return cls(
                config=data.get('config', {}),
                history=data.get('history', []),
                total_elapsed=data.get('total_elapsed', 0.0),
                total_fuzz_time=data.get('total_fuzz_time', 0.0),
            )
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

        With dynamic generation count, num_total_gens is used as a HINT
        (max generations), not a hard limit. The actual number of future
        generations is estimated from the remaining budget.

        The algorithm ensures:
        1. Each generation gets at least T_min fuzzing time
        2. Budget is fairly distributed across estimated remaining generations
        3. Historical performance informs but does NOT dominate scheduling
        4. Early-stopped generations do NOT cascade into shorter epochs

        Returns:
            Epoch duration in seconds, clipped to [T_min, T_max].
        """
        cfg = self.cfg
        history = self.state.history

        # --- Dynamic budget-fair allocation ---
        T_remain = max(cfg.T_budget - self.state.total_elapsed, 0)

        # Estimate how many more generations we can run
        gens_left = self._estimate_remaining_gens(gen, num_total_gens)

        # Per-gen cost = LLM + fuzz + overhead; reserve LLM for remaining gens
        T_llm_total = cfg.T_llm_estimate * gens_left
        T_fuzz_remain = max(T_remain - T_llm_total, cfg.T_min * gens_left)

        # Fair share: divide remaining fuzzing budget equally
        T_fair = T_fuzz_remain / gens_left

        if not history:
            # No history: use default (generous first epoch)
            T = max(cfg.T_default, T_fair)
        else:
            # Use history to adjust, but T_fair is the baseline
            T = T_fair

            # Boost if previous generations showed good coverage gains
            recent = history[-1]
            if recent.get('delta_cov', 0) > 0 and recent.get('actual_time', 0) > 0:
                recent_efficiency = recent['delta_cov'] / recent['actual_time']
                avg_efficiency = sum(
                    h.get('delta_cov', 0) / max(h.get('actual_time', 1), 1)
                    for h in history
                ) / len(history)

                # If recent efficiency is above average, give slightly more time
                if recent_efficiency > avg_efficiency * 1.2:
                    T = T * 1.15

            # LLM evolution boost: later generations have evolved seeds
            if gen > 0:
                gens_done = len(history)
                total_est = gens_done + gens_left
                T = T * (1.0 + cfg.gamma * min(gen / max(total_est, 1), 1.0))

            # IMPORTANT: Do NOT reduce time based on early stops
            # (the old algorithm did this, causing the cascade problem)

        T = int(max(cfg.T_min, min(T, cfg.T_max)))

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

        Uses historical average wall-clock time per generation if available,
        otherwise uses T_default + T_llm_estimate as the estimate.
        """
        cfg = self.cfg
        T_remain = max(cfg.T_budget - self.state.total_elapsed, 0)
        history = self.state.history

        if history:
            # Average wall-clock time per generation from actual data
            avg_wall = sum(
                h.get('wall_clock_total', h.get('actual_time', cfg.T_default) + cfg.T_llm_estimate)
                for h in history
            ) / len(history)
        else:
            # First generation: estimate from defaults
            avg_wall = cfg.T_default + cfg.T_llm_estimate

        # Ensure minimum per-gen estimate (T_min + some LLM time)
        avg_wall = max(avg_wall, cfg.T_min + cfg.T_llm_estimate * 0.5)

        gens_left = max(int(T_remain / avg_wall), 1)

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

        # Minimum cost for one more generation
        T_min_gen = cfg.T_min + cfg.T_llm_estimate + 300  # fuzz + LLM + overhead

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
            actual_time: Actual fuzzing time in seconds.
            wall_clock_total: Total wall-clock time for this generation
                              (including LLM, seed selection, etc.).
                              If 0, falls back to actual_time + T_llm_estimate.
        """
        delta = end_cov - start_cov
        was_early = actual_time < (self._current_T * 0.95) if self._current_T > 0 else False
        was_ext = self._extended

        entry = {
            'gen': gen,
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

        # Update total elapsed using actual wall-clock time (not estimate)
        if wall_clock_total > 0:
            self.state.total_elapsed += wall_clock_total
        else:
            self.state.total_elapsed += actual_time + self.cfg.T_llm_estimate

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
        lines.append(f"  Total elapsed: {self.state.total_elapsed:.0f}s "
                      f"/ {self.cfg.T_budget}s budget")
        lines.append(f"  Total fuzz time: {self.state.total_fuzz_time:.0f}s "
                      f"({self.state.total_fuzz_time/max(self.state.total_elapsed,1)*100:.0f}% of elapsed)")
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
    p_predict.add_argument('--T-max', type=int, default=7200)
    p_predict.add_argument('--T-default', type=int, default=3600)

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
