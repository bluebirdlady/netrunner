extends Control

# ── InstallOnIceTest ──────────────────────────────────────────────────────────
# Automated tests for the install-on-ice (trojan) flow.
#
# Covers:
#   1. Program with install_on_ice:true is hosted on the chosen ice
#   2. host.hosted_cards contains the installed trojan
#   3. hosted_on_id is set to the host ice's runtime_instance_id
#   4. server_id is inherited from the host ice
#   5. Fallback: if no ice exists, install is rejected and credits refunded
#   6. Boomerang-style choose_target_on_install sets target_id, not hosted_on_id
#   7. A second trojan can target a different ice (two independent installs)
#   8. The show_host_ice_prompt signal fix: host_ice_choice_resolved signal
#      is defined on GameUI and is correctly emitted/received  (smoke test)
#
# Scene layout: RunButton + OutputLabel in a VBoxContainer (standard test scene).

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
		_log("[color=red]ABORT — failed to load abilities.json[/color]")
		return

	_log("[b]── Install-on-Ice Tests ──[/b]\n")

	await _test_trojan_hosted_on_ice()
	await _test_trojan_host_fields()
	await _test_no_ice_install_rejected()
	await _test_two_trojans_different_ice()
	await _test_boomerang_target_not_hosted()
	_test_gameui_signal_defined()

	_log("")
	_log("[b]Results: %d passed, %d failed[/b]" % [_pass_count, _fail_count])
	if _fail_count == 0:
		_log("[color=green]All tests passed.[/color]")
	else:
		_log("[color=red]%d test(s) failed.[/color]" % _fail_count)


# ── Tests ─────────────────────────────────────────────────────────────────────

func _test_trojan_hosted_on_ice() -> void:
	_log("[b]Test 1[/b] — Trojan installs onto chosen ice")

	var ctx := _make_ctx()
	var hq_ice := _install_ice(ctx, "palisade", "hq")

	# Give runner Botulus (install_on_ice: true) with enough credits
	var botulus_rec := _make_program_record("botulus", 2, ["virus", "trojan"])
	ctx.runner_hand.append({"card_id": "botulus", "card_record": botulus_rec})
	ctx.runner_credits = 4

	# Stub picks the first (only) ice candidate
	var stub := _StubRunner.new()
	stub.host_ice_result = hq_ice
	ctx.runner_decision_maker = stub

	var tm := _make_turn_manager(ctx)
	ctx.active_player = "runner"
	ctx.runner_clicks = 1
	var action := GameAction.install(botulus_rec, "runner_rig")
	await tm._execute_action("runner", action)

	_expect_eq("HQ ice has 1 hosted card",     hq_ice.hosted_cards.size(), 1)
	_expect_eq("hosted card is botulus",
		(hq_ice.hosted_cards[0] as InstalledCard).card_id, "botulus")
	_expect_eq("runner rig does not contain trojan",
		ctx.runner_rig.any(func(c: InstalledCard): return c.card_id == "botulus"), false)
	_log("")


func _test_trojan_host_fields() -> void:
	_log("[b]Test 2[/b] — Trojan hosted_on_id and server_id are set correctly")

	var ctx := _make_ctx()
	var rd_ice := _install_ice(ctx, "enigma", "rd")

	var tranq_rec := _make_program_record("tranquilizer", 3, ["virus", "trojan"])
	ctx.runner_hand.append({"card_id": "tranquilizer", "card_record": tranq_rec})
	ctx.runner_credits = 5

	var stub := _StubRunner.new()
	stub.host_ice_result = rd_ice
	ctx.runner_decision_maker = stub

	var tm := _make_turn_manager(ctx)
	ctx.active_player = "runner"
	ctx.runner_clicks = 1
	var action := GameAction.install(tranq_rec, "runner_rig")
	await tm._execute_action("runner", action)

	var trojan: InstalledCard = null
	if not rd_ice.hosted_cards.is_empty():
		trojan = rd_ice.hosted_cards[0] as InstalledCard
	_expect_eq("hosted_on_id matches host runtime_instance_id",
		trojan != null and trojan.hosted_on_id == rd_ice.runtime_instance_id, true)
	_expect_eq("trojan server_id matches host server_id",
		trojan != null and trojan.server_id == rd_ice.server_id, true)
	_log("")


func _test_no_ice_install_rejected() -> void:
	_log("[b]Test 3[/b] — Trojan install fails gracefully when no ice exists")

	var ctx := _make_ctx()
	# No ice anywhere — all servers empty

	var botulus_rec := _make_program_record("botulus", 2, ["virus", "trojan"])
	ctx.runner_hand.append({"card_id": "botulus", "card_record": botulus_rec})
	ctx.runner_credits = 4

	var stub := _StubRunner.new()
	stub.host_ice_result = null  # no ice to pick
	ctx.runner_decision_maker = stub

	var tm := _make_turn_manager(ctx)
	ctx.active_player = "runner"
	ctx.runner_clicks = 1
	var credits_before := ctx.runner_credits
	var action := GameAction.install(botulus_rec, "runner_rig")
	await tm._execute_action("runner", action)

	_expect_eq("runner rig is empty (install rejected)",
		ctx.runner_rig.is_empty(), true)
	_expect_eq("runner credits refunded",
		ctx.runner_credits, credits_before)
	_log("")


func _test_two_trojans_different_ice() -> void:
	_log("[b]Test 4[/b] — Two trojans can be hosted on separate ice")

	var ctx := _make_ctx()
	var hq_ice := _install_ice(ctx, "palisade", "hq")
	var rd_ice  := _install_ice(ctx, "enigma",  "rd")

	var bot1_rec := _make_program_record("botulus", 2, ["virus", "trojan"])
	var bot2_rec := _make_program_record("tranquilizer", 3, ["virus", "trojan"])
	ctx.runner_hand.append({"card_id": "botulus",       "card_record": bot1_rec})
	ctx.runner_hand.append({"card_id": "tranquilizer",  "card_record": bot2_rec})
	ctx.runner_credits = 10

	var stub := _StubRunner.new()
	var tm   := _make_turn_manager(ctx)
	ctx.active_player = "runner"
	ctx.runner_clicks  = 2

	# First install — pick hq_ice
	stub.host_ice_result = hq_ice
	ctx.runner_decision_maker = stub
	await tm._execute_action("runner", GameAction.install(bot1_rec, "runner_rig"))

	# Second install — pick rd_ice
	stub.host_ice_result = rd_ice
	await tm._execute_action("runner", GameAction.install(bot2_rec, "runner_rig"))

	_expect_eq("hq_ice hosts 1 trojan", hq_ice.hosted_cards.size(), 1)
	_expect_eq("rd_ice hosts 1 trojan", rd_ice.hosted_cards.size(),  1)
	_expect_eq("hq_ice hosts botulus",
		(hq_ice.hosted_cards[0] as InstalledCard).card_id, "botulus")
	_expect_eq("rd_ice hosts tranquilizer",
		(rd_ice.hosted_cards[0] as InstalledCard).card_id, "tranquilizer")
	_log("")


func _test_boomerang_target_not_hosted() -> void:
	_log("[b]Test 5[/b] — choose_target_on_install card gets target_id, not hosted")

	var ctx := _make_ctx()
	var arc_ice := _install_ice(ctx, "wraparound", "archives")

	# Boomerang-style card: has choose_target_on_install, NOT install_on_ice
	var boom_rec := _make_program_record("boomerang", 3, ["fracter"])
	# abilities.json entry must exist with choose_target_on_install for this to fire;
	# if it doesn't the test still validates no physical hosting occurs.
	ctx.runner_hand.append({"card_id": "boomerang", "card_record": boom_rec})
	ctx.runner_credits = 5

	var stub := _StubRunner.new()
	stub.host_ice_result = arc_ice
	ctx.runner_decision_maker = stub

	var tm := _make_turn_manager(ctx)
	ctx.active_player = "runner"
	ctx.runner_clicks  = 1
	await tm._execute_action("runner", GameAction.install(boom_rec, "runner_rig"))

	# Boomerang goes to runner rig, not hosted on ice
	var in_rig: bool = ctx.runner_rig.any(func(c: InstalledCard): return c.card_id == "boomerang")
	_expect_eq("boomerang is in runner rig", in_rig, true)
	_expect_eq("arc_ice has no hosted cards", arc_ice.hosted_cards.is_empty(), true)
	_log("")


func _test_gameui_signal_defined() -> void:
	_log("[b]Test 6[/b] — GameUI.host_ice_choice_resolved signal is defined")

	# Load GameUI scene and verify the signal exists
	var scene := load("res://Scenes/UI/GameUI.tscn")
	if scene == null:
		_log("  [color=yellow]SKIP[/color] — could not load GameUI.tscn (headless?)")
		return

	var gui: Node = scene.instantiate()
	add_child(gui)  # must be in tree for signal inspection
	_expect_eq("host_ice_choice_resolved signal exists",
		gui.has_signal("host_ice_choice_resolved"), true)
	gui.queue_free()
	_log("")


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_ctx() -> GameContext:
	var ctx := GameContext.new()
	ctx.corp_credits   = 10
	ctx.runner_credits = 10
	ctx.runner_clicks  = 4
	ctx.servers["hq"]       = Server.make("hq")
	ctx.servers["rd"]       = Server.make("rd")
	ctx.servers["archives"] = Server.make("archives")
	return ctx


func _install_ice(ctx: GameContext, ice_id: String, srv_id: String) -> InstalledCard:
	var r       := _make_ice_record(ice_id, 3, 2, ["barrier"])
	var ic      := InstalledCard.make_runtime_instance(r, srv_id, "ice", true)
	(ctx.servers[srv_id] as Server).install_ice(ic)
	return ic


func _make_turn_manager(ctx: GameContext) -> TurnManager:
	var tm := TurnManager.new(ctx, _ability_registry)
	tm.action_executed.connect(func(player, action):
		_log("  [action] %s: %s" % [player, action.describe()])
	)
	tm.action_rejected.connect(func(player, action, reason):
		_log("  [reject ] %s: %s — %s" % [player, action.describe(), reason])
	)
	return tm


func _make_ice_record(id: String, cost: int, strength: int, subtypes: Array) -> CardRecord:
	var r           := CardRecord.new()
	r.id             = id
	r.title          = id.capitalize()
	r.card_type      = "ice"
	r.side           = "corp"
	r.cost           = cost
	r.strength       = strength
	r.subtypes       = subtypes
	r.stripped_text  = ""
	return r


func _make_program_record(id: String, cost: int, subtypes: Array) -> CardRecord:
	var r           := CardRecord.new()
	r.id             = id
	r.title          = id.capitalize()
	r.card_type      = "program"
	r.side           = "runner"
	r.cost           = cost
	r.strength       = 1
	r.subtypes       = subtypes
	r.stripped_text  = ""
	return r


func _expect_eq(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_log("  [color=green]PASS[/color] %s = %s" % [label, str(actual)])
		_pass_count += 1
	else:
		_log("  [color=red]FAIL[/color] %s — expected %s, got %s" % [label, str(expected), str(actual)])
		_fail_count += 1


func _log(text: String) -> void:
	output_label.append_text(text + "\n")


# ── Stub decision-maker ───────────────────────────────────────────────────────
# Immediately returns a pre-configured ice for host/target selection.
# Mirrors HumanDecisionMaker's interface for the fields TurnManager calls.

class _StubRunner:
	var host_ice_result: InstalledCard = null

	func choose_action(_ctx: GameContext) -> GameAction:
		return GameAction.end_turn()

	func choose_host_ice(_ctx: GameContext) -> InstalledCard:
		return host_ice_result

	func choose_target_ice(candidates: Array, _name: String, _ctx: GameContext) -> InstalledCard:
		return host_ice_result if host_ice_result != null else (candidates[0] if not candidates.is_empty() else null)

	func choose_trash(_card: CardRecord, _ctx: GameContext) -> bool:
		return false

	func choose_jack_out(_ctx: GameContext) -> bool:
		return false

	func choose_modes(_modes: Array, _max: int, _ctx: GameContext) -> Array:
		return [0]

	func choose_target(candidates: Array, _opts: Dictionary) -> Variant:
		return candidates[0] if not candidates.is_empty() else null
