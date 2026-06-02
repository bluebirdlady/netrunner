class_name EncounterState
extends RefCounted

# ── EncounterState ────────────────────────────────────────────────────────────
# Lives for exactly one ice encounter. Tracks which subroutines are broken,
# each installed icebreaker's temporary strength boost, and credit spending.
# Discarded after the encounter ends — boosts do not persist between encounters.

# The ice being encountered
var ice_card:          InstalledCard = null
var ice_strength:      int           = 0
## Applied by encounter paid abilities (e.g. Arruaceiras Crew tag-to-weaken).
## Negative values reduce the ice's effective strength for this encounter.
var strength_modifiers: int          = 0
var subroutines:       Array         = []   # Array[Dictionary] from AbilityRegistry
var broken_indices:    Array         = []   # Array[int] — broken subroutine indices

# Per-icebreaker temporary strength boosts for this encounter.
# Keys are runtime_instance_id (String) so two copies of the same breaker are tracked independently.
var temp_strength_boosts: Dictionary = {}

# Tracks which trojan card_ids have already used their interface_break this encounter.
# Enforces "once per encounter" restrictions (e.g. Slap Vandal).
var trojan_used_this_encounter: Dictionary = {}  # card_id (String) → true

# Set by the Banner encounter action (2cr). When true, end_run effects on this
# barrier ice are suppressed for the remainder of the encounter.
var barrier_etr_suppressed: bool = false

# Reference to installed icebreakers available this encounter
var available_breakers: Array = []   # Array[InstalledCard]

# Stegodon MK IV (TAI): penalty applied to all icebreaker strengths this encounter.
# Set in make() when ctx.run_ice_derezzed_this_run is true.
var breaker_strength_penalty: int = 0

# Optional GameContext reference for querying board-wide modifiers (e.g. Turbine)
var ctx: Object = null
# When true, only fracters can break subroutines on this ice (Semak-samun restriction).
# AI icebreakers are excluded from breaking when this is set.
var fracter_only_break: bool = false
# Set to true the moment any subroutine on this ice is broken by a decoder icebreaker.
# Read by RunStateMachine after the encounter to populate last_ice_broken_with_decoder,
# which on_runner_passes conditions (VSA: "ice_not_broken_with_decoder") then check.
var broken_with_decoder: bool = false


# ── Construction ──────────────────────────────────────────────────────────────

static func make(ice: InstalledCard, subs: Array, breakers: Array, game_ctx: Object = null) -> EncounterState:
	var e              := EncounterState.new()
	e.ice_card         = ice
	e.ice_strength     = ice.card_record.strength if ice.card_record != null else 0
	e.subroutines      = subs.duplicate()
	e.broken_indices   = []
	e.available_breakers = breakers.duplicate()
	e.ctx              = game_ctx
	# GAMEDRAGON Pro: carry forward any run-level strength boosts into this encounter.
	if game_ctx != null and game_ctx.get("run_level_strength_boosts") != null:
		for breaker_id in game_ctx.run_level_strength_boosts:
			e.temp_strength_boosts[breaker_id] = game_ctx.run_level_strength_boosts[breaker_id]
	# Stegodon MK IV (TAI): Corp derezzed non-attacked ice at run start → all breakers −2 str.
	if game_ctx != null and game_ctx.get("run_ice_derezzed_this_run"):
		e.breaker_strength_penalty = 2
		game_ctx.send_log("[Stegodon MK IV] Breakers suffer −2 strength this encounter.")
	# Scatter Field (and any future ice with strength_bonus_if_only_ice): +N strength
	# while this is the only piece of ice protecting its server.
	if game_ctx != null and game_ctx.has_meta("ability_registry"):
		var enc_ab_reg: Object = game_ctx.get_meta("ability_registry")
		if enc_ab_reg != null:
			var enc_ability: Dictionary = enc_ab_reg._abilities.get(ice.card_id, {}) as Dictionary
			var only_ice_bonus: int = int(enc_ability.get("strength_bonus_if_only_ice", 0))
			if only_ice_bonus > 0 and game_ctx.has_method("get_server"):
				var enc_server: Object = game_ctx.get_server(ice.server_id)
				if enc_server != null and enc_server.ice.size() == 1:
					e.ice_strength += only_ice_bonus
	# The Tungsten Tailor (VP3): apply global ice strength modifier from installed hardware
	if game_ctx != null and game_ctx.has_method("query_ice_strength_modifier"):
		var tt_mod: int = game_ctx.query_ice_strength_modifier()
		if tt_mod != 0:
			e.ice_strength += tt_mod
	# Stick and Poke (VP8): first time each turn you encounter ice, prepend a net-damage sub.
	if game_ctx != null and not game_ctx.once_per_turn_triggered.get("_sap_first_encounter", false):
		for sap_rig in game_ctx.runner_rig:
			var sap_ic: InstalledCard = sap_rig as InstalledCard
			if sap_ic != null and sap_ic.card_id == "stick_and_poke":
				game_ctx.once_per_turn_triggered["_sap_first_encounter"] = true
				var sap_sub: Dictionary = {
					"label": "Do 1 net damage. The Runner draws 1 card.",
					"effects": [
						{"type": "deal_damage", "params": {"damage_type": "net", "amount": 1}},
						{"type": "draw_cards",  "params": {"subject": "runner",  "amount": 1}}
					]
				}
				e.subroutines.insert(0, sap_sub)
				game_ctx.send_log("Stick and Poke: injects net-damage sub before %s's subroutines." % \
					e.ice_card.display_name())
				break
	return e


# ── Strength queries ──────────────────────────────────────────────────────────

# Current effective strength of a breaker including temporary boosts and board modifiers
func get_breaker_strength(breaker: InstalledCard) -> int:
	# Check for dynamic base strength override (e.g. Echelon/Unity: strength = installed icebreakers)
	var base: int = _resolve_breaker_base_strength(breaker)
	# Permanent strength from power counters (e.g. Marjanah: +1 per ice passed)
	var permanent: int = breaker.get_counter("power")
	var boost: int = temp_strength_boosts.get(breaker.runtime_instance_id, 0)
	var board_bonus: int = 0
	if ctx != null and ctx.has_method("query_breaker_strength_bonus"):
		board_bonus = ctx.query_breaker_strength_bonus()
	# GAMEDRAGON Pro: +1 strength per attached GAMEDRAGON Pro
	var gamedragon_bonus: int = 0
	if ctx != null and ctx.has_method("gamedragon_breaker_bonus"):
		gamedragon_bonus = ctx.gamedragon_breaker_bonus(breaker)
	return base + permanent + boost + board_bonus + gamedragon_bonus - breaker_strength_penalty


func _resolve_breaker_base_strength(breaker: InstalledCard) -> int:
	# Check if this specific breaker has a dynamic base strength modifier
	if ctx != null and ctx.has_method("query_dynamic_breaker_base"):
		var dynamic_base: int = ctx.query_dynamic_breaker_base(breaker)
		if dynamic_base >= 0:
			return dynamic_base
	# Default: use printed strength from card record
	return breaker.card_record.strength if breaker.card_record != null else 0


# Effective ice strength after all modifiers (arruaceiras_crew weaken, etc.)
func effective_ice_strength() -> int:
	return ice_strength + strength_modifiers


# Whether a breaker meets or exceeds the ice strength
func breaker_reaches(breaker: InstalledCard) -> bool:
	return get_breaker_strength(breaker) >= effective_ice_strength()


# Apply a temporary strength boost to a breaker
func apply_boost(breaker: InstalledCard, amount: int) -> void:
	var current: int = temp_strength_boosts.get(breaker.runtime_instance_id, 0)
	temp_strength_boosts[breaker.runtime_instance_id] = current + amount


# ── Subroutine queries ────────────────────────────────────────────────────────

func is_broken(sub_index: int) -> bool:
	return broken_indices.has(sub_index)

func break_subroutine(sub_index: int) -> void:
	if not broken_indices.has(sub_index):
		broken_indices.append(sub_index)

func all_broken() -> bool:
	return broken_indices.size() >= subroutines.size()

func unbroken_indices() -> Array:
	var result: Array = []
	for i in range(subroutines.size()):
		if not broken_indices.has(i):
			result.append(i)
	return result


# ── Breaker queries ───────────────────────────────────────────────────────────

# Returns all installed breakers that can interact with the encountered ice
# based on subtype matching.
func breakers_for_ice() -> Array:
	if ice_card == null or ice_card.card_record == null:
		return []

	# Merge printed subtypes with runtime-granted subtypes (e.g. Chromatophores grants barrier/code_gate/sentry)
	var ice_subtypes: Array = ice_card.card_record.subtypes.duplicate()
	for es in ice_card.extra_subtypes:
		if not ice_subtypes.has(es):
			ice_subtypes.append(es)
	var result: Array       = []

	for breaker in available_breakers:
		var b: InstalledCard = breaker as InstalledCard
		if b.card_record == null:
			continue
		if _breaker_matches_ice(b, ice_subtypes):
			result.append(b)

	return result


func _breaker_matches_ice(breaker: InstalledCard, ice_subtypes: Array) -> bool:
	var breaker_subtypes: Array = breaker.card_record.subtypes

	# Standard matching evaluated FIRST — fracter/barrier, decoder/code_gate, killer/sentry.
	# A breaker with both "ai" and "fracter" subtypes qualifies as a fracter and may break
	# Semak-samun (fracter_only_break) even though it is also an AI breaker.
	const MATCHES := {
		"fracter": "barrier",
		"decoder": "code_gate",
		"killer":  "sentry",
	}

	for breaker_type in MATCHES:
		if breaker_subtypes.has(breaker_type):
			var ice_type: String = MATCHES[breaker_type]
			if ice_subtypes.has(ice_type):
				return true

	# AI breakers with no standard subtype match can interact with any ice,
	# UNLESS fracter_only_break is set (e.g. Semak-samun restricts to fracters only).
	if breaker_subtypes.has("ai"):
		return not fracter_only_break

	return false


# ── Display ───────────────────────────────────────────────────────────────────

func describe() -> String:
	var ice_name: String = ice_card.display_name() if ice_card else "?"
	var broken_count := broken_indices.size()
	var total_count  := subroutines.size()
	var eff_str: int = effective_ice_strength()
	var str_str: String = str(eff_str) if strength_modifiers == 0 else \
		"%d (base %d%+d)" % [eff_str, ice_strength, strength_modifiers]
	return "%s (str %s) — %d/%d subs broken" % [ice_name, str_str, broken_count, total_count]
