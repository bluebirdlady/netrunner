class_name BanListManager
extends RefCounted

# ── BanListManager ─────────────────────────────────────────────────────────────
# Format detection and ban list enforcement for the DeckBuilder.
#
# Rules environments:
#   "gateway"  — System Gateway cards only; no bans applied.
#   "startup"  — Any Elevation or Vantage Point cards present; Startup ban list.
#   "standard" — Any cards outside the above three sets; Standard ban list.
#
# Ban list files live in res://Data/Game_Rules/ and follow the naming pattern:
#   startup_ban_list_YY_MM.txt
#   standard_ban_list_YY_MM.txt
# The alphabetically-last matching file is used (newest by YYMM date suffix).
#
# All expensive work (file I/O, CardRegistry scan) is cached after the first
# call and reused for the remainder of the game session.

const STARTUP_SETS: Array = ["system_gateway", "elevation", "vantage_point"]
const RULES_DIR    := "res://Data/Game_Rules/"

# Session-scoped caches — persist until the game exits.
static var _banned_ids_cache: Dictionary = {}  # "startup"|"standard" → Array[String]
static var _title_id_map:     Dictionary = {}  # title.lower() → card_id
static var _title_map_ready:  bool       = false


# ── Format detection ──────────────────────────────────────────────────────────

# Detect the rules format from a list of card IDs (deck cards + identity).
# Returns "gateway", "startup", or "standard".
static func detect_format(card_ids: Array) -> String:
	var has_elev_or_vp := false
	var has_beyond     := false
	for cid in card_ids:
		var record: CardRecord = CardRegistry.get_card(cid)
		if record == null:
			continue
		var sets: Array = record.card_set_ids
		if sets.is_empty():
			# No set information — conservative assumption: treat as standard.
			has_beyond = true
			continue
		for s in sets:
			if s not in STARTUP_SETS:
				has_beyond = true
				break
			if s == "elevation" or s == "vantage_point":
				has_elev_or_vp = true
	if has_beyond:
		return "standard"
	if has_elev_or_vp:
		return "startup"
	return "gateway"


# ── Ban list queries ──────────────────────────────────────────────────────────

# Return the banned card IDs for a given format (cached after first call).
# Returns an empty Array for "gateway".
static func get_banned_ids(format: String) -> Array:
	if format == "gateway":
		return []
	if _banned_ids_cache.has(format):
		return _banned_ids_cache[format]
	var titles := _load_banned_titles(format)
	var ids    := _resolve_titles(titles)
	_banned_ids_cache[format] = ids
	return ids


# Return the subset of card_ids that appear on the active ban list.
# card_ids should include both deck cards and the identity.
static func banned_in_deck(card_ids: Array, format: String) -> Array:
	if format == "gateway":
		return []
	var banned := get_banned_ids(format)
	return card_ids.filter(func(id: String) -> bool: return id in banned)


# Clear the session cache (useful if rules files are updated at runtime).
static func invalidate_cache() -> void:
	_banned_ids_cache.clear()
	_title_id_map.clear()
	_title_map_ready = false


# ── Private — file loading ────────────────────────────────────────────────────

static func _load_banned_titles(format: String) -> Array:
	var prefix := "startup_ban_list_" if format == "startup" else "standard_ban_list_"
	var path   := _newest_file(prefix)
	if path == "":
		push_warning("BanListManager: no %s ban list file found in '%s'" % [format, RULES_DIR])
		return []
	return _parse_file(path)


static func _newest_file(prefix: String) -> String:
	var dir := DirAccess.open(RULES_DIR)
	if dir == null:
		push_warning("BanListManager: cannot open rules directory '%s'" % RULES_DIR)
		return ""
	var matches: Array = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() \
				and fname.begins_with(prefix) \
				and fname.ends_with(".txt"):
			matches.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	if matches.is_empty():
		return ""
	matches.sort()          # alphabetical sort = YYMM order → last is newest
	return RULES_DIR + matches[-1]


# Parse a ban list file and return the list of banned card titles.
# Expected file format (lines within "Banned" blocks are indented with spaces):
#
#   Corp Cards
#
#       Banned
#           Seamless Launch
#           NBN: Reality Plus
#
#   Runner Cards
#
#       Banned
#           Cleaver
#
# An empty line exits the current Banned block.  Multiple Banned blocks
# within a single file (Corp and Runner) are all collected into one list.
static func _parse_file(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("BanListManager: cannot open '%s'" % path)
		return []
	var titles: Array = []
	var in_banned := false
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line == "Banned":
			in_banned = true
			continue
		if in_banned:
			if line == "":
				in_banned = false
				continue
			titles.append(line)
	file.close()
	return titles


# ── Private — title → ID resolution ──────────────────────────────────────────

static func _resolve_titles(titles: Array) -> Array:
	_ensure_title_map()
	var ids: Array = []
	for title in titles:
		var id: String = _title_id_map.get((title as String).to_lower(), "")
		if id != "":
			ids.append(id)
		else:
			push_warning("BanListManager: could not resolve banned card '%s' to a card ID" % title)
	return ids


static func _ensure_title_map() -> void:
	if _title_map_ready:
		return
	if not CardRegistry.is_loaded:
		push_warning("BanListManager: CardRegistry not ready — ban title resolution deferred")
		return
	for record in CardRegistry.all_cards():
		_title_id_map[(record.title as String).to_lower()] = record.id
	_title_map_ready = true
