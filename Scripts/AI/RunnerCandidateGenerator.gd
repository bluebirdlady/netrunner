class_name RunnerCandidateGenerator
extends RefCounted

# ── RunnerCandidateGenerator ──────────────────────────────────────────────────
# Generates legal Runner click actions from a SimState snapshot without access
# to a live GameContext.  Mirrors SnapshotCandidateGenerator for the runner.
# ─────────────────────────────────────────────────────────────────────────────

const MAX_CANDIDATES := 16

const ECONOMY_NET: Dictionary = {
	"sure_gamble": 4, "hedge_fund": 4, "lucky_find": 6,
	"bravado": 4, "creative_commission": 3
}
const DRAW_NET: Dictionary = {
	"diesel": 3, "quality_time": 5
}
const RUN_EVENT_SERVER: Dictionary = {
	"legwork":            "hq",
	"wanton_destruction": "hq",
	"the_makers_eye":     "rd",
	"dirty_laundry":      "",
}
const ICE_TO_BREAKER: Dictionary = {
	"barrier": "fracter", "code_gate": "decoder", "sentry": "killer"
}


# ── Public API ────────────────────────────────────────────────────────────────

static func generate(snap: Dictionary) -> Array:
	if (snap.get("runner_clicks_left", 0) as int) <= 0:
		return []
	var out: Array = []
	_add_basic(out, snap)
	_add_events(out, snap)
	_add_installs(out, snap)
	_add_runs(out, snap)
	if out.size() > MAX_CANDIDATES:
		out = out.slice(0, MAX_CANDIDATES)
	return out


# ── Action generators ─────────────────────────────────────────────────────────

static func _add_basic(out: Array, snap: Dictionary) -> void:
	# Gain credits — always available (capped to prevent infinite credit plans)
	if (snap.get("runner_credits", 0) as int) < 20:
		out.append(GameAction.gain_credits())
	# Draw — available if stack has cards and grip is below max
	if (snap.get("runner_deck", 0) as int) > 0 \
			and (snap.get("runner_hand_size", 0) as int) < 8:
		out.append(GameAction.draw_card())


static func _add_events(out: Array, snap: Dictionary) -> void:
	var cr: int  = snap.get("runner_credits", 0) as int
	var ran: Array = snap.get("centrals_run", []) as Array

	for rec in snap.get("runner_hand_cards", []) as Array:
		var record: CardRecord = rec as CardRecord
		if record == null or record.card_type != "event":
			continue
		var cost: int = maxi(0, record.cost)
		if cost > cr:
			continue

		# Economy events: always candidate when affordable
		if ECONOMY_NET.has(record.id):
			out.append(GameAction.play_operation(record))
			continue

		# Draw events: candidate when grip is below maximum
		if DRAW_NET.has(record.id):
			if (snap.get("runner_hand_size", 0) as int) < 6:
				out.append(GameAction.play_operation(record))
			continue

		# Run events: candidate when the target server is useful and unrun
		if RUN_EVENT_SERVER.has(record.id):
			var target: String = RUN_EVENT_SERVER[record.id] as String
			if target == "":
				# Dirty Laundry — useful if any central or remote agenda unrun
				var has_target: bool = "rd" not in ran or "hq" not in ran
				if not has_target:
					for r in snap.get("remotes", []) as Array:
						if (r as Dictionary).get("has_agenda", false):
							has_target = true
							break
				if has_target:
					out.append(GameAction.play_operation(record))
			else:
				if target not in ran:
					out.append(GameAction.play_operation(record))


static func _add_installs(out: Array, snap: Dictionary) -> void:
	var cr: int = snap.get("runner_credits", 0) as int
	# Cap total programs to prevent rig overflow in simulation
	if (snap.get("runner_prg_count", 0) as int) >= 4:
		return
	for rec in snap.get("runner_hand_cards", []) as Array:
		var record: CardRecord = rec as CardRecord
		if record == null or record.card_type != "program":
			continue
		var cost: int = maxi(0, record.cost)
		if cost > cr:
			continue
		out.append(GameAction.install(record, "runner_rig", "program"))


static func _add_runs(out: Array, snap: Dictionary) -> void:
	var cr:          int  = snap.get("runner_credits", 0) as int
	var ran:         Array = snap.get("centrals_run",   []) as Array
	var has_fracter: bool = snap.get("runner_has_fracter", false) as bool
	var has_decoder: bool = snap.get("runner_has_decoder", false) as bool
	var has_killer:  bool = snap.get("runner_has_killer",  false) as bool
	var has_ai:      bool = snap.get("runner_has_ai",      false) as bool
	var has_any:     bool = has_fracter or has_decoder or has_killer or has_ai

	# R&D run
	if "rd" not in ran:
		var rd_cost: int = (snap.get("rd_rezzed", 0) as int) * 2 \
			+ (snap.get("rd_unrezzed", 0) as int)
		var rd_breakable: bool = (snap.get("rd_rezzed", 0) as int) == 0 or has_any
		if cr >= rd_cost and rd_breakable:
			out.append(GameAction.run("rd"))

	# HQ run
	if "hq" not in ran:
		var hq_cost: int = (snap.get("hq_rezzed", 0) as int) * 2 \
			+ (snap.get("hq_unrezzed", 0) as int)
		var hq_breakable: bool = (snap.get("hq_rezzed", 0) as int) == 0 or has_any
		if cr >= hq_cost and hq_breakable:
			out.append(GameAction.run("hq"))

	# Remote runs (agenda only)
	for r in snap.get("remotes", []) as Array:
		var rd: Dictionary = r as Dictionary
		var server_id: String = rd.get("server_id", "") as String
		if not rd.get("has_agenda", false) or server_id in ran:
			continue
		var cost: int = (rd.get("rezzed_count", 0) as int) * 2 \
			+ (rd.get("unrezzed_count", 0) as int)
		if cr < cost:
			continue
		if not _remote_breakable(rd, has_fracter, has_decoder, has_killer, has_ai):
			continue
		out.append(GameAction.run(server_id))


static func _remote_breakable(
		rd:          Dictionary,
		has_fracter: bool,
		has_decoder: bool,
		has_killer:  bool,
		has_ai:      bool) -> bool:
	if has_ai:
		return true
	for sub in rd.get("rezzed_types", []) as Array:
		var needed: String = ICE_TO_BREAKER.get(sub, "") as String
		if needed == "":
			continue
		var covered: bool
		match needed:
			"fracter": covered = has_fracter
			"decoder": covered = has_decoder
			"killer":  covered = has_killer
			_:         covered = false
		if not covered:
			return false
	return true
