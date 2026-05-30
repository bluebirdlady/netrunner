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
	ctx.corp_gained_advance_credits_this_turn = false   # reset for Built to Last
	ctx.corp_finished_an_action_this_turn     = false   # reset for Petty Cash condition
	ctx.corp_played_operation_this_turn = false          # reset for Nebula Making Stars
	ctx.corp_last_scored_agenda_points = 0              # reset for Neurospike
	ctx.corp_agendas_scored_this_turn  = 0              # reset for first-agenda triggers
	ctx.ice_rezzed_this_turn           = false          # reset for Underdome Irregulars
	ctx.doubles_played_this_turn       = 0              # reset for Synchrocyclotron
	ctx.corp_scored_agenda_not_installed_this_turn = false   # reset for Myōshu
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
	var did_discard := false
	while ctx.corp_hand.size() > ctx.corp_max_hand_size() and not ctx.game_over:
		# Discard the last card (AI discards from the end for simplicity)
		var discarded: Dictionary = ctx.corp_hand.pop_back() as Dictionary
		var record: CardRecord    = discarded.get("card_record", null) as CardRecord
		ctx.corp_discard.append(record)
		if record != null:
			ctx.corp_discard_facedown[record.title] = true   # hand discards always facedown
		ctx.send_log("%s discards %s to hand limit." % [ctx.corp_name(), record.title if record else "?"])
		did_discard = true
	ctx.corp_discarded_to_hand_limit_last_turn = did_discard
	if not ctx.simulation_mode: emit_signal("hand_changed", "corp")


func _runner_discard_to_hand_limit() -> void:
	var limit: int = ctx.runner_max_hand_size()
	if limit < 0:
		# Already flatlined from core damage — nothing to do
		return
	var discarded_records: Array = []
	while ctx.runner_hand.size() > limit and not ctx.game_over:
		# Human runner picks which card to discard; AI discards from the end for simplicity
		var discarded: Dictionary = ctx.runner_hand.pop_back() as Dictionary
		var record: CardRecord    = discarded.get("card_record", null) as CardRecord
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
	ctx.runner_trashed_during_breach_this_turn = false  # reset each turn (Loup)
	ctx.runner_program_install_discounted_this_turn = false  # reset each turn (DZMZ)
	ctx.runner_carnivore_used_this_turn = false              # reset each turn
	ctx.runner_stole_agenda_this_turn  = false               # reset each turn (Hype Machine)
	ctx.runner_successful_run_on_rd_this_turn       = false  # reset each turn (VP1 Chain Reaction)
	ctx.runner_successful_run_on_archives_this_turn = false  # reset each turn (VP1 Chain Reaction)
	ctx.once_per_turn_triggered.clear()                      # reset per-turn trigger guards
	if runner_penalty > 0:
		ctx.send_log("%s loses %d click(s) this turn (deferred penalty)." % [ctx.runner_name(), runner_penalty])
	ctx.turn_number   += 1

	if not ctx.simulation_mode: emit_signal("turn_started", "runner", ctx.turn_number)
	ctx.send_log("=== %s Turn %d begins. Credits: %d, Clicks: %d ===" % [
		ctx.runner_name(), ctx.turn_number, ctx.runner_credits, ctx.runner_clicks
	])
	# Fire start-of-turn triggers (resources, hardware, etc.)
	await ctx.notify_event("runner_turn_start", {}, interpreter)

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
			break

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
		"end_turn":           await _do_end_turn(player)
		_:
			return {"ok": false, "reason": "Unknown action type: %s" % action.type}

	# Mark that the Corp has completed a click action this turn (Petty Cash condition).
	# rez_card and pass are not click-costing actions — everything else is.
	if player == "corp" and action.type not in ["rez_card", "pass", "end_turn"]:
		ctx.corp_finished_an_action_this_turn = true

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

		_:
			return {"ok": false, "reason": "Unknown action type: %s" % action.type}


# ── Action implementations ────────────────────────────────────────────────────

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

		# ── Hosted install credits (e.g. Open Market: credits for connection/job installs) ──
		# Find the first rig card whose install_credits_for_subtypes list contains
		# any subtype of the card being installed. Its hosted credits supplement
		# runner_credits for the affordability check and are drawn down first.
		var om_source: InstalledCard = null
		var om_available: int = 0
		for rig_c in ctx.runner_rig:
			var rc: InstalledCard = rig_c as InstalledCard
			if rc == null:
				continue
			var rc_def: Dictionary = ability_registry._abilities.get(rc.card_id, {}) as Dictionary
			var allowed_sts: Array = rc_def.get("install_credits_for_subtypes", []) as Array
			if allowed_sts.is_empty():
				continue
			for st in allowed_sts:
				if record.has_subtype(st as String):
					om_source    = rc
					om_available = rc.get_counter("credits")
					break
			if om_source != null:
				break

		if ctx.runner_credits + om_available < pay_cost:
			ctx.send_log("%s cannot afford to install %s." % [ctx.runner_name(), record.title])
			return

		# Spend hosted credits first, then top up from runner's pool
		var om_used: int = 0
		if om_source != null and om_available > 0:
			om_used = min(pay_cost, om_available)
			om_source.remove_counter("credits", om_used)
			ctx.send_log("%s: %d hosted cr from %s used for %s (%d remaining)." % [
				ctx.runner_name(), om_used, om_source.display_name(),
				record.title, om_source.get_counter("credits")
			])
		ctx.runner_credits -= (pay_cost - om_used)

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
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_host_ice"):
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
		# Fire runner_installs_card for Bling and similar triggers
		await ctx.notify_event("runner_installs_card", {
			"credits_paid": pay_cost - om_used,
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
		server = ctx.create_remote_server()
		server_id = server.server_id

	# Pay ice install cost
	if record.is_ice():
		var ice_cost: int = server.ice_install_cost()
		ctx.set_credits(player, ctx.get_credits(player) - ice_cost)
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
		ctx.send_log("%s trashes %s as an additional cost." % [ctx.runner_name(), op_tc_target.display_name()])

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
			await ctx.notify_event("runner_plays_event", {"card_id": record.id}, interpreter)
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
	var search_list: Array = ctx.runner_rig if player == "runner" else []
	for server in ctx.servers.values():
		search_list.append_array((server as Server).root)
	if player == "corp":
		search_list.append_array(ctx.corp_score_area_cards)
		# Runner's score area: Corp can use abilities on stolen agendas (e.g. Next Big Thing)
		search_list.append_array(ctx.runner_score_area_cards)
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
			var id_ca_def: Dictionary = id_def.get("identity_click_action", {}) as Dictionary
			if id_ca_def.is_empty():
				ctx.send_log("use_installed_card: identity has no identity_click_action defined.")
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

	ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
	# Tag source card type for Zwicky Group credit-gain tracking.
	if installed.card_record != null:
		ctx.current_ability_source_card_type = installed.card_record.card_type
	await interpreter.execute_trigger(click_action_def, ctx)
	ctx.current_event_data = {}
	ctx.current_ability_source_card_type = ""


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
	if installed.card_record != null and installed.card_record.is_ice():
		ctx.ice_rezzed_this_turn = true
	_register_card_listeners(installed)

	var on_rez_def = ability_registry.get_on_rez(installed.card_id)
	if on_rez_def != null:
		ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
		await interpreter.execute_trigger(on_rez_def as Dictionary, ctx)
		ctx.current_event_data = {}

	ctx.send_log("%s rezzes %s for %d cr." % [ctx.player_name(player), installed.display_name(), rez_cost])
	if not ctx.simulation_mode: emit_signal("card_installed", installed.card_record, installed.server_id)


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

func _score_agenda(card: InstalledCard) -> void:
	var record: CardRecord = card.card_record
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
					"corp_plays_operation", "corp_rezzes_ice",
					"runner_discards_to_hand_limit", "corp_discard_phase_ends",
					"runner_discard_phase_ends",
					"tag_removed", "corp_gains_credits_via_ability",
				"archives_cards_turned_faceup", "runner_plays_event"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)

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
						"before_breach", "runner_installs_virus", "runner_installs_card",
						"runner_successful_hq_run",
						"on_advance", "breach_complete", "run_start",
						"corp_discard_phase_ends", "runner_discard_phase_ends",
						"archives_cards_turned_faceup", "runner_plays_event"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)

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
