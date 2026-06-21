class_name RunnerCandidateGenerator
extends RefCounted

const AiCardHints = preload("res://Scripts/AI/AiCardHints.gd")

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
	# Draw — the ceiling depends on whether the runner currently lacks breakers.
	# Normally we stop at the hand limit (drawing past it just produces a discard
	# at turn end with no net gain).  When no breakers are installed the runner
	# is locked out of defended servers and must cycle the deck to find one;
	# drawing over the limit is then productive (one of those cards could be a
	# breaker worth ~40 utility points), so we raise the ceiling to allow
	# multi-click search sequences across turns.  The evaluator clamps grip reward
	# at +4 above MIN_HAND (= 8 cards at default limit), so using hand_lim+3 as
	# the search ceiling matches the highest-rewarded state without generating
	# candidates the evaluator can't distinguish anyway.
	var hand_sz: int   = snap.get("runner_hand_size",  0) as int
	var hand_lim: int  = snap.get("runner_hand_limit", 5) as int
	var has_dead: bool = snap.get("runner_has_dead_card", false) as bool
	var needs_breaker: bool = not (snap.get("runner_has_fracter", false) as bool) \
		and not (snap.get("runner_has_decoder", false) as bool) \
		and not (snap.get("runner_has_killer",  false) as bool) \
		and not (snap.get("runner_has_ai",      false) as bool)
	var draw_ceiling: int = (hand_lim + 3) if needs_breaker else hand_lim
	if (snap.get("runner_deck", 0) as int) > 0 and (hand_sz < draw_ceiling or has_dead):
		out.append(GameAction.draw_card())
	# Remove 1 tag (2cr) — offered when tagged and affordable.
	if (snap.get("runner_tags", 0) as int) > 0 and (snap.get("runner_credits", 0) as int) >= 2:
		out.append(GameAction.remove_tag())


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

		# Draw events (Diesel, Quality Time): normally only offered below the hand
		# limit.  When searching for breakers, allow up to hand_lim+2 so the runner
		# can invest a click+card into finding one even at a full grip.
		if DRAW_NET.has(record.id):
			var ev_hand_lim: int = snap.get("runner_hand_limit", 5) as int
			var ev_needs_breaker: bool = \
				not (snap.get("runner_has_fracter", false) as bool) \
				and not (snap.get("runner_has_decoder", false) as bool) \
				and not (snap.get("runner_has_killer",  false) as bool) \
				and not (snap.get("runner_has_ai",      false) as bool)
			var ev_ceiling: int = (ev_hand_lim + 2) if ev_needs_breaker else ev_hand_lim
			if (snap.get("runner_hand_size", 0) as int) < ev_ceiling:
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

		# Hint-based events: offered when all declared conditions are met
		elif AiCardHints.has_hint(record.id):
			if AiCardHints.condition_met(record.id, snap):
				out.append(GameAction.play_operation(record))


static func _add_installs(out: Array, snap: Dictionary) -> void:
	var cr: int      = snap.get("runner_credits", 0) as int
	var mu_used: int = snap.get("runner_mu_used",  0) as int
	var mu_max: int  = snap.get("runner_mu_max",   4) as int
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
		# MU check: don't offer installs that would exceed memory limit.
		var mu_cost: int = record.memory_cost if record.memory_cost > 0 else 1
		if mu_used + mu_cost > mu_max:
			continue
		out.append(GameAction.install(record, "runner_rig", "program"))


static func _add_runs(out: Array, snap: Dictionary) -> void:
	var cr:          int   = snap.get("runner_credits",   0) as int
	var corp_cr:     int   = snap.get("corp_credits",     0) as int
	var ran:         Array = snap.get("centrals_run",    []) as Array
	var has_fracter: bool  = snap.get("runner_has_fracter", false) as bool
	var has_decoder: bool  = snap.get("runner_has_decoder", false) as bool
	var has_killer:  bool  = snap.get("runner_has_killer",  false) as bool
	var has_ai:      bool  = snap.get("runner_has_ai",      false) as bool

	# Per-piece cost for unrezzed ICE, scaled by Corp credits.
	# A wealthy Corp is essentially certain to rez on approach.
	var unrez_per_ice: int = _unrezzed_ice_cost(corp_cr)

	# R&D run
	if "rd" not in ran:
		var rd_rezzed_cost: int = snap.get("break_cost_rd",
			(snap.get("rd_rezzed", 0) as int) * 2) as int
		var rd_cost: int = rd_rezzed_cost \
			+ (snap.get("rd_unrezzed", 0) as int) * unrez_per_ice
		var rd_types: Array = snap.get("rd_rezzed_types", []) as Array
		if cr >= rd_cost and _types_breakable(rd_types, has_fracter, has_decoder, has_killer, has_ai):
			out.append(GameAction.run("rd"))

	# HQ run
	if "hq" not in ran:
		var hq_rezzed_cost: int = snap.get("break_cost_hq",
			(snap.get("hq_rezzed", 0) as int) * 2) as int
		var hq_cost: int = hq_rezzed_cost \
			+ (snap.get("hq_unrezzed", 0) as int) * unrez_per_ice
		var hq_types: Array = snap.get("hq_rezzed_types", []) as Array
		if cr >= hq_cost and _types_breakable(hq_types, has_fracter, has_decoder, has_killer, has_ai):
			out.append(GameAction.run("hq"))

	# Remote runs (agenda only) — blocked when corp identity requires a central run first
	# and no central has been run yet this turn (mirrors TurnManager enforcement).
	var central_first: bool = snap.get("corp_requires_central_first", false) as bool
	if central_first and ran.is_empty():
		return
	for r in snap.get("remotes", []) as Array:
		var rd: Dictionary = r as Dictionary
		var server_id: String = rd.get("server_id", "") as String
		if not rd.get("has_agenda", false) or server_id in ran:
			continue
		var remote_rezzed_cost: int = rd.get("break_cost",
			(rd.get("rezzed_count", 0) as int) * 2) as int
		var cost: int = remote_rezzed_cost \
			+ (rd.get("unrezzed_count", 0) as int) * unrez_per_ice
		if cr < cost:
			continue
		if not _remote_breakable(rd, has_fracter, has_decoder, has_killer, has_ai):
			continue
		out.append(GameAction.run(server_id))


# Per-piece credit cost to budget for unrezzed ICE, scaled by Corp credits.
# Mirrors RunnerStateEvaluator._unrezzed_ice_cost_per_piece — must stay in sync.
static func _unrezzed_ice_cost(corp_cr: int) -> int:
	if corp_cr < 4:  return 1
	if corp_cr < 8:  return 2
	if corp_cr < 12: return 3
	return 4


static func _remote_breakable(
		rd:          Dictionary,
		has_fracter: bool,
		has_decoder: bool,
		has_killer:  bool,
		has_ai:      bool) -> bool:
	return _types_breakable(rd.get("rezzed_types", []) as Array,
		has_fracter, has_decoder, has_killer, has_ai)


static func _types_breakable(
		types:       Array,
		has_fracter: bool,
		has_decoder: bool,
		has_killer:  bool,
		has_ai:      bool) -> bool:
	if types.is_empty() or has_ai:
		return true
	for sub in types:
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
