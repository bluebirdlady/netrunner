extends Node

# ── SelfPlayRunner ────────────────────────────────────────────────────────────
# Headless AI-vs-AI self-play harness.
#
# Usage:
#   godot --headless res://Scenes/SelfPlay.tscn
#
# Corp AI (CorpTurnAI_Strategic) vs Runner AI (SimRunnerAI campaign mode).
# Both AIs are synchronous, so the game runs at maximum speed.
# Each action is printed to stdout in a human-readable format for debugging.
# ─────────────────────────────────────────────────────────────────────────────

const MAX_TURNS := 80  # Safety cap — a game shouldn't need more than this

# ── Starter decks (play to 6 agenda points) ───────────────────────────────────

const CORP_DECK_IDS: Array = [
	"offworld_office", "offworld_office", "offworld_office",
	"send_a_message", "send_a_message",
	"superconducting_hub", "superconducting_hub",
	"nico_campaign", "nico_campaign",
	"urtica_cipher", "urtica_cipher",
	"regolith_mining_license", "regolith_mining_license",
	"hedge_fund", "hedge_fund", "hedge_fund",
	"government_subsidy", "government_subsidy",
	"seamless_launch", "seamless_launch",
	"manegarm_skunkworks",
	"bran_1_0", "bran_1_0",
	"diviner", "diviner",
	"karuna", "karuna",
	"palisade", "palisade", "palisade",
	"whitespace", "whitespace",
	"tithe", "tithe",
]

const RUNNER_DECK_IDS: Array = [
	"tread_lightly", "tread_lightly",
	"creative_commission", "creative_commission",
	"vrcation", "vrcation",
	"overclock", "overclock",
	"jailbreak", "jailbreak", "jailbreak",
	"sure_gamble", "sure_gamble", "sure_gamble",
	"docklands_pass",
	"pennyshaver",
	"red_team",
	"telework_contract", "telework_contract",
	"smartware_distributor", "smartware_distributor",
	"verbal_plasticity",
	"cleaver", "cleaver",
	"carmen", "carmen",
	"unity", "unity",
	"mayfly", "mayfly",
]

# ── State for logging ─────────────────────────────────────────────────────────

var _ctx:         GameContext
var _turn_count:  int = 0
var _action_count: int = 0
var _click_index: int = 0
var _last_beat_msec: int = 0

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_beat_msec >= 5000:
		_last_beat_msec = now
		print("[heartbeat] alive — turn %d, actions %d, time %ds" % [
			_turn_count, _action_count, now / 1000])


# ── Entry point ───────────────────────────────────────────────────────────────

func _ready() -> void:
	_run_game()

func _run_game() -> void:
	print("╔══════════════════════════════════════════════════════╗")
	print("║          NETRUNNER SELF-PLAY (AI vs AI)              ║")
	print("║  Corp: The Syndicate  vs  Runner: The Catalyst       ║")
	print("║  Starter decks — playing to 6 agenda points          ║")
	print("╚══════════════════════════════════════════════════════╝")
	print("")

	var ab := AbilityRegistry.new()
	if not ab.load_from_file("res://Data/abilities.json"):
		print("ERROR: failed to load abilities.json")
		get_tree().quit()
		return
	print("Loaded %d ability definitions." % ab._abilities.size())

	_ctx = GameContext.new()
	_ctx.corp_credits   = 5
	_ctx.runner_credits = 5
	_ctx.corp_clicks    = 3
	_ctx.runner_clicks  = 0

	_ctx.corp_identity   = CardRegistry.get_card("the_syndicate_profit_over_principle")
	_ctx.runner_identity = CardRegistry.get_card("the_catalyst_convention_breaker")
	if _ctx.corp_identity == null or _ctx.runner_identity == null:
		print("ERROR: identity cards not found in registry")
		get_tree().quit()
		return

	_load_deck(CORP_DECK_IDS,   _ctx.corp_deck)
	_load_deck(RUNNER_DECK_IDS, _ctx.runner_deck)
	_ctx.corp_deck.shuffle()
	_ctx.runner_deck.shuffle()

	for _i in range(5):
		if not _ctx.corp_deck.is_empty():
			var c: CardRecord = _ctx.corp_deck.pop_front()
			_ctx.corp_hand.append({"card_id": c.id, "card_record": c})
	for _i in range(5):
		if not _ctx.runner_deck.is_empty():
			var c: CardRecord = _ctx.runner_deck.pop_front()
			_ctx.runner_hand.append({"card_id": c.id, "card_record": c})

	_ctx.servers["hq"]       = Server.make("hq")
	_ctx.servers["rd"]       = Server.make("rd")
	_ctx.servers["archives"] = Server.make("archives")

	var corp_brain   := CorpTurnAI_MCTS.new(ab)
	# Reduce MCTS iterations for self-play — 20 is enough to observe strategic behavior
	# without the ~1s-per-action cost of the full 100-iteration search.
	corp_brain._turn_tree.iterations = 20
	var runner_brain := SimRunnerAI.new()
	runner_brain.campaign_runner_mode = true
	_ctx.corp_decision_maker   = corp_brain
	_ctx.runner_decision_maker = runner_brain

	var tm  := TurnManager.new(_ctx, ab)
	var rsm := RunStateMachine.new(_ctx, ab)
	_ctx.set_meta("run_state_machine", rsm)
	_ctx.set_meta("ability_registry",  ab)
	_ctx.set_meta("register_installed_card", Callable(tm, "_register_card_listeners"))

	_wire_logging(tm)

	# ── Mulligan ──────────────────────────────────────────────────────────────
	print("── Opening hands ──")
	print("  Corp:   %s" % _hand_summary(_ctx.corp_hand))
	print("  Runner: %s" % _hand_summary(_ctx.runner_hand))

	if _corp_wants_mulligan():
		_mulligan_corp()
		print("  Corp mulligans → %s" % _hand_summary(_ctx.corp_hand))
	else:
		print("  Corp keeps.")

	if _runner_wants_mulligan():
		_mulligan_runner()
		print("  Runner mulligans → %s" % _hand_summary(_ctx.runner_hand))
	else:
		print("  Runner keeps.")
	print("")

	await tm.run_game(MAX_TURNS)
	# game_over signal fires before run_game returns; get_tree().quit() called there.
	# If we hit MAX_TURNS without a winner, report a draw.
	if not _ctx.game_over:
		print("\n=== TURN LIMIT REACHED (no winner after %d turns) ===" % MAX_TURNS)
		print("Score: Corp %d — Runner %d" % [
			_ctx.corp_agenda_points(), _ctx.runner_agenda_points()])
	get_tree().quit()


# ── Logging wiring ────────────────────────────────────────────────────────────

func _wire_logging(tm: TurnManager) -> void:
	tm.turn_started.connect(func(player: String, turn_number: int) -> void:
		_turn_count  = turn_number
		_click_index = 0
		var header := "\n══ Turn %d — %s  [Corp: %dcr %d✋ | Runner: %dcr %d✋]" % [
			turn_number,
			"CORP" if player == "corp" else "RUNNER",
			_ctx.corp_credits,   _ctx.corp_hand.size(),
			_ctx.runner_credits, _ctx.runner_hand.size(),
		]
		if not _ctx.runner_rig.is_empty():
			header += "  Rig: %s" % _rig_summary()
		print(header)
		if player == "corp":
			_print_board_state()
	)

	tm.action_executed.connect(func(player: String, action: GameAction) -> void:
		_action_count += 1
		_click_index += 1
		print("  %d. [%s] %s" % [_click_index, player, _describe_action(action)])
	)

	tm.game_over.connect(func(winner: String, reason: String) -> void:
		print("\n╔══════════════════════════════════════════════════════╗")
		print("║  GAME OVER                                           ║")
		print("║  Winner : %-42s ║" % winner.to_upper())
		print("║  Reason : %-42s ║" % reason)
		print("║  Turns  : %-5d  |  Total actions: %-16d ║" % [_turn_count, _action_count])
		print("║  Score  : Corp %-3d — Runner %-3d                      ║" % [
			_ctx.corp_agenda_points(), _ctx.runner_agenda_points()])
		print("╚══════════════════════════════════════════════════════╝")
	)


# ── Action description ────────────────────────────────────────────────────────

func _describe_action(action: GameAction) -> String:
	match action.type:
		"gain_credits":
			var creds := _ctx.corp_credits if _ctx.active_player == "corp" else _ctx.runner_credits
			return "Gain 1 credit  [→ %dcr]" % creds
		"draw_card":
			return "Draw a card  [→ %d cards]" % (
				_ctx.corp_hand.size() if _ctx.active_player == "corp" else _ctx.runner_hand.size())
		"play_operation":
			var rec: CardRecord = action.params.get("card_record", null) as CardRecord
			return "Play %s" % (rec.title if rec else "?")
		"install":
			var rec: CardRecord = action.params.get("card_record", null) as CardRecord
			var srv: String     = action.params.get("server_id",  "?") as String
			return "Install %s → %s" % [rec.title if rec else "?", srv]
		"advance":
			var adv_id: String = action.params.get("card_id", "") as String
			var adv_rec: CardRecord = CardRegistry.get_card(adv_id) if adv_id else null
			return "Advance %s" % (adv_rec.title if adv_rec else adv_id if adv_id else "?")
		"score_agenda":
			var ic: InstalledCard = action.params.get("card", null) as InstalledCard
			var title := ic.card_record.title if ic and ic.card_record else "?"
			return "Score agenda: %s  [Corp: %d pts]" % [title, _ctx.corp_agenda_points()]
		"rez_card":
			var ic: InstalledCard = action.params.get("card", null) as InstalledCard
			var title := ic.card_record.title if ic and ic.card_record else "?"
			return "Rez %s  [→ %dcr]" % [title, _ctx.corp_credits]
		"run":
			var srv: String = action.params.get("server_id", "?") as String
			return "Run %s" % srv.to_upper()
		"trash":
			var rec: CardRecord = action.params.get("card_record", null) as CardRecord
			return "Trash %s" % (rec.title if rec else "?")
		"pass_priority", "pass":
			return "Pass"
		"end_turn":
			return "End turn"
		_:
			return action.type


# ── Board state snapshot ──────────────────────────────────────────────────────

func _print_board_state() -> void:
	# Remote servers with installed cards
	for key in _ctx.servers:
		var s: Server = _ctx.servers[key] as Server
		if s == null or not s.is_remote():
			continue
		var cards: Array = []
		for ic_any in s.root:
			var ic: InstalledCard = ic_any as InstalledCard
			if ic and ic.card_record:
				var label := ic.card_record.title
				if ic.is_rezzed:
					label += "(rezzed)"
				var adv: int = ic.counters.get("advancement", 0) as int
				if adv > 0:
					label += "[%d adv]" % adv
				cards.append(label)
		var ice_parts: Array = []
		for ic_any in s.ice:
			var ic: InstalledCard = ic_any as InstalledCard
			if ic and ic.card_record:
				ice_parts.append(ic.card_record.title if ic.is_rezzed else "?ICE?")
		var ice_str := " | ICE: %s" % ", ".join(ice_parts) if not ice_parts.is_empty() else ""
		if not cards.is_empty() or not ice_parts.is_empty():
			print("    %s: %s%s" % [s.server_id, ", ".join(cards), ice_str])


# ── Summary helpers ───────────────────────────────────────────────────────────

func _hand_summary(hand: Array) -> String:
	var titles: Array = []
	for entry in hand:
		var rec: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if rec:
			titles.append(rec.title)
	return ", ".join(titles)


func _rig_summary() -> String:
	var parts: Array = []
	for ic_any in _ctx.runner_rig:
		var ic: InstalledCard = ic_any as InstalledCard
		if ic and ic.card_record:
			parts.append(ic.card_record.title)
	return ", ".join(parts)


# ── Mulligan ──────────────────────────────────────────────────────────────────

func _corp_wants_mulligan() -> bool:
	var agendas    := 0
	var afford_ice := 0
	for entry in _ctx.corp_hand:
		var rec: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if rec == null:
			continue
		if rec.is_agenda():
			agendas += 1
		if rec.is_ice() and rec.cost <= _ctx.corp_credits:
			afford_ice += 1
	return agendas > 2 or afford_ice < 2


func _runner_wants_mulligan() -> bool:
	for entry in _ctx.runner_hand:
		var rec: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if rec and rec.card_type in ["event", "resource"]:
			return false
	return true


func _mulligan_corp() -> void:
	for entry in _ctx.corp_hand:
		var rec: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if rec:
			_ctx.corp_deck.append(rec)
	_ctx.corp_hand.clear()
	_ctx.corp_deck.shuffle()
	for _i in range(5):
		if not _ctx.corp_deck.is_empty():
			var c: CardRecord = _ctx.corp_deck.pop_front()
			_ctx.corp_hand.append({"card_id": c.id, "card_record": c})


func _mulligan_runner() -> void:
	for entry in _ctx.runner_hand:
		var rec: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if rec:
			_ctx.runner_deck.append(rec)
	_ctx.runner_hand.clear()
	_ctx.runner_deck.shuffle()
	for _i in range(5):
		if not _ctx.runner_deck.is_empty():
			var c: CardRecord = _ctx.runner_deck.pop_front()
			_ctx.runner_hand.append({"card_id": c.id, "card_record": c})


# ── Deck loading ──────────────────────────────────────────────────────────────

func _load_deck(ids: Array, deck: Array) -> void:
	for card_id in ids:
		var rec: CardRecord = CardRegistry.get_card(card_id)
		if rec:
			deck.append(rec)
		else:
			print("WARNING: card not found: %s" % card_id)
