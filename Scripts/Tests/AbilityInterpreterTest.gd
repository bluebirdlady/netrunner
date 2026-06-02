extends Control

# ── AbilityInterpreterTest ────────────────────────────────────────────────────
# Comprehensive integration tests for AbilityInterpreter and EncounterProcessor.
# Each test builds a minimal GameContext, executes an ability or encounter action,
# and asserts the expected outcome.
#
# Groups:
#   A  — Core trigger effects (inline ability definitions, no file load)
#   B  — Condition evaluation
#   C  — Counter effects (add_self_counters, add_self_counter_if_server)
#   D  — Subroutine execution
#   E  — Encounter actions (EncounterProcessor, also inline registry)
#   F  — Integration tests against the real abilities.json
#
# Scene setup: Control > VBoxContainer > [RunButton (Button), OutputLabel (RichTextLabel)]

@onready var output_label: RichTextLabel = $VBoxContainer/OutputLabel
@onready var run_button:   Button        = $VBoxContainer/RunButton

var _interpreter: AbilityInterpreter
var _pass_count:  int = 0
var _fail_count:  int = 0


func _ready() -> void:
	run_button.pressed.connect(_on_run_pressed)


func _on_run_pressed() -> void:
	output_label.clear()
	_pass_count = 0
	_fail_count = 0
	_interpreter = AbilityInterpreter.new()

	_log("[b]── Group A: Core trigger effects ──[/b]\n")
	await _test_a1_gain_credits_corp()
	await _test_a2_gain_credits_runner()
	await _test_a3_draw_cards_runner()
	await _test_a4_draw_cards_corp()
	await _test_a5_deal_damage_net()
	await _test_a6_deal_damage_core()
	await _test_a7_give_tags()
	await _test_a8_remove_tags_clamped()
	await _test_a9_end_run()
	await _test_a10_lose_credits()

	_log("\n[b]── Group B: Condition evaluation ──[/b]\n")
	await _test_b1_tagged_condition_fires()
	await _test_b2_tagged_condition_blocked()
	await _test_b3_credits_lte_fires()
	await _test_b4_credits_lte_blocked()
	await _test_b5_and_condition_passes()
	await _test_b6_and_condition_fails()
	await _test_b7_or_condition_passes()
	await _test_b8_or_condition_blocked()
	await _test_b9_not_condition()

	_log("\n[b]── Group C: Counter effects ──[/b]\n")
	await _test_c1_add_self_counters()
	await _test_c2_add_self_counter_if_server_central_hq()
	await _test_c3_add_self_counter_if_server_central_rd()
	await _test_c4_add_self_counter_if_server_remote_blocked()

	_log("\n[b]── Group D: Subroutine execution ──[/b]\n")
	await _test_d1_sub_end_run()
	await _test_d2_sub_conditional_fires()
	await _test_d3_sub_conditional_blocked()
	await _test_d4_sub_deal_damage()

	_log("\n[b]── Group E: Encounter actions ──[/b]\n")
	await _test_e1_boost_strength_success()
	await _test_e2_boost_strength_no_credits()
	await _test_e3_break_subroutine_success()
	await _test_e4_break_subroutine_strength_fails()
	await _test_e5_break_subroutine_no_credits()
	await _test_e6_break_all_success()
	await _test_e7_break_all_partial_credits()
	await _test_e8_weaken_ice_success()
	await _test_e9_weaken_ice_no_counters()
	await _test_e10_break_with_click_success()
	await _test_e11_break_with_click_no_clicks()
	await _test_e12_spend_hosted_credits_success()
	await _test_e13_spend_hosted_credits_empty()

	_log("\n[b]── Group F: Integration (abilities.json) ──[/b]\n")
	var reg := AbilityRegistry.new()
	if reg.load_from_file("res://Data/abilities.json"):
		await _test_f1_hedge_fund(reg)
		await _test_f2_palisade_sub(reg)
		await _test_f3_urtica_cipher_access(reg)
		await _test_f4_whitespace_sub2_fires(reg)
		await _test_f5_whitespace_sub2_blocked(reg)
	else:
		_log("  [color=yellow]SKIP — abilities.json not loaded[/color]")

	_log("")
	_log("[b]Results: %d passed, %d failed[/b]" % [_pass_count, _fail_count])
	if _fail_count == 0:
		_log("[color=green]All tests passed.[/color]")
	else:
		_log("[color=red]%d test(s) failed.[/color]" % _fail_count)


# ── Group A: Core trigger effects ─────────────────────────────────────────────

func _test_a1_gain_credits_corp() -> void:
	_log("[b]A1[/b] — Corp gains 9 credits")
	var ctx := _make_ctx()
	ctx.corp_credits = 5
	var def := _trigger([_effect("gain_credits", {"subject": "corp", "amount": 9})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp_credits", ctx.corp_credits, 14)


func _test_a2_gain_credits_runner() -> void:
	_log("[b]A2[/b] — Runner gains 4 credits")
	var ctx := _make_ctx()
	ctx.runner_credits = 3
	var def := _trigger([_effect("gain_credits", {"subject": "runner", "amount": 4})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("runner_credits", ctx.runner_credits, 7)


func _test_a3_draw_cards_runner() -> void:
	_log("[b]A3[/b] — Runner draws 2 cards from a 3-card deck")
	var ctx := _make_ctx()
	for i in range(3):
		ctx.runner_deck.append(_make_card_record("sure_gamble_%d" % i, "event", "runner"))
	var hand_before: int = ctx.runner_hand.size()
	var def := _trigger([_effect("draw_cards", {"subject": "runner", "amount": 2})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("runner_hand grew by 2", ctx.runner_hand.size(), hand_before + 2)
	_expect_eq("runner_deck shrank by 2", ctx.runner_deck.size(), 1)


func _test_a4_draw_cards_corp() -> void:
	_log("[b]A4[/b] — Corp draws 1 card from deck")
	var ctx := _make_ctx()
	ctx.corp_deck.append(_make_card_record("hedge_fund", "operation", "corp"))
	ctx.corp_deck.append(_make_card_record("ice_wall", "ice", "corp"))
	var hand_before: int = ctx.corp_hand.size()
	var def := _trigger([_effect("draw_cards", {"subject": "corp", "amount": 1})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp_hand grew by 1", ctx.corp_hand.size(), hand_before + 1)
	_expect_eq("corp_deck shrank by 1", ctx.corp_deck.size(), 1)


func _test_a5_deal_damage_net() -> void:
	_log("[b]A5[/b] — 3 net damage removes 3 cards from a 5-card hand")
	var ctx := _make_ctx()
	for i in range(5):
		ctx.runner_hand.append({"card_id": "card_%d" % i, "card_record": _make_card_record("c%d" % i, "event", "runner")})
	var def := _trigger([_effect("deal_damage", {"damage_type": "net", "amount": 3})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("runner_hand size", ctx.runner_hand.size(), 2)
	_expect_eq("runner_discard grew", ctx.runner_discard.size(), 3)
	_expect_eq("game not over", ctx.game_over, false)


func _test_a6_deal_damage_core() -> void:
	_log("[b]A6[/b] — 1 core damage increments runner_core_damage_taken and removes a card")
	var ctx := _make_ctx()
	for i in range(3):
		ctx.runner_hand.append({"card_id": "card_%d" % i, "card_record": _make_card_record("c%d" % i, "event", "runner")})
	var core_before: int = ctx.runner_core_damage_taken
	var def := _trigger([_effect("deal_damage", {"damage_type": "core", "amount": 1})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("runner_core_damage_taken increased", ctx.runner_core_damage_taken, core_before + 1)
	_expect_eq("one card removed from hand", ctx.runner_hand.size(), 2)


func _test_a7_give_tags() -> void:
	_log("[b]A7[/b] — Runner receives 2 tags")
	var ctx := _make_ctx()
	ctx.runner_tags = 0
	var def := _trigger([_effect("give_tags", {"amount": 2})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("runner_tags", ctx.runner_tags, 2)


func _test_a8_remove_tags_clamped() -> void:
	_log("[b]A8[/b] — remove_tags is clamped to 0 (cannot go negative)")
	var ctx := _make_ctx()
	ctx.runner_tags = 1
	# Remove 5 but only 1 exists — should clamp to 0, not go negative.
	var def := _trigger([_effect("remove_tags", {"amount": 5})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("runner_tags clamped to 0", ctx.runner_tags, 0)


func _test_a9_end_run() -> void:
	_log("[b]A9[/b] — end_run sets run_ended = true")
	var ctx := _make_ctx()
	ctx.run_active = true
	ctx.run_ended  = false
	var def := _trigger([_effect("end_run", {})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("run_ended", ctx.run_ended, true)


func _test_a10_lose_credits() -> void:
	_log("[b]A10[/b] — Runner loses credits (clamped to 0)")
	var ctx := _make_ctx()
	ctx.runner_credits = 4
	# Losing 10 from 4 should clamp to 0, not go negative.
	var def := _trigger([_effect("lose_credits", {"subject": "runner", "amount": 10})])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("runner_credits clamped to 0", ctx.runner_credits, 0)


# ── Group B: Condition evaluation ─────────────────────────────────────────────

func _test_b1_tagged_condition_fires() -> void:
	_log("[b]B1[/b] — runner_is_tagged condition fires when runner has a tag")
	var ctx := _make_ctx()
	ctx.runner_tags    = 1
	ctx.corp_credits   = 5
	var def := {
		"condition": {"type": "runner_is_tagged"},
		"effects":   [_effect("gain_credits", {"subject": "corp", "amount": 3})]
	}
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp gained credits", ctx.corp_credits, 8)


func _test_b2_tagged_condition_blocked() -> void:
	_log("[b]B2[/b] — runner_is_tagged condition is blocked when runner is clean")
	var ctx := _make_ctx()
	ctx.runner_tags  = 0
	ctx.corp_credits = 5
	var def := {
		"condition": {"type": "runner_is_tagged"},
		"effects":   [_effect("gain_credits", {"subject": "corp", "amount": 3})]
	}
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp credits unchanged", ctx.corp_credits, 5)


func _test_b3_credits_lte_fires() -> void:
	_log("[b]B3[/b] — credits_compare lte fires when runner credits ≤ threshold")
	var ctx := _make_ctx()
	ctx.runner_credits = 4
	ctx.run_active     = true
	ctx.run_ended      = false
	var def := {
		"condition": {
			"type": "credits_compare",
			"params": {"subject": "runner", "operator": "lte", "value": 6}
		},
		"effects": [_effect("end_run", {})]
	}
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("run ended (credits ≤ 6)", ctx.run_ended, true)


func _test_b4_credits_lte_blocked() -> void:
	_log("[b]B4[/b] — credits_compare lte is blocked when runner credits > threshold")
	var ctx := _make_ctx()
	ctx.runner_credits = 10
	ctx.run_active     = true
	ctx.run_ended      = false
	var def := {
		"condition": {
			"type": "credits_compare",
			"params": {"subject": "runner", "operator": "lte", "value": 6}
		},
		"effects": [_effect("end_run", {})]
	}
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("run not ended (credits > 6)", ctx.run_ended, false)


func _test_b5_and_condition_passes() -> void:
	_log("[b]B5[/b] — 'and' condition passes when all sub-conditions pass")
	var ctx := _make_ctx()
	ctx.runner_tags    = 2
	ctx.runner_credits = 3
	ctx.corp_credits   = 5
	var def := {
		"condition": {
			"type": "and",
			"conditions": [
				{"type": "runner_is_tagged"},
				{"type": "credits_compare", "params": {"subject": "runner", "operator": "lte", "value": 5}}
			]
		},
		"effects": [_effect("gain_credits", {"subject": "corp", "amount": 2})]
	}
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp gained credits (both conditions met)", ctx.corp_credits, 7)


func _test_b6_and_condition_fails() -> void:
	_log("[b]B6[/b] — 'and' condition fails when one sub-condition fails")
	var ctx := _make_ctx()
	ctx.runner_tags    = 0   # not tagged — first condition fails
	ctx.runner_credits = 3
	ctx.corp_credits   = 5
	var def := {
		"condition": {
			"type": "and",
			"conditions": [
				{"type": "runner_is_tagged"},
				{"type": "credits_compare", "params": {"subject": "runner", "operator": "lte", "value": 5}}
			]
		},
		"effects": [_effect("gain_credits", {"subject": "corp", "amount": 2})]
	}
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp credits unchanged (and failed)", ctx.corp_credits, 5)


func _test_b7_or_condition_passes() -> void:
	_log("[b]B7[/b] — 'or' condition passes when one sub-condition passes")
	var ctx := _make_ctx()
	ctx.runner_tags    = 1   # tagged — first passes; second will fail (credits not ≤ 2)
	ctx.runner_credits = 10
	ctx.corp_credits   = 5
	var def := {
		"condition": {
			"type": "or",
			"conditions": [
				{"type": "runner_is_tagged"},
				{"type": "credits_compare", "params": {"subject": "runner", "operator": "lte", "value": 2}}
			]
		},
		"effects": [_effect("gain_credits", {"subject": "corp", "amount": 3})]
	}
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp gained credits (or passed)", ctx.corp_credits, 8)


func _test_b8_or_condition_blocked() -> void:
	_log("[b]B8[/b] — 'or' condition is blocked when no sub-condition passes")
	var ctx := _make_ctx()
	ctx.runner_tags    = 0   # not tagged
	ctx.runner_credits = 10  # credits > 2
	ctx.corp_credits   = 5
	var def := {
		"condition": {
			"type": "or",
			"conditions": [
				{"type": "runner_is_tagged"},
				{"type": "credits_compare", "params": {"subject": "runner", "operator": "lte", "value": 2}}
			]
		},
		"effects": [_effect("gain_credits", {"subject": "corp", "amount": 3})]
	}
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp credits unchanged (or failed)", ctx.corp_credits, 5)


func _test_b9_not_condition() -> void:
	_log("[b]B9[/b] — 'not' condition inverts a passing condition")
	var ctx := _make_ctx()
	ctx.runner_tags  = 1   # tagged — but 'not' tagged should block
	ctx.corp_credits = 5
	var def := {
		"condition": {
			"type": "not",
			"condition": {"type": "runner_is_tagged"}
		},
		"effects": [_effect("gain_credits", {"subject": "corp", "amount": 3})]
	}
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp credits unchanged (not-tagged blocked)", ctx.corp_credits, 5)


# ── Group C: Counter effects ──────────────────────────────────────────────────

func _test_c1_add_self_counters() -> void:
	_log("[b]C1[/b] — add_self_counters places a power counter on the owning card")
	var ctx := _make_ctx()
	# Install a card and point current_event_data at it.
	var remote := ctx.create_remote_server()
	var rec  := _make_card_record("rezeki", "program", "runner")
	var card := InstalledCard.make(rec, remote.server_id, "root", true)
	card.runtime_instance_id = "rezeki_test_01"
	remote.install_in_root(card)
	ctx.current_event_data = {"card_instance_id": "rezeki_test_01"}
	# Effect: add 2 power counters
	var def := _trigger([{"type": "add_self_counters", "counter": "power", "amount": 2}])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("power counters on card", card.get_counter("power"), 2)


func _test_c2_add_self_counter_if_server_central_hq() -> void:
	_log("[b]C2[/b] — add_self_counter_if_server adds a virus counter on a successful HQ run")
	var ctx := _make_ctx()
	var leech := _make_rig_card(ctx, "leech", "program", "leech_iid_01")
	ctx.current_event_data = {
		"card_instance_id": "leech_iid_01",
		"server_id": "hq"
	}
	var def := _trigger([{
		"type": "add_self_counter_if_server",
		"counter": "virus",
		"amount": 1,
		"params": {"server": "central"}
	}])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("virus counter added (HQ is central)", leech.get_counter("virus"), 1)


func _test_c3_add_self_counter_if_server_central_rd() -> void:
	_log("[b]C3[/b] — add_self_counter_if_server adds a virus counter on a successful R&D run")
	var ctx := _make_ctx()
	var leech := _make_rig_card(ctx, "leech", "program", "leech_iid_02")
	ctx.current_event_data = {
		"card_instance_id": "leech_iid_02",
		"server_id": "rd"
	}
	var def := _trigger([{
		"type": "add_self_counter_if_server",
		"counter": "virus",
		"amount": 1,
		"params": {"server": "central"}
	}])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("virus counter added (R&D is central)", leech.get_counter("virus"), 1)


func _test_c4_add_self_counter_if_server_remote_blocked() -> void:
	_log("[b]C4[/b] — add_self_counter_if_server does NOT add a counter on a remote run")
	var ctx := _make_ctx()
	var leech := _make_rig_card(ctx, "leech", "program", "leech_iid_03")
	ctx.current_event_data = {
		"card_instance_id": "leech_iid_03",
		"server_id": "remote_0"
	}
	var def := _trigger([{
		"type": "add_self_counter_if_server",
		"counter": "virus",
		"amount": 1,
		"params": {"server": "central"}
	}])
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("no virus counter added (remote run)", leech.get_counter("virus"), 0)


# ── Group D: Subroutine execution ─────────────────────────────────────────────

func _test_d1_sub_end_run() -> void:
	_log("[b]D1[/b] — End-the-run subroutine fires unconditionally")
	var ctx := _make_ctx()
	ctx.run_active = true
	ctx.run_ended  = false
	var sub := {"effects": [_effect("end_run", {})]}
	var result: bool = await _interpreter.execute_subroutine(sub, ctx)
	_expect_eq("subroutine returned true", result, true)
	_expect_eq("run_ended", ctx.run_ended, true)


func _test_d2_sub_conditional_fires() -> void:
	_log("[b]D2[/b] — Conditional subroutine fires when condition passes")
	var ctx := _make_ctx()
	ctx.runner_tags  = 1
	ctx.corp_credits = 5
	var sub := {
		"condition": {"type": "runner_is_tagged"},
		"effects":   [_effect("gain_credits", {"subject": "corp", "amount": 4})]
	}
	var result: bool = await _interpreter.execute_subroutine(sub, ctx)
	_expect_eq("subroutine returned true", result, true)
	_expect_eq("corp gained credits", ctx.corp_credits, 9)


func _test_d3_sub_conditional_blocked() -> void:
	_log("[b]D3[/b] — Conditional subroutine is blocked when condition fails")
	var ctx := _make_ctx()
	ctx.runner_tags  = 0
	ctx.corp_credits = 5
	var sub := {
		"condition": {"type": "runner_is_tagged"},
		"effects":   [_effect("gain_credits", {"subject": "corp", "amount": 4})]
	}
	var result: bool = await _interpreter.execute_subroutine(sub, ctx)
	_expect_eq("subroutine returned false (condition blocked)", result, false)
	_expect_eq("corp credits unchanged", ctx.corp_credits, 5)


func _test_d4_sub_deal_damage() -> void:
	_log("[b]D4[/b] — Damage subroutine removes a card from hand")
	var ctx := _make_ctx()
	for i in range(4):
		ctx.runner_hand.append({"card_id": "c%d" % i, "card_record": _make_card_record("c%d" % i, "event", "runner")})
	var sub := {"effects": [_effect("deal_damage", {"damage_type": "net", "amount": 2})]}
	await _interpreter.execute_subroutine(sub, ctx)
	_expect_eq("two cards trashed from hand", ctx.runner_hand.size(), 2)


# ── Group E: Encounter actions ────────────────────────────────────────────────

func _test_e1_boost_strength_success() -> void:
	_log("[b]E1[/b] — boost_strength: credits deducted and breaker strength increased")
	var setup := _make_encounter_setup(3, 1, 1, 1, 1)
	var enc: EncounterState = setup["enc"]
	var ctx: GameContext    = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	var breaker: InstalledCard = setup["breaker"]
	ctx.runner_credits = 5

	var action := {"type": "boost_strength", "card_id": "t_breaker", "times": 2}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("boost succeeded", ok, true)
	_expect_eq("credits deducted (2 × 1cr)", ctx.runner_credits, 3)
	_expect_eq("breaker strength boosted by 2", enc.get_breaker_strength(breaker), 3)


func _test_e2_boost_strength_no_credits() -> void:
	_log("[b]E2[/b] — boost_strength: fails when runner cannot afford it")
	var setup := _make_encounter_setup(3, 1, 1, 1, 2)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_credits = 1   # needs 2 to boost once

	var action := {"type": "boost_strength", "card_id": "t_breaker", "times": 1}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("boost failed (no credits)", ok, false)
	_expect_eq("credits unchanged", ctx.runner_credits, 1)


func _test_e3_break_subroutine_success() -> void:
	_log("[b]E3[/b] — break_subroutine: credits deducted and sub marked broken")
	var setup := _make_encounter_setup(2, 2, 2, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_credits = 5

	var action := {"type": "break_subroutine", "card_id": "t_breaker", "sub_index": 0}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("break succeeded", ok, true)
	_expect_eq("1 credit deducted", ctx.runner_credits, 4)
	_expect_eq("sub 0 broken", enc.is_broken(0), true)
	_expect_eq("sub 1 not broken", enc.is_broken(1), false)


func _test_e4_break_subroutine_strength_fails() -> void:
	_log("[b]E4[/b] — break_subroutine: fails when breaker strength < ice strength")
	# Ice strength 5, breaker strength 1 — breaker cannot reach.
	var setup := _make_encounter_setup(5, 1, 1, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_credits = 10

	var action := {"type": "break_subroutine", "card_id": "t_breaker", "sub_index": 0}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("break failed (strength check)", ok, false)
	_expect_eq("sub 0 not broken", enc.is_broken(0), false)
	_expect_eq("credits unchanged", ctx.runner_credits, 10)


func _test_e5_break_subroutine_no_credits() -> void:
	_log("[b]E5[/b] — break_subroutine: fails when runner has no credits")
	# Ice strength 2, breaker strength 2 — can reach but has no credits.
	var setup := _make_encounter_setup(2, 2, 1, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_credits = 0   # can't afford the break cost of 1

	var action := {"type": "break_subroutine", "card_id": "t_breaker", "sub_index": 0}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("break failed (no credits)", ok, false)
	_expect_eq("sub 0 not broken", enc.is_broken(0), false)


func _test_e6_break_all_success() -> void:
	_log("[b]E6[/b] — break_all: all three subroutines broken, correct credits deducted")
	var setup := _make_encounter_setup(2, 2, 3, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_credits = 10

	var action := {"type": "break_all", "card_id": "t_breaker"}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("break_all succeeded", ok, true)
	_expect_eq("3 credits deducted (3 subs × 1cr)", ctx.runner_credits, 7)
	_expect_eq("all subs broken", enc.all_broken(), true)


func _test_e7_break_all_partial_credits() -> void:
	_log("[b]E7[/b] — break_all: breaks only as many subs as credits allow")
	var setup := _make_encounter_setup(2, 2, 4, 2, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_credits = 4   # can afford 2 of the 4 subs at 2cr each

	var action := {"type": "break_all", "card_id": "t_breaker"}
	await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("2 subs broken (partial)", enc.broken_indices.size(), 2)
	_expect_eq("credits at 0", ctx.runner_credits, 0)


func _test_e8_weaken_ice_success() -> void:
	_log("[b]E8[/b] — weaken_ice: virus counter spent, ice strength reduced by 1")
	var setup := _make_encounter_setup(3, 1, 1, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	# Place a Leech card with 2 virus counters in the runner rig.
	var leech := _make_rig_card(ctx, "leech", "program", "leech_weaken_01")
	leech.add_counter("virus", 2)
	var str_before: int = enc.ice_strength

	var action := {"type": "weaken_ice", "card_id": "leech"}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("weaken succeeded", ok, true)
	_expect_eq("ice strength reduced by 1", enc.ice_strength, str_before - 1)
	_expect_eq("1 virus counter spent", leech.get_counter("virus"), 1)


func _test_e9_weaken_ice_no_counters() -> void:
	_log("[b]E9[/b] — weaken_ice: fails gracefully when no virus counters")
	var setup := _make_encounter_setup(3, 1, 1, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	var leech := _make_rig_card(ctx, "leech", "program", "leech_weaken_02")
	# No counters placed.
	var str_before: int = enc.ice_strength

	var action := {"type": "weaken_ice", "card_id": "leech"}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("weaken failed (no counters)", ok, false)
	_expect_eq("ice strength unchanged", enc.ice_strength, str_before)


func _test_e10_break_with_click_success() -> void:
	_log("[b]E10[/b] — break_with_click: click spent and sub broken (bioroid)")
	var setup := _make_encounter_setup(3, 1, 2, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_clicks = 2

	var action := {"type": "break_with_click", "sub_index": 0}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("break_with_click succeeded", ok, true)
	_expect_eq("1 click spent", ctx.runner_clicks, 1)
	_expect_eq("sub 0 broken", enc.is_broken(0), true)


func _test_e11_break_with_click_no_clicks() -> void:
	_log("[b]E11[/b] — break_with_click: fails when runner has no clicks")
	var setup := _make_encounter_setup(3, 1, 1, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_clicks = 0

	var action := {"type": "break_with_click", "sub_index": 0}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("break_with_click failed (no clicks)", ok, false)
	_expect_eq("sub 0 not broken", enc.is_broken(0), false)


func _test_e12_spend_hosted_credits_success() -> void:
	_log("[b]E12[/b] — spend_hosted_credits: hosted credits transferred to runner pool")
	var setup := _make_encounter_setup(3, 1, 1, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_credits = 2
	var hosted := _make_rig_card(ctx, "hostcard", "program", "hosted_01")
	hosted.add_counter("credits", 3)

	var action := {"type": "spend_hosted_credits", "card_id": "hostcard", "amount": 2}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("spend_hosted_credits succeeded", ok, true)
	_expect_eq("runner_credits increased by 2", ctx.runner_credits, 4)
	_expect_eq("hosted credits reduced by 2", hosted.get_counter("credits"), 1)


func _test_e13_spend_hosted_credits_empty() -> void:
	_log("[b]E13[/b] — spend_hosted_credits: fails when hosted card has no credits")
	var setup := _make_encounter_setup(3, 1, 1, 1, 1)
	var enc: EncounterState  = setup["enc"]
	var ctx: GameContext     = setup["ctx"]
	var reg: AbilityRegistry = setup["reg"]
	ctx.runner_credits = 2
	var hosted := _make_rig_card(ctx, "hostcard", "program", "hosted_02")
	# No hosted credits added.

	var action := {"type": "spend_hosted_credits", "card_id": "hostcard", "amount": 1}
	var ok: bool = await _interpreter.process_encounter_action(action, enc, ctx, reg)
	_expect_eq("spend_hosted_credits failed (empty)", ok, false)
	_expect_eq("runner_credits unchanged", ctx.runner_credits, 2)


# ── Group F: Integration against abilities.json ───────────────────────────────

func _test_f1_hedge_fund(reg: AbilityRegistry) -> void:
	_log("[b]F1[/b] — Hedge Fund: Corp gains 9 credits (from abilities.json)")
	var ctx := _make_ctx()
	ctx.corp_credits = 5
	var def: Dictionary = reg.get_on_play("hedge_fund") as Dictionary
	await _interpreter.execute_trigger(def, ctx)
	_expect_eq("corp_credits after Hedge Fund", ctx.corp_credits, 14)


func _test_f2_palisade_sub(reg: AbilityRegistry) -> void:
	_log("[b]F2[/b] — Palisade sub 1: End the run")
	var ctx := _make_ctx()
	ctx.run_active = true
	ctx.run_ended  = false
	var subs: Array = reg.get_subroutines("palisade")
	if subs.is_empty():
		_log("  [color=yellow]SKIP — no subs defined for palisade[/color]")
		return
	await _interpreter.execute_subroutine(subs[0] as Dictionary, ctx)
	_expect_eq("run_ended", ctx.run_ended, true)


func _test_f3_urtica_cipher_access(reg: AbilityRegistry) -> void:
	_log("[b]F3[/b] — Urtica Cipher on access: 2 + 3 advancement counters = 5 net damage")
	var ctx := _make_ctx()
	ctx.corp_credits = 5
	# Corp must choose to activate: inject a decision maker that always picks option 0.
	ctx.corp_decision_maker = _AlwaysActivate.new()
	# Install Urtica with 3 advancement counters in a remote.
	var remote  := ctx.create_remote_server()
	var rec     := _make_card_record("urtica_cipher", "asset", "corp")
	var urtica  := InstalledCard.make(rec, remote.server_id, "root", false)
	urtica.add_counter("advancement", 3)
	remote.install_in_root(urtica)
	# Fill grip with 6 cards so the runner survives (5 damage → 1 card remains).
	for i in range(6):
		ctx.runner_hand.append({"card_id": "g%d" % i, "card_record": _make_card_record("g%d" % i, "event", "runner")})
	# The handler reads the InstalledCard directly from current_event_data["card"].
	ctx.current_event_data = {"card": urtica}

	var def: Dictionary = reg.get_on_access("urtica_cipher") as Dictionary
	await _interpreter.execute_trigger(def, ctx)
	# Corp paid 2 cr, 2 base + 3 counters = 5 damage, 6 - 5 = 1 card remains.
	_expect_eq("runner_hand size after 5 net damage", ctx.runner_hand.size(), 1)
	_expect_eq("corp paid 2 cr", ctx.corp_credits, 3)


func _test_f4_whitespace_sub2_fires(reg: AbilityRegistry) -> void:
	_log("[b]F4[/b] — Whitespace sub 2: End run fires when runner credits ≤ 6")
	var ctx := _make_ctx()
	ctx.runner_credits = 4
	ctx.run_active     = true
	ctx.run_ended      = false
	var subs: Array = reg.get_subroutines("whitespace")
	if subs.size() < 2:
		_log("  [color=yellow]SKIP — whitespace does not have 2 subs defined[/color]")
		return
	await _interpreter.execute_subroutine(subs[1] as Dictionary, ctx)
	_expect_eq("run_ended (credits ≤ 6)", ctx.run_ended, true)


func _test_f5_whitespace_sub2_blocked(reg: AbilityRegistry) -> void:
	_log("[b]F5[/b] — Whitespace sub 2: End run blocked when runner credits > 6")
	var ctx := _make_ctx()
	ctx.runner_credits = 10
	ctx.run_active     = true
	ctx.run_ended      = false
	var subs: Array = reg.get_subroutines("whitespace")
	if subs.size() < 2:
		_log("  [color=yellow]SKIP — whitespace does not have 2 subs defined[/color]")
		return
	await _interpreter.execute_subroutine(subs[1] as Dictionary, ctx)
	_expect_eq("run_ended should be false (credits > 6)", ctx.run_ended, false)


# ── Factories ─────────────────────────────────────────────────────────────────

func _make_ctx() -> GameContext:
	var ctx        := GameContext.new()
	ctx.run_active  = false
	ctx.run_ended   = false
	ctx.simulation_mode = true   # suppress log output during tests
	return ctx


func _make_card_record(id: String, card_type: String, side: String) -> CardRecord:
	var r          := CardRecord.new()
	r.id            = id
	r.title         = id
	r.card_type     = card_type
	r.side          = side
	r.cost          = 0
	r.strength      = 0
	r.stripped_text = ""
	r.subtypes      = []
	return r


# Creates an InstalledCard in the runner rig with a given id and instance_id.
func _make_rig_card(ctx: GameContext, card_id: String, card_type: String, instance_id: String) -> InstalledCard:
	var rec  := _make_card_record(card_id, card_type, "runner")
	var card := InstalledCard.make(rec, "", "root", false)
	card.runtime_instance_id = instance_id
	ctx.runner_rig.append(card)
	return card


# Builds a minimal EncounterState and supporting objects for encounter tests.
# Returns a Dictionary with keys: enc, ctx, reg, breaker, ice
func _make_encounter_setup(
		ice_str: int, breaker_str: int, sub_count: int,
		break_cost: int, boost_cost: int) -> Dictionary:

	var ctx := _make_ctx()
	ctx.runner_credits = 10
	ctx.runner_clicks  = 3

	# Inline AbilityRegistry — no file load required.
	var reg := AbilityRegistry.new()
	reg._abilities["t_breaker"] = {
		"break": {"cost_per_sub": break_cost},
		"boost": {"cost": boost_cost, "strength_gained": 1}
	}

	# Ice card
	var ice_rec  := _make_card_record("t_ice", "ice", "corp")
	ice_rec.strength = ice_str
	var ice_ic   := InstalledCard.make(ice_rec, "hq", "ice", true)
	ice_ic.runtime_instance_id = "t_ice"

	# Breaker card
	var breaker_rec  := _make_card_record("t_breaker", "program", "runner")
	breaker_rec.strength = breaker_str
	var breaker_ic   := InstalledCard.make(breaker_rec, "", "root", false)
	breaker_ic.runtime_instance_id = "t_breaker"
	ctx.runner_rig.append(breaker_ic)

	# Subroutines
	var subs: Array = []
	for i in range(sub_count):
		subs.append({"label": "End the run.", "effects": [_effect("end_run", {})]})

	# EncounterState (constructed directly to avoid EncounterState.make() side-effects)
	var enc                  := EncounterState.new()
	enc.ice_card              = ice_ic
	enc.ice_strength          = ice_str
	enc.subroutines           = subs
	enc.broken_indices        = []
	enc.available_breakers    = [breaker_ic]
	enc.temp_strength_boosts  = {}
	enc.ctx                   = null   # no board-wide modifiers needed for unit tests

	return {"enc": enc, "ctx": ctx, "reg": reg, "breaker": breaker_ic, "ice": ice_ic}


# ── Inline ability definition helpers ─────────────────────────────────────────

# Wraps a list of effect dicts into a trigger definition.
func _trigger(effects: Array) -> Dictionary:
	return {"effects": effects}


# Creates a single effect dict with a params sub-dictionary.
func _effect(type: String, params: Dictionary) -> Dictionary:
	return {"type": type, "params": params}


# ── Assertion helpers ─────────────────────────────────────────────────────────

func _expect_eq(label: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_log("  [color=green]PASS[/color] %s = %s" % [label, str(actual)])
		_pass_count += 1
	else:
		_log("  [color=red]FAIL[/color] %s: expected %s, got %s" % [label, str(expected), str(actual)])
		_fail_count += 1


func _log(text: String) -> void:
	output_label.append_text(text + "\n")


# ── Decision-maker stubs ───────────────────────────────────────────────────────

# Always picks option 0 (the first / "activate" choice) in any modal decision.
# Used for tests where the Corp must choose to pay an optional ability cost.
class _AlwaysActivate:
	func choose_modes(_modes: Array, _max: int, _ctx: GameContext) -> Array:
		return [0]
	func choose_target(candidates: Array, _ctx) -> Variant:
		return candidates[0] if not candidates.is_empty() else null
	func choose_optional_ability(_prompt: String, _ctx: GameContext) -> bool:
		return true
