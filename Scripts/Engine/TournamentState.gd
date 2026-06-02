class_name TournamentState
extends RefCounted

# ── TournamentState ───────────────────────────────────────────────────────────
# Owns tournament progression: the 6 opponent pool, round results, and rating.
# Persists to user://tournament_save.json so a tournament can survive restarts.

const SAVE_PATH    := "user://tournament_save.json"
const ROUND_COUNT  := 6

# Rating tiers — index 0 = 6 wins, index 6 = 0 wins.
const RATINGS := [
	{"wins": 6, "title": "TOURNAMENT CHAMPION",   "subtitle": "Perfect run. They'll be talking about this one."},
	{"wins": 5, "title": "CIRCUIT WINNER",         "subtitle": "One slip. Still the best in the room."},
	{"wins": 4, "title": "REGIONAL FINALIST",      "subtitle": "Top cut. You belong here."},
	{"wins": 3, "title": "CONSISTENT COMPETITOR",  "subtitle": "Even split. You know what you're doing."},
	{"wins": 2, "title": "PROMISING CONTENDER",    "subtitle": "More losses than wins, but you're learning."},
	{"wins": 1, "title": "LEARNING THE GAME",      "subtitle": "One win to build on. Come back stronger."},
	{"wins": 0, "title": "HONORABLE PARTICIPANT",  "subtitle": "You showed up. That counts for something."},
]

# ── State ─────────────────────────────────────────────────────────────────────

var _save: Dictionary = {}


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func load_or_new() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			file.close()
			if parsed is Dictionary:
				_save = parsed as Dictionary
				return
	_save = _empty_save()


func persist() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("TournamentState: cannot write save")
		return
	file.store_string(JSON.stringify(_save, "\t"))
	file.close()


func clear() -> void:
	_save = _empty_save()
	persist()


# ── Tournament setup ──────────────────────────────────────────────────────────

# Initialise a new tournament from a fetched pool.
# Picks 6 opponents: tries to get faction diversity, falls back to random.
func start_new_tournament(pool: Array) -> void:
	var picked := _pick_diverse(pool, ROUND_COUNT)
	_save["opponents"] = picked
	_save["results"]   = []     # Array of bools: true = win
	_save["active"]    = true
	_save["fetched_at"] = Time.get_datetime_string_from_system()
	persist()


func _pick_diverse(pool: Array, count: int) -> Array:
	if pool.size() <= count:
		return pool.duplicate()

	# Bucket by faction, pick one from each faction first, then fill randomly.
	var by_faction: Dictionary = {}
	for opp in pool:
		var f: String = opp.get("faction", "unknown")
		if not by_faction.has(f):
			by_faction[f] = []
		(by_faction[f] as Array).append(opp)

	var picked: Array = []
	var factions := by_faction.keys()
	factions.shuffle()
	for f in factions:
		if picked.size() >= count:
			break
		var bucket: Array = by_faction[f] as Array
		bucket.shuffle()
		picked.append(bucket[0])

	# Fill remaining slots from pool without duplicating picked identities.
	if picked.size() < count:
		var used_ids := {}
		for p in picked:
			used_ids[p.get("nrdb_id", "")] = true
		var remainder := pool.filter(func(o): return not used_ids.has(o.get("nrdb_id", "")))
		remainder.shuffle()
		for o in remainder:
			if picked.size() >= count:
				break
			picked.append(o)

	return picked.slice(0, count)


# ── Progress ──────────────────────────────────────────────────────────────────

func has_active_tournament() -> bool:
	return _save.get("active", false) as bool

func is_complete() -> bool:
	return has_active_tournament() and results().size() >= ROUND_COUNT

func current_round() -> int:
	return results().size()   # 0-based: 0 = about to play round 1

func results() -> Array:
	return _save.get("results", []) as Array

func wins() -> int:
	return results().filter(func(r): return r == true).size()

func losses() -> int:
	return results().filter(func(r): return r == false).size()

func opponents() -> Array:
	return _save.get("opponents", []) as Array

func current_opponent() -> Dictionary:
	var idx := current_round()
	var opps := opponents()
	if idx >= opps.size():
		return {}
	return opps[idx] as Dictionary

func record_result(runner_wins: bool) -> void:
	var res: Array = _save.get("results", []) as Array
	res.append(runner_wins)
	_save["results"] = res
	if res.size() >= ROUND_COUNT:
		_save["active"] = false
	persist()


# ── Rating ────────────────────────────────────────────────────────────────────

func get_rating() -> Dictionary:
	var w := wins()
	for tier in RATINGS:
		if (tier as Dictionary).get("wins", -1) == w:
			return tier as Dictionary
	return RATINGS[RATINGS.size() - 1] as Dictionary


# ── Helpers ───────────────────────────────────────────────────────────────────

func _empty_save() -> Dictionary:
	return {
		"active":     false,
		"opponents":  [],
		"results":    [],
		"fetched_at": ""
	}
