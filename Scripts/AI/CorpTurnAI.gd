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

# Operations that can deal direct damage.  Kept for legacy _kill_window_check
# reference; active kill detection is now handled by KillWindowPlanner.
const DAMAGE_OPERATION_IDS := ["neurospike", "measured_response", "punitive_counterstrike", "boom", "scorched_earth"]

var _run_ai: CorpRunAI
var _ability_registry: AbilityRegistry
var _interpreter: AbilityInterpreter   # needed for condition evaluation

# Whole-turn beam search (beam_width=3 for the heuristic tier).
# Uses a separate evaluator so subclass _evaluator fields are not shadowed.
var _base_evaluator: CorpStateEvaluator
var _base_planner:   CorpTurnPlanner


func _init(ability_registry: AbilityRegistry) -> void:
	_run_ai           = CorpRunAI.new(ability_registry)
	_ability_registry = ability_registry
	_interpreter      = AbilityInterpreter.new()
	_base_evaluator   = CorpStateEvaluator.new()
	_base_planner     = CorpTurnPlanner.new(_base_evaluator)
	_base_planner.beam_width = 3


# ── Turn-time interface ───────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
	# 0a. Petty Cash from Archives (first action only — not in snapshot domain).
	if not ctx.corp_finished_an_action_this_turn:
		for cr in ctx.corp_discard:
			var pc_record: CardRecord = cr as CardRecord
			if pc_record != null and pc_record.id == "petty_cash":
				return GameAction.play_from_archives("petty_cash")

	# Hard override: kill window.
	var kill_action: GameAction = KillWindowPlanner.first_action(ctx)
	if kill_action != null:
		return kill_action

	# Hard override: scoring line.
	var scoring_action: GameAction = FastAdvancePlanner.first_action(ctx)
	if scoring_action != null:
		return scoring_action

	# Whole-turn beam search at beam_width=3.
	var snap:   Dictionary = _base_evaluator.snapshot(ctx)
	var action: GameAction = _resolve_sim_action(
		_base_planner.plan_first_action(snap, "rd", ctx), ctx)
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

	# 0b2. Corp identity click action (e.g. Synapse Global: remove tag → 2cr)
	var identity_click := _get_identity_click_action(ctx)
	if identity_click != null:
		return identity_click

	# 0c. Kill window — checked before scoring so a lethal combo is never
	# delayed by agenda advancement.  KillWindowPlanner covers:
	#   • Neurospike chain (Corp scored this turn)
	#   • Measured Response (threat >= 4, runner ran last turn, runner broke)
	#   • Score-then-Spike combo (ready agenda + enough Neurospikes)
	var kill_action: GameAction = KillWindowPlanner.first_action(ctx)
	if kill_action != null:
		return kill_action

	# 1. Score a ready agenda
	var ready := _find_ready_agenda(ctx)
	if ready != null:
		return GameAction.advance(ready.card_id)

	# 1.5. Multi-click scoring line ─────────────────────────────────────────────
	# If we can finish scoring an installed agenda THIS TURN using remaining
	# clicks, commit to it now rather than deferring to economic or defensive
	# actions.  FastAdvancePlanner checks all installed agendas and returns the
	# first action of the sequence (could be an operation or an advance).
	var scoring_action: GameAction = FastAdvancePlanner.first_action(ctx)
	if scoring_action != null:
		return scoring_action

	# ── State-aware overrides ──────────────────────────────────────────────────
	# (Kill window handled above at 0c via KillWindowPlanner.)

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

	# 12.6. §10.5.3 — Trash a runner resource while runner is tagged.
	# Only fires when runner has a dangerous or high-value resource installed.
	if ctx.runner_is_tagged() and ctx.corp_credits >= 2 and ctx.corp_clicks >= 1:
		var resource_target := _find_best_runner_resource_to_trash(ctx)
		if resource_target != null:
			return GameAction.trash_runner_resource(
				resource_target.runtime_instance_id, resource_target.card_id)

	# 12.7. §10.1.2 — Purge virus counters when viral pressure crosses threshold.
	# Costs 3 clicks — only fires when the threat justifies the investment.
	if ctx.corp_clicks >= 3 and _should_purge_viruses(ctx):
		return GameAction.purge_virus()

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

# Boost a trace just enough to guarantee success against the Runner's maximum
# possible total (link + all available credits), if affordable; otherwise
# spend nothing. Used by Winchester / Scapenet traces.
func choose_trace_boost(base_strength: int, ctx: GameContext) -> int:
	var runner_max: int = ctx.runner_total_link() + ctx.runner_credits
	var needed: int = (runner_max + 1) - base_strength
	if needed <= 0:
		return 0
	return min(needed, ctx.corp_credits)

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

	# Multi-click abilities: ensure the Corp has enough clicks to pay the total cost.
	var extra_clicks: int = click_def.get("additional_cost_clicks", 0)
	if ctx.corp_clicks < 1 + extra_clicks:
		return -1  # can't afford multi-click cost this turn

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
	# Tag-cost click actions in runner’s score area (e.g. Oracle Thinktank: recover agenda).
	# These remove a stolen agenda from the runner’s area — very valuable.
	if ctx.runner_score_area_cards.has(card):
		var card_def2: Dictionary = _ability_registry._abilities.get(card.card_id, {}) as Dictionary
		var click_def2: Dictionary = card_def2.get("click_action", {}) as Dictionary
		var tag_cost: int = click_def2.get("tag_cost", 0)
		if tag_cost > 0 and ctx.runner_tags >= tag_cost:
			# Recovering a stolen agenda: value = agenda’s AP × 5 (removes from runner score)
			var ap: int = card.card_record.agenda_points if card.card_record != null else 1
			return ap * 5
		# Other runner-score-area Corp actions (Next Big Thing, etc.)
		score += 5
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

	# Check Runner’s score area — Corp abilities on stolen agendas
	# (e.g. Next Big Thing, Oracle Thinktank).
	# Abilities may use _owner OR subject to mark Corp-side actions.
	for card in ctx.runner_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		if c == null or c.card_record == null:
			continue
		var card_def: Dictionary = _ability_registry._abilities.get(c.card_id, {}) as Dictionary
		var click_def: Dictionary = card_def.get("click_action", {}) as Dictionary
		if click_def.is_empty():
			continue
		var owner: String = click_def.get("_owner", click_def.get("subject", ""))
		if owner != "corp":
			continue
		# Check tag cost (e.g. Oracle Thinktank needs 1 runner tag to fire)
		var tag_cost: int = click_def.get("tag_cost", 0)
		if tag_cost > 0 and ctx.runner_tags < tag_cost:
			continue
		var score := _score_click_action(c, ctx)
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
	# ── Bigger Picture: drain 5cr per tag removed (runner loses, Corp gains) ────
	# Condition: runner is tagged (checked separately by _operation_passes_condition).
	if record.id == "bigger_picture":
		if ctx.runner_tags <= 0:
			return -1   # condition won't pass
		# Drain value: each tag we remove = runner loses 5cr + Corp gains 5cr.
		# The AI defaults to mode 0 (drain), so value = tags × net credit swing.
		var drain_tags: int = ctx.runner_tags   # drain all of them
		var runner_can_afford: int = ctx.runner_credits   # capped by runner wealth
		# Each tag removed: runner loses 5cr (capped at 0) and Corp gains 5cr.
		var drained: int = mini(drain_tags * 5, runner_can_afford)
		return (drained + drain_tags * 3) / 5   # rough net value score

	# ── Retribution: trash a runner program or hardware (condition: tagged) ────
	if record.id == "retribution":
		if ctx.runner_tags <= 0:
			return -1   # condition won't pass
		# Value scales with rig quality — trashing a breaker is game-changing.
		var has_breaker: bool = false
		for rig_ic in ctx.runner_rig:
			var rc: InstalledCard = rig_ic as InstalledCard
			if rc == null or rc.card_record == null:
				continue
			if rc.card_record.has_subtype("fracter") or \
			   rc.card_record.has_subtype("killer")  or \
			   rc.card_record.has_subtype("decoder") or \
			   rc.card_record.has_subtype("ai"):
				has_breaker = true
				break
		if not has_breaker and ctx.runner_rig.is_empty():
			return 1   # nothing worth trashing
		return 10 if has_breaker else 5   # breaker trash is very high value

	# ── IP Enforcement: recover highest-AP stolen agenda for X tags + X credits ─
	# Value = AP recovered × 6 (large: restores corp score AND strips runner score).
	if record.id == "ip_enforcement":
		if ctx.runner_tags <= 0 or ctx.runner_score_area_cards.is_empty():
			return -1   # condition won't pass; skip
		var max_ap: int = 0
		for scored_ic in ctx.runner_score_area_cards:
			var ic: InstalledCard = scored_ic as InstalledCard
			if ic == null or ic.card_record == null:
				continue
			var ap: int = ic.card_record.agenda_points
			if ap <= ctx.runner_tags and ap <= ctx.corp_credits and ap > max_ap:
				max_ap = ap
		return -1 if max_ap == 0 else max_ap * 6

	# ── Midnight Sun operations ────────────────────────────────────────────────

	# Big Deal: highest value when Corp has an installed card with 3+ adv counters
	# (possibly scoreable this click). RFGs, so only play when timing is right.
	if record.id == "big_deal":
		var best_adv: int = 0
		for bd_srv_any in ctx.servers.values():
			var bd_srv: Server = bd_srv_any as Server
			if bd_srv == null:
				continue
			for bd_c_any in bd_srv.root:
				var bd_c: InstalledCard = bd_c_any as InstalledCard
				if bd_c != null and bd_c.card_record != null and bd_c.card_record.is_agenda():
					best_adv = maxi(best_adv, bd_c.get_counter("advancement"))
		# Big Deal places 4 counters, so a card at req-4 or fewer can be scored.
		# Value is very high when a close score is available.
		if best_adv >= 0:
			return 15 + best_adv * 2   # high base + bonus for pre-existing counters

	# Mitosis: valuable when HQ has ≥2 installable cards and Corp has clicks to spare.
	# Costs 2 clicks total. Skip if hand is tiny or credits are low.
	if record.id == "mitosis":
		var installable_count: int = 0
		for mt_e in ctx.corp_hand:
			var mt_r: CardRecord = (mt_e as Dictionary).get("card_record", null) as CardRecord
			if mt_r != null and (mt_r.is_agenda() or mt_r.is_ice() or mt_r.card_type == "asset"):
				installable_count += 1
		if installable_count < 2 or ctx.corp_clicks < 2:
			return -1
		return 8 if installable_count >= 2 else 4

	# Mutually Assured Destruction: costs 3 clicks. High value if runner rig is large
	# and Corp has rezzed cards to spare (mass-tag + trash for kill setup).
	if record.id == "mutually_assured_destruction":
		if ctx.corp_clicks < 3:
			return -1
		# Only worth it if runner has enough tags to exploit OR rig is large enough to punish
		var runner_rig_size: int = ctx.runner_rig.size()
		if runner_rig_size < 2:
			return -1
		return 6 + runner_rig_size * 1   # scales with runner board size

	# Extract: gain 6cr + optionally gain 3cr by trashing a low-value installed card.
	# Net value roughly similar to government_subsidy in credit-tight games.
	if record.id == "extract":
		var base_extract: int = 5   # gaining 6cr is always good
		# Bonus if Corp has a spent campaign (empty) or low-value asset to trash for +9cr total
		for ex_srv_any in ctx.servers.values():
			var ex_srv: Server = ex_srv_any as Server
			if ex_srv == null:
				continue
			for ex_c_any in ex_srv.root:
				var ex_c: InstalledCard = ex_c_any as InstalledCard
				if ex_c != null and not ex_c.is_rezzed:
					base_extract += 3   # can trash an unrezzed card for 9cr total
					break
		return base_extract

	# Moon Pool: activating trashes HQ cards and recovers Archives agendas.
	# Only worth using if facedown Archives has content to recover.
	# Evaluated here as a click action (it's a Corp click_action on the card,
	# not a hand operation, but included for completeness).

	# Trust Operation: play when Runner is tagged + Corp has Archives content.
	if record.id == "trust_operation":
		if ctx.runner_tags <= 0:
			return -1
		var has_runner_resource: bool = false
		for tr_rig in ctx.runner_rig:
			var tr_ic: InstalledCard = tr_rig as InstalledCard
			if tr_ic != null and tr_ic.card_record != null \
					and tr_ic.card_record.card_type == "resource":
				has_runner_resource = true
				break
		if not has_runner_resource:
			return -1
		return 9   # trash key runner resource + free install from Archives

	# Backroom Machinations: gives 1 agenda point at cost of 1 runner tag.
	# Value scales steeply near win threshold.
	if record.id == "backroom_machinations":
		if ctx.runner_tags <= 0:
			return -1
		var pts_to_win: int = ctx.agenda_points_to_win - ctx.corp_score
		if pts_to_win <= 1:
			return 30   # win condition!
		if pts_to_win == 2:
			return 15   # one more agenda closes it
		return 6   # still a free agenda point

	# Artificial Cryptocrash: usually played on score (on_score effect).
	# As a standalone op it has no direct effect; return 0.

	# ── Economy value (net credits gained) ────────────────────────────────────
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
	var p := prompt.to_lower()

	# Midnight Sun card-specific heuristics ────────────────────────────────────

	# Ob Superheavy: always accept the search trigger (free install is always good).
	if "ob superheavy" in p or "searches r&d" in p:
		return true

	# Purge virus counters: accept when runner has significant virus pressure.
	if "purge" in p:
		var virus_count := 0
		for rv_card in ctx.runner_rig:
			var rv_ic: InstalledCard = rv_card as InstalledCard
			if rv_ic != null:
				virus_count += rv_ic.get_counter("virus")
		return virus_count >= 3   # purge when meaningful virus threat exists

	# Stavka: trash a low-value installed card for +5 strength — always worth it
	# if Corp has a low-value rezzed card and is facing a strong icebreaker.
	if "stavka" in p:
		return ctx.runner_rig.size() >= 2   # runner has substantial rig

	# Big Deal: always accept placing counters / scoring (called automatically).
	if "big deal" in p:
		return true

	# Regenesis: accept scoring Archives agenda when no other score is available.
	if "regenesis" in p:
		return ctx.corp_score < ctx.agenda_points_to_win - 1

	# Mitosis: always install (the AI chose to play Mitosis, so commit to it).
	if "mitosis" in p:
		return true

	# Heuristic: if the ability trashes the card, only accept if the card is low value
	# or if the Corp is desperate for a short‑term gain.
	if "trash" in p:
		return ctx.corp_credits < 5
	# Otherwise, accept if the prompt mentions credits/draw and we need them
	if "credit" in p and ctx.corp_credits < ECONOMY_THRESHOLD:
		return true
	if "draw" in p and ctx.corp_hand.size() < MIN_HAND_SIZE:
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


# §10.5.3 — Find the most valuable runner resource to trash while runner is tagged.
# Returns the InstalledCard to target, or null if no resources are installed or
# the runner has no tags.
func _find_best_runner_resource_to_trash(ctx: GameContext) -> InstalledCard:
	if not ctx.runner_is_tagged():
		return null
	var best: InstalledCard = null
	var best_cost: int = -1
	for r in ctx.runner_rig:
		var ic: InstalledCard = r as InstalledCard
		if ic == null or ic.card_record == null:
			continue
		if ic.card_record.card_type != "resource":
			continue
		# Prefer higher-cost resources (proxy for value)
		var c: int = max(0, ic.card_record.cost)
		if c > best_cost:
			best_cost = c
			best = ic
	return best


# §10.1.2 — Decide whether to spend 3 clicks to purge virus counters.
# Threshold: purge when total virus counters across the runner's rig exceed 4,
# or when any single card has ≥ 3 counters (e.g. Fermenter, Conduit).
func _should_purge_viruses(ctx: GameContext) -> bool:
	var total := 0
	for r in ctx.runner_rig:
		var ic: InstalledCard = r as InstalledCard
		if ic == null or ic.card_record == null:
			continue
		if not ic.card_record.has_subtype("virus"):
			continue
		var v: int = ic.get_counter("virus")
		if v >= 3:
			return true   # single dangerous card — purge immediately
		total += v
	return total > 4


# Returns a GameAction for the Corp identity's click action if it is available
# and passes its condition, or null otherwise.
# Covers e.g. Synapse Global (click + remove tag → 2cr) and Topan Ormas Leader.
# The action uses instance_id "identity_corp" which TurnManager routes correctly.
func _get_identity_click_action(ctx: GameContext) -> GameAction:
	if ctx.corp_identity == null:
		return null
	var id_def: Dictionary  = _ability_registry._abilities.get(ctx.corp_identity.id, {}) as Dictionary
	var ca_def: Dictionary  = id_def.get("identity_click_action",
		id_def.get("click_action", {})) as Dictionary
	if ca_def.is_empty():
		return null
	# Check condition if present
	var condition: Dictionary = ca_def.get("condition", {}) as Dictionary
	if not condition.is_empty():
		if not _interpreter._evaluate_condition(condition, ctx):
			return null
	# Check once-per-turn guard
	var opt_key: String = ca_def.get("once_per_turn_key", "")
	if opt_key != "":
		var full_key := "identity_corp:%s" % opt_key
		if ctx.once_per_turn_triggered.get(full_key, false):
			return null
	# Build the action using the sentinel instance_id TurnManager expects.
	return GameAction.use_installed_card("identity_corp", ctx.corp_identity.id)


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
	# Also check runner's score area — Corp can use some stolen agendas (e.g. Next Big Thing,
	# Oracle Thinktank).  Accept _owner OR subject == "corp".
	for card in ctx.runner_score_area_cards:
		var c: InstalledCard = card as InstalledCard
		if c == null or c.card_record == null:
			continue
		var card_def: Dictionary = _ability_registry._abilities.get(c.card_id, {}) as Dictionary
		var ca_def: Dictionary   = card_def.get("click_action", {}) as Dictionary
		if ca_def.is_empty():
			continue
		var owner: String = ca_def.get("_owner", ca_def.get("subject", ""))
		if owner != "corp":
			continue
		# Tag-cost actions (e.g. Oracle Thinktank: remove 1 tag → shuffle to R&D)
		var tag_cost: int = ca_def.get("tag_cost", 0)
		if tag_cost > 0:
			if ctx.runner_tags >= tag_cost:
				return c
			continue   # can't afford tag cost
		# Agenda-counter actions (e.g. Next Big Thing, Dividends)
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


func choose_card_name(ctx: GameContext) -> String:
	# Complete Image: pick the card title most duplicated in the runner's visible discard.
	# This maximises the chance of chaining repeat-damage on the named card.
	var counts: Dictionary = {}
	for e in ctx.runner_discard:
		var cr: CardRecord = e as CardRecord
		if cr != null and cr.title != "":
			counts[cr.title] = counts.get(cr.title, 0) + 1
	var best_name := ""
	var best_count := 0
	for title in counts:
		if counts[title] > best_count:
			best_count = counts[title]
			best_name = title
	# Fallback: most common runner card in game — any name triggers 1 net damage.
	return best_name if best_name != "" else "Sure Gamble"


func choose_runner_card_type(types: Array, _ctx: GameContext) -> String:
	# Events are ~2× more likely than resources in a typical runner grip.
	# 2/3 event, 1/3 resource — used by Focus Group, Touch-Ups, and similar.
	var prefer_event: bool = randf() < 2.0 / 3.0
	if prefer_event and "event" in types:
		return "event"
	if "resource" in types:
		return "resource"
	if "event" in types:
		return "event"
	if not types.is_empty():
		return types[0] as String
	return "event"


func choose_installed_card(candidates: Array, _ctx: GameContext) -> InstalledCard:
	# Called when placing advancement counters on an installed card (Seamless Launch,
	# Touch-Ups, etc.).  Prefer the agenda closest to its scoring threshold; fall
	# back to the first advanceable non-agenda (traps), then the first candidate.
	if candidates.is_empty():
		return null
	var best_agenda: InstalledCard = null
	var best_gap: int = 999
	var first_non_agenda: InstalledCard = null
	for cand_any in candidates:
		var cand: InstalledCard = cand_any as InstalledCard
		if cand == null or cand.card_record == null:
			continue
		if cand.card_record.is_agenda():
			var req: int = cand.card_record.advancement_requirement
			var cur: int = cand.get_counter("advancement")
			var gap: int = req - cur
			if gap > 0 and gap < best_gap:
				best_gap  = gap
				best_agenda = cand
		elif first_non_agenda == null and not cand.card_record.is_ice():
			first_non_agenda = cand
	if best_agenda != null:
		return best_agenda
	if first_non_agenda != null:
		return first_non_agenda
	return candidates[0] as InstalledCard


func choose_target(candidates: Array, context: Dictionary) -> Variant:
	if candidates.is_empty():
		return null
	# MS-L007: for advancement counter placement (Pravdivost, Vasilisa, etc.),
	# prefer the agenda closest to its scoring threshold.
	var reason: String = (context as Dictionary).get("reason", "") if context is Dictionary else ""
	if reason in ["advance_optional", "advance_required", "target", "focus_group_advance"]:
		var best: InstalledCard = null
		var best_gap: int = 999
		for cand_any in candidates:
			var cand: InstalledCard = cand_any as InstalledCard
			if cand == null or cand.card_record == null:
				continue
			if cand.card_record.is_agenda():
				var req: int  = cand.card_record.advancement_requirement
				var cur: int  = cand.get_counter("advancement")
				var gap: int  = req - cur
				if gap > 0 and gap < best_gap:
					best_gap = gap
					best = cand
		if best != null:
			return best
	# Generic fallback: pick the first available candidate.
	return candidates[0]


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


# Translates snap-level sentinel card IDs to real installed-card IDs before the
# action is handed to the game engine.
#
# "__sim_trap__"   — represents "advance a non-agenda advanceable card in a
#                    protected remote" in the MCTS/beam snap.  The engine cannot
#                    find a literal card with that ID, so we resolve it to the
#                    actual card's card_id here.
func _resolve_sim_action(action: GameAction, ctx: GameContext) -> GameAction:
	if action == null or action.type != "advance":
		return action
	var card_id: String = action.params.get("card_id", "") as String
	if card_id != "__sim_trap__":
		return action
	# Walk protected remotes to find the actual advanceable non-agenda.
	for srv_key in ctx.servers:
		var srv: Server = ctx.servers[srv_key] as Server
		if srv == null or not srv.is_remote() or srv.ice.size() == 0:
			continue
		for root_c in srv.root:
			var ic: InstalledCard = root_c as InstalledCard
			if ic != null and ic.card_record != null \
					and not ic.card_record.is_agenda() and ic.can_be_advanced():
				return GameAction.advance(ic.card_id)
	return GameAction.gain_credits()
