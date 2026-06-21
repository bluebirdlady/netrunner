# Plan: Systematic Card & Mechanic Coverage Sweep

## Goal

Ensure every implemented card (a) works correctly in the engine and (b) is used competently by the AI, using self-play runs as the primary validation vehicle.

## Two Distinct Dimensions

### 1. Functional coverage (engine correctness)
"Does the card do what it says?"

This is already partially tracked by the per-set coverage CSVs (coverage_*.csv). Each row has an ID, a Coverage field, and a Notes column. The AICoverageAuditor tool can read these to produce a gap report.

Current gap-identification workflow:
- Read coverage CSVs → filter rows where Coverage != "Full"
- Cross-reference against abilities.json to confirm which are actually stubbed vs. just un-marked
- Prioritize by frequency of card in campaign opponent decks and precon decks (high-traffic cards first)

### 2. AI coverage (strategic competence)
"Does the AI know when and how to use the card?"

This is tracked implicitly via AiCardHints.gd and the event_projections pipeline, but has no dedicated coverage record. A card may be engine-correct and yet never played by the AI because:
- It has no entry in AiCardHints.HINTS
- Its AbilityRegistry auto-projection is incomplete
- The evaluator doesn't reward the outcome it creates

## Proposed Sweep Protocol

### Phase A — Inventory
1. Generate a merged table: card_id | set | type | functional_coverage | has_hints_entry | has_auto_projection
   - functional_coverage from coverage CSVs
   - has_hints_entry: grep AiCardHints.HINTS
   - has_auto_projection: grep AbilityRegistry get_ai_projection calls / abilities.json "ai_projection" keys

2. Sort by: (a) in active campaign deck? → top priority; (b) functional_coverage gap; (c) missing hints

### Phase B — Mechanic clustering
Group cards into mechanic families so fixes generalize:
- Tag-give / tag-remove / tag-punishment (NBN package)
- Advancement-counter abilities (Drago, Oaktown, Big Deal...)
- On-score / on-steal triggers
- Trace mechanics (initiation, link boost, success/fail branches)
- Virus counters / purge interaction
- Hosted counter economies (Aumakua, Cezve, Rezeki...)
- Run replacement events (Dirty Laundry, Legwork, The Maker's Eye)
- "Swap from HQ / R&D" install effects
- Multi-access modifiers (The Twinning, Khusyuk, Divide and Conquer)

For each family: one dedicated self-play run with logging enabled, then audit the log for incorrect behavior.

### Phase C — Self-play validation runs
For each gap card or mechanic family:
1. Construct or choose a campaign deck pair that exercises the mechanic heavily
2. Run `--batch 20 --verbose` and capture the log
3. Check for: error messages, "not enough X" warnings, actions never chosen, actions chosen incorrectly
4. File an issue stub in Planning/ if a defect is found; fix and re-run until clean

### Phase D — AI hints gap-fill
After functional coverage is green, sweep the has_hints_entry = false list:
- For each Runner event: add a HINTS entry (conditions + snap_delta + value_bonus)
- For each Corp operation/asset with a click_action: verify _snap_click_assets() guards correctly
- For each unique Corp agenda: verify on-score trigger reaches the evaluator

## Suggested tooling additions
- Add a `--log-card-actions` flag to SelfPlayRunner that prints every card-play decision with the snap score before/after, making it easier to see whether the AI is valuing cards correctly without reading the full verbose log.
- Extend the coverage CSV format to add an `AI_Coverage` column (None / Partial / Full) maintained alongside functional coverage.

## Success criteria
- All cards in active campaign decks: functional_coverage = Full, AI_Coverage >= Partial
- All Runner events and Corp assets with click abilities: has_hints_entry = true or has_auto_projection = true
- 20-game self-play batch with any standard precon matchup produces no engine error lines in the log
