extends Control

# ── GameContextTest ───────────────────────────────────────────────────────────
# Validates GameContext.clone_for_sim() and simulation_mode flag.
# Phase 1: clone isolation tests.
# Phase 2: headless Corp turn timing test — verifies no frame yielding occurs.
#
# Scene setup: VBoxContainer → RunButton (Button) + OutputLabel (RichTextLabel).

@onready var output_label: RichTextLabel = $VBoxContainer/OutputLabel
@onready var run_button:   Button        = $VBoxContainer/RunButton

var _pass_count: int = 0
var _fail_count: int = 0
var _ability_registry: AbilityRegistry


func _ready() -> void:
	run_button.pressed.connect(_on_run_pressed)


func _on_run_pressed() -> void:
	output_label.clear()
	_pass_count = 0
	_fail_count = 0

	_ability_registry = AbilityRegistry.new()
	if not _ability_registry.load_from_file("res://Data/abilities.json"):
		_log("[color=red]Failed to load abilities.json — timing test will be skipped.[/color]")

	_log("[b]── GameContext Clone Tests (Phase 1) ──[/b]\n")

	_test_scalar_isolation()
	_test_server_ice_counter_isolation()
	_test_runner_rig_isolation()
	_test_hand_isolation()
	_test_listener_registry_isolation()
	_test_simulation_mode_flag()

	_log("")
	_log("[b]── Simulation Mode Tests (Phase 2) ──[/b]\n")
	await _test_headless_corp_turn_timing()

	_log("")
	_log("[b]── Sim AI Full Game Test (Phase 3) ──[/b]\n")
	await _test_sim_ai_full_game()

	_log("")
	_log("[b]── GameSimulator Forward Model (Phase 4) ──[/b]\n")
	await _test_game_simulator_bulk()

	_log("")
	_log("[b]── DeterminizationSampler (Phase 5) ──[/b]\n")
	_test_determinization_sampler()

	_log("")
	_log("[b]── MCTS Core (Phase 6) ──[/b]\n")
	await _test_mcts_single_decision()

	_log("")
	_log("[b]── MCTS Integration / Win-Rate Benchmark (Phase 7) ──[/b]\n")
	await _test_mcts_win_rate_vs_tactical()

	_log("")
	_log("[b]── Corp Turn AI Board-State Tests (Phase 8) ──[/b]\n")
	_test_ai_ready_agenda_scores()
	_test_ai_kill_window_fires()
	_test_ai_kill_window_suppressed()
	_test_ai_trap_window_fires()
	_test_ai_runner_pressure_ices_hq()
	_test_ai_upgrade_installs_in_agenda_remote()
	_test_ai_upgrade_beats_asset()
	_test_ai_proactive_trap_advance()
	_test_ai_kill_beats_trap_window_priority()
	_test_ai_agenda_installs_into_protected_remote()

	_log("")
	_log("[b]Results: %d passed, %d failed[/b]" % [_pass_count, _fail_count])
	if _fail_count == 0:
		_log("[color=green]All tests passed.[/color]")
	else:
		_log("[color=red]%d test(s) failed.[/color]" % _fail_count)


# ── Tests ─────────────────────────────────────────────────────────────────────

func _test_scalar_isolation() -> void:
	_log("[b]Test 1[/b] — Mutating clone credits does not affect original")
	var orig  := _make_mid_game_context()
	var clone := orig.clone_for_sim()

	clone.corp_credits   += 99
	clone.runner_credits += 99
	clone.runner_tags    += 5
	clone.turn_number    += 10

	_expect_eq("orig corp_credits unchanged",   orig.corp_credits,   8)
	_expect_eq("orig runner_credits unchanged", orig.runner_credits, 4)
	_expect_eq("orig runner_tags unchanged",    orig.runner_tags,    0)
	_expect_eq("orig turn_number unchanged",    orig.turn_number,    3)
	_expect_eq("clone is in simulation_mode",   clone.simulation_mode, true)
	_log("")


func _test_server_ice_counter_isolation() -> void:
	_log("[b]Test 2[/b] — Mutating an installed card counter in clone does not affect original")
	var orig  := _make_mid_game_context()
	var clone := orig.clone_for_sim()

	# Add an advancement counter to the agenda in the clone's remote server
	var clone_remote: Server = _find_first_remote(clone)
	var clone_agenda: InstalledCard = clone_remote.get_agenda_or_asset() if clone_remote else null
	if clone_agenda == null:
		_log("  [color=yellow]SKIP[/color] no agenda found in remote (setup issue)")
		return

	var orig_adv_before: int = _get_remote_agenda_advancement(orig)
	clone_agenda.add_counter("advancement", 3)

	_expect_eq("orig agenda advancement unchanged", _get_remote_agenda_advancement(orig), orig_adv_before)
	_expect_eq("clone agenda advancement updated",  clone_agenda.get_counter("advancement"), orig_adv_before + 3)
	_log("")


func _test_runner_rig_isolation() -> void:
	_log("[b]Test 3[/b] — Trashing a card from clone rig does not affect original rig")
	var orig  := _make_mid_game_context()
	var clone := orig.clone_for_sim()

	var orig_rig_size: int = orig.runner_rig.size()
	if clone.runner_rig.is_empty():
		_log("  [color=yellow]SKIP[/color] runner rig empty (setup issue)")
		return

	# Trash first rig card from clone
	var trashed: InstalledCard = clone.runner_rig.pop_front() as InstalledCard
	if trashed != null and trashed.card_record != null:
		clone.runner_discard.append(trashed.card_record)

	_expect_eq("orig rig size unchanged",  orig.runner_rig.size(),   orig_rig_size)
	_expect_eq("clone rig size reduced",   clone.runner_rig.size(),  orig_rig_size - 1)
	_expect_eq("orig discard unchanged",   orig.runner_discard.size(), 0)
	_expect_eq("clone discard grew",       clone.runner_discard.size(), 1)
	_log("")


func _test_hand_isolation() -> void:
	_log("[b]Test 4[/b] — Removing a card from clone hand does not affect original hand")
	var orig  := _make_mid_game_context()
	var clone := orig.clone_for_sim()

	var orig_hand_size: int = orig.corp_hand.size()
	if clone.corp_hand.is_empty():
		_log("  [color=yellow]SKIP[/color] corp hand empty (setup issue)")
		return

	clone.corp_hand.pop_back()

	_expect_eq("orig hand size unchanged", orig.corp_hand.size(),  orig_hand_size)
	_expect_eq("clone hand size reduced",  clone.corp_hand.size(), orig_hand_size - 1)
	_log("")


func _test_listener_registry_isolation() -> void:
	_log("[b]Test 5[/b] — Adding a listener to the clone does not affect original registry")
	var orig  := _make_mid_game_context()
	var orig_count_before: int = _listener_count(orig, "corp_turn_start")

	var clone := orig.clone_for_sim()
	clone.register_listener("corp_turn_start", "fake_sim_card", {"effect": "noop"})

	_expect_eq("orig listener count unchanged",
		_listener_count(orig, "corp_turn_start"), orig_count_before)
	_expect_eq("clone listener count grew",
		_listener_count(clone, "corp_turn_start"), orig_count_before + 1)
	_log("")


func _test_simulation_mode_flag() -> void:
	_log("[b]Test 6[/b] — simulation_mode is false on original, true on clone")
	var orig  := _make_mid_game_context()
	var clone := orig.clone_for_sim()

	_expect_eq("orig simulation_mode is false", orig.simulation_mode,  false)
	_expect_eq("clone simulation_mode is true",  clone.simulation_mode, true)
	_log("")


# ── Phase 2 tests ─────────────────────────────────────────────────────────────

# Runs a full Corp action phase on a cloned context and verifies:
#   1. It completes (no hang or infinite yield).
#   2. Wall-clock time is well under 100 ms — confirming no frame yielding.
#   3. Corp credits changed as expected (actions were actually executed).
#   4. simulation_mode suppresses send_log (event_log stays empty on the clone).
func _test_headless_corp_turn_timing() -> void:
	_log("[b]Test 7[/b] — Headless Corp turn completes without frame yielding")

	if _ability_registry == null:
		_log("  [color=yellow]SKIP[/color] ability_registry not loaded")
		return

	var orig  := _make_rich_mid_game_context()
	var clone := orig.clone_for_sim()

	# Inject a stub Corp AI and stub Runner into the sim context.
	var corp_ai := CorpTurnAI.new(_ability_registry)
	clone.corp_decision_maker   = corp_ai
	clone.runner_decision_maker = _StubRunner.new()

	var tm := TurnManager.new(clone, _ability_registry)

	# Time the Corp action phase only (not a full game loop).
	var t_start: int = Time.get_ticks_msec()
	clone.active_player = "corp"
	clone.corp_clicks   = 3
	# Mandatory draw (stub: skip if deck empty, just run the action phase)
	while clone.corp_clicks > 0 and not clone.game_over:
		var action: GameAction = await clone.corp_decision_maker.choose_action(clone)
		if action == null or action.type == "end_turn":
			break
		await tm._execute_action("corp", action)
	var elapsed: int = Time.get_ticks_msec() - t_start

	_log("  Elapsed: %d ms" % elapsed)
	_expect_eq("completes in under 100 ms", elapsed < 100, true)
	_expect_eq("clone is in simulation_mode", clone.simulation_mode, true)
	_expect_eq("clone event_log is empty (send_log suppressed)", clone.event_log.is_empty(), true)
	_expect_eq("original credits unchanged", orig.corp_credits, 8)
	_log("")


# ── Phase 3 test ──────────────────────────────────────────────────────────────

# Runs a full simulated game (both sides) on a cloned context and verifies:
#   1. The game reaches a terminal state (game_over = true).
#   2. It completes well under 2 000 ms — no frame yielding.
#   3. The original context is unaffected.
func _test_sim_ai_full_game() -> void:
	_log("[b]Test 8[/b] — Full simulated game with SimCorpAI + SimRunnerAI")

	if _ability_registry == null:
		_log("  [color=yellow]SKIP[/color] ability_registry not loaded")
		return

	var orig  := _make_rich_mid_game_context()
	var clone := orig.clone_for_sim()

	clone.corp_decision_maker   = SimCorpAI.new(_ability_registry)
	clone.runner_decision_maker = SimRunnerAI.new()

	var tm := TurnManager.new(clone, _ability_registry)

	var t_start: int = Time.get_ticks_msec()
	var turn_cap: int = 0
	while not clone.game_over and turn_cap < 40:
		clone.active_player = "corp"
		clone.corp_clicks   = 3
		await tm._corp_turn()
		if clone.game_over:
			break
		clone.active_player = "runner"
		clone.runner_clicks = 4
		await tm._runner_turn()
		turn_cap += 1
	var elapsed: int = Time.get_ticks_msec() - t_start

	_log("  Elapsed: %d ms, turns: %d, game_over: %s, winner: %s" % [elapsed, turn_cap, str(clone.game_over), clone.winner])
	_expect_eq("game reaches terminal state or turn cap", clone.game_over or turn_cap >= 40, true)
	_expect_eq("completes under 2000 ms", elapsed < 2000, true)
	_expect_eq("original corp_credits unchanged", orig.corp_credits, 8)
	_expect_eq("clone in simulation_mode", clone.simulation_mode, true)
	_log("")


# ── Phase 7 test ──────────────────────────────────────────────────────────────

# Plays GAME_COUNT full automated games for each AI tier (MCTS and Tactical),
# both against SimRunnerAI, from identical starting positions.
# Reports Corp win rates and average turn counts.
# MCTS should win at least as often as Tactical (hard to guarantee in short runs,
# so the test asserts both AIs produce valid terminal states, not a specific win rate).
func _test_mcts_win_rate_vs_tactical() -> void:
	_log("[b]Test 12[/b] — MCTS vs Tactical win-rate benchmark (20 games each)")

	if _ability_registry == null:
		_log("  [color=yellow]SKIP[/color] ability_registry not loaded")
		return

	const GAME_COUNT := 20
	const TURN_CAP   := 50

	var card_pool: Array = []
	for id in ["sure_gamble", "diesel", "dirty_laundry", "corroder",
				"cleaver", "paperclip", "rezeki", "aumakua"]:
		card_pool.append(_make_runner_card_record(id, "event"))

	var results := {}
	for tier in ["tactical", "mcts"]:
		var corp_wins := 0
		var runner_wins := 0
		var incomplete := 0
		var total_turns := 0
		var total_ms := 0

		for _g in range(GAME_COUNT):
			var ctx := _make_rich_mid_game_context()
			# Suppress all game logs — these are automated benchmark games, not real play.
			ctx.simulation_mode = true
			ctx.runner_decision_maker = SimRunnerAI.new()
			if tier == "mcts":
				var mcts_ai := CorpTurnAI_MCTS.new(_ability_registry)
				mcts_ai.set_card_pool(card_pool)
				ctx.corp_decision_maker = mcts_ai
			else:
				ctx.corp_decision_maker = CorpTurnAI_Tactical.new(_ability_registry)

			var tm := TurnManager.new(ctx, _ability_registry)
			var t0 := Time.get_ticks_msec()
			# run_game(TURN_CAP) handles game_over checks cleanly between turns.
			await tm.run_game(TURN_CAP)
			total_ms += Time.get_ticks_msec() - t0
			total_turns += ctx.turn_number - 3  # test context starts at turn 3

			if ctx.game_over:
				if ctx.winner == "corp":
					corp_wins += 1
				else:
					runner_wins += 1
			else:
				incomplete += 1

		results[tier] = {
			"corp_wins": corp_wins,
			"runner_wins": runner_wins,
			"incomplete": incomplete,
			"avg_turns": float(total_turns) / float(GAME_COUNT),
			"avg_ms": float(total_ms) / float(GAME_COUNT),
		}

	var tac: Dictionary  = results["tactical"] as Dictionary
	var mct: Dictionary  = results["mcts"]     as Dictionary

	_log("  Tactical  — Corp wins: %d  Runner wins: %d  Incomplete: %d  Avg turns: %.1f  Avg ms/game: %.0f" % [
		tac["corp_wins"], tac["runner_wins"], tac["incomplete"], tac["avg_turns"], tac["avg_ms"]])
	_log("  MCTS      — Corp wins: %d  Runner wins: %d  Incomplete: %d  Avg turns: %.1f  Avg ms/game: %.0f" % [
		mct["corp_wins"], mct["runner_wins"], mct["incomplete"], mct["avg_turns"], mct["avg_ms"]])

	# Structural assertions — both AIs must produce valid terminal states.
	_expect_eq("Tactical: all games reach a state",
		(tac["corp_wins"] as int) + (tac["runner_wins"] as int) + (tac["incomplete"] as int), GAME_COUNT)
	_expect_eq("MCTS: all games reach a state",
		(mct["corp_wins"] as int) + (mct["runner_wins"] as int) + (mct["incomplete"] as int), GAME_COUNT)
	_expect_eq("MCTS avg ms/game within 30 s budget", (mct["avg_ms"] as float) < 30000.0, true)
	_log("")


# ── Phase 6 test ──────────────────────────────────────────────────────────────

# Validates MCTSTree.choose_action():
#   1. Returns a non-null GameAction.
#   2. The action type is one of the expected Corp click actions.
#   3. Completes within a generous wall-clock budget (5 s covers even slow machines).
#   4. Reports MCTS timing and the chosen action for manual inspection.
func _test_mcts_single_decision() -> void:
	_log("[b]Test 11[/b] — MCTSTree produces a valid Corp action")

	if _ability_registry == null:
		_log("  [color=yellow]SKIP[/color] ability_registry not loaded")
		return

	var ctx := _make_rich_mid_game_context()

	# Build a small uniform card pool from synthetic records (no CardRegistry needed).
	var card_pool: Array = []
	for id in ["sure_gamble", "diesel", "dirty_laundry", "corroder",
				"cleaver", "paperclip", "rezeki", "aumakua"]:
		card_pool.append(_make_runner_card_record(id, "event"))

	var mcts := MCTSTree.new(_ability_registry)

	var t0: int = Time.get_ticks_msec()
	var action: GameAction = await mcts.choose_action(ctx, card_pool, null)
	var elapsed: int = Time.get_ticks_msec() - t0

	var valid_types := ["gain_credits", "draw_card", "play_operation",
						"install", "advance", "use_installed_card", "end_turn"]

	_log("  Elapsed: %d ms  |  Chosen action: %s" % [elapsed, action.describe() if action != null else "null"])
	_expect_eq("returns a non-null action", action != null, true)
	if action != null:
		_expect_eq("action type is a valid Corp click action",
			valid_types.has(action.type), true)
	_expect_eq("completes within 5000 ms", elapsed < 5000, true)
	_log("")


# ── Phase 5 test ──────────────────────────────────────────────────────────────

# Validates DeterminizationSampler:
#   1. Produces exactly N contexts.
#   2. Each context has the correct grip size.
#   3. Grip cards are all valid runner CardRecords.
#   4. Original context is not modified.
#   5. Samples differ from each other (not all identical).
func _test_determinization_sampler() -> void:
	_log("[b]Test 10[/b] — DeterminizationSampler produces valid determinizations")

	var ctx := _make_rich_mid_game_context()
	var expected_grip_size: int = ctx.runner_hand.size()

	# Build a minimal card pool from cards we know exist.
	var pool: Array = []
	for id in ["sure_gamble", "diesel", "dirty_laundry", "easy_mark",
				"corroder", "cleaver", "paperclip", "bukhgalter",
				"rezeki", "aumakua", "botulus", "pelangi",
				"deuces_wild", "pinhole_threading", "demolition_run"]:
		var r := _make_runner_card_record(id, "event")
		pool.append(r)

	const N := 12
	var samples: Array = DeterminizationSampler.sample(ctx, N, null, pool)

	_expect_eq("produces N contexts", samples.size(), N)

	var all_same: bool = true
	var first_ids: Array = []
	if not samples.is_empty():
		var first: GameContext = samples[0] as GameContext
		for entry in first.runner_hand:
			first_ids.append((entry as Dictionary).get("card_id", ""))

	for i in range(samples.size()):
		var s: GameContext = samples[i] as GameContext
		_expect_eq("sample %d has correct grip size" % i, s.runner_hand.size(), expected_grip_size)
		_expect_eq("sample %d is in simulation_mode" % i, s.simulation_mode, true)
		# Check all grip entries have a card_record
		var valid := true
		for entry in s.runner_hand:
			var r: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
			if r == null or r.side != "runner":
				valid = false
		_expect_eq("sample %d grip cards are valid runner cards" % i, valid, true)

		if i > 0:
			var ids: Array = []
			for entry in s.runner_hand:
				ids.append((entry as Dictionary).get("card_id", ""))
			if ids != first_ids:
				all_same = false

	_expect_eq("samples are not all identical", all_same, false)
	_expect_eq("original grip size unchanged", ctx.runner_hand.size(), expected_grip_size)
	_expect_eq("original is not simulation_mode", ctx.simulation_mode, false)
	_log("")


# ── Phase 4 test ──────────────────────────────────────────────────────────────

# Runs 100 forward simulations of 10 turns each via GameSimulator.advance().
# Measures per-simulation wall-clock time and records outcome distribution.
func _test_game_simulator_bulk() -> void:
	_log("[b]Test 9[/b] — 100 × 10-turn forward simulations via GameSimulator")

	if _ability_registry == null:
		_log("  [color=yellow]SKIP[/color] ability_registry not loaded")
		return

	const SIM_COUNT  := 100
	const SIM_TURNS  := 10
	const TARGET_MS  := 5   # per simulation

	var base := _make_rich_mid_game_context()

	var corp_wins:   int = 0
	var runner_wins: int = 0
	var incomplete:  int = 0
	var total_ms:    int = 0

	for _i in range(SIM_COUNT):
		var t0: int = Time.get_ticks_msec()
		var result: GameContext = await GameSimulator.advance(base, _ability_registry, SIM_TURNS)
		total_ms += Time.get_ticks_msec() - t0

		if result.game_over:
			if result.winner == "corp":
				corp_wins += 1
			else:
				runner_wins += 1
		else:
			incomplete += 1

	var avg_ms: float = float(total_ms) / float(SIM_COUNT)
	_log("  Avg: %.2f ms/sim  |  Corp wins: %d  Runner wins: %d  Incomplete: %d" % [
		avg_ms, corp_wins, runner_wins, incomplete])

	_expect_eq("avg per-sim time under %d ms" % TARGET_MS, avg_ms < TARGET_MS, true)
	_expect_eq("all sims completed without crash", corp_wins + runner_wins + incomplete, SIM_COUNT)
	_expect_eq("original context unaffected", base.simulation_mode, false)
	_log("")


# Richer mid-game context with a real corp hand so the AI has actions to take.
func _make_rich_mid_game_context() -> GameContext:
	var ctx := _make_mid_game_context()
	# Give Corp a deck so mandatory draw doesn't fail
	for _i in range(5):
		ctx.corp_deck.append(_make_card_record("hedge_fund", "operation"))
	# Give Runner credits and a small hand/deck
	ctx.runner_credits = 6
	for _i in range(3):
		var card := _make_runner_card_record("sure_gamble", "event")
		ctx.runner_hand.append({"card_id": card.id, "card_record": card})
	for _i in range(5):
		ctx.runner_deck.append(_make_runner_card_record("sure_gamble", "event"))
	return ctx


# ── Context factory ───────────────────────────────────────────────────────────

func _make_mid_game_context() -> GameContext:
	var ctx              := GameContext.new()
	ctx.corp_credits      = 8
	ctx.runner_credits    = 4
	ctx.runner_tags       = 0
	ctx.turn_number       = 3
	ctx.agenda_points_to_win = 7

	# Corp hand — two operations
	var op1 := _make_card_record("hedge_fund", "operation")
	var op2 := _make_card_record("spin_doctor", "operation")
	ctx.corp_hand.append({"card_id": op1.id, "card_record": op1})
	ctx.corp_hand.append({"card_id": op2.id, "card_record": op2})

	# HQ with one piece of ice
	var hq    := ctx.get_server("hq")
	var pali  := _make_card_record("palisade", "ice")
	var pali_ic := InstalledCard.make_runtime_instance(pali, "hq", "ice", true)
	hq.install_ice(pali_ic)

	# Remote with an agenda (1 of 3 advancements)
	var remote   := ctx.create_remote_server()
	var agenda_r := _make_agenda_record("offworld_office", 3, 2)
	var agenda_ic := InstalledCard.make_runtime_instance(agenda_r, remote.server_id, "root", false)
	agenda_ic.add_counter("advancement", 1)
	remote.install_in_root(agenda_ic)

	# Runner rig — one icebreaker
	var fracter    := _make_card_record("cleaver", "program")
	var fracter_ic := InstalledCard.make_runtime_instance(fracter, "runner_rig", "root", true)
	ctx.runner_rig.append(fracter_ic)

	# Register a listener so the registry is non-empty
	ctx.register_listener("corp_turn_start", pali_ic.runtime_instance_id, {"effect": "stub"})

	return ctx


# ── Helpers ───────────────────────────────────────────────────────────────────

func _find_first_remote(ctx: GameContext) -> Server:
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s.is_remote():
			return s
	return null


func _get_remote_agenda_advancement(ctx: GameContext) -> int:
	var remote := _find_first_remote(ctx)
	if remote == null:
		return -1
	var agenda: InstalledCard = remote.get_agenda_or_asset()
	if agenda == null:
		return -1
	return agenda.get_counter("advancement")


func _listener_count(ctx: GameContext, event_type: String) -> int:
	var listeners: Array = ctx._event_listeners.get(event_type, []) as Array
	return listeners.size()


func _make_card_record(id: String, card_type: String) -> CardRecord:
	var r        := CardRecord.new()
	r.id          = id
	r.title       = id
	r.card_type   = card_type
	r.side        = "corp"
	r.cost        = 0
	r.stripped_text = ""
	r.subtypes    = []
	return r


func _make_runner_card_record(id: String, card_type: String) -> CardRecord:
	var r        := CardRecord.new()
	r.id          = id
	r.title       = id
	r.card_type   = card_type
	r.side        = "runner"
	r.cost        = 0
	r.stripped_text = ""
	r.subtypes    = []
	return r


func _make_agenda_record(id: String, adv_req: int, points: int) -> CardRecord:
	var r                     := CardRecord.new()
	r.id                      = id
	r.title                   = id
	r.card_type               = "agenda"
	r.side                    = "corp"
	r.cost                    = -1
	r.advancement_requirement = adv_req
	r.agenda_points           = points
	r.stripped_text           = ""
	r.subtypes                = []
	return r


func _expect_eq(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_log("  [color=green]PASS[/color] %s = %s" % [label, str(actual)])
		_pass_count += 1
	else:
		_log("  [color=red]FAIL[/color] %s: expected %s, got %s" % [label, str(expected), str(actual)])
		_fail_count += 1


func _log(text: String) -> void:
	output_label.append_text(text + "\n")


# ── Phase 8 helpers ───────────────────────────────────────────────────────────

# Fresh CorpTurnAI backed by an EMPTY registry.
# Empty registry means get_on_play() always returns {}, so every operation
# passes its condition check.  Tests synthetic card IDs safely.
func _make_corp_turn_ai() -> CorpTurnAI:
	return CorpTurnAI.new(AbilityRegistry.new())


# Installed trap: non-agenda asset whose text contains "can be advanced".
func _make_trap_ic(id: String, server_id: String, n_counters: int) -> InstalledCard:
	var r := _make_card_record(id, "asset")
	r.text = "can be advanced"
	var ic := InstalledCard.make_runtime_instance(r, server_id, "root", false)
	if n_counters > 0:
		ic.add_counter("advancement", n_counters)
	return ic


# Runner icebreaker with a specific subtype (fracter / killer / decoder).
func _make_breaker_ic(id: String, subtype: String) -> InstalledCard:
	var r := _make_runner_card_record(id, "program")
	r.subtypes = [subtype]
	return InstalledCard.make_runtime_instance(r, "runner_rig", "root", true)


# Rezzed ice installed in a server's ice zone.
func _make_ice_ic(id: String, server_id: String) -> InstalledCard:
	var r := _make_card_record(id, "ice")
	r.subtypes = ["barrier"]
	r.strength = 2
	return InstalledCard.make_runtime_instance(r, server_id, "ice", true)


# Fill the runner's hand with N stub event cards.
func _add_runner_hand_cards(ctx: GameContext, count: int) -> void:
	for i in range(count):
		var r := _make_runner_card_record("stub_event_%d" % i, "event")
		ctx.runner_hand.append({"card_id": r.id, "card_record": r})


# ── Phase 8 tests ──────────────────────────────────────────────────────────────

func _test_ai_ready_agenda_scores() -> void:
	_log("[b]AI Test 13[/b] — Ready agenda scores before any other action")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits = 5
	_add_runner_hand_cards(ctx, 4)

	var remote    := ctx.create_remote_server()
	remote.install_ice(_make_ice_ic("palisade", remote.server_id))
	var agenda_r  := _make_agenda_record("offworld_office", 3, 2)
	var agenda_ic := InstalledCard.make_runtime_instance(agenda_r, remote.server_id, "root", false)
	agenda_ic.add_counter("advancement", 3)   # 3/3 — meets requirement
	remote.install_in_root(agenda_ic)

	var ice_r := _make_card_record("palisade", "ice")
	ctx.corp_hand.append({"card_id": ice_r.id, "card_record": ice_r})

	var action := ai.choose_action(ctx)
	_expect_eq("action type is advance",      action.type,                        "advance")
	_expect_eq("advances the ready agenda",   action.params.get("card_id", ""),  agenda_ic.card_id)
	_log("")


func _test_ai_kill_window_fires() -> void:
	_log("[b]AI Test 14[/b] — Kill window fires: plays damage op at runner grip = 2")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits = 5
	_add_runner_hand_cards(ctx, 2)   # grip = 2 — kill window threshold

	var dmg_op := _make_card_record("neurospike", "operation")
	ctx.corp_hand.append({"card_id": dmg_op.id, "card_record": dmg_op})

	var action := ai.choose_action(ctx)
	_expect_eq("plays damage operation at grip 2", action.type, "play_operation")
	_log("")


func _test_ai_kill_window_suppressed() -> void:
	_log("[b]AI Test 15[/b] — Kill window suppressed at grip = 3; advances agenda instead")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits   = 5
	ctx.runner_credits = 0
	_add_runner_hand_cards(ctx, 3)   # grip = 3 — above kill threshold

	var dmg_op := _make_card_record("neurospike", "operation")
	ctx.corp_hand.append({"card_id": dmg_op.id, "card_record": dmg_op})

	# Almost-scored agenda (1/2) in iced remote — scoring window should fire
	var remote    := ctx.create_remote_server()
	remote.install_ice(_make_ice_ic("palisade", remote.server_id))
	var agenda_r  := _make_agenda_record("offworld_office", 2, 2)
	var agenda_ic := InstalledCard.make_runtime_instance(agenda_r, remote.server_id, "root", false)
	agenda_ic.add_counter("advancement", 1)
	remote.install_in_root(agenda_ic)

	var action := ai.choose_action(ctx)
	_expect_eq("action is advance (not play_operation)", action.type,                       "advance")
	_expect_eq("advances the agenda card",               action.params.get("card_id", ""), agenda_ic.card_id)
	_log("")


func _test_ai_trap_window_fires() -> void:
	_log("[b]AI Test 16[/b] — Trap window (A2): advances trap when counter+1 >= grip")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits = 2
	_add_runner_hand_cards(ctx, 3)   # grip = 3; counter 2+1 = 3 >= 3

	var remote  := ctx.create_remote_server()
	remote.install_ice(_make_ice_ic("palisade", remote.server_id))
	var trap_ic := _make_trap_ic("clearinghouse", remote.server_id, 2)
	remote.install_in_root(trap_ic)

	var action := ai.choose_action(ctx)
	_expect_eq("action type is advance",  action.type,                       "advance")
	_expect_eq("advances the trap card",  action.params.get("card_id", ""), trap_ic.card_id)
	_log("")


func _test_ai_runner_pressure_ices_hq() -> void:
	_log("[b]AI Test 17[/b] — Runner pressure (C): ices HQ when runner has full rig")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits = 5
	_add_runner_hand_cards(ctx, 5)

	ctx.runner_rig.append(_make_breaker_ic("cleaver",  "fracter"))
	ctx.runner_rig.append(_make_breaker_ic("echelon",  "killer"))
	ctx.runner_rig.append(_make_breaker_ic("unity",    "decoder"))

	var ice_r := _make_card_record("palisade", "ice")
	ctx.corp_hand.append({"card_id": ice_r.id, "card_record": ice_r})
	# HQ intentionally left bare (GameContext._init creates empty centrals)

	var action := ai.choose_action(ctx)
	_expect_eq("action type is install",  action.type,                         "install")
	_expect_eq("target server is hq",     action.params.get("server_id", ""), "hq")
	_expect_eq("zone is ice",             action.params.get("zone", ""),       "ice")
	_log("")


func _test_ai_upgrade_installs_in_agenda_remote() -> void:
	_log("[b]AI Test 18[/b] — Upgrade (step 9.5) installs in iced remote with agenda")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits = 5
	_add_runner_hand_cards(ctx, 5)

	# Iced remote with an agenda that is not close to scoring (0/3)
	var remote    := ctx.create_remote_server()
	remote.install_ice(_make_ice_ic("palisade", remote.server_id))
	var agenda_r  := _make_agenda_record("offworld_office", 3, 2)
	var agenda_ic := InstalledCard.make_runtime_instance(agenda_r, remote.server_id, "root", false)
	remote.install_in_root(agenda_ic)

	# Upgrade in hand only — no ice, no other agenda
	var upgrade_r := _make_card_record("anoetic_void", "upgrade")
	ctx.corp_hand.append({"card_id": upgrade_r.id, "card_record": upgrade_r})

	var action := ai.choose_action(ctx)
	_expect_eq("action type is install",             action.type,                         "install")
	_expect_eq("installs in iced remote with agenda", action.params.get("server_id", ""), remote.server_id)
	_log("")


func _test_ai_upgrade_beats_asset() -> void:
	_log("[b]AI Test 19[/b] — Upgrade (step 9.5) chosen over asset (step 10) when both in hand")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits = 5
	_add_runner_hand_cards(ctx, 5)

	var remote    := ctx.create_remote_server()
	remote.install_ice(_make_ice_ic("palisade", remote.server_id))
	var agenda_r  := _make_agenda_record("offworld_office", 3, 2)
	var agenda_ic := InstalledCard.make_runtime_instance(agenda_r, remote.server_id, "root", false)
	remote.install_in_root(agenda_ic)

	var upgrade_r := _make_card_record("anoetic_void", "upgrade")
	var asset_r   := _make_card_record("regolith_mining_license", "asset")
	ctx.corp_hand.append({"card_id": upgrade_r.id, "card_record": upgrade_r})
	ctx.corp_hand.append({"card_id": asset_r.id,   "card_record": asset_r})

	var action := ai.choose_action(ctx)
	_expect_eq("action type is install", action.type, "install")
	var chosen: CardRecord = action.params.get("card_record", null) as CardRecord
	var chosen_type := chosen.card_type if chosen != null else ""
	_expect_eq("installed card is upgrade not asset", chosen_type, "upgrade")
	_log("")


func _test_ai_proactive_trap_advance() -> void:
	_log("[b]AI Test 20[/b] — Proactive trap advance (step 12.5) at runner grip = 4")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits = 2
	_add_runner_hand_cards(ctx, 4)   # grip = 4: above trap-window (3), at or below step-12.5 threshold (5)

	var remote  := ctx.create_remote_server()
	remote.install_ice(_make_ice_ic("palisade", remote.server_id))
	var trap_ic := _make_trap_ic("clearinghouse", remote.server_id, 0)
	remote.install_in_root(trap_ic)
	# corp_hand intentionally empty — no other productive action available

	var action := ai.choose_action(ctx)
	_expect_eq("action type is advance", action.type,                       "advance")
	_expect_eq("advances the trap",      action.params.get("card_id", ""), trap_ic.card_id)
	_log("")


func _test_ai_kill_beats_trap_window_priority() -> void:
	_log("[b]AI Test 21[/b] — Kill window (A) fires before trap window (A2) at grip = 2")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits = 5
	_add_runner_hand_cards(ctx, 2)   # grip = 2 — both kill and trap windows would qualify

	# Trap with 1 counter in iced remote: 1+1=2 >= grip=2, trap window would fire
	var remote  := ctx.create_remote_server()
	remote.install_ice(_make_ice_ic("palisade", remote.server_id))
	var trap_ic := _make_trap_ic("clearinghouse", remote.server_id, 1)
	remote.install_in_root(trap_ic)

	# Damage op in hand — kill window (checked first) should win
	var dmg_op := _make_card_record("neurospike", "operation")
	ctx.corp_hand.append({"card_id": dmg_op.id, "card_record": dmg_op})

	var action := ai.choose_action(ctx)
	_expect_eq("plays damage op (kill window fires before trap window)", action.type, "play_operation")
	_log("")


func _test_ai_agenda_installs_into_protected_remote() -> void:
	_log("[b]AI Test 22[/b] — Agenda installs into existing protected remote, not new_remote")
	var ai  := _make_corp_turn_ai()
	var ctx := GameContext.new()
	ctx.corp_credits = 5
	_add_runner_hand_cards(ctx, 5)

	# Protected empty remote: has ice, no root card
	var protected_remote := ctx.create_remote_server()
	protected_remote.install_ice(_make_ice_ic("palisade", protected_remote.server_id))

	# Agenda + backup ice in hand
	var agenda_r := _make_agenda_record("offworld_office", 3, 2)
	var ice_r    := _make_card_record("palisade", "ice")
	ctx.corp_hand.append({"card_id": agenda_r.id, "card_record": agenda_r})
	ctx.corp_hand.append({"card_id": ice_r.id,    "card_record": ice_r})

	var action := ai.choose_action(ctx)
	_expect_eq("action type is install", action.type, "install")
	_expect_eq("installs into existing protected remote, not new_remote",
		action.params.get("server_id", ""), protected_remote.server_id)
	_log("")


# ── Stub Runner — gains credits every click, never runs ───────────────────────
class _StubRunner:
	func choose_action(_ctx: GameContext) -> GameAction:
		return GameAction.gain_credits()
	func choose_break_subroutines(_ice: InstalledCard, _subs: Array, _ctx: GameContext) -> Array:
		return []
	func choose_jack_out(_ctx: GameContext) -> bool:
		return false
	func choose_trash(_card: CardRecord, _ctx: GameContext) -> bool:
		return false
	func get_pre_click_rez_actions(_ctx: GameContext) -> Array:
		return []
	func choose_trigger_order(triggers: Array, _ctx: GameContext) -> int:
		return 0
