class_name GameAction
extends RefCounted

# ── GameAction ────────────────────────────────────────────────────────────────
# Immutable description of a single action a player wants to take.
# The TurnManager validates and executes these.
# Neither the decision maker nor the UI mutate game state directly —
# they produce GameActions and hand them to the TurnManager.

var type:   String     = ""
var params: Dictionary = {}


# ── Factory methods ───────────────────────────────────────────────────────────

static func gain_credits() -> GameAction:
	return _make("gain_credits", {})

static func draw_card() -> GameAction:
	return _make("draw_card", {})

static func install(card_record: CardRecord, server_id: String, zone: String = "root") -> GameAction:
	return _make("install", {
		"card_record": card_record,
		"server_id":   server_id,
		"zone":        zone
	})

static func advance(card_id: String) -> GameAction:
	return _make("advance", {"card_id": card_id})

static func play_operation(card_record: CardRecord) -> GameAction:
	return _make("play_operation", {"card_record": card_record})

static func run(server_id: String) -> GameAction:
	return _make("run", {"server_id": server_id})

static func use_installed_card(instance_id: String, card_id: String) -> GameAction:
	return _make("use_installed_card", {"card_instance_id": instance_id, "card_id": card_id})

static func end_turn() -> GameAction:
	return _make("end_turn", {})

static func pass_window() -> GameAction:
	return _make("pass", {})

static func rez_card(card_id: String, instance_id: String = "") -> GameAction:
	return _make("rez_card", {"card_id": card_id, "card_instance_id": instance_id})

# Petty Cash: spend [click], play the named operation from Archives, then RFG it.
static func play_from_archives(card_id: String) -> GameAction:
	return _make("play_from_archives", {"card_id": card_id})


# ── Display ───────────────────────────────────────────────────────────────────

func describe() -> String:
	match type:
		"gain_credits":   return "Gain 1 credit"
		"draw_card":      return "Draw 1 card"
		"end_turn":       return "End turn"
		"run":            return "Run on %s" % params.get("server_id", "?")
		"advance":        return "Advance %s" % params.get("card_id", "?")
		"play_operation":
			var r: CardRecord = params.get("card_record", null)
			return "Play %s" % (r.title if r else "?")
		"install":
			var r: CardRecord = params.get("card_record", null)
			return "Install %s in %s" % [r.title if r else "?", params.get("server_id", "?")]
		"pass":               return "Pass priority"
		"rez_card":          return "Rez %s" % params.get("card_id", "?")
		"use_installed_card": return "Use %s" % params.get("card_id", "?")
		"play_from_archives": return "Play %s from Archives" % params.get("card_id", "?")
		_:
			return type


# ── Internal ──────────────────────────────────────────────────────────────────

static func _make(action_type: String, action_params: Dictionary) -> GameAction:
	var a        := GameAction.new()
	a.type        = action_type
	a.params      = action_params
	return a
