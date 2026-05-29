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
	if ctx.corp_credits - rez_cost < CREDIT_FLOOR:
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

	_log("AI: rezzing %s for %d credits." % [record.title, rez_cost])
	return true


func _ice_is_worth_rezzing(card: InstalledCard) -> bool:
	var record: CardRecord = card.card_record

	# Ice with meaningful strength is worth rezzing.
	if record.strength >= MIN_USEFUL_STRENGTH:
		return true

	# Strength-0 ice is worth rezzing only if it has implemented subroutines.
	var subroutines: Array = ability_registry.get_subroutines(card.card_id)
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
	print("[CorpRunAI] " + message)
