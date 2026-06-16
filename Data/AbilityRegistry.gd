class_name AbilityRegistry
extends RefCounted

# ── AbilityRegistry ───────────────────────────────────────────────────────────
# Loads hand-authored ability definitions from abilities.json and provides
# lookup by card id. Entirely separate from CardRegistry — one holds API data,
# the other holds behaviour definitions.
#
# Usage (via autoload or direct instantiation):
#   var defs = AbilityRegistry.new()
#   defs.load_from_file("res://Data/abilities.json")
#   var def = defs.get_on_play("hedge_fund")
#   var subs = defs.get_subroutines("palisade")

var _abilities: Dictionary = {}
var is_loaded: bool = false


# ── Loading ───────────────────────────────────────────────────────────────────

func load_from_file(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_error("AbilityRegistry: file not found: %s" % path)
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("AbilityRegistry: could not open %s" % path)
		return false

	var parsed: Dictionary = JSON.parse_string(file.get_as_text()) as Dictionary
	file.close()

	if parsed == null:
		push_error("AbilityRegistry: failed to parse %s" % path)
		return false

	_abilities = parsed
	is_loaded  = true
	print("AbilityRegistry: loaded definitions for %d cards" % _abilities.size())
	return true


# ── Lookups ───────────────────────────────────────────────────────────────────

# Returns the on_play definition dict, or null if not defined.
func get_on_play(card_id: String) -> Variant:
	return _get_trigger(card_id, "on_play")

# Returns the on_access definition dict, or null if not defined.
func get_on_access(card_id: String) -> Variant:
	return _get_trigger(card_id, "on_access")

# Returns the on_rez definition dict, or null if not defined.
func get_on_rez(card_id: String) -> Variant:
	return _get_trigger(card_id, "on_rez")

# Returns the on_rez_during_run definition dict, or null if not defined.
# Used for ice abilities that fire when rezzed during an active run (e.g. Hákarl, Stavka, Wave).
func get_on_rez_during_run(card_id: String) -> Variant:
	return _get_trigger(card_id, "on_rez_during_run")

# Returns the on_score definition dict, or null if not defined.
func get_on_score(card_id: String) -> Variant:
	return _get_trigger(card_id, "on_score")

# Returns the on_steal definition dict, or null if not defined.
func get_on_steal(card_id: String) -> Variant:
	return _get_trigger(card_id, "on_steal")

# Returns the on_forfeit definition dict, or null if not defined.
func get_on_forfeit(card_id: String) -> Variant:
	return _get_trigger(card_id, "on_forfeit")

# Returns array of subroutine dicts, or [] if none defined.
func get_subroutines(card_id: String) -> Array:
	if not _abilities.has(card_id):
		return []
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	return card_def.get("subroutines", []) as Array


# Returns subroutines filtered by the installed card's current state.
# Used for cards like Pharos where subroutines are conditionally present.
func get_subroutines_for_card(card_id: String, installed: InstalledCard) -> Array:
	var all_subs: Array = get_subroutines(card_id)
	if all_subs.is_empty() or installed == null:
		return all_subs

	var result: Array = []
	for sub in all_subs:
		var s: Dictionary = sub as Dictionary
		# Check "require_advancement" condition — sub only exists if card has N+ counters
		var required: int = s.get("require_advancement", 0)
		if required > 0:
			var actual: int = installed.get_counter("advancement")
			if actual < required:
				continue   # sub doesn't exist yet
		# Check "require_server" condition — sub only exists while protecting that server
		# (e.g. Winchester's bonus Trace[3] sub while protecting HQ).
		var required_server: String = s.get("require_server", "")
		if required_server != "" and installed.server_id != required_server:
			continue
		result.append(s)
	return result

# Returns true if any ability is defined for this card.
func has_definition(card_id: String) -> bool:
	return _abilities.has(card_id)

# Returns the break definition for an icebreaker, or null if none.
func get_break(card_id: String) -> Variant:
	if not _abilities.has(card_id):
		return null
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	if not card_def.has("break"):
		return null
	return card_def["break"]

# Returns the appropriate break definition for the given ice, accounting for
# dual-type breakers (e.g. Lobisomem) that have separate blocks per ice type.
# ice_subtypes should be CardRecord.subtypes(ice_card.card_id).
func get_break_for_ice(card_id: String, ice_subtypes: Array) -> Variant:
	if not _abilities.has(card_id):
		return null
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	# Prefer a type-specific break block when the ice matches.
	if card_def.has("break_barrier") and "barrier" in ice_subtypes:
		return card_def["break_barrier"]
	if not card_def.has("break"):
		return null
	return card_def["break"]

# Returns the alternative break interface for an icebreaker (e.g. Euler's free
# first-turn code-gate break, Odore's free sentry break with 3+ virtual
# resources), or null if this card has no break_alt or it doesn't apply to
# this ice's subtypes. Availability conditions (requires_installed_this_turn,
# installed_cards_by_subtype_gte) are checked separately by the caller, since
# they require GameContext/InstalledCard state this registry doesn't have.
func get_break_alt_for_ice(card_id: String, ice_subtypes: Array) -> Variant:
	if not _abilities.has(card_id):
		return null
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	if not card_def.has("break_alt"):
		return null
	var alt: Dictionary = card_def["break_alt"] as Dictionary
	var restriction: String = alt.get("subtype_restriction", "")
	if restriction != "" and not (restriction in ice_subtypes):
		return null
	return alt

# Returns the on_fully_break_code_gate trigger for an icebreaker, or null if none.
# Fires when the breaker is used to break the last unbroken subroutine on a code gate.
func get_on_fully_break_code_gate(card_id: String) -> Variant:
	if not _abilities.has(card_id):
		return null
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	if not card_def.has("on_fully_break_code_gate"):
		return null
	return card_def["on_fully_break_code_gate"]

# Returns the on_fully_break_sentry trigger for an icebreaker, or null if none.
# Fires when the breaker is used to break the last unbroken subroutine on a sentry.
# Used by: Orca (charge 1 installed card on first full-break per turn).
func get_on_fully_break_sentry(card_id: String) -> Variant:
	if not _abilities.has(card_id):
		return null
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	if not card_def.has("on_fully_break_sentry"):
		return null
	return card_def["on_fully_break_sentry"]

# Returns the on_fully_break_ice trigger for an icebreaker, or null if none.
# Fires when the breaker is used to break the last unbroken subroutine on
# any piece of ice, regardless of subtype.
# Used by: Makler (first time per turn -> gain 1cr).
func get_on_fully_break_ice(card_id: String) -> Variant:
	if not _abilities.has(card_id):
		return null
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	if not card_def.has("on_fully_break_ice"):
		return null
	return card_def["on_fully_break_ice"]

# Returns the boost definition for an icebreaker, or null if none.
func get_boost(card_id: String) -> Variant:
	if not _abilities.has(card_id):
		return null
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	if not card_def.has("boost"):
		return null
	return card_def["boost"]

# Returns true if this card has icebreaker abilities.
func is_icebreaker(card_id: String) -> bool:
	if get_break(card_id) != null:
		return true
	if not _abilities.has(card_id):
		return false
	return (_abilities[card_id] as Dictionary).has("break_barrier")

# Returns a top-level boolean flag from the ability definition (e.g. "fracter_only_break").
func get_flag(card_id: String, flag_name: String) -> bool:
	if not _abilities.has(card_id):
		return false
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	return card_def.get(flag_name, false) as bool


# Returns the interface_break definition dict for a trojan, or null if none.
# Used by Slap Vandal and similar "Interface →" abilities on hosted trojans.
func get_interface_break(card_id: String) -> Variant:
	return _get_trigger(card_id, "interface_break")


# Returns the umbrella_break definition dict, or null if none.
# Used by Umbrella (and future rig programs that break via hosted-trojan condition).
func get_umbrella_break(card_id: String) -> Variant:
	return _get_trigger(card_id, "umbrella_break")


# Returns the on_runner_passes trigger dict for an ice card, or null if none.
# Fires after the runner passes that specific ice (Phoneutria, Tatu-Bola, VSA).
func get_on_runner_passes(card_id: String) -> Variant:
	return _get_trigger(card_id, "on_runner_passes")


# Returns the on_runner_passes_host trigger dict for a trojan, or null if none.
# Fires after the runner passes the ice the trojan is hosted on (Pichação).
func get_on_runner_passes_host(card_id: String) -> Variant:
	return _get_trigger(card_id, "on_runner_passes_host")


# Returns an Array of "when encountered" ability dicts for an ice card.
# These are the ice's own abilities that fire at encounter time (e.g. Jaguarundi's
# tag-or-click). They are distinct from the global encounter_ice event and are
# interruptible by AirbladeX (JSRF Ed.).
# Each element is a trigger dict suitable for AbilityInterpreter.execute_trigger().
# A single dict value is wrapped in an Array for uniform iteration.
func get_on_encounter_self(card_id: String) -> Array:
	if not _abilities.has(card_id):
		return []
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	var result: Variant = card_def.get("on_encounter_self", null)
	if result == null:
		return []
	if result is Array:
		return result as Array
	return [result]


# ── Internal ──────────────────────────────────────────────────────────────────

func _get_trigger(card_id: String, trigger: String) -> Variant:
	if not _abilities.has(card_id):
		return null
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	if not card_def.has(trigger):
		return null
	return card_def[trigger]
