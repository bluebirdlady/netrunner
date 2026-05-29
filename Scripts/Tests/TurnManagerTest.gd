extends Control

# ── TurnManagerTest ───────────────────────────────────────────────────────────
# Tests the TurnManager driving a full game loop.
# Corp uses CorpTurnAI. Runner uses a stub that alternates between
# running HQ and gaining credits, to give the Corp something to defend.
#
# We don't run to a real game conclusion — instead we run for a fixed number
# of Corp turns and verify the board state looks reasonable.
#
# Scene setup: same as other tests (RunButton + OutputLabel in VBoxContainer).

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

	_log("[b]── Turn Manager Tests ──[/b]\n")

	await _test_corp_gains_credits()
	await _test_corp_installs_ice_on_hq()
	await _test_corp_installs_and_advances_agenda()
	await _test_corp_scores_agenda()

	_log("")
	_log("[b]Results: %d passed, %d failed[/b]" % [_pass_count, _fail_count])
	if _fail_count == 0:
		_log("[color=green]All tests passed.[/color]")
	else:
		_log("[color=red]%d test(s) failed.[/color]" % _fail_count)


# ── Tests ─────────────────────────────────────────────────────────────────────

func _test_corp_gains_credits() -> void:
	_log("[b]Test 1[/b] — Corp gains credits when below threshold")
	# Corp starts at 3 credits (below ECONOMY_THRESHOLD of 6), empty hand.
	# Should spend all 3 clicks gaining credits.
	var ctx := _make_context(3)
	var tm  := _make_turn_manager(ctx)

	# Run exactly one Corp turn
	ctx.active_player = "corp"
	ctx.corp_clicks   = 3
	_corp_mandatory_draw_stub(ctx)  # no deck, skip draw
	await _run_corp_turn(ctx, tm)

	_expect_eq("corp credits after 3 gain-credit clicks", ctx.corp_credits, 6)
	_log("")


func _test_corp_installs_ice_on_hq() -> void:
	_log("[b]Test 2[/b] — Corp installs ice on unprotected HQ")
	var ctx := _make_context(10)
	# Give Corp a Palisade in hand
	var palisade := _make_ice_record("palisade", 3, 2, ["barrier"])
	ctx.corp_hand.append({"card_id": "palisade", "card_record": palisade})

	var tm := _make_turn_manager(ctx)
	ctx.active_player = "corp"
	ctx.corp_clicks   = 3
	await _run_corp_turn(ctx, tm)

	var hq: Server = ctx.get_server("hq")
	_expect_eq("HQ has ice after Corp turn", hq.ice_count(), 1)
	_expect_eq("ice is Palisade", hq.get_ice_at(0).card_id, "palisade")
	_log("")


func _test_corp_installs_and_advances_agenda() -> void:
	_log("[b]Test 3[/b] — Corp installs agenda in protected remote and advances it")
	var ctx := _make_context(10)

	# Pre-install ice on a remote so Corp sees it as protected
	var remote  := ctx.create_remote_server()
	var palisade := _make_ice_record("palisade", 3, 2, ["barrier"])
	var ice_card := InstalledCard.make(palisade, remote.server_id, "ice", true)
	remote.install_ice(ice_card)

	# Give Corp an agenda in hand (advancement req 3)
	var agenda := _make_agenda_record("offworld_office", 3, 2)
	ctx.corp_hand.append({"card_id": "offworld_office", "card_record": agenda})

	var tm := _make_turn_manager(ctx)
	ctx.active_player = "corp"
	ctx.corp_clicks   = 3
	await _run_corp_turn(ctx, tm)

	# Corp should install the agenda (click 1), then advance it (click 2+3)
	var installed_agenda: InstalledCard = remote.get_agenda_or_asset()
	_expect_eq("agenda installed in protected remote", installed_agenda != null, true)
	if installed_agenda != null:
		_expect_eq("agenda advanced at least once",
			installed_agenda.get_counter("advancement") >= 1, true)
	_log("")


func _test_corp_scores_agenda() -> void:
	_log("[b]Test 4[/b] — Corp scores agenda when advancement requirement met")
	var ctx := _make_context(10)

	# Pre-install an agenda with 2 of 3 required advancement counters
	var remote  := ctx.create_remote_server()
	var palisade := _make_ice_record("palisade", 3, 2, ["barrier"])
	var ice_card := InstalledCard.make(palisade, remote.server_id, "ice", true)
	remote.install_ice(ice_card)

	var agenda_record := _make_agenda_record("offworld_office", 3, 2)
	var agenda_card   := InstalledCard.make(agenda_record, remote.server_id, "root", false)
	agenda_card.add_counter("advancement", 2)  # one away from scoring
	remote.install_in_root(agenda_card)

	var tm := _make_turn_manager(ctx)
	ctx.active_player = "corp"
	ctx.corp_clicks   = 3
	await _run_corp_turn(ctx, tm)

	# Corp should advance once (meeting requirement) and auto-score
	_expect_eq("corp scored agenda", ctx.corp_score_area.size(), 1)
	_expect_eq("corp has 2 agenda points", ctx.corp_agenda_points(), 2)
	_expect_eq("remote root is now empty", remote.root.size(), 0)
	_log("")


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_context(credits: int) -> GameContext:
	var ctx          := GameContext.new()
	ctx.corp_credits  = credits
	return ctx


func _make_turn_manager(ctx: GameContext) -> TurnManager:
	var tm       := TurnManager.new(ctx, _ability_registry)
	var corp_ai  := CorpTurnAI.new(_ability_registry)
	ctx.corp_decision_maker   = corp_ai
	ctx.runner_decision_maker = _StubRunner.new()
	# Log all actions
	tm.action_executed.connect(func(player, action):
		_log("  [action] %s: %s" % [player, action.describe()])
	)
	tm.action_rejected.connect(func(player, action, reason):
		_log("  [rejected] %s: %s — %s" % [player, action.describe(), reason])
	)
	return tm


func _run_corp_turn(ctx: GameContext, tm: TurnManager) -> void:
	# Run just the Corp action phase (not the full game loop)
	while ctx.corp_clicks > 0 and not ctx.game_over:
		var action: GameAction = await ctx.corp_decision_maker.choose_action(ctx)
		if action == null or action.type == "end_turn":
			break
		await tm._execute_action("corp", action)


func _corp_mandatory_draw_stub(_ctx: GameContext) -> void:
	pass  # no deck in these tests, skip mandatory draw


func _make_ice_record(id: String, cost: int, strength: int, subtypes: Array) -> CardRecord:
	var r        := CardRecord.new()
	r.id          = id
	r.title       = id
	r.card_type   = "ice"
	r.side        = "corp"
	r.cost        = cost
	r.strength    = strength
	r.subtypes    = subtypes
	r.stripped_text = ""
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
