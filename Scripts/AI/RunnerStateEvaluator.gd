class_name RunnerStateEvaluator
extends RefCounted

# ── RunnerStateEvaluator ──────────────────────────────────────────────────────
# Converts a live GameContext into a lightweight SimState snapshot and
# evaluates runner turn plans from the runner's perspective.
#
# Snapshot schema
# ─────────────────────────────────────────────────────────────────────────────
#   runner_credits    : int
#   runner_hand_size  : int
#   runner_hand_cards : Array[CardRecord]  — cards available to play/install
#   runner_deck       : int   — stack size
#   runner_score      : int   — agenda points
#   corp_score        : int
#   pts_to_win        : int
#   runner_clicks_left: int
#   runner_has_fracter: bool
#   runner_has_decoder: bool
#   runner_has_killer : bool
#   runner_has_ai     : bool
#   runner_prg_count  : int
#   centrals_run      : Array[String]
#   hq_rezzed         : int
#   hq_unrezzed       : int
#   rd_rezzed         : int
#   rd_unrezzed       : int
#   remotes           : Array[Dictionary]
#                       each: {server_id, rezzed_count, unrezzed_count, rezzed_types, has_agenda, agenda_pts}
#   agenda_pts_accrued: float  — expected agenda value from central accesses in this plan
# ─────────────────────────────────────────────────────────────────────────────

const WIN_VALUE  :=  10000.0
const LOSE_VALUE := -10000.0

const CREDIT_FLOOR       := 5
const BREAKER_VALUE      := 40.0   # per covered breaker type
const AI_BREAKER_BONUS   := 40.0   # extra for AI covering all types
const UNCOVERED_ICE_COST := 25.0   # penalty per rezzed ICE type with no breaker
const CREDIT_SURPLUS_VAL := 2.0    # per credit above floor (clamped)
const GRIP_SURPLUS_VAL   := 3.0    # per card above MIN_HAND (clamped)
const CENTRAL_RUN_VALUE  := 12.0   # per central visited this plan
const MIN_HAND           := 4

# Expected agenda points per single card accessed on a central server.
const RD_EXPECTED_PTS_PER_ACCESS := 0.12
const HQ_EXPECTED_PTS_PER_ACCESS := 0.08

# Converts expected pts into utility units (calibrated to WIN_VALUE / average pts_to_win).
const EXPECTED_PTS_MULTIPLIER := WIN_VALUE / 7.0   # ≈ 1428 per expected pt

# Net credit gains for known economy events.
const ECONOMY_NET: Dictionary = {
	"sure_gamble": 4, "hedge_fund": 4, "lucky_find": 6,
	"bravado": 4, "creative_commission": 3
}
# Net draws for known draw events.
const DRAW_NET: Dictionary = {
	"diesel": 3, "quality_time": 5
}
# Run events mapped to their default target server.
const RUN_EVENT_SERVER: Dictionary = {
	"legwork":            "hq",
	"wanton_destruction": "hq",
	"the_makers_eye":     "rd",
	"dirty_laundry":      "",    # any server — resolved at projection time
}

const ICE_TO_BREAKER: Dictionary = {
	"barrier": "fracter", "code_gate": "decoder", "sentry": "killer"
}


# ── Snapshot builder ──────────────────────────────────────────────────────────

func snapshot(ctx: GameContext) -> Dictionary:
	var snap: Dictionary = {}

	snap["runner_credits"]     = ctx.runner_credits
	snap["runner_hand_size"]   = ctx.runner_hand.size()
	snap["runner_deck"]        = ctx.runner_deck.size()
	snap["runner_score"]       = ctx.runner_agenda_points()
	snap["corp_score"]         = ctx.corp_agenda_points()
	snap["pts_to_win"]         = ctx.agenda_points_to_win
	snap["runner_clicks_left"] = ctx.runner_clicks
	snap["centrals_run"]       = ctx.runner_centrals_run_this_turn.duplicate()
	snap["agenda_pts_accrued"] = 0.0

	# Hand cards — store CardRecord references (cheap; not cloned)
	var hand_cards: Array = []
	for entry in ctx.runner_hand:
		var rec: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if rec != null:
			hand_cards.append(rec)
	snap["runner_hand_cards"] = hand_cards

	# Rig breaker coverage
	var has_fracter := false
	var has_decoder := false
	var has_killer  := false
	var has_ai      := false
	var prg_count   := 0
	for rig_any in ctx.runner_rig:
		var b: InstalledCard = rig_any as InstalledCard
		if b == null or b.card_record == null or b.card_record.card_type != "program":
			continue
		prg_count += 1
		for sub in b.card_record.subtypes:
			match sub:
				"fracter": has_fracter = true
				"decoder": has_decoder = true
				"killer":  has_killer  = true
				"ai":      has_ai      = true
	snap["runner_has_fracter"] = has_fracter
	snap["runner_has_decoder"] = has_decoder
	snap["runner_has_killer"]  = has_killer
	snap["runner_has_ai"]      = has_ai
	snap["runner_prg_count"]   = prg_count

	# Central server ICE counts
	var hq: Server = ctx.servers.get("hq", null) as Server
	var rd: Server = ctx.servers.get("rd", null) as Server
	snap["hq_rezzed"]   = _count_rezzed(hq)
	snap["hq_unrezzed"] = _count_unrezzed(hq)
	snap["rd_rezzed"]   = _count_rezzed(rd)
	snap["rd_unrezzed"] = _count_unrezzed(rd)

	# Remote servers
	var remotes: Array = []
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s == null or not s.is_remote():
			continue
		var rez_count   := 0
		var unrez_count := 0
		var rez_types:   Array = []
		for ice_any in s.ice:
			var ic: InstalledCard = ice_any as InstalledCard
			if ic == null:
				continue
			if ic.is_rezzed:
				rez_count += 1
				if ic.card_record != null:
					for sub in ic.card_record.subtypes:
						if sub not in rez_types:
							rez_types.append(sub)
			else:
				unrez_count += 1
		var card: InstalledCard = s.get_agenda_or_asset()
		var has_agenda := card != null and card.card_record != null \
			and card.card_record.is_agenda()
		var pts: int = 0
		if has_agenda and card != null and card.card_record != null:
			pts = card.card_record.agenda_points
		remotes.append({
			"server_id":      s.server_id,
			"rezzed_count":   rez_count,
			"unrezzed_count": unrez_count,
			"rezzed_types":   rez_types,
			"has_agenda":     has_agenda,
			"agenda_pts":     pts,
		})
	snap["remotes"] = remotes

	return snap


# ── Evaluate ──────────────────────────────────────────────────────────────────

func evaluate(snap: Dictionary) -> float:
	var pts_to_win:   int = snap.get("pts_to_win",   7) as int
	var runner_score: int = snap.get("runner_score", 0) as int
	var corp_score:   int = snap.get("corp_score",   0) as int

	if runner_score >= pts_to_win: return WIN_VALUE
	if corp_score   >= pts_to_win: return LOSE_VALUE

	var u: float = 0.0

	# Score position — dominant dimension
	var pts_scale: float = WIN_VALUE / float(pts_to_win)
	u += float(runner_score) * pts_scale
	u -= float(corp_score)   * pts_scale * 0.6

	# Expected agenda value accrued from central accesses in this plan
	u += snap.get("agenda_pts_accrued", 0.0) as float

	# Credit surplus above safety floor
	var cr: int = snap.get("runner_credits", 0) as int
	u += CREDIT_SURPLUS_VAL * clampf(float(cr - CREDIT_FLOOR), -8.0, 12.0)

	# Grip health
	var grip: int = snap.get("runner_hand_size", 0) as int
	u += GRIP_SURPLUS_VAL * clampf(float(grip - MIN_HAND), -4.0, 4.0)

	# Breaker suite completeness
	var has_fracter: bool = snap.get("runner_has_fracter", false) as bool
	var has_decoder: bool = snap.get("runner_has_decoder", false) as bool
	var has_killer:  bool = snap.get("runner_has_killer",  false) as bool
	var has_ai:      bool = snap.get("runner_has_ai",      false) as bool
	if has_fracter or has_ai: u += BREAKER_VALUE
	if has_decoder or has_ai: u += BREAKER_VALUE
	if has_killer  or has_ai: u += BREAKER_VALUE
	if has_ai:                 u += AI_BREAKER_BONUS

	# Penalty for rezzed remote ICE types with no matching breaker
	var uncovered: Dictionary = {}
	for r in snap.get("remotes", []) as Array:
		var rd: Dictionary = r as Dictionary
		for sub in rd.get("rezzed_types", []) as Array:
			var needed: String = ICE_TO_BREAKER.get(sub, "") as String
			if needed == "" or uncovered.has(needed):
				continue
			var covered: bool
			match needed:
				"fracter": covered = has_fracter or has_ai
				"decoder": covered = has_decoder or has_ai
				"killer":  covered = has_killer  or has_ai
				_:         covered = true
			if not covered:
				uncovered[needed] = true
	u -= UNCOVERED_ICE_COST * float(uncovered.size())

	# Central run pressure bonus (for centrals run during this plan)
	var ran: Array = snap.get("centrals_run", []) as Array
	for server_id in ran:
		if server_id in ["rd", "hq"]:
			u += CENTRAL_RUN_VALUE

	return u


# ── Action projector ──────────────────────────────────────────────────────────

func project_runner_action(snap: Dictionary, action: GameAction) -> Dictionary:
	var s: Dictionary = snap.duplicate()
	# Deep-copy mutable arrays so branches are independent.
	s["runner_hand_cards"] = (snap.get("runner_hand_cards", []) as Array).duplicate()
	s["centrals_run"]      = (snap.get("centrals_run", []) as Array).duplicate()
	s["remotes"]           = (snap.get("remotes", []) as Array).duplicate()
	s["runner_clicks_left"] = (snap.get("runner_clicks_left", 0) as int) - 1

	match action.type:
		"gain_credits":
			s["runner_credits"] = (snap.get("runner_credits", 0) as int) + 1

		"draw_card":
			s["runner_hand_size"] = (snap.get("runner_hand_size", 0) as int) + 1
			s["runner_deck"]      = maxi(0, (snap.get("runner_deck", 0) as int) - 1)

		"play_operation":
			var rec: CardRecord = action.params.get("card_record", null) as CardRecord
			if rec != null:
				_remove_from_hand(s, rec)
				s["runner_hand_size"] = maxi(0, (snap.get("runner_hand_size", 0) as int) - 1)
				var cost: int = maxi(0, rec.cost)
				# Economy event: overrides simple cost deduction with net gain.
				var net: int = ECONOMY_NET.get(rec.id, 0)
				if net > 0:
					s["runner_credits"] = (snap.get("runner_credits", 0) as int) + net
				# Draw event: free, adds cards to grip.
				elif DRAW_NET.has(rec.id):
					s["runner_credits"] = (snap.get("runner_credits", 0) as int) - cost
					s["runner_hand_size"] = (s.get("runner_hand_size", 0) as int) \
						+ (DRAW_NET.get(rec.id, 0) as int)
					s["runner_deck"] = maxi(0, (snap.get("runner_deck", 0) as int) \
						- (DRAW_NET.get(rec.id, 0) as int))
				# Run event: pay cost, accrue run value on the target server.
				elif RUN_EVENT_SERVER.has(rec.id):
					s["runner_credits"] = maxi(0, (snap.get("runner_credits", 0) as int) - cost)
					var target: String = _resolve_run_event_target(rec.id, snap)
					_apply_run(s, target)
				else:
					s["runner_credits"] = maxi(0, (snap.get("runner_credits", 0) as int) - cost)

		"install":
			var rec: CardRecord = action.params.get("card_record", null) as CardRecord
			if rec != null and rec.card_type == "program":
				_remove_from_hand(s, rec)
				s["runner_hand_size"] = maxi(0, (snap.get("runner_hand_size", 0) as int) - 1)
				var cost: int = maxi(0, rec.cost)
				s["runner_credits"]  = maxi(0, (snap.get("runner_credits", 0) as int) - cost)
				s["runner_prg_count"] = (snap.get("runner_prg_count", 0) as int) + 1
				for sub in rec.subtypes:
					match sub:
						"fracter": s["runner_has_fracter"] = true
						"decoder": s["runner_has_decoder"] = true
						"killer":  s["runner_has_killer"]  = true
						"ai":      s["runner_has_ai"]      = true

		"run":
			var server_id: String = action.params.get("server_id", "") as String
			_apply_run(s, server_id)

	return s


# ── Internal helpers ──────────────────────────────────────────────────────────

func _apply_run(s: Dictionary, server_id: String) -> void:
	if server_id == "":
		return
	# Deduct estimated break cost.
	var cost: int = _break_cost(server_id, s)
	s["runner_credits"] = maxi(0, (s.get("runner_credits", 0) as int) - cost)
	# Mark as run (dedup for centrals).
	var ran: Array = s.get("centrals_run", []) as Array
	if server_id not in ran:
		ran.append(server_id)
	s["centrals_run"] = ran
	# Accrue expected access value.
	if server_id == "rd":
		s["agenda_pts_accrued"] = (s.get("agenda_pts_accrued", 0.0) as float) \
			+ RD_EXPECTED_PTS_PER_ACCESS * EXPECTED_PTS_MULTIPLIER
	elif server_id == "hq":
		s["agenda_pts_accrued"] = (s.get("agenda_pts_accrued", 0.0) as float) \
			+ HQ_EXPECTED_PTS_PER_ACCESS * EXPECTED_PTS_MULTIPLIER
	else:
		# Remote: high-confidence agenda steal — update runner_score directly.
		for r in s.get("remotes", []) as Array:
			var rd: Dictionary = r as Dictionary
			if rd.get("server_id", "") == server_id and rd.get("has_agenda", false):
				var pts: int = rd.get("agenda_pts", 2) as int
				s["runner_score"] = (s.get("runner_score", 0) as int) + pts
				break


func _break_cost(server_id: String, snap: Dictionary) -> int:
	match server_id:
		"hq":
			return (snap.get("hq_rezzed", 0) as int) * 2 \
				+ (snap.get("hq_unrezzed", 0) as int)
		"rd":
			return (snap.get("rd_rezzed", 0) as int) * 2 \
				+ (snap.get("rd_unrezzed", 0) as int)
		"archives":
			return 0
	for r in snap.get("remotes", []) as Array:
		var rd: Dictionary = r as Dictionary
		if rd.get("server_id", "") == server_id:
			return (rd.get("rezzed_count", 0) as int) * 2 \
				+ (rd.get("unrezzed_count", 0) as int)
	return 0


func _resolve_run_event_target(card_id: String, snap: Dictionary) -> String:
	# Dirty Laundry can target any server — pick best unrun central or remote.
	if card_id == "dirty_laundry":
		var ran: Array = snap.get("centrals_run", []) as Array
		if "rd" not in ran:
			return "rd"
		if "hq" not in ran:
			return "hq"
		for r in snap.get("remotes", []) as Array:
			var rd: Dictionary = r as Dictionary
			if rd.get("has_agenda", false):
				return rd.get("server_id", "archives") as String
		return "archives"
	return RUN_EVENT_SERVER.get(card_id, "rd") as String


func _remove_from_hand(s: Dictionary, rec: CardRecord) -> void:
	var hand: Array = s.get("runner_hand_cards", []) as Array
	hand.erase(rec)
	s["runner_hand_cards"] = hand


static func _count_rezzed(server: Server) -> int:
	if server == null:
		return 0
	var n := 0
	for ice_any in server.ice:
		var ic: InstalledCard = ice_any as InstalledCard
		if ic != null and ic.is_rezzed:
			n += 1
	return n


static func _count_unrezzed(server: Server) -> int:
	if server == null:
		return 0
	var n := 0
	for ice_any in server.ice:
		var ic: InstalledCard = ice_any as InstalledCard
		if ic != null and not ic.is_rezzed:
			n += 1
	return n
