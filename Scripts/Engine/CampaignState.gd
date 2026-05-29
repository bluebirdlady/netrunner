class_name CampaignState
extends RefCounted

# ── CampaignState ─────────────────────────────────────────────────────────────
# Manages campaign progression: missions, fiction, unlocked card pool, current deck.
# Persists to user://campaign_save.json.

const SAVE_PATH      := "user://campaign_save.json"
const CAMPAIGN_PATH  := "res://Campaign/campaign.json"
const FICTION_PATH   := "res://Campaign/Fiction/"

var _campaign: Dictionary = {}
var _save:     Dictionary = {}

# ── Load / Save ───────────────────────────────────────────────────────────────

func load_campaign() -> bool:
	var file := FileAccess.open(CAMPAIGN_PATH, FileAccess.READ)
	if file == null:
		push_error("CampaignState: cannot open campaign.json")
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed == null or not parsed is Dictionary:
		push_error("CampaignState: campaign.json parse error")
		return false
	_campaign = parsed as Dictionary
	_load_save()
	return true


func _load_save() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		_save = _fresh_save()
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		_save = _fresh_save()
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	_save = parsed if parsed is Dictionary else _fresh_save()
	# Migrate old flat-array unlocked_cards to dict format
	var unlocked = _save.get("unlocked_cards", {})
	if unlocked is Array:
		var migrated: Dictionary = {}
		for card_id in unlocked:
			migrated[card_id] = 3
		_save["unlocked_cards"] = migrated
		persist()
	# Migrate saves that pre-date identity-as-card: ensure starter identity is present
	var starter_id: String = _campaign.get("runner_identity", "")
	if starter_id != "" and not (_save.get("unlocked_cards", {}) as Dictionary).has(starter_id):
		unlock_card(starter_id, 1)
		persist()
	# Retroactively grant any cards added to already-completed missions after the save
	# was created.  This is the only way existing saves can receive new unlocks, since
	# complete_mission() is not re-called on replay and there is no in-game save reset.
	var _completed_ids: Array = _save.get("completed_missions", [])
	var _gained_new := false
	for _mission_def in _campaign.get("missions", []):
		var _mid: String = (_mission_def as Dictionary).get("id", "")
		if _mid not in _completed_ids:
			continue
		for _unlock in (_mission_def as Dictionary).get("unlocks_cards", []):
			var _uid: String = _unlock if _unlock is String else (_unlock as Dictionary).get("id", "")
			var _award: int  = 1 if _unlock is String else (_unlock as Dictionary).get("count", 1) as int
			if _uid == "":
				continue
			var _current: int = int((_save.get("unlocked_cards", {}) as Dictionary).get(_uid, 0))
			if _current < _award:
				unlock_card(_uid, _award - _current)
				_gained_new = true
	if _gained_new:
		persist()


func _fresh_save() -> Dictionary:
	# Starter deck cards begin fully unlocked at 3 copies (2 for singletons)
	var starter_unlocks: Dictionary = {}
	for card_id in _campaign.get("runner_starter_deck", []):
		if card_id not in starter_unlocks:
			starter_unlocks[card_id] = 0
		starter_unlocks[card_id] += 1
	# Cap at 3 per card
	for k in starter_unlocks:
		starter_unlocks[k] = min(starter_unlocks[k], 3)
	# Starter identity is an unlocked card like any other — seed 1 copy
	var starter_identity: String = _campaign.get("runner_identity", "")
	if starter_identity != "":
		starter_unlocks[starter_identity] = 1

	return {
		"completed_missions": [],
		"unlocked_fiction":   [],
		"unlocked_cards":     starter_unlocks,
		"current_deck":       _default_deck(),
		"available_missions": ["act1_hb"]
	}


func _default_deck() -> Dictionary:
	# Build default deck from the campaign's runner_starter_deck list
	var cards: Dictionary = {}
	for card_id in _campaign.get("runner_starter_deck", []):
		if card_id not in cards:
			cards[card_id] = 0
		cards[card_id] += 1
	return {
		"identity": _campaign.get("runner_identity", ""),
		"cards": cards
	}


func persist() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("CampaignState: cannot write save file")
		return
	file.store_string(JSON.stringify(_save, "\t"))
	file.close()


# ── Mission queries ───────────────────────────────────────────────────────────

func get_available_missions() -> Array:
	var available: Array = _save.get("available_missions", ["act1_hb"])
	var result: Array = []
	for mission_def in _campaign.get("missions", []):
		if mission_def["id"] in available:
			result.append(mission_def)
	return result


func is_mission_complete(mission_id: String) -> bool:
	return mission_id in _save.get("completed_missions", [])


func complete_mission(mission_id: String) -> void:
	var completed: Array = _save.get("completed_missions", [])
	if mission_id not in completed:
		completed.append(mission_id)
	_save["completed_missions"] = completed

	for mission_def in _campaign.get("missions", []):
		if mission_def["id"] == mission_id:
			for next_id in mission_def.get("unlocks_missions", []):
				_unlock_mission(next_id)
			for unlock in mission_def.get("unlocks_cards", []):
				# unlock can be a string (card_id, 1 copy) or dict {id, count}
				if unlock is String:
					unlock_card(unlock, 1)
				elif unlock is Dictionary:
					unlock_card(unlock.get("id", ""), unlock.get("count", 1))
			break

	persist()


func _unlock_mission(mission_id: String) -> void:
	var available: Array = _save.get("available_missions", [])
	if mission_id not in available:
		available.append(mission_id)
	_save["available_missions"] = available


func unlock_card(card_id: String, count: int = 1) -> void:
	if card_id == "":
		return
	var unlocked: Dictionary = _save.get("unlocked_cards", {}) as Dictionary
	var current: int = int(unlocked.get(card_id, 0))
	unlocked[card_id] = min(current + count, 3)
	_save["unlocked_cards"] = unlocked


# ── Deck management ───────────────────────────────────────────────────────────

# Returns {card_id: count} of all unlocked cards
func get_unlocked_card_pool() -> Dictionary:
	return _save.get("unlocked_cards", {}) as Dictionary


# Returns {identity, cards: {card_id: count}}
func get_current_deck() -> Dictionary:
	var deck = _save.get("current_deck", null)
	if deck == null:
		_save["current_deck"] = _default_deck()
		persist()
	return _save.get("current_deck", {}) as Dictionary


func save_deck(identity_id: String, cards: Dictionary) -> void:
	_save["current_deck"] = {"identity": identity_id, "cards": cards}
	persist()


# Returns deck as flat Array[String] for use in Main/_populate_campaign_state
func get_runner_deck() -> Array:
	var deck := get_current_deck()
	var cards: Dictionary = deck.get("cards", {}) as Dictionary
	var result: Array = []
	for card_id in cards:
		var count: int = int(cards[card_id])
		for i in range(count):
			result.append(card_id)
	return result


func get_runner_identity_id() -> String:
	var deck := get_current_deck()
	return deck.get("identity", _campaign.get("runner_identity", ""))


# Returns all unique card IDs the runner could legally draw from:
# the starter deck plus every card unlockable across all missions.
# This represents the format's full runner card pool — public information
# the Corp AI can reason from without knowing the player's exact deck.
func get_full_card_pool() -> Array:
	var seen: Dictionary = {}
	for card_id in _campaign.get("runner_starter_deck", []):
		seen[card_id] = true
	for mission in _campaign.get("missions", []):
		for card_id in mission.get("unlocks_cards", []):
			seen[card_id] = true
	return seen.keys()


# ── Fiction ───────────────────────────────────────────────────────────────────

func get_fiction_text(fiction_id: String) -> String:
	var path := FICTION_PATH + fiction_id + ".txt"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "// TRANSMISSION ERROR — DATA CORRUPTED //"
	var text := file.get_as_text()
	file.close()

	var read: Array = _save.get("unlocked_fiction", [])
	if fiction_id not in read:
		read.append(fiction_id)
	_save["unlocked_fiction"] = read
	persist()
	return text


func is_fiction_read(fiction_id: String) -> bool:
	return fiction_id in _save.get("unlocked_fiction", [])


# ── Mission data accessors ────────────────────────────────────────────────────

func get_mission(mission_id: String) -> Dictionary:
	for mission_def in _campaign.get("missions", []):
		if mission_def["id"] == mission_id:
			return mission_def
	return {}


func get_opponent(opponent_id: String) -> Dictionary:
	return _campaign.get("opponents", {}).get(opponent_id, {}) as Dictionary


func campaign_title() -> String:
	return _campaign.get("title", "CAMPAIGN")

func campaign_subtitle() -> String:
	return _campaign.get("subtitle", "")


# ── Named deck saves ──────────────────────────────────────────────────────────
# Stored in the save file as "saved_decks": [{name, identity, cards}, ...]

func get_saved_decks() -> Array:
	return _save.get("saved_decks", [])


# Save (or overwrite) a named build.  Names are the unique key.
func save_named_deck(name: String, identity_id: String, cards: Dictionary) -> void:
	if name == "":
		return
	var decks: Array = _save.get("saved_decks", [])
	var entry := {"name": name, "identity": identity_id, "cards": cards}
	for i in range(decks.size()):
		if (decks[i] as Dictionary).get("name", "") == name:
			decks[i] = entry
			_save["saved_decks"] = decks
			persist()
			return
	decks.append(entry)
	_save["saved_decks"] = decks
	persist()


func delete_named_deck(name: String) -> void:
	var decks: Array = _save.get("saved_decks", [])
	decks = decks.filter(func(d): return (d as Dictionary).get("name", "") != name)
	_save["saved_decks"] = decks
	persist()
