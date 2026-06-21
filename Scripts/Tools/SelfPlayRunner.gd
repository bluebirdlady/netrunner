extends Node

# ── SelfPlayRunner ────────────────────────────────────────────────────────────
# Headless AI-vs-AI self-play harness.
#
# Usage (single game, starter decks):
#   godot --headless res://Scenes/SelfPlay.tscn
#
# Usage (batch — prints per-game results and a win-rate summary):
#   godot --headless res://Scenes/SelfPlay.tscn -- --batch 50
#   godot --headless res://Scenes/SelfPlay.tscn -- --batch 50 --verbose
#
# Deck selection flags (can be combined with --batch):
#   --corp-opponent  <id>          load Corp identity+deck from campaign.json
#   --runner-opponent <id>         load Runner identity+deck from corp_campaign.json
#   --corp-identity  <card_id>     override Corp identity card
#   --corp-deck      <id,id,...>   override Corp deck (comma-separated card IDs)
#   --runner-identity <card_id>    override Runner identity card
#   --runner-deck    <id,id,...>   override Runner deck (comma-separated card IDs)
#
# Corp AI (CorpTurnAI_MCTS) vs Runner AI (SimRunnerAI campaign mode).
# Both AIs are synchronous, so the game runs at maximum speed.
# In single-game mode every action is printed; in batch mode only results are.
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

# ── State ─────────────────────────────────────────────────────────────────────

var _ctx:          GameContext
var _turn_count:   int = 0
var _action_count: int = 0
var _click_index:  int = 0
var _last_beat_msec: int = 0

# Batch-mode state
var _batch_mode:    bool  = false
var _batch_verbose: bool  = false
var _batch_total:   int   = 1
var _weights:       Dictionary = {}   # optional weight overrides from --weights <json>
var _batch_index:   int   = 0
var _batch_results: Array = []   # Array of {winner, reason, turns, actions}

# Current-game result captured by the game_over signal
var _game_result: Dictionary = {}

# Active deck configuration (resolved from args; defaults to starter decks)
var _corp_identity_id:  String = "the_syndicate_profit_over_principle"
var _runner_identity_id: String = "the_catalyst_convention_breaker"
var _corp_deck_ids:     Array  = CORP_DECK_IDS
var _runner_deck_ids:   Array  = RUNNER_DECK_IDS

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_beat_msec >= 5000:
		_last_beat_msec = now
		if _batch_mode:
			print("[heartbeat] game %d/%d — turn %d, time %ds" % [
				_batch_index + 1, _batch_total, _turn_count, now / 1000])
		else:
			print("[heartbeat] alive — turn %d, actions %d, time %ds" % [
				_turn_count, _action_count, now / 1000])


# ── Entry point ───────────────────────────────────────────────────────────────

func _ready() -> void:
	var args: Array = OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a: String = args[i] as String
		match a:
			"--batch":
				if i + 1 < args.size():
					_batch_mode  = true
					_batch_total = maxi(1, int(args[i + 1] as String))
					i += 1
			"--verbose":
				_batch_verbose = true
			"--corp-opponent":
				if i + 1 < args.size():
					_load_campaign_opponent(args[i + 1] as String, "corp")
					i += 1
			"--runner-opponent":
				if i + 1 < args.size():
					_load_campaign_opponent(args[i + 1] as String, "runner")
					i += 1
			"--corp-identity":
				if i + 1 < args.size():
					_corp_identity_id = args[i + 1] as String
					i += 1
			"--corp-deck":
				if i + 1 < args.size():
					_corp_deck_ids = Array((args[i + 1] as String).split(","))
					i += 1
			"--runner-identity":
				if i + 1 < args.size():
					_runner_identity_id = args[i + 1] as String
					i += 1
			"--runner-deck":
				if i + 1 < args.size():
					_runner_deck_ids = Array((args[i + 1] as String).split(","))
					i += 1
			"--weights":
				if i + 1 < args.size():
					_load_weights(args[i + 1] as String)
					i += 1
		i += 1

	if _batch_mode:
		await _run_batch()
	else:
		await _run_game()
		get_tree().quit()


func _load_weights(path: String) -> void:
	var resolved: String = path if path.begins_with("res://") or path.is_absolute_path() \
		else "res://" + path
	var f := FileAccess.open(resolved, FileAccess.READ)
	if f == null:
		print("SelfPlayRunner: WARNING — cannot open weights file: %s" % resolved)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed == null or not (parsed is Dictionary):
		print("SelfPlayRunner: WARNING — weights file is not valid JSON: %s" % resolved)
		return
	_weights = parsed as Dictionary
	print("SelfPlayRunner: loaded %d weight overrides from %s" % [_weights.size(), resolved])


func _load_campaign_opponent(opponent_id: String, side: String) -> void:
	# Corp opponents live in campaign.json (runner campaign);
	# Runner opponents live in corp_campaign.json (corp campaign).
	var json_path: String = "res://Campaign/campaign.json" if side == "corp" \
		else "res://Campaign/corp_campaign.json"
	var f := FileAccess.open(json_path, FileAccess.READ)
	if f == null:
		print("ERROR: cannot open %s" % json_path)
		get_tree().quit(1)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed == null:
		print("ERROR: failed to parse %s" % json_path)
		get_tree().quit(1)
		return
	var opponents: Dictionary = (parsed as Dictionary).get("opponents", {}) as Dictionary
	if not opponents.has(opponent_id):
		print("ERROR: opponent '%s' not found in %s" % [opponent_id, json_path])
		print("Available opponents:")
		var keys: Array = opponents.keys()
		keys.sort()
		for k in keys:
			var o: Dictionary = opponents[k] as Dictionary
			print("  %-30s  %s" % [k, o.get("name", "")])
		get_tree().quit(1)
		return
	var opp: Dictionary = opponents[opponent_id] as Dictionary
	var deck_raw: Array = opp.get("deck", []) as Array
	var deck_ids: Array = []
	for entry in deck_raw:
		deck_ids.append(entry as String)
	if side == "corp":
		_corp_identity_id = opp.get("identity", _corp_identity_id) as String
		_corp_deck_ids    = deck_ids
	else:
		_runner_identity_id = opp.get("identity", _runner_identity_id) as String
		_runner_deck_ids    = deck_ids
	print("SelfPlayRunner: loaded %s opponent '%s' — %s (%d cards)" % [
		side, opponent_id,
		_corp_identity_id if side == "corp" else _runner_identity_id,
		deck_ids.size(),
	])


func _run_batch() -> void:
	print("╔══════════════════════════════════════════════════════╗")
	print("║     NETRUNNER SELF-PLAY — BATCH MODE (%3d games)     ║" % _batch_total)
	print("╚══════════════════════════════════════════════════════╝")

	var ab := AbilityRegistry.new()
	if not ab.load_from_file("res://Data/abilities.json"):
		print("ERROR: failed to load abilities.json")
		get_tree().quit()
		return

	for i in range(_batch_total):
		_batch_index   = i
		_turn_count    = 0
		_action_count  = 0
		_click_index   = 0
		_game_result   = {}
		await _run_game_with_registry(ab)
		_batch_results.append(_game_result)
		var r: Dictionary = _game_result
		print("  [%3d/%3d]  %-8s  %-32s  %2d turns" % [
			i + 1, _batch_total,
			(r.get("winner", "?") as String).to_upper(),
			r.get("reason", ""),
			r.get("turns",  0),
		])

	_print_batch_summary()
	get_tree().quit()


func _print_batch_summary() -> void:
	var corp_wins:   int = 0
	var runner_wins: int = 0
	var draws:       int = 0
	var total_turns: int = 0
	var reasons:     Dictionary = {}

	for r in _batch_results:
		var w: String = r.get("winner", "draw") as String
		var reason: String = r.get("reason", "") as String
		match w:
			"corp":   corp_wins   += 1
			"runner": runner_wins += 1
			_:        draws       += 1
		total_turns += r.get("turns", 0) as int
		reasons[reason] = (reasons.get(reason, 0) as int) + 1

	var n: int = _batch_results.size()
	var avg_turns: float = float(total_turns) / float(maxi(1, n))

	print("")
	print("╔══════════════════════════════════════════════════════╗")
	print("║  BATCH SUMMARY  (%d games)                           " % n)
	print("╠══════════════════════════════════════════════════════╣")
	print("║  Corp   wins : %3d  (%5.1f%%)                        " % [corp_wins,   100.0 * corp_wins   / n])
	print("║  Runner wins : %3d  (%5.1f%%)                        " % [runner_wins, 100.0 * runner_wins / n])
	print("║  Draws       : %3d  (%5.1f%%)                        " % [draws,       100.0 * draws       / n])
	print("║  Avg turns   : %.1f                                  " % avg_turns)
	print("╠══════════════════════════════════════════════════════╣")
	print("║  Win reasons:")
	var sorted_reasons: Array = reasons.keys()
	sorted_reasons.sort()
	for reason in sorted_reasons:
		print("║    %-32s  %3d" % [reason, reasons[reason]])
	print("╚══════════════════════════════════════════════════════╝")


func _run_game() -> void:
	var ab := AbilityRegistry.new()
	if not ab.load_from_file("res://Data/abilities.json"):
		print("ERROR: failed to load abilities.json")
		get_tree().quit()
		return
	await _run_game_with_registry(ab)


func _run_game_with_registry(ab: AbilityRegistry) -> void:
	_ctx = GameContext.new()
	_ctx.corp_credits   = 5
	_ctx.runner_credits = 5
	_ctx.corp_clicks    = 3
	_ctx.runner_clicks  = 0

	_ctx.corp_identity   = CardRegistry.get_card(_corp_identity_id)
	_ctx.runner_identity = CardRegistry.get_card(_runner_identity_id)
	if _ctx.corp_identity == null or _ctx.runner_identity == null:
		print("ERROR: identity cards not found — corp='%s' runner='%s'" % [
			_corp_identity_id, _runner_identity_id])
		get_tree().quit()
		return

	if not _batch_mode or _batch_verbose:
		print("╔══════════════════════════════════════════════════════╗")
		print("║          NETRUNNER SELF-PLAY (AI vs AI)              ║")
		print("║  Corp:   %-43s║" % (_ctx.corp_identity.title + "  "))
		print("║  Runner: %-43s║" % (_ctx.runner_identity.title + "  "))
		print("║  Playing to 6 agenda points                          ║")
		print("╚══════════════════════════════════════════════════════╝")
		print("")
		print("Loaded %d ability definitions." % ab._abilities.size())

	_load_deck(_corp_deck_ids,   _ctx.corp_deck)
	_load_deck(_runner_deck_ids, _ctx.runner_deck)
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
	corp_brain._turn_tree.iterations = 100
	var runner_brain := SimRunnerAI.new()
	runner_brain.campaign_runner_mode = true
	if not _weights.is_empty():
		corp_brain.apply_weights(_weights)
		runner_brain.apply_weights(_weights)
	_ctx.corp_decision_maker   = corp_brain
	_ctx.runner_decision_maker = runner_brain

	var tm  := TurnManager.new(_ctx, ab)
	var rsm := RunStateMachine.new(_ctx, ab)
	_ctx.set_meta("run_state_machine", rsm)
	_ctx.set_meta("ability_registry",  ab)
	_ctx.set_meta("register_installed_card", Callable(tm, "_register_card_listeners"))

	_wire_logging(tm)

	# ── Mulligan ──────────────────────────────────────────────────────────────
	var verbose: bool = not _batch_mode or _batch_verbose
	if verbose:
		print("── Opening hands ──")
		print("  Corp:   %s" % _hand_summary(_ctx.corp_hand))
		print("  Runner: %s" % _hand_summary(_ctx.runner_hand))

	if _corp_wants_mulligan():
		_mulligan_corp()
		if verbose:
			print("  Corp mulligans → %s" % _hand_summary(_ctx.corp_hand))
	else:
		if verbose:
			print("  Corp keeps.")

	if _runner_wants_mulligan():
		_mulligan_runner()
		if verbose:
			print("  Runner mulligans → %s" % _hand_summary(_ctx.runner_hand))
	else:
		if verbose:
			print("  Runner keeps.")
	if verbose:
		print("")

	await tm.run_game(MAX_TURNS)
	# game_over signal fires and populates _game_result before run_game returns.
	# If we hit MAX_TURNS without a winner, record a draw.
	if not _ctx.game_over:
		if verbose:
			print("\n=== TURN LIMIT REACHED (no winner after %d turns) ===" % MAX_TURNS)
			print("Score: Corp %d — Runner %d" % [
				_ctx.corp_agenda_points(), _ctx.runner_agenda_points()])
		_game_result = {
			"winner": "draw",
			"reason": "turn limit (%d turns)" % MAX_TURNS,
			"turns":  _turn_count,
			"actions": _action_count,
		}


# ── Logging wiring ────────────────────────────────────────────────────────────

func _wire_logging(tm: TurnManager) -> void:
	var verbose: bool = not _batch_mode or _batch_verbose

	tm.turn_started.connect(func(player: String, turn_number: int) -> void:
		_turn_count  = turn_number
		_click_index = 0
		if not verbose:
			return
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
		_click_index  += 1
		if not verbose:
			return
		print("  %d. [%s] %s" % [_click_index, player, _describe_action(action)])
	)

	tm.game_over.connect(func(winner: String, reason: String) -> void:
		_game_result = {
			"winner":  winner,
			"reason":  reason,
			"turns":   _turn_count,
			"actions": _action_count,
		}
		if not verbose:
			return
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
