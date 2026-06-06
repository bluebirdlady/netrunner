class_name TournamentFetcher
extends RefCounted

# ── TournamentFetcher ─────────────────────────────────────────────────────────
# Builds a pool of Corp opponents for the Open Circuit tournament mode.
#
# Strategy:
#   1. On first call (or force_refresh=true), scrape the NRDB web search page
#      for Startup-legal Corp decklists sorted by popularity, extract deck IDs
#      from the HTML, then fetch each deck's details via the v3 API.
#   2. Results are written to a local cache (user://tournament_deck_cache.json).
#   3. Subsequent calls return the cached pool instantly — no network needed.
#   4. The caller passes force_refresh=true when the player explicitly requests
#      a fresh scrape.
#
# Each returned opponent dict:
#   {
#     "name":       String  — deck title
#     "author":     String  — NRDB username
#     "identity":   String  — card_id of the Corp identity
#     "faction":    String  — faction_id (e.g. "haas-bioroid")
#     "deck":       Array   — flat Array[String] of card_ids (copies repeated)
#     "likes":      int     — likes count at fetch time
#     "nrdb_id":    String  — decklist ID for attribution
#   }

# Web search URL — only the web UI supports rotation_id + popularity sort together.
const SEARCH_URL := "https://netrunnerdb.com/en/decklists/find" \
	+ "?faction=corp&sort=popularity&rotation_id=7" \
	+ "&is_legal=1&mwl_code=startup-balance-update-26-05-for-classic-only" \
	+ "&packs%5B%5D=vp&packs%5B%5D=elev&packs%5B%5D=sg"

const API_BASE   := "https://api-preview.netrunnerdb.com/api/v3/public"
const CACHE_PATH := "user://tournament_deck_cache.json"
const MIN_POOL   := 6
const MAX_POOL   := 30

signal fetch_progress(message: String)
signal fetch_completed(result: Dictionary)


# ── Public ────────────────────────────────────────────────────────────────────

func fetch(force_refresh: bool = false) -> Dictionary:
	emit_signal("fetch_progress", "Checking deck archive…")

	if not force_refresh:
		var cached := _load_cache()
		if cached.size() >= MIN_POOL:
			emit_signal("fetch_progress", "Using archived pool (%d decks)" % cached.size())
			var result := {"ok": true, "opponents": cached}
			emit_signal("fetch_completed", result)
			return result

	return await _scrape_and_cache()


# ── Scrape ────────────────────────────────────────────────────────────────────

func _scrape_and_cache() -> Dictionary:
	emit_signal("fetch_progress", "Fetching NetrunnerDB search results…")

	var deck_ids := await _scrape_deck_ids()
	if deck_ids.is_empty():
		return _fail("Could not extract any deck IDs from the NetrunnerDB search page")

	emit_signal("fetch_progress", "Found %d listings, loading details…" % deck_ids.size())

	var opponents: Array = []
	var cap := mini(deck_ids.size(), MAX_POOL)
	for i in range(cap):
		emit_signal("fetch_progress", "Loading deck %d / %d…" % [i + 1, cap])
		var deck_data := await _fetch_deck_by_id(deck_ids[i] as String)
		if not deck_data.is_empty():
			opponents.append(deck_data)

	if opponents.size() < MIN_POOL:
		return _fail("Too few valid Corp decks found (%d, need %d)" % [opponents.size(), MIN_POOL])

	_save_cache(opponents)
	emit_signal("fetch_progress", "Archive updated: %d decks stored" % opponents.size())

	var result := {"ok": true, "opponents": opponents}
	emit_signal("fetch_completed", result)
	return result


func _scrape_deck_ids() -> Array:
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)

	# Provide a browser-like User-Agent so the site returns full HTML.
	var headers := PackedStringArray(["User-Agent: Mozilla/5.0 (compatible; NetrunnerClient/1.0)"])
	var err := http.request(SEARCH_URL, headers)
	if err != OK:
		http.queue_free()
		return []

	var response = await http.request_completed
	http.queue_free()

	var http_code: int        = response[1]
	var body: PackedByteArray = response[3]
	if http_code != 200:
		push_warning("TournamentFetcher: search page returned HTTP %d" % http_code)
		return []

	return _extract_deck_ids(body.get_string_from_utf8())


func _extract_deck_ids(html: String) -> Array:
	var ids:  Array      = []
	var seen: Dictionary = {}
	var regex            := RegEx.new()
	# Deck page URLs look like /en/decklist/<uuid>/title-slug
	regex.compile("/en/decklist/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/")
	for m in regex.search_all(html):
		var deck_id: String = m.get_string(1)
		if not seen.has(deck_id):
			seen[deck_id] = true
			ids.append(deck_id)
	return ids


func _fetch_deck_by_id(deck_id: String) -> Dictionary:
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)

	var url := API_BASE + "/decklists/" + deck_id
	var err  := http.request(url)
	if err != OK:
		http.queue_free()
		return {}

	var response = await http.request_completed
	http.queue_free()

	var http_code: int        = response[1]
	var body: PackedByteArray = response[3]
	if http_code != 200:
		return {}

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not parsed is Dictionary:
		return {}

	# JSON:API single-resource responses wrap the item in "data": {…} (object),
	# not "data": […] (array) — normalise both shapes to an array.
	var raw_data = (parsed as Dictionary).get("data")
	var data_arr: Array
	if raw_data is Array:
		data_arr = raw_data
	elif raw_data is Dictionary:
		data_arr = [raw_data]
	else:
		return {}

	var results := _parse_opponents(data_arr)
	return results[0] if not results.is_empty() else {}


# ── Cache ──────────────────────────────────────────────────────────────────────

func _save_cache(opponents: Array) -> void:
	var file := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if not file:
		push_warning("TournamentFetcher: could not write cache to " + CACHE_PATH)
		return
	file.store_string(JSON.stringify({"opponents": opponents}))
	file.close()


func _load_cache() -> Array:
	if not FileAccess.file_exists(CACHE_PATH):
		return []
	var file := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if not file:
		return []
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return []
	var raw = (parsed as Dictionary).get("opponents")
	return raw if raw is Array else []


# ── Parsing ───────────────────────────────────────────────────────────────────

func _parse_opponents(data: Array) -> Array:
	var out: Array = []
	for entry in data:
		var d := entry as Dictionary
		if d == null:
			continue
		var raw_attrs = d.get("attributes")
		if not raw_attrs is Dictionary:
			continue
		var attrs := raw_attrs as Dictionary

		var side: String = attrs.get("side_id", "")
		if side != "corp":
			continue

		var identity: String = attrs.get("identity_card_id", "")
		if identity == "" or not CardRegistry.has_card(identity):
			continue

		var raw_cards = attrs.get("card_slots", {})
		if not raw_cards is Dictionary or (raw_cards as Dictionary).is_empty():
			continue

		var deck := _expand_deck(raw_cards as Dictionary)
		if deck.is_empty():
			continue

		out.append({
			"name":     str(attrs.get("name", "Unknown Deck")),
			"author":   _extract_author(d),
			"identity": identity,
			"faction":  str(attrs.get("faction_id", "")),
			"deck":     deck,
			"likes":    int(attrs.get("likes_count", 0)),
			"nrdb_id":  str(d.get("id", ""))
		})

	return out


func _expand_deck(cards: Dictionary) -> Array:
	var out: Array = []
	for card_id in cards:
		var count: int = int(cards[card_id])
		for _i in range(count):
			out.append(str(card_id))
	return out


func _extract_author(entry: Dictionary) -> String:
	var attrs: Dictionary = entry.get("attributes", {}) as Dictionary
	var user_id: String = str(attrs.get("user_id", ""))
	if user_id != "" and user_id != "null":
		return user_id
	return "Anonymous"


# ── Helpers ───────────────────────────────────────────────────────────────────

func _fail(message: String) -> Dictionary:
	push_warning("TournamentFetcher: " + message)
	var result := {"ok": false, "error": message, "opponents": []}
	emit_signal("fetch_completed", result)
	return result
