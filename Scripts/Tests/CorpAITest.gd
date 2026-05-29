extends Control

# ── CorpAITest ────────────────────────────────────────────────────────────────
# Tests the CorpRunAI heuristic decision maker in isolation and integrated
# with the RunStateMachine.
#
# Scene setup: same as other test scenes (RunButton + OutputLabel in VBoxContainer).

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

	_log("[b]── Corp Run AI Tests ──[/b]\n")

	# Isolated heuristic tests
	_test_rez_affordable_ice()
	_test_no_rez_cannot_afford()
	_test_no_rez_would_go_broke()
	_test_no_rez_blank_ice()
	_test_rez_strength_zero_with_subroutines()

	# Integrated run tests
	await _test_ai_rezzes_palisade_stops_run()
	await _test_ai_holds_palisade_when_broke()
	await _test_ai_rezzes_whitespace_drains_runner()

	_log("")
	_log("[b]Results: %d passed, %d failed[/b]" % [_pass_count, _fail_count])
	if _fail_count == 0:
		_log("[color=green]All tests passed.[/color]")
	else:
		_log("[color=red]%d test(s) failed.[/color]" % _fail_count)


# ── Isolated heuristic tests ──────────────────────────────────────────────────

func _test_rez_affordable_ice() -> void:
	_log("[b]Heuristic 1[/b] — Rez affordable ice with strength")
	var ai  := CorpRunAI.new(_ability_registry)
	var ctx := _make_context(10)
	var ice := _make_ice("palisade", 3, 2, ["barrier"])
	_expect_eq("should rez", ai.choose_rez(ice, ctx), true)


func _test_no_rez_cannot_afford() -> void:
	_log("\n[b]Heuristic 2[/b] — Don't rez ice we can't afford")
	var ai  := CorpRunAI.new(_ability_registry)
	var ctx := _make_context(2)   # only 2 credits
	var ice := _make_ice("brân_1_0", 3, 3, ["barrier"])  # costs 3
	_expect_eq("should not rez", ai.choose_rez(ice, ctx), false)


func _test_no_rez_would_go_broke() -> void:
	_log("\n[b]Heuristic 3[/b] — Don't rez if it drops below credit floor")
	var ai  := CorpRunAI.new(_ability_registry)
	var ctx := _make_context(4)   # 4 credits
	var ice := _make_ice("palisade", 3, 2, ["barrier"])  # costs 3, leaves 1 — below floor of 2
	_expect_eq("should not rez", ai.choose_rez(ice, ctx), false)


func _test_no_rez_blank_ice() -> void:
	_log("\n[b]Heuristic 4[/b] — Don't rez strength-0 ice with no subroutines")
	var ai  := CorpRunAI.new(_ability_registry)
	var ctx := _make_context(10)
	# An ice with strength 0 and no entry in ability registry
	var ice := _make_ice("unknown_ice", 0, 0, ["barrier"])
	_expect_eq("should not rez blank ice", ai.choose_rez(ice, ctx), false)


func _test_rez_strength_zero_with_subroutines() -> void:
	_log("\n[b]Heuristic 5[/b] — Rez strength-0 ice that has implemented subroutines")
	var ai  := CorpRunAI.new(_ability_registry)
	var ctx := _make_context(10)
	# Whitespace has strength 0 but has subroutines in abilities.json
	var ice := _make_ice("whitespace", 0, 0, ["code_gate"])
	_expect_eq("should rez whitespace", ai.choose_rez(ice, ctx), true)


# ── Integrated run tests ──────────────────────────────────────────────────────

func _test_ai_rezzes_palisade_stops_run() -> void:
	_log("\n[b]Integrated 1[/b] — AI rezzes Palisade, subroutine ends run")
	var ctx := _make_context(10)

	var remote   := ctx.create_remote_server()
	var ice_card := _make_installed_ice("palisade", 3, 2, ["barrier"], remote.server_id)
	remote.install_ice(ice_card)

	ctx.corp_decision_maker   = CorpRunAI.new(_ability_registry)
	ctx.runner_decision_maker = _RunnerNeverBreak.new()

	await _run(ctx, remote.server_id)

	_expect_eq("run ended by AI-rezzed Palisade", int(ctx.run_successful), 0)
	_expect_eq("palisade is now rezzed", int(ice_card.is_rezzed), 1)
	_expect_eq("corp paid rez cost", ctx.corp_credits, 7)  # 10 - 3


func _test_ai_holds_palisade_when_broke() -> void:
	_log("\n[b]Integrated 2[/b] — AI holds Palisade when below credit floor")
	var ctx := _make_context(4)  # 4 credits, Palisade costs 3, leaves 1 — below floor

	var remote   := ctx.create_remote_server()
	var ice_card := _make_installed_ice("palisade", 3, 2, ["barrier"], remote.server_id)
	remote.install_ice(ice_card)

	var agenda_record := _make_agenda("priority_requisition", 3, 2)
	var agenda_card   := InstalledCard.make(agenda_record, remote.server_id, "root", false)
	remote.install_in_root(agenda_card)

	ctx.corp_decision_maker   = CorpRunAI.new(_ability_registry)
	ctx.runner_decision_maker = _RunnerNeverBreak.new()

	await _run(ctx, remote.server_id)

	# AI didn't rez, runner passed unrezzed ice and stole agenda
	_expect_eq("palisade not rezzed", int(ice_card.is_rezzed), 0)
	_expect_eq("run succeeded (AI held ice)", int(ctx.run_successful), 1)
	_expect_eq("runner stole agenda", ctx.runner_agenda_points(), 2)


func _test_ai_rezzes_whitespace_drains_runner() -> void:
	_log("\n[b]Integrated 3[/b] — AI rezzes Whitespace, runner loses credits")
	var ctx := _make_context(10)
	ctx.runner_credits = 8

	var remote   := ctx.create_remote_server()
	var ice_card := _make_installed_ice("whitespace", 0, 0, ["code_gate"], remote.server_id)
	remote.install_ice(ice_card)

	ctx.corp_decision_maker   = CorpRunAI.new(_ability_registry)
	ctx.runner_decision_maker = _RunnerNeverBreak.new()

	await _run(ctx, remote.server_id)

	# Whitespace costs 0 to rez; sub 1 drains 3 credits (8->5);
	# sub 2 condition: 5 <= 6, so end run fires
	_expect_eq("whitespace rezzed", int(ice_card.is_rezzed), 1)
	_expect_eq("runner lost 3 credits", ctx.runner_credits, 5)
	_expect_eq("run ended by sub 2", int(ctx.run_successful), 0)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_context(credits: int) -> GameContext:
	var ctx          := GameContext.new()
	ctx.corp_credits  = credits
	return ctx

func _make_ice(id: String, cost: int, strength: int, subtypes: Array) -> InstalledCard:
	var record    := CardRecord.new()
	record.id      = id
	record.title   = id
	record.card_type = "ice"
	record.side    = "corp"
	record.cost    = cost
	record.strength= strength
	record.subtypes= subtypes
	record.stripped_text = ""
	var card := InstalledCard.make(record, "hq", "ice", false)
	return card

func _make_installed_ice(id: String, cost: int, strength: int, subtypes: Array, server_id: String) -> InstalledCard:
	var record    := CardRecord.new()
	record.id      = id
	record.title   = id
	record.card_type = "ice"
	record.side    = "corp"
	record.cost    = cost
	record.strength= strength
	record.subtypes= subtypes
	record.stripped_text = ""
	return InstalledCard.make(record, server_id, "ice", false)

func _make_agenda(id: String, adv_req: int, points: int) -> CardRecord:
	var r                     := CardRecord.new()
	r.id                      = id
	r.title                   = id
	r.card_type               = "agenda"
	r.side                    = "corp"
	r.cost                    = -1
	r.advancement_requirement = adv_req
	r.agenda_points           = points
	r.stripped_text           = ""
	return r

func _run(ctx: GameContext, server_id: String) -> void:
	var machine := RunStateMachine.new(ctx, _ability_registry)
	machine.phase_changed.connect(func(p):
		_log("  [phase] %s" % RunStateMachine.Phase.keys()[p])
	)
	await machine.execute(server_id)

func _expect_eq(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_log("  [color=green]PASS[/color] %s = %s" % [label, str(actual)])
		_pass_count += 1
	else:
		_log("  [color=red]FAIL[/color] %s: expected %s, got %s" % [label, str(expected), str(actual)])
		_fail_count += 1

func _log(text: String) -> void:
	output_label.append_text(text + "\n")


# ── Stub Runner decision maker ────────────────────────────────────────────────

class _RunnerNeverBreak:
	func choose_break_subroutines(_ice: InstalledCard, _subs: Array, _ctx: GameContext) -> Array:
		return []
	func choose_jack_out(_ctx: GameContext) -> bool:
		return false
	func choose_trash(_card: CardRecord, _ctx: GameContext) -> bool:
		return false
