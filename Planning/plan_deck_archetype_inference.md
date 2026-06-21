# Plan: Deck Archetype Inference for AI Strategy Adaptation

*Updated 2026-06-21 after cluster analysis completion. Supersedes the earlier draft.*

---

## Goal

Allow each AI brain to examine its own deck at game start, classify itself into a strategic archetype using the pre-built cluster models, and then activate archetype-appropriate weight presets on top of the globally-tuned base weights.

---

## Motivation

A single weight configuration is a compromise. Concrete examples from the cluster analysis:

- **Thule Kill (HB C5)** and **Reality Plus Tags (NBN C8)** need to value tag delivery and kill-threat windows highly — but the base Corp weights optimise for generic scoring.
- **Esa Mill (Anarch C1)** should weight R&D runs and virus counter maintenance far above breaker value — but the base Runner weights treat all servers roughly equally.
- **Arissana ICE-Destroy (Shaper C3)** improves its run cost over time by permanently removing ICE; the AI should re-evaluate run profitability more aggressively as the game progresses.
- **Ob Fast-Advance (Weyland C4)** benefits from chained installs (Descent, Pivot, Slash and Burn) in ways the generic Corp evaluator doesn't model.

The cluster models already exist and provide the feature space for this — the task is to wire them into the AI pipeline.

---

## Cluster Taxonomy

Derived from the DeckAnalysis models (`model_<faction>_standard.json`). Clusters with n < 15 are noted but may not warrant dedicated presets unless they produce distinctive AI behaviors.

### Corp Archetypes

| ID | Faction | Cluster | n | Label | Strategic signature |
|----|---------|---------|---|-------|---------------------|
| `hb_pd_fast_advance` | HB | C0 | 59 | **PD Fast Advance** | Synchrocyclotron + Nanomanagement + Wage Workers; score in one click window |
| `hb_pd_glacier` | HB | C1 | 52 | **PD Glacier** | Anoetic Void, Bran 1.0, Tranquility Home Grid; heavy tax, patient scoring |
| `hb_pd_big_deal` | HB | C2 | 24 | **PD Big Deal Burst** | Your Digital Life + Big Deal; economy burst into sudden score |
| `hb_thule_kill` | HB | C5 | 57 | **Thule Kill** | Distributed Tracing + End of the Line + Nightmare Archive + Hypoxia; flatline |
| `hb_thule_bioroid` | HB | C6 | 18 | **Thule Bioroid ICE** | Echo/Bloop/Pulse/Wave; ICE that fires on multiple subroutines |
| `jinteki_rh_glacier` | Jinteki | C0 | 68 | **Restoring Humanity Glacier** | La Costa Grid + Sisyphus + Anoetic Void; drip-advance glacier |
| `jinteki_au_co` | Jinteki | C1 | 65 | **Au Co Midrange** | Hybrid Release + Regenesis + Anemone; sustained drip-economy mid-game |
| `jinteki_pe_traps` | Jinteki | C6 | 24 | **PE Traps** | Clearinghouse + Urtica Cipher + Neurospike + Cerebral Overwriter; kill via access |
| `jinteki_issuaq` | Jinteki | C7 | 23 | **Issuaq Scoring** | Issuaq + Palisade + Seamless Launch + Myoshu; grind scoring |
| `jinteki_rp_lockdown` | Jinteki | C3 | 13 | **RP Lockdown** | Front Company + Regenesis + Let Them Dream; lock out remotes via RP identity |
| `nbn_ntm_standard` | NBN | C4 | 73 | **NTM Standard** | Nebula Talent + Nonequivalent Exchange + Superconducting Hub; tempo NBN |
| `nbn_synapse_trace` | NBN | C5 | 40 | **Synapse Trace** | Synapse Signal + Oracle Thinktank + Starlit Knight; win traces to drain runner |
| `nbn_editorial_kill` | NBN | C1 | 32 | **Editorial Kill** | Editorial Division + End of the Line + Game Over + Vulture Fund; tag storm kill |
| `nbn_reality_plus_tags` | NBN | C8 | 17 | **Reality Plus Tags** | Reality Plus + Public Trail + Retribution + End of the Line |
| `nbn_epiphany` | NBN | C0 | 36 | **Epiphany FA** | Epiphany Analytica + Federal Fundraising + Stoke the Embers; FA horizontal |
| `weyland_btl_glacier` | Weyland | C1 | 73 | **Built to Last Glacier** | Charlotte Cacador + Clearinghouse + Pharos + Colossus; economy-efficient big ICE |
| `weyland_ob_fa` | Weyland | C4 | 30 | **Ob Fast Advance** | Nuvem SA + Descent + Slash and Burn + Pivot; chain installs via Ob ability |
| `weyland_kill` | Weyland | C2 | 18 | **Weyland Kill** | End of the Line + Public Trail + Mutually Assured Destruction |
| `weyland_bangun_kill` | Weyland | C3 | 33 | **Bangun/Angelique Kill** | Bangun + Daniela + Angelique + Orbital Superiority; Jinteki-splash meat damage |
| `weyland_earth_station` | Weyland | C6 | 13 | **Earth Station Lockdown** | Earth Station + NAPD Cordon + Daily Quest; high cost-to-run remotes |
| `weyland_zwicky_assets` | Weyland | C7 | 43 | **Zwicky Asset Engine** | Zwicky Group + Kessleroid + Eminent Domain + Ballista; asset/rezzed-ICE economy |

### Runner Archetypes

| ID | Faction | Cluster | n | Label | Strategic signature |
|----|---------|---------|---|-------|---------------------|
| `anarch_hoshiko_tagme` | Anarch | C0 | 93 | **Hoshiko Tag-Me Multiaccess** | Hoshiko + Trickster Taka + The Twinning; run every turn, accept tags |
| `anarch_esa_mill` | Anarch | C1 | 39 | **Esa Mill/Aggro** | Esa + Begemot + Chastushka + Hippocampic Mechanocytes; mill R&D via virus |
| `anarch_loup_virus` | Anarch | C2 | 28 | **Loup Virus Engine** | Cookbook + Cacophony + Carnivore + DZMZ; trash assets, accumulate virus counters |
| `anarch_brazilian_crew` | Anarch | C3 | 34 | **Brazilian Crew** | Valentina + Arruaceiras Crew + Transfer of Wealth; run-on-success econ disruption |
| `criminal_muslihat` | Criminal | C0 | 98 | **Muslihat Modern Criminal** | Muslihat + Sang Kancil + Virtual Intelligence; diverse run events |
| `criminal_sable` | Criminal | C7 | 60 | **Sable Standard** | Nyusha Sable + AirbladEx + No Free Lunch + Carpe Diem; complete runs for directive |
| `criminal_zahya` | Criminal | C6 | 13 | **Zahya Multi-Access** | Zahya + Docklands Pass + Steelskin Scarring + Finality |
| `criminal_mercury` | Criminal | C5 | 21 | **Mercury Run Events** | Malandragem + Mercury + S-Dobrado; Sao Paolo run event engine |
| `shaper_lat_standard` | Shaper | C1 | 69 | **Lat Standard** | Lat + Magdalene + Deep Dive + Spec Work; draw-heavy, setup before run |
| `shaper_lat_econ` | Shaper | C2 | 48 | **Lat Econ Pressure** | Aniccam + Burner + Transfer of Wealth + Lat; current-based econ pressure |
| `shaper_arissana` | Shaper | C3 | 52 | **Arissana ICE-Destroy** | Arissana + Physarum + Slap Vandal + Wake Implant; permanently remove ICE |
| `shaper_twinning` | Shaper | C4 | 25 | **Twinning Multiaccess** | The Twinning + Buzzsaw + Magdalene + Afterimage |
| `shaper_tao` | Shaper | C9 | 19 | **Tao Standard** | Tao + Conduit + Bravado + Flux Capacitor |

---

## Implementation Design

### Phase 0 — Label the existing cluster JSON files

Add a `"label"` and `"archetype_id"` field to each centroid in the cluster model files. This is a one-time annotation step done in R or Python — no code changes to Godot.

Expected output: each `model_<faction>_standard.json` gains a `"labels"` array parallel to `"centroids"` and `"cluster_sizes"`:

```json
{
  "vocab": [...],
  "idf": [...],
  "centroids": [[...], [...]],
  "cluster_sizes": [93, 39, ...],
  "labels": ["anarch_hoshiko_tagme", "anarch_esa_mill", ...]
}
```

Small clusters (n < 10) that don't have a clear AI-meaningful strategy get label `"misc"` and are skipped during preset lookup (fall back to base weights).

### Phase 1 — GDScript cosine similarity classifier

A static utility class loaded once at game start. It reads all seven cluster model files, builds an in-memory index, and exposes one method.

```gdscript
# Scripts/AI/DeckArchetypeClassifier.gd
class_name DeckArchetypeClassifier

# Loaded once from Data/archetype_models/*.json
static var _models: Dictionary = {}   # faction → {vocab, idf, centroids, labels}

static func load_models(model_dir: String) -> void:
    # Called at game start by SelfPlayRunner / CampaignManager

static func classify(deck_card_ids: Array[String], faction: String) -> String:
    # Returns the archetype_id of the nearest centroid, or "generic" if no model loaded.
    # 1. Build TF-IDF vector for this deck (same vocab + IDF as the model).
    # 2. Normalise to unit length.
    # 3. Compute dot-product against each centroid (already unit-normalised during export).
    # 4. Return the label of the highest-scoring centroid.
    # 5. If the best score < CONFIDENCE_THRESHOLD (0.10), return "generic".

static func classify_with_scores(deck_card_ids: Array[String], faction: String) -> Dictionary:
    # Returns {"label": str, "scores": {label: float, ...}} for debugging.
```

**TF-IDF encoding**: for a deck of N cards with count c_i for card i:
- TF(i) = c_i / N (frequency within the deck)
- TF-IDF(i) = TF(i) × IDF(i)  (IDF values are in the model JSON)
- Normalise the resulting vector to unit length before dot-product

The centroids in the exported JSON must also be unit-normalised (can be done during the Phase 0 annotation step in Python).

**Why cosine similarity?** The cluster analysis was built on TF-IDF vectors, so cosine similarity in the same space gives the most faithful distance metric. Euclidean distance would disadvantage long decks vs short ones.

### Phase 2 — Archetype weight presets

A second JSON file (or a new section in `weights_config.json`) holds per-archetype weight *deltas* — values added to or multiplying the base weights from evolutionary tuning:

```json
{
  "archetype_presets": {
    "hb_thule_kill": {
      "w_rd_bare_penalty":  -3.0,
      "w_hq_bare_penalty":  -2.0,
      "kill_threat_value":  20.0
    },
    "anarch_hoshiko_tagme": {
      "tag_penalty_per_tag": 5.0,
      "CENTRAL_RUN_VALUE":   18.0
    },
    "shaper_arissana": {
      "UNCOVERED_ICE_COST": 15.0,
      "BREAKER_VALUE":      30.0
    }
  }
}
```

These are applied in `apply_weights()` after the base weights are loaded, with archetype deltas as a second pass. Evaluators need no structural change — they already accept arbitrary key-value weight dictionaries.

### Phase 3 — Activation in SelfPlayRunner

```gdscript
# In SelfPlayRunner._ready() or equivalent setup section, after deck construction:
var corp_faction   = _corp_deck.identity.faction
var runner_faction = _runner_deck.identity.faction

var corp_archetype   = DeckArchetypeClassifier.classify(_corp_deck.card_ids,   corp_faction)
var runner_archetype = DeckArchetypeClassifier.classify(_runner_deck.card_ids, runner_faction)

corp_brain.apply_archetype(corp_archetype,   _archetype_presets)
runner_brain.apply_archetype(runner_archetype, _archetype_presets)
```

`apply_archetype()` on each brain class merges the preset delta dict into the evaluator via an extra `apply_weights()` call. The merge strategy is additive for value weights and multiplicative for multipliers — documented explicitly per key in the preset JSON.

### Phase 4 — Per-archetype evolutionary tuning

Once the base weights are stable (evolutionary tuner Phase A complete):

1. Create a matchup set that pairs each archetype against its statistically common opponents (derived from real tournament data where available, or from the cluster co-occurrence in the self-play corpus).
2. Run the evolutionary tuner with base weights frozen (read-only) and only the archetype delta vector as the chromosome.
3. Because the delta space is much smaller (3–6 keys per archetype vs. 7–13 for the full base), convergence is faster — 200–500 evaluations vs. 2000+ for base.
4. Tuned deltas are saved per-archetype into the preset JSON.

Chromosome structure for an archetype run:
```
--side corp-archetype:<id>
--base-weights tuner/best_weights.json   # locked
--preset-keys w_rd_bare_penalty,kill_threat_value,...
```
This requires a small extension to `evolutionary_tuner.py` to support a "preset-only" mode.

---

## Data Flow Diagram

```
Game start
    │
    ▼
DeckArchetypeClassifier.classify(deck_ids, faction)
    │   reads: Data/archetype_models/<faction>_standard.json
    │   computes: TF-IDF vector → cosine sim → best label
    ▼
archetype_id (e.g. "hb_thule_kill")
    │
    ▼
brain.apply_weights(base_weights)          ← from evolutionary tuner Phase A
brain.apply_archetype(archetype_id, presets) ← additive delta from Phase 4
    │
    ▼
AI plays with archetype-aware parameters
    │
    ▼
(logging) SelfPlayRunner logs archetype_id per game
    └─ enables post-hoc analysis: "does kill preset actually improve kill rate?"
```

---

## Key Design Decisions

**Additive deltas, not full presets.** Archetype presets store *offsets* from the base, not complete weight vectors. This means:
- The evolutionary tuner's global work is never wasted.
- If an archetype is novel or has too few training games, the delta stays at zero and the base weights apply gracefully.
- Tuning archetype deltas is fast because the search space is small.

**Confidence threshold → fallback to generic.** If no cluster scores above 0.10 cosine similarity, the classifier returns `"generic"` and no archetype preset is applied. This handles novel or hybrid decks cleanly.

**Read model files at game start, not at compile time.** This means adding new archetypes never requires a GDScript recompile — just update the JSON files and relaunch.

**Archetype is determined once, not re-evaluated mid-game.** The deck doesn't change during play. Re-classifying every turn would waste CPU and add instability. The classification is stamped at game start and logged.

---

## Phasing and Prerequisites

| Phase | Deliverable | Prerequisite | Estimated scope |
|-------|-------------|--------------|-----------------|
| 0 | Annotate cluster JSON files with labels | Cluster analysis complete ✓ | Python script, ~1 hr |
| 1 | `DeckArchetypeClassifier.gd` | Phase 0 | ~150 lines GDScript |
| 2 | Archetype preset JSON (hand-tuned initial values) | Phase 1 | Design + JSON authoring |
| 3 | `apply_archetype()` on corp/runner brains | Phase 2 | ~30 lines per brain class |
| 4 | Per-archetype evolutionary tuning | Base tuner Phase A complete | Tuner extension + run time |

**Do not start Phase 0 until the evolutionary tuner has produced stable base weights.** Starting archetype-specific tuning before the base is stable risks locking in archetype deltas that compensate for a weak base rather than expressing genuine archetype strategy.

---

## Open Questions (to resolve after base tuning)

1. **Should archetype classification be symmetric?** Currently each side classifies independently. Should the runner's archetype preset respond to a known Corp archetype (e.g., run more aggressively against a known kill deck)? This would be Phase 5 complexity — defer.

2. **What to do with small clusters (n < 15)?** Options: (a) merge into the nearest large cluster; (b) keep as `"misc"` and fallback to base; (c) treat as variant presets with reduced-confidence deltas. Current recommendation: option (b) until Phase 4 provides data.

3. **How to export unit-normalised centroids from R?** The R clustering code (`DeckClustering.R`, `CorpClusters.R`) produces raw centroids. The Phase 0 Python annotation script should normalise them before writing to the model JSON files.
