class_name CorpTurnAI
extends RefCounted

# ── CorpTurnAI ────────────────────────────────────────────────────────────────
# Heuristic Corp decision maker for choices that arise during the Corp's turn.
# Implements choose_action(ctx) -> GameAction.
#
# Also owns a CorpRunAI instance and forwards run-time decisions to it,
# making CorpTurnAI the single Corp decision maker the TurnManager interacts with.
#
# Priority order each click:
#   1. Score agenda if one is ready in a protected remote
#   2. Advance agenda that is one counter away from scoring, in a protected remote
#   3. Install agenda in a protected remote (if one exists with ice)
#   4. Install ice on HQ if unprotected
#   5. Install ice on R&D if unprotected
#   6. Install ice on a remote with an agenda
#   7. Gain credits if below economy threshold
#   8. Draw a card if hand is small and deck is not empty
#   9. Gain credits (fallback)

const ECONOMY_THRESHOLD := 6   # try to stay above this credit level
const ECONOMY_CEILING   := 14  # don't gain credits beyond this — find something better to do
const MIN_HAND_SIZE     := 4   # draw if hand drops below this

var _run_ai: CorpRunAI
var _ability_registry: AbilityRegistry


func _init(ability_registry: AbilityRegistry) -> void:
	_run_ai = CorpRunAI.new(ability_registry)
	_ability_registry = ability_registry


# ── Turn-time interface ───────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
	# Free rezzes are handled by get_pre_click_rez_actions() called from TurnManager
	# before this loop — do not mix free paid-actions with click actions here.

	# 0a. Petty Cash from Archives: play as first action if available (nets +5cr, click-neutral).
	if not ctx.corp_finished_an_action_this_turn:
		for cr in ctx.corp_discard:
			var pc_record: CardRecord = cr as CardRecord
			if pc_record != null and pc_record.id == "petty_cash":
				return GameAction.play_from_archives("petty_cash")

	# 0b. Use click actions on installed Corp cards (e.g. Regolith Mining License)
	var card_with_action := _find_corp_click_action(ctx)
	if card_with_action != null:
		return GameAction.use_installed_card(card_with_action.runtime_instance_id, card_with_action.card_id)

	# 1. Score a ready agenda
	var ready := _find_ready_agenda(ctx)
	if ready != null:
		# Scoring is free (no click cost in standard rules — handled in TurnManager
		# via the advance action triggering auto-score). If already at requirement,
		# we just advance once more to trigger scoring. This is a simplification;
		# proper scoring as a free action will be refined later.
		if ready.meets_advancement_requirement():
			return GameAction.advance(ready.card_id)

	# 2. Advance an agenda that is one away from scoring, in a protected remote
	var almost := _find_almost_scored_agenda(ctx)
	if almost != null and ctx.corp_credits >= 1:
		return GameAction.advance(almost.card_id)

	# 3. Install an agenda — prefer a protected remote, but also install into
	#    a new unprotected remote if we have ice in hand to protect it next click
	var agenda_to_install := _find_agenda_in_hand(ctx)
	if agenda_to_install != null:
		var protected_remote := _find_protected_empty_remote(ctx)
		if protected_remote != null:
			return GameAction.install(agenda_to_install, protected_remote.server_id)
		# No protected remote — install into new remote if we have ice to follow up
		elif _find_ice_in_hand(ctx) != null and ctx.corp_credits >= max(0, agenda_to_install.cost) + 1:
			var new_remote := ctx.create_remote_server()
			return GameAction.install(agenda_to_install, new_remote.server_id)

	# 4. Protect HQ if unprotected
	if not _server_has_ice(ctx, "hq"):
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, "hq", "ice")

	# 5. Protect R&D if unprotected
	if not _server_has_ice(ctx, "rd"):
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, "rd", "ice")

	# 6. Install ice on a remote that has an agenda but needs more ice
	var vulnerable_remote := _find_agenda_remote_needing_ice(ctx)
	if vulnerable_remote != null:
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, vulnerable_remote.server_id, "ice")

	# 7. Install ice on a remote that has cards but no ice
	var unprotected_remote := _find_remote_needing_ice(ctx)
	if unprotected_remote != null:
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, unprotected_remote.server_id, "ice")

	# 8. Install an asset in a new remote if we have one and can afford it
	var asset_to_install := _find_asset_in_hand(ctx)
	if asset_to_install != null and ctx.corp_credits >= max(0, asset_to_install.cost):
		var new_remote := ctx.create_remote_server()
		return GameAction.install(asset_to_install, new_remote.server_id)

	# 9. Advance any installed agenda in a protected remote
	if ctx.corp_credits >= 1:
		var any_agenda := _find_any_installed_agenda(ctx)
		if any_agenda != null:
			return GameAction.advance(any_agenda.card_id)

	# 10. Advance any installed agenda even in an unprotected remote — don't
	#     just sit on it forever waiting for ice that never comes.
	if ctx.corp_credits >= 1:
		var exposed_agenda := _find_any_installed_agenda_unprotected(ctx)
		if exposed_agenda != null:
			return GameAction.advance(exposed_agenda.card_id)

	# 11. Draw if hand is below threshold — prefer options over credits
	if ctx.corp_hand.size() < MIN_HAND_SIZE and not ctx.corp_deck.is_empty():
		return GameAction.draw_card()

	# 12. Play an operation rather than clicking for 1 credit where possible.
	#     Economy ops (Hedge Fund, Government Subsidy) are far more efficient.
	#     Only skip if already at the economy ceiling (nothing left to buy).
	if ctx.corp_credits < ECONOMY_CEILING:
		var best_op := _find_best_operation(ctx)
		if best_op != null:
			return GameAction.play_operation(best_op)

	# 13. Gain credits if below threshold
	if ctx.corp_credits < ECONOMY_THRESHOLD:
		return GameAction.gain_credits()

	# 14. Draw as general fallback — cycle the deck to find something useful
	#     rather than hoarding credits above the ceiling.
	if not ctx.corp_deck.is_empty() and ctx.corp_hand.size() < 6:
		return GameAction.draw_card()

	# 15. Gain credits up to ceiling
	if ctx.corp_credits < ECONOMY_CEILING:
		return GameAction.gain_credits()

	# 16. Hard fallback — truly nothing to do (stall click)
	return GameAction.gain_credits()


# ── Run-time interface (forwarded to CorpRunAI) ───────────────────────────────

func choose_rez(card: InstalledCard, ctx: GameContext) -> bool:
	return _run_ai.choose_rez(card, ctx)


func choose_from_search(candidates: Array, _ctx: GameContext) -> CardRecord:
	# Heuristic: pick the cheapest card (most immediately playable)
	var best: CardRecord = candidates[0] as CardRecord
	for c in candidates:
		var r: CardRecord = c as CardRecord
		if r != null and r.cost < best.cost:
			best = r
	return best


func choose_card_from_hand(hand: Array, _ctx: GameContext) -> Variant:
	# Heuristic: return the most expensive card (hardest to play again soon),
	# or if all equal, just return the last card drawn (index 0 = oldest).
	var best: Variant = hand[0]
	var best_cost: int = -1
	for entry in hand:
		var r: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if r != null and r.cost > best_cost:
			best_cost = r.cost
			best = entry
	return best



func get_pre_click_rez_actions(ctx: GameContext) -> Array:
	var actions: Array = []
	for server in ctx.servers.values():
		var s: Server = server as Server
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if not c.is_rezzed and c.card_record != null:
				var ctype: String = c.card_record.card_type
				if (ctype == "asset" or ctype == "upgrade") and ctx.corp_credits >= ctx.query_rez_cost(c):
					actions.append(GameAction.rez_card(c.card_id, c.runtime_instance_id))
	return actions


# Corp chooses which scored agenda to forfeit (or null to decline for optional forfeits).
# AI heuristic: forfeit the agenda worth the fewest points (minimise agenda point loss).
func choose_sabotage_discard(ctx: GameContext) -> Dictionary:
	# Called by AbilityInterpreter when the Runner's card triggers sabotage.
	# Returns {"source": "hq", "card_record": cr} or {"source": "rd"}.
	# Strategy: trash the cheapest non-agenda from HQ to avoid giving the Runner
	# a stealable agenda in Archives; fall back to top of R&D otherwise.
	var best_cr: CardRecord = null
	var best_cost := 9999
	for hand_entry in ctx.corp_hand:
		var cr: CardRecord = hand_entry.get("card_record") as CardRecord
		if cr == null or cr.card_type == "agenda":
			continue
		if cr.cost < best_cost:
			best_cost = cr.cost
			best_cr = cr
	if best_cr != null:
		return {"source": "hq", "card_record": best_cr}
	if not ctx.corp_deck.is_empty():
		return {"source": "rd"}
	if not ctx.corp_hand.is_empty():
		return {"source": "hq", "card_record": ctx.corp_hand[0].get("card_record") as CardRecord}
	return {}


func choose_forfeit_agenda(candidates: Array, _ctx: GameContext) -> InstalledCard:
	if candidates.is_empty():
		return null
	var best: InstalledCard = candidates[0] as InstalledCard
	for c in candidates:
		var ic: InstalledCard = c as InstalledCard
		if ic == null or ic.card_record == null:
			continue
		if best.card_record == null or ic.card_record.agenda_points < best.card_record.agenda_points:
			best = ic
	return best


func choose_from_runner_score(candidates: Array, _ctx: GameContext) -> CardRecord:
	# IP Enforcement: Corp takes the highest-value agenda from the Runner's score area.
	# Maximises the point swing: Corp gains the most points while Runner loses the most.
	if candidates.is_empty():
		return null
	var best: CardRecord = candidates[0] as CardRecord
	for c in candidates:
		var cr: CardRecord = c as CardRecord
		if cr != null and cr.agenda_points > best.agenda_points:
			best = cr
	return best


func choose_pay_shred_etr(_count: int, _ctx: GameContext) -> bool:
	# Shred interrupt: Corp may trash 'count' random HQ cards to keep the ETR.
	# AI always pays — ending the run is almost always worth the card loss.
	return true


func choose_window_action(ctx: GameContext, actor: String, can_rez_ice: bool) -> GameAction:
	# The Corp AI's behaviour during a paid-ability/rez timing window.
	# During approach (can_rez_ice = true): decide whether to rez the approached ice.
	# During movement or encounter (can_rez_ice = false): consider rezzing upgrades.
	if actor != "corp":
		return GameAction.pass_window()

	var target_server: Server = ctx.get_server(ctx.run_target_server)
	if target_server == null:
		return GameAction.pass_window()

	if can_rez_ice:
		# Find the outermost unrezzed ice — that's what the runner is approaching.
		# The RunStateMachine snapshots ice at run start; we scan the live server
		# for the first unrezzed piece at the current approach position.
		for ice in target_server.ice:
			var c: InstalledCard = ice as InstalledCard
			if not c.is_rezzed:
				if _run_ai.choose_rez(c, ctx):
					var iid: String = c.get("runtime_instance_id") if c.get("runtime_instance_id") != null else ""
					return GameAction.rez_card(c.card_id, iid)
			break  # only consider the outermost unrezzed piece
	else:
		# Non-approach window: consider rezzing upgrades in the target server root
		for root_card in target_server.root:
			var c: InstalledCard = root_card as InstalledCard
			if not c.is_rezzed and c.card_record != null and c.card_record.card_type == "upgrade":
				if _run_ai.choose_rez(c, ctx):
					var iid: String = c.get("runtime_instance_id") if c.get("runtime_instance_id") != null else ""
					return GameAction.rez_card(c.card_id, iid)

	# Check for scored agenda paw_actions usable during any run window
	# (e.g. Proprionegation: spend 1 agenda counter to move runner to outermost Archives).
	for agenda_card in ctx.corp_score_area_cards:
		var ag: InstalledCard = agenda_card as InstalledCard
		if ag == null or ag.card_record == null:
			continue
		var ag_def: Dictionary = _ability_registry._abilities.get(ag.card_id, {}) as Dictionary
		var paw_def: Variant   = ag_def.get("paw_action", null)
		if paw_def == null:
			continue
		# Check conditions: needs agenda counter and run must be active (already true here)
		if ag.get_counter("agenda") <= 0:
			continue
		# AI heuristic: only use Proprionegation when it would help (runner past all ice,
		# Archives has ice that would stop the runner)
		var archives_server: Server = ctx.get_server("archives")
		if archives_server != null and archives_server.ice_count() > 0:
			return GameAction.use_installed_card(ag.runtime_instance_id, ag.card_id)

	return GameAction.pass_window()


# ── Heuristic helpers ─────────────────────────────────────────────────────────

func _find_ready_agenda(ctx: GameContext) -> InstalledCard:
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null:
				continue
			if c.card_record.is_agenda() and c.meets_advancement_requirement():
				return c
	return null


func _find_almost_scored_agenda(ctx: GameContext) -> InstalledCard:
	# An agenda that needs exactly one more advancement counter to score,
	# sitting in a remote with at least one piece of ice.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote() or not s.has_ice():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null or not c.card_record.is_agenda():
				continue
			var needed: int = c.card_record.advancement_requirement - c.get_counter("advancement")
			if needed == 1:
				return c
	return null


func _find_agenda_in_hand(ctx: GameContext) -> CardRecord:
	for entry in ctx.corp_hand:
		var e: Dictionary  = entry as Dictionary
		var r: CardRecord  = e.get("card_record", null) as CardRecord
		if r != null and r.is_agenda():
			return r
	return null


func _find_ice_in_hand(ctx: GameContext) -> CardRecord:
	for entry in ctx.corp_hand:
		var e: Dictionary = entry as Dictionary
		var r: CardRecord = e.get("card_record", null) as CardRecord
		if r != null and r.is_ice():
			return r
	return null


func _find_protected_empty_remote(ctx: GameContext) -> Server:
	# A remote server that has ice but no agenda/asset in its root.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote():
			continue
		if s.has_ice() and s.get_agenda_or_asset() == null:
			return s
	return null


func _find_agenda_remote_needing_ice(ctx: GameContext) -> Server:
	# A remote with an agenda but fewer than 2 ice protecting it.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote():
			continue
		if s.get_agenda_or_asset() == null:
			continue
		if s.ice_count() < 2:
			return s
	return null


func _find_remote_needing_ice(ctx: GameContext) -> Server:
	# A remote with cards installed but no protecting ice
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote():
			continue
		if not s.is_empty() and not s.has_ice():
			return s
	return null


func _find_asset_in_hand(ctx: GameContext) -> CardRecord:
	for entry in ctx.corp_hand:
		var e: Dictionary = entry as Dictionary
		var r: CardRecord = e.get("card_record", null) as CardRecord
		if r != null and r.is_asset():
			return r
	return null


func _find_any_installed_agenda(ctx: GameContext) -> InstalledCard:
	# Any agenda installed in a protected (iced) remote that hasn't met its requirement.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote() or not s.has_ice():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null or not c.card_record.is_agenda():
				continue
			if not c.meets_advancement_requirement():
				return c
	return null


func _find_any_installed_agenda_unprotected(ctx: GameContext) -> InstalledCard:
	# Fallback: any agenda installed in a remote WITHOUT ice that hasn't met its requirement.
	# Used when no iced remote exists — better to advance the exposed agenda than do nothing.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote() or s.has_ice():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null or not c.card_record.is_agenda():
				continue
			if not c.meets_advancement_requirement():
				return c
	return null





func choose_modes(modes: Array, max_choices: int, ctx: GameContext) -> Array:
	# Detect if this is a "Corp chooses on Runner's turn" situation (e.g. Wildcat Strike).
	# In that case, pick whichever option hurts the Runner most.
	var is_adversarial: bool = ctx.active_player == "runner"

	if is_adversarial:
		# Deny what the Runner needs most:
		# - If Runner has few credits (≤3), deny credits → pick draw
		# - If Runner has large hand (≥4 cards), deny draw → pick credits
		# - Otherwise, deny credits (economy denial is usually stronger)
		var deny_credits: bool = ctx.runner_credits <= 3
		var deny_draw:    bool = ctx.runner_hand.size() >= 4
		for i in range(modes.size()):
			var label: String = (modes[i] as Dictionary).get("label", "").to_lower()
			if deny_credits and "credit" in label:
				ctx.send_log("[Wildcat Strike] Corp denies credits — Runner draws instead.")
				return [i]
			if deny_draw and "draw" in label:
				ctx.send_log("[Wildcat Strike] Corp denies draws — Runner gains credits instead.")
				return [i]
		# Default: deny credits (economy denial)
		for i in range(modes.size()):
			if "credit" in (modes[i] as Dictionary).get("label", "").to_lower():
				ctx.send_log("[Wildcat Strike] Corp denies credits by default.")
				return [i]
		return [0]

	# Normal Corp-turn modal: pick based on Corp's own needs
	var want_credits: bool = ctx.corp_credits < ECONOMY_THRESHOLD
	var result: Array = []
	for i in range(min(max_choices, modes.size())):
		var mode: Dictionary = modes[i] as Dictionary
		var label: String = mode.get("label", "").to_lower()
		if want_credits and "credit" in label:
			result.append(i)
			break
		elif not want_credits and "draw" in label:
			result.append(i)
			break
	if result.is_empty():
		result.append(0)
	return result


func _find_playable_operations(ctx: GameContext) -> Array:
	# Returns all operations in the Corp hand that are currently affordable.
	var ops: Array = []
	for entry in ctx.corp_hand:
		var r: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if r == null or r.card_type != "operation":
			continue
		if ctx.corp_credits >= max(0, r.cost):
			ops.append(r)
	return ops


func _find_best_operation(ctx: GameContext) -> CardRecord:
	# Heuristic: prefer high-value economy operations; fall back to any playable op.
	# Economy value is net-credit gain (gain - cost).  Non-economy ops are rated 0.
	const ECONOMY_IDS := {
		"government_subsidy": 11,   # gains 14, costs 3
		"hedge_fund":          4,   # gains 9,  costs 5
		"predictive_planogram": 3,  # gains 3 (corp path)
		"hansei_review":        2,  # draw value approximated as 2cr-equivalent
	}
	var best_op: CardRecord   = null
	var best_val: int         = -1
	for entry in ctx.corp_hand:
		var r: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if r == null or r.card_type != "operation":
			continue
		if ctx.corp_credits < max(0, r.cost):
			continue
		var val: int = ECONOMY_IDS.get(r.id, 0) as int
		if val > best_val:
			best_val = val
			best_op  = r
	# Only play zero-value ops (Neurospike, etc.) if we have nothing better to do.
	if best_op != null and best_val >= 0:
		return best_op
	return null


func _server_has_ice(ctx: GameContext, server_id: String) -> bool:
	var server: Server = ctx.get_server(server_id)
	return server != null and server.has_ice()


func _find_unrezzed_asset_or_upgrade(ctx: GameContext) -> InstalledCard:
	# Find any installed but unrezzed asset or upgrade the Corp can afford to rez
	for server in ctx.servers.values():
		var s: Server = server as Server
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if not c.is_rezzed and c.card_record != null:
				var ctype: String = c.card_record.card_type
				if ctype == "asset" or ctype == "upgrade":
					return c
	return null


func _find_corp_click_action(ctx: GameContext) -> InstalledCard:
	# Find a rezzed Corp installed card with a click_action and resources remaining.
	for server in ctx.servers.values():
		var s: Server = server as Server
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if not c.is_rezzed or c.card_record == null:
				continue
			var card_def: Dictionary = _ability_registry._abilities.get(c.card_id, {}) as Dictionary
			var click_def: Dictionary = card_def.get("click_action", {}) as Dictionary
			if click_def.is_empty():
				continue
			# One-shot abilities (e.g. Humanoid Resources): use whenever we have
			# enough clicks — there are no counter resources to deplete.
			if click_def.get("one_shot", false):
				var needed: int = 1 + click_def.get("additional_cost_clicks", 0)
				if ctx.corp_clicks >= needed:
					return c
			# Standard assets/upgrades: use if they have hosted credits
			elif c.get_counter("credits") > 0:
				return c
	# Also check scored agendas — Dividends click actions spend "agenda" counters
	for card in ctx.corp_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		if c == null or c.card_record == null:
			continue
		var card_def: Dictionary = _ability_registry._abilities.get(c.card_id, {}) as Dictionary
		if not card_def.has("click_action"):
			continue
		if c.get_counter("agenda") > 0:
			return c
	# Also check runner's score area — Corp can use some stolen agendas (e.g. Next Big Thing)
	for card in ctx.runner_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		if c == null or c.card_record == null:
			continue
		var card_def: Dictionary = _ability_registry._abilities.get(c.card_id, {}) as Dictionary
		var ca_def: Dictionary = card_def.get("click_action", {}) as Dictionary
		if ca_def.is_empty() or ca_def.get("subject", "") != "corp":
			continue
		if c.get_counter("agenda") > 0:
			return c
	return null


func choose_use_anoetic_void(ctx: GameContext) -> bool:
	# Use Anoetic Void if we can afford the tempo hit and the breach is dangerous.
	# Heuristic: use it if runner has 4+ agenda points (close to winning)
	# or the server being breached has an agenda installed.
	if ctx.corp_credits < 4:   # need 2cr + want some reserve
		return false
	if ctx.corp_hand.size() < 2:
		return false
	# Always use it if runner is close to winning
	if ctx.runner_agenda_points() >= ctx.agenda_points_to_win - 2:
		return true
	# Use it if the breached server has an agenda
	var breach_server_id: String = ctx.current_event_data.get("server_id", "")
	var server: Server = ctx.get_server(breach_server_id)
	if server != null:
		for card in server.root:
			var c: InstalledCard = card as InstalledCard
			if c != null and c.card_record != null and c.card_record.is_agenda():
				return true
	return false


func choose_tags_to_remove(max_count: int, _ctx: GameContext) -> int:
	# Bigger Picture: always remove all tags to maximise credit drain.
	return max_count


func choose_install_faceup(_card_record: CardRecord, _ctx: GameContext) -> bool:
	# BANGUN: always install agendas faceup — the access punishment is the whole point.
	return true


func choose_runner_card_type(types: Array, ctx: GameContext) -> String:
	# Touch-ups: pick the card type most represented in the runner's grip.
	var counts: Dictionary = {}
	for entry in ctx.runner_hand:
		var r: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if r != null:
			counts[r.card_type] = counts.get(r.card_type, 0) + 1
	var best := 0
	var best_type := ""
	for t in types:
		if counts.get(t, 0) > best:
			best = counts.get(t, 0)
			best_type = t
	return best_type if best_type != "" else types[0]


func choose_optional_ability(_prompt: String, _ctx: GameContext) -> bool:
	# Generic optional ability — Corp AI always activates optional abilities.
	return true


func choose_activate_clearinghouse(card: InstalledCard, ctx: GameContext) -> bool:
	# Activate if the damage would flatline or nearly flatline the runner,
	# OR if the runner is close to winning (desperate times).
	var counters: int    = card.get_counter("advancement")   # read actual counters; corp_turn_start fires before any clicks
	var runner_grip: int = ctx.runner_hand.size()

	# Always activate if it kills
	if counters >= runner_grip:
		return true

	# Activate if runner is 1 steal away from winning and we have 3+ counters
	if ctx.runner_agenda_points() >= ctx.agenda_points_to_win - 2 and counters >= 3:
		return true

	# Otherwise hold — let it grow more threatening
	return false
