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
	return get_break(card_id) != null

# Returns a top-level boolean flag from the ability definition (e.g. "fracter_only_break").
func get_flag(card_id: String, flag_name: String) -> bool:
	if not _abilities.has(card_id):
		return false
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	return card_def.get(flag_name, false) as bool


# ── Internal ──────────────────────────────────────────────────────────────────

func _get_trigger(card_id: String, trigger: String) -> Variant:
	if not _abilities.has(card_id):
		return null
	var card_def: Dictionary = _abilities[card_id] as Dictionary
	if not card_def.has(trigger):
		return null
	return card_def[trigger]
