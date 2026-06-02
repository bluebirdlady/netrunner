class_name TournamentFetcher
extends RefCounted

# ── TournamentFetcher ─────────────────────────────────────────────────────────
# Fetches recent well-liked Corp Startup decklists from NetrunnerDB v3 API.
# Returns a pool of candidate opponent dicts; TournamentState picks 6 from them.
#
# Each returned opponent dict:
#   {
#     "name":       String   — deck title
#     "author":     String   — NRDB username
#     "identity":   String   — card_id of the Corp identity
#     "faction":    String   — faction_id (e.g. "haas-bioroid")
#     "deck":       Array    — flat Array[String] of card_ids (copies repeated)
#     "likes":      int      — likes count at fetch time
#     "nrdb_id":    String   — decklist ID for attribution
#   }

const API_BASE    := "https://api-preview.netrunnerdb.com/api/v3/public"
# Sort by likes desc, fetch enough to get 6 valid Corp decks after filtering.
const FETCH_URL   := API_BASE + "/decklists?filter[format_id]=startup&filter[side_id]=corp&sort=-likes_count&page[limit]=40"
const MIN_POOL    := 6    # must return at least this many to run a tournament
const MAX_POOL    := 20   # cap so we don't over-fetch

signal fetch_progress(message: String)
signal fetch_completed(result: Dictionary)


# ── Public ────────────────────────────────────────────────────────────────────

# Returns { "ok": true, "opponents": Array } or { "ok": false, "error": String }
func fetch() -> Dictionary:
	emit_signal("fetch_progress", "Connecting to NetrunnerDB…")

	var http := HTTPRequest.new()
	# HTTPRequest must live in the scene tree to use its request_completed signal.
	Engine.get_main_loop().root.add_child(http)

	var err := http.request(FETCH_URL)
	if err != OK:
		http.queue_free()
		return _fail("HTTP request failed (code %d)" % err)

	emit_signal("fetch_progress", "Downloading Startup decklists…")
	var response = await http.request_completed
	http.queue_free()

	var http_code: int        = response[1]
	var body: PackedByteArray = response[3]

	if http_code != 200:
		return _fail("NetrunnerDB returned HTTP %d" % http_code)

	var json_text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(json_text)
	if parsed == null or not parsed is Dictionary:
		return _fail("Failed to parse API response")

	var data: Array = (parsed as Dictionary).get("data", []) as Array
	if data.is_empty():
		return _fail("API returned no decklists")

	emit_signal("fetch_progress", "Processing %d decklists…" % data.size())
	var opponents := _parse_opponents(data)

	if opponents.size() < MIN_POOL:
		return _fail("Too few valid Corp decks found (%d, need %d)" % [opponents.size(), MIN_POOL])

	# Trim to MAX_POOL so we don't overwhelm TournamentState's picker.
	if opponents.size() > MAX_POOL:
		opponents = opponents.slice(0, MAX_POOL)

	var result := {"ok": true, "opponents": opponents}
	emit_signal("fetch_completed", result)
	return result


# ── Parsing ───────────────────────────────────────────────────────────────────

func _parse_opponents(data: Array) -> Array:
	var out: Array = []
	for entry in data:
		var d := entry as Dictionary
		if d == null:
			continue
		var attrs: Dictionary = d.get("attributes", {}) as Dictionary
		if attrs.is_empty():
			continue

		# Must be Corp side.
		var side: String = attrs.get("side_id", "")
		if side != "corp":
			continue

		# Must have an identity we can resolve.
		var identity: String = attrs.get("identity_card_id", "")
		if identity == "" or not CardRegistry.has_card(identity):
			continue

		# Must have a non-empty card list.
		var raw_cards = attrs.get("cards", {})
		if not raw_cards is Dictionary or (raw_cards as Dictionary).is_empty():
			continue

		var deck := _expand_deck(raw_cards as Dictionary)
		if deck.is_empty():
			continue

		var likes: int = int(attrs.get("likes_count", 0))
		var name:  String = str(attrs.get("name", "Unknown Deck"))
		var author: String = _extract_author(d)
		var faction: String = attrs.get("faction_id", "")

		out.append({
			"name":     name,
			"author":   author,
			"identity": identity,
			"faction":  faction,
			"deck":     deck,
			"likes":    likes,
			"nrdb_id":  str(d.get("id", ""))
		})

	return out


# Convert {"hedge_fund": 3, ...} → ["hedge_fund", "hedge_fund", "hedge_fund", ...]
func _expand_deck(cards: Dictionary) -> Array:
	var out: Array = []
	for card_id in cards:
		var count: int = int(cards[card_id])
		for _i in range(count):
			out.append(str(card_id))
	return out


func _extract_author(entry: Dictionary) -> String:
	# v3 decklists may embed user data in relationships or a nested "user" attribute.
	var attrs: Dictionary = entry.get("attributes", {}) as Dictionary
	var user = attrs.get("user", null)
	if user is Dictionary:
		var handle = (user as Dictionary).get("handle", "")
		if handle != "":
			return str(handle)
	# Some builds expose user_name directly.
	var username = attrs.get("user_name", "")
	if str(username) != "":
		return str(username)
	return "Anonymous"


# ── Helpers ───────────────────────────────────────────────────────────────────

func _fail(message: String) -> Dictionary:
	push_warning("TournamentFetcher: " + message)
	var result := {"ok": false, "error": message, "opponents": []}
	emit_signal("fetch_completed", result)
	return result
