#!/usr/bin/env python3
"""
evolutionary_tuner.py — CMA-ES harness for Netrunner AI weight optimisation.

Usage:
    python evolutionary_tuner.py --side corp   [options]
    python evolutionary_tuner.py --side runner [options]

Options:
    --side      {corp|runner}     Which AI's weights to optimise (required)
    --games     N                 Games per fitness evaluation (default: 30)
    --config    path              Path to weights_config.json (default: weights_config.json)
    --godot     path              Path to Godot executable (default: godot)
    --project   path              Path to Godot project root (default: ..)
    --log       path              CSV log output (default: tuner_log.csv)
    --best      path              Best weights JSON output (default: best_weights.json)
    --seed      N                 Random seed for reproducibility (default: 42)
    --restarts  N                 CMA-ES restarts (default: 1)

The fitness function (higher = better):
    fitness = this_side_win_rate
            - 0.1 * abs(avg_turns - 14.0)
            - 0.05 * flatline_rate

Optimised weights are written to best_weights.json on each improvement
and can be passed back to Godot via --weights tuner/best_weights.json.
"""

import argparse
import csv
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

try:
    import cma
except ImportError:
    sys.exit("ERROR: pycma not installed. Run: pip install cma")


# ── Constants ─────────────────────────────────────────────────────────────────

TARGET_AVG_TURNS = 14.0
AVG_TURNS_WEIGHT = 0.1
FLATLINE_WEIGHT  = 0.05
GODOT_TIMEOUT    = 600   # seconds — kill batch if it exceeds this


# ── Godot subprocess driver ───────────────────────────────────────────────────

def run_batch(godot: str, project: str, weights_path: str,
              matchup: dict, games: int) -> dict | None:
    """
    Run one self-play batch and return parsed stats, or None on failure.
    Returns: {corp_wins, runner_wins, total, avg_turns, flatlines}
    """
    args = [
        godot,
        "--path", project,
        "--headless",
        "res://Scenes/SelfPlay.tscn",
        "--",
        "--batch", str(games),
        "--corp-opponent",   matchup["corp"],
        "--runner-opponent", matchup["runner"],
        "--weights",         weights_path,
    ]
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=GODOT_TIMEOUT,
        )
        stdout = (result.stdout or "") + (result.stderr or "")
    except subprocess.TimeoutExpired:
        print("  [WARN] Godot batch timed out — skipping")
        return None
    except FileNotFoundError:
        sys.exit(f"ERROR: Godot executable not found: {godot!r}")

    return _parse_batch_output(stdout, games)


def _parse_batch_output(text: str, expected_games: int) -> dict | None:
    corp_wins   = _extract_int(r"Corp\s+wins\s*:\s*(\d+)", text)
    runner_wins = _extract_int(r"Runner\s+wins\s*:\s*(\d+)", text)
    avg_turns   = _extract_float(r"Avg\s+turns\s*:\s*([\d.]+)", text)
    flatlines   = len(re.findall(r"flatlined", text, re.IGNORECASE))

    if corp_wins is None or runner_wins is None or avg_turns is None:
        print("  [WARN] Could not parse batch output")
        return None

    total = corp_wins + runner_wins
    if total == 0:
        return None

    return {
        "corp_wins":   corp_wins,
        "runner_wins": runner_wins,
        "total":       total,
        "avg_turns":   avg_turns,
        "flatlines":   flatlines,
    }


def _extract_int(pattern: str, text: str) -> int | None:
    m = re.search(pattern, text)
    return int(m.group(1)) if m else None


def _extract_float(pattern: str, text: str) -> float | None:
    m = re.search(pattern, text)
    return float(m.group(1)) if m else None


# ── Fitness function ──────────────────────────────────────────────────────────

def compute_fitness(stats_list: list[dict], side: str) -> float:
    """
    Aggregate fitness across all matchups.
    side: 'corp' or 'runner' — determines which win rate is the primary objective.
    """
    if not stats_list:
        return -1000.0

    total_games      = 0
    weighted_wr      = 0.0
    weighted_turns   = 0.0
    weighted_flatline = 0.0

    for stats in stats_list:
        n = stats["total"]
        if n == 0:
            continue
        win_count = stats["corp_wins"] if side == "corp" else stats["runner_wins"]
        wr        = win_count / n
        flatline_rate = stats["flatlines"] / n

        weighted_wr       += wr * n
        weighted_turns    += stats["avg_turns"] * n
        weighted_flatline += flatline_rate * n
        total_games       += n

    if total_games == 0:
        return -1000.0

    avg_wr       = weighted_wr       / total_games
    avg_turns    = weighted_turns    / total_games
    avg_flatline = weighted_flatline / total_games

    fitness = (avg_wr
               - AVG_TURNS_WEIGHT * abs(avg_turns - TARGET_AVG_TURNS)
               - FLATLINE_WEIGHT  * avg_flatline)
    return fitness


# ── Chromosome helpers ────────────────────────────────────────────────────────

def build_chromosome(config: dict, side: str) -> tuple[list[str], list[float], list[float], list[float], list[float]]:
    """Return (names, x0, lo, hi, sigmas) for the given side."""
    params = config[side]
    names  = list(params.keys())
    x0     = [params[k]["initial"] for k in names]
    lo     = [params[k]["lo"]      for k in names]
    hi     = [params[k]["hi"]      for k in names]
    sigmas = [params[k]["sigma"]   for k in names]
    return names, x0, lo, hi, sigmas


def clamp_vector(x: list[float], lo: list[float], hi: list[float]) -> list[float]:
    return [max(lo[i], min(hi[i], x[i])) for i in range(len(x))]


def vector_to_weights(names: list[str], x: list[float]) -> dict:
    return {k: v for k, v in zip(names, x)}


# ── CSV logger ────────────────────────────────────────────────────────────────

class TunerLogger:
    def __init__(self, path: str, names: list[str]):
        self.path   = path
        self.names  = names
        self._count = 0
        with open(path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["eval", "fitness", "corp_wr", "runner_wr", "avg_turns", "flatline_rate"] + names)

    def log(self, fitness: float, stats_list: list[dict], x: list[float]) -> None:
        self._count += 1
        total = sum(s["total"] for s in stats_list) or 1
        corp_wr   = sum(s["corp_wins"]   for s in stats_list) / total
        runner_wr = sum(s["runner_wins"] for s in stats_list) / total
        avg_turns = sum(s["avg_turns"] * s["total"] for s in stats_list) / total
        flat_rate = sum(s["flatlines"]   for s in stats_list) / total
        with open(self.path, "a", newline="") as f:
            writer = csv.writer(f)
            writer.writerow([self._count, f"{fitness:.4f}",
                             f"{corp_wr:.3f}", f"{runner_wr:.3f}",
                             f"{avg_turns:.1f}", f"{flat_rate:.3f}"]
                            + [f"{v:.4f}" for v in x])


# ── Main optimisation loop ────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="CMA-ES tuner for Netrunner AI weights")
    parser.add_argument("--side",    required=True, choices=["corp", "runner"])
    parser.add_argument("--games",   type=int,   default=30)
    parser.add_argument("--config",  default=str(Path(__file__).parent / "weights_config.json"))
    parser.add_argument("--godot",   default="godot")
    parser.add_argument("--project", default=str(Path(__file__).parent.parent))
    parser.add_argument("--log",     default=str(Path(__file__).parent / "tuner_log.csv"))
    parser.add_argument("--best",    default=str(Path(__file__).parent / "best_weights.json"))
    parser.add_argument("--seed",    type=int, default=42)
    parser.add_argument("--restarts",type=int, default=1)
    args = parser.parse_args()

    with open(args.config) as f:
        config = json.load(f)

    matchups = config.get("matchups", [])
    if not matchups:
        sys.exit("ERROR: no matchups defined in weights_config.json")

    names, x0, lo, hi, sigmas = build_chromosome(config, args.side)
    sigma0 = sum(sigmas) / len(sigmas)   # mean initial step size

    print(f"Optimising {args.side} weights ({len(names)} params) across {len(matchups)} matchup(s)")
    print(f"Games per eval: {args.games}  |  Initial sigma: {sigma0:.3f}")
    print(f"Params: {names}")

    logger      = TunerLogger(args.log, names)
    best_fitness = -1e9
    best_x       = list(x0)
    weights_tmp  = str(Path(__file__).parent / "_current_weights.json")
    eval_count   = 0

    for restart in range(args.restarts):
        if restart > 0:
            print(f"\n--- Restart {restart + 1} ---")
            # Perturb the best known solution as the new start point
            import random
            random.seed(args.seed + restart)
            x0 = [b + random.gauss(0, s * 0.5) for b, s in zip(best_x, sigmas)]
            x0 = clamp_vector(x0, lo, hi)

        opts = cma.CMAOptions()
        opts["seed"]      = args.seed + restart
        opts["verbose"]   = 1
        opts["tolx"]      = 1e-4
        opts["tolfun"]    = 1e-4
        opts["maxfevals"] = 5000

        es = cma.CMAEvolutionStrategy(x0, sigma0, opts)

        while not es.stop():
            solutions = es.ask()

            fitnesses = []
            for x in solutions:
                x_clamped = clamp_vector(x, lo, hi)
                weights   = vector_to_weights(names, x_clamped)

                with open(weights_tmp, "w") as f:
                    json.dump(weights, f, indent=2)

                stats_list = []
                for matchup in matchups:
                    stats = run_batch(args.godot, args.project, weights_tmp, matchup, args.games)
                    if stats:
                        stats_list.append(stats)

                fitness = compute_fitness(stats_list, args.side)
                fitnesses.append(-fitness)   # CMA-ES minimises; negate for maximisation

                eval_count += 1
                logger.log(fitness, stats_list or [{"total":0,"corp_wins":0,"runner_wins":0,"avg_turns":0,"flatlines":0}], x_clamped)

                if fitness > best_fitness:
                    best_fitness = fitness
                    best_x       = list(x_clamped)
                    with open(args.best, "w") as f:
                        json.dump(weights, f, indent=2)
                    print(f"  [eval {eval_count}] NEW BEST fitness={fitness:.4f}  weights={weights}")
                else:
                    print(f"  [eval {eval_count}] fitness={fitness:.4f}  (best={best_fitness:.4f})")

            es.tell(solutions, fitnesses)
            es.disp()

        print(f"\nRestart {restart + 1} converged after {eval_count} evaluations")
        print(f"Best fitness: {best_fitness:.4f}")
        print(f"Best weights written to: {args.best}")

    print("\n=== Optimisation complete ===")
    print(f"Total evaluations: {eval_count}")
    print(f"Best fitness:      {best_fitness:.4f}")
    print(f"Best weights:      {args.best}")


if __name__ == "__main__":
    main()
