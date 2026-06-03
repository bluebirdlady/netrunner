class_name AbilityInterpreter
extends RefCounted

# ── AbilityInterpreter ────────────────────────────────────────────────────────
# Executes structured ability definitions from AbilityRegistry against a
# GameContext. Contains no game state of its own — it is purely a function
# from (definition, context) -> (mutated context).
#
# Adding support for a new card that uses existing effect types: write JSON.
# Adding a new effect type: add one handler to _execute_effect().
#
# Usage:
#   var interp := AbilityInterpreter.new()
#   await interp.execute_trigger(ability_def, context)


var _encounter_processor: EncounterProcessor = EncounterProcessor.new()


# ── Public entry points ───────────────────────────────────────────────────────

# Execute a trigger definition (on_play, on_access, on_rez, etc.)
# These are the dicts returned by AbilityRegistry.get_on_play() etc.
func execute_trigger(trigger_def: Dictionary, ctx: GameContext) -> void:
	# Route modal abilities to the modal executor
	if trigger_def.has("modes"):
		await execute_modal_trigger(trigger_def, ctx)
		return

	# Check top-level condition
	if trigger_def.has("condition"):
		if not _evaluate_condition(trigger_def["condition"] as Dictionary, ctx):
			ctx.send_log("Condition not met — ability has no effect.")
			return

	# Resolve targeting if required
	var chosen_target: Variant = null
	if trigger_def.has("target"):
		chosen_target = await _resolve_target(trigger_def["target"] as Dictionary, ctx)
		if chosen_target == null:
			ctx.send_log("No valid targets — ability has no effect.")
			return

	# Execute effects
	var effects: Array = trigger_def.get("effects", []) as Array
	for effect in effects:
		await _execute_effect(effect as Dictionary, ctx, chosen_target)


# Execute a single subroutine definition.
# Returns true if the subroutine fired, false if its condition blocked it.
func execute_subroutine(sub_def: Dictionary, ctx: GameContext) -> bool:
	if sub_def.has("condition"):
		if not _evaluate_condition(sub_def["condition"] as Dictionary, ctx):
			ctx.send_log("Subroutine condition not met — no effect.")
			return false

	var effects: Array = sub_def.get("effects", []) as Array
	for effect in effects:
		await _execute_effect(effect as Dictionary, ctx, null)
	return true


# ── Condition evaluation ──────────────────────────────────────────────────────

func _evaluate_condition(condition: Dictionary, ctx: GameContext) -> bool:
	var ctype: String = condition.get("type", "")
	var params: Dictionary = condition.get("params", {}) as Dictionary

	match ctype:
		"runner_is_tagged":
			return ctx.runner_is_tagged()

		"credits_compare":
			var subject: String   = params.get("subject", "runner")
			var operator: String  = params.get("operator", "lte")
			var value: int        = params.get("value", 0)
			var credits: int      = ctx.get_credits(subject)
			match operator:
				"lt":  return credits <  value
				"lte": return credits <= value
				"gt":  return credits >  value
				"gte": return credits >= value
				"eq":  return credits == value
				"neq": return credits != value
			push_error("AbilityInterpreter: unknown operator '%s'" % operator)
			return false

		"and":
			var conditions: Array = condition.get("conditions", []) as Array
			for c in conditions:
				if not _evaluate_condition(c as Dictionary, ctx):
					return false
			return true

		"or":
			var conditions: Array = condition.get("conditions", []) as Array
			for c in conditions:
				if _evaluate_condition(c as Dictionary, ctx):
					return true
			return false

		"not":
			var inner: Dictionary = condition.get("condition", {}) as Dictionary
			return not _evaluate_condition(inner, ctx)

		"runner_made_successful_run":
			return ctx.runner_made_successful_run_this_turn

		"runner_ran_all_three_centrals_this_turn":
			# True when the runner made successful runs on HQ, R&D, AND Archives this turn.
			# Used by Jeitinho (add-self-to-score trigger) and The Wizard's Chest (trash condition).
			return ctx.runner_hq_successful_run_this_turn \
				and ctx.runner_successful_run_on_rd_this_turn \
				and ctx.runner_successful_run_on_archives_this_turn

		"runner_made_successful_run_last_turn":
			# Public Trail: "Play only if the Runner made a successful run during their last turn."
			return ctx.runner_made_successful_run_last_turn

		"runner_stole_or_trashed_last_runner_turn":
			# Active Policing / Bring Them Home pre-play condition.
			return ctx.runner_stole_or_trashed_last_runner_turn

		"corp_discarded_last_turn":
			return ctx.corp_discarded_to_hand_limit_last_turn

		"corp_scored_agenda_this_turn":
			return ctx.corp_last_scored_agenda_points > 0

		"first_agenda_scored_this_turn":
			# True only while the very first agenda of this Corp turn is being scored.
			return ctx.corp_agendas_scored_this_turn == 1

		"first_mandate_this_turn":
			# True when no Mandate-subtype operation has been played yet this Corp turn.
			# Evaluated during on_play resolution, before TurnManager increments the counter.
			return ctx.corp_mandates_played_this_turn == 0

		"threat_gte":
			# True when the current threat level (runner's agenda points) is at or above
			# the specified threshold.  Used by all "threat X" card abilities.
			# params: { "value": int }  (or top-level "value" for shorthand)
			var tg_threshold: int = condition.get("value", params.get("value", 0))
			return ctx.threat_level() >= tg_threshold

		"tags_compare":
			# Evaluate the runner's tag count against a threshold.
			# params: { "operator": "gte"|"lte"|"gt"|"lt"|"eq", "value": int }
			var operator: String = params.get("operator", "gte")
			var value: int       = params.get("value", 0)
			var tags: int        = ctx.runner_tags
			match operator:
				"lt":  return tags <  value
				"lte": return tags <= value
				"gt":  return tags >  value
				"gte": return tags >= value
				"eq":  return tags == value
				"neq": return tags != value
			push_error("AbilityInterpreter: unknown operator '%s' in tags_compare" % operator)
			return false

		"self_counter_gte":
			# True if the owning card has >= threshold of a given counter type.
			# Used by Syailendra: fire bonus ability when 3+ advancement counters.
			var sc_counter: String = condition.get("counter", "advancement")
			var sc_threshold: int  = condition.get("threshold", 0)
			var sc_card := _get_self_card(ctx)
			if sc_card == null:
				return false
			return sc_card.get_counter(sc_counter) >= sc_threshold

		"agenda_on_my_server":
			# True when the scored/stolen agenda's server matches the listening card's server.
			# Used by Lamplighter: self-trash whenever an agenda leaves its protecting server.
			var ams_event_server: String = ctx.current_event_data.get("server_id", "")
			if ams_event_server == "":
				return false
			var ams_card := _get_self_card(ctx)
			if ams_card == null:
				return false
			return ams_card.server_id == ams_event_server

		"self_is_rezzed":
			# True when the owning card (card_instance_id) is currently rezzed.
			# Used by Public Access Plaza threat variant: tag only fires if the asset is rezzed.
			var sir_card := _get_self_card(ctx)
			if sir_card == null:
				return false
			return sir_card.is_rezzed

		"self_in_corp_score_area":
			# True when the owning card is currently in the Corp's scored-agenda area.
			# Used by scored-agenda ongoing effects (e.g. Aggressive Trendsetting) so they
			# fire only after the agenda is scored, not while still installed face-down.
			var sca_card := _get_self_card(ctx)
			if sca_card == null:
				return false
			for sca_c in ctx.corp_score_area_cards:
				var sca_ic: InstalledCard = sca_c as InstalledCard
				if sca_ic != null and sca_ic.runtime_instance_id == sca_card.runtime_instance_id:
					return true
			return false

		"ice_on_my_server":
			# True when the approached/encountered ice is protecting the same server as the
			# listening card, AND the listening card is rezzed.
			# Used by Mitra Aman: fire only when ice on its own server is approached.
			var ims_ice: InstalledCard = ctx.current_event_data.get("ice", null) as InstalledCard
			if ims_ice == null:
				return false
			var ims_card := _get_self_card(ctx)
			if ims_card == null or not ims_card.is_rezzed:
				return false
			return ims_card.server_id == ims_ice.server_id

		"run_active":
			# True when a run is currently in progress.
			# Used by Bumi 1.0: rez trigger only fires when rezzed during a run.
			return ctx.run_active

		"subroutine_resolved_this_run":
			# True when at least one subroutine has resolved during the current run.
			# Ryo "Phoenix" Ōno: first successful run after a subroutine resolved.
			return ctx.run_had_subroutine_resolve

		"runner_not_tagged":
			# True when the runner has no tags.
			return not ctx.runner_is_tagged()

		"self_on_central_server":
			# True when the owning card is installed on a central server (HQ, R&D, or Archives).
			# Used by: Grubber — take bad pub on rez if it protects a central.
			var sons_card: InstalledCard = ctx.current_event_data.get("card", null) as InstalledCard
			if sons_card == null:
				return false
			return sons_card.server_id in ["hq", "rd", "archives"]

		"run_was_on_host_server":
			# True when the current run's target server is the same server the owning trojan's
			# host ice belongs to.  Used by: Stowaway (gain 2cr on successful run on this server).
			var rwhs_iid: String = ctx.current_event_data.get("card_instance_id", "")
			if rwhs_iid == "":
				return false
			for rwhs_srv in ctx.servers.values():
				var rwhs_s: Server = rwhs_srv as Server
				for rwhs_ice in rwhs_s.ice:
					var rwhs_ic: InstalledCard = rwhs_ice as InstalledCard
					if rwhs_ic == null:
						continue
					for rwhs_hosted in rwhs_ic.hosted_cards:
						var rwhs_h: InstalledCard = rwhs_hosted as InstalledCard
						if rwhs_h != null and rwhs_h.runtime_instance_id == rwhs_iid:
							return rwhs_s.server_id == ctx.run_target_server
			return false

		"agenda_scored_or_stolen_this_turn":
			# True when at least one agenda was scored by Corp or stolen by Runner this turn.
			# Used by: Hype Machine (rez cost discount when an agenda changes hands).
			return ctx.corp_agendas_scored_this_turn > 0 or ctx.runner_stole_agenda_this_turn

		"ice_rezzed_this_turn":
			# True when at least one piece of ice was rezzed this turn.
			# Used by: Underdome Irregulars end-of-turn bonus.
			return ctx.ice_rezzed_this_turn

		"corp_scored_non_installed_agenda_this_turn":
			# True when the Corp scored an agenda that was not installed this turn.
			# Used by: Myōshu (play condition).
			return ctx.corp_scored_agenda_not_installed_this_turn

		"runner_stole_agenda_this_turn":
			# True when the Runner has stolen at least one agenda this turn.
			# Used by: various Corp reaction effects.
			return ctx.runner_stole_agenda_this_turn

		"run_was_successful":
			# True when the most recent run (or current run) was successful.
			# Persists after run ends — effects after choose_and_run/initiate_run can check it.
			# Used by: VP2 Take a Dive (conditional bad pub), VP10 Kompromat (derez choice).
			return ctx.run_successful

		"runner_has_no_clicks":
			# True when the runner has zero or fewer clicks remaining.
			# Used by: VP31 Vertigo (prevent steal/trash when runner has no clicks).
			return ctx.runner_clicks <= 0

		"pass_ice_is_outermost":
			# True when the ice just passed is the outermost ice on the server (index 0).
			# Set by RunStateMachine in the pass_ice event payload.
			# Used by: VP23 Sipa (Corp may swap only when Sipa is the outermost ice passed).
			return ctx.current_event_data.get("is_outermost", false)

		"pass_ice_all_subs_broken":
			# True when all subroutines on the just-passed ice were broken.
			# Set by RunStateMachine in the pass_ice event payload.
			# Used by: VP23 Sipa (Corp may swap only when all subs were broken).
			return ctx.current_event_data.get("all_subs_broken", false)

		"pass_ice_is_self":
			# True when the ice being passed is this registered card itself.
			# Needed because pass_ice fires for all registered listeners, not just the passed ice.
			# Used by: VP23 Sipa, VP31 Vertigo (trigger only when self is passed).
			var pis_ice: InstalledCard    = ctx.current_event_data.get("ice", null) as InstalledCard
			if pis_ice == null:
				return false
			var pis_self := _get_self_card(ctx)
			if pis_self == null:
				return false
			return pis_ice.runtime_instance_id == pis_self.runtime_instance_id

		"pass_ice_is_code_gate_or_sentry":
			# True when the ice just passed is a rezzed code gate or sentry.
			# Used by: Sisyphus Protocol (trigger re-encounter option on code gate/sentry pass).
			var pcgos_ice: InstalledCard = ctx.current_event_data.get("ice", null) as InstalledCard
			if pcgos_ice == null or not pcgos_ice.is_rezzed:
				return false
			if pcgos_ice.card_record == null:
				return false
			return pcgos_ice.card_record.has_subtype("code_gate") \
				or pcgos_ice.card_record.has_subtype("sentry")

		"encounter_ended_is_self":
			# True when the ice whose encounter just ended is this registered card itself.
			# Needed because encounter_ended fires for all registered listeners.
			# Used by: VP40 Knowledge Seeker (post-encounter virus counter check).
			var ees_ice: InstalledCard = ctx.current_event_data.get("ice", null) as InstalledCard
			if ees_ice == null:
				return false
			var ees_self := _get_self_card(ctx)
			if ees_self == null:
				return false
			return ees_ice.runtime_instance_id == ees_self.runtime_instance_id

		"encounter_is_self":
			# True when the ice currently being encountered is this card itself.
			# Works for both encounter_ice and encounter_ended event data (both carry "ice" field).
			# Used by: Seraph (on-encounter toll fires only for Seraph's own encounter).
			var eis_ice: InstalledCard = ctx.current_event_data.get("ice", null) as InstalledCard
			if eis_ice == null:
				return false
			var eis_self := _get_self_card(ctx)
			if eis_self == null:
				return false
			return eis_ice.runtime_instance_id == eis_self.runtime_instance_id

		"event_param_gte":
			# True when a named key in the current event data is >= a threshold.
			# Condition dict fields: "key" (String), "threshold" (int).
			# Used by: VP7 Nurse Hanh (archives_cards_turned_faceup count >= 2).
			var epg_key: String    = condition.get("key", "")
			var epg_threshold: int = condition.get("threshold", 0)
			var epg_value: int     = int(ctx.current_event_data.get(epg_key, 0))
			return epg_value >= epg_threshold

		"all_centrals_successful_run_this_turn":
			# True when the Runner has made a successful run on HQ, R&D, and Archives
			# this turn (VP1 Chain Reaction play condition).
			return ctx.runner_hq_successful_run_this_turn and \
				   ctx.runner_successful_run_on_rd_this_turn and \
				   ctx.runner_successful_run_on_archives_this_turn

		"advance_target_is_self":
			# True when the card being advanced is this card itself (VP56 SZE).
			# Relies on current_event_data["card_id"] matching the listening card's card_id.
			var ats_self_card := _get_self_card(ctx)
			if ats_self_card == null:
				return false
			var ats_advanced_id: String = ctx.current_event_data.get("card_id", "")
			return ats_self_card.card_id == ats_advanced_id

		"run_target_is_not_self_server":
			# True when the run target server is not the server this card is installed in (VP56 SZE).
			var rtns_self_card := _get_self_card(ctx)
			if rtns_self_card == null:
				return false
			var rtns_run_server: String = ctx.current_event_data.get("server_id", "")
			return rtns_run_server != "" and rtns_run_server != rtns_self_card.server_id

		"run_target_is_self_server":
			# True when the active run is targeting the server this card is installed in.
			# Used by VP64 Flagship (approach_server) and VP65 Shackleton Grid.
			var rtss_card := _get_self_card(ctx)
			if rtss_card == null:
				return false
			return ctx.run_target_server != "" and ctx.run_target_server == rtss_card.server_id

		"installed_card_is_hardware":
			# True when the runner_installs_card event data refers to a hardware card.
			# Used by VP17 Hiram to filter the install trigger.
			var ich_card := _get_self_card(ctx)
			if ich_card == null:
				return false
			return ich_card.card_record != null and ich_card.card_record.card_type == "hardware"

		"hardware_trashed_source_is_runner":
			# True when the hardware_trashed event was sourced by the runner (not Corp or game).
			# Used by VP17 Hiram to exclude Corp-caused and game-caused hardware trashes.
			return ctx.current_event_data.get("source", "") == "runner"

		# ── VP36 Méliès U conditions ─────────────────────────────────────────────

		"run_target_is_central_server":
			# True when the run target is any central server (hq, rd, or archives).
			# Used by Méliès U front-side to gate the flip trigger on successful_run.
			var rtcs_server: String = ctx.current_event_data.get("server_id", "")
			return rtcs_server in ["hq", "rd", "archives"]

		"melies_u_not_flipped":
			# True when Méliès U is on its front side (not currently flipped to a back side).
			# Used to gate the +1 credit trigger at runner_action_phase_ends.
			return not ctx.melies_u_flipped

		"melies_u_is_flipped":
			# True when Méliès U is on one of its three back sides.
			# Used to gate the flip-back trigger at runner_discard_phase_ends.
			return ctx.melies_u_flipped

		"melies_u_secret_matches_run_server":
			# True when the Corp's secretly chosen side matches the server in the current event.
			# Used to gate the back-side ability on melies_u_flipped: ability only resolves
			# when the prediction was correct.
			var smrs_server: String = ctx.current_event_data.get("server_id", "")
			return ctx.melies_u_secret_side != "" and ctx.melies_u_secret_side == smrs_server

		"self_has_subtype":
			# True when the owning card (as an InstalledCard) currently has the given subtype,
			# including any runtime-granted extra_subtypes.
			# Used by: Lycian Multi-Munition subroutines (conditional on chosen subtype).
			# Condition dict field: "subtype" (String, normalised underscore form).
			var shs_self := _get_self_card(ctx)
			if shs_self == null:
				return false
			var shs_subtype: String = condition.get("subtype", "").to_lower().replace(" ", "_")
			# Check printed subtypes via CardRecord, then runtime-granted extra_subtypes
			if shs_self.card_record != null and shs_self.card_record.has_subtype(shs_subtype):
				return true
			return shs_self.extra_subtypes.has(shs_subtype)

		"run_modifier_false":
			# True when a run_modifiers key is absent or false.
			# Used by: Pressure Spike (once-per-run +9 str; button hidden after first use).
			var rmf_key: String = condition.get("key", "")
			return not ctx.run_modifiers.get(rmf_key, false)

		"rezzed_card_is_host":
			# True when the card that was just rezzed (corp_rezzes_ice/corp_rezzes_card event)
			# is the same ice this trojan is hosted on.
			# Used by: Isaac Liberdade (gain counter when host ice is rezzed).
			var rch_rezzed: InstalledCard = ctx.current_event_data.get("card", null) as InstalledCard
			if rch_rezzed == null:
				return false
			var rch_self := _get_self_card(ctx)
			if rch_self == null:
				return false
			return rch_rezzed.runtime_instance_id == rch_self.hosted_on_id

		"run_target_is":
			# True when the current run target server matches the given "server" key.
			# Used by: Cataloguer (gate successful_run trigger to R&D only).
			var rti_server: String = condition.get("server", "")
			var rti_run_server: String = ctx.current_event_data.get("server_id", ctx.run_target_server)
			return rti_run_server == rti_server

		"event_server_is_hq":
			# True when the current event's server_id is hq.
			# Used by: The Basalt Spire (before_breach +1 access to HQ only).
			return ctx.current_event_data.get("server_id", "") == "hq"

		"event_server_is_hq_or_rd":
			# True when the current event's server_id is hq or rd.
			# Used by: Manuel Lattes de Moura (before_breach bonus access),
			#          Amelia Earhart (card_accessed_event tracking).
			var eshr_server: String = ctx.current_event_data.get("server_id", "")
			return eshr_server in ["hq", "rd"]

		"amelia_count_gte":
			# True when ctx.amelia_hq_rd_access_count >= the given threshold.
			# Used by: Amelia Earhart (gate turn-start activation ability).
			var amelia_threshold: int = condition.get("count", 3)
			return ctx.amelia_hq_rd_access_count >= amelia_threshold

		"runner_is_untagged":
			# True when the runner has no tags.
			# Used by: Eye for an Eye, Privileged Access (play condition).
			return ctx.runner_tags == 0

		"rezzed_this_turn":
			# True when the owning card was rezzed during the current Corp turn.
			# Checks ctx.ice_rezzed_this_turn_instance_ids (populated at every rez site).
			# Used by: Cloud Eater (encounter_ended gate).
			var rtt_self := _get_self_card(ctx)
			if rtt_self == null:
				return false
			return ctx.ice_rezzed_this_turn_instance_ids.has(rtt_self.runtime_instance_id)

		"runner_gained_first_tag":
			# True when the runner_takes_tags event payload carries from_zero = true,
			# meaning runner_tags was 0 before this tag was granted.
			# Used by: Sebastiao Souza Pessoa (install connection when going from 0 tags).
			return ctx.current_event_data.get("from_zero", false)

		"self_has_hosted_corp_cards":
			# True when the owning program has at least one corp card stored in hosted_corp_cards.
			# Used by: Cupellation (before_breach gate for +2 HQ access offer).
			var shcc_self := _get_self_card(ctx)
			if shcc_self == null:
				return false
			return not shcc_self.hosted_corp_cards.is_empty()

		"archives_distinct_card_types_gte":
			# True when Archives contains at least N distinct corp card types.
			# Counts unique card_type values across all CardRecord entries in ctx.corp_discard.
			# Used by: Logjam (on_rez counter initialisation check).
			var adct_threshold: int = condition.get("count", 1)
			var adct_types: Array = []
			for adct_cr in ctx.corp_discard:
				var adct_c: CardRecord = adct_cr as CardRecord
				if adct_c != null and not adct_types.has(adct_c.card_type):
					adct_types.append(adct_c.card_type)
			return adct_types.size() >= adct_threshold

		"grip_size_gte":
			# True when the runner's grip (hand) has >= N cards.
			# Phoneutria on_runner_passes: "if there are 4 or more cards in the grip".
			# Value can be at the condition top level or nested under "params".
			var gsg_threshold: int = condition.get("value", params.get("value", 4))
			return ctx.runner_hand.size() >= gsg_threshold

		"ice_not_broken_with_decoder":
			# True when no decoder icebreaker broke any subroutine during the
			# most recent encounter — stored in current_event_data by _fire_on_pass_triggers.
			# Virtual Service Agent fires a tag when this is true.
			return not ctx.current_event_data.get("broken_with_decoder", false)

		_:
			push_error("AbilityInterpreter: unknown condition type '%s'" % ctype)
			return false


# ── Target resolution ─────────────────────────────────────────────────────────

func _resolve_target(target_spec: Dictionary, ctx: GameContext) -> Variant:
	var ttype: String   = target_spec.get("type", "")
	var params: Dictionary = target_spec.get("params", {}) as Dictionary

	var candidates: Array = []

	match ttype:
		"installed_card":
			var controller: String = params.get("controller", "")
			var card_types: Array  = params.get("card_types", []) as Array
			var exclude_installed_this_turn: bool = params.get("exclude_installed_this_turn", false)
			var pool: Array = []
			if controller == "runner" or controller == "":
				pool.append_array(ctx.runner_rig)
			if controller == "corp" or controller == "":
				pool.append_array(ctx.all_installed())
			candidates = pool.filter(func(c: InstalledCard):
				var type_match: bool = card_types.is_empty() or card_types.has(c.card_record.card_type)
				var turn_ok: bool = not exclude_installed_this_turn or \
					not ctx.corp_installed_this_turn.has(c.card_id)
				return type_match and turn_ok
			)
		_:
			push_error("AbilityInterpreter: unknown target type '%s'" % ttype)
			return null

	if candidates.is_empty():
		return null

	# Random selection (e.g. HQ access)
	if params.get("random", false):
		return candidates[randi() % candidates.size()]

	# Ask the decision maker to choose
	var decision_maker: Object = ctx.corp_decision_maker if ctx.active_player == "corp" else ctx.runner_decision_maker
	if decision_maker == null:
		push_error("AbilityInterpreter: target required but no decision_maker set")
		return candidates[0]

	var choice_context := {
		"reason": "target",
		"target_spec": target_spec
	}
	if not decision_maker.has_method("choose_target"):
		return candidates[0]
	return await decision_maker.choose_target(candidates, choice_context)


# ── Effect execution ──────────────────────────────────────────────────────────

func _execute_effect(effect: Dictionary, ctx: GameContext, chosen_target: Variant) -> void:
	# Optional per-effect condition guard (e.g. Esca: only deal damage if runner is tagged)
	if effect.has("condition"):
		if not _evaluate_condition(effect["condition"] as Dictionary, ctx):
			return

	var etype: String    = effect.get("type", "")
	var params: Dictionary = effect.get("params", {}) as Dictionary

	match etype:

		"gain_credits":
			var subject: String = params.get("subject", "corp")
			var amount: int     = params.get("amount", 0)
			ctx.set_credits(subject, ctx.get_credits(subject) + amount)
			ctx.send_log("%s gains %d credits." % [ctx.player_name(subject), amount])
			# The Zwicky Group: fire event when Corp gains credits via agenda/operation ability.
			if subject == "corp" and amount > 0 and \
					ctx.current_ability_source_card_type in ["operation", "agenda"]:
				await ctx.notify_event("corp_gains_credits_via_ability", {"amount": amount}, self)

		"lose_credits":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 0)
			var current: int    = ctx.get_credits(subject)
			var lost: int       = min(amount, current)  # can't go below 0
			ctx.set_credits(subject, current - lost)
			ctx.send_log("%s loses %d credits." % [ctx.player_name(subject), lost])

		"corp_loses_runner_gains_double":
			# Transfer of Wealth: Corp loses up to N credits; Runner gains 2× the amount lost.
			var tow_amount: int  = params.get("amount", 3)
			var tow_lost: int    = min(tow_amount, ctx.corp_credits)
			ctx.corp_credits    -= tow_lost
			var tow_gained: int  = tow_lost * 2
			ctx.runner_credits  += tow_gained
			ctx.send_log("Transfer of Wealth: %s loses %d cr; %s gains %d cr." % [
				ctx.corp_name(), tow_lost, ctx.runner_name(), tow_gained
			])

		"tag_or_spend_click":
			# Jaguarundi (TAI): Runner must spend 1 click or take 1 tag.
			# If the runner has no clicks, they must take the tag (no choice offered).
			# params: (none — always 1 click / 1 tag)
			var tosc_has_click: bool = ctx.runner_clicks > 0
			var tosc_spend_click: bool = false
			if tosc_has_click:
				# Offer the choice via choose_optional_ability: true = spend click, false = take tag.
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_optional_ability"):
					tosc_spend_click = await ctx.runner_decision_maker.choose_optional_ability(
						"Spend 1[click] to avoid 1 tag? (Jaguarundi)", ctx)
				else:
					tosc_spend_click = true  # AI default: spend the click
			if tosc_spend_click and tosc_has_click:
				ctx.runner_clicks -= 1
				ctx.send_log("[Jaguarundi] Runner spends 1[click] to avoid the tag. (%d remaining)" % ctx.runner_clicks)
			else:
				var tosc_was_zero: bool = (ctx.runner_tags == 0)
				ctx.runner_tags += 1
				ctx.send_log("[Jaguarundi] Runner takes 1 tag. (%d total)" % ctx.runner_tags)
				await ctx.notify_event("runner_takes_tags", {"amount": 1, "from_zero": tosc_was_zero}, self)

		"runner_loses_click":
			# M.I.C. subroutine: Runner loses 1 click (floored at 0).
			var rlc_amount: int = params.get("amount", 1)
			ctx.runner_clicks = max(0, ctx.runner_clicks - rlc_amount)
			ctx.send_log("Runner loses %d click(s). (%d remaining)" % [rlc_amount, ctx.runner_clicks])

		"runner_click_or_etr":
			# M.I.C. ice_paid_ability effect: Runner may spend 1 click to avoid ending the run.
			# If the runner has no clicks or declines, the run ends.
			var rce_has_click: bool = ctx.runner_clicks > 0
			var rce_spend: bool = false
			if rce_has_click:
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_spend_click_to_continue"):
					rce_spend = await ctx.runner_decision_maker.choose_spend_click_to_continue(ctx)
				else:
					rce_spend = true  # AI / sim default: spend the click to continue
			if rce_spend and rce_has_click:
				ctx.runner_clicks -= 1
				ctx.send_log("Runner spends 1 click to continue the run. (%d remaining)" % ctx.runner_clicks)
			else:
				ctx.run_ended = true
				ctx.send_log("Runner cannot or does not spend a click — run ends.")

		"net_damage_pay_credits_optional":
			# Attini (TAI): Runner may pay `cost` credits to avoid `amount` net damage.
			# If ctx.runner_cannot_spend_credits_during_sub_resolution is true (Threat 3),
			# or if the runner cannot afford the cost, the damage resolves immediately.
			var ndpo_cost:   int = params.get("cost",   1)
			var ndpo_amount: int = params.get("amount", 1)
			var ndpo_blocked: bool = ctx.runner_cannot_spend_credits_during_sub_resolution
			var ndpo_can_afford: bool = ctx.runner_credits >= ndpo_cost
			var ndpo_pay: bool = false
			if not ndpo_blocked and ndpo_can_afford:
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_optional_ability"):
					ndpo_pay = await ctx.runner_decision_maker.choose_optional_ability(
						"Pay %d[credit] to avoid %d net damage?" % [ndpo_cost, ndpo_amount], ctx)
				else:
					ndpo_pay = true  # AI default: pay to avoid damage
			if ndpo_pay:
				ctx.runner_spend_credits(ndpo_cost)
				ctx.send_log("Runner pays %dcr to avoid %d net damage." % [ndpo_cost, ndpo_amount])
			else:
				if ndpo_blocked:
					ctx.send_log("[Attini] Runner cannot spend credits — %d net damage resolves." % ndpo_amount)
				await _deal_damage("net", ndpo_amount, ctx)

		"end_run":
			# Banner: if the runner spent 2cr to suppress ETR subs on this barrier, skip it.
			# Use has_meta guard — get_meta throws in some Godot 4 builds even with a default.
			var _etr_encounter: EncounterState = null
			if ctx.has_meta("_current_encounter"):
				_etr_encounter = ctx.get_meta("_current_encounter") as EncounterState
			if _etr_encounter != null and _etr_encounter.barrier_etr_suppressed:
				var _etr_ice: InstalledCard = _etr_encounter.ice_card
				if _etr_ice != null and _etr_ice.card_record != null and \
						_etr_ice.card_record.has_subtype("barrier"):
					ctx.send_log("[Banner] ETR subroutine suppressed.")
					return
			ctx.run_ended = true
			ctx.send_log("Run ended.")

		"end_run_if_tagged":
			# Subroutine: end the run only if the Runner currently has at least one tag.
			# Used by Lamplighter.
			if ctx.runner_is_tagged():
				ctx.run_ended = true
				ctx.send_log("End the run (Runner is tagged).")
			else:
				ctx.send_log("Runner has no tags — end-the-run sub is blank.")

		"end_run_if_threat_gte":
			# Subroutine: end the run only if the current threat level (runner's agenda
			# points) meets the threshold.  Used by N-Pot subs 2 and 3.
			# params: { "value": int }
			var eritg_threshold: int = params.get("value", 0)
			if ctx.threat_level() >= eritg_threshold:
				ctx.run_ended = true
				ctx.send_log("End the run (threat level %d >= %d)." % [ctx.threat_level(), eritg_threshold])
			else:
				ctx.send_log("Threat level %d < %d — sub is blank." % [ctx.threat_level(), eritg_threshold])

		"end_run_if_hq_gt_grip":
			# Subroutine: end the run if there are more cards in HQ than in the Runner's grip.
			# Used by Piranhas (RWR).
			var erigp_hq_count:   int = ctx.corp_hand.size()
			var erigp_grip_count: int = ctx.runner_hand.size()
			if erigp_hq_count > erigp_grip_count:
				ctx.run_ended = true
				ctx.send_log("End the run (HQ has %d card(s), grip has %d)." % [erigp_hq_count, erigp_grip_count])
			else:
				ctx.send_log("HQ (%d) is not greater than grip (%d) — sub is blank." % [erigp_hq_count, erigp_grip_count])

		"deal_damage":
			var damage_type: String = params.get("damage_type", "net")
			var amount_def          = params.get("amount", 0)
			var amount: int         = _resolve_amount(amount_def, ctx)
			await _deal_damage(damage_type, amount, ctx)

		"deal_damage_etr_if_odd_cost":
			# Diviner: do N net damage; if the trashed card has an odd printed cost, end the run.
			var damage_type: String = params.get("damage_type", "net")
			var amount: int         = _resolve_amount(params.get("amount", 1), ctx)
			var trashed_cards: Array = await _deal_damage(damage_type, amount, ctx)
			if not ctx.game_over and not trashed_cards.is_empty():
				var first: CardRecord = trashed_cards[0] as CardRecord
				if first != null:
					var printed_cost: int = max(0, first.cost)
					if printed_cost % 2 != 0:
						ctx.send_log("Diviner: %s has odd cost (%d) — run ends." % [first.title, printed_cost])
						ctx.run_ended = true
					else:
						ctx.send_log("Diviner: %s has even cost (%d) — run continues." % [first.title, printed_cost])

		"deal_damage_then_may_jack_out":
			# Karunā sub 1: do 2 net damage, then the Runner may jack out.
			# If they jack out, sub 2 (end the run) does not resolve even if unbroken.
			var damage_type: String = params.get("damage_type", "net")
			var amount: int         = _resolve_amount(params.get("amount", 2), ctx)
			await _deal_damage(damage_type, amount, ctx)
			if not ctx.game_over:
				# Offer jack-out window to the runner
				var did_jack_out := false
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_jack_out"):
					did_jack_out = await ctx.runner_decision_maker.choose_jack_out(ctx)
				if did_jack_out:
					ctx.send_log("%s jacks out after Karunā damage." % ctx.runner_name())
					ctx.run_ended = true
					# Mark that the runner chose to jack out so sub 2 is skipped
					ctx.set_meta("karuna_runner_jacked_out", true)

		"draw_cards":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 1)
			_draw_cards(subject, amount, ctx)

		"draw_cards_optional":
			# Subject may choose to draw N cards.  AI defaults to always drawing.
			# params: { subject: "corp"|"runner", amount: int }
			var doc_subject: String = params.get("subject", "corp")
			var doc_amount: int     = params.get("amount", 1)
			var doc_deck: Array = ctx.corp_deck if doc_subject == "corp" else ctx.runner_deck
			if doc_deck.is_empty():
				ctx.send_log("%s has no cards to draw." % ctx.player_name(doc_subject))
				return
			var doc_do_draw := false
			var doc_dm: Object = ctx.corp_decision_maker if doc_subject == "corp" else ctx.runner_decision_maker
			if doc_dm != null and doc_dm.has_method("choose_modes"):
				var doc_modes: Array = [
					{"label": "Draw %d card(s)" % doc_amount},
					{"label": "Pass"}
				]
				var doc_chosen: Array = await doc_dm.choose_modes(doc_modes, 1, ctx)
				doc_do_draw = (not doc_chosen.is_empty() and doc_chosen[0] == 0)
			else:
				doc_do_draw = true  # AI default: always draw
			if doc_do_draw:
				_draw_cards(doc_subject, doc_amount, ctx)

		"lago_paranoa_trash_draw_one":
			# Lago Paranoá Shelter (TAI): runner may trash the top card of the stack to
			# draw 1 card.  Ruling: can be used even if only 1 card remains in stack
			# (side-effects of paying the cost are ignored when determining eligibility).
			if ctx.runner_deck.is_empty():
				ctx.send_log("[Lago Paranoá Shelter] Stack is empty — cannot activate.")
				return
			var lp_use := false
			var lp_dm: Object = ctx.runner_decision_maker
			if lp_dm != null and lp_dm.has_method("choose_optional_ability"):
				lp_use = await lp_dm.choose_optional_ability(
					"Lago Paranoá Shelter: trash top stack card to draw 1?", ctx)
			else:
				lp_use = true  # AI default: always use
			if not lp_use:
				return
			# Pay cost: trash top card of stack
			var lp_top: CardRecord = ctx.runner_deck.pop_front() as CardRecord
			if lp_top != null:
				ctx.runner_discard.append(lp_top)
				ctx.send_log("[Lago Paranoá Shelter] %s trashes %s from top of stack." % [
					ctx.runner_name(), lp_top.title])
				# Fire on_self_trashed_from_grip_or_stack (e.g. Strike Fund on top of stack)
				await _fire_self_trashed_triggers([lp_top], ctx)
			# Draw 1 card
			_draw_cards("runner", 1, ctx)

		"runner_must_pay_or_end_run":
			# Runner must choose one of the listed payment options or end the run.
			# Used by Manegarm Skunkworks.
			var options: Array = params.get("options", []) as Array
			if options.is_empty():
				return

			# Build available options the runner can actually afford
			var affordable: Array = []
			for opt in options:
				var o: Dictionary = opt as Dictionary
				match o.get("type", ""):
					"clicks":
						if ctx.runner_clicks >= o.get("amount", 0):
							affordable.append(o)
					"credits":
						if ctx.runner_credits >= o.get("amount", 0):
							affordable.append(o)

			if affordable.is_empty():
				ctx.send_log("%s cannot afford any payment option — run ends." % ctx.runner_name())
				ctx.run_ended = true
				return

			# Ask runner to choose
			var dm: Object = ctx.runner_decision_maker
			var chosen: Variant = null
			if dm != null and dm.has_method("choose_payment_option"):
				chosen = await dm.choose_payment_option(affordable, ctx)
			else:
				chosen = null  # no decision maker — end run

			if chosen == null:
				ctx.send_log("%s ends the run (Manegarm Skunkworks)." % ctx.runner_name())
				ctx.run_ended = true
				return

			# Apply chosen payment
			var c: Dictionary = chosen as Dictionary
			match c.get("type", ""):
				"clicks":
					var amount: int = c.get("amount", 0)
					ctx.runner_clicks -= amount
					ctx.send_log("%s spends %d click(s) for Manegarm Skunkworks." % [ctx.runner_name(), amount])
				"credits":
					var amount: int = c.get("amount", 0)
					ctx.runner_credits -= amount
					ctx.send_log("%s pays %d cr for Manegarm Skunkworks." % [ctx.runner_name(), amount])

		"install_ice_from_hq":
			# Corp chooses an ice from HQ (or Archives if allowed) and installs it
			# on the current run server ignoring all costs.
			var also_archives: bool = params.get("also_archives", false)
			var candidates: Array = []
			for entry in ctx.corp_hand:
				var e: Dictionary = entry as Dictionary
				var r: CardRecord = e.get("card_record", null) as CardRecord
				if r != null and r.is_ice():
					candidates.append(e)
			if also_archives:
				for r in ctx.corp_discard:
					var record: CardRecord = r as CardRecord
					if record != null and record.is_ice():
						candidates.append({"card_id": record.id, "card_record": record, "_from_archives": true})
			if candidates.is_empty():
				ctx.send_log("%s has no ice in HQ%s to install." % [ctx.corp_name(), " or Archives" if also_archives else ""])
			else:
				var dm: Object = ctx.corp_decision_maker
				var chosen_entry: Variant = null
				if dm != null and dm.has_method("choose_card_from_hand"):
					chosen_entry = await dm.choose_card_from_hand(candidates, ctx)
				else:
					chosen_entry = candidates[0]
				if chosen_entry != null:
					var record: CardRecord = (chosen_entry as Dictionary).get("card_record", null) as CardRecord
					if record != null:
						if (chosen_entry as Dictionary).get("_from_archives", false):
							ctx.corp_discard.erase(record)
						else:
							ctx.corp_hand.erase(chosen_entry)
						# Use run server if active; create a new remote as fallback (e.g. KPI played as operation)
						var server: Server = ctx.get_server(ctx.run_target_server)
						if server == null:
							server = ctx.create_remote_server()
						if server != null:
							var installed := InstalledCard.make_runtime_instance(record, server.server_id, "ice", false)
							server.install_ice(installed)
							ctx.send_log("%s installs %s from %s on %s (ignoring costs)." % [ctx.corp_name(),
								record.title,
								"Archives" if (chosen_entry as Dictionary).get("_from_archives", false) else "HQ",
								server.display_name()
							])

		"trash_runner_installed":
			# Trash one of the runner\'s installed cards matching given types.
			# Also scans programs hosted on ice (trojans like Chromatophores, Botulus).
			var card_types: Array      = params.get("card_types", ["resource"]) as Array
			var subtypes: Array        = params.get("subtypes", []) as Array
			var exclude_subtypes: Array = params.get("exclude_subtypes", []) as Array
			var pool: Array = ctx.runner_rig.filter(func(c: InstalledCard):
				if c.card_record == null:
					return false
				var type_match := card_types.is_empty() or card_types.has(c.card_record.card_type)
				var sub_match  := subtypes.is_empty()
				if not sub_match:
					for st in subtypes:
						if c.card_record.has_subtype(st):
							sub_match = true
							break
				var excl_match := true
				if not exclude_subtypes.is_empty():
					for est in exclude_subtypes:
						if c.card_record.has_subtype(est):
							excl_match = false
							break
				return type_match and sub_match and excl_match
			)
			# Also include programs hosted on ice (e.g. Chromatophores as a trojan on ice)
			for tri_server in ctx.servers.values():
				for tri_ice in (tri_server as Server).ice:
					for tri_hosted in (tri_ice as InstalledCard).hosted_cards:
						var tri_h: InstalledCard = tri_hosted as InstalledCard
						if tri_h == null or tri_h.card_record == null:
							continue
						var tri_type_match := card_types.is_empty() or card_types.has(tri_h.card_record.card_type)
						var tri_sub_match  := subtypes.is_empty()
						if not tri_sub_match:
							for st in subtypes:
								if tri_h.card_record.has_subtype(st):
									tri_sub_match = true
									break
						var tri_excl_match := true
						if not exclude_subtypes.is_empty():
							for est in exclude_subtypes:
								if tri_h.card_record.has_subtype(est):
									tri_excl_match = false
									break
						if tri_type_match and tri_sub_match and tri_excl_match and not pool.has(tri_h):
							pool.append(tri_h)
			if pool.is_empty():
				ctx.send_log("No valid %s cards to trash." % ctx.runner_name())
			else:
				var dm: Object = ctx.corp_decision_maker
				var target: InstalledCard = null
				if dm != null and dm.has_method("choose_target"):
					target = await dm.choose_target(pool, {"reason": "trash_runner_installed"})
				else:
					target = pool[0] as InstalledCard
				if target != null:
					# ── Trash interrupt (e.g. Manuel Lattes de Moura Threat 3 protection) ──
					var tri_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry \
						if ctx.has_meta("ability_registry") else null
					var tri_def: Dictionary = tri_ab_reg._abilities.get(target.card_id, {}) \
						as Dictionary if tri_ab_reg != null else {}
					var tri_interrupt: Dictionary = tri_def.get("trash_interrupt", {}) as Dictionary
					if not tri_interrupt.is_empty():
						# Check optional condition (e.g. threat_gte)
						var tri_cond: Dictionary = tri_interrupt.get("condition", {}) as Dictionary
						var tri_cond_met := true
						if not tri_cond.is_empty():
							tri_cond_met = _evaluate_condition(tri_cond, ctx)
						if tri_cond_met:
							# Execute interrupt effects — if they set run_modifiers["trash_cancelled"] the trash fails
							ctx.run_modifiers.erase("trash_cancelled")
							await execute_trigger(tri_interrupt as Dictionary, ctx)
							if ctx.run_modifiers.get("trash_cancelled", false):
								ctx.run_modifiers.erase("trash_cancelled")
								ctx.send_log("%s's trash is blocked by its interrupt effect." % target.display_name())
								return  # abort the trash
					if target.hosted_on_id != "":
						# Hosted trojan — remove from host ice and clean up granted subtypes
						_cleanup_granted_subtypes(target, ctx)
						var tri_host := ctx.get_ice_by_instance_id(target.hosted_on_id)
						if tri_host != null:
							tri_host.hosted_cards.erase(target)
					else:
						ctx.runner_rig.erase(target)
					if target.card_record != null:
						ctx.runner_discard.append(target.card_record)
					ctx.unregister_all_card_effects(target.runtime_instance_id)
					ctx.send_log("%s trashes %s's %s." % [ctx.corp_name(), ctx.runner_name(), target.display_name()])
					# VP17 Hiram: fire hardware_trashed for Corp-caused hardware trashes too
					if target.card_record != null and target.card_record.card_type == "hardware":
						await ctx.notify_event("hardware_trashed", {
							"card_id": target.card_id, "source": "corp"
						}, self)

		"rfg_runner_heap_card":
			# Corp removes 1 card from the Runner's discard (heap) from the game.
			# Corp may choose any card; AI picks the first (and thus highest-impact) entry.
			if ctx.runner_discard.is_empty():
				ctx.send_log("Runner's heap is empty — nothing to remove from game.")
				return
			var rfg_target: CardRecord = null
			var rfg_dm: Object = ctx.corp_decision_maker
			if rfg_dm != null and rfg_dm.has_method("choose_card_from_discard"):
				rfg_target = await rfg_dm.choose_card_from_discard(ctx.runner_discard, ctx)
			if rfg_target == null:
				rfg_target = ctx.runner_discard[0] as CardRecord
			if rfg_target == null:
				return
			ctx.runner_discard.erase(rfg_target)
			ctx.runner_rfg.append(rfg_target)
			ctx.send_log("%s removes %s from the game (from Runner's heap)." % [
				ctx.corp_name(), rfg_target.title])

		"search_deck":
			# Search deck for cards matching a condition, let player choose one,
			# add it to hand, then shuffle the deck.
			var subject: String      = params.get("subject", "runner")
			var subtypes: Array      = params.get("subtypes", []) as Array
			var card_types: Array    = params.get("card_types", []) as Array
			var reveal: bool         = params.get("reveal", true)
			var deck: Array          = ctx.corp_deck if subject == "corp" else ctx.runner_deck
			var hand: Array          = ctx.corp_hand if subject == "corp" else ctx.runner_hand

			# Build candidate list from deck
			var candidates: Array = []
			for card_record in deck:
				var r: CardRecord = card_record as CardRecord
				if r == null:
					continue
				var type_match := card_types.is_empty() or card_types.has(r.card_type)
				var subtype_match := subtypes.is_empty()
				if not subtype_match:
					for st in subtypes:
						if r.has_subtype(st):
							subtype_match = true
							break
				if type_match and subtype_match:
					candidates.append(r)

			if candidates.is_empty():
				ctx.send_log("No matching cards found in deck.")
			else:
				var dm: Object = ctx.corp_decision_maker if subject == "corp" else ctx.runner_decision_maker
				var chosen: CardRecord = null
				if dm != null and dm.has_method("choose_from_search"):
					chosen = await dm.choose_from_search(candidates, ctx)
				else:
					chosen = candidates[0]

				if chosen != null:
					deck.erase(chosen)
					var chosen_hand_entry: Dictionary = {"card_id": chosen.id, "card_record": chosen}
					hand.append(chosen_hand_entry)
					if reveal:
						ctx.send_log("%s reveals and takes %s from their deck." % [ctx.player_name(subject), chosen.title])
					else:
						ctx.send_log("%s takes a card from their deck." % ctx.player_name(subject))
					# Shuffle the deck after searching
					deck.shuffle()
					ctx.send_log("%s's deck is shuffled." % ctx.player_name(subject))

					# Optional install after search (e.g. Mutual Favor: install if successful run this turn)
					var install_if_run: bool = params.get("install_if_successful_run", false)
					if install_if_run and subject == "runner" and ctx.runner_made_successful_run_this_turn:
						var do_install := false
						if ctx.runner_decision_maker != null and \
								ctx.runner_decision_maker.has_method("choose_optional_ability"):
							do_install = await ctx.runner_decision_maker.choose_optional_ability(
								"Install %s now?" % chosen.title, ctx)
						else:
							do_install = true  # AI: always install when able
						if do_install:
							# Check MU for programs
							if chosen.card_type == "program" and chosen.memory_cost > 0:
								if ctx.runner_mu_available() < chosen.memory_cost:
									ctx.send_log("Not enough MU to install %s." % chosen.title)
									do_install = false
							if do_install:
								# Pay install cost (reduced by any active discounts — use raw cost for now)
								var install_cost: int = max(0, chosen.cost)
								if ctx.runner_available_credits() < install_cost:
									ctx.send_log("Cannot afford to install %s (costs %d)." % [chosen.title, install_cost])
								else:
									ctx.runner_spend_credits(install_cost)
									hand.erase(chosen_hand_entry)
									var mf_installed := InstalledCard.make_runtime_instance(chosen, "runner_rig", "root", true)
									ctx.runner_rig.append(mf_installed)
									if ctx.has_meta("register_installed_card"):
										var mf_reg: Callable = ctx.get_meta("register_installed_card") as Callable
										mf_reg.call(mf_installed)
									if ctx.has_meta("ability_registry"):
										var mf_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
										var mf_on_rez = mf_ab_reg.get_on_rez(chosen.id)
										if mf_on_rez != null:
											ctx.current_event_data = {"card": mf_installed, "card_instance_id": mf_installed.runtime_instance_id}
											await execute_trigger(mf_on_rez as Dictionary, ctx)
											ctx.current_event_data = {}
									if chosen.card_type == "program" and chosen.has_subtype("virus"):
										await ctx.notify_event("runner_installs_virus", {
											"card": mf_installed,
											"card_instance_id": mf_installed.runtime_instance_id
										}, self)
									await ctx.notify_event("runner_installs_card", {
										"credits_paid": install_cost,
										"card": mf_installed,
										"card_instance_id": mf_installed.runtime_instance_id
									}, self)
									ctx.send_log("%s installs %s for %d cr. [MU: %d/%d]" % [
										ctx.runner_name(), chosen.title, install_cost,
										ctx.runner_mu_used(), ctx.runner_total_mu()
									])

		"choose_and_return_to_deck":
			# Ask the active player to choose a card from their hand to shuffle back.
			var subject: String = params.get("subject", "corp")
			var hand: Array = ctx.corp_hand if subject == "corp" else ctx.runner_hand
			var deck: Array = ctx.corp_deck if subject == "corp" else ctx.runner_deck
			if hand.is_empty():
				ctx.send_log("No cards in hand to return to deck.")
			else:
				var dm: Object = ctx.corp_decision_maker if subject == "corp" else ctx.runner_decision_maker
				var chosen_entry: Variant = null
				if dm != null and dm.has_method("choose_card_from_hand"):
					chosen_entry = await dm.choose_card_from_hand(hand, ctx)
				else:
					chosen_entry = hand[0]
				if chosen_entry != null:
					hand.erase(chosen_entry)
					var insert_pos: int = randi() % (deck.size() + 1)
					deck.insert(insert_pos, (chosen_entry as Dictionary).get("card_record", null))
					var r: CardRecord = (chosen_entry as Dictionary).get("card_record", null)
					ctx.send_log("%s shuffles %s back into their deck." % [
						ctx.player_name(subject),
						r.title if r else "a card"
					])

		"set_run_modifier":
			# Set a key in ctx.run_modifiers for the duration of the current run.
			var key: String = params.get("key", "")
			var value: int  = int(params.get("value", 0))
			if key != "":
				ctx.run_modifiers[key] = value
				ctx.send_log("Run modifier set: %s = %d" % [key, value])

		"run_with_breach_redirect":
			# Beatriz Friere Gonzalez / Eru Ayase-Pessoa (TAI):
			# Ask the runner to choose a server, run it, and if successful redirect the breach.
			# The redirect is registered as a one-shot successful_run listener so it fires
			# inside the run (before the breach phase) rather than after rsm.execute() returns.
			# params:
			#   servers:        Array  — allowed servers (same syntax as choose_and_run)
			#   redirect_to:    String — server id to redirect breach to ("rd", "archives", etc.)
			#   extra_accesses: int    — bonus accesses on the redirected breach (default 1)
			var rwbr_servers: Array  = params.get("servers", ["hq", "rd", "archives"]) as Array
			var rwbr_redir: String   = params.get("redirect_to", "rd")
			var rwbr_extra: int      = params.get("extra_accesses", 1)

			# Expand "remote" placeholder to live remote server IDs.
			var rwbr_expanded: Array = []
			for rwbr_srv in rwbr_servers:
				if rwbr_srv == "remote":
					for rwbr_remote in ctx.get_remote_servers():
						rwbr_expanded.append((rwbr_remote as Server).server_id)
				else:
					rwbr_expanded.append(rwbr_srv)
			if not rwbr_expanded.is_empty():
				rwbr_servers = rwbr_expanded
			if rwbr_servers.is_empty():
				push_error("run_with_breach_redirect: no valid servers")
				return

			# Runner chooses the run target.
			var rwbr_chosen: String = rwbr_servers[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				rwbr_chosen = await ctx.runner_decision_maker.choose_server(rwbr_servers, ctx)
			ctx.set_meta("chosen_run_server", rwbr_chosen)

			# Register a one-shot successful_run listener that sets the redirect fields.
			# Uses a unique listener ID so cleanup is precise.
			var rwbr_lid := "breach_redir_%s" % str(randi())
			ctx.register_listener("successful_run", rwbr_lid, {
				"effects": [
					{
						"type": "set_breach_redirect",
						"params": {"server": rwbr_redir, "extra_accesses": rwbr_extra}
					}
				]
			})

			# Execute the run.
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				(ctx.get_meta("on_run_started") as Callable).call(rwbr_chosen)
				await Engine.get_main_loop().process_frame
			var rwbr_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if rwbr_rsm == null:
				push_error("run_with_breach_redirect: no run_state_machine on ctx")
				ctx.unregister_all_card_effects(rwbr_lid)
				return
			await rwbr_rsm.execute(rwbr_chosen)

			# Clean up the listener regardless of run outcome.
			ctx.unregister_all_card_effects(rwbr_lid)

		"set_breach_redirect":
			# Beatriz Friere Gonzalez / Eru Ayase-Pessoa (TAI):
			# Redirect the current run's breach to a different server and grant +N extra accesses.
			# params:
			#   server: String — target server id for the breach (e.g. "rd", "archives")
			#   extra_accesses: int — additional cards accessed beyond base (default 1)
			# Must be used during a run (ctx.run_active must be true).
			if not ctx.run_active:
				push_error("set_breach_redirect called outside a run — ignored.")
				return
			var sbr_server: String = params.get("server", "")
			var sbr_extra: int     = params.get("extra_accesses", 1)
			if sbr_server == "" or not ctx.servers.has(sbr_server):
				push_error("set_breach_redirect: invalid server '%s'" % sbr_server)
				return
			ctx.run_breach_redirect     = sbr_server
			ctx.run_breach_extra_accesses += sbr_extra
			ctx.send_log("[Breach Redirect] Breach will target %s with +%d access." % [sbr_server, sbr_extra])

		"initiate_run":
			# Start a run as part of playing an event.
			var server_id: String = params.get("server_id", "")
			if server_id == "" and ctx.has_meta("chosen_run_server"):
				server_id = ctx.get_meta("chosen_run_server")
			if server_id == "" or not ctx.servers.has(server_id):
				push_error("AbilityInterpreter: initiate_run has no valid server")
				return
			# Mark that a run event is active (used by Sang Kancil cost reduction, etc.)
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var cb: Callable = ctx.get_meta("on_run_started") as Callable
				cb.call(server_id)
				await Engine.get_main_loop().process_frame
			var rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if rsm == null:
				push_error("AbilityInterpreter: initiate_run — no run_state_machine on ctx")
				return
			await rsm.execute(server_id)

		"choose_and_run":
			# Ask the runner to choose a server from a list, then run it.
			var allowed: Array = params.get("servers", ["hq", "rd", "archives"]) as Array
			# Expand "remote" placeholder to actual live remote server IDs.
			# abilities.json uses "remote" as shorthand; ctx only knows "remote_0" etc.
			var expanded: Array = []
			for srv_entry in allowed:
				if srv_entry == "remote":
					for remote_srv in ctx.get_remote_servers():
						expanded.append((remote_srv as Server).server_id)
				else:
					expanded.append(srv_entry)
			if not expanded.is_empty():
				allowed = expanded
			if allowed.is_empty():
				push_error("AbilityInterpreter: choose_and_run — no valid servers available")
				return
			var chosen: String = allowed[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				chosen = await ctx.runner_decision_maker.choose_server(allowed, ctx)
			ctx.set_meta("chosen_run_server", chosen)
			# Mark that a run event is active (used by Sang Kancil cost reduction, etc.)
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var cb: Callable = ctx.get_meta("on_run_started") as Callable
				cb.call(chosen)
				await Engine.get_main_loop().process_frame
			var rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if rsm == null:
				push_error("AbilityInterpreter: choose_and_run — no run_state_machine on ctx")
				return
			await rsm.execute(chosen)

		"run_s_dobrado_central":
			# S-Dobrado (TAI): run a central server with encounter-bypass abilities.
			# The first rezzed ice encountered is bypassed automatically.
			# At Threat 4, the second rezzed ice encountered may be bypassed for [click].
			# RSM reads ctx.run_modifiers["s_dobrado_active"] in _phase_encounter_ice.
			var _sdb_centrals: Array = ["hq", "rd", "archives"]
			var _sdb_chosen: String = _sdb_centrals[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				_sdb_chosen = await ctx.runner_decision_maker.choose_server(_sdb_centrals, ctx)
			ctx.set_meta("chosen_run_server", _sdb_chosen)
			ctx.run_modifiers["s_dobrado_active"] = true
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var _sdb_cb: Callable = ctx.get_meta("on_run_started") as Callable
				_sdb_cb.call(_sdb_chosen)
				await Engine.get_main_loop().process_frame
			var _sdb_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if _sdb_rsm == null:
				push_error("AbilityInterpreter: run_s_dobrado_central — no run_state_machine on ctx")
				return
			ctx.send_log("S-Dobrado: %s runs %s." % [ctx.runner_name(), _sdb_chosen.to_upper()])
			await _sdb_rsm.execute(_sdb_chosen)

		"run_central_if_unrun":
			# Red Team: spend a click to run a central not yet run this turn.
			# If successful, take payout_amount credits from this card's hosted pool.
			var payout_counter: String = params.get("payout_counter", "credits")
			var payout_amount: int     = params.get("payout_amount", 3)

			# Build list of eligible centrals (not yet run this turn, has credits)
			var self_card := _get_self_card(ctx)
			if self_card == null or self_card.get_counter(payout_counter) <= 0:
				ctx.send_log("Red Team: no credits remaining — cannot use.")
				return

			var all_centrals: Array = ["hq", "rd", "archives"]
			var eligible: Array = []
			for srv in all_centrals:
				if srv not in ctx.runner_centrals_run_this_turn:
					eligible.append(srv)

			if eligible.is_empty():
				ctx.send_log("Red Team: all central servers already run this turn.")
				return

			# Ask runner to choose which central to run
			var chosen: String = eligible[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				chosen = await ctx.runner_decision_maker.choose_server(eligible, ctx)

			ctx.send_log("Red Team: %s runs %s." % [ctx.runner_name(), chosen.to_upper()])

			# Register a one-shot successful_run hook to pay out before breach
			ctx.set_meta("red_team_pending_payout", {
				"card_instance_id": self_card.runtime_instance_id,
				"counter": payout_counter,
				"amount": payout_amount,
				"server_id": chosen
			})

			# Initiate the run
			if ctx.has_meta("on_run_started"):
				var cb: Callable = ctx.get_meta("on_run_started") as Callable
				cb.call(chosen)
				await Engine.get_main_loop().process_frame
			var rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if rsm == null:
				push_error("AbilityInterpreter: run_central_if_unrun — no run_state_machine on ctx")
				ctx.remove_meta("red_team_pending_payout")
				return
			await rsm.execute(chosen)

			# Record that this central was run
			if chosen not in ctx.runner_centrals_run_this_turn:
				ctx.runner_centrals_run_this_turn.append(chosen)
			ctx.remove_meta_if_exists("red_team_pending_payout")

		"rez_card_free":
			# Rez an installed card ignoring its rez cost.
			# Prompts the active player to choose which card to rez.
			var target_zone: String = params.get("target_zone", "ice")
			var candidates: Array   = []
			for server in ctx.servers.values():
				var s: Server = server as Server
				var zone_cards: Array = s.ice if target_zone == "ice" else s.root
				for card in zone_cards:
					var c: InstalledCard = card as InstalledCard
					if not c.is_rezzed:
						candidates.append(c)
			if candidates.is_empty():
				ctx.send_log("No unrezzed %s to rez for free." % target_zone)
			else:
				var dm: Object = ctx.corp_decision_maker if ctx.active_player == "corp" else ctx.runner_decision_maker
				var target: InstalledCard = null
				if dm != null and dm.has_method("choose_target"):
					target = await dm.choose_target(candidates, {"reason": "rez_free"})
				else:
					target = candidates[0]
				if target != null:
					target.is_rezzed = true
					if target.runtime_instance_id != "":
						ctx.ice_rezzed_this_turn_instance_ids.append(target.runtime_instance_id)
					ctx.send_log("Rezzed %s for free." % target.display_name())

		"increase_hand_size":
			var subject: String = params.get("subject", "corp")
			var amount: int     = params.get("amount", 1)
			if subject == "corp":
				ctx.corp_hand_size_bonus += amount
				ctx.send_log("%s max hand size increased to %d." % [ctx.corp_name(), ctx.corp_max_hand_size()])
			else:
				ctx.runner_hand_size_bonus += amount
				ctx.send_log("%s max hand size increased to %d." % [ctx.runner_name(), ctx.runner_max_hand_size()])

		"add_self_counter_if_server":
			# Add a counter to self only if the run is on a specific server.
			# "central" is a special value matching hq, rd, or archives.
			var required_server: String = params.get("server", "rd")
			var counter_type: String    = effect.get("counter", params.get("counter", "virus"))
			var amount: int             = int(effect.get("amount", params.get("amount", 1)))
			var actual_server: String   = ctx.current_event_data.get("server_id", "")
			var server_matches: bool
			if required_server == "central":
				server_matches = actual_server in ["hq", "rd", "archives"]
			else:
				server_matches = (actual_server == required_server)
			if server_matches:
				var self_card := _get_self_card(ctx)
				if self_card != null:
					self_card.add_counter(counter_type, amount)
					ctx.send_log("Placed %d %s counter(s) on %s (%d total)." % [
						amount, counter_type, self_card.display_name(),
						self_card.get_counter(counter_type)
					])

		"set_bonus_access_from_counters":
			# Set run_modifiers["bonus_access"] to the card's current counter count.
			# Only fires if the current run is on the required server (if specified).
			var required_server: String = params.get("server", "")
			if required_server != "":
				var actual_server: String = ctx.current_event_data.get("server_id", "")
				if actual_server != required_server:
					return  # wrong server — do nothing
			var counter_type: String = effect.get("counter", params.get("counter", "virus"))
			var self_card := _get_self_card(ctx)
			if self_card != null:
				var count: int = self_card.get_counter(counter_type)
				ctx.run_modifiers["bonus_access"] = count
				if count > 0:
					ctx.send_log("%s: +%d R&D access from virus counters." % [self_card.display_name(), count])

		"transfer_hosted_credits":
			# Move credits from a hosted card counter to the runner's pool.
			# Used by Leech to spend hosted credits during encounters.
			var amount: int         = int(effect.get("amount", params.get("amount", 1)))
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var self_card := _get_self_card(ctx)
			if self_card != null:
				var available: int = self_card.get_counter(counter_type)
				var taken: int     = min(amount, available)
				if taken > 0:
					self_card.remove_counter(counter_type, taken)
					ctx.runner_credits += taken
					ctx.send_log("%s takes %d cr from %s (%d remaining)." % [ctx.runner_name(),
						taken, self_card.display_name(), self_card.get_counter(counter_type)
					])

		"add_self_counters":
			# Add counters to the card that owns this ability.
			# The owning card's instance_id is in ctx.current_event_data.
			# Note: JSON stores "counter" and "amount" at effect top level, not under "params"
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int          = int(effect.get("amount", params.get("amount", 0)))
			var asc_iid: String      = ctx.current_event_data.get("card_instance_id", "")
			# Identity cards are bare CardRecords — use the identity counter dictionaries.
			if asc_iid == "identity_corp":
				ctx.corp_identity_counters[counter_type] = \
					ctx.corp_identity_counters.get(counter_type, 0) + amount
				ctx.send_log("Placed %d %s counter(s) on %s." % [amount, counter_type, ctx.corp_name()])
			elif asc_iid == "identity_runner":
				ctx.runner_identity_counters[counter_type] = \
					ctx.runner_identity_counters.get(counter_type, 0) + amount
				ctx.send_log("Placed %d %s counter(s) on %s." % [amount, counter_type, ctx.runner_name()])
			else:
				var self_card := _get_self_card(ctx)
				if self_card != null:
					self_card.add_counter(counter_type, amount)
					ctx.send_log("Placed %d %s counter(s) on %s." % [amount, counter_type, self_card.display_name()])
				else:
					push_error("AbilityInterpreter: add_self_counters could not find self card in event data")

		"take_hosted_credits":
			# Move credits from the card's hosted counter to a player's credit pool.
			var subject: String  = effect.get("subject", params.get("subject", "corp"))
			var amount: int      = int(effect.get("amount", params.get("amount", 0)))
			var self_card := _get_self_card(ctx)
			if self_card != null:
				var available: int = self_card.get_counter("credits")
				var taken: int     = min(amount, available)
				if taken > 0:
					self_card.remove_counter("credits", taken)
					ctx.set_credits(subject, ctx.get_credits(subject) + taken)
					ctx.send_log("%s takes %d cr from %s (%d remaining)." % [
						ctx.player_name(subject), taken, self_card.display_name(),
						self_card.get_counter("credits")
					])
					# The Zwicky Group: Corp taking credits from an agenda/operation ability.
					if subject == "corp" and \
							ctx.current_ability_source_card_type in ["operation", "agenda"]:
						await ctx.notify_event("corp_gains_credits_via_ability", {"amount": taken}, self)

		"take_hosted_credits_amount":
			# Click action: take a fixed amount of hosted credits (Regolith, Telework).
			# Respects available credits — takes up to amount or what's available.
			var subject: String     = effect.get("subject", params.get("subject", "runner"))
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int         = int(effect.get("amount", params.get("amount", 3)))
			var self_card := _get_self_card(ctx)
			if self_card == null:
				push_error("AbilityInterpreter: take_hosted_credits_amount — card not found")
			else:
				var available: int = self_card.get_counter(counter_type)
				if available <= 0:
					ctx.send_log("%s is empty." % self_card.display_name())
				else:
					var taken: int = min(amount, available)
					self_card.remove_counter(counter_type, taken)
					ctx.set_credits(subject, ctx.get_credits(subject) + taken)
					ctx.send_log("%s takes %d cr from %s (%d remaining)." % [
						ctx.player_name(subject), taken, self_card.display_name(),
						self_card.get_counter(counter_type)
					])

		"take_all_hosted_credits":
			# Click action: take ALL hosted credits (Smartware Distributor, Pennyshaver).
			var subject: String     = effect.get("subject", params.get("subject", "runner"))
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var self_card := _get_self_card(ctx)
			if self_card == null:
				push_error("AbilityInterpreter: take_all_hosted_credits — card not found")
			else:
				var available: int = self_card.get_counter(counter_type)
				if available <= 0:
					ctx.send_log("%s has no credits to take." % self_card.display_name())
				else:
					self_card.remove_counter(counter_type, available)
					ctx.set_credits(subject, ctx.get_credits(subject) + available)
					ctx.send_log("%s takes all %d cr from %s." % [
						ctx.player_name(subject), available, self_card.display_name()
					])

		"remove_self_counter":
			# Remove one counter of a type from the owning card.
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int          = int(effect.get("amount", params.get("amount", 1)))
			var self_card := _get_self_card(ctx)
			if self_card != null:
				self_card.remove_counter(counter_type, amount)

		"self_trash_if_empty":
			# Trash the owning card if a given counter reaches zero.
			# Optional: on_trash_gain_clicks — { subject: "corp"|"runner", amount: int }
			# grants clicks to the specified player when the card self-trashes (e.g. Otto Campaign).
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var self_card := _get_self_card(ctx)
			if self_card != null and self_card.get_counter(counter_type) <= 0:
				# Remove from server
				var server: Server = ctx.get_server(self_card.server_id)
				if server:
					server.remove_from_root(self_card)
					ctx.remove_empty_remote_servers()
				# Also check runner rig
				ctx.runner_rig.erase(self_card)
				# Unregister all its listeners
				ctx.unregister_all_card_effects(self_card.runtime_instance_id)
				ctx.send_log("%s is trashed (empty)." % self_card.display_name())
				# VP17 Hiram: runner hardware self-trashing triggers look-at-R&D
				if self_card.card_record != null and self_card.card_record.card_type == "hardware":
					await ctx.notify_event("hardware_trashed", {
						"card_id": self_card.card_id, "source": "runner"
					}, self)
				# Grant bonus clicks on self-trash (e.g. Otto Campaign: Corp gains 2 clicks)
				var otgc = effect.get("on_trash_gain_clicks", null)
				if otgc != null:
					var otgc_subject: String = (otgc as Dictionary).get("subject", "corp")
					var otgc_amount: int     = (otgc as Dictionary).get("amount", 0)
					if otgc_subject == "corp":
						ctx.corp_clicks += otgc_amount
						ctx.send_log("%s gains %d click(s) (%s trashed)." % [ctx.corp_name(), otgc_amount, self_card.display_name()])
					else:
						ctx.runner_clicks += otgc_amount
						ctx.send_log("%s gains %d click(s) (%s trashed)." % [ctx.runner_name(), otgc_amount, self_card.display_name()])

		"self_trash_if_empty_and_draw":
			# Trash the owning card if empty, and draw 1 card for the Corp (Nico Campaign).
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var self_card := _get_self_card(ctx)
			if self_card != null and self_card.get_counter(counter_type) <= 0:
				var server: Server = ctx.get_server(self_card.server_id)
				if server:
					server.remove_from_root(self_card)
					ctx.remove_empty_remote_servers()
				ctx.runner_rig.erase(self_card)
				ctx.unregister_all_card_effects(self_card.runtime_instance_id)
				ctx.send_log("%s is trashed (empty)." % self_card.display_name())
				# VP17 Hiram: runner hardware self-trashing triggers look-at-R&D
				if self_card.card_record != null and self_card.card_record.card_type == "hardware":
					await ctx.notify_event("hardware_trashed", {
						"card_id": self_card.card_id, "source": "runner"
					}, self)
				# Draw 1 card for the Corp
				if not ctx.corp_deck.is_empty():
					var drawn: CardRecord = ctx.corp_deck.pop_front() as CardRecord
					ctx.corp_hand.append({"card_id": drawn.id, "card_record": drawn})
					ctx.send_log("%s draws %s (Nico Campaign)." % [ctx.corp_name(), drawn.title])
				else:
					ctx.send_log("%s deck is empty — cannot draw from Nico Campaign." % ctx.corp_name())

		"lose_clicks_next_turn":
			var subject: String = params.get("subject", "runner")
			var amount: int     = params.get("amount", 1)
			var current: int    = ctx.pending_click_penalties.get(subject, 0)
			ctx.pending_click_penalties[subject] = current + amount
			ctx.send_log("%s will lose %d click(s) next turn." % [ctx.player_name(subject), amount])

		"add_counters_to_target":
			var counter_type: String = params.get("counter_type", "advancement")
			var amount: int          = params.get("amount", 1)
			if chosen_target != null and chosen_target is InstalledCard:
				(chosen_target as InstalledCard).add_counter(counter_type, amount)
				ctx.send_log("Placed %d %s counter(s) on %s." % [
					amount, counter_type,
					(chosen_target as InstalledCard).display_name()
				])
			else:
				push_error("AbilityInterpreter: add_counters_to_target has no valid target")

		"trash_card":
			var target_ref: String = params.get("target", "chosen")
			if target_ref == "chosen" and chosen_target != null:
				_trash_installed_card(chosen_target as InstalledCard, ctx)
			else:
				push_error("AbilityInterpreter: trash_card has no valid target")

		"install_from_grip_optional":
			# Pantograph: runner may install a card from grip paying its install cost.
			if ctx.runner_hand.is_empty():
				ctx.send_log("Pantograph: no cards in grip to install.")
				return
			var dm: Object = ctx.runner_decision_maker
			if dm == null:
				return
			var chosen: CardRecord = null
			if dm.has_method("choose_card_from_hand"):
				var entry: Variant = await dm.choose_card_from_hand(ctx.runner_hand, ctx)
				if entry != null:
					chosen = (entry as Dictionary).get("card_record", null) as CardRecord
			if chosen == null:
				ctx.send_log("Pantograph: runner declines to install.")
				return
			var cost: int = max(0, chosen.cost)
			if ctx.runner_credits < cost:
				ctx.send_log("Pantograph: cannot afford to install %s." % chosen.title)
				return
			ctx.runner_credits -= cost
			var installed := InstalledCard.make_runtime_instance(chosen, "runner_rig", "root", true)
			ctx.runner_rig.append(installed)
			for i in range(ctx.runner_hand.size()):
				var e: Dictionary = ctx.runner_hand[i] as Dictionary
				if e.get("card_record", null) == chosen:
					ctx.runner_hand.remove_at(i)
					break
			if ctx.has_meta("ability_registry"):
				var ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var on_rez_def = ab_reg.get_on_rez(chosen.id)
				if on_rez_def != null:
					ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
					await execute_trigger(on_rez_def as Dictionary, ctx)
					ctx.current_event_data = {}
			ctx.send_log("Pantograph: %s installs %s for %d cr." % [ctx.runner_name(), chosen.title, cost])

		"install_from_grip_free":
			# Pantograph: install a card from grip ignoring install cost.
			var installable: Array = []
			for entry in ctx.runner_hand:
				var e: Dictionary = entry as Dictionary
				var r: CardRecord = e.get("card_record", null) as CardRecord
				if r == null:
					continue
				if r.card_type in ["program", "hardware", "resource"]:
					installable.append(entry)

			if installable.is_empty():
				ctx.send_log("Pantograph: no installable cards in grip.")
				return

			var chosen_entry: Variant = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_hand"):
				chosen_entry = await ctx.runner_decision_maker.choose_card_from_hand(installable, ctx)

			if chosen_entry == null:
				ctx.send_log("Pantograph: no card chosen.")
				return

			var record: CardRecord = (chosen_entry as Dictionary).get("card_record", null) as CardRecord
			if record == null:
				return

			# MU check for programs
			if record.card_type == "program" and record.memory_cost > 0:
				if ctx.runner_mu_available() < record.memory_cost:
					ctx.send_log("Pantograph: not enough MU to install %s." % record.title)
					return

			# Remove from hand and install
			ctx.runner_hand.erase(chosen_entry)
			var installed := InstalledCard.make_runtime_instance(record, "runner_rig", "root", true)
			ctx.runner_rig.append(installed)

			# Register event listeners via TurnManager callback
			if ctx.has_meta("register_installed_card"):
				var reg: Callable = ctx.get_meta("register_installed_card") as Callable
				reg.call(installed)

			# Fire on_rez if defined
			if ctx.has_meta("ability_registry"):
				var reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var on_rez_def = reg.get_on_rez(record.id)
				if on_rez_def != null:
					ctx.current_event_data = {"card": installed, "card_instance_id": installed.runtime_instance_id}
					await execute_trigger(on_rez_def as Dictionary, ctx)
					ctx.current_event_data = {}

			ctx.send_log("Pantograph: %s installs %s for free. [MU: %d/%d]" % [
				ctx.runner_name(), record.title,
				ctx.runner_mu_used(), ctx.runner_total_mu()
			])

		"give_tags":
			# Give the runner N tags, then fire runner_takes_tags so identity abilities
			# like NBN: Reality Plus can react.
			var amount: int = _resolve_amount(params.get("amount", 1), ctx)
			if amount <= 0:
				return
			var _gt_was_zero: bool = (ctx.runner_tags == 0)
			ctx.runner_tags += amount
			ctx.send_log("%s takes %d tag(s). (%d total)" % [ctx.runner_name(), amount, ctx.runner_tags])
			await ctx.notify_event("runner_takes_tags", {"amount": amount, "from_zero": _gt_was_zero}, self)

		"give_bad_pub":
			# Corp takes N bad publicity.
			# params: { amount: int }
			var gbp_amount: int = params.get("amount", 1)
			ctx.corp_bad_pub += gbp_amount
			ctx.send_log("%s takes %d bad publicity. (%d total)" % [
				ctx.corp_name(), gbp_amount, ctx.corp_bad_pub])
			# VP46 Ad Nihilum: notify all listeners that Corp gained bad pub
			await ctx.notify_event("corp_gains_bad_pub", {"amount": gbp_amount}, self)

		"clearinghouse_activate":
			# Clearinghouse: At turn start, Corp may add 1 advancement counter,
			# then deal 1 meat per counter and trash itself. Activation is optional.
			var self_card := _get_self_card(ctx)
			if self_card == null:
				return

			# AI decision: activate if runner is close to winning or has many counters
			# (threat grows each turn — AI should activate when it will be lethal or near-lethal)
			var current_counters: int = self_card.get_counter("advancement")
			var damage_if_activate: int = current_counters + 1   # +1 for the counter we're adding
			var runner_grip: int = ctx.runner_hand.size()

			var should_activate := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_activate_clearinghouse"):
				should_activate = await ctx.corp_decision_maker.choose_activate_clearinghouse(self_card, ctx)
			else:
				# Default AI: activate if it would flatline (or near-flatline) the runner
				should_activate = damage_if_activate >= runner_grip

			if not should_activate:
				ctx.send_log("Clearinghouse: Corp holds. (%d counters, would deal %d meat)" % [
					current_counters, damage_if_activate
				])
				return

			# Activate: add 1 counter first
			self_card.add_counter("advancement", 1)
			var total_damage: int = self_card.get_counter("advancement")
			ctx.send_log("Clearinghouse fires! Deals %d meat damage." % total_damage)

			# Deal meat damage
			await _deal_damage("meat", total_damage, ctx)

			# Trash Clearinghouse (mandatory after activating)
			var server: Server = ctx.get_server(self_card.server_id)
			if server:
				server.remove_from_root(self_card)
				ctx.remove_empty_remote_servers()
			ctx.unregister_all_card_effects(self_card.runtime_instance_id)
			if self_card.card_record != null:
				ctx.corp_discard.append(self_card.card_record)
			ctx.send_log("Clearinghouse is trashed.")
			# Tranquilizer: derez the ice this program is hosted on.
			# Fires at the start of the Corp's turn while installed.
			if self_card != null and self_card.hosted_on_id != "":
				var host_ice := ctx.get_ice_by_instance_id(self_card.hosted_on_id)
				if host_ice != null and host_ice.is_rezzed:
					host_ice.is_rezzed = false
					ctx.send_log("Tranquilizer: %s is derezzed." % host_ice.display_name())
					await ctx.notify_event("on_derez", {
						"card": host_ice,
						"card_instance_id": self_card.runtime_instance_id
					}, self)
				elif host_ice != null:
					ctx.send_log("Tranquilizer: %s is already unrezzed." % host_ice.display_name())

		"gain_credits_per_counter":
			# Fermenter: gain 2cr for each hosted virus counter, then card trashes itself.
			var counter_type: String = effect.get("counter", "virus")
			var credits_per: int     = int(effect.get("credits_per", params.get("credits_per", 2)))
			var self_card := _get_self_card(ctx)
			if self_card != null:
				var count: int    = self_card.get_counter(counter_type)
				var gained: int   = count * credits_per
				ctx.runner_credits += gained
				ctx.send_log("Fermenter: %s gains %d cr (%d counters × %d cr)." % [
					ctx.runner_name(), gained, count, credits_per
				])
			else:
				push_error("AbilityInterpreter: gain_credits_per_counter — card not found")

		"deal_damage_per_self_counter":
			# Deal N damage where N = this card's own counter of the specified type.
			# Used by Phat Gioan Baotixita: first-agenda trigger deals net damage
			# equal to accumulated power counters.
			var ddpc_counter: String = params.get("counter", "power")
			var ddpc_dtype:   String = params.get("damage_type", "net")
			var ddpc_card := _get_self_card(ctx)
			if ddpc_card == null:
				push_error("AbilityInterpreter: deal_damage_per_self_counter — card not found")
				return
			var ddpc_count: int = ddpc_card.get_counter(ddpc_counter)
			if ddpc_count <= 0:
				ctx.send_log("%s: no %s counters — no damage dealt." % [
					ddpc_card.display_name(), ddpc_counter
				])
				return
			ctx.send_log("%s: %d %s counter(s) — deals %d %s damage." % [
				ddpc_card.display_name(), ddpc_count, ddpc_counter, ddpc_count, ddpc_dtype
			])
			await _deal_damage(ddpc_dtype, ddpc_count, ctx)

		"add_counters_to_installed_virus":
			# Cookbook: when a virus program is installed, place 1 counter on it.
			# The newly installed card's instance_id is in event_data.
			var counter_type: String = effect.get("counter", "virus")
			var amount: int          = int(effect.get("amount", 1))
			# The newly-installed virus card is the event source
			var new_card_iid: String = ctx.current_event_data.get("card_instance_id", "")
			var new_card := ctx.get_installed_card_by_instance_id(new_card_iid)
			if new_card != null:
				new_card.add_counter(counter_type, amount)
				ctx.send_log("Cookbook: placed %d %s counter(s) on %s." % [
					amount, counter_type, new_card.display_name()
				])

		"gain_credits_first_trash_this_turn":
			# Loup: the first time each turn you trash during a breach, gain 2cr.
			if ctx.runner_trashed_during_breach_this_turn:
				return   # already fired this turn
			ctx.runner_trashed_during_breach_this_turn = true
			var amount: int = int(params.get("amount", 2))
			ctx.runner_credits += amount
			ctx.send_log("Loup: %s gains %d cr (first trash this turn)." % [ctx.runner_name(), amount])

		"may_swap_two_ice":
			# Tāo: after a successful run, may swap two ice on any single server.
			if ctx.runner_decision_maker == null:
				return

			# Build list of servers that have ≥2 ice
			var eligible_servers: Array = []
			for server in ctx.servers.values():
				var s: Server = server as Server
				if s.ice_count() >= 2:
					eligible_servers.append(s)

			if eligible_servers.is_empty():
				return   # No servers with 2+ ice — nothing to swap

			# Ask runner to choose a server and two ice positions (or decline)
			var swap_choice: Variant = null
			if ctx.runner_decision_maker.has_method("choose_ice_swap"):
				swap_choice = await ctx.runner_decision_maker.choose_ice_swap(eligible_servers, ctx)

			if swap_choice == null:
				return   # Runner declined

			# swap_choice is a Dictionary: {server: Server, pos_a: int, pos_b: int}
			var s: Server = (swap_choice as Dictionary).get("server", null) as Server
			var pos_a: int = (swap_choice as Dictionary).get("pos_a", 0)
			var pos_b: int = (swap_choice as Dictionary).get("pos_b", 1)

			if s == null or pos_a == pos_b:
				return
			if pos_a < 0 or pos_b < 0 or pos_a >= s.ice.size() or pos_b >= s.ice.size():
				return

			# Perform the swap
			var ice_a: InstalledCard = s.ice[pos_a] as InstalledCard
			var ice_b: InstalledCard = s.ice[pos_b] as InstalledCard
			s.ice[pos_a] = ice_b
			s.ice[pos_b] = ice_a
			ctx.send_log("Tāo: swaps %s (position %d) and %s (position %d) on %s." % [
				ice_a.display_name(), pos_a,
				ice_b.display_name(), pos_b,
				s.display_name()
			])
			# Anoetic Void: Corp may pay 2cr + trash 2 from HQ to end the breach.
			var breach_server: String = ctx.current_event_data.get("server_id", "")
			var av_iid: String        = ctx.current_event_data.get("card_instance_id", "")
			var av_card := ctx.get_installed_card_by_instance_id(av_iid)
			if av_card == null or av_card.server_id != breach_server or not av_card.is_rezzed:
				return
			var cost_cr: int    = int(params.get("cost_credits", 2))
			var cost_trash: int = int(params.get("cost_trash_hq", 2))
			if ctx.corp_credits < cost_cr or ctx.corp_hand.size() < cost_trash:
				return
			# Ask Corp decision maker
			var use_it := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_use_anoetic_void"):
				use_it = await ctx.corp_decision_maker.choose_use_anoetic_void(ctx)
			else:
				# AI default: use it when ahead on points or runner has few cards
				use_it = ctx.corp_credits >= cost_cr + 2
			if not use_it:
				return
			# Pay costs
			ctx.corp_credits -= cost_cr
			for i in range(cost_trash):
				if ctx.corp_hand.is_empty():
					break
				var discarded: Dictionary = ctx.corp_hand.pop_back() as Dictionary
				var record: CardRecord    = discarded.get("card_record", null) as CardRecord
				if record:
					ctx.corp_discard.append(record)
					ctx.corp_discard_facedown[record.title] = true
					ctx.send_log("Anoetic Void: Corp trashes %s from HQ." % record.title)
			# Cancel the breach
			ctx.run_modifiers["breach_cancelled"] = true
			ctx.send_log("Anoetic Void: %s pays %d cr and trashes %d — breach ended." % [ctx.corp_name(), cost_cr, cost_trash])

		# ── Pennyshaver / Red Team: counter effects gated on central server ───

		"add_self_counters_if_central":
			# Add counters to the owning card only if the run was on a central server.
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int          = int(effect.get("amount", params.get("amount", 1)))
			var server_id: String    = ctx.current_event_data.get("server_id", "")
			var server: Server       = ctx.get_server(server_id)
			if server != null and not server.is_remote():
				var self_card := _get_self_card(ctx)
				if self_card != null:
					self_card.add_counter(counter_type, amount)
					ctx.send_log("Placed %d %s counter(s) on %s (%s run)." % [
						amount, counter_type, self_card.display_name(), server_id
					])

		"take_hosted_credits_if_central":
			# Transfer hosted credits to runner's pool only on a central server run.
			var counter_type: String = effect.get("counter", params.get("counter", "credits"))
			var amount: int          = int(effect.get("amount", params.get("amount", 1)))
			var server_id: String    = ctx.current_event_data.get("server_id", "")
			var server: Server       = ctx.get_server(server_id)
			if server != null and not server.is_remote():
				var self_card := _get_self_card(ctx)
				if self_card != null:
					var available: int = self_card.get_counter(counter_type)
					var taken: int     = min(amount, available)
					if taken > 0:
						self_card.remove_counter(counter_type, taken)
						ctx.runner_credits += taken
						ctx.send_log("%s takes %d cr from %s (%d remaining)." % [ctx.runner_name(),
							taken, self_card.display_name(), self_card.get_counter(counter_type)
						])
					else:
						ctx.send_log("%s has no hosted credits to take." % self_card.display_name())

		# ── Docklands Pass: bonus access gated on server ──────────────────────

		"add_bonus_access_if_server":
			# Add to run_modifiers["bonus_access"] if run is on the specified server.
			# Only fires the FIRST TIME per turn that server is breached (Docklands Pass rule).
			var required_server: String = params.get("server", "hq")
			var amount: int             = params.get("amount", 1)
			var actual_server: String   = ctx.current_event_data.get("server_id", "")
			if actual_server == required_server:
				# Use a per-turn flag on ctx so it persists across runs but resets each turn
				var already_fired: bool = false
				if required_server == "hq":
					already_fired = ctx.runner_hq_breached_this_turn
				if not already_fired:
					if required_server == "hq":
						ctx.runner_hq_breached_this_turn = true
					var current: int = ctx.run_modifiers.get("bonus_access", 0)
					ctx.run_modifiers["bonus_access"] = current + amount
					ctx.send_log("Docklands Pass: +%d access on %s." % [amount, required_server.to_upper()])

		# ── Mayfly: self-trash when run ends if the breaker was used ──────────

		"self_trash_if_used_this_run":
			# Trash the owning card at run end. Mayfly always trashes when the run
			# ends if it was used — unconditional per card text.
			var self_card := _get_self_card(ctx)
			if self_card != null:
				ctx.runner_rig.erase(self_card)
				ctx.unregister_all_card_effects(self_card.runtime_instance_id)
				ctx.send_log("%s is trashed (end of run)." % self_card.display_name())
				# VP17 Hiram: runner hardware self-trashing triggers look-at-R&D
				if self_card.card_record != null and self_card.card_record.card_type == "hardware":
					await ctx.notify_event("hardware_trashed", {
						"card_id": self_card.card_id, "source": "runner"
					}, self)

		"self_trash":
			# Unconditionally trash the owning card (Tranquilizer, Fermenter, Spin Doctor, etc.)
			var self_card := _get_self_card(ctx)
			if self_card != null:
				if self_card.hosted_on_id != "":
					# Hosted on ice (e.g. Tranquilizer, Chromatophores)
					# Clean up any subtypes this program had granted to the host ice first
					_cleanup_granted_subtypes(self_card, ctx)
					var host_ice := ctx.get_ice_by_instance_id(self_card.hosted_on_id)
					if host_ice != null:
						host_ice.hosted_cards.erase(self_card)
					if self_card.card_record != null:
						ctx.runner_discard.append(self_card.card_record)
				else:
					# Check corp server roots first (e.g. Spin Doctor asset)
					var found_in_server := false
					for server in ctx.servers.values():
						var s: Server = server as Server
						if s.root.has(self_card):
							s.remove_from_root(self_card)
							ctx.remove_empty_remote_servers()
							found_in_server = true
							break
					if found_in_server:
						if self_card.card_record != null:
							ctx.corp_discard.append(self_card.card_record)
					else:
						# Check server ice arrays (e.g. Lamplighter ICE self-trashing)
						var found_as_ice := false
						for ice_server in ctx.servers.values():
							var si: Server = ice_server as Server
							if si.ice.has(self_card):
								si.remove_ice(self_card)
								found_as_ice = true
								break
						if found_as_ice:
							if self_card.card_record != null:
								ctx.corp_discard.append(self_card.card_record)
						else:
							# Runner rig card (e.g. Fermenter)
							ctx.runner_rig.erase(self_card)
							if self_card.card_record != null:
								ctx.runner_discard.append(self_card.card_record)
				ctx.unregister_all_card_effects(self_card.runtime_instance_id)
				ctx.send_log("%s is trashed." % self_card.display_name())
				# VP17 Hiram: runner hardware self-trashing triggers look-at-R&D
				if self_card.card_record != null and self_card.card_record.card_type == "hardware":
					await ctx.notify_event("hardware_trashed", {
						"card_id": self_card.card_id, "source": "runner"
					}, self)

		# ── Spin Doctor: shuffle cards from Archives into R&D ─────────────────

		"shuffle_archives_to_rd":
			var max_count: int = params.get("max_count", 2)
			if ctx.corp_discard.is_empty():
				ctx.send_log("Archives is empty — nothing to shuffle into R&D.")
			else:
				var dm: Object = ctx.corp_decision_maker
				var chosen: Array = []
				if dm != null and dm.has_method("choose_cards_from_archives"):
					chosen = await dm.choose_cards_from_archives(ctx.corp_discard, max_count, ctx)
				else:
					var count: int = min(max_count, ctx.corp_discard.size())
					for i in range(count):
						chosen.append(ctx.corp_discard[i])
				for card in chosen:
					ctx.corp_discard.erase(card)
					ctx.corp_deck.append(card)
				ctx.corp_deck.shuffle()
				ctx.send_log("Spin Doctor: shuffled %d card(s) from Archives into R&D." % chosen.size())

		# ── Malapert Data Vault: peek top of R&D; add to HQ if agenda/operation ──

		"malapert_top_rd_to_hq":
			if ctx.corp_deck.is_empty():
				ctx.send_log("Malapert Data Vault: R&D is empty.")
			else:
				var top_card: CardRecord = ctx.corp_deck[0] as CardRecord
				if top_card == null:
					pass
				elif top_card.card_type in ["agenda", "operation"]:
					# Corp always benefits from pulling an agenda or operation into hand.
					# Default AI: always accept. A human chooser method can override.
					var should_add := true
					if ctx.corp_decision_maker != null and \
							ctx.corp_decision_maker.has_method("choose_malapert_add_to_hq"):
						should_add = await ctx.corp_decision_maker.choose_malapert_add_to_hq(top_card, ctx)
					if should_add:
						ctx.corp_deck.pop_front()
						ctx.corp_hand.append({"card_id": top_card.id, "card_record": top_card})
						ctx.send_log("Malapert Data Vault: %s (%s) moved from top of R&D to HQ." % [
							top_card.title, top_card.card_type
						])
					else:
						ctx.send_log("Malapert Data Vault: Corp declines to add %s to HQ." % top_card.title)
				else:
					ctx.send_log("Malapert Data Vault: Top of R&D is %s (%s) — not an agenda or operation." % [
						top_card.title, top_card.card_type
					])

		# ── Precision Design: add 1 card from Archives to HQ ─────────────────

		"fetch_from_archives_to_hq":
			if ctx.corp_discard.is_empty():
				ctx.send_log("Archives is empty — Precision Design has nothing to fetch.")
			else:
				var dm: Object = ctx.corp_decision_maker
				var chosen_arch: CardRecord = null
				if dm != null and dm.has_method("choose_from_archives"):
					chosen_arch = await dm.choose_from_archives(ctx.corp_discard, ctx)
				else:
					chosen_arch = ctx.corp_discard[0] as CardRecord if not ctx.corp_discard.is_empty() else null
				if chosen_arch != null:
					ctx.corp_discard.erase(chosen_arch)
					ctx.corp_hand.append({"card_id": chosen_arch.id, "card_record": chosen_arch})
					ctx.send_log("Precision Design: %s adds %s from Archives to HQ." % [ctx.corp_name(), chosen_arch.title])

		# ── Bahia Bands: modal run event ─────────────────────────────────────

		"run_with_choose_n_effects":
			# Bahia Bands (TAI): Runner runs any server.  If the run is successful, they pick
			# N of the available options and execute them in chosen order.
			# effect fields: server ("any" = all servers), choose (int), options (Array of {label, effect}).
			var rwcn_server_param: String = effect.get("server", "any")
			var rwcn_choose: int          = int(effect.get("choose", 2))
			var rwcn_options: Array       = effect.get("options", []) as Array

			# Build the candidate server list.
			var rwcn_servers: Array = []
			if rwcn_server_param == "any":
				rwcn_servers.append_array(["hq", "rd", "archives"])
				for rwcn_remote in ctx.get_remote_servers():
					rwcn_servers.append((rwcn_remote as Server).server_id)
			else:
				rwcn_servers.append(rwcn_server_param)

			if rwcn_servers.is_empty():
				ctx.send_log("[Bahia Bands] No valid servers to run.")
				return

			# Runner picks a server.
			var rwcn_chosen_server: String = rwcn_servers[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				rwcn_chosen_server = await ctx.runner_decision_maker.choose_server(rwcn_servers, ctx)

			ctx.send_log("[Bahia Bands] %s runs %s." % [ctx.runner_name(), rwcn_chosen_server.to_upper()])
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				(ctx.get_meta("on_run_started") as Callable).call(rwcn_chosen_server)
				await Engine.get_main_loop().process_frame

			var rwcn_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if rwcn_rsm == null:
				push_error("AbilityInterpreter: run_with_choose_n_effects — no run_state_machine on ctx")
				return
			await rwcn_rsm.execute(rwcn_chosen_server)

			if not ctx.run_successful:
				ctx.send_log("[Bahia Bands] Run unsuccessful — no bonus effects.")
				return

			# Run succeeded: runner picks N options.
			ctx.send_log("[Bahia Bands] Run successful! %s chooses %d option(s)." % [ctx.runner_name(), rwcn_choose])
			var rwcn_chosen_modes: Array = []
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				rwcn_chosen_modes = await ctx.runner_decision_maker.choose_modes(rwcn_options, rwcn_choose, ctx)
			else:
				# Fallback: take first N options.
				for _rwcn_i in range(mini(rwcn_choose, rwcn_options.size())):
					rwcn_chosen_modes.append(rwcn_options[_rwcn_i])

			for rwcn_mode in rwcn_chosen_modes:
				var rwcn_sub_effect: Dictionary = (rwcn_mode as Dictionary).get("effect", {}) as Dictionary
				if rwcn_sub_effect.is_empty():
					continue
				ctx.send_log("[Bahia Bands] Resolving: %s." % (rwcn_mode as Dictionary).get("label", "?"))
				await _execute_effect(rwcn_sub_effect, ctx, chosen_target)

		"install_from_grip_discount":
			# Bahia Bands sub-effect: Runner installs 1 card from grip at a credit discount.
			# params: { discount: int }  (default 1)
			var ifgd2_disc: int = params.get("discount", 1)
			var ifgd2_installable: Array = []
			for ifgd2_entry in ctx.runner_hand:
				var ifgd2_e: Dictionary = ifgd2_entry as Dictionary
				var ifgd2_r: CardRecord = ifgd2_e.get("card_record", null) as CardRecord
				if ifgd2_r == null:
					continue
				if ifgd2_r.card_type not in ["program", "hardware", "resource"]:
					continue
				var ifgd2_cost: int = maxi(0, ifgd2_r.cost - ifgd2_disc)
				if ctx.runner_credits < ifgd2_cost:
					continue
				if ifgd2_r.card_type == "program" and ifgd2_r.memory_cost > 0:
					if ctx.runner_mu_available() < ifgd2_r.memory_cost:
						continue
				ifgd2_installable.append(ifgd2_entry)

			if ifgd2_installable.is_empty():
				ctx.send_log("[Bahia Bands] No cards in grip can be installed.")
				return

			var ifgd2_chosen_entry: Variant = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_hand"):
				ifgd2_chosen_entry = await ctx.runner_decision_maker.choose_card_from_hand(ifgd2_installable, ctx)
			else:
				ifgd2_chosen_entry = ifgd2_installable[0]

			if ifgd2_chosen_entry == null:
				ctx.send_log("[Bahia Bands] Runner skips install.")
				return

			var ifgd2_record: CardRecord = (ifgd2_chosen_entry as Dictionary).get("card_record", null) as CardRecord
			if ifgd2_record == null:
				return

			var ifgd2_pay: int = maxi(0, ifgd2_record.cost - ifgd2_disc)
			ctx.runner_credits -= ifgd2_pay
			ctx.runner_hand.erase(ifgd2_chosen_entry)
			var ifgd2_installed := InstalledCard.make_runtime_instance(ifgd2_record, "runner_rig", "root", true)
			ctx.runner_rig.append(ifgd2_installed)
			if ctx.has_meta("register_installed_card"):
				(ctx.get_meta("register_installed_card") as Callable).call(ifgd2_installed)
			if ctx.has_meta("ability_registry"):
				var ifgd2_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var ifgd2_on_rez = ifgd2_ab_reg.get_on_rez(ifgd2_record.id)
				if ifgd2_on_rez != null:
					ctx.current_event_data = {"card": ifgd2_installed, "card_instance_id": ifgd2_installed.runtime_instance_id}
					await execute_trigger(ifgd2_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			if ifgd2_record.card_type == "program" and ifgd2_record.has_subtype("virus"):
				await ctx.notify_event("runner_installs_virus", {
					"card": ifgd2_installed,
					"card_instance_id": ifgd2_installed.runtime_instance_id
				}, self)
			ctx.send_log("[Bahia Bands] %s installed %s (paid %d cr)." % [
				ctx.runner_name(), ifgd2_record.title, ifgd2_pay])

		"place_credits_on_self_for_trash_costs":
			# Bahia Bands sub-effect: place N credits on ctx.run_event_trash_credits.
			# These credits are spent before the runner's pool when paying trash costs this run.
			var pcsftc_amount: int = params.get("amount", 4)
			ctx.run_event_trash_credits += pcsftc_amount
			ctx.send_log("[Bahia Bands] Placed %d credit(s) on event for trash costs (%d total)." % [
				pcsftc_amount, ctx.run_event_trash_credits])

		# ── Hansei Review: Corp discards a card from HQ ───────────────────────

		"discard_grip_to_stack_random":
			# Daniela Jorge Inácio (TAI): discard N random cards from the runner's grip
			# to the bottom of the stack (runner deck). Used as an additional steal/trash cost.
			# params: { amount: int }
			var dgts_amount: int = params.get("amount", 2)
			var dgts_hand: Array = ctx.runner_hand.duplicate()
			dgts_hand.shuffle()
			var dgts_count: int = mini(dgts_amount, dgts_hand.size())
			for i in range(dgts_count):
				var dgts_entry: Dictionary = dgts_hand[i] as Dictionary
				ctx.runner_hand.erase(dgts_entry)
				var dgts_record: CardRecord = dgts_entry.get("card_record", null) as CardRecord
				if dgts_record != null:
					ctx.runner_deck.append(dgts_record)   # bottom of stack
					ctx.send_log("[Daniela] Runner discards %s to the bottom of the stack." % dgts_record.title)

		"urban_art_vernissage_bounce_trojan":
			# Urban Art Vernissage (TAI): At the start of the Runner's turn, the Runner may
			# return 1 installed non-virus trojan program to the grip.  If they do, place 2
			# credits on this resource (to be spent on future install costs via install_credits_any).
			var uav_self := _get_self_card(ctx)
			if uav_self == null:
				push_error("urban_art_vernissage_bounce_trojan: self card not found")
				return
			# Collect eligible trojans: programs with "trojan" subtype and NOT "virus" subtype.
			var uav_trojans: Array = []
			for uav_rc in ctx.runner_rig:
				var uav_c: InstalledCard = uav_rc as InstalledCard
				if uav_c == null or uav_c.card_record == null:
					continue
				var uav_cr: CardRecord = uav_c.card_record
				if uav_cr.card_type == "program" and uav_cr.has_subtype("trojan") and \
						not uav_cr.has_subtype("virus"):
					uav_trojans.append(uav_c)
			if uav_trojans.is_empty():
				return   # No eligible trojans — ability has no effect this turn.
			# Runner may optionally choose one to return (passing null = decline).
			var uav_chosen: InstalledCard = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_to_bounce"):
				uav_chosen = await ctx.runner_decision_maker.choose_card_to_bounce(uav_trojans, ctx)
			elif not uav_trojans.is_empty():
				uav_chosen = null   # default: do not bounce unless runner says so
			if uav_chosen == null:
				return   # Runner declines.
			# Return the chosen trojan to the grip.
			ctx.runner_rig.erase(uav_chosen)
			if uav_chosen.card_record != null:
				ctx.runner_hand.append({"card_id": uav_chosen.card_id, "card_record": uav_chosen.card_record})
			ctx.unregister_all_card_effects(uav_chosen.runtime_instance_id)
			ctx.send_log("[Urban Art Vernissage] %s returns %s to grip." % [
				ctx.runner_name(), uav_chosen.display_name()
			])
			# Place 2 credits on Urban Art Vernissage.
			uav_self.add_counter("credits", 2)
			ctx.send_log("[Urban Art Vernissage] 2 credits placed (%d total)." % uav_self.get_counter("credits"))

		"cybersand_trash_for_credits":
			# Cybersand Harvester (TAI): Corp trashes this asset as a paid ability to gain all
			# hosted credits.  Implemented as a click action in the digital edition.
			var ctfc_self := _get_self_card(ctx)
			if ctfc_self == null:
				push_error("cybersand_trash_for_credits: self card not found")
				return
			var ctfc_amount: int = ctfc_self.get_counter("credits")
			# Move hosted credits to Corp pool.
			ctx.corp_credits += ctfc_amount
			ctx.send_log("[Cybersand Harvester] Corp gains %d credit(s) (total: %d)." % [
				ctfc_amount, ctx.corp_credits
			])
			# Trash the asset: remove from server root, unregister listeners, add to Archives.
			var ctfc_server: Server = ctx.get_server(ctfc_self.server_id) if ctx.has_method("get_server") else null
			if ctfc_server != null:
				ctfc_server.remove_from_root(ctfc_self)
				ctx.remove_empty_remote_servers()
			ctx.unregister_all_card_effects(ctfc_self.runtime_instance_id)
			if ctfc_self.card_record != null:
				ctx.corp_discard.append(ctfc_self.card_record)
			ctx.send_log("[Cybersand Harvester] Cybersand Harvester trashed.")

		"shuffle_self_to_rd_from_runner_score_area":
			# Oracle Thinktank (TAI): Corp uses [click] + removes 1 runner tag to shuffle
			# Oracle Thinktank from the Runner's score area back into R&D.
			# Self card is the InstalledCard that represents Oracle Thinktank in runner_score_area_cards.
			var srsa_ic := _get_self_card(ctx)
			if srsa_ic == null:
				push_error("shuffle_self_to_rd_from_runner_score_area: self card not found")
				return
			# Remove from runner_score_area (CardRecord list) — matches by card_id
			var srsa_cr: CardRecord = null
			for rsa_entry in ctx.runner_score_area:
				var rsa_r: CardRecord = rsa_entry as CardRecord
				if rsa_r != null and rsa_r.id == srsa_ic.card_id:
					srsa_cr = rsa_r
					ctx.runner_score_area.erase(rsa_entry)
					break
			# Remove from runner_score_area_cards (InstalledCard list)
			ctx.runner_score_area_cards.erase(srsa_ic)
			# Add to corp_deck (R&D) and shuffle
			var srsa_record: CardRecord = srsa_cr if srsa_cr != null else srsa_ic.card_record
			if srsa_record != null:
				ctx.corp_deck.append(srsa_record)
			ctx.corp_deck.shuffle()
			ctx.send_log("[Oracle Thinktank] Corp shuffles Oracle Thinktank back into R&D.")

		"epiphany_analytica_install_from_rd":
			# Epiphany Analytica: Nations Undivided (TAI): Corp spends [click] + 1 power counter
			# to look at the top 3 cards of R&D and optionally install 1 of them.
			var ea_power: int = ctx.corp_identity_counters.get("power", 0)
			if ea_power < 1:
				ctx.send_log("[Epiphany Analytica] No power counters remaining — cannot activate.")
				return
			ctx.corp_identity_counters["power"] = ea_power - 1
			ctx.send_log("[Epiphany Analytica] 1 power counter spent (%d remaining)." % \
				(ea_power - 1))
			# Peek top 3 R&D
			var ea_peek: int = mini(3, ctx.corp_deck.size())
			if ea_peek == 0:
				ctx.send_log("[Epiphany Analytica] R&D is empty.")
				return
			var ea_top: Array = []
			for ea_i in range(ea_peek):
				ea_top.append(ctx.corp_deck[ea_i])
			ctx.send_log("[Epiphany Analytica] Corp looks at top %d card(s) of R&D: %s." % [
				ea_peek, ", ".join(ea_top.map(func(r): return (r as CardRecord).title))
			])
			# Corp picks one to install (may decline by returning null)
			var ea_chosen: CardRecord = null
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_from_search"):
				ea_chosen = await ctx.corp_decision_maker.choose_from_search(ea_top, ctx)
			if ea_chosen == null:
				ctx.send_log("[Epiphany Analytica] Corp declines to install.")
				return
			# Remove chosen card from R&D (may be at position 0, 1, or 2)
			ctx.corp_deck.erase(ea_chosen)
			ctx.send_log("[Epiphany Analytica] Corp pulls %s from R&D to install." % ea_chosen.title)
			# Corp picks a server
			var ea_servers: Array = ctx.servers.keys()
			var ea_server_id: String = ea_servers[0] if not ea_servers.is_empty() else "hq"
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_server"):
				ea_server_id = await ctx.corp_decision_maker.choose_server(ea_servers, ctx)
			var ea_server: Server = ctx.get_server(ea_server_id) if ctx.has_method("get_server") else null
			if ea_server == null:
				ctx.send_log("[Epiphany Analytica] Server not found — returning card to R&D.")
				ctx.corp_deck.append(ea_chosen)
				ctx.corp_deck.shuffle()
				return
			# Pay install cost (normal, per rulings)
			var ea_install_cost: int = maxi(0, ea_chosen.cost if ea_chosen.cost >= 0 else 0)
			# Add install cost discount for ice if multiple ice already installed (positional cost)
			if ea_chosen.card_type == "ice":
				ea_install_cost += ea_server.ice.size()
			if ctx.corp_credits < ea_install_cost:
				ctx.send_log("[Epiphany Analytica] Corp cannot afford install cost %d (has %d) — card returned to R&D." % [
					ea_install_cost, ctx.corp_credits])
				ctx.corp_deck.append(ea_chosen)
				ctx.corp_deck.shuffle()
				return
			ctx.corp_credits -= ea_install_cost
			# Install the card (unrezzed, unless Corp rezzes separately)
			var ea_zone: String = "ice" if ea_chosen.card_type == "ice" else "root"
			var ea_inst := _install_corp_card(ea_chosen, ea_server, ea_zone, false)
			if ctx.has_meta("register_installed_card"):
				(ctx.get_meta("register_installed_card") as Callable).call(ea_inst)
			ctx.send_log("[Epiphany Analytica] %s installed in %s (cost %d)." % [
				ea_chosen.title, ea_server_id, ea_install_cost
			])

		"discard_from_corp_hand":
			var amount: int = params.get("amount", 1)
			var dm: Object = ctx.corp_decision_maker
			var dfch_discarded := 0
			for _i in range(min(amount, ctx.corp_hand.size())):
				var chosen_entry: Variant = null
				if dm != null and dm.has_method("choose_card_from_hand"):
					chosen_entry = await dm.choose_card_from_hand(ctx.corp_hand, ctx)
				else:
					chosen_entry = ctx.corp_hand.back() if not ctx.corp_hand.is_empty() else null
				if chosen_entry == null:
					break
				ctx.corp_hand.erase(chosen_entry)
				var hq_record: CardRecord = (chosen_entry as Dictionary).get("card_record", null) as CardRecord
				if hq_record != null:
					ctx.corp_discard.append(hq_record)
					ctx.corp_discard_facedown[hq_record.title] = true
					ctx.send_log("%s discards %s from HQ." % [ctx.corp_name(), hq_record.title])
				dfch_discarded += 1
			# AU Co.: The Gold Standard in Clones — place 1 counter when 1+ cards trashed from HQ.
			if dfch_discarded > 0 and ctx.corp_identity != null and \
					ctx.corp_identity.id == "au_co_the_gold_standard_in_clones":
				ctx.corp_identity_counters["power"] = ctx.corp_identity_counters.get("power", 0) + 1
				ctx.send_log("AU Co.: Power counter placed (%d total)." % ctx.corp_identity_counters.get("power", 0))

		# ── Longevity Serum: shuffle discard into deck, gain 1cr per card ─────

		"shuffle_discard_to_deck_gain_credits":
			var subject: String = params.get("subject", "corp")
			var s_discard: Array = ctx.corp_discard if subject == "corp" else ctx.runner_discard
			var s_deck: Array    = ctx.corp_deck    if subject == "corp" else ctx.runner_deck
			if s_discard.is_empty():
				ctx.send_log("Discard pile is empty — nothing to shuffle.")
			else:
				var dm: Object = ctx.corp_decision_maker if subject == "corp" else ctx.runner_decision_maker
				var chosen_cards: Array = []
				if dm != null and dm.has_method("choose_cards_to_shuffle_into_deck"):
					chosen_cards = await dm.choose_cards_to_shuffle_into_deck(s_discard.duplicate(), ctx)
				else:
					chosen_cards = s_discard.duplicate()
				for card in chosen_cards:
					s_discard.erase(card)
					s_deck.append(card)
				s_deck.shuffle()
				var gained: int = chosen_cards.size()
				if gained > 0:
					ctx.set_credits(subject, ctx.get_credits(subject) + gained)
					ctx.send_log("Longevity Serum: shuffled %d card(s) into R&D, gained %d cr." % [gained, gained])
					# The Zwicky Group: Longevity Serum is an operation.
					if subject == "corp" and \
							ctx.current_ability_source_card_type in ["operation", "agenda"]:
						await ctx.notify_event("corp_gains_credits_via_ability", {"amount": gained}, self)

		# ── Neurospike: deal net damage equal to last scored agenda's points ────

		"deal_damage_from_last_scored_agenda":
			var damage_type: String = params.get("damage_type", "net")
			var amount: int = ctx.corp_last_scored_agenda_points
			if amount <= 0:
				ctx.send_log("Neurospike: no agenda scored this turn — no damage.")
			else:
				ctx.send_log("Neurospike: deals %d %s damage." % [amount, damage_type])
				await _deal_damage(damage_type, amount, ctx)

		# ── Weyland Built to Last: gain 2cr on first advance each turn ────────

		"gain_credits_first_advance_this_turn":
			if ctx.corp_gained_advance_credits_this_turn:
				return
			ctx.corp_gained_advance_credits_this_turn = true
			var btl_amount: int = params.get("amount", 2)
			ctx.corp_credits += btl_amount
			ctx.send_log("Built to Last: %s gains %d cr (first advance this turn)." % [ctx.corp_name(), btl_amount])

		# ── Zahya: gain 1cr per access beyond the first in HQ/Archives ────────

		"gain_credits_per_access_beyond_first":
			var allowed_servers: Array = params.get("servers", []) as Array
			var breach_server_id: String = ctx.current_event_data.get("server_id", "")
			if not allowed_servers.is_empty() and breach_server_id not in allowed_servers:
				return
			var total_accessed: int = ctx.current_event_data.get("access_count", 0)
			var zahya_bonus: int = max(0, total_accessed - 1)
			if zahya_bonus > 0:
				ctx.runner_credits += zahya_bonus
				ctx.send_log("Zahya: gains %d cr (%d accesses)." % [zahya_bonus, total_accessed])

		# ── Nanomanagement / otto_campaign extras: grant clicks ───────────────

		"gain_clicks":
			# Grant extra clicks to the Corp or Runner.
			# Used by Nanomanagement (Corp gains 2), and future cards.
			var gc_subject: String = params.get("subject", "corp")
			var gc_amount: int     = params.get("amount", 1)
			if gc_subject == "corp":
				ctx.corp_clicks += gc_amount
				ctx.send_log("%s gains %d click(s). (%d total)" % [ctx.corp_name(), gc_amount, ctx.corp_clicks])
			else:
				ctx.runner_clicks += gc_amount
				ctx.send_log("%s gains %d click(s). (%d total)" % [ctx.runner_name(), gc_amount, ctx.runner_clicks])

		# ── Chrysopoeian Skimming: Corp gains a click ────────────────────────

		"corp_gain_click":
			# Grant the Corp bonus click(s) for their next turn via pending_click_bonuses.
			# Using deferred (not ctx.corp_clicks +=) is correct even when this fires
			# during the Corp's own turn — pending bonuses are applied at the very start
			# of the next turn before any actions.  Always safe to defer rather than grant
			# an immediate mid-turn click the Corp cannot spend in the current priority window.
			# params: { amount: int }  default 1
			var cgc_amount: int = params.get("amount", 1)
			ctx.pending_click_bonuses["corp"] = ctx.pending_click_bonuses.get("corp", 0) + cgc_amount
			ctx.send_log("%s will gain +%d click(s) at the start of their next turn." % [
				ctx.corp_name(), cgc_amount])

		# ── Chrysopoeian Skimming: Corp reveal-or-peek branch ───────────────────────

		"chrysopoeian_skimming_reveal_or_peek":
			# Chrysopoeian Skimming (TAI Runner event):
			# Corp may reveal an agenda from HQ. If they do, Corp gains [click] next turn
			# and draws 1 card. Otherwise, the Runner looks at the top 3 cards of R&D.
			#
			# "gain [click]" is deferred via pending_click_bonuses — this fires during
			# the Runner's turn, so the Corp cannot spend an immediate click.

			# Build the list of agendas currently in HQ
			var cs_agendas: Array = []
			for cs_entry in ctx.corp_hand:
				var cs_dict: Dictionary = cs_entry as Dictionary
				var cs_rec: CardRecord  = cs_dict.get("card_record", null) as CardRecord
				if cs_rec != null and cs_rec.is_agenda():
					cs_agendas.append(cs_dict)

			var cs_revealed := false

			if not cs_agendas.is_empty():
				# Corp decides whether to reveal an agenda
				var cs_corp_dm: Object = ctx.corp_decision_maker
				var cs_will_reveal := false
				if cs_corp_dm != null and cs_corp_dm.has_method("choose_optional_ability"):
					cs_will_reveal = await cs_corp_dm.choose_optional_ability(
						"Chrysopoeian Skimming: reveal an agenda from HQ to gain [click] next turn and draw 1?", ctx)
				else:
					cs_will_reveal = true  # AI: always reveal (Corp benefits)

				if cs_will_reveal:
					# If multiple agendas in HQ, ask Corp which to reveal
					var cs_target: Dictionary = cs_agendas[0] as Dictionary
					if cs_agendas.size() > 1 and cs_corp_dm != null and \
							cs_corp_dm.has_method("choose_card_from_hq_to_reveal"):
						var cs_chosen: Dictionary = await cs_corp_dm.choose_card_from_hq_to_reveal(ctx)
						if not cs_chosen.is_empty():
							var cs_chosen_rec: CardRecord = cs_chosen.get("card_record", null) as CardRecord
							if cs_chosen_rec != null and cs_chosen_rec.is_agenda():
								cs_target = cs_chosen

					var cs_agenda_rec: CardRecord = cs_target.get("card_record", null) as CardRecord
					if cs_agenda_rec != null:
						ctx.send_log("[Chrysopoeian Skimming] %s reveals %s from HQ." % [
							ctx.corp_name(), cs_agenda_rec.title])
						# Gain [click] at start of Corp's next turn
						ctx.pending_click_bonuses["corp"] = ctx.pending_click_bonuses.get("corp", 0) + 1
						ctx.send_log("[Chrysopoeian Skimming] %s gains +1 click next turn." % ctx.corp_name())
						# Corp draws 1 card
						_draw_cards("corp", 1, ctx)
						cs_revealed = true

			if not cs_revealed:
				# Runner looks at top 3 cards of R&D (does not draw them)
				var cs_n: int = mini(3, ctx.corp_deck.size())
				if cs_n == 0:
					ctx.send_log("[Chrysopoeian Skimming] R&D is empty — nothing to look at.")
				else:
					var cs_titles: Array = []
					for cs_i in range(cs_n):
						cs_titles.append((ctx.corp_deck[cs_i] as CardRecord).title)
					ctx.send_log("[Chrysopoeian Skimming] %s looks at top %d card(s) of R&D: %s." % [
						ctx.runner_name(), cs_n, ", ".join(cs_titles)])
					# Notify UI via registered callback if present
					if ctx.has_meta("on_look_at_top_rd_n"):
						var cs_cb: Callable = ctx.get_meta("on_look_at_top_rd_n") as Callable
						await cs_cb.call(cs_n, ctx.corp_deck.slice(0, cs_n))

		# ── Slash & Burn / Tree Line / Greasing the Palm: place advancement counters ──

		"add_advancement_counters_on_installed":
			# Place N advancement counters on any installed advanceable card.
			# If the card is an agenda and now meets its advancement requirement, score it inline.
			# params: { amount: int, target_zone: "root"|"ice"|"any" }
			# target_zone defaults to "root" (agendas/assets/upgrades); use "ice" for Tree Line.
			var aaci_amount: int     = params.get("amount", 1)
			var aaci_zone: String    = params.get("target_zone", "root")

			# Build the candidate pool.
			var aaci_pool: Array = []
			for aaci_srv in ctx.servers.values():
				var aaci_s: Server = aaci_srv as Server
				if aaci_zone in ["root", "any"]:
					for aaci_c in aaci_s.root:
						var aaci_ic: InstalledCard = aaci_c as InstalledCard
						if aaci_ic != null and aaci_ic.can_be_advanced():
							aaci_pool.append(aaci_ic)
				if aaci_zone in ["ice", "any"]:
					for aaci_c in aaci_s.ice:
						var aaci_ic: InstalledCard = aaci_c as InstalledCard
						if aaci_ic != null and aaci_ic.can_be_advanced():
							aaci_pool.append(aaci_ic)

			if aaci_pool.is_empty():
				ctx.send_log("%s: no advanceable installed cards." % ctx.corp_name())
				return

			# Corp picks a target.
			var aaci_target: InstalledCard = aaci_pool[0]
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_installed_card"):
				var aaci_chosen: Variant = await ctx.corp_decision_maker.choose_installed_card(
					aaci_pool, ctx)
				if aaci_chosen is InstalledCard:
					aaci_target = aaci_chosen as InstalledCard

			# Place the counters.
			aaci_target.add_counter("advancement", aaci_amount)
			ctx.send_log("%s places %d advancement counter(s) on %s (%d total)." % [
				ctx.corp_name(), aaci_amount, aaci_target.display_name(),
				aaci_target.get_counter("advancement")])

			# Score if it's an agenda that now meets its requirement.
			if aaci_target.card_record == null or not aaci_target.card_record.is_agenda():
				return
			if not aaci_target.meets_advancement_requirement():
				return

			# Inline scoring (mirrors TurnManager._score_agenda without TurnManager dependency).
			var aaci_record: CardRecord = aaci_target.card_record
			ctx.send_log("%s scores %s! (%d agenda point%s)" % [
				ctx.corp_name(), aaci_record.title, aaci_record.agenda_points,
				"s" if aaci_record.agenda_points != 1 else ""])

			# Remove from server.
			var aaci_server: Server = ctx.get_server(aaci_target.server_id)
			if aaci_server != null:
				aaci_server.remove_from_root(aaci_target)
				if aaci_server.is_empty() and aaci_server.is_remote():
					ctx.remove_empty_remote_servers()

			# Move to Corp score area.
			ctx.corp_score_area.append(aaci_record)
			ctx.corp_score_area_cards.append(aaci_target)
			ctx.corp_last_scored_agenda_points   = aaci_record.agenda_points
			ctx.corp_agendas_scored_this_turn   += 1
			# Was installed this turn — leave corp_scored_agenda_not_installed_this_turn
			# unchanged (only set to true if NOT installed this turn; scoring an installed
			# card doesn't set it).

			# Fire on_score ability (excess = 0 since we just hit the requirement exactly
			# or beyond — pass actual excess for accuracy).
			var aaci_excess: int = maxi(0,
				aaci_target.get_counter("advancement") - aaci_record.advancement_requirement)
			var aaci_ab_reg: AbilityRegistry = null
			if ctx.has_meta("ability_registry"):
				aaci_ab_reg = ctx.get_meta("ability_registry") as AbilityRegistry
			if aaci_ab_reg != null:
				var aaci_on_score = aaci_ab_reg.get_on_score(aaci_record.id)
				if aaci_on_score != null:
					ctx.current_event_data = {
						"card":                aaci_target,
						"card_instance_id":    aaci_target.runtime_instance_id,
						"excess_advancement":  aaci_excess
					}
					ctx.current_ability_source_card_type = "agenda"
					await execute_trigger(aaci_on_score as Dictionary, ctx)
					ctx.current_event_data = {}
					ctx.current_ability_source_card_type = ""

			# Notify listeners (Malapert, Phat Gioan, etc.)
			await ctx.notify_event("corp_scores_agenda", {
				"agenda_id":     aaci_record.id,
				"agenda_points": aaci_record.agenda_points,
				"server_id":     aaci_target.server_id
			}, self)

			# Check Corp win condition.
			if ctx.corp_agenda_points() >= ctx.agenda_points_to_win:
				ctx.send_log("%s wins!" % ctx.corp_name())
				ctx.game_over = true
				ctx.winner    = "corp"

		"add_advancement_counters_on_installed_multi":
			# Greasing the Palm (TAI): Place 1 advancement counter on each of up to N
			# *different* installed advanceable cards.  Corp picks targets one at a time;
			# already-chosen cards are removed from the candidate pool each round.
			# params: { amount: int, max_targets: int }
			var aacim_amount: int      = params.get("amount", 1)
			var aacim_max: int         = params.get("max_targets", 3)
			var aacim_already: Array   = []   # InstalledCards already targeted this activation

			for _aacim_i in range(aacim_max):
				# Rebuild pool each round to exclude already-chosen cards.
				var aacim_pool: Array = []
				for aacim_srv in ctx.servers.values():
					for aacim_c in (aacim_srv as Server).root:
						var aacim_ic: InstalledCard = aacim_c as InstalledCard
						if aacim_ic != null and aacim_ic.can_be_advanced() \
								and not aacim_already.has(aacim_ic):
							aacim_pool.append(aacim_ic)

				if aacim_pool.is_empty():
					break

				# Corp may decline to pick further targets ("up to").
				var aacim_target: InstalledCard = null
				if ctx.corp_decision_maker != null and \
						ctx.corp_decision_maker.has_method("choose_installed_card"):
					var aacim_chosen: Variant = await ctx.corp_decision_maker.choose_installed_card(
						aacim_pool, ctx)
					if aacim_chosen is InstalledCard:
						aacim_target = aacim_chosen as InstalledCard
				else:
					aacim_target = aacim_pool[0]   # AI fallback: pick first available

				if aacim_target == null:
					break   # Corp declines further selections

				aacim_already.append(aacim_target)
				aacim_target.add_counter("advancement", aacim_amount)
				ctx.send_log("%s places %d advancement counter(s) on %s (%d total)." % [
					ctx.corp_name(), aacim_amount, aacim_target.display_name(),
					aacim_target.get_counter("advancement")])

				# Score immediately if this is an agenda that now meets its requirement.
				if aacim_target.card_record != null and \
						aacim_target.card_record.is_agenda() and \
						aacim_target.meets_advancement_requirement():
					var aacim_rec: CardRecord = aacim_target.card_record
					ctx.send_log("%s scores %s! (%d agenda point%s)" % [
						ctx.corp_name(), aacim_rec.title, aacim_rec.agenda_points,
						"s" if aacim_rec.agenda_points != 1 else ""])
					var aacim_srv2: Server = ctx.get_server(aacim_target.server_id)
					if aacim_srv2 != null:
						aacim_srv2.remove_from_root(aacim_target)
						if aacim_srv2.is_empty() and aacim_srv2.is_remote():
							ctx.remove_empty_remote_servers()
					ctx.corp_score_area.append(aacim_rec)
					ctx.corp_score_area_cards.append(aacim_target)
					ctx.corp_last_scored_agenda_points  = aacim_rec.agenda_points
					ctx.corp_agendas_scored_this_turn  += 1
					var aacim_excess2: int = maxi(0,
						aacim_target.get_counter("advancement") - aacim_rec.advancement_requirement)
					var aacim_ab_reg: AbilityRegistry = null
					if ctx.has_meta("ability_registry"):
						aacim_ab_reg = ctx.get_meta("ability_registry") as AbilityRegistry
					if aacim_ab_reg != null:
						var aacim_on_score = aacim_ab_reg.get_on_score(aacim_rec.id)
						if aacim_on_score != null:
							ctx.current_event_data = {
								"card":               aacim_target,
								"card_instance_id":   aacim_target.runtime_instance_id,
								"excess_advancement": aacim_excess2
							}
							ctx.current_ability_source_card_type = "agenda"
							await execute_trigger(aacim_on_score as Dictionary, ctx)
							ctx.current_event_data = {}
							ctx.current_ability_source_card_type = ""
					await ctx.notify_event("corp_scores_agenda", {
						"agenda_id":     aacim_rec.id,
						"agenda_points": aacim_rec.agenda_points,
						"server_id":     aacim_target.server_id
					}, self)
					if ctx.corp_agenda_points() >= ctx.agenda_points_to_win:
						ctx.send_log("%s wins!" % ctx.corp_name())
						ctx.game_over = true
						ctx.winner    = "corp"
					break   # A won game ends further selection

		# ── Armed Asset Protection: gain credits per distinct card type in Archives ──

		"count_card_types_in_archives":
			# Armed Asset Protection (TAI): Gain credit_per_type credits for each distinct
			# card type among *faceup* cards in Archives. If any faceup card is an agenda,
			# gain agenda_bonus additional credits.
			# params: { credit_per_type: int, agenda_bonus: int }
			var ccat_per_type: int    = params.get("credit_per_type", 1)
			var ccat_ag_bonus: int    = params.get("agenda_bonus", 2)

			# Collect distinct card types from faceup Archives cards only.
			var ccat_types: Dictionary = {}   # card_type → true (used as a set)
			for ccat_cr in ctx.corp_discard:
				var ccat_r: CardRecord = ccat_cr as CardRecord
				if ccat_r == null:
					continue
				# Skip facedown cards (unrezzed-when-trashed installs)
				if ctx.corp_discard_facedown.get(ccat_r.title, false):
					continue
				ccat_types[ccat_r.card_type] = true

			var ccat_count: int   = ccat_types.size()
			var ccat_gain: int    = ccat_count * ccat_per_type
			var ccat_has_ag: bool = ccat_types.has("agenda")
			if ccat_has_ag:
				ccat_gain += ccat_ag_bonus

			ctx.corp_credits += ccat_gain
			ctx.send_log("%s gains %d cr from Armed Asset Protection (%d distinct card type%s in Archives%s)." % [
				ctx.corp_name(), ccat_gain, ccat_count,
				"s" if ccat_count != 1 else "",
				" + 2 agenda bonus" if ccat_has_ag else ""])

		# ── Flyswatter: purge all virus counters ──────────────────────────────

		"purge_virus_counters":
			# Remove all virus counters from all installed runner cards.
			var pv_total := 0
			for pv_card in ctx.runner_rig:
				var pv_c: InstalledCard = pv_card as InstalledCard
				if pv_c == null:
					continue
				var pv_vc: int = pv_c.get_counter("virus")
				if pv_vc > 0:
					pv_c.remove_counter("virus", pv_vc)
					pv_total += pv_vc
			# Also purge from programs hosted on ice
			for pv_server in ctx.servers.values():
				for pv_ice in (pv_server as Server).ice:
					for pv_hosted in (pv_ice as InstalledCard).hosted_cards:
						var pv_h: InstalledCard = pv_hosted as InstalledCard
						if pv_h != null:
							var pv_hvc: int = pv_h.get_counter("virus")
							if pv_hvc > 0:
								pv_h.remove_counter("virus", pv_hvc)
								pv_total += pv_hvc
			ctx.send_log("Purge: removed %d virus counter(s) from runner's installed cards." % pv_total)
			# Trash any runner-installed cards with trashed_on_purge: true (e.g. Physarum Entangler).
			var _pv_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry \
				if ctx.has_meta("ability_registry") else null
			var _pv_to_trash: Array = []
			for _pv_rig_card in ctx.runner_rig:
				var _pv_rc: InstalledCard = _pv_rig_card as InstalledCard
				if _pv_rc == null or _pv_ab_reg == null:
					continue
				var _pv_ab: Dictionary = _pv_ab_reg._abilities.get(_pv_rc.card_id, {}) as Dictionary
				if _pv_ab.get("trashed_on_purge", false):
					_pv_to_trash.append(_pv_rc)
			# Also check programs hosted on ice
			for _pv_srv in ctx.servers.values():
				for _pv_ice in (_pv_srv as Server).ice:
					for _pv_hosted in (_pv_ice as InstalledCard).hosted_cards:
						var _pv_h: InstalledCard = _pv_hosted as InstalledCard
						if _pv_h == null or _pv_ab_reg == null:
							continue
						var _pv_hab: Dictionary = _pv_ab_reg._abilities.get(_pv_h.card_id, {}) as Dictionary
						if _pv_hab.get("trashed_on_purge", false):
							_pv_to_trash.append(_pv_h)
			for _pv_trash_card in _pv_to_trash:
				var _pv_tc: InstalledCard = _pv_trash_card as InstalledCard
				ctx.runner_rig.erase(_pv_tc)
				# Remove from hosted_cards if it's a trojan
				if _pv_tc.hosted_on_id != "":
					var _pv_host_ice: InstalledCard = ctx.get_ice_by_instance_id(_pv_tc.hosted_on_id)
					if _pv_host_ice != null:
						_pv_host_ice.hosted_cards.erase(_pv_tc)
				ctx.unregister_all_card_effects(_pv_tc.runtime_instance_id)
				if _pv_tc.card_record != null:
					ctx.runner_discard.append(_pv_tc.card_record)
				ctx.send_log("Purge: %s is trashed (trashed on purge)." % _pv_tc.display_name())
			# Notify listeners (e.g. Heliamphora) that a purge just happened.
			await ctx.notify_event("corp_purges_virus_counters", {}, self)

		# ── Heliamphora: redirect one Archives access per breach to hosted zone ──

		"heliamphora_redirect_access":
			# Fires on the "before_access" interrupt event.
			# Once per Archives breach, the runner may host the about-to-be-accessed
			# card on Heliamphora instead of accessing it.  The card is not stolen or
			# trashed — it simply moves to Heliamphora's faceup_hosted_cards.
			# The card is later returned to Archives when Heliamphora is trashed.
			# Signals RunStateMachine via run_modifiers["access_redirected_to_heliamphora"].
			if ctx.current_event_data.get("server_id", "") != "archives":
				return  # only redirects Archives accesses
			if ctx.run_modifiers.get("heliamphora_used_this_breach", false):
				return  # already used this breach
			var hra_card: CardRecord = ctx.current_event_data.get("card", null) as CardRecord
			if hra_card == null:
				return
			var hra_self := _get_self_card(ctx)
			if hra_self == null or not hra_self.is_rezzed:
				return
			# Ask runner whether to redirect.
			# AI heuristic: only redirect agendas (saves them from being shuffled away).
			var hra_dm: Object = ctx.runner_decision_maker
			var hra_is_human: bool = hra_dm != null and hra_dm.has_method("choose_modes") \
				and hra_dm.get("choose_modes_proxy") != null \
				and (hra_dm.get("choose_modes_proxy") as Callable).is_valid()
			var hra_redirect: bool = false
			if hra_is_human:
				var hra_modes: Array = [
					{"label": "Host on Heliamphora (skip access)"},
					{"label": "Access normally"}
				]
				var hra_choice: Array = await hra_dm.choose_modes(hra_modes, 1, ctx)
				hra_redirect = (not hra_choice.is_empty() and int(hra_choice[0]) == 0)
			else:
				# AI: redirect only agendas — there's no benefit to hosting non-agendas
				hra_redirect = (hra_card != null and hra_card.is_agenda())
			if not hra_redirect:
				return  # runner chose to access normally (or AI decided not to redirect)
			# Signal the redirect to RunStateMachine
			ctx.run_modifiers["heliamphora_used_this_breach"] = true
			ctx.run_modifiers["access_redirected_to_heliamphora"] = hra_self.runtime_instance_id
			ctx.send_log("Heliamphora: %s will be hosted instead of accessed." % hra_card.title)

		# ── Heliamphora: Corp purges — trash 2 HQ, trash self ────────────────────

		"heliamphora_purge_response":
			# Fires on corp_purges_virus_counters.
			# Corp trashes 2 cards from HQ at random, then Heliamphora is trashed.
			# Any cards hosted on Heliamphora return to Archives.
			var hpr_self := _get_self_card(ctx)
			if hpr_self == null:
				return
			# Trash up to 2 random HQ cards
			var hpr_trashed: int = 0
			while hpr_trashed < 2 and not ctx.corp_hand.is_empty():
				var hpr_idx: int = randi() % ctx.corp_hand.size()
				var hpr_entry: Dictionary = ctx.corp_hand[hpr_idx] as Dictionary
				var hpr_r: CardRecord = hpr_entry.get("card_record", null) as CardRecord
				ctx.corp_hand.remove_at(hpr_idx)
				if hpr_r != null:
					ctx.corp_discard.append(hpr_r)
					ctx.send_log("Heliamphora: Corp trashes %s from HQ at random." % hpr_r.title)
				hpr_trashed += 1
			if hpr_trashed == 0:
				ctx.send_log("Heliamphora: HQ is empty — no cards trashed.")
			# Return hosted cards to Archives
			for hpr_hc in hpr_self.faceup_hosted_cards:
				var hpr_hcr: CardRecord = hpr_hc as CardRecord
				if hpr_hcr != null:
					ctx.corp_discard.append(hpr_hcr)
					ctx.send_log("Heliamphora: %s returned to Archives." % hpr_hcr.title)
			hpr_self.faceup_hosted_cards.clear()
			# Trash Heliamphora itself
			_trash_installed_card(hpr_self, ctx)
			if hpr_self.card_record != null:
				ctx.runner_discard.append(hpr_self.card_record)
			ctx.send_log("Heliamphora is trashed.")

		# ── Lie Low: remove tags ──────────────────────────────────────────────

		"remove_tags":
			# Remove up to N tags from the runner.
			var rt_amount: int = params.get("amount", 1)
			var rt_removed: int = min(rt_amount, ctx.runner_tags)
			ctx.runner_tags -= rt_removed
			ctx.send_log("%s removes %d tag(s). (%d remaining)" % [ctx.runner_name(), rt_removed, ctx.runner_tags])
			if rt_removed > 0:
				await ctx.notify_event("tag_removed", {"amount": rt_removed}, self)

		# ── Ritual: draw 1 card per remaining click ───────────────────────────

		"draw_cards_equal_to_remaining_clicks":
			# Draw 1 card for each click the subject currently has remaining.
			# Ritual fires this after spending 1 click to play, so remaining
			# clicks represent the usable draw count.
			var drc_subject: String = params.get("subject", "runner")
			var drc_clicks: int = ctx.runner_clicks if drc_subject == "runner" else ctx.corp_clicks
			if drc_clicks > 0:
				_draw_cards(drc_subject, drc_clicks, ctx)
			else:
				ctx.send_log("%s has no clicks remaining — draws 0 cards." % ctx.player_name(drc_subject))

		# ── Side Hustle: accumulate credits and auto-fire at threshold ────────

		"self_payout_and_trash_at_threshold":
			# When the owning card's hosted counter reaches the given threshold,
			# take all credits, draw 1 card, and self-trash. Used by Side Hustle.
			var sp_counter: String = effect.get("counter", params.get("counter", "credits"))
			var sp_threshold: int  = int(effect.get("threshold", params.get("threshold", 6)))
			var sp_card := _get_self_card(ctx)
			if sp_card == null:
				return
			if sp_card.get_counter(sp_counter) < sp_threshold:
				return   # threshold not yet reached
			# Take all hosted credits
			var sp_taken: int = sp_card.get_counter(sp_counter)
			sp_card.remove_counter(sp_counter, sp_taken)
			ctx.runner_credits += sp_taken
			ctx.send_log("%s takes all %d cr from %s (threshold reached)." % [
				ctx.runner_name(), sp_taken, sp_card.display_name()
			])
			# Draw 1 card for the runner
			_draw_cards("runner", 1, ctx)
			# Self-trash
			ctx.runner_rig.erase(sp_card)
			ctx.unregister_all_card_effects(sp_card.runtime_instance_id)
			if sp_card.card_record != null:
				ctx.runner_discard.append(sp_card.card_record)
			ctx.send_log("%s is trashed." % sp_card.display_name())

		# ── Top Down Solutions / KPI / Peer Review: install any card from HQ ─

		"install_any_from_hq":
			# Corp installs up to max_installs cards from HQ (and optionally Archives)
			# ignoring all costs.  Cards go into a new remote server (or the current
			# run server if one is active).
			# params:
			#   max_installs:  int    — how many cards to install (default 1)
			#   optional:      bool   — Corp may decline (default false)
			#   zone:          String — force "ice" or "root"; "" = auto by card type
			#   also_archives: bool   — include Archives (corp_discard) as a source
			var iafh_max:          int    = params.get("max_installs", 1)
			var iafh_opt:          bool   = params.get("optional", false)
			var iafh_zone:         String = params.get("zone", "")
			var iafh_also_arch:    bool   = params.get("also_archives", false)

			for _iafh_i in range(iafh_max):
				# Build combined candidate list
				var iafh_candidates: Array = []
				for iafh_hq_entry in ctx.corp_hand:
					var iafh_hq_e: Dictionary = iafh_hq_entry as Dictionary
					iafh_candidates.append({
						"card_id":     iafh_hq_e.get("card_id", ""),
						"card_record": iafh_hq_e.get("card_record", null),
						"_zone":       "hq",
						"_hq_entry":   iafh_hq_e
					})
				if iafh_also_arch:
					for iafh_arch_r in ctx.corp_discard:
						var iafh_arch_rec: CardRecord = iafh_arch_r as CardRecord
						if iafh_arch_rec != null:
							iafh_candidates.append({
								"card_id":     iafh_arch_rec.id,
								"card_record": iafh_arch_rec,
								"_zone":       "archives"
							})

				if iafh_candidates.is_empty():
					var iafh_src: String = "HQ or Archives" if iafh_also_arch else "HQ"
					ctx.send_log("%s has no cards in %s to install." % [ctx.corp_name(), iafh_src])
					break

				var iafh_dm: Object = ctx.corp_decision_maker
				var iafh_chosen: Variant = null
				if iafh_dm != null and iafh_dm.has_method("choose_card_from_hand"):
					iafh_chosen = await iafh_dm.choose_card_from_hand(iafh_candidates, ctx)
				elif not iafh_opt:
					iafh_chosen = iafh_candidates[0]
				if iafh_chosen == null:
					break   # Corp declined

				var iafh_chosen_d: Dictionary = iafh_chosen as Dictionary
				var iafh_record: CardRecord   = iafh_chosen_d.get("card_record", null) as CardRecord
				var iafh_src_zone: String     = iafh_chosen_d.get("_zone", "hq")
				if iafh_record == null:
					break

				# Remove from source zone
				if iafh_src_zone == "hq":
					var iafh_hq_entry: Dictionary = iafh_chosen_d.get("_hq_entry", {}) as Dictionary
					ctx.corp_hand.erase(iafh_hq_entry)
				else:
					ctx.corp_discard.erase(iafh_record)

				# Determine target server
				var iafh_server: Server = null
				if ctx.run_active and ctx.run_target_server != "":
					iafh_server = ctx.get_server(ctx.run_target_server)
				if iafh_server == null:
					iafh_server = ctx.create_remote_server()

				var iafh_z: String = iafh_zone
				if iafh_z == "":
					iafh_z = "ice" if iafh_record.is_ice() else "root"
				var iafh_installed := _install_corp_card(iafh_record, iafh_server, iafh_z, false)
				ctx.corp_installed_this_turn.append(iafh_record.id)
				var iafh_src_label: String = "Archives" if iafh_src_zone == "archives" else "HQ"
				ctx.send_log("%s installs %s from %s in %s (ignoring costs)." % [
					ctx.corp_name(), iafh_record.title, iafh_src_label, iafh_server.display_name()
				])

		# ── Empiricist / Syailendra: place advancement counter on installed ───

		"place_advancement_on_installed":
			# Corp places advancement counters on a chosen advanceable installed card.
			# optional: true means the Corp may skip.
			var pai_amount: int  = params.get("amount", 1)
			var pai_opt: bool    = params.get("optional", true)
			# Collect all advanceable cards (server roots + advanceable ice)
			var pai_pool: Array = []
			for pai_server in ctx.servers.values():
				var pai_s: Server = pai_server as Server
				for pai_root in pai_s.root:
					var pai_c: InstalledCard = pai_root as InstalledCard
					if pai_c.can_be_advanced():
						pai_pool.append(pai_c)
				for pai_ice in pai_s.ice:
					var pai_ic: InstalledCard = pai_ice as InstalledCard
					if pai_ic.can_be_advanced():
						pai_pool.append(pai_ic)
			if pai_pool.is_empty():
				ctx.send_log("No advanceable targets available for advancement counter.")
				return
			var pai_dm: Object = ctx.corp_decision_maker
			var pai_target: InstalledCard = null
			if pai_opt:
				# Optional: AI chooses (null = decline)
				if pai_dm != null and pai_dm.has_method("choose_target"):
					pai_target = await pai_dm.choose_target(pai_pool, {"reason": "advance_optional"})
			else:
				if pai_dm != null and pai_dm.has_method("choose_target"):
					pai_target = await pai_dm.choose_target(pai_pool, {"reason": "advance_required"})
				else:
					pai_target = pai_pool[0]
			if pai_target != null:
				pai_target.add_counter("advancement", pai_amount)
				ctx.send_log("%s places %d advancement counter(s) on %s." % [
					ctx.corp_name(), pai_amount, pai_target.display_name()
				])

		# ── Empiricist sub 1: add card from HQ to top of R&D ─────────────────

		"return_card_to_top_from_hand":
			# Corp (or runner) optionally returns a card from hand to top of deck.
			var rct_subject: String = params.get("subject", "corp")
			var rct_opt: bool       = params.get("optional", true)
			var rct_hand: Array = ctx.corp_hand if rct_subject == "corp" else ctx.runner_hand
			var rct_deck: Array = ctx.corp_deck if rct_subject == "corp" else ctx.runner_deck
			if rct_hand.is_empty():
				return
			var rct_dm: Object = ctx.corp_decision_maker if rct_subject == "corp" else ctx.runner_decision_maker
			var rct_entry: Variant = null
			if rct_dm != null and rct_dm.has_method("choose_card_from_hand"):
				rct_entry = await rct_dm.choose_card_from_hand(rct_hand, ctx)
			elif not rct_opt:
				rct_entry = rct_hand[0]
			if rct_entry == null:
				return   # Declined
			rct_hand.erase(rct_entry)
			var rct_record: CardRecord = (rct_entry as Dictionary).get("card_record", null) as CardRecord
			if rct_record != null:
				rct_deck.push_front(rct_record)
				ctx.send_log("%s adds %s to the top of their deck." % [ctx.player_name(rct_subject), rct_record.title])

		# ── Recurring credits: refill to max at start of turn ────────────────

		"refill_recurring_credits":
			# Refill the owning card's recurring credit counter to the specified maximum.
			# Used by Azimat (runner_turn_start, max 2) and Mahkota Langit Grid (corp_turn_start, max 2).
			# Only tops up; does not overfill. No-ops if already at max.
			var rrc_counter: String = effect.get("counter", params.get("counter", "recurring_credits"))
			var rrc_max: int        = int(effect.get("max", params.get("max", 2)))
			var rrc_card := _get_self_card(ctx)
			if rrc_card != null:
				var rrc_current: int = rrc_card.get_counter(rrc_counter)
				if rrc_current < rrc_max:
					rrc_card.add_counter(rrc_counter, rrc_max - rrc_current)
					ctx.send_log("%s: %s refilled to %d." % [rrc_card.display_name(), rrc_counter, rrc_max])

		# ── Install ice from HQ with fallback outside runs ────────────────────
		# (Extends existing install_ice_from_hq to work outside run context)

		"install_ice_from_hq_any_server":
			# Like install_ice_from_hq but also works outside of runs.
			# Corp chooses ice from HQ and a server to install it on.
			# params: { optional: bool, exclude_run_server: bool }
			#   exclude_run_server: true → cannot install on the currently attacked server
			#   (used by Tributary sub 1: "another server")
			var iifha_exclude_run: bool = params.get("exclude_run_server", false)
			var iifha_candidates: Array = []
			for iifha_entry in ctx.corp_hand:
				var iifha_e: Dictionary = iifha_entry as Dictionary
				var iifha_r: CardRecord = iifha_e.get("card_record", null) as CardRecord
				if iifha_r != null and iifha_r.is_ice():
					iifha_candidates.append(iifha_entry)
			if iifha_candidates.is_empty():
				ctx.send_log("%s has no ice in HQ to install." % ctx.corp_name())
			else:
				var iifha_dm: Object = ctx.corp_decision_maker
				var iifha_chosen: Variant = null
				if iifha_dm != null and iifha_dm.has_method("choose_card_from_hand"):
					iifha_chosen = await iifha_dm.choose_card_from_hand(iifha_candidates, ctx)
				else:
					iifha_chosen = iifha_candidates[0]
				if iifha_chosen != null:
					var iifha_record: CardRecord = (iifha_chosen as Dictionary).get("card_record", null) as CardRecord
					if iifha_record != null:
						ctx.corp_hand.erase(iifha_chosen)
						# Choose destination server.
						# If exclude_run_server, pick any server other than the run target.
						var iifha_server: Server = null
						if not iifha_exclude_run and ctx.run_active and ctx.run_target_server != "":
							iifha_server = ctx.get_server(ctx.run_target_server)
						if iifha_server == null:
							# Find any existing server (excluding run target if requested).
							for iifha_srv in ctx.servers.values():
								var iifha_s: Server = iifha_srv as Server
								if iifha_s != null and (not iifha_exclude_run or iifha_s.server_id != ctx.run_target_server):
									iifha_server = iifha_s
									break
						if iifha_server == null:
							iifha_server = ctx.create_remote_server()
						var iifha_inst := InstalledCard.make_runtime_instance(
							iifha_record, iifha_server.server_id, "ice", false
						)
						iifha_server.install_ice(iifha_inst)
						ctx.send_log("%s installs %s from HQ on %s (ignoring costs)." % [
							ctx.corp_name(), iifha_record.title, iifha_server.display_name()
						])

		# ── Dividends mechanic ────────────────────────────────────────────────────

		"place_dividend_counters":
			# On-score effect for Dividends agendas.
			# Reads "dividends" (printed N) from the effect definition and
			# "excess_advancement" from current_event_data, then places
			# (dividends + excess) "agenda" counters on the just-scored card.
			var dividends: int  = int(effect.get("dividends", 0))
			var iid: String     = ctx.current_event_data.get("card_instance_id", "")
			var excess: int     = ctx.current_event_data.get("excess_advancement", 0) as int
			var total: int      = dividends + excess
			if total <= 0:
				return
			var scored_card := ctx.get_installed_card_by_instance_id(iid)
			if scored_card == null:
				push_error("AbilityInterpreter: place_dividend_counters — cannot find scored card '%s'" % iid)
				return
			scored_card.add_counter("agenda", total)
			ctx.send_log("%s places %d agenda counter(s) on %s (Dividends %d + %d excess)." % [
				ctx.corp_name(), total, scored_card.display_name(), dividends, excess
			])

		"spend_agenda_counter":
			# Prerequisite effect for Dividends click actions.
			# Removes 1 "agenda" counter from the scored card that owns this ability.
			# Aborts the remaining effects if no counter is available.
			# Searches both Corp and Runner score areas (for Next Big Thing in runner area).
			var iid: String = ctx.current_event_data.get("card_instance_id", "")
			var scored_card := ctx.get_scored_agenda_by_instance_id(iid)
			if scored_card == null:
				scored_card = ctx.get_installed_card_by_instance_id(iid)
			if scored_card == null:
				ctx.send_log("spend_agenda_counter: scored agenda not found.")
				return
			var available: int = scored_card.get_counter("agenda")
			if available <= 0:
				ctx.send_log("%s has no agenda counters to spend." % scored_card.display_name())
				return
			scored_card.remove_counter("agenda", 1)
			ctx.send_log("%s spends 1 agenda counter from %s (%d remaining)." % [
				ctx.corp_name(), scored_card.display_name(), scored_card.get_counter("agenda")
			])

		"install_from_archives_free":
			# Dividends payout — Project Ingatan.
			# Corp chooses any card from Archives (corp_discard) and installs it
			# on a new remote server, ignoring all costs.
			if ctx.corp_discard.is_empty():
				ctx.send_log("%s: Archives is empty — nothing to install." % ctx.corp_name())
				return
			var ifa_candidates: Array = []
			for ifa_r in ctx.corp_discard:
				var ifa_record: CardRecord = ifa_r as CardRecord
				if ifa_record == null:
					continue
				# Only cards that can be installed (not operations/events)
				var ct: String = ifa_record.card_type
				if ct in ["ice", "agenda", "asset", "upgrade"]:
					ifa_candidates.append({"card_id": ifa_record.id, "card_record": ifa_record})
			if ifa_candidates.is_empty():
				ctx.send_log("%s: Archives has no installable cards." % ctx.corp_name())
				return
			var ifa_dm: Object = ctx.corp_decision_maker
			var ifa_entry: Variant = null
			if ifa_dm != null and ifa_dm.has_method("choose_card_from_hand"):
				ifa_entry = await ifa_dm.choose_card_from_hand(ifa_candidates, ctx)
			else:
				ifa_entry = ifa_candidates[0]
			if ifa_entry == null:
				return
			var ifa_record: CardRecord = (ifa_entry as Dictionary).get("card_record", null) as CardRecord
			if ifa_record == null:
				return
			ctx.corp_discard.erase(ifa_record)
			var ifa_zone: String = "ice" if ifa_record.is_ice() else "root"
			var ifa_server: Server = ctx.create_remote_server()
			var ifa_installed := _install_corp_card(ifa_record, ifa_server, ifa_zone, false)
			ctx.send_log("%s installs %s from Archives on %s (ignoring costs)." % [
				ctx.corp_name(), ifa_record.title, ifa_server.display_name()
			])

		"install_from_archives_filtered":
			# Install 1 card of given types from Archives (free, Corp chooses server).
			# Like install_from_archives_free but with a type filter and server choice.
			# params: { card_types: Array }  default: all installable types
			var ifaf_types: Array = params.get("card_types", ["ice", "agenda", "asset", "upgrade"]) as Array
			var ifaf_candidates: Array = []
			for ifaf_r in ctx.corp_discard:
				var ifaf_record: CardRecord = ifaf_r as CardRecord
				if ifaf_record == null:
					continue
				if ifaf_types.has(ifaf_record.card_type):
					ifaf_candidates.append({"card_id": ifaf_record.id, "card_record": ifaf_record})
			if ifaf_candidates.is_empty():
				ctx.send_log("%s: Archives has no installable cards of the required type." % ctx.corp_name())
				return
			var ifaf_dm: Object = ctx.corp_decision_maker
			var ifaf_entry: Variant = null
			if ifaf_dm != null and ifaf_dm.has_method("choose_card_from_hand"):
				ifaf_entry = await ifaf_dm.choose_card_from_hand(ifaf_candidates, ctx)
			else:
				ifaf_entry = ifaf_candidates[0]
			if ifaf_entry == null:
				return
			var ifaf_record: CardRecord = (ifaf_entry as Dictionary).get("card_record", null) as CardRecord
			if ifaf_record == null:
				return
			ctx.corp_discard.erase(ifaf_record)
			var ifaf_zone: String = "ice" if ifaf_record.is_ice() else "root"
			# Choose target server (AI picks most defended existing remote or creates new one)
			var ifaf_server: Server = null
			if ifaf_dm != null and ifaf_dm.has_method("choose_install_server"):
				ifaf_server = await ifaf_dm.choose_install_server(ifaf_record, ctx)
			if ifaf_server == null:
				ifaf_server = ctx.create_remote_server()
			var ifaf_installed := _install_corp_card(ifaf_record, ifaf_server, ifaf_zone, false)
			ctx.corp_installed_this_turn.append(ifaf_record.id)
			ctx.send_log("%s installs %s from Archives on %s." % [
				ctx.corp_name(), ifaf_record.title, ifaf_server.display_name()])

		"install_and_rez_from_archives_discounted":
			# Reanimation Protocol: install and rez 1 ice from Archives, paying 10cr less.
			# If the rezzed ice is not a Liability subtype, Corp takes 1 bad pub.
			# params: { discount: int }  (default 10)
			var iara_discount: int = params.get("discount", 10)
			var iara_candidates: Array = []
			for iara_r in ctx.corp_discard:
				var iara_record: CardRecord = iara_r as CardRecord
				if iara_record != null and iara_record.is_ice():
					iara_candidates.append({"card_id": iara_record.id, "card_record": iara_record})
			if iara_candidates.is_empty():
				ctx.send_log("%s: no ice in Archives to install." % ctx.corp_name())
				return
			var iara_dm: Object = ctx.corp_decision_maker
			var iara_entry: Variant = null
			if iara_dm != null and iara_dm.has_method("choose_card_from_hand"):
				iara_entry = await iara_dm.choose_card_from_hand(iara_candidates, ctx)
			else:
				iara_entry = iara_candidates[0]
			if iara_entry == null:
				return
			var iara_record: CardRecord = (iara_entry as Dictionary).get("card_record", null) as CardRecord
			if iara_record == null:
				return
			# Compute discounted rez cost
			var iara_rez_cost: int = max(0, max(0, iara_record.cost) - iara_discount)
			if ctx.corp_credits < iara_rez_cost:
				ctx.send_log("%s cannot afford to rez %s (%d cr after discount, have %d)." % [
					ctx.corp_name(), iara_record.title, iara_rez_cost, ctx.corp_credits])
				return
			ctx.corp_discard.erase(iara_record)
			# Choose server
			var iara_server: Server = null
			if iara_dm != null and iara_dm.has_method("choose_install_server"):
				iara_server = await iara_dm.choose_install_server(iara_record, ctx)
			if iara_server == null:
				iara_server = ctx.create_remote_server()
			var iara_installed := InstalledCard.make_runtime_instance(
				iara_record, iara_server.server_id, "ice", true
			)
			iara_server.install_ice(iara_installed)
			ctx.corp_credits -= iara_rez_cost
			ctx.corp_installed_this_turn.append(iara_record.id)
			ctx.send_log("%s installs and rezzes %s from Archives for %d cr." % [
				ctx.corp_name(), iara_record.title, iara_rez_cost])
			# Bad pub if non-Liability ice
			if not iara_record.has_subtype("liability"):
				ctx.corp_bad_pub += 1
				ctx.send_log("%s takes 1 bad publicity (non-Liability ice). (%d total)" % [
					ctx.corp_name(), ctx.corp_bad_pub])

		"search_rd_to_top":
			# Dividends payout — Embedded Reporting.
			# Search R&D for a card matching the given card_type(s), then place it
			# on top of R&D.  R&D is shuffled after the chosen card is removed.
			var srtt_types: Array   = params.get("card_types", []) as Array
			var srtt_subs: Array    = params.get("subtypes",   []) as Array
			var srtt_candidates: Array = []
			for srtt_r in ctx.corp_deck:
				var srtt_record: CardRecord = srtt_r as CardRecord
				if srtt_record == null:
					continue
				var srtt_type_ok := srtt_types.is_empty() or srtt_types.has(srtt_record.card_type)
				var srtt_sub_ok  := srtt_subs.is_empty()
				if not srtt_sub_ok:
					for st in srtt_subs:
						if srtt_record.has_subtype(st):
							srtt_sub_ok = true
							break
				if srtt_type_ok and srtt_sub_ok:
					srtt_candidates.append(srtt_record)
			if srtt_candidates.is_empty():
				ctx.send_log("%s searches R&D but finds no matching card — R&D is shuffled." % ctx.corp_name())
				ctx.corp_deck.shuffle()
				return
			var srtt_dm: Object = ctx.corp_decision_maker
			var srtt_chosen: CardRecord = null
			if srtt_dm != null and srtt_dm.has_method("choose_from_search"):
				srtt_chosen = await srtt_dm.choose_from_search(srtt_candidates, ctx)
			else:
				srtt_chosen = srtt_candidates[0]
			if srtt_chosen == null:
				ctx.corp_deck.shuffle()
				return
			ctx.corp_deck.erase(srtt_chosen)
			ctx.corp_deck.shuffle()         # shuffle the remaining deck first
			ctx.corp_deck.push_front(srtt_chosen)  # then place chosen card on top
			ctx.send_log("%s searches R&D and places %s on top of R&D." % [
				ctx.corp_name(), srtt_chosen.title
			])

		"search_rd_install_free":
			# Dividends payout — Off the Books.
			# Corp searches R&D for any card and may install it ignoring all costs.
			if ctx.corp_deck.is_empty():
				ctx.send_log("%s: R&D is empty." % ctx.corp_name())
				return
			# Build candidate list (installable cards only: not operations)
			var srif_candidates: Array = []
			for srif_r in ctx.corp_deck:
				var srif_record: CardRecord = srif_r as CardRecord
				if srif_record == null:
					continue
				var srif_ct: String = srif_record.card_type
				if srif_ct in ["ice", "agenda", "asset", "upgrade"]:
					srif_candidates.append(srif_record)
			if srif_candidates.is_empty():
				ctx.send_log("%s searches R&D but finds no installable card — R&D is shuffled." % ctx.corp_name())
				ctx.corp_deck.shuffle()
				return
			var srif_dm: Object = ctx.corp_decision_maker
			var srif_chosen: CardRecord = null
			if srif_dm != null and srif_dm.has_method("choose_from_search"):
				srif_chosen = await srif_dm.choose_from_search(srif_candidates, ctx)
			else:
				srif_chosen = srif_candidates[0]
			if srif_chosen == null:
				ctx.corp_deck.shuffle()
				return
			ctx.corp_deck.erase(srif_chosen)
			ctx.corp_deck.shuffle()
			var srif_zone: String = "ice" if srif_chosen.is_ice() else "root"
			var srif_server: Server = ctx.create_remote_server()
			var srif_installed := _install_corp_card(srif_chosen, srif_server, srif_zone, false)
			ctx.send_log("%s searches R&D and installs %s on %s (ignoring costs)." % [
				ctx.corp_name(), srif_chosen.title, srif_server.display_name()
			])

		# ── NBN: tag-related effects ──────────────────────────────────────────────

		"give_tags_if_agenda_stolen_this_run":
			# AMAZE Amusements: whenever a run on THIS card's server ends, if the Runner
			# stole an agenda during that run, give the Runner N tags.
			if not ctx.runner_stole_agenda_this_run:
				return
			var run_server: String = ctx.current_event_data.get("server_id", "")
			var amaze_card := _get_self_card(ctx)
			if amaze_card == null or amaze_card.server_id != run_server:
				return   # run was on a different server
			if not amaze_card.is_rezzed:
				return   # must be rezzed to trigger
			var amaze_amount: int = params.get("amount", 2)
			var _amaze_was_zero: bool = (ctx.runner_tags == 0)
			ctx.runner_tags += amaze_amount
			ctx.send_log("AMAZE Amusements: %s takes %d tag(s) (agenda stolen this run). (%d total)" % [
				ctx.runner_name(), amaze_amount, ctx.runner_tags
			])
			await ctx.notify_event("runner_takes_tags", {"amount": amaze_amount, "from_zero": _amaze_was_zero}, self)

		"runner_must_take_tag_or_end_run":
			# Funhouse encounter_ice: the Runner must take N tags or end the run.
			# If the Runner decision maker has no preference, default to taking the tag.
			var rmt_amount: int = params.get("amount", 1)
			var rmt_end_run := false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_take_tag_or_end_run"):
				rmt_end_run = await ctx.runner_decision_maker.choose_take_tag_or_end_run(rmt_amount, ctx)
			if rmt_end_run:
				ctx.run_ended = true
				ctx.send_log("%s ends the run to avoid %d tag(s) (Funhouse)." % [ctx.runner_name(), rmt_amount])
			else:
				var _rmt_was_zero: bool = (ctx.runner_tags == 0)
				ctx.runner_tags += rmt_amount
				ctx.send_log("%s takes %d tag(s) to continue the run (Funhouse). (%d total)" % [
					ctx.runner_name(), rmt_amount, ctx.runner_tags
				])
				await ctx.notify_event("runner_takes_tags", {"amount": rmt_amount, "from_zero": _rmt_was_zero}, self)

		"give_tag_unless_runner_pays":
			# Give the Runner 1 tag unless they pay cost credits.
			# Used by Funhouse subroutine (cost 4) and Public Trail (cost 8).
			var gtup_cost: int = params.get("cost", 4)
			var gtup_pays := false
			if ctx.runner_credits >= gtup_cost and ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_pay_to_avoid_tag"):
				gtup_pays = await ctx.runner_decision_maker.choose_pay_to_avoid_tag(gtup_cost, ctx)
			if gtup_pays:
				ctx.runner_credits -= gtup_cost
				ctx.send_log("%s pays %d cr to avoid 1 tag." % [ctx.runner_name(), gtup_cost])
			else:
				var _gtup_was_zero: bool = (ctx.runner_tags == 0)
				ctx.runner_tags += 1
				ctx.send_log("%s takes 1 tag (did not pay %d cr). (%d total)" % [
					ctx.runner_name(), gtup_cost, ctx.runner_tags
				])
				await ctx.notify_event("runner_takes_tags", {"amount": 1, "from_zero": _gtup_was_zero}, self)

		"deal_damage_unless_runner_pays":
			# Corp operation effect (e.g. Measured Response): do N damage unless the
			# Runner pays M credits to prevent it.
			# params: { damage_type, damage, cost }
			var ddup_type:   String = params.get("damage_type", "meat")
			var ddup_damage: int    = params.get("damage", 0)
			var ddup_cost:   int    = params.get("cost", 0)
			var ddup_pays := false
			if ctx.runner_credits >= ddup_cost and ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_pay_to_avoid_damage"):
				ddup_pays = await ctx.runner_decision_maker.choose_pay_to_avoid_damage(
					ddup_cost, ddup_damage, ddup_type, ctx
				)
			if ddup_pays:
				ctx.runner_credits -= ddup_cost
				ctx.send_log("%s pays %d cr to avoid %d %s damage." % [
					ctx.runner_name(), ddup_cost, ddup_damage, ddup_type
				])
			else:
				ctx.send_log("%s takes %d %s damage (did not pay %d cr)." % [
					ctx.runner_name(), ddup_damage, ddup_type, ddup_cost
				])
				await _deal_damage(ddup_type, ddup_damage, ctx)

		"deal_damage_unless_jack_out":
			# Runner takes N damage unless they jack out.  If they jack out the run ends.
			# Used by: Lionsmane sub 3.
			# params: { damage_type: "net"|"meat"|"core", damage: int }
			var ddjo_type:   String = params.get("damage_type", "net")
			var ddjo_damage: int    = params.get("damage", 2)
			var ddjo_jack := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_jack_out"):
				ddjo_jack = await ctx.runner_decision_maker.choose_jack_out(ctx)
			if ddjo_jack:
				ctx.send_log("%s jacks out to avoid %d %s damage." % [
					ctx.runner_name(), ddjo_damage, ddjo_type])
				ctx.run_ended = true
			else:
				await _deal_damage(ddjo_type, ddjo_damage, ctx)

		"x_net_damage_and_x_tags_by_runner_tags":
			# Do X net damage and give X tags, where X is the Runner's current tag count.
			# Used by: Vicsek sub 1.
			var xdt_x: int = ctx.runner_tags
			if xdt_x <= 0:
				ctx.send_log("Vicsek: Runner has no tags — no damage or tags given.")
				return
			await _deal_damage("net", xdt_x, ctx)
			if not ctx.game_over:
				var _xdt_was_zero: bool = (ctx.runner_tags == 0)
				ctx.runner_tags += xdt_x
				ctx.send_log("%s takes %d tag(s). (%d total)" % [ctx.runner_name(), xdt_x, ctx.runner_tags])
				await ctx.notify_event("runner_takes_tags", {"amount": xdt_x, "from_zero": _xdt_was_zero}, self)

		"trash_runner_program_unless_pay":
			# Runner must trash 1 installed program or pay N credits to avoid it.
			# Used by: Event Horizon sub 1.
			# params: { cost: int }
			var trpp_cost: int = params.get("cost", 3)
			var trpp_programs: Array = ctx.runner_rig.filter(
				func(c: InstalledCard): return c.card_record != null and c.card_record.card_type == "program"
			)
			if trpp_programs.is_empty():
				ctx.send_log("%s has no installed programs — subroutine has no effect." % ctx.runner_name())
				return
			# Can the runner afford to pay?
			var trpp_can_pay: bool = ctx.runner_available_credits() >= trpp_cost
			var trpp_pay := false
			if trpp_can_pay and ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_pay_to_avoid_damage"):
				trpp_pay = await ctx.runner_decision_maker.choose_pay_to_avoid_damage(
					trpp_cost, 0, "trash_program", ctx
				)
			if trpp_pay:
				ctx.runner_credits -= trpp_cost
				ctx.send_log("%s pays %d cr to keep programs." % [ctx.runner_name(), trpp_cost])
			else:
				var trpp_dm: Object = ctx.runner_decision_maker
				var trpp_target: InstalledCard = null
				if trpp_dm != null and trpp_dm.has_method("choose_target"):
					trpp_target = await trpp_dm.choose_target(trpp_programs, {"reason": "trash_program"})
				else:
					trpp_target = trpp_programs[0] as InstalledCard
				if trpp_target != null:
					ctx.runner_rig.erase(trpp_target)
					ctx.unregister_all_card_effects(trpp_target.runtime_instance_id)
					if trpp_target.card_record != null:
						ctx.runner_discard.append(trpp_target.card_record)
					ctx.send_log("%s trashes %s." % [ctx.runner_name(), trpp_target.display_name()])

		# ── Byte: Corp may pay N cr to give tag(s) + net damage on access ───────────

		"corp_optional_pay_tag_and_damage":
			# Byte on_access: Corp may pay cost credits to give the Runner tags and net damage.
			# Skips silently if Corp cannot afford the cost.
			var copd_cost:   int    = params.get("cost", 4)
			var copd_tags:   int    = params.get("tags", 1)
			var copd_damage: int    = params.get("damage", 3)
			var copd_dtype:  String = params.get("damage_type", "net")

			if ctx.corp_credits < copd_cost:
				ctx.send_log("Byte: %s cannot afford to activate (%d cr needed, %d available)." % [
					ctx.corp_name(), copd_cost, ctx.corp_credits
				])
				return

			# Corp decides whether to pay
			var copd_pay := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var copd_modes: Array = [
					{"label": "Byte: pay %d cr — %s takes %d tag(s) + %d %s damage" % [
						copd_cost, ctx.runner_name(), copd_tags, copd_damage, copd_dtype]},
					{"label": "Pass"}
				]
				var copd_chosen: Array = await ctx.corp_decision_maker.choose_modes(copd_modes, 1, ctx)
				copd_pay = (not copd_chosen.is_empty() and copd_chosen[0] == 0)
			else:
				# Fallback AI: activate if it would flatline or if runner is untagged
				copd_pay = copd_damage >= ctx.runner_hand.size() or ctx.runner_tags == 0

			if not copd_pay:
				ctx.send_log("Byte: %s passes." % ctx.corp_name())
				return

			ctx.corp_credits -= copd_cost
			ctx.send_log("Byte: %s pays %d cr." % [ctx.corp_name(), copd_cost])
			var _copd_was_zero: bool = (ctx.runner_tags == 0)
			ctx.runner_tags += copd_tags
			ctx.send_log("Byte: %s takes %d tag(s). (%d total)" % [
				ctx.runner_name(), copd_tags, ctx.runner_tags
			])
			await ctx.notify_event("runner_takes_tags", {"amount": copd_tags, "from_zero": _copd_was_zero}, self)
			await _deal_damage(copd_dtype, copd_damage, ctx)

		# ── Urtica Cipher: Corp may pay 2cr on access to deal net damage ──────────

		"urtica_cipher_trigger":
			# Urtica Cipher on_access: Corp may pay 2 credits. If they do, the Runner
			# takes net damage equal to 2 plus the number of hosted advancement counters.
			var uc_cost: int = 2
			var uc_card: InstalledCard = ctx.current_event_data.get("card", null) as InstalledCard
			var uc_adv:  int = uc_card.get_counter("advancement") if uc_card != null else 0
			var uc_damage: int = 2 + uc_adv

			if ctx.corp_credits < uc_cost:
				ctx.send_log("Urtica Cipher: %s cannot afford to activate (2 cr needed, %d available)." % [
					ctx.corp_name(), ctx.corp_credits
				])
				return

			# Corp decides whether to pay
			var uc_pay := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var uc_modes: Array = [
					{"label": "Urtica Cipher: pay 2 cr — %s takes %d net damage (%d base + %d adv)" % [
						ctx.runner_name(), uc_damage, 2, uc_adv]},
					{"label": "Pass"}
				]
				var uc_chosen: Array = await ctx.corp_decision_maker.choose_modes(uc_modes, 1, ctx)
				uc_pay = (not uc_chosen.is_empty() and uc_chosen[0] == 0)
			else:
				# AI fallback: activate if it could flatline the runner
				uc_pay = uc_damage >= ctx.runner_hand.size()

			if not uc_pay:
				ctx.send_log("Urtica Cipher: %s passes." % ctx.corp_name())
				return

			ctx.corp_credits -= uc_cost
			ctx.send_log("Urtica Cipher: %s pays 2 cr." % ctx.corp_name())
			ctx.send_log("Urtica Cipher: dealing %d net damage (%d base + %d advancement)." % [
				uc_damage, 2, uc_adv
			])
			await _deal_damage("net", uc_damage, ctx)

		"reality_plus_trigger":
			# NBN: Reality Plus identity — the first time each turn the Runner takes a
			# tag, the Corp gains 2 credits or draws 2 cards (Corp's choice).
			if ctx.corp_used_reality_plus_this_turn:
				return
			ctx.corp_used_reality_plus_this_turn = true
			ctx.send_log("NBN: Reality Plus — %s may gain 2 cr or draw 2 cards." % ctx.corp_name())
			var rp_modes: Array = [
				{
					"label": "Gain 2 credits",
					"effects": [{"type": "gain_credits", "params": {"subject": "corp", "amount": 2}}]
				},
				{
					"label": "Draw 2 cards",
					"effects": [{"type": "draw_cards", "params": {"subject": "corp", "amount": 2}}]
				}
			]
			var rp_idx := 0
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var rp_chosen: Array = await ctx.corp_decision_maker.choose_modes(rp_modes, 1, ctx)
				if not rp_chosen.is_empty():
					rp_idx = rp_chosen[0]
			var rp_mode: Dictionary = rp_modes[rp_idx] as Dictionary
			ctx.send_log("Reality Plus: %s chooses '%s'." % [ctx.corp_name(), rp_mode.get("label", "")])
			for rp_eff in rp_mode.get("effects", []) as Array:
				await _execute_effect(rp_eff as Dictionary, ctx, null)

		# ── Stealth credits ──────────────────────────────────────────────────────

		"place_stealth_credits":
			# Place stealth credits on this card (triggered on install or at start of turn).
			# params:  amount: int
			var psc_amount: int = params.get("amount", 1)
			var psc_card := _get_self_card(ctx)
			if psc_card == null:
				push_error("AbilityInterpreter: place_stealth_credits — self card not found.")
				return
			psc_card.add_counter("stealth_credits", psc_amount)
			ctx.send_log("%s: +%d stealth credit(s) (%d total)." % [
				psc_card.display_name(), psc_amount, psc_card.get_counter("stealth_credits")
			])

		"add_run_stealth_credits":
			# Add transient stealth credits to run_modifiers (consumed first, gone after the run).
			# params:  amount: int
			var arsc_amount: int = params.get("amount", 0)
			ctx.run_modifiers["stealth_credits"] = \
				ctx.run_modifiers.get("stealth_credits", 0) + arsc_amount
			ctx.send_log("Placed %d stealth credit(s) for this run." % arsc_amount)

		"trash_hardware_from_grip_for_stealth":
			# Runner optionally trashes 1 hardware from grip to place N stealth credits on this card.
			# Used by: VP19 Methuselah run_start trigger.
			var thgfs_amount: int = params.get("amount", 2)
			var thgfs_card := _get_self_card(ctx)
			if thgfs_card == null:
				push_error("AbilityInterpreter: trash_hardware_from_grip_for_stealth — card not found")
				return
			# Collect hardware entries from the runner's grip
			var thgfs_options: Array = []
			for thgfs_entry in ctx.runner_hand:
				var thgfs_dict: Dictionary = thgfs_entry as Dictionary
				var thgfs_rec: CardRecord  = thgfs_dict.get("card_record", null) as CardRecord
				if thgfs_rec != null and thgfs_rec.card_type == "hardware":
					thgfs_options.append(thgfs_dict)
			if thgfs_options.is_empty():
				return  # no hardware to offer; silently do nothing
			# Ask the runner if they want to trash a hardware (optional ability)
			var thgfs_chosen: Dictionary = {}
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_hardware_from_grip_to_trash"):
				thgfs_chosen = await ctx.runner_decision_maker.choose_hardware_from_grip_to_trash(
					thgfs_options, ctx)
			else:
				thgfs_chosen = thgfs_options[0]   # AI default: trash first hardware
			if thgfs_chosen.is_empty():
				return  # player declined
			var thgfs_trashed: CardRecord = thgfs_chosen.get("card_record", null) as CardRecord
			if thgfs_trashed == null:
				return
			ctx.runner_hand.erase(thgfs_chosen)
			ctx.runner_discard.append(thgfs_trashed)
			thgfs_card.add_counter("stealth_credits", thgfs_amount)
			ctx.send_log("%s: trashes %s from grip — +%d stealth cr (%d total)." % [
				thgfs_card.display_name(), thgfs_trashed.title,
				thgfs_amount, thgfs_card.get_counter("stealth_credits")
			])
			# VP17 Hiram: runner trashing hardware from grip (any location) triggers look-at-R&D
			await ctx.notify_event("hardware_trashed", {
				"card_id": thgfs_trashed.id, "source": "runner", "from_grip": true
			}, self)

		# ── Corp card management ──────────────────────────────────────────────────

		"shuffle_hq_or_archives_card_to_rd":
			# Corp may shuffle 1 card from HQ or Archives into R&D.
			# Used by: Sleipnir sub 2.
			var shoa_candidates: Array = []
			for shoa_entry in ctx.corp_hand:
				var shoa_e: Dictionary = shoa_entry as Dictionary
				var shoa_r: CardRecord = shoa_e.get("card_record", null) as CardRecord
				if shoa_r != null:
					shoa_candidates.append({"card_id": shoa_r.id, "card_record": shoa_r, "_zone": "hq", "_entry": shoa_e})
			for shoa_r in ctx.corp_discard:
				var shoa_record: CardRecord = shoa_r as CardRecord
				if shoa_record != null:
					shoa_candidates.append({"card_id": shoa_record.id, "card_record": shoa_record, "_zone": "archives"})
			if shoa_candidates.is_empty():
				ctx.send_log("HQ and Archives are empty — nothing to shuffle into R&D.")
				return
			var shoa_dm: Object = ctx.corp_decision_maker
			var shoa_chosen: Variant = null
			if shoa_dm != null and shoa_dm.has_method("choose_card_from_hand"):
				shoa_chosen = await shoa_dm.choose_card_from_hand(shoa_candidates, ctx)
			else:
				shoa_chosen = shoa_candidates[0]
			if shoa_chosen == null:
				return
			var shoa_chosen_d: Dictionary = shoa_chosen as Dictionary
			var shoa_record: CardRecord   = shoa_chosen_d.get("card_record", null) as CardRecord
			var shoa_zone: String         = shoa_chosen_d.get("_zone", "hq")
			if shoa_record == null:
				return
			if shoa_zone == "hq":
				var shoa_entry: Dictionary = shoa_chosen_d.get("_entry", {}) as Dictionary
				ctx.corp_hand.erase(shoa_entry)
			else:
				ctx.corp_discard.erase(shoa_record)
			# Insert at a random position in R&D (shuffle effect)
			var shoa_pos: int = randi() % (ctx.corp_deck.size() + 1)
			ctx.corp_deck.insert(shoa_pos, shoa_record)
			ctx.send_log("%s shuffles %s from %s into R&D." % [
				ctx.corp_name(), shoa_record.title, "HQ" if shoa_zone == "hq" else "Archives"])

		# ── RWR The Holo Man: move self to another server's root ────────────────

		"may_move_self_to_server_root":
			# Corp may move this installed upgrade to the root of a different server.
			# Used by: The Holo Man (corp_turn_start trigger).
			# params: { optional: bool }
			var mms_optional: bool = params.get("optional", true)
			var mms_self := _get_self_card(ctx)
			if mms_self == null:
				push_error("AbilityInterpreter: may_move_self_to_server_root — no self card in context")
				return

			# Must currently be installed in a server root.
			var mms_src: Server = ctx.get_server(mms_self.server_id)
			if mms_src == null:
				ctx.send_log("%s: not in a server — cannot move." % mms_self.display_name())
				return

			# Need at least one other valid destination.
			var mms_destinations: Array = []
			for mms_srv in ctx.servers.values():
				var mms_s: Server = mms_srv as Server
				if mms_s != null and mms_s.server_id != mms_src.server_id:
					mms_destinations.append(mms_s)

			if mms_destinations.is_empty():
				ctx.send_log("%s: no other server to move to." % mms_self.display_name())
				return

			# Optional: ask Corp DM whether to use the ability.
			if mms_optional:
				var mms_want: bool = false
				var mms_dm: Object = ctx.corp_decision_maker
				if ctx.simulation_mode:
					# AI: move to an existing remote that has a card in root (more useful position).
					for mms_cand in mms_destinations:
						if not (mms_cand as Server).root.is_empty():
							mms_want = true
							break
				elif mms_dm != null and mms_dm.has_method("choose_optional_ability"):
					mms_want = await mms_dm.choose_optional_ability(
						"Move %s to another server's root?" % mms_self.display_name(), ctx)
				if not mms_want:
					ctx.send_log("%s: %s declines to move." % [ctx.corp_name(), mms_self.display_name()])
					return

			# Choose destination server.
			var mms_dest: Server = null
			var mms_dm2: Object = ctx.corp_decision_maker
			if not ctx.simulation_mode and mms_dm2 != null and mms_dm2.has_method("choose_server"):
				mms_dest = await mms_dm2.choose_server(ctx, {"exclude": mms_src.server_id})
			if mms_dest == null or mms_dest.server_id == mms_src.server_id:
				# AI / fallback: prefer a remote with cards in root; otherwise first available.
				for mms_s3 in mms_destinations:
					var mms_srv3: Server = mms_s3 as Server
					if not mms_srv3.root.is_empty():
						mms_dest = mms_srv3
						break
				if mms_dest == null:
					mms_dest = mms_destinations[0] as Server

			# Execute the move.
			mms_src.remove_from_root(mms_self)
			ctx.remove_empty_remote_servers()
			mms_dest.install_in_root(mms_self)   # updates server_id and zone on the card

			ctx.send_log("%s: %s moves from %s to %s." % [
				ctx.corp_name(), mms_self.display_name(),
				mms_src.display_name(), mms_dest.display_name()])

		"move_rezzed_upgrade_to_server":
			# Corp moves 1 rezzed upgrade to the root of another server.
			# Used by: Lotus Haze agenda counter ability.
			var mrus_candidates: Array = []
			for mrus_srv in ctx.servers.values():
				var mrus_s: Server = mrus_srv as Server
				for mrus_root in mrus_s.root:
					var mrus_c: InstalledCard = mrus_root as InstalledCard
					if mrus_c != null and mrus_c.is_rezzed and \
							mrus_c.card_record != null and mrus_c.card_record.card_type == "upgrade":
						mrus_candidates.append(mrus_c)
			if mrus_candidates.is_empty():
				ctx.send_log("No rezzed upgrades to move.")
				return
			var mrus_dm: Object = ctx.corp_decision_maker
			var mrus_target: InstalledCard = null
			if mrus_dm != null and mrus_dm.has_method("choose_target"):
				mrus_target = await mrus_dm.choose_target(mrus_candidates, {"reason": "move_upgrade"})
			else:
				mrus_target = mrus_candidates[0] as InstalledCard
			if mrus_target == null:
				return
			# Find source server and remove from it
			var mrus_src: Server = ctx.servers.get(mrus_target.server_id, null) as Server
			if mrus_src != null:
				mrus_src.remove_from_root(mrus_target)
			# Choose destination server
			var mrus_dest: Server = null
			if mrus_dm != null and mrus_dm.has_method("choose_server"):
				mrus_dest = await mrus_dm.choose_server(ctx)
			if mrus_dest == null:
				# Default: first available server that isn't the source
				for mrus_s2 in ctx.servers.values():
					var mrus_s2_s: Server = mrus_s2 as Server
					if mrus_s2_s != null and mrus_s2_s.server_id != mrus_target.server_id:
						mrus_dest = mrus_s2_s
						break
			if mrus_dest == null:
				mrus_dest = ctx.create_remote_server()
			mrus_target.server_id = mrus_dest.server_id
			mrus_dest.install_in_root(mrus_target)
			ctx.send_log("%s moves %s to %s." % [
				ctx.corp_name(), mrus_target.display_name(), mrus_dest.display_name()])

		"corp_trash_self_to_end_run":
			# Corp may trash this ice to end the run.  Only usable during a run against this server.
			# Used by: Event Horizon ([trash]: End the run. Only during run against this server.)
			if not ctx.run_active:
				return
			var ctse_self := _get_self_card(ctx)
			if ctse_self == null:
				return
			# Only during a run against this card's server
			if ctse_self.server_id != ctx.run_target_server:
				ctx.send_log("Event Horizon: can only be used during a run on %s." % ctse_self.server_id)
				return
			# Corp decides whether to trash self to end the run
			var ctse_do_it := false
			var ctse_dm: Object = ctx.corp_decision_maker
			if ctse_dm != null and ctse_dm.has_method("choose_modes"):
				var ctse_modes: Array = [
					{"label": "Trash Event Horizon to end the run"},
					{"label": "Pass"}
				]
				var ctse_chosen: Array = await ctse_dm.choose_modes(ctse_modes, 1, ctx)
				ctse_do_it = (not ctse_chosen.is_empty() and ctse_chosen[0] == 0)
			else:
				ctse_do_it = true  # AI: always use it
			if ctse_do_it:
				var ctse_src: Server = ctx.servers.get(ctse_self.server_id, null) as Server
				if ctse_src != null:
					ctse_src.remove_ice(ctse_self)
				ctx.unregister_all_card_effects(ctse_self.runtime_instance_id)
				if ctse_self.card_record != null:
					ctx.corp_discard.append(ctse_self.card_record)
				ctx.run_ended = true
				ctx.send_log("%s trashes Event Horizon to end the run." % ctx.corp_name())

		"cultivate_top_5":
			# Look at the top 5 cards of R&D. Trash 1, add 1 to HQ, arrange the rest.
			# Used by: Cultivate.
			var ct5_n: int = mini(5, ctx.corp_deck.size())
			if ct5_n == 0:
				ctx.send_log("%s: R&D is empty." % ctx.corp_name())
				return
			var ct5_top: Array = []
			for ct5_i in range(ct5_n):
				ct5_top.append(ctx.corp_deck[ct5_i])
			# Corp chooses which card to trash
			var ct5_dm: Object = ctx.corp_decision_maker
			var ct5_trash_entry: Variant = null
			var ct5_hq_entry: Variant    = null
			if ct5_dm != null and ct5_dm.has_method("cultivate_choose"):
				var ct5_result: Dictionary = await ct5_dm.cultivate_choose(ct5_top, ctx)
				ct5_trash_entry = ct5_result.get("trash", null)
				ct5_hq_entry    = ct5_result.get("add_to_hq", null)
			else:
				ct5_trash_entry = ct5_top[0]
				ct5_hq_entry    = ct5_top[1] if ct5_n > 1 else null
			# Remove trash target from deck and discard it
			if ct5_trash_entry != null:
				ctx.corp_deck.erase(ct5_trash_entry)
				var ct5_tr: CardRecord = ct5_trash_entry as CardRecord
				if ct5_tr != null:
					ctx.corp_discard.append(ct5_tr)
					ctx.send_log("Cultivate: trashes %s from R&D." % ct5_tr.title)
			# Remove HQ target from deck and add to HQ
			if ct5_hq_entry != null and ct5_hq_entry != ct5_trash_entry:
				ctx.corp_deck.erase(ct5_hq_entry)
				var ct5_hq: CardRecord = ct5_hq_entry as CardRecord
				if ct5_hq != null:
					ctx.corp_hand.append({"card_id": ct5_hq.id, "card_record": ct5_hq})
					ctx.send_log("Cultivate: adds %s to HQ." % ct5_hq.title)
			# Remaining cards stay in R&D (already in top positions; AI keeps original order)
			ctx.send_log("Cultivate: remaining top cards stay in R&D.")

		"luana_campos_turn_begin":
			# Luana Campos: When your turn begins, you may host 1 bad publicity on this asset.
			# If you do, gain 3cr and draw 1 card.
			var lc_self := _get_self_card(ctx)
			if lc_self == null or not lc_self.is_rezzed:
				return
			if ctx.corp_bad_pub <= 0:
				return  # No bad pub to host
			var lc_dm: Object = ctx.corp_decision_maker
			var lc_host := false
			if lc_dm != null and lc_dm.has_method("choose_modes"):
				var lc_modes: Array = [
					{"label": "Host 1 bad pub on Luana Campos — gain 3cr and draw 1"},
					{"label": "Pass"}
				]
				var lc_chosen: Array = await lc_dm.choose_modes(lc_modes, 1, ctx)
				lc_host = (not lc_chosen.is_empty() and lc_chosen[0] == 0)
			else:
				lc_host = true  # AI: always use it
			if lc_host:
				ctx.corp_bad_pub -= 1
				lc_self.add_counter("bad_pub", 1)
				ctx.corp_credits += 3
				_draw_cards("corp", 1, ctx)
				ctx.send_log("Luana Campos: hosts 1 bad pub, gains 3 cr, draws 1 card.")

		# ── Derez effects ────────────────────────────────────────────────────────

		"may_trash_self_to_derez_corp_card":
			# Runner may trash this card to derez 1 rezzed Corp card.
			# Optional: runner chooses whether to activate.
			# params:
			#   required_server: "hq"|"rd"|etc — skip if run was on a different server
			var mtd_required: String = params.get("required_server", "")
			if mtd_required != "" and ctx.current_event_data.get("server_id", "") != mtd_required:
				return  # wrong server

			# Gather all rezzed Corp cards (ice + root) as candidates
			var mtd_candidates: Array = []
			for mtd_server in ctx.servers.values():
				var mtd_s: Server = mtd_server as Server
				for mtd_ice in mtd_s.ice:
					var mtd_c: InstalledCard = mtd_ice as InstalledCard
					if mtd_c.is_rezzed:
						mtd_candidates.append(mtd_c)
				for mtd_root in mtd_s.root:
					var mtd_c: InstalledCard = mtd_root as InstalledCard
					if mtd_c.is_rezzed:
						mtd_candidates.append(mtd_c)

			if mtd_candidates.is_empty():
				return  # nothing to derez

			# Ask runner: activate (trash self to derez) or pass?
			var mtd_activate := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var mtd_modes: Array = [
					{"label": "Trash this card to derez a Corp card"},
					{"label": "Pass"}
				]
				var mtd_chosen: Array = await ctx.runner_decision_maker.choose_modes(mtd_modes, 1, ctx)
				mtd_activate = (not mtd_chosen.is_empty() and mtd_chosen[0] == 0)
			else:
				mtd_activate = true  # AI default: always use it

			if not mtd_activate:
				return

			# Ask runner to choose which Corp card to derez
			var mtd_target: InstalledCard = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_derez_target"):
				mtd_target = await ctx.runner_decision_maker.choose_derez_target(mtd_candidates, ctx)
			else:
				mtd_target = mtd_candidates[0] as InstalledCard

			if mtd_target == null:
				return

			# Derez the chosen Corp card
			await _derez_card(mtd_target, ctx)

			# Trash self (this card)
			var mtd_self := _get_self_card(ctx)
			if mtd_self != null:
				ctx.runner_rig.erase(mtd_self)
				ctx.unregister_all_card_effects(mtd_self.runtime_instance_id)
				if mtd_self.card_record != null:
					ctx.runner_discard.append(mtd_self.card_record)
				ctx.send_log("%s is trashed." % mtd_self.display_name())
				# VP17 Hiram: runner hardware self-trashing triggers look-at-R&D
				if mtd_self.card_record != null and mtd_self.card_record.card_type == "hardware":
					await ctx.notify_event("hardware_trashed", {
						"card_id": mtd_self.card_id, "source": "runner"
					}, self)

		"corp_derez_chosen_ice":
			# Corp derezzes up to count rezzed ice of their choice.
			# params:
			#   count:  int    — number of ice to derez (default 1)
			#   server: String — "run_target" restricts to the currently-attacked server; "" = any server
			var cdci_filter: String = params.get("server", "")
			var cdci_count: int     = params.get("count", 1)
			var cdci_pool: Array    = []
			for cdci_server in ctx.servers.values():
				var cdci_s: Server = cdci_server as Server
				if cdci_filter == "run_target" and cdci_s.server_id != ctx.run_target_server:
					continue
				for cdci_ice in cdci_s.ice:
					var cdci_c: InstalledCard = cdci_ice as InstalledCard
					if cdci_c != null and cdci_c.is_rezzed:
						cdci_pool.append(cdci_c)
			if cdci_pool.is_empty():
				ctx.send_log("No rezzed ice to derez.")
				return
			for _cdci_i in range(mini(cdci_count, cdci_pool.size())):
				var cdci_target: InstalledCard = cdci_pool[0]
				var cdci_dm: Object = ctx.corp_decision_maker
				if cdci_dm != null and cdci_dm.has_method("choose_derez_target"):
					cdci_target = await cdci_dm.choose_derez_target(cdci_pool, ctx)
				cdci_pool.erase(cdci_target)
				await _derez_card(cdci_target, ctx)

		"add_unrezzed_corp_card_to_hq":
			# Hermes (TAI): find 1 unrezzed installed Corp card (ice or root) anywhere,
			# remove it from its server, add it to HQ (as a hand entry, face-down).
			# Corp chooses which card to bounce.
			var auc_pool: Array = []
			for auc_srv in ctx.servers.values():
				var auc_s: Server = auc_srv as Server
				for auc_ic in auc_s.ice:
					var auc_c: InstalledCard = auc_ic as InstalledCard
					if auc_c != null and not auc_c.is_rezzed:
						auc_pool.append(auc_c)
				for auc_rt in auc_s.root:
					var auc_c: InstalledCard = auc_rt as InstalledCard
					if auc_c != null and not auc_c.is_rezzed:
						auc_pool.append(auc_c)
			if auc_pool.is_empty():
				ctx.send_log("[Hermes] No unrezzed installed Corp cards to add to HQ.")
				return
			# Runner always picks the target — mandatory, no declining (Hermes ruling 2023-10-04).
			var auc_target: InstalledCard = auc_pool[0] as InstalledCard
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_derez_target"):
				auc_target = await ctx.runner_decision_maker.choose_derez_target(auc_pool, ctx)
			if auc_target == null:
				return
			# Remove from its server.
			var auc_removed := false
			for auc_srv2 in ctx.servers.values():
				var auc_s2: Server = auc_srv2 as Server
				if auc_s2.ice.has(auc_target):
					auc_s2.ice.erase(auc_target)
					auc_removed = true
					break
				if auc_s2.root.has(auc_target):
					auc_s2.remove_from_root(auc_target)
					auc_removed = true
					break
			if not auc_removed:
				push_error("add_unrezzed_corp_card_to_hq: target not found in any server")
				return
			ctx.unregister_all_card_effects(auc_target.runtime_instance_id)
			ctx.remove_empty_remote_servers()
			# Add to HQ as a hand entry (card is unrezzed, so name stays hidden in real play).
			if auc_target.card_record != null:
				ctx.corp_hand.append({"card_id": auc_target.card_id, "card_record": auc_target.card_record})
				ctx.send_log("[Hermes] %s adds 1 unrezzed card to HQ." % ctx.corp_name())

		"search_rd_install_rez_ice_discount_3":
			# Tucana (TAI): Corp may search R&D for 1 ice, shuffle R&D, then install and rez
			# that ice paying a total of 3cr less across install+rez costs combined.
			# Rulings:
			#   • Discount spreads across install and rez costs (Corp decides allocation).
			#   • Corp may not decline the rez unless they cannot afford it or it has extra costs.
			#   • If Corp cannot afford the rez portion: install unrezzed, reveal the card.
			#   • 419 Amoral Scammer: install fires before rez (normal sequence).
			#
			# Corp offers to search — the ability is optional ("you may").
			var srdi_use := false
			var srdi_cdm: Object = ctx.corp_decision_maker
			if srdi_cdm != null and srdi_cdm.has_method("choose_optional_ability"):
				srdi_use = await srdi_cdm.choose_optional_ability(
					"Tucana: search R&D for 1 ice to install and rez (3cr discount)?", ctx)
			else:
				srdi_use = true   # AI: always use
			if not srdi_use:
				ctx.send_log("[Tucana] Corp declines.")
				return

			# Build list of ice in R&D.
			var srdi_ice_cards: Array = []
			for srdi_card in ctx.corp_deck:
				var srdi_cr: CardRecord = srdi_card as CardRecord
				if srdi_cr != null and srdi_cr.card_type == "ice":
					srdi_ice_cards.append(srdi_cr)
			if srdi_ice_cards.is_empty():
				ctx.send_log("[Tucana] No ice found in R&D — R&D shuffled.")
				ctx.corp_deck.shuffle()
				return

			# Corp chooses which ice to fetch (or declines).
			var srdi_chosen: CardRecord = null
			if srdi_cdm != null and srdi_cdm.has_method("choose_from_search"):
				srdi_chosen = await srdi_cdm.choose_from_search(srdi_ice_cards, ctx)
			else:
				srdi_chosen = srdi_ice_cards[0] as CardRecord
			ctx.corp_deck.shuffle()   # always shuffle, even if declining
			if srdi_chosen == null:
				ctx.send_log("[Tucana] Corp declines to install.")
				return
			ctx.corp_deck.erase(srdi_chosen)
			ctx.send_log("[Tucana] Corp fetches %s from R&D." % srdi_chosen.title)

			# Corp chooses a server to install it in (any server).
			var srdi_all_servers: Array = ctx.servers.keys()
			var srdi_server_id: String = srdi_all_servers[0] if not srdi_all_servers.is_empty() else ""
			if srdi_cdm != null and srdi_cdm.has_method("choose_server"):
				srdi_server_id = await srdi_cdm.choose_server(srdi_all_servers, ctx)
			var srdi_server: Server = ctx.get_server(srdi_server_id) if srdi_server_id != "" else null
			if srdi_server == null:
				push_error("Tucana: could not find server '%s' — returning ice to HQ." % srdi_server_id)
				ctx.corp_hand.append({"card_id": srdi_chosen.id, "card_record": srdi_chosen})
				return

			# Compute combined cost (positional install + printed rez) minus 3cr discount.
			var srdi_positional: int = srdi_server.ice.size()   # before install
			var srdi_rez_cost: int   = max(0, srdi_chosen.cost if srdi_chosen.cost >= 0 else 0)
			var srdi_discounted: int = max(0, srdi_positional + srdi_rez_cost - 3)

			# Install the ice unrezzed first (419 Amoral Scammer fires during install).
			var srdi_inst := _install_corp_card(srdi_chosen, srdi_server, "ice", false)
			if ctx.has_meta("register_installed_card"):
				(ctx.get_meta("register_installed_card") as Callable).call(srdi_inst)
			ctx.send_log("[Tucana] %s installs %s in %s." % [
				ctx.corp_name(), srdi_chosen.title, srdi_server.display_name()])

			if ctx.corp_credits >= srdi_discounted:
				# Corp can afford combined — pay and rez.
				ctx.corp_credits -= srdi_discounted
				srdi_inst.is_rezzed = true
				ctx.ice_rezzed_this_turn = true
				if srdi_inst.runtime_instance_id != "":
					ctx.ice_rezzed_this_turn_instance_ids.append(srdi_inst.runtime_instance_id)
				# Fire on_rez ability for the rezzed ice.
				var srdi_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry \
					if ctx.has_meta("ability_registry") else null
				if srdi_ab_reg != null:
					var srdi_on_rez: Variant = srdi_ab_reg.get_on_rez(srdi_chosen.id)
					if srdi_on_rez != null:
						ctx.current_event_data = {"card": srdi_inst, "card_instance_id": srdi_inst.runtime_instance_id}
						await execute_trigger(srdi_on_rez as Dictionary, ctx)
						ctx.current_event_data = {}
				ctx.send_log("[Tucana] %s rezzed — Corp paid %d cr total (3 cr discount applied)." % [
					srdi_chosen.title, srdi_discounted])
				await ctx.notify_event("corp_rezzes_card", {
					"card": srdi_inst, "card_instance_id": srdi_inst.runtime_instance_id
				}, self)
				await ctx.notify_event("corp_rezzes_ice", {
					"card": srdi_inst, "card_instance_id": srdi_inst.runtime_instance_id
				}, self)
			else:
				# Cannot afford combined cost — install unrezzed; Corp must reveal the card.
				ctx.send_log("[Tucana] Corp cannot afford rez cost (%d discounted, has %d) — %s installed unrezzed. Corp reveals: %s." % [
					srdi_discounted, ctx.corp_credits, srdi_chosen.title, srdi_chosen.title])

		"stegodon_derez_non_attacked_ice":
			# Stegodon MK IV (TAI): Corp may derez 1 rezzed ice NOT on the currently-attacked server,
			# then gains 1 credit. If activated, sets ctx.run_ice_derezzed_this_run so all
			# icebreaker strengths are reduced by 2 for the remainder of the run.
			# Fires as a run_start trigger (once per turn via once_per_turn_key).
			var sdna_attacked: String = ctx.current_event_data.get("server_id", ctx.run_target_server)

			# Build candidate pool: rezzed ice NOT on the attacked server
			var sdna_pool: Array = []
			for sdna_sv in ctx.servers.values():
				var sdna_s: Server = sdna_sv as Server
				if sdna_s.server_id == sdna_attacked:
					continue
				for sdna_ic in sdna_s.ice:
					var sdna_c: InstalledCard = sdna_ic as InstalledCard
					if sdna_c != null and sdna_c.is_rezzed:
						sdna_pool.append(sdna_c)

			if sdna_pool.is_empty():
				ctx.send_log("[Stegodon MK IV] No eligible ice to derez.")
				return

			# Corp decides whether to use the ability (optional)
			var sdna_use := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_optional_ability"):
				sdna_use = await ctx.corp_decision_maker.choose_optional_ability(
					"Derez 1 non-attacked-server ice to give breakers −2 str this run and gain 1[credit]?", ctx)
			else:
				sdna_use = true  # AI default: always use it

			if not sdna_use:
				return

			# Corp picks which ice to derez
			var sdna_target: InstalledCard = sdna_pool[0] as InstalledCard
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_derez_target"):
				sdna_target = await ctx.corp_decision_maker.choose_derez_target(sdna_pool, ctx)
			if sdna_target == null:
				return

			await _derez_card(sdna_target, ctx)
			ctx.run_ice_derezzed_this_run = true
			ctx.corp_credits += 1
			ctx.send_log("[Stegodon MK IV] %s derezzed. Corp gains 1[credit]. Breakers suffer −2 str this run." % \
				sdna_target.display_name())

		"may_trash_self_to_bypass":
			# Runner may trash this card to bypass the currently encountered ice
			# (pass through without resolving any subroutines).
			# params:
			#   trigger_if_corp_credits_gte: int — only offer if Corp has at least this many credits
			var mttb_threshold: int = params.get("trigger_if_corp_credits_gte", 0)
			if mttb_threshold > 0 and ctx.corp_credits < mttb_threshold:
				return  # condition not met — ability does not trigger

			# Ask runner: activate (trash self to bypass) or pass?
			var mttb_activate := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var mttb_modes: Array = [
					{"label": "Trash this card to bypass %s" % ctx.current_event_data.get("ice", null).display_name()},
					{"label": "Pass"}
				]
				var mttb_chosen: Array = await ctx.runner_decision_maker.choose_modes(mttb_modes, 1, ctx)
				mttb_activate = (not mttb_chosen.is_empty() and mttb_chosen[0] == 0)
			else:
				mttb_activate = true  # AI default: always bypass when condition is met

			if not mttb_activate:
				return

			# Set bypass flag — RunStateMachine checks this immediately after encounter_ice
			ctx.run_modifiers["bypass_current_ice"] = true

			# Trash self
			var mttb_self := _get_self_card(ctx)
			if mttb_self != null:
				ctx.runner_rig.erase(mttb_self)
				ctx.unregister_all_card_effects(mttb_self.runtime_instance_id)
				if mttb_self.card_record != null:
					ctx.runner_discard.append(mttb_self.card_record)
				ctx.send_log("%s is trashed — %s bypassed." % [
					mttb_self.display_name(),
					ctx.current_event_data.get("ice", null).display_name()
				])
				# VP17 Hiram: runner hardware self-trashing triggers look-at-R&D
				if mttb_self.card_record != null and mttb_self.card_record.card_type == "hardware":
					await ctx.notify_event("hardware_trashed", {
						"card_id": mttb_self.card_id, "source": "runner"
					}, self)

		# ── Boomerang: optional heap recursion after successful run ─────────────

		"boomerang_recur_from_heap":
			# "When this run ends, if it was successful, you may shuffle 1 copy of
			# Boomerang from your heap into your stack."
			# The run_end event data carries {successful: bool}.
			# When Boomerang is trashed mid-run via trash_self_on_use, its run_end
			# listener is kept alive (via unregister_card_effects_except_event) so this
			# fires. After this effect executes for a trashed Boomerang, its run_end
			# listener is cleaned up so it won't ghost-fire on future runs.
			var bm_iid: String = ctx.current_event_data.get("card_instance_id", "")

			# Determine if this card is still in the rig (not trashed during the run)
			var bm_still_installed: bool = false
			for bm_c in ctx.runner_rig:
				if (bm_c as InstalledCard).runtime_instance_id == bm_iid:
					bm_still_installed = true
					break

			if not ctx.current_event_data.get("successful", false):
				# Not a successful run. If the card was trashed, clean up the listener.
				if not bm_still_installed and bm_iid != "":
					ctx.unregister_all_card_effects(bm_iid)
				return

			# Successful run — find a copy of Boomerang in the runner's discard pile
			var bm_discard_idx: int = -1
			for bm_i in range(ctx.runner_discard.size()):
				var bm_r: CardRecord = ctx.runner_discard[bm_i] as CardRecord
				if bm_r != null and bm_r.id == "boomerang":
					bm_discard_idx = bm_i
					break

			# If Boomerang was trashed during this run, clean up the orphaned run_end
			# listener now — it has served its purpose regardless of whether we recur.
			if not bm_still_installed and bm_iid != "":
				ctx.unregister_all_card_effects(bm_iid)

			if bm_discard_idx < 0:
				return  # no Boomerang in heap

			# Ask the runner if they want to shuffle it back
			var bm_choose := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var bm_modes: Array = [
					{"label": "Shuffle Boomerang into stack"},
					{"label": "Leave Boomerang in heap"}
				]
				var bm_chosen: Array = await ctx.runner_decision_maker.choose_modes(bm_modes, 1, ctx)
				bm_choose = (not bm_chosen.is_empty() and bm_chosen[0] == 0)
			else:
				bm_choose = true  # AI default: always recur

			if bm_choose:
				var bm_record: CardRecord = ctx.runner_discard[bm_discard_idx] as CardRecord
				ctx.runner_discard.remove_at(bm_discard_idx)
				var bm_insert: int = randi() % (ctx.runner_deck.size() + 1)
				ctx.runner_deck.insert(bm_insert, bm_record)
				ctx.send_log("%s shuffles %s from their heap into their stack." % [
					ctx.runner_name(), bm_record.title
				])

		# ── Devadatta Drone: spend power counters for bonus R&D access ───────────

		"spend_counters_for_bonus_access":
			# During a breach of the specified server, runner may spend up to N counters
			# from this card for +N additional accesses. Fires via before_breach trigger.
			var scba_server: String  = params.get("server", "rd")
			var scba_counter: String = params.get("counter", "power")
			var scba_breach: String  = ctx.current_event_data.get("server_id", "")
			if scba_breach != scba_server:
				return   # only fires on the target server

			var scba_card := _get_self_card(ctx)
			if scba_card == null:
				return

			var scba_available: int = scba_card.get_counter(scba_counter)
			if scba_available <= 0:
				return   # no counters to spend

			# Ask runner how many counters to spend (0 = decline)
			var scba_spend: int = scba_available   # AI default: spend all
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_spend_counter_amount"):
				scba_spend = await ctx.runner_decision_maker.choose_spend_counter_amount(
					scba_card, scba_counter, scba_available, ctx
				)
			scba_spend = clampi(scba_spend, 0, scba_available)
			if scba_spend <= 0:
				return

			scba_card.remove_counter(scba_counter, scba_spend)
			var scba_current: int = ctx.run_modifiers.get("bonus_access", 0)
			ctx.run_modifiers["bonus_access"] = scba_current + scba_spend
			ctx.send_log("%s spends %d %s counter(s) from %s — +%d %s access." % [
				ctx.runner_name(), scba_spend, scba_counter,
				scba_card.display_name(), scba_spend, scba_server.to_upper()
			])

		# ── Biawak: trash a program or end the run ────────────────────────────────

		"runner_must_trash_program_or_etr":
			# Subroutine: trash an installed program, or if none, end the run.
			var rmt_programs: Array = ctx.runner_rig.filter(
				func(c: InstalledCard): return c.card_record != null and c.card_record.card_type == "program"
			)
			# Also include programs hosted on ice
			for rmt_server in ctx.servers.values():
				for rmt_ice in (rmt_server as Server).ice:
					for rmt_hosted in (rmt_ice as InstalledCard).hosted_cards:
						var rmt_h: InstalledCard = rmt_hosted as InstalledCard
						if rmt_h != null and rmt_h.card_record != null and rmt_h.card_record.card_type == "program":
							if not rmt_programs.has(rmt_h):
								rmt_programs.append(rmt_h)
			if rmt_programs.is_empty():
				ctx.run_ended = true
				ctx.send_log("Biawak: no installed programs — run ended.")
			else:
				# Runner must choose which program to trash
				var rmt_target: InstalledCard = null
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_trash_from_rig"):
					rmt_target = await ctx.runner_decision_maker.choose_trash_from_rig(rmt_programs, ctx)
				if rmt_target == null:
					rmt_target = rmt_programs[0] as InstalledCard
				_trash_installed_card(rmt_target, ctx)
				if rmt_target.card_record != null:
					ctx.runner_discard.append(rmt_target.card_record)
				ctx.send_log("Biawak: %s trashed %s." % [ctx.runner_name(), rmt_target.display_name()])

		# ── Biawak: trash a resource or end the run ───────────────────────────────

		"runner_must_trash_resource_or_etr":
			# Subroutine: trash an installed resource, or if none, end the run.
			var rmr_resources: Array = ctx.runner_rig.filter(
				func(c: InstalledCard): return c.card_record != null and c.card_record.card_type == "resource"
			)
			if rmr_resources.is_empty():
				ctx.run_ended = true
				ctx.send_log("Biawak: no installed resources — run ended.")
			else:
				var rmr_target: InstalledCard = null
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_trash_from_rig"):
					rmr_target = await ctx.runner_decision_maker.choose_trash_from_rig(rmr_resources, ctx)
				if rmr_target == null:
					rmr_target = rmr_resources[0] as InstalledCard
				ctx.runner_rig.erase(rmr_target)
				ctx.unregister_all_card_effects(rmr_target.runtime_instance_id)
				if rmr_target.card_record != null:
					ctx.runner_discard.append(rmr_target.card_record)
				ctx.send_log("Biawak: %s trashed %s." % [ctx.runner_name(), rmr_target.display_name()])

		# ── Generic: trash 1 installed program (runner chooses, no opt-out) ────────

		"trash_runner_program":
			# Runner must trash 1 installed program of their choice.  No payment option.
			# If no programs are installed, the effect does nothing.
			# Used by: Lycian Multi-Munition sentry subroutine.
			var trp_programs: Array = ctx.runner_rig.filter(
				func(c: InstalledCard): return c.card_record != null and c.card_record.card_type == "program"
			)
			if trp_programs.is_empty():
				ctx.send_log("%s has no installed programs — subroutine has no effect." % ctx.runner_name())
				return
			var trp_target: InstalledCard = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_trash_from_rig"):
				trp_target = await ctx.runner_decision_maker.choose_trash_from_rig(trp_programs, ctx)
			if trp_target == null:
				trp_target = trp_programs[0] as InstalledCard
			_trash_installed_card(trp_target, ctx)
			if trp_target.card_record != null:
				ctx.runner_discard.append(trp_target.card_record)
			ctx.send_log("%s trashes %s." % [ctx.runner_name(), trp_target.display_name()])

		# ── Plutus: corp turn start — may play a transaction from Archives (RFG) ──

		"may_play_transaction_from_archives_rfg":
			# Plutus corp_turn_start: Corp may play a transaction from Archives,
			# then remove it from the game instead of placing it in Archives again.
			var mptafr_candidates: Array = []
			for mptafr_r in ctx.corp_discard:
				var mptafr_record: CardRecord = mptafr_r as CardRecord
				if mptafr_record == null:
					continue
				if mptafr_record.card_type == "operation" and mptafr_record.has_subtype("transaction"):
					mptafr_candidates.append(mptafr_record)
			if mptafr_candidates.is_empty():
				ctx.send_log("Plutus: no transactions in Archives to play.")
				return

			# Corp chooses one (or declines)
			var mptafr_dm: Object = ctx.corp_decision_maker
			var mptafr_chosen: CardRecord = null
			if mptafr_dm != null and mptafr_dm.has_method("choose_from_archives"):
				mptafr_chosen = await mptafr_dm.choose_from_archives(mptafr_candidates, ctx)
			else:
				mptafr_chosen = mptafr_candidates[0]   # AI default: always use it

			if mptafr_chosen == null:
				ctx.send_log("Plutus: Corp declines to play a transaction from Archives.")
				return

			ctx.send_log("Plutus: %s plays %s from Archives." % [ctx.corp_name(), mptafr_chosen.title])
			ctx.corp_discard.erase(mptafr_chosen)

			# Execute the transaction's on_play effect
			if ctx.has_meta("ability_registry"):
				var mptafr_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var mptafr_on_play = mptafr_ab_reg.get_on_play(mptafr_chosen.id)
				if mptafr_on_play != null:
					await execute_trigger(mptafr_on_play as Dictionary, ctx)
				else:
					ctx.send_log("Plutus: %s has no on_play effect defined." % mptafr_chosen.title)

			# Remove from game (not back to Archives)
			ctx.corp_rfg.append(mptafr_chosen)
			ctx.send_log("Plutus: %s is removed from the game." % mptafr_chosen.title)

		# ── Humanoid Resources: play 1 operation from HQ ─────────────────────────

		"may_play_operation_from_hq":
			# Corp may choose 1 operation from HQ, pay its cost, and execute its on_play.
			# Used by Humanoid Resources (fires after self-trash + gain + draw + install).
			# params: { "optional": bool }
			await _do_play_operation_from_hq(
				"Humanoid Resources",
				params.get("optional", true),
				ctx
			)

		# ── Generic: play 1 operation from HQ (Sudden Commandment, etc.) ─────────

		"play_operation_from_hq":
			# Corp may choose 1 affordable operation from HQ, pay its cost, and resolve it.
			# params: { "optional": bool, "exclude_terminal": bool }
			await _do_play_operation_from_hq(
				"Play Operation",
				params.get("optional", true),
				ctx,
				params.get("exclude_terminal", false)
			)

		# ── Mycoweb sub 1: install ice from Archives, ignoring all costs ──────────

		"install_ice_from_archives":
			# Corp may install 1 piece of ice from Archives on the run server (or a new
			# remote if called outside a run), ignoring all costs.
			# params: { "optional": bool }
			var iifa_optional: bool = params.get("optional", true)

			# Collect ice from Archives (corp_discard)
			var iifa_candidates: Array = []
			for iifa_r in ctx.corp_discard:
				var iifa_record: CardRecord = iifa_r as CardRecord
				if iifa_record != null and iifa_record.is_ice():
					iifa_candidates.append({"card_id": iifa_record.id, "card_record": iifa_record})

			if iifa_candidates.is_empty():
				ctx.send_log("[Mycoweb] Archives has no ice to install.")
				return

			# Optional: Corp may decline (default true when no method available)
			if iifa_optional:
				var iifa_dm_opt: Object = ctx.corp_decision_maker
				var iifa_will_use := true
				if iifa_dm_opt != null and iifa_dm_opt.has_method("choose_optional_ability"):
					iifa_will_use = await iifa_dm_opt.choose_optional_ability("Install 1 ice from Archives?", ctx)
				if not iifa_will_use:
					ctx.send_log("[Mycoweb] Corp declines to install ice from Archives.")
					return

			# Corp chooses which ice to install
			var iifa_dm: Object = ctx.corp_decision_maker
			var iifa_chosen_entry: Variant = null
			if iifa_dm != null and iifa_dm.has_method("choose_card_from_hand"):
				iifa_chosen_entry = await iifa_dm.choose_card_from_hand(iifa_candidates, ctx)
			else:
				iifa_chosen_entry = iifa_candidates[0]

			if iifa_chosen_entry == null:
				return

			var iifa_record: CardRecord = (iifa_chosen_entry as Dictionary).get("card_record", null) as CardRecord
			if iifa_record == null:
				return

			ctx.corp_discard.erase(iifa_record)
			var iifa_server: Server = ctx.get_server(ctx.run_target_server)
			if iifa_server == null:
				iifa_server = ctx.create_remote_server()
			if iifa_server != null:
				var iifa_installed := InstalledCard.make_runtime_instance(iifa_record, iifa_server.server_id, "ice", false)
				iifa_server.install_ice(iifa_installed)
				ctx.send_log("[Mycoweb] %s installs %s from Archives on %s (ignoring costs)." % [
					ctx.corp_name(), iifa_record.title, iifa_server.display_name()
				])

		# ── Mycoweb sub 2: rez installed ice at a credit discount ─────────────────

		"rez_ice_discounted":
			# Corp may rez 1 unrezzed installed ice, paying N credits less.
			# Uses run_modifiers["extra_rez_cost"] (negative = discount) and calls RSM._rez_card.
			# params: { "discount": int, "optional": bool }
			var rid_discount: int  = params.get("discount", 2)
			var rid_optional: bool = params.get("optional", true)

			# Collect all unrezzed installed ice across all servers
			var rid_candidates: Array = []
			for rid_srv in ctx.servers.values():
				for rid_c in (rid_srv as Server).ice:
					var rid_ic: InstalledCard = rid_c as InstalledCard
					if not rid_ic.is_rezzed:
						rid_candidates.append(rid_ic)

			if rid_candidates.is_empty():
				ctx.send_log("[Mycoweb] No unrezzed ice to rez.")
				return

			# Optional: Corp may decline
			if rid_optional:
				var rid_dm_opt: Object = ctx.corp_decision_maker
				var rid_will_use := true
				if rid_dm_opt != null and rid_dm_opt.has_method("choose_optional_ability"):
					rid_will_use = await rid_dm_opt.choose_optional_ability(
						"Rez 1 ice at %d[credit] discount?" % rid_discount, ctx)
				if not rid_will_use:
					ctx.send_log("[Mycoweb] Corp declines discounted rez.")
					return

			# Corp chooses which ice to rez; default heuristic: most expensive (best discount value)
			var rid_target: InstalledCard = rid_candidates[0] as InstalledCard
			var rid_dm: Object = ctx.corp_decision_maker
			if rid_dm != null and rid_dm.has_method("choose_derez_target"):
				# choose_derez_target picks one InstalledCard from a list — reused here for selection
				rid_target = await rid_dm.choose_derez_target(rid_candidates, ctx)
			else:
				# Inline fallback: pick the most expensive unrezzed ice
				for rid_ic in rid_candidates:
					var rid_c: InstalledCard = rid_ic as InstalledCard
					if rid_c.card_record != null and rid_target.card_record != null:
						if rid_c.card_record.cost > rid_target.card_record.cost:
							rid_target = rid_c

			if rid_target == null:
				return

			# Apply discount via run_modifiers, rez via RSM, then clear the modifier
			ctx.run_modifiers["extra_rez_cost"] = -rid_discount
			if ctx.has_meta("run_state_machine"):
				var rid_rsm: Object = ctx.get_meta("run_state_machine")
				await rid_rsm._rez_card(rid_target)
			ctx.run_modifiers.erase("extra_rez_cost")

		# ── Mycoweb subs 3 & 4: resolve a subroutine on a rezzed ice of a subtype ─

		"resolve_sub_on_rezzed_ice_of_subtype":
			# Corp picks a rezzed ice matching 'subtype', then picks one of its subroutines
			# to resolve (bypassing break windows — this is a direct Corp trigger).
			# params: { "subtype": String, "exclude_card_id": String (optional) }
			var rsris_subtype: String = params.get("subtype", "sentry")
			var rsris_exclude: String = params.get("exclude_card_id", "")

			# Collect rezzed ice of the matching subtype, excluding any by card_id if requested
			var rsris_candidates: Array = []
			for rsris_srv in ctx.servers.values():
				for rsris_c in (rsris_srv as Server).ice:
					var rsris_ic: InstalledCard = rsris_c as InstalledCard
					if not rsris_ic.is_rezzed:
						continue
					if rsris_exclude != "" and rsris_ic.card_id == rsris_exclude:
						continue
					if rsris_ic.has_effective_subtype(rsris_subtype):
						rsris_candidates.append(rsris_ic)

			if rsris_candidates.is_empty():
				ctx.send_log("[Mycoweb] No rezzed %s found to trigger." % rsris_subtype)
				return

			# Corp chooses which ice to target (default: first candidate)
			var rsris_target: InstalledCard = rsris_candidates[0] as InstalledCard
			var rsris_dm: Object = ctx.corp_decision_maker
			if rsris_dm != null and rsris_dm.has_method("choose_derez_target"):
				rsris_target = await rsris_dm.choose_derez_target(rsris_candidates, ctx)

			if rsris_target == null:
				return

			# Fetch the subroutine list for the chosen ice via ability_registry
			var rsris_subs: Array = []
			if ctx.has_meta("ability_registry"):
				var rsris_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				rsris_subs = rsris_ab_reg.get_subroutines_for_card(rsris_target.card_id, rsris_target)

			if rsris_subs.is_empty():
				ctx.send_log("[Mycoweb] %s has no implemented subroutines." % rsris_target.display_name())
				return

			# Corp chooses which subroutine to resolve (default: index 0)
			var rsris_sub_idx: int = 0
			if rsris_subs.size() > 1 and rsris_dm != null and rsris_dm.has_method("choose_modes"):
				var rsris_modes: Array = []
				for rsris_s in rsris_subs:
					rsris_modes.append({"label": (rsris_s as Dictionary).get("label", "Subroutine")})
				var rsris_choice: Array = await rsris_dm.choose_modes(rsris_modes, 1, ctx)
				if not rsris_choice.is_empty():
					rsris_sub_idx = rsris_choice[0]

			var rsris_chosen_sub: Dictionary = rsris_subs[rsris_sub_idx] as Dictionary
			ctx.send_log("[Mycoweb] Corp fires subroutine %d of %s: %s" % [
				rsris_sub_idx, rsris_target.display_name(),
				rsris_chosen_sub.get("label", "?")
			])
			await execute_subroutine(rsris_chosen_sub, ctx)

		# ── Mitra Aman: swap approached ice with ice on HQ or Archives ───────────

		"swap_approached_ice_with_central":
			# Swap the ice currently being approached (from current_event_data["ice"])
			# with a piece of installed ice on HQ or Archives.
			# After the swap, stores the swapped-in ice in ctx meta so that
			# RunStateMachine._phase_approach_ice can update its snapshot pointer.
			var saic_approached: InstalledCard = \
				ctx.current_event_data.get("ice", null) as InstalledCard
			if saic_approached == null:
				push_error("AbilityInterpreter: swap_approached_ice_with_central — no ice in event data")
				return

			# Gather all ice installed on HQ and Archives
			var saic_candidates: Array = []
			for saic_sid in ["hq", "archives"]:
				var saic_srv: Server = ctx.get_server(saic_sid) as Server
				if saic_srv != null:
					for saic_c in saic_srv.ice:
						saic_candidates.append(saic_c)

			if saic_candidates.is_empty():
				ctx.send_log("Mitra Aman: no installed ice on HQ or Archives — swap skipped.")
				return

			# Corp chooses which ice to swap in
			var saic_chosen: InstalledCard = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var saic_modes: Array = []
				for saic_c in saic_candidates:
					var saic_ic: InstalledCard = saic_c as InstalledCard
					var saic_src: Server = ctx.get_server(saic_ic.server_id) as Server
					var saic_src_name: String = saic_src.display_name() if saic_src else saic_ic.server_id
					saic_modes.append({
						"label": "%s (%s)" % [saic_ic.display_name(), saic_src_name]
					})
				var saic_result: Array = \
					await ctx.corp_decision_maker.choose_modes(saic_modes, 1, ctx)
				if not saic_result.is_empty():
					saic_chosen = saic_candidates[saic_result[0]] as InstalledCard
			else:
				saic_chosen = saic_candidates[0] as InstalledCard

			if saic_chosen == null:
				return

			# Locate both ice in their respective server arrays
			var saic_old_srv: Server = ctx.get_server(saic_approached.server_id) as Server
			var saic_new_srv: Server = ctx.get_server(saic_chosen.server_id) as Server
			var saic_old_pos: int    = saic_old_srv.ice.find(saic_approached) if saic_old_srv else -1
			var saic_new_pos: int    = saic_new_srv.ice.find(saic_chosen)     if saic_new_srv else -1

			if saic_old_pos < 0 or saic_new_pos < 0:
				push_error("AbilityInterpreter: swap_approached_ice_with_central — ice not found in server array")
				return

			# Perform physical swap and update server_id on each card
			saic_old_srv.ice[saic_old_pos] = saic_chosen
			saic_chosen.server_id          = saic_old_srv.server_id
			saic_new_srv.ice[saic_new_pos] = saic_approached
			saic_approached.server_id      = saic_new_srv.server_id

			ctx.send_log("Mitra Aman: %s moved to %s; %s moved to %s." % [
				saic_chosen.display_name(),    saic_old_srv.display_name(),
				saic_approached.display_name(), saic_new_srv.display_name()
			])

			# Signal RunStateMachine to update its _ice_positions snapshot at the
			# current index so the runner now approaches the swapped-in ice.
			ctx.set_meta("run_ice_swapped", saic_chosen)

		# ── Sabotage ──────────────────────────────────────────────────────────────

		"sabotage":
			# The Corp trashes N cards of their choice from HQ and/or the top of R&D.
			# params: { "amount": int }
			var sab_amount: int = params.get("amount", 1)
			ctx.send_log("[Sabotage %d] %s must trash %d card(s) from HQ or R&D." % [
				sab_amount, ctx.corp_name(), sab_amount
			])
			for _sab_i in range(sab_amount):
				if ctx.corp_hand.is_empty() and ctx.corp_deck.is_empty():
					ctx.send_log("[Sabotage] %s has no cards remaining." % ctx.corp_name())
					break

				var sab_choice: Dictionary = {}
				if ctx.corp_decision_maker != null and \
						ctx.corp_decision_maker.has_method("choose_sabotage_discard"):
					sab_choice = await ctx.corp_decision_maker.choose_sabotage_discard(ctx)
				else:
					# Default: trash cheapest non-agenda from HQ; fallback to R&D
					sab_choice = _sabotage_default_choice(ctx)

				var sab_source: String = sab_choice.get("source", "rd")
				if sab_source == "hq":
					var sab_cr: CardRecord = sab_choice.get("card_record", null) as CardRecord
					var sab_found := false
					for sab_j in range(ctx.corp_hand.size()):
						if ctx.corp_hand[sab_j].get("card_record") == sab_cr:
							ctx.corp_hand.remove_at(sab_j)
							ctx.corp_discard.append(sab_cr)
							ctx.send_log("[Sabotage] %s trashes %s from HQ." % [
								ctx.corp_name(), sab_cr.title
							])
							sab_found = true
							break
					if not sab_found:
						sab_source = "rd"   # card not in hand — fall through to R&D

				if sab_source == "rd":
					if not ctx.corp_deck.is_empty():
						var sab_top: CardRecord = ctx.corp_deck.pop_front()
						ctx.corp_discard.append(sab_top)
						ctx.send_log("[Sabotage] %s trashes top of R&D: %s." % [
							ctx.corp_name(), sab_top.title
						])
					elif not ctx.corp_hand.is_empty():
						# R&D empty — must trash from HQ as a last resort
						var sab_fb: Dictionary = ctx.corp_hand.pop_front()
						var sab_fb_cr: CardRecord = sab_fb.get("card_record") as CardRecord
						if sab_fb_cr != null:
							ctx.corp_discard.append(sab_fb_cr)
							ctx.send_log("[Sabotage] R&D empty — %s trashes %s from HQ." % [
								ctx.corp_name(), sab_fb_cr.title
							])

		# ── Optional counter spend (e.g. Cacophony end-of-turn) ──────────────────

		"optional_spend_counters":
			# Runner may spend N counters of a given type on this card to fire an effect.
			# params: { "counter": str, "cost": int, "prompt": str, "effects": Array }
			var osc_counter: String = params.get("counter", "power")
			var osc_cost:    int    = params.get("cost", 0)
			var osc_prompt:  String = params.get("prompt", "Spend %d %s counter(s)?" % [osc_cost, osc_counter])
			var osc_effects: Array  = params.get("effects", []) as Array

			var osc_card := _get_self_card(ctx)
			if osc_card == null:
				return
			if osc_card.get_counter(osc_counter) < osc_cost:
				return   # not enough counters

			# Ask the runner (or use a default) whether to activate
			var osc_activate := false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_optional_ability"):
				osc_activate = await ctx.runner_decision_maker.choose_optional_ability(osc_prompt, ctx)
			else:
				osc_activate = true   # default: activate when counters are available

			if not osc_activate:
				ctx.send_log("%s declines." % osc_card.display_name())
				return

			osc_card.remove_counter(osc_counter, osc_cost)
			ctx.send_log("%s spends %d %s counter(s) (%d remaining)." % [
				osc_card.display_name(), osc_cost, osc_counter,
				osc_card.get_counter(osc_counter)
			])
			for osc_eff in osc_effects:
				await _execute_effect(osc_eff as Dictionary, ctx, null)

		"install_from_heap":
			var ifh_types: Array = params.get("card_types", []) as Array
			var ifh_candidates: Array = []
			for ifh_r in ctx.runner_discard:
				var ifh_record: CardRecord = ifh_r as CardRecord
				if ifh_record == null:
					continue
				if ifh_types.is_empty() or ifh_types.has(ifh_record.card_type):
					ifh_candidates.append(ifh_record)
			if ifh_candidates.is_empty():
				ctx.send_log("Scrounge: no eligible cards in heap.")
				return
			var ifh_chosen: CardRecord = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_heap"):
				ifh_chosen = await ctx.runner_decision_maker.choose_from_heap(ifh_candidates, ctx)
			else:
				ifh_chosen = ifh_candidates[0]
			if ifh_chosen == null:
				ctx.send_log("Scrounge: no program chosen.")
				return
			var ifh_cost: int = max(0, ifh_chosen.cost)
			# DZMZ Optimizer discount for programs
			if ifh_chosen.card_type == "program" and not ctx.runner_program_install_discounted_this_turn:
				for ifh_rig_c in ctx.runner_rig:
					var ifh_c: InstalledCard = ifh_rig_c as InstalledCard
					if ifh_c != null and ifh_c.card_id == "dzmz_optimizer":
						ifh_cost = max(0, ifh_cost - 1)
						ctx.runner_program_install_discounted_this_turn = true
						ctx.send_log("DZMZ Optimizer: heap install costs 1 less (now %d¢)." % ifh_cost)
						break
			# MU check for programs
			if ifh_chosen.card_type == "program" and ifh_chosen.memory_cost > 0:
				if ctx.runner_mu_available() < ifh_chosen.memory_cost:
					ctx.send_log("Scrounge: not enough MU for %s — cannot install." % ifh_chosen.title)
					return
			if ctx.runner_credits < ifh_cost:
				ctx.send_log("Scrounge: cannot afford %s (costs %d¢)." % [ifh_chosen.title, ifh_cost])
				return
			ctx.runner_credits -= ifh_cost
			ctx.runner_discard.erase(ifh_chosen)
			var ifh_installed := InstalledCard.make_runtime_instance(ifh_chosen, "runner_rig", "root", true)
			ctx.runner_rig.append(ifh_installed)
			if ctx.has_meta("register_installed_card"):
				var ifh_reg: Callable = ctx.get_meta("register_installed_card") as Callable
				ifh_reg.call(ifh_installed)
			if ctx.has_meta("ability_registry"):
				var ifh_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var ifh_on_rez = ifh_ab_reg.get_on_rez(ifh_chosen.id)
				if ifh_on_rez != null:
					ctx.current_event_data = {"card": ifh_installed, "card_instance_id": ifh_installed.runtime_instance_id}
					await execute_trigger(ifh_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			if ifh_chosen.card_type == "program" and ifh_chosen.has_subtype("virus"):
				await ctx.notify_event("runner_installs_virus", {
					"card": ifh_installed,
					"card_instance_id": ifh_installed.runtime_instance_id
				}, self)
			ctx.send_log("Scrounge: %s installs %s from heap for %d¢. [MU: %d/%d]" % [
				ctx.runner_name(), ifh_chosen.title, ifh_cost,
				ctx.runner_mu_used(), ctx.runner_total_mu()
			])

		"return_heap_card_to_stack":
			var rhcs_types: Array = params.get("card_types", []) as Array
			var rhcs_opt: bool    = params.get("optional", true)
			var rhcs_candidates: Array = []
			for rhcs_r in ctx.runner_discard:
				var rhcs_record: CardRecord = rhcs_r as CardRecord
				if rhcs_record == null:
					continue
				if rhcs_types.is_empty() or rhcs_types.has(rhcs_record.card_type):
					rhcs_candidates.append(rhcs_record)
			if rhcs_candidates.is_empty():
				ctx.send_log("Scrounge: no more eligible cards in heap to return.")
				return
			var rhcs_chosen: CardRecord = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_heap"):
				rhcs_chosen = await ctx.runner_decision_maker.choose_from_heap(rhcs_candidates, ctx)
			elif not rhcs_opt:
				rhcs_chosen = rhcs_candidates[0]
			if rhcs_chosen == null:
				ctx.send_log("Scrounge: runner declines to return a program to stack.")
				return
			ctx.runner_discard.erase(rhcs_chosen)
			ctx.runner_deck.push_back(rhcs_chosen)
			ctx.send_log("Scrounge: %s returns %s to the bottom of their stack." % [
				ctx.runner_name(), rhcs_chosen.title
			])

		"install_from_grip_discounted":
			var ifgd_require_success: bool = params.get("requires_successful_run", false)
			if ifgd_require_success and not ctx.run_successful:
				ctx.send_log("Illumination: run was not successful — no installation.")
				return
			var ifgd_max: int   = params.get("max_installs", 3)
			var ifgd_disc: int  = params.get("discount_per_card", 1)
			var ifgd_count: int = 0
			for _ifgd_i in range(ifgd_max):
				var ifgd_installable: Array = []
				for ifgd_entry in ctx.runner_hand:
					var ifgd_e: Dictionary = ifgd_entry as Dictionary
					var ifgd_r: CardRecord = ifgd_e.get("card_record", null) as CardRecord
					if ifgd_r == null:
						continue
					if ifgd_r.card_type not in ["program", "hardware", "resource"]:
						continue
					var ifgd_cost: int = max(0, ifgd_r.cost - ifgd_disc)
					if ctx.runner_credits < ifgd_cost:
						continue
					if ifgd_r.card_type == "program" and ifgd_r.memory_cost > 0:
						if ctx.runner_mu_available() < ifgd_r.memory_cost:
							continue
					ifgd_installable.append(ifgd_entry)
				if ifgd_installable.is_empty():
					if ifgd_count == 0:
						ctx.send_log("Illumination: no cards in grip that can be installed.")
					else:
						ctx.send_log("Illumination: no further cards can be installed.")
					break
				var ifgd_chosen_entry: Variant = null
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_hand"):
					ifgd_chosen_entry = await ctx.runner_decision_maker.choose_card_from_hand(ifgd_installable, ctx)
				else:
					ifgd_chosen_entry = ifgd_installable[0]
				if ifgd_chosen_entry == null:
					ctx.send_log("Illumination: runner done installing.")
					break
				var ifgd_record: CardRecord = (ifgd_chosen_entry as Dictionary).get("card_record", null) as CardRecord
				if ifgd_record == null:
					break
				var ifgd_pay: int = max(0, ifgd_record.cost - ifgd_disc)
				ctx.runner_credits -= ifgd_pay
				ctx.runner_hand.erase(ifgd_chosen_entry)
				var ifgd_installed := InstalledCard.make_runtime_instance(ifgd_record, "runner_rig", "root", true)
				ctx.runner_rig.append(ifgd_installed)
				if ctx.has_meta("register_installed_card"):
					var ifgd_reg: Callable = ctx.get_meta("register_installed_card") as Callable
					ifgd_reg.call(ifgd_installed)
				if ctx.has_meta("ability_registry"):
					var ifgd_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
					var ifgd_on_rez = ifgd_ab_reg.get_on_rez(ifgd_record.id)
					if ifgd_on_rez != null:
						ctx.current_event_data = {"card": ifgd_installed, "card_instance_id": ifgd_installed.runtime_instance_id}
						await execute_trigger(ifgd_on_rez as Dictionary, ctx)
						ctx.current_event_data = {}
				if ifgd_record.card_type == "program" and ifgd_record.has_subtype("virus"):
					await ctx.notify_event("runner_installs_virus", {
						"card": ifgd_installed,
						"card_instance_id": ifgd_installed.runtime_instance_id
					}, self)
				ifgd_count += 1
				ctx.send_log("Illumination: %s installs %s for %d¢ (%d/%d). [MU: %d/%d]" % [
					ctx.runner_name(), ifgd_record.title, ifgd_pay,
					ifgd_count, ifgd_max, ctx.runner_mu_used(), ctx.runner_total_mu()
				])
			if ifgd_count > 0:
				ctx.send_log("Illumination: %s installed %d card(s)." % [ctx.runner_name(), ifgd_count])

		"charm_offensive_trash_rezzed_copy":
			var cotrc_accessed: Array = ctx.run_accessed_archives_card_ids
			if cotrc_accessed.is_empty():
				ctx.send_log("Charm Offensive: no cards were accessed in Archives.")
				return
			var cotrc_candidates: Array = []
			for cotrc_server in ctx.servers.values():
				var cotrc_s: Server = cotrc_server as Server
				if cotrc_s == null:
					continue
				for cotrc_root in cotrc_s.root:
					var cotrc_c: InstalledCard = cotrc_root as InstalledCard
					if cotrc_c != null and cotrc_c.is_rezzed and cotrc_c.card_record != null:
						if cotrc_c.card_id in cotrc_accessed:
							cotrc_candidates.append(cotrc_c)
				for cotrc_ice in cotrc_s.ice:
					var cotrc_c: InstalledCard = cotrc_ice as InstalledCard
					if cotrc_c != null and cotrc_c.is_rezzed and cotrc_c.card_record != null:
						if cotrc_c.card_id in cotrc_accessed:
							cotrc_candidates.append(cotrc_c)
			if cotrc_candidates.is_empty():
				ctx.send_log("Charm Offensive: no rezzed copies of accessed cards found.")
				return
			var cotrc_chosen: InstalledCard = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var cotrc_modes: Array = []
				for cotrc_c in cotrc_candidates:
					var cotrc_ic: InstalledCard = cotrc_c as InstalledCard
					cotrc_modes.append({"label": "Trash %s" % cotrc_ic.display_name()})
				cotrc_modes.append({"label": "Pass"})
				var cotrc_result: Array = await ctx.runner_decision_maker.choose_modes(cotrc_modes, 1, ctx)
				if not cotrc_result.is_empty():
					var cotrc_idx: int = cotrc_result[0]
					if cotrc_idx < cotrc_candidates.size():
						cotrc_chosen = cotrc_candidates[cotrc_idx] as InstalledCard
			else:
				cotrc_chosen = cotrc_candidates[0] as InstalledCard   # AI default: always trash
			if cotrc_chosen == null:
				ctx.send_log("Charm Offensive: runner declines to trash.")
				return
			var cotrc_srv: Server = ctx.get_server(cotrc_chosen.server_id)
			if cotrc_srv != null:
				if cotrc_chosen.zone == "ice":
					cotrc_srv.remove_ice(cotrc_chosen)
				else:
					cotrc_srv.remove_from_root(cotrc_chosen)
				ctx.remove_empty_remote_servers()
			ctx.unregister_all_card_effects(cotrc_chosen.runtime_instance_id)
			if cotrc_chosen.card_record != null:
				ctx.corp_discard.append(cotrc_chosen.card_record)
			ctx.send_log("Charm Offensive: %s trashes %s." % [ctx.runner_name(), cotrc_chosen.display_name()])

		# ── Identity flip ────────────────────────────────────────────────────────

		"flip_identity":
			# Flip a dual-faced identity to its other face.
			# params:
			#   face         : "runner" | "corp"
			#   flip_to      : String  — abilities.json key for the new face
			#   flip_title   : String  — display title of the new face (full "Name: Subtitle" form)
			#   condition    : String? — "mu_full" | "mu_has_unused" | "server_is_hq_or_rd" |
			#                            "corp_played_operation" | "" (no condition)
			#   optional     : bool    — if true, ask the runner before flipping
			#   on_flip      : Array   — sub-effects to execute after flip succeeds
			var fi_face:      String = params.get("face",       "runner")
			var fi_flip_to:   String = params.get("flip_to",    "")
			var fi_flip_title:String = params.get("flip_title", "")
			var fi_condition: String = params.get("condition",  "")
			var fi_optional:  bool   = params.get("optional",   false)
			var fi_on_flip:   Array  = params.get("on_flip",    []) as Array

			if fi_flip_to == "":
				push_error("flip_identity: flip_to not specified")
				return

			# ── Condition check ──────────────────────────────────────────────
			match fi_condition:
				"mu_full":
					if ctx.runner_mu_available() != 0:
						return   # condition not met
				"mu_has_unused":
					if ctx.runner_mu_available() < 1:
						return
				"server_is_hq_or_rd":
					var fi_server_id: String = ctx.current_event_data.get("server_id", "")
					if fi_server_id not in ["hq", "rd"]:
						return
				"corp_played_operation":
					if not ctx.corp_played_operation_this_turn:
						return
				_:
					pass  # no condition (or unrecognised — treat as always met)

			# ── Optional check ───────────────────────────────────────────────
			if fi_optional:
				var fi_want_flip: bool = false
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_flip_identity"):
					fi_want_flip = await ctx.runner_decision_maker.choose_flip_identity(fi_flip_title, ctx)
				else:
					fi_want_flip = true   # AI default: always flip
				if not fi_want_flip:
					ctx.send_log("Identity flip declined.")
					return

			# ── Perform flip ─────────────────────────────────────────────────
			if not ctx.has_meta("reregister_identity"):
				push_error("flip_identity: reregister_identity callable missing from ctx")
				return
			var fi_reregister: Callable = ctx.get_meta("reregister_identity") as Callable
			var fi_instance_id: String = "identity_runner" if fi_face == "runner" else "identity_corp"
			if fi_face == "runner":
				ctx.runner_identity_face_title = fi_flip_title
			else:
				ctx.corp_identity_face_title = fi_flip_title
			fi_reregister.call(fi_instance_id, fi_flip_to)
			ctx.send_log("Identity flip: now playing as %s." % fi_flip_title)

			# ── on_flip sub-effects ──────────────────────────────────────────
			for fi_eff in fi_on_flip:
				await _execute_effect(fi_eff as Dictionary, ctx, null)

		# ── Faceup card hosting effects ───────────────────────────────────────────

		"host_top_of_stack_faceup":
			# Bling: trigger on runner_installs_card event; only fires when credits_paid == 0.
			var htsf_only_free: bool = params.get("only_if_free", true)
			if htsf_only_free:
				var htsf_paid: int = ctx.current_event_data.get("credits_paid", -1) as int
				if htsf_paid != 0:
					return
			# Find the Bling InstalledCard via event card_instance_id
			var htsf_host := _get_self_card(ctx)
			if htsf_host == null:
				ctx.send_log("host_top_of_stack_faceup: host card not found.")
				return
			if ctx.runner_deck.is_empty():
				ctx.send_log("%s: stack is empty — nothing to host." % htsf_host.display_name())
				return
			var htsf_card: CardRecord = ctx.runner_deck.pop_front() as CardRecord
			htsf_host.faceup_hosted_cards.append(htsf_card)
			ctx.send_log("%s: %s hosts %s faceup from top of stack." % [
				ctx.runner_name(), htsf_host.display_name(), htsf_card.title
			])

		"trash_faceup_hosted_cards":
			# Bling: at start of runner's turn, trash all hosted cards.
			var tfhc_host := _get_self_card(ctx)
			if tfhc_host == null or tfhc_host.faceup_hosted_cards.is_empty():
				return
			for tfhc_cr in tfhc_host.faceup_hosted_cards:
				var tfhc_r: CardRecord = tfhc_cr as CardRecord
				if tfhc_r != null:
					ctx.runner_discard.append(tfhc_r)
					ctx.send_log("%s: trashing hosted %s." % [tfhc_host.display_name(), tfhc_r.title])
			tfhc_host.faceup_hosted_cards.clear()

		"host_programs_from_grip_and_optionally_install":
			# Madani click action: choose programs from grip to stage, then optionally install one.
			var hpfg_host := _get_self_card(ctx)
			if hpfg_host == null:
				ctx.send_log("Madani: host card not found.")
				return
			# Gather programs from hand
			var hpfg_programs: Array = []
			for hpfg_entry in ctx.runner_hand:
				var hpfg_e: Dictionary = hpfg_entry as Dictionary
				var hpfg_r: CardRecord = hpfg_e.get("card_record", null) as CardRecord
				if hpfg_r != null and hpfg_r.card_type == "program":
					hpfg_programs.append(hpfg_entry)
			if hpfg_programs.is_empty():
				ctx.send_log("Madani: no programs in grip to host.")
				return
			# Ask runner to choose programs to stage (may choose multiple)
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_programs_to_host"):
				var hpfg_chosen: Array = await ctx.runner_decision_maker.choose_programs_to_host(hpfg_programs, ctx)
				for hpfg_choice in hpfg_chosen:
					var hpfg_entry: Dictionary = hpfg_choice as Dictionary
					var hpfg_cr: CardRecord = hpfg_entry.get("card_record", null) as CardRecord
					if hpfg_cr == null:
						continue
					ctx.runner_hand.erase(hpfg_choice)
					hpfg_host.faceup_hosted_cards.append(hpfg_cr)
					ctx.send_log("Madani: %s stages %s." % [ctx.runner_name(), hpfg_cr.title])
			else:
				# AI default: stage all programs
				for hpfg_entry in hpfg_programs:
					var hpfg_cr: CardRecord = (hpfg_entry as Dictionary).get("card_record", null) as CardRecord
					if hpfg_cr == null:
						continue
					ctx.runner_hand.erase(hpfg_entry)
					hpfg_host.faceup_hosted_cards.append(hpfg_cr)
					ctx.send_log("Madani: %s stages %s." % [ctx.runner_name(), hpfg_cr.title])
			# Optional install: pick one hosted program to install now
			if hpfg_host.faceup_hosted_cards.is_empty():
				return
			var hpfg_installable: Array = []
			for hpfg_cr in hpfg_host.faceup_hosted_cards:
				var hpfg_r: CardRecord = hpfg_cr as CardRecord
				if hpfg_r == null:
					continue
				var hpfg_cost: int = max(0, hpfg_r.cost)
				if hpfg_r.memory_cost > 0 and ctx.runner_mu_available() < hpfg_r.memory_cost:
					continue
				if ctx.runner_credits >= hpfg_cost:
					hpfg_installable.append(hpfg_r)
			if hpfg_installable.is_empty():
				ctx.send_log("Madani: no hosted programs can be afforded or fit in MU.")
				return
			var hpfg_to_install: CardRecord = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_heap"):
				hpfg_to_install = await ctx.runner_decision_maker.choose_from_heap(hpfg_installable, ctx)
			else:
				hpfg_to_install = hpfg_installable[0]
			if hpfg_to_install == null:
				ctx.send_log("Madani: runner declines to install a hosted program.")
				return
			var hpfg_pay: int = max(0, hpfg_to_install.cost)
			# DZMZ discount
			if not ctx.runner_program_install_discounted_this_turn:
				for hpfg_rig_c in ctx.runner_rig:
					var hpfg_c: InstalledCard = hpfg_rig_c as InstalledCard
					if hpfg_c != null and hpfg_c.card_id == "dzmz_optimizer":
						hpfg_pay = max(0, hpfg_pay - 1)
						ctx.runner_program_install_discounted_this_turn = true
						ctx.send_log("DZMZ Optimizer: Madani install costs 1 less (now %d¢)." % hpfg_pay)
						break
			ctx.runner_credits -= hpfg_pay
			hpfg_host.faceup_hosted_cards.erase(hpfg_to_install)
			var hpfg_installed := InstalledCard.make_runtime_instance(hpfg_to_install, "runner_rig", "root", true)
			ctx.runner_rig.append(hpfg_installed)
			if ctx.has_meta("register_installed_card"):
				var hpfg_reg: Callable = ctx.get_meta("register_installed_card") as Callable
				hpfg_reg.call(hpfg_installed)
			if ctx.has_meta("ability_registry"):
				var hpfg_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var hpfg_on_rez = hpfg_ab_reg.get_on_rez(hpfg_to_install.id)
				if hpfg_on_rez != null:
					ctx.current_event_data = {"card": hpfg_installed, "card_instance_id": hpfg_installed.runtime_instance_id}
					await execute_trigger(hpfg_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			if hpfg_to_install.has_subtype("virus"):
				await ctx.notify_event("runner_installs_virus", {
					"card": hpfg_installed,
					"card_instance_id": hpfg_installed.runtime_instance_id
				}, self)
			await ctx.notify_event("runner_installs_card", {
				"credits_paid": hpfg_pay,
				"card": hpfg_installed,
				"card_instance_id": hpfg_installed.runtime_instance_id
			}, self)
			ctx.send_log("Madani: %s installs %s for %d¢. [MU: %d/%d]" % [
				ctx.runner_name(), hpfg_to_install.title, hpfg_pay,
				ctx.runner_mu_used(), ctx.runner_total_mu()
			])

		"host_random_hq_card":
			# Détente: on first successful HQ run, take 1 random HQ card faceup (not installed/rezzed).
			var hrhc_host := _get_self_card(ctx)
			if hrhc_host == null:
				ctx.send_log("Détente: host card not found.")
				return
			if ctx.corp_hand.is_empty():
				ctx.send_log("Détente: HQ is empty — nothing to host.")
				return
			var hrhc_idx: int = randi() % ctx.corp_hand.size()
			var hrhc_entry: Dictionary = ctx.corp_hand[hrhc_idx] as Dictionary
			var hrhc_cr: CardRecord = hrhc_entry.get("card_record", null) as CardRecord
			if hrhc_cr == null:
				return
			ctx.corp_hand.remove_at(hrhc_idx)
			hrhc_host.faceup_hosted_cards.append(hrhc_cr)
			ctx.send_log("Détente: %s takes %s from HQ faceup." % [ctx.runner_name(), hrhc_cr.title])

		"detente_trash_hosted_and_access_hq":
			# Détente click ability: return 2 hosted cards to HQ, then runner may access 1 random HQ card.
			var dtha_host := _get_self_card(ctx)
			if dtha_host == null:
				ctx.send_log("Détente: host card not found.")
				return
			if dtha_host.faceup_hosted_cards.size() < 2:
				ctx.send_log("Détente: need at least 2 hosted cards to use this ability (have %d)." % dtha_host.faceup_hosted_cards.size())
				return
			# Return first 2 hosted cards to HQ (top)
			for _dtha_i in range(2):
				var dtha_cr: CardRecord = dtha_host.faceup_hosted_cards.pop_front() as CardRecord
				if dtha_cr == null:
					continue
				ctx.corp_hand.append({"card_id": dtha_cr.id, "card_record": dtha_cr})
				ctx.send_log("Détente: %s returned to HQ." % dtha_cr.title)
			# Access 1 random HQ card
			if not ctx.corp_hand.is_empty():
				var dtha_access_idx: int = randi() % ctx.corp_hand.size()
				var dtha_access_entry: Dictionary = ctx.corp_hand[dtha_access_idx] as Dictionary
				var dtha_access_cr: CardRecord = dtha_access_entry.get("card_record", null) as CardRecord
				if dtha_access_cr != null:
					ctx.send_log("Détente: %s accesses %s from HQ." % [ctx.runner_name(), dtha_access_cr.title])
					ctx.accessed_card_id = dtha_access_cr.id
					await ctx.notify_event("access_card", {"card_id": dtha_access_cr.id, "runtime_instance_id": ""}, self)
					# Steal agendas
					if dtha_access_cr.is_agenda():
						ctx.runner_score_area.append(dtha_access_cr)
						ctx.corp_hand.remove_at(dtha_access_idx)
						ctx.send_log("Détente: %s STEALS %s!" % [ctx.runner_name(), dtha_access_cr.title])
						await ctx.notify_event("runner_steals_agenda", {
							"agenda_id": dtha_access_cr.id,
							"agenda_points": dtha_access_cr.agenda_points
						}, self)
					else:
						ctx.send_log("Détente: %s is not an agenda — cannot be stolen." % dtha_access_cr.title)
			else:
				ctx.send_log("Détente: HQ is empty — no access.")

		"gamedragon_attach_to_icebreaker":
			# GAMEDRAGON Pro: on install and on turn start, may host self on a non-AI icebreaker.
			var gdati_self := _get_self_card(ctx)
			if gdati_self == null:
				ctx.send_log("GAMEDRAGON Pro: card not found.")
				return
			# Gather non-AI icebreakers (not self)
			var gdati_candidates: Array = []
			for gdati_rig_c in ctx.runner_rig:
				var gdati_c: InstalledCard = gdati_rig_c as InstalledCard
				if gdati_c == null or gdati_c.card_record == null:
					continue
				if gdati_c.runtime_instance_id == gdati_self.runtime_instance_id:
					continue  # don't host on self
				var gdati_subtypes: Array = gdati_c.card_record.subtypes
				if gdati_subtypes.has("icebreaker") or \
				   gdati_subtypes.has("fracter") or gdati_subtypes.has("decoder") or \
				   gdati_subtypes.has("killer"):
					if not gdati_subtypes.has("ai"):
						gdati_candidates.append(gdati_c)
			if gdati_candidates.is_empty():
				ctx.send_log("GAMEDRAGON Pro: no eligible icebreakers to attach to.")
				return
			var gdati_chosen: InstalledCard = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_host_ice"):
				# Reuse choose_host_ice proxy for icebreaker selection
				gdati_chosen = await ctx.runner_decision_maker.choose_host_ice(ctx)
				# Verify the choice is actually an icebreaker candidate (not ice)
				if gdati_chosen != null and not gdati_candidates.has(gdati_chosen):
					gdati_chosen = gdati_candidates[0]
			if gdati_chosen == null:
				gdati_chosen = gdati_candidates[0]
			gdati_self.hosted_on_id = gdati_chosen.runtime_instance_id
			ctx.send_log("GAMEDRAGON Pro: attached to %s (+1 str; pumps persist this run)." % gdati_chosen.display_name())

		# ── Chromatophores: grant subtypes to host ice ───────────────────────────────

		"grant_subtypes_to_host_ice":
			# Fires on Chromatophores' on_rez: adds barrier, code_gate, sentry to the host ice's
			# extra_subtypes.  Reversed automatically when Chromatophores is trashed.
			var gst_subtypes: Array = params.get("subtypes", []) as Array
			var gst_self := _get_self_card(ctx)
			if gst_self == null or gst_self.hosted_on_id == "":
				push_error("AbilityInterpreter: grant_subtypes_to_host_ice — no host ice found")
				return
			var gst_host := ctx.get_ice_by_instance_id(gst_self.hosted_on_id)
			if gst_host == null:
				push_error("AbilityInterpreter: grant_subtypes_to_host_ice — host ice not found (hosted_on_id=%s)" % gst_self.hosted_on_id)
				return
			for gst_st in gst_subtypes:
				var gst_normalized: String = (gst_st as String).to_lower().replace(" ", "_")
				if not gst_host.extra_subtypes.has(gst_normalized):
					gst_host.extra_subtypes.append(gst_normalized)
				if not gst_self.granted_subtypes_to_host.has(gst_normalized):
					gst_self.granted_subtypes_to_host.append(gst_normalized)
			ctx.send_log("%s: %s gains [%s] as additional subtypes." % [
				gst_self.display_name(), gst_host.display_name(), ", ".join(gst_subtypes)
			])

		# ── Lycian Multi-Munition: choose subtypes on rez ───────────────────────

		"choose_and_grant_subtypes_to_self":
			# On rez: Corp picks 1 or more subtypes from a fixed list; grants them to self.
			# params: { "options": ["barrier","code_gate","sentry"], "min_choices": 1 }
			# The decision is made by the Corp decision-maker (AI or human).
			var cags_options: Array  = params.get("options", []) as Array
			var cags_min: int        = params.get("min_choices", 1)
			var cags_self := _get_self_card(ctx)
			if cags_self == null:
				push_error("AbilityInterpreter: choose_and_grant_subtypes_to_self — no self card")
				return
			# Build mode list for choose_modes
			var cags_modes: Array = []
			for cags_opt in cags_options:
				cags_modes.append({"label": (cags_opt as String).replace("_", " ").capitalize()})
			# Corp chooses; max = all options, min enforced by only accepting non-empty result
			var cags_dm = ctx.corp_decision_maker
			var cags_indices: Array = []
			if cags_dm != null and cags_dm.has_method("choose_modes"):
				cags_indices = await cags_dm.choose_modes(cags_modes, cags_options.size(), ctx)
			if cags_indices.is_empty() or (cags_dm != null and not cags_dm.has_method("choose_modes")):
				# AI or no DM: choose all available subtypes for maximum flexibility
				cags_indices = range(cags_options.size())
			# Apply chosen subtypes
			var cags_chosen_labels: Array = []
			for cags_idx in cags_indices:
				var cags_idx_int: int = int(cags_idx)
				if cags_idx_int >= 0 and cags_idx_int < cags_options.size():
					var cags_norm: String = (cags_options[cags_idx_int] as String).to_lower().replace(" ", "_")
					if not cags_self.extra_subtypes.has(cags_norm):
						cags_self.extra_subtypes.append(cags_norm)
					cags_chosen_labels.append(cags_norm.replace("_", " ").capitalize())
			ctx.send_log("%s gains subtype(s): [%s]." % [
				cags_self.display_name(), ", ".join(cags_chosen_labels)
			])

		# ── Lycian Multi-Munition: grant chosen subtypes to self ────────────────

		"grant_subtypes_to_self":
			# Fired from on_rez after Corp chooses subtypes via choose_modes.
			# Appends each chosen subtype (normalised) to this ice's extra_subtypes.
			# Cleared by derez_self when the ice is derezzed at turn end.
			var gss_subtypes: Array = params.get("subtypes", []) as Array
			var gss_self := _get_self_card(ctx)
			if gss_self == null:
				push_error("AbilityInterpreter: grant_subtypes_to_self — no self card in ctx")
				return
			for gss_st in gss_subtypes:
				var gss_norm: String = (gss_st as String).to_lower().replace(" ", "_")
				if not gss_self.extra_subtypes.has(gss_norm):
					gss_self.extra_subtypes.append(gss_norm)
			ctx.send_log("%s gains subtype(s): [%s]." % [
				gss_self.display_name(), ", ".join(gss_subtypes)
			])

		# ── Derez self (clears runtime extra_subtypes first) ─────────────────────

		"derez_self":
			# Derez the owning card.  Also clears any runtime-granted extra_subtypes
			# so they don't persist into the next rez cycle.
			# Used by: Lycian Multi-Munition (derez at end of any turn).
			var ds_self := _get_self_card(ctx)
			if ds_self == null or not ds_self.is_rezzed:
				return
			ds_self.extra_subtypes.clear()
			await _derez_card(ds_self, ctx)

		# ── IP Enforcement: Corp takes agenda from Runner's score area ────────────

		"steal_agenda_from_runner_score":
			# Corp takes 1 agenda from the Runner's score area and adds it to their own.
			# Used by IP Enforcement (play only if Runner is tagged).
			if ctx.runner_score_area.is_empty():
				ctx.send_log("IP Enforcement: %s's score area is empty — no agenda to take." % ctx.runner_name())
				return

			# Corp decision maker picks which agenda to claim
			var safrs_candidates: Array = ctx.runner_score_area.duplicate()
			var safrs_chosen: CardRecord = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_from_runner_score"):
				safrs_chosen = await ctx.corp_decision_maker.choose_from_runner_score(safrs_candidates, ctx)
			else:
				# Default: pick the highest-value agenda (most swing)
				var safrs_best: CardRecord = safrs_candidates[0] as CardRecord
				for safrs_c in safrs_candidates:
					var safrs_cr: CardRecord = safrs_c as CardRecord
					if safrs_cr != null and safrs_cr.agenda_points > safrs_best.agenda_points:
						safrs_best = safrs_cr
				safrs_chosen = safrs_best

			if safrs_chosen == null:
				ctx.send_log("IP Enforcement: no agenda selected.")
				return

			# Transfer: Runner → Corp
			ctx.runner_score_area.erase(safrs_chosen)
			ctx.corp_score_area.append(safrs_chosen)
			# Create a synthetic InstalledCard so corp_score_area_cards stays in sync
			var safrs_ic := InstalledCard.make_runtime_instance(safrs_chosen, "corp_score_area", "root", true)
			ctx.corp_score_area_cards.append(safrs_ic)

			ctx.send_log("IP Enforcement: %s takes %s (%d pt%s) from %s's score area." % [
				ctx.corp_name(),
				safrs_chosen.title,
				safrs_chosen.agenda_points,
				"s" if safrs_chosen.agenda_points != 1 else "",
				ctx.runner_name()
			])

			# Fire corp_scores_agenda so listeners react (Malapert, Phat Gioan, etc.)
			await ctx.notify_event("corp_scores_agenda", {
				"agenda_id": safrs_chosen.id,
				"card_instance_id": safrs_ic.runtime_instance_id
			}, self)

			# Check Corp win
			if ctx.corp_agenda_points() >= ctx.agenda_points_to_win:
				ctx.send_log("%s wins via IP Enforcement!" % ctx.corp_name())
				ctx.game_over = true
				ctx.winner    = "corp"

		# ── Maintenance Access: set a server approach redirect ────────────────────

		"set_server_approach_redirect":
			# Stores a redirect in run_modifiers so that when the runner would approach
			# the 'from' server's root (after clearing all its ice), the RSM instead
			# changes the attacked server to 'to' and approaches it.
			# Maintenance Access: Run Archives; redirect to HQ when reaching Archives root.
			var ssr_from: String = params.get("from", "")
			var ssr_to: String   = params.get("to", "")
			if ssr_from == "" or ssr_to == "":
				push_error("AbilityInterpreter: set_server_approach_redirect missing 'from' or 'to'")
				return
			ctx.run_modifiers["server_approach_redirect"] = {"from": ssr_from, "to": ssr_to}
			ctx.send_log("Server approach redirect set: %s → %s (Maintenance Access)." % [
				ssr_from.to_upper(), ssr_to.to_upper()
			])

		# ── Proprionegation: move runner to outermost position of a server ────────

		"move_runner_to_outermost":
			# Corp paid ability (paw_action): during a run, move the runner to the outermost
			# position of the specified server.  The RSM checks run_modifiers["run_position_reset"]
			# after each PAW/encounter window and applies the reset.
			if not ctx.run_active:
				ctx.send_log("move_runner_to_outermost: no run active — ability has no effect.")
				return
			var mro_server_id: String = params.get("server_id", "archives")
			ctx.run_modifiers["run_position_reset"] = {"server_id": mro_server_id}
			var mro_server: Server = ctx.get_server(mro_server_id)
			var mro_name: String = mro_server.display_name() if mro_server != null else mro_server_id.to_upper()
			ctx.send_log("Proprionegation: Runner will be moved to the outermost position of %s." % mro_name)

		# ── Knickknack O'Brian: trash own installed card for credits + draw ─────────

		"trash_installed_for_credits_and_draw":
			# Runner may trash 1 of their installed cards (optionally excluding self)
			# and gain credits equal to the trashed card's printed install cost, then draw N.
			# params: { "optional": bool, "exclude_self": bool, "draw": int }
			var tifd_optional:  bool = params.get("optional", true)
			var tifd_excl_self: bool = params.get("exclude_self", true)
			var tifd_draw_n:    int  = params.get("draw", 1)

			# Build candidate list from runner rig, excluding self if requested.
			var tifd_self := _get_self_card(ctx)
			var tifd_self_iid: String = tifd_self.runtime_instance_id if tifd_self != null else ""
			var tifd_candidates: Array = []
			for tifd_c in ctx.runner_rig:
				var tifd_ic: InstalledCard = tifd_c as InstalledCard
				if tifd_ic == null:
					continue
				if tifd_excl_self and tifd_ic.runtime_instance_id == tifd_self_iid:
					continue
				tifd_candidates.append(tifd_ic)
			# Also include programs hosted on ice (trojans, Chromatophores, etc.)
			for tifd_srv in ctx.servers.values():
				for tifd_ice in (tifd_srv as Server).ice:
					for tifd_hosted in (tifd_ice as InstalledCard).hosted_cards:
						var tifd_h: InstalledCard = tifd_hosted as InstalledCard
						if tifd_h == null:
							continue
						if tifd_excl_self and tifd_h.runtime_instance_id == tifd_self_iid:
							continue
						if not tifd_candidates.has(tifd_h):
							tifd_candidates.append(tifd_h)

			if tifd_candidates.is_empty():
				ctx.send_log("Knickknack O'Brian: no other installed cards to trash.")
				return

			# Optional gate: ask runner whether to activate at all.
			if tifd_optional:
				var tifd_want := false
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_optional_ability"):
					tifd_want = await ctx.runner_decision_maker.choose_optional_ability(
						"Knickknack O'Brian: trash an installed card to gain its printed cost in credits and draw 1?", ctx
					)
				else:
					tifd_want = true   # AI default: always sell a card
				if not tifd_want:
					ctx.send_log("Knickknack O'Brian: %s declines." % ctx.runner_name())
					return

			# Runner picks which card to sacrifice.
			var tifd_chosen: InstalledCard = null
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_trash_from_rig"):
				tifd_chosen = await ctx.runner_decision_maker.choose_trash_from_rig(tifd_candidates, ctx)
			if tifd_chosen == null:
				tifd_chosen = tifd_candidates[0] as InstalledCard

			if tifd_chosen == null or tifd_chosen.card_record == null:
				ctx.send_log("Knickknack O'Brian: no card chosen.")
				return

			var tifd_cost: int = max(0, tifd_chosen.card_record.cost)

			# Trash the chosen card.
			if tifd_chosen.hosted_on_id != "":
				# Trojan hosted on ice — clean up granted subtypes then remove from host.
				_cleanup_granted_subtypes(tifd_chosen, ctx)
				var tifd_host := ctx.get_ice_by_instance_id(tifd_chosen.hosted_on_id)
				if tifd_host != null:
					tifd_host.hosted_cards.erase(tifd_chosen)
			else:
				ctx.runner_rig.erase(tifd_chosen)
			ctx.runner_discard.append(tifd_chosen.card_record)
			ctx.unregister_all_card_effects(tifd_chosen.runtime_instance_id)
			ctx.send_log("Knickknack O'Brian: %s trashes %s (printed cost %d)." % [
				ctx.runner_name(), tifd_chosen.display_name(), tifd_cost
			])

			# Gain credits equal to printed install cost.
			if tifd_cost > 0:
				ctx.runner_credits += tifd_cost
				ctx.send_log("%s gains %d credits." % [ctx.runner_name(), tifd_cost])

			# Draw N cards.
			_draw_cards("runner", tifd_draw_n, ctx)

		# ── Semak-samun: end run unless runner suffers N damage ───────────────────

		"etr_unless_runner_suffers_damage":
			# Runner chooses: suffer N damage and continue the run, or end the run.
			var eurs_amount: int = params.get("amount", 3)
			var eurs_dtype: String = params.get("damage_type", "net")
			var eurs_take: bool = false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_suffer_damage_or_etr"):
				eurs_take = await ctx.runner_decision_maker.choose_suffer_damage_or_etr(
					eurs_amount, eurs_dtype, ctx
				)
			else:
				# AI default: take damage if grip is large enough to survive
				eurs_take = ctx.runner_hand.size() >= eurs_amount
			if eurs_take:
				ctx.send_log("Runner accepts %d %s damage to continue the run." % [eurs_amount, eurs_dtype])
				await _deal_damage(eurs_dtype, eurs_amount, ctx)
			else:
				ctx.run_ended = true
				ctx.send_log("Runner ends the run (refuses %d %s damage)." % [eurs_amount, eurs_dtype])

		# ── Aggressive Trendsetting: runner spends [click] or Corp gets +1 next turn ──

		"aggressive_trendsetting_choice":
			# The first time the Runner trashes an installed Corp card each of their turns,
			# they may spend [click]. If they do not, Corp gets +1 allotted click next turn.
			var at_can_spend: bool = ctx.runner_clicks > 0
			var at_spend: bool = false
			if at_can_spend:
				if ctx.runner_decision_maker != null and \
						ctx.runner_decision_maker.has_method("choose_optional_ability"):
					at_spend = await ctx.runner_decision_maker.choose_optional_ability(
						"Aggressive Trendsetting: spend [click] to deny the Corp a bonus click next turn?", ctx
					)
				# else: AI defaults to false (conserve clicks)
			if at_spend:
				ctx.runner_clicks -= 1
				ctx.send_log("Aggressive Trendsetting: %s spends 1 click." % ctx.runner_name())
			else:
				ctx.pending_click_bonuses["corp"] = ctx.pending_click_bonuses.get("corp", 0) + 1
				ctx.send_log("Aggressive Trendsetting: %s will get +1 click next turn." % ctx.corp_name())

		# ── LEO Construction: trash rezzed bioroid on attacked server to end the run ──

		"leo_trash_bioroid_to_etr":
			# Corp paw_action: trash 1 rezzed bioroid in the root of or protecting
			# the currently attacked server. If a valid target exists and is trashed,
			# end the run.
			if not ctx.run_active:
				ctx.send_log("LEO: no run active.")
				return
			var leo_server: Server = ctx.get_server(ctx.run_target_server)
			if leo_server == null:
				ctx.send_log("LEO: attacked server not found.")
				return
			var leo_candidates: Array = []
			for leo_c in leo_server.root:
				var leo_ic: InstalledCard = leo_c as InstalledCard
				if leo_ic != null and leo_ic.is_rezzed and leo_ic.card_record != null \
						and leo_ic.card_record.has_subtype("bioroid"):
					leo_candidates.append(leo_ic)
			for leo_c in leo_server.ice:
				var leo_ic: InstalledCard = leo_c as InstalledCard
				if leo_ic != null and leo_ic.is_rezzed and leo_ic.card_record != null \
						and leo_ic.card_record.has_subtype("bioroid"):
					leo_candidates.append(leo_ic)
			if leo_candidates.is_empty():
				ctx.send_log("LEO: no rezzed bioroid cards on %s." % leo_server.display_name())
				return
			var leo_dm: Object = ctx.corp_decision_maker
			var leo_chosen: InstalledCard = null
			if leo_dm != null and leo_dm.has_method("choose_target"):
				leo_chosen = await leo_dm.choose_target(leo_candidates, {"reason": "leo_trash_bioroid"})
			if leo_chosen == null:
				leo_chosen = leo_candidates[0]
			# Remove from whichever zone it occupies
			if leo_chosen.zone == "ice":
				leo_server.ice.erase(leo_chosen)
			else:
				leo_server.root.erase(leo_chosen)
			if leo_chosen.card_record != null:
				ctx.corp_discard.append(leo_chosen.card_record)
			ctx.unregister_all_card_effects(leo_chosen.runtime_instance_id)
			ctx.remove_empty_remote_servers()
			ctx.send_log("LEO: %s trashes %s — run ends." % [ctx.corp_name(), leo_chosen.display_name()])
			ctx.run_ended = true

		# ── Magdalene Keino Chemutai: install program or hardware from just-discarded cards ─

		"magdalene_install_from_discarded":
			# Runner may install 1 program or piece of hardware from among the cards
			# they just discarded to reach their maximum hand size. The chosen card is
			# pulled back from runner_discard and installed ignoring the install cost.
			var mifd_discarded: Array = ctx.current_event_data.get("discarded_cards", []) as Array
			var mifd_candidates: Array = []
			for mifd_cr in mifd_discarded:
				var mifd_r: CardRecord = mifd_cr as CardRecord
				if mifd_r != null and mifd_r.card_type in ["program", "hardware"]:
					# Only offer if the card is still in the discard pile (not already rescued)
					if ctx.runner_discard.has(mifd_r):
						mifd_candidates.append(mifd_r)
			if mifd_candidates.is_empty():
				ctx.send_log("Magdalene: no programs or hardware among discarded cards.")
				return
			var mifd_want: bool = false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
				mifd_want = await ctx.runner_decision_maker.choose_optional_ability(
					"Magdalene: install 1 program or hardware from among the cards you just discarded (ignoring cost)?", ctx
				)
			else:
				mifd_want = true   # AI default: always rescue
			if not mifd_want:
				ctx.send_log("Magdalene: %s declines." % ctx.runner_name())
				return
			var mifd_chosen: CardRecord = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_discard"):
				mifd_chosen = await ctx.runner_decision_maker.choose_card_from_discard(mifd_candidates, ctx)
			if mifd_chosen == null:
				mifd_chosen = mifd_candidates[0]
			if mifd_chosen == null:
				return
			# MU check for programs
			if mifd_chosen.card_type == "program" and mifd_chosen.memory_cost > 0:
				if ctx.runner_mu_available() < mifd_chosen.memory_cost:
					ctx.send_log("Magdalene: not enough MU to install %s." % mifd_chosen.title)
					return
			# Pull it out of the discard pile and install it
			ctx.runner_discard.erase(mifd_chosen)
			var mifd_inst := InstalledCard.make_runtime_instance(mifd_chosen, "runner_rig", "root", true)
			ctx.runner_rig.append(mifd_inst)
			if ctx.has_meta("register_installed_card"):
				(ctx.get_meta("register_installed_card") as Callable).call(mifd_inst)
			if ctx.has_meta("ability_registry"):
				var mifd_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var mifd_on_rez = mifd_reg.get_on_rez(mifd_chosen.id)
				if mifd_on_rez != null:
					ctx.current_event_data = {"card": mifd_inst, "card_instance_id": mifd_inst.runtime_instance_id}
					await execute_trigger(mifd_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			ctx.send_log("Magdalene: %s installs %s from heap (ignoring cost). [MU: %d/%d]" % [
				ctx.runner_name(), mifd_chosen.title,
				ctx.runner_mu_used(), ctx.runner_total_mu()
			])

		# ── Barry "Baz" Wong: install 1 resource or hardware from grip ───────────────

		"install_resource_or_hardware_from_grip":
			# Barry: whenever Corp rezzes ice, Runner may install 1 resource or hardware
			# from their grip, ignoring the install cost.
			var irhg_types: Array = ["hardware", "resource"]
			var irhg_candidates: Array = []
			for irhg_entry in ctx.runner_hand:
				var irhg_r: CardRecord = (irhg_entry as Dictionary).get("card_record", null) as CardRecord
				if irhg_r != null and irhg_r.card_type in irhg_types:
					irhg_candidates.append(irhg_entry)
			if irhg_candidates.is_empty():
				ctx.send_log("Barry 'Baz' Wong: no resource or hardware in grip.")
				return
			var irhg_want: bool = false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
				irhg_want = await ctx.runner_decision_maker.choose_optional_ability(
					"Barry 'Baz' Wong: install 1 resource or hardware from grip (ignoring cost)?", ctx
				)
			else:
				irhg_want = true   # AI default: always install
			if not irhg_want:
				ctx.send_log("Barry 'Baz' Wong: %s declines." % ctx.runner_name())
				return
			var irhg_dm: Object = ctx.runner_decision_maker
			var irhg_chosen: Variant = null
			if irhg_dm != null and irhg_dm.has_method("choose_card_from_hand"):
				irhg_chosen = await irhg_dm.choose_card_from_hand(irhg_candidates, ctx)
			if irhg_chosen == null:
				irhg_chosen = irhg_candidates[0]
			var irhg_record: CardRecord = (irhg_chosen as Dictionary).get("card_record", null) as CardRecord
			if irhg_record == null:
				return
			ctx.runner_hand.erase(irhg_chosen)
			var irhg_inst := InstalledCard.make_runtime_instance(irhg_record, "runner_rig", "root", true)
			ctx.runner_rig.append(irhg_inst)
			if ctx.has_meta("register_installed_card"):
				(ctx.get_meta("register_installed_card") as Callable).call(irhg_inst)
			if ctx.has_meta("ability_registry"):
				var irhg_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var irhg_on_rez = irhg_reg.get_on_rez(irhg_record.id)
				if irhg_on_rez != null:
					ctx.current_event_data = {"card": irhg_inst, "card_instance_id": irhg_inst.runtime_instance_id}
					await execute_trigger(irhg_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			ctx.send_log("Barry 'Baz' Wong: %s installs %s (ignoring cost)." % [
				ctx.runner_name(), irhg_record.title
			])

		# ── Idiosyncresis: optional trash to gain 3cr per advancement counter ──────

		"idiosyncresis_activate":
			# Corp may trash this asset. If they do, for each hosted advancement
			# counter: gain 3[credit] and the Runner loses 2[credit].
			var ia_card := _get_self_card(ctx)
			if ia_card == null:
				return
			var ia_want: bool = false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_optional_ability"):
				ia_want = await ctx.corp_decision_maker.choose_optional_ability(
					"Idiosyncresis: trash this asset? (For each advancement counter: gain 3[cr], Runner loses 2[cr])", ctx
				)
			else:
				ia_want = ia_card.get_counter("advancement") > 0   # AI: only trash if there are counters
			if not ia_want:
				ctx.send_log("Idiosyncresis: %s declines to trash." % ctx.corp_name())
				return
			var ia_counters: int = ia_card.get_counter("advancement")
			var ia_server: Server = ctx.get_server(ia_card.server_id)
			if ia_server != null:
				ia_server.root.erase(ia_card)
			if ia_card.card_record != null:
				ctx.corp_discard.append(ia_card.card_record)
			ctx.unregister_all_card_effects(ia_card.runtime_instance_id)
			ctx.send_log("Idiosyncresis: %s trashes it (%d advancement counter(s))." % [ctx.corp_name(), ia_counters])
			if ia_counters > 0:
				var ia_corp_gain: int = ia_counters * 3
				ctx.corp_credits += ia_corp_gain
				ctx.send_log("%s gains %d credits." % [ctx.corp_name(), ia_corp_gain])
				var ia_lose: int = min(ia_counters * 2, ctx.runner_credits)
				ctx.runner_credits -= ia_lose
				ctx.send_log("%s loses %d credits (%d remaining)." % [ctx.runner_name(), ia_lose, ctx.runner_credits])

		# ── MuslihaT: peek top of stack, optionally add to grip if icebreaker/run ─

		"muslihat_peek_top_card":
			# Runner looks at the top card of their stack.
			# If it is an icebreaker or run event, they may reveal it and add it to their grip.
			if ctx.runner_deck.is_empty():
				ctx.send_log("MuslihaT: stack is empty.")
				return
			var mpt_entry: Dictionary = ctx.runner_deck.back() as Dictionary
			var mpt_record: CardRecord = mpt_entry.get("card_record", null) as CardRecord
			if mpt_record == null:
				return
			ctx.send_log("MuslihaT: %s peeks at the top of their stack." % ctx.runner_name())
			var mpt_qualifies: bool = mpt_record.has_subtype("icebreaker") or mpt_record.has_subtype("run")
			if not mpt_qualifies:
				ctx.send_log("MuslihaT: top card is not an icebreaker or run event — not revealed.")
				return
			var mpt_want: bool = false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
				mpt_want = await ctx.runner_decision_maker.choose_optional_ability(
					"MuslihaT: reveal %s and add it to your grip?" % mpt_record.title, ctx
				)
			else:
				mpt_want = true   # AI default: always take it
			if mpt_want:
				ctx.runner_deck.erase(mpt_entry)
				ctx.runner_hand.append(mpt_entry)
				ctx.send_log("MuslihaT: reveals %s and adds it to the grip." % mpt_record.title)
			else:
				ctx.send_log("MuslihaT: %s declines." % ctx.runner_name())

		# ── Topan: install 1 card from grip at 2cr less, then suffer 1 meat damage ─

		"topan_install_from_grip_discounted":
			# Runner installs 1 card from their grip, paying 2[credit] less.
			# After the install, the Runner suffers 1 meat damage.
			var tigd_installable: Array = []
			for tigd_entry in ctx.runner_hand:
				var tigd_r: CardRecord = (tigd_entry as Dictionary).get("card_record", null) as CardRecord
				if tigd_r != null and tigd_r.card_type in ["program", "hardware", "resource"]:
					tigd_installable.append(tigd_entry)
			if tigd_installable.is_empty():
				ctx.send_log("Topan: no installable cards in grip.")
				return
			var tigd_dm: Object = ctx.runner_decision_maker
			var tigd_chosen: Variant = null
			if tigd_dm != null and tigd_dm.has_method("choose_card_from_hand"):
				tigd_chosen = await tigd_dm.choose_card_from_hand(tigd_installable, ctx)
			if tigd_chosen == null:
				tigd_chosen = tigd_installable[0]
			var tigd_record: CardRecord = (tigd_chosen as Dictionary).get("card_record", null) as CardRecord
			if tigd_record == null:
				return
			var tigd_cost: int = max(0, tigd_record.cost - 2)
			if ctx.runner_credits < tigd_cost:
				ctx.send_log("Topan: can't afford %s (cost %d after 2cr discount)." % [tigd_record.title, tigd_cost])
				return
			if tigd_record.card_type == "program" and tigd_record.memory_cost > 0:
				if ctx.runner_mu_available() < tigd_record.memory_cost:
					ctx.send_log("Topan: not enough MU to install %s." % tigd_record.title)
					return
			ctx.runner_credits -= tigd_cost
			ctx.runner_hand.erase(tigd_chosen)
			var tigd_inst := InstalledCard.make_runtime_instance(tigd_record, "runner_rig", "root", true)
			ctx.runner_rig.append(tigd_inst)
			if ctx.has_meta("register_installed_card"):
				(ctx.get_meta("register_installed_card") as Callable).call(tigd_inst)
			if ctx.has_meta("ability_registry"):
				var tigd_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var tigd_on_rez = tigd_reg.get_on_rez(tigd_record.id)
				if tigd_on_rez != null:
					ctx.current_event_data = {"card": tigd_inst, "card_instance_id": tigd_inst.runtime_instance_id}
					await execute_trigger(tigd_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			ctx.send_log("Topan: %s installs %s for %d cr (2cr discount). [MU: %d/%d]" % [
				ctx.runner_name(), tigd_record.title, tigd_cost,
				ctx.runner_mu_used(), ctx.runner_total_mu()
			])
			ctx.send_log("Topan: %s suffers 1 meat damage." % ctx.runner_name())
			await _deal_damage("meat", 1, ctx)

		# ── Poétrï Luxury Brands: look top 3 R&D, install 1 non-agenda ───────────

		"look_top_3_rd_install_non_agenda":
			# Corp looks at the top 3 cards of R&D (index 0 = top, drawn via pop_front).
			# May install 1 non-agenda card from among them, ignoring all costs.
			if ctx.corp_deck.is_empty():
				ctx.send_log("Poétrï: R&D is empty — nothing to look at.")
				return
			var lt3_count: int = min(3, ctx.corp_deck.size())
			var lt3_candidates: Array = []
			for lt3_i in range(lt3_count):
				var lt3_r: CardRecord = ctx.corp_deck[lt3_i] as CardRecord
				if lt3_r != null and lt3_r.card_type != "agenda":
					lt3_candidates.append(lt3_r)
			if lt3_candidates.is_empty():
				ctx.send_log("Poétrï: no non-agenda cards in top %d of R&D." % lt3_count)
				return
			var lt3_dm: Object = ctx.corp_decision_maker
			var lt3_chosen: CardRecord = null
			if lt3_dm != null and lt3_dm.has_method("choose_from_search"):
				lt3_chosen = await lt3_dm.choose_from_search(lt3_candidates, ctx)
			if lt3_chosen == null:
				ctx.send_log("Poétrï: Corp declines to install from R&D.")
				return
			ctx.corp_deck.erase(lt3_chosen)
			var lt3_server: Server = ctx.create_remote_server()
			var lt3_z: String = "ice" if lt3_chosen.is_ice() else "root"
			var lt3_inst := _install_corp_card(lt3_chosen, lt3_server, lt3_z, false)
			ctx.send_log("Poétrï: %s installs %s from R&D on %s (ignoring costs)." % [
				ctx.corp_name(), lt3_chosen.title, lt3_server.display_name()
			])

		# ── Poétrï Luxury Brands: install 1 non-agenda from HQ ───────────────────

		"install_non_agenda_from_hq":
			# Corp installs 1 non-agenda card from HQ, ignoring all costs.
			var inafh_candidates: Array = []
			for inafh_entry in ctx.corp_hand:
				var inafh_r: CardRecord = (inafh_entry as Dictionary).get("card_record", null) as CardRecord
				if inafh_r != null and inafh_r.card_type != "agenda":
					inafh_candidates.append(inafh_entry)
			if inafh_candidates.is_empty():
				ctx.send_log("Poétrï: no non-agenda cards in HQ to install.")
				return
			var inafh_dm: Object = ctx.corp_decision_maker
			var inafh_chosen: Variant = null
			if inafh_dm != null and inafh_dm.has_method("choose_card_from_hand"):
				inafh_chosen = await inafh_dm.choose_card_from_hand(inafh_candidates, ctx)
			if inafh_chosen == null:
				inafh_chosen = inafh_candidates[0]   # AI default: install first candidate
			var inafh_record: CardRecord = (inafh_chosen as Dictionary).get("card_record", null) as CardRecord
			if inafh_record == null:
				return
			ctx.corp_hand.erase(inafh_chosen)
			var inafh_server: Server = ctx.create_remote_server()
			var inafh_z: String = "ice" if inafh_record.is_ice() else "root"
			var inafh_inst := _install_corp_card(inafh_record, inafh_server, inafh_z, false)
			ctx.send_log("Poétrï: %s installs %s from HQ on %s (ignoring costs)." % [
				ctx.corp_name(), inafh_record.title, inafh_server.display_name()
			])

		# ── Mercia B4LL4RD: install ice from HQ at 1cr less, move self to its server

		# ── RWR Tributary: move self to outermost ice position ───────────────────

		"move_self_to_outermost_position":
			# Corp may move this ice to index 0 (outermost) of its protecting server.
			# Used by Tributary's run_start trigger.
			# params: { optional: bool }
			var msop_opt: bool = params.get("optional", true)
			var msop_self := _get_self_card(ctx)
			if msop_self == null:
				push_error("AbilityInterpreter: move_self_to_outermost_position — no self card")
				return

			var msop_server: Server = ctx.get_server(msop_self.server_id)
			if msop_server == null or msop_server.ice.is_empty():
				return

			# Already outermost — nothing to do.
			if msop_server.ice.size() > 0 and (msop_server.ice[0] as InstalledCard).runtime_instance_id == msop_self.runtime_instance_id:
				ctx.send_log("Tributary: already at the outermost position.")
				return

			if msop_opt:
				var msop_dm: Object = ctx.corp_decision_maker
				var msop_want: bool = true
				if not ctx.simulation_mode and msop_dm != null and msop_dm.has_method("choose_optional_ability"):
					msop_want = await msop_dm.choose_optional_ability(
						"Move Tributary to the outermost position of %s?" % msop_server.display_name(), ctx)
				# AI: always move (forces runner to encounter it, maximising sub value)
				if not msop_want:
					ctx.send_log("Tributary: %s declines to move." % ctx.corp_name())
					return

			# Move self to index 0.
			msop_server.ice.erase(msop_self)
			msop_server.ice.insert(0, msop_self)
			ctx.send_log("Tributary: %s moves to the outermost position of %s." % [
				msop_self.display_name(), msop_server.display_name()])

		"mercia_install_ice_and_move_self":
			# Corp may install 1 ice from HQ, paying 1[credit] less.
			# If installed, move Mercia to the root of the server that ice is protecting.
			var miams_candidates: Array = []
			for miams_entry in ctx.corp_hand:
				var miams_r: CardRecord = (miams_entry as Dictionary).get("card_record", null) as CardRecord
				if miams_r != null and miams_r.is_ice():
					miams_candidates.append(miams_entry)
			if miams_candidates.is_empty():
				ctx.send_log("Mercia: no ice in HQ to install.")
				return
			var miams_want: bool = false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_optional_ability"):
				miams_want = await ctx.corp_decision_maker.choose_optional_ability(
					"Mercia B4LL4RD: install 1 ice from HQ (1cr discount) and move Mercia to that server?", ctx
				)
			else:
				miams_want = true
			if not miams_want:
				ctx.send_log("Mercia: %s declines." % ctx.corp_name())
				return
			var miams_dm: Object = ctx.corp_decision_maker
			var miams_chosen: Variant = null
			if miams_dm != null and miams_dm.has_method("choose_card_from_hand"):
				miams_chosen = await miams_dm.choose_card_from_hand(miams_candidates, ctx)
			if miams_chosen == null:
				miams_chosen = miams_candidates[0]
			var miams_record: CardRecord = (miams_chosen as Dictionary).get("card_record", null) as CardRecord
			if miams_record == null:
				return
			var miams_cost: int = max(0, miams_record.cost - 1)
			if ctx.corp_credits < miams_cost:
				ctx.send_log("Mercia: can't afford %s (cost %d after 1cr discount)." % [miams_record.title, miams_cost])
				return
			ctx.corp_credits -= miams_cost
			ctx.corp_hand.erase(miams_chosen)
			var miams_server: Server = ctx.create_remote_server()
			var miams_inst := InstalledCard.make_runtime_instance(miams_record, miams_server.server_id, "ice", false)
			miams_server.install_ice(miams_inst)
			ctx.send_log("Mercia: %s installs %s on %s for %d cr." % [
				ctx.corp_name(), miams_record.title, miams_server.display_name(), miams_cost
			])
			# Move Mercia to the root of the newly protected server
			var miams_self := _get_self_card(ctx)
			if miams_self != null:
				var miams_old: Server = ctx.get_server(miams_self.server_id)
				if miams_old != null:
					miams_old.root.erase(miams_self)
				miams_server.install_in_root(miams_self)
				ctx.send_log("Mercia moves to the root of %s." % miams_server.display_name())

		# ── Next Big Thing: draw 4, optionally shuffle any HQ cards into R&D ──────

		"next_big_thing_draw_and_shuffle":
			# Corp draws 4 cards, then may shuffle any number of cards from HQ into R&D.
			_draw_cards("corp", 4, ctx)
			if ctx.corp_hand.is_empty():
				ctx.send_log("Next Big Thing: HQ is empty — nothing to shuffle into R&D.")
				return
			var nbt_dm: Object = ctx.corp_decision_maker
			var nbt_chosen: Array = []
			if nbt_dm != null and nbt_dm.has_method("choose_cards_to_shuffle_into_deck"):
				nbt_chosen = await nbt_dm.choose_cards_to_shuffle_into_deck(ctx.corp_hand.duplicate(), ctx)
			for nbt_entry in nbt_chosen:
				ctx.corp_hand.erase(nbt_entry)
				ctx.corp_deck.append(nbt_entry)
			if not nbt_chosen.is_empty():
				ctx.corp_deck.shuffle()
				ctx.send_log("Next Big Thing: %s shuffles %d card(s) from HQ into R&D." % [
					ctx.corp_name(), nbt_chosen.size()
				])
			else:
				ctx.send_log("Next Big Thing: no cards shuffled from HQ.")

		# ── AU Co.: The Gold Standard in Clones: spend 2 counters, look top 3 R&D

		"au_co_activate":
			var au_counters: int = ctx.corp_identity_counters.get("power", 0)
			if au_counters < 2:
				ctx.send_log("AU Co.: Only %d power counter(s) — need 2 to activate." % au_counters)
				return
			var au_use: bool = false
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_optional_ability"):
				au_use = await ctx.corp_decision_maker.choose_optional_ability(
					"AU Co.: Remove 2 power counters to look at top 3 R&D, trash 1, add rest to HQ?", ctx
				)
			else:
				au_use = au_counters >= 2
			if not au_use:
				ctx.send_log("AU Co.: %s passes on the ability." % ctx.corp_name())
				return
			ctx.corp_identity_counters["power"] -= 2
			ctx.send_log("AU Co.: Removed 2 power counters. Remaining: %d" % \
				ctx.corp_identity_counters.get("power", 0))
			# Look at top 3 of R&D
			var au_count: int = min(3, ctx.corp_deck.size())
			if au_count == 0:
				ctx.send_log("AU Co.: R&D is empty.")
				return
			var au_top: Array = []
			for _au_i in range(au_count):
				au_top.append(ctx.corp_deck[_au_i] as CardRecord)
			ctx.send_log("AU Co.: %s looks at top %d card(s) of R&D." % [ctx.corp_name(), au_count])
			# Corp chooses 1 to trash
			var au_trash: CardRecord = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_card_to_trash"):
				au_trash = await ctx.corp_decision_maker.choose_card_to_trash(au_top.duplicate(), ctx)
			if au_trash == null:
				au_trash = au_top[0] as CardRecord
			# Remove all looked-at cards from top of deck, then distribute
			for _au_i in range(au_count):
				ctx.corp_deck.pop_front()
			for au_card in au_top:
				if au_card == au_trash:
					ctx.corp_discard.append(au_card)
					ctx.corp_discard_facedown[au_card.title] = false
					ctx.send_log("AU Co.: Trashed %s (%s) from R&D." % [au_card.title, au_card.card_type])
				else:
					ctx.corp_hand.append({"card_id": au_card.id, "card_record": au_card})
					ctx.send_log("AU Co.: Added %s to HQ." % au_card.title)

		# ── PT Untaian: pay 1cr to place 1 advancement on unrezzed advanceable card ─

		"pt_untaian_advance":
			# Condition baked in: fires only when HQ has ≤ 3 cards after discard.
			if ctx.corp_hand.size() > 3:
				return
			if ctx.corp_credits < 1:
				ctx.send_log("PT Untaian: %s cannot afford 1cr." % ctx.corp_name())
				return
			# Build pool of unrezzed advanceable cards
			var ptu_pool: Array = []
			for ptu_sv in ctx.servers.values():
				var ptu_s: Server = ptu_sv as Server
				for ptu_c in ptu_s.root:
					var ptu_ic: InstalledCard = ptu_c as InstalledCard
					if not ptu_ic.is_rezzed and ptu_ic.can_be_advanced():
						ptu_pool.append(ptu_ic)
				for ptu_c in ptu_s.ice:
					var ptu_ic: InstalledCard = ptu_c as InstalledCard
					if not ptu_ic.is_rezzed and ptu_ic.can_be_advanced():
						ptu_pool.append(ptu_ic)
			if ptu_pool.is_empty():
				ctx.send_log("PT Untaian: No unrezzed advanceable cards.")
				return
			var ptu_use: bool = false
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_optional_ability"):
				ptu_use = await ctx.corp_decision_maker.choose_optional_ability(
					"PT Untaian: Pay 1[cr] to place 1 advancement counter on an unrezzed card?", ctx
				)
			else:
				ptu_use = true
			if not ptu_use:
				ctx.send_log("PT Untaian: %s declines." % ctx.corp_name())
				return
			ctx.corp_credits -= 1
			var ptu_target: InstalledCard = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_target"):
				ptu_target = await ctx.corp_decision_maker.choose_target(ptu_pool, {"reason": "pt_untaian_advance"})
			if ptu_target == null:
				ptu_target = ptu_pool[0] as InstalledCard
			ptu_target.add_counter("advancement", 1)
			ctx.send_log("PT Untaian: %s pays 1cr, places 1 advancement counter on %s. (Cannot score this turn.)" % [
				ctx.corp_name(), ptu_target.display_name()
			])

		# ── Touch-ups: place 2 advancement counters, then sabotage runner grip ───

		"touch_ups_advance_and_shuffle":
			# Step 1: Place 2 advancement counters on 1 installed advanceable card.
			var tu_pool: Array = []
			for tu_sv in ctx.servers.values():
				var tu_s: Server = tu_sv as Server
				for tu_c in tu_s.root:
					if (tu_c as InstalledCard).can_be_advanced():
						tu_pool.append(tu_c)
				for tu_c in tu_s.ice:
					if (tu_c as InstalledCard).can_be_advanced():
						tu_pool.append(tu_c)
			if tu_pool.is_empty():
				ctx.send_log("Touch-ups: No advanceable cards — cannot place counters.")
				return
			var tu_target: InstalledCard = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_target"):
				tu_target = await ctx.corp_decision_maker.choose_target(
					tu_pool, {"reason": "touch_ups_advance"}
				)
			if tu_target == null:
				tu_target = tu_pool[0] as InstalledCard
			tu_target.add_counter("advancement", 2)
			ctx.send_log("Touch-ups: %s places 2 advancement counters on %s (%d total)." % [
				ctx.corp_name(), tu_target.display_name(), tu_target.get_counter("advancement")
			])
			# Step 2 (conditional — "if you do"): choose type, reveal grip, shuffle up to 2 back.
			if ctx.runner_hand.is_empty():
				ctx.send_log("Touch-ups: Runner grip is empty — nothing to shuffle back.")
				return
			# Corp chooses a runner card type
			var tu_all_types: Array = ["program", "hardware", "resource", "event"]
			var tu_chosen_type: String = ""
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_runner_card_type"):
				tu_chosen_type = await ctx.corp_decision_maker.choose_runner_card_type(tu_all_types, ctx)
			if tu_chosen_type == "":
				# AI default: pick most-represented type in grip (maximum disruption)
				var tu_counts: Dictionary = {}
				for tu_e in ctx.runner_hand:
					var tu_r: CardRecord = (tu_e as Dictionary).get("card_record", null) as CardRecord
					if tu_r != null:
						tu_counts[tu_r.card_type] = tu_counts.get(tu_r.card_type, 0) + 1
				var tu_best := 0
				for t in tu_all_types:
					if tu_counts.get(t, 0) > tu_best:
						tu_best = tu_counts.get(t, 0)
						tu_chosen_type = t
			if tu_chosen_type == "":
				tu_chosen_type = tu_all_types[0]
			ctx.send_log("Touch-ups: %s chooses type '%s' and reveals %s's grip:" % [
				ctx.corp_name(), tu_chosen_type, ctx.runner_name()
			])
			# Reveal grip (log all cards)
			for tu_e in ctx.runner_hand:
				var tu_r: CardRecord = (tu_e as Dictionary).get("card_record", null) as CardRecord
				if tu_r != null:
					ctx.send_log("  [%s] %s" % [tu_r.card_type, tu_r.title])
			# Filter to chosen type
			var tu_candidates: Array = []
			for tu_e in ctx.runner_hand:
				var tu_r: CardRecord = (tu_e as Dictionary).get("card_record", null) as CardRecord
				if tu_r != null and tu_r.card_type == tu_chosen_type:
					tu_candidates.append(tu_e)
			if tu_candidates.is_empty():
				ctx.send_log("Touch-ups: No %s cards in grip — nothing to shuffle back." % tu_chosen_type)
				return
			# Corp picks up to 2 of the matching cards to shuffle back
			var tu_chosen_entries: Array = []
			for _i in range(min(2, tu_candidates.size())):
				var tu_remaining: Array = tu_candidates.filter(
					func(e): return not tu_chosen_entries.has(e)
				)
				if tu_remaining.is_empty():
					break
				var tu_pick_records: Array = tu_remaining.map(
					func(e): return (e as Dictionary).get("card_record", null) as CardRecord
				)
				var tu_picked_record: CardRecord = null
				if ctx.corp_decision_maker != null and \
						ctx.corp_decision_maker.has_method("choose_card_to_trash"):
					tu_picked_record = await ctx.corp_decision_maker.choose_card_to_trash(
						tu_pick_records, ctx
					)
				if tu_picked_record == null:
					tu_picked_record = tu_pick_records[0] as CardRecord
				# Map record back to hand entry
				for tu_e in tu_remaining:
					if (tu_e as Dictionary).get("card_record", null) == tu_picked_record:
						tu_chosen_entries.append(tu_e)
						break
			# Move chosen cards from grip to stack, then shuffle
			for tu_entry in tu_chosen_entries:
				ctx.runner_hand.erase(tu_entry)
				var tu_r: CardRecord = (tu_entry as Dictionary).get("card_record", null) as CardRecord
				if tu_r != null:
					ctx.runner_deck.append(tu_r)
					ctx.send_log("Touch-ups: Shuffled %s back into the stack." % tu_r.title)
			if not tu_chosen_entries.is_empty():
				ctx.runner_deck.shuffle()
				ctx.send_log("Touch-ups: %s shuffles the stack." % ctx.runner_name())

		# ── Bigger Picture: remove N tags; runner loses 5cr each, Corp gains ────

		"bigger_picture_drain":
			if ctx.runner_tags == 0:
				ctx.send_log("Bigger Picture: Runner has no tags to remove.")
				return
			var bp_max: int = ctx.runner_tags
			var bp_remove: int = bp_max  # default: remove all (maximise drain)
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_tags_to_remove"):
				bp_remove = await ctx.corp_decision_maker.choose_tags_to_remove(bp_max, ctx)
			bp_remove = clampi(bp_remove, 0, bp_max)
			if bp_remove == 0:
				ctx.send_log("Bigger Picture: Corp removes 0 tags.")
				return
			ctx.runner_tags -= bp_remove
			ctx.send_log("Bigger Picture: Removed %d tag(s) from %s. (%d remaining)" % [
				bp_remove, ctx.runner_name(), ctx.runner_tags
			])
			var bp_drain: int = min(bp_remove * 5, ctx.runner_credits)
			ctx.runner_credits -= bp_drain
			ctx.corp_credits   += bp_drain
			ctx.send_log("Bigger Picture: %s loses %d credits. %s gains %d credits." % [
				ctx.runner_name(), bp_drain, ctx.corp_name(), bp_drain
			])
			# The Zwicky Group: Bigger Picture is an operation; any credit gain qualifies.
			if bp_drain > 0 and ctx.current_ability_source_card_type in ["operation", "agenda"]:
				await ctx.notify_event("corp_gains_credits_via_ability", {"amount": bp_drain}, self)
			if bp_remove > 0:
				await ctx.notify_event("tag_removed", {"amount": bp_remove}, self)

		# ── Synapse Global: install any card from HQ ignoring costs ─────────────

		"synapse_install_from_hq":
			# Corp may reveal and install any 1 card from HQ, ignoring all costs.
			if ctx.corp_hand.is_empty():
				ctx.send_log("Synapse Global: HQ is empty — nothing to install.")
				return
			var sg_want: bool = false
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_optional_ability"):
				sg_want = await ctx.corp_decision_maker.choose_optional_ability(
					"Synapse Global: reveal and install 1 card from HQ (ignoring all costs)?", ctx
				)
			else:
				sg_want = true
			if not sg_want:
				ctx.send_log("Synapse Global: %s declines to install." % ctx.corp_name())
				return
			var sg_dm: Object = ctx.corp_decision_maker
			var sg_chosen_entry: Variant = null
			if sg_dm != null and sg_dm.has_method("choose_card_from_hand"):
				sg_chosen_entry = await sg_dm.choose_card_from_hand(ctx.corp_hand, ctx)
			if sg_chosen_entry == null:
				sg_chosen_entry = ctx.corp_hand[0]
			var sg_record: CardRecord = (sg_chosen_entry as Dictionary).get("card_record", null) as CardRecord
			if sg_record == null:
				return
			ctx.corp_hand.erase(sg_chosen_entry)
			ctx.send_log("Synapse Global: %s reveals %s." % [ctx.corp_name(), sg_record.title])
			var sg_server: Server = ctx.create_remote_server()
			var sg_zone: String = "ice" if sg_record.is_ice() else "root"
			var sg_inst := _install_corp_card(sg_record, sg_server, sg_zone, false)
			ctx.send_log("Synapse Global: %s installs %s on %s (ignoring costs)." % [
				ctx.corp_name(), sg_record.title, sg_server.display_name()
			])

		# ── Synapse Global click action: remove 1 tag, gain 2 credits ───────────

		"synapse_remove_tag_gain_credits":
			if ctx.runner_tags < 1:
				ctx.send_log("Synapse Global: no tags to remove.")
				return
			ctx.runner_tags -= 1
			ctx.send_log("Synapse Global: %s removes 1 tag from %s. (%d remaining)" % [
				ctx.corp_name(), ctx.runner_name(), ctx.runner_tags
			])
			ctx.corp_credits += 2
			ctx.send_log("Synapse Global: %s gains 2 credits. (%d total)" % [
				ctx.corp_name(), ctx.corp_credits
			])
			# Fire tag_removed so the install-trigger can react (once_per_turn_key guards it).
			await ctx.notify_event("tag_removed", {"amount": 1}, self)

		# ── Petty Cash: gain 1 click if not played from HQ ───────────────────────

		"petty_cash_gain_click_if_not_hq":
			if ctx.current_operation_play_source != "hq":
				ctx.corp_clicks += 1
				ctx.send_log("Petty Cash: %s gains 1 click (played from Archives, %d remaining)." % [
					ctx.corp_name(), ctx.corp_clicks
				])

		# ── Phật Gioan Baotixita: remove up to 2 counters, do 1 + removed net damage ─

		"phat_optional_damage":
			var phat_self: InstalledCard = \
				ctx.get_installed_card_by_instance_id(
					ctx.current_event_data.get("card_instance_id", ""))
			if phat_self == null:
				# Fall back: find the rezzed Phật Gioan Baotixita in any server root
				for phat_sv in ctx.servers.values():
					var phat_s: Server = phat_sv as Server
					for phat_c in phat_s.root:
						var phat_ic: InstalledCard = phat_c as InstalledCard
						if phat_ic != null and phat_ic.card_id == "phat_gioan_baotixita" \
								and phat_ic.is_rezzed:
							phat_self = phat_ic
							break
					if phat_self != null:
						break
			if phat_self == null:
				return
			var phat_available: int = phat_self.get_counter("power")
			var phat_max_remove: int = min(2, phat_available)
			var phat_remove: int = 0
			if phat_max_remove > 0:
				if ctx.corp_decision_maker != null and \
						ctx.corp_decision_maker.has_method("choose_tags_to_remove"):
					# Reuse choose_tags_to_remove as a generic "choose N up to max" prompt
					phat_remove = await ctx.corp_decision_maker.choose_tags_to_remove(phat_max_remove, ctx)
				else:
					phat_remove = phat_max_remove   # AI default: maximise damage
				phat_remove = clampi(phat_remove, 0, phat_max_remove)
				if phat_remove > 0:
					phat_self.remove_counter("power", phat_remove)
					ctx.send_log("Phật Gioan Baotixita: %s removes %d power counter(s) (%d remaining)." % [
						ctx.corp_name(), phat_remove, phat_self.get_counter("power")
					])
			var phat_damage: int = 1 + phat_remove
			ctx.send_log("Phật Gioan Baotixita: does %d net damage." % phat_damage)
			await _deal_damage("net", phat_damage, ctx)

		# ── Peer Review: reveal all but 1 card in HQ ─────────────────────────────

		"reveal_hq_except_one":
			if ctx.corp_hand.is_empty():
				return
			# Corp chooses which card to keep hidden (AI: keep the cheapest/last card)
			var rheo_hidden_idx: int = ctx.corp_hand.size() - 1
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_card_from_hand"):
				var rheo_chosen = await ctx.corp_decision_maker.choose_card_from_hand(
					ctx.corp_hand, ctx)
				if rheo_chosen != null:
					rheo_hidden_idx = ctx.corp_hand.find(rheo_chosen)
			ctx.send_log("Peer Review: %s reveals all but 1 card in HQ:" % ctx.corp_name())
			for rheo_i in range(ctx.corp_hand.size()):
				if rheo_i == rheo_hidden_idx:
					continue
				var rheo_entry: Dictionary = ctx.corp_hand[rheo_i] as Dictionary
				var rheo_r: CardRecord = rheo_entry.get("card_record", null) as CardRecord
				if rheo_r != null:
					ctx.send_log("  [%s] %s" % [rheo_r.card_type, rheo_r.title])

		# ── Mitra Aman: Corp may trash to gain 3cr and optionally swap ice ────────

		"mitra_aman_approach":
			# The Corp may choose to trigger this (optional).
			var mitra_want := false
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_optional_ability"):
				mitra_want = await ctx.corp_decision_maker.choose_optional_ability(
					"Mitra Aman: Trash to gain 3[cr] and optionally swap approached ice?", ctx
				)
			else:
				mitra_want = true   # AI default: always activate
			if not mitra_want:
				ctx.send_log("Mitra Aman: Corp declines to activate.")
				return
			# Trash self
			var mitra_self := _get_self_card(ctx)
			if mitra_self != null:
				var mitra_srv: Server = ctx.get_server(mitra_self.server_id) as Server
				if mitra_srv != null:
					mitra_srv.remove_from_root(mitra_self)
				ctx.unregister_all_card_effects(mitra_self.runtime_instance_id)
				if mitra_self.card_record != null:
					ctx.corp_discard.append(mitra_self.card_record)
				ctx.send_log("Mitra Aman: %s trashes Mitra Aman." % ctx.corp_name())
			# Gain 3cr
			ctx.corp_credits += 3
			ctx.send_log("Mitra Aman: %s gains 3 credits. (%d total)" % [
				ctx.corp_name(), ctx.corp_credits
			])
			# Optional ice swap (reuse existing swap effect machinery)
			await _execute_effect({"type": "swap_approached_ice_with_central"}, ctx, null)

		# ── IP Enforcement: remove X tags, install agenda with AP = X from Runner ─

		"ip_enforcement_execute":
			# Find the best valid X: Corp must have X tags to remove, X credits to pay,
			# and a matching AP=X agenda in the Runner's score area.
			var ipe_runner_scored: Array = ctx.runner_score_area_cards
			if ipe_runner_scored.is_empty():
				ctx.send_log("IP Enforcement: no agendas in Runner's score area.")
				return
			# Build candidate table: AP → InstalledCard
			var ipe_by_ap: Dictionary = {}
			for ipe_a in ipe_runner_scored:
				var ipe_ic: InstalledCard = ipe_a as InstalledCard
				if ipe_ic == null or ipe_ic.card_record == null:
					continue
				var ipe_ap: int = max(0, ipe_ic.card_record.agenda_points)
				if not ipe_by_ap.has(ipe_ap):
					ipe_by_ap[ipe_ap] = ipe_ic
			# Find highest X where Corp can afford X credits + X tags
			var ipe_x: int = 0
			var ipe_target: InstalledCard = null
			for ipe_ap in ipe_by_ap.keys():
				var ipe_ap_int: int = int(ipe_ap)
				if ctx.runner_tags >= ipe_ap_int and ctx.corp_credits >= ipe_ap_int:
					if ipe_ap_int > ipe_x:
						ipe_x = ipe_ap_int
						ipe_target = ipe_by_ap[ipe_ap] as InstalledCard
			if ipe_target == null or ipe_x == 0:
				ctx.send_log("IP Enforcement: Corp cannot afford any valid X (tags: %d, credits: %d)." % [
					ctx.runner_tags, ctx.corp_credits
				])
				return
			# Pay X credits and remove X tags
			ctx.corp_credits  -= ipe_x
			ctx.runner_tags   -= ipe_x
			ctx.send_log("IP Enforcement: Corp pays %d cr and removes %d tag(s) from %s. (%d tags remaining)" % [
				ipe_x, ipe_x, ctx.runner_name(), ctx.runner_tags
			])
			await ctx.notify_event("tag_removed", {"amount": ipe_x}, self)
			if ctx.game_over:
				return
			# Install the agenda: move from runner score to corp score area
			var ipe_record: CardRecord = ipe_target.card_record
			ctx.runner_score_area_cards.erase(ipe_target)
			ctx.runner_score_area.erase(ipe_record)
			ctx.corp_score_area_cards.append(ipe_target)
			ctx.corp_score_area.append(ipe_record)
			ipe_target.server_id = "corp_score"
			ctx.send_log("IP Enforcement: %s installs %s (AP %d) from %s's score area." % [
				ctx.corp_name(), ipe_record.title, ipe_x, ctx.runner_name()
			])
			# If Runner is still tagged, place 1 advancement counter on the agenda
			if ctx.runner_is_tagged():
				ipe_target.add_counter("advancement", 1)
				ctx.send_log("IP Enforcement: Runner is still tagged — 1 advancement counter placed on %s." % \
					ipe_record.title)

		# ── The Zwicky Group: optional draw 1 card ───────────────────────────────

		"zwicky_optional_draw":
			var zw_want := false
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_optional_ability"):
				zw_want = await ctx.corp_decision_maker.choose_optional_ability(
					"The Zwicky Group: draw 1 card?", ctx
				)
			else:
				zw_want = true   # AI default: always draw
			if zw_want:
				_draw_cards("corp", 1, ctx)

		# ── VP47 Witch Hunt / VP49 Magistrate Revontulet: remove bad publicity ────

		"remove_bad_pub":
			# Remove up to N bad publicity from the Corp.
			# params: { amount: int }
			var rbp_amount: int  = params.get("amount", 1)
			var rbp_removed: int = min(rbp_amount, ctx.corp_bad_pub)
			ctx.corp_bad_pub -= rbp_removed
			ctx.send_log("%s removes %d bad publicity. (%d remaining)" % [
				ctx.corp_name(), rbp_removed, ctx.corp_bad_pub])

		# ── VP47 Witch Hunt: remove all runner tags ───────────────────────────────

		"remove_all_runner_tags":
			# Remove every tag the Runner currently has.
			var rat_count: int = ctx.runner_tags
			if rat_count <= 0:
				ctx.send_log("Runner has no tags to remove.")
				return
			ctx.runner_tags = 0
			ctx.send_log("%s removes all %d tag(s)." % [ctx.runner_name(), rat_count])
			await ctx.notify_event("tag_removed", {"amount": rat_count}, self)

		# ── VP61 Myōshu: add played operation to Corp score area ─────────────────

		"add_self_to_score_area":
			# The played operation scores itself as an N-point agenda.
			# Requires TurnManager to set ctx meta "current_op_card_record" before trigger.
			# Sets ctx meta "operation_scored_as_agenda" so TurnManager skips the discard.
			# params: { points: int }
			var asta_points: int = params.get("points", 2)
			var asta_record: CardRecord = null
			if ctx.has_meta("current_op_card_record"):
				asta_record = ctx.get_meta("current_op_card_record") as CardRecord
			if asta_record == null:
				push_error("AbilityInterpreter: add_self_to_score_area — no current_op_card_record in ctx meta")
				return
			# Override agenda_points so corp_agenda_points() counts it correctly
			asta_record.agenda_points = asta_points
			# Create synthetic InstalledCard for score area tracking
			var asta_ic := InstalledCard.make_runtime_instance(asta_record, "corp_score_area", "root", true)
			ctx.corp_score_area.append(asta_record)
			ctx.corp_score_area_cards.append(asta_ic)
			ctx.corp_last_scored_agenda_points            = asta_points
			ctx.corp_agendas_scored_this_turn            += 1
			ctx.corp_scored_agenda_not_installed_this_turn = true
			ctx.send_log("%s: %s scores as a %d-point agenda!" % [
				ctx.corp_name(), asta_record.title, asta_points])
			await ctx.notify_event("corp_scores_agenda", {
				"agenda_id":     asta_record.id,
				"agenda_points": asta_points,
				"server_id":     ""
			}, self)
			# Signal TurnManager not to also discard this card
			ctx.set_meta("operation_scored_as_agenda", true)
			# Inline win check — TurnManager's _check_win_conditions will emit the signal
			if ctx.corp_agenda_points() >= ctx.agenda_points_to_win:
				ctx.game_over = true
				ctx.winner    = "corp"

		# ── RWR Kingmaking: score a 1-point agenda directly from HQ ─────────────

		"score_agenda_from_hq_direct":
			# Corp scores a qualifying agenda from HQ without advancing it.
			# params: { max_points: int, optional: bool }
			var safh_max: int     = params.get("max_points", 1)
			var safh_opt: bool    = params.get("optional", true)

			# Build the candidate list: agendas in HQ with agenda_points <= max_points.
			var safh_candidates: Array = []
			for safh_entry in ctx.corp_hand:
				var safh_cr: CardRecord = (safh_entry as Dictionary).get("card_record", null) as CardRecord
				if safh_cr != null and safh_cr.is_agenda() and safh_cr.agenda_points <= safh_max:
					safh_candidates.append(safh_entry)

			if safh_candidates.is_empty():
				ctx.send_log("%s: no %d-point agenda in HQ to score." % [ctx.corp_name(), safh_max])
				return

			# Optional: Corp may decline.
			if safh_opt:
				var safh_dm: Object = ctx.corp_decision_maker
				var safh_confirmed: bool = true
				if not ctx.simulation_mode and safh_dm != null and safh_dm.has_method("confirm_action"):
					safh_confirmed = await safh_dm.confirm_action(
						"Score a %d-point agenda from HQ?" % safh_max, ctx)
				elif ctx.simulation_mode:
					# AI: always score when available.
					safh_confirmed = true
				if not safh_confirmed:
					ctx.send_log("%s: declines to score from HQ." % ctx.corp_name())
					return

			# Choose which agenda to score.
			var safh_chosen_entry: Variant = safh_candidates[0]
			var safh_dm2: Object = ctx.corp_decision_maker
			if not ctx.simulation_mode and safh_dm2 != null and safh_dm2.has_method("choose_card_from_hand"):
				safh_chosen_entry = await safh_dm2.choose_card_from_hand(safh_candidates, ctx)
			if safh_chosen_entry == null:
				return
			var safh_record: CardRecord = (safh_chosen_entry as Dictionary).get("card_record", null) as CardRecord
			if safh_record == null:
				return

			# Remove from HQ.
			ctx.corp_hand.erase(safh_chosen_entry)

			# Create a synthetic InstalledCard (never was on a server).
			var safh_ic := InstalledCard.make_runtime_instance(safh_record, "corp_score_area", "root", true)

			# Move to score area.
			ctx.corp_score_area.append(safh_record)
			ctx.corp_score_area_cards.append(safh_ic)
			ctx.corp_last_scored_agenda_points            = safh_record.agenda_points
			ctx.corp_agendas_scored_this_turn            += 1
			# Was never installed this turn (came from HQ).
			ctx.corp_scored_agenda_not_installed_this_turn = true

			ctx.send_log("%s scores %s directly from HQ! (%d agenda point%s)" % [
				ctx.corp_name(), safh_record.title, safh_record.agenda_points,
				"s" if safh_record.agenda_points != 1 else ""])

			# Fire on_score ability for the scored agenda (excess advancement = 0).
			var safh_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
			if safh_ab_reg != null:
				var safh_on_score = safh_ab_reg.get_on_score(safh_record.id)
				if safh_on_score != null:
					ctx.current_event_data = {
						"card": safh_ic,
						"card_instance_id": safh_ic.runtime_instance_id,
						"excess_advancement": 0
					}
					ctx.current_ability_source_card_type = "agenda"
					await execute_trigger(safh_on_score as Dictionary, ctx)
					ctx.current_event_data = {}
					ctx.current_ability_source_card_type = ""

			# Broadcast so reactive cards (Pantograph, Lamplighter, etc.) can respond.
			await ctx.notify_event("corp_scores_agenda", {
				"agenda_id":     safh_record.id,
				"agenda_points": safh_record.agenda_points,
				"server_id":     ""
			}, self)

			# Inline win check.
			if ctx.corp_agenda_points() >= ctx.agenda_points_to_win:
				ctx.game_over = true
				ctx.winner    = "corp"

		# ── RWR Jeitinho: add self to runner score area as an assassination agenda ──

		"add_self_to_runner_score_as_assassination_agenda":
			# Jeitinho (runner hardware). Fired at runner_turn_end when the runner
			# made successful runs on HQ, R&D, and Archives.
			# Removes Jeitinho from the runner rig, creates a synthetic InstalledCard
			# entry in runner_score_area_cards (worth 0 agenda points), and increments
			# ctx.runner_assassination_agendas.  If that reaches 3, runner wins.
			var asaa_optional: bool = params.get("optional", true)
			var asaa_self := _get_self_card(ctx)
			if asaa_self == null:
				push_error("AbilityInterpreter: add_self_to_runner_score_as_assassination_agenda — no self card found")
				return

			if asaa_optional:
				var asaa_dm = ctx.runner_decision_maker
				var asaa_confirmed: bool = true
				if not ctx.simulation_mode and asaa_dm != null and asaa_dm.has_method("confirm_action"):
					asaa_confirmed = await asaa_dm.confirm_action(
						"Add %s to your score area as an assassination agenda?" % asaa_self.display_name(), ctx)
				if not asaa_confirmed:
					return

			# Move card from runner rig → synthetic score-area slot
			ctx.runner_rig.erase(asaa_self)
			ctx.unregister_all_card_effects(asaa_self.runtime_instance_id)

			# The card enters the score area tagged as an assassination agenda worth 0 points.
			# We do NOT add it to ctx.runner_score_area (CardRecord list) because that is
			# summed for agenda-point wins; assassination agendas are tracked separately.
			var asaa_ic := InstalledCard.make_runtime_instance(
				asaa_self.card_record, "runner_score_area", "root", true)
			# Tag it so the UI and other queries can identify it
			asaa_ic.set_meta("is_assassination_agenda", true)
			ctx.runner_score_area_cards.append(asaa_ic)
			ctx.runner_assassination_agendas += 1

			ctx.send_log("%s adds %s to their score area as assassination agenda #%d!" % [
				ctx.runner_name(), asaa_self.display_name(), ctx.runner_assassination_agendas])

			# Inline win check — fires before TurnManager's _check_win_conditions so the
			# game can end inside the turn-end phase rather than needing a separate pass.
			if ctx.runner_assassination_agendas >= 3:
				ctx.send_log("%s wins — 3 assassination agendas assembled!" % ctx.runner_name())
				ctx.game_over = true
				ctx.winner    = "runner"

		# ── VP54 Scapegoat: bounce a runner installed card to stack ───────────────

		"shuffle_runner_installed_to_stack":
			# Corp picks 1 of the Runner's installed cards; it is returned to the stack
			# and the stack is shuffled.
			# params: { card_types: Array } — optional filter (empty = any type)
			var srits_types: Array = params.get("card_types", []) as Array
			var srits_pool: Array  = ctx.runner_rig.filter(func(c: InstalledCard):
				return srits_types.is_empty() or \
					(c.card_record != null and srits_types.has(c.card_record.card_type))
			)
			if srits_pool.is_empty():
				ctx.send_log("Scapegoat: no valid runner installed cards.")
				return
			var srits_dm: Object = ctx.corp_decision_maker
			var srits_target: InstalledCard = srits_pool[0] as InstalledCard
			if srits_dm != null and srits_dm.has_method("choose_derez_target"):
				srits_target = await srits_dm.choose_derez_target(srits_pool, ctx)
			if srits_target == null:
				return
			ctx.runner_rig.erase(srits_target)
			ctx.unregister_all_card_effects(srits_target.runtime_instance_id)
			if srits_target.card_record != null:
				ctx.runner_deck.push_back(srits_target.card_record)
				ctx.runner_deck.shuffle()
			ctx.send_log("Scapegoat: %s's %s is returned to the stack (shuffled)." % [
				ctx.runner_name(), srits_target.display_name()])

		# ── VP33 Realloc: derez 2 rezzed ice, gain their printed rez costs ────────

		"derez_two_rezzed_ice_gain_rez_costs":
			# Corp picks 2 rezzed ice; gains the sum of their printed rez costs,
			# then derezzes both.
			var dtr_candidates: Array = []
			for dtr_srv in ctx.servers.values():
				for dtr_c in (dtr_srv as Server).ice:
					var dtr_ic: InstalledCard = dtr_c as InstalledCard
					if dtr_ic != null and dtr_ic.is_rezzed:
						dtr_candidates.append(dtr_ic)
			if dtr_candidates.size() < 2:
				ctx.send_log("Realloc: fewer than 2 rezzed ice — no effect.")
				return
			var dtr_dm: Object = ctx.corp_decision_maker
			# First pick
			var dtr_first: InstalledCard = dtr_candidates[0] as InstalledCard
			if dtr_dm != null and dtr_dm.has_method("choose_derez_target"):
				dtr_first = await dtr_dm.choose_derez_target(dtr_candidates, ctx)
			dtr_candidates.erase(dtr_first)
			# Second pick
			var dtr_second: InstalledCard = dtr_candidates[0] as InstalledCard
			if dtr_dm != null and dtr_dm.has_method("choose_derez_target"):
				dtr_second = await dtr_dm.choose_derez_target(dtr_candidates, ctx)
			# Gain printed rez costs
			var dtr_gain: int = 0
			if dtr_first.card_record != null:
				dtr_gain += max(0, dtr_first.card_record.cost)
			if dtr_second.card_record != null:
				dtr_gain += max(0, dtr_second.card_record.cost)
			ctx.corp_credits += dtr_gain
			ctx.send_log("Realloc: derezzes %s and %s — %s gains %d credits." % [
				dtr_first.display_name(), dtr_second.display_name(),
				ctx.corp_name(), dtr_gain])
			await _derez_card(dtr_first, ctx)
			await _derez_card(dtr_second, ctx)

		# ── VP44 Unleash: rez ice for free, optionally resolve a sub ─────────────

		"rez_installed_ice_free_and_optionally_fire_sub":
			# Corp rezzes 1 unrezzed installed ice for free, then may optionally
			# resolve 1 subroutine on that ice immediately.
			var riff_candidates: Array = []
			for riff_srv in ctx.servers.values():
				for riff_c in (riff_srv as Server).ice:
					var riff_ic: InstalledCard = riff_c as InstalledCard
					if riff_ic != null and not riff_ic.is_rezzed:
						riff_candidates.append(riff_ic)
			if riff_candidates.is_empty():
				ctx.send_log("Unleash: no unrezzed ice to rez.")
				return
			var riff_dm: Object = ctx.corp_decision_maker
			var riff_target: InstalledCard = riff_candidates[0] as InstalledCard
			if riff_dm != null and riff_dm.has_method("choose_derez_target"):
				riff_target = await riff_dm.choose_derez_target(riff_candidates, ctx)
			if riff_target == null:
				return
			# Rez for free
			riff_target.is_rezzed    = true
			ctx.ice_rezzed_this_turn = true
			# Register listeners (same path as TurnManager._do_install with rez:true)
			if ctx.has_meta("register_installed_card"):
				var riff_reg: Callable = ctx.get_meta("register_installed_card") as Callable
				riff_reg.call(riff_target)
			# Retrieve ability registry once
			var riff_ab_reg: AbilityRegistry = null
			if ctx.has_meta("ability_registry"):
				riff_ab_reg = ctx.get_meta("ability_registry") as AbilityRegistry
			# Fire on_rez if the ice has one
			if riff_ab_reg != null:
				var riff_on_rez = riff_ab_reg.get_on_rez(riff_target.card_id)
				if riff_on_rez != null:
					ctx.current_event_data = {
						"card":             riff_target,
						"card_instance_id": riff_target.runtime_instance_id
					}
					await execute_trigger(riff_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			ctx.send_log("Unleash: %s rezzes %s for free." % [
				ctx.corp_name(), riff_target.display_name()])
			# Optional: resolve 1 subroutine
			if riff_ab_reg == null:
				return
			var riff_subs: Array = riff_ab_reg.get_subroutines_for_card(riff_target.card_id, riff_target)
			if riff_subs.is_empty():
				return
			var riff_want_sub := false
			if riff_dm != null and riff_dm.has_method("choose_optional_ability"):
				riff_want_sub = await riff_dm.choose_optional_ability(
					"Unleash: resolve 1 subroutine on %s?" % riff_target.display_name(), ctx)
			else:
				riff_want_sub = true   # AI default: always fire
			if not riff_want_sub:
				return
			var riff_sub_idx: int = 0
			if riff_subs.size() > 1 and riff_dm != null and riff_dm.has_method("choose_modes"):
				var riff_modes: Array = []
				for riff_s in riff_subs:
					riff_modes.append({"label": (riff_s as Dictionary).get("label", "Sub")})
				var riff_choice: Array = await riff_dm.choose_modes(riff_modes, 1, ctx)
				if not riff_choice.is_empty():
					riff_sub_idx = riff_choice[0]
			if riff_sub_idx < riff_subs.size():
				var riff_sub: Dictionary = riff_subs[riff_sub_idx] as Dictionary
				ctx.send_log("Unleash: Corp fires '%s' on %s." % [
					riff_sub.get("label", "sub"), riff_target.display_name()])
				await execute_subroutine(riff_sub, ctx)

		# ── VP53 Flood the Market: count qualifying remotes, place advancements ───

		"count_remotes_place_advancements":
			# Count remote servers with both a root card and at least 1 ice.
			# Place that many advancement counters on a Corp-chosen installed card.
			var crpa_count: int = 0
			for crpa_srv in ctx.get_remote_servers():
				var crpa_s: Server = crpa_srv as Server
				if not crpa_s.root.is_empty() and crpa_s.ice_count() > 0:
					crpa_count += 1
			if crpa_count == 0:
				ctx.send_log("Flood the Market: no qualifying remote servers — no counters placed.")
				return
			ctx.send_log("Flood the Market: %d qualifying remote server(s)." % crpa_count)
			var crpa_candidates: Array = ctx.all_installed()
			if crpa_candidates.is_empty():
				ctx.send_log("Flood the Market: no installed Corp cards to advance.")
				return
			var crpa_dm: Object = ctx.corp_decision_maker
			var crpa_target: InstalledCard = crpa_candidates[0] as InstalledCard
			if crpa_dm != null and crpa_dm.has_method("choose_derez_target"):
				crpa_target = await crpa_dm.choose_derez_target(crpa_candidates, ctx)
			if crpa_target == null:
				return
			crpa_target.add_counter("advancement", crpa_count)
			ctx.send_log("Flood the Market: placed %d advancement counter(s) on %s." % [
				crpa_count, crpa_target.display_name()])

		# ── VP32 Caveat Emptor: gain/lose clicks next turn ────────────────────────

		"gain_clicks_next_turn":
			# Add (or subtract, if negative) pending click bonuses for a player's next turn.
			# params: { subject: "corp"|"runner", amount: int }
			var gcnt_subject: String = params.get("subject", "corp")
			var gcnt_amount: int     = params.get("amount", 1)
			ctx.pending_click_bonuses[gcnt_subject] = \
				ctx.pending_click_bonuses.get(gcnt_subject, 0) + gcnt_amount
			var gcnt_label: String = "gains" if gcnt_amount >= 0 else "loses"
			ctx.send_log("%s %s %d click(s) next turn." % [
				ctx.player_name(gcnt_subject), gcnt_label, abs(gcnt_amount)])

		# ── Psi game ─────────────────────────────────────────────────────────────

		"psi_game":
			# Both players secretly bid 0, 1, or 2 credits, then reveal simultaneously.
			# Each player pays their bid to the bank regardless of outcome.
			# params: {
			#   on_match:    Array[effect]  — fires when bids are equal (Runner wins)
			#   on_mismatch: Array[effect]  — fires when bids differ  (Corp wins)
			# }
			var psi_max_corp:   int = min(2, ctx.corp_credits)
			var psi_max_runner: int = min(2, ctx.runner_credits)

			# ── Corp AI bid (weighted toward 0 — credits matter) ──────────────
			var psi_corp_bid: int = 0
			var psi_roll: int = randi() % 6   # 0-5
			if psi_roll < 3:
				psi_corp_bid = 0
			elif psi_roll < 5:
				psi_corp_bid = min(1, psi_max_corp)
			else:
				psi_corp_bid = min(2, psi_max_corp)

			# ── Runner bid ────────────────────────────────────────────────────
			var psi_runner_bid: int = 0
			var psi_rdm: Object = ctx.runner_decision_maker
			if not ctx.simulation_mode and psi_rdm != null and psi_rdm.has_method("choose_psi_bid"):
				psi_runner_bid = await psi_rdm.choose_psi_bid(psi_max_runner, ctx)
			elif psi_rdm != null and psi_rdm.has_method("choose_psi_bid"):
				# SimRunnerAI path
				psi_runner_bid = psi_rdm.choose_psi_bid(psi_max_runner, ctx)

			# Clamp to affordable range (safety net)
			psi_corp_bid   = clampi(psi_corp_bid,   0, psi_max_corp)
			psi_runner_bid = clampi(psi_runner_bid, 0, psi_max_runner)

			# ── Pay bids ──────────────────────────────────────────────────────
			ctx.corp_credits   -= psi_corp_bid
			ctx.runner_credits -= psi_runner_bid

			# ── Reveal ────────────────────────────────────────────────────────
			ctx.send_log("Psi game: %s bids %d cr, %s bids %d cr." % [
				ctx.corp_name(), psi_corp_bid, ctx.runner_name(), psi_runner_bid])

			if psi_corp_bid == psi_runner_bid:
				ctx.send_log("Psi game: bids match — Runner wins!")
				for psi_eff in params.get("on_match", []) as Array:
					await _execute_effect(psi_eff as Dictionary, ctx, null)
			else:
				ctx.send_log("Psi game: bids differ — Corp wins!")
				for psi_eff in params.get("on_mismatch", []) as Array:
					await _execute_effect(psi_eff as Dictionary, ctx, null)

		# ── Generic: optional pay-N-credits-to-trigger ──────────────────────────

		"may_pay_for_effect":
			# Optionally pay a credit cost to resolve a list of sub-effects.
			# If a "condition" block is present, skips entirely when the condition is false.
			# params: {
			#   subject:   "corp" | "runner"  (who pays — default "corp")
			#   cost:      int
			#   condition: Dictionary (optional — evaluated via _evaluate_condition)
			#   label:     String    (shown in the decision prompt)
			#   effects:   Array[Dictionary]
			# }
			var mpfe_cond: Dictionary = params.get("condition", {}) as Dictionary
			if not mpfe_cond.is_empty():
				if not _evaluate_condition(mpfe_cond, ctx):
					return   # condition not met — silently skip

			var mpfe_subject: String  = params.get("subject", "corp")
			var mpfe_cost: int        = params.get("cost", 0)
			var mpfe_label: String    = params.get("label", "Pay %d[credit]?" % mpfe_cost)
			var mpfe_effects: Array   = params.get("effects", []) as Array

			# Check affordability
			if ctx.get_credits(mpfe_subject) < mpfe_cost:
				return

			# Ask the paying player whether to spend
			var mpfe_dm: Object = ctx.corp_decision_maker \
				if mpfe_subject == "corp" else ctx.runner_decision_maker
			var mpfe_pay: bool = true
			if not ctx.simulation_mode and mpfe_dm != null and mpfe_dm.has_method("confirm_action"):
				mpfe_pay = await mpfe_dm.confirm_action(mpfe_label, ctx)
			elif ctx.simulation_mode:
				# AI heuristic: pay if cost is low relative to credits
				mpfe_pay = ctx.get_credits(mpfe_subject) >= mpfe_cost * 2

			if not mpfe_pay:
				return

			ctx.set_credits(mpfe_subject, ctx.get_credits(mpfe_subject) - mpfe_cost)
			if not ctx.simulation_mode:
				emit_signal("credits_changed", mpfe_subject, ctx.get_credits(mpfe_subject))
			ctx.send_log("%s pays %d cr: %s" % [ctx.player_name(mpfe_subject), mpfe_cost, mpfe_label])

			# Execute sub-effects
			for mpfe_eff in mpfe_effects:
				await _execute_effect(mpfe_eff as Dictionary, ctx, chosen_target)

		# ── RWR terminal ops: deferred click penalty ─────────────────────────────

		"pending_click_penalty":
			# Deduct N allotted clicks from a player's next turn (applies before the click
			# count is set, so it cannot go below 0).
			# params: { subject: "corp"|"runner", amount: int }
			var pcp_subject: String = params.get("subject", "runner")
			var pcp_amount: int     = params.get("amount", 1)
			ctx.pending_click_penalties[pcp_subject] = \
				ctx.pending_click_penalties.get(pcp_subject, 0) + pcp_amount
			ctx.send_log("%s will lose %d allotted click(s) next turn." % [
				ctx.player_name(pcp_subject), pcp_amount])

		# ── RWR Bring Them Home: move random grip cards to top of stack ──────────

		"reveal_random_grip_cards_to_stack_top":
			# Corp reveals N cards at random from the runner's grip and moves them to
			# the top of the runner's stack (deck), in a random order.
			# params: { amount: int }
			var rrgts_amount: int = params.get("amount", 1)
			if ctx.runner_hand.is_empty():
				ctx.send_log("Runner's grip is empty — no cards to move.")
				return
			rrgts_amount = min(rrgts_amount, ctx.runner_hand.size())
			var rrgts_moved: Array = []
			for _i in range(rrgts_amount):
				var rrgts_idx: int = randi() % ctx.runner_hand.size()
				var rrgts_entry: Dictionary = ctx.runner_hand[rrgts_idx] as Dictionary
				ctx.runner_hand.remove_at(rrgts_idx)
				rrgts_moved.append(rrgts_entry)
				var rrgts_title: String = (rrgts_entry.get("card_record", null) as CardRecord).title \
					if rrgts_entry.get("card_record", null) != null else rrgts_entry.get("card_id", "?")
				ctx.send_log("Bring Them Home: reveals %s from grip." % rrgts_title)
			# Add to top of stack (front of array)
			for rrgts_card in rrgts_moved:
				ctx.runner_deck.push_front(rrgts_card)
			ctx.send_log("%d card(s) moved from grip to top of stack." % rrgts_moved.size())
			if not ctx.simulation_mode:
				emit_signal("hand_changed", "runner")

		"reveal_random_grip_card_shuffle_to_stack":
			# Corp reveals 1 card at random from the runner's grip and the runner shuffles
			# it into their stack.
			# params: {} — amount always 1
			if ctx.runner_hand.is_empty():
				ctx.send_log("Runner's grip is empty — no cards to move.")
				return
			var rrgcs_idx: int = randi() % ctx.runner_hand.size()
			var rrgcs_entry: Dictionary = ctx.runner_hand[rrgcs_idx] as Dictionary
			ctx.runner_hand.remove_at(rrgcs_idx)
			var rrgcs_title: String = (rrgcs_entry.get("card_record", null) as CardRecord).title \
				if rrgcs_entry.get("card_record", null) != null else rrgcs_entry.get("card_id", "?")
			ctx.send_log("Bring Them Home (threat): reveals %s; runner shuffles it into stack." % rrgcs_title)
			# Insert at a random position in the stack
			var rrgcs_insert_pos: int = randi() % (ctx.runner_deck.size() + 1)
			ctx.runner_deck.insert(rrgcs_insert_pos, rrgcs_entry)
			if not ctx.simulation_mode:
				emit_signal("hand_changed", "runner")

		# ── VP16 Underdome Irregulars: conditional bonus or self-trash ───────────

		"underdome_irregulars_end_of_turn":
			# Corp discard phase end: if ice was rezzed this turn, offer Corp a bonus
			# (draw 2 cards or remove 1 runner tag). Otherwise, trash self.
			if not ctx.ice_rezzed_this_turn:
				# No ice rezzed — self-trash
				var ui_self := _get_self_card(ctx)
				if ui_self != null:
					var ui_srv: Server = ctx.get_server(ui_self.server_id)
					if ui_srv != null:
						ui_srv.remove_from_root(ui_self)
						ctx.remove_empty_remote_servers()
					ctx.unregister_all_card_effects(ui_self.runtime_instance_id)
					if ui_self.card_record != null:
						ctx.corp_discard.append(ui_self.card_record)
					ctx.send_log("Underdome Irregulars: no ice rezzed this turn — trashes itself.")
				return
			# Ice rezzed: offer bonus
			var ui_dm: Object = ctx.corp_decision_maker
			var ui_modes: Array = [
				{"label": "Draw 2 cards"},
				{"label": "Remove 1 runner tag"}
			]
			var ui_choice: Array = [0]
			if ui_dm != null and ui_dm.has_method("choose_modes"):
				ui_choice = await ui_dm.choose_modes(ui_modes, 1, ctx)
			var ui_pick: int = ui_choice[0] if not ui_choice.is_empty() else 0
			if ui_pick == 0:
				_draw_cards("corp", 2, ctx)
				ctx.send_log("Underdome Irregulars: Corp draws 2 cards.")
			else:
				if ctx.runner_tags > 0:
					ctx.runner_tags -= 1
					ctx.send_log("Underdome Irregulars: removes 1 tag from %s. (%d remaining)" % [
						ctx.runner_name(), ctx.runner_tags])
					await ctx.notify_event("tag_removed", {"amount": 1}, self)
				else:
					ctx.send_log("Underdome Irregulars: no tags to remove.")

		# ── VP2 Take a Dive / VP10 Kompromat: run-end effect ─────────────────────

		"kompromat_run_end_check":
			# VP10 Kompromat: Corp must derez 1 ice on the run server OR take 1 bad pub.
			var krc_server: Server = ctx.get_server(ctx.run_target_server)
			if krc_server == null:
				ctx.send_log("Kompromat: run server not found — Corp takes 1 bad pub.")
				ctx.corp_bad_pub += 1
				await ctx.notify_event("corp_gains_bad_pub", {"amount": 1}, self)
				return
			var krc_rezzed: Array = []
			for krc_c in krc_server.ice:
				var krc_ic: InstalledCard = krc_c as InstalledCard
				if krc_ic != null and krc_ic.is_rezzed:
					krc_rezzed.append(krc_ic)
			# Corp chooses: derez ice (if available) or take bad pub
			var krc_can_derez: bool = not krc_rezzed.is_empty()
			var krc_modes: Array = []
			if krc_can_derez:
				krc_modes.append({"label": "Derez 1 ice on this server"})
			krc_modes.append({"label": "Take 1 bad pub"})
			var krc_pick: int = krc_modes.size() - 1  # default: bad pub
			var krc_dm: Object = ctx.corp_decision_maker
			if krc_dm != null and krc_dm.has_method("choose_modes"):
				var krc_result: Array = await krc_dm.choose_modes(krc_modes, 1, ctx)
				krc_pick = krc_result[0] if not krc_result.is_empty() else krc_pick
			if krc_can_derez and krc_modes[krc_pick].get("label", "").begins_with("Derez"):
				var krc_target: InstalledCard = krc_rezzed[0] as InstalledCard
				if krc_dm != null and krc_dm.has_method("choose_derez_target"):
					krc_target = await krc_dm.choose_derez_target(krc_rezzed, ctx)
				await _derez_card(krc_target, ctx)
				ctx.send_log("Kompromat: %s derezzes %s." % [ctx.corp_name(), krc_target.display_name()])
			else:
				ctx.corp_bad_pub += 1
				ctx.send_log("Kompromat: %s takes 1 bad pub (%d total)." % [ctx.corp_name(), ctx.corp_bad_pub])
				await ctx.notify_event("corp_gains_bad_pub", {"amount": 1}, self)

		# ── VP14 Rotary: take tag for bonus access before breach ───────────────────

		"may_take_tag_for_extra_access":
			# VP14 Rotary: before breaching HQ or R&D, runner may take 1 tag for +1 access.
			# params: { servers: Array } — servers where this bonus applies
			var mtfea_servers: Array = params.get("servers", ["hq", "rd"]) as Array
			if ctx.run_target_server not in mtfea_servers:
				return  # This breach is on a different server — skip
			var mtfea_offer: bool = false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_yes_no"):
				mtfea_offer = await ctx.runner_decision_maker.choose_yes_no(
					"Take 1 tag to access 1 additional card from %s?" % ctx.run_target_server.to_upper(), ctx)
			if mtfea_offer:
				var _mtfea_was_zero: bool = (ctx.runner_tags == 0)
				ctx.runner_tags += 1
				ctx.send_log("Rotary: %s takes 1 tag to access 1 additional card. (%d total)" % [
					ctx.runner_name(), ctx.runner_tags])
				await ctx.notify_event("runner_takes_tags", {"amount": 1, "from_zero": _mtfea_was_zero}, self)
				if not ctx.game_over:
					ctx.run_modifiers["bonus_access"] = ctx.run_modifiers.get("bonus_access", 0) + 1

		# ── VP19 Beta Build: search stack, install non-virus program ──────────────

		"search_stack_install_non_virus_program":
			# VP19 Beta Build: search the runner's deck for a non-virus program,
			# install it for free.  Stores instance_id in ctx.beta_build_installed_card_id
			# so RSM can return it to the top of the stack at run end.
			var ssivp_candidates: Array = []
			for ssivp_r in ctx.runner_deck:
				var ssivp_cr: CardRecord = ssivp_r as CardRecord
				if ssivp_cr == null:
					continue
				if ssivp_cr.card_type == "program" and not ssivp_cr.has_subtype("virus"):
					ssivp_candidates.append(ssivp_cr)
			if ssivp_candidates.is_empty():
				ctx.send_log("Beta Build: no non-virus programs found in stack.")
				ctx.runner_deck.shuffle()
				ctx.send_log("%s shuffles their stack." % ctx.runner_name())
				return
			var ssivp_chosen: CardRecord = ssivp_candidates[0] as CardRecord
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_search"):
				var ssivp_picked: Variant = await ctx.runner_decision_maker.choose_from_search(ssivp_candidates, ctx)
				if ssivp_picked is CardRecord:
					ssivp_chosen = ssivp_picked as CardRecord
			# MU check
			if ssivp_chosen.memory_cost > 0 and ctx.runner_mu_available() < ssivp_chosen.memory_cost:
				ctx.send_log("Beta Build: not enough MU to install %s — install skipped." % ssivp_chosen.title)
				ctx.runner_deck.shuffle()
				return
			# Remove from deck and install
			ctx.runner_deck.erase(ssivp_chosen)
			ctx.runner_deck.shuffle()
			ctx.send_log("%s shuffles their stack." % ctx.runner_name())
			var ssivp_installed := InstalledCard.make_runtime_instance(ssivp_chosen, "runner_rig", "root", true)
			ctx.runner_rig.append(ssivp_installed)
			# Register event listeners via TurnManager callback
			if ctx.has_meta("register_installed_card"):
				var ssivp_reg: Callable = ctx.get_meta("register_installed_card") as Callable
				ssivp_reg.call(ssivp_installed)
			# Fire on_rez if defined
			if ctx.has_meta("ability_registry"):
				var ssivp_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var ssivp_on_rez = ssivp_ab_reg.get_on_rez(ssivp_chosen.id)
				if ssivp_on_rez != null:
					ctx.current_event_data = {
						"card": ssivp_installed,
						"card_instance_id": ssivp_installed.runtime_instance_id
					}
					await execute_trigger(ssivp_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			# Track for run-end return
			ctx.beta_build_installed_card_id = ssivp_installed.runtime_instance_id
			ctx.send_log("Beta Build: %s installs %s for free. [MU: %d/%d]" % [
				ctx.runner_name(), ssivp_chosen.title,
				ctx.runner_mu_used(), ctx.runner_total_mu()])

		# ── Muse: on install, search stack/heap/grip for a non-daemon program ───────

		"search_zones_install_program":
			# Muse on_install: search the named zones for a non-daemon program.
			# If the found program is a trojan, install it on a piece of ice (existing path).
			# Otherwise install it hosted on Muse (daemon hosting — zero extra MU).
			# params: { "zones": ["stack","heap","grip"], "filter": "non_daemon",
			#           "shuffle_stack": true }
			var szip_zones: Array  = params.get("zones", ["stack"]) as Array
			var szip_filter: String = params.get("filter", "non_daemon")
			var szip_shuffle: bool  = params.get("shuffle_stack", true)

			# Build candidate list: CardRecord entries from each zone
			var szip_candidates: Array = []
			var szip_stack_searched: bool = false
			for szip_zone in szip_zones:
				match (szip_zone as String):
					"stack":
						for szip_r in ctx.runner_deck:
							var szip_cr: CardRecord = szip_r as CardRecord
							if szip_cr == null or szip_cr.card_type != "program":
								continue
							if szip_filter == "non_daemon" and szip_cr.has_subtype("daemon"):
								continue
							szip_candidates.append({"record": szip_cr, "zone": "stack"})
						szip_stack_searched = true
					"heap":
						for szip_r in ctx.runner_discard:
							var szip_cr: CardRecord = szip_r as CardRecord
							if szip_cr == null or szip_cr.card_type != "program":
								continue
							if szip_filter == "non_daemon" and szip_cr.has_subtype("daemon"):
								continue
							szip_candidates.append({"record": szip_cr, "zone": "heap"})
					"grip":
						for szip_entry in ctx.runner_hand:
							var szip_cr: CardRecord = (szip_entry as Dictionary).get("card_record", null) as CardRecord
							if szip_cr == null or szip_cr.card_type != "program":
								continue
							if szip_filter == "non_daemon" and szip_cr.has_subtype("daemon"):
								continue
							szip_candidates.append({"record": szip_cr, "zone": "grip"})

			# Shuffle stack regardless of whether a match is found
			if szip_stack_searched and szip_shuffle:
				ctx.runner_deck.shuffle()
				ctx.send_log("%s shuffles their stack." % ctx.runner_name())

			if szip_candidates.is_empty():
				ctx.send_log("Muse: no matching programs found.")
				return

			# Runner chooses one
			var szip_chosen_entry: Dictionary = szip_candidates[0] as Dictionary
			var szip_chosen_records: Array = []
			for szip_ce in szip_candidates:
				szip_chosen_records.append((szip_ce as Dictionary).get("record"))
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_search"):
				var szip_picked: Variant = await ctx.runner_decision_maker.choose_from_search(
					szip_chosen_records, ctx)
				if szip_picked is CardRecord:
					for szip_ce in szip_candidates:
						if (szip_ce as Dictionary).get("record") == szip_picked:
							szip_chosen_entry = szip_ce as Dictionary
							break

			var szip_record: CardRecord = szip_chosen_entry.get("record") as CardRecord
			var szip_from_zone: String  = szip_chosen_entry.get("zone", "stack")
			var szip_is_trojan: bool    = szip_record.has_subtype("trojan")

			# Remove from the source zone
			match szip_from_zone:
				"stack":
					ctx.runner_deck.erase(szip_record)
				"heap":
					ctx.runner_discard.erase(szip_record)
				"grip":
					# Remove from hand (entries are dicts with card_record key)
					for szip_i in range(ctx.runner_hand.size() - 1, -1, -1):
						var szip_he: Dictionary = ctx.runner_hand[szip_i] as Dictionary
						if szip_he.get("card_record") == szip_record:
							ctx.runner_hand.remove_at(szip_i)
							break

			# Find Muse itself (the self card executing this effect)
			var szip_muse: InstalledCard = _get_self_card(ctx)

			# Build the InstalledCard
			var szip_installed := InstalledCard.make_runtime_instance(szip_record, "runner_rig", "root", true)

			if szip_is_trojan:
				# Trojan path: install on a piece of ice
				var szip_host_ice: InstalledCard = null
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_host_ice"):
					szip_host_ice = await ctx.runner_decision_maker.choose_host_ice(ctx)
				if szip_host_ice == null:
					# Fallback: first available ice
					for szip_srv in ctx.servers.values():
						for szip_ice in (szip_srv as Server).ice:
							szip_host_ice = szip_ice as InstalledCard
							break
						if szip_host_ice != null:
							break
				if szip_host_ice != null:
					szip_installed.hosted_on_id = szip_host_ice.runtime_instance_id
					szip_installed.server_id    = szip_host_ice.server_id
					szip_host_ice.hosted_cards.append(szip_installed)
					ctx.send_log("Muse: %s installs %s on %s." % [
						ctx.runner_name(), szip_record.title, szip_host_ice.display_name()])
				else:
					# No ice to host on — fall back to rig
					ctx.runner_rig.append(szip_installed)
					ctx.send_log("Muse: %s installs %s (no ice available for trojan)." % [
						ctx.runner_name(), szip_record.title])
			else:
				# Non-trojan: install hosted on Muse (daemon hosting, zero extra MU)
				if szip_muse != null:
					szip_installed.hosted_on_id = szip_muse.runtime_instance_id
					szip_installed.server_id    = "runner_rig"
					szip_muse.hosted_cards.append(szip_installed)
					ctx.send_log("Muse: %s installs %s hosted on Muse." % [
						ctx.runner_name(), szip_record.title])
				else:
					# Muse couldn't be found — fall back to normal rig install
					ctx.runner_rig.append(szip_installed)
					ctx.send_log("Muse: %s installs %s (fallback — Muse not found in ctx)." % [
						ctx.runner_name(), szip_record.title])

			# Register event listeners
			if ctx.has_meta("register_installed_card"):
				var szip_reg: Callable = ctx.get_meta("register_installed_card") as Callable
				szip_reg.call(szip_installed)

			# Fire on_rez/on_install if defined (programs auto-rez on install)
			if ctx.has_meta("ability_registry"):
				var szip_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var szip_on_rez = szip_ab_reg.get_on_rez(szip_record.id)
				if szip_on_rez != null:
					ctx.current_event_data = {
						"card": szip_installed,
						"card_instance_id": szip_installed.runtime_instance_id
					}
					await execute_trigger(szip_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			ctx.send_log("[MU: %d/%d used]" % [ctx.runner_mu_used(), ctx.runner_total_mu()])

		# ── VP23 Sipa: Corp may swap passed ice with any other installed ice ───────

		"corp_may_swap_passed_ice_with_any_installed":
			# VP23 Sipa pass_ice trigger: Corp may swap the just-passed ice with any
			# other installed ice anywhere on the board.
			var cmspi_passed: InstalledCard = ctx.current_event_data.get("ice", null) as InstalledCard
			if cmspi_passed == null:
				return
			# Gather all other installed ice across every server
			var cmspi_candidates: Array = []
			for cmspi_srv_val in ctx.servers.values():
				var cmspi_s: Server = cmspi_srv_val as Server
				for cmspi_c in cmspi_s.ice:
					var cmspi_ic: InstalledCard = cmspi_c as InstalledCard
					if cmspi_ic != null and \
							cmspi_ic.runtime_instance_id != cmspi_passed.runtime_instance_id:
						cmspi_candidates.append(cmspi_ic)
			if cmspi_candidates.is_empty():
				ctx.send_log("Sipa: no other installed ice to swap with.")
				return
			var cmspi_dm: Object = ctx.corp_decision_maker
			var cmspi_chosen: InstalledCard = null
			if cmspi_dm != null and cmspi_dm.has_method("choose_modes"):
				var cmspi_modes: Array = [{"label": "Decline (keep positions)"}]
				for cmspi_ic in cmspi_candidates:
					var cmspi_ic_srv: Server = ctx.get_server((cmspi_ic as InstalledCard).server_id)
					var cmspi_srv_name: String = \
						cmspi_ic_srv.display_name() if cmspi_ic_srv != null else "unknown"
					cmspi_modes.append({"label": "Swap with %s (%s)" % [
						(cmspi_ic as InstalledCard).display_name(), cmspi_srv_name]})
				var cmspi_result: Array = await cmspi_dm.choose_modes(cmspi_modes, 1, ctx)
				var cmspi_idx: int = cmspi_result[0] if not cmspi_result.is_empty() else 0
				if cmspi_idx > 0:
					cmspi_chosen = cmspi_candidates[cmspi_idx - 1] as InstalledCard
			else:
				cmspi_chosen = cmspi_candidates[0] as InstalledCard  # AI default: swap first
			if cmspi_chosen == null:
				ctx.send_log("Sipa: %s declines to swap." % ctx.corp_name())
				return
			# Perform physical swap in server arrays
			var cmspi_srv_a: Server = ctx.get_server(cmspi_passed.server_id)
			var cmspi_srv_b: Server = ctx.get_server(cmspi_chosen.server_id)
			var cmspi_pos_a: int    = cmspi_srv_a.ice.find(cmspi_passed) if cmspi_srv_a else -1
			var cmspi_pos_b: int    = cmspi_srv_b.ice.find(cmspi_chosen) if cmspi_srv_b else -1
			if cmspi_pos_a < 0 or cmspi_pos_b < 0:
				push_error("AbilityInterpreter: Sipa swap — ice not found in server array")
				return
			cmspi_srv_a.ice[cmspi_pos_a] = cmspi_chosen
			cmspi_chosen.server_id       = cmspi_srv_a.server_id
			cmspi_srv_b.ice[cmspi_pos_b] = cmspi_passed
			cmspi_passed.server_id       = cmspi_srv_b.server_id
			ctx.send_log("Sipa: %s moves %s to %s; %s moves to %s." % [
				ctx.corp_name(),
				cmspi_chosen.display_name(), cmspi_srv_a.display_name(),
				cmspi_passed.display_name(), cmspi_srv_b.display_name()])

		# ── Adrian Seis (TAI): block all access except self ──────────────────────

		"runner_cannot_access_except_self":
			# Adrian Seis — psi mismatch (Corp wins, bids differ):
			# The runner cannot access any card in the server this run except Adrian Seis
			# itself.  We store Adrian Seis's runtime_instance_id in a flag; _access_card
			# in RSM skips every card whose IID doesn't match.  Adrian Seis is an upgrade
			# in the root so it IS in the access list — the runner sees it but cannot access
			# anything else (the Corp benefits by hiding all other root cards).
			var rcaes_iid: String = ctx.current_event_data.get("card_instance_id", "")
			if rcaes_iid == "":
				push_error("runner_cannot_access_except_self: no card_instance_id in current_event_data")
				return
			ctx.runner_cannot_access_except_self_card_id = rcaes_iid
			ctx.send_log("[Adrian Seis] %s cannot access cards in this server other than Adrian Seis this run." % \
				ctx.runner_name())

		"runner_cannot_access_self":
			# Adrian Seis — psi match (runner wins, bids match):
			# The runner cannot access Adrian Seis itself for the remainder of this run.
			# Appends the card's runtime_instance_id to the general access blocklist so the
			# RSM skips it when iterating the breach access list.
			var rcas_iid: String = ctx.current_event_data.get("card_instance_id", "")
			if rcas_iid == "":
				push_error("runner_cannot_access_self: no card_instance_id in current_event_data")
				return
			if rcas_iid not in ctx.runner_access_blocked_card_iids:
				ctx.runner_access_blocked_card_iids.append(rcas_iid)
			ctx.send_log("[Adrian Seis] Adrian Seis cannot be accessed by %s for the remainder of this run." % \
				ctx.runner_name())

		# ── Capybara (TAI): remove from game on bypass to derez that ice ───────────

		"remove_self_from_game_derez_bypassed_ice":
			# Capybara hardware: when a bypass occurs, the runner may remove Capybara
			# from the game to derez the bypassed ice.  Fires via runner_bypasses_ice
			# listener; current_event_data["ice"] is the InstalledCard that was bypassed.
			var cap_self: InstalledCard = _get_self_card(ctx)
			if cap_self == null:
				return
			var cap_ice: InstalledCard = ctx.current_event_data.get("ice", null) as InstalledCard
			if cap_ice == null or not cap_ice.is_rezzed:
				return
			# Optional: ask the runner
			var cap_use := false
			var cap_dm: Object = ctx.runner_decision_maker
			if cap_dm != null and cap_dm.has_method("choose_optional_ability"):
				cap_use = await cap_dm.choose_optional_ability(
					"Capybara: remove from game to derez %s?" % cap_ice.display_name(), ctx)
			else:
				cap_use = true  # AI: always use when ice is still rezzed
			if not cap_use:
				return
			# Remove Capybara from the game (not the discard)
			ctx.runner_rig.erase(cap_self)
			ctx.unregister_all_card_effects(cap_self.runtime_instance_id)
			if cap_self.card_record != null:
				ctx.runner_rfg.append(cap_self.card_record)
			# Derez the bypassed ice
			cap_ice.is_rezzed = false
			ctx.send_log("[Capybara] Removed from game — %s is derezzed." % cap_ice.display_name())

		# ── VP31 Vertigo: prevent runner from stealing or trashing this run ────────

		"set_runner_cannot_steal_or_trash":
			# VP31 Vertigo pass_ice trigger: prevent runner from stealing or trashing
			# any card for the remainder of this run.
			ctx.runner_cannot_steal_or_trash_this_run = true
			ctx.send_log("Vertigo: %s cannot steal or trash cards for the rest of this run." % \
				ctx.runner_name())

		# ── RWR Sisyphus Protocol: Corp may pay or trash to force re-encounter ────

		"sisyphus_protocol_re_encounter_choice":
			# Fired by Sisyphus Protocol's pass_ice trigger (scored agenda, once per turn).
			# Corp chooses to pay 1cr OR trash 1 card from HQ. If they do, the runner
			# must encounter the just-passed code gate or sentry again.
			var spr_ice: InstalledCard = ctx.current_event_data.get("ice", null) as InstalledCard
			if spr_ice == null:
				return

			# Build the mode list based on what the Corp can currently afford.
			var spr_modes: Array = [{"label": "Decline — do not force re-encounter"}]
			if ctx.corp_credits >= 1:
				spr_modes.append({"label": "Pay 1[credit] — %s must encounter %s again" % [
					ctx.runner_name(), spr_ice.display_name()]})
			if not ctx.corp_hand.is_empty():
				spr_modes.append({"label": "Trash 1 HQ card — %s must encounter %s again" % [
					ctx.runner_name(), spr_ice.display_name()]})

			if spr_modes.size() == 1:
				# Corp cannot pay or trash — ability does nothing.
				ctx.send_log("Sisyphus Protocol: %s cannot afford to force re-encounter." % ctx.corp_name())
				return

			# Ask the Corp DM for a choice.
			var spr_dm: Object = ctx.corp_decision_maker
			var spr_result: Array = [0]
			if spr_dm != null and spr_dm.has_method("choose_modes"):
				# AI heuristic: use the ability if it costs only credits and Corp is ahead.
				if ctx.simulation_mode:
					var spr_corp_pts: int  = ctx.corp_agenda_points()
					var spr_run_pts:  int  = ctx.runner_agenda_points()
					if spr_corp_pts >= spr_run_pts and ctx.corp_credits >= 1:
						spr_result = [1]   # pay 1cr
					else:
						spr_result = [0]   # decline
				else:
					spr_result = await spr_dm.choose_modes(spr_modes, 1, ctx)

			var spr_choice: int = spr_result[0] if not spr_result.is_empty() else 0
			# Map choice index back to the actual list (which may be missing "pay" if unaffordable).
			# Rebuild to get actual labels.
			if spr_choice == 0:
				ctx.send_log("Sisyphus Protocol: %s declines." % ctx.corp_name())
				return

			# Identify what was chosen by re-walking the modes array.
			var spr_label: String = (spr_modes[spr_choice] as Dictionary).get("label", "")
			if spr_label.begins_with("Pay 1"):
				ctx.corp_credits -= 1
				ctx.send_log("Sisyphus Protocol: %s pays 1[cr] — %s must encounter %s again." % [
					ctx.corp_name(), ctx.runner_name(), spr_ice.display_name()])
			elif spr_label.begins_with("Trash 1"):
				# Corp chooses a card from HQ to trash.
				var spr_hq_entry: Variant = ctx.corp_hand[0]
				if spr_dm != null and spr_dm.has_method("choose_card_from_hand"):
					spr_hq_entry = await spr_dm.choose_card_from_hand(ctx.corp_hand, ctx)
				if spr_hq_entry == null:
					ctx.send_log("Sisyphus Protocol: %s cancels trash — no re-encounter." % ctx.corp_name())
					return
				var spr_hq_record: CardRecord = (spr_hq_entry as Dictionary).get("card_record", null) as CardRecord
				ctx.corp_hand.erase(spr_hq_entry)
				if spr_hq_record != null:
					ctx.corp_discard.append(spr_hq_record)
					ctx.send_log("Sisyphus Protocol: %s trashes %s from HQ — %s must encounter %s again." % [
						ctx.corp_name(), spr_hq_record.title, ctx.runner_name(), spr_ice.display_name()])
				else:
					ctx.send_log("Sisyphus Protocol: %s trashes from HQ — %s must encounter %s again." % [
						ctx.corp_name(), ctx.runner_name(), spr_ice.display_name()])
			else:
				return   # Unexpected — bail out

			# Signal RunStateMachine to re-encounter the passed ice.
			ctx.run_modifiers["re_encounter_current_ice"] = true

		# ── VP31 Vertigo / general: runner loses N clicks immediately ─────────────

		"lose_clicks":
			# Reduce the runner's or Corp's click pool immediately (floor 0).
			# params: { subject: "runner"|"corp", amount: int }
			var lc_subject: String = params.get("subject", "runner")
			var lc_amount: int     = params.get("amount", 1)
			if lc_subject == "corp":
				ctx.corp_clicks = max(0, ctx.corp_clicks - lc_amount)
				ctx.send_log("%s loses %d click(s). (%d remaining)" % [
					ctx.corp_name(), lc_amount, ctx.corp_clicks])
			else:
				ctx.runner_clicks = max(0, ctx.runner_clicks - lc_amount)
				ctx.send_log("%s loses %d click(s). (%d remaining)" % [
					ctx.runner_name(), lc_amount, ctx.runner_clicks])

		# ── VP39 ezaM sub 1: look at top of R&D, may move to bottom ───────────────

		"look_top_rd_may_move_to_bottom":
			# VP39 ezaM sub 1: Corp looks at the top card of R&D, may move it to bottom.
			if ctx.corp_deck.is_empty():
				ctx.send_log("ezaM: R&D is empty — nothing to look at.")
				return
			var ltrm_card: CardRecord = ctx.corp_deck[0] as CardRecord
			ctx.send_log("ezaM: %s looks at top of R&D (%s)." % [ctx.corp_name(), ltrm_card.title])
			var ltrm_move: bool = false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_yes_no"):
				ltrm_move = await ctx.corp_decision_maker.choose_yes_no(
					"Move %s to the bottom of R&D?" % ltrm_card.title, ctx)
			if ltrm_move:
				ctx.corp_deck.remove_at(0)
				ctx.corp_deck.append(ltrm_card)
				ctx.send_log("ezaM: %s moves %s to the bottom of R&D." % [ctx.corp_name(), ltrm_card.title])
			else:
				ctx.send_log("ezaM: %s leaves R&D unchanged." % ctx.corp_name())

		# ── VP39 ezaM sub 2: all ICE gets +1 strength for this run ────────────────

		"set_global_ice_strength_bonus":
			# VP39 ezaM sub 2: all ICE gets +N strength for the rest of this run.
			# Applied to each new EncounterState.ice_strength when encounters are set up.
			# params: { amount: int }
			var sgsb_amount: int = params.get("amount", 1)
			ctx.global_ice_strength_bonus_this_run += sgsb_amount
			ctx.send_log("ezaM: all ICE gains +%d strength for the rest of this run." % sgsb_amount)

		# ── VP39 ezaM paw_action: swap self with any other installed ice ──────────

		"swap_self_with_any_installed_ice":
			# VP39 ezaM paw_action (cost 1 click): swap ezaM with any other installed ice.
			# Signals RSM via enc_swap_ice meta to update its position snapshot.
			var sswai_self: InstalledCard = ctx.current_event_data.get("card", null) as InstalledCard
			if sswai_self == null:
				push_error("AbilityInterpreter: swap_self_with_any_installed_ice — no card in event data")
				return
			# Gather all other installed ice across every server
			var sswai_candidates: Array = []
			for sswai_srv_val in ctx.servers.values():
				var sswai_s: Server = sswai_srv_val as Server
				for sswai_c in sswai_s.ice:
					var sswai_ic: InstalledCard = sswai_c as InstalledCard
					if sswai_ic != null and \
							sswai_ic.runtime_instance_id != sswai_self.runtime_instance_id:
						sswai_candidates.append(sswai_ic)
			if sswai_candidates.is_empty():
				ctx.send_log("ezaM: no other installed ice to swap with.")
				return
			var sswai_dm: Object = ctx.corp_decision_maker
			var sswai_chosen: InstalledCard = sswai_candidates[0] as InstalledCard
			if sswai_dm != null and sswai_dm.has_method("choose_derez_target"):
				sswai_chosen = await sswai_dm.choose_derez_target(sswai_candidates, ctx)
			if sswai_chosen == null:
				return
			# Perform physical swap in server arrays
			var sswai_srv_a: Server = ctx.get_server(sswai_self.server_id)
			var sswai_srv_b: Server = ctx.get_server(sswai_chosen.server_id)
			var sswai_pos_a: int    = sswai_srv_a.ice.find(sswai_self)   if sswai_srv_a else -1
			var sswai_pos_b: int    = sswai_srv_b.ice.find(sswai_chosen) if sswai_srv_b else -1
			if sswai_pos_a < 0 or sswai_pos_b < 0:
				push_error("AbilityInterpreter: ezaM swap — ice not found in server array")
				return
			sswai_srv_a.ice[sswai_pos_a] = sswai_chosen
			sswai_chosen.server_id       = sswai_srv_a.server_id
			sswai_srv_b.ice[sswai_pos_b] = sswai_self
			sswai_self.server_id         = sswai_srv_b.server_id
			ctx.send_log("ezaM: %s swaps %s into position (ezaM moves to %s)." % [
				ctx.corp_name(), sswai_chosen.display_name(), sswai_srv_b.display_name()])
			# Signal RSM to update its _ice_positions snapshot for the current encounter position
			ctx.set_meta("enc_swap_ice", sswai_chosen)

		# ── VP40 Knowledge Seeker sub 1: place virus counter on self ─────────────

		"place_virus_counter_on_self":
			# VP40 Knowledge Seeker sub 1: place 1 virus counter on this ICE.
			var pvcos_card := _get_self_card(ctx)
			if pvcos_card == null:
				push_error("AbilityInterpreter: place_virus_counter_on_self — card not found")
				return
			pvcos_card.add_counter("virus", 1)
			ctx.send_log("Knowledge Seeker: places 1 virus counter on itself (%d total)." % \
				pvcos_card.get_counter("virus"))

		# ── VP40 Knowledge Seeker sub 2: look at top N of R&D, arrange ────────────

		"look_top_n_rd_arrange":
			# VP40 Knowledge Seeker sub 2: Corp looks at top N cards of R&D and
			# arranges them in any order.
			# params: { count: int }
			var ltnra_count: int = params.get("count", 4)
			if ctx.corp_deck.is_empty():
				ctx.send_log("Knowledge Seeker: R&D is empty.")
				return
			var ltnra_n: int    = mini(ltnra_count, ctx.corp_deck.size())
			var ltnra_view: Array = []
			for i in range(ltnra_n):
				ltnra_view.append(ctx.corp_deck[i])
			ctx.send_log("Knowledge Seeker: %s looks at top %d card(s) of R&D." % [
				ctx.corp_name(), ltnra_n])
			# Corp arranges; if no DM method, leave order unchanged
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("arrange_top_rd"):
				var ltnra_arranged: Array = \
					await ctx.corp_decision_maker.arrange_top_rd(ltnra_view, ctx)
				if ltnra_arranged.size() == ltnra_n:
					for i in range(ltnra_n):
						ctx.corp_deck[i] = ltnra_arranged[i]
					ctx.send_log("Knowledge Seeker: %s arranges the top %d card(s) of R&D." % [
						ctx.corp_name(), ltnra_n])

		# ── VP40 Knowledge Seeker encounter_ended: purge counters and derez ───────

		"purge_self_counters_and_derez":
			# VP40 Knowledge Seeker encounter_ended trigger: when this ICE has >= 3 virus
			# counters after the encounter, remove all counters and derez itself.
			# params: { counter: String }  default "virus"
			var pscad_counter: String = params.get("counter", "virus")
			var pscad_card := _get_self_card(ctx)
			if pscad_card == null:
				push_error("AbilityInterpreter: purge_self_counters_and_derez — card not found")
				return
			var pscad_count: int = pscad_card.get_counter(pscad_counter)
			pscad_card.remove_counter(pscad_counter, pscad_count)
			ctx.send_log("Knowledge Seeker: removes %d virus counter(s) and derezzes itself." % pscad_count)
			await _derez_card(pscad_card, ctx)

		# ── VP18 Aircheck: optional run on a remote server ────────────────────────

		"optional_run":
			# Ask the runner if they want to make an optional run on one of the specified servers.
			# If they decline, nothing happens. If they accept, a full run is initiated.
			# params: { "servers": Array }
			# Used by: VP18 Aircheck (optional second run on remote after successful HQ/R&D run).
			var or_servers: Array = params.get("servers", ["remote"]) as Array
			# Expand "remote" placeholder to actual live remote server IDs
			var or_expanded: Array = []
			for or_entry in or_servers:
				if or_entry == "remote":
					for or_remote_srv in ctx.get_remote_servers():
						or_expanded.append((or_remote_srv as Server).server_id)
				else:
					or_expanded.append(or_entry)
			if or_expanded.is_empty():
				ctx.send_log("Aircheck: no valid remote servers available â optional run skipped.")
				return
			# Ask runner if they want to make the run
			var or_do_run := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_run"):
				or_do_run = await ctx.runner_decision_maker.choose_optional_run(or_expanded, ctx)
			else:
				or_do_run = true   # AI default: always run if servers available
			if not or_do_run:
				ctx.send_log("Aircheck: %s declines the optional run." % ctx.runner_name())
				return
			# Choose server and run
			var or_chosen: String = or_expanded[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				or_chosen = await ctx.runner_decision_maker.choose_server(or_expanded, ctx)
			if ctx.has_meta("on_run_started"):
				var or_cb: Callable = ctx.get_meta("on_run_started") as Callable
				or_cb.call(or_chosen)
				await Engine.get_main_loop().process_frame
			var or_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if or_rsm == null:
				push_error("AbilityInterpreter: optional_run â no run_state_machine on ctx")
				return
			await or_rsm.execute(or_chosen)

		# ── VP22 Read-Write Share: host a grip card facedown, draw 1 ─────────────

		"host_card_from_grip_facedown_draw":
			# Runner may host 1 card from grip facedown on this program, then draw 1 card.
			# Does nothing if grip is empty or hosting limit is reached.
			# params: { "limit": int }  default 4
			# Used by: VP22 Read-Write Share (on_rez and runner_turn_start triggers).
			var hcgfd_limit: int = params.get("limit", 4)
			var hcgfd_card := _get_self_card(ctx)
			if hcgfd_card == null:
				push_error("AbilityInterpreter: host_card_from_grip_facedown_draw — card not found")
				return
			if hcgfd_card.hosted_grip_cards.size() >= hcgfd_limit:
				ctx.send_log("Read-Write Share: already at limit (%d hosted cards)." % hcgfd_limit)
				return
			if ctx.runner_hand.is_empty():
				ctx.send_log("Read-Write Share: grip is empty â nothing to host.")
				return
			# Runner may optionally host a card
			var hcgfd_do_host := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_host_card_facedown"):
				hcgfd_do_host = await ctx.runner_decision_maker.choose_host_card_facedown(hcgfd_card, ctx)
			else:
				hcgfd_do_host = true   # AI default: always host
			if not hcgfd_do_host:
				ctx.send_log("Read-Write Share: %s declines to host a card." % ctx.runner_name())
				return
			# Runner chooses which grip card to host
			var hcgfd_chosen_entry: Dictionary = {}
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_grip"):
				hcgfd_chosen_entry = await ctx.runner_decision_maker.choose_card_from_grip(ctx)
			if hcgfd_chosen_entry.is_empty() and not ctx.runner_hand.is_empty():
				hcgfd_chosen_entry = ctx.runner_hand[0] as Dictionary
			if hcgfd_chosen_entry.is_empty():
				return
			var hcgfd_record: CardRecord = hcgfd_chosen_entry.get("card_record", null) as CardRecord
			if hcgfd_record == null:
				return
			# Move from grip to hosted facedown
			ctx.runner_hand.erase(hcgfd_chosen_entry)
			hcgfd_card.hosted_grip_cards.append(hcgfd_record)
			ctx.send_log("Read-Write Share: %s hosts %s facedown (%d/%d)." % [
				ctx.runner_name(), hcgfd_record.title,
				hcgfd_card.hosted_grip_cards.size(), hcgfd_limit])
			# Draw 1 card as the hosting bonus
			_draw_cards("runner", 1, ctx)

		# ── VP22 Read-Write Share: shuffle hosted cards back into stack ───────────

		"shuffle_hosted_grip_to_stack":
			# Shuffle all facedown hosted cards on this program back into the runner's stack.
			# Used by: VP22 Read-Write Share on_trash trigger.
			var shgs_card := _get_self_card(ctx)
			if shgs_card == null:
				push_error("AbilityInterpreter: shuffle_hosted_grip_to_stack — card not found")
				return
			if shgs_card.hosted_grip_cards.is_empty():
				ctx.send_log("Read-Write Share: no hosted cards to return to stack.")
				return
			var shgs_count: int = shgs_card.hosted_grip_cards.size()
			for shgs_hosted in shgs_card.hosted_grip_cards:
				var shgs_cr: CardRecord = shgs_hosted as CardRecord
				if shgs_cr != null:
					ctx.runner_deck.append(shgs_cr)
			shgs_card.hosted_grip_cards.clear()
			ctx.runner_deck.shuffle()
			ctx.send_log("Read-Write Share: shuffles %d hosted card(s) back into the stack." % shgs_count)

		# ── VP25 Word on the Street: respond to Corp scoring an agenda ────────────

		"word_on_the_street_corp_scores_response":
			# Two-branch response to corp_scores_agenda event:
			#   Installed this turn (not_installed_this_turn == false):
			#     Word on the Street moves to Corp score area as -1 agenda points.
			#   Not installed this turn (not_installed_this_turn == true):
			#     Trash self, Runner gains 4 cr, draws 1 card.
			# Used by: VP25 Word on the Street corp_scores_agenda trigger.
			var wots_card := _get_self_card(ctx)
			if wots_card == null:
				push_error("AbilityInterpreter: word_on_the_street — card not found")
				return
			if not ctx.corp_scored_agenda_not_installed_this_turn:
				# Agenda WAS installed this turn â Word on the Street moves to Corp score area as -1 AP
				ctx.runner_rig.erase(wots_card)
				ctx.unregister_all_card_effects(wots_card.runtime_instance_id)
				var wots_cr: CardRecord = wots_card.card_record
				if wots_cr != null:
					wots_cr.agenda_points = -1
					wots_cr.card_type = "agenda"
					ctx.corp_score_area.append(wots_cr)
					var wots_inst := InstalledCard.make_runtime_instance(wots_cr, "corp_score_area", "root", true)
					ctx.corp_score_area_cards.append(wots_inst)
				ctx.send_log("Word on the Street: %s adds it to their score area as -1 agenda point." % ctx.corp_name())
			else:
				# Agenda was NOT installed this turn â trash self, Runner gains 4 cr, draws 1
				ctx.runner_rig.erase(wots_card)
				ctx.unregister_all_card_effects(wots_card.runtime_instance_id)
				if wots_card.card_record != null:
					ctx.runner_discard.append(wots_card.card_record)
				ctx.runner_credits += 4
				ctx.send_log("Word on the Street: trashed â %s gains 4 cr." % ctx.runner_name())
				_draw_cards("runner", 1, ctx)

		# ── VP35 Perfect Recall: reveal HQ card, block runner steal/trash of copies ─

		"reveal_hq_card_and_block_steal_trash":
			# Corp picks 1 card from HQ and reveals it to the Runner.
			# The Runner cannot steal or trash copies of that card for the remainder of this run.
			# Used by: VP35 Perfect Recall paw_action.
			if ctx.corp_hand.is_empty():
				ctx.send_log("Perfect Recall: HQ is empty â no card to reveal.")
				return
			# Corp chooses which HQ card to reveal
			var rhrst_entry: Dictionary = {}
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_card_from_hq_to_reveal"):
				rhrst_entry = await ctx.corp_decision_maker.choose_card_from_hq_to_reveal(ctx)
			if rhrst_entry.is_empty() and not ctx.corp_hand.is_empty():
				rhrst_entry = ctx.corp_hand[0] as Dictionary
			if rhrst_entry.is_empty():
				return
			var rhrst_record: CardRecord = rhrst_entry.get("card_record", null) as CardRecord
			if rhrst_record == null:
				return
			ctx.send_log("Perfect Recall: %s reveals %s from HQ." % [ctx.corp_name(), rhrst_record.title])
			if rhrst_record.id not in ctx.runner_steal_trash_blocked_card_ids:
				ctx.runner_steal_trash_blocked_card_ids.append(rhrst_record.id)
			ctx.send_log("Perfect Recall: %s cannot steal or trash copies of %s this run." % [
				ctx.runner_name(), rhrst_record.title])

		# ── VP1 Chain Reaction: Runner trashes 2 Corp installed, Corp trashes 1 Runner installed ──

		"runner_chooses_corp_installed_to_trash":
			# Runner chooses up to `count` installed Corp cards to trash.
			# Used by: VP1 Chain Reaction on_play effect.
			var rcc_count: int = params.get("count", 2)
			var rcc_candidates: Array = []
			for srv in ctx.servers.values():
				var s: Server = srv as Server
				rcc_candidates.append_array(s.ice)
				rcc_candidates.append_array(s.root)
			if rcc_candidates.is_empty():
				ctx.send_log("Chain Reaction: no installed Corp cards to trash.")
				return
			var rcc_to_trash: int = mini(rcc_count, rcc_candidates.size())
			var rcc_chosen: Array = []
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_installed_to_trash"):
				rcc_chosen = await ctx.runner_decision_maker.choose_installed_to_trash(rcc_candidates, rcc_to_trash, ctx)
			else:
				for i in range(rcc_to_trash):
					rcc_chosen.append(rcc_candidates[i])
			for rcc_card in rcc_chosen:
				var rcc_ic: InstalledCard = rcc_card as InstalledCard
				if rcc_ic == null:
					continue
				var rcc_server: Server = ctx.get_server(rcc_ic.server_id)
				if rcc_server != null:
					if rcc_ic.zone == "root":
						rcc_server.remove_from_root(rcc_ic)
					else:
						rcc_server.remove_ice(rcc_ic)
				ctx.unregister_all_card_effects(rcc_ic.runtime_instance_id)
				if rcc_ic.card_record != null:
					ctx.corp_discard.append(rcc_ic.card_record)
					if not rcc_ic.is_rezzed:
						ctx.corp_discard_facedown[rcc_ic.card_record.title] = true
				ctx.send_log("Chain Reaction: %s trashes %s." % [ctx.runner_name(), rcc_ic.display_name()])
			ctx.remove_empty_remote_servers()

		"corp_chooses_runner_installed_to_trash":
			# Corp chooses 1 installed Runner card to trash.
			# Used by: VP1 Chain Reaction on_play effect.
			if ctx.runner_rig.is_empty():
				ctx.send_log("Chain Reaction: Runner has no installed cards to trash.")
				return
			var ccrt_chosen: InstalledCard = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_runner_installed_to_trash"):
				ccrt_chosen = await ctx.corp_decision_maker.choose_runner_installed_to_trash(ctx.runner_rig.duplicate(), ctx)
			else:
				ccrt_chosen = ctx.runner_rig[0] as InstalledCard
			if ccrt_chosen == null:
				return
			ctx.runner_rig.erase(ccrt_chosen)
			ctx.unregister_all_card_effects(ccrt_chosen.runtime_instance_id)
			if ccrt_chosen.card_record != null:
				ctx.runner_discard.append(ccrt_chosen.card_record)
			ctx.send_log("Chain Reaction: %s trashes %s." % [ctx.corp_name(), ccrt_chosen.display_name()])
			# VP17 Hiram: Corp trashing runner hardware fires hardware_trashed (Corp source)
			if ccrt_chosen.card_record != null and ccrt_chosen.card_record.card_type == "hardware":
				await ctx.notify_event("hardware_trashed", {
					"card_id": ccrt_chosen.card_id, "source": "corp"
				}, self)

		# ── VP56 Sacrifice Zone Expansion: reactive meat damage on runner run ──────

		"sacrifice_zone_expansion_reactive":
			# Corp may remove 1 advancement counter from SZE to deal 1 meat damage.
			# Fires when the Runner makes a successful run on a remote (not SZE's own server).
			var sze_card := _get_self_card(ctx)
			if sze_card == null:
				push_error("AbilityInterpreter: sacrifice_zone_expansion_reactive — card not found")
				return
			if sze_card.get_counter("advancement") < 1:
				ctx.send_log("Sacrifice Zone Expansion: no advancement counters to spend.")
				return
			var sze_activate := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var sze_modes: Array = [
					{"label": "Sacrifice Zone Expansion: remove 1 advancement counter — do 1 meat damage"},
					{"label": "Pass"}
				]
				var sze_chosen: Array = await ctx.corp_decision_maker.choose_modes(sze_modes, 1, ctx)
				sze_activate = (not sze_chosen.is_empty() and sze_chosen[0] == 0)
			else:
				sze_activate = true
			if not sze_activate:
				ctx.send_log("Sacrifice Zone Expansion: %s passes." % ctx.corp_name())
				return
			sze_card.remove_counter("advancement", 1)
			ctx.send_log("Sacrifice Zone Expansion: removes 1 advancement counter (%d remaining) — 1 meat damage." % sze_card.get_counter("advancement"))
			await _deal_damage("meat", 1, ctx)

		"derez_host_ice":
			# Tranquilizer: at the start of Corp's turn, derez the ice this program is hosted on.
			var dhi_self := _get_self_card(ctx)
			if dhi_self == null:
				return
			if dhi_self.hosted_on_id == "":
				ctx.send_log("Tranquilizer: not hosted on ice — no effect.")
				return
			var dhi_host := ctx.get_ice_by_instance_id(dhi_self.hosted_on_id)
			if dhi_host == null:
				return
			if dhi_host.is_rezzed:
				dhi_host.is_rezzed = false
				ctx.send_log("Tranquilizer: %s is derezzed." % dhi_host.display_name())
				await ctx.notify_event("on_derez", {
					"card": dhi_host,
					"card_instance_id": dhi_self.runtime_instance_id
				}, self)
			else:
				ctx.send_log("Tranquilizer: %s is already unrezzed." % dhi_host.display_name())

		# ── VP17 Hiram: look at top card of R&D ─────────────────────────────────

		"look_at_top_rd":
			# Runner looks at the top card of R&D (does not draw it; not an expose).
			if ctx.corp_deck.is_empty():
				ctx.send_log("%s looks at top of R&D — R&D is empty." % ctx.runner_name())
			else:
				var ltr_top: CardRecord = ctx.corp_deck[0] as CardRecord
				ctx.send_log("%s looks at top of R&D: %s." % [ctx.runner_name(), ltr_top.title])
				# Notify UI if a display callback is registered
				if ctx.has_meta("on_look_at_rd_top"):
					var ltr_cb: Callable = ctx.get_meta("on_look_at_rd_top") as Callable
					await ltr_cb.call(ltr_top)

		# ── VP64 Flagship: suppress run success ──────────────────────────────────

		"suppress_run_success":
			# When set, _phase_success() skips run_successful and the successful_run event.
			# The breach still happens normally.
			ctx.run_success_suppressed = true
			ctx.send_log("Flagship: run success suppressed — breach proceeds without success effects.")

		# ── VP46 Ad Nihilum: search R&D for non-agenda card by subtypes ──────────

		"search_rd_non_agenda_by_subtypes":
			# Search R&D for a non-agenda card with one of the specified subtypes.
			# params: { subtypes: Array[String], destination: "hq" }
			var srnas_subtypes: Array = params.get("subtypes", []) as Array
			# Collect matching cards
			var srnas_matches: Array = []
			for srnas_cr in ctx.corp_deck:
				var srnas_r: CardRecord = srnas_cr as CardRecord
				if srnas_r == null or srnas_r.is_agenda():
					continue
				var srnas_match := false
				for srnas_st in srnas_subtypes:
					if srnas_r.has_subtype(srnas_st as String):
						srnas_match = true
						break
				if srnas_match:
					srnas_matches.append(srnas_r)
			if srnas_matches.is_empty():
				ctx.send_log("%s: no matching card in R&D — shuffles R&D." % ctx.corp_name())
				ctx.corp_deck.shuffle()
				return
			# Corp may choose which card to take (may also decline)
			var srnas_chosen: CardRecord = null
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_from_rd_by_subtypes"):
				srnas_chosen = await ctx.corp_decision_maker.choose_from_rd_by_subtypes(
					srnas_matches, ctx)
			else:
				srnas_chosen = srnas_matches[0]   # AI default: take first match
			ctx.corp_deck.erase(srnas_chosen)
			ctx.corp_deck.shuffle()
			if srnas_chosen != null:
				ctx.corp_hand.append({"card_id": srnas_chosen.id, "card_record": srnas_chosen})
				ctx.send_log("Ad Nihilum: %s searches R&D — reveals and adds %s to HQ." % [
					ctx.corp_name(), srnas_chosen.title
				])
			else:
				ctx.send_log("Ad Nihilum: %s declines to search R&D." % ctx.corp_name())

		# ── VP65 Shackleton Grid: Corp may do 4 meat damage ─────────────────────

		"corp_may_deal_meat_damage":
			# Corp may choose to deal N meat damage to the runner.
			# params: { amount: int }
			var cmdd_amount: int = params.get("amount", 4)
			var cmdd_deal := true
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var cmdd_modes: Array = [
					{"label": "Deal %d meat damage (Shackleton Grid)" % cmdd_amount},
					{"label": "Decline"}
				]
				var cmdd_chosen: Array = await ctx.corp_decision_maker.choose_modes(cmdd_modes, 1, ctx)
				cmdd_deal = (not cmdd_chosen.is_empty() and cmdd_chosen[0] == 0)
			else:
				cmdd_deal = true   # AI default: always deal the damage
			if cmdd_deal:
				ctx.send_log("Shackleton Grid: %s deals %d meat damage." % [ctx.corp_name(), cmdd_amount])
				await _deal_damage("meat", cmdd_amount, ctx)
			else:
				ctx.send_log("Shackleton Grid: %s declines." % ctx.corp_name())

		# ── VP36 Méliès U effects ─────────────────────────────────────────────────

		"flip_melies_u":
			# Flip Méliès U to its back side and reveal the Corp's prediction.
			# Fires the internal melies_u_flipped event so the back-side ability
			# can check whether the prediction matches the run server.
			ctx.melies_u_flipped = true
			var fmu_server: String = ctx.current_event_data.get("server_id", "")
			var fmu_secret: String = ctx.melies_u_secret_side
			if fmu_secret == "":
				ctx.send_log("Méliès U flips! No prediction was set — back-side ability does not resolve.")
			elif fmu_secret == fmu_server:
				ctx.send_log("Méliès U flips! Prediction correct — %s predicted %s and run is on %s!" % [
					ctx.corp_name(), fmu_secret.to_upper(), fmu_server.to_upper()])
			else:
				ctx.send_log("Méliès U flips! Prediction wrong — %s predicted %s but run is on %s." % [
					ctx.corp_name(), fmu_secret.to_upper(), fmu_server.to_upper()])
			# Notify UI so GameUI can immediately refresh the identity card display.
			if ctx.has_meta("on_melies_u_flip"):
				(ctx.get_meta("on_melies_u_flip") as Callable).call(true, fmu_server)
			# Fire internal event so back-side ability can resolve (condition guards it).
			await ctx.notify_event("melies_u_flipped", {"server_id": fmu_server}, self)

		"flip_melies_u_back":
			# Flip Méliès U back to its front side at end of Runner's discard phase.
			if ctx.melies_u_flipped:
				ctx.melies_u_flipped = false
				ctx.send_log("Méliès U flips back to its front side.")
				# Notify UI so the identity card reverts to its front-face art.
				if ctx.has_meta("on_melies_u_flip"):
					(ctx.get_meta("on_melies_u_flip") as Callable).call(false, "")

		"corp_secretly_select_melies_side":
			# Corp secretly chooses which central server to predict for next Runner turn.
			# Logged only as "Corp sets identity" — the specific choice stays hidden.
			var css_sides: Array = ["hq", "rd", "archives"]
			var css_labels: Array = [
				{"label": "Predict HQ (Tenure Floors)"},
				{"label": "Predict R&D"},
				{"label": "Predict Archives (Disposal Grounds)"}
			]
			var css_idx: int = 0
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var css_chosen: Array = await ctx.corp_decision_maker.choose_modes(css_labels, 1, ctx)
				css_idx = css_chosen[0] if not css_chosen.is_empty() else 0
			# AI fallback: pick the central the runner is most likely to run next.
			# Simple heuristic — prefer the central they haven't run successfully this turn.
			else:
				if not ctx.runner_successful_run_on_rd_this_turn:
					css_idx = 1   # R&D
				elif not ctx.runner_successful_run_on_archives_this_turn:
					css_idx = 2   # Archives
				else:
					css_idx = 0   # HQ
			ctx.melies_u_secret_side = css_sides[css_idx]
			ctx.send_log("Méliès U: %s secretly sets their identity (choice hidden)." % ctx.corp_name())

		"may_trash_top_rd_add_archives_to_hq":
			# Méliès U back-side ability: Corp looks at top of R&D, may trash it,
			# and if they do, add 1 card from Archives to HQ.
			if ctx.corp_deck.is_empty():
				ctx.send_log("Méliès U: R&D is empty — no card to look at.")
				return
			var mta_top: CardRecord = ctx.corp_deck[0] as CardRecord
			ctx.send_log("Méliès U: %s looks at top of R&D: %s." % [ctx.corp_name(), mta_top.title])
			# Corp may trash the top card.
			var mta_trash := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_modes"):
				var mta_modes: Array = [
					{"label": "Trash %s from R&D" % mta_top.title},
					{"label": "Leave %s on top" % mta_top.title}
				]
				var mta_chosen: Array = await ctx.corp_decision_maker.choose_modes(mta_modes, 1, ctx)
				mta_trash = (not mta_chosen.is_empty() and mta_chosen[0] == 0)
			else:
				mta_trash = true   # AI default: always trash (disruptive)
			if not mta_trash:
				ctx.send_log("Méliès U: %s leaves %s on top of R&D." % [ctx.corp_name(), mta_top.title])
				return
			# Trash the top card to Archives (faceup — Corp placed it, not runner accessed it).
			ctx.corp_deck.erase(mta_top)
			ctx.corp_discard.append(mta_top)
			ctx.corp_discard_facedown[mta_top.title] = false
			ctx.send_log("Méliès U: %s trashes %s from R&D to Archives." % [ctx.corp_name(), mta_top.title])
			# Now add 1 card from Archives to HQ.
			if ctx.corp_discard.is_empty():
				ctx.send_log("Méliès U: Archives is empty — no card to add to HQ.")
				return
			var mta_arch_card: CardRecord = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_from_archives"):
				mta_arch_card = await ctx.corp_decision_maker.choose_from_archives(
					ctx.corp_discard.duplicate(), ctx)
			else:
				mta_arch_card = ctx.corp_discard[0] as CardRecord   # AI default: first card
			if mta_arch_card == null:
				ctx.send_log("Méliès U: %s does not take a card from Archives." % ctx.corp_name())
				return
			ctx.corp_discard.erase(mta_arch_card)
			ctx.corp_discard_facedown.erase(mta_arch_card.title)
			ctx.corp_hand.append({"card_id": mta_arch_card.id, "card_record": mta_arch_card})
			ctx.send_log("Méliès U: %s adds %s from Archives to HQ." % [ctx.corp_name(), mta_arch_card.title])

		# ── Generic optional multi-mode choice (corp or runner) ──────────────────

		"optional_choice":
			# Presents a list of labelled modes; the chosen player picks one (or declines).
			# params: {
			#   chooser: "corp" | "runner"   (default "corp")
			#   modes:   Array[{ label: String, condition: Dict (opt), effects: Array }]
			#   optional: bool (default true — player may decline)
			# }
			var oc_chooser: String  = params.get("chooser", "corp")
			var oc_optional: bool   = params.get("optional", true)
			var oc_all_modes: Array = params.get("modes", []) as Array
			var oc_dm: Object = ctx.corp_decision_maker \
				if oc_chooser == "corp" else ctx.runner_decision_maker

			# Filter modes by their optional inline conditions
			var oc_available: Array = []
			var oc_available_indices: Array = []
			for oc_i in range(oc_all_modes.size()):
				var oc_m: Dictionary = oc_all_modes[oc_i] as Dictionary
				var oc_mc: Dictionary = oc_m.get("condition", {}) as Dictionary
				if oc_mc.is_empty() or _evaluate_condition(oc_mc, ctx):
					oc_available.append(oc_m)
					oc_available_indices.append(oc_i)

			if oc_available.is_empty():
				return

			# Ask the choosing player
			var oc_chosen_idx: int = -1
			if oc_dm != null and oc_dm.has_method("choose_modes"):
				var oc_labels: Array = []
				for oc_m in oc_available:
					oc_labels.append(oc_m as Dictionary)
				if oc_optional:
					oc_labels.append({"label": "Decline"})
				var oc_result: Array = await oc_dm.choose_modes(oc_labels, 1, ctx)
				if oc_result.is_empty():
					return
				var oc_sel = oc_result[0]
				var oc_sel_int: int = int(oc_sel) if oc_sel is int else 0
				if oc_sel_int < oc_available.size():
					oc_chosen_idx = oc_sel_int
				# else: chose "Decline" label
			else:
				# AI default: pick first available mode
				oc_chosen_idx = 0

			if oc_chosen_idx < 0:
				return

			var oc_chosen_mode: Dictionary = oc_available[oc_chosen_idx] as Dictionary
			ctx.send_log("%s chooses: %s" % [ctx.player_name(oc_chooser), oc_chosen_mode.get("label", "?")])
			for oc_eff in oc_chosen_mode.get("effects", []) as Array:
				await _execute_effect(oc_eff as Dictionary, ctx, null)

		# ── Spend counter for a menu of effects (Solidarity Badge, Coalescence) ──

		"may_spend_counter_for_choice":
			# Runner may optionally spend 1 counter (+ optional click) to pick an effect.
			# params: {
			#   counter:    String (default "power")
			#   click_cost: bool   (default false — if true, also spends 1 runner click)
			#   choices:    Array[{ label: String, condition: Dict (opt), effects: Array }]
			# }
			var mscc_counter: String = params.get("counter", "power")
			var mscc_click: bool     = params.get("click_cost", false)
			var mscc_all: Array      = params.get("choices", []) as Array

			var mscc_self := _get_self_card(ctx)
			if mscc_self == null:
				return
			if mscc_self.get_counter(mscc_counter) < 1:
				return   # no counters
			if mscc_click and ctx.runner_clicks < 1:
				return   # no click to spend

			# Filter choices by inline conditions
			var mscc_available: Array = []
			for mscc_m in mscc_all:
				var mscc_mc: Dictionary = (mscc_m as Dictionary).get("condition", {}) as Dictionary
				if mscc_mc.is_empty() or _evaluate_condition(mscc_mc, ctx):
					mscc_available.append(mscc_m)

			if mscc_available.is_empty():
				return

			# Prompt runner
			var mscc_chosen_idx: int = -1
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var mscc_modes: Array = []
				for mscc_m in mscc_available:
					mscc_modes.append(mscc_m as Dictionary)
				mscc_modes.append({"label": "Decline"})
				var mscc_result: Array = await ctx.runner_decision_maker.choose_modes(mscc_modes, 1, ctx)
				if mscc_result.is_empty():
					return
				var mscc_sel = mscc_result[0]
				var mscc_sel_int: int = int(mscc_sel) if mscc_sel is int else 0
				if mscc_sel_int < mscc_available.size():
					mscc_chosen_idx = mscc_sel_int
			else:
				mscc_chosen_idx = 0   # AI default: first choice

			if mscc_chosen_idx < 0:
				return   # declined

			# Pay costs
			if mscc_click:
				ctx.runner_clicks = max(0, ctx.runner_clicks - 1)
				ctx.send_log("%s spends 1 click." % ctx.runner_name())
			mscc_self.remove_counter(mscc_counter, 1)
			ctx.send_log("%s spends 1 %s counter (%d remaining)." % [
				mscc_self.display_name(), mscc_counter, mscc_self.get_counter(mscc_counter)])

			# Execute chosen effects
			var mscc_chosen_mode: Dictionary = mscc_available[mscc_chosen_idx] as Dictionary
			ctx.send_log("%s: %s" % [mscc_self.display_name(), mscc_chosen_mode.get("label", "?")])
			for mscc_eff in mscc_chosen_mode.get("effects", []) as Array:
				await _execute_effect(mscc_eff as Dictionary, ctx, null)

		# ── Click + trash self for a runner choice (Friend of a Friend) ──────────

		"click_trash_for_runner_choice":
			# Runner spends 1 click and trashes this card, then gains a chosen effect.
			# params: {
			#   choices: Array[{ label: String, condition: Dict (opt), effects: Array }]
			# }
			var ctrc_all: Array = params.get("choices", []) as Array
			var ctrc_self := _get_self_card(ctx)
			if ctrc_self == null:
				return
			if ctx.runner_clicks < 1:
				return

			# Filter choices by inline conditions
			var ctrc_available: Array = []
			for ctrc_m in ctrc_all:
				var ctrc_cond: Dictionary = (ctrc_m as Dictionary).get("condition", {}) as Dictionary
				if ctrc_cond.is_empty() or _evaluate_condition(ctrc_cond, ctx):
					ctrc_available.append(ctrc_m)

			if ctrc_available.is_empty():
				return

			# Prompt runner
			var ctrc_chosen_idx: int = -1
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_modes"):
				var ctrc_modes: Array = []
				for ctrc_m in ctrc_available:
					ctrc_modes.append(ctrc_m as Dictionary)
				ctrc_modes.append({"label": "Pass"})
				var ctrc_result: Array = await ctx.runner_decision_maker.choose_modes(ctrc_modes, 1, ctx)
				if ctrc_result.is_empty():
					return
				var ctrc_sel = ctrc_result[0]
				var ctrc_sel_int: int = int(ctrc_sel) if ctrc_sel is int else 0
				if ctrc_sel_int < ctrc_available.size():
					ctrc_chosen_idx = ctrc_sel_int
			else:
				# AI default: pick the first available choice (best value)
				ctrc_chosen_idx = 0

			if ctrc_chosen_idx < 0:
				return   # passed

			# Pay click and trash self
			ctx.runner_clicks = max(0, ctx.runner_clicks - 1)
			ctx.send_log("%s spends 1 click." % ctx.runner_name())
			_trash_installed_card(ctrc_self, ctx)
			if ctrc_self.card_record != null:
				ctx.runner_discard.append(ctrc_self.card_record)
			ctx.send_log("%s is trashed." % ctrc_self.display_name())

			# Execute chosen effects
			var ctrc_chosen: Dictionary = ctrc_available[ctrc_chosen_idx] as Dictionary
			ctx.send_log("%s: %s" % [ctrc_self.display_name(), ctrc_chosen.get("label", "?")])
			for ctrc_eff in ctrc_chosen.get("effects", []) as Array:
				await _execute_effect(ctrc_eff as Dictionary, ctx, null)

		# ── Gain 1cr for each runner tag (Capacitor sub 1) ────────────────────────

		"gain_credits_per_runner_tag":
			# Corp gains 1cr for each tag the runner currently has.
			# params: { subject: "corp" | "runner" (default "corp"), per_tag: int (default 1) }
			var gcprt_subject: String = params.get("subject", "corp")
			var gcprt_per: int        = params.get("per_tag", 1)
			var gcprt_tags: int       = ctx.runner_tags
			if gcprt_tags <= 0:
				ctx.send_log("%s: Runner has no tags — no credits gained." % ctx.player_name(gcprt_subject))
				return
			var gcprt_amount: int = gcprt_tags * gcprt_per
			ctx.set_credits(gcprt_subject, ctx.get_credits(gcprt_subject) + gcprt_amount)
			ctx.send_log("%s gains %d credit(s) (%d tag(s) × %d). (%d total)" % [
				ctx.player_name(gcprt_subject), gcprt_amount,
				gcprt_tags, gcprt_per, ctx.get_credits(gcprt_subject)])

		# ── Trash 1 installed card of a given type with per-encounter cap ─────────

		"trash_runner_card_type":
			# Trash 1 installed runner card of the given type (resource/hardware/program).
			# Respects a per-encounter cap tracked in run_modifiers by a shared key.
			# params: { card_type: String, per_encounter_max: int (default 99),
			#           cap_key: String (default "self") }
			var trct_type: String    = params.get("card_type", "program")
			var trct_max: int        = params.get("per_encounter_max", 99)
			var trct_cap_key: String = params.get("cap_key", "self")

			# Resolve the cap counter key (use ice instance id when "self")
			var trct_self := _get_self_card(ctx)
			var trct_iid: String = trct_self.runtime_instance_id if trct_self != null else "unknown"
			if trct_cap_key == "self":
				trct_cap_key = "_trct_cap_" + trct_iid

			var trct_done: int = ctx.run_modifiers.get(trct_cap_key, 0) as int
			if trct_done >= trct_max:
				ctx.send_log("Sorocaban Blade: trash limit (%d) reached this encounter." % trct_max)
				return

			# Collect candidates
			var trct_pool: Array = []
			for trct_rc in ctx.runner_rig:
				var trct_ic: InstalledCard = trct_rc as InstalledCard
				if trct_ic == null:
					continue
				if trct_ic.card_record == null:
					continue
				match trct_type:
					"resource":
						if trct_ic.card_record.card_type == "resource":
							trct_pool.append(trct_ic)
					"hardware":
						if trct_ic.card_record.card_type == "hardware":
							trct_pool.append(trct_ic)
					"program":
						if trct_ic.card_record.card_type == "program":
							trct_pool.append(trct_ic)

			if trct_pool.is_empty():
				ctx.send_log("No installed %s to trash." % trct_type)
				return

			# Choose target
			var trct_target: InstalledCard = trct_pool[0]
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_trash_from_rig"):
				var trct_chosen = await ctx.corp_decision_maker.choose_trash_from_rig(trct_pool, ctx)
				if trct_chosen is InstalledCard:
					trct_target = trct_chosen as InstalledCard

			# Increment cap counter before trashing (in case trash triggers something)
			ctx.run_modifiers[trct_cap_key] = trct_done + 1

			_trash_installed_card(trct_target, ctx)
			if trct_target.card_record != null:
				ctx.runner_discard.append(trct_target.card_record)
			ctx.send_log("Trashed installed %s: %s" % [trct_type, trct_target.display_name()])

		# ── Pretty Mary da Silva: +1 R&D access if ≥2 already allowed ────────────

		"pretty_mary_rd_bonus_access":
			# Fires on before_breach. If breaching R&D and runner is already allowed
			# to access ≥2 cards, grant 1 additional access.
			var pm_server: String = ctx.current_event_data.get("server_id", "")
			if pm_server != "rd":
				return
			var pm_current_bonus: int = ctx.run_modifiers.get("bonus_access", 0) as int
			# Base R&D access is always 1 (top card); total = 1 + bonus_access
			if (1 + pm_current_bonus) < 2:
				return   # fewer than 2 allowed — Pretty Mary does not trigger
			ctx.run_modifiers["bonus_access"] = pm_current_bonus + 1
			ctx.send_log("Pretty Mary da Silva: +1 R&D access (already accessing ≥2 cards).")

		# ── Ashen Epilogue: shuffle grip+heap to stack, RFG top 5, draw 5 ─────────

		"shuffle_grip_and_heap_into_stack":
			# Move all grip cards and heap (runner_discard) into the runner's stack, then shuffle.
			var sgh_grip: Array = ctx.runner_hand.duplicate()
			for sgh_entry in sgh_grip:
				ctx.runner_hand.erase(sgh_entry)
				var sgh_cr: CardRecord = (sgh_entry as Dictionary).get("card_record", null) as CardRecord
				if sgh_cr != null:
					ctx.runner_deck.append(sgh_cr)
			var sgh_heap: Array = ctx.runner_discard.duplicate()
			for sgh_cr2 in sgh_heap:
				ctx.runner_discard.erase(sgh_cr2)
				ctx.runner_deck.append(sgh_cr2 as CardRecord)
			ctx.runner_deck.shuffle()
			ctx.send_log("%s shuffles grip and heap into stack (%d cards)." % [
				ctx.runner_name(), ctx.runner_deck.size()])

		"rfg_top_n_stack":
			# Remove the top N cards of the runner's stack from the game.
			var rfg_n: int = params.get("amount", 5)
			var rfg_removed: int = 0
			for _rfg_i in range(rfg_n):
				if ctx.runner_deck.is_empty():
					break
				var rfg_card: CardRecord = ctx.runner_deck.pop_front() as CardRecord
				if rfg_card != null:
					ctx.runner_rfg.append(rfg_card)
					rfg_removed += 1
			ctx.send_log("%s removes top %d card(s) of stack from the game." % [ctx.runner_name(), rfg_removed])

		# ── Charlotte Cacador: remove 1 advancement → gain 4cr + draw 1 ──────────

		"remove_self_advancement_for_effect":
			var rsae_self := _get_self_card(ctx)
			if rsae_self == null or rsae_self.get_counter("advancement") < 1:
				ctx.send_log("Charlotte Cacador: no advancement counters to remove.")
				return
			# Optional: let Corp choose whether to activate
			var rsae_want := true
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_optional_ability"):
				rsae_want = await ctx.corp_decision_maker.choose_optional_ability(
					"Charlotte Cacador: remove 1 advancement counter to gain 4[credit] and draw 1?", ctx)
			if not rsae_want:
				ctx.send_log("Charlotte Cacador: Corp declines.")
				return
			rsae_self.remove_counter("advancement", 1)
			ctx.corp_credits += 4
			ctx.send_log("Charlotte Cacador: removed 1 advancement. %s gains 4[credit] and draws 1." % ctx.corp_name())
			# Draw 1 card
			if not ctx.corp_deck.is_empty():
				var rsae_drawn: CardRecord = ctx.corp_deck.pop_front() as CardRecord
				if rsae_drawn != null:
					ctx.corp_hand.append({"card_id": rsae_drawn.id, "card_record": rsae_drawn})
					ctx.send_log("%s draws %s." % [ctx.corp_name(), rsae_drawn.title])

		# ── Warm Reception: derez self and 1 other rezzed card (if no ice on server) ─

		"derez_self_and_another":
			var dsa_self := _get_self_card(ctx)
			if dsa_self == null:
				return
			# Check condition: no ice protecting this card's server
			var dsa_server: Server = ctx.get_server(dsa_self.server_id)
			if dsa_server == null or dsa_server.ice_count() > 0:
				return   # ice is present — skip the derez clause
			# Collect all other rezzed corp cards (assets, upgrades, ice) to pick from
			var dsa_candidates: Array = []
			for dsa_srv in ctx.servers.values():
				var dsa_s: Server = dsa_srv as Server
				for dsa_root in dsa_s.root:
					var dsa_c: InstalledCard = dsa_root as InstalledCard
					if dsa_c.is_rezzed and dsa_c.runtime_instance_id != dsa_self.runtime_instance_id:
						dsa_candidates.append(dsa_c)
				for dsa_ice in dsa_s.ice:
					var dsa_ic: InstalledCard = dsa_ice as InstalledCard
					if dsa_ic.is_rezzed and dsa_ic.runtime_instance_id != dsa_self.runtime_instance_id:
						dsa_candidates.append(dsa_ic)
			# Derez self
			await _derez_card(dsa_self, ctx)
			ctx.send_log("Warm Reception: derezzes itself (no ice protecting its server).")
			# Derez another
			if dsa_candidates.is_empty():
				ctx.send_log("Warm Reception: no other rezzed card to derez.")
				return
			var dsa_target: InstalledCard = null
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_derez_target"):
				dsa_target = await ctx.corp_decision_maker.choose_derez_target(dsa_candidates, ctx)
			if dsa_target == null:
				dsa_target = dsa_candidates[0]
			await _derez_card(dsa_target, ctx)
			ctx.send_log("Warm Reception: also derezzes %s." % dsa_target.display_name())

		# ── Janaina JK Dumont Kindelan: take all hosted credits + optional HQ install ─

		"take_credits_from_card_and_install":
			var tcci_self := _get_self_card(ctx)
			if tcci_self == null:
				return
			# Take all hosted credits
			var tcci_credits: int = tcci_self.get_counter("credits")
			if tcci_credits > 0:
				tcci_self.remove_counter("credits", tcci_credits)
				ctx.corp_credits += tcci_credits
				ctx.send_log("Janaina: %s takes %d[credit] from %s." % [
					ctx.corp_name(), tcci_credits, tcci_self.display_name()])
			else:
				ctx.send_log("Janaina: no hosted credits to take.")
			# Optionally install 1 card from HQ
			if ctx.corp_hand.is_empty():
				return
			var tcci_want := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_optional_ability"):
				tcci_want = await ctx.corp_decision_maker.choose_optional_ability(
					"Janaina: install 1 card from HQ (ignoring all costs)?", ctx)
			if not tcci_want:
				return
			var tcci_dm: Object = ctx.corp_decision_maker
			var tcci_chosen: Variant = null
			if tcci_dm != null and tcci_dm.has_method("choose_card_from_hand"):
				tcci_chosen = await tcci_dm.choose_card_from_hand(ctx.corp_hand, ctx)
			if tcci_chosen == null:
				tcci_chosen = ctx.corp_hand[0]
			var tcci_record: CardRecord = (tcci_chosen as Dictionary).get("card_record", null) as CardRecord
			if tcci_record == null:
				return
			ctx.corp_hand.erase(tcci_chosen)
			var tcci_server: Server = ctx.create_remote_server()
			var tcci_zone: String = "ice" if tcci_record.is_ice() else "root"
			var tcci_inst := _install_corp_card(tcci_record, tcci_server, tcci_zone, false)
			ctx.corp_installed_this_turn.append(tcci_record.id)
			ctx.send_log("Janaina: %s installs %s from HQ in %s (ignoring costs)." % [
				ctx.corp_name(), tcci_record.title, tcci_server.display_name()])
			# Fire on_rez (unrented, face-down — same pattern as Synapse Global)
			var tcci_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry \
				if ctx.has_meta("ability_registry") else null
			var tcci_on_rez: Variant = tcci_ab_reg.get_on_rez(tcci_record.id) if tcci_ab_reg != null else null
			if tcci_on_rez != null:
				ctx.current_event_data = {"card": tcci_inst, "card_instance_id": tcci_inst.runtime_instance_id}
				await execute_trigger(tcci_on_rez as Dictionary, ctx)
				ctx.current_event_data = {}

		# ── Hearts and Minds: move advancement + optional extra placement ─────────

		"move_advancement_to_installed":
			# Build pool of advanceable installed cards with at least 1 advancement counter (sources)
			var mai_sources: Array = []
			var mai_all: Array = []
			for mai_srv in ctx.servers.values():
				var mai_s: Server = mai_srv as Server
				for mai_c in mai_s.root:
					var mai_ic: InstalledCard = mai_c as InstalledCard
					if mai_ic == null:
						continue
					mai_all.append(mai_ic)
					if mai_ic.can_be_advanced() and mai_ic.get_counter("advancement") >= 1:
						mai_sources.append(mai_ic)
				for mai_ice in mai_s.ice:
					var mai_ii: InstalledCard = mai_ice as InstalledCard
					if mai_ii == null:
						continue
					mai_all.append(mai_ii)
					if mai_ii.can_be_advanced() and mai_ii.get_counter("advancement") >= 1:
						mai_sources.append(mai_ii)
			if mai_sources.is_empty() or mai_all.is_empty():
				ctx.send_log("Hearts and Minds: no valid source or destination.")
				return
			# Ask Corp to choose source
			var mai_dm: Object = ctx.corp_decision_maker
			var mai_source: InstalledCard = null
			if mai_dm != null and mai_dm.has_method("choose_target"):
				mai_source = await mai_dm.choose_target(mai_sources, {"reason": "hearts_and_minds_source"}) as InstalledCard
			if mai_source == null:
				mai_source = mai_sources[0]
			# Build destinations (any advanceable installed card, including source if it has ≥1)
			var mai_dests: Array = mai_all.filter(func(c): return c.can_be_advanced())
			if mai_dests.is_empty():
				ctx.send_log("Hearts and Minds: no advanceable destination.")
				return
			var mai_dest: InstalledCard = null
			if mai_dm != null and mai_dm.has_method("choose_target"):
				mai_dest = await mai_dm.choose_target(mai_dests, {"reason": "hearts_and_minds_dest"}) as InstalledCard
			if mai_dest == null:
				mai_dest = mai_dests[0]
			# Move 1 counter
			mai_source.remove_counter("advancement", 1)
			mai_dest.add_counter("advancement", 1)
			ctx.send_log("Hearts and Minds: moved 1 advancement from %s to %s." % [
				mai_source.display_name(), mai_dest.display_name()])
			# Conditional: if no ice is protecting the destination server, also place 1 new counter
			var mai_dest_server: Server = ctx.get_server(mai_dest.server_id)
			if mai_dest_server != null and mai_dest_server.ice_count() == 0:
				mai_dest.add_counter("advancement", 1)
				ctx.send_log("Hearts and Minds: no ice on %s's server — placed 1 additional advancement on %s." % [
					mai_dest.display_name(), mai_dest.display_name()])

		# ── Working Prototype: remove N counters from self ────────────────────────

		"remove_self_counter":
			var rsc_self := _get_self_card(ctx)
			if rsc_self == null:
				return
			var rsc_counter: String = effect.get("counter", params.get("counter", "power"))
			var rsc_amount: int     = int(effect.get("amount", params.get("amount", 1)))
			rsc_self.remove_counter(rsc_counter, rsc_amount)
			ctx.send_log("Removed %d %s counter(s) from %s (%d remaining)." % [
				rsc_amount, rsc_counter, rsc_self.display_name(), rsc_self.get_counter(rsc_counter)])

		# ── Working Prototype: move 1 resource from heap to top of stack ─────────

		"move_resource_from_heap_to_stack_top":
			var mrh_candidates: Array = []
			for mrh_r in ctx.runner_discard:
				var mrh_cr: CardRecord = mrh_r as CardRecord
				if mrh_cr != null and mrh_cr.card_type == "resource":
					mrh_candidates.append(mrh_cr)
			if mrh_candidates.is_empty():
				ctx.send_log("Working Prototype: no resources in heap.")
				return
			var mrh_chosen: CardRecord = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_heap"):
				mrh_chosen = await ctx.runner_decision_maker.choose_from_heap(mrh_candidates, ctx)
			if mrh_chosen == null:
				mrh_chosen = mrh_candidates[0]
			ctx.runner_discard.erase(mrh_chosen)
			ctx.runner_deck.push_front(mrh_chosen)
			ctx.send_log("Working Prototype: %s moves %s from heap to top of stack." % [
				ctx.runner_name(), mrh_chosen.title])

		# ── Meeting of Minds: search stack for connection/virtual, gain 1cr per grip match ─

		"search_and_gain_per_grip_match":
			var sgm_candidates: Array = []
			for sgm_r in ctx.runner_deck:
				var sgm_cr: CardRecord = sgm_r as CardRecord
				if sgm_cr != null and (sgm_cr.has_subtype("connection") or sgm_cr.has_subtype("virtual")):
					sgm_candidates.append(sgm_cr)
			if sgm_candidates.is_empty():
				ctx.send_log("Meeting of Minds: no connection or virtual cards in stack.")
				ctx.runner_deck.shuffle()
				return
			var sgm_chosen: CardRecord = null
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_search"):
				sgm_chosen = await ctx.runner_decision_maker.choose_from_search(sgm_candidates, ctx)
			if sgm_chosen == null:
				sgm_chosen = sgm_candidates[0]
			ctx.runner_deck.erase(sgm_chosen)
			ctx.send_log("Meeting of Minds: %s reveals %s from stack." % [ctx.runner_name(), sgm_chosen.title])
			# Count grip cards that share at least one subtype with the found card
			var sgm_matches: int = 0
			for sgm_he in ctx.runner_hand:
				var sgm_hd: Dictionary = sgm_he as Dictionary
				var sgm_hcr: CardRecord = sgm_hd.get("card_record", null) as CardRecord
				if sgm_hcr == null:
					continue
				for sgm_st in sgm_chosen.subtypes:
					if sgm_hcr.has_subtype(sgm_st as String):
						sgm_matches += 1
						break
			if sgm_matches > 0:
				ctx.runner_credits += sgm_matches
				ctx.send_log("Meeting of Minds: %d matching card(s) in grip — %s gains %d[credit]." % [
					sgm_matches, ctx.runner_name(), sgm_matches])
			else:
				ctx.send_log("Meeting of Minds: no matching subtypes in grip — no credits gained.")
			# Add found card to hand
			ctx.runner_hand.append({"card_id": sgm_chosen.id, "card_record": sgm_chosen})
			# Shuffle stack
			ctx.runner_deck.shuffle()
			ctx.send_log("%s's stack is shuffled." % ctx.runner_name())

		# ── Pressure Spike: once-per-run +9 str boost (Threat 4 paid ability) ──────
		"pressure_spike_str_boost":
			# Grants +9 strength to Pressure Spike for the remainder of this run.
			# Stored in run_level_strength_boosts so it carries between encounters.
			# Enforced once per run via run_modifiers flag.
			if ctx.run_modifiers.get("pressure_spike_str_used", false):
				ctx.send_log("Pressure Spike: +9 str already used this run.")
				return
			ctx.run_modifiers["pressure_spike_str_used"] = true
			# Find Pressure Spike in rig and apply run-level boost
			for _pss_rig in ctx.runner_rig:
				var _pss_ic: InstalledCard = _pss_rig as InstalledCard
				if _pss_ic != null and _pss_ic.card_id == "pressure_spike":
					var _pss_prev: int = ctx.run_level_strength_boosts.get(_pss_ic.runtime_instance_id, 0)
					ctx.run_level_strength_boosts[_pss_ic.runtime_instance_id] = _pss_prev + 9
					ctx.send_log("Pressure Spike: +9 str for the remainder of this run.")
					break

		# ── Isaac Liberdade: click to move to another installed ice (runner turn end) ──
		"isaac_move_to_ice":
			# Runner may spend 1 click to move Isaac Liberdade to a different installed ice.
			var iml_self := _get_self_card(ctx)
			if iml_self == null:
				return
			# Collect candidate ice (excluding current host)
			var iml_candidates: Array = []
			for iml_srv in ctx.servers.values():
				for iml_ice in (iml_srv as Server).ice:
					var iml_ic: InstalledCard = iml_ice as InstalledCard
					if iml_ic != null and iml_ic.runtime_instance_id != iml_self.hosted_on_id:
						iml_candidates.append(iml_ic)
			if iml_candidates.is_empty():
				ctx.send_log("Isaac Liberdade: no other installed ice to move to.")
				return
			# Ask runner
			var iml_dm: Object = ctx.runner_decision_maker
			var iml_activate := false
			if iml_dm != null and iml_dm.has_method("choose_modes"):
				var iml_modes: Array = [
					{"label": "[Click]: Move Isaac Liberdade to another installed ice"},
					{"label": "Do not move"}
				]
				var iml_chosen: Array = await iml_dm.choose_modes(iml_modes, 1, ctx)
				iml_activate = not iml_chosen.is_empty() and int(iml_chosen[0]) == 0
			else:
				iml_activate = false  # AI default: don't move
			if not iml_activate:
				return
			if ctx.runner_clicks < 1:
				ctx.send_log("Isaac Liberdade: no clicks remaining.")
				return
			ctx.runner_clicks -= 1
			# Choose target ice
			var iml_target: InstalledCard = null
			if iml_dm != null and iml_dm.has_method("choose_target_ice"):
				iml_target = await iml_dm.choose_target_ice(iml_candidates, "Isaac Liberdade", ctx)
			else:
				iml_target = iml_candidates[0] if not iml_candidates.is_empty() else null
			if iml_target == null:
				ctx.runner_clicks += 1  # refund
				return
			# Remove from current host
			var iml_old_host: InstalledCard = ctx.get_ice_by_instance_id(iml_self.hosted_on_id)
			if iml_old_host != null:
				iml_old_host.hosted_cards.erase(iml_self)
			# Attach to new host
			iml_self.hosted_on_id = iml_target.runtime_instance_id
			iml_target.hosted_cards.append(iml_self)
			ctx.send_log("Isaac Liberdade: moved to %s." % iml_target.display_name())

		# ── Amanuensis: spend power counter per tag removed → draw 2 cards each ──
		"amanuensis_spend_counter_draw_on_untag":
			# Fires on tag_removed event.  Spend 1 power counter per removed tag
			# (up to available counters) to draw 2 cards each.
			var ama_self := _get_self_card(ctx)
			if ama_self == null:
				return
			if not ama_self.is_rezzed:
				return  # Console must be installed (runner installs hardware, so is_rezzed is true by default)
			var ama_tags_removed: int = int(ctx.current_event_data.get("amount", 1))
			var ama_available: int    = ama_self.get_counter("power")
			if ama_available <= 0:
				return
			var ama_spend: int = mini(ama_tags_removed, ama_available)
			ama_self.remove_counter("power", ama_spend)
			var ama_draw: int = ama_spend * 2
			for _ama_i in range(ama_draw):
				if ctx.runner_deck.is_empty():
					break
				var ama_top: Dictionary = ctx.runner_deck.pop_front() as Dictionary
				ctx.runner_hand.append(ama_top)
			ctx.send_log("Amanuensis: spent %d power counter(s) — %s draws %d card(s)." % [
				ama_spend, ctx.runner_name(), mini(ama_draw, ama_draw)])

		# ── AI Set: on-pass ice and trojan effects ──────────────────────────────

		"corp_swap_self_ice_with_hq_gain_credits":
			# Tatu-Bola on_runner_passes: Corp may swap this ice with any ice in HQ.
			# If they do, this ice goes to HQ unrezzed and the chosen ice installs in its place.
			# Corp gains 'credits' cr for the swap.
			# params: { credits: int }  (default 4)
			var tsw_credits: int = params.get("credits", 4)
			var tsw_self := _get_self_card(ctx)
			if tsw_self == null:
				return

			# Find ice cards in HQ.
			var tsw_hq_ice: Array = []
			for tsw_hq_entry in ctx.corp_hand:
				var tsw_e: Dictionary = tsw_hq_entry as Dictionary
				var tsw_cr: CardRecord = tsw_e.get("card_record", null) as CardRecord
				if tsw_cr != null and tsw_cr.card_type == "ice":
					tsw_hq_ice.append(tsw_hq_entry)
			if tsw_hq_ice.is_empty():
				ctx.send_log("Tatu-Bola: no ice in HQ — swap not available.")
				return

			# Corp decides whether to swap.
			var tsw_do_swap := false
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_optional_ability"):
				tsw_do_swap = await ctx.corp_decision_maker.choose_optional_ability(
					"Tatu-Bola: swap with ice from HQ (gain %d cr)?" % tsw_credits, ctx)
			else:
				tsw_do_swap = true   # AI default: always swap
			if not tsw_do_swap:
				return

			# Corp picks which ice from HQ (use choose_card_from_hand if available).
			var tsw_chosen_entry: Dictionary = tsw_hq_ice[0] as Dictionary
			if ctx.corp_decision_maker != null and \
					ctx.corp_decision_maker.has_method("choose_card_from_hand"):
				var tsw_raw: Variant = await ctx.corp_decision_maker.choose_card_from_hand(
					tsw_hq_ice, ctx)
				if tsw_raw is Dictionary:
					tsw_chosen_entry = tsw_raw as Dictionary
			var tsw_chosen_cr: CardRecord = tsw_chosen_entry.get("card_record", null) as CardRecord
			if tsw_chosen_cr == null:
				return

			# Locate Tatu-Bola in its server's ice array.
			var tsw_server: Server = ctx.get_server(tsw_self.server_id)
			if tsw_server == null:
				return
			var tsw_pos: int = -1
			for tsw_i in range(tsw_server.ice.size()):
				var tsw_ic: InstalledCard = tsw_server.ice[tsw_i] as InstalledCard
				if tsw_ic != null and tsw_ic.runtime_instance_id == tsw_self.runtime_instance_id:
					tsw_pos = tsw_i
					break
			if tsw_pos < 0:
				push_error("AbilityInterpreter: Tatu-Bola not found in server ice array")
				return

			# Perform the swap.
			# 1. Remove chosen ice from HQ.
			ctx.corp_hand.erase(tsw_chosen_entry)
			# 2. Install chosen ice unrezzed in Tatu-Bola's position.
			var tsw_new_ice := InstalledCard.make_runtime_instance(
				tsw_chosen_cr, tsw_self.server_id, "ice", false)
			tsw_server.ice[tsw_pos] = tsw_new_ice
			# 3. Return Tatu-Bola to HQ as a card entry (unrezzed, back to hand).
			ctx.corp_hand.append({"card_id": tsw_self.card_id, "card_record": tsw_self.card_record})
			# 4. Unregister Tatu-Bola's event listeners.
			ctx.unregister_all_card_effects(tsw_self.runtime_instance_id)
			# 5. Signal RSM to update its _ice_positions snapshot for this position.
			# Needed so any re-encounter (Sisyphus Protocol etc.) uses the new ice, not
			# the now-departed Tatu-Bola InstalledCard.
			ctx.set_meta("pass_swap_ice", tsw_new_ice)
			# 6. Corp gains credits.
			ctx.corp_credits += tsw_credits
			ctx.send_log("Tatu-Bola: swapped out for %s (installed unrezzed) — %s gains %d cr." % [
				tsw_chosen_cr.title, ctx.corp_name(), tsw_credits
			])

		"pichacao_pass_host":
			# Pichação on_runner_passes_host: runner may gain [click].
			# If this is NOT the first click gained during a run this turn, add self to grip.
			var pich_self := _get_self_card(ctx)
			if pich_self == null:
				return

			# Runner may optionally gain the click.
			var pich_gain := false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("choose_optional_ability"):
				pich_gain = await ctx.runner_decision_maker.choose_optional_ability(
					"Pichação: gain [click]?", ctx)
			else:
				pich_gain = true   # AI / sim default: always gain the click
			if not pich_gain:
				return

			# Check BEFORE incrementing whether this is the 2nd+ click gained this run.
			var pich_returning: bool = ctx.run_clicks_gained_this_run >= 1

			ctx.runner_clicks += 1
			ctx.run_clicks_gained_this_run += 1
			ctx.send_log("Pichação: %s gains 1 click." % ctx.runner_name())

			if pich_returning:
				# Return Pichação to grip (remove from host ice and rig).
				var pich_host := ctx.get_ice_by_instance_id(pich_self.hosted_on_id)
				if pich_host != null:
					pich_host.hosted_cards.erase(pich_self)
				ctx.runner_rig.erase(pich_self)
				if pich_self.card_record != null:
					ctx.runner_hand.append({
						"card_id":     pich_self.card_id,
						"card_record": pich_self.card_record
					})
				ctx.unregister_all_card_effects(pich_self.runtime_instance_id)
				ctx.send_log("Pichação: returned to grip (2nd click gained this run).")

		# ── RWR Step 4: Complex Multi-State and Interrupt Cards ──────────────────

		"increment_run_modifier":
			# Add a fixed amount to a run_modifiers key (creating it if absent).
			# Used by: Manuel Lattes de Moura (before_breach bonus access +1).
			var irm_key: String = params.get("key", "")
			var irm_amount: int = params.get("amount", 1)
			if irm_key != "":
				ctx.run_modifiers[irm_key] = ctx.run_modifiers.get(irm_key, 0) + irm_amount

		"eye_for_an_eye_run":
			# Eye for an Eye (on_play):
			# Condition: runner is untagged. Run HQ. On success: take 1 tag + 1 bonus access.
			# efa_active flag makes _access_card offer the runner a grip-trash-to-trash interrupt.
			if ctx.runner_tags > 0:
				ctx.send_log("Eye for an Eye: cannot play while tagged.")
				return
			ctx.run_modifiers["efa_active"] = true
			# +1 bonus access on HQ this run
			ctx.run_modifiers["bonus_access"] = ctx.run_modifiers.get("bonus_access", 0) + 1
			# Register one-shot successful_run hook: take 1 tag
			var efa_lid := "efa_listener_%s" % str(randi())
			ctx.register_listener("successful_run", efa_lid, {
				"effects": [{"type": "efa_on_success"}]
			})
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var efa_cb: Callable = ctx.get_meta("on_run_started") as Callable
				efa_cb.call("hq")
				await Engine.get_main_loop().process_frame
			var efa_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if efa_rsm == null:
				push_error("AbilityInterpreter: eye_for_an_eye_run — no run_state_machine")
				ctx.run_modifiers.erase("efa_active")
				ctx.unregister_all_card_effects(efa_lid)
				return
			await efa_rsm.execute("hq")
			ctx.unregister_all_card_effects(efa_lid)
			ctx.run_modifiers.erase("efa_active")

		"efa_on_success":
			# Internal: Eye for an Eye successful run hook — take 1 tag.
			var _efa_was_zero: bool = (ctx.runner_tags == 0)
			ctx.runner_tags += 1
			ctx.send_log("Eye for an Eye: %s takes 1 tag (%d total)." % [ctx.runner_name(), ctx.runner_tags])
			await ctx.notify_event("runner_takes_tags", {"amount": 1, "from_zero": _efa_was_zero}, self)

		"privileged_access_run":
			# Privileged Access (on_play):
			# Condition: runner is untagged. Set privileged_access_active flag, run Archives.
			# _phase_success checks the flag and asks the runner to choose normal breach
			# or the alternative (take 1 tag + install from heap for 2cr less).
			if ctx.runner_tags > 0:
				ctx.send_log("Privileged Access: cannot play while tagged.")
				return
			ctx.run_modifiers["privileged_access_active"] = true
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var pa_cb: Callable = ctx.get_meta("on_run_started") as Callable
				pa_cb.call("archives")
				await Engine.get_main_loop().process_frame
			var pa_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if pa_rsm == null:
				push_error("AbilityInterpreter: privileged_access_run — no run_state_machine")
				ctx.run_modifiers.erase("privileged_access_active")
				return
			await pa_rsm.execute("archives")

		"privileged_access_install":
			# Privileged Access alternative breach (called from RunStateMachine._phase_success):
			# Take 1 tag + install 1 card from heap for 2cr less.
			# Threat 3: may also install 1 program from heap.
			var pa_threat3: bool = params.get("threat3", false)
			var _pai_was_zero: bool = (ctx.runner_tags == 0)
			ctx.runner_tags += 1
			ctx.send_log("Privileged Access: %s takes 1 tag (%d total)." % [ctx.runner_name(), ctx.runner_tags])
			await ctx.notify_event("runner_takes_tags", {"amount": 1, "from_zero": _pai_was_zero}, self)
			if ctx.game_over:
				return
			# Build list of installable cards from heap
			var pa_heap: Array = ctx.runner_discard.duplicate()
			if pa_heap.is_empty():
				ctx.send_log("Privileged Access: heap is empty — no card to install.")
				return
			# Choose a card from heap
			var pa_pick: CardRecord = pa_heap[0] as CardRecord
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_heap"):
				pa_pick = await ctx.runner_decision_maker.choose_from_heap(pa_heap, ctx)
			if pa_pick == null:
				return
			# Install cost (base cost - 2, min 0)
			var pa_discount: int = 2
			var pa_base_cost: int = max(0, pa_pick.cost)
			var pa_install_cost: int = max(0, pa_base_cost - pa_discount)
			if ctx.runner_credits < pa_install_cost:
				ctx.send_log("Privileged Access: cannot afford to install %s (%dcr needed)." % [
					pa_pick.title, pa_install_cost])
				return
			ctx.runner_credits -= pa_install_cost
			ctx.runner_discard.erase(pa_pick)
			var pa_ic := InstalledCard.new()
			pa_ic.card_id       = pa_pick.id
			pa_ic.card_record   = pa_pick
			pa_ic.is_rezzed     = true
			pa_ic.runtime_instance_id = "pa_ic_%s" % str(randi())
			ctx.runner_rig.append(pa_ic)
			ctx.send_log("Privileged Access: installs %s from heap for %dcr." % [pa_pick.title, pa_install_cost])
			# Fire on_rez
			var pa_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry \
				if ctx.has_meta("ability_registry") else null
			if pa_ab_reg != null:
				var pa_on_rez = pa_ab_reg.get_on_rez(pa_pick.id)
				if pa_on_rez != null:
					ctx.current_event_data = {"card": pa_ic, "card_instance_id": pa_ic.runtime_instance_id}
					await execute_trigger(pa_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			# Threat 3: optionally install a program too
			if pa_threat3:
				var pa_programs: Array = []
				for pa_hcr in ctx.runner_discard:
					var pa_pcr: CardRecord = pa_hcr as CardRecord
					if pa_pcr != null and pa_pcr.card_type == "program":
						pa_programs.append(pa_pcr)
				if not pa_programs.is_empty():
					var pa_do_program := false
					if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
						pa_do_program = await ctx.runner_decision_maker.choose_optional_ability(
							"Privileged Access (Threat 3): install a program from heap for 2cr less?", ctx)
					else:
						pa_do_program = true
					if pa_do_program:
						var pa_prog: CardRecord = pa_programs[0] as CardRecord
						if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_from_heap"):
							pa_prog = await ctx.runner_decision_maker.choose_from_heap(pa_programs, ctx)
						if pa_prog != null:
							var pa_prog_cost: int = max(0, pa_prog.cost - pa_discount)
							if ctx.runner_credits >= pa_prog_cost:
								ctx.runner_credits -= pa_prog_cost
								ctx.runner_discard.erase(pa_prog)
								var pa_prog_ic := InstalledCard.new()
								pa_prog_ic.card_id       = pa_prog.id
								pa_prog_ic.card_record   = pa_prog
								pa_prog_ic.is_rezzed     = true
								pa_prog_ic.runtime_instance_id = "pa_prog_%s" % str(randi())
								ctx.runner_rig.append(pa_prog_ic)
								ctx.send_log("Privileged Access (Threat 3): installs %s for %dcr." % [pa_prog.title, pa_prog_cost])
								if pa_ab_reg != null:
									var pa_prog_rez = pa_ab_reg.get_on_rez(pa_prog.id)
									if pa_prog_rez != null:
										ctx.current_event_data = {"card": pa_prog_ic, "card_instance_id": pa_prog_ic.runtime_instance_id}
										await execute_trigger(pa_prog_rez as Dictionary, ctx)
										ctx.current_event_data = {}
							else:
								ctx.send_log("Privileged Access: cannot afford %s (%dcr needed)." % [pa_prog.title, pa_prog_cost])

		"manuel_trash_interrupt":
			# Manuel Lattes de Moura trash_interrupt (Threat 3):
			# Corp must trash 1 card from HQ before trashing Manuel. If Corp cannot/declines, trash is cancelled.
			# Sets run_modifiers["trash_cancelled"] if Corp does not pay the additional cost.
			var mlt_hq: Array = ctx.corp_hand.duplicate()
			if mlt_hq.is_empty():
				ctx.send_log("Manuel Lattes de Moura: HQ is empty — Corp cannot pay the interrupt cost.")
				ctx.run_modifiers["trash_cancelled"] = true
				return
			# Ask Corp decision maker to confirm paying the cost
			var mlt_do_pay := false
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_optional_ability"):
				mlt_do_pay = await ctx.corp_decision_maker.choose_optional_ability(
					"Manuel Lattes de Moura: trash 1 card from HQ to proceed with the trash?", ctx)
			else:
				mlt_do_pay = true  # AI default: always pay
			if not mlt_do_pay:
				ctx.send_log("Manuel Lattes de Moura: Corp declines — trash is cancelled.")
				ctx.run_modifiers["trash_cancelled"] = true
				return
			# Corp picks a card from HQ to trash
			var mlt_pick: Dictionary = mlt_hq[0] as Dictionary
			if ctx.corp_decision_maker != null and ctx.corp_decision_maker.has_method("choose_card_from_hand"):
				var mlt_picked = await ctx.corp_decision_maker.choose_card_from_hand(mlt_hq, ctx)
				if mlt_picked != null:
					mlt_pick = mlt_picked as Dictionary
			ctx.corp_hand.erase(mlt_pick)
			var mlt_cr: CardRecord = mlt_pick.get("card_record", null) as CardRecord
			ctx.corp_discard.append(mlt_cr if mlt_cr != null else mlt_pick)
			ctx.send_log("Manuel Lattes de Moura: Corp trashes %s from HQ." % (mlt_cr.title if mlt_cr != null else "a card"))

		"amelia_earhart_activate":
			# Amelia Earhart (runner_turn_start paid ability):
			# If amelia_hq_rd_access_count >= 3: spend 3 clicks + trash self → Corp loses 10cr.
			var ama_self := _get_self_card(ctx)
			if ama_self == null:
				return
			if ctx.amelia_hq_rd_access_count < 3:
				return
			if ctx.runner_clicks < 3:
				ctx.send_log("Amelia Earhart: not enough clicks (need 3).")
				return
			var ama_do_activate := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
				ama_do_activate = await ctx.runner_decision_maker.choose_optional_ability(
					"Amelia Earhart: spend 3 [click] + trash self → Corp loses 10cr (%d accesses tracked)?" \
					% ctx.amelia_hq_rd_access_count, ctx)
			else:
				ama_do_activate = true  # AI default: always activate
			if not ama_do_activate:
				return
			ctx.runner_clicks -= 3
			# Trash Amelia
			ctx.runner_rig.erase(ama_self)
			ctx.unregister_all_card_effects(ama_self.runtime_instance_id)
			if ama_self.card_record != null:
				ctx.runner_discard.append(ama_self.card_record)
			ctx.send_log("Amelia Earhart: trashed. Corp loses 10cr.")
			ctx.amelia_hq_rd_access_count = 0
			# Corp loses 10cr (floored at 0)
			var ama_loss: int = min(10, ctx.corp_credits)
			ctx.corp_credits -= ama_loss
			ctx.send_log("Amelia Earhart: Corp loses %dcr (was %d)." % [ama_loss, ctx.corp_credits + ama_loss])

		# ── RWR Step 3: Runner Run Events and Rig-State Trackers ─────────────────

		"alarm_clock_optional_hq_run":
			# Alarm Clock (runner_turn_start trigger):
			# Ask runner if they want to make a run on HQ. If yes, set alarm_clock_active
			# flag so the approach-ice phase offers a 2-click bypass on the outermost ice.
			var ac_do_run := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
				ac_do_run = await ctx.runner_decision_maker.choose_optional_ability(
					"Alarm Clock: make a run on HQ this turn (may spend 2 [click] to bypass first ice)?", ctx)
			else:
				ac_do_run = (ctx.runner_clicks >= 1)
			if not ac_do_run:
				return
			ctx.run_modifiers["alarm_clock_active"] = true
			ctx.send_log("Alarm Clock: %s runs HQ." % ctx.runner_name())
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var ac_cb: Callable = ctx.get_meta("on_run_started") as Callable
				ac_cb.call("hq")
				await Engine.get_main_loop().process_frame
			var ac_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if ac_rsm == null:
				push_error("AbilityInterpreter: alarm_clock_optional_hq_run — no run_state_machine")
				return
			await ac_rsm.execute("hq")

		"cataloguer_reorder_top_rd":
			# Cataloguer (successful_run on R&D trigger):
			# Spend 1 power counter → look at top 4 cards of R&D → runner reorders them.
			var cat_self := _get_self_card(ctx)
			if cat_self == null:
				return
			if cat_self.get_counter("power") <= 0:
				return
			var cat_count: int = mini(4, ctx.corp_deck.size())
			if cat_count == 0:
				ctx.send_log("Cataloguer: R&D is empty.")
				return
			cat_self.remove_counter("power", 1)
			# Take the top N cards
			var cat_top: Array = []
			for _ci in range(cat_count):
				cat_top.append(ctx.corp_deck.pop_front())
			# Ask runner to reorder
			var cat_records: Array = []
			for cat_e in cat_top:
				cat_records.append((cat_e as Dictionary).get("card_record", null))
			var cat_ordered_records: Array = cat_records.duplicate()
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_order"):
				cat_ordered_records = await ctx.runner_decision_maker.choose_card_order(cat_records, ctx)
			# Rebuild ordered entries and push back to top of R&D
			var cat_used: Array = []
			var cat_result: Array = []
			for cat_cr in cat_ordered_records:
				for cat_e2 in cat_top:
					var cat_edict: Dictionary = cat_e2 as Dictionary
					if not cat_used.has(cat_e2) and cat_edict.get("card_record", null) == cat_cr:
						cat_result.append(cat_e2)
						cat_used.append(cat_e2)
						break
			# Append any remaining (safety — shouldn't happen)
			for cat_e3 in cat_top:
				if not cat_used.has(cat_e3):
					cat_result.append(cat_e3)
			# Insert back at front of deck (reversed so index 0 ends up on top)
			for cat_i in range(cat_result.size() - 1, -1, -1):
				ctx.corp_deck.push_front(cat_result[cat_i])
			ctx.send_log("Cataloguer: %s reordered the top %d cards of R&D." % [ctx.runner_name(), cat_count])

		"cataloguer_breach_rd":
			# Cataloguer (click ability):
			# Spend 1 power counter → set skip_ice_to_breach flag → run R&D.
			var catb_self := _get_self_card(ctx)
			if catb_self == null:
				return
			if catb_self.get_counter("power") <= 0:
				ctx.send_log("Cataloguer: no power counters remaining.")
				return
			catb_self.remove_counter("power", 1)
			ctx.run_modifiers["skip_ice_to_breach"] = true
			ctx.send_log("Cataloguer: %s skips ice and breaches R&D." % ctx.runner_name())
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var catb_cb: Callable = ctx.get_meta("on_run_started") as Callable
				catb_cb.call("rd")
				await Engine.get_main_loop().process_frame
			var catb_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if catb_rsm == null:
				push_error("AbilityInterpreter: cataloguer_breach_rd — no run_state_machine")
				ctx.run_modifiers.erase("skip_ice_to_breach")
				return
			await catb_rsm.execute("rd")

		"jml_gain_click":
			# Juli Moreira Lee (runner_rig_action trigger):
			# First time each turn a rig card is used: spend 1 power counter → gain 1 click.
			var jml_self := _get_self_card(ctx)
			if jml_self == null:
				return
			var jml_iid: String = jml_self.runtime_instance_id
			if ctx.once_per_turn_triggered.has(jml_iid):
				return
			if jml_self.get_counter("power") <= 0:
				ctx.send_log("Juli Moreira Lee: no power counters remaining.")
				return
			jml_self.remove_counter("power", 1)
			ctx.runner_clicks += 1
			ctx.once_per_turn_triggered[jml_iid] = true
			ctx.send_log("Juli Moreira Lee: %s gains [click]." % ctx.runner_name())

		"trick_shot_run":
			# Trick Shot (on_play):
			# Gain 4 run credits, run R&D, if successful gain 2cr + 1 bonus access.
			# After run resolves, may immediately run a remote.
			ctx.runner_credits += 4
			ctx.send_log("Trick Shot: %s gains 4 [credits] (run credits)." % ctx.runner_name())
			# Set bonus access flag before the run (+1 access on R&D)
			ctx.run_modifiers["bonus_access"] = ctx.run_modifiers.get("bonus_access", 0) + 1
			# Register one-shot successful_run hook: gain 2cr
			ctx.set_meta("trick_shot_pending", true)
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var ts_cb: Callable = ctx.get_meta("on_run_started") as Callable
				ts_cb.call("rd")
				await Engine.get_main_loop().process_frame
			var ts_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if ts_rsm == null:
				push_error("AbilityInterpreter: trick_shot_run — no run_state_machine")
				ctx.run_modifiers["bonus_access"] = maxi(0, ctx.run_modifiers.get("bonus_access", 1) - 1)
				ctx.remove_meta("trick_shot_pending")
				return
			# Hook: listen for successful_run on rd
			var ts_listener_id := "trick_shot_listener_%s" % str(randi())
			ctx.register_listener("successful_run", ts_listener_id, {
				"effects": [{"type": "trick_shot_on_success"}]
			})
			await ts_rsm.execute("rd")
			ctx.unregister_all_card_effects(ts_listener_id)
			ctx.remove_meta_if_exists("trick_shot_pending")
			# Optional remote run
			var ts_remotes: Array = []
			for ts_srv in ctx.get_remote_servers():
				ts_remotes.append((ts_srv as Server).server_id)
			if ts_remotes.is_empty():
				return
			var ts_do_remote := false
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
				ts_do_remote = await ctx.runner_decision_maker.choose_optional_ability(
					"Trick Shot: run a remote server?", ctx)
			else:
				ts_do_remote = true
			if not ts_do_remote:
				return
			var ts_chosen: String = ts_remotes[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				ts_chosen = await ctx.runner_decision_maker.choose_server(ts_remotes, ctx)
			if ctx.has_meta("on_run_started"):
				var ts_rcb: Callable = ctx.get_meta("on_run_started") as Callable
				ts_rcb.call(ts_chosen)
				await Engine.get_main_loop().process_frame
			await ts_rsm.execute(ts_chosen)

		"trick_shot_on_success":
			# Internal hook fired when the Trick Shot R&D run succeeds.
			if ctx.has_meta("trick_shot_pending"):
				ctx.runner_credits += 2
				ctx.send_log("Trick Shot: %s gains 2 [credits]." % ctx.runner_name())

		"burner_run":
			# Burner (on_play): Run HQ. On access, reveal 3 random HQ cards,
			# runner picks 2 to place on top or bottom of R&D.
			ctx.set_meta("burner_pending", true)
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var br_cb: Callable = ctx.get_meta("on_run_started") as Callable
				br_cb.call("hq")
				await Engine.get_main_loop().process_frame
			var br_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if br_rsm == null:
				push_error("AbilityInterpreter: burner_run — no run_state_machine")
				ctx.remove_meta("burner_pending")
				return
			# One-shot access hook: replace normal breach with burner reveal
			var br_lid := "burner_listener_%s" % str(randi())
			ctx.register_listener("successful_run", br_lid, {
				"effects": [{"type": "burner_on_success"}]
			})
			await br_rsm.execute("hq")
			ctx.unregister_all_card_effects(br_lid)
			ctx.remove_meta_if_exists("burner_pending")

		"burner_on_success":
			# Internal hook: reveal 3 random HQ cards, runner places 2 on R&D.
			if not ctx.has_meta("burner_pending"):
				return
			var bos_hand: Array = ctx.corp_hand.duplicate()
			if bos_hand.is_empty():
				ctx.send_log("Burner: HQ is empty — nothing to reveal.")
				return
			bos_hand.shuffle()
			var bos_reveal_count: int = mini(3, bos_hand.size())
			var bos_revealed: Array = bos_hand.slice(0, bos_reveal_count)
			# Log revealed cards
			var bos_names: Array = []
			for bos_e in bos_revealed:
				var bos_cr: CardRecord = (bos_e as Dictionary).get("card_record", null) as CardRecord
				bos_names.append(bos_cr.title if bos_cr != null else "?")
			ctx.send_log("Burner: revealed %s." % ", ".join(bos_names))
			# Runner picks 2 to place on R&D
			var bos_to_place: int = mini(2, bos_reveal_count)
			for bos_i in range(bos_to_place):
				var bos_remaining: Array = []
				for bos_re in bos_revealed:
					if not ctx.run_modifiers.get("_burner_placed_%s" % str(bos_re.hash()), false):
						bos_remaining.append(bos_re)
				if bos_remaining.is_empty():
					break
				# Default: pick first remaining
				var bos_pick: Dictionary = bos_remaining[0] as Dictionary
				# (Human DM would be wired via a choose_from_list prompt — simplified here)
				var bos_cr2: CardRecord = bos_pick.get("card_record", null) as CardRecord
				ctx.run_modifiers["_burner_placed_%s" % str(bos_pick.hash())] = true
				# Remove from HQ
				ctx.corp_hand.erase(bos_pick)
				# Ask top or bottom
				var bos_placement: String = "bottom"
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_top_or_bottom"):
					bos_placement = await ctx.runner_decision_maker.choose_top_or_bottom(bos_cr2, "Burner", ctx)
				if bos_placement == "top":
					ctx.corp_deck.push_front(bos_pick)
					ctx.send_log("Burner: placed %s on top of R&D." % (bos_cr2.title if bos_cr2 != null else "?"))
				else:
					ctx.corp_deck.push_back(bos_pick)
					ctx.send_log("Burner: placed %s on bottom of R&D." % (bos_cr2.title if bos_cr2 != null else "?"))
			# Clean up temp flags
			for bos_e3 in bos_revealed:
				ctx.run_modifiers.erase("_burner_placed_%s" % str(bos_e3.hash()))

		"window_of_opportunity_run":
			# Window of Opportunity (on_play):
			# 1) Optional: install 1 program or hardware from grip.
			# 2) Set woo_active flag.
			# 3) Runner chooses a server to run.
			# The RunStateMachine handles derez at initiation and Corp free-rez at end.
			# Optional install step
			var woo_types: Array = ["program", "hardware"]
			var woo_candidates: Array = []
			for woo_e in ctx.runner_hand:
				var woo_cr: CardRecord = (woo_e as Dictionary).get("card_record", null) as CardRecord
				if woo_cr != null and woo_cr.card_type in woo_types:
					woo_candidates.append(woo_e)
			if not woo_candidates.is_empty():
				var woo_do_install := false
				if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_optional_ability"):
					woo_do_install = await ctx.runner_decision_maker.choose_optional_ability(
						"Window of Opportunity: install a program or hardware from grip?", ctx)
				else:
					woo_do_install = true
				if woo_do_install:
					var woo_chosen_e: Variant = woo_candidates[0]
					if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_card_from_hand"):
						woo_chosen_e = await ctx.runner_decision_maker.choose_card_from_hand(woo_candidates, ctx)
					if woo_chosen_e != null:
						var woo_chosen_cr: CardRecord = (woo_chosen_e as Dictionary).get("card_record", null) as CardRecord
						if woo_chosen_cr != null:
							ctx.runner_hand.erase(woo_chosen_e)
							var woo_ic := InstalledCard.new()
							woo_ic.card_id       = woo_chosen_cr.id
							woo_ic.card_record   = woo_chosen_cr
							woo_ic.is_rezzed     = true
							woo_ic.runtime_instance_id = "woo_ic_%s" % str(randi())
							ctx.runner_rig.append(woo_ic)
							ctx.send_log("Window of Opportunity: installed %s." % woo_chosen_cr.title)
							# Fire on_rez if present
							var woo_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry \
								if ctx.has_meta("ability_registry") else null
							if woo_ab_reg != null:
								var woo_on_rez = woo_ab_reg.get_on_rez(woo_chosen_cr.id)
								if woo_on_rez != null:
									ctx.current_event_data = {"card": woo_ic, "card_instance_id": woo_ic.runtime_instance_id}
									await execute_trigger(woo_on_rez as Dictionary, ctx)
									ctx.current_event_data = {}
			# Set the derez flag so RunStateMachine can act on it
			ctx.run_modifiers["woo_active"] = true
			# Choose and run a server
			var woo_all_servers: Array = ["hq", "rd", "archives"]
			for woo_rsrv in ctx.get_remote_servers():
				woo_all_servers.append((woo_rsrv as Server).server_id)
			var woo_run_server: String = woo_all_servers[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				woo_run_server = await ctx.runner_decision_maker.choose_server(woo_all_servers, ctx)
			ctx.send_log("Window of Opportunity: %s runs %s." % [ctx.runner_name(), woo_run_server.to_upper()])
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var woo_cb: Callable = ctx.get_meta("on_run_started") as Callable
				woo_cb.call(woo_run_server)
				await Engine.get_main_loop().process_frame
			var woo_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if woo_rsm == null:
				push_error("AbilityInterpreter: window_of_opportunity_run — no run_state_machine")
				ctx.run_modifiers.erase("woo_active")
				return
			await woo_rsm.execute(woo_run_server)

		"spree_run":
			# Spree (on_play): place 3 counters on this event card (stored in run_modifiers),
			# then runner chooses a server to run.
			# During the run, EncounterProcessor checks run_modifiers["spree_counters"]
			# and offers the spend-1-counter-move-trojan paid ability in the encounter window.
			ctx.run_modifiers["spree_counters"] = 3
			var spr_all_servers: Array = ["hq", "rd", "archives"]
			for spr_rsrv in ctx.get_remote_servers():
				spr_all_servers.append((spr_rsrv as Server).server_id)
			var spr_run_server: String = spr_all_servers[0]
			if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_server"):
				spr_run_server = await ctx.runner_decision_maker.choose_server(spr_all_servers, ctx)
			ctx.send_log("Spree: %s runs %s with 3 counters." % [ctx.runner_name(), spr_run_server.to_upper()])
			ctx.run_modifiers["run_event_active"] = 1
			if ctx.has_meta("on_run_started"):
				var spr_cb: Callable = ctx.get_meta("on_run_started") as Callable
				spr_cb.call(spr_run_server)
				await Engine.get_main_loop().process_frame
			var spr_rsm: Object = ctx.get_meta("run_state_machine") if ctx.has_meta("run_state_machine") else null
			if spr_rsm == null:
				push_error("AbilityInterpreter: spree_run — no run_state_machine")
				ctx.run_modifiers.erase("spree_counters")
				return
			await spr_rsm.execute(spr_run_server)
			ctx.run_modifiers.erase("spree_counters")

		# ── RWR Step 5: Cupellation ─────────────────────────────────────────────

		"cancel_trash":
			# Generic: set trash_cancelled flag to block a pending trash.
			# Used by trash_interrupt effects (e.g. Cupellation protecting hosted Corp cards).
			ctx.run_modifiers["trash_cancelled"] = true
			ctx.send_log("Trash cancelled by interrupt effect.")

		"cupellation_activate":
			# Cupellation (before_breach trigger): set run_modifiers["cupellation_active"]
			# so RunStateMachine._access_card offers the capture option each access.
			ctx.run_modifiers["cupellation_active"] = true
			ctx.send_log("Cupellation: capture mode active — may spend 1cr per accessed card to host it.")

		"cupellation_breach_bonus":
			# Cupellation before_breach effect (second of two effects in before_breach trigger):
			# If breaching HQ and this program has a hosted Corp card, offer:
			# pay 1cr + trash self → access 2 additional cards.
			var cup_self := _get_self_card(ctx)
			if cup_self == null:
				return
			# Only fires for HQ breaches
			if ctx.current_event_data.get("server_id", "") != "hq":
				return
			# Only if there's a hosted Corp card
			if cup_self.hosted_corp_cards.is_empty():
				return
			# Runner may pay 1cr and trash Cupellation to gain +2 accesses
			if ctx.runner_credits < 1:
				ctx.send_log("Cupellation: %s cannot afford 1¢ for bonus access." % ctx.runner_name())
				return
			var cup_dm: Object = ctx.runner_decision_maker
			var cup_do_activate := false
			if cup_dm != null and cup_dm.has_method("choose_optional_ability"):
				cup_do_activate = await cup_dm.choose_optional_ability(
					"Cupellation: pay 1¢ and trash to access 2 additional HQ cards?", ctx)
			else:
				cup_do_activate = true   # AI default: always take bonus accesses
			if not cup_do_activate:
				return
			ctx.runner_credits -= 1
			ctx.send_log("Cupellation: %s pays 1¢." % ctx.runner_name())
			# Trash Cupellation
			ctx.runner_rig.erase(cup_self)
			ctx.unregister_all_card_effects(cup_self.runtime_instance_id)
			if cup_self.card_record != null:
				ctx.runner_discard.append(cup_self.card_record)
			ctx.send_log("Cupellation: trashed — %s gains 2 additional HQ accesses." % ctx.runner_name())
			# Grant +2 accesses for this breach
			var cup_bonus: int = ctx.run_modifiers.get("bonus_accesses", 0)
			ctx.run_modifiers["bonus_accesses"] = cup_bonus + 2

		# ── RWR Step 5: Brasilia Government Grid ────────────────────────────────

		"brasilia_derez_and_boost":
			# Brasilia Government Grid (corp_rezzes_ice trigger, once per turn):
			# Fires when Corp rezzes a piece of ice during a run against Brasilia's server.
			# Corp may derez another installed piece of ice; if they do, the newly rezzed ice
			# gets +3 strength for the remainder of this run.
			var brg_self := _get_self_card(ctx)
			if brg_self == null:
				return
			# Check: the rezzed ice must be on the same server as Brasilia
			var brg_rezzed_ice: InstalledCard = ctx.current_event_data.get("ice", null) as InstalledCard
			if brg_rezzed_ice == null:
				return
			if brg_rezzed_ice.server_id != brg_self.server_id:
				return   # ice rezzed on a different server
			if ctx.run_target_server != brg_self.server_id:
				return   # run is not targeting this server
			# Build list of all installed rezzed ice (excluding the newly rezzed one itself)
			var brg_derez_pool: Array = []
			for brg_srv in ctx.servers.values():
				for brg_srv_ice in (brg_srv as Server).ice:
					var brg_ic: InstalledCard = brg_srv_ice as InstalledCard
					if brg_ic != null and brg_ic.is_rezzed \
							and brg_ic.runtime_instance_id != brg_rezzed_ice.runtime_instance_id:
						brg_derez_pool.append(brg_ic)
			if brg_derez_pool.is_empty():
				ctx.send_log("Brasilia Government Grid: no other rezzed ice to derez.")
				return
			# Corp optionally chooses an ice to derez
			var brg_dm: Object = ctx.corp_decision_maker
			var brg_do_derez := false
			if brg_dm != null and brg_dm.has_method("choose_optional_ability"):
				brg_do_derez = await brg_dm.choose_optional_ability(
					"Brasilia Government Grid: derez another ice to give %s +3 strength?" % brg_rezzed_ice.display_name(), ctx)
			else:
				brg_do_derez = true   # AI default: always accept
			if not brg_do_derez:
				return
			var brg_target: InstalledCard = null
			if brg_dm != null and brg_dm.has_method("choose_target"):
				brg_target = await brg_dm.choose_target(brg_derez_pool, {"reason": "brasilia_derez"})
			else:
				brg_target = brg_derez_pool[0] as InstalledCard
			if brg_target == null:
				return
			brg_target.is_rezzed = false
			ctx.send_log("Brasilia Government Grid: %s is derezzed." % brg_target.display_name())
			# Grant +3 str to the newly rezzed ice for the rest of this run
			var brg_boosted: Array = ctx.run_modifiers.get("brasilia_boosted_ice_iids", []) as Array
			if not brg_boosted.has(brg_rezzed_ice.runtime_instance_id):
				brg_boosted.append(brg_rezzed_ice.runtime_instance_id)
			ctx.run_modifiers["brasilia_boosted_ice_iids"] = brg_boosted
			ctx.send_log("Brasilia Government Grid: %s gets +3 strength for this run." % brg_rezzed_ice.display_name())

		# ── RWR Step 5: Sebastiao Souza Pessoa ──────────────────────────────────

		"sebastiao_install_connection":
			# Sebastão Souza Pessoa (runner_takes_tags trigger, condition: runner_gained_first_tag):
			# Runner may install 1 connection resource from their GRIP, paying 2cr less (min 0).
			var ssp_connections: Array = []
			for ssp_entry in ctx.runner_hand:
				var ssp_record: CardRecord = (ssp_entry as Dictionary).get("card_record", null) as CardRecord
				if ssp_record == null:
					ssp_record = ssp_entry as CardRecord
				if ssp_record != null and ssp_record.card_type == "resource" \
						and ssp_record.has_subtype("connection"):
					ssp_connections.append(ssp_record)
			if ssp_connections.is_empty():
				ctx.send_log("Sebastão Souza Pessoa: no connection resources in grip.")
				return
			var ssp_dm: Object = ctx.runner_decision_maker
			var ssp_do_install := false
			if ssp_dm != null and ssp_dm.has_method("choose_optional_ability"):
				ssp_do_install = await ssp_dm.choose_optional_ability(
					"Sebastão: install a connection from grip (paying 2cr less)?", ctx)
			else:
				ssp_do_install = true
			if not ssp_do_install:
				return
			var ssp_chosen: CardRecord = null
			if ssp_dm != null and ssp_dm.has_method("choose_from_hand"):
				ssp_chosen = await ssp_dm.choose_from_hand(ssp_connections, ctx)
			else:
				ssp_chosen = ssp_connections[0]
			if ssp_chosen == null:
				return
			# Pay install cost (cost - 2, min 0)
			var ssp_cost: int = max(0, ssp_chosen.cost - 2)
			if ctx.runner_credits < ssp_cost:
				ctx.send_log("Sebastão Souza Pessoa: cannot afford %d¢ install cost." % ssp_cost)
				return
			ctx.runner_credits -= ssp_cost
			# Remove from hand
			for ssp_i in range(ctx.runner_hand.size()):
				var ssp_entry: Variant = ctx.runner_hand[ssp_i]
				var ssp_cr: CardRecord = null
				if ssp_entry is Dictionary:
					ssp_cr = (ssp_entry as Dictionary).get("card_record", null) as CardRecord
				else:
					ssp_cr = ssp_entry as CardRecord
				if ssp_cr == ssp_chosen:
					ctx.runner_hand.remove_at(ssp_i)
					break
			var ssp_installed := InstalledCard.make_runtime_instance(ssp_chosen, "runner_rig", "root", true)
			ctx.runner_rig.append(ssp_installed)
			if ctx.has_meta("register_installed_card"):
				var ssp_reg: Callable = ctx.get_meta("register_installed_card") as Callable
				ssp_reg.call(ssp_installed)
			if ctx.has_meta("ability_registry"):
				var ssp_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
				var ssp_on_rez = ssp_ab_reg.get_on_rez(ssp_chosen.id)
				if ssp_on_rez != null:
					ctx.current_event_data = {
						"card": ssp_installed,
						"card_instance_id": ssp_installed.runtime_instance_id
					}
					await execute_trigger(ssp_on_rez as Dictionary, ctx)
					ctx.current_event_data = {}
			ctx.send_log("Sebastão Souza Pessoa: installed %s from grip (paid %d¢)." % [ssp_chosen.title, ssp_cost])

		"sebastiao_trash_interrupt":
			# Sebastão Souza Pessoa (trash_interrupt): As additional cost to trash this connection,
			# Corp must trash 1 card from HQ. If HQ is empty, the trash proceeds without extra cost.
			if ctx.corp_hand.is_empty():
				ctx.send_log("Sebastão Souza Pessoa: HQ is empty — no additional trash cost.")
				return
			var ssp_ti_dm: Object = ctx.corp_decision_maker
			var ssp_ti_do_trash_hq := false
			if ssp_ti_dm != null and ssp_ti_dm.has_method("choose_optional_ability"):
				ssp_ti_do_trash_hq = await ssp_ti_dm.choose_optional_ability(
					"Sebastão Souza Pessoa: trash 1 card from HQ as additional trash cost?", ctx)
			else:
				ssp_ti_do_trash_hq = true  # AI default: pay the cost
			if not ssp_ti_do_trash_hq:
				# Corp refuses — trash is cancelled
				ctx.run_modifiers["trash_cancelled"] = true
				ctx.send_log("Sebastão Souza Pessoa: Corp declines to trash from HQ — trash cancelled.")
				return
			# Corp chooses 1 card from HQ to trash
			var ssp_ti_chosen_entry: Variant = null
			if ssp_ti_dm != null and ssp_ti_dm.has_method("choose_card_from_hand"):
				ssp_ti_chosen_entry = await ssp_ti_dm.choose_card_from_hand(ctx.corp_hand, ctx)
			else:
				ssp_ti_chosen_entry = ctx.corp_hand[0]
			if ssp_ti_chosen_entry == null:
				return
			var ssp_ti_entry: Dictionary = ssp_ti_chosen_entry as Dictionary
			var ssp_ti_cr: CardRecord = ssp_ti_entry.get("card_record", null) as CardRecord
			ctx.corp_hand.erase(ssp_ti_entry)
			if ssp_ti_cr != null:
				ctx.corp_discard.append(ssp_ti_cr)
				ctx.corp_discard_facedown[ssp_ti_cr.title] = true
				ctx.send_log("Sebastão Souza Pessoa: Corp trashes %s from HQ as additional cost." % ssp_ti_cr.title)
			else:
				ctx.send_log("Sebastão Souza Pessoa: Corp trashes a card from HQ as additional cost.")

		# ── RWR Step 5: Lightning Laboratory ────────────────────────────────────

		"lightning_lab_rez_free_ice":
			# Lightning Laboratory (scored Corp agenda, run_start trigger):
			# Corp may spend 1 agenda counter to rez up to 2 ice protecting the attacked server,
			# ignoring all costs. At runner_turn_end, derez 2 ice protecting that server.
			var llr_self := _get_self_card(ctx)
			if llr_self == null:
				return
			# Check Corp has a counter to spend
			if llr_self.get_counter("agenda") < 1:
				return  # no counters left
			# Find unrezzed ice on the attacked server
			var llr_server_id: String = ctx.run_target_server
			if llr_server_id.is_empty():
				return
			var llr_server: Server = ctx.get_server(llr_server_id)
			if llr_server == null:
				return
			var llr_candidates: Array = []
			for llr_ice in llr_server.ice:
				var llr_ic: InstalledCard = llr_ice as InstalledCard
				if llr_ic != null and not llr_ic.is_rezzed:
					llr_candidates.append(llr_ic)
			if llr_candidates.is_empty():
				return  # nothing to rez
			# Ask Corp if they want to spend the counter
			var llr_dm: Object = ctx.corp_decision_maker
			var llr_do_activate := false
			if llr_dm != null and llr_dm.has_method("choose_optional_ability"):
				llr_do_activate = await llr_dm.choose_optional_ability(
					"Lightning Laboratory: spend 1 agenda counter to rez up to 2 ice on %s?" % llr_server_id, ctx)
			else:
				llr_do_activate = true
			if not llr_do_activate:
				return
			# Spend the counter
			llr_self.remove_counter("agenda", 1)
			ctx.send_log("Lightning Laboratory: spends 1 agenda counter.")
			# Corp chooses up to 2 ice to rez for free
			var llr_rezzed_iids: Array = []
			var llr_to_rez_count: int = min(2, llr_candidates.size())
			for _llr_i in range(llr_to_rez_count):
				if llr_candidates.is_empty():
					break
				var llr_target: InstalledCard = null
				if llr_dm != null and llr_dm.has_method("choose_target"):
					llr_target = await llr_dm.choose_target(llr_candidates, {"reason": "lightning_lab_rez"})
				else:
					llr_target = llr_candidates[0] as InstalledCard
				if llr_target == null:
					break
				llr_candidates.erase(llr_target)
				llr_target.is_rezzed = true
				ctx.ice_rezzed_this_turn_instance_ids.append(llr_target.runtime_instance_id)
				llr_rezzed_iids.append(llr_target.runtime_instance_id)
				ctx.send_log("Lightning Laboratory: rezzed %s for free." % llr_target.display_name())
				# Register listeners for the newly rezzed ice (similar to _rez_card)
				if ctx.has_meta("ability_registry"):
					var llr_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
					var llr_on_rez = llr_ab_reg.get_on_rez(llr_target.card_id)
					if llr_on_rez != null:
						ctx.current_event_data = {"card": llr_target, "card_instance_id": llr_target.runtime_instance_id}
						await execute_trigger(llr_on_rez as Dictionary, ctx)
						ctx.current_event_data = {}
			# Track rezzed ice IIDs and the server for end-of-turn derez
			var llr_existing: Array = ctx.lightning_lab_rezzed_ice_iids.duplicate()
			for llr_iid in llr_rezzed_iids:
				if not llr_existing.has(llr_iid):
					llr_existing.append(llr_iid)
			ctx.lightning_lab_rezzed_ice_iids = llr_existing
			ctx.run_modifiers["lightning_lab_rezzed_server"] = llr_server_id

		"lightning_lab_derez_at_end":
			# Lightning Laboratory (scored Corp agenda, runner_turn_end trigger):
			# Derez the up-to-2 ice that Lightning Lab rezzed free this Runner's turn.
			if ctx.lightning_lab_rezzed_ice_iids.is_empty():
				return
			var lld_count := 0
			for lld_iid in ctx.lightning_lab_rezzed_ice_iids:
				var lld_ic: InstalledCard = ctx.get_ice_by_instance_id(lld_iid as String)
				if lld_ic != null and lld_ic.is_rezzed:
					lld_ic.is_rezzed = false
					ctx.send_log("Lightning Laboratory: %s is derezzed." % lld_ic.display_name())
					lld_count += 1
			ctx.lightning_lab_rezzed_ice_iids.clear()
			ctx.run_modifiers.erase("lightning_lab_rezzed_server")
			if lld_count > 0:
				ctx.send_log("Lightning Laboratory: %d ice derezzed at end of Runner turn." % lld_count)

		# ── RWR Step 5: Logjam ───────────────────────────────────────────────────

		"logjam_init_from_archives":
			# Logjam (on_rez):
			# "Place 1 advancement counter on it plus 1 advancement counter for each card type
			#  among faceup cards in Archives."
			# Faceup = in corp_discard and NOT currently in corp_discard_facedown as true.
			# Card types: agenda, asset, upgrade, operation, ice (and any others).
			var lij_self := _get_self_card(ctx)
			if lij_self == null:
				push_error("AbilityInterpreter: logjam_init_from_archives — no self card")
				return
			# Count distinct card types among faceup Archives cards
			var lij_faceup_types: Array = []
			for lij_cr in ctx.corp_discard:
				var lij_record: CardRecord = lij_cr as CardRecord
				if lij_record == null:
					continue
				# A card is facedown if its title is in corp_discard_facedown with value true
				if ctx.corp_discard_facedown.get(lij_record.title, false):
					continue   # facedown — skip
				var lij_type: String = lij_record.card_type
				if not lij_faceup_types.has(lij_type):
					lij_faceup_types.append(lij_type)
			var lij_tokens: int = 1 + lij_faceup_types.size()
			lij_self.add_counter("advancement", lij_tokens)
			ctx.send_log("Logjam: placed %d advancement counter(s) (1 base + %d distinct card type(s) in Archives)." % [
				lij_tokens, lij_faceup_types.size()])

		# ── RWR Step 5: Boto ─────────────────────────────────────────────────────

		"may_trash_hq_card_etr":
			# Boto sub 2/3: "You may trash 1 card from HQ to end the run."
			# Corp may choose any card from HQ to trash; if they do, the run ends.
			if ctx.corp_hand.is_empty():
				ctx.send_log("May trash HQ card → ETR: HQ is empty — sub has no effect.")
				return
			var mthq_dm: Object = ctx.corp_decision_maker
			var mthq_do_pay := false
			if mthq_dm != null and mthq_dm.has_method("choose_optional_ability"):
				mthq_do_pay = await mthq_dm.choose_optional_ability(
					"Boto: trash 1 card from HQ to end the run?", ctx)
			else:
				mthq_do_pay = true  # AI default: always pay to end the run
			if not mthq_do_pay:
				ctx.send_log("Boto: Corp declines to trash — sub has no effect.")
				return
			# Corp picks which HQ card to trash
			var mthq_entry: Dictionary = {}
			if mthq_dm != null and mthq_dm.has_method("choose_card_from_hand"):
				var mthq_chosen = await mthq_dm.choose_card_from_hand(ctx.corp_hand.duplicate(), ctx)
				if mthq_chosen != null and ctx.corp_hand.has(mthq_chosen):
					mthq_entry = mthq_chosen as Dictionary
				else:
					mthq_entry = ctx.corp_hand[0] as Dictionary
			else:
				mthq_entry = ctx.corp_hand[0] as Dictionary
			ctx.corp_hand.erase(mthq_entry)
			var mthq_cr: CardRecord = mthq_entry.get("card_record", null) as CardRecord
			if mthq_cr != null:
				ctx.corp_discard.append(mthq_cr)
				ctx.corp_discard_facedown[mthq_cr.title] = false  # trashed from HQ = faceup
				ctx.send_log("Boto: Corp trashes %s from HQ — run ends." % mthq_cr.title)
			else:
				ctx.send_log("Boto: Corp trashes a card from HQ — run ends.")
			ctx.run_ended = true

		# ── RWR Step 5: Business as Usual ────────────────────────────────────────

		"advance_two_installed":
			# Business as Usual (corp operation): place 1 advancement token on each of up to 2
			# installed Corp cards. Corp chooses which cards to advance.
			var ati_pool: Array = []
			for ati_srv_val in ctx.servers.values():
				var ati_s: Server = ati_srv_val as Server
				for ati_root_card in ati_s.root:
					var ati_ic: InstalledCard = ati_root_card as InstalledCard
					if ati_ic != null:
						ati_pool.append(ati_ic)
				for ati_ice_card in ati_s.ice:
					var ati_ic2: InstalledCard = ati_ice_card as InstalledCard
					if ati_ic2 != null and ati_ic2.can_be_advanced():
						ati_pool.append(ati_ic2)
			if ati_pool.is_empty():
				ctx.send_log("Business as Usual: no installed cards to advance.")
				return
			var ati_dm: Object = ctx.corp_decision_maker
			# Place up to 2 advancement tokens, one at a time
			for ati_i in range(2):
				if ati_pool.is_empty():
					break
				var ati_target: InstalledCard = null
				if ati_dm != null and ati_dm.has_method("choose_target"):
					ati_target = await ati_dm.choose_target(ati_pool, {"reason": "advance_installed"})
				else:
					ati_target = ati_pool[0] as InstalledCard
				if ati_target == null:
					break
				ati_target.add_counter("advancement", 1)
				ctx.send_log("Business as Usual: places 1 advancement token on %s." % ati_target.display_name())
				# Don't remove from pool — Corp can put both tokens on the same card

		"remove_all_virus_counters":
			# Business as Usual (corp operation):
			# "Remove all virus counters from 1 installed card." — Corp chooses the target card.
			# Build pool of runner cards that have at least 1 virus counter.
			var ravc_pool: Array = []
			for ravc_rig in ctx.runner_rig:
				var ravc_ic: InstalledCard = ravc_rig as InstalledCard
				if ravc_ic != null and ravc_ic.get_counter("virus") > 0:
					ravc_pool.append(ravc_ic)
			# Also check trojans hosted on ice
			for ravc_srv in ctx.servers.values():
				for ravc_ice in (ravc_srv as Server).ice:
					for ravc_hosted in (ravc_ice as InstalledCard).hosted_cards:
						var ravc_h: InstalledCard = ravc_hosted as InstalledCard
						if ravc_h != null and ravc_h.get_counter("virus") > 0 and not ravc_pool.has(ravc_h):
							ravc_pool.append(ravc_h)
			if ravc_pool.is_empty():
				ctx.send_log("Business as Usual: no cards with virus counters.")
				return
			var ravc_dm: Object = ctx.corp_decision_maker
			var ravc_target: InstalledCard = null
			if ravc_dm != null and ravc_dm.has_method("choose_target"):
				ravc_target = await ravc_dm.choose_target(ravc_pool, {"reason": "remove_virus_counters"})
			else:
				ravc_target = ravc_pool[0] as InstalledCard
			if ravc_target != null:
				var ravc_removed: int = ravc_target.get_counter("virus")
				ravc_target.counters["virus"] = 0
				ctx.send_log("Business as Usual: removes %d virus counter(s) from %s." % [
					ravc_removed, ravc_target.display_name()])

		# ── RWR Step 5: The Basalt Spire ─────────────────────────────────────────

		"basalt_spire_add_one_from_archives":
			# The Basalt Spire (on_steal trigger and click_action effect):
			# "You may add 1 card from Archives to HQ." — Corp chooses which card.
			if ctx.corp_discard.is_empty():
				ctx.send_log("The Basalt Spire: Archives is empty — nothing to add to HQ.")
				return
			var tbs_dm: Object = ctx.corp_decision_maker
			var tbs_do_add := false
			if tbs_dm != null and tbs_dm.has_method("choose_optional_ability"):
				tbs_do_add = await tbs_dm.choose_optional_ability(
					"The Basalt Spire: add 1 card from Archives to HQ?", ctx)
			else:
				tbs_do_add = true  # AI always takes it
			if not tbs_do_add:
				ctx.send_log("The Basalt Spire: Corp declines.")
				return
			var tbs_cr: CardRecord = null
			if tbs_dm != null and tbs_dm.has_method("choose_card_from_discard"):
				tbs_cr = await tbs_dm.choose_card_from_discard(ctx.corp_discard, ctx)
			else:
				tbs_cr = ctx.corp_discard[0] as CardRecord
			if tbs_cr == null:
				return
			ctx.corp_discard.erase(tbs_cr)
			ctx.corp_discard_facedown.erase(tbs_cr.title)
			ctx.corp_hand.append({"card_record": tbs_cr, "known": false})
			ctx.send_log("The Basalt Spire: %s added from Archives to HQ." % tbs_cr.title)

		"basalt_spire_counter_ability":
			# The Basalt Spire (Corp click_action from score area):
			# "●  Hosted agenda counter, trash the top card of R&D: Add 1 card from Archives to HQ."
			# Costs: 1 click (handled by click_action wrapper) + 1 agenda counter + trash top R&D.
			var tbs_self := _get_self_card(ctx)
			if tbs_self == null:
				return
			if tbs_self.get_counter("agenda") < 1:
				ctx.send_log("The Basalt Spire: no agenda counters remaining.")
				return
			if ctx.corp_deck.is_empty():
				ctx.send_log("The Basalt Spire: R&D is empty — cannot pay trash cost.")
				return
			if ctx.corp_discard.is_empty():
				ctx.send_log("The Basalt Spire: Archives is empty — no benefit from activating.")
				return
			# Pay: spend 1 agenda counter
			tbs_self.remove_counter("agenda", 1)
			# Pay: trash top card of R&D
			var tbs_top: CardRecord = ctx.corp_deck.pop_front() as CardRecord
			if tbs_top != null:
				ctx.corp_discard.append(tbs_top)
				ctx.corp_discard_facedown[tbs_top.title] = false  # trashed from R&D = faceup
				ctx.send_log("The Basalt Spire: spends 1 agenda counter — trashes %s from R&D." % tbs_top.title)
			# Effect: add 1 card from Archives to HQ (Corp chooses)
			var tbs2_dm: Object = ctx.corp_decision_maker
			var tbs2_cr: CardRecord = null
			if tbs2_dm != null and tbs2_dm.has_method("choose_card_from_discard"):
				tbs2_cr = await tbs2_dm.choose_card_from_discard(ctx.corp_discard, ctx)
			else:
				tbs2_cr = ctx.corp_discard[0] as CardRecord if not ctx.corp_discard.is_empty() else null
			if tbs2_cr != null:
				ctx.corp_discard.erase(tbs2_cr)
				ctx.corp_discard_facedown.erase(tbs2_cr.title)
				ctx.corp_hand.append({"card_record": tbs2_cr, "known": false})
				ctx.send_log("The Basalt Spire: %s added from Archives to HQ." % tbs2_cr.title)

		# ── RWR Step 5: Seraph ───────────────────────────────────────────────────

		"seraph_encounter_toll":
			# Seraph on_encounter: Runner loses 3cr unless they suffer 2 net damage or take 1 tag.
			# Runner chooses which penalty to suffer; credits option requires affordability.
			var set_options: Array = [
				{"type": "credits", "amount": params.get("credits", 3), "label": "Lose 3[credit]"},
				{"type": "net",     "amount": params.get("net", 2),     "label": "Suffer 2 net damage"},
				{"type": "tag",     "amount": params.get("tag", 1),     "label": "Take 1 tag"},
			]
			# Credits option only available if affordable
			var set_affordable: Array = []
			for set_opt in set_options:
				var set_o: Dictionary = set_opt as Dictionary
				if set_o.get("type") == "credits" and ctx.runner_credits < set_o.get("amount", 0):
					continue  # can't pay; skip but other options remain
				set_affordable.append(set_o)
			if set_affordable.is_empty():
				# Shouldn't happen (net/tag always available) — fallback
				await _deal_damage("net", 1, ctx)
				ctx.send_log("Seraph: no options available — default 1 net damage.")
				return
			var set_chosen: Variant = null
			var set_dm: Object = ctx.runner_decision_maker
			if set_dm != null and set_dm.has_method("choose_payment_option"):
				set_chosen = await set_dm.choose_payment_option(set_affordable, ctx)
			else:
				# AI default: prefer tag (least immediately harmful) over damage over credits
				for set_pref in ["tag", "net", "credits"]:
					for set_a in set_affordable:
						if (set_a as Dictionary).get("type") == set_pref:
							set_chosen = set_a
							break
					if set_chosen != null:
						break
			if set_chosen == null:
				set_chosen = set_affordable[0]
			var set_c: Dictionary = set_chosen as Dictionary
			match set_c.get("type", ""):
				"credits":
					ctx.runner_credits -= set_c.get("amount", 3)
					ctx.send_log("Seraph: %s loses %d cr." % [ctx.runner_name(), set_c.get("amount", 3)])
				"net":
					await _deal_damage("net", set_c.get("amount", 1), ctx)
				"tag":
					var set_was_zero := (ctx.runner_tags == 0)
					ctx.runner_tags += set_c.get("amount", 1)
					ctx.send_log("Seraph: %s takes %d tag(s)." % [ctx.runner_name(), set_c.get("amount", 1)])
					await ctx.notify_event("runner_takes_tags", {
						"amount": set_c.get("amount", 1), "from_zero": set_was_zero
					}, self)

		# ── RWR Step 5: Cloud Eater ──────────────────────────────────────────────

		"cloud_eater_end_toll":
			# Cloud Eater encounter_ended trigger (fires only when rezzed this turn, via JSON condition).
			# "Trash 1 installed Runner card unless the Runner takes 2 tags or suffers 3 net damage."
			# → Runner may pay tags/damage to avoid the trash.  If they don't (or can't), Corp trashes.
			var ceet_rig_all: Array = []
			for ceet_ic in ctx.runner_rig:
				ceet_rig_all.append(ceet_ic as InstalledCard)
			for ceet_srv in ctx.servers.values():
				for ceet_ice in (ceet_srv as Server).ice:
					for ceet_h in (ceet_ice as InstalledCard).hosted_cards:
						var ceet_hc: InstalledCard = ceet_h as InstalledCard
						if ceet_hc != null and not ceet_rig_all.has(ceet_hc):
							ceet_rig_all.append(ceet_hc)

			ctx.send_log("Cloud Eater: (rezzed this turn) trash 1 Runner card unless Runner takes 2 tags or suffers 3 net damage.")

			# Offer the Runner options to avoid the trash
			var ceet_avoid_opts: Array = [
				{"type": "tags",   "amount": 2, "label": "Take 2 tags to avoid"},
				{"type": "damage", "amount": 3, "label": "Suffer 3 net damage to avoid"},
			]
			var ceet_runner_dm: Object = ctx.runner_decision_maker
			var ceet_avoid_chosen: Variant = null

			if not ceet_rig_all.is_empty():
				# Runner has cards to lose — offer the avoidance options
				if ceet_runner_dm != null and ceet_runner_dm.has_method("choose_payment_option"):
					ceet_avoid_chosen = await ceet_runner_dm.choose_payment_option(ceet_avoid_opts, ctx)
				else:
					# AI Runner: prefer tags if already tagged (less relative harm), else damage
					if ctx.runner_tags > 0:
						ceet_avoid_chosen = ceet_avoid_opts[0]  # take 2 tags
					else:
						ceet_avoid_chosen = null  # let the card be trashed rather than take damage

			if ceet_avoid_chosen != null:
				# Runner pays to avoid
				var ceet_ac: Dictionary = ceet_avoid_chosen as Dictionary
				match ceet_ac.get("type", ""):
					"tags":
						var ceet_was_zero: bool = (ctx.runner_tags == 0)
						ctx.runner_tags += 2
						ctx.send_log("Cloud Eater: %s takes 2 tags to avoid trash." % ctx.runner_name())
						await ctx.notify_event("runner_takes_tags", {"amount": 2, "from_zero": ceet_was_zero}, self)
					"damage":
						await _deal_damage("net", 3, ctx)
						ctx.send_log("Cloud Eater: %s suffers 3 net damage to avoid trash." % ctx.runner_name())
			else:
				# No avoidance paid — Corp trashes 1 Runner card
				if ceet_rig_all.is_empty():
					ctx.send_log("Cloud Eater: no Runner cards to trash.")
					return
				var ceet_corp_dm: Object = ctx.corp_decision_maker
				var ceet_target: InstalledCard = null
				if ceet_corp_dm != null and ceet_corp_dm.has_method("choose_target"):
					ceet_target = await ceet_corp_dm.choose_target(ceet_rig_all, {"reason": "cloud_eater_trash"})
				else:
					ceet_target = ceet_rig_all[0] as InstalledCard
				if ceet_target != null:
					if ceet_target.hosted_on_id != "":
						var ceet_host := ctx.get_ice_by_instance_id(ceet_target.hosted_on_id)
						if ceet_host != null:
							ceet_host.hosted_cards.erase(ceet_target)
					else:
						ctx.runner_rig.erase(ceet_target)
					ctx.unregister_all_card_effects(ceet_target.runtime_instance_id)
					if ceet_target.card_record != null:
						ctx.runner_discard.append(ceet_target.card_record)
					ctx.send_log("Cloud Eater: trashes %s." % ceet_target.display_name())

		# ── RWR Step 5: Descent ──────────────────────────────────────────────────

		"descent_hq_activate":
			# Descent (hq_activate trigger): Corp reveals and trashes this ice from HQ
			# to draw 1 card and reveal up to 2 agendas from HQ/Archives, shuffling them into R&D.
			# The PAW handler moves Descent to Archives after this trigger fires.
			_draw_cards("corp", 1, ctx)
			# Collect agendas from HQ and Archives to reveal (up to 2)
			var dsc_agendas: Array = []
			for dsc_hq_entry in ctx.corp_hand:
				var dsc_hq_cr: CardRecord = (dsc_hq_entry as Dictionary).get("card_record", null) as CardRecord
				if dsc_hq_cr != null and dsc_hq_cr.is_agenda():
					dsc_agendas.append({"source": "hq", "card_record": dsc_hq_cr, "entry": dsc_hq_entry})
					if dsc_agendas.size() >= 2:
						break
			if dsc_agendas.size() < 2:
				for dsc_arc_cr in ctx.corp_discard:
					var dsc_ac: CardRecord = dsc_arc_cr as CardRecord
					if dsc_ac != null and dsc_ac.is_agenda():
						dsc_agendas.append({"source": "archives", "card_record": dsc_ac})
						if dsc_agendas.size() >= 2:
							break
			# Corp may reveal up to 2; let Corp pick which ones (AI: take as many as available)
			var dsc_dm: Object = ctx.corp_decision_maker
			var dsc_reveal: Array = []
			if dsc_dm != null and dsc_dm.has_method("choose_targets_up_to"):
				dsc_reveal = await dsc_dm.choose_targets_up_to(dsc_agendas, 2, {"reason": "descent_reveal_agendas"})
			else:
				# AI default: reveal as many as available (up to 2)
				dsc_reveal = dsc_agendas.slice(0, min(2, dsc_agendas.size()))
			for dsc_entry in dsc_reveal:
				var dsc_e: Dictionary = dsc_entry as Dictionary
				var dsc_cr: CardRecord = dsc_e.get("card_record", null) as CardRecord
				if dsc_cr == null:
					continue
				ctx.send_log("Descent: reveals %s." % dsc_cr.title)
				if dsc_e.get("source", "") == "hq":
					var dsc_hq_e: Dictionary = dsc_e.get("entry", {}) as Dictionary
					ctx.corp_hand.erase(dsc_hq_e)
				else:
					ctx.corp_discard.erase(dsc_cr)
					ctx.corp_discard_facedown.erase(dsc_cr.title)
				ctx.corp_deck.append(dsc_cr)
			if not dsc_reveal.is_empty():
				ctx.corp_deck.shuffle()
				ctx.send_log("Descent: %d agenda(s) shuffled into R&D." % dsc_reveal.size())

		"descent_move_to_hq":
			# Descent corp_turn_start trigger: Corp may move this installed ice to HQ.
			# Once in HQ, Corp can later activate it with the [click]+1cr cost from HQ.
			var dtmh_self := _get_self_card(ctx)
			if dtmh_self == null:
				return
			# Check this ice is still installed on a server (not already in HQ)
			var dtmh_server: Server = ctx.get_server(dtmh_self.server_id)
			if dtmh_server == null or not dtmh_server.ice.has(dtmh_self):
				return
			# Ask Corp if they want to move it
			var dtmh_do_move := false
			var dtmh_dm: Object = ctx.corp_decision_maker
			if dtmh_dm != null and dtmh_dm.has_method("choose_optional_ability"):
				dtmh_do_move = await dtmh_dm.choose_optional_ability(
					"Descent: move this ice to HQ?", ctx)
			else:
				dtmh_do_move = false   # AI default: keep it installed
			if not dtmh_do_move:
				return
			# Remove from server and unregister listeners
			dtmh_server.ice.erase(dtmh_self)
			ctx.unregister_all_card_effects(dtmh_self.runtime_instance_id)
			# Add to corp_hand as a known card
			ctx.corp_hand.append({"card_record": dtmh_self.card_record, "known": true})
			ctx.send_log("Descent: Corp moves %s to HQ." % dtmh_self.display_name())

		_:
			push_error("AbilityInterpreter: unknown effect type '%s'" % etype)


# ── Effect helpers ────────────────────────────────────────────────────────────

# Default heuristic for sabotage when no decision-maker method is available.
# Returns {"source": "hq", "card_record": cr} or {"source": "rd"}.
func _sabotage_default_choice(ctx: GameContext) -> Dictionary:
	# Prefer cheapest non-agenda from HQ — safe to lose, can't be stolen from Archives
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
	# No non-agendas in HQ — trash top of R&D (unknown card, less predictably bad)
	if not ctx.corp_deck.is_empty():
		return {"source": "rd"}
	# R&D empty — must trash from HQ (even an agenda)
	if not ctx.corp_hand.is_empty():
		return {"source": "hq", "card_record": ctx.corp_hand[0].get("card_record") as CardRecord}
	return {}   # nothing to trash

func _resolve_amount(amount_def: Variant, ctx: GameContext) -> int:
	if amount_def is int:
		return amount_def
	if amount_def is float:
		return int(amount_def)

	# Structured amount: {"base": 2, "plus_counters": "advancement"}
	if amount_def is Dictionary:
		var base: int        = int((amount_def as Dictionary).get("base", 0))
		var plus_counters    = (amount_def as Dictionary).get("plus_counters", "")
		if plus_counters != "":
			base += ctx.get_counters_on_accessed_card(plus_counters as String)
		return base

	push_error("AbilityInterpreter: unrecognised amount definition: %s" % str(amount_def))
	return 0


# ── Phase 1 helpers ───────────────────────────────────────────────────────────

# Returns the InstalledCard that "owns" the currently executing ability.
# Reads card_instance_id (preferred) then card_id from current_event_data,
# and falls back from get_by_instance_id to get_by_id so on_rez abilities
# fired before the card has a runtime_instance_id still resolve correctly.
func _get_self_card(ctx: GameContext) -> InstalledCard:
	var iid: String = ctx.current_event_data.get("card_instance_id", "")
	if iid.is_empty():
		iid = ctx.current_event_data.get("card_id", "")
	var card := ctx.get_installed_card_by_instance_id(iid)
	if card == null and not iid.is_empty():
		card = ctx.get_installed_card_by_id(iid)
	return card


# Places a Corp card into a server (ice or root zone) as an InstalledCard.
# Does NOT update corp_installed_this_turn, log, notify events, or pay costs —
# the caller is responsible for all of those.  Returns the new InstalledCard.
func _install_corp_card(record: CardRecord, server: Server,
		zone: String, rezzed: bool) -> InstalledCard:
	var installed := InstalledCard.make_runtime_instance(record, server.server_id, zone, rezzed)
	if zone == "ice":
		server.install_ice(installed)
	else:
		server.install_in_root(installed)
	return installed


func _deal_damage(damage_type: String, amount: int, ctx: GameContext) -> Array:
	# ── AirbladeX (JSRF Ed.) interrupt — prevent net damage ──────────────────
	# [interrupt] → Hosted power counter: Prevent 1 net damage.
	# Only offered during a run, per damage point, while counters remain.
	# The runner is asked for each potential prevention; they may decline to
	# preserve counters for the when-encountered interrupt.
	if damage_type == "net" and ctx.run_active and amount > 0:
		var prevented: int = 0
		while prevented < amount and ctx.runner_has_airbladex_counter():
			var use_it: bool = false
			if ctx.runner_decision_maker != null and \
					ctx.runner_decision_maker.has_method("use_airbladex_prevent_net_damage"):
				use_it = await ctx.runner_decision_maker.use_airbladex_prevent_net_damage(
					damage_type, amount - prevented, ctx)
			# else: no decision maker — don't auto-spend
			if use_it:
				ctx.spend_airbladex_counter()
				prevented += 1
				ctx.send_log("[AirbladeX] 1 net damage prevented (%d of %d remaining)." % \
					[amount - prevented, amount])
			else:
				break  # runner declined — stop offering for this damage event
		amount -= prevented
		if amount <= 0:
			return []   # all damage prevented

	ctx.send_log("Runner takes %d %s damage." % [amount, damage_type])
	var trashed: int = 0
	var trashed_cards: Array = []
	for i in range(amount):
		if ctx.runner_hand.is_empty():
			ctx.send_log("%s is flatlined! (no cards remaining in grip)" % ctx.runner_name())
			ctx.game_over = true
			ctx.winner    = "corp"
			break
		var idx: int = randi() % ctx.runner_hand.size()
		var entry: Dictionary = ctx.runner_hand[idx] as Dictionary
		ctx.runner_hand.remove_at(idx)
		var record: CardRecord = entry.get("card_record", null) as CardRecord
		if record != null:
			trashed_cards.append(record)
			ctx.runner_discard.append(record)
		trashed += 1
		ctx.send_log("  Trashed from grip: %s" % entry.get("card_id", "unknown"))
	ctx.send_log("%d card(s) trashed from %s's grip." % [trashed, ctx.runner_name()])
	# AU Co.: The Gold Standard in Clones — place 1 power counter whenever Corp deals damage.
	if trashed > 0 and not ctx.game_over and ctx.corp_identity != null and \
			ctx.corp_identity.id == "au_co_the_gold_standard_in_clones":
		ctx.corp_identity_counters["power"] = ctx.corp_identity_counters.get("power", 0) + 1
		ctx.send_log("AU Co.: Power counter placed (%d total)." % ctx.corp_identity_counters.get("power", 0))
	# Core damage: permanently reduce maximum hand size by the amount actually dealt.
	if damage_type == "core" and trashed > 0 and not ctx.game_over:
		ctx.runner_core_damage_taken += trashed
		ctx.send_log("%s's maximum hand size permanently reduced to %d (core damage total: %d)." % [
			ctx.runner_name(), ctx.runner_max_hand_size(), ctx.runner_core_damage_taken
		])
		if ctx.runner_max_hand_size() < 0:
			ctx.send_log("%s is flatlined! (maximum hand size below 0 from core damage)" % ctx.runner_name())
			ctx.game_over = true
			ctx.winner    = "corp"
	# Strike Fund and similar: fire on_self_trashed_from_grip_or_stack triggers.
	# Ruling: cards trashed from grip by damage trigger this (not discard to hand size).
	if not trashed_cards.is_empty() and not ctx.game_over:
		await _fire_self_trashed_triggers(trashed_cards, ctx)

	return trashed_cards


# ── Self-trashed-from-grip/stack trigger helper ───────────────────────────────
# Called whenever cards are moved from runner_hand or runner_deck to runner_discard
# as a TRASH (not a discard-to-hand-limit). Checks each card for an
# on_self_trashed_from_grip_or_stack ability and executes it.
# Examples: Strike Fund (may gain 2cr); Labor Rights stack trash; Lago Paranoá stack cost.
func _fire_self_trashed_triggers(records: Array, ctx: GameContext) -> void:
	if not ctx.has_meta("ability_registry"):
		return
	var ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
	for rec in records:
		var record: CardRecord = rec as CardRecord
		if record == null:
			continue
		var card_def: Dictionary = ab_reg._abilities.get(record.id, {}) as Dictionary
		var trigger_def: Variant = card_def.get("on_self_trashed_from_grip_or_stack", null)
		if trigger_def == null:
			continue
		ctx.current_event_data = {"card_id": record.id}
		await execute_trigger(trigger_def as Dictionary, ctx)
		ctx.current_event_data = {}


# ── Forfeit helper ────────────────────────────────────────────────────────────
# Removes a scored agenda from corp_score_area, places it in corp_discard,
# fires the on_forfeit event, and executes any on_forfeit ability for that card.

func _forfeit_agenda(scored_agenda: InstalledCard, ctx: GameContext) -> void:
	var idx: int = -1
	for i in range(ctx.corp_score_area_cards.size()):
		if ctx.corp_score_area_cards[i] == scored_agenda:
			idx = i
			break
	if idx < 0:
		push_error("AbilityInterpreter._forfeit_agenda: card not found in corp score area")
		return
	var record: CardRecord = ctx.corp_score_area[idx] as CardRecord
	ctx.corp_score_area_cards.remove_at(idx)
	ctx.corp_score_area.remove_at(idx)
	if record != null:
		ctx.corp_discard.append(record)
	ctx.send_log("%s forfeits %s. (%d agenda point(s) remaining)" % [
		ctx.corp_name(), scored_agenda.display_name(), ctx.corp_agenda_points()
	])
	# Fire on_forfeit event for listeners
	await ctx.notify_event("on_forfeit", {
		"card": scored_agenda,
		"card_instance_id": scored_agenda.runtime_instance_id,
		"card_id": scored_agenda.card_id
	}, self)
	# Execute on_forfeit ability trigger (e.g. Greenmail gains 9cr)
	if ctx.has_meta("ability_registry"):
		var ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
		var on_forfeit_def = ab_reg.get_on_forfeit(scored_agenda.card_id)
		if on_forfeit_def != null:
			ctx.current_event_data = {
				"card": scored_agenda,
				"card_instance_id": scored_agenda.runtime_instance_id
			}
			await execute_trigger(on_forfeit_def as Dictionary, ctx)
			ctx.current_event_data = {}


func _derez_card(card: InstalledCard, ctx: GameContext) -> void:
	card.is_rezzed = false
	ctx.unregister_all_card_effects(card.runtime_instance_id)
	ctx.send_log("%s is derezzed." % card.display_name())
	await ctx.notify_event("on_derez", {
		"card": card,
		"card_instance_id": card.runtime_instance_id
	}, self)


func _cleanup_granted_subtypes(card: InstalledCard, ctx: GameContext) -> void:
	# If this program had granted subtypes to its host ice, remove them now.
	if card.granted_subtypes_to_host.is_empty() or card.hosted_on_id == "":
		return
	var host_ice := ctx.get_ice_by_instance_id(card.hosted_on_id)
	if host_ice == null:
		return
	for st in card.granted_subtypes_to_host:
		host_ice.extra_subtypes.erase(st)
	ctx.send_log("%s: removed granted subtypes [%s] from %s." % [
		card.display_name(), ", ".join(card.granted_subtypes_to_host), host_ice.display_name()
	])
	card.granted_subtypes_to_host.clear()


func _trash_installed_card(card: InstalledCard, ctx: GameContext) -> void:
	# If this card has hosted programs (ice with trojans, or daemon with hosted programs),
	# trash those first before removing the host.
	if not card.hosted_cards.is_empty():
		for hosted in card.hosted_cards.duplicate():
			var h: InstalledCard = hosted as InstalledCard
			if h == null:
				continue
			ctx.runner_rig.erase(h)  # no-op if not in runner_rig (daemon-hosted programs)
			ctx.unregister_all_card_effects(h.runtime_instance_id)
			if h.card_record != null:
				ctx.runner_discard.append(h.card_record)
			ctx.send_log("  %s trashed (host removed)." % h.display_name())
		card.hosted_cards.clear()

	# Remove from runner rig, from host ice, or from host daemon
	if card.hosted_on_id != "":
		# Clean up any subtypes this program granted to its host (e.g. Chromatophores)
		_cleanup_granted_subtypes(card, ctx)
		# Try ice first; fall back to any installed card (covers daemon hosts like Muse)
		var host_card: InstalledCard = ctx.get_ice_by_instance_id(card.hosted_on_id)
		if host_card == null:
			host_card = ctx.get_installed_card_by_instance_id(card.hosted_on_id)
		if host_card != null:
			host_card.hosted_cards.erase(card)
	else:
		ctx.runner_rig.erase(card)

	ctx.unregister_all_card_effects(card.runtime_instance_id)
	ctx.send_log("Trashed installed card: %s" % card.display_name())

func _draw_cards(subject: String, amount: int, ctx: GameContext) -> void:
	var deck: Array
	var hand: Array
	if subject == "corp":
		deck = ctx.corp_deck
		hand = ctx.corp_hand
	else:
		deck = ctx.runner_deck
		hand = ctx.runner_hand
	var drawn := 0
	for i in range(amount):
		if deck.is_empty():
			ctx.send_log("%s deck empty — cannot draw." % ctx.player_name(subject))
			break
		var card: CardRecord = deck.pop_front() as CardRecord
		hand.append({"card_id": card.id, "card_record": card})
		drawn += 1
	ctx.send_log("%s draws %d card(s)." % [ctx.player_name(subject), drawn])


# ── Play-operation-from-HQ shared implementation ─────────────────────────────
# Used by both "may_play_operation_from_hq" (Humanoid Resources) and the
# generic "play_operation_from_hq" (Sudden Commandment, etc.).
# source_label: human-readable card/context name for log messages.
# optional:     true → Corp may decline; false → must play if any operation exists.

func _do_play_operation_from_hq(source_label: String, optional: bool, ctx: GameContext,
		exclude_terminal: bool = false) -> void:
	# Gather affordable operations from HQ.
	var ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry if ctx.has_meta("ability_registry") else null
	var candidates: Array = []
	for entry in ctx.corp_hand:
		var e: Dictionary = entry as Dictionary
		var r: CardRecord  = e.get("card_record", null) as CardRecord
		if r == null or r.card_type != "operation":
			continue
		if ctx.corp_credits < max(0, r.cost):
			continue
		# Sudden Commandment restricts to non-terminal operations.
		if exclude_terminal and ab_reg != null and ab_reg.get_flag(r.id, "terminal"):
			continue
		candidates.append(entry)

	if candidates.is_empty():
		ctx.send_log("%s: no affordable operations in HQ." % source_label)
		return

	# Corp chooses which operation to play (null = decline when optional).
	var dm: Object = ctx.corp_decision_maker
	var chosen_entry: Variant = null
	if dm != null and dm.has_method("choose_card_from_hand"):
		chosen_entry = await dm.choose_card_from_hand(candidates, ctx)
	elif not optional:
		chosen_entry = candidates[0]

	if chosen_entry == null:
		ctx.send_log("%s: %s declines to play an operation." % [source_label, ctx.corp_name()])
		return

	var record: CardRecord = (chosen_entry as Dictionary).get("card_record", null) as CardRecord
	if record == null:
		return

	# Pay the operation's credit cost.
	var cost: int = max(0, record.cost)
	ctx.corp_credits -= cost
	ctx.corp_hand.erase(chosen_entry)
	ctx.send_log("%s: %s plays %s%s." % [
		source_label,
		ctx.corp_name(),
		record.title,
		(" for %d cr" % cost) if cost > 0 else " for free"
	])

	# Execute the operation's on_play effects.
	if ab_reg != null:
		var on_play_def = ab_reg.get_on_play(record.id)
		if on_play_def != null:
			ctx.corp_played_operation_this_turn = true
			await execute_trigger(on_play_def as Dictionary, ctx)
		else:
			ctx.send_log("%s: %s has no on_play effect." % [source_label, record.title])

	# Discard to Archives.
	ctx.corp_discard.append(record)


# ── Encounter action processing ───────────────────────────────────────────────
# Delegates to EncounterProcessor. Kept here so RunStateMachine and other
# callers need not change — the public signature is identical.

func process_encounter_action(action: Dictionary, encounter: EncounterState,
		ctx: GameContext, ability_registry: AbilityRegistry) -> bool:
	return await _encounter_processor.process(action, encounter, ctx, ability_registry, self)


# ── Encounter card ability execution (Step-2 cards) ──────────────────────────
# Called by EncounterProcessor when the runner chooses a use_encounter_ability action.

func execute_encounter_card_ability(card_id: String, mode_index: int,
		encounter: EncounterState, ctx: GameContext) -> void:
	var _eeca_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry \
		if ctx.has_meta("ability_registry") else null
	var card_def: Dictionary = _eeca_ab_reg._abilities.get(card_id, {}) as Dictionary \
		if _eeca_ab_reg != null else {}
	var ab_def: Dictionary   = card_def.get("encounter_ability", {}) as Dictionary
	var modes: Array         = ab_def.get("modes", []) as Array
	if mode_index < 0 or mode_index >= modes.size():
		push_error("execute_encounter_card_ability: bad mode index %d for '%s'" % [mode_index, card_id])
		return

	var mode: Dictionary = modes[mode_index] as Dictionary

	# ── Find the card in the runner's rig (or hosted on ice) ──────────────────
	var self_card: InstalledCard = null
	for _eeca_c in ctx.runner_rig:
		var _eeca_ic: InstalledCard = _eeca_c as InstalledCard
		if _eeca_ic != null and _eeca_ic.card_id == card_id:
			self_card = _eeca_ic
			break
	if self_card == null:
		for _eeca_srv in ctx.servers.values():
			for _eeca_ice in (_eeca_srv as Server).ice:
				for _eeca_h in (_eeca_ice as InstalledCard).hosted_cards:
					var _eeca_hi: InstalledCard = _eeca_h as InstalledCard
					if _eeca_hi != null and _eeca_hi.card_id == card_id:
						self_card = _eeca_hi
						break

	# ── Mark once-per-turn if applicable ─────────────────────────────────────
	var eeca_opt_key: String = mode.get("once_per_turn_key", "")
	if eeca_opt_key != "" and self_card != null:
		var eeca_full_key: String = self_card.runtime_instance_id + ":" + eeca_opt_key
		ctx.once_per_turn_triggered[eeca_full_key] = true

	# ── Pay costs ─────────────────────────────────────────────────────────────
	var eeca_credits: int = mode.get("cost_credits", 0)
	if eeca_credits > 0:
		ctx.runner_spend_credits(eeca_credits)
		ctx.send_log("[Encounter] %s spends %d cr." % [card_id, eeca_credits])

	var eeca_clicks: int = mode.get("cost_clicks", 0)
	if eeca_clicks > 0:
		ctx.runner_clicks -= eeca_clicks
		ctx.send_log("[Encounter] %s spends %d click(s)." % [card_id, eeca_clicks])

	var eeca_counter_cost: Dictionary = mode.get("cost_counter", {}) as Dictionary
	if not eeca_counter_cost.is_empty() and self_card != null:
		var eeca_ctype: String = eeca_counter_cost.get("type", "power")
		var eeca_camt:  int    = eeca_counter_cost.get("amount", 1)
		self_card.remove_counter(eeca_ctype, eeca_camt)
		ctx.send_log("[Encounter] %s spends %d %s counter(s)." % [card_id, eeca_camt, eeca_ctype])

	var eeca_cost_tag: int = mode.get("cost_tag", 0)
	if eeca_cost_tag > 0:
		ctx.runner_tags += eeca_cost_tag
		ctx.send_log("[Encounter] %s: Runner takes %d tag(s)." % [card_id, eeca_cost_tag])
		await ctx.notify_event("runner_receives_tag", {"amount": eeca_cost_tag}, self)

	# ── Execute effects ───────────────────────────────────────────────────────
	# Temporarily set current_event_data so _get_self_card() can find self_card.
	var eeca_prev_event_data: Dictionary = ctx.current_event_data.duplicate()
	if self_card != null:
		ctx.current_event_data["card_instance_id"] = self_card.runtime_instance_id

	for _eeca_eff in (mode.get("effects", []) as Array):
		var _eeca_e: Dictionary = _eeca_eff as Dictionary
		match _eeca_e.get("type", ""):

			"bypass_current_ice_flag":
				ctx.run_modifiers["bypass_current_ice"] = true
				ctx.send_log("[Encounter] %s: %s is bypassed." % [
					card_id, encounter.ice_card.display_name() if encounter.ice_card else "ice"])

			"bypass_if_ice_strength_lte":
				var threshold: int = (_eeca_e.get("params", {}) as Dictionary).get("threshold", 3)
				if encounter.effective_ice_strength() <= threshold:
					ctx.run_modifiers["bypass_current_ice"] = true
					ctx.send_log("[Encounter] %s: %s bypassed (str %d ≤ %d)." % [
						card_id, encounter.ice_card.display_name() if encounter.ice_card else "ice",
						encounter.effective_ice_strength(), threshold])
				else:
					ctx.send_log("[Encounter] %s: Ice strength is %d — bypass threshold is %d. Ability wasted." % [
						card_id, encounter.effective_ice_strength(), threshold])

			"bypass_rfg_self_any_ice":
				ctx.run_modifiers["bypass_current_ice"] = true
				# Remove self from game
				if self_card != null:
					ctx.runner_rig.erase(self_card)
					if self_card.hosted_on_id != "":
						var rfg_host: InstalledCard = ctx.get_ice_by_instance_id(self_card.hosted_on_id)
						if rfg_host != null:
							rfg_host.hosted_cards.erase(self_card)
					ctx.unregister_all_card_effects(self_card.runtime_instance_id)
					# RFG — do NOT add to discard
					ctx.send_log("[Encounter] %s: Removed from game — %s bypassed." % [
						card_id, encounter.ice_card.display_name() if encounter.ice_card else "ice"])

			"physarum_bypass_host_ice":
				# Physarum Entangler: pay 1cr per unbroken sub → bypass (non-barrier only).
				var physarum_unbroken: int = encounter.unbroken_indices().size()
				if physarum_unbroken == 0:
					# All subs already broken — bypass is still triggered
					ctx.run_modifiers["bypass_current_ice"] = true
					ctx.send_log("[Encounter] Physarum Entangler: all subs broken, ice bypassed.")
				else:
					var physarum_cost: int = physarum_unbroken * 1
					if ctx.runner_available_credits() < physarum_cost:
						ctx.send_log("[Encounter] Physarum Entangler: cannot afford %dcr to bypass." % physarum_cost)
					else:
						ctx.runner_spend_credits(physarum_cost)
						ctx.run_modifiers["bypass_current_ice"] = true
						ctx.send_log("[Encounter] Physarum Entangler: pays %dcr — %s bypassed." % [
							physarum_cost, encounter.ice_card.display_name() if encounter.ice_card else "ice"])

			"weaken_encountered_ice":
				var wamount: int = _eeca_e.get("amount", -2)
				encounter.strength_modifiers += wamount
				ctx.send_log("[Encounter] %s: %s gets %d str modifier (effective str %d)." % [
					card_id,
					encounter.ice_card.display_name() if encounter.ice_card else "ice",
					wamount, encounter.effective_ice_strength()])

			"trash_encountered_ice":
				# Arruaceiras Crew: trash the encountered ice (only if str ≤ 0).
				if encounter.effective_ice_strength() > 0:
					ctx.send_log("[Encounter] %s: Ice strength is %d — cannot trash." % [
						card_id, encounter.effective_ice_strength()])
				elif encounter.ice_card != null:
					var tei_ice: InstalledCard = encounter.ice_card
					var tei_server: Server = ctx.get_server(tei_ice.server_id)
					if tei_server != null:
						tei_server.ice.erase(tei_ice)
					ctx.unregister_all_card_effects(tei_ice.runtime_instance_id)
					if tei_ice.card_record != null:
						ctx.corp_discard.append(tei_ice.card_record)
					ctx.run_ended = true  # Ice is trashed — run ends
					ctx.send_log("[Encounter] %s: %s trashed (str %d). Run ends." % [
						card_id, tei_ice.display_name(), encounter.effective_ice_strength()])

	# Restore event data context
	ctx.current_event_data = eeca_prev_event_data

	# ── Trash self (e.g. arruaceiras_crew mode 2) ─────────────────────────────
	if mode.get("trash_self", false) and self_card != null:
		ctx.runner_rig.erase(self_card)
		if self_card.hosted_on_id != "":
			var ts_host: InstalledCard = ctx.get_ice_by_instance_id(self_card.hosted_on_id)
			if ts_host != null:
				ts_host.hosted_cards.erase(self_card)
		ctx.unregister_all_card_effects(self_card.runtime_instance_id)
		if self_card.card_record != null:
			ctx.runner_discard.append(self_card.card_record)
		ctx.send_log("[Encounter] %s is trashed (paid ability cost)." % self_card.display_name())


# ── Spree: move a trojan during a run ────────────────────────────────────────

func execute_spree_move_trojan(encounter: EncounterState, ctx: GameContext) -> void:
	# Spend 1 Spree counter → runner picks an installed trojan → runner picks
	# a piece of ice protecting the run server → trojan moves there.
	var smt_counters: int = ctx.run_modifiers.get("spree_counters", 0)
	if smt_counters <= 0:
		ctx.send_log("Spree: no counters remaining.")
		return

	# Collect all installed trojans (programs hosted on ice)
	var smt_trojans: Array = []
	for smt_rig in ctx.runner_rig:
		var smt_ic: InstalledCard = smt_rig as InstalledCard
		if smt_ic != null and smt_ic.hosted_on_id != "":
			smt_trojans.append(smt_ic)
	for smt_srv in ctx.servers.values():
		var smt_s: Server = smt_srv as Server
		for smt_ice in smt_s.ice:
			var smt_host_ice: InstalledCard = smt_ice as InstalledCard
			for smt_hosted in smt_host_ice.hosted_cards:
				var smt_h: InstalledCard = smt_hosted as InstalledCard
				if smt_h != null and not smt_trojans.has(smt_h):
					smt_trojans.append(smt_h)
	if smt_trojans.is_empty():
		ctx.send_log("Spree: no installed trojans to move.")
		return

	# Collect ice on the run server (derive server from current run or encounter ice)
	var smt_server_id: String = ctx.run_target_server
	if smt_server_id == "" and encounter != null and encounter.ice_card != null:
		smt_server_id = encounter.ice_card.server_id
	var smt_run_server: Server = ctx.get_server(smt_server_id) if smt_server_id != "" else null
	var smt_ice_candidates: Array = []
	if smt_run_server != null:
		for smt_ri in smt_run_server.ice:
			var smt_ric: InstalledCard = smt_ri as InstalledCard
			if smt_ric != null:
				smt_ice_candidates.append(smt_ric)
	if smt_ice_candidates.is_empty():
		ctx.send_log("Spree: no ice on this server to move a trojan onto.")
		return

	# Runner picks trojan to move
	var smt_chosen_trojan: InstalledCard = smt_trojans[0]
	if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_trash_from_rig"):
		smt_chosen_trojan = await ctx.runner_decision_maker.choose_trash_from_rig(smt_trojans, ctx)

	# Runner picks target ice
	var smt_target_ice: InstalledCard = smt_ice_candidates[0]
	if ctx.runner_decision_maker != null and ctx.runner_decision_maker.has_method("choose_target_ice"):
		smt_target_ice = await ctx.runner_decision_maker.choose_target_ice(smt_ice_candidates, "Spree", ctx)

	if smt_chosen_trojan == null or smt_target_ice == null:
		return

	# Remove from old host
	var smt_old_host: InstalledCard = ctx.get_ice_by_instance_id(smt_chosen_trojan.hosted_on_id)
	if smt_old_host != null:
		smt_old_host.hosted_cards.erase(smt_chosen_trojan)
	# Also remove from runner_rig if present there
	ctx.runner_rig.erase(smt_chosen_trojan)

	# Attach to new host
	smt_chosen_trojan.hosted_on_id = smt_target_ice.runtime_instance_id
	smt_target_ice.hosted_cards.append(smt_chosen_trojan)

	ctx.run_modifiers["spree_counters"] = smt_counters - 1
	ctx.send_log("Spree: moved %s to %s. (%d counter(s) remaining)" % [
		smt_chosen_trojan.display_name(),
		smt_target_ice.display_name(),
		ctx.run_modifiers["spree_counters"]
	])


# ── Modal ability execution ───────────────────────────────────────────────────
# Handles cards like Predictive Planogram where the player chooses between
# multiple effects. Supports a bonus_condition that auto-executes remaining
# modes when a condition is met (e.g. "if runner is tagged, do both").

func execute_modal_trigger(trigger_def: Dictionary, ctx: GameContext) -> void:
	var modes: Array      = trigger_def.get("modes", []) as Array
	var max_choices: int  = trigger_def.get("max_choices", 1)

	if modes.is_empty():
		return

	# Check bonus condition — may increase max_choices
	var bonus_def: Variant = trigger_def.get("bonus_condition", null)
	var bonus_active := false
	if bonus_def != null:
		bonus_active = _evaluate_condition(bonus_def as Dictionary, ctx)
		if bonus_active:
			ctx.send_log("Bonus condition met — all modes will execute.")
			max_choices = modes.size()

	# Filter modes whose per-mode conditions are not met, building a remapped
	# eligible list so the DM only sees valid options.  The original indices are
	# preserved so execution can reference the original modes array.
	var eligible_modes: Array = []      # subset of modes that pass their condition
	var eligible_original_idx: Array = [] # original index of each eligible mode
	for _emt_i in range(modes.size()):
		var _emt_m: Dictionary = modes[_emt_i] as Dictionary
		if _emt_m.has("condition"):
			if not _evaluate_condition(_emt_m["condition"] as Dictionary, ctx):
				continue
		eligible_modes.append(_emt_m)
		eligible_original_idx.append(_emt_i)

	if eligible_modes.is_empty():
		ctx.send_log("Modal: no eligible modes (all conditions failed).")
		return

	# Ask decision maker to choose from eligible modes.
	# "chooser" overrides the active player — used by Wildcat Strike where Corp
	# chooses even though the Runner is the active player.
	var chooser: String = trigger_def.get("chooser", ctx.active_player)
	var chosen_eligible_indices: Array = []
	var decision_maker: Object = ctx.corp_decision_maker if chooser == "corp" else ctx.runner_decision_maker
	if chooser == "corp":
		ctx.send_log("Corp chooses the effect of this card...")
	if decision_maker != null and decision_maker.has_method("choose_modes"):
		chosen_eligible_indices = await decision_maker.choose_modes(eligible_modes, max_choices, ctx)
	else:
		chosen_eligible_indices = [0]

	# Map eligible indices back to original mode indices
	var all_original_indices: Array = []
	for ei in chosen_eligible_indices:
		if ei >= 0 and ei < eligible_original_idx.size():
			var orig: int = eligible_original_idx[ei] as int
			if not all_original_indices.has(orig):
				all_original_indices.append(orig)

	# If bonus is active, also execute remaining eligible modes not yet chosen
	if bonus_active:
		for orig_i in eligible_original_idx:
			if not all_original_indices.has(orig_i):
				all_original_indices.append(orig_i)

	# Execute chosen modes in order
	for idx in all_original_indices:
		if idx < 0 or idx >= modes.size():
			continue
		var mode: Dictionary = modes[idx] as Dictionary
		ctx.send_log("Modal: executing '%s'." % mode.get("label", "mode %d" % idx))
		var effects: Array = mode.get("effects", []) as Array
		for effect in effects:
			await _execute_effect(effect as Dictionary, ctx, null)
