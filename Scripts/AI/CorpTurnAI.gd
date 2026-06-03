class_name CorpTurnAI
extends RefCounted

# ── CorpTurnAI ────────────────────────────────────────────────────────────────
# Improved Corp decision maker.
#
# Priority order each click:
#   0a. Play Petty Cash from Archives (first action only)
#   0b. Use a beneficial click action on an installed Corp card (asset/upgrade/agenda)
#    1. Score a ready agenda
#   ── State-aware overrides (fire when a decisive condition holds) ────────────
#    A. Kill window  : play a damage operation if runner grip ≤ 2
#    A2. Trap window  : advance an installed trap card if one more counter kills
#    B. Scoring window: advance if agenda is 1 click from scoring and runner is broke
#    C. Runner pressure: install ice immediately if runner has a complete rig
#   ───────────────────────────────────────────────────────────────────────────
#    2. Advance an agenda one counter away (in a protected remote)
#    3. Install an agenda (prefer protected remote, else new remote if ice in hand)
#    4. Reinforce HQ if it has been successfully run this turn and has <2 ice
#    5. Reinforce R&D similarly
#    6. Protect HQ if it has no ice
#    7. Protect R&D if it has no ice
#    8. Install ice on a remote that has an agenda but needs more ice
#    9. Install ice on any remote that has cards but no ice
#   9.5 Install an upgrade in the best available server
#   10. Install an asset in a new remote
#   11. Advance any installed agenda in a protected remote
#   12. Advance any installed agenda (even unprotected – don’t stall forever)
#   13. Play a beneficial operation that passes its condition
#   14. Draw if hand size < MIN_HAND_SIZE
#   15. Gain credits if below _economy_threshold() (game-state adaptive)
#   16. Draw (general fallback)
#   17. Gain credits up to ceiling
#   18. Gain credits (hard fallback)

const ECONOMY_THRESHOLD := 6
const ECONOMY_CEILING   := 14
const MIN_HAND_SIZE     := 4

# Operations that can deal direct damage.  Checked by _kill_window_check.
const DAMAGE_OPERATION_IDS := ["neurospike", "punitive_counterstrike", "boom", "scorched_earth"]

var _run_ai: CorpRunAI
var _ability_registry: AbilityRegistry
var _interpreter: AbilityInterpreter   # needed for condition evaluation


func _init(ability_registry: AbilityRegistry) -> void:
	_run_ai = CorpRunAI.new(ability_registry)
	_ability_registry = ability_registry
	_interpreter = AbilityInterpreter.new()


# ── Turn-time interface ───────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
	var action := _choose_action_impl(ctx)
	if not ctx.simulation_mode:
		DecisionLogger.log_heuristic(ctx, action)
	return action


func _choose_action_impl(ctx: GameContext) -> GameAction:
	# 0a. Petty Cash from Archives (first action only)
	if not ctx.corp_finished_an_action_this_turn:
		for cr in ctx.corp_discard:
			var pc_record: CardRecord = cr as CardRecord
			if pc_record != null and pc_record.id == "petty_cash":
				return GameAction.play_from_archives("petty_cash")

	# 0b. Click actions on installed cards (scored first by benefit)
	var best_card := _best_click_action_card(ctx)
	if best_card != null:
		return GameAction.use_installed_card(best_card.runtime_instance_id, best_card.card_id)

	# 1. Score a ready agenda
	var ready := _find_ready_agenda(ctx)
	if ready != null:
		return GameAction.advance(ready.card_id)

	# ── State-aware overrides ──────────────────────────────────────────────────
	# A. Kill window: runner grip is small enough that a damage op ends the game.
	var kill_action := _kill_window_check(ctx)
	if kill_action != null:
		return kill_action

	# A2. Trap window: one more counter on an installed trap card reaches kill range.
	var trap_action := _trap_window_check(ctx)
	if trap_action != null:
		return trap_action

	# B. Scoring window: agenda is one click away and runner cannot afford to run.
	var window_action := _scoring_window_check(ctx)
	if window_action != null:
		return window_action

	# C. Runner pressure: runner has a complete rig — ice up exposed servers now.
	var pressure_action := _runner_pressure_check(ctx)
	if pressure_action != null:
		return pressure_action
	# ──────────────────────────────────────────────────────────────────────────

	# 2. Advance an agenda that is one away, in a protected remote
	var almost := _find_almost_scored_agenda(ctx)
	if almost != null and ctx.corp_credits >= 1:
		return GameAction.advance(almost.card_id)

	# 3. Install an agenda
	var agenda_to_install := _find_agenda_in_hand(ctx)
	if agenda_to_install != null:
		var protected_remote := _find_protected_empty_remote(ctx)
		if protected_remote != null:
			return GameAction.install(agenda_to_install, protected_remote.server_id)
		elif _find_ice_in_hand(ctx) != null and ctx.corp_credits >= max(0, agenda_to_install.cost) + 1:
			var new_remote := ctx.create_remote_server()
			return GameAction.install(agenda_to_install, new_remote.server_id)

	# 4. Reinforce HQ if it has been successfully run this turn and has <2 ice
	if ctx.runner_hq_successful_run_this_turn and _server_ice_count(ctx, "hq") < 2:
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, "hq", "ice")

	# 5. Reinforce R&D similarly
	if ctx.runner_successful_run_on_rd_this_turn and _server_ice_count(ctx, "rd") < 2:
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, "rd", "ice")

	# Optional: reinforce Archives if it has been successfully run this turn
	if ctx.runner_successful_run_on_archives_this_turn and _server_ice_count(ctx, "archives") < 2:
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, "archives", "ice")

	# 6. Protect HQ if no ice
	if not _server_has_ice(ctx, "hq"):
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, "hq", "ice")

	# 7. Protect R&D if no ice
	if not _server_has_ice(ctx, "rd"):
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, "rd", "ice")

	# 8. Install ice on a remote that has an agenda but needs more ice
	var vulnerable_remote := _find_agenda_remote_needing_ice(ctx)
	if vulnerable_remote != null:
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, vulnerable_remote.server_id, "ice")

	# 9. Install ice on any remote that has cards but no ice
	var unprotected_remote := _find_remote_needing_ice(ctx)
	if unprotected_remote != null:
		var ice := _find_ice_in_hand(ctx)
		if ice != null:
			return GameAction.install(ice, unprotected_remote.server_id, "ice")

	# 9.5. Install an upgrade in the best available server
	var upgrade_to_install := _find_upgrade_in_hand(ctx)
	if upgrade_to_install != null and ctx.corp_credits >= max(0, upgrade_to_install.cost):
		var upgrade_server := _find_best_upgrade_server(ctx)
		if upgrade_server != null:
			return GameAction.install(upgrade_to_install, upgrade_server.server_id)

	# 10. Install an asset in a new remote
	var asset_to_install := _find_asset_in_hand(ctx)
	if asset_to_install != null and ctx.corp_credits >= max(0, asset_to_install.cost):
		var new_remote := ctx.create_remote_server()
		return GameAction.install(asset_to_install, new_remote.server_id)

	# 11. Advance any installed agenda in a protected remote
	if ctx.corp_credits >= 1:
		var any_agenda := _find_any_installed_agenda(ctx)
		if any_agenda != null:
			return GameAction.advance(any_agenda.card_id)

	# 12. Advance any installed agenda even unprotected
	if ctx.corp_credits >= 1:
		var exposed_agenda := _find_any_installed_agenda_unprotected(ctx)
		if exposed_agenda != null:
			return GameAction.advance(exposed_agenda.card_id)

	# 12.5. Advance an installed trap card when the runner's grip is in threat range.
	# Builds up Clearinghouse counters, Urtica Cipher potency, etc. before kill window.
	if ctx.corp_credits >= 1 and ctx.runner_hand.size() <= 5:
		var trap := _find_advanceable_non_agenda(ctx)
		if trap != null:
			return GameAction.advance(trap.card_id)

	# 13. Play a beneficial operation (passing condition)
	var best_op := _find_best_operation(ctx)
	if best_op != null:
		return GameAction.play_operation(best_op)

	# 14. Draw if hand is below threshold
	if ctx.corp_hand.size() < MIN_HAND_SIZE and not ctx.corp_deck.is_empty():
		return GameAction.draw_card()

	# 15. Gain credits if below adaptive threshold
	if ctx.corp_credits < _economy_threshold(ctx):
		return GameAction.gain_credits()

	# 16. Draw as fallback
	if not ctx.corp_deck.is_empty() and ctx.corp_hand.size() < 6:
		return GameAction.draw_card()

	# 17. Gain credits up to ceiling
	if ctx.corp_credits < ECONOMY_CEILING:
		return GameAction.gain_credits()

	# 18. Hard fallback
	return GameAction.gain_credits()


# ── Run‑time interface (forwarded to CorpRunAI) ───────────────────────────────

func choose_rez(card: InstalledCard, ctx: GameContext) -> bool:
	return _run_ai.choose_rez(card, ctx)


func choose_from_search(candidates: Array, _ctx: GameContext) -> CardRecord:
	var best: CardRecord = candidates[0] as CardRecord
	for c in candidates:
		var r: CardRecord = c as CardRecord
		if r != null and r.cost < best.cost:
			best = r
	return best


func choose_card_from_hand(hand: Array, _ctx: GameContext) -> Variant:
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
				# Avoid rezzing trap assets (Snare!, etc.) – leave them unrezzed
				if (ctype == "asset" or ctype == "upgrade") and ctx.corp_credits >= ctx.query_rez_cost(c):
					if _is_safe_to_rez_asset(c):
						actions.append(GameAction.rez_card(c.card_id, c.runtime_instance_id))
	return actions


func choose_sabotage_discard(ctx: GameContext) -> Dictionary:
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
	if candidates.is_empty():
		return null
	var best: CardRecord = candidates[0] as CardRecord
	for c in candidates:
		var cr: CardRecord = c as CardRecord
		if cr != null and cr.agenda_points > best.agenda_points:
			best = cr
	return best


func choose_pay_shred_etr(_count: int, _ctx: GameContext) -> bool:
	return true


func choose_discard_to_hand_limit(hand: Array, excess: int, _ctx: GameContext) -> Array:
	# Heuristic: discard the least-valuable non-agenda cards first.
	# Agendas are last resort — having them in Archives is dangerous.
	# Within non-agendas: discard lowest-cost operations first (easiest to redraw/replay),
	# keep expensive assets/ice/upgrades (harder to rebuild board state).
	var scored: Array = []
	for e in hand:
		var ed: Dictionary = e as Dictionary
		var cr: CardRecord = ed.get("card_record", null) as CardRecord
		if cr == null:
			continue
		var type_score: int
		match cr.card_type:
			"operation": type_score = 0    # cheapest to replay
			"asset":     type_score = 100
			"upgrade":   type_score = 150
			"ice":       type_score = 200
			"agenda":    type_score = 10000  # strong preference to keep
			_:           type_score = 50
		var card_score: int = type_score + (cr.cost if cr.cost >= 0 else 0)
		scored.append({"entry": ed, "score": card_score})
	scored.sort_custom(func(a, b): return a.score < b.score)
	var result: Array = []
	for i in range(mini(excess, scored.size())):
		result.append(scored[i].entry)
	return result


func choose_window_action(ctx: GameContext, actor: String, can_rez_ice: bool) -> GameAction:
	if actor != "corp":
		return GameAction.pass_window()

	var target_server: Server = ctx.get_server(ctx.run_target_server)
	if target_server == null:
		return GameAction.pass_window()

	if can_rez_ice:
		for ice in target_server.ice:
			var c: InstalledCard = ice as InstalledCard
			if not c.is_rezzed:
				if _run_ai.should_rez_ice(c, ctx):  # lifetime-value model
					return GameAction.rez_card(c.card_id, c.runtime_instance_id)
			break  # only consider the outermost unrezzed ice
	else:
		# Consider rezzing upgrades in root (e.g., Ash)
		for root_card in target_server.root:
			var c: InstalledCard = root_card as InstalledCard
			if not c.is_rezzed and c.card_record != null and c.card_record.card_type == "upgrade":
				if ctx.corp_credits >= ctx.query_rez_cost(c):
					return GameAction.rez_card(c.card_id, c.runtime_instance_id)

	# Check ice trash abilities (e.g. M.I.C.: trash self → Runner spends [click] or run ends).
	if not ctx.corp_ice_trash_abilities_available.is_empty():
		for _mic_entry in ctx.corp_ice_trash_abilities_available:
			var _mic_e: Dictionary       = _mic_entry as Dictionary
			var _mic_ice: InstalledCard  = _mic_e.get("card", null) as InstalledCard
			if _mic_ice == null:
				continue
			# Heuristic: use if runner has no clicks left (guaranteed ETR) or only 1 click.
			# Trashing our own ice is a real cost, so only do it when it will matter.
			if ctx.runner_clicks <= 1:
				return GameAction.use_ice_trash_ability(_mic_ice.runtime_instance_id, _mic_ice.card_id)

	# Check scored agendas with paw_actions (generic)
	for agenda_card in ctx.corp_score_area_cards:
		var ag: InstalledCard = agenda_card as InstalledCard
		if ag == null or ag.card_record == null:
			continue
		var ag_def: Dictionary = _ability_registry._abilities.get(ag.card_id, {}) as Dictionary
		var paw_def: Variant   = ag_def.get("paw_action", null)
		if paw_def == null:
			continue
		if ag.get_counter("agenda") <= 0:
			continue
		# Generic condition evaluation for paw_action
		var condition: Dictionary = (paw_def as Dictionary).get("condition", {}) as Dictionary
		if not condition.is_empty():
			if not _interpreter._evaluate_condition(condition, ctx):
				continue
		return GameAction.use_installed_card(ag.runtime_instance_id, ag.card_id)

	return GameAction.pass_window()


# ── New / improved decision methods ───────────────────────────────────────────

# Called by AbilityInterpreter when the Corp may pay an optional cost for a trigger
# (e.g., Urtica Cipher, Byte, Anoetic Void already has its own method).
# Parameters:
#   card         - the card triggering the optional payment (e.g., Urtica Cipher)
#   ctx          - game context
#   cost         - credits the Corp must pay to activate
#   benefit_type - String describing the benefit: "damage", "credits", "tag"
#   value        - the amount of the benefit (e.g., damage points, credits gained, tags given)
func choose_pay_optional_trigger(card: InstalledCard, ctx: GameContext, cost: int, benefit_type: String, value: int) -> bool:
	match benefit_type.to_lower():
		"damage":
			var runner_grip = ctx.runner_hand.size()
			# Pay if it would flatline or remove runner's last card, or if runner is close to winning
			if value >= runner_grip:
				return true
			if ctx.runner_agenda_points() >= ctx.agenda_points_to_win - 2:
				return true
			return false
		"credits":
			# Pay if the net gain (value - cost) is positive and Corp needs credits
			var net = value - cost
			return net > 0 and ctx.corp_credits < ECONOMY_THRESHOLD + 5
		"tag":
			# Pay to give tags if runner has few tags and we can land them
			return ctx.runner_tags < 2
		_:
			# Unknown benefit – decline by default
			return false


# NEW: Score a click action based on expected benefit.
func _score_click_action(card: InstalledCard, ctx: GameContext) -> int:
	var card_def: Dictionary = _ability_registry._abilities.get(card.card_id, {}) as Dictionary
	var click_def: Dictionary = card_def.get("click_action", {}) as Dictionary
	if click_def.is_empty():
		return -1

	var score := 0
	# One‑shot abilities (e.g., Humanoid Resources) – use if we have the clicks
	if click_def.get("one_shot", false):
		# Very valuable – they often give a net gain
		score += 10
		return score

	# For recurring‑credit assets (e.g., Regolith Mining License)
	var hosted_credits: int = card.get_counter("credits")
	if hosted_credits > 0:
		score += hosted_credits * 2   # each credit is worth 2 points
	# For agenda counters (Dividends)
	if card.card_record != null and card.card_record.is_agenda():
		var agenda_counters: int = card.get_counter("agenda")
		if agenda_counters > 0:
			score += agenda_counters * 3
	# If the card is in the runner’s score area but has a click action for Corp
	if ctx.runner_score_area_cards.has(card):
		score += 5   # Corp can use stolen agendas, very valuable
	return score


func _best_click_action_card(ctx: GameContext) -> InstalledCard:
	var best_card: InstalledCard = null
	var best_score: int = -1

	# Check Corp installed cards
	for server in ctx.servers.values():
		var s: Server = server as Server
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if not c.is_rezzed or c.card_record == null:
				continue
			var score = _score_click_action(c, ctx)
			if score > best_score and ctx.corp_clicks >= 1:
				best_score = score
				best_card = c

	# Check Corp scored agendas
	for card in ctx.corp_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		var score = _score_click_action(c, ctx)
		if score > best_score and ctx.corp_clicks >= 1:
			best_score = score
			best_card = c

	# Check Runner’s score area (for cards like Next Big Thing)
	for card in ctx.runner_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		var card_def = _ability_registry._abilities.get(c.card_id, {}) as Dictionary
		var click_def = card_def.get("click_action", {}) as Dictionary
		if click_def.is_empty() or click_def.get("subject", "") != "corp":
			continue
		var score = _score_click_action(c, ctx)
		if score > best_score and ctx.corp_clicks >= 1:
			best_score = score
			best_card = c

	return best_card if best_score > 0 else null


# NEW: Evaluate operation condition before playing.
func _operation_passes_condition(record: CardRecord, ctx: GameContext) -> bool:
	var on_play_def: Dictionary = _ability_registry.get_on_play(record.id)
	if on_play_def.is_empty():
		return true   # no condition = always allowed
	if not on_play_def.has("condition"):
		return true
	return _interpreter._evaluate_condition(on_play_def["condition"] as Dictionary, ctx)


func _find_best_operation(ctx: GameContext) -> CardRecord:
	var best_op: CardRecord = null
	var best_val: int = -1
	for entry in ctx.corp_hand:
		var r: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if r == null or r.card_type != "operation":
			continue
		if ctx.corp_credits < max(0, r.cost):
			continue
		# Skip operations whose condition fails
		if not _operation_passes_condition(r, ctx):
			continue
		var val: int = _operation_value(r, ctx)   # new scoring
		if val > best_val:
			best_val = val
			best_op = r
	# Don’t play zero‑value ops if we have other good moves – but we are already in the
	# fallback part of priority list, so play if any passes condition.
	if best_op != null and best_val >= 0:
		return best_op
	return null


func _operation_value(record: CardRecord, ctx: GameContext) -> int:
	# Economy value (net credits gained)
	const ECONOMY_MAP = {
		"government_subsidy": 11,   # gain 14 cost 3 -> net +11
		"hedge_fund":          4,   # gain 9 cost 5 -> net +4
		"predictive_planogram": 3,  # gain 3 (corp path)
		"hansei_review":        2,  # draw value approx 2cr
	}
	var base = ECONOMY_MAP.get(record.id, 0)
	# Additional heuristics: if we are below threshold, value credits more
	if ctx.corp_credits < ECONOMY_THRESHOLD and base > 0:
		base += 3
	# If we are at ceiling, devalue economy ops (avoid over‑hoarding)
	if ctx.corp_credits > ECONOMY_CEILING and base > 0:
		base = max(0, base - 5)
	return base


# NEW: Helper to count ice on a server.
func _server_ice_count(ctx: GameContext, server_id: String) -> int:
	var server: Server = ctx.get_server(server_id)
	return server.ice_count() if server else 0


# NEW: Avoid rezzing trap assets that are better left face‑down.
func _is_safe_to_rez_asset(card: InstalledCard) -> bool:
	# Snare!, Shock!, etc. – cards that damage on access
	var unsafe_ids = ["snare", "shock"]
	if card.card_id in unsafe_ids:
		return false
	return true


# NEW: Optional abilities – not auto‑accept.
func choose_optional_ability(prompt: String, ctx: GameContext) -> bool:
	# Heuristic: if the ability trashes the card, only accept if the card is low value
	# or if the Corp is desperate for a short‑term gain.
	if "trash" in prompt.to_lower():
		# For now, decline trashing abilities unless the Corp is below 5 credits
		return ctx.corp_credits < 5
	# Otherwise, accept if the prompt mentions credits/draw and we need them
	if "credit" in prompt.to_lower() and ctx.corp_credits < ECONOMY_THRESHOLD:
		return true
	if "draw" in prompt.to_lower() and ctx.corp_hand.size() < MIN_HAND_SIZE:
		return true
	# Default false – be more conservative
	return false



# ── State-aware override helpers ──────────────────────────────────────────────

# Returns true if the runner's rig covers all three standard ice subtypes, or
# contains an AI breaker (which breaks any ice type regardless of subtype).
func _runner_has_full_rig(ctx: GameContext) -> bool:
	var has_fracter := false
	var has_killer  := false
	var has_decoder := false
	for ic in ctx.runner_rig:
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null:
			continue
		if c.card_record.has_subtype("ai"):
			return true   # AI breaker covers everything
		if c.card_record.has_subtype("fracter"):
			has_fracter = true
		if c.card_record.has_subtype("killer"):
			has_killer = true
		if c.card_record.has_subtype("decoder"):
			has_decoder = true
	return has_fracter and has_killer and has_decoder


# Returns true if an agenda that is ≤1 advance from scoring sits in a protected
# (iced) remote.  Used by _economy_threshold to lower the credit floor.
func _is_scoring_window_active(ctx: GameContext) -> bool:
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote() or not s.has_ice():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null or not c.card_record.is_agenda():
				continue
			var needed: int = c.card_record.advancement_requirement - c.get_counter("advancement")
			if needed <= 1:
				return true
	return false


# Returns the credit threshold below which the Corp should prioritise gaining
# credits.  Adapts to the current game state rather than using a fixed value.
func _economy_threshold(ctx: GameContext) -> int:
	if _is_scoring_window_active(ctx):
		return 4   # accept a thin credit pool to push an almost-scored agenda
	if _runner_has_full_rig(ctx):
		return 8   # need reserve credits to rez ice when the runner runs
	return ECONOMY_THRESHOLD


# Override A — Kill window.
# Play a damage operation immediately if the runner's hand is small enough
# that the damage could be decisive (≤2 cards remaining).
func _kill_window_check(ctx: GameContext) -> GameAction:
	if ctx.runner_hand.size() > 2:
		return null
	for entry in ctx.corp_hand:
		var r: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if r == null or r.card_type != "operation":
			continue
		if ctx.corp_credits < max(0, r.cost):
			continue
		if r.id in DAMAGE_OPERATION_IDS and _operation_passes_condition(r, ctx):
			return GameAction.play_operation(r)
	return null


# Override B — Scoring window.
# Advance an agenda that is exactly one click from scoring if it sits behind
# ice and the runner cannot afford to break into that server this turn.
# Estimate break cost per ice: 3cr with a full rig, 4cr with a partial rig,
# effectively infinite with no rig at all.
func _scoring_window_check(ctx: GameContext) -> GameAction:
	if ctx.corp_credits < 1:
		return null
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote() or not s.has_ice():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null or not c.card_record.is_agenda():
				continue
			if c.meets_advancement_requirement():
				continue   # step 1 already handles ready-to-score agendas
			var needed: int = c.card_record.advancement_requirement - c.get_counter("advancement")
			if needed != 1:
				continue
			var est_break_cost: int
			if ctx.runner_rig.is_empty():
				est_break_cost = 99   # no rig — runner cannot break in at all
			elif _runner_has_full_rig(ctx):
				est_break_cost = s.ice_count() * 3
			else:
				est_break_cost = s.ice_count() * 4
			if ctx.runner_credits < est_break_cost:
				return GameAction.advance(c.card_id)
	return null


# Override A2 — Trap window.
# Advance an installed trap card when one more counter reaches kill range.
# Fires in the urgent state-aware block so kill set-up takes priority over
# routine setup plays.
func _trap_window_check(ctx: GameContext) -> GameAction:
	if ctx.runner_hand.size() > 3 or ctx.corp_credits < 1:
		return null
	var runner_grip: int = ctx.runner_hand.size()
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote() or not s.has_ice():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null or c.card_record.is_agenda() or not c.can_be_advanced():
				continue
			# Advance if the next counter would reach or exceed kill threshold.
			if c.get_counter("advancement") + 1 >= runner_grip:
				return GameAction.advance(c.card_id)
	return null


# Returns the best installed advanceable non-agenda card for proactive advancement.
# Prefers protected (iced) remotes; falls back to any remote.
func _find_advanceable_non_agenda(ctx: GameContext) -> InstalledCard:
	var fallback: InstalledCard = null
	for server in ctx.servers.values():
		var s: Server = server as Server
		if not s.is_remote():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_record == null or c.card_record.is_agenda() or not c.can_be_advanced():
				continue
			if s.has_ice():
				return c        # protected server — take it immediately
			if fallback == null:
				fallback = c    # keep as fallback
	return fallback


# Override C — Runner pressure.
# When the runner has a complete rig every server is threatened.  Install ice
# on the most exposed server before spending clicks on setup or economy.
func _runner_pressure_check(ctx: GameContext) -> GameAction:
	if not _runner_has_full_rig(ctx):
		return null
	var ice := _find_ice_in_hand(ctx)
	if ice == null:
		return null
	# Protect unprotected centrals first; install cost = existing ice count.
	if not _server_has_ice(ctx, "hq"):
		return GameAction.install(ice, "hq", "ice")
	if not _server_has_ice(ctx, "rd"):
		return GameAction.install(ice, "rd", "ice")
	# Then agenda remotes with no ice protection.
	var vuln := _find_agenda_remote_needing_ice(ctx)
	if vuln != null and ctx.corp_credits >= vuln.ice_count():
		return GameAction.install(ice, vuln.server_id, "ice")
	return null


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


func _find_upgrade_in_hand(ctx: GameContext) -> CardRecord:
	for entry in ctx.corp_hand:
		var e: Dictionary = entry as Dictionary
		var r: CardRecord = e.get("card_record", null) as CardRecord
		if r != null and r.card_type == "upgrade":
			return r
	return null


# Returns the server that would benefit most from having an upgrade installed.
# Only returns remote servers — installing upgrades in HQ or R&D causes
# misplaced cards (e.g. Malapert Data Vault in HQ).
func _find_best_upgrade_server(ctx: GameContext) -> Server:
	# 1. Iced remote with an agenda — directly protects the scoring server.
	for server in ctx.servers.values():
		var s: Server = server as Server
		if s == null or not s.is_remote() or not s.has_ice():
			continue
		var ic: InstalledCard = s.get_agenda_or_asset()
		if ic != null and ic.card_record != null and ic.card_record.is_agenda():
			return s
	# 2. Any remote with an agenda (even without ice).
	for server in ctx.servers.values():
		var s: Server = server as Server
		if s == null or not s.is_remote():
			continue
		var ic: InstalledCard = s.get_agenda_or_asset()
		if ic != null and ic.card_record != null and ic.card_record.is_agenda():
			return s
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


func choose_target(candidates: Array, _context: Dictionary) -> Variant:
	# Generic target selection — pick the first available candidate.
	return candidates[0] if not candidates.is_empty() else null


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
