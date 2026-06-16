# HumanDecisionMaker.gd
extends RefCounted
class_name HumanDecisionMaker

# ── HumanDecisionMaker ────────────────────────────────────────────────────────
# Bridges the async decision_maker interface to the UI layer via proxy callables.
# Main.gd sets each proxy to a function that shows a UI prompt and awaits the
# player's button press.
#
# Required proxy callables (set by Main.gd before the game loop starts):
#   action_selected_proxy   — not needed; action_selected signal handles this
#   rez_proxy               — func(InstalledCard) -> bool
#   jack_out_proxy          — func() -> bool
#   break_subroutines_proxy — func(InstalledCard, Array) -> Array
#   trash_proxy             — func(CardRecord) -> bool

signal action_selected(action: GameAction)
signal encounter_action_selected(action: Dictionary)
signal mode_chosen(indices: Array)

var rez_proxy:               Callable
var jack_out_proxy:          Callable
var encounter_action_proxy:  Callable   # func(EncounterState) -> Dictionary
var trash_proxy:             Callable
var choose_modes_proxy:      Callable   # func(modes, max_choices) -> Array[int]
var choose_server_proxy:      Callable   # func(allowed_servers) -> String
var choose_card_from_hand_proxy:  Callable # func(hand) -> Dictionary
var host_ice_proxy:           Callable   # func(candidates: Array[InstalledCard]) -> InstalledCard
var choose_from_search_proxy:          Callable # func(candidates) -> CardRecord
var choose_payment_option_proxy:       Callable # func(options) -> Dictionary or null
var choose_take_tag_or_end_run_proxy:  Callable # func(amount: int) -> bool (true = end run)
var choose_pay_to_avoid_tag_proxy:     Callable # func(cost: int) -> bool (true = pay)
var ice_trash_ability_proxy:           Callable # func(ice: InstalledCard, ability: Dictionary) -> bool
var spend_click_to_continue_proxy:     Callable # func() -> bool (true = spend click, false = end run)


func choose_action(_ctx: GameContext) -> GameAction:
	var action: GameAction = await action_selected
	return action


func choose_rez(card: InstalledCard, _ctx: GameContext) -> bool:
	if rez_proxy.is_valid():
		return await rez_proxy.call(card)
	return false


func choose_jack_out(_ctx: GameContext) -> bool:
	if jack_out_proxy.is_valid():
		return await jack_out_proxy.call()
	return false


# Uprising: Euler / Odore — choose between an icebreaker's primary break
# interface and its alternative (free/conditional) interface when both are
# available for the encountered ice. Returns 0 for primary, 1 for alt.
var choose_break_interface_proxy: Callable  # func(breaker: InstalledCard, primary: Dictionary, alt: Dictionary, unbroken_count: int) -> int

func choose_break_interface(breaker: InstalledCard, primary: Dictionary, alt: Dictionary,
		unbroken_count: int, _ctx: GameContext) -> int:
	if choose_break_interface_proxy.is_valid():
		return await choose_break_interface_proxy.call(breaker, primary, alt, unbroken_count)
	# AI default: use the free alternative interface if it can break everything
	# unbroken in one activation; otherwise stick with the primary interface.
	if alt.get("cost_per_sub", 1) == 0 and unbroken_count <= alt.get("subs_per_use", 1):
		return 1
	return 0


func choose_encounter_action(encounter: EncounterState, _ctx: GameContext) -> Dictionary:
	if encounter_action_proxy.is_valid():
		return await encounter_action_proxy.call(encounter)
	# No proxy set — pass immediately (no breaking)
	return {"type": "done"}


func choose_trash(card: CardRecord, _ctx: GameContext) -> bool:
	if trash_proxy.is_valid():
		return await trash_proxy.call(card)
	return false


func choose_modes(modes: Array, max_choices: int, _ctx: GameContext) -> Array:
	if choose_modes_proxy.is_valid():
		return await choose_modes_proxy.call(modes, max_choices)
	# Default: choose first mode
	return [0]


func choose_server(allowed_servers: Array, _ctx: GameContext) -> String:
	if choose_server_proxy.is_valid():
		return await choose_server_proxy.call(allowed_servers)
	return allowed_servers[0] if not allowed_servers.is_empty() else "hq"


func choose_card_from_hand(hand: Array, _ctx: GameContext) -> Variant:
	if choose_card_from_hand_proxy.is_valid():
		return await choose_card_from_hand_proxy.call(hand)
	return hand[0] if not hand.is_empty() else null


func choose_from_search(candidates: Array, _ctx: GameContext) -> CardRecord:
	if choose_from_search_proxy.is_valid():
		return await choose_from_search_proxy.call(candidates)
	return candidates[0] as CardRecord if not candidates.is_empty() else null


var choose_flip_identity_proxy: Callable  # func(new_face_title: String) -> bool (true = flip)

# Runner is offered an optional identity flip.  Returns true if the player accepts.
func choose_flip_identity(new_face_title: String, _ctx: GameContext) -> bool:
	if choose_flip_identity_proxy.is_valid():
		return await choose_flip_identity_proxy.call(new_face_title)
	return true  # AI/fallback default: always flip when able


func choose_payment_option(options: Array, _ctx: GameContext) -> Variant:
	if choose_payment_option_proxy.is_valid():
		return await choose_payment_option_proxy.call(options)
	# Default: end the run (no proxy set)
	return null


# Funhouse encounter_ice: Runner chooses to take N tags or end the run.
# Returns true if the Runner wants to END the run, false to take the tags.
func choose_take_tag_or_end_run(amount: int, _ctx: GameContext) -> bool:
	if choose_take_tag_or_end_run_proxy.is_valid():
		return await choose_take_tag_or_end_run_proxy.call(amount)
	return false   # Default: take the tag, continue the run


# Funhouse subroutine / Public Trail: Runner may pay cost to avoid 1 tag.
# Returns true if the Runner pays, false to take the tag instead.
func choose_pay_to_avoid_tag(cost: int, _ctx: GameContext) -> bool:
	if choose_pay_to_avoid_tag_proxy.is_valid():
		return await choose_pay_to_avoid_tag_proxy.call(cost)
	return false   # Default: take the tag, don't pay


var choose_pay_to_avoid_damage_proxy: Callable  # func(cost, damage, type) -> bool

# Measured Response: Runner may pay cost credits to prevent N damage.
# Returns true if the Runner pays, false to take the damage.
func choose_pay_to_avoid_damage(cost: int, damage: int, damage_type: String, _ctx: GameContext) -> bool:
	if choose_pay_to_avoid_damage_proxy.is_valid():
		return await choose_pay_to_avoid_damage_proxy.call(cost, damage, damage_type)
	return cost <= _ctx.runner_credits   # Default: pay if affordable (damage avoidance is usually worth it)


# ── Shred: Corp may trash X HQ cards to keep an ETR ─────────────────────────

var choose_pay_shred_etr_proxy: Callable  # func(count: int) -> bool (true = pay)

# Shred interrupt: Corp may trash 'count' random HQ cards to end the run.
# Returns true if Corp pays (ETR stands), false to let the ETR be prevented.
func choose_pay_shred_etr(count: int, _ctx: GameContext) -> bool:
	if choose_pay_shred_etr_proxy.is_valid():
		return await choose_pay_shred_etr_proxy.call(count)
	return true   # Default: pay — preserving the ETR is usually worth it


# ── Choose card name (e.g. Complete Image chain damage) ──────────────────────

var choose_card_name_proxy: Callable  # func(ctx: GameContext) -> String

func choose_card_name(ctx: GameContext) -> String:
	if choose_card_name_proxy.is_valid():
		return await choose_card_name_proxy.call(ctx)
	return ""  # Default: blank name — card is unplayable without UI

# ── Generic optional ability (e.g. Cacophony end-of-turn counter spend) ──────

var choose_optional_ability_proxy: Callable  # func(prompt: String) -> bool

# Returns true if the Runner wants to activate the optional ability.
func choose_optional_ability(prompt: String, _ctx: GameContext) -> bool:
	if choose_optional_ability_proxy.is_valid():
		return await choose_optional_ability_proxy.call(prompt)
	return true   # Default: activate when available


# ── Generic yes/no prompt (e.g. Buffer Drive redirect, Mystic Maemi, mu_safecracker) ──

var choose_yes_no_proxy: Callable  # func(prompt: String) -> bool

# Returns true for "yes" on a generic optional yes/no decision.
func choose_yes_no(prompt: String, _ctx: GameContext) -> bool:
	if choose_yes_no_proxy.is_valid():
		return await choose_yes_no_proxy.call(prompt)
	return true   # Default: take the optional benefit when available


# ── AirbladeX (JSRF Ed.) interrupt windows ───────────────────────────────────

# Interrupt 1: Prevent 1 net damage during a run.
# Called before each point of net damage while a run is active and AirbladeX
# has power counters.  Returns true if the runner spends a counter to prevent.
var airbladex_prevent_damage_proxy: Callable  # func(damage_type, amount_remaining) -> bool

func use_airbladex_prevent_net_damage(damage_type: String, amount_remaining: int,
		_ctx: GameContext) -> bool:
	if airbladex_prevent_damage_proxy.is_valid():
		return await airbladex_prevent_damage_proxy.call(damage_type, amount_remaining)
	return false   # Default: don't spend (preserve counters for when-encountered)


# Interrupt 2: Prevent a "when encountered" ice ability from firing.
# Called before each on_encounter_self ability on the encountered ice while
# AirbladeX has power counters.  Returns true if the runner spends a counter.
var airbladex_prevent_when_encountered_proxy: Callable  # func(ice_card, ability_def) -> bool

func use_airbladex_prevent_when_encountered(ice_card: InstalledCard,
		ability_def: Dictionary, _ctx: GameContext) -> bool:
	if airbladex_prevent_when_encountered_proxy.is_valid():
		return await airbladex_prevent_when_encountered_proxy.call(ice_card, ability_def)
	return true   # Default: always prevent when available (when-encountered abilities are usually bad)


# ── Psi game bid ──────────────────────────────────────────────────────────────

var psi_bid_proxy: Callable   # func(max_bid: int) -> int

# Runner secretly chooses a psi bid of 0, 1, or 2 credits.
# max_bid is capped to the Runner's current credit total by the caller.
func choose_psi_bid(max_bid: int, _ctx: GameContext) -> int:
	if psi_bid_proxy.is_valid():
		return await psi_bid_proxy.call(max_bid)
	return 0   # Default: always bid 0


# ── Trace ──────────────────────────────────────────────────────────────────────

# Corp chooses how many credits to spend boosting a trace's strength
# (0..corp_credits). Used by: Winchester, Scapenet.
var choose_trace_boost_proxy: Callable  # func(base_strength: int) -> int

func choose_trace_boost(base_strength: int, _ctx: GameContext) -> int:
	if choose_trace_boost_proxy.is_valid():
		return await choose_trace_boost_proxy.call(base_strength)
	return 0   # Default: don't boost


# Runner chooses how many credits to spend boosting their link to beat a trace
# (0..runner_credits). Used by: Winchester, Scapenet.
var choose_trace_link_boost_proxy: Callable  # func(trace_strength: int, link: int) -> int

func choose_trace_link_boost(trace_strength: int, link: int, _ctx: GameContext) -> int:
	if choose_trace_link_boost_proxy.is_valid():
		return await choose_trace_link_boost_proxy.call(trace_strength, link)
	return 0   # Default: don't boost


# ── Pay-or-end-the-run ────────────────────────────────────────────────────────

# Runner may pay 'cost' credits to avoid the run ending.
# Used by: Gold Farmer, Cayambe Grid.
var choose_pay_to_avoid_etr_proxy: Callable  # func(cost: int) -> bool (true = pay)

func choose_pay_to_avoid_etr(cost: int, _ctx: GameContext) -> bool:
	if choose_pay_to_avoid_etr_proxy.is_valid():
		return await choose_pay_to_avoid_etr_proxy.call(cost)
	return cost <= _ctx.runner_credits   # Default: pay if affordable (avoid ending the run)


# ── Wall to Wall ───────────────────────────────────────────────────────────────

# Corp chooses 1 of the listed options (when Corp has another rezzed asset).
var choose_wall_to_wall_option_proxy: Callable  # func(choices: Array) -> String

func choose_wall_to_wall_option(choices: Array, _ctx: GameContext) -> String:
	if choose_wall_to_wall_option_proxy.is_valid():
		return await choose_wall_to_wall_option_proxy.call(choices)
	return choices[0] if not choices.is_empty() else ""


# Corp chooses up to `max_count` distinct options, in order (no other rezzed assets).
var choose_wall_to_wall_options_multi_proxy: Callable  # func(choices: Array, max_count: int) -> Array

func choose_wall_to_wall_options_multi(choices: Array, max_count: int, _ctx: GameContext) -> Array:
	if choose_wall_to_wall_options_multi_proxy.is_valid():
		return await choose_wall_to_wall_options_multi_proxy.call(choices, max_count)
	return choices.slice(0, max_count)


# ── Bigger Picture: Corp chooses how many tags to remove ─────────────────────

var choose_tags_to_remove_proxy: Callable  # func(max_count: int) -> int

func choose_tags_to_remove(max_count: int, _ctx: GameContext) -> int:
	if choose_tags_to_remove_proxy.is_valid():
		return await choose_tags_to_remove_proxy.call(max_count)
	return max_count   # Default: remove all (maximum drain)


# ── BANGUN: Corp chooses whether to install an agenda faceup ─────────────────

var choose_install_faceup_proxy: Callable   # func(card_record: CardRecord) -> bool

# Returns true if the Corp wants to install the given agenda faceup.
func choose_install_faceup(card_record: CardRecord, _ctx: GameContext) -> bool:
	if choose_install_faceup_proxy.is_valid():
		return await choose_install_faceup_proxy.call(card_record)
	return true   # Default: install faceup (maximises the punishment threat)


# ── Touch-ups: Corp chooses a runner card type to shuffle back ────────────────

var choose_runner_card_type_proxy: Callable  # func(types: Array) -> String

func choose_runner_card_type(types: Array, _ctx: GameContext) -> String:
	if choose_runner_card_type_proxy.is_valid():
		return await choose_runner_card_type_proxy.call(types)
	return ""   # Empty string → effect uses its own AI fallback


# ── Sabotage (Corp AI) ────────────────────────────────────────────────────────

# Not normally called on a HumanDecisionMaker (Corp is AI), but provided for
# completeness in case a human Corp is ever wired up.
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


func choose_window_action(ctx: GameContext, actor: String, can_rez_ice: bool) -> GameAction:
	# Human Corp player: show rez prompt for the approached ice or upgrades.
	# Human Runner player: pass for now — paid ability selection is a future feature.
	if actor == "corp" and can_rez_ice and rez_proxy.is_valid():
		# Find the first unrezzed ice on the target server to offer rezzing
		var target_server: Server = ctx.get_server(ctx.run_target_server)
		if target_server != null:
			for ice in target_server.ice:
				var c: InstalledCard = ice as InstalledCard
				if not c.is_rezzed:
					var should_rez: bool = await rez_proxy.call(c)
					if should_rez:
						var iid: String = c.get("runtime_instance_id") if c.get("runtime_instance_id") != null else ""
						return GameAction.rez_card(c.card_id, iid)
				break  # only ask about the outermost unrezzed piece

	elif actor == "corp" and not can_rez_ice and rez_proxy.is_valid():
		# Offer to rez upgrades in the target server root
		var target_server: Server = ctx.get_server(ctx.run_target_server)
		if target_server != null:
			for root_card in target_server.root:
				var c: InstalledCard = root_card as InstalledCard
				if not c.is_rezzed and c.card_record != null and c.card_record.card_type == "upgrade":
					var should_rez: bool = await rez_proxy.call(c)
					if should_rez:
						var iid: String = c.get("runtime_instance_id") if c.get("runtime_instance_id") != null else ""
						return GameAction.rez_card(c.card_id, iid)

	# Corp ice trash ability (e.g. M.I.C.: [trash] ice → Runner spends [click] or run ends).
	if actor == "corp" and not ctx.corp_ice_trash_abilities_available.is_empty() and \
			ice_trash_ability_proxy.is_valid():
		for _ita_entry in ctx.corp_ice_trash_abilities_available:
			var _ita_e: Dictionary = _ita_entry as Dictionary
			var _ita_ice: InstalledCard = _ita_e.get("card", null) as InstalledCard
			var _ita_ab: Dictionary     = _ita_e.get("ability", {}) as Dictionary
			if _ita_ice == null:
				continue
			var use_it: bool = await ice_trash_ability_proxy.call(_ita_ice, _ita_ab)
			if use_it:
				return GameAction.use_ice_trash_ability(_ita_ice.runtime_instance_id, _ita_ice.card_id)

	return GameAction.pass_window()


func choose_spend_click_to_continue(_ctx: GameContext) -> bool:
	if spend_click_to_continue_proxy.is_valid():
		return await spend_click_to_continue_proxy.call()
	return false  # Default: do not spend — accept run ending


func choose_host_ice(ctx: GameContext) -> InstalledCard:
	# Gather all installed ice across all Corp servers
	var candidates: Array = []
	for server in ctx.servers.values():
		for ice in (server as Server).ice:
			candidates.append(ice as InstalledCard)

	if candidates.is_empty():
		return null

	# For now, default to first available ice; UI prompt will be wired via proxy
	if host_ice_proxy.is_valid():
		return await host_ice_proxy.call(candidates, ctx)

	return candidates[0]


func choose_target_ice(candidates: Array, card_name: String, _ctx: GameContext) -> InstalledCard:
	if candidates.is_empty():
		return null
	if host_ice_proxy.is_valid():
		var prompt: String = "Choose a piece of ice to target with %s:" % card_name
		return await host_ice_proxy.call(candidates, _ctx, prompt)
	return candidates[0]


var ice_swap_proxy: Callable   # func(eligible_servers: Array) -> Variant

func choose_ice_swap(eligible_servers: Array, _ctx: GameContext) -> Variant:
	if ice_swap_proxy.is_valid():
		return await ice_swap_proxy.call(eligible_servers)
	return null   # decline by default


var carnivore_proxy: Callable   # func(card_record: CardRecord) -> bool

func choose_carnivore(card_record: CardRecord, _ctx: GameContext) -> bool:
	if carnivore_proxy.is_valid():
		return await carnivore_proxy.call(card_record)
	return false


var choose_access_target_proxy: Callable   # func(candidates: Array) -> Variant

func choose_access_target(candidates: Array, _ctx: GameContext) -> Variant:
	if choose_access_target_proxy.is_valid():
		return await choose_access_target_proxy.call(candidates)
	return candidates[0] if not candidates.is_empty() else null


var choose_spend_counter_amount_proxy: Callable  # func(card, counter_type, max_amount) -> int

# Runner chooses how many counters to spend from a card (0 = decline, max = spend all).
func choose_spend_counter_amount(card: InstalledCard, counter_type: String, max_amount: int, _ctx: GameContext) -> int:
	if choose_spend_counter_amount_proxy.is_valid():
		return await choose_spend_counter_amount_proxy.call(card, counter_type, max_amount)
	return max_amount   # Default: spend all available


var choose_trash_from_rig_proxy: Callable  # func(candidates: Array[InstalledCard]) -> InstalledCard

# Runner chooses which installed card to trash (forced by ice subroutine effect).
func choose_trash_from_rig(candidates: Array, _ctx: GameContext) -> InstalledCard:
	if choose_trash_from_rig_proxy.is_valid():
		return await choose_trash_from_rig_proxy.call(candidates)
	return candidates[0] as InstalledCard if not candidates.is_empty() else null


var choose_programs_to_host_proxy: Callable  # func(candidates: Array[hand entries]) -> Array[hand entries]

# Runner chooses which programs from their grip to stage on Madani.
# Returns an array of hand-entry Dicts; may be empty to decline.
func choose_programs_to_host(candidates: Array, _ctx: GameContext) -> Array:
	if choose_programs_to_host_proxy.is_valid():
		return await choose_programs_to_host_proxy.call(candidates)
	# AI default: stage all programs immediately
	return candidates.duplicate()


var choose_from_heap_proxy: Callable  # func(candidates: Array[CardRecord]) -> CardRecord or null

# Runner chooses a card from their heap (discard pile) to act on.
# Returns null if the runner declines (for optional effects).
func choose_from_heap(candidates: Array, _ctx: GameContext) -> CardRecord:
	if choose_from_heap_proxy.is_valid():
		return await choose_from_heap_proxy.call(candidates)
	return candidates[0] as CardRecord if not candidates.is_empty() else null


var choose_multiple_from_heap_proxy: Callable  # func(candidates: Array[CardRecord], max_count: int) -> Array[CardRecord]

# Runner chooses up to max_count cards from a list of heap candidates
# (e.g. Harmony AR Therapy: up to 5 cards with different titles).
# AI default: greedily take up to max_count candidates in the order given
# (callers pre-filter for distinct titles etc. as needed).
func choose_multiple_from_heap(candidates: Array, max_count: int, _ctx: GameContext) -> Array:
	if choose_multiple_from_heap_proxy.is_valid():
		return await choose_multiple_from_heap_proxy.call(candidates, max_count)
	if candidates.size() <= max_count:
		return candidates.duplicate()
	return candidates.slice(0, max_count)


var choose_forfeit_agenda_proxy: Callable   # func(candidates: Array[InstalledCard]) -> InstalledCard or null

# Corp chooses a scored agenda to forfeit, or returns null to decline (for optional forfeits).
func choose_forfeit_agenda(candidates: Array, _ctx: GameContext) -> InstalledCard:
	if choose_forfeit_agenda_proxy.is_valid():
		return await choose_forfeit_agenda_proxy.call(candidates)
	return null   # Default: decline to forfeit


var choose_derez_target_proxy: Callable   # func(candidates: Array[InstalledCard]) -> InstalledCard

func choose_derez_target(candidates: Array, _ctx: GameContext) -> InstalledCard:
	if choose_derez_target_proxy.is_valid():
		return await choose_derez_target_proxy.call(candidates)
	# Default: derez the most expensive rezzed card (AI heuristic)
	var best: InstalledCard = candidates[0] as InstalledCard
	for c in candidates:
		var ic: InstalledCard = c as InstalledCard
		if ic.card_record != null and best.card_record != null:
			if ic.card_record.cost > best.card_record.cost:
				best = ic
	return best


# ── Semak-samun: suffer damage or end the run ─────────────────────────────────

var choose_from_runner_score_proxy: Callable   # func(candidates: Array[CardRecord]) -> CardRecord

# Corp chooses which agenda to take from the Runner's score area (IP Enforcement).
func choose_from_runner_score(candidates: Array, _ctx: GameContext) -> CardRecord:
	if choose_from_runner_score_proxy.is_valid():
		return await choose_from_runner_score_proxy.call(candidates)
	# Default: take the highest-value agenda
	var best: CardRecord = candidates[0] as CardRecord
	for c in candidates:
		var cr: CardRecord = c as CardRecord
		if cr != null and cr.agenda_points > best.agenda_points:
			best = cr
	return best


var choose_suffer_damage_or_etr_proxy: Callable   # func(amount: int, type: String) -> bool (true = take damage)

# Runner chooses to suffer N damage (and continue the run) or end the run.
# Returns true if the runner opts to take the damage.
func choose_suffer_damage_or_etr(amount: int, damage_type: String, _ctx: GameContext) -> bool:
	if choose_suffer_damage_or_etr_proxy.is_valid():
		return await choose_suffer_damage_or_etr_proxy.call(amount, damage_type)
	# Default: take damage if grip is large enough to survive
	return _ctx.runner_hand.size() >= amount


# ── Discard-to-hand-limit ─────────────────────────────────────────────────────

# Proxy set by Main.gd: func(hand: Array, excess: int) -> Array[Dictionary]
# Returns an array of hand-entry Dicts the player chose to discard.
# May return fewer entries than excess (caller loops until satisfied).
var choose_subs_to_break_proxy: Callable   # func(candidates: Array[int], max_count: int, encounter: EncounterState) -> Array[int]

# Runner chooses which subroutine indices to target when a break_all action cannot
# cover every unbroken sub (e.g. Boomerang's 2-sub cap, or partial-credit break).
# candidates — Array[int] of unbroken sub indices available to target
# max_count  — how many must be chosen (equals the number the breaker can break)
# Returns    — Array[int] of the chosen indices (subset of candidates, length == max_count)
func choose_subs_to_break(candidates: Array, max_count: int,
		encounter: EncounterState, _ctx: GameContext) -> Array:
	if choose_subs_to_break_proxy.is_valid():
		return await choose_subs_to_break_proxy.call(candidates, max_count, encounter)
	# No proxy — return empty so EncounterProcessor falls through to its own heuristic.
	return []


var choose_programs_to_trash_for_mu_proxy: Callable

# Runner chooses which programs to trash to bring MU back within the limit.
# programs  — Array[InstalledCard] of installed programs with memory_cost > 0
# excess_mu — MU that must be freed (chosen programs must total >= this)
# Returns   — Array[InstalledCard] to trash
func choose_programs_to_trash_for_mu(programs: Array, excess_mu: int, _ctx: GameContext) -> Array:
	if choose_programs_to_trash_for_mu_proxy.is_valid():
		return await choose_programs_to_trash_for_mu_proxy.call(programs, excess_mu)
	return []


var choose_discard_to_hand_limit_proxy: Callable

# Player (human runner or corp) chooses which cards to discard during their discard phase.
# hand     — duplicate of current hand (Array of {card_id, card_record} Dicts)
# excess   — number of cards that need to be discarded
# Returns  — Array of hand-entry Dicts to discard (may contain 1..excess entries)
func choose_discard_to_hand_limit(hand: Array, excess: int, _ctx: GameContext) -> Array:
	if choose_discard_to_hand_limit_proxy.is_valid():
		return await choose_discard_to_hand_limit_proxy.call(hand, excess)
	# Fallback: discard the first `excess` cards (TurnManager heuristic takes over if empty)
	return []


# ── Card ordering (Cataloguer R&D reorder, Burner HQ reveal placement) ───────

var choose_card_order_proxy: Callable  # func(cards: Array[CardRecord]) -> Array[CardRecord]

# Runner arranges the provided cards in their desired order.
# Returns the same cards in a (possibly reordered) array.
func choose_card_order(cards: Array, _ctx: GameContext) -> Array:
	if choose_card_order_proxy.is_valid():
		return await choose_card_order_proxy.call(cards)
	return cards.duplicate()  # AI/fallback: keep original order


var choose_top_or_bottom_proxy: Callable  # func(card: CardRecord) -> String ("top"/"bottom")

# Runner places a single card either on top or bottom of a deck.
# Returns "top" or "bottom".
func choose_top_or_bottom(card: CardRecord, context_label: String, _ctx: GameContext) -> String:
	if choose_top_or_bottom_proxy.is_valid():
		return await choose_top_or_bottom_proxy.call(card, context_label)
	return "bottom"  # AI default: hide it at the bottom


# ── Parhelion: Charge ─────────────────────────────────────────────────────────

var choose_card_to_charge_proxy: Callable  # func(candidates: Array[InstalledCard]) -> InstalledCard

# Runner picks one installed card with ≥1 power counter to add 1 power counter to.
# Returns null to decline (charge is always optional per card text).
func choose_card_to_charge(candidates: Array, _ctx: GameContext) -> InstalledCard:
	if choose_card_to_charge_proxy.is_valid():
		return await choose_card_to_charge_proxy.call(candidates)
	# Fallback: pick the card with the most power counters (maximise return on charge).
	if candidates.is_empty():
		return null
	var best: InstalledCard = candidates[0] as InstalledCard
	for c in candidates:
		var ic: InstalledCard = c as InstalledCard
		if ic != null and ic.get_counter("power") > best.get_counter("power"):
			best = ic
	return best
