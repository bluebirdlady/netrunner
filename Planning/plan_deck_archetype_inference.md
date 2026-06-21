# Plan: Deck Archetype Inference for AI Strategy Adaptation

## Goal

Allow the AI to examine the contents of its own deck at game start and infer which strategic archetype it belongs to, then activate archetype-appropriate parameter presets rather than using a single global weight set for all decks.

## Motivation

A single weight configuration is a compromise. A Glacier Corp (ice-heavy, score-behind-barriers) should value early ice placement even more than average. A Fast Advance Corp (rush, never install remotes unprotected) should weight tempo and click efficiency above ice. A Kill Corp (Boom!/HHN package) should weight tag delivery and flatline threat. These require different evaluator behaviors that a single parameter set cannot simultaneously optimize.

The same applies to Runner: Anarch aggression vs. Criminal econ-tempo vs. Shaper rig-building have distinct strategic priorities.

## External Work Integration

You have been running cluster analysis of NetrunnerDB decks using card co-occurrence patterns. This work provides:
1. **Archetype cluster centroids** — a vector of card frequencies for each discovered archetype
2. **Text descriptions** — derived from deck descriptions via a language model, giving human-readable names to the clusters (e.g., "Prison Asset Spam", "Glacier HB", "Fast Advance NBN", "Tag & Bag")
3. **Archetype membership function** — given a deck's card vector, return the probability of belonging to each archetype

The integration point is: at game start, call the membership function with the AI's deck list → get an archetype label (or a soft distribution) → load the corresponding parameter preset.

## Archetype Taxonomy (starting point)

### Corp Archetypes
| Label | Key indicators | AI priority shift |
|-------|----------------|-------------------|
| Glacier | High ice count (15+), low agenda density | Ice centrals earlier, higher bare-central penalty |
| Fast Advance | Biotic Labor / SanSan / audacity cards | Score windows > ice; higher tempo value |
| Asset Spam | Multiple asset types, Jackson Howard equivalents | Remote economy; lower score urgency |
| Kill / Flatline | Boom!, HHN, Punitive, Scorched Earth | Tag delivery value; force runner economy denial |
| Rush | Many cheap ice, 3/2 agendas | Early scoring windows; deprioritize late ice |

### Runner Archetypes
| Label | Key indicators | AI priority shift |
|-------|----------------|-------------------|
| Aggressive / Criminal | Low install count, high econ events | Run early and often; credits above programs |
| Tempo / Shaper | Medium rig, tutors | Rig-complete before pressuring; value installs |
| Anarch Virus | Virus cards, Imp, Wanton | Pressure remotes fast; use virus counters as tempo |
| Tag-me | High link or tag-removal, I've Had Worse | Ignore tag penalty; maximize access count |
| Big Rig | High MU, Endless Hunger / Femme | Build complete rig before running; value memory |

## Implementation Design

### Step 1 — In-engine archetype classifier (GDScript)

A lightweight classifier that runs at the start of each AI turn (or once at game start):

```gdscript
class_name DeckArchetypeClassifier
static func classify(deck_ids: Array, ab_reg: AbilityRegistry) -> String:
    # Returns an archetype label string, e.g. "glacier", "fast_advance", "kill"
    # Uses a simple feature-vector dot-product against hardcoded centroid vectors.
    # Centroid vectors are derived offline from the NetrunnerDB cluster analysis
    # and baked in as constants.
```

For the initial version, a rules-based approach is sufficient:
- Count cards belonging to tagged subgroups (e.g., cards with `cost_advancement_counters` → advancement archetype)
- Count ice pieces → glacier indicator
- Check for known kill-package cards (boom, hhn, punitive) → kill indicator
- Assign the label whose indicator score is highest

Later this can be replaced with a dot-product against learned centroids from the external clustering work.

### Step 2 — Archetype parameter presets

A dictionary in CorpStateEvaluator (and RunnerStateEvaluator) that maps archetype label → weight overrides:

```gdscript
const ARCHETYPE_OVERRIDES: Dictionary = {
    "glacier": {
        "rd_bare_central_penalty": 14.0,  # even stronger ice urgency
        "hq_bare_central_penalty": 9.0,
        "phase_econ_mult":         1.1,   # economy slightly less dominant
    },
    "fast_advance": {
        "rd_bare_central_penalty": 5.0,   # don't overinvest in ice
        "phase_score_mult":        1.4,   # score windows more valuable
    },
    "kill": {
        "tag_delivery_value":      25.0,  # new weight for tagging the runner
        "rd_bare_central_penalty": 7.0,
    },
}
```

These are applied after the base constants are loaded, so the evolutionary tuner (see plan_evolutionary_ai_tuner.md) can still optimize the base values and the overrides are relative deltas.

### Step 3 — Activation at game start

In SelfPlayRunner (and eventually in the live campaign brain), after the deck is built:

```gdscript
var archetype: String = DeckArchetypeClassifier.classify(_corp_deck_ids, ab_reg)
corp_brain._evaluator.set_archetype(archetype)
```

`set_archetype()` merges the override dict into the evaluator's live constants.

## Integration with External Clustering Work

The NetrunnerDB cluster centroids can be exported as a JSON file (e.g., `Data/archetype_centroids.json`) with structure:

```json
{
  "corp": {
    "glacier":      { "barrier_ice_count_norm": 0.42, "agenda_density_norm": 0.18, ... },
    "fast_advance": { "advance_operation_count_norm": 0.35, ... }
  },
  "runner": { ... }
}
```

The GDScript classifier loads this file and computes cosine similarity between the deck's feature vector and each centroid. The highest-similarity label wins (or a soft mixture can be used if the margin is low).

Text descriptions from the language model can be stored as a `"description"` field in the same JSON, making it easy to expose archetype names in UI or logging.

## Relationship to Evolutionary Tuner

The two plans compose naturally:
1. First run the evolutionary tuner (plan_evolutionary_ai_tuner.md) with a generic deck → get globally-optimal base weights
2. Then run the tuner separately per archetype matchup with the base weights locked → get archetype-specific deltas
3. The archetype deltas tend to be small (±20–30% of the base values), so the search space for step 2 is much smaller

## Phasing

| Phase | What to build | Prerequisite |
|-------|--------------|--------------|
| 0 | Rules-based classifier (card-count heuristics) | Nothing; ship now |
| 1 | Hardcoded archetype override presets | Phase 0; manual tuning |
| 2 | Load centroids from external JSON; cosine similarity classifier | External clustering export |
| 3 | Evolutionary tuning of per-archetype overrides | plan_evolutionary_ai_tuner.md Phase A complete |
| 4 | Soft mixture (weighted sum of archetypes) when margin < threshold | Phase 3 |
