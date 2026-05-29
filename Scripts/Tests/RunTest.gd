extends Control

# ── RunTest ───────────────────────────────────────────────────────────────────
# Tests the RunStateMachine through several scenarios:
#   1. Unprotected server — run succeeds, agenda stolen
#   2. Single unrezzed ice — Corp declines to rez, run succeeds
#   3. Single rezzed barrier — subroutine ends run
#   4. Single rezzed barrier — Runner breaks subroutine, run succeeds
#   5. Rezzed code gate with conditional sub — Whitespace scenario
#
# Scene setup: same as AbilityTest (RunButton + OutputLabel in VBoxContainer).

@onready var output_label: RichTextLabel = $VBoxContainer/OutputLabel
@onready var run_button:   Button        = $VBoxContainer/RunButton

var _ability_registry: AbilityRegistry
var _pass_count: int = 0
var _fail_count: int = 0


func _ready() -> void:
	run_button.pressed.connect(_on_run_pressed)


func _on_run_pressed() -> void:
	output_label.clear()
	_pass_count = 0
	_fail_count = 0

	_ability_registry = AbilityRegistry.new()
	if not _ability_registry.load_from_file("res://Data/abilities.json"):
		_log("[color=red]Failed to load abilities.json[/color]")
		return

	_log("[b]── Run State Machine Tests ──[/b]\n")

	await _test_unprotected_server_steal()
	await _test_unrezzed_ice_corp_passes()
	await _test_rezzed_barrier_ends_run()
	await _test_rezzed_barrier_broken_run_succeeds()
	await _test_whitespace_conditional()

	_log("")
	_log("[b]Results: %d passed, %d failed[/b]" % [_pass_count, _fail_count])
	if _fail_count == 0:
		_log("[color=green]All tests passed.[/color]")
	else:
		_log("[color=red]%d test(s) failed.[/color]" % _fail_count)


# ── Tests ─────────────────────────────────────────────────────────────────────

func _test_unprotected_server_steal() -> void:
	_log("[b]Test 1[/b] — Unprotected remote: runner steals agenda")
	var ctx := _make_context()

	# Install an agenda in a remote server
	var remote := ctx.create_remote_server()
	var agenda_record := _fake_agenda("priority_requisition", 3, 2)
	var agenda_card   := InstalledCard.make(agenda_record, remote.server_id, "root", false)
	remote.install_in_root(agenda_card)

	ctx.corp_decision_maker   = _CorpPassAll.new()
	ctx.runner_decision_maker = _RunnerNeverBreakNeverJack.new()

	await _run(ctx, remote.server_id)

	_expect_eq("run_successful", int(ctx.run_successful), 1)
	_expect_eq("runner_agenda_points", ctx.runner_agenda_points(), 2)
	_expect_eq("agenda removed from server", remote.root.size(), 0)
	_log("")


func _test_unrezzed_ice_corp_passes() -> void:
	_log("[b]Test 2[/b] — Unrezzed ice, Corp declines to rez: run succeeds")
	var ctx := _make_context()

	var remote := ctx.create_remote_server()
	var palisade := _fake_ice("palisade", 0, ["barrier"])
	var ice_card  := InstalledCard.make(palisade, remote.server_id, "ice", false)
	remote.install_ice(ice_card)

	var agenda_record := _fake_agenda("hedge_fund_agenda", 3, 2)
	var agenda_card   := InstalledCard.make(agenda_record, remote.server_id, "root", false)
	remote.install_in_root(agenda_card)

	ctx.corp_decision_maker   = _CorpPassAll.new()   # never rezzes
	ctx.runner_decision_maker = _RunnerNeverBreakNeverJack.new()

	await _run(ctx, remote.server_id)

	_expect_eq("run_successful", int(ctx.run_successful), 1)
	_expect_eq("runner_agenda_points", ctx.runner_agenda_points(), 2)
	_log("")


func _test_rezzed_barrier_ends_run() -> void:
	_log("[b]Test 3[/b] — Rezzed Palisade, no breaker: subroutine ends run")
	var ctx := _make_context()

	var remote   := ctx.create_remote_server()
	var palisade := _fake_ice("palisade", 0, ["barrier"])
	var ice_card  := InstalledCard.make(palisade, remote.server_id, "ice", true)  # already rezzed
	remote.install_ice(ice_card)

	ctx.corp_decision_maker   = _CorpRezAll.new()
	ctx.runner_decision_maker = _RunnerNeverBreakNeverJack.new()  # breaks nothing

	await _run(ctx, remote.server_id)

	_expect_eq("run_successful", int(ctx.run_successful), 0)
	_expect_eq("runner_agenda_points", ctx.runner_agenda_points(), 0)
	_log("")


func _test_rezzed_barrier_broken_run_succeeds() -> void:
	_log("[b]Test 4[/b] — Rezzed Palisade, runner breaks subroutine: run succeeds")
	var ctx := _make_context()

	var remote   := ctx.create_remote_server()
	var palisade := _fake_ice("palisade", 0, ["barrier"])
	var ice_card  := InstalledCard.make(palisade, remote.server_id, "ice", true)
	remote.install_ice(ice_card)

	var agenda_record := _fake_agenda("breaking_news", 3, 1)
	var agenda_card   := InstalledCard.make(agenda_record, remote.server_id, "root", false)
	remote.install_in_root(agenda_card)

	ctx.corp_decision_maker   = _CorpRezAll.new()
	ctx.runner_decision_maker = _RunnerBreakAll.new()  # breaks all subroutines

	await _run(ctx, remote.server_id)

	_expect_eq("run_successful", int(ctx.run_successful), 1)
	_expect_eq("runner_agenda_points", ctx.runner_agenda_points(), 1)
	_log("")


func _test_whitespace_conditional() -> void:
	_log("[b]Test 5[/b] — Whitespace: sub 1 fires, sub 2 conditional on credits")
	var ctx := _make_context()
	ctx.runner_credits = 8

	var hq := ctx.get_server("hq")
	var whitespace_record := _fake_ice("whitespace", 0, ["code_gate"])
	var ice_card := InstalledCard.make(whitespace_record, "hq", "ice", true)
	hq.install_ice(ice_card)

	ctx.corp_decision_maker   = _CorpRezAll.new()
	ctx.runner_decision_maker = _RunnerNeverBreakNeverJack.new()

	await _run(ctx, "hq")

	# Sub 1: Runner loses 3 credits (8 -> 5)
	# Sub 2: condition is runner <= 6 credits — 5 <= 6 is true — end run fires
	_expect_eq("runner_credits after sub 1", ctx.runner_credits, 5)
	_expect_eq("run ended by sub 2", int(ctx.run_successful), 0)
	_log("")


# ── Helpers ───────────────────────────────────────────────────────────────────

func _run(ctx: GameContext, server_id: String) -> void:
	var machine := RunStateMachine.new(ctx, _ability_registry)
	# Log all phase changes to output
	machine.phase_changed.connect(func(p):
		_log("  [phase] %s" % RunStateMachine.Phase.keys()[p])
	)
	await machine.execute(server_id)


func _make_context() -> GameContext:
	var ctx          := GameContext.new()
	ctx.corp_credits = 10
	return ctx


func _fake_ice(id: String, rez_cost: int, subtypes: Array) -> CardRecord:
	var r           := CardRecord.new()
	r.id            = id
	r.title         = id.capitalize().replace("_", " ")
	r.card_type     = "ice"
	r.side          = "corp"
	r.cost          = rez_cost
	r.strength      = 2
	r.subtypes      = subtypes
	r.stripped_text = ""
	return r


func _fake_agenda(id: String, adv_req: int, points: int) -> CardRecord:
	var r                    := CardRecord.new()
	r.id                     = id
	r.title                  = id.capitalize().replace("_", " ")
	r.card_type              = "agenda"
	r.side                   = "corp"
	r.cost                   = -1
	r.advancement_requirement= adv_req
	r.agenda_points          = points
	r.stripped_text          = ""
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


# ── Stub decision makers ──────────────────────────────────────────────────────

# Corp never rezzes anything.
class _CorpPassAll:
	func choose_rez(_card: InstalledCard, _ctx: GameContext) -> bool:
		return false

# Corp always rezzes if it can afford it (card is already rezzed in tests,
# so this mainly matters for the non-ice rez window).
class _CorpRezAll:
	func choose_rez(_card: InstalledCard, _ctx: GameContext) -> bool:
		return true

# Runner never breaks subroutines and never jacks out.
class _RunnerNeverBreakNeverJack:
	func choose_break_subroutines(_ice: InstalledCard, _subs: Array, _ctx: GameContext) -> Array:
		return []
	func choose_jack_out(_ctx: GameContext) -> bool:
		return false
	func choose_trash(_card: CardRecord, _ctx: GameContext) -> bool:
		return false

# Runner breaks all subroutines and never jacks out.
class _RunnerBreakAll:
	func choose_break_subroutines(_ice: InstalledCard, subs: Array, _ctx: GameContext) -> Array:
		var all_indices: Array = []
		for i in range(subs.size()):
			all_indices.append(i)
		return all_indices
	func choose_jack_out(_ctx: GameContext) -> bool:
		return false
	func choose_trash(_card: CardRecord, _ctx: GameContext) -> bool:
		return false
