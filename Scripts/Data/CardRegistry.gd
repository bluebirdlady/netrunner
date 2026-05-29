extends Node

# ── CardRegistry ──────────────────────────────────────────────────────────────
# Autoload singleton. Add to Project > Project Settings > Autoload as "CardRegistry".
#
# Loads card data from the local cache on startup.
# Provides fast lookup by card id, and filtered views by type, faction, side, etc.
# Never fetches from the network — that's CardImporter's job.
#
# Usage:
#   var card = CardRegistry.get_card("hedge_fund")
#   var ice  = CardRegistry.get_cards_by_type("ice")
#   var corp = CardRegistry.get_cards_by_side("corp")

const CACHE_PATH := "user://nrdb_cache/cards.json"

# Primary store: card_id -> CardRecord
var _cards: Dictionary = {}
var is_loaded: bool    = false

signal loaded(card_count: int)
signal load_failed(reason: String)


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_load_from_cache()


# ── Cache loading ─────────────────────────────────────────────────────────────

func _load_from_cache() -> void:
	if not FileAccess.file_exists(CACHE_PATH):
		push_warning("CardRegistry: no cache found at %s — run CardImporter first" % CACHE_PATH)
		emit_signal("load_failed", "No cache found. Please fetch card data.")
		return

	var file := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if file == null:
		var msg := "CardRegistry: could not open cache file"
		push_error(msg)
		emit_signal("load_failed", msg)
		return

	var raw_text  := file.get_as_text()
	file.close()

	var raw_array: Array = JSON.parse_string(raw_text) as Array
	if raw_array == null or raw_array.is_empty():
		var msg := "CardRegistry: cache is malformed"
		push_error(msg)
		emit_signal("load_failed", msg)
		return

	_cards.clear()
	for raw_card in raw_array:
		var record := CardRecord.from_api_data(raw_card)
		if record.id != "":
			_cards[record.id] = record

	is_loaded = true
	print("CardRegistry: loaded %d cards" % _cards.size())
	emit_signal("loaded", _cards.size())


func reload() -> void:
	is_loaded = false
	_load_from_cache()


# ── Lookups ───────────────────────────────────────────────────────────────────

func get_card(id: String) -> CardRecord:
	return _cards.get(id, null)

func has_card(id: String) -> bool:
	return _cards.has(id)

func all_cards() -> Array:
	return _cards.values()

func get_cards_by_side(side: String) -> Array:
	return _cards.values().filter(func(c): return c.side == side)

func get_cards_by_type(card_type: String) -> Array:
	return _cards.values().filter(func(c): return c.card_type == card_type)

func get_cards_by_faction(faction: String) -> Array:
	return _cards.values().filter(func(c): return c.faction == faction)

func get_cards_by_subtype(subtype: String) -> Array:
	return _cards.values().filter(func(c): return c.has_subtype(subtype))

func get_corp_cards() -> Array:
	return get_cards_by_side("corp")

func get_runner_cards() -> Array:
	return get_cards_by_side("runner")

func get_ice() -> Array:
	return get_cards_by_type("ice")

func get_agendas() -> Array:
	return get_cards_by_type("agenda")

func get_identities() -> Array:
	# v2 uses "identity"; v3 may use "corp_identity" / "runner_identity"
	return _cards.values().filter(func(c): return c.is_identity())

# Search by partial title match (case-insensitive) — useful for debug/dev tools
func search_by_title(query: String) -> Array:
	var q := query.to_lower()
	return _cards.values().filter(func(c): return c.title.to_lower().contains(q))

# Return a filtered set by format legality
# format: "standard" | "startup" | "eternal"
func get_cards_in_format(_format: String) -> Array:
	# The v2 cache doesn't include format data per-card.
	# This is a placeholder — format filtering requires v3 API data.
	# For now, return all cards and log a warning.
	push_warning("CardRegistry: format filtering not yet supported with v2 cache")
	return all_cards()
