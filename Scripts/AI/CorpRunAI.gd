class_name CorpRunAI
extends RefCounted

# ── CorpRunAI ─────────────────────────────────────────────────────────────────
# Heuristic Corp decision maker for choices that arise during a run.
# Implements the run-time half of the Corp decision interface.
#
# Turn-time decisions (what to install, when to advance, what to play) live
# in CorpTurnAI, which is built when the turn manager exists.
#
# Interface expected by RunStateMachine:
#   choose_rez(card: InstalledCard, ctx: GameContext) -> bool

# The minimum credits the Corp tries to keep in reserve after rezzing.
# Rezzing below this floor risks being unable to rez more important ice later.
const CREDIT_FLOOR := 2

# Minimum strength an ice must have to be considered worth rezzing.
# Strength-0 ice with no implemented subroutines is not worth the cost.
const MIN_USEFUL_STRENGTH := 1

var ability_registry: AbilityRegistry
var silent: bool = false


func _init(registry: AbilityRegistry) -> void:
	ability_registry = registry


# ── Run-time interface ────────────────────────────────────────────────────────

# Called by RunStateMachine during Approach Ice (for the approached ice)
# and during Movement (for non-ice cards like upgrades).
func choose_rez(card: InstalledCard, ctx: GameContext) -> bool:
	if card.is_rezzed:
		return false  # already rezzed, nothing to decide

	if card.card_record == null:
		return false  # no data, can't evaluate

	if card.zone == "ice":
		return _should_rez_ice(card, ctx)
	else:
		return _should_rez_non_ice(card, ctx)


# ── Ice rez heuristic ─────────────────────────────────────────────────────────

func _should_rez_ice(card: InstalledCard, ctx: GameContext) -> bool:
	var record: CardRecord = card.card_record
	# Use the same cost formula as RunStateMachine._rez_card so the decision
	# never diverges from what the engine will actually charge.
	var rez_cost: int = ctx.query_rez_cost(card) + ctx.run_modifiers.get("extra_rez_cost", 0)

	# Gate 1: can we afford it?
	if ctx.corp_credits < rez_cost:
		_log("AI: cannot afford to rez %s (costs %d, have %d)" % [
			record.title, rez_cost, ctx.corp_credits])
		return false

	# Gate 2: will we stay above the credit floor?
	# Exception: never refuse to rez ICE that is the only thing standing between
	# the runner and an immediate agenda steal — a stolen agenda is permanent.
	if ctx.corp_credits - rez_cost < CREDIT_FLOOR and not _ice_protects_agenda_remote(card, ctx):
		_log("AI: rezzing %s would drop below credit floor — holding." % record.title)
		return false

	# Gate 3: is this ice worth rezzing?
	if not _ice_is_worth_rezzing(card):
		_log("AI: %s is not worth rezzing (no useful subroutines)." % record.title)
		return false

	# Gate 4: does the runner have a breaker that trivially handles this ice?
	if _runner_can_trivially_break(card, ctx):
		_log("AI: runner can trivially break %s — considering bluff." % record.title)
		# For now: rez anyway. Future enhancement: sometimes bluff unrezzed.
		# Fall through to rez.

	# Gate 5: strategic opportunity cost — is there a better unrezzed ice
	# elsewhere that we cannot afford if we spend these credits now?
	if _better_rez_opportunity_exists(card, ctx):
		return false

	_log("AI: rezzing %s for %d credits." % [record.title, rez_cost])
	return true


func _ice_is_worth_rezzing(card: InstalledCard) -> bool:
	var record: CardRecord = card.card_record

	# Ice with meaningful strength is worth rezzing.
	if record.strength >= MIN_USEFUL_STRENGTH:
		return true

	# Strength-0 ice is worth rezzing only if it has implemented subroutines.
	var subroutines: Array = ability_registry.get_subroutines(card.card_record.id)
	if not subroutines.is_empty():
		return true

	# No strength, no subroutines — not worth the cost.
	return false


func _runner_can_trivially_break(card: InstalledCard, ctx: GameContext) -> bool:
	# AI breakers (e.g. Mayfly) can interact with any ice type regardless of subtype.
	for rig_card in ctx.runner_rig:
		var rc: InstalledCard = rig_card as InstalledCard
		if rc.card_record != null and rc.card_record.has_subtype("ai"):
			return true

	# Standard subtype matching: fracter/barrier, killer/sentry, decoder/code_gate.
	var record: CardRecord = card.card_record
	var breaker_for_subtype := {
		"barrier":   "fracter",
		"sentry":    "killer",
		"code_gate": "decoder",
	}
	for subtype in record.subtypes:
		var needed_breaker: String = breaker_for_subtype.get(subtype, "")
		if needed_breaker == "":
			continue
		for rig_card in ctx.runner_rig:
			var rc: InstalledCard = rig_card as InstalledCard
			if rc.card_record != null and rc.card_record.has_subtype(needed_breaker):
				return true

	return false


# ── Non-ice rez heuristic ─────────────────────────────────────────────────────

func _should_rez_non_ice(card: InstalledCard, ctx: GameContext) -> bool:
	var record: CardRecord = card.card_record
	var rez_cost: int = ctx.query_rez_cost(card) + ctx.run_modifiers.get("extra_rez_cost", 0)

	# Gate 1: can we afford it?
	if ctx.corp_credits < rez_cost:
		return false

	# Gate 2: stay above credit floor.
	if ctx.corp_credits - rez_cost < CREDIT_FLOOR:
		return false

	# Upgrades that fire during runs (like Manegarm Skunkworks) are high value.
	# For now: always rez non-ice if we pass the credit gates.
	# Future enhancement: evaluate specific upgrade abilities.
	_log("AI: rezzing upgrade %s for %d credits." % [record.title, rez_cost])
	return true


# ── Helpers ───────────────────────────────────────────────────────────────────

func _log(message: String) -> void:
	if not silent:
		print("[CorpRunAI] " + message)


# Returns true when this ICE is the outermost layer protecting a remote server
# that contains an unscored agenda.  Used to bypass the credit floor: the Corp
# should always rez ICE in front of an accessible agenda rather than let the
# runner steal it for free just to preserve a credit buffer.
func _ice_protects_agenda_remote(ice: InstalledCard, ctx: GameContext) -> bool:
	if ice.server_id in ["rd", "hq", "archives"]:
		return false   # centrals: apply floor normally
	var server: Server = ctx.get_server(ice.server_id)
	if server == null:
		return false
	for card_any in server.root:
		var ic: InstalledCard = card_any as InstalledCard
		if ic != null and ic.card_record != null and ic.card_record.is_agenda():
			return true
	return false


# ── Lifetime-value ice rezzing ────────────────────────────────────────────────
#
# Ice that is rezzed persists. Every future run through this server will have
# to deal with it. The correct comparison is therefore:
#
#   rez if  lifetime_value(ice) >= rez_cost
#
# where lifetime_value = per_encounter_runner_tax × expected_encounter_count.
#
# This replaces the old flat-threshold heuristic that was too conservative
# because it only considered the immediate encounter.

func should_rez_ice(ice: InstalledCard, ctx: GameContext) -> bool:
	var rez_cost: int = ctx.query_rez_cost(ice) + ctx.run_modifiers.get("extra_rez_cost", 0)

	# Free to rez — always worth it.
	if rez_cost <= 0:
		_log("AI: rezzing %s for free." % ice.card_record.title)
		return true

	# Hard gate: cannot afford it.
	if ctx.corp_credits < rez_cost:
		return false

	# Hard gate: must stay above dynamic credit floor.
	# Exception: never hold a rez just to maintain liquidity when the runner is
	# approaching a server with an agenda — a stolen agenda is worth far more
	# than any credit buffer.
	if ctx.corp_credits - rez_cost < _dynamic_credit_floor(ctx) \
			and not _ice_protects_agenda_remote(ice, ctx):
		_log("AI: rezzing %s would breach credit floor — holding." % ice.card_record.title)
		return false

	# Quality gate: strength-0 ice with no subroutines is never worth it.
	if not _ice_is_worth_rezzing(ice):
		return false

	# Lifetime-value calculation.
	var tax: float = _estimate_runner_tax_per_encounter(ice, ctx)
	var encounters: float = _estimate_remaining_encounter_count(ice, ctx)
	var lifetime_value: float = tax * encounters

	_log("AI: %s — rez_cost=%d  tax/enc=%.1f  enc=%.1f  LTV=%.1f" % [
		ice.card_record.title, rez_cost, tax, encounters, lifetime_value])

	# Rez if the ice will pay for itself over its expected lifetime.
	# We add a small urgency bonus when the runner is poor (they may not be
	# able to break it at all this run, making the immediate encounter free).
	var urgency_bonus: float = 0.0
	if ctx.runner_credits <= rez_cost:
		urgency_bonus = float(rez_cost) * 0.5   # runner likely can't break right now
	if ctx.runner_credits == 0:
		urgency_bonus = float(rez_cost)          # runner is broke — definitely rez

	if not (lifetime_value + urgency_bonus) >= float(rez_cost):
		return false

	# Strategic opportunity cost: don't spend here if a higher-priority ice
	# elsewhere would be unaffordable as a result.
	if _better_rez_opportunity_exists(ice, ctx):
		return false

	return true


# Estimate how many credits the runner will spend (or be forced to spend) each
# time they encounter this ice, assuming they use their best available breaker.
func _estimate_runner_tax_per_encounter(ice: InstalledCard, ctx: GameContext) -> float:
	var record: CardRecord = ice.card_record
	var strength: int = record.strength
	var sub_count: int = ability_registry.get_subroutines(ice.card_id).size()

	# Find the runner's best breaker for this ice type.
	var breaker := _find_best_breaker(ice, ctx)
	if breaker == null:
		# No breaker installed: runner must jack out or face full subroutine consequences.
		# Model as: strength + 2 per subroutine + 2 for the threat itself.
		return float(strength + sub_count * 2 + 2)

	# Breaker installed: estimate the credit cost to boost + break.
	var b_record: CardRecord = breaker.card_record
	var b_abilities: Dictionary = ability_registry._abilities.get(b_record.id, {})

	var boost_cost: float = 0.0
	var break_cost: float = 0.0

	var boost_info: Dictionary = b_abilities.get("boost", {})
	if not boost_info.is_empty():
		var cost_per_boost: float = float(boost_info.get("cost", 1))
		var str_per_boost: float = float(boost_info.get("strength_gained", 1))
		if str_per_boost > 0.0:
			var breaker_str: int = b_record.strength
			var str_needed: int = max(0, strength - breaker_str)
			var boosts_needed: float = ceil(float(str_needed) / str_per_boost)
			boost_cost = boosts_needed * cost_per_boost

	var break_info: Dictionary = b_abilities.get("break", {})
	if not break_info.is_empty():
		var cost_per_sub: float = float(break_info.get("cost_per_sub", 1))
		break_cost = float(sub_count) * cost_per_sub
	elif sub_count > 0:
		break_cost = float(sub_count)   # fallback: 1 credit per sub

	var total: float = boost_cost + break_cost
	# Floor at 1 so even cheap-to-break ice is never valued at zero.
	return max(1.0, total)


# Find the runner's installed breaker best suited to handle this ice.
# Returns null if no matching breaker is installed.
func _find_best_breaker(ice: InstalledCard, ctx: GameContext) -> InstalledCard:
	var record: CardRecord = ice.card_record
	var subtype_map := {
		"barrier":   "fracter",
		"sentry":    "killer",
		"code_gate": "decoder",
	}

	var needed_type := ""
	for subtype in record.subtypes:
		if subtype_map.has(subtype):
			needed_type = subtype_map[subtype]
			break

	var best: InstalledCard = null
	var best_tax: float = INF

	for rig_entry in ctx.runner_rig:
		var rc: InstalledCard = rig_entry as InstalledCard
		if rc == null or rc.card_record == null:
			continue
		var is_match := false
		if rc.card_record.has_subtype("ai"):
			is_match = true
		elif needed_type != "" and rc.card_record.has_subtype(needed_type):
			is_match = true
		if not is_match:
			continue
		# Pick the breaker with the lowest estimated break cost (best for runner).
		var b_abilities: Dictionary = ability_registry._abilities.get(rc.card_record.id, {})
		var cost_per_sub: float = float(b_abilities.get("break", {}).get("cost_per_sub", 1.0))
		if cost_per_sub < best_tax:
			best_tax = cost_per_sub
			best = rc

	return best


# Estimate how many times a runner will encounter this ice over the game.
# Centrals are run more often; empty remotes are rarely revisited.
func _estimate_remaining_encounter_count(ice: InstalledCard, ctx: GameContext) -> float:
	var server_id: String = ice.server_id
	if server_id in ["hq", "rd", "archives"]:
		return 3.0   # centrals are targeted repeatedly throughout the game

	var server: Server = ctx.get_server(server_id)
	if server != null and server.get_agenda_or_asset() != null:
		return 2.5   # active remote with something worth stealing — contested
	return 1.5       # empty or low-value remote — may only be run once


# Credit floor scales up when the Corp has multiple unrezzed ice,
# so we don't blow our budget on the first piece and have nothing left.
func _dynamic_credit_floor(ctx: GameContext) -> int:
	var unrezzed := 0
	for server in ctx.servers.values():
		var s: Server = server as Server
		for ice_entry in s.ice:
			var c: InstalledCard = ice_entry as InstalledCard
			if not c.is_rezzed:
				unrezzed += 1
	return CREDIT_FLOOR + (unrezzed / 3)


# ── Strategic rez: opportunity-cost comparison ────────────────────────────────

# Returns true if the Corp should DEFER rezzing `this_ice` because there is
# another unrezzed ice on a more threatened server with better
# protection-per-credit, and we cannot afford both.
#
# The test: for every other unrezzed ice that we could NOT still afford after
# rezzing `this_ice`, compare their combined priority scores
#   priority = _rez_value_per_credit × _server_threat_estimate
# Defer if any alternative beats this ice's priority by at least DEFER_MARGIN.
const DEFER_MARGIN := 1.30   # alternative must be ≥30% better to justify holding

func _better_rez_opportunity_exists(this_ice: InstalledCard, ctx: GameContext) -> bool:
	var this_cost:     int   = ctx.query_rez_cost(this_ice)
	var this_priority: float = _rez_value_per_credit(this_ice, ctx) * \
							   _server_threat_estimate(this_ice.server_id, ctx)
	var floor: int = _dynamic_credit_floor(ctx)

	for server_entry in ctx.servers.values():
		var s: Server = server_entry as Server
		for ice_entry in s.ice:
			var other: InstalledCard = ice_entry as InstalledCard
			if other == null or other == this_ice or other.is_rezzed:
				continue
			if other.card_record == null:
				continue
			var other_cost: int = ctx.query_rez_cost(other)
			if other_cost <= 0:
				continue   # free to rez — never blocks us

			# Only matters if rezzing `this_ice` would leave us unable to
			# rez `other` while staying above the credit floor.
			var credits_after_this: int = ctx.corp_credits - this_cost
			if credits_after_this >= other_cost + floor:
				continue   # can afford both — no conflict

			# We cannot afford both.  Compare priority scores.
			var other_priority: float = _rez_value_per_credit(other, ctx) * \
										_server_threat_estimate(other.server_id, ctx)

			if other_priority >= this_priority * DEFER_MARGIN:
				_log("AI: deferring %s (pri=%.2f) — saving for %s on %s (pri=%.2f)" % [
					this_ice.card_record.title, this_priority,
					other.card_record.title,    other.server_id,
					other_priority])
				return true

	return false


# Lifetime-value-per-credit: a dimensionless efficiency score used to rank
# unrezzed ice when comparing opportunity cost.
func _rez_value_per_credit(ice: InstalledCard, ctx: GameContext) -> float:
	var rez_cost: int = ctx.query_rez_cost(ice)
	if rez_cost <= 0:
		return 100.0   # free ice is always efficient
	var tax:       float = _estimate_runner_tax_per_encounter(ice, ctx)
	var encounters: float = _estimate_remaining_encounter_count(ice, ctx)
	return (tax * encounters) / float(rez_cost)


# Urgency score for a server: how much does the runner want to access it right now?
# Central servers and servers with agendas are higher-threat.
# Recent successful runs raise the estimate further.
func _server_threat_estimate(server_id: String, ctx: GameContext) -> float:
	var threat: float
	match server_id:
		"rd":       threat = 2.5   # R&D is the most run central
		"hq":       threat = 2.0   # HQ is frequently targeted
		"archives": threat = 0.8   # usually low priority
		_:
			# Remote: depends on what is installed
			var server: Server = ctx.get_server(server_id)
			if server == null:
				return 1.0
			var root_card: InstalledCard = server.get_agenda_or_asset()
			if root_card != null and root_card.card_record != null:
				if root_card.card_record.is_agenda():
					threat = 2.0   # agenda in remote — runner must check it
				else:
					threat = 1.2   # asset — runner may want to trash
			else:
				threat = 0.7   # empty remote — low priority

	# Boost when the runner has already broken through this server this turn
	# (they are actively targeting it).
	if server_id == "hq" and ctx.runner_hq_successful_run_this_turn:
		threat += 0.5
	elif server_id == "rd" and ctx.runner_successful_run_on_rd_this_turn:
		threat += 0.5

	return threat
