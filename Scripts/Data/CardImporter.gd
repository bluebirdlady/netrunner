class_name CardImporter
extends RefCounted

# ── Fetches card data from NetrunnerDB API v2 and writes a local JSON cache. ──
# Called explicitly when the player requests a data refresh.
# Normal startup loads from cache via CardRegistry instead.
#
# Usage:
#   var importer := CardImporter.new()
#   var result = await importer.fetch_and_cache()
#   if result.success:
#       print("Imported %d cards" % result.card_count)
#   else:
#       print("Import failed: " % result.error)

const API_BASE        := "https://api-preview.netrunnerdb.com/api/v3/public"
const CARDS_ENDPOINT  := API_BASE + "/cards?page[size]=1000"
const CACHE_PATH      := "user://nrdb_cache/cards.json"
const CACHE_META_PATH := "user://nrdb_cache/meta.json"

signal progress(message: String)
signal completed(result: Dictionary)


# ── Public API ────────────────────────────────────────────────────────────────

func fetch_and_cache() -> Dictionary:
	emit_signal("progress", "Connecting to NetrunnerDB...")

	var all_cards: Array = []
	var next_url: String = CARDS_ENDPOINT

	while next_url != "":
		var http := HTTPRequest.new()
		Engine.get_main_loop().root.add_child(http)

		var error := http.request(next_url)
		if error != OK:
			http.queue_free()
			return _fail("HTTP request failed (error code %d)" % error)

		emit_signal("progress", "Downloading card data... (%d so far)" % all_cards.size())
		var response = await http.request_completed
		http.queue_free()

		var http_code: int        = response[1]
		var body: PackedByteArray = response[3]

		if http_code != 200:
			return _fail("NetrunnerDB returned HTTP %d" % http_code)

		var json_text := body.get_string_from_utf8()
		var parsed: Dictionary = JSON.parse_string(json_text) as Dictionary
		if parsed == null:
			return _fail("Failed to parse JSON response")

		# v3 returns {"data": [...], "links": {"next": "..."}}
		var page_cards: Array = parsed.get("data", []) as Array
		all_cards.append_array(page_cards)

		# Follow pagination
		var links: Dictionary = parsed.get("links", {}) as Dictionary
		next_url = links.get("next", "")

	if all_cards.is_empty():
		return _fail("API returned no cards")

	emit_signal("progress", "Caching %d cards..." % all_cards.size())
	var write_result := _write_cache(all_cards, {})
	if not write_result:
		return _fail("Failed to write cache to disk")

	var result := {
		"success":    true,
		"card_count": all_cards.size(),
		"error":      ""
	}
	emit_signal("progress", "Done. %d cards cached." % all_cards.size())
	emit_signal("completed", result)
	return result


# ── Cache write ───────────────────────────────────────────────────────────────

func _write_cache(raw_cards: Array, _full_response: Dictionary) -> bool:
	# Ensure cache directory exists
	var dir := DirAccess.open("user://")
	if not dir.dir_exists("nrdb_cache"):
		var err := dir.make_dir("nrdb_cache")
		if err != OK:
			push_error("CardImporter: could not create cache directory")
			return false

	# Write the raw card array — CardRegistry parses this on load
	var cards_json := JSON.stringify(raw_cards, "\t")
	var file := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("CardImporter: could not open %s for writing" % CACHE_PATH)
		return false
	file.store_string(cards_json)
	file.close()

	# Write metadata: timestamp and card count for display purposes
	var meta := {
		"fetched_at":  Time.get_datetime_string_from_system(),
		"card_count":  raw_cards.size(),
		"api_version": "3.0"
	}
	var meta_file := FileAccess.open(CACHE_META_PATH, FileAccess.WRITE)
	if meta_file == null:
		push_error("CardImporter: could not open %s for writing" % CACHE_META_PATH)
		return false
	meta_file.store_string(JSON.stringify(meta, "\t"))
	meta_file.close()

	return true


# ── Helpers ───────────────────────────────────────────────────────────────────

func _fail(message: String) -> Dictionary:
	push_error("CardImporter: " + message)
	var result := {"success": false, "card_count": 0, "error": message}
	emit_signal("completed", result)
	return result


# ── Cache introspection (static — no import needed) ───────────────────────────

static func cache_exists() -> bool:
	return FileAccess.file_exists(CACHE_PATH)

static func cache_metadata() -> Dictionary:
	if not FileAccess.file_exists(CACHE_META_PATH):
		return {}
	var file := FileAccess.open(CACHE_META_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Dictionary = JSON.parse_string(file.get_as_text()) as Dictionary
	file.close()
	return parsed if parsed != null else {}
