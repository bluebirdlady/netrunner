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
	ctx.runner_cannot_steal_or_trash_this_run         = false # reset for VP31 Vertigo
	ctx.runner_cannot_access_except_self_card_id      = ""    # reset for Adrian Seis
	ctx.global_ice_strength_bonus_this_run    = 0     # reset for VP39 ezaM
	ctx.beta_build_installed_card_id          = ""    # reset for VP19 Beta Build
	ctx.runner_steal_trash_blocked_card_ids   = []    # reset for VP35 Perfect Recall
	ctx.runner_access_blocked_card_iids       = []    # reset for Adrian Seis
	ctx.run_success_suppressed                = false  # reset for VP64 Flagship
	ctx.runner_outside_credits_spent_pending  = 0     # reset for VP65 Shackleton Grid
	ctx.run_clicks_gained_this_run            = 0     # reset for Pichação
	ctx.run_ice_derezzed_this_run             = false  # reset for Stegodon MK IV
	ctx.run_runner_broke_any_subroutine       = false  # reset for Mercury
	ctx.run_breach_redirect                   = ""     # reset for Beatriz / Eru
	ctx.run_breach_extra_accesses             = 0      # reset for Beatriz / Eru
	ctx.active_server_additional_steal_cost   = {}     # reset for Daniela Jorge Inácio
	ctx.active_server_additional_trash_cost   = {}     # reset for Daniela Jorge Inácio
	ctx.run_event_trash_credits               = 0      # reset for Bahia Bands
	ctx.run_s_dobrado_encounter_count         = 0      # reset for S-Dobrado
	ctx.arissana_installed_this_run_iid       = ""    # reset for Arissana

	ctx.send_log("--- Run on %s begins ---" % server.display_name())
	await _phase_initiation()


# ── Phase 1: Initiation ───────────────────────────────────────────────────────

func _phase_initiation() -> void:
	_set_phase(Phase.INITIATION)
	ctx.send_log("[Initiation] Run declared on %s." % _target_server.display_name())

	# Notify structural event hooks that a run has commenced
	await ctx.notify_event("run_start", {"server_id": _target_server.server_id}, interpreter)

	# Re-snapshot ice positions: a run_start effect may have reordered ice on the server
	# (e.g. Tributary moving itself to the outermost position).
	_ice_positions = _target_server.ice.duplicate()

	# Daniela Jorge Inácio (TAI): scan the target server root for rezzed cards that impose
	# additional steal/trash costs. Populate ctx fields so _steal_agenda/_offer_trash can check.
	for _dji_root in _target_server.root:
		var _dji_c: InstalledCard = _dji_root as InstalledCard
		if _dji_c == null or not _dji_c.is_rezzed:
			continue
		var _dji_def: Dictionary = ability_registry._abilities.get(_dji_c.card_id, {}) as Dictionary
		var _dji_sc: Dictionary = _dji_def.get("additional_steal_cost", {}) as Dictionary
		if not _dji_sc.is_empty():
			ctx.active_server_additional_steal_cost = _dji_sc
		var _dji_tc: Dictionary = _dji_def.get("additional_trash_cost", {}) as Dictionary
		if not _dji_tc.is_empty():
			ctx.active_server_additional_trash_cost = _dji_tc

	# Front Company (TAI): if the runner runs Archives and Front Company is rezzed in a
	# server with no ice, deal 2 net damage before the first approach.
	if _target_server.server_id == "archives":
		for fc_srv in ctx.servers.values():
			var fc_s: Server = fc_srv as Server
			if fc_s.server_id == "archives":
				continue
			for fc_root in fc_s.root:
				var fc_c: InstalledCard = fc_root as InstalledCard
				if fc_c == null or not fc_c.is_rezzed or fc_c.card_id != "front_company":
					continue
				if fc_s.ice.is_empty():
					ctx.send_log("[Front Company] Runner runs Archives while Front Company's server is unprotected — 2 net damage.")
					await interpreter.execute_trigger(
						{"effects": [{"type": "deal_damage", "params": {"damage_type": "net", "amount": 2}}]}, ctx)
					if ctx.game_over:
						await _phase_end()
						return

	# Window of Opportunity: runner derezzed 1 ice before this run — offer choice now (initiation).
	if ctx.run_modifiers.get("woo_active", false):
		ctx.run_modifiers.erase("woo_active")
		var woo_rezzed_ice: Array = []
		for woo_ic in _target_server.ice:
			var woo_c: InstalledCard = woo_ic as InstalledCard
			if woo_c != null and woo_c.is_rezzed:
				woo_rezzed_ice.append(woo_c)
		if not woo_rezzed_ice.is_empty():
			var woo_target: InstalledCard = null
			var woo_dm: Object = ctx.runner_decision_maker
			if woo_dm != null and woo_dm.has_method("choose_target_ice"):
				woo_target = await woo_dm.choose_target_ice(woo_rezzed_ice, "Window of Opportunity", ctx)
			else:
				woo_target = woo_rezzed_ice[0] as InstalledCard
			if woo_target != null:
				ctx.run_modifiers["woo_derez_iid"] = woo_target.runtime_instance_id
				woo_target.is_rezzed = false
				ctx.send_log("Window of Opportunity: %s is derezzed." % woo_target.display_name())

	# Cataloguer / breach-only: skip all ice and go straight to the root zone.
	if ctx.run_modifiers.get("skip_ice_to_breach", false):
		ctx.run_modifiers.erase("skip_ice_to_breach")
		_ice_positions.clear()

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

	# Alarm Clock: on first ice approach, runner may spend 2 clicks to bypass.
	if ctx.run_modifiers.get("alarm_clock_active", false) and _ice_index == 0 and ice_card.is_rezzed:
		ctx.run_modifiers.erase("alarm_clock_active")
		if ctx.runner_clicks >= 2:
			var ac_use := false
			var ac_dm: Object = ctx.runner_decision_maker
			if ac_dm != null and ac_dm.has_method("choose_optional_ability"):
				ac_use = await ac_dm.choose_optional_ability(
					"Alarm Clock: spend 2 [click] to bypass %s?" % ice_card.display_name(), ctx)
			else:
				ac_use = true  # AI: always bypass if possible
			if ac_use:
				ctx.runner_clicks -= 2
				ctx.run_modifiers["bypass_current_ice"] = true
				ctx.send_log("Alarm Clock: Runner spends 2 clicks to bypass %s." % ice_card.display_name())
	elif ctx.run_modifiers.get("alarm_clock_active", false) and _ice_index == 0:
		ctx.run_modifiers.erase("alarm_clock_active")  # consume even if not used (unrezzed ice)

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

	# Fire the ice's own "when encountered" abilities (e.g. Jaguarundi's tag-or-click).
	# These are interruptible by AirbladeX (JSRF Ed.) — see _fire_ice_when_encountered().
	await _fire_ice_when_encountered(ice_card)
	if ctx.run_ended:
		await _phase_end()
		return

	# S-Dobrado (TAI): first encountered rezzed ice is bypassed automatically.
	# At Threat 4, the runner may spend [click] to bypass the second encountered ice.
	# Threat level is checked at the moment the encounter begins (Archer ruling:
	# if threat drops during the encounter window, the ability is no longer active).
	if ctx.run_modifiers.get("s_dobrado_active", false) and ice_card.is_rezzed:
		var _sdb_n: int = ctx.run_s_dobrado_encounter_count
		ctx.run_s_dobrado_encounter_count += 1
		if _sdb_n == 0:
			ctx.run_modifiers["bypass_current_ice"] = true
			ctx.send_log("[S-Dobrado] First encountered ice (%s) — bypassed." % ice_card.display_name())
		elif _sdb_n == 1 and ctx.threat_level() >= 4:
			var _sdb_spend := false
			var _sdb_dm: Object = ctx.runner_decision_maker
			if _sdb_dm != null and _sdb_dm.has_method("choose_optional_ability"):
				_sdb_spend = await _sdb_dm.choose_optional_ability(
					"S-Dobrado (Threat 4): spend [click] to bypass %s?" % ice_card.display_name(), ctx)
			else:
				_sdb_spend = ctx.runner_clicks > 0  # AI: spend if possible
			if _sdb_spend and ctx.runner_clicks > 0:
				ctx.runner_clicks -= 1
				ctx.run_modifiers["bypass_current_ice"] = true
				ctx.send_log("[S-Dobrado] Threat 4 — Runner spends [click] to bypass %s." % ice_card.display_name())

	# Bypass: runner ability set this flag during encounter_ice — skip subroutines entirely
	if ctx.run_modifiers.get("bypass_current_ice", false):
		ctx.run_modifiers.erase("bypass_current_ice")
		ctx.send_log("[Bypass] %s is bypassed — subroutines do not fire." % ice_card.display_name())
		# Fire bypass event so hardware such as Capybara can respond (derez, etc.)
		await ctx.notify_event("runner_bypasses_ice",
			{"ice": ice_card, "card_instance_id": ice_card.runtime_instance_id}, interpreter)
		if ctx.run_ended:
			await _phase_end()
			return
		await _phase_movement()
		return

	# Tracks whether all subroutines on this ice were broken (for Sipa pass_ice condition).
	# Default true — blank ice has zero subs, so vacuously all are "broken".
	var _all_subs_broken_for_pass: bool  = true
	# Tracks whether any subroutine was broken by a decoder (for VSA on_runner_passes).
	# Captured from EncounterState.broken_with_decoder after the encounter window.
	var _pass_broken_with_decoder: bool  = false

	var subroutines: Array = ability_registry.get_subroutines_for_card(ice_card.card_id, ice_card)

	# Starlit Knight (TAI): at Threat N, append X dynamic subs where X = count_source.
	var _dyn_ab: Dictionary = ability_registry._abilities.get(ice_card.card_id, {}) as Dictionary
	if _dyn_ab.has("threat_dynamic_subs") and ice_card.is_rezzed:
		var _dyn_def: Dictionary   = _dyn_ab["threat_dynamic_subs"] as Dictionary
		var _dyn_threshold: int    = _dyn_def.get("threat", 999)
		if ctx.threat_level() >= _dyn_threshold:
			var _dyn_count_source: String = _dyn_def.get("count_source", "")
			var _dyn_n: int = 0
			match _dyn_count_source:
				"runner_tags": _dyn_n = ctx.runner_tags
			var _dyn_sub: Dictionary = _dyn_def.get("sub", {"label": "End the run.", "effects": [{"type": "end_run"}]})
			for _dyn_i in range(_dyn_n):
				subroutines.append(_dyn_sub.duplicate(true))

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
		ctx.set_meta("_current_encounter", encounter)
		# Apply global ICE strength bonus for this run (VP39 ezaM sub 2)
		if ctx.global_ice_strength_bonus_this_run != 0:
			encounter.ice_strength += ctx.global_ice_strength_bonus_this_run
		# Passive tagged-runner strength bonus (e.g. Capacitor: +2 str while Runner is tagged)
		var _enc_ab_def: Dictionary = ability_registry._abilities.get(ice_card.card_id, {}) as Dictionary
		var _enc_tagged_bonus: int = _enc_ab_def.get("strength_bonus_while_runner_tagged", 0)
		if _enc_tagged_bonus > 0 and ctx.runner_is_tagged():
			encounter.ice_strength += _enc_tagged_bonus
			ctx.send_log("[Encounter] %s: +%d str (Runner is tagged)." % [ice_card.display_name(), _enc_tagged_bonus])
		# Brasilia Government Grid: +3 str for ice marked as boosted this run.
		var _enc_brasilia_boosted: Array = ctx.run_modifiers.get("brasilia_boosted_ice_iids", []) as Array
		if ice_card.runtime_instance_id in _enc_brasilia_boosted:
			encounter.ice_strength += 3
			ctx.send_log("[Encounter] %s: +3 str (Brasilia Government Grid)." % ice_card.display_name())

		# Logjam (and similar): ice strength = base + advancement counters on this ice.
		if ability_registry.get_flag(ice_card.card_id, "str_from_advance_tokens"):
			var _adv_str_bonus: int = ice_card.get_counter("advancement")
			if _adv_str_bonus > 0:
				encounter.ice_strength += _adv_str_bonus
				ctx.send_log("[Encounter] %s: +%d str from %d advancement token(s)." % [
					ice_card.display_name(), _adv_str_bonus, _adv_str_bonus])
		# Boto (and similar): +N str at threat level >= threshold.
		var _enc_threat_str_def: Dictionary = (_enc_ab_def.get("strength_bonus_threat", {}) as Dictionary)
		if not _enc_threat_str_def.is_empty():
			var _enc_ts_bonus: int     = _enc_threat_str_def.get("amount", 2)
			var _enc_ts_threshold: int = _enc_threat_str_def.get("threat_gte", 4)
			if ctx.threat_level() >= _enc_ts_threshold:
				encounter.ice_strength += _enc_ts_bonus
				ctx.send_log("[Encounter] %s: +%d str (threat %d ≥ %d)." % [
					ice_card.display_name(), _enc_ts_bonus, ctx.threat_level(), _enc_ts_threshold])
		# Semak-samun style: restrict subroutine breaking to fracters only (AI excluded)
		if ability_registry.get_flag(ice_card.card_id, "fracter_only_break"):
			encounter.fracter_only_break = true
		# Isaac Liberdade (and similar trojans): if the encountered ice has advancement
		# counters, grant a strength bonus from "ice_strength_bonus_if_advanced".
		for _isl_rig in ctx.runner_rig:
			var _isl_ic: InstalledCard = _isl_rig as InstalledCard
			if _isl_ic == null or _isl_ic.hosted_on_id != ice_card.runtime_instance_id:
				continue
			var _isl_ab: Dictionary = ability_registry._abilities.get(_isl_ic.card_id, {}) as Dictionary
			var _isl_bonus: int = _isl_ab.get("ice_strength_bonus_if_advanced", 0)
			if _isl_bonus > 0 and ice_card.get_counter("advancement") > 0:
				encounter.ice_strength += _isl_bonus
				ctx.send_log("[Encounter] %s: +%d str from %s (host ice has advancement token)." % [
					ice_card.display_name(), _isl_bonus, _isl_ic.display_name()])
		# Monkeywrench (and any future trojan with trojan_host_strength_mod /
		# trojan_server_strength_mod): apply strength penalties from trojans hosted on this ice.
		for _mw_hc in ice_card.hosted_cards:
			var _mw_ic: InstalledCard = _mw_hc as InstalledCard
			if _mw_ic == null or _mw_ic.card_record == null:
				continue
			var _mw_ab: Dictionary = ability_registry._abilities.get(_mw_ic.card_id, {}) as Dictionary
			# Host penalty: applied directly to this encounter's ice_strength.
			var _mw_host_mod: int = _mw_ab.get("trojan_host_strength_mod", 0)
			if _mw_host_mod != 0:
				encounter.ice_strength += _mw_host_mod
				ctx.send_log("[Encounter] %s: %+d str from %s (trojan)." % [
					ice_card.display_name(), _mw_host_mod, _mw_ic.display_name()])
			# Server-wide penalty: stored in run_modifiers so subsequent ice encounters pick it up.
			var _mw_server_mod: int = _mw_ab.get("trojan_server_strength_mod", 0)
			if _mw_server_mod != 0:
				var _mw_existing: int = ctx.run_modifiers.get("server_ice_strength_mod", 0)
				ctx.run_modifiers["server_ice_strength_mod"] = _mw_existing + _mw_server_mod
				ctx.send_log("[Encounter] %s grants server-wide str %+d (all other ice this run)." % [
					_mw_ic.display_name(), _mw_server_mod])
		# Apply any accumulated server-wide ice strength penalty from trojans passed earlier this run.
		# (Applies to every ice encounter; the host ice's own trojan was handled above.)
		var _mw_srv_penalty: int = ctx.run_modifiers.get("server_ice_strength_mod", 0)
		if _mw_srv_penalty != 0:
			# Check if this ice is NOT the one hosting the trojan(s) that set the penalty.
			# We detect this by checking whether this ice has any hosted trojans with the key —
			# if so, the penalty was already applied via trojan_host_strength_mod above,
			# and the server penalty should only hit *other* ice.
			var _mw_this_ice_hosts_trojan := false
			for _mw_chk in ice_card.hosted_cards:
				var _mw_chk_ic: InstalledCard = _mw_chk as InstalledCard
				if _mw_chk_ic != null:
					var _mw_chk_ab: Dictionary = ability_registry._abilities.get(_mw_chk_ic.card_id, {}) as Dictionary
					if _mw_chk_ab.get("trojan_server_strength_mod", 0) != 0:
						_mw_this_ice_hosts_trojan = true
						break
			if not _mw_this_ice_hosts_trojan:
				encounter.ice_strength += _mw_srv_penalty
				ctx.send_log("[Encounter] %s: %+d str (server-wide trojan penalty)." % [
					ice_card.display_name(), _mw_srv_penalty])

		# Populate corp ice trash abilities (e.g. M.I.C.: [trash]: Runner spends [click] or run ends).
		ctx.corp_ice_trash_abilities_available = []
		var _enc_ice_pab: Variant = ability_registry._abilities.get(ice_card.card_id, {}).get("ice_paid_ability", null)
		if _enc_ice_pab != null:
			ctx.corp_ice_trash_abilities_available = [{"card": ice_card, "ability": _enc_ice_pab as Dictionary}]

		emit_signal("encounter_started", encounter)

		# NSG 6.5.3.b: symmetric PAW — both players use paid abilities; runner may also break subs
		await _execute_encounter_window(encounter)
		ctx.corp_ice_trash_abilities_available = []  # clear after encounter window closes
		if ctx.has_meta("_current_encounter"):
			ctx.remove_meta("_current_encounter")

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

		# Attini (TAI): if this ice has runner_cannot_pay_subs_at_threat and threat is met,
		# block credit spending during subroutine resolution.
		var _att_threshold: int = ability_registry._abilities.get(ice_card.card_id, {}).get("runner_cannot_pay_subs_at_threat", -1)
		if _att_threshold >= 0 and ice_card.is_rezzed and ctx.threat_level() >= _att_threshold:
			ctx.runner_cannot_spend_credits_during_sub_resolution = true

		# Resolve unbroken subroutines
		for i in range(subroutines.size()):
			if encounter.is_broken(i):
				ctx.send_log("[Encounter] Subroutine %d broken." % i)
				emit_signal("subroutine_broken", ice_card, i)
				ctx.run_runner_broke_any_subroutine = true  # Mercury: track sub-break this run
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
				ctx.runner_cannot_spend_credits_during_sub_resolution = false
				# Fire encounter_ended so post-encounter triggers can react (e.g. Knowledge Seeker)
				await ctx.notify_event("encounter_ended", {"ice": ice_card}, interpreter)
				await _phase_end()
				return

		ctx.runner_cannot_spend_credits_during_sub_resolution = false

		# Determine if all subroutines were broken (for VP23 Sipa pass_ice condition)
		_all_subs_broken_for_pass = true
		for i in range(subroutines.size()):
			if not encounter.is_broken(i):
				_all_subs_broken_for_pass = false
				break
		# Capture decoder-break flag for VSA on_runner_passes condition.
		_pass_broken_with_decoder = encounter.broken_with_decoder

	# Store pass_ice event data flags
	ctx.run_modifiers["last_ice_all_subs_broken"]    = _all_subs_broken_for_pass
	ctx.run_modifiers["last_ice_broken_with_decoder"] = _pass_broken_with_decoder

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
		var pass_is_outermost: bool        = (_ice_index == 0)
		var pass_all_subs_broken: bool     = ctx.run_modifiers.get("last_ice_all_subs_broken", false)
		var pass_broken_with_decoder: bool = ctx.run_modifiers.get("last_ice_broken_with_decoder", false)
		ctx.run_modifiers.erase("last_ice_all_subs_broken")
		ctx.run_modifiers.erase("last_ice_broken_with_decoder")
		await ctx.notify_event("pass_ice", {
			"ice":             _ice_positions[_ice_index],
			"is_outermost":    pass_is_outermost,
			"all_subs_broken": pass_all_subs_broken
		}, interpreter)

		# Fire ice-specific and trojan on-pass triggers (Phoneutria, Tatu-Bola, VSA, Pichação).
		# These run AFTER the general pass_ice event and BEFORE the Sisyphus re-encounter check.
		await _fire_on_pass_triggers(_ice_positions[_ice_index], pass_broken_with_decoder)
		# Tatu-Bola (and similar pass-swap effects): update _ice_positions snapshot so any
		# re-encounter (Sisyphus Protocol etc.) uses the newly installed ice, not the departed one.
		if ctx.has_meta("pass_swap_ice"):
			var psw_ic: InstalledCard = ctx.get_meta("pass_swap_ice") as InstalledCard
			ctx.remove_meta("pass_swap_ice")
			if psw_ic != null and _ice_index < _ice_positions.size():
				_ice_positions[_ice_index] = psw_ic
		if ctx.run_ended:
			await _phase_end()
			return

	# Sisyphus Protocol (and similar scored-agenda effects): Corp may force re-encounter
	# of the just-passed ice. Checked before the PAW so the runner cannot jack out first.
	if ctx.run_modifiers.get("re_encounter_current_ice", false):
		ctx.run_modifiers.erase("re_encounter_current_ice")
		if _ice_index < _ice_positions.size():
			await _phase_encounter_ice(_ice_positions[_ice_index])
			return

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
			var _tow_was_zero: bool = (ctx.runner_tags == 0)
			ctx.runner_tags += 1
			ctx.send_log("Transfer of Wealth: %s takes 1 tag (%d total)." % [ctx.runner_name(), ctx.runner_tags])
			await ctx.notify_event("runner_takes_tags", {"amount": 1, "from_zero": _tow_was_zero}, interpreter)
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

	# ── Breach redirect (Beatriz Friere Gonzalez, Eru Ayase-Pessoa) ─────────────
	# If a redirect is set, swap _target_server for the breach phase only.
	# Extra accesses are merged into run_modifiers["bonus_access"] for _breach_server.
	var _redirect_original_server: Server = null
	if ctx.run_breach_redirect != "":
		var _redir_server: Server = ctx.get_server(ctx.run_breach_redirect)
		if _redir_server != null:
			ctx.send_log("[Breach Redirect] Breach redirected from %s to %s." % [
				_target_server.display_name(), _redir_server.display_name()])
			_redirect_original_server = _target_server
			_target_server = _redir_server
		ctx.run_breach_redirect = ""   # consumed
	if ctx.run_breach_extra_accesses > 0:
		ctx.run_modifiers["bonus_access"] = \
			ctx.run_modifiers.get("bonus_access", 0) + ctx.run_breach_extra_accesses
		ctx.run_breach_extra_accesses = 0  # consumed

	# ── Privileged Access: alternative breach for Archives ───────────────────────
	if ctx.run_modifiers.get("privileged_access_active", false) \
			and _target_server != null and _target_server.server_id == "archives":
		ctx.run_modifiers.erase("privileged_access_active")
		var pa_use_alt := false
		var pa_threat3: bool = ctx.threat_level() >= 3
		var pa_prompt: String = "Privileged Access: take 1 tag to install a card from heap " + \
			("(or a program, Threat 3)" if pa_threat3 else "") + " for 2cr less instead of breaching?"
		if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
			pa_use_alt = await ctx.runner_decision_maker.choose_optional_ability(pa_prompt, ctx)
		else:
			pa_use_alt = true  # AI default: always take the install
		if pa_use_alt:
			await interpreter._execute_effect({"type": "privileged_access_install", "params": {"threat3": pa_threat3}}, ctx, null)
		else:
			await _breach_server()
	else:
		await _breach_server()

	# Restore original target server if a redirect was applied.
	if _redirect_original_server != null:
		_target_server = _redirect_original_server

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

	# Window of Opportunity: Corp may rez the derezed ice for free after the run.
	if ctx.run_modifiers.has("woo_derez_iid"):
		var woo_end_iid: String = ctx.run_modifiers["woo_derez_iid"]
		ctx.run_modifiers.erase("woo_derez_iid")
		var woo_end_ice: InstalledCard = ctx.get_ice_by_instance_id(woo_end_iid)
		if woo_end_ice != null and not woo_end_ice.is_rezzed:
			var woo_corp_dm: Object = ctx.corp_decision_maker
			var woo_do_rez := false
			if woo_corp_dm != null and woo_corp_dm.has_method("choose_optional_ability"):
				woo_do_rez = await woo_corp_dm.choose_optional_ability(
					"Window of Opportunity: rez %s for free?" % woo_end_ice.display_name(), ctx)
			else:
				woo_do_rez = true  # AI: always rez for free
			if woo_do_rez:
				woo_end_ice.is_rezzed = true
				if woo_end_ice.runtime_instance_id != "":
					ctx.ice_rezzed_this_turn_instance_ids.append(woo_end_ice.runtime_instance_id)
				ctx.send_log("Window of Opportunity: Corp rezzes %s for free." % woo_end_ice.display_name())
				# Fire on_rez trigger
				var woo_ab_reg: AbilityRegistry = ability_registry
				var woo_on_rez = woo_ab_reg.get_on_rez(woo_end_ice.card_id)
				if woo_on_rez != null:
					ctx.current_event_data = {"card": woo_end_ice, "card_instance_id": woo_end_ice.runtime_instance_id}
					await interpreter.execute_trigger(woo_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}

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

	# Arissana Rocha Nahu: Street Artist (TAI): if the runner installed a program via Arissana
	# this run, check whether it is a trojan. If not, trash it at run end.
	if ctx.arissana_installed_this_run_iid != "":
		var aris_end_iid: String = ctx.arissana_installed_this_run_iid
		ctx.arissana_installed_this_run_iid = ""
		var aris_prog: InstalledCard = ctx.get_installed_card_by_instance_id(aris_end_iid)
		if aris_prog != null:
			var aris_is_trojan: bool = ability_registry.get_flag(aris_prog.card_id, "install_on_ice")
			if not aris_is_trojan:
				ctx.runner_rig.erase(aris_prog)
				ctx.unregister_all_card_effects(aris_end_iid)
				if aris_prog.card_record != null:
					ctx.runner_discard.append(aris_prog.card_record)
					ctx.send_log("[Arissana] %s is not a trojan — trashed at run end." % aris_prog.display_name())
			else:
				ctx.send_log("[Arissana] %s is a trojan — stays installed." % aris_prog.display_name())

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

	# Mercury: Chrome Libertador (TAI): once per turn, when breaching HQ or R&D, if the
	# runner did not break any subroutines this run, may access 1 additional card.
	# Rulings: "once per turn" spans all runs (not per-run); optional ("you may");
	# Divide and Conquer: bonus applies to HQ or R&D, not both in the same trigger.
	if ctx.runner_identity != null and ctx.runner_identity.id == "mercury" \
			and not ctx.run_runner_broke_any_subroutine \
			and _target_server.server_id in ["hq", "rd"] \
			and not ctx.once_per_turn_triggered.get("mercury:bonus_access", false):
		var merc_use := false
		var merc_dm: Object = ctx.runner_decision_maker
		if merc_dm != null and merc_dm.has_method("choose_optional_ability"):
			merc_use = await merc_dm.choose_optional_ability(
				"Mercury: Chrome Libertador — access 1 additional card from %s?" % \
				_target_server.server_id.to_upper(), ctx)
		else:
			merc_use = true   # AI: always take bonus access
		if merc_use:
			ctx.once_per_turn_triggered["mercury:bonus_access"] = true
			match _target_server.server_id:
				"hq":
					var merc_available: Array = []
					for mi in range(ctx.corp_hand.size()):
						if mi not in _hq_accessed_indices:
							merc_available.append(mi)
					merc_available.shuffle()
					if not merc_available.is_empty():
						access_list.append(ctx.corp_hand[merc_available[0]])
						_hq_accessed_indices.append(merc_available[0])
				"rd":
					var merc_next: int = access_list.size()   # next card index in R&D
					if merc_next < ctx.corp_deck.size():
						access_list.append(ctx.corp_deck[merc_next])
			ctx.send_log("[Mercury] No subroutines broken this run — +1 bonus access on %s." % \
				_target_server.server_id.to_upper())

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

		# ── Heliamphora interrupt: fire before_access, then check for redirect ──
		# Extract card_record from whatever target type we have.
		var ba_card_record: CardRecord = null
		if target is CardRecord:
			ba_card_record = target as CardRecord
		elif target is InstalledCard:
			ba_card_record = (target as InstalledCard).card_record
		elif target is Dictionary:
			ba_card_record = (target as Dictionary).get("card_record", null) as CardRecord
		ctx.run_modifiers.erase("access_redirected_to_heliamphora")
		await ctx.notify_event("before_access", {
			"card": ba_card_record,
			"server_id": _target_server.server_id
		}, interpreter)
		if ctx.run_modifiers.has("access_redirected_to_heliamphora"):
			# Runner chose to host this card on Heliamphora — skip normal access.
			var ba_helio_iid: String = ctx.run_modifiers.get("access_redirected_to_heliamphora", "") as String
			ctx.run_modifiers.erase("access_redirected_to_heliamphora")
			var ba_helio: InstalledCard = ctx.get_installed_card_by_instance_id(ba_helio_iid)
			if ba_helio != null and ba_card_record != null:
				# Move the card from corp_discard (Archives) to Heliamphora's hosted zone.
				ctx.corp_discard.erase(ba_card_record)
				ba_helio.faceup_hosted_cards.append(ba_card_record)
				ctx.send_log("[Heliamphora] %s hosted — not accessed this breach." % ba_card_record.title)
			access_count += 1
			continue

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

	# Adrian Seis (TAI) — psi mismatch (Corp wins): runner can only access Adrian Seis
	# itself.  Since Adrian Seis is an upgrade in a server root, its IID is stored; every
	# other card's IID won't match, so the entire breach is silently blocked.
	if ctx.runner_cannot_access_except_self_card_id != "":
		var aeis_allowed: String = ctx.runner_cannot_access_except_self_card_id
		var aeis_this: String    = instance_id if instance_id != "" else card_id
		if aeis_this != aeis_allowed:
			ctx.send_log("[Adrian Seis] Access to %s blocked — runner may only access Adrian Seis this run." % \
				(card_record.title if card_record else card_id))
			return

	# Adrian Seis (TAI) — psi match (runner wins): runner cannot access Adrian Seis itself
	# (or any other card explicitly added to this blocklist).
	if not ctx.runner_access_blocked_card_iids.is_empty():
		var aeis2_this: String = instance_id if instance_id != "" else card_id
		if aeis2_this in ctx.runner_access_blocked_card_iids:
			ctx.send_log("[Adrian Seis] Access to %s blocked this run." % \
				(card_record.title if card_record else card_id))
			return

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
		var _bangun_was_zero: bool = (ctx.runner_tags == 0)
		ctx.runner_tags += 1
		ctx.send_log("BANGUN: Runner gains 1 tag (%d total)." % ctx.runner_tags)
		await ctx.notify_event("runner_takes_tags", {"amount": 1, "from_zero": _bangun_was_zero}, interpreter)
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

	# ── Eye for an Eye: runner may trash 1 grip card to trash the accessed card ──
	# Active when run_modifiers["efa_active"] is set. Does not apply to agendas.
	if ctx.run_modifiers.get("efa_active", false) and card_record != null \
			and not card_record.is_agenda() and not ctx.runner_hand.is_empty():
		var efa_use := false
		if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
			efa_use = await ctx.runner_decision_maker.choose_optional_ability(
				"Eye for an Eye: trash 1 card from grip to trash %s?" % card_record.title, ctx)
		else:
			efa_use = true  # AI default: always use it
		if efa_use:
			# Runner picks a card from grip to discard
			var efa_cost_card: Variant = ctx.runner_hand[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_hand"):
				efa_cost_card = await ctx.runner_decision_maker.choose_card_from_hand(ctx.runner_hand.duplicate(), ctx)
			if efa_cost_card != null and ctx.runner_hand.has(efa_cost_card):
				ctx.runner_hand.erase(efa_cost_card)
				var efa_cost_cr: CardRecord = (efa_cost_card as Dictionary).get("card_record", null) as CardRecord
				ctx.runner_discard.append(efa_cost_cr if efa_cost_cr != null else efa_cost_card)
				ctx.send_log("Eye for an Eye: %s discards %s." % [
					ctx.runner_name(), efa_cost_cr.title if efa_cost_cr != null else "a card"])
			# Trash the accessed corp card
			if card is InstalledCard:
				var efa_inst: InstalledCard = card as InstalledCard
				var efa_srv: Server = ctx.get_server(efa_inst.server_id)
				if efa_srv != null:
					efa_srv.remove_from_root(efa_inst)
					ctx.remove_empty_remote_servers()
				ctx.unregister_all_card_effects(efa_inst.runtime_instance_id)
				if not efa_inst.is_rezzed:
					ctx.corp_discard_facedown[card_record.title] = true
			ctx.corp_discard.append(card_record)
			ctx.send_log("Eye for an Eye: trashes %s." % card_record.title)
			await ctx.notify_event("runner_trashes_during_breach", {"card_id": card_id}, interpreter)
			var _efa_outcome := "accessed"
			emit_signal("card_accessed", card_record, _efa_outcome)
			if ctx.has_meta("on_card_display_done"):
				var efa_cb: Callable = ctx.get_meta("on_card_display_done") as Callable
				await efa_cb.call(card_record, _efa_outcome)
			return

	# ── Cupellation: runner may spend 1cr to host the accessed card instead of accessing normally ──
	# Active when run_modifiers["cupellation_active"] is set (set by before_breach trigger).
	# Not available for agendas (those still steal normally) or cards in Archives.
	if ctx.run_modifiers.get("cupellation_active", false) and card_record != null \
			and not card_record.is_agenda() and is_installed:
		var cup_use := false
		if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
			cup_use = await ctx.runner_decision_maker.choose_optional_ability(
				"Cupellation: spend 1cr to host %s instead of accessing it?" % card_record.title, ctx)
		else:
			cup_use = (ctx.runner_credits >= 1)
		if cup_use and ctx.runner_credits >= 1:
			ctx.runner_credits -= 1
			# Find Cupellation in the rig
			var cup_ic: InstalledCard = null
			for cup_rig in ctx.runner_rig:
				var cup_c: InstalledCard = cup_rig as InstalledCard
				if cup_c != null and cup_c.card_id == "cupellation":
					cup_ic = cup_c
					break
			if cup_ic != null:
				cup_ic.hosted_corp_cards.append(card_record)
				# Remove from server without giving runner access benefits
				if card is InstalledCard:
					var cup_inst: InstalledCard = card as InstalledCard
					var cup_srv: Server = ctx.get_server(cup_inst.server_id)
					if cup_srv != null:
						cup_srv.remove_from_root(cup_inst)
						ctx.remove_empty_remote_servers()
					ctx.unregister_all_card_effects(cup_inst.runtime_instance_id)
				ctx.send_log("Cupellation: captures %s (hosted on Cupellation, not accessed normally)." % card_record.title)
				var _cup_outcome := "cupellation_captured"
				emit_signal("card_accessed", card_record, _cup_outcome)
				if ctx.has_meta("on_card_display_done"):
					var cup_cb: Callable = ctx.get_meta("on_card_display_done") as Callable
					await cup_cb.call(card_record, _cup_outcome)
				return
			else:
				ctx.runner_credits += 1  # refund — Cupellation not found
				ctx.send_log("Cupellation: card not found in rig.")

	if card_record.is_agenda():
		await _steal_agenda(card_record, card)
	elif card_record.is_asset() or card_record.card_type == "upgrade":
		# Rule 7.1.5.b: runner cannot trash cards in Archives.
		# Cards accessed from HQ or R&D are not installed but still trashable.
		var _in_archives: bool = _target_server != null and _target_server.server_id == "archives"
		if not _in_archives:
			await _offer_trash(card, card_record)

	# Stop if game ended during steal or trash resolution
	if ctx.game_over:
		return

	# Amelia Earhart: count each access on HQ and R&D
	if _target_server != null and _target_server.server_id in ["hq", "rd"]:
		ctx.amelia_hq_rd_access_count += 1

	# Notify listeners about this card access (for Amelia Earhart tracking, etc.)
	await ctx.notify_event("card_accessed_event", {
		"card_id": card_id,
		"server_id": _target_server.server_id if _target_server != null else "",
		"card_record": card_record
	}, interpreter)

	# Determine outcome for display
	var _outcome := "accessed"
	if card_record != null and card_record.is_agenda():
		_outcome = "stolen"
	emit_signal("card_accessed", card_record, _outcome)

	# Wait for the UI to finish displaying this card before accessing the next one.
	if ctx.has_meta("on_card_display_done"):
		var cb: Callable = ctx.get_meta("on_card_display_done") as Callable
		await cb.call(card_record, _outcome)

func _steal_agenda(card_record: CardRecord, source: Variant = null) -> void:
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

	# Daniela Jorge Inácio (TAI): additional steal cost (e.g. discard 2 grip cards to stack).
	if not ctx.active_server_additional_steal_cost.is_empty():
		var dji_sc: Dictionary = ctx.active_server_additional_steal_cost
		var dji_amount: int    = dji_sc.get("params", {}).get("amount", 2)
		if ctx.runner_hand.size() < dji_amount:
			ctx.send_log("[Access] Runner cannot steal %s — needs %d grip cards for Daniela cost (has %d)." % [
				card_record.title, dji_amount, ctx.runner_hand.size()])
			return
		await interpreter.execute_trigger({"effects": [dji_sc]}, ctx)
		ctx.send_log("[Daniela] Runner discards %d card(s) from grip to steal %s." % [dji_amount, card_record.title])

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

	# Remove from HQ hand or R&D deck when the card was accessed as an uninstalled card.
	# Without this, the same copy can be stolen on every subsequent HQ/R&D access.
	if source is Dictionary:
		ctx.corp_hand.erase(source)
	elif source is CardRecord:
		ctx.corp_deck.erase(source)

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

	# Register ongoing listeners for agendas with persistent effects in runner score area
	# (e.g. The Basalt Spire: before_breach bonus access to HQ).
	_register_stolen_agenda_listeners(stolen_inst)

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


func _register_stolen_agenda_listeners(card: InstalledCard) -> void:
	# Register ongoing event listeners for agendas with persistent effects after being stolen
	# (e.g. The Basalt Spire: before_breach gives +1 access to HQ per breach of HQ).
	var instance_id: String  = card.runtime_instance_id if card.runtime_instance_id != "" else card.card_id
	var card_def: Dictionary = ability_registry._abilities.get(card.card_id, {}) as Dictionary
	if card_def.is_empty():
		return
	for event_type in [
			"corp_turn_start", "runner_turn_start", "corp_turn_end", "runner_turn_end",
			"run_start", "successful_run", "breach_complete", "runner_steals_agenda",
			"runner_takes_tags", "corp_scores_agenda", "runner_trashes_during_breach",
			"before_breach", "card_accessed_event", "runner_rig_action"]:
		var trigger_def = card_def.get(event_type, null)
		if trigger_def != null:
			ctx.register_listener(event_type, instance_id, trigger_def as Dictionary)


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

	# Total available credits includes Azimat recurring trash credits + Bahia Bands event credits
	var available: int = ctx.runner_trash_credits_available() + ctx.run_event_trash_credits

	ctx.send_log("[Access] Runner may trash %s for %d credits (Runner has %d total)." % [
		card_record.title, effective_trash_cost, available
	])
	if available < effective_trash_cost:
		ctx.send_log("[Access] Runner cannot afford to trash.")
		return

	# Daniela Jorge Inácio (TAI): additional trash cost check — runner must be able to pay
	# before they are even offered the trash option.
	var dji_trash_blocked := false
	if not ctx.active_server_additional_trash_cost.is_empty():
		var dji_tc: Dictionary = ctx.active_server_additional_trash_cost
		var dji_tc_amount: int = dji_tc.get("params", {}).get("amount", 2)
		if ctx.runner_hand.size() < dji_tc_amount:
			ctx.send_log("[Access] Runner cannot afford Daniela trash cost — needs %d grip cards (has %d)." % [
				dji_tc_amount, ctx.runner_hand.size()])
			dji_trash_blocked = true

	var should_trash := false
	if not dji_trash_blocked and ctx.runner_decision_maker != null:
		should_trash = await ctx.runner_decision_maker.choose_trash(card_record, ctx)

	if should_trash:
		# Apply Daniela additional trash cost before spending credits.
		if not ctx.active_server_additional_trash_cost.is_empty():
			var dji_tc2: Dictionary = ctx.active_server_additional_trash_cost
			await interpreter.execute_trigger({"effects": [dji_tc2]}, ctx)
		# Drain Bahia Bands run-event hosted credits before the runner's pool.
		var bb_remaining: int = effective_trash_cost
		if ctx.run_event_trash_credits > 0 and bb_remaining > 0:
			var bb_draw: int = mini(ctx.run_event_trash_credits, bb_remaining)
			ctx.run_event_trash_credits -= bb_draw
			bb_remaining -= bb_draw
			if bb_draw > 0:
				ctx.send_log("[Bahia Bands] %d hosted credit(s) spent on trash (%d remaining on event)." % [
					bb_draw, ctx.run_event_trash_credits])
		ctx.runner_spend_for_trash(bb_remaining)
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
		elif card is Dictionary:
			# Card was accessed from HQ hand — remove it from the hand array
			ctx.corp_hand.erase(card)
		elif card is CardRecord:
			# Card was accessed from R&D deck — remove it from the deck
			ctx.corp_deck.erase(card)
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

	# ── Mandatory additional rez cost (e.g. Plutus: forfeit agenda OR reveal+trash 3 HQ; Piranhas: bad pub or remove tag) ──
	var add_rez_cost_def: Variant = card_def_check.get("additional_rez_cost", null)
	if add_rez_cost_def != null:
		var arc_type: String = (add_rez_cost_def as Dictionary).get("type", "")
		if arc_type == "bad_pub_or_remove_tag":
			# Corp must take 1 bad publicity OR remove 1 tag to rez this ice (Piranhas).
			var arc_can_remove_tag: bool = ctx.runner_tags > 0
			# Corp always has the option to take bad pub; removing tag requires the runner to have one.
			# Corp chooses which cost to pay.
			var arc_pay_bad_pub: bool = true  # default: take bad pub
			if arc_can_remove_tag and ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_modes"):
				var arc_modes: Array = [
					{"label": "Take 1 bad publicity"},
					{"label": "Remove 1 tag from the Runner"}
				]
				var arc_chosen: Array = await ctx.corp_decision_maker.choose_modes(arc_modes, 1, ctx)
				arc_pay_bad_pub = (arc_chosen.is_empty() or arc_chosen[0] == 0)
			elif arc_can_remove_tag:
				# AI default: removing a tag is strictly better for the corp
				arc_pay_bad_pub = false
			if arc_pay_bad_pub:
				ctx.corp_bad_pub += 1
				ctx.send_log("[Rez] %s: Corp takes 1 bad publicity as additional rez cost (%d total)." % [
					record.title, ctx.corp_bad_pub])
			else:
				ctx.runner_tags -= 1
				ctx.send_log("[Rez] %s: Corp removes 1 Runner tag as additional rez cost (%d remaining)." % [
					record.title, ctx.runner_tags])
		elif arc_type == "forfeit_or_reveal_trash_hq":
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
	# Track all ice (and root cards) rezzed this turn by IID (Cloud Eater, Lightning Lab).
	if card.runtime_instance_id != "":
		ctx.ice_rezzed_this_turn_instance_ids.append(card.runtime_instance_id)
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
						"before_breach", "before_access", "runner_installs_virus",
						"on_advance", "breach_complete", "run_start", "runner_takes_tags",
						"archives_cards_turned_faceup",
						"hardware_trashed", "runner_spends_outside_credits", "corp_gains_bad_pub",
						"corp_purges_virus_counters", "corp_rezzes_ice"]:
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


# ── On-pass trigger firing ───────────────────────────────────────────────────
#
# Fires after the runner successfully passes a piece of ice.  Two trigger types:
# ── Arissana Rocha Nahu: Street Artist — in-run program install ───────────────
#
# Called when the runner chooses to use Arissana's once-per-turn paid ability.
# Installs 1 program from grip at normal install cost. At run end, RSM trashes
# the program unless it is a trojan (has install_on_ice: true flag).
func _arissana_install_program() -> void:
	# Filter grip for programs
	var aris_candidates: Array = []
	for aris_entry in ctx.runner_hand:
		var aris_e: Dictionary = aris_entry as Dictionary
		var aris_r: CardRecord = aris_e.get("card_record", null) as CardRecord
		if aris_r != null and aris_r.card_type == "program":
			aris_candidates.append(aris_entry)
	if aris_candidates.is_empty():
		ctx.send_log("[Arissana] No programs in grip to install.")
		return

	# Runner chooses which program
	var aris_chosen: Variant = aris_candidates[0]
	var aris_rdm: Object = ctx.runner_decision_maker
	if aris_rdm != null and aris_rdm.has_method("choose_card_from_hand"):
		aris_chosen = await aris_rdm.choose_card_from_hand(aris_candidates, ctx)
	if aris_chosen == null:
		ctx.send_log("[Arissana] Runner declines to install.")
		return

	var aris_record: CardRecord = (aris_chosen as Dictionary).get("card_record", null) as CardRecord
	if aris_record == null:
		return

	# Check install cost and MU
	var aris_cost: int = max(0, aris_record.cost if aris_record.cost >= 0 else 0)
	if ctx.runner_credits < aris_cost:
		ctx.send_log("[Arissana] Cannot afford %s (costs %d cr)." % [aris_record.title, aris_cost])
		return
	if aris_record.memory_cost > 0 and ctx.runner_mu_available() < aris_record.memory_cost:
		ctx.send_log("[Arissana] Not enough MU to install %s (%d MU needed)." % [
			aris_record.title, aris_record.memory_cost])
		return

	# Pay and install
	ctx.runner_credits -= aris_cost
	ctx.runner_hand.erase(aris_chosen)
	var aris_inst := InstalledCard.make_runtime_instance(aris_record, "runner_rig", "root", true)
	ctx.runner_rig.append(aris_inst)

	# Register listeners
	if ctx.has_meta("register_installed_card"):
		(ctx.get_meta("register_installed_card") as Callable).call(aris_inst)

	# Fire on_rez ability (install-time effects, e.g. Botulus places counters)
	var aris_on_rez = ability_registry.get_on_rez(aris_record.id)
	if aris_on_rez != null:
		ctx.current_event_data = {"card": aris_inst, "card_instance_id": aris_inst.runtime_instance_id}
		await interpreter.execute_trigger(aris_on_rez as Dictionary, ctx)
		ctx.current_event_data = {}

	# Fire install events (virus, program, card — for Cookbook, LilyPAD, Bling, etc.)
	if aris_record.has_subtype("virus"):
		await ctx.notify_event("runner_installs_virus", {
			"card": aris_inst, "card_instance_id": aris_inst.runtime_instance_id
		}, interpreter)
	await ctx.notify_event("runner_installs_program", {
		"card": aris_inst, "card_instance_id": aris_inst.runtime_instance_id
	}, interpreter)
	await ctx.notify_event("runner_installs_card", {
		"card": aris_inst, "card_instance_id": aris_inst.runtime_instance_id
	}, interpreter)

	# Track for end-of-run trojan check
	ctx.arissana_installed_this_run_iid = aris_inst.runtime_instance_id

	ctx.send_log("[Arissana] %s installs %s for %d cr. [MU: %d/%d used]" % [
		ctx.runner_name(), aris_record.title, aris_cost,
		ctx.runner_mu_used(), ctx.runner_total_mu()])


#   on_runner_passes      — defined on the ice itself (Phoneutria, Tatu-Bola, VSA)
#   on_runner_passes_host — defined on a trojan hosted on the ice (Pichação)
#
# `broken_with_decoder` is true when a decoder icebreaker broke at least one
# subroutine during the encounter — used by VSA's "ice_not_broken_with_decoder" condition.
func _fire_on_pass_triggers(ice_card: InstalledCard, broken_with_decoder: bool) -> void:
	# Build the shared event data for this pass event.
	var pass_event_data: Dictionary = {
		"ice":                 ice_card,
		"card_instance_id":    ice_card.runtime_instance_id,
		"broken_with_decoder": broken_with_decoder
	}

	# 1. Ice's own on_runner_passes ability.
	var ice_pass_def: Variant = ability_registry.get_on_runner_passes(ice_card.card_id)
	if ice_pass_def != null:
		ctx.current_event_data = pass_event_data
		await interpreter.execute_trigger(ice_pass_def as Dictionary, ctx)
		ctx.current_event_data = {}
		if ctx.run_ended:
			return

	# 2. Each trojan hosted on this ice: on_runner_passes_host.
	# Iterate a snapshot — the trojan itself may modify hosted_cards (Pichação returns to grip).
	for hc in ice_card.hosted_cards.duplicate():
		var hosted: InstalledCard = hc as InstalledCard
		if hosted == null:
			continue
		var trojan_pass_def: Variant = ability_registry.get_on_runner_passes_host(hosted.card_id)
		if trojan_pass_def == null:
			continue
		# Override card_instance_id so _get_self_card() finds the trojan, not the ice.
		var trojan_event_data: Dictionary = pass_event_data.duplicate()
		trojan_event_data["card_instance_id"] = hosted.runtime_instance_id
		ctx.current_event_data = trojan_event_data
		await interpreter.execute_trigger(trojan_pass_def as Dictionary, ctx)
		ctx.current_event_data = {}
		if ctx.run_ended:
			return


# ── AirbladeX: ice "when encountered" ability firing with interrupt hook ──────
#
# Fires each on_encounter_self ability defined for the encountered ice in order.
# Before each ability, if the runner has an AirbladeX counter, they are offered
# the interrupt: spend 1 counter to prevent that specific ability.
# Respects threat conditions defined on each ability dict ("threat": int).
func _fire_ice_when_encountered(ice_card: InstalledCard) -> void:
	var abilities: Array = ability_registry.get_on_encounter_self(ice_card.card_id)
	if abilities.is_empty():
		return

	for we_def_raw in abilities:
		var we_def: Dictionary = we_def_raw as Dictionary

		# Respect threat gating: "threat": N means only active at threat N or above.
		var we_threat: int = we_def.get("threat", 0)
		if we_threat > 0 and ctx.threat_level() < we_threat:
			continue

		# AirbladeX interrupt window — offered before this ability fires.
		if ctx.runner_has_airbladex_counter():
			var use_airbladex: bool = false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("use_airbladex_prevent_when_encountered"):
				use_airbladex = await ctx.runner_decision_maker.use_airbladex_prevent_when_encountered(
					ice_card, we_def, ctx)
			if use_airbladex:
				ctx.spend_airbladex_counter()
				ctx.send_log("[AirbladeX] %s's 'when encountered' ability prevented." % \
					ice_card.display_name())
				continue  # this ability is suppressed; check next one

		# Execute the ability.
		ctx.current_event_data = {
			"card":               ice_card,
			"card_instance_id":   ice_card.runtime_instance_id
		}
		await interpreter.execute_trigger(we_def, ctx)
		ctx.current_event_data = {}

		if ctx.run_ended:
			return  # caller will handle _phase_end


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

	# Arissana Rocha Nahu: Street Artist (TAI): once per turn, 0cr, only during a run:
	# install 1 program from grip (paying its install cost). Offered at the top of each
	# PAW window so the runner gets first priority (active player in their turn).
	# Ruling: Runner must act before the Corp can rez; once both pass, window closes.
	if ctx.run_active and ctx.runner_identity != null and \
			ctx.runner_identity.id == "arissana_rocha_nahu" and \
			not ctx.once_per_turn_triggered.get("arissana:install", false):
		var aris_dm: Object = ctx.runner_decision_maker
		var aris_use := false
		if aris_dm != null and aris_dm.has_method("choose_optional_ability"):
			aris_use = await aris_dm.choose_optional_ability(
				"Arissana Rocha Nahu: Street Artist — install a program from grip (paying its cost)?", ctx)
		# else: AI defaults to false (conserve unless DM overrides)
		if aris_use:
			ctx.once_per_turn_triggered["arissana:install"] = true
			await _arissana_install_program()

	# ── Run-time runner paid abilities (e.g. B-1001): scan rig for run_paid_ability ──
	# Offered once at the start of each PAW invocation, before the Corp/Runner loop.
	# Each card with "run_paid_ability" is offered if: run is active, condition met,
	# not yet used this turn (once_per_turn_key). Cost (e.g. remove tag) paid here.
	if ctx.run_active:
		for _rpab_card in ctx.runner_rig.duplicate():
			var rpab_ic: InstalledCard = _rpab_card as InstalledCard
			if rpab_ic == null or rpab_ic.card_record == null:
				continue
			var rpab_def: Dictionary = ability_registry._abilities.get(rpab_ic.card_id, {}) as Dictionary
			var rpab_pab: Variant = rpab_def.get("run_paid_ability", null)
			if rpab_pab == null:
				continue
			var rpab_dict: Dictionary = rpab_pab as Dictionary
			# Once-per-turn guard
			var rpab_once_key: String = rpab_dict.get("once_per_turn_key", "")
			var rpab_full_key: String = "%s:%s" % [rpab_ic.runtime_instance_id, rpab_once_key] \
				if rpab_once_key != "" else ""
			if rpab_full_key != "" and ctx.once_per_turn_triggered.get(rpab_full_key, false):
				continue
			# Condition guard
			var rpab_cond: Dictionary = rpab_dict.get("condition", {}) as Dictionary
			if not rpab_cond.is_empty() and not interpreter._evaluate_condition(rpab_cond, ctx):
				continue
			# Offer to runner DM
			var rpab_label: String = rpab_dict.get("label", "%s ability" % rpab_ic.display_name())
			var rpab_use := false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_optional_ability"):
				rpab_use = await ctx.runner_decision_maker.choose_optional_ability(rpab_label, ctx)
			# AI defaults to false — conservative (don't end run unexpectedly)
			if not rpab_use:
				continue
			# Pay cost
			var rpab_cost: Dictionary = rpab_dict.get("cost", {}) as Dictionary
			var rpab_remove_tags: int = rpab_cost.get("remove_tag", 0)
			if rpab_remove_tags > 0:
				if ctx.runner_tags < rpab_remove_tags:
					ctx.send_log("[%s] Not enough tags to pay cost." % rpab_ic.display_name())
					continue
				ctx.runner_tags -= rpab_remove_tags
				ctx.send_log("[%s] Runner removes %d tag(s) as cost. (%d remaining)" % [
					rpab_ic.display_name(), rpab_remove_tags, ctx.runner_tags])
				await ctx.notify_event("tag_removed", {"amount": rpab_remove_tags}, interpreter)
			# Mark used
			if rpab_full_key != "":
				ctx.once_per_turn_triggered[rpab_full_key] = true
			# Execute effects
			ctx.current_event_data = {"card": rpab_ic, "card_instance_id": rpab_ic.runtime_instance_id}
			var rpab_effects: Array = rpab_dict.get("effects", []) as Array
			await interpreter.execute_trigger({"effects": rpab_effects}, ctx)
			ctx.current_event_data = {}
			if ctx.run_ended:
				break

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
		"use_ice_trash_ability":
			# Corp activates an ice's trash-self paid ability (e.g. M.I.C.).
			# 1. Remove the ice from its server.
			# 2. Execute the ability's effects (e.g. runner_click_or_etr).
			if actor != "corp":
				return
			var ita_iid: String = action.params.get("card_instance_id", "")
			var ita_card: InstalledCard = ctx.get_installed_card_by_instance_id(ita_iid) if ita_iid != "" else null
			if ita_card == null:
				ctx.send_log("[ice_paid_ability] Ice not found — ignoring.")
				return
			var ita_card_id: String = ita_card.card_id
			var ita_ability: Dictionary = ability_registry._abilities.get(ita_card_id, {}) \
				.get("ice_paid_ability", {}) as Dictionary
			if ita_ability.is_empty():
				ctx.send_log("[ice_paid_ability] No ability defined on %s." % ita_card.display_name())
				return
			# Remove from server and move to Archives.
			var ita_server: Server = ctx.get_server(ita_card.server_id)
			if ita_server != null:
				ita_server.ice.erase(ita_card)
				ctx.remove_empty_remote_servers()
			ctx.unregister_all_card_effects(ita_card.runtime_instance_id)
			if ita_card.card_record != null:
				ctx.corp_discard.append(ita_card.card_record)
			ctx.corp_ice_trash_abilities_available = []  # consumed; no double-use
			ctx.send_log("Corp trashes %s — activating ice paid ability." % ita_card.display_name())
			# Execute the ability effects.
			ctx.current_event_data = {"card": ita_card, "card_instance_id": ita_card.runtime_instance_id}
			await interpreter.execute_trigger(ita_ability, ctx)
			ctx.current_event_data = {}
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

			# ── Credit cost (e.g. Brasilia Government Grid: 1cr) ─────────────────
			var paw_cost_credits: int = (paw_def as Dictionary).get("cost_credits", 0)
			if paw_cost_credits > 0:
				if ctx.corp_credits < paw_cost_credits:
					ctx.send_log("PAW: '%s' — Corp needs %d¢ but has %d." % [
						paw_card_id, paw_cost_credits, ctx.corp_credits])
					return
				ctx.corp_credits -= paw_cost_credits
				ctx.send_log("PAW: %s spends %d¢ for %s." % [ctx.corp_name(), paw_cost_credits, paw_card_id])

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

		"activate_from_hq":
			# Descent-style: Corp activates a card from HQ during a PAW window.
			# Fires the card's "hq_activate" trigger, then moves the card to Archives.
			var afhq_card_id: String = action.params.get("card_id", "")
			if afhq_card_id.is_empty():
				ctx.send_log("PAW activate_from_hq: no card_id specified.")
				return
			# Find the card in corp_hand
			var afhq_entry: Dictionary = {}
			var afhq_cr: CardRecord = null
			for afhq_e in ctx.corp_hand:
				var afhq_d: Dictionary = afhq_e as Dictionary
				var afhq_r: CardRecord = afhq_d.get("card_record", null) as CardRecord
				if afhq_r != null and afhq_r.id == afhq_card_id:
					afhq_entry = afhq_d
					afhq_cr    = afhq_r
					break
			if afhq_cr == null:
				ctx.send_log("PAW activate_from_hq: '%s' not found in HQ." % afhq_card_id)
				return
			var afhq_def: Dictionary = ability_registry._abilities.get(afhq_card_id, {}) as Dictionary
			var afhq_trigger: Variant = afhq_def.get("hq_activate", null)
			if afhq_trigger == null:
				ctx.send_log("PAW activate_from_hq: '%s' has no hq_activate trigger." % afhq_card_id)
				return
			# Remove from HQ first so the card can't be accessed during its own effect
			ctx.corp_hand.erase(afhq_entry)
			ctx.send_log("%s activates %s from HQ." % [ctx.corp_name(), afhq_cr.title])
			ctx.current_event_data = {"card_id": afhq_card_id}
			await interpreter.execute_trigger(afhq_trigger as Dictionary, ctx)
			ctx.current_event_data = {}
			# Move to Archives after activation (unless return_to_hq flag is set)
			if not afhq_def.get("return_to_hq_after_activate", false):
				ctx.corp_discard.append(afhq_cr)
				ctx.send_log("%s moves to Archives." % afhq_cr.title)
			else:
				ctx.corp_hand.append({"card_record": afhq_cr, "known": false})
				ctx.send_log("%s returns to HQ." % afhq_cr.title)

		_:
			ctx.send_log("Invalid structural window action executed: %s" % action.type)


func _verify_and_pay_costs(player: String, ab_def: Dictionary) -> bool:
	var cost: int = ab_def.get("cost", 0)
	var current_credits = ctx.get_credits(player)
	if current_credits >= cost:
		ctx.set_credits(player, current_credits - cost)
		return true
	return false
