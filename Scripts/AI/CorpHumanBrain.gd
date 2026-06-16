# CorpHumanBrain.gd
extends RefCounted
class_name CorpHumanBrain

# ── CorpHumanBrain ────────────────────────────────────────────────────────────
# Bridges the Corp decision-maker interface to the UI layer via proxy callables,
# mirroring the pattern used by HumanDecisionMaker for the Runner side.
#
# Main.gd sets each proxy to a function that shows a UI prompt and awaits the
# Corp player's input. In C1 all proxies are unset; each method returns a safe
# stub default so games run headlessly without UI.

signal action_selected(action: GameAction)

# ── Proxy callables (wired by CorpScene in C2+) ───────────────────────────────
var choose_rez_proxy:              Callable  # func(InstalledCard, GameContext) -> bool
var choose_discard_proxy:          Callable  # func(hand: Array, excess: int, GameContext) -> Variant
var choose_server_proxy:           Callable  # func(allowed: Array) -> String
var choose_card_from_hand_proxy:   Callable  # func(hand: Array) -> Variant
var choose_install_zone_proxy:     Callable  # func(CardRecord, Server) -> String
var choose_modes_proxy:            Callable  # func(modes: Array, max: int) -> Array
var choose_optional_ability_proxy: Callable  # func(prompt: String) -> bool
var choose_psi_bid_proxy:          Callable  # func(max_bid: int) -> int
var choose_trace_boost_proxy:      Callable  # func(base: int) -> int
var choose_window_action_proxy:    Callable  # func(GameContext, String, bool) -> GameAction
var choose_forfeit_agenda_proxy:   Callable  # func(agendas: Array, GameContext) -> Variant
var choose_trash_from_rig_proxy:   Callable  # func(candidates: Array, GameContext) -> InstalledCard
var choose_card_name_proxy:        Callable  # func(GameContext) -> String


# ── Core action selection ─────────────────────────────────────────────────────

func choose_action(_ctx: GameContext) -> GameAction:
	# Suspends until CorpScene (C2) emits action_selected with the Corp
	# player's chosen GameAction. Until then only stub/test callers emit this.
	return await action_selected


# ── Pre-click rez (before click phase) ───────────────────────────────────────

func get_pre_click_rez_actions(_ctx: GameContext) -> Array:
	# Corp may rez assets/upgrades as paid abilities before spending clicks.
	# In C1 this returns nothing; C3 wires the rez prompt via CorpScene.
	return []


# ── Rez decisions ─────────────────────────────────────────────────────────────

func choose_rez(card: InstalledCard, ctx: GameContext) -> bool:
	if choose_rez_proxy.is_valid():
		return await choose_rez_proxy.call(card, ctx)
	return false   # C1 stub: never rez


# ── Hand-limit discard ────────────────────────────────────────────────────────

func choose_discard_to_hand_limit(hand: Array, excess: int, ctx: GameContext) -> Variant:
	if choose_discard_proxy.is_valid():
		return await choose_discard_proxy.call(hand, excess, ctx)
	# Fallback heuristic: discard the cheapest non-agenda, same logic as
	# TurnManager's built-in fallback (TurnManager.gd lines ~319-336).
	var best_entry: Dictionary = {}
	var best_score: int = 9999
	for e in hand:
		var ed: Dictionary = e as Dictionary
		var cr: CardRecord = ed.get("card_record", null) as CardRecord
		if cr == null:
			continue
		var score: int = cr.cost if cr.cost >= 0 else 0
		if cr.card_type == "agenda":
			score += 100
		if score < best_score:
			best_score = score
			best_entry = ed
	if best_entry.is_empty() and not hand.is_empty():
		best_entry = hand[hand.size() - 1] as Dictionary
	return best_entry


# ── Server and install-zone selection ────────────────────────────────────────

func choose_server(allowed: Array, _ctx: GameContext) -> String:
	if choose_server_proxy.is_valid():
		return await choose_server_proxy.call(allowed)
	return allowed[0] if not allowed.is_empty() else ""


func choose_card_from_hand(hand: Array, _ctx: GameContext) -> Variant:
	if choose_card_from_hand_proxy.is_valid():
		return await choose_card_from_hand_proxy.call(hand)
	return hand[0] if not hand.is_empty() else null


func choose_install_zone(record: CardRecord, _server: Server, _ctx: GameContext) -> String:
	if choose_install_zone_proxy.is_valid():
		return await choose_install_zone_proxy.call(record, _server)
	return "ice" if record.is_ice() else "root"


func choose_install_faceup(_record: CardRecord, _ctx: GameContext) -> bool:
	# BANGUN identity — Corp chooses whether to install agendas faceup.
	# Stubbed false until C3 wires the prompt.
	return false


# ── Modal choices ─────────────────────────────────────────────────────────────

func choose_modes(modes: Array, _max_choices: int, _ctx: GameContext) -> Array:
	if choose_modes_proxy.is_valid():
		return await choose_modes_proxy.call(modes, _max_choices)
	return [0]   # default: first option


func choose_optional_ability(prompt: String, _ctx: GameContext) -> bool:
	if choose_optional_ability_proxy.is_valid():
		return await choose_optional_ability_proxy.call(prompt)
	return false


# ── Psi games and traces ──────────────────────────────────────────────────────

func choose_psi_bid(max_bid: int, _ctx: GameContext) -> int:
	if choose_psi_bid_proxy.is_valid():
		return await choose_psi_bid_proxy.call(max_bid)
	return 0   # C1 stub: always bid 0


func choose_trace_boost(base_strength: int, _ctx: GameContext) -> int:
	if choose_trace_boost_proxy.is_valid():
		return await choose_trace_boost_proxy.call(base_strength)
	return 0   # C1 stub: never boost traces


# ── Paid-ability windows ──────────────────────────────────────────────────────

func choose_window_action(ctx: GameContext, actor: String, can_rez_ice: bool) -> GameAction:
	if choose_window_action_proxy.is_valid():
		return await choose_window_action_proxy.call(ctx, actor, can_rez_ice)
	return GameAction.pass_window()


# ── Agenda forfeit ────────────────────────────────────────────────────────────

func choose_forfeit_agenda(agendas: Array, ctx: GameContext) -> Variant:
	if choose_forfeit_agenda_proxy.is_valid():
		return await choose_forfeit_agenda_proxy.call(agendas, ctx)
	return null   # C1 stub: decline to forfeit


# ── Azef Protocol additional scoring cost ─────────────────────────────────────

func choose_trash_from_rig(candidates: Array, ctx: GameContext) -> InstalledCard:
	if choose_trash_from_rig_proxy.is_valid():
		return await choose_trash_from_rig_proxy.call(candidates, ctx)
	# Fallback: trash the first unrezzed card, or candidates[0]
	for c in candidates:
		var ic: InstalledCard = c as InstalledCard
		if ic != null and not ic.is_rezzed:
			return ic
	return candidates[0] as InstalledCard if not candidates.is_empty() else null


# ── Card name and type choices ────────────────────────────────────────────────

func choose_card_name(ctx: GameContext) -> String:
	if choose_card_name_proxy.is_valid():
		return await choose_card_name_proxy.call(ctx)
	return ""


func choose_runner_card_type(types: Array, _ctx: GameContext) -> String:
	# Engram Flush, Saisentan, etc. — stub picks first type until C3.
	return types[0] if not types.is_empty() else "program"
