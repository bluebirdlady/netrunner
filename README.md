# Netrunner Solo

A solo-playable implementation of **Null Signal Games' Netrunner** built in **Godot 4.6 / GDScript**. The project targets the NSG Standard card pool and includes a full rules engine, narrative campaign modes for both sides, and AI opponents capable of planning multi-click turn sequences.

> **Fan project.** Netrunner is a trademark of Null Signal Games. Card text and imagery belong to their respective rights holders. This project is not affiliated with or endorsed by NSG.

---

## What it plays

- **Format**: NSG Standard (with optional Startup ban list)
- **Card pool**: 2 054 cards across all Standard-legal sets:
  - System Gateway · Salvaged Memories
  - Ashes cycle: Uprising, Downfall
  - Borealis cycle: Midnight Sun, Parhelion
  - Liberation cycle: Rebellion Without Rehearsal
  - Elevation cycle: Automata Initiative, Vantage Point
- Card data sourced from NetrunnerDB; ability effects implemented in `Data/abilities.json`

---

## Features

### Rules engine
- Full turn and click structure, mandatory draws, paid ability windows
- Complete run state machine: approach, encounter, pass, breach, access, trash
- Subroutine resolution with break/boost costing derived from ability data
- Traces, psi games, damage (net / meat / core), tags, bad publicity
- ICE rezzing, asset/upgrade installation, agenda advancement and scoring
- Trigger ordering and "when accessed" effects
- Ban list enforcement via `BanListManager`

### Campaign modes
- **Runner arc** — "Convention Breaker": 10-act narrative campaign with branching mission graph, pre/post-mission fiction, and progressive AI difficulty
- **Corp arc** — parallel 10-act campaign playing from the Corp side
- Fiction archive accessible from the campaign menu

### AI opponents

**Corp AI**
- Strategic layer: plans ice placement, economy, fast-advance windows, and kill threats
- Tactical layer: MCTS search over the run state during encounters
- Rezzing decisions informed by a Bayesian runner threat model

**Runner AI**
- Beam search over projected turn sequences, evaluating multi-click plans
- Data-driven card projection (`AbilityRegistry.get_ai_projection`) auto-derives economy/draw values directly from `abilities.json` on-play effects
- `AiCardHints` fallback covers ~52 runner events too complex to auto-derive: run events, tutors, install-discount events, and complex cards (Deep Dive, Khusyuk, Reprise, Harmony AR Therapy, etc.)
- Escalating unrezzed-ICE cost estimation scaled to Corp credit total
- Breaker-drought detection: raises draw ceiling and prioritises tutor events when the runner has no installed breakers

### Self-play
`Scripts/Tools/SelfPlayRunner.gd` runs headless Corp-vs-Runner games for AI regression testing.

---

## Project structure

```
Data/
  abilities.json          on-play and passive ability definitions
  AbilityRegistry.gd      card data access + AI projection
  Game_Rules/             NSG comprehensive rules PDF + ban lists

Sets/
  system_gateway.csv      per-set card CSVs (name · cost · text · subtypes …)
  …

Campaign/
  campaign.json           Runner arc mission graph
  corp_campaign.json      Corp arc mission graph
  Fiction/                pre/post-mission narrative text files

Scripts/
  Engine/                 core rules: RunStateMachine, TurnManager,
                          GameContext, AbilityInterpreter, EncounterProcessor …
  AI/                     Corp AI (MCTS + strategic/tactical layers),
                          Runner AI (beam search + AiCardHints)
  Tests/                  test scenes for engine subsystems
  Tools/                  SelfPlayRunner headless harness

Scenes/                   Godot scene files (UI, campaign controller, tests)
Assets/                   card art and UI assets
```

---

## Running the project

1. Open the project in **Godot 4.6** (Mono build required for C# assembly).
2. The main scene is `Scenes/UI/CampaignController.tscn`.
3. Press **F5** to launch the campaign arc selection menu.

For headless validation (parse check + card registry load):

```
godot --headless --check-only --quit --path <project_root>
```

Expected output ends with `CardRegistry: loaded 2054 cards` and no script errors.

---

## Development status

The rules engine is substantially complete for the Standard card pool. Known gaps and in-progress work:

| Area | Status |
|------|--------|
| Runner events (AI projection) | P1 auto-derive done; P2 AiCardHints done; P3–P6 pending |
| Corp AI strategic rez | Partial — unrezzed ICE cost scaling implemented |
| Runner AI fast-advance detection | Pending |
| Runner AI kill-window detection | Pending |
| Downfall Corp cards (G5–G6) | G1–G4 complete; G5–G6 in progress |
| Mulligan rules | Pending |
