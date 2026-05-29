extends Control

# ── AbilityTest ───────────────────────────────────────────────────────────────
# Tests the AbilityInterpreter against all five initial ability definitions.
# Each test constructs a minimal GameContext, executes an ability, and verifies
# the expected outcome.
#
# Scene setup: same as DataLayerTest but with just a RichTextLabel (OutputLabel)
# and a Button (RunButton, text "Run Ability Tests").

@onready var output_label: RichTextLabel = $VBoxContainer/OutputLabel
@onready var run_button:   Button        = $VBoxContainer/RunButton

var _ability_registry: AbilityRegistry
var _interpreter:      AbilityInterpreter
var _pass_count:       int = 0
var _fail_count:       int = 0


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

	_interpreter = AbilityInterpreter.new()

	_log("[b]── Ability Interpreter Tests ──[/b]\n")

	await _test_hedge_fund()
	await _test_palisade()
	await _test_whitespace_sub_1()
	await _test_whitespace_sub_2_fires()
	await _test_whitespace_sub_2_blocked()
	await _test_urtica_cipher()
	await _test_retribution_tagged()
	await _test_retribution_untagged()

	_log("")
	_log("[b]Results: %d passed, %d failed[/b]" % [_pass_count, _fail_count])
	if _fail_count == 0:
		_log("[color=green]All tests passed.[/color]")
	else:
		_log("[color=red]%d test(s) failed.[/color]" % _fail_count)


# ── Tests ─────────────────────────────────────────────────────────────────────

func _test_hedge_fund() -> void:
	_log("[b]Hedge Fund[/b] — Corp gains 9 credits")
	var ctx := _make_context()
	ctx.corp_credits = 5

	var def: Dictionary = _ability_registry.get_on_play("hedge_fund") as Dictionary
	await _interpreter.execute_trigger(def, ctx)

	_expect_eq("corp_credits", ctx.corp_credits, 14)


func _test_palisade() -> void:
	_log("\n[b]Palisade[/b] — End the run")
	var ctx := _make_context()
	ctx.run_active = true

	var subs: Array = _ability_registry.get_subroutines("palisade")
	await _interpreter.execute_subroutine(subs[0] as Dictionary, ctx)

	_expect_eq("run_ended", int(ctx.run_ended), 1)


func _test_whitespace_sub_1() -> void:
	_log("\n[b]Whitespace sub 1[/b] — Runner loses 3 credits")
	var ctx := _make_context()
	ctx.runner_credits = 8

	var subs: Array = _ability_registry.get_subroutines("whitespace")
	await _interpreter.execute_subroutine(subs[0] as Dictionary, ctx)

	_expect_eq("runner_credits", ctx.runner_credits, 5)


func _test_whitespace_sub_2_fires() -> void:
	_log("\n[b]Whitespace sub 2[/b] — End run fires when runner has <= 6 credits")
	var ctx := _make_context()
	ctx.runner_credits = 4   # <= 6, condition should pass
	ctx.run_active = true

	var subs: Array = _ability_registry.get_subroutines("whitespace")
	await _interpreter.execute_subroutine(subs[1] as Dictionary, ctx)

	_expect_eq("run_ended (should fire)", int(ctx.run_ended), 1)


func _test_whitespace_sub_2_blocked() -> void:
	_log("\n[b]Whitespace sub 2[/b] — End run blocked when runner has > 6 credits")
	var ctx := _make_context()
	ctx.runner_credits = 10   # > 6, condition should fail
	ctx.run_active = true

	var subs: Array = _ability_registry.get_subroutines("whitespace")
	await _interpreter.execute_subroutine(subs[1] as Dictionary, ctx)

	_expect_eq("run_ended (should not fire)", int(ctx.run_ended), 0)


func _test_urtica_cipher() -> void:
	_log("\n[b]Urtica Cipher[/b] — Net damage = 2 + advancement counters")
	var ctx := _make_context()
	ctx.accessed_card_id = "urtica_cipher"
	# Put urtica in installed_cards with 3 advancement counters
	var remote := ctx.create_remote_server()
	var urtica_record := CardRecord.new()
	urtica_record.id        = "urtica_cipher"
	urtica_record.card_type = "asset"
	urtica_record.cost      = 0
	urtica_record.stripped_text = ""
	var urtica_card := InstalledCard.make(urtica_record, remote.server_id, "root", false)
	urtica_card.add_counter("advancement", 3)
	remote.install_in_root(urtica_card)
	# Give runner 6 cards in grip
	for i in range(6):
		ctx.runner_hand.append({"card_id": "runner_card_%d" % i})

	var def: Dictionary = _ability_registry.get_on_access("urtica_cipher") as Dictionary
	await _interpreter.execute_trigger(def, ctx)

	# Should deal 2 + 3 = 5 net damage → 5 cards trashed from grip of 6
	_expect_eq("runner_hand size after 5 damage", ctx.runner_hand.size(), 1)


func _test_retribution_tagged() -> void:
	_log("\n[b]Retribution[/b] — Trashes a runner program when tagged")
	var ctx := _make_context()
	ctx.runner_tags = 1
	var unity_record := CardRecord.new()
	unity_record.id        = "unity"
	unity_record.card_type = "program"
	unity_record.cost      = 0
	unity_record.stripped_text = ""
	var unity_card := InstalledCard.make(unity_record, "", "root", false)
	ctx.runner_rig.append(unity_card)
	# Use a simple auto-picker as decision maker
	ctx.corp_decision_maker = _AutoPicker.new()

	var def: Dictionary = _ability_registry.get_on_play("retribution") as Dictionary
	await _interpreter.execute_trigger(def, ctx)

	_expect_eq("runner_rig after trash", ctx.runner_rig.size(), 0)


func _test_retribution_untagged() -> void:
	_log("\n[b]Retribution[/b] — Does nothing when runner is not tagged")
	var ctx := _make_context()
	ctx.runner_tags = 0
	var unity_record := CardRecord.new()
	unity_record.id         = "unity"
	unity_record.card_type  = "program"
	unity_record.cost       = 0
	unity_record.stripped_text = ""
	var unity_card := InstalledCard.make(unity_record, "", "root", false)
	ctx.runner_rig.append(unity_card)

	var def: Dictionary = _ability_registry.get_on_play("retribution") as Dictionary
	await _interpreter.execute_trigger(def, ctx)

	_expect_eq("runner_rig unchanged", ctx.runner_rig.size(), 1)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_context() -> GameContext:
	var ctx := GameContext.new()
	ctx.run_active = false
	ctx.run_ended  = false
	return ctx

func _expect_eq(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_log("  [color=green]PASS[/color] %s = %s" % [label, str(actual)])
		_pass_count += 1
	else:
		_log("  [color=red]FAIL[/color] %s: expected %s, got %s" % [label, str(expected), str(actual)])
		_fail_count += 1

func _log(text: String) -> void:
	output_label.append_text(text + "\n")


# ── AutoPicker — minimal decision_maker that always picks the first candidate ─
class _AutoPicker:
	func choose_target(candidates: Array, _context: Dictionary) -> Variant:
		if candidates.is_empty():
			return null
		return candidates[0]
