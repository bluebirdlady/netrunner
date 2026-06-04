class_name TurnManager
extends RefCounted

# ── TurnManager ───────────────────────────────────────────────────────────────
# Drives the outer game loop: Corp turn, then Runner turn, repeat.
# Validates and executes GameActions produced by decision makers.
# Fires signals at each meaningful moment for the UI to consume.
# Checks win conditions after each action.
#
# Usage:
#   var tm := TurnManager.new(ctx, ability_registry)
#   tm.action_executed.connect(_on_action)
#   await tm.run_game()

const CORP_CLICKS_PER_TURN:   int = 3
const RUNNER_CLICKS_PER_TURN: int = 4
const MAX_HAND_SIZE:          int = 5
# Seconds to pause after each visible Corp action so the human player can read it.
const CORP_ACTION_PACE_SECS: float = 0.55

# Starter deck identities play to 6 agenda points; all others play to 7
const STARTER_CORP_ID:   String = "the_syndicate_profit_over_principle"
const STARTER_RUNNER_ID: String = "the_catalyst_convention_breaker"

var agenda_points_to_win: int = 7
# Prevents the game_over signal from firing more than once, even if ctx.game_over
# was set directly by a subsystem (e.g. RunStateMachine._steal_agenda) before
# _check_win_conditions() runs.
var _game_over_signaled: bool = false

var ctx:              GameContext
var ability_registry: AbilityRegistry
var interpreter:      AbilityInterpreter

# ── Signals ───────────────────────────────────────────────────────────────────
signal turn_started(player: String, turn_number: int)
signal action_executed(player: String, action: GameAction)
signal action_rejected(player: String, action: GameAction, reason: String)
signal game_over(winner: String, reason: String)
signal credits_changed(player: String, amount: int)
signal hand_changed(player: String)
signal card_installed(card_record: CardRecord, server_id: String)
signal card_advanced(card_id: String, counter_count: int)
# Fired true just before Corp decision maker runs (MCTS may take 1-2 s),
# fired false immediately after the action is chosen.
signal corp_thinking(is_thinking: bool)


# ── Construction ──────────────────────────────────────────────────────────────

func _init(game_ctx: GameContext, ab_registry: AbilityRegistry) -> void:
	ctx              = game_ctx
	ability_registry = ab_registry
	interpreter      = AbilityInterpreter.new()


# ── Main loop ─────────────────────────────────────────────────────────────────

func run_game(max_turns: int = 0) -> void:
	# Set win threshold: starter identities play to 6, all others to 7
	var corp_id:   String = ctx.corp_identity.id   if ctx.corp_identity   != null else ""
	var runner_id: String = ctx.runner_identity.id if ctx.runner_identity != null else ""
	if corp_id == STARTER_CORP_ID and runner_id == STARTER_RUNNER_ID:
		agenda_points_to_win = 6
		ctx.agenda_points_to_win = 6
		ctx.send_log("Starter decks detected — playing to 6 agenda points.")
	else:
		agenda_points_to_win = 7
		ctx.agenda_points_to_win = 7

	# Register identity ability listeners using synthetic instance IDs
	_register_identity_listeners("identity_runner", runner_id)
	_register_identity_listeners("identity_corp",   corp_id)

	# Expose identity re-registration so AbilityInterpreter flip effects can swap faces.
	# The callable unregisters all current listeners for the given instance_id, then
	# registers the new face's listeners from abilities.json.
	ctx.set_meta("reregister_identity", func(instance_id: String, new_card_id: String) -> void:
		ctx.unregister_all_card_effects(instance_id)
		_register_identity_listeners(instance_id, new_card_id)
	)

	var turns_run: int = 0
	while not ctx.game_over:
		if max_turns > 0 and turns_run >= max_turns:
			break
		# Yield two frames before the Corp turn so Godot renders the runner's final
		# action state before MCTS starts computing (fix for "last action appears late").
		if not ctx.simulation_mode:
			var _st := Engine.get_main_loop() as SceneTree
			if _st != null:
				await _st.process_frame
				await _st.process_frame
		await _corp_turn()
		if ctx.game_over:
			break
		await _runner_turn()
		turns_run += 1


# ── Corp turn ─────────────────────────────────────────────────────────────────

func _corp_turn() -> void:
	ctx.active_player = "corp"
	var corp_penalty: int = ctx.pending_click_penalties.get("corp", 0)
	var corp_bonus: int   = ctx.pending_click_bonuses.get("corp", 0)
	ctx.corp_clicks = max(0, CORP_CLICKS_PER_TURN - corp_penalty) + corp_bonus
	ctx.pending_click_penalties["corp"] = 0
	ctx.pending_click_bonuses["corp"]   = 0
	if corp_bonus > 0:
		ctx.send_log("%s gets +%d click(s) this turn (deferred bonus)." % [ctx.corp_name(), corp_bonus])
	ctx.corp_installed_this_turn = []   # reset for Seamless Launch restriction
	ctx.corp_first_remote_install_triggered_this_turn = false   # reset for A Teia: IP Recovery
	ctx.a_teia_free_installed_instance_ids = []                 # reset for A Teia: IP Recovery
	ctx.corp_gained_advance_credits_this_turn = false   # reset for Built to Last
	ctx.corp_finished_an_action_this_turn     = false   # reset for Petty Cash condition
	ctx.corp_played_operation_this_turn = false          # reset for Nebula Making Stars
	ctx.corp_mandates_played_this_turn  = 0              # reset for Sudden Commandment Threat 3
	ctx.corp_last_scored_agenda_points = 0              # reset for Neurospike
	ctx.corp_agendas_scored_this_turn  = 0              # reset for first-agenda triggers
	ctx.ice_rezzed_this_turn                 = false   # reset for Underdome Irregulars
	ctx.ice_rezzed_this_turn_instance_ids.clear()      # reset for Cloud Eater / Lightning Lab
	ctx.doubles_played_this_turn       = 0              # reset for Synchrocyclotron
	ctx.corp_scored_agenda_not_installed_this_turn = false   # reset for Myōshu
	# Capture whether the runner stole or trashed last runner turn before clearing the flag.
	# Active Policing / Bring Them Home pre-play condition reads this.
	ctx.runner_stole_or_trashed_last_runner_turn = \
		ctx.runner_stole_agenda_this_turn or ctx.runner_trashed_during_breach_this_turn
	ctx.runner_stole_agenda_this_turn  = false          # reset each turn (Hype Machine)
	# Capture whether the runner ran successfully last turn before this turn's reset.
	# Used by Public Trail ("Play only if the Runner made a successful run during their last turn").
	ctx.runner_made_successful_run_last_turn = ctx.runner_made_successful_run_this_turn
	ctx.corp_used_reality_plus_this_turn = false        # reset once-per-turn identity limit
	ctx.once_per_turn_triggered.clear()                # reset per-turn trigger guards
	if corp_penalty > 0:
		ctx.send_log("%s loses %d click(s) this turn (deferred penalty)." % [ctx.corp_name(), corp_penalty])

	# Draw phase: mandatory draw, then start-of-turn events
	_corp_mandatory_draw()
	if not ctx.simulation_mode: emit_signal("turn_started", "corp", ctx.turn_number)
	ctx.send_log("=== %s Turn %d begins. Credits: %d, Clicks: %d ===" % [
		ctx.corp_name(), ctx.turn_number, ctx.corp_credits, ctx.corp_clicks
	])
	# Fire start-of-turn triggers (assets, upgrades, etc.)
	await ctx.notify_event("corp_turn_start", {}, interpreter)

	# Pre-click free actions: Corp may rez assets/upgrades as paid abilities before spending clicks.
	# Handled separately so the click loop only processes click-costing actions.
	if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("get_pre_click_rez_actions"):
		for rez_action in ctx.corp_decision_maker.get_pre_click_rez_actions(ctx):
			await _do_rez_card("corp", rez_action as GameAction)

	# Action phase
	while ctx.corp_clicks > 0 and not ctx.game_over:
		if ctx.corp_decision_maker == null:
			ctx.send_log("No %s decision maker — ending turn." % ctx.corp_name())
			break

		# Signal that the Corp AI is now computing its next action.
		# GameUI uses this to show a "planning" overlay while MCTS runs.
		if not ctx.simulation_mode:
			emit_signal("corp_thinking", true)

		var action: GameAction = await ctx.corp_decision_maker.choose_action(ctx)

		# Thinking is done — dismiss the planning overlay before executing the action.
		if not ctx.simulation_mode:
			emit_signal("corp_thinking", false)
			# Yield one frame so the overlay can begin fading before the action fires.
			var _st := Engine.get_main_loop() as SceneTree
			if _st != null:
				await _st.process_frame

		if action == null:
			ctx.send_log("No action from %s — ending turn." % ctx.corp_name())
			break

		var result := await _execute_action("corp", action)
		if not result["ok"]:
			ctx.send_log("%s action rejected: %s" % [ctx.corp_name(), result["reason"]])
			# Give the AI another chance rather than looping forever
			# If it keeps producing invalid actions something is wrong
			break

		# Brief pause between Corp actions so the human player can read the log
		# and the game doesn't feel like it resolved instantaneously.
		if not ctx.simulation_mode:
			var _st2 := Engine.get_main_loop() as SceneTree
			if _st2 != null:
				await _st2.create_timer(CORP_ACTION_PACE_SECS).timeout

	# Discard phase
	_corp_discard_to_hand_limit()
	if not ctx.game_over:
		await ctx.notify_event("corp_discard_phase_ends", {}, interpreter)


func _corp_mandatory_draw() -> void:
	if ctx.corp_deck.is_empty():
		ctx.send_log("%s deck is empty — %s loses!" % [ctx.corp_name(), ctx.corp_name()])
		_end_game("runner", "Corp could not draw (empty R&D)")
		return
		
	# Pop the clean object directly
	var drawn: CardRecord = ctx.corp_deck.pop_front() as CardRecord
	
	# Package it into the dictionary format your hand structure expects
	ctx.corp_hand.append({"card_id": drawn.id, "card_record": drawn})

	if not ctx.simulation_mode: emit_signal("hand_changed", "corp")
	ctx.send_log("%s draws %s." % [ctx.corp_name(), drawn.title])


func _corp_discard_to_hand_limit() -> void:
	var limit: int = ctx.corp_max_hand_size()
	var did_discard := false
	while ctx.corp_hand.size() > limit and not ctx.game_over:
		var excess: int = ctx.corp_hand.size() - limit
		var chosen_entry: Dictionary = {}

		# Ask the Corp AI / human to choose which card(s) to discard.
		if ctx.corp_decision_maker != null and \
				ctx.corp_decision_maker.has_method("choose_discard_to_hand_limit"):
			var chosen = await ctx.corp_decision_maker.choose_discard_to_hand_limit(
				ctx.corp_hand.duplicate(), excess, ctx)
			if chosen is Array and not (chosen as Array).is_empty():
				# Caller may return multiple cards; process them all this iteration
				for entry in (chosen as Array):
					var e: Dictionary = entry as Dictionary
					var cr: CardRecord = e.get("card_record", null) as CardRecord
					ctx.corp_hand.erase(e)
					if cr != null:
						ctx.corp_discard.append(cr)
						ctx.corp_discard_facedown[cr.title] = true
					ctx.send_log("%s discards %s to hand limit." % [ctx.corp_name(), cr.title if cr else "?"])
					did_discard = true
				if not ctx.simulation_mode: emit_signal("hand_changed", "corp")
				continue   # re-check limit after batch discard
			elif chosen is Dictionary and not (chosen as Dictionary).is_empty():
				chosen_entry = chosen as Dictionary
			# else fall through to fallback

		if chosen_entry.is_empty():
			# Fallback: discard the card with the lowest install/play cost that isn't an agenda
			var best_entry: Dictionary = {}
			var best_score: int = 9999
			for e in ctx.corp_hand:
				var ed: Dictionary = e as Dictionary
				var cr: CardRecord = ed.get("card_record", null) as CardRecord
				if cr == null:
					continue
				# Heuristic: agendas have high discard cost (being in Archives is dangerous)
				var score: int = cr.cost if cr.cost >= 0 else 0
				if cr.card_type == "agenda":
					score += 100   # strong preference to keep agendas
				if score < best_score:
					best_score = score
					best_entry = ed
			if best_entry.is_empty() and not ctx.corp_hand.is_empty():
				best_entry = ctx.corp_hand[ctx.corp_hand.size() - 1] as Dictionary
			chosen_entry = best_entry

		if chosen_entry.is_empty():
			break   # nothing to discard (safety exit)

		var record: CardRecord = chosen_entry.get("card_record", null) as CardRecord
		ctx.corp_hand.erase(chosen_entry)
		if record != null:
			ctx.corp_discard.append(record)
			ctx.corp_discard_facedown[record.title] = true   # hand discards always facedown
		ctx.send_log("%s discards %s to hand limit." % [ctx.corp_name(), record.title if record else "?"])
		did_discard = true
		if not ctx.simulation_mode: emit_signal("hand_changed", "corp")

	ctx.corp_discarded_to_hand_limit_last_turn = did_discard
	if not ctx.simulation_mode: emit_signal("hand_changed", "corp")


func _runner_discard_to_hand_limit() -> void:
	var limit: int = ctx.runner_max_hand_size()
	if limit < 0:
		# Already flatlined from core damage — nothing to do
		return
	var discarded_records: Array = []
	while ctx.runner_hand.size() > limit and not ctx.game_over:
		var excess: int = ctx.runner_hand.size() - limit
		var chosen_entry: Dictionary = {}

		# Ask runner (human or AI) to choose which card to discard.
		if ctx.runner_decision_maker != null and \
				ctx.runner_decision_maker.has_method("choose_discard_to_hand_limit"):
			var chosen = await ctx.runner_decision_maker.choose_discard_to_hand_limit(
				ctx.runner_hand.duplicate(), excess, ctx)
			if chosen is Array and not (chosen as Array).is_empty():
				# Batch discard
				for entry in (chosen as Array):
					var e: Dictionary = entry as Dictionary
					var cr: CardRecord = e.get("card_record", null) as CardRecord
					ctx.runner_hand.erase(e)
					if cr != null:
						ctx.runner_discard.append(cr)
						discarded_records.append(cr)
					ctx.send_log("%s discards %s to hand limit. (%d cards remaining)" % [
						ctx.runner_name(), cr.title if cr else "?", limit])
				if not ctx.simulation_mode: emit_signal("hand_changed", "runner")
				continue
			elif chosen is Dictionary and not (chosen as Dictionary).is_empty():
				chosen_entry = chosen as Dictionary

		if chosen_entry.is_empty():
			# Fallback heuristic: discard the card of lowest strategic value.
			# Priority: resources < events < hardware < programs; break ties by cost (lower = discard first).
			var best_entry: Dictionary = {}
			var best_score: int = 9999
			for e in ctx.runner_hand:
				var ed: Dictionary = e as Dictionary
				var cr: CardRecord = ed.get("card_record", null) as CardRecord
				if cr == null:
					continue
				# Lower score → discard first
				var type_score: int
				match cr.card_type:
					"resource": type_score = 0
					"event":    type_score = 1
					"hardware": type_score = 2
					"program":  type_score = 3
					_:          type_score = 0
				var card_score: int = type_score * 100 + (cr.cost if cr.cost >= 0 else 0)
				if card_score < best_score:
					best_score = card_score
					best_entry = ed
			if best_entry.is_empty() and not ctx.runner_hand.is_empty():
				best_entry = ctx.runner_hand[ctx.runner_hand.size() - 1] as Dictionary
			chosen_entry = best_entry

		if chosen_entry.is_empty():
			break

		ctx.runner_hand.erase(chosen_entry)
		var record: CardRecord = chosen_entry.get("card_record", null) as CardRecord
		if record != null:
			ctx.runner_discard.append(record)
			discarded_records.append(record)
		ctx.send_log("%s discards %s to hand limit (%d)." % [
			ctx.runner_name(), record.title if record else "?", limit
		])
		if not ctx.simulation_mode: emit_signal("hand_changed", "runner")
	# Magdalene Keino Chemutai: fire event so identity can install from discarded cards
	if not discarded_records.is_empty():
		await ctx.notify_event("runner_discards_to_hand_limit", {
			"discarded_cards": discarded_records
		}, interpreter)


# ── Runner turn ───────────────────────────────────────────────────────────────

func _runner_turn() -> void:
	ctx.active_player  = "runner"
	var runner_penalty: int = ctx.pending_click_penalties.get("runner", 0)
	ctx.runner_clicks = max(0, RUNNER_CLICKS_PER_TURN - runner_penalty)
	ctx.pending_click_penalties["runner"] = 0
	ctx.runner_made_successful_run_this_turn = false   # reset each turn
	ctx.runner_centrals_run_this_turn = []             # reset each turn
	ctx.runner_click_draws_this_turn  = 0              # reset each turn
	ctx.runner_hq_breached_this_turn        = false    # reset each turn
	ctx.runner_hq_successful_run_this_turn  = false    # reset each turn (Détente)
	ctx.runner_trashed_during_breach_this_turn    = false  # reset each turn (Loup)
	ctx.runner_trashed_own_installed_this_turn    = false  # reset each turn (Boi Tata)
	ctx.runner_program_install_discounted_this_turn = false  # reset each turn (DZMZ)
	ctx.runner_carnivore_used_this_turn = false              # reset each turn
	ctx.runner_stole_agenda_this_turn  = false               # reset each turn (Hype Machine)
	ctx.runner_action_type_counts_this_turn = {}             # reset each turn (Wage Workers)
	ctx.runner_first_run_this_turn_made     = false          # reset each turn (Front Company)
	ctx.runner_successful_run_on_rd_this_turn       = false  # reset each turn (VP1 Chain Reaction)
	ctx.runner_successful_run_on_archives_this_turn = false  # reset each turn (VP1 Chain Reaction)
	ctx.once_per_turn_triggered.clear()                      # reset per-turn trigger guards
	# Clear turn-scoped strength bonuses (e.g. Living Mural Threat 4 install: +3 str this turn).
	for _ts_card in ctx.runner_rig:
		var _ts_ic: InstalledCard = _ts_card as InstalledCard
		if _ts_ic != null and _ts_ic.get_counter("turn_str_bonus") > 0:
			_ts_ic.remove_counter("turn_str_bonus", _ts_ic.get_counter("turn_str_bonus"))
	if runner_penalty > 0:
		ctx.send_log("%s loses %d click(s) this turn (deferred penalty)." % [ctx.runner_name(), runner_penalty])
	ctx.turn_number   += 1

	if not ctx.simulation_mode: emit_signal("turn_started", "runner", ctx.turn_number)
	ctx.send_log("=== %s Turn %d begins. Credits: %d, Clicks: %d ===" % [
		ctx.runner_name(), ctx.turn_number, ctx.runner_credits, ctx.runner_clicks
	])
	# Fire start-of-turn triggers (resources, hardware, etc.)
	await ctx.notify_event("runner_turn_start", {}, interpreter)

	var _consecutive_rejections := 0
	while ctx.runner_clicks > 0 and not ctx.game_over:
		if ctx.runner_decision_maker == null:
			ctx.send_log("No %s decision maker — ending turn." % ctx.runner_name())
			break

		var action: GameAction = await ctx.runner_decision_maker.choose_action(ctx)
		if action == null:
			ctx.send_log("No action from %s — ending turn." % ctx.runner_name())
			break

		var result := await _execute_action("runner", action)
		if not result["ok"]:
			ctx.send_log("%s action rejected: %s" % [ctx.runner_name(), result["reason"]])
			_consecutive_rejections += 1
			if _consecutive_rejections >= 5:
				# Safety valve: an AI that keeps submitting invalid actions would loop
				# forever on continue — break after five consecutive rejections.
				ctx.send_log("%s: too many consecutive invalid actions — ending turn." % ctx.runner_name())
				break
			# No click was spent on a rejected action; let the runner try again.
			continue
		_consecutive_rejections = 0

	# Action phase ends — fire before discard phase begins.
	# VP36 Méliès U front-side passive (+1 cr) triggers here when not flipped.
	if not ctx.game_over:
		await ctx.notify_event("runner_action_phase_ends", {}, interpreter)

	# Discard phase: runner discards down to max hand size (relevant after core damage)
	await _runner_discard_to_hand_limit()
	if not ctx.game_over:
		await ctx.notify_event("runner_discard_phase_ends", {}, interpreter)


# ── Action execution ──────────────────────────────────────────────────────────

func _execute_action(player: String, action: GameAction) -> Dictionary:
	# Validate first
	var valid := _validate_action(player, action)
	if not valid["ok"]:
		if not ctx.simulation_mode: emit_signal("action_rejected", player, action, valid["reason"])
		return valid

	# Execute
	match action.type:
		"gain_credits":    await _do_gain_credits(player)
		"draw_card":       await _do_draw_card(player)
		"install":         await _do_install(player, action)
		"advance":         await _do_advance(player, action)
		"play_operation":  await _do_play_operation(player, action)
		"run":             await _do_run(action)
		"rez_card":           await _do_rez_card(player, action)
		"use_installed_card": await _do_use_installed_card(player, action)
		"play_from_archives": await _do_play_from_archives(player, action)
		"use_hq_card":        await _do_use_hq_card(player, action)
		"remove_tag":              await _do_remove_tag()
		"trash_runner_resource":   await _do_trash_runner_resource(action)
		"purge_virus":             await _do_purge_virus()
		"end_turn":           await _do_end_turn(player)
		_:
			return {"ok": false, "reason": "Unknown action type: %s" % action.type}

	# Mark that the Corp has completed a click action this turn (Petty Cash condition).
	# rez_card and pass are not click-costing actions — everything else is.
	if player == "corp" and action.type not in ["rez_card", "pass", "end_turn"]:
		ctx.corp_finished_an_action_this_turn = true

	# Wage Workers (TAI): track runner click-action types; fire +1 click when any hits 3.
	if player == "runner":
		var ww_type: String = ""
		match action.type:
			"draw_card":       ww_type = "click_to_draw"
			"gain_credits":    ww_type = "click_to_gain_credit"
			"install":         ww_type = "click_to_install"
			"run":             ww_type = "click_to_run"
			"play_operation":  ww_type = "click_to_play_event"
		if ww_type != "":
			var ww_prev: int = ctx.runner_action_type_counts_this_turn.get(ww_type, 0)
			ctx.runner_action_type_counts_this_turn[ww_type] = ww_prev + 1
			# Fire Wage Workers trigger exactly when this type's count first reaches 3.
			if ww_prev + 1 == 3:
				await ctx.notify_event("wage_workers_threshold", {"action_type": ww_type}, interpreter)

	if not ctx.simulation_mode: emit_signal("action_executed", player, action)
	_check_win_conditions()
	return {"ok": true, "reason": ""}


# ── Validation ────────────────────────────────────────────────────────────────

func _validate_action(player: String, action: GameAction) -> Dictionary:
	var clicks: int = ctx.corp_clicks if player == "corp" else ctx.runner_clicks

	match action.type:
		"end_turn":
			return {"ok": true, "reason": ""}

		"rez_card":
			return {"ok": true, "reason": ""}

		"use_installed_card":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			# Check for additional click costs in the card's click_action def (e.g. Rent Rioters: 3 total)
			var act_card_id: String = action.params.get("card_id", "")
			if act_card_id != "":
				var act_card_def: Dictionary = ability_registry._abilities.get(act_card_id, {}) as Dictionary
				var act_click_def: Dictionary = act_card_def.get("click_action", {}) as Dictionary
				var act_extra: int = act_click_def.get("additional_cost_clicks", 0)
				if act_extra > 0 and clicks < 1 + act_extra:
					return {"ok": false, "reason": "Not enough clicks for %s (need %d total)" % [act_card_id, 1 + act_extra]}
				# Check tag_cost: Corp abilities on stolen agendas may require the Runner to have tags.
				# e.g. Oracle Thinktank — Corp removes 1 runner tag to shuffle back into R&D.
				var act_tag_cost: int = act_click_def.get("tag_cost", 0)
				if act_tag_cost > 0 and ctx.runner_tags < act_tag_cost:
					return {"ok": false, "reason": "Not enough Runner tags for %s (need %d)" % [act_card_id, act_tag_cost]}
			return {"ok": true, "reason": ""}

		"gain_credits", "draw_card":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			return {"ok": true, "reason": ""}

		"run":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			var target: String = action.params.get("server_id", "")
			var rp_mods: Array = ctx._state_modifiers.get("block_remote_runs_unless_ran_central", [])
			if not rp_mods.is_empty() and target.begins_with("remote_"):
				if ctx.runner_centrals_run_this_turn.is_empty():
					return {"ok": false, "reason": "Replicating Perfection: you must run a central server before running on a remote."}
			# Front Company (TAI): if the runner has not yet made a run this turn,
			# they cannot run on a remote server while Front Company is rezzed in any
			# non-Archives server.
			if not ctx.runner_first_run_this_turn_made and target.begins_with("remote_"):
				for fc_srv in ctx.servers.values():
					var fc_s: Server = fc_srv as Server
					if fc_s.server_id == "archives":
						continue
					for fc_root in fc_s.root:
						var fc_c: InstalledCard = fc_root as InstalledCard
						if fc_c != null and fc_c.is_rezzed and fc_c.card_id == "front_company":
							return {"ok": false, "reason": "Front Company: you must make another run before running on a remote."}
			return {"ok": true, "reason": ""}

		"install":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			var record: CardRecord = action.params.get("card_record", null) as CardRecord
			if record == null:
				return {"ok": false, "reason": "No card to install"}
			# Ice install costs 1 credit per existing ice on target server
			if record.is_ice():
				var server: Server = ctx.get_server(action.params.get("server_id", ""))
				var ice_cost: int  = server.ice_install_cost() if server else 0
				if ctx.get_credits(player) < ice_cost:
					return {"ok": false, "reason": "Cannot afford ice install cost"}
			# A Teia: IP Recovery — enforce the 2-remote-server limit.
			# If no target server is specified (new remote) or the target doesn't exist yet,
			# check whether a new remote can be created.
			if player == "corp":
				var install_target_id: String = action.params.get("server_id", "")
				var target_is_new_remote: bool = (install_target_id == "" or \
						(install_target_id.begins_with("remote_") and \
						 ctx.get_server(install_target_id) == null))
				if target_is_new_remote and not ctx.can_create_new_remote_server():
					return {"ok": false, "reason": "A Teia: IP Recovery limits you to 2 remote servers."}
			return {"ok": true, "reason": ""}

		"advance":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			if ctx.get_credits(player) < 1:
				return {"ok": false, "reason": "Cannot afford advance (costs 1 credit)"}
			var card_id: String = action.params.get("card_id", "")
			var card := _find_advanceable_card(card_id)
			if card == null:
				return {"ok": false, "reason": "Card %s not found or not advanceable" % card_id}
			return {"ok": true, "reason": ""}

		"play_operation":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			var record: CardRecord = action.params.get("card_record", null) as CardRecord
			if record == null:
				return {"ok": false, "reason": "No operation to play"}
			if ctx.get_credits(player) < max(0, record.cost):
				return {"ok": false, "reason": "Cannot afford %s" % record.title}
			# Check additional click costs (e.g. Lie Low, Maintenance Access: spend 1 extra click)
			var op_card_def: Dictionary = ability_registry._abilities.get(record.id, {}) as Dictionary
			var op_extra: int = op_card_def.get("additional_cost_clicks", 0)
			if op_extra > 0 and clicks < 1 + op_extra:
				return {"ok": false, "reason": "Not enough clicks for %s (need %d total)" % [record.title, 1 + op_extra]}
			# Pre-play condition guard — mirrors _do_play_card's early-return checks so
			# the UI and AI never see the card as playable when its condition isn't met.
			var va_ppc: String = op_card_def.get("pre_play_condition", "")
			if va_ppc == "runner_stole_or_trashed_last_runner_turn" and player == "corp":
				if not ctx.runner_stole_or_trashed_last_runner_turn:
					return {"ok": false,
						"reason": "%s: Runner did not steal or trash last turn." % record.title}
			if va_ppc == "corp_scored_non_installed_agenda_this_turn" and player == "corp":
				if not ctx.corp_scored_agenda_not_installed_this_turn:
					return {"ok": false,
						"reason": "%s: Corp has not scored a non-installed agenda this turn." % record.title}
			if va_ppc == "runner_made_successful_run_last_turn" and player == "runner":
				if not ctx.runner_made_successful_run_last_turn:
					return {"ok": false,
						"reason": "%s: Runner did not make a successful run last turn." % record.title}
			return {"ok": true, "reason": ""}

		"play_from_archives":
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			var pfa_card_id: String = action.params.get("card_id", "")
			var pfa_found := false
			for cr in ctx.corp_discard:
				if (cr as CardRecord).id == pfa_card_id:
					pfa_found = true
					break
			if not pfa_found:
				return {"ok": false, "reason": "%s not found in Archives" % pfa_card_id}
			return {"ok": true, "reason": ""}

		"use_hq_card":
			# Expendable ability: activate a card from HQ by paying [click] + credit cost,
			# revealing and trashing the card.  Used by Slash & Burn Agriculture, Tree Line,
			# Angelique Garza Correa, and similar "expendable" TAI Corp cards.
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks"}
			var uhcv_card_id: String = action.params.get("card_id", "")
			var uhcv_def: Dictionary = ability_registry._abilities.get(uhcv_card_id, {}) as Dictionary
			var uhcv_hq_def: Dictionary = uhcv_def.get("hq_click_ability", {}) as Dictionary
			# Threat condition (e.g. Angelique requires Threat 3)
			var uhcv_threat: int = uhcv_hq_def.get("threat_condition", -1)
			if uhcv_threat >= 0 and ctx.threat_level() < uhcv_threat:
				return {"ok": false, "reason": "%s requires Threat %d (current: %d)." % [
					uhcv_card_id, uhcv_threat, ctx.threat_level()]}
			# Credit cost
			var uhcv_cr: int = uhcv_hq_def.get("credit_cost", 0)
			if ctx.corp_credits < uhcv_cr:
				return {"ok": false, "reason": "Cannot afford %s (need %d cr, have %d)." % [
					uhcv_card_id, uhcv_cr, ctx.corp_credits]}
			# Card must be present in HQ
			var uhcv_found := false
			for uhcv_e in ctx.corp_hand:
				if (uhcv_e as Dictionary).get("card_id", "") == uhcv_card_id:
					uhcv_found = true
					break
			if not uhcv_found:
				return {"ok": false, "reason": "%s not found in HQ." % uhcv_card_id}
			return {"ok": true, "reason": ""}

		# ── §10.5.4  Runner removes 1 tag ──────────────────────────────────────────
		"remove_tag":
			if player != "runner":
				return {"ok": false, "reason": "Only the Runner may remove tags as a basic action."}
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks."}
			if ctx.runner_credits < 2:
				return {"ok": false, "reason": "Need 2cr to remove a tag (have %d)." % ctx.runner_credits}
			if ctx.runner_tags <= 0:
				return {"ok": false, "reason": "Runner has no tags to remove."}
			return {"ok": true, "reason": ""}

		# ── §10.5.3  Corp trashes a tagged Runner's resource ────────────────────────
		"trash_runner_resource":
			if player != "corp":
				return {"ok": false, "reason": "Only the Corp may trash Runner resources as a basic action."}
			if clicks < 1:
				return {"ok": false, "reason": "Not enough clicks."}
			if ctx.corp_credits < 2:
				return {"ok": false, "reason": "Need 2cr to trash a resource (have %d)." % ctx.corp_credits}
			if not ctx.runner_is_tagged():
				return {"ok": false, "reason": "Runner is not tagged."}
			var trv_iid: String = action.params.get("card_instance_id", "")
			for trv_card in ctx.runner_rig:
				var trv_ic: InstalledCard = trv_card as InstalledCard
				if trv_ic != null and trv_ic.runtime_instance_id == trv_iid:
					if trv_ic.card_record == null or trv_ic.card_record.card_type != "resource":
						return {"ok": false, "reason": "Target is not a resource."}
					return {"ok": true, "reason": ""}
			return {"ok": false, "reason": "Target resource not found in Runner's rig."}

		# ── §10.1.2  Corp purges virus counters ─────────────────────────────────────
		"purge_virus":
			if player != "corp":
				return {"ok": false, "reason": "Only the Corp may purge virus counters."}
			if clicks < 3:
				return {"ok": false, "reason": "Need 3 clicks to purge (have %d)." % clicks}
			return {"ok": true, "reason": ""}

		_:
			return {"ok": false, "reason": "Unknown action type: %s" % action.type}


# ── Action implementations ────────────────────────────────────────────────────

# ── Expendable (HQ click ability) ────────────────────────────────────────────
# Handles non-operation Corp cards (agendas, ice, upgrades) that have an ability
# usable from HQ by paying [click] + credit_cost, then revealing and trashing
# the card itself.  Examples: Slash & Burn Agriculture, Tree Line, Angelique.
func _do_use_hq_card(player: String, action: GameAction) -> void:
	_spend_click(player)

	var uhc_card_id: String   = action.params.get("card_id", "")
	var uhc_def: Dictionary   = ability_registry._abilities.get(uhc_card_id, {}) as Dictionary
	var uhc_hq_def: Dictionary = uhc_def.get("hq_click_ability", {}) as Dictionary
	var uhc_cr: int           = uhc_hq_def.get("credit_cost", 0)

	# Find the card entry in HQ.
	var uhc_entry: Variant    = null
	var uhc_record: CardRecord = null
	for e in ctx.corp_hand:
		var d: Dictionary = e as Dictionary
		if d.get("card_id", "") == uhc_card_id:
			uhc_entry  = e
			uhc_record = d.get("card_record", null) as CardRecord
			break

	if uhc_entry == null or uhc_record == null:
		push_error("_do_use_hq_card: '%s' not found in HQ." % uhc_card_id)
		return

	# Pay credit cost.
	if uhc_cr > 0:
		ctx.corp_credits -= uhc_cr
		if not ctx.simulation_mode: emit_signal("credits_changed", player, ctx.corp_credits)

	# Reveal (log) and trash from HQ to Archives faceup.
	ctx.corp_hand.erase(uhc_entry)
	ctx.corp_discard.append(uhc_record)
	ctx.send_log("[Expendable] %s reveals and trashes %s from HQ." % [
		ctx.corp_name(), uhc_record.title])
	if not ctx.simulation_mode: emit_signal("hand_changed", player)

	# Fire the effects defined in hq_click_ability.
	var uhc_effects: Array = uhc_hq_def.get("effects", []) as Array
	if not uhc_effects.is_empty():
		ctx.current_event_data = {"card_id": uhc_card_id, "card_instance_id": uhc_card_id}
		await interpreter.execute_trigger({"effects": uhc_effects}, ctx)
		ctx.current_event_data = {}


func _do_gain_credits(player: String) -> void:
	_spend_click(player)
	ctx.set_credits(player, ctx.get_credits(player) + 1)
	if not ctx.simulation_mode: emit_signal("credits_changed", player, ctx.get_credits(player))
	ctx.send_log("%s gains 1 credit. (%d total)" % [ctx.player_name(player), ctx.get_credits(player)])


func _do_draw_card(player: String) -> void:
	_spend_click(player)
	var deck: Array = ctx.corp_deck if player == "corp" else ctx.runner_deck
	
	if deck.is_empty():
		if player == "corp":
			_end_game("runner", "Corp could not draw (empty R&D)")
		else:
			ctx.send_log("%s deck is empty — cannot draw." % ctx.runner_name())
		return
		
	# Pop the object asset cleanly
	var drawn: CardRecord = deck.pop_front() as CardRecord
	var hand_entry := {"card_id": drawn.id, "card_record": drawn}
	
	if player == "corp":
		ctx.corp_hand.append(hand_entry)
	else:
		ctx.runner_hand.append(hand_entry)
		
	if not ctx.simulation_mode: emit_signal("hand_changed", player)
	ctx.send_log("%s draws %s." % [ctx.player_name(player), drawn.title])

	# Verbal Plasticity: draw 1 extra card on the FIRST click-draw of the runner's turn only.
	if player == "runner":
		ctx.runner_click_draws_this_turn += 1
		if ctx.runner_click_draws_this_turn == 1:
			var mods: Array = ctx._state_modifiers.get("extra_draw_on_click_draw", [])
			if not mods.is_empty():
				var extra: int = 0
				for mod in mods:
					extra += (mod as Dictionary).get("value", 0) as int
				for _i in range(extra):
					if deck.is_empty():
						ctx.send_log("%s deck empty — Verbal Plasticity cannot draw extra." % ctx.runner_name())
						break
					var extra_card: CardRecord = deck.pop_front() as CardRecord
					ctx.runner_hand.append({"card_id": extra_card.id, "card_record": extra_card})
					ctx.send_log("Verbal Plasticity: %s draws %s." % [ctx.runner_name(), extra_card.title])
				if not ctx.simulation_mode: emit_signal("hand_changed", player)


func _do_install(player: String, action: GameAction) -> void:
	_spend_click(player)
	var record: CardRecord = action.params.get("card_record", null) as CardRecord
	var server_id: String  = action.params.get("server_id", "")
	var zone: String       = action.params.get("zone", "root")

	# Runner programs, hardware, and resources go directly to the rig
	if player == "runner" and server_id == "runner_rig":
		var pay_cost: int = max(0, record.cost)

		# Conditional install cost reduction (e.g. Carmen: 5 → 3 after successful run)
		var card_def: Dictionary = ability_registry._abilities.get(record.id, {}) as Dictionary
		var conditional_cost: Variant = card_def.get("install_cost_if_successful_run", null)
		if conditional_cost != null and ctx.runner_made_successful_run_this_turn:
			pay_cost = int(conditional_cost)
			ctx.send_log("Conditional install cost applies: %s costs %d¢ this turn." % [record.title, pay_cost])

		print("Player install: card is: ", record.title, " and charged cost is: ", pay_cost)

		# DZMZ Optimizer: first program install each turn costs 1cr less
		if record.card_type == "program" and not ctx.runner_program_install_discounted_this_turn:
			var has_dzmz := false
			for rig_card in ctx.runner_rig:
				var c: InstalledCard = rig_card as InstalledCard
				if c != null and c.card_id == "dzmz_optimizer":
					has_dzmz = true
					break
			if has_dzmz:
				pay_cost = max(0, pay_cost - 1)
				ctx.runner_program_install_discounted_this_turn = true
				ctx.send_log("DZMZ Optimizer: %s costs 1 less (now %d¢)." % [record.title, pay_cost])

		# Per-icebreaker install cost reduction (e.g. Principia: 1cr less per other installed icebreaker)
		var discount_per_ib: int = card_def.get("install_cost_discount_per_icebreaker", 0)
		if discount_per_ib > 0:
			var num_other_ib := 0
			for rig_card in ctx.runner_rig:
				var c: InstalledCard = rig_card as InstalledCard
				if c == null or c.card_record == null:
					continue
				if c.card_record.has_subtype("icebreaker") or \
				   c.card_record.subtypes.any(func(s): return s in ["fracter", "decoder", "killer", "ai"]):
					num_other_ib += 1
			if num_other_ib > 0:
				var ib_discount: int = discount_per_ib * num_other_ib
				pay_cost = max(0, pay_cost - ib_discount)
				ctx.send_log("%s: %d other icebreaker(s) installed — install costs %d¢ less (now %d¢)." % [
					record.title, num_other_ib, ib_discount, pay_cost
				])

		# Hackerspace (VP6): unique companion/connection resources may be hosted for 1cr discount
		var hs_host: InstalledCard = null
		var hs_will_host := false
		if record.card_type == "resource" and record.is_unique and \
				(record.has_subtype("companion") or record.has_subtype("connection")):
			for hs_search in ctx.runner_rig:
				var hs_ic: InstalledCard = hs_search as InstalledCard
				if hs_ic != null and hs_ic.card_id == "hackerspace" and \
						hs_ic.hosted_runner_resources.size() < 4:
					hs_host = hs_ic
					break
			if hs_host != null:
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_modes"):
					var hs_modes: Array = [
						{"label": "Install on Hackerspace (1cr discount)"},
						{"label": "Install normally"}
					]
					var hs_chosen: Array = await ctx.runner_decision_maker.choose_modes(hs_modes, 1, ctx)
					hs_will_host = (not hs_chosen.is_empty() and hs_chosen[0] == 0)
				else:
					hs_will_host = true   # AI default: always take the discount
				if hs_will_host:
					pay_cost = max(0, pay_cost - 1)
					ctx.send_log("Hackerspace: %s costs 1cr less to install (now %dcr)." % \
						[record.title, pay_cost])

		# MU check for programs (hosted-on-ice programs still use MU)
		if record.card_type == "program" and record.memory_cost > 0:
			var mu_needed: int = record.memory_cost
			if ctx.runner_mu_available() < mu_needed:
				ctx.send_log("%s cannot install %s — not enough MU (%d needed, %d available, %d total)." % [
					ctx.runner_name(), record.title,
					mu_needed, ctx.runner_mu_available(), ctx.runner_total_mu()
				])
				return

		# ── Hosted install credits ────────────────────────────────────────────────
		# Two sources of hosted credits can supplement runner_credits at install time:
		#   1. install_credits_for_subtypes (Open Market style): subtype-restricted.
		#   2. install_credits_any (Urban Art Vernissage): unrestricted Runner install credits.
		# All matching sources are pooled; hosted credits are drawn first, then runner pool.
		ctx.install_credit_sources = []
		var ic_total_hosted: int = 0

		for rig_c in ctx.runner_rig:
			var rc: InstalledCard = rig_c as InstalledCard
			if rc == null:
				continue
			var rc_def: Dictionary = ability_registry._abilities.get(rc.card_id, {}) as Dictionary

			# Subtype-restricted source
			var allowed_sts: Array = rc_def.get("install_credits_for_subtypes", []) as Array
			if not allowed_sts.is_empty():
				for st in allowed_sts:
					if record.has_subtype(st as String):
						ctx.install_credit_sources.append(rc)
						ic_total_hosted += rc.get_counter("credits")
						break
				continue   # don't double-count as unrestricted

			# Unrestricted hosted install credits (TAI: Urban Art Vernissage; others may be added)
			if rc_def.get("install_credits_any", false):
				var ic_avail: int = rc.get_counter("credits")
				if ic_avail > 0:
					ctx.install_credit_sources.append(rc)
					ic_total_hosted += ic_avail

		if ctx.runner_credits + ic_total_hosted < pay_cost:
			ctx.send_log("%s cannot afford to install %s." % [ctx.runner_name(), record.title])
			ctx.install_credit_sources = []
			return

		# Spend hosted credits first (in order), then top up from runner pool.
		var ic_remaining_cost: int = pay_cost
		for ic_src in ctx.install_credit_sources:
			if ic_remaining_cost <= 0:
				break
			var ic_src_card: InstalledCard = ic_src as InstalledCard
			var ic_draw: int = min(ic_remaining_cost, ic_src_card.get_counter("credits"))
			if ic_draw > 0:
				ic_src_card.remove_counter("credits", ic_draw)
				ic_remaining_cost -= ic_draw
				ctx.send_log("%s: %d hosted cr from %s used for %s (%d remaining on source)." % [
					ctx.runner_name(), ic_draw, ic_src_card.display_name(),
					record.title, ic_src_card.get_counter("credits")
				])
		ctx.runner_credits -= ic_remaining_cost
		ctx.install_credit_sources = []   # consumed — clear

		# Check if this card must be hosted on a specific ice card
		var must_host_on_ice: bool = card_def.get("install_on_ice", false)
		var host_ice: InstalledCard = null
		if must_host_on_ice:
			# Ask the runner to choose a target ice
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_host_ice"):
				host_ice = await ctx.runner_decision_maker.choose_host_ice(ctx)
			if host_ice == null:
				# No valid target — find any installed ice
				for server in ctx.servers.values():
					for ice in (server as Server).ice:
						host_ice = ice as InstalledCard
						break
					if host_ice != null:
						break
			if host_ice == null:
				ctx.send_log("%s cannot install %s — no installed ice to host it." % [ctx.runner_name(), record.title])
				ctx.runner_credits += pay_cost   # refund
				return

		var installed := InstalledCard.make_runtime_instance(record, "runner_rig", "root", true)

		if must_host_on_ice and host_ice != null:
			# Host on the chosen ice rather than the general rig
			installed.hosted_on_id = host_ice.runtime_instance_id
			installed.server_id    = host_ice.server_id   # same server as host
			host_ice.hosted_cards.append(installed)
			ctx.send_log("%s hosts %s on %s." % [ctx.runner_name(), record.title, host_ice.display_name()])
		else:
			ctx.runner_rig.append(installed)
		# Hackerspace (VP6): add to hosted resources list if player chose hosting
		if hs_host != null and hs_will_host:
			hs_host.hosted_runner_resources.append(installed)
			ctx.send_log("Hackerspace: %s is now hosted on Hackerspace." % record.title)

		# Boomerang-style: choose a target ice on install (no physical hosting)
		var choose_target_flag: Variant = card_def.get("choose_target_on_install", null)
		if choose_target_flag != null and not must_host_on_ice:
			var target_candidates: Array = []
			for ct_server in ctx.servers.values():
				for ct_ice in (ct_server as Server).ice:
					target_candidates.append(ct_ice as InstalledCard)
			if not target_candidates.is_empty():
				var ct_chosen: InstalledCard = null
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_target_ice"):
					ct_chosen = await ctx.runner_decision_maker.choose_target_ice(target_candidates, record.title, ctx)
				elif ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_host_ice"):
					ct_chosen = await ctx.runner_decision_maker.choose_host_ice(ctx)
				if ct_chosen == null:
					ct_chosen = target_candidates[0]  # fallback: first ice
				installed.target_id = ct_chosen.runtime_instance_id
				ctx.send_log("%s targets %s with %s." % [ctx.runner_name(), ct_chosen.display_name(), record.title])

		_remove_from_hand(player, record)
		_register_card_listeners(installed)
		# Fire on_rez directly on this card only — never broadcast via notify_event
		var on_rez_def = ability_registry.get_on_rez(record.id)
		if on_rez_def != null:
			ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
			await interpreter.execute_trigger(on_rez_def as Dictionary, ctx)
			ctx.current_event_data = {}
		if not ctx.simulation_mode: emit_signal("card_installed", record, "runner_rig")
		if not ctx.simulation_mode: emit_signal("hand_changed", player)
		# Fire runner_installs_virus for Cookbook
		if record.card_type == "program" and record.has_subtype("virus"):
			await ctx.notify_event("runner_installs_virus", {
				"card": installed,
				"card_instance_id": installed.runtime_instance_id
			}, interpreter)
		# Fire runner_installs_program for LilyPAD and similar "first program install" triggers
		if record.card_type == "program":
			await ctx.notify_event("runner_installs_program", {
				"card": installed,
				"card_instance_id": installed.runtime_instance_id
			}, interpreter)
		# Fire runner_installs_card for Bling and similar triggers
		await ctx.notify_event("runner_installs_card", {
			"credits_paid": ic_remaining_cost,
			"card": installed,
			"card_instance_id": installed.runtime_instance_id
		}, interpreter)
		ctx.send_log("%s installs %s. [MU: %d/%d used]" % [
			ctx.runner_name(), record.title, ctx.runner_mu_used(), ctx.runner_total_mu()
		])
		return

	# Get or create server for corp cards and runner ice (future)
	var server: Server = ctx.get_server(server_id)
	if server == null:
		# A Teia: IP Recovery — double-check the remote cap here in case the call bypassed
		# validation (e.g. triggered free installs, which skip normal action validation).
		# The A Teia free-install helper passes an explicit server_id, so this only guards
		# against unexpected new-remote creation that would exceed the cap.
		if player == "corp" and not ctx.can_create_new_remote_server():
			ctx.send_log("[A Teia] Cannot create a new remote server — limit of 2 reached.")
			return
		server = ctx.create_remote_server()
		server_id = server.server_id

	# Pay ice install cost (positional: 1cr per existing ice on target server).
	# Corp assets with "corp_install_credits_any: true" (e.g. Cybersand Harvester) can
	# contribute hosted credits before the Corp's own pool is drawn.
	if record.is_ice():
		var ice_cost: int = server.ice_install_cost()
		var ice_cost_remaining: int = ice_cost
		if ice_cost_remaining > 0:
			for csh_srv in ctx.servers.values():
				if ice_cost_remaining <= 0:
					break
				var csh_s: Server = csh_srv as Server
				for csh_root_c in csh_s.root:
					if ice_cost_remaining <= 0:
						break
					var csh_c: InstalledCard = csh_root_c as InstalledCard
					if csh_c == null or not csh_c.is_rezzed:
						continue
					var csh_def: Dictionary = ability_registry._abilities.get(csh_c.card_id, {}) as Dictionary
					if csh_def.get("corp_install_credits_any", false):
						var csh_avail: int = csh_c.get_counter("credits")
						var csh_draw: int  = mini(ice_cost_remaining, csh_avail)
						if csh_draw > 0:
							csh_c.remove_counter("credits", csh_draw)
							ice_cost_remaining -= csh_draw
							ctx.send_log("[Cybersand Harvester] %d hosted cr used for ice install (%d remaining on source)." % [
								csh_draw, csh_c.get_counter("credits")
							])
		ctx.set_credits(player, ctx.get_credits(player) - ice_cost_remaining)
		if ice_cost > 0:
			ctx.send_log("%s pays %d credit(s) to install ice." % [ctx.player_name(player), ice_cost])

	# Create InstalledCard
	var installed := InstalledCard.make_runtime_instance(record, server_id, zone, false)

	if zone == "ice":
		server.install_ice(installed)
	else:
		server.install_in_root(installed)

	# ── BANGUN: Corp may install agendas faceup ───────────────────────────────
	# Faceup agendas are "neither rezzed nor unrezzed" (per rules). Their
	# abilities are NOT active.  When the Runner accesses one, BANGUN deals
	# 2 meat damage and gives 1 tag (checked in RunStateMachine._access_card).
	if player == "corp" and zone == "root" and record.is_agenda() and \
			ctx.corp_identity != null and \
			ctx.corp_identity.id == "bangun_when_disaster_strikes":
		var want_faceup := false
		if ctx.corp_decision_maker != null and \
				ctx.corp_decision_maker.has_method("choose_install_faceup"):
			want_faceup = await ctx.corp_decision_maker.choose_install_faceup(record, ctx)
		if want_faceup:
			installed.is_face_up = true
			ctx.send_log("BANGUN: %s installs %s faceup." % [ctx.corp_name(), record.title])

	# Generic faceup install for agendas with install_faceup flag (e.g. VP56 Sacrifice Zone Expansion)
	if player == "corp" and zone == "root" and record.is_agenda() and not installed.is_face_up:
		var faceup_def: Dictionary = ability_registry._abilities.get(record.id, {}) as Dictionary
		if faceup_def.get("install_faceup", false):
			installed.is_face_up = true
			ctx.send_log("%s installs %s faceup." % [ctx.corp_name(), record.title])
	# Register listeners for faceup-installed Corp cards (active without being rezzed)
	if player == "corp" and installed.is_face_up:
		_register_card_listeners(installed)

	# Remove from hand
	_remove_from_hand(player, record)

	if not ctx.simulation_mode: emit_signal("card_installed", record, server_id)
	if not ctx.simulation_mode: emit_signal("hand_changed", player)
	ctx.send_log("%s installs %s in %s." % [ctx.player_name(player), record.title, server.display_name()])
	# Track Corp installs this turn for Seamless Launch restriction
	if player == "corp":
		ctx.corp_installed_this_turn.append(record.id)

	# Fire corp_installs_in_root for Lago Paranoá Shelter and similar triggers.
	# Fires whenever the Corp places a card in the root zone of any server (not ice).
	if player == "corp" and zone == "root":
		await ctx.notify_event("corp_installs_in_root", {
			"card_id": record.id,
			"server_id": server_id
		}, interpreter)

	# A Teia: IP Recovery — the first time each turn the Corp installs a card in the root
	# of, or protecting (ice), a remote server, offer a free install from HQ into another
	# remote server's root or protecting another remote server.
	if player == "corp" and not ctx.corp_first_remote_install_triggered_this_turn and \
			server.is_remote() and \
			ctx.corp_identity != null and ctx.corp_identity.id == "a_teia_ip_recovery":
		ctx.corp_first_remote_install_triggered_this_turn = true
		await _a_teia_free_install(server_id)


# ── A Teia: IP Recovery — free install from HQ into another remote ───────────────
# Called the first time each Corp turn that a Corp card is installed in a remote
# server root or protecting (as ice) a remote server.
# triggering_server_id: the server the Corp just installed into (excluded from targets).
func _a_teia_free_install(triggering_server_id: String) -> void:
	# Must have at least one card in HQ.
	if ctx.corp_hand.is_empty():
		ctx.send_log("[A Teia] No cards in HQ — free install skipped.")
		return

	# Offer the Corp the option to use the ability at all.
	var at_use := false
	if ctx.corp_decision_maker != null and \
			ctx.corp_decision_maker.has_method("choose_optional_ability"):
		at_use = await ctx.corp_decision_maker.choose_optional_ability(
			"A Teia: IP Recovery — install 1 card from HQ in another remote for free?", ctx)
	if not at_use:
		ctx.send_log("[A Teia] Corp declines the free install.")
		return

	# Build list of candidate target servers:
	# Any existing remote other than the triggering server, plus one "new remote" slot
	# if the cap (2) is not yet reached.
	var at_targets: Array = []
	for at_srv_key in ctx.servers:
		var at_s: Server = ctx.servers[at_srv_key] as Server
		if at_s.is_remote() and at_s.server_id != triggering_server_id:
			at_targets.append(at_s.server_id)
	# Allow creating a new remote if below the 2-remote cap.
	var at_can_new: bool = ctx.can_create_new_remote_server()
	if at_can_new:
		at_targets.append("new_remote")

	if at_targets.is_empty():
		ctx.send_log("[A Teia] No valid target server for free install — ability fizzles.")
		return

	# Corp chooses a card from HQ.
	var at_chosen_entry: Variant = null
	if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_card_from_hand"):
		at_chosen_entry = await ctx.corp_decision_maker.choose_card_from_hand(ctx.corp_hand, ctx)
	else:
		at_chosen_entry = ctx.corp_hand[0]
	if at_chosen_entry == null:
		ctx.send_log("[A Teia] Corp chooses no card — free install skipped.")
		return
	var at_record: CardRecord = (at_chosen_entry as Dictionary).get("card_record", null) as CardRecord
	if at_record == null:
		return

	# Corp chooses a target server.
	var at_target_id: String = at_targets[0]
	if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_server"):
		at_target_id = await ctx.corp_decision_maker.choose_server(at_targets, ctx)

	# Resolve "new_remote" into an actual server id.
	var at_server: Server
	if at_target_id == "new_remote":
		at_server = ctx.create_remote_server()
		at_target_id = at_server.server_id
	else:
		at_server = ctx.get_server(at_target_id)
	if at_server == null:
		ctx.send_log("[A Teia] Target server not found — free install aborted.")
		return

	# Corp chooses root or ice for the free-installed card.
	var at_zone: String = "root"
	if at_record.is_ice():
		at_zone = "ice"
	elif ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_install_zone"):
		at_zone = await ctx.corp_decision_maker.choose_install_zone(at_record, at_server, ctx)

	# Remove the card from HQ.
	ctx.corp_hand.erase(at_chosen_entry)

	# Install the card for free (no click, no credit cost).
	var at_installed := InstalledCard.make_runtime_instance(at_record, at_target_id, at_zone, false)
	if at_zone == "ice":
		at_server.install_ice(at_installed)
	else:
		at_server.install_in_root(at_installed)

	# Register ongoing listeners (face-down Corp cards are inactive until rezzed,
	# but faceup installs like BANGUN need this — guard with is_face_up for safety).
	if at_installed.is_face_up:
		_register_card_listeners(at_installed)

	# Track instance ID so _score_agenda can block scoring this turn.
	ctx.a_teia_free_installed_instance_ids.append(at_installed.runtime_instance_id)

	if not ctx.simulation_mode:
		emit_signal("card_installed", at_record, at_target_id)
		emit_signal("hand_changed", "corp")
	ctx.send_log("[A Teia] %s freely installs %s in %s (cannot score this turn)." % [
		ctx.corp_name(), at_record.title, at_server.display_name()])


func _do_advance(player: String, action: GameAction) -> void:
	_spend_click(player)
	ctx.set_credits(player, ctx.get_credits(player) - 1)
	if not ctx.simulation_mode: emit_signal("credits_changed", player, ctx.get_credits(player))

	var card_id: String  = action.params.get("card_id", "")
	var card := _find_advanceable_card(card_id)
	if card == null:
		return

	card.add_counter("advancement", 1)
	if not ctx.simulation_mode: emit_signal("card_advanced", card_id, card.get_counter("advancement"))
	ctx.send_log("%s advances %s (%d counters)." % [
		ctx.player_name(player), card.display_name(), card.get_counter("advancement")
	])

	# Fire on_advance for identity abilities (e.g. Weyland: Built to Last)
	await ctx.notify_event("on_advance", {"card_id": card_id}, interpreter)

	# Check if agenda can be scored
	if card.card_record != null and card.card_record.is_agenda():
		if card.meets_advancement_requirement():
			_score_agenda(card)


func _do_play_operation(player: String, action: GameAction) -> void:
	var record: CardRecord = action.params.get("card_record", null) as CardRecord
	if record == null:
		return

	# Look up card def early — needed for pre-play conditions and cost adjustments.
	var op_card_def: Dictionary = ability_registry._abilities.get(record.id, {}) as Dictionary

	# Pre-play conditions checked BEFORE spending any resources.
	if op_card_def.get("requires_first_action_this_turn", false) and player == "corp":
		if ctx.corp_finished_an_action_this_turn:
			ctx.send_log("%s: cannot play — already finished an action this turn." % record.title)
			return

	# Myōshu: can only play if Corp scored a non-installed agenda this turn.
	if op_card_def.get("pre_play_condition", "") == "corp_scored_non_installed_agenda_this_turn" and player == "corp":
		if not ctx.corp_scored_agenda_not_installed_this_turn:
			ctx.send_log("%s: cannot play — Corp has not scored a non-installed agenda this turn." % record.title)
			return

	# Active Policing / Bring Them Home: play only if runner stole or trashed last runner turn.
	if op_card_def.get("pre_play_condition", "") == "runner_stole_or_trashed_last_runner_turn" and player == "corp":
		if not ctx.runner_stole_or_trashed_last_runner_turn:
			ctx.send_log("%s: cannot play — Runner did not steal or trash a Corp card last turn." % record.title)
			return

	_spend_click(player)

	# Base play cost, with optional dynamic reduction (VP12 Tailgate: −1 per ice on a server).
	var cost: int = max(0, record.cost)
	if player == "runner":
		var per_ice_red: Dictionary = op_card_def.get("play_cost_reduction_per_ice_on_server", {}) as Dictionary
		if not per_ice_red.is_empty():
			var pir_server: String = per_ice_red.get("server", "hq")
			var pir_srv: Server = ctx.get_server(pir_server) as Server
			var pir_count: int = pir_srv.ice_count() if pir_srv != null else 0
			if pir_count > 0:
				cost = max(0, cost - pir_count)
				ctx.send_log("%s: %d ice on %s → play cost reduced to %d¢." % [
					record.title, pir_count, pir_server.to_upper(), cost])

	ctx.set_credits(player, ctx.get_credits(player) - cost)
	if not ctx.simulation_mode: emit_signal("credits_changed", player, ctx.get_credits(player))

	# Additional click costs (e.g. Lie Low, Maintenance Access: spend 1 extra click).
	var op_extra_clicks: int = op_card_def.get("additional_cost_clicks", 0)

	# VP27 Synchrocyclotron: first double per Corp turn costs 1 fewer click.
	if op_card_def.get("is_double", false) and player == "corp":
		if ctx.doubles_played_this_turn == 0:
			for synchro_srv in ctx.servers.values():
				for synchro_root in (synchro_srv as Server).root:
					var synchro_c: InstalledCard = synchro_root as InstalledCard
					if synchro_c != null and synchro_c.card_id == "synchrocyclotron" and synchro_c.is_rezzed:
						op_extra_clicks = max(0, op_extra_clicks - 1)
						ctx.send_log("Synchrocyclotron: first double this turn costs 1 fewer click.")
						break
		ctx.doubles_played_this_turn += 1

	for _i in range(op_extra_clicks):
		_spend_click(player)
	if op_extra_clicks > 0:
		ctx.send_log("%s spends %d additional click(s) to play %s." % [ctx.player_name(player), op_extra_clicks, record.title])

	# Additional cost: remove 1 tag (VP44 Unleash).
	if op_card_def.get("additional_cost_remove_tag", false) and player == "runner":
		if ctx.runner_tags <= 0:
			ctx.send_log("%s cannot play %s — no tags to remove." % [ctx.runner_name(), record.title])
			# Refund resources spent above
			ctx.runner_clicks += 1 + op_extra_clicks
			ctx.runner_credits += cost
			return
		ctx.runner_tags -= 1
		ctx.send_log("%s removes 1 tag to play %s (%d remaining)." % [
			ctx.runner_name(), record.title, ctx.runner_tags])

	# Additional cost: trash 1 installed card of given types (e.g. Sell Out: trash 1 resource)
	var op_trash_cost: Dictionary = op_card_def.get("additional_cost_trash_installed", {}) as Dictionary
	if not op_trash_cost.is_empty() and player == "runner":
		var op_tc_types: Array = op_trash_cost.get("card_types", []) as Array
		var op_tc_pool: Array  = ctx.runner_rig.filter(func(c: InstalledCard):
			return c.card_record != null and (op_tc_types.is_empty() or op_tc_types.has(c.card_record.card_type))
		)
		if op_tc_pool.is_empty():
			ctx.send_log("%s cannot play %s — no valid installed card to trash." % [
				ctx.runner_name(), record.title])
			# Refund click and credit
			ctx.runner_clicks += 1
			ctx.runner_credits += max(0, record.cost)
			return
		var op_tc_target: InstalledCard = null
		if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_target"):
			op_tc_target = await ctx.runner_decision_maker.choose_target(op_tc_pool, {"reason": "additional_cost_trash"})
		else:
			op_tc_target = op_tc_pool[0] as InstalledCard
		if op_tc_target == null:
			ctx.send_log("%s cancels %s." % [ctx.runner_name(), record.title])
			ctx.runner_clicks += 1
			ctx.runner_credits += max(0, record.cost)
			return
		ctx.runner_rig.erase(op_tc_target)
		ctx.unregister_all_card_effects(op_tc_target.runtime_instance_id)
		if op_tc_target.card_record != null:
			ctx.runner_discard.append(op_tc_target.card_record)
		ctx.runner_trashed_own_installed_this_turn = true
		ctx.send_log("%s trashes %s as an additional cost." % [ctx.runner_name(), op_tc_target.display_name()])
		# VP17 Hiram: fire hardware_trashed if the runner trashed a hardware as a cost
		if op_tc_target.card_record != null and op_tc_target.card_record.card_type == "hardware":
			await ctx.notify_event("hardware_trashed", {
				"card_id": op_tc_target.card_id, "source": "runner"
			}, interpreter)

	# Remove from hand
	_remove_from_hand(player, record)

	# Execute ability.
	# Tag (1) source card type for The Zwicky Group credit-gain tracking and
	# (2) play source so Petty Cash knows it came from HQ.
	# Also expose the card record in ctx meta so add_self_to_score_area (VP61 Myōshu)
	# can reference it without a separate parameter.
	ctx.current_operation_play_source = "hq"
	ctx.set_meta("current_op_card_record", record)
	var on_play_def = ability_registry.get_on_play(record.id)
	if on_play_def != null:
		ctx.current_ability_source_card_type = record.card_type   # "operation" or "event"
		await interpreter.execute_trigger(on_play_def as Dictionary, ctx)
		ctx.current_ability_source_card_type = ""
	ctx.remove_meta("current_op_card_record")
	ctx.current_operation_play_source = ""

	# Terminal operations: Corp's action phase ends immediately after resolving.
	if op_card_def.get("terminal", false) and player == "corp":
		ctx.corp_clicks = 0
		ctx.send_log("%s is terminal — Corp's action phase ends." % record.title)

	# Operations/events go to the correct discard pile after resolving.
	# Exception: if the effect scored this card as an agenda (VP61 Myōshu), skip discard.
	if player == "corp":
		if ctx.has_meta("operation_scored_as_agenda"):
			ctx.remove_meta("operation_scored_as_agenda")
			# Card now lives in corp_score_area — do not discard
		else:
			ctx.corp_discard.append(record)
		# Track for Nebula Making Stars flip condition; fire once-per-turn click gain trigger
		ctx.corp_played_operation_this_turn = true
		# Track mandate subtype plays (Sudden Commandment Threat 3).
		if "mandate" in record.subtypes:
			ctx.corp_mandates_played_this_turn += 1
		await ctx.notify_event("corp_plays_operation", {}, interpreter)
	else:
		var removes_self: bool = on_play_def != null and \
			(on_play_def as Dictionary).get("remove_from_game", false)
		if removes_self:
			ctx.runner_rfg.append(record)
		else:
			ctx.runner_discard.append(record)
		# VP20 Touchstone and other cards that react to the runner playing an event.
		if record.card_type == "event":
			await ctx.notify_event("runner_plays_event", {
				"card_id": record.id,
				"card_record": record   # Added so listeners can check subtypes (e.g. Debbie)
			}, interpreter)
	ctx.send_log("%s plays %s." % [ctx.player_name(player), record.title])
	if not ctx.simulation_mode: emit_signal("hand_changed", player)


func _do_play_from_archives(player: String, action: GameAction) -> void:
	# Petty Cash: [click] Play this operation from Archives. After it resolves, RFG it.
	var card_id: String = action.params.get("card_id", "")

	# Find the card in Archives (corp_discard)
	var record: CardRecord = null
	for cr in ctx.corp_discard:
		if (cr as CardRecord).id == card_id:
			record = cr as CardRecord
			break
	if record == null:
		ctx.send_log("play_from_archives: %s not found in Archives." % card_id)
		return

	# Pre-condition: must still be the first action this turn
	var pfa_def: Dictionary = ability_registry._abilities.get(card_id, {}) as Dictionary
	if pfa_def.get("requires_first_action_this_turn", false) and player == "corp":
		if ctx.corp_finished_an_action_this_turn:
			ctx.send_log("%s (Archives): cannot play — already finished an action this turn." % record.title)
			return

	# Spend the click
	_spend_click(player)
	ctx.send_log("%s plays %s from Archives." % [ctx.player_name(player), record.title])

	# Tag play source and ability source for downstream effects
	ctx.current_operation_play_source  = "archives"
	ctx.current_ability_source_card_type = "operation"

	# Execute on_play trigger
	var on_play_def = ability_registry.get_on_play(card_id)
	if on_play_def != null:
		await interpreter.execute_trigger(on_play_def as Dictionary, ctx)

	ctx.current_operation_play_source    = ""
	ctx.current_ability_source_card_type = ""

	# Remove from Archives and place in the RFG zone (not back to discard)
	ctx.corp_discard.erase(record)
	ctx.corp_removed_from_game.append(record)
	ctx.send_log("%s: removed from the game." % record.title)

	# Fire corp_plays_operation so identity listeners (Zwicky Group, etc.) can react
	ctx.corp_played_operation_this_turn = true
	await ctx.notify_event("corp_plays_operation", {}, interpreter)


# ── §10.5.4  Runner removes 1 tag ────────────────────────────────────────────

func _do_remove_tag() -> void:
	_spend_click("runner")
	ctx.runner_credits -= 2
	if not ctx.simulation_mode: emit_signal("credits_changed", "runner", ctx.runner_credits)
	ctx.runner_tags -= 1
	ctx.send_log("%s removes 1 tag (%d remaining). [paid 2cr]" % [
		ctx.runner_name(), ctx.runner_tags])
	await ctx.notify_event("tag_removed", {"amount": 1}, interpreter)


# ── §10.5.3  Corp trashes a tagged Runner's resource ─────────────────────────

func _do_trash_runner_resource(action: GameAction) -> void:
	_spend_click("corp")
	ctx.corp_credits -= 2
	if not ctx.simulation_mode: emit_signal("credits_changed", "corp", ctx.corp_credits)

	var iid: String = action.params.get("card_instance_id", "")
	var target: InstalledCard = null
	for r in ctx.runner_rig:
		var ic: InstalledCard = r as InstalledCard
		if ic != null and ic.runtime_instance_id == iid:
			target = ic
			break

	if target == null:
		push_error("TurnManager: trash_runner_resource — target not found: %s" % iid)
		return

	ctx.runner_rig.erase(target)
	ctx.unregister_all_card_effects(iid)
	if target.card_record != null:
		ctx.runner_discard.append(target.card_record)
		ctx.send_log("%s trashes %s. [tagged Runner, paid 2cr]" % [
			ctx.corp_name(), target.card_record.title])
	if not ctx.simulation_mode: emit_signal("hand_changed", "runner")


# ── §10.1.2  Corp purges all virus counters ───────────────────────────────────

func _do_purge_virus() -> void:
	# Costs 3 Corp clicks.
	for _i in range(3):
		_spend_click("corp")
	ctx.send_log("%s purges all virus counters." % ctx.corp_name())
	# Reuse the ability-interpreter effect so purge-reactive cards fire correctly.
	var purge_def := {"effects": [{"type": "purge_virus_counters"}]}
	await interpreter.execute_trigger(purge_def, ctx)


# ── §10.9  Run ────────────────────────────────────────────────────────────────

func _do_run(action: GameAction) -> void:
	_spend_click("runner")
	var server_id: String = action.params.get("server_id", "hq")

	# Notify Main so it can open RunScene before the run begins
	if ctx.has_meta("on_run_started"):
		var cb: Callable = ctx.get_meta("on_run_started") as Callable
		cb.call(server_id)
		if not ctx.simulation_mode:
			await Engine.get_main_loop().process_frame

	# Reuse the run_state_machine stored on ctx so RunScene stays connected
	var run: RunStateMachine
	if ctx.has_meta("run_state_machine"):
		run = ctx.get_meta("run_state_machine") as RunStateMachine
	else:
		run = RunStateMachine.new(ctx, ability_registry)
	await run.execute(server_id)
	ctx.runner_first_run_this_turn_made = true   # Front Company: first run is now done
	if ctx.run_successful:
		ctx.runner_made_successful_run_this_turn = true
		# Détente: fire once-per-turn event on first successful HQ run
		if server_id == "hq" and not ctx.runner_hq_successful_run_this_turn:
			ctx.runner_hq_successful_run_this_turn = true
			await ctx.notify_event("runner_successful_hq_run", {}, interpreter)
	# Track central servers attempted (for Red Team restriction)
	if server_id in ["hq", "rd", "archives"]:
		if server_id not in ctx.runner_centrals_run_this_turn:
			ctx.runner_centrals_run_this_turn.append(server_id)


func _do_use_installed_card(player: String, action: GameAction) -> void:
	_spend_click(player)
	var instance_id: String = action.params.get("card_instance_id", "")
	var card_id: String     = action.params.get("card_id", "")

	# Find the installed card — also checks scored agendas for Dividends / NBT click actions
	var installed: InstalledCard = null
	# duplicate() is critical: without it this is a reference alias and every
	# append_array below permanently mutates ctx.runner_rig, causing Corp server
	# cards and score-area cards to accumulate there on every use_installed_card call.
	var search_list: Array = ctx.runner_rig.duplicate() if player == "runner" else []
	for server in ctx.servers.values():
		search_list.append_array((server as Server).root)
	if player == "corp":
		search_list.append_array(ctx.corp_score_area_cards)
		# Runner's score area: Corp can use abilities on stolen agendas (e.g. Next Big Thing)
		search_list.append_array(ctx.runner_score_area_cards)
	# Note: runner_score_area_cards are deliberately NOT included for player=="runner".
	# All stolen Corp agendas have Corp-side click actions (e.g. Basalt Spire, Oracle
	# Thinktank); those are used by the Corp via the player=="corp" branch above.
	for card in search_list:
		var c: InstalledCard = card as InstalledCard
		if c == null:
			continue
		if (instance_id != "" and c.runtime_instance_id == instance_id) or \
		   (instance_id == "" and c.card_id == card_id):
			installed = c
			break

	if installed == null:
		# ── Identity fallback: check if the targeted card is the player's identity ─
		var id_record: CardRecord = ctx.runner_identity if player == "runner" else ctx.corp_identity
		var id_iid:    String     = "identity_runner"   if player == "runner" else "identity_corp"
		if id_record != null and (card_id == id_record.id or instance_id == id_iid):
			var id_def: Dictionary    = ability_registry._abilities.get(id_record.id, {}) as Dictionary
			# Prefer dedicated identity_click_action key; fall back to plain click_action so
			# identities like Synapse Global (which use click_action) work without data changes.
			var id_ca_def: Dictionary = id_def.get("identity_click_action", {}) as Dictionary
			if id_ca_def.is_empty():
				id_ca_def = id_def.get("click_action", {}) as Dictionary
			if id_ca_def.is_empty():
				ctx.send_log("use_installed_card: identity has no click action defined.")
				return
			# Optional credit cost (e.g. Vic: 1cr per use)
			var id_cc: int = id_ca_def.get("credit_cost", 0)
			if id_cc > 0:
				if ctx.get_credits(player) < id_cc:
					ctx.send_log("%s: cannot afford identity ability (need %dcr)." % [id_record.title, id_cc])
					return
				ctx.set_credits(player, ctx.get_credits(player) - id_cc)
				if not ctx.simulation_mode: emit_signal("credits_changed", player, ctx.get_credits(player))
			var id_opt_key: String = id_ca_def.get("once_per_turn_key", "")
			if id_opt_key != "":
				var id_opt_full := "%s:%s" % [id_iid, id_opt_key]
				if ctx.once_per_turn_triggered.get(id_opt_full, false):
					ctx.send_log("%s: ability can only be used once per turn." % id_record.title)
					if id_cc > 0:
						ctx.set_credits(player, ctx.get_credits(player) + id_cc)
					return
				ctx.once_per_turn_triggered[id_opt_full] = true
			ctx.current_event_data = {"card_instance_id": id_iid}
			await interpreter.execute_trigger(id_ca_def, ctx)
			ctx.current_event_data = {}
			return
		ctx.send_log("use_installed_card: card not found (%s)" % (instance_id if instance_id != "" else card_id))
		return

	# Look up click_action definition in ability registry
	var card_def: Dictionary = ability_registry._abilities.get(installed.card_id, {}) as Dictionary
	var click_action_def: Dictionary = card_def.get("click_action", {}) as Dictionary
	if click_action_def.is_empty():
		ctx.send_log("use_installed_card: %s has no click_action defined." % installed.display_name())
		return

	# Additional click costs (e.g. Rent Rioters: 3 clicks total, 1 from action + 2 more)
	var extra_clicks: int = click_action_def.get("additional_cost_clicks", 0)
	if extra_clicks > 0:
		var available: int = ctx.runner_clicks if player == "runner" else ctx.corp_clicks
		if available < extra_clicks:
			ctx.send_log("%s: not enough clicks (need %d more) — cancelling." % [installed.display_name(), extra_clicks])
			return
		for _i in range(extra_clicks):
			_spend_click(player)
		ctx.send_log("%s spends %d additional click(s) for %s." % [ctx.player_name(player), extra_clicks, installed.display_name()])

	# ── Once-per-turn guard for installed card click actions ─────────────────
	var ca_opt_key: String = click_action_def.get("once_per_turn_key", "")
	if ca_opt_key != "":
		var ca_opt_full := "%s:%s" % [installed.runtime_instance_id, ca_opt_key]
		if ctx.once_per_turn_triggered.get(ca_opt_full, false):
			ctx.send_log("%s: this ability can only be used once per turn." % installed.display_name())
			return
		ctx.once_per_turn_triggered[ca_opt_full] = true

	# ── Tag cost: Corp abilities on stolen agendas (e.g. Oracle Thinktank) ──
	# Deduct runner tags as a cost before executing the effect.
	var ca_tag_cost: int = click_action_def.get("tag_cost", 0)
	if ca_tag_cost > 0:
		ctx.runner_tags -= ca_tag_cost
		ctx.send_log("%s removes %d Runner tag(s) as a cost for %s." % [
			ctx.player_name(player), ca_tag_cost, installed.display_name()
		])

	ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
	# Tag source card type for Zwicky Group credit-gain tracking.
	if installed.card_record != null:
		ctx.current_ability_source_card_type = installed.card_record.card_type
	await interpreter.execute_trigger(click_action_def, ctx)
	ctx.current_event_data = {}
	ctx.current_ability_source_card_type = ""
	# Notify JML and similar: runner used an installed rig card's paid ability.
	if player == "runner":
		await ctx.notify_event("runner_rig_action", {
			"card": installed,
			"card_instance_id": installed.runtime_instance_id
		}, interpreter)


func _do_rez_card(player: String, action: GameAction) -> void:
	# Rezzing costs no click — it's a paid action outside the normal click economy.
	# Find the card by instance_id or card_id across all servers.
	var instance_id: String = action.params.get("card_instance_id", "")
	var card_id: String     = action.params.get("card_id", "")

	var installed: InstalledCard = null
	for server in ctx.servers.values():
		var s: Server = server as Server
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if (instance_id != "" and c.runtime_instance_id == instance_id) or \
			   (instance_id == "" and c.card_id == card_id):
				installed = c
				break
		if installed != null:
			break

	if installed == null or installed.card_record == null:
		ctx.send_log("Rez failed: card not found (%s)" % (instance_id if instance_id != "" else card_id))
		return

	# Use query_rez_cost so passive modifiers (e.g. Fransofia Ward +1) are applied.
	var rez_cost: int = ctx.query_rez_cost(installed)

	# ── Rez discount: Hype Machine — 6cr off if an agenda was scored/stolen this turn ──
	if ability_registry._abilities.has(installed.card_id):
		var tm_hm_def: Dictionary = ability_registry._abilities[installed.card_id] as Dictionary
		var tm_hm_discount: int   = int(tm_hm_def.get("rez_cost_reduction_if_agenda_scored_stolen", 0))
		if tm_hm_discount > 0 and \
				(ctx.corp_agendas_scored_this_turn > 0 or ctx.runner_stole_agenda_this_turn):
			rez_cost = max(0, rez_cost - tm_hm_discount)
			ctx.send_log("[Rez] Hype Machine: agenda scored/stolen this turn → %d cr discount (cost now %d)." % [
				tm_hm_discount, rez_cost])

	# ── Dynamic rez cost reduction per other unrezzed ice (e.g. Reverb) ──
	if ability_registry._abilities.has(installed.card_id):
		var tm_rcr_def: Dictionary = ability_registry._abilities[installed.card_id] as Dictionary
		var tm_per_unrezzed: int   = int(tm_rcr_def.get("rez_cost_reduction_per_unrezzed_ice", 0))
		if tm_per_unrezzed > 0:
			var tm_unrezzed_count := 0
			for tm_srv in ctx.servers.values():
				for tm_ice in (tm_srv as Server).ice:
					var tm_ic: InstalledCard = tm_ice as InstalledCard
					if tm_ic != null and tm_ic.runtime_instance_id != installed.runtime_instance_id and not tm_ic.is_rezzed:
						tm_unrezzed_count += 1
			rez_cost = max(0, rez_cost - tm_per_unrezzed * tm_unrezzed_count)
			if tm_unrezzed_count > 0:
				ctx.send_log("[Rez] %s: %d other unrezzed ice → %d credit discount (cost now %d)." % [
					installed.display_name(), tm_unrezzed_count, tm_per_unrezzed * tm_unrezzed_count, rez_cost])

	# ── Optional forfeit discount (e.g. Biawak: forfeit 1 agenda to pay 10cr of cost) ──
	if ability_registry._abilities.has(installed.card_id):
		var tm_card_def: Dictionary = ability_registry._abilities[installed.card_id] as Dictionary
		var tm_fd_def: Variant = tm_card_def.get("forfeit_rez_discount", null)
		if tm_fd_def != null and not ctx.corp_score_area_cards.is_empty():
			var tm_fd_amount: int = (tm_fd_def as Dictionary).get("amount", 0)
			var tm_fd_chosen: InstalledCard = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_forfeit_agenda"):
				tm_fd_chosen = await ctx.corp_decision_maker.choose_forfeit_agenda(
					ctx.corp_score_area_cards.duplicate(), ctx
				)
			if tm_fd_chosen != null:
				rez_cost = max(0, rez_cost - tm_fd_amount)
				await interpreter._forfeit_agenda(tm_fd_chosen, ctx)

		# ── Vovô Ozetti: rez discount for ice/root on the same server ───────────
		# Scan the server's root for installed cards with rez discount flags.
		var vv_server: Server = ctx.get_server(installed.server_id)
		if vv_server != null:
			for vv_root_card in vv_server.root:
				var vv_rc: InstalledCard = vv_root_card as InstalledCard
				if vv_rc == null or not vv_rc.is_rezzed:
					continue
				var vv_def: Dictionary = ability_registry._abilities.get(vv_rc.card_id, {}) as Dictionary
				# Ice rez discount (unconditional)
				var vv_ice_disc: int = int(vv_def.get("rez_discount_for_ice_on_same_server", 0))
				if vv_ice_disc > 0 and installed.zone == "ice":
					rez_cost = max(0, rez_cost - vv_ice_disc)
					ctx.send_log("[Vovô Ozetti] %s lowers rez cost by %d cr (now %d)." % [
						vv_rc.display_name(), vv_ice_disc, rez_cost])
				# Root card rez discount (Threat 4 only)
				if installed.zone == "root" and installed.runtime_instance_id != vv_rc.runtime_instance_id:
					var vv_root_disc_def: Variant = vv_def.get("rez_discount_for_root_on_same_server", null)
					if vv_root_disc_def != null:
						var vv_root_disc_amount: int = 0
						var vv_root_disc_cond: Dictionary = {}
						if vv_root_disc_def is Dictionary:
							vv_root_disc_amount = int((vv_root_disc_def as Dictionary).get("amount", 0))
							vv_root_disc_cond   = (vv_root_disc_def as Dictionary).get("condition", {}) as Dictionary
						elif vv_root_disc_def is int:
							vv_root_disc_amount = int(vv_root_disc_def)
						var vv_cond_ok: bool = true
						if not vv_root_disc_cond.is_empty():
							var vv_cond_type: String = vv_root_disc_cond.get("type", "")
							var vv_cond_val: int     = int(vv_root_disc_cond.get("params", {}).get("value", 0))
							if vv_cond_type == "threat_gte":
								vv_cond_ok = ctx.threat_level() >= vv_cond_val
						if vv_cond_ok and vv_root_disc_amount > 0:
							rez_cost = max(0, rez_cost - vv_root_disc_amount)
							ctx.send_log("[Vovô Ozetti] Threat 4 — lowers root rez cost by %d cr (now %d)." % [
								vv_root_disc_amount, rez_cost])

		# ── Mandatory additional rez cost (e.g. Plutus: forfeit agenda OR reveal+trash 3 HQ) ──
		var tm_arc_def: Variant = tm_card_def.get("additional_rez_cost", null)
		if tm_arc_def != null:
			var tm_arc_type: String = (tm_arc_def as Dictionary).get("type", "")
			if tm_arc_type == "forfeit_or_reveal_trash_hq":
				var tm_reveal_count: int  = (tm_arc_def as Dictionary).get("reveal_trash_count", 3)
				var tm_can_forfeit: bool  = not ctx.corp_score_area_cards.is_empty()
				var tm_can_reveal: bool   = ctx.corp_hand.size() >= tm_reveal_count
				if not tm_can_forfeit and not tm_can_reveal:
					ctx.send_log("Rez failed: %s cannot pay additional rez cost." % installed.display_name())
					return
				var tm_arc_chosen: InstalledCard = null
				if tm_can_forfeit and ctx.corp_decision_maker != null and \
						ctx.corp_decision_maker.has_method("choose_forfeit_agenda"):
					tm_arc_chosen = await ctx.corp_decision_maker.choose_forfeit_agenda(
						ctx.corp_score_area_cards.duplicate(), ctx
					)
				if tm_arc_chosen != null:
					await interpreter._forfeit_agenda(tm_arc_chosen, ctx)
				elif tm_can_reveal:
					ctx.send_log("%s reveals and trashes %d card(s) from HQ for %s." % [
						ctx.corp_name(), tm_reveal_count, installed.display_name()
					])
					for _tm_i in range(min(tm_reveal_count, ctx.corp_hand.size())):
						var tm_entry: Dictionary = ctx.corp_hand.pop_back() as Dictionary
						var tm_record: CardRecord = tm_entry.get("card_record", null) as CardRecord
						if tm_record != null:
							ctx.corp_discard.append(tm_record)
							ctx.corp_discard_facedown[tm_record.title] = true
							ctx.send_log("  %s revealed and trashed from HQ." % tm_record.title)
				else:
					ctx.send_log("Rez failed: %s cannot pay additional rez cost." % installed.display_name())
					return

			# ── Valentão: take 1 bad pub OR remove 1 Runner tag ──────────────────
			elif tm_arc_type == "bad_pub_or_remove_runner_tag":
				# Corp must pay one option. Remove tag only available if runner has tags.
				var vm_can_tag: bool = ctx.runner_tags > 0
				var vm_take_bad_pub: bool = true  # Corp can always take bad pub
				if vm_can_tag and ctx.corp_decision_maker != null and \
						ctx.corp_decision_maker.has_method("choose_optional_ability"):
					# true = remove runner tag (preferred), false = take bad pub
					var vm_prefer_tag: bool = await ctx.corp_decision_maker.choose_optional_ability(
						"Valentão rez cost: remove 1 Runner tag (or take 1 bad pub)?", ctx)
					vm_take_bad_pub = not vm_prefer_tag
				elif vm_can_tag:
					vm_take_bad_pub = false  # AI: prefer removing a Runner tag
				if vm_take_bad_pub:
					ctx.corp_bad_pub += 1
					ctx.send_log("[Valentão] %s takes 1 bad publicity as rez cost. (%d total)" % [
						ctx.corp_name(), ctx.corp_bad_pub])
					await ctx.notify_event("corp_gains_bad_pub", {"amount": 1}, interpreter)
				else:
					ctx.runner_tags -= 1
					ctx.send_log("[Valentão] %s removes 1 Runner tag as rez cost. (%d remaining)" % [
						ctx.corp_name(), ctx.runner_tags])
					await ctx.notify_event("tag_removed", {"amount": 1}, interpreter)

	if player == "corp":
		# Corp may supplement with Mahkota Langit Grid recurring credits on the same server
		if ctx.corp_rez_credits_available(installed.server_id) < rez_cost:
			ctx.send_log("Cannot afford to rez %s (costs %d, have %d)." % [
				installed.display_name(), rez_cost, ctx.corp_rez_credits_available(installed.server_id)
			])
			return
		ctx.corp_spend_for_rez(rez_cost, installed.server_id)
	else:
		var credits: int = ctx.runner_credits
		if credits < rez_cost:
			ctx.send_log("Cannot afford to rez %s (costs %d, have %d)." % [installed.display_name(), rez_cost, credits])
			return
		ctx.runner_credits -= rez_cost

	installed.is_rezzed = true
	var _is_ice_rez: bool = installed.card_record != null and installed.card_record.is_ice()
	if _is_ice_rez:
		ctx.ice_rezzed_this_turn = true
	# Track all cards rezzed this turn by IID (Cloud Eater, Lightning Lab).
	if installed.runtime_instance_id != "":
		ctx.ice_rezzed_this_turn_instance_ids.append(installed.runtime_instance_id)
	_register_card_listeners(installed)

	var on_rez_def = ability_registry.get_on_rez(installed.card_id)
	if on_rez_def != null:
		ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
		await interpreter.execute_trigger(on_rez_def as Dictionary, ctx)
		ctx.current_event_data = {}

	ctx.send_log("%s rezzes %s for %d cr." % [ctx.player_name(player), installed.display_name(), rez_cost])
	if not ctx.simulation_mode: emit_signal("card_installed", installed.card_record, installed.server_id)
	# Notify listeners that a corp card was rezzed.
	await ctx.notify_event("corp_rezzes_card", {
		"card": installed,
		"card_instance_id": installed.runtime_instance_id
	}, interpreter)
	# Also fire corp_rezzes_ice so assets like Cybersand Harvester react to out-of-run rezzes.
	if _is_ice_rez:
		await ctx.notify_event("corp_rezzes_ice", {
			"ice": installed,
			"card_instance_id": installed.runtime_instance_id
		}, interpreter)


func _do_end_turn(player: String) -> void:
	if player == "corp":
		await ctx.notify_event("corp_turn_end", {}, interpreter)
		ctx.corp_clicks = 0
	else:
		await ctx.notify_event("runner_turn_end", {}, interpreter)
		ctx.runner_clicks = 0
	ctx.send_log("%s ends their turn." % ctx.player_name(player))


# ── Win condition checking ────────────────────────────────────────────────────

func _check_win_conditions() -> void:
	if ctx.game_over:
		# A subsystem (e.g. RunStateMachine._steal_agenda) set ctx.game_over directly
		# without going through _end_game(), so the signal was never emitted.
		# Catch that here and emit exactly once.
		if not _game_over_signaled:
			_game_over_signaled = true
			var reason := ""
			if ctx.winner == "runner":
				reason = "%s stole enough agendas to win" % ctx.runner_name()
			elif ctx.winner == "corp":
				reason = "%s wins" % ctx.corp_name()
			ctx.send_log("Game over — %s wins. %s" % [ctx.player_name(ctx.winner), reason])
			if not ctx.simulation_mode: emit_signal("game_over", ctx.winner, reason)
		return

	# Assassination win — 3 assassination agendas in runner score area (Jeitinho)
	if ctx.runner_assassination_agendas >= 3:
		_end_game("runner", "%s assembled 3 assassination agendas" % ctx.runner_name())
		return

	# Agenda point victory
	if ctx.corp_agenda_points() >= agenda_points_to_win:
		_end_game("corp", "%s scored %d agenda points" % [ctx.corp_name(), ctx.corp_agenda_points()])
		return
	if ctx.runner_agenda_points() >= agenda_points_to_win:
		_end_game("runner", "%s scored %d agenda points" % [ctx.runner_name(), ctx.runner_agenda_points()])
		return

	# Flatline — runner has no cards in grip
	if ctx.runner_hand.is_empty() and ctx.active_player == "runner":
		_end_game("corp", "\"%s\" flatlined (empty grip)" % ctx.runner_name())
		return


func _end_game(winner: String, reason: String) -> void:
	ctx.game_over = true
	ctx.winner    = winner
	ctx.send_log("Game over — %s wins. %s" % [ctx.player_name(winner), reason])
	if not _game_over_signaled:
		_game_over_signaled = true
		if not ctx.simulation_mode: emit_signal("game_over", winner, reason)


# ── Agenda scoring ────────────────────────────────────────────────────────────

func _register_scored_agenda_listeners(card: InstalledCard) -> void:
	# Register ongoing event triggers for a Corp-scored agenda that lives in the
	# Corp's score area.  These cover abilities that fire each turn (e.g. Lightning
	# Laboratory: run_start → free rez; corp_turn_end → derez those ice) or that
	# need click_action support (e.g. Basalt Spire counter ability).
	var instance_id: String  = card.runtime_instance_id if card.runtime_instance_id != "" else card.card_id
	var card_def: Dictionary = ability_registry._abilities.get(card.card_id, {}) as Dictionary
	if card_def.is_empty():
		return
	for event_type in [
			"corp_turn_start", "runner_turn_start", "corp_turn_end", "runner_turn_end",
			"run_start", "successful_run", "breach_complete", "runner_steals_agenda",
			"runner_takes_tags", "corp_scores_agenda", "runner_trashes_during_breach",
			"before_breach", "card_accessed_event"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)


func _score_agenda(card: InstalledCard) -> void:
	var record: CardRecord = card.card_record

	# A Teia: IP Recovery — cannot score a card that was freely installed this turn.
	if card.runtime_instance_id in ctx.a_teia_free_installed_instance_ids:
		ctx.send_log("[A Teia] %s cannot be scored this turn — it was freely installed by A Teia's ability." % \
			record.title)
		return

	ctx.send_log("%s scores %s! (%d agenda points)" % [ctx.corp_name(), record.title, record.agenda_points])
	ctx.corp_score_area.append(record)
	# Also keep the InstalledCard so Dividends effects can access counters on the scored card
	ctx.corp_score_area_cards.append(card)
	ctx.corp_last_scored_agenda_points  = record.agenda_points
	ctx.corp_agendas_scored_this_turn  += 1
	# Myōshu play condition: track if any scored agenda was NOT installed this turn.
	if not ctx.corp_installed_this_turn.has(record.id):
		ctx.corp_scored_agenda_not_installed_this_turn = true

	# Remove from server
	var server: Server = ctx.get_server(card.server_id)
	if server:
		server.remove_from_root(card)
		ctx.remove_empty_remote_servers()

	# Calculate excess advancement counters for the Dividends mechanic.
	# Excess = counters beyond the printed requirement at the moment of scoring.
	var excess: int = max(0, card.get_counter("advancement") - record.advancement_requirement)

	# Fire on_score ability of the scored agenda.
	# Set current_event_data so effects like place_dividend_counters can read the
	# scored card's instance_id and the excess advancement count.
	var on_score_def = ability_registry.get_on_score(record.id)
	if on_score_def != null:
		ctx.current_event_data = {
			"card": card,
			"card_instance_id": card.runtime_instance_id,
			"excess_advancement": excess
		}
		ctx.current_ability_source_card_type = "agenda"
		await interpreter.execute_trigger(on_score_def as Dictionary, ctx)
		ctx.current_event_data = {}
		ctx.current_ability_source_card_type = ""

	# Register ongoing event listeners for the scored agenda's ongoing abilities
	# (e.g. Lightning Lab run_start, corp_turn_end; Basalt Spire click_action).
	_register_scored_agenda_listeners(card)

	# Broadcast so runner cards (e.g. Pantograph) and corp ICE (e.g. Lamplighter) can respond.
	# server_id is still valid on the InstalledCard even after removal from the server array.
	await ctx.notify_event("corp_scores_agenda", {
		"agenda_id":    record.id,
		"agenda_points": record.agenda_points,
		"server_id":    card.server_id
	}, interpreter)

	# Check win condition immediately — Corp may have won by scoring
	_check_win_conditions()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _spend_click(player: String) -> void:
	if player == "corp":
		ctx.corp_clicks   = max(0, ctx.corp_clicks - 1)
	else:
		ctx.runner_clicks = max(0, ctx.runner_clicks - 1)


func _remove_from_hand(player: String, record: CardRecord) -> void:
	var hand: Array = ctx.corp_hand if player == "corp" else ctx.runner_hand
	for i in range(hand.size()):
		var entry: Dictionary = hand[i] as Dictionary
		if entry.get("card_id", "") == record.id:
			hand.remove_at(i)
			return
	# Not found in hand — check faceup-hosted cards on rig (Bling, Madani, etc.)
	if player == "runner":
		for rig_c in ctx.runner_rig:
			var ic: InstalledCard = rig_c as InstalledCard
			if ic == null:
				continue
			for i in range(ic.faceup_hosted_cards.size()):
				var cr: CardRecord = ic.faceup_hosted_cards[i] as CardRecord
				if cr != null and cr.id == record.id:
					ic.faceup_hosted_cards.remove_at(i)
					return


func _register_identity_listeners(instance_id: String, card_id: String) -> void:
	if card_id == "":
		return
	var card_def: Dictionary = ability_registry._abilities.get(card_id, {}) as Dictionary
	if card_def.is_empty():
		return
	for event_type in ["corp_turn_start", "runner_turn_start", "corp_turn_end", "runner_turn_end",
					"encounter_ice", "encounter_ended", "pass_ice", "successful_run", "approach_server",
					"run_end", "on_derez", "corp_scores_agenda", "runner_steals_agenda",
					"before_breach", "runner_trashes_during_breach", "runner_installs_virus",
					"on_advance", "breach_complete", "run_start", "runner_takes_tags",
					"corp_plays_operation", "corp_rezzes_ice", "corp_rezzes_card",
					"runner_discards_to_hand_limit", "corp_discard_phase_ends",
					"runner_discard_phase_ends",
					"tag_removed", "corp_gains_credits_via_ability",
					"archives_cards_turned_faceup", "runner_plays_event",
					"hardware_trashed", "runner_installs_card",
					"runner_spends_outside_credits", "corp_gains_bad_pub",
					"runner_action_phase_ends", "melies_u_flipped",
					"runner_rig_action", "card_accessed_event"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)
	# Aliases: some older abilities.json entries use "on_" prefix keys.
	for _id_alias in [["on_successful_run", "successful_run"], ["on_breach", "breach_complete"]]:
		var _id_alias_def = card_def.get(_id_alias[0], null)
		if _id_alias_def != null:
			ctx.register_listener(_id_alias[1], instance_id, _id_alias_def as Dictionary)

	var id_modifiers: Array = card_def.get("passive_modifiers", []) as Array
	for mod in id_modifiers:
		var mod_dict: Dictionary = mod as Dictionary
		var extra := {}
		for key in ["card_id", "method"]:
			if mod_dict.has(key):
				extra[key] = mod_dict[key]
		ctx.register_modifier(
			mod_dict.get("type", ""),
			instance_id,
			mod_dict.get("value", 0),
			mod_dict.get("conditions", {}) as Dictionary,
			extra
		)


func _register_card_listeners(installed: InstalledCard) -> void:
	# Register all event listeners and passive modifiers for this card.
	# Uses instance_id so effects can be cleaned up when the card leaves play.
	var instance_id: String = installed.runtime_instance_id if installed.runtime_instance_id != "" else installed.card_id
	var card_id: String     = installed.card_id
	var card_def: Dictionary = ability_registry._abilities.get(card_id, {}) as Dictionary

	# Register triggered event listeners
	for event_type in ["corp_turn_start", "runner_turn_start", "corp_turn_end", "runner_turn_end",
						"approach_ice", "encounter_ice", "encounter_ended", "pass_ice", "successful_run",
						"approach_server", "run_end", "on_derez",
						"corp_scores_agenda", "runner_steals_agenda", "runner_trashes_during_breach",
						"before_breach", "before_access", "runner_installs_virus", "runner_installs_card",
						"runner_successful_hq_run",
						"on_advance", "breach_complete", "run_start",
						"corp_discard_phase_ends", "runner_discard_phase_ends",
						"archives_cards_turned_faceup", "runner_plays_event",
						"hardware_trashed", "runner_spends_outside_credits", "corp_gains_bad_pub",
						"runner_action_phase_ends", "melies_u_flipped",
						"tag_removed", "corp_purges_virus_counters", "corp_rezzes_card",
						"corp_rezzes_ice", "runner_takes_tags", "runner_rig_action",
						"card_accessed_event", "wage_workers_threshold",
						"runner_bypasses_ice",
						"runner_installs_program", "corp_installs_in_root"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)
	# Aliases: some abilities.json entries use "on_" prefix or alternative key names.
	for _rc_alias in [["on_successful_run", "successful_run"], ["on_breach", "breach_complete"]]:
		var _rc_alias_def = card_def.get(_rc_alias[0], null)
		if _rc_alias_def != null:
			ctx.register_listener(_rc_alias[1], instance_id, _rc_alias_def as Dictionary)

	# Register passive modifiers (e.g. Turbine's breaker_strength boost, Echelon's dynamic strength)
	var modifiers: Array = card_def.get("passive_modifiers", []) as Array
	for mod in modifiers:
		var mod_dict: Dictionary = mod as Dictionary
		var extra := {}
		# Pass through any extra fields needed by dynamic modifiers
		for key in ["card_id", "method"]:
			if mod_dict.has(key):
				extra[key] = mod_dict[key]
		# Server-scoped modifiers (e.g. Mahkota recurring credits) carry the owning card's server_id
		if mod_dict.get("server_scoped", false):
			extra["server_id"] = installed.server_id
		ctx.register_modifier(
			mod_dict.get("type", ""),
			instance_id,
			mod_dict.get("value", 0),
			mod_dict.get("conditions", {}) as Dictionary,
			extra
		)


func _find_advanceable_card(card_id: String) -> InstalledCard:
	for server in ctx.servers.values():
		var s: Server = server as Server
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c.card_id == card_id and c.can_be_advanced():
				return c
	return null
