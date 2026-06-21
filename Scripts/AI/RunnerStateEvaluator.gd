class_name RunnerStateEvaluator
extends RefCounted

const AiCardHints = preload("res://Scripts/AI/AiCardHints.gd")

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
#   hq_rezzed_types   : Array[String]  — subtypes of rezzed ICE on HQ
#   rd_rezzed         : int
#   rd_unrezzed       : int
#   rd_rezzed_types   : Array[String]  — subtypes of rezzed ICE on RD
#   remotes           : Array[Dictionary]
#                       each: {server_id, rezzed_count, unrezzed_count, rezzed_types, has_agenda, agenda_pts}
#   agenda_pts_accrued: float  — expected agenda value from central accesses in this plan
#   runner_event_projections: Dictionary  — card_id → merged projection (see _merge_projection)
#                              built once per snapshot; P4 projector reads from here instead
#                              of re-querying AbilityRegistry/AiCardHints each step.
# ─────────────────────────────────────────────────────────────────────────────

const WIN_VALUE  :=  10000.0
const LOSE_VALUE := -10000.0

const CREDIT_FLOOR       := 5
const AI_BREAKER_BONUS   := 40.0   # extra for AI covering all types
const MIN_HAND           := 4

# Tunable evaluation weights — overrideable via apply_weights().
var BREAKER_VALUE      := 40.0   # per covered breaker type
var UNCOVERED_ICE_COST := 25.0   # penalty per rezzed ICE type with no breaker
var CREDIT_SURPLUS_VAL := 2.0    # per credit above floor (clamped)
var GRIP_SURPLUS_VAL   := 3.0    # per card above MIN_HAND (clamped)
var CENTRAL_RUN_VALUE  := 12.0   # per central visited this plan
var tag_penalty_per_tag := 20.0  # utility penalty per tag held

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


# ── Weight overrides (for evolutionary tuner) ────────────────────────────────

func apply_weights(weights: Dictionary) -> void:
	if weights.has("BREAKER_VALUE"):      BREAKER_VALUE      = float(weights["BREAKER_VALUE"])
	if weights.has("UNCOVERED_ICE_COST"): UNCOVERED_ICE_COST = float(weights["UNCOVERED_ICE_COST"])
	if weights.has("CREDIT_SURPLUS_VAL"): CREDIT_SURPLUS_VAL = float(weights["CREDIT_SURPLUS_VAL"])
	if weights.has("GRIP_SURPLUS_VAL"):   GRIP_SURPLUS_VAL   = float(weights["GRIP_SURPLUS_VAL"])
	if weights.has("CENTRAL_RUN_VALUE"):  CENTRAL_RUN_VALUE  = float(weights["CENTRAL_RUN_VALUE"])
	if weights.has("tag_penalty_per_tag"): tag_penalty_per_tag = float(weights["tag_penalty_per_tag"])


# ── Snapshot builder ──────────────────────────────────────────────────────────

func snapshot(ctx: GameContext) -> Dictionary:
	var snap: Dictionary = {}

	snap["runner_credits"]     = ctx.runner_credits
	snap["runner_hand_size"]   = ctx.runner_hand.size()
	snap["runner_deck"]        = ctx.runner_deck.size()
	snap["runner_score"]       = ctx.runner_agenda_points()
	snap["corp_score"]         = ctx.corp_agenda_points()
	snap["corp_credits"]       = ctx.corp_credits
	snap["pts_to_win"]         = ctx.agenda_points_to_win
	snap["runner_clicks_left"] = ctx.runner_clicks
	snap["centrals_run"]          = ctx.runner_centrals_run_this_turn.duplicate()
	var corp_id: String = ctx.corp_identity.id if ctx.corp_identity != null else ""
	snap["corp_requires_central_first"] = corp_id == "jinteki_replicating_perfection"
	snap["agenda_pts_accrued"]    = 0.0
	snap["event_value_accrued"]   = 0.0

	# Hand cards — store CardRecord references (cheap; not cloned).
	# Also track composition flags needed by AiCardHints condition evaluator.
	var hand_cards: Array = []
	var hand_has_prg_hw    := false
	var hand_has_resource  := false
	var installable_count  := 0
	for entry in ctx.runner_hand:
		var rec: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if rec == null:
			continue
		hand_cards.append(rec)
		match rec.card_type:
			"program", "hardware":
				hand_has_prg_hw = true
				if maxi(0, rec.cost) <= ctx.runner_credits:
					installable_count += 1
			"resource":
				hand_has_resource = true
				if maxi(0, rec.cost) <= ctx.runner_credits:
					installable_count += 1
	snap["runner_hand_cards"]             = hand_cards
	snap["runner_hand_has_prg_hw"]        = hand_has_prg_hw
	snap["runner_hand_has_resource"]      = hand_has_resource
	snap["runner_installable_hand_count"] = installable_count

	# Rig breaker coverage + MU usage
	var has_fracter := false
	var has_decoder := false
	var has_killer  := false
	var has_ai      := false
	var prg_count   := 0
	var mu_used     := 0
	for rig_any in ctx.runner_rig:
		var b: InstalledCard = rig_any as InstalledCard
		if b == null or b.card_record == null or b.card_record.card_type != "program":
			continue
		prg_count += 1
		var mc: int = b.card_record.memory_cost
		if mc > 0:
			mu_used += mc
		else:
			mu_used += 1   # programs that don't specify MU still cost 1
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
	snap["runner_mu_used"]     = mu_used
	snap["runner_mu_max"]      = ctx.runner_total_mu()

	# Max count of installed cards that share the same printed cost (used by Khusyuk).
	var cost_groups: Dictionary = {}
	for rig_k in ctx.runner_rig:
		var ic_k: InstalledCard = rig_k as InstalledCard
		if ic_k == null or ic_k.card_record == null:
			continue
		var c: int = ic_k.card_record.cost
		cost_groups[c] = (cost_groups.get(c, 0) as int) + 1
	var max_cost_group: int = 0
	for cnt in cost_groups.values():
		if (cnt as int) > max_cost_group:
			max_cost_group = cnt as int
	snap["runner_max_cost_installed"] = max_cost_group

	# Dead-hand detection: true when the grip contains a card that is worthless
	# to keep — either a duplicate of an already-installed program, or a second
	# copy of a unique card that is already installed anywhere in the rig.
	# When true, a draw click has cycling value even above the hand limit.
	var installed_ids: Dictionary = {}
	for rig_any2 in ctx.runner_rig:
		var rc2: InstalledCard = rig_any2 as InstalledCard
		if rc2 != null and rc2.card_record != null:
			installed_ids[rc2.card_id] = true
	var has_dead_card := false
	for hand_entry in ctx.runner_hand:
		var hand_rec: CardRecord = (hand_entry as Dictionary).get("card_record", null) as CardRecord
		if hand_rec == null:
			continue
		if installed_ids.has(hand_rec.id):
			# Duplicate of an installed card — worthless if unique or already covers
			# the breaker type we need.
			if hand_rec.is_unique or hand_rec.card_type == "program":
				has_dead_card = true
				break
	snap["runner_has_dead_card"] = has_dead_card
	snap["runner_hand_limit"]   = ctx.runner_max_hand_size()

	# Tag count and heap state for AiCardHints conditions.
	snap["runner_tags"]      = ctx.runner_tags
	snap["runner_heap_size"] = ctx.runner_discard.size()
	var heap_has_prg := false
	for h_entry in ctx.runner_discard:
		var h_rec: CardRecord = h_entry as CardRecord
		if h_rec != null and h_rec.card_type == "program":
			heap_has_prg = true
			break
	snap["runner_heap_has_program"] = heap_has_prg

	# Agenda-stolen flag: starts false; set to true by _apply_run when a remote
	# agenda is accessed in this projection sequence (enables Reprise).
	snap["runner_stole_agenda_this_turn"] = false

	# Ability registry — used for break-cost computation and event projections.
	var ab_reg: AbilityRegistry = null
	if ctx.has_meta("ability_registry"):
		ab_reg = ctx.get_meta("ability_registry") as AbilityRegistry

	# Pre-compute projections for every event card currently in hand.
	# Merges AbilityRegistry auto-projection (Layer 1) with AiCardHints (Layer 2).
	# Stored once here so the beam-search projector can read without re-querying.
	var event_projections: Dictionary = {}
	for ep_rec in hand_cards:
		var ep_card: CardRecord = ep_rec as CardRecord
		if ep_card == null or ep_card.card_type != "event":
			continue
		var auto_proj: Variant = ab_reg.get_ai_projection(ep_card.id) if ab_reg != null else null
		var hint: Dictionary = AiCardHints.get_hint(ep_card.id)
		var merged: Variant = _merge_projection(auto_proj, hint)
		if merged != null:
			event_projections[ep_card.id] = merged
	snap["runner_event_projections"] = event_projections

	# Central server ICE counts + actual rezzed break costs
	var hq: Server = ctx.servers.get("hq", null) as Server
	var rd: Server = ctx.servers.get("rd", null) as Server
	snap["hq_rezzed"]       = _count_rezzed(hq)
	snap["hq_unrezzed"]     = _count_unrezzed(hq)
	snap["hq_rezzed_types"] = _rezzed_server_types(hq)
	snap["rd_rezzed"]       = _count_rezzed(rd)
	snap["rd_unrezzed"]     = _count_unrezzed(rd)
	snap["rd_rezzed_types"] = _rezzed_server_types(rd)
	snap["break_cost_hq"]   = _rezzed_server_break_cost(hq, ctx.runner_rig, ab_reg)
	snap["break_cost_rd"]   = _rezzed_server_break_cost(rd, ctx.runner_rig, ab_reg)

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
			"break_cost":     _rezzed_server_break_cost(s, ctx.runner_rig, ab_reg),
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

	# Strategic value bonus accumulated from events played during this plan
	u += snap.get("event_value_accrued", 0.0) as float

	# Credit surplus above safety floor
	var cr: int = snap.get("runner_credits", 0) as int
	u += CREDIT_SURPLUS_VAL * clampf(float(cr - CREDIT_FLOOR), -8.0, 12.0)

	# Grip health
	var grip: int = snap.get("runner_hand_size", 0) as int
	u += GRIP_SURPLUS_VAL * clampf(float(grip - MIN_HAND), -4.0, 4.0)

	# Tags are a kill threat — each one makes the runner a flatline target.
	var tags: int = snap.get("runner_tags", 0) as int
	if tags > 0:
		u -= tag_penalty_per_tag * float(tags)

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
				s["runner_credits"] = maxi(0, (snap.get("runner_credits", 0) as int) - cost)
				var projs: Dictionary = snap.get("runner_event_projections", {}) as Dictionary
				if projs.has(rec.id):
					_apply_projection(s, projs[rec.id] as Dictionary)

		"install":
			var rec: CardRecord = action.params.get("card_record", null) as CardRecord
			if rec != null and rec.card_type == "program":
				_remove_from_hand(s, rec)
				s["runner_hand_size"] = maxi(0, (snap.get("runner_hand_size", 0) as int) - 1)
				var cost: int = maxi(0, rec.cost)
				s["runner_credits"]  = maxi(0, (snap.get("runner_credits", 0) as int) - cost)
				s["runner_prg_count"] = (snap.get("runner_prg_count", 0) as int) + 1
				var mu_cost: int = rec.memory_cost if rec.memory_cost > 0 else 1
				s["runner_mu_used"] = (snap.get("runner_mu_used", 0) as int) + mu_cost
				for sub in rec.subtypes:
					match sub:
						"fracter": s["runner_has_fracter"] = true
						"decoder": s["runner_has_decoder"] = true
						"killer":  s["runner_has_killer"]  = true
						"ai":      s["runner_has_ai"]      = true

		"run":
			var server_id: String = action.params.get("server_id", "") as String
			_apply_run(s, server_id)

		"remove_tag":
			s["runner_credits"] = maxi(0, (s.get("runner_credits", 0) as int) - 2)
			s["runner_tags"]    = maxi(0, (s.get("runner_tags",    0) as int) - 1)

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
				s["runner_stole_agenda_this_turn"] = true
				break


func _break_cost(server_id: String, snap: Dictionary) -> int:
	var unrez_cost: int = _unrezzed_ice_cost_per_piece(snap)
	match server_id:
		"hq":
			# Actual break cost for rezzed ICE (precomputed); scaled estimate for unrezzed.
			var rezzed_cost: int = snap.get("break_cost_hq",
				(snap.get("hq_rezzed", 0) as int) * 2) as int
			return rezzed_cost + (snap.get("hq_unrezzed", 0) as int) * unrez_cost
		"rd":
			var rezzed_cost: int = snap.get("break_cost_rd",
				(snap.get("rd_rezzed", 0) as int) * 2) as int
			return rezzed_cost + (snap.get("rd_unrezzed", 0) as int) * unrez_cost
		"archives":
			return 0
	for r in snap.get("remotes", []) as Array:
		var rd: Dictionary = r as Dictionary
		if rd.get("server_id", "") == server_id:
			var rezzed_cost: int = rd.get("break_cost",
				(rd.get("rezzed_count", 0) as int) * 2) as int
			return rezzed_cost + (rd.get("unrezzed_count", 0) as int) * unrez_cost
	return 0


# Per-piece credit cost the Runner should budget for each unrezzed ICE piece,
# scaled by Corp credits.  A wealthy Corp is essentially certain to rez on
# approach; a broke Corp may not be able to afford it.
func _unrezzed_ice_cost_per_piece(snap: Dictionary) -> int:
	var corp_cr: int = snap.get("corp_credits", 0) as int
	if corp_cr < 4:  return 1   # Corp is tight — most ICE stays face-down
	if corp_cr < 8:  return 2   # Corp can rez medium ICE (Tithe, Palisade)
	if corp_cr < 12: return 3   # Corp rezzes most ICE
	return 4                    # Corp is flush — treat every piece as a real obstacle


func _merge_projection(auto_proj: Variant, hint: Dictionary) -> Variant:
	# Start with the canonical projection schema (same shape as get_ai_projection).
	var proj: Dictionary = {
		"complete":          false,
		"credits_delta":     0,
		"cards_drawn":       0,
		"clicks_gained":     0,
		"tags_added":        0,
		"bad_pub_given":     0,
		"installs_program":  false,
		"installs_hardware": false,
		"installs_resource": false,
		"install_from_deck": false,
		"program_subtype":   "",
		"runs_server":       "",
		"run_is_replaced":   false,
		"value_bonus":       0.0,
	}
	var has_anything := false

	# Layer 1: auto-projection from abilities.json.
	if auto_proj != null:
		for k in (auto_proj as Dictionary):
			proj[k] = (auto_proj as Dictionary)[k]
		has_anything = true

	# Layer 2: AiCardHints fills gaps and always stacks value_bonus.
	if not hint.is_empty():
		var delta: Dictionary = hint.get("snap_delta", {}) as Dictionary

		if (proj["credits_delta"] as int) == 0 and delta.has("credits_delta"):
			proj["credits_delta"] = delta["credits_delta"] as int
		if (proj["cards_drawn"] as int) == 0 and delta.has("cards_drawn"):
			proj["cards_drawn"] = delta["cards_drawn"] as int
		# hint clicks_delta is negative for extra click cost; stored as clicks_gained
		if (proj["clicks_gained"] as int) == 0 and delta.has("clicks_delta"):
			proj["clicks_gained"] = delta["clicks_delta"] as int
		if (proj["runs_server"] as String) == "" and delta.has("runs_server"):
			proj["runs_server"] = delta["runs_server"] as String
		if not (proj["installs_program"] as bool):
			if delta.get("installs_program", false) as bool:
				proj["installs_program"] = true
			elif delta.get("installs_breaker_if_need", false) as bool:
				proj["installs_program"] = true
				if (proj["program_subtype"] as String) == "":
					proj["program_subtype"] = "icebreaker"
		if not (proj["installs_resource"] as bool) and delta.get("installs_resource", false) as bool:
			proj["installs_resource"] = true
		if not (proj["install_from_deck"] as bool) and delta.get("install_from_deck", false) as bool:
			proj["install_from_deck"] = true

		proj["value_bonus"] = (proj["value_bonus"] as float) \
			+ (hint.get("value_bonus", 0.0) as float)
		has_anything = true

	if not has_anything:
		return null

	# Discard projections with no useful modelled effect.
	if (proj["credits_delta"] as int) == 0 \
			and (proj["cards_drawn"] as int) == 0 \
			and (proj["clicks_gained"] as int) == 0 \
			and not (proj["installs_program"] as bool) \
			and not (proj["installs_hardware"] as bool) \
			and not (proj["installs_resource"] as bool) \
			and (proj["runs_server"] as String) == "" \
			and (proj["value_bonus"] as float) == 0.0:
		return null

	return proj


func _apply_projection(s: Dictionary, proj: Dictionary) -> void:
	# Credit gain (GROSS — card cost already deducted by the caller).
	var cr_gain: int = proj.get("credits_delta", 0) as int
	if cr_gain != 0:
		s["runner_credits"] = maxi(0, (s.get("runner_credits", 0) as int) + cr_gain)

	# Card draw.
	var draw: int = proj.get("cards_drawn", 0) as int
	if draw > 0:
		s["runner_hand_size"] = (s.get("runner_hand_size", 0) as int) + draw
		s["runner_deck"]      = maxi(0, (s.get("runner_deck", 0) as int) - draw)

	# Click adjustment: negative = additional cost, positive = extra click gained.
	var clicks: int = proj.get("clicks_gained", 0) as int
	if clicks != 0:
		s["runner_clicks_left"] = maxi(0, (s.get("runner_clicks_left", 0) as int) + clicks)

	# Program install: increment program count and MU usage.
	# Icebreaker tutors also set the most-needed missing breaker flag.
	if proj.get("installs_program", false) as bool:
		s["runner_prg_count"] = (s.get("runner_prg_count", 0) as int) + 1
		s["runner_mu_used"]   = (s.get("runner_mu_used",   0) as int) + 1
		if (proj.get("program_subtype", "") as String) == "icebreaker":
			if not (s.get("runner_has_fracter", false) as bool):
				s["runner_has_fracter"] = true
			elif not (s.get("runner_has_decoder", false) as bool):
				s["runner_has_decoder"] = true
			elif not (s.get("runner_has_killer", false) as bool):
				s["runner_has_killer"]  = true

	# Deck deduction for install-from-deck effects.
	if proj.get("install_from_deck", false) as bool:
		s["runner_deck"] = maxi(0, (s.get("runner_deck", 0) as int) - 1)

	# Run a server.
	var runs: String = proj.get("runs_server", "") as String
	if runs != "":
		_apply_run(s, _resolve_hint_run_target(runs, s))

	# Accumulate strategic value bonus for the evaluator to pick up.
	var vb: float = proj.get("value_bonus", 0.0) as float
	if vb != 0.0:
		s["event_value_accrued"] = (s.get("event_value_accrued", 0.0) as float) + vb


func _resolve_hint_run_target(runs: String, snap: Dictionary) -> String:
	var ran: Array = snap.get("centrals_run", []) as Array
	match runs:
		"rd":       return "rd"
		"hq":       return "hq"
		"archives": return "archives"
		"any_central":
			# Prefer the breakable central; fall back to unbreakable only as last resort.
			if "rd" not in ran and _central_breakable("rd", snap): return "rd"
			if "hq" not in ran and _central_breakable("hq", snap): return "hq"
			if "rd" not in ran: return "rd"
			if "hq" not in ran: return "hq"
			return ""
		"any":
			# Prefer breakable unrun centrals; fall back to archives rather than
			# steering into ICE the runner cannot break.
			if "rd" not in ran and _central_breakable("rd", snap): return "rd"
			if "hq" not in ran and _central_breakable("hq", snap): return "hq"
			for r in snap.get("remotes", []) as Array:
				var rd: Dictionary = r as Dictionary
				if rd.get("has_agenda", false):
					return rd.get("server_id", "") as String
			return "archives"
	return runs


func _remove_from_hand(s: Dictionary, rec: CardRecord) -> void:
	var hand: Array = s.get("runner_hand_cards", []) as Array
	hand.erase(rec)
	s["runner_hand_cards"] = hand


# Returns the total credit cost for the runner to break all currently-rezzed
# ICE on a server, using the cheapest available breaker for each piece.
# Unrezzed ICE is excluded — callers add a heuristic for those separately.
func _rezzed_server_break_cost(server: Server, rig: Array, ab_reg: AbilityRegistry) -> int:
	if server == null:
		return 0
	var total := 0
	for ice_any in server.ice:
		var ic: InstalledCard = ice_any as InstalledCard
		if ic == null or not ic.is_rezzed or ic.card_record == null:
			continue
		total += _single_ice_break_cost(ic, rig, ab_reg)
	return total


# Estimate the runner's cheapest credit cost to break a single rezzed ICE piece.
# Uses the ability registry for exact boost+break costs when available; falls
# back to a penalty estimate when no matching breaker is installed.
func _single_ice_break_cost(ice: InstalledCard, rig: Array, ab_reg: AbilityRegistry) -> int:
	var record: CardRecord = ice.card_record
	var strength: int      = record.strength
	var sub_count: int     = ab_reg.get_subroutines(ice.card_id).size() if ab_reg != null else 1
	if sub_count <= 0:
		sub_count = 1

	var best_cost: float = INF

	for rig_any in rig:
		var breaker: InstalledCard = rig_any as InstalledCard
		if breaker == null or breaker.card_record == null \
				or breaker.card_record.card_type != "program":
			continue
		if ab_reg == null:
			continue
		var break_def: Variant = ab_reg.get_break_for_ice(breaker.card_id, record.subtypes)
		if break_def == null:
			continue

		# Boost cost: credits to reach the ICE's strength from the breaker's base.
		var boost_cost: float = 0.0
		var boost_def: Variant = ab_reg.get_boost(breaker.card_id)
		if boost_def != null:
			var bd: Dictionary     = boost_def as Dictionary
			var cost_per_boost: float = float(bd.get("cost", 1))
			var str_per_boost: float  = float(bd.get("strength_gained", 1))
			var str_needed: int = maxi(0, strength - breaker.card_record.strength)
			if str_per_boost > 0.0:
				boost_cost = ceil(float(str_needed) / str_per_boost) * cost_per_boost

		# Break cost: credits to break all subroutines.
		var bk: Dictionary       = break_def as Dictionary
		var cost_per_sub: float  = float(bk.get("cost_per_sub", 1))
		var break_cost: float    = float(sub_count) * cost_per_sub

		var total: float = boost_cost + break_cost
		if total < best_cost:
			best_cost = total

	if best_cost == INF:
		# No breaker for this ICE type — runner must jack out or eat subs.
		# Penalty: enough to discourage the run unless very credits-rich.
		return maxi(2, strength + sub_count)

	return maxi(1, int(best_cost))


static func _central_breakable(server_id: String, snap: Dictionary) -> bool:
	var types_key: String = "hq_rezzed_types" if server_id == "hq" else "rd_rezzed_types"
	var rezzed_types: Array = snap.get(types_key, []) as Array
	if rezzed_types.is_empty():
		return true
	if snap.get("runner_has_ai", false) as bool:
		return true
	var has_fracter: bool = snap.get("runner_has_fracter", false) as bool
	var has_decoder: bool = snap.get("runner_has_decoder", false) as bool
	var has_killer:  bool = snap.get("runner_has_killer",  false) as bool
	for sub in rezzed_types:
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


static func _rezzed_server_types(server: Server) -> Array:
	if server == null:
		return []
	var types: Array = []
	for ice_any in server.ice:
		var ic: InstalledCard = ice_any as InstalledCard
		if ic == null or not ic.is_rezzed or ic.card_record == null:
			continue
		for sub in ic.card_record.subtypes:
			if sub not in types:
				types.append(sub)
	return types


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
