# Plan: Evolutionary AI Parameter Tuner

## Goal

Replace manual trial-and-error weight tuning with an automated evolutionary harness that explores the multidimensional space of AI evaluation parameters (and optionally deck compositions) to converge on a balanced, competent configuration.

## The Problem with Manual Tuning

The current evaluator has ~20 named weight constants (phase_econ_mult, bare-central penalty, breaker values, MCTS iterations, tag penalty, ...). Each change to one shifts the equilibrium in ways that interact with all others. Manual binary search across a 20-D space is both slow and brittle. An evolutionary search can explore thousands of configurations overnight on a dedicated machine.

## Chromosome: What Gets Evolved

### Tier 1 — High-impact, tune first
Corp evaluator weights:
- phase_econ_mult (early game economy multiplier, currently 1.3)
- rd_bare_central_penalty (currently 10.0)
- hq_bare_central_penalty (currently 6.0)
- breached_server_1ice_penalty (currently 15.0)
- breached_server_multi_ice_penalty (currently 6.0)
- proven_access_prob_boost (currently 0.20)
- agenda_density_threshold (when Corp treats agenda presence as urgent)

Runner evaluator weights:
- BREAKER_VALUE (currently 40.0)
- UNCOVERED_ICE_COST (currently 25.0)
- CREDIT_SURPLUS_VAL (currently 2.0)
- GRIP_SURPLUS_VAL (currently 3.0)
- CENTRAL_RUN_VALUE (currently 12.0)
- tag_penalty_per_tag (currently 20.0)

Search parameters:
- MCTS iterations (currently 100)
- RunnerTurnPlanner beam_width (currently 5)

### Tier 2 — Optional, add later
- Deck composition (which 45/49 cards to include from a card pool)
- Per-archetype weight offsets (see plan_deck_archetype_inference.md)

## Fitness Function

Primary objective: **Win rate for a given AI**. Since both AIs will be competing, optimizing individual win rate will tend to improve both sides and work toward balance while improving both the Corp and Runner AIs individually. In real gameplay, humans will play against one or the other, so balance per se is not the goal; competence is.

```
fitness = this_model_win_rate                # competence
        - 0.1 * abs(avg_turns - 14.0)        # reasonable game length
        - 0.05 * flatline_rate               # low flatlines = more strategic games
```

Evaluated over N self-play games (suggest N=30 per evaluation for reasonable signal).

## Architecture

### Option A — Pure Python driver (recommended for first pass)
A Python script (`tuner/evolutionary_tuner.py`) that:
1. Reads a JSON config specifying the chromosome bounds and starting values
2. Generates a candidate config dict (the chromosome)
3. Writes it to a temp JSON file (`tuner/current_weights.json`)
4. Calls Godot headless: `godot -- --batch 30 --weights tuner/current_weights.json`
5. Parses stdout for `Corp wins: X / Runner wins: Y / Avg turns: Z`
6. Computes fitness; feeds back to the optimizer

SelfPlayRunner would need a `--weights <path>` flag that reads the JSON and overrides the named constants before running.

### Option B — GDScript in-process harness
A dedicated Godot scene that runs N batches with different weight configs in sequence (no subprocess), writing results to a CSV. Faster per evaluation but harder to integrate with an external optimizer library.

**Recommendation**: Option A. Python has mature optimization libraries (CMA-ES via `pycma`, Bayesian optimization via `scikit-optimize` or `optuna`) and the subprocess overhead is negligible compared to batch game time.

## Optimization Algorithm

**CMA-ES** (Covariance Matrix Adaptation Evolution Strategy) is the right tool:
- Handles 15–25 continuous parameters well
- Self-adapts step sizes; no learning-rate tuning needed
- Converges in O(10 * D^2) evaluations where D = parameter count; ~2250 evals for 15 params
- Available as `pip install cma`

Alternative: **Optuna TPE** (Tree-structured Parzen Estimator) — easier to add constraints and categorical parameters, better for mixed spaces if deck composition is included.

## Practical Schedule (on a dedicated machine)

Assumptions:
- 30-game batch = ~90 seconds on a mid-range CPU
- 2250 CMA-ES evaluations = ~56 hours of continuous runtime
- Can run overnight for ~3 nights to get a full sweep

Practical approach:
1. Start with Tier 1 weights only (13 params → ~1690 evals → ~42 hours)
2. Lock in converged Tier 1 results
3. Add MCTS/beam params for Tier 2 sweep

## Implementation Steps

1. **SelfPlayRunner**: Add `--weights <json_path>` argument parsing; load and override named constants at startup before running the batch
2. **tuner/evolutionary_tuner.py**: Implement the subprocess driver and CMA-ES loop; write best-seen config to `tuner/best_weights.json` on each improvement
3. **Logging**: Tuner appends one line per evaluation to `tuner/tuner_log.csv` (generation, params, fitness) for visualization
4. **Transfer**: When a good config is found, manually copy the values back into the GDScript constants and run a final 100-game confirmation batch

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Overfitting to one matchup | Run fitness eval across 2–3 different deck pairs; use weighted average |
| Local optima | CMA-ES is robust to this at 15 params; also try multiple random restarts |
| Parameter drift makes the game "boring" | Add the competence-floor constraint to fitness |
| Godot process leaks between evaluations | Add a watchdog timeout; kill and restart if a batch exceeds 3× expected time |
