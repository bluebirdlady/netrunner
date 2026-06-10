class_name EncounterProcessor
extends RefCounted

# ── EncounterProcessor ────────────────────────────────────────────────────────
# Handles all player actions that occur during an ice encounter:
# boosting breaker strength, breaking subroutines, spending hosted credits,
# weakening ice with virus counters, and breaking with clicks (bioroids).
#
# Extracted from AbilityInterpreter as Phase 5 of the refactor plan.
# AbilityInterpreter.process_encounter_action() delegates here.
#
# The `interpreter` argument is the AbilityInterpreter instance; it is passed
# through to ctx.check_outside_credits_trigger() which needs an Object ref for
# the runner_spends_outside_credits event callback.
# ─────────────────────────────────────────────────────────────────────────────


func process(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry,
		interpreter: Object) -> bool:

	var action_type: String = action.get("type", "")

	# Midnight Sun: Trieste Model Bioroids — Runner cannot break subs on the locked ice
	# using ANY card ability (program breaks, hardware breaks, bioroid click breaks, etc.).
	# L016 fix: verify Trieste itself is still rezzed before enforcing the lock; clear stale lock.
	if ctx.trieste_locked_ice_instance_id != "":
		var trieste_still_active: bool = false
		for t_srv_any in ctx.servers.values():
			var t_srv: Server = t_srv_any as Server
			if t_srv == null:
				continue
			for t_c_any in t_srv.root:
				var t_c: InstalledCard = t_c_any as InstalledCard
				if t_c != null and t_c.card_id == "trieste_model_bioroids" and t_c.is_rezzed:
					trieste_still_active = true
					break
			if trieste_still_active:
				break
		if not trieste_still_active:
			ctx.trieste_locked_ice_instance_id = ""   # stale lock — Trieste was trashed/derezzed

	if action_type in ["break_subroutine", "break_all", "hardware_break", "break_click"] \
			and ctx.trieste_locked_ice_instance_id != "" \
			and encounter.ice_card != null \
			and encounter.ice_card.runtime_instance_id == ctx.trieste_locked_ice_instance_id:
		ctx.send_log("[Trieste Model Bioroids] Runner card abilities cannot break subs on %s." % \
			encounter.ice_card.display_name())
		return false

	match action_type:
		"boost_strength":
			var boost_ok: bool = await _do_boost(action, encounter, ctx, ability_registry)
			await ctx.check_outside_credits_trigger(interpreter)
			return boost_ok
		"break_subroutine":
			var bs_before: int = encounter.broken_indices.size()
			var break_ok: bool = await _do_break_sub(action, encounter, ctx, ability_registry)
			if break_ok and bs_before == 0 and encounter.broken_indices.size() > 0:
				await _check_flux_capacitor(encounter, ctx, interpreter)
			if break_ok and encounter.all_broken():
				await _check_fully_broke_sentry_async(action.get("card_id", ""), encounter, ctx, ability_registry, interpreter)
			await ctx.check_outside_credits_trigger(interpreter)
			return break_ok
		"break_all":
			var ba_before: int = encounter.broken_indices.size()
			var break_all_ok: bool = await _do_break_all(action, encounter, ctx, ability_registry)
			if break_all_ok and ba_before == 0 and encounter.broken_indices.size() > 0:
				await _check_flux_capacitor(encounter, ctx, interpreter)
			if break_all_ok and encounter.all_broken():
				await _check_fully_broke_sentry_async(action.get("card_id", ""), encounter, ctx, ability_registry, interpreter)
			await ctx.check_outside_credits_trigger(interpreter)
			return break_all_ok
		"spend_hosted_credits":
			return _do_spend_hosted_credits(action, encounter, ctx)
		"weaken_ice":
			return _do_weaken_ice(action, encounter, ctx)
		"break_with_click":
			return _do_break_with_click(action, encounter, ctx, ability_registry)
		"break_self_sub":
			# N-Pot: runner pays cost credits to break one subroutine on the ice itself.
			var bss_cost: int = action.get("cost", 3)
			var bss_idx:  int = action.get("sub_index", -1)
			if bss_idx < 0 or bss_idx >= encounter.subroutines.size():
				push_error("EncounterProcessor: break_self_sub — invalid sub index %d" % bss_idx)
				return false
			if encounter.is_broken(bss_idx):
				ctx.send_log("[Encounter] Sub %d is already broken." % bss_idx)
				return false
			if ctx.runner_available_credits() < bss_cost:
				ctx.send_log("[Encounter] Cannot afford self-break (need %d)." % bss_cost)
				return false
			ctx.runner_credits -= bss_cost
			encounter.break_subroutine(bss_idx)
			var sub_label: String = (encounter.subroutines[bss_idx] as Dictionary).get("label", "sub %d" % bss_idx)
			ctx.send_log("[Encounter] %s spends %d cr to break '%s'." % [
				ctx.runner_name(), bss_cost, sub_label
			])
			return true
		"spree_move_trojan":
			# Spree event: spend 1 counter from run_modifiers → move a trojan
			await interpreter.execute_spree_move_trojan(encounter, ctx)
			return true
		"suppress_etr_subs":
			# Banner: spend 2cr to suppress all ETR subroutines on this barrier for the encounter.
			var ses_ok: bool = _do_suppress_etr_subs(action, encounter, ctx, ability_registry)
			await ctx.check_outside_credits_trigger(interpreter)
			return ses_ok
		"trojan_break_sub":
			# Trojan interface break: a trojan hosted on the encountered ice breaks 1 sub.
			# Enforces once-per-encounter via encounter.trojan_used_this_encounter.
			var tbs_ok: bool = _do_trojan_break_sub(action, encounter, ctx, ability_registry)
			await ctx.check_outside_credits_trigger(interpreter)
			return tbs_ok
		"umbrella_break":
			# Umbrella (TAI): breaks up to N code-gate subs on ice hosting a trojan.
			# If at least 1 subroutine was broken, each player may draw 1 card.
			var umb_before: int = encounter.unbroken_indices().size()
			var umb_ok: bool = await _do_umbrella_break(action, encounter, ctx, ability_registry)
			# Draw trigger: fires when at least 1 sub was actually broken this activation
			if umb_ok and encounter.unbroken_indices().size() < umb_before:
				# Corp may draw 1 card
				if not ctx.corp_deck.is_empty():
					var umb_corp_draw := false
					if ctx.corp_decision_maker != null and \
							ctx.corp_decision_maker.has_method("choose_optional_ability"):
						umb_corp_draw = await ctx.corp_decision_maker.choose_optional_ability(
							"Umbrella: draw 1 card?", ctx)
					else:
						umb_corp_draw = true  # AI: always draw
					if umb_corp_draw:
						var umb_cr: CardRecord = ctx.corp_deck.pop_front() as CardRecord
						if umb_cr != null:
							ctx.corp_hand.append({"card_id": umb_cr.id, "card_record": umb_cr})
							ctx.send_log("[Umbrella] %s draws 1 card." % ctx.corp_name())
				# Runner may draw 1 card
				if not ctx.runner_deck.is_empty():
					var umb_run_draw := false
					if ctx.runner_decision_maker != null and \
							ctx.runner_decision_maker.has_method("choose_optional_ability"):
						umb_run_draw = await ctx.runner_decision_maker.choose_optional_ability(
							"Umbrella: draw 1 card?", ctx)
					else:
						umb_run_draw = true  # AI: always draw
					if umb_run_draw:
						var umb_rr: CardRecord = ctx.runner_deck.pop_front() as CardRecord
						if umb_rr != null:
							ctx.runner_hand.append({"card_id": umb_rr.id, "card_record": umb_rr})
							ctx.send_log("[Umbrella] %s draws 1 card." % ctx.runner_name())
			await ctx.check_outside_credits_trigger(interpreter)
			return umb_ok
		"use_encounter_ability":
			# Runner activates a card's encounter_ability mode (e.g. Malandragem bypass,
			# Physarum Entangler, Arruaceiras Crew weaken/trash).
			var uea_card_id: String = action.get("card_id", "")
			var uea_mode_idx: int   = action.get("mode_index", 0)
			await interpreter.execute_encounter_card_ability(uea_card_id, uea_mode_idx, encounter, ctx)
			return true
		"matryoshka_break":
			# Parhelion: Matryoshka interface break — X credits + turn 1 hosted copy facedown → break X subs.
			# action: { "type": "matryoshka_break", "card_id": String, "sub_indices": Array[int] }
			var mb_ok: bool = await _do_matryoshka_break(action, encounter, ctx)
			await ctx.check_outside_credits_trigger(interpreter)
			return mb_ok
		"hardware_break":
			# Midnight Sun: Endurance — spend 2 power counters from hardware to break
			# up to 2 subroutines on the encountered ice (any type).
			# action: { "type": "hardware_break", "card_id": "endurance", "sub_indices": Array[int] }
			var hb_card_id: String = action.get("card_id", "")
			var hb_sub_indices: Array = action.get("sub_indices", [])
			# Find the hardware in runner_rig
			var hb_hw: InstalledCard = null
			for hb_c in ctx.runner_rig:
				var hb_ic: InstalledCard = hb_c as InstalledCard
				if hb_ic != null and hb_ic.card_id == hb_card_id:
					hb_hw = hb_ic
					break
			if hb_hw == null:
				ctx.send_log("[Encounter] Hardware '%s' not found in rig." % hb_card_id)
				return false
			# Read the hardware_break_ability definition
			var hb_card_def: Dictionary = ability_registry._abilities.get(hb_card_id, {}) as Dictionary
			var hb_ability: Dictionary = hb_card_def.get("hardware_break_ability", {}) as Dictionary
			if hb_ability.is_empty():
				ctx.send_log("[Encounter] %s has no hardware break ability." % hb_hw.display_name())
				return false
			var hb_counter_cost: int = hb_ability.get("cost_power_counter", 2)
			var hb_subs_per_use: int = hb_ability.get("subs_per_use", 2)
			if hb_hw.get_counter("power") < hb_counter_cost:
				ctx.send_log("[Encounter] %s needs %d power counter(s) — has %d." % [
					hb_hw.display_name(), hb_counter_cost, hb_hw.get_counter("power")])
				return false
			var hb_valid: Array = hb_sub_indices.filter(func(idx):
				return idx >= 0 and idx < encounter.subroutines.size() and not encounter.is_broken(idx)
			)
			if hb_valid.is_empty():
				ctx.send_log("[Encounter] No valid subroutines to break with %s." % hb_hw.display_name())
				return false
			if hb_valid.size() > hb_subs_per_use:
				hb_valid = hb_valid.slice(0, hb_subs_per_use)
			hb_hw.remove_counter("power", hb_counter_cost)
			for hb_idx in hb_valid:
				encounter.break_subroutine(hb_idx)
				var hb_label: String = (encounter.subroutines[hb_idx] as Dictionary).get("label", "sub %d" % hb_idx)
				ctx.send_log("[Encounter] %s spends %d counter(s) to break '%s' (%d remaining)." % [
					hb_hw.display_name(), hb_counter_cost, hb_label, hb_hw.get_counter("power")])
			ctx.run_runner_broke_any_subroutine = true
			await ctx.check_outside_credits_trigger(interpreter)
			return true
		"f2p_break":
			# Uprising: F2P — Runner pays 2cr to break 1 sub on this ice (untagged only).
			var f2p_ok: bool = _do_f2p_break(action, encounter, ctx, ability_registry)
			await ctx.check_outside_credits_trigger(interpreter)
			return f2p_ok
		"done":
			return true
		_:
			push_error("EncounterProcessor: unknown encounter action '%s'" % action_type)
			return false


# ── Private helpers ───────────────────────────────────────────────────────────

func _do_boost(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry):

	var breaker := _find_breaker(action.get("card_id", ""), encounter)
	if breaker == null:
		return false

	var boost_def: Variant = ability_registry.get_boost(breaker.card_id)
	if boost_def == null:
		push_error("EncounterProcessor: %s has no boost ability" % breaker.card_id)
		return false

	var boost_dict: Dictionary = boost_def as Dictionary
	var cost: int              = boost_dict.get("cost", 0)
	var times: int             = action.get("times", 1)

	# Run-event cost reduction (e.g. Sang Kancil: boost costs 2cr less when run event active)
	if ctx.run_modifiers.get("run_event_active", 0) > 0:
		var run_event_discount: int = boost_dict.get("run_event_cost_reduction", 0)
		cost = max(0, cost - run_event_discount)

	# discount_if_runner_trashed_own: paid abilities cost N less if runner trashed own card this turn (Boi Tata)
	var trashed_own_discount: int = boost_dict.get("discount_if_runner_trashed_own", 0)
	if trashed_own_discount > 0 and ctx.runner_trashed_own_installed_this_turn:
		cost = max(0, cost - trashed_own_discount)

	# Calculate strength gained per use before any payment path.
	# Unity: 1cr → strength equal to number of installed icebreakers (including itself).
	var str_per_use: int = boost_dict.get("strength_gained", 1)
	if boost_dict.get("strength_gained_modifier", "") == "installed_icebreaker_count":
		str_per_use = ctx.count_installed_icebreakers()
	var total_boost: int = str_per_use * times

	# ── Audrey v2: boost costs trashing a card from grip ──────────────────────
	var trash_grip_cost: int = boost_dict.get("cost_trash_grip", 0)
	if trash_grip_cost > 0:
		if ctx.runner_hand.size() < trash_grip_cost * times:
			ctx.send_log("[Encounter] Cannot boost %s — not enough grip cards (need %d)." % [
				breaker.display_name(), trash_grip_cost * times])
			return false
		for _tgc_i in range(times):
			var tgc_entry: Dictionary = {}
			var tgc_dm: Object = ctx.runner_decision_maker
			if tgc_dm != null and tgc_dm.has_method("choose_card_from_grip_to_trash"):
				tgc_entry = await tgc_dm.choose_card_from_grip_to_trash(ctx)
			if tgc_entry.is_empty() and not ctx.runner_hand.is_empty():
				tgc_entry = ctx.runner_hand[0] as Dictionary
			if tgc_entry.is_empty():
				return false
			var tgc_cr: CardRecord = tgc_entry.get("card_record", null) as CardRecord
			ctx.runner_hand.erase(tgc_entry)
			if tgc_cr != null:
				ctx.runner_discard.append(tgc_cr)
				ctx.send_log("[Encounter] %s trashes %s from grip: +%d str." % [
					breaker.display_name(), tgc_cr.title, str_per_use])
		encounter.apply_boost(breaker, total_boost)
		ctx.send_log("[Encounter] %s now at effective str %d." % [
			breaker.display_name(), encounter.get_breaker_strength(breaker)])
		return true

	# ── Power-counter boost (e.g. Propeller: 1 power counter → +2 str) ─────────
	var pwr_boost_cost: int = boost_dict.get("cost_power_counter", 0)
	if pwr_boost_cost > 0:
		var needed: int = pwr_boost_cost * times
		if breaker.get_counter("power") < needed:
			ctx.send_log("[Encounter] Cannot boost %s — need %d power counter(s), have %d." % [
				breaker.display_name(), needed, breaker.get_counter("power")])
			return false
		breaker.remove_counter("power", needed)
		encounter.apply_boost(breaker, total_boost)
		ctx.send_log("[Encounter] %s spends %d power counter(s): +%d str (now %d, %d counters left)." % [
			breaker.display_name(), needed, total_boost,
			encounter.get_breaker_strength(breaker), breaker.get_counter("power")])
		return true

	# ── Standard credit or stealth payment ───────────────────────────────────
	var total_cost: int     = cost * times
	var costs_stealth: bool = boost_dict.get("costs_stealth", false)

	if costs_stealth:
		if ctx.runner_stealth_credits() < total_cost:
			ctx.send_log("[Encounter] Cannot afford stealth boost (need %d stealth, have %d)." % [
				total_cost, ctx.runner_stealth_credits()])
			return false
	elif ctx.runner_available_credits() < total_cost:
		ctx.send_log("[Encounter] Cannot afford boost (need %d, have %d)." % [
			total_cost, ctx.runner_available_credits()])
		return false

	if costs_stealth:
		ctx.runner_spend_stealth_credits(total_cost)
	else:
		ctx.runner_spend_credits(total_cost)

	if boost_dict.get("target_ice", false):
		# Corsair and similar: reduce the encountered ice's strength rather than boosting the breaker.
		encounter.ice_strength -= total_boost
		ctx.send_log("[Encounter] %s: %s loses %d str (now %d). Cost: %d stealth cr." % [
			breaker.display_name(), encounter.ice_card.display_name(),
			total_boost, encounter.ice_strength, total_cost
		])
	else:
		encounter.apply_boost(breaker, total_boost)
		# GAMEDRAGON Pro: persist this boost to the run-level dict so it carries over to the next encounter.
		if ctx.has_method("has_gamedragon_attached") and ctx.has_gamedragon_attached(breaker):
			var prev_run_boost: int = ctx.run_level_strength_boosts.get(breaker.runtime_instance_id, 0)
			ctx.run_level_strength_boosts[breaker.runtime_instance_id] = prev_run_boost + total_boost

		if boost_dict.get("strength_gained_modifier", "") == "installed_icebreaker_count":
			ctx.send_log("[Encounter] %s boosted +%d str (%d icebreakers). Cost: %d cr." % [
				breaker.display_name(), total_boost, str_per_use, total_cost
			])
		else:
			ctx.send_log("[Encounter] %s boosted %s +%d str (now %d). Cost: %d cr." % [
				breaker.display_name(), "×%d" % times if times > 1 else "",
				total_boost, encounter.get_breaker_strength(breaker), total_cost
			])
	return true


func _do_break_sub(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var breaker := _find_breaker(action.get("card_id", ""), encounter)
	if breaker == null:
		return false

	var sub_index: int = action.get("sub_index", -1)
	if sub_index < 0 or sub_index >= encounter.subroutines.size():
		push_error("EncounterProcessor: invalid sub_index %d" % sub_index)
		return false

	if encounter.is_broken(sub_index):
		ctx.send_log("[Encounter] Subroutine %d already broken." % sub_index)
		return true  # not an error, just redundant

	# ── Parhelion: Anvil — all printed subs unbreakable this encounter ─────────
	if ctx.run_modifiers.get("anvil_subs_unbreakable", false):
		ctx.send_log("[Encounter] Cannot break — Anvil effect: printed subroutines cannot be broken this encounter.")
		return false

	# ── Uprising: Next Activation Command — non-icebreakers cannot break subs ──
	if _blocked_by_next_activation_command(ctx, breaker.card_record):
		return false

	# ── Parhelion: Hafrun — specific breaker disabled for this run ─────────────
	var hafrun_key: String = "hafrun_disabled_" + breaker.runtime_instance_id
	if ctx.run_modifiers.get(hafrun_key, false):
		ctx.send_log("[Encounter] Cannot break with %s — Hafrun has disabled it for the remainder of this run." % \
			breaker.display_name())
		return false

	# ── Parhelion: Unsmiling Tsarevna — limit 1 break per encounter on this ice ─
	var tsarevna_ice_key: String = "tsarevna_sub_limit_" + encounter.ice_card.runtime_instance_id
	if ctx.run_modifiers.has(tsarevna_ice_key) and encounter.broken_indices.size() >= 1:
		ctx.send_log("[Encounter] Cannot break — Unsmiling Tsarevna limits breaks to 1 per encounter on this ice.")
		return false

	var ice_subtypes: Array = encounter.ice_card.card_record.subtypes if encounter.ice_card.card_record != null else []
	ice_subtypes = ice_subtypes + encounter.ice_card.extra_subtypes
	var break_def: Variant = ability_registry.get_break_for_ice(breaker.card_id, ice_subtypes)
	if break_def == null:
		push_error("EncounterProcessor: %s has no break ability" % breaker.card_id)
		return false

	var break_dict: Dictionary = break_def as Dictionary

	# break_limit_per_encounter: ice restricts how many subroutines can be broken total this encounter.
	# An optional break_limit_except_subtype lists breaker subtypes that are exempt from the limit.
	if encounter.ice_card.card_record != null:
		var ice_ab_def: Dictionary = ability_registry._abilities.get(
			encounter.ice_card.card_id, {}) as Dictionary
		var break_limit: int = ice_ab_def.get("break_limit_per_encounter", -1)
		# Uprising: Akhet — while 3+ hosted advancement counters, the Runner cannot
		# break more than 1 printed sub per encounter.
		var cond_limit: Dictionary = ice_ab_def.get("break_limit_per_encounter_if_counters_gte", {}) as Dictionary
		if not cond_limit.is_empty() and encounter.ice_card.get_counter("advancement") >= int(cond_limit.get("threshold", 0)):
			var cl: int = int(cond_limit.get("limit", -1))
			if break_limit < 0 or cl < break_limit:
				break_limit = cl
		if break_limit >= 0:
			var exempt_subtypes: Array = ice_ab_def.get("break_limit_except_subtype", []) as Array
			var is_exempt := false
			if not exempt_subtypes.is_empty() and breaker.card_record != null:
				for exempt_st in exempt_subtypes:
					if breaker.card_record.has_subtype(exempt_st as String):
						is_exempt = true
						break
			if not is_exempt and encounter.broken_indices.size() >= break_limit:
				ctx.send_log("[Encounter] %s: break limit of %d sub(s) per encounter reached." % [
					encounter.ice_card.display_name(), break_limit])
				return false

	# host_only: Botulus can only break subs on its host ice.
	if break_dict.get("host_only", false):
		if breaker.hosted_on_id == "" or breaker.hosted_on_id != encounter.ice_card.runtime_instance_id:
			ctx.send_log("[Encounter] %s can only break subroutines on %s." % [
				breaker.display_name(),
				ctx.get_ice_by_instance_id(breaker.hosted_on_id).display_name() if breaker.hosted_on_id != "" else "its host ice"
			])
			return false

	# target_only: Boomerang can only break subs on its chosen target ice.
	if break_dict.get("target_only", false):
		if breaker.target_id == "" or breaker.target_id != encounter.ice_card.runtime_instance_id:
			var target_ice := ctx.get_ice_by_instance_id(breaker.target_id) if breaker.target_id != "" else null
			ctx.send_log("[Encounter] %s can only break subroutines on %s." % [
				breaker.display_name(),
				target_ice.display_name() if target_ice != null else "its chosen target"
			])
			return false

	# same_server_only: Living Mural can only break subs on ice protecting its own server.
	# The breaker is a trojan hosted on ice; that host ice's server must match the encounter.
	if break_dict.get("same_server_only", false):
		var sso_host: InstalledCard = ctx.get_ice_by_instance_id(breaker.hosted_on_id) \
			if breaker.hosted_on_id != "" else null
		if sso_host == null or sso_host.server_id != encounter.ice_card.server_id:
			ctx.send_log("[Encounter] %s can only break subroutines on ice protecting its server." % \
				breaker.display_name())
			return false

	# Strength check (host_only and target_only bypass the strength check).
	if not break_dict.get("host_only", false) and not break_dict.get("target_only", false) \
			and not encounter.breaker_reaches(breaker):
		ctx.send_log("[Encounter] %s (str %d) cannot reach %s (str %d)." % [
			breaker.display_name(),
			encounter.get_breaker_strength(breaker),
			encounter.ice_card.display_name(),
			encounter.effective_ice_strength()
		])
		return false

	# cost_power_counter_overhead: flat power-counter cost before breaking (e.g. Lobisomem vs barriers).
	var overhead_counters: int = break_dict.get("cost_power_counter_overhead", 0)
	if overhead_counters > 0:
		if breaker.get_counter("power") < overhead_counters:
			ctx.send_log("[Encounter] %s needs %d power counter(s) to break this ice type." % [
				breaker.display_name(), overhead_counters])
			return false
		breaker.remove_counter("power", overhead_counters)
		ctx.send_log("[Encounter] %s spends %d power counter(s) to break barrier." % [
			breaker.display_name(), overhead_counters])

	# ── Midnight Sun: Revolver — dual-cost break (trash_self OR power_counter) ──
	# dual_cost_options: Array of { type: "trash_self"|"power_counter", amount: int }
	# Runner chooses payment per break activation.
	var dual_cost_opts: Array = break_dict.get("dual_cost_options", []) as Array
	if not dual_cost_opts.is_empty():
		# Determine available options
		var dc_can_trash := false
		var dc_counter_cost := 1
		var dc_can_counter := false
		for dc_opt in dual_cost_opts:
			var dc_o: Dictionary = dc_opt as Dictionary
			match dc_o.get("type", ""):
				"trash_self":
					dc_can_trash = true
				"power_counter":
					dc_counter_cost = dc_o.get("amount", 1)
					if breaker.get_counter("power") >= dc_counter_cost:
						dc_can_counter = true
		if not dc_can_trash and not dc_can_counter:
			ctx.send_log("[Encounter] %s cannot break — no valid payment available." % breaker.display_name())
			return false
		# Choose payment: offer choice if both available; otherwise force the only option
		var dc_use_trash := false
		if dc_can_trash and dc_can_counter:
			if not ctx.simulation_mode and ctx.runner_decision_maker != null \
					and ctx.runner_decision_maker.has_method("choose_dual_cost_break"):
				dc_use_trash = await ctx.runner_decision_maker.choose_dual_cost_break(breaker, ctx)
			else:
				dc_use_trash = false   # AI: always prefer counter to preserve the card
		elif dc_can_trash and not dc_can_counter:
			dc_use_trash = true
		# Execute the chosen payment
		var dc_sub_label: String = (encounter.subroutines[sub_index] as Dictionary).get("label", "sub %d" % sub_index)
		if dc_use_trash:
			encounter.break_subroutine(sub_index)
			ctx.send_log("[Encounter] %s trashes itself to break '%s'." % [breaker.display_name(), dc_sub_label])
			_trash_breaker(breaker, ctx)
		else:
			breaker.remove_counter("power", dc_counter_cost)
			encounter.break_subroutine(sub_index)
			ctx.send_log("[Encounter] %s spends %d power counter(s) to break '%s' (%d remaining)." % [
				breaker.display_name(), dc_counter_cost, dc_sub_label, breaker.get_counter("power")])
		if breaker.card_record != null and breaker.card_record.subtypes.has("decoder"):
			encounter.broken_with_decoder = true
		_check_tungsten_tailor(encounter, ctx)
		_check_fully_broke_code_gate(breaker, encounter, ctx, ability_registry)
		ctx.run_runner_broke_any_subroutine = true
		return true

	var cost: int       = break_dict.get("cost_per_sub", 1)
	var virus_cost: int = break_dict.get("cost_virus_counter", 0)

	# discount_if_runner_trashed_own: paid abilities cost N less if runner trashed own card this turn (Boi Tata)
	var break_trashed_discount: int = break_dict.get("discount_if_runner_trashed_own", 0)
	if break_trashed_discount > 0 and ctx.runner_trashed_own_installed_this_turn:
		cost = max(0, cost - break_trashed_discount)

	# Parhelion: Tremolo — reduce cost_per_sub by number of installed cybernetic hardware (min 0)
	if break_dict.get("cybernetic_cost_reduction", false):
		cost = max(0, cost - ctx.count_installed_cybernetic_hardware())

	if virus_cost > 0:
		# Botulus spends virus counters.
		var available_virus: int = breaker.get_counter("virus")
		if available_virus < virus_cost:
			ctx.send_log("[Encounter] %s has no virus counters to spend." % breaker.display_name())
			return false
		breaker.remove_counter("virus", virus_cost)
	elif break_dict.get("costs_stealth", false):
		if ctx.runner_stealth_credits() < cost:
			ctx.send_log("[Encounter] Cannot afford stealth break (need %d stealth, have %d)." % [
				cost, ctx.runner_stealth_credits()])
			return false
		ctx.runner_spend_stealth_credits(cost)
	elif ctx.runner_available_credits() < cost:
		ctx.send_log("[Encounter] Cannot afford to break (need %d, have %d)." % [
			cost, ctx.runner_available_credits()])
		return false
	else:
		ctx.runner_spend_credits(cost)

	encounter.break_subroutine(sub_index)
	var sub_label: String = (encounter.subroutines[sub_index] as Dictionary).get("label", "subroutine %d" % sub_index)

	if virus_cost > 0:
		ctx.send_log("[Encounter] %s breaks '%s' (1 virus, %d remaining)." % [
			breaker.display_name(), sub_label, breaker.get_counter("virus")])
	elif break_dict.get("costs_stealth", false):
		ctx.send_log("[Encounter] %s breaks '%s' for %d stealth cr." % [breaker.display_name(), sub_label, cost])
	else:
		ctx.send_log("[Encounter] %s breaks '%s' for %d cr." % [breaker.display_name(), sub_label, cost])

	# Record that a decoder was used — VSA's on_runner_passes reads this via
	# last_ice_broken_with_decoder in run_modifiers (set by RunStateMachine after encounter).
	if breaker.card_record != null and breaker.card_record.subtypes.has("decoder"):
		encounter.broken_with_decoder = true

	_check_tungsten_tailor(encounter, ctx)
	_check_fully_broke_code_gate(breaker, encounter, ctx, ability_registry)

	# trash_self_on_use: card trashes itself after breaking (Boomerang).
	# Keep the run_end listener alive so the heap-recur ability can still fire.
	if break_dict.get("trash_self_on_use", false):
		_trash_breaker(breaker, ctx)

	_apply_printed_sub_break_modifiers(encounter, ctx, ability_registry, [sub_index])
	return true


func _do_break_all(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var breaker := _find_breaker(action.get("card_id", ""), encounter)
	if breaker == null:
		return false

	var ice_subtypes_all: Array = encounter.ice_card.card_record.subtypes if encounter.ice_card.card_record != null else []
	ice_subtypes_all = ice_subtypes_all + encounter.ice_card.extra_subtypes
	var break_def: Variant = ability_registry.get_break_for_ice(breaker.card_id, ice_subtypes_all)
	if break_def == null:
		return false

	# ── Parhelion: Anvil — all printed subs unbreakable this encounter ─────────
	if ctx.run_modifiers.get("anvil_subs_unbreakable", false):
		ctx.send_log("[Encounter] Cannot break — Anvil effect: printed subroutines cannot be broken this encounter.")
		return false

	# ── Uprising: Next Activation Command — non-icebreakers cannot break subs ──
	if _blocked_by_next_activation_command(ctx, breaker.card_record):
		return false

	# ── Parhelion: Hafrun — specific breaker disabled for this run ─────────────
	var hafrun_key_all: String = "hafrun_disabled_" + breaker.runtime_instance_id
	if ctx.run_modifiers.get(hafrun_key_all, false):
		ctx.send_log("[Encounter] Cannot break with %s — Hafrun has disabled it for the remainder of this run." % \
			breaker.display_name())
		return false

	# ── Parhelion: Unsmiling Tsarevna — limit 1 break per encounter on this ice ─
	var tsarevna_all_key: String = "tsarevna_sub_limit_" + encounter.ice_card.runtime_instance_id
	if ctx.run_modifiers.has(tsarevna_all_key) and encounter.broken_indices.size() >= 1:
		ctx.send_log("[Encounter] Cannot break — Unsmiling Tsarevna limits breaks to 1 per encounter on this ice.")
		return false

	var break_dict: Dictionary = break_def as Dictionary
	var _gf_unbroken_before: Array = encounter.unbroken_indices()

	# target_only: can only break subs on the chosen target ice (Boomerang).
	if break_dict.get("target_only", false):
		if breaker.target_id == "" or breaker.target_id != encounter.ice_card.runtime_instance_id:
			var target_ice := ctx.get_ice_by_instance_id(breaker.target_id) if breaker.target_id != "" else null
			ctx.send_log("[Encounter] %s can only break subroutines on %s." % [
				breaker.display_name(),
				target_ice.display_name() if target_ice != null else "its chosen target"
			])
			return false

	# same_server_only: Living Mural can only break subs on ice protecting its own server.
	if break_dict.get("same_server_only", false):
		var sso_host_all: InstalledCard = ctx.get_ice_by_instance_id(breaker.hosted_on_id) \
			if breaker.hosted_on_id != "" else null
		if sso_host_all == null or sso_host_all.server_id != encounter.ice_card.server_id:
			ctx.send_log("[Encounter] %s can only break subroutines on ice protecting its server." % \
				breaker.display_name())
			return false

	# Strength check (skip for host_only or target_only breakers).
	if not break_dict.get("host_only", false) and not break_dict.get("target_only", false) \
			and not encounter.breaker_reaches(breaker):
		ctx.send_log("[Encounter] %s cannot reach %s — boost first." % [
			breaker.display_name(), encounter.ice_card.display_name()
		])
		return false

	# cost_power_counter_overhead: flat power-counter cost before breaking (e.g. Lobisomem vs barriers).
	var overhead_all: int = break_dict.get("cost_power_counter_overhead", 0)
	if overhead_all > 0:
		if breaker.get_counter("power") < overhead_all:
			ctx.send_log("[Encounter] %s needs %d power counter(s) to break this ice type." % [
				breaker.display_name(), overhead_all])
			return false
		breaker.remove_counter("power", overhead_all)
		ctx.send_log("[Encounter] %s spends %d power counter(s) to break barrier." % [
			breaker.display_name(), overhead_all])

	# Parhelion: Orca — flat cost for entire break activation (not per sub).
	# "flat_break_cost: N" means Runner pays N credits once to break all unbroken subs.
	var flat_break_cost: int = break_dict.get("flat_break_cost", 0)
	if flat_break_cost > 0:
		if ctx.runner_available_credits() < flat_break_cost:
			ctx.send_log("[Encounter] Cannot afford to break all subs (need %d cr)." % flat_break_cost)
			return false
		ctx.runner_spend_credits(flat_break_cost)
		for idx in encounter.unbroken_indices():
			encounter.break_subroutine(idx)
			var fbl: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
			ctx.send_log("[Encounter] %s breaks '%s'." % [breaker.display_name(), fbl])
		if breaker.card_record != null and breaker.card_record.subtypes.has("decoder"):
			encounter.broken_with_decoder = true
		ctx.send_log("[Encounter] %s: paid %d cr flat to break all subs." % [breaker.display_name(), flat_break_cost])
		if break_dict.get("trash_self_on_use", false):
			_trash_breaker(breaker, ctx)
		_apply_printed_sub_break_modifiers(encounter, ctx, ability_registry, _gf_unbroken_before)
		return true

	var cost_per_sub: int = break_dict.get("cost_per_sub", 1)
	var virus_cost: int   = break_dict.get("cost_virus_counter", 0)
	# Flat virus cost: pay once to break up to subs_per_use subs (Audrey v2 model).
	# Different from cost_virus_counter which deducts 1 counter per sub (Botulus model).
	var virus_flat: int   = break_dict.get("cost_virus_counter_flat", 0)

	# discount_if_runner_trashed_own: paid abilities cost N less if runner trashed own card this turn (Boi Tata)
	var ball_trashed_discount: int = break_dict.get("discount_if_runner_trashed_own", 0)
	if ball_trashed_discount > 0 and ctx.runner_trashed_own_installed_this_turn:
		cost_per_sub = max(0, cost_per_sub - ball_trashed_discount)

	# Parhelion: Tremolo — reduce cost_per_sub by number of installed cybernetic hardware (min 0)
	if break_dict.get("cybernetic_cost_reduction", false):
		cost_per_sub = max(0, cost_per_sub - ctx.count_installed_cybernetic_hardware())

	var unbroken: Array   = encounter.unbroken_indices()

	# ── subs_per_use cap ─────────────────────────────────────────────────────
	# When the breaker can only break N subs per activation (Boomerang: 2, Audrey v2: 2),
	# the runner chooses *which* subs to break rather than defaulting to 0..N-1.
	var subs_cap: int = break_dict.get("subs_per_use", 0)
	if subs_cap > 0 and unbroken.size() > subs_cap:
		unbroken = await _ask_runner_choose_subs(unbroken, subs_cap, breaker, encounter, ctx)

	if virus_flat > 0:
		# Flat virus cost (Audrey v2): pay once, break up to subs_per_use subs.
		# The subs_cap selection above already capped unbroken to subs_per_use.
		var av_flat: int = breaker.get_counter("virus")
		if av_flat < virus_flat:
			ctx.send_log("[Encounter] %s needs %d virus counter(s) to activate — has %d." % [
				breaker.display_name(), virus_flat, av_flat])
			return false
		breaker.remove_counter("virus", virus_flat)
		for idx in unbroken:
			encounter.break_subroutine(idx)
			var sub_label_flat: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
			ctx.send_log("[Encounter] %s breaks '%s'." % [breaker.display_name(), sub_label_flat])
		ctx.send_log("[Encounter] %s spends 1 virus counter (%d remaining)." % [
			breaker.display_name(), breaker.get_counter("virus")])
	elif virus_cost > 0:
		# Virus-counter cost — break as many as we have virus counters for.
		var available_virus: int = breaker.get_counter("virus")
		var can_break_v: int     = min(available_virus, unbroken.size())
		if can_break_v == 0:
			ctx.send_log("[Encounter] %s has no virus counters to spend." % breaker.display_name())
			return false
		# If virus supply limits how many subs can be broken, ask the runner which to target.
		var virus_targets: Array = unbroken
		if can_break_v < unbroken.size():
			virus_targets = await _ask_runner_choose_subs(unbroken, can_break_v, breaker, encounter, ctx)
		for idx in virus_targets:
			breaker.remove_counter("virus", virus_cost)
			encounter.break_subroutine(idx)
			var sub_label_v: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
			ctx.send_log("[Encounter] %s breaks '%s' (1 virus, %d remaining)." % [
				breaker.display_name(), sub_label_v, breaker.get_counter("virus")])
	else:
		var total_cost: int = cost_per_sub * unbroken.size()
		if ctx.runner_available_credits() < total_cost:
			# Partial break: runner can't afford all subs — let them choose which to break.
			var can_break: int = (ctx.runner_available_credits() / cost_per_sub) if cost_per_sub > 0 else unbroken.size()
			if can_break == 0:
				ctx.send_log("[Encounter] %s cannot afford to break any subroutine (need %d cr)." % [
					breaker.display_name(), cost_per_sub])
				return false
			var partial_targets: Array = await _ask_runner_choose_subs(unbroken, can_break, breaker, encounter, ctx)
			for idx in partial_targets:
				ctx.runner_spend_credits(cost_per_sub)
				encounter.break_subroutine(idx)
				var sub_label: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
				ctx.send_log("[Encounter] %s breaks '%s'." % [breaker.display_name(), sub_label])
			ctx.send_log("[Encounter] Out of credits — %d subs remain unbroken." % (unbroken.size() - can_break))
		else:
			# Can afford all — no choice needed, break everything in unbroken.
			for idx in unbroken:
				ctx.runner_spend_credits(cost_per_sub)
				encounter.break_subroutine(idx)
				var sub_label: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
				ctx.send_log("[Encounter] %s breaks '%s'." % [breaker.display_name(), sub_label])

	# Record that a decoder was used — VSA's on_runner_passes reads this.
	if breaker.card_record != null and breaker.card_record.subtypes.has("decoder"):
		encounter.broken_with_decoder = true

	_check_tungsten_tailor(encounter, ctx)
	_check_fully_broke_code_gate(breaker, encounter, ctx, ability_registry)

	# trash_self_on_use: card trashes itself after breaking (Boomerang).
	if break_dict.get("trash_self_on_use", false):
		_trash_breaker(breaker, ctx)

	var _gf_newly_broken: Array = _gf_unbroken_before.filter(func(idx): return encounter.is_broken(idx))
	_apply_printed_sub_break_modifiers(encounter, ctx, ability_registry, _gf_newly_broken)
	return true


func _do_break_with_click(action: Dictionary, encounter: EncounterState, ctx: GameContext,
		ability_registry: AbilityRegistry) -> bool:
	# Runner spends 1 click to break 1 subroutine on a bioroid.
	# No strength check required — this is the ice's own ability, not an icebreaker.
	# Midnight Sun: Hákarl 1.0 — block this ability when suppression flag is set.
	if ctx.runner_bioroid_paid_abilities_suppressed:
		ctx.send_log("[Encounter] Cannot use bioroid paid abilities this turn (Hákarl 1.0 effect).")
		return false
	if ctx.runner_clicks < 1:
		ctx.send_log("[Encounter] Runner has no clicks to spend.")
		return false
	var sub_index: int = action.get("sub_index", -1)
	if sub_index < 0 or sub_index >= encounter.subroutines.size():
		push_error("EncounterProcessor: break_with_click — invalid sub_index %d" % sub_index)
		return false
	if encounter.is_broken(sub_index):
		ctx.send_log("[Encounter] Subroutine %d already broken." % sub_index)
		return true
	ctx.runner_clicks -= 1
	encounter.break_subroutine(sub_index)
	var sub_label: String = (encounter.subroutines[sub_index] as Dictionary).get("label", "sub %d" % sub_index)
	ctx.send_log("[Encounter] Runner spends 1 click to break '%s'. (%d clicks remaining)" % [
		sub_label, ctx.runner_clicks
	])
	# Tyr: each [lose click] break grants the Corp +1 allotted click for their next turn.
	if encounter.ice_card != null:
		var ice_def: Dictionary = ability_registry._abilities.get(encounter.ice_card.card_id, {}) as Dictionary
		if ice_def.get("bioroid_break_grants_corp_click", false):
			ctx.pending_click_bonuses["corp"] = ctx.pending_click_bonuses.get("corp", 0) + 1
			ctx.send_log("[Tyr] %s will gain +1 click at the start of their next turn." % ctx.corp_name())
	return true


func _do_spend_hosted_credits(action: Dictionary, encounter: EncounterState, ctx: GameContext) -> bool:
	# Transfer hosted credits from a card to the runner's pool.
	var card_id: String = action.get("card_id", "")
	var amount: int     = action.get("amount", 1)
	var source: InstalledCard = _find_card_in_rig(card_id, ctx)
	if source == null:
		push_error("EncounterProcessor: spend_hosted_credits — card '%s' not found" % card_id)
		return false
	var available: int = source.get_counter("credits")
	var taken: int     = min(amount, available)
	if taken <= 0:
		ctx.send_log("[Encounter] %s has no hosted credits to spend." % source.display_name())
		return false
	source.remove_counter("credits", taken)
	ctx.runner_credits += taken
	ctx.send_log("[Encounter] %s takes %d cr from %s (%d remaining)." % [
		ctx.runner_name(), taken, source.display_name(), source.get_counter("credits")
	])
	return true


func _do_weaken_ice(action: Dictionary, encounter: EncounterState, ctx: GameContext) -> bool:
	# Spend 1 virus counter from a card (e.g. Leech) to give the encountered ice -1 strength.
	var card_id: String = action.get("card_id", "")
	var source: InstalledCard = _find_card_in_rig_or_hosted(card_id, ctx)
	if source == null:
		push_error("EncounterProcessor: weaken_ice — card '%s' not found" % card_id)
		return false
	var available: int = source.get_counter("virus")
	if available <= 0:
		ctx.send_log("[Encounter] %s has no virus counters to spend." % source.display_name())
		return false
	source.remove_counter("virus", 1)
	encounter.ice_strength -= 1
	ctx.send_log("[Encounter] %s spends 1 virus counter — %s is now strength %d (%d counters left)." % [
		source.display_name(),
		encounter.ice_card.display_name() if encounter.ice_card != null else "ice",
		encounter.ice_strength,
		source.get_counter("virus")
	])
	return true


# ── Trojan interface break ────────────────────────────────────────────────────

func _do_suppress_etr_subs(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var card_id: String = action.get("card_id", "")

	# Find the suppressor card in the runner's rig.
	var banner: InstalledCard = _find_card_in_rig(card_id, ctx)
	if banner == null:
		push_error("EncounterProcessor: suppress_etr_subs — '%s' not found in rig" % card_id)
		return false

	# Read cost from the card's suppress_etr_action definition.
	var ses_def: Dictionary = ability_registry._abilities.get(card_id, {}) \
		.get("suppress_etr_action", {}) as Dictionary
	var cost: int = ses_def.get("cost", 2)

	# Gate: encountered ice must be a barrier.
	if encounter.ice_card == null or encounter.ice_card.card_record == null or \
			not encounter.ice_card.card_record.has_subtype("barrier"):
		ctx.send_log("[Encounter] %s only works against barriers." % banner.display_name())
		return false

	# Gate: not already used this encounter.
	if encounter.barrier_etr_suppressed:
		ctx.send_log("[Encounter] ETR subroutines are already suppressed this encounter.")
		return false

	# Afford check.
	if ctx.runner_available_credits() < cost:
		ctx.send_log("[Encounter] Cannot afford %s (need %d, have %d)." % [
			banner.display_name(), cost, ctx.runner_available_credits()])
		return false

	ctx.runner_spend_credits(cost)
	encounter.barrier_etr_suppressed = true
	ctx.send_log("[Encounter] %s: ETR subroutines on %s are suppressed this encounter." % [
		banner.display_name(), encounter.ice_card.display_name()])
	return true


func _do_trojan_break_sub(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var card_id: String  = action.get("card_id", "")
	var sub_index: int   = action.get("sub_index", -1)

	# Find the trojan in the hosted_cards of the encountered ice.
	var trojan: InstalledCard = null
	if encounter.ice_card != null:
		for hc in encounter.ice_card.hosted_cards:
			var hc_ic: InstalledCard = hc as InstalledCard
			if hc_ic != null and hc_ic.card_id == card_id:
				trojan = hc_ic
				break
	if trojan == null:
		push_error("EncounterProcessor: trojan_break_sub — trojan '%s' not found on ice" % card_id)
		return false

	# ── Uprising: Next Activation Command — non-icebreakers cannot break subs ──
	if _blocked_by_next_activation_command(ctx, trojan.card_record):
		return false

	var ib_def: Variant = ability_registry.get_interface_break(card_id)
	if ib_def == null:
		push_error("EncounterProcessor: trojan_break_sub — '%s' has no interface_break" % card_id)
		return false
	var ib_dict: Dictionary = ib_def as Dictionary

	# Once-per-encounter guard.
	if ib_dict.get("once_per_encounter", false):
		if encounter.trojan_used_this_encounter.get(card_id, false):
			ctx.send_log("[Encounter] %s has already been used this encounter." % trojan.display_name())
			return false

	# Validate sub index.
	if sub_index < 0 or sub_index >= encounter.subroutines.size():
		push_error("EncounterProcessor: trojan_break_sub — invalid sub_index %d" % sub_index)
		return false
	if encounter.is_broken(sub_index):
		ctx.send_log("[Encounter] Subroutine %d is already broken." % sub_index)
		return true  # already done, not an error

	# Afford check.
	var cost: int = ib_dict.get("cost_per_sub", 1)
	if ctx.runner_available_credits() < cost:
		ctx.send_log("[Encounter] Cannot afford %s interface break (need %d, have %d)." % [
			trojan.display_name(), cost, ctx.runner_available_credits()])
		return false

	ctx.runner_spend_credits(cost)
	encounter.break_subroutine(sub_index)

	if ib_dict.get("once_per_encounter", false):
		encounter.trojan_used_this_encounter[card_id] = true

	var sub_label: String = (encounter.subroutines[sub_index] as Dictionary).get("label", "subroutine %d" % sub_index)
	ctx.send_log("[Encounter] %s (interface): breaks '%s' for %d cr." % [
		trojan.display_name(), sub_label, cost])
	return true


func _do_umbrella_break(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:

	var card_id: String = action.get("card_id", "")

	# Find Umbrella in the runner's rig.
	var umbrella: InstalledCard = _find_card_in_rig(card_id, ctx)
	if umbrella == null:
		push_error("EncounterProcessor: umbrella_break — '%s' not found in rig" % card_id)
		return false

	# ── Uprising: Next Activation Command — non-icebreakers cannot break subs ──
	if _blocked_by_next_activation_command(ctx, umbrella.card_record):
		return false

	var ub_def: Variant = ability_registry.get_umbrella_break(card_id)
	if ub_def == null:
		push_error("EncounterProcessor: umbrella_break — '%s' has no umbrella_break def" % card_id)
		return false
	var ub_dict: Dictionary = ub_def as Dictionary

	# Gate: the encountered ice must have at least one hosted trojan.
	if encounter.ice_card == null or encounter.ice_card.hosted_cards.is_empty():
		ctx.send_log("[Encounter] %s can only interface with ice that has a hosted trojan." % umbrella.display_name())
		return false
	var has_trojan := false
	for hc in encounter.ice_card.hosted_cards:
		if (hc as InstalledCard) != null:
			has_trojan = true
			break
	if not has_trojan:
		ctx.send_log("[Encounter] %s can only interface with ice that has a hosted trojan." % umbrella.display_name())
		return false

	# Gate: ice must be a code gate (or match the umbrella_break subtype list).
	var required_subtypes: Array = ub_dict.get("subtypes", ["code_gate"]) as Array
	if encounter.ice_card.card_record != null and not required_subtypes.is_empty():
		var ice_stypes: Array = encounter.ice_card.card_record.subtypes + encounter.ice_card.extra_subtypes
		var type_ok := false
		for rst in required_subtypes:
			if ice_stypes.has(rst):
				type_ok = true
				break
		if not type_ok:
			ctx.send_log("[Encounter] %s can only break subroutines on: %s." % [
				umbrella.display_name(), ", ".join(required_subtypes)])
			return false

	var cost_per_sub: int = ub_dict.get("cost_per_sub", 2)
	var subs_cap: int     = ub_dict.get("subs_per_use", 3)
	var unbroken: Array   = encounter.unbroken_indices()

	if unbroken.is_empty():
		ctx.send_log("[Encounter] All subroutines already broken.")
		return true

	# If more unbroken subs than cap, ask runner to choose which to break.
	var targets: Array = unbroken
	if subs_cap > 0 and unbroken.size() > subs_cap:
		targets = await _ask_runner_choose_subs(unbroken, subs_cap, umbrella, encounter, ctx)

	var total_cost: int = cost_per_sub * targets.size()
	if ctx.runner_available_credits() < total_cost:
		# Partial: break what we can afford.
		var can_break: int = ctx.runner_available_credits() / cost_per_sub if cost_per_sub > 0 else targets.size()
		if can_break == 0:
			ctx.send_log("[Encounter] %s cannot afford to break any subroutine (need %d cr)." % [
				umbrella.display_name(), cost_per_sub])
			return false
		targets = await _ask_runner_choose_subs(targets, can_break, umbrella, encounter, ctx)

	for idx in targets:
		ctx.runner_spend_credits(cost_per_sub)
		encounter.break_subroutine(idx)
		var sub_label: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
		ctx.send_log("[Encounter] %s (interface) breaks '%s' for %d cr." % [
			umbrella.display_name(), sub_label, cost_per_sub])

	return true


# ── Shared micro-helpers ──────────────────────────────────────────────────────

# Uprising: Next Activation Command — "The Runner cannot use non-icebreaker
# cards to break subroutines" while the lockdown operation is active.
func _blocked_by_next_activation_command(ctx: GameContext, card_record: CardRecord) -> bool:
	var nac_active := false
	for lockdown_card in ctx.active_lockdown_cards:
		if (lockdown_card as InstalledCard).card_id == "next_activation_command":
			nac_active = true
			break
	if not nac_active:
		return false
	if card_record != null and card_record.has_subtype("icebreaker"):
		return false
	ctx.send_log("[Encounter] Next Activation Command: only icebreakers can break subroutines.")
	return true


# Uprising: Gold Farmer — "Whenever the Runner breaks a printed subroutine on
# this ice, they lose 1[credit]." Called with the indices freshly broken by a
# single break action; only indices within the ice's printed subroutine count
# trigger the credit loss.
func _apply_printed_sub_break_modifiers(encounter: EncounterState, ctx: GameContext,
		ability_registry: AbilityRegistry, newly_broken: Array) -> void:
	if newly_broken.is_empty() or encounter.ice_card == null:
		return
	var ab_def: Dictionary = ability_registry._abilities.get(encounter.ice_card.card_id, {}) as Dictionary
	var mods: Array = ab_def.get("passive_modifiers", []) as Array
	var loses_credits := false
	for m in mods:
		if (m as Dictionary).get("type", "") == "runner_loses_credits_on_printed_sub_break":
			loses_credits = true
			break
	if not loses_credits:
		return
	var printed_count: int = ability_registry.get_subroutines_for_card(
		encounter.ice_card.card_id, encounter.ice_card).size()
	for idx in newly_broken:
		if int(idx) < printed_count and ctx.runner_credits > 0:
			ctx.runner_credits -= 1
			ctx.send_log("[Encounter] %s loses 1cr (broke a printed subroutine on %s)." % [
				ctx.runner_name(), encounter.ice_card.display_name()])


# Uprising: F2P — "2[credit]: Break 1 subroutine on this ice. Only the Runner
# can use this ability, and only if they are not tagged."
func _do_f2p_break(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:
	var ice_card: InstalledCard = encounter.ice_card
	if ice_card == null:
		return false
	var ab_def: Dictionary = ability_registry._abilities.get(ice_card.card_id, {}) as Dictionary
	var f2p_def: Dictionary = ab_def.get("runner_paid_break_ability", {}) as Dictionary
	if f2p_def.is_empty():
		return false

	# Uprising: Next Activation Command — only icebreakers can break subs.
	if _blocked_by_next_activation_command(ctx, null):
		return false

	var condition: String = f2p_def.get("condition", "")
	if condition == "runner_not_tagged" and ctx.runner_is_tagged():
		ctx.send_log("[Encounter] Cannot use %s's ability — %s is tagged." % [
			ice_card.display_name(), ctx.runner_name()])
		return false

	var cost: int = f2p_def.get("cost_credits", 2)
	if ctx.runner_available_credits() < cost:
		ctx.send_log("[Encounter] Cannot afford %s's ability (need %d cr)." % [ice_card.display_name(), cost])
		return false

	var subs_per_use: int = f2p_def.get("subs_per_use", 1)
	var sub_indices: Array = action.get("sub_indices", [])
	var valid: Array = sub_indices.filter(func(idx):
		return idx >= 0 and idx < encounter.subroutines.size() and not encounter.is_broken(idx)
	)
	if valid.is_empty():
		ctx.send_log("[Encounter] No valid subroutines to break with %s." % ice_card.display_name())
		return false
	if valid.size() > subs_per_use:
		valid = valid.slice(0, subs_per_use)

	ctx.runner_spend_credits(cost)
	for idx in valid:
		encounter.break_subroutine(idx)
		var label: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
		ctx.send_log("[Encounter] %s spends %d cr to break '%s'." % [ctx.runner_name(), cost, label])
	ctx.run_runner_broke_any_subroutine = true
	_apply_printed_sub_break_modifiers(encounter, ctx, ability_registry, valid)
	return true


func _find_breaker(card_id: String, encounter: EncounterState) -> InstalledCard:
	for b in encounter.available_breakers:
		var breaker: InstalledCard = b as InstalledCard
		if breaker.card_id == card_id:
			return breaker
	push_error("EncounterProcessor: breaker '%s' not found in encounter" % card_id)
	return null


func _find_card_in_rig(card_id: String, ctx: GameContext) -> InstalledCard:
	for c in ctx.runner_rig:
		var ic: InstalledCard = c as InstalledCard
		if ic != null and ic.card_id == card_id:
			return ic
	return null


func _find_card_in_rig_or_hosted(card_id: String, ctx: GameContext) -> InstalledCard:
	var found := _find_card_in_rig(card_id, ctx)
	if found != null:
		return found
	# Also search programs hosted on ice.
	for server in ctx.servers.values():
		for ice_card in (server as Server).ice:
			for hc in (ice_card as InstalledCard).hosted_cards:
				var ic: InstalledCard = hc as InstalledCard
				if ic != null and ic.card_id == card_id:
					return ic
	return null


func _check_fully_broke_code_gate(breaker: InstalledCard, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> void:
	# Fires on_fully_break_code_gate when every subroutine on a code gate is now broken.
	if not encounter.all_broken():
		return
	var ice_subtypes: Array = encounter.ice_card.card_record.subtypes if encounter.ice_card.card_record != null else []
	ice_subtypes = ice_subtypes + encounter.ice_card.extra_subtypes
	if not "code_gate" in ice_subtypes:
		return
	var trigger: Variant = ability_registry.get_on_fully_break_code_gate(breaker.card_id)
	if trigger == null:
		return
	# Execute supported effects inline (counter placement only).
	for eff in (trigger as Dictionary).get("effects", []) as Array:
		if eff.get("type", "") == "add_self_counters":
			var counter_type: String = eff.get("counter", "power")
			var amount: int = eff.get("amount", 1)
			breaker.add_counter(counter_type, amount)
			ctx.send_log("[Encounter] %s gains %d %s counter(s) (fully broke code gate)." % [
				breaker.display_name(), amount, counter_type])


func _check_tungsten_tailor(encounter: EncounterState, ctx: GameContext) -> void:
	# The Tungsten Tailor (VP3): first time per turn, gain 1 cr when breaking
	# a sub on ice with ≤0 strength.
	if encounter.effective_ice_strength() > 0:
		return
	var tt_key := "_tt_first_break"
	if ctx.once_per_turn_triggered.get(tt_key, false):
		return
	for rig_card in ctx.runner_rig:
		var tt_ic: InstalledCard = rig_card as InstalledCard
		if tt_ic != null and tt_ic.card_id == "the_tungsten_tailor":
			ctx.once_per_turn_triggered[tt_key] = true
			ctx.runner_credits += 1
			ctx.send_log("The Tungsten Tailor: %s gains 1 cr." % ctx.runner_name())
			break


func _ask_runner_choose_subs(candidates: Array, max_count: int,
		breaker: InstalledCard, encounter: EncounterState, ctx: GameContext) -> Array:
	# Ask the runner to choose exactly `max_count` subroutine indices to break from `candidates`.
	# Falls back to the first `max_count` in candidate order if no DM method is available.
	#
	# DM method signature:
	#   choose_subs_to_break(candidates: Array[int], max_count: int,
	#                        encounter: EncounterState, ctx: GameContext) -> Array[int]
	# Returns the chosen subset of candidate indices (length == max_count, or fewer if candidates
	# is exhausted, though that shouldn't happen).
	if ctx.runner_decision_maker != null and \
			ctx.runner_decision_maker.has_method("choose_subs_to_break"):
		var chosen: Array = await ctx.runner_decision_maker.choose_subs_to_break(
			candidates, max_count, encounter, ctx)
		# Validate: all returned indices must be in candidates; clamp to max_count.
		var validated: Array = []
		for idx in chosen:
			if idx in candidates and not idx in validated:
				validated.append(idx)
				if validated.size() >= max_count:
					break
		if not validated.is_empty():
			var labels: Array = []
			for idx in validated:
				labels.append((encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx))
			ctx.send_log("[Encounter] %s chooses to break: %s" % [
				breaker.display_name(), ", ".join(labels)])
			return validated

	# Fallback: use AI heuristic — break the most dangerous-looking subs first.
	# "Dangerous" = subs that end the run, deal damage, or give tags are highest priority.
	var scored: Array = []
	for idx in candidates:
		var sub_def: Dictionary = encounter.subroutines[idx] as Dictionary
		var label: String = sub_def.get("label", "").to_lower()
		var priority: int = 0
		# End-the-run subs are highest danger (the ice stops us without them)
		if "end the run" in label or "end_run" in label:
			priority = 100
		# Damage subs are next
		elif "damage" in label or "net" in label or "meat" in label or "brain" in label:
			priority = 80
		# Tag subs
		elif "tag" in label:
			priority = 60
		# Trash subs
		elif "trash" in label:
			priority = 50
		# Credit loss
		elif "lose" in label or "credit" in label:
			priority = 30
		scored.append({"idx": idx, "priority": priority})
	scored.sort_custom(func(a, b): return a.priority > b.priority)
	var result: Array = []
	for i in range(mini(max_count, scored.size())):
		result.append(scored[i].idx)
	return result


func _trash_breaker(breaker: InstalledCard, ctx: GameContext) -> void:
	# trash_self_on_use: card trashes itself after breaking (Boomerang).
	# Keep the run_end listener alive so the heap-recur ability can still fire.
	ctx.runner_rig.erase(breaker)
	ctx.unregister_card_effects_except_event(breaker.runtime_instance_id, "run_end")
	if breaker.card_record != null:
		ctx.runner_discard.append(breaker.card_record)
	ctx.send_log("[Encounter] %s is trashed." % breaker.display_name())


# ── Parhelion: Orca on_fully_break_sentry trigger ────────────────────────────

func _check_fully_broke_sentry_async(card_id: String, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry, interpreter: Object) -> void:
	# Fires when all subroutines on a sentry have been broken this encounter.
	# Used by: Orca (charge 1 installed card on first full-break per turn).
	if not encounter.all_broken():
		return
	var ice_subtypes: Array = encounter.ice_card.card_record.subtypes \
		if encounter.ice_card.card_record != null else []
	ice_subtypes = ice_subtypes + encounter.ice_card.extra_subtypes
	if not "sentry" in ice_subtypes:
		return
	var trigger: Variant = ability_registry.get_on_fully_break_sentry(card_id)
	if trigger == null:
		return
	# Set context so self-referencing effects can find the breaker.
	var trigger_dict: Dictionary = trigger as Dictionary
	ctx.current_event_data["card_instance_id"] = \
		ctx.current_event_data.get("card_instance_id", card_id)
	await interpreter.execute_trigger(trigger_dict, ctx)


# ── Parhelion: Matryoshka break ──────────────────────────────────────────────

func _do_matryoshka_break(action: Dictionary, encounter: EncounterState, ctx: GameContext) -> bool:
	# Interface: X credits + turn 1 hosted copy facedown → break X subs.
	# The runner pays X cr AND turns 1 currently-faceup hosted copy facedown.
	# Each activation breaks up to X unbroken printed subroutines.
	var card_id: String = action.get("card_id", "")
	var matryoshka: InstalledCard = _find_card_in_rig(card_id, ctx)
	if matryoshka == null:
		push_error("EncounterProcessor: matryoshka_break — '%s' not found in rig" % card_id)
		return false

	# ── Uprising: Next Activation Command — non-icebreakers cannot break subs ──
	if _blocked_by_next_activation_command(ctx, matryoshka.card_record):
		return false

	# Count faceup hosted copies.
	var faceup_hosted: Array = []
	for hc in matryoshka.hosted_cards:
		var hc_ic: InstalledCard = hc as InstalledCard
		if hc_ic != null and not hc_ic.is_facedown:
			faceup_hosted.append(hc_ic)
	if faceup_hosted.is_empty():
		ctx.send_log("[Matryoshka] No faceup hosted copies available to spend.")
		return false

	# Determine how many subs to break and credit cost.
	var sub_indices: Array = action.get("sub_indices", []) as Array
	if sub_indices.is_empty():
		# Fallback: use all unbroken subs (up to faceup_hosted count * whatever credits allow)
		var max_x: int = mini(faceup_hosted.size(), encounter.unbroken_indices().size())
		if max_x == 0:
			ctx.send_log("[Matryoshka] No unbroken subs to break.")
			return true
		max_x = mini(max_x, ctx.runner_available_credits())
		if max_x == 0:
			ctx.send_log("[Matryoshka] Cannot afford Matryoshka break (need ≥1 cr).")
			return false
		sub_indices = encounter.unbroken_indices().slice(0, max_x)

	var x: int = sub_indices.size()
	if x == 0:
		return true

	# Check we have X credits and at least 1 faceup hosted copy.
	if ctx.runner_available_credits() < x:
		ctx.send_log("[Matryoshka] Cannot afford to break %d sub(s) — need %d cr." % [x, x])
		return false
	if faceup_hosted.is_empty():
		ctx.send_log("[Matryoshka] No faceup hosted copies to spend.")
		return false

	# Pay X credits.
	ctx.runner_spend_credits(x)

	# Turn 1 faceup hosted copy facedown.
	var spent_copy: InstalledCard = faceup_hosted[0] as InstalledCard
	spent_copy.is_facedown = true
	ctx.send_log("[Matryoshka] Spends %d cr + turns 1 hosted copy facedown to break %d sub(s)." % [x, x])

	# Break the chosen subs.
	for idx in sub_indices:
		if idx >= 0 and idx < encounter.subroutines.size() and not encounter.is_broken(idx):
			encounter.break_subroutine(idx)
			var sub_label: String = (encounter.subroutines[idx] as Dictionary).get("label", "sub %d" % idx)
			ctx.send_log("[Matryoshka] Breaks '%s'." % sub_label)

	return true


# ── Parhelion: Flux Capacitor trojan first-break trigger ─────────────────────

func _check_flux_capacitor(encounter: EncounterState, ctx: GameContext, interpreter: Object) -> void:
	# Fires the first time the Runner breaks a subroutine during an encounter with
	# the ice hosting Flux Capacitor.  Each installed Flux Capacitor fires once per
	# encounter (tracked via run_modifiers["flux_cap_fired_<iid>"]).
	if encounter.ice_card == null:
		return
	for hc in encounter.ice_card.hosted_cards:
		var hc_ic: InstalledCard = hc as InstalledCard
		if hc_ic == null or hc_ic.card_id != "flux_capacitor":
			continue
		var fc_key: String = "flux_cap_fired_" + hc_ic.runtime_instance_id
		if ctx.run_modifiers.get(fc_key, false):
			continue
		ctx.run_modifiers[fc_key] = true
		ctx.send_log("[Flux Capacitor] First sub broken this encounter — %s may charge 1 installed card." % \
			ctx.runner_name())
		# Optional: Runner may charge 1 installed card
		var fc_opt := false
		if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
			fc_opt = await ctx.runner_decision_maker.choose_optional_ability(
				"Flux Capacitor: charge 1 installed card?", ctx)
		else:
			fc_opt = true  # AI: always charge if possible
		if fc_opt:
			await interpreter.execute_trigger({"effects": [{"type": "charge_card"}]}, ctx)
