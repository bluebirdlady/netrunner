class_name RunStateMachine
extends RefCounted

# ── RunStateMachine ───────────────────────────────────────────────────────────
# Drives a single run from initiation through to the End phase.
# Owns no game state — reads and writes a GameContext.
# Fires the AbilityInterpreter at the correct timing windows.
# Asks decision_makers for Corp and Runner choices.

enum Phase {
	INITIATION,
	APPROACH_ICE,
	ENCOUNTER_ICE,
	MOVEMENT,
	SUCCESS,
	END,
}

var ctx:              GameContext
var ability_registry: AbilityRegistry
var interpreter:      AbilityInterpreter

# Run position tracking
var _target_server:   Server       = null
var _ice_positions:   Array        = []   # ordered ice, outermost first
var _ice_index:       int          = 0    # current position in _ice_positions
var _current_phase:   Phase        = Phase.INITIATION
var _has_passed_ice:  bool         = false  # NSG 6.5.4: jack-out only after passing ice

# Signals — the UI listens to these to update the display
signal phase_changed(phase: Phase)
signal ice_approached(ice_card: InstalledCard)
signal ice_encountered(ice_card: InstalledCard)
signal ice_rezzed(ice_card: InstalledCard)
signal subroutine_resolving(ice_card: InstalledCard, sub_index: int, sub_def: Dictionary)
signal subroutine_broken(ice_card: InstalledCard, sub_index: int)
signal encounter_started(encounter: EncounterState)
signal encounter_updated(encounter: EncounterState)
signal run_succeeded(server_id: String)
signal run_ended_unsuccessfully(reason: String)
signal card_accessed(card_record: CardRecord, outcome: String)

# Structural window notifications for UI state synchronization
signal timing_window_opened(priority_actor: String)
signal timing_window_closed()


# ── Construction ──────────────────────────────────────────────────────────────

func _init(game_ctx: GameContext, ab_registry: AbilityRegistry) -> void:
	ctx              = game_ctx
	ability_registry = ab_registry
	interpreter      = AbilityInterpreter.new()


# ── Entry point ───────────────────────────────────────────────────────────────

func execute(server_id: String) -> void:
	var server := ctx.get_server(server_id)
	if server == null:
		push_error("RunStateMachine: unknown server '%s'" % server_id)
		return

	_target_server  = server
	_ice_positions  = server.ice.duplicate()  # snapshot at run start
	_ice_index      = 0
	_has_passed_ice = false

	ctx.run_active        = true
	ctx.run_ended         = false
	ctx.run_successful    = false
	ctx.run_target_server = server_id
	ctx.runner_stole_agenda_this_run = false   # reset for AMAZE Amusements
	ctx.run_accessed_archives_card_ids = []    # reset for Charm Offensive
	ctx.run_level_strength_boosts      = {}    # reset for GAMEDRAGON Pro pump persistence
	ctx.run_had_subroutine_resolve            = false # reset for Ryo "Phoenix" Ōno
	ctx.runner_cannot_steal_or_trash_this_run = false # reset for VP31 Vertigo
	ctx.global_ice_strength_bonus_this_run    = 0     # reset for VP39 ezaM
	ctx.beta_build_installed_card_id          = ""    # reset for VP19 Beta Build
	ctx.runner_steal_trash_blocked_card_ids   = []    # reset for VP35 Perfect Recall
	ctx.run_success_suppressed                = false  # reset for VP64 Flagship
	ctx.runner_outside_credits_spent_pending  = 0     # reset for VP65 Shackleton Grid

	ctx.send_log("--- Run on %s begins ---" % server.display_name())
	await _phase_initiation()


# ── Phase 1: Initiation ───────────────────────────────────────────────────────

func _phase_initiation() -> void:
	_set_phase(Phase.INITIATION)
	ctx.send_log("[Initiation] Run declared on %s." % _target_server.display_name())

	# Notify structural event hooks that a run has commenced
	await ctx.notify_event("run_start", {"server_id": _target_server.server_id}, interpreter)

	# NSG 6.5.1.c: Paid Ability Window opens during Initiation before the first approach
	await _execute_paid_ability_and_rez_window(false)

	if ctx.run_ended:
		await _phase_end()
		return

	if _apply_run_position_reset():
		if _ice_positions.is_empty():
			await _phase_movement()
		else:
			await _phase_approach_ice()
		return

	if _ice_positions.is_empty():
		ctx.send_log("[Initiation] No ice protecting server — proceeding to root.")
		await _phase_movement()
	else:
		await _phase_approach_ice()


# ── Phase 2: Approach Ice ─────────────────────────────────────────────────────

func _phase_approach_ice() -> void:
	_set_phase(Phase.APPROACH_ICE)
	var ice_card: InstalledCard = _ice_positions[_ice_index]
	ctx.send_log("[Approach] Runner approaches %s (position %d)." % [
		ice_card.display_name() if ice_card.is_rezzed else "unrezzed ice",
		_ice_index
	])
	emit_signal("ice_approached", ice_card)

	# 1. Notify listeners that ice is approached (e.g., dynamic environmental modifiers)
	await ctx.notify_event("approach_ice", {"ice": ice_card}, interpreter)

	# Mitra Aman (and similar effects) may swap this ice with a central-server ice.
	# The effect stores the replacement in ctx meta so we can update our snapshot here.
	if ctx.has_meta("run_ice_swapped"):
		var swapped_in: InstalledCard = ctx.get_meta("run_ice_swapped") as InstalledCard
		ctx.remove_meta("run_ice_swapped")
		if swapped_in != null:
			_ice_positions[_ice_index] = swapped_in
			ice_card = swapped_in
			ctx.send_log("[Approach] Ice replaced — runner now approaches %s." % \
				(ice_card.display_name() if ice_card.is_rezzed else "unrezzed ice"))
			emit_signal("ice_approached", ice_card)

	# 2. Open a structural priority-passing window where players can use abilities or rez ice
	await _execute_paid_ability_and_rez_window(true)

	if ctx.run_ended:
		await _phase_end()
		return

	if _apply_run_position_reset():
		if _ice_positions.is_empty():
			await _phase_movement()
		else:
			await _phase_approach_ice()
		return

	if ice_card.is_rezzed:
		await _phase_encounter_ice(ice_card)
	else:
		ctx.send_log("[Approach] Corp declines to rez. Runner passes unrezzed ice.")
		await _phase_movement()


# ── Phase 3: Encounter Ice ────────────────────────────────────────────────────

func _phase_encounter_ice(ice_card: InstalledCard) -> void:
	_set_phase(Phase.ENCOUNTER_ICE)
	ctx.send_log("[Encounter] Runner encounters %s." % ice_card.display_name())
	emit_signal("ice_encountered", ice_card)

	# Notify encounter hooks (e.g. Tithe's on_encounter credit gain)
	await ctx.notify_event("encounter_ice", {"ice": ice_card}, interpreter)

	if ctx.run_ended:
		await _phase_end()
		return

	# Bypass: runner ability set this flag during encounter_ice — skip subroutines entirely
	if ctx.run_modifiers.get("bypass_current_ice", false):
		ctx.run_modifiers.erase("bypass_current_ice")
		ctx.send_log("[Bypass] %s is bypassed — subroutines do not fire." % ice_card.display_name())
		await _phase_movement()
		return

	# Tracks whether all subroutines on this ice were broken (for Sipa pass_ice condition).
	# Default true — blank ice has zero subs, so vacuously all are "broken".
	var _all_subs_broken_for_pass: bool = true

	var subroutines: Array = ability_registry.get_subroutines_for_card(ice_card.card_id, ice_card)
	if subroutines.is_empty():
		ctx.send_log("[Encounter] %s has no implemented subroutines — treating as blank." % ice_card.display_name())
		# Still open a PAW even for blank ice
		await _execute_paid_ability_and_rez_window(false)
		# Proprionegation may have fired during the blank-ice PAW
		if _apply_run_position_reset():
			if _ice_positions.is_empty():
				await _phase_movement()
			else:
				await _phase_approach_ice()
			return
	else:
		var encounter := EncounterState.make(ice_card, subroutines, ctx.all_programs_for_encounter(ice_card), ctx)
		# Apply global ICE strength bonus for this run (VP39 ezaM sub 2)
		if ctx.global_ice_strength_bonus_this_run != 0:
			encounter.ice_strength += ctx.global_ice_strength_bonus_this_run
		# Semak-samun style: restrict subroutine breaking to fracters only (AI excluded)
		if ability_registry.get_flag(ice_card.card_id, "fracter_only_break"):
			encounter.fracter_only_break = true
		emit_signal("encounter_started", encounter)

		# NSG 6.5.3.b: symmetric PAW — both players use paid abilities; runner may also break subs
		await _execute_encounter_window(encounter)

		# ezaM paw_action: Corp swapped this ice mid-encounter — update position snapshot
		if ctx.has_meta("enc_swap_ice"):
			var esw_swapped_in: InstalledCard = ctx.get_meta("enc_swap_ice") as InstalledCard
			ctx.remove_meta("enc_swap_ice")
			if esw_swapped_in != null:
				_ice_positions[_ice_index] = esw_swapped_in

		if ctx.run_ended:
			await _phase_end()
			return

		# Proprionegation may have fired during the encounter window
		if _apply_run_position_reset():
			if _ice_positions.is_empty():
				await _phase_movement()
			else:
				await _phase_approach_ice()
			return

		# Resolve unbroken subroutines
		for i in range(subroutines.size()):
			if encounter.is_broken(i):
				ctx.send_log("[Encounter] Subroutine %d broken." % i)
				emit_signal("subroutine_broken", ice_card, i)
				continue

			emit_signal("subroutine_resolving", ice_card, i, subroutines[i] as Dictionary)
			ctx.run_had_subroutine_resolve = true   # Ryo "Phoenix" Ōno: a subroutine is resolving
			# Set event_data so self-referencing subroutine effects (e.g. place_virus_counter_on_self)
			# can find the ice card by instance_id.
			ctx.current_event_data = {"card": ice_card, "card_instance_id": ice_card.runtime_instance_id}
			await interpreter.execute_subroutine(subroutines[i] as Dictionary, ctx)
			ctx.current_event_data = {}

			if ctx.run_ended:
				# ── Shred: first ETR during this run may be prevented ────────────────
				if ctx.run_modifiers.get("prevent_first_etr", 0) > 0:
					ctx.run_modifiers.erase("prevent_first_etr")
					var shred_prevented: bool = await _shred_check_etr_prevention()
					if shred_prevented:
						ctx.run_ended = false
						continue   # ETR negated — proceed to next subroutine
					# else: Corp paid the cost — ETR stands
				# ── End Shred check ──────────────────────────────────────────────────
				ctx.send_log("[Encounter] Run ended by subroutine.")
				# Fire encounter_ended so post-encounter triggers can react (e.g. Knowledge Seeker)
				await ctx.notify_event("encounter_ended", {"ice": ice_card}, interpreter)
				await _phase_end()
				return

		# Determine if all subroutines were broken (for VP23 Sipa pass_ice condition)
		_all_subs_broken_for_pass = true
		for i in range(subroutines.size()):
			if not encounter.is_broken(i):
				_all_subs_broken_for_pass = false
				break

	# Store all-subs-broken state for pass_ice event data
	ctx.run_modifiers["last_ice_all_subs_broken"] = _all_subs_broken_for_pass

	# Fire encounter_ended: post-encounter trigger (VP40 Knowledge Seeker).
	# Does NOT fire for bypassed ice (bypass returns early above).
	await ctx.notify_event("encounter_ended", {"ice": ice_card}, interpreter)

	await _phase_movement()


# ── Phase 4: Movement ─────────────────────────────────────────────────────────

func _phase_movement() -> void:
	_set_phase(Phase.MOVEMENT)

	# Notify passing milestone effects; track that runner has cleared at least one ice
	if _ice_index < _ice_positions.size():
		_has_passed_ice = true
		# Enrich pass_ice event: outermost flag and all-subs-broken flag (VP23 Sipa, VP31 Vertigo)
		var pass_is_outermost: bool      = (_ice_index == 0)
		var pass_all_subs_broken: bool   = ctx.run_modifiers.get("last_ice_all_subs_broken", false)
		ctx.run_modifiers.erase("last_ice_all_subs_broken")
		await ctx.notify_event("pass_ice", {
			"ice":             _ice_positions[_ice_index],
			"is_outermost":    pass_is_outermost,
			"all_subs_broken": pass_all_subs_broken
		}, interpreter)

	await _execute_paid_ability_and_rez_window(false)
	if ctx.run_ended:
		await _phase_end()
		return

	# Proprionegation may have fired during the movement PAW — reset runner's position
	if _apply_run_position_reset():
		if _ice_positions.is_empty():
			await _phase_movement()
		else:
			await _phase_approach_ice()
		return

	# NSG 6.5.4: Runner may only jack out after passing at least one piece of ice
	if _has_passed_ice:
		var jack_out := await _runner_jack_out_window()
		if jack_out:
			ctx.send_log("[Movement] Runner jacks out.")
			await _phase_end()
			return

	# Advance engine position pointer across deep ice setups
	_ice_index += 1
	if _ice_index < _ice_positions.size():
		await _phase_approach_ice()
	else:
		# ── Baker redirect (VP15) ────────────────────────────────────────────────
		# Baker runs Archives; at approach time, may pay 1 stealth cr to redirect to HQ or R&D.
		if ctx.run_modifiers.get("baker_active", 0) > 0 and _target_server.server_id == "archives":
			ctx.run_modifiers.erase("baker_active")
			if ctx.runner_stealth_credits() >= 1:
				var baker_choices: Array = [
					{"label": "Baker: redirect to HQ (1 stealth cr)"},
					{"label": "Baker: redirect to R&D (1 stealth cr)"},
					{"label": "Approach Archives normally"}
				]
				var baker_choice: int = 2   # default: no redirect
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_modes"):
					var baker_chosen: Array = await ctx.runner_decision_maker.choose_modes(
						baker_choices, 1, ctx)
					if not baker_chosen.is_empty():
						baker_choice = baker_chosen[0]
				if baker_choice == 0 or baker_choice == 1:
					var baker_new_id: String = "hq" if baker_choice == 0 else "rd"
					var baker_new_server: Server = ctx.get_server(baker_new_id)
					if baker_new_server != null and ctx.runner_spend_stealth_credits(1):
						ctx.send_log("Baker: 1 stealth cr — redirecting run from Archives to %s." % \
							baker_new_server.display_name())
						_target_server        = baker_new_server
						ctx.run_target_server = baker_new_id
						await ctx.notify_event("approach_server", {"server_id": baker_new_id}, interpreter)
						await _phase_success()
						return
			else:
				ctx.send_log("Baker: %s cannot afford redirect — no stealth credits." % ctx.runner_name())
		# ── End Baker redirect ────────────────────────────────────────────────────

		# ── Maintenance Access redirect ──────────────────────────────────────────
		# Set before initiating the run via set_server_approach_redirect effect.
		# Fires here when the runner would approach the target server's root.
		if ctx.run_modifiers.has("server_approach_redirect"):
			var redir: Dictionary = ctx.run_modifiers.get("server_approach_redirect", {}) as Dictionary
			ctx.run_modifiers.erase("server_approach_redirect")
			var redir_from: String  = redir.get("from", "")
			var redir_to: String    = redir.get("to", "")
			if redir_from == _target_server.server_id and redir_to != "" and redir_to != redir_from:
				var redir_server: Server = ctx.get_server(redir_to)
				if redir_server != null:
					ctx.send_log("[Maintenance Access] Run redirected from %s to %s." % [
						_target_server.display_name(), redir_server.display_name()
					])
					_target_server        = redir_server
					ctx.run_target_server = redir_to
					_ice_positions        = redir_server.ice.duplicate()
					_ice_index            = 0
					_has_passed_ice       = false
					if _ice_positions.is_empty():
						ctx.send_log("[Redirect] No ice on %s — approaching server root." % redir_server.display_name())
						await ctx.notify_event("approach_server", {"server_id": redir_to}, interpreter)
						await _phase_success()
					else:
						await _phase_approach_ice()
					return
		# ── End redirect check ───────────────────────────────────────────────────
		ctx.send_log("[Movement] Runner approaches the server root.")
		await ctx.notify_event("approach_server", {"server_id": _target_server.server_id}, interpreter)
		await _phase_success()


# ── Phase 5: Success ─────────────────────────────────────────────────────────

func _phase_success() -> void:
	_set_phase(Phase.SUCCESS)

	# VP64 Flagship: when suppressed the run reaches the server but is not "successful"
	# for card-ability purposes.  The breach still occurs normally.
	if ctx.run_success_suppressed:
		ctx.run_success_suppressed = false
		ctx.send_log("[Success] Run reaches %s but success is suppressed (Flagship)." % \
			_target_server.display_name())
	else:
		ctx.run_successful = true
		ctx.send_log("[Success] Run successful on %s!" % _target_server.display_name())
		emit_signal("run_succeeded", _target_server.server_id)
		# Track successful runs on each central for Chain Reaction (VP1) and other per-central guards.
		# Set here (not only in TurnManager) so event-card-initiated runs also populate these flags.
		match _target_server.server_id:
			"rd":
				ctx.runner_successful_run_on_rd_this_turn = true
			"archives":
				ctx.runner_successful_run_on_archives_this_turn = true
			"hq":
				ctx.runner_hq_successful_run_this_turn = true

		# Global announcement triggers
		await ctx.notify_event("successful_run", {"server_id": _target_server.server_id}, interpreter)

		# Run-event "gain on success" reward (e.g. Clean Getaway: gain 6cr if successful)
		var gain_on_success: int = ctx.run_modifiers.get("gain_on_success", 0)
		if gain_on_success > 0:
			ctx.runner_credits += gain_on_success
			ctx.send_log("%s gains %d cr (run successful)." % [ctx.runner_name(), gain_on_success])

		# Transfer of Wealth: take 1 tag, Corp loses up to 3cr, Runner gains 2× the amount lost.
		if ctx.run_modifiers.get("transfer_of_wealth_on_success", 0) > 0:
			ctx.runner_tags += 1
			ctx.send_log("Transfer of Wealth: %s takes 1 tag (%d total)." % [ctx.runner_name(), ctx.runner_tags])
			await ctx.notify_event("runner_takes_tags", {"amount": 1}, interpreter)
			if not ctx.game_over:
				var tow_lost: int   = min(3, ctx.corp_credits)
				ctx.corp_credits   -= tow_lost
				var tow_gained: int = tow_lost * 2
				ctx.runner_credits += tow_gained
				ctx.send_log("Transfer of Wealth: %s loses %d cr; %s gains %d cr." % [
					ctx.corp_name(), tow_lost, ctx.runner_name(), tow_gained
				])

	# Red Team payout: take hosted credits before breach
	if ctx.has_meta("red_team_pending_payout"):
		var payout: Dictionary = ctx.get_meta("red_team_pending_payout") as Dictionary
		if payout.get("server_id", "") == _target_server.server_id:
			var iid: String          = payout.get("card_instance_id", "")
			var counter: String      = payout.get("counter", "credits")
			var amount: int          = payout.get("amount", 3)
			var self_card: InstalledCard = ctx.get_installed_card_by_instance_id(iid)
			if self_card != null:
				var available: int = self_card.get_counter(counter)
				var taken: int     = min(amount, available)
				if taken > 0:
					self_card.remove_counter(counter, taken)
					ctx.runner_credits += taken
					ctx.send_log("Red Team: %s takes %d cr (%d remaining on Red Team)." % [
						ctx.runner_name(), taken, self_card.get_counter(counter)
					])
				# Self-trash when all hosted credits are removed ("trash this card
				# when they are all removed" per card text).
				if self_card.get_counter(counter) <= 0:
					ctx.runner_rig.erase(self_card)
					ctx.unregister_all_card_effects(iid)
					if self_card.card_record != null:
						ctx.runner_discard.append(self_card.card_record)
					ctx.send_log("Red Team: all credits spent — trashed.")

	await _breach_server()
	await _phase_end()


# ── Phase 6: End ─────────────────────────────────────────────────────────────

func _phase_end() -> void:
	_set_phase(Phase.END)
	ctx.run_active = false

	if ctx.run_successful:
		ctx.send_log("[End] Run ended successfully.")
	else:
		ctx.send_log("[End] Run ended unsuccessfully.")
		emit_signal("run_ended_unsuccessfully",
			"subroutine" if ctx.run_ended else "jack_out")

	# Final cleanup triggers
	await ctx.notify_event("run_end", {"server_id": _target_server.server_id, "successful": ctx.run_successful}, interpreter)

	# Return unspent Overclock credits to the bank (they don't carry over)
	var overclock_remaining: int = ctx.run_modifiers.get("overclock_credits", 0)
	if overclock_remaining > 0:
		ctx.send_log("Overclock: %d unspent credit(s) returned to the bank." % overclock_remaining)

	# Beta Build (VP19): return the installed program to the top of the runner's stack at run end
	if ctx.beta_build_installed_card_id != "":
		var bb_iid: String = ctx.beta_build_installed_card_id
		ctx.beta_build_installed_card_id = ""
		var bb_card: InstalledCard = ctx.get_installed_card_by_instance_id(bb_iid)
		if bb_card != null:
			ctx.runner_rig.erase(bb_card)
			ctx.unregister_all_card_effects(bb_iid)
			if bb_card.card_record != null:
				ctx.runner_deck.push_front(bb_card.card_record)
				ctx.send_log("Beta Build: %s returned to top of stack." % bb_card.card_record.title)

	ctx.run_ended      = false
	ctx.run_modifiers  = {}   # clear all run-scoped modifiers


# ── Breach ────────────────────────────────────────────────────────────────────

func _breach_server() -> void:
	ctx.send_log("[Breach] Runner breaches %s." % _target_server.display_name())

	# Fire before_breach interrupt — allows Anoetic Void to end the breach early
	await ctx.notify_event("before_breach", {
		"server_id": _target_server.server_id
	}, interpreter)

	if ctx.run_modifiers.get("breach_cancelled", false):
		ctx.send_log("[Breach] Breach ended before access (Corp ability).")
		return

	var access_list: Array = _target_server.get_root_access_cards()
	var _hq_accessed_indices: Array = []   # tracks HQ hand indices already in access_list

	match _target_server.server_id:
		"hq":
			if not ctx.corp_hand.is_empty():
				var idx: int = randi() % ctx.corp_hand.size()
				access_list.append(ctx.corp_hand[idx])
				_hq_accessed_indices.append(idx)
		"rd":
			if not ctx.corp_deck.is_empty():
				access_list.append(ctx.corp_deck[0])
		"archives":
			# Per rules: before accessing, all facedown cards in Archives are turned faceup.
			if not ctx.corp_discard_facedown.is_empty():
				var nh_faceup_count: int = ctx.corp_discard_facedown.size()
				ctx.send_log("[Breach] Corp turns %d facedown card(s) in Archives faceup." % nh_faceup_count)
				ctx.corp_discard_facedown.clear()
				# VP7 Nurse Hạnh: notify when facedown cards are turned faceup in Archives
				await ctx.notify_event("archives_cards_turned_faceup", {"count": nh_faceup_count}, interpreter)
			access_list.append_array(ctx.corp_discard)

	# Apply bonus access from run modifiers (e.g. Docklands Pass, Jailbreak, Conduit)
	var bonus_access: int = ctx.run_modifiers.get("bonus_access", 0)
	if bonus_access > 0:
		match _target_server.server_id:
			"hq":
				var available: Array = []
				for i in range(ctx.corp_hand.size()):
					if i not in _hq_accessed_indices:
						available.append(i)
				available.shuffle()
				for i in range(min(bonus_access, available.size())):
					var pick_idx: int = available[i]
					access_list.append(ctx.corp_hand[pick_idx])
					_hq_accessed_indices.append(pick_idx)
			"rd":
				for i in range(bonus_access):
					if i + 1 < ctx.corp_deck.size():
						access_list.append(ctx.corp_deck[i + 1])
		ctx.send_log("[Breach] Bonus access: %d extra card(s)." % bonus_access)

	if access_list.is_empty():
		ctx.send_log("[Breach] Nothing to access.")
		return

	# NSG 7.1/7.2: Runner chooses the order to access cards one at a time.
	# R&D cards are pre-ordered top-to-bottom; runner choice is meaningful for
	# root cards mixed with HQ/Archives targets.
	var access_count: int = 0
	while not access_list.is_empty() and not ctx.game_over:
		# VP64 Flagship: max_access caps how many cards can be accessed this breach.
		var max_acc: int = ctx.run_modifiers.get("max_access", -1)
		if max_acc >= 0 and access_count >= max_acc:
			ctx.send_log("[Breach] Access limited to %d card(s) this breach." % max_acc)
			break
		var target: Variant = await _runner_choose_access_target(access_list)
		access_list.erase(target)
		await _access_card(target)
		access_count += 1

	# Fire breach_complete so identity abilities (e.g. Zahya) can react to access count
	if not ctx.game_over:
		await ctx.notify_event("breach_complete", {
			"server_id": _target_server.server_id,
			"access_count": access_count
		}, interpreter)


func _runner_choose_access_target(candidates: Array) -> Variant:
	if candidates.size() == 1:
		return candidates[0]
	if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_access_target"):
		return await ctx.runner_decision_maker.choose_access_target(candidates, ctx)
	return candidates[0]


func _access_card(card: Variant) -> void:
	var card_id: String = ""
	var card_record: CardRecord = null
	var instance_id: String = ""

	if card is InstalledCard:
		var ic := card as InstalledCard
		card_id     = ic.card_id
		card_record = ic.card_record
		instance_id = ic.runtime_instance_id
	elif card is Dictionary:
		var d := card as Dictionary
		card_id     = d.get("card_id", "")
		card_record = d.get("card_record", null) as CardRecord
		instance_id = d.get("runtime_instance_id", "")
	elif card is CardRecord:
		# Raw CardRecord — comes from corp_deck (R&D access) or corp_discard
		card_record = card as CardRecord
		card_id     = card_record.id

	ctx.accessed_card_id = instance_id if instance_id != "" else card_id
	# Track Archives breach card IDs for Charm Offensive
	if _target_server != null and _target_server.server_id == "archives" and card_id != "":
		if card_id not in ctx.run_accessed_archives_card_ids:
			ctx.run_accessed_archives_card_ids.append(card_id)
	ctx.send_log("[Access] Runner accesses: %s" % (card_record.title if card_record else card_id))

	# Universal framework dispatch trigger
	await ctx.notify_event("access_card", {"card_id": card_id, "runtime_instance_id": instance_id}, interpreter)

	# on_access abilities only fire when the card is accessed while installed (not from Archives/heap)
	# A card accessed from Archives is a CardRecord or a dict without a live server reference.
	var is_installed: bool = (card is InstalledCard)
	if is_installed:
		var on_access_def = ability_registry.get_on_access(card_id)
		if on_access_def != null:
			await interpreter.execute_trigger(on_access_def as Dictionary, ctx)

	# Stop immediately if damage caused a flatline
	if ctx.game_over:
		return

	if card_record == null:
		return

	# ── BANGUN: Whenever Runner accesses a faceup installed agenda ────────────
	# Deals 2 meat damage and gives 1 tag.  Fires before the steal/trash flow.
	if card is InstalledCard and (card as InstalledCard).is_face_up and \
			card_record.is_agenda() and ctx.corp_identity != null and \
			ctx.corp_identity.id == "bangun_when_disaster_strikes":
		ctx.send_log("BANGUN: Runner accesses faceup agenda — 2 meat damage and 1 tag!")
		await interpreter._deal_damage("meat", 2, ctx)
		if ctx.game_over:
			return
		ctx.runner_tags += 1
		ctx.send_log("BANGUN: Runner gains 1 tag (%d total)." % ctx.runner_tags)
		await ctx.notify_event("runner_takes_tags", {"amount": 1}, interpreter)
		if ctx.game_over:
			return

	# Carnivore: runner may trash 2 from grip to trash this card (once per turn)
	if not ctx.runner_carnivore_used_this_turn and not card_record.is_agenda():
		var carnivore_installed := false
		for rig_card in ctx.runner_rig:
			var c: InstalledCard = rig_card as InstalledCard
			if c != null and c.card_id == "carnivore":
				carnivore_installed = true
				break
		if carnivore_installed and ctx.runner_hand.size() >= 2:
			var use_carnivore := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_carnivore"):
				use_carnivore = await ctx.runner_decision_maker.choose_carnivore(card_record, ctx)
			if use_carnivore:
				# Trash 2 cards from grip
				for i in range(2):
					if ctx.runner_hand.is_empty():
						break
					var discarded: Dictionary = ctx.runner_hand.pop_back() as Dictionary
					var r: CardRecord = discarded.get("card_record", null) as CardRecord
					if r:
						ctx.runner_discard.append(r)
						ctx.send_log("Carnivore: trashes %s from grip." % r.title)
				ctx.runner_carnivore_used_this_turn = true
				# Trash the accessed card
				if card is InstalledCard:
					var installed: InstalledCard = card as InstalledCard
					var server: Server = ctx.get_server(installed.server_id)
					if server:
						server.remove_from_root(installed)
					ctx.corp_discard.append(card_record)
					ctx.send_log("Carnivore: trashes %s." % card_record.title)
					# Fire Loup trigger
					await ctx.notify_event("runner_trashes_during_breach", {
						"card_id": card_record.id
					}, interpreter)
				# Skip normal steal/trash flow for this card
				var _outcome_c := "accessed"
				emit_signal("card_accessed", card_record, _outcome_c)
				if ctx.has_meta("on_card_display_done"):
					var cb: Callable = ctx.get_meta("on_card_display_done") as Callable
					await cb.call(card_record, _outcome_c)
				return

	# ── Gourmand: access interrupt — trash any installed non-agenda for free, draw 1 ──
	if not card_record.is_agenda() and (card is InstalledCard):
		var gm_installed: InstalledCard = null
		for rig_c in ctx.runner_rig:
			var rc: InstalledCard = rig_c as InstalledCard
			if rc != null and rc.card_id == "gourmand":
				gm_installed = rc
				break
		if gm_installed != null:
			# Respect cannot_be_trashed_while_rezzed flag (e.g. Kessleroid)
			var gm_card_def: Dictionary = ability_registry._abilities.get(card_record.id, {}) as Dictionary
			var gm_protected: bool = (card as InstalledCard).is_rezzed and \
				gm_card_def.get("cannot_be_trashed_while_rezzed", false)
			if not gm_protected:
				var gm_use := false
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
					var gm_modes: Array = [
						{"label": "Gourmand: trash %s for free and draw 1" % card_record.title},
						{"label": "Pass"}
					]
					var gm_chosen: Array = await ctx.runner_decision_maker.choose_modes(gm_modes, 1, ctx)
					gm_use = (not gm_chosen.is_empty() and gm_chosen[0] == 0)
				else:
					gm_use = true   # AI default: always use it

				if gm_use:
					# Pay the [trash] cost: remove Gourmand from the rig
					ctx.runner_rig.erase(gm_installed)
					ctx.unregister_all_card_effects(gm_installed.runtime_instance_id)
					if gm_installed.card_record != null:
						ctx.runner_discard.append(gm_installed.card_record)
					ctx.send_log("Gourmand: %s trashes Gourmand." % ctx.runner_name())
					# Trash the accessed corp card (no credit cost)
					var gm_target: InstalledCard = card as InstalledCard
					var gm_server: Server = ctx.get_server(gm_target.server_id)
					if gm_server != null:
						gm_server.remove_from_root(gm_target)
						ctx.remove_empty_remote_servers()
					ctx.unregister_all_card_effects(gm_target.runtime_instance_id)
					ctx.corp_discard.append(card_record)
					ctx.send_log("Gourmand: trashes %s." % card_record.title)
					# Draw 1 card
					if not ctx.runner_deck.is_empty():
						var gm_draw: CardRecord = ctx.runner_deck.pop_front() as CardRecord
						ctx.runner_hand.append({"card_id": gm_draw.id, "card_record": gm_draw})
						ctx.send_log("Gourmand: %s draws 1 card." % ctx.runner_name())
					else:
						ctx.send_log("Gourmand: stack is empty — no draw.")
					await ctx.notify_event("runner_trashes_during_breach", {
						"card_id": card_record.id
					}, interpreter)
					var _outcome_gm := "accessed"
					emit_signal("card_accessed", card_record, _outcome_gm)
					if ctx.has_meta("on_card_display_done"):
						var cb: Callable = ctx.get_meta("on_card_display_done") as Callable
						await cb.call(card_record, _outcome_gm)
					return

	# ── Lampades (VP5): access → spend 1 power counter + pay rez/play cost in stealth → trash ──
	# Agendas cannot be targeted (no rez/play cost per ruling).
	if not card_record.is_agenda() and card_record.cost >= 0:
		var lampades_ic: InstalledCard = null
		for lmp in ctx.runner_rig:
			var lc: InstalledCard = lmp as InstalledCard
			if lc != null and lc.card_id == "lampades" and lc.get_counter("power") >= 1:
				lampades_ic = lc
				break
		if lampades_ic != null and ctx.runner_stealth_credits() >= card_record.cost:
			var lmp_use := false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_modes"):
				var lmp_modes: Array = [
					{"label": "Lampades: trash %s (%dcr stealth + 1 counter)" % \
						[card_record.title, card_record.cost]},
					{"label": "Pass"}
				]
				var lmp_chosen: Array = await ctx.runner_decision_maker.choose_modes(
					lmp_modes, 1, ctx)
				lmp_use = (not lmp_chosen.is_empty() and lmp_chosen[0] == 0)
			else:
				lmp_use = true   # AI default: always trash when affordable
			if lmp_use:
				lampades_ic.remove_counter("power", 1)
				ctx.runner_spend_stealth_credits(card_record.cost)
				ctx.send_log("Lampades: 1 power counter + %dcr stealth — %s trashed." % \
					[card_record.cost, card_record.title])
				if card is InstalledCard:
					var lmp_inst: InstalledCard = card as InstalledCard
					var lmp_srv: Server = ctx.get_server(lmp_inst.server_id)
					if lmp_srv != null:
						if lmp_inst.zone == "root":
							lmp_srv.remove_from_root(lmp_inst)
						else:
							lmp_srv.remove_ice(lmp_inst)
						ctx.remove_empty_remote_servers()
					ctx.unregister_all_card_effects(lmp_inst.runtime_instance_id)
					if not lmp_inst.is_rezzed:
						ctx.corp_discard_facedown[card_record.title] = true
				ctx.corp_discard.append(card_record)
				await ctx.notify_event("runner_trashes_during_breach",
					{"card_id": card_id}, interpreter)
				var _lmp_outcome := "trashed"
				emit_signal("card_accessed", card_record, _lmp_outcome)
				if ctx.has_meta("on_card_display_done"):
					var lmp_cb: Callable = ctx.get_meta("on_card_display_done") as Callable
					await lmp_cb.call(card_record, _lmp_outcome)
				return
	# ── End Lampades ──────────────────────────────────────────────────────────────

	if card_record.is_agenda():
		await _steal_agenda(card_record)
	elif card_record.is_asset() or card_record.card_type == "upgrade":
		# Don't offer trash for cards already in Archives
		if is_installed:
			await _offer_trash(card, card_record)

	# Stop if game ended during steal or trash resolution
	if ctx.game_over:
		return

	# Determine outcome for display
	var _outcome := "accessed"
	if card_record != null and card_record.is_agenda():
		_outcome = "stolen"
	emit_signal("card_accessed", card_record, _outcome)

	# Wait for the UI to finish displaying this card before accessing the next one.
	if ctx.has_meta("on_card_display_done"):
		var cb: Callable = ctx.get_meta("on_card_display_done") as Callable
		await cb.call(card_record, _outcome)

func _steal_agenda(card_record: CardRecord) -> void:
	# Vertigo (VP31): runner cannot steal while this run-scoped flag is active
	if ctx.runner_cannot_steal_or_trash_this_run:
		ctx.send_log("[Access] Runner cannot steal %s — Vertigo effect active." % card_record.title)
		return
	# Perfect Recall (VP35): runner cannot steal specific card IDs this run
	if card_record.id in ctx.runner_steal_trash_blocked_card_ids:
		ctx.send_log("[Access] Runner cannot steal %s — Perfect Recall effect active." % card_record.title)
		return

	# Additional cost: steal_costs_click — Runner must spend 1 click to steal.
	# If the Runner has no clicks, the steal is blocked.
	var sc_def: Dictionary = ability_registry._abilities.get(card_record.id, {}) as Dictionary
	if sc_def.get("steal_costs_click", false):
		if ctx.runner_clicks < 1:
			ctx.send_log("[Access] Runner cannot steal %s — no clicks remaining." % card_record.title)
			return
		ctx.runner_clicks -= 1
		ctx.send_log("[Access] Runner spends 1 click to steal %s." % card_record.title)

	# Additional steal cost: credits (e.g. Magistrate Revontulet: must pay 3cr to steal).
	var sc_credits: int = sc_def.get("steal_costs_credits", 0)
	if sc_credits > 0:
		if ctx.runner_credits < sc_credits:
			ctx.send_log("[Access] Runner cannot steal %s — needs %d cr (has %d)." % [
				card_record.title, sc_credits, ctx.runner_credits])
			return
		ctx.runner_credits -= sc_credits
		ctx.send_log("[Access] Runner pays %d cr to steal %s." % [sc_credits, card_record.title])

	ctx.send_log("[Access] Runner steals %s! (%d agenda points)" % [
		card_record.title, card_record.agenda_points
	])
	ctx.runner_score_area.append(card_record)
	ctx.runner_stole_agenda_this_run  = true   # AMAZE Amusements tracks this
	ctx.runner_stole_agenda_this_turn = true   # Hype Machine rez discount

	# Create a parallel InstalledCard so counter-bearing abilities (e.g. Next Big Thing)
	# can store and read counters even after the agenda moves to the runner's score area.
	var stolen_inst := InstalledCard.make_runtime_instance(card_record, "runner_score_area", "root", true)
	ctx.runner_score_area_cards.append(stolen_inst)

	# server_id is _target_server (the run's target); capture before removal.
	var stolen_server_id: String = _target_server.server_id if _target_server != null else ""

	for server in ctx.servers.values():
		var s: Server = server as Server
		for installed in s.root:
			var c: InstalledCard = installed as InstalledCard
			if c.card_id == card_record.id:
				s.remove_from_root(c)
				ctx.unregister_all_card_effects(c.runtime_instance_id)
				break

	# Fire on_steal ability (e.g. Send a Message, Superconducting Hub, Next Big Thing).
	# Set current_event_data so counter effects (add_self_counters) can find the card.
	var on_steal_def = ability_registry.get_on_steal(card_record.id)
	if on_steal_def != null:
		ctx.current_event_data = {
			"card": stolen_inst,
			"card_instance_id": stolen_inst.runtime_instance_id
		}
		await interpreter.execute_trigger(on_steal_def as Dictionary, ctx)
		ctx.current_event_data = {}

	# Notify listeners (e.g. Lamplighter: self-trash when agenda stolen from its server)
	await ctx.notify_event("runner_steals_agenda", {
		"agenda_id":  card_record.id,
		"server_id":  stolen_server_id
	}, interpreter)

	# Check if runner has won by stealing this agenda
	if ctx.runner_agenda_points() >= ctx.agenda_points_to_win:
		ctx.send_log("Runner wins by stealing agendas!")
		ctx.game_over = true
		ctx.winner    = "runner"


func _offer_trash(card: Variant, card_record: CardRecord) -> void:
	if card_record.trash_cost < 0:
		return

	# Vertigo (VP31): runner cannot trash while this run-scoped flag is active
	if ctx.runner_cannot_steal_or_trash_this_run:
		ctx.send_log("[Access] Runner cannot trash %s — Vertigo effect active." % card_record.title)
		return

	# Perfect Recall (VP35): runner cannot trash specific card IDs this run
	if card_record.id in ctx.runner_steal_trash_blocked_card_ids:
		ctx.send_log("[Access] Runner cannot trash %s — Perfect Recall effect active." % card_record.title)
		return

	# Kessleroid-style protection: rezzed ice that the runner cannot trash
	if card is InstalledCard and (card as InstalledCard).is_rezzed:
		var ct_card_def: Dictionary = ability_registry._abilities.get(card_record.id, {}) as Dictionary
		if ct_card_def.get("cannot_be_trashed_while_rezzed", false):
			ctx.send_log("[Access] %s cannot be trashed while rezzed." % card_record.title)
			return

	# Effective trash cost: base + any modifiers from rezzed cards in same server (e.g. Mahkota +2)
	var accessed_server: Server = null
	if card is InstalledCard:
		accessed_server = ctx.get_server((card as InstalledCard).server_id)
	var effective_trash_cost: int = _compute_effective_trash_cost(card_record, accessed_server)

	# Total available credits includes Azimat recurring trash credits
	var available: int = ctx.runner_trash_credits_available()

	ctx.send_log("[Access] Runner may trash %s for %d credits (Runner has %d total)." % [
		card_record.title, effective_trash_cost, available
	])
	if available < effective_trash_cost:
		ctx.send_log("[Access] Runner cannot afford to trash.")
		return

	var should_trash := false
	if ctx.runner_decision_maker != null:
		should_trash = await ctx.runner_decision_maker.choose_trash(card_record, ctx)

	if should_trash:
		ctx.runner_spend_for_trash(effective_trash_cost)
		# VP65 Shackleton Grid: check if outside-pool credits were used for this trash cost
		await ctx.check_outside_credits_trigger(interpreter)
		ctx.send_log("[Access] Runner trashes %s." % card_record.title)
		if card is InstalledCard:
			var installed: InstalledCard = card as InstalledCard

			# Fire on_trash ability BEFORE unregistering effects (e.g. future "when trashed" abilities)
			var ot_card_def: Dictionary = ability_registry._abilities.get(card_record.id, {}) as Dictionary
			var on_trash_def: Variant = ot_card_def.get("on_trash", null)
			if on_trash_def != null:
				ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
				await interpreter.execute_trigger(on_trash_def as Dictionary, ctx)
				ctx.current_event_data = {}

			var server: Server = ctx.get_server(installed.server_id)
			if server:
				server.remove_from_root(installed)
			ctx.unregister_all_card_effects(installed.runtime_instance_id)
			# Cascade-trash any runner programs hosted on this ice
			if installed.zone == "ice" and not installed.hosted_cards.is_empty():
				for hosted in installed.hosted_cards.duplicate():
					var h: InstalledCard = hosted as InstalledCard
					ctx.runner_rig.erase(h)
					ctx.unregister_all_card_effects(h.runtime_instance_id)
					ctx.send_log("  %s trashed (host ice removed)." % h.display_name())
				installed.hosted_cards.clear()
			# Unrezzed cards go facedown in Archives
			if not installed.is_rezzed:
				ctx.corp_discard_facedown[card_record.title] = true
		ctx.corp_discard.append(card_record)

		# Fire trash-during-breach event (Loup identity ability)
		await ctx.notify_event("runner_trashes_during_breach", {
			"card_id": card_record.id
		}, interpreter)


# ── Decision windows ──────────────────────────────────────────────────────────

func _rez_card(card: InstalledCard) -> void:
	if card.is_rezzed:
		return
	var record: CardRecord = card.card_record
	if record == null:
		return
		
	var rez_cost: int = ctx.query_rez_cost(card)
	# Apply run-scoped extra rez cost (e.g. Tread Lightly) or discount (e.g. Mycoweb sub 2)
	rez_cost += ctx.run_modifiers.get("extra_rez_cost", 0)
	rez_cost = max(0, rez_cost)   # prevent a discount from driving cost below zero

	# ── Rez discount: Hype Machine — 6cr off if an agenda was scored/stolen this turn ──
	var rsm_hm_def: Dictionary = ability_registry._abilities.get(record.id, {}) as Dictionary
	var rsm_hm_discount: int   = int(rsm_hm_def.get("rez_cost_reduction_if_agenda_scored_stolen", 0))
	if rsm_hm_discount > 0 and \
			(ctx.corp_agendas_scored_this_turn > 0 or ctx.runner_stole_agenda_this_turn):
		rez_cost = max(0, rez_cost - rsm_hm_discount)
		ctx.send_log("[Rez] Hype Machine: agenda scored/stolen this turn → %d cr discount (cost now %d)." % [
			rsm_hm_discount, rez_cost])

	# ── Dynamic rez cost reduction per other unrezzed ice (e.g. Reverb) ──
	var card_def_check: Dictionary = ability_registry._abilities.get(record.id, {}) as Dictionary
	var per_unrezzed: int = int(card_def_check.get("rez_cost_reduction_per_unrezzed_ice", 0))
	if per_unrezzed > 0:
		var rsm_unrezzed_count := 0
		for rsm_srv in ctx.servers.values():
			for rsm_ice in (rsm_srv as Server).ice:
				var rsm_ic: InstalledCard = rsm_ice as InstalledCard
				if rsm_ic != null and rsm_ic.runtime_instance_id != card.runtime_instance_id and not rsm_ic.is_rezzed:
					rsm_unrezzed_count += 1
		rez_cost = max(0, rez_cost - per_unrezzed * rsm_unrezzed_count)
		if rsm_unrezzed_count > 0:
			ctx.send_log("[Rez] %s: %d other unrezzed ice → %d credit discount (cost now %d)." % [
				record.title, rsm_unrezzed_count, per_unrezzed * rsm_unrezzed_count, rez_cost])

	# ── Optional forfeit discount (e.g. Biawak: forfeit 1 agenda to pay 10cr of cost) ──
	var forfeit_discount_def: Variant = card_def_check.get("forfeit_rez_discount", null)
	if forfeit_discount_def != null and not ctx.corp_score_area_cards.is_empty():
		var fd_amount: int = (forfeit_discount_def as Dictionary).get("amount", 0)
		var fd_candidates: Array = ctx.corp_score_area_cards.duplicate()
		var fd_chosen: InstalledCard = null
		if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_forfeit_agenda"):
			fd_chosen = await ctx.corp_decision_maker.choose_forfeit_agenda(fd_candidates, ctx)
		if fd_chosen != null:
			rez_cost = max(0, rez_cost - fd_amount)
			await interpreter._forfeit_agenda(fd_chosen, ctx)

	# ── Mandatory additional rez cost (e.g. Plutus: forfeit agenda OR reveal+trash 3 HQ) ──
	var add_rez_cost_def: Variant = card_def_check.get("additional_rez_cost", null)
	if add_rez_cost_def != null:
		var arc_type: String = (add_rez_cost_def as Dictionary).get("type", "")
		if arc_type == "forfeit_or_reveal_trash_hq":
			var arc_reveal_count: int = (add_rez_cost_def as Dictionary).get("reveal_trash_count", 3)
			var arc_can_forfeit: bool = not ctx.corp_score_area_cards.is_empty()
			var arc_can_reveal: bool  = ctx.corp_hand.size() >= arc_reveal_count
			if not arc_can_forfeit and not arc_can_reveal:
				ctx.send_log("[Rez] %s cannot pay additional rez cost — no agenda to forfeit and too few HQ cards." % record.title)
				return
			# Corp chooses: forfeit (non-null) or reveal+trash (null from choose_forfeit_agenda)
			var arc_chosen: InstalledCard = null
			if arc_can_forfeit and ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_forfeit_agenda"):
				arc_chosen = await ctx.corp_decision_maker.choose_forfeit_agenda(
					ctx.corp_score_area_cards.duplicate(), ctx
				)
			if arc_chosen != null:
				# Pay by forfeiting
				await interpreter._forfeit_agenda(arc_chosen, ctx)
			elif arc_can_reveal:
				# Pay by revealing and trashing 3 cards from HQ
				ctx.send_log("[Rez] %s reveals and trashes %d card(s) from HQ as additional rez cost." % [
					ctx.corp_name(), arc_reveal_count
				])
				for _arc_i in range(min(arc_reveal_count, ctx.corp_hand.size())):
					var arc_entry: Dictionary = ctx.corp_hand.pop_back() as Dictionary
					var arc_record: CardRecord = arc_entry.get("card_record", null) as CardRecord
					if arc_record != null:
						ctx.corp_discard.append(arc_record)
						ctx.corp_discard_facedown[arc_record.title] = true
						ctx.send_log("  %s revealed and trashed from HQ." % arc_record.title)
			else:
				ctx.send_log("[Rez] %s cannot pay additional rez cost — run out of options." % record.title)
				return

	# Corp may supplement corp credits with Mahkota Langit Grid recurring credits on this server
	var rez_server_id: String = card.server_id
	if ctx.corp_rez_credits_available(rez_server_id) < rez_cost:
		ctx.send_log("[Rez] Corp cannot afford to rez %s (costs %d, has %d)." % [
			card.card_id, rez_cost, ctx.corp_rez_credits_available(rez_server_id)
		])
		return

	ctx.corp_spend_for_rez(rez_cost, rez_server_id)
	card.is_rezzed    = true
	if record.is_ice():
		ctx.ice_rezzed_this_turn = true
	ctx.send_log("[Rez] Corp rezzes %s for %d credits." % [record.title, rez_cost])
	emit_signal("ice_rezzed", card)

	# Register ongoing triggers/modifiers now that the card is face-up
	_register_rezzed_listeners(card)

	# Core notification framework hook
	await ctx.notify_event("rez_card", {"card": card}, interpreter)
	# Barry "Baz" Wong: fire a dedicated ice-rez event for identity/card listeners
	if record.is_ice():
		await ctx.notify_event("corp_rezzes_ice", {"ice": card}, interpreter)

	var on_rez_def = ability_registry.get_on_rez(card.card_id)
	if on_rez_def != null:
		ctx.current_event_data = {"card": card, "card_instance_id": card.runtime_instance_id}
		await interpreter.execute_trigger(on_rez_def as Dictionary, ctx)
		ctx.current_event_data = {}


# Mirrors TurnManager._register_card_listeners for cards rezzed mid-run.
# Must be kept in sync with the event list there.
func _register_rezzed_listeners(card: InstalledCard) -> void:
	var instance_id: String  = card.runtime_instance_id if card.runtime_instance_id != "" else card.card_id
	var card_def: Dictionary = ability_registry._abilities.get(card.card_id, {}) as Dictionary
	for event_type in ["corp_turn_start", "runner_turn_start", "corp_turn_end", "runner_turn_end",
						"approach_ice", "encounter_ice", "encounter_ended", "pass_ice", "successful_run",
						"approach_server", "run_end", "on_derez",
						"corp_scores_agenda", "runner_steals_agenda", "runner_trashes_during_breach",
						"before_breach", "runner_installs_virus",
						"on_advance", "breach_complete", "run_start", "runner_takes_tags",
						"archives_cards_turned_faceup",
						"hardware_trashed", "runner_spends_outside_credits", "corp_gains_bad_pub"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)
	var modifiers: Array = card_def.get("passive_modifiers", []) as Array
	for mod in modifiers:
		var mod_dict: Dictionary = mod as Dictionary
		var extra := {}
		for key in ["card_id", "method"]:
			if mod_dict.has(key):
				extra[key] = mod_dict[key]
		# Server-scoped modifiers (e.g. Mahkota recurring credits) carry the owning card's server_id
		if mod_dict.get("server_scoped", false):
			extra["server_id"] = card.server_id
		ctx.register_modifier(
			mod_dict.get("type", ""),
			instance_id,
			mod_dict.get("value", 0),
			mod_dict.get("conditions", {}) as Dictionary,
			extra
		)


# Compute effective trash cost: base cost + modifiers from rezzed cards in the same server.
# e.g. Mahkota Langit Grid adds +2 to each asset in the server root.
func _compute_effective_trash_cost(card_record: CardRecord, server: Server) -> int:
	var cost: int = card_record.trash_cost
	if server == null or not card_record.is_asset():
		return cost
	for root_card in server.root:
		var rc: InstalledCard = root_card as InstalledCard
		if rc == null or not rc.is_rezzed:
			continue
		var rc_def: Dictionary = ability_registry._abilities.get(rc.card_id, {}) as Dictionary
		cost += int(rc_def.get("trash_cost_increase_own_server_assets", 0))
	return cost


# Kept for external callers; new code uses encounter loop directly
func _runner_break_subroutines(_ice_card: InstalledCard, _subroutines: Array) -> Array:
	return []


func _runner_jack_out_window() -> bool:
	if ctx.runner_decision_maker == null:
		return false
	return await ctx.runner_decision_maker.choose_jack_out(ctx)


# ── Run position helpers ───────────────────────────────────────────────────────

# Proprionegation: Corp ability sets run_modifiers["run_position_reset"] during a PAW.
# After any PAW/encounter window, the RSM calls this to check and apply the reset.
# Returns true if a reset was applied; the calling phase should then restart from
# the new position and return early.
func _apply_run_position_reset() -> bool:
	if not ctx.run_modifiers.has("run_position_reset"):
		return false
	var reset: Dictionary = ctx.run_modifiers.get("run_position_reset", {}) as Dictionary
	ctx.run_modifiers.erase("run_position_reset")
	var new_server_id: String = reset.get("server_id", "")
	var new_server: Server = ctx.get_server(new_server_id)
	if new_server == null:
		push_error("RunStateMachine: run_position_reset — unknown server '%s'" % new_server_id)
		return false
	ctx.send_log("[Proprionegation] Runner is moved to the outermost position of %s." % new_server.display_name())
	_target_server        = new_server
	ctx.run_target_server = new_server_id
	_ice_positions        = new_server.ice.duplicate()
	_ice_index            = 0
	_has_passed_ice       = false
	return true


# ── Shred: ETR prevention helper ─────────────────────────────────────────────
#
# Called the first time an ETR fires while run_modifiers["prevent_first_etr"] is set.
# The Corp may trash X random HQ cards to let the ETR stand; otherwise it is prevented.
# X = number of cards currently in the root of the attacked server.
#
# Returns true  → ETR is prevented (Corp declined or could not pay)
# Returns false → ETR stands     (Corp paid the cost, or X was 0)
func _shred_check_etr_prevention() -> bool:
	var root_count: int = _target_server.root.size() if _target_server != null else 0

	# X=0: cost is zero — Corp automatically pays, ETR stands.
	if root_count == 0:
		ctx.send_log("[Shred] Root is empty (X=0) — ETR is not prevented.")
		return false

	# Corp cannot pay the full cost — ETR is prevented.
	if ctx.corp_hand.size() < root_count:
		ctx.send_log("[Shred] Corp has %d HQ card(s), needs %d — ETR prevented (Shred)." % [
			ctx.corp_hand.size(), root_count
		])
		return true

	# Corp has enough cards — ask whether to pay.
	var should_pay := true
	if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_pay_shred_etr"):
		should_pay = await ctx.corp_decision_maker.choose_pay_shred_etr(root_count, ctx)

	if not should_pay:
		ctx.send_log("[Shred] Corp declines to pay — ETR prevented (Shred).")
		return true

	# Corp pays: reveal (implicit in singleplayer) and trash X HQ cards at random.
	ctx.send_log("[Shred] Corp reveals and trashes %d HQ card(s) at random to end the run." % root_count)
	for _si in range(root_count):
		if ctx.corp_hand.is_empty():
			break
		var shred_idx: int = randi() % ctx.corp_hand.size()
		var shred_entry: Dictionary = ctx.corp_hand[shred_idx] as Dictionary
		ctx.corp_hand.remove_at(shred_idx)
		var shred_record: CardRecord = shred_entry.get("card_record", null) as CardRecord
		if shred_record != null:
			ctx.corp_discard.append(shred_record)
			ctx.corp_discard_facedown[shred_record.title] = true
			ctx.send_log("[Shred] Corp reveals and trashes %s from HQ." % shred_record.title)
	return false   # Corp paid — ETR stands


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_phase(phase: Phase) -> void:
	_current_phase = phase
	emit_signal("phase_changed", phase)


# ── Timing Windows Loop ───────────────────────────────────────────────────────

func _execute_paid_ability_and_rez_window(can_rez_ice: bool = false) -> void:
	var current_priority_actor: String = ctx.active_player
	var consecutive_passes := 0
	var action_count := 0
	var max_window_actions := 100

	emit_signal("timing_window_opened", current_priority_actor)

	while consecutive_passes < 2:
		if action_count >= max_window_actions:
			push_error("RunStateMachine: paid-ability window hit %d-action limit — forcing close." % max_window_actions)
			break
		action_count += 1

		var dm = ctx.corp_decision_maker if current_priority_actor == "corp" else ctx.runner_decision_maker
		if dm == null or not dm.has_method("choose_window_action"):
			consecutive_passes += 1
			current_priority_actor = "runner" if current_priority_actor == "corp" else "corp"
			continue

		var chosen_action: GameAction = await dm.choose_window_action(ctx, current_priority_actor, can_rez_ice)

		if chosen_action == null or chosen_action.type == "pass":
			consecutive_passes += 1
			current_priority_actor = "runner" if current_priority_actor == "corp" else "corp"
		else:
			consecutive_passes = 0
			await _process_window_action(chosen_action, current_priority_actor, can_rez_ice)
			# If a rez action was chosen but the card is still unrezzed, the rez
			# failed silently (e.g. cost was unaffordable after modifiers). Treat
			# that as a pass so the AI doesn't retry the same action indefinitely.
			if chosen_action.type == "rez_card":
				var iid: String = chosen_action.params.get("card_instance_id", "")
				var target: InstalledCard = ctx.get_installed_card_by_instance_id(iid) if iid != "" else null
				if target == null or not target.is_rezzed:
					consecutive_passes += 1
					current_priority_actor = "runner" if current_priority_actor == "corp" else "corp"

	emit_signal("timing_window_closed")


func _execute_encounter_window(encounter: EncounterState) -> void:
	var consecutive_passes := 0
	var current_actor: String = ctx.active_player  # runner is active player during a run
	var action_count := 0
	var max_window_actions := 100
	emit_signal("timing_window_opened", current_actor)

	while not ctx.run_ended and consecutive_passes < 2:
		if action_count >= max_window_actions:
			push_error("RunStateMachine: encounter window hit %d-action limit — forcing close." % max_window_actions)
			break
		action_count += 1

		if current_actor == "runner":
			if ctx.runner_decision_maker == null:
				consecutive_passes += 1
			else:
				var action: Dictionary = await ctx.runner_decision_maker.choose_encounter_action(encounter, ctx)
				if action.get("type", "") == "done":
					consecutive_passes += 1
				else:
					consecutive_passes = 0
					await interpreter.process_encounter_action(action, encounter, ctx, ability_registry)
					emit_signal("encounter_updated", encounter)
		else:
			var dm = ctx.corp_decision_maker
			if dm == null or not dm.has_method("choose_window_action"):
				consecutive_passes += 1
			else:
				var corp_action: GameAction = await dm.choose_window_action(ctx, "corp", false)
				if corp_action == null or corp_action.type == "pass":
					consecutive_passes += 1
				else:
					consecutive_passes = 0
					await _process_window_action(corp_action, "corp", false)

		current_actor = "runner" if current_actor == "corp" else "corp"

	emit_signal("timing_window_closed")


func _process_window_action(action: GameAction, actor: String, can_rez_ice: bool) -> void:
	match action.type:
		"rez_card":
			if actor != "corp":
				return
			var card_id = action.params.get("card_id", "")
			var instance_id = action.params.get("card_instance_id", "")
			
			var card: InstalledCard = null
			if instance_id != "":
				card = ctx.get_installed_card_by_instance_id(instance_id)
			else:
				card = ctx.get_installed_card_by_id(card_id)
				
			if card:
				if card.is_ice() and not can_rez_ice:
					ctx.send_log("[Warning] Cannot rez ICE outside of approach window positions.")
					return
				await _rez_card(card)
				
		"use_paid_ability":
			var ab_def = action.params.get("ability_def", {}) as Dictionary
			if await _verify_and_pay_costs(actor, ab_def):
				# Clear out payload trace before starting clean interaction loops
				ctx.current_event_data = {}
				await interpreter.execute_trigger(ab_def, ctx)

		"use_installed_card":
			# Corp uses a card's paw_action during a timing window.
			# Supports scored agendas (Proprionegation), installed cards, and Corp identity (LEO).
			var paw_iid: String      = action.params.get("card_instance_id", "")
			var paw_card_id: String  = action.params.get("card_id", "")
			var paw_card: InstalledCard = ctx.get_scored_agenda_by_instance_id(paw_iid)
			if paw_card == null:
				paw_card = ctx.get_installed_card_by_instance_id(paw_iid)

			# ── Identity fallback: Corp identity as PAW source ─────────────────────
			var paw_effective_iid: String = paw_iid
			if paw_card == null:
				if ctx.corp_identity != null and \
						(paw_card_id == ctx.corp_identity.id or paw_iid == "identity_corp"):
					paw_card_id       = ctx.corp_identity.id
					paw_effective_iid = "identity_corp"
				else:
					ctx.send_log("PAW use_installed_card: card '%s' not found." % (paw_iid if paw_iid != "" else paw_card_id))
					return
			else:
				paw_effective_iid = paw_card.runtime_instance_id

			var paw_card_def: Dictionary = ability_registry._abilities.get(paw_card_id, {}) as Dictionary
			var paw_def: Variant = paw_card_def.get("paw_action", null)
			if paw_def == null:
				ctx.send_log("PAW use_installed_card: '%s' has no paw_action." % paw_card_id)
				return

			# ── Server restriction (VP45 Red Room) ──────────────────────────────────
			# paw_requires_run_on_other_server: ability is only legal when the active
			# run is targeting a different server from the card's own server.
			if (paw_def as Dictionary).get("paw_requires_run_on_other_server", false):
				if not ctx.run_active or ctx.run_target_server == "" or \
						(paw_card != null and ctx.run_target_server == paw_card.server_id):
					ctx.send_log("PAW: '%s' can only be used during a run on another server." % paw_card_id)
					return

			# ── Once-per-turn guard ────────────────────────────────────────────────
			var paw_opt_key: String = (paw_def as Dictionary).get("once_per_turn_key", "")
			if paw_opt_key != "":
				var paw_opt_full := "%s:%s" % [paw_effective_iid, paw_opt_key]
				if ctx.once_per_turn_triggered.get(paw_opt_full, false):
					ctx.send_log("PAW: '%s' can only be used once per turn." % paw_card_id)
					return
				ctx.once_per_turn_triggered[paw_opt_full] = true

			# ── Click cost (e.g. VP39 ezaM swap ability costs 1 click) ────────────
			var paw_cost_clicks: int = (paw_def as Dictionary).get("cost_clicks", 0)
			if paw_cost_clicks > 0:
				if ctx.corp_clicks < paw_cost_clicks:
					ctx.send_log("PAW: '%s' — Corp needs %d click(s) but has %d." % [
						paw_card_id, paw_cost_clicks, ctx.corp_clicks])
					return
				ctx.corp_clicks -= paw_cost_clicks
				ctx.send_log("PAW: %s spends %d click(s) to use %s." % [
					ctx.corp_name(), paw_cost_clicks, paw_card_id])

			# ── Counter cost (e.g. VP35 Perfect Recall: spend 1 power counter) ─────
			var paw_cost_counters_def: Dictionary = (paw_def as Dictionary).get("cost_counters", {}) as Dictionary
			if not paw_cost_counters_def.is_empty() and paw_card != null:
				var pcc_counter: String = paw_cost_counters_def.get("counter", "power")
				var pcc_amount: int     = int(paw_cost_counters_def.get("amount", 1))
				if paw_card.get_counter(pcc_counter) < pcc_amount:
					ctx.send_log("PAW: '%s' — needs %d %s counter(s) but has %d." % [
						paw_card_id, pcc_amount, pcc_counter, paw_card.get_counter(pcc_counter)])
					return
				paw_card.remove_counter(pcc_counter, pcc_amount)
				ctx.send_log("PAW: %s spends %d %s counter(s) from %s." % [
					ctx.corp_name(), pcc_amount, pcc_counter, paw_card_id])

			ctx.current_event_data = {"card": paw_card, "card_instance_id": paw_effective_iid}
			await interpreter.execute_trigger(paw_def as Dictionary, ctx)
			ctx.current_event_data = {}

		_:
			ctx.send_log("Invalid structural window action executed: %s" % action.type)


func _verify_and_pay_costs(player: String, ab_def: Dictionary) -> bool:
	var cost: int = ab_def.get("cost", 0)
	var current_credits = ctx.get_credits(player)
	if current_credits >= cost:
		ctx.set_credits(player, current_credits - cost)
		return true
	return false
