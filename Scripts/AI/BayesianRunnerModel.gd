class_name BayesianRunnerModel
extends RunnerThreatModel

# ── BayesianRunnerModel ───────────────────────────────────────────────────────
# Extends RunnerThreatModel with probabilistic deck modeling.
#
# Seeded from public information only (runner identity + format card pool).
# Updated via Bayesian observation as the runner installs, plays, draws, and
# ends turns.
#
# Internal state
# ─────────────────────────────────────────────────────────────────────────────
#   _prior_deck   : { card_id → float }  expected copies in a typical deck
#   _observed     : { card_id → int   }  confirmed seen (install / play)
#   _discard_seen : { card_id → int   }  confirmed in discard pile
#   _runner_turns : int                  runner turns fully completed
#   _total_drawn  : int                  total cards drawn (estimated)
#
# Probability model
# ─────────────────────────────────────────────────────────────────────────────
# _remaining_copies(c) = prior(c) − observed(c) − discarded(c)
# P(at least one copy of c in grip of N) ≈ 1 − ((total−rem) / total)^N
# (hypergeometric binomial approximation)
# ─────────────────────────────────────────────────────────────────────────────

const BREAKER_SUBTYPES      := ["fracter", "killer", "decoder", "ai"]
const MAX_COPIES_PER_CARD   := 3


# ── Internal state ────────────────────────────────────────────────────────────

var _prior_deck:   Dictionary = {}   # card_id → float  (expected copies)
var _observed:     Dictionary = {}   # card_id → int    (confirmed seen)
var _discard_seen: Dictionary = {}   # card_id → int    (confirmed in discard)
var _action_history: Array    = []   # raw event log
var _runner_turns: int        = 0    # runner turns completed
var _total_drawn:  int        = 0    # total cards drawn (conservative estimate)


# ── Initialization ────────────────────────────────────────────────────────────

func seed_from_identity_and_pool(identity_id: String, pool_card_ids: Array) -> void:
	_prior_deck.clear()
	_observed.clear()
	_discard_seen.clear()
	_action_history.clear()
	_runner_turns = 0
	_total_drawn  = 0

	var identity: CardRecord = CardRegistry.get_card(identity_id)
	if identity == null:
		push_warning("BayesianRunnerModel: identity not found: %s" % identity_id)
		return

	var influence_limit: int = identity.influence_limit \
		if identity.influence_limit > 0 else 15

	for card_id in pool_card_ids:
		var card: CardRecord = CardRegistry.get_card(card_id)
		if card == null:
			continue
		if card.side == "corp" or card.card_type == "identity":
			continue
		var expected: float = _compute_prior_copies(card, influence_limit)
		if expected > 0.05:
			_prior_deck[card_id] = expected


# ── Prior computation (improved) ──────────────────────────────────────────────

func _compute_prior_copies(card: CardRecord, influence_limit: int) -> float:
	var cost:     int   = max(0, card.cost)
	var inf_cost: int   = card.influence_cost
	var base:     float

	# ── In-faction or neutral ──────────────────────────────────────────────────
	if inf_cost == 0:
		if   cost <= 1: base = 2.8
		elif cost <= 3: base = 2.2
		elif cost <= 5: base = 1.4
		else:           base = 0.9
	else:
	# ── Out-of-faction splash ──────────────────────────────────────────────────
		match inf_cost:
			1: base = 1.2
			2: base = 0.6
			3: base = 0.3
			_: base = 0.1
		base *= clampf(float(influence_limit) / 15.0, 0.2, 1.0)

	# ── Card-type bonuses ──────────────────────────────────────────────────────
	# Cheap neutral events (Sure Gamble, etc.) appear in almost every deck.
	# Hardware competes with programs for install slots.
	match card.card_type:
		"event":
			if cost <= 2 and inf_cost == 0:
				base *= 1.3
		"hardware":
			base *= 0.9
		"resource":
			if inf_cost == 0:
				base *= 1.1

	# Icebreakers are highly expected regardless of cost.
	for bt in BREAKER_SUBTYPES:
		if card.has_subtype(bt):
			base = maxf(base, 1.5)
			break

	return base


# ── Observation ───────────────────────────────────────────────────────────────

# Record an observable runner action.
# action_type: "install" | "play" | "play_operation" | "draw_card" |
#              "discard" | "end_turn" | "run"
func observe(action_type: String, params: Dictionary) -> void:
	_action_history.append({"type": action_type, "params": params})

	match action_type:
		"install", "play", "play_operation":
			var card_id: String = params.get("card_id", "") as String
			if card_id == "" or not _prior_deck.has(card_id):
				return
			var seen: int = _observed.get(card_id, 0) as int
			_observed[card_id] = min(seen + 1, MAX_COPIES_PER_CARD)

		"draw_card":
			# Runner spent a click to draw one card.
			_total_drawn = min(_total_drawn + 1, _deck_size_estimate())

		"discard":
			# A card entered the runner's discard pile.
			var card_id: String = params.get("card_id", "") as String
			if card_id != "" and _prior_deck.has(card_id):
				var dc: int = _discard_seen.get(card_id, 0) as int
				_discard_seen[card_id] = min(dc + 1, MAX_COPIES_PER_CARD)

		"end_turn":
			_runner_turns += 1
			# Account for the mandatory draw at start of next runner turn.
			_total_drawn = min(_total_drawn + 1, _deck_size_estimate())


# ── Deck density helpers ──────────────────────────────────────────────────────

# Expected total deck size (sum of prior expected copies).
func _deck_size_estimate() -> int:
	var total: float = 0.0
	for card_id in _prior_deck:
		total += _prior_deck[card_id] as float
	return int(round(total))


# Expected remaining copies of card_id in (deck + unobserved hand).
func _remaining_copies(card_id: String) -> float:
	var prior:     float = _prior_deck.get(card_id,   0.0) as float
	var seen:      int   = _observed.get(card_id,     0)   as int
	var discarded: int   = _discard_seen.get(card_id, 0)   as int
	return maxf(0.0, prior - float(seen) - float(discarded))


# Sum of remaining copies across the entire prior.
func _total_remaining() -> float:
	var total: float = 0.0
	for card_id in _prior_deck:
		total += _remaining_copies(card_id)
	return total


# ── Hand probability queries ──────────────────────────────────────────────────

# P(grip contains at least one card with this subtype).
func p_has_subtype_in_hand(subtype: String, ctx: GameContext) -> float:
	var tot:      float = _total_remaining()
	var matching: float = 0.0
	for card_id in _prior_deck:
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record != null and record.has_subtype(subtype):
			matching += _remaining_copies(card_id)
	if tot <= 0.0 or matching <= 0.0:
		return 0.0
	var grip: int = ctx.runner_hand.size()
	if grip <= 0:
		return 0.0
	return clampf(1.0 - pow((tot - matching) / tot, grip), 0.0, 1.0)


# P(grip contains at least one copy of a specific card).
func p_has_card_in_hand(card_id: String, ctx: GameContext) -> float:
	var rem: float = _remaining_copies(card_id)
	var tot: float = _total_remaining()
	if tot <= 0.0 or rem <= 0.0:
		return 0.0
	var grip: int = ctx.runner_hand.size()
	if grip <= 0:
		return 0.0
	return clampf(1.0 - pow((tot - rem) / tot, grip), 0.0, 1.0)


# P(runner can break [subtype] ice this turn):
# 1.0 if already installed; otherwise probability it's in hand (ready to install first).
func p_subtype_accessible(subtype: String, ctx: GameContext) -> float:
	for ic in ctx.runner_rig:
		var c: InstalledCard = ic as InstalledCard
		if c != null and c.card_record != null and c.card_record.has_subtype(subtype):
			return 1.0
	return p_has_subtype_in_hand(subtype, ctx)


# ── Snapshot-based hand queries (no live ctx) ─────────────────────────────────

# P(runner grip holds at least one [subtype] breaker), from SimState snapshot.
func p_has_subtype_in_hand_snap(subtype: String, snap: Dictionary) -> float:
	var tot:      float = _total_remaining()
	var matching: float = 0.0
	for card_id in _prior_deck:
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record != null and record.has_subtype(subtype):
			matching += _remaining_copies(card_id)
	if tot <= 0.0 or matching <= 0.0:
		return 0.0
	var grip: int = snap.get("runner_hand", 0) as int
	if grip <= 0:
		return 0.0
	return clampf(1.0 - pow((tot - matching) / tot, grip), 0.0, 1.0)


# P(runner can break [subtype] ice this turn), from SimState snapshot.
func p_subtype_accessible_snap(subtype: String, snap: Dictionary) -> float:
	match subtype:
		"fracter": if snap.get("runner_has_fracter", false): return 1.0
		"killer":  if snap.get("runner_has_killer",  false): return 1.0
		"decoder": if snap.get("runner_has_decoder", false): return 1.0
		"ai":      if snap.get("runner_has_ai_breaker", false): return 1.0
	return p_has_subtype_in_hand_snap(subtype, snap)


# ── Improved server success estimate (overrides parent) ───────────────────────

# Overrides RunnerThreatModel._estimate_run_success to account for the
# probability that the runner has an uninstalled breaker in hand.
func _estimate_run_success(server_id: String, ctx: GameContext) -> float:
	var server: Server = ctx.get_server(server_id)
	if server == null:
		return 0.0

	var ice_count:   int = server.ice.size()
	var runner_cr:   int = ctx.runner_credits
	var breakers:    int = _count_installed_breakers(ctx)
	var ai_breakers: int = _count_ai_breakers(ctx)

	var base: float
	if ai_breakers > 0:
		base = 0.75
	elif breakers >= 3:
		base = 0.80
	elif breakers >= 2:
		base = 0.65
	elif breakers >= 1:
		base = 0.45
	else:
		base = 0.20

	base -= float(ice_count) * 0.12

	if   runner_cr >= 8: base += 0.10
	elif runner_cr <= 2: base -= 0.15

	# Mismatch penalty — scaled by P(runner has the missing breaker in hand).
	# Full -0.20 when the runner definitely lacks the type; reduced proportionally
	# when the Bayesian model estimates they might have it in hand.
	if ai_breakers == 0 and breakers > 0:
		var breaker_types := _breaker_subtypes_installed(ctx)
		var srv_subtypes  := _server_ice_subtypes(server)
		if srv_subtypes["barrier"] and not breaker_types.get("fracter", false):
			var p_accessible: float = p_subtype_accessible("fracter", ctx)
			base -= 0.20 * (1.0 - p_accessible)
		if srv_subtypes["sentry"] and not breaker_types.get("killer", false):
			var p_accessible: float = p_subtype_accessible("killer", ctx)
			base -= 0.20 * (1.0 - p_accessible)
		if srv_subtypes["code_gate"] and not breaker_types.get("decoder", false):
			var p_accessible: float = p_subtype_accessible("decoder", ctx)
			base -= 0.20 * (1.0 - p_accessible)

	# Agenda in root boosts run motivation (with Bangun trap exception from parent).
	if server.is_remote():
		for c in server.root:
			var ic: InstalledCard = c as InstalledCard
			if ic != null and ic.card_record != null and ic.card_record.is_agenda():
				if ic.is_face_up and ctx.corp_identity != null and \
						ctx.corp_identity.id == "bangun_when_disaster_strikes":
					var grip_size: int = ctx.runner_hand.size()
					if   grip_size <= 2: base -= 0.35
					elif grip_size <= 4: base -= 0.20
					else:                base -= 0.08
				else:
					base += 0.15
				break

	return clampf(base, 0.0, 1.0)


# ── Rig completeness (updated to use _observed) ───────────────────────────────

func estimated_rig_completeness(ctx: GameContext) -> float:
	var installed_breakers := 0
	for c in ctx.runner_rig:
		var ic: InstalledCard = c as InstalledCard
		if ic == null or ic.card_record == null:
			continue
		for sub in BREAKER_SUBTYPES:
			if ic.card_record.has_subtype(sub):
				installed_breakers += 1
				break

	var expected_breakers := 0.0
	for card_id in _prior_deck:
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record == null:
			continue
		for sub in BREAKER_SUBTYPES:
			if record.has_subtype(sub):
				expected_breakers += _prior_deck[card_id] as float
				break

	if expected_breakers <= 0.0:
		return clampf(float(installed_breakers) / 3.0, 0.0, 1.0)
	return clampf(float(installed_breakers) / expected_breakers, 0.0, 1.0)


# ── Economy trajectory ────────────────────────────────────────────────────────

# Expected runner credit count at the start of their next turn.
func estimated_runner_credits_next_turn(ctx: GameContext) -> float:
	var current: float = float(ctx.runner_credits)

	# Base economy gain per turn, scaled by how credit-poor the runner is.
	var econ_gain: float
	if   current <= 3: econ_gain = 3.5
	elif current <= 6: econ_gain = 2.5
	else:              econ_gain = 1.5

	# Probability-weighted bonus from likely economy events in hand.
	var tot: float = _total_remaining()
	if tot > 0.0:
		var p_econ_event: float = 0.0
		for card_id in _prior_deck:
			var record: CardRecord = CardRegistry.get_card(card_id)
			if record == null or record.card_type != "event":
				continue
			if max(0, record.cost) <= 1:
				p_econ_event += _remaining_copies(card_id) / tot
		econ_gain += p_econ_event * 2.5

	return minf(current + econ_gain, 20.0)


# ── k_likely_runner_responses (improved live-ctx version) ─────────────────────

func k_likely_runner_responses(k: int, ctx: GameContext) -> Array:
	var candidates: Array = []

	for server_id in ctx.servers:
		var s: Server = ctx.servers[server_id] as Server
		if not s.is_remote() and server_id not in ["hq", "rd"]:
			continue
		var t: float = threat(server_id, ctx)
		if t > 0.05:
			candidates.append({
				"type":        "run",
				"server_id":   server_id,
				"probability": t,
			})

	# Install candidate — runner more likely to install when rig is incomplete,
	# or when lost breakers need to be replaced.
	if ctx.runner_credits >= 3 and _prior_deck.size() > 0:
		var lost_breakers: int = 0
		for card_id in _discard_seen:
			var record: CardRecord = CardRegistry.get_card(card_id)
			if record == null:
				continue
			for bt in BREAKER_SUBTYPES:
				if record.has_subtype(bt):
					lost_breakers += _discard_seen[card_id] as int
					break
		var rig_urgency: float = clampf(
			(1.0 - estimated_rig_completeness(ctx)) + float(lost_breakers) * 0.15,
			0.0, 1.0)
		var install_prob: float = clampf(rig_urgency, 0.1, 0.6)
		candidates.append({
			"type":        "install",
			"server_id":   "",
			"probability": install_prob,
		})

	candidates.sort_custom(func(a, b):
		return float(a["probability"]) > float(b["probability"]))

	var top_k: Array = candidates.slice(0, k)
	var total: float = 0.0
	for entry in top_k:
		total += float((entry as Dictionary).get("probability", 0.0))
	if total > 0.0:
		for i in range(top_k.size()):
			var e: Dictionary = (top_k[i] as Dictionary).duplicate()
			e["probability"] = float(e["probability"]) / total
			top_k[i] = e
	return top_k


# ── k_likely_runner_responses_from_snap (snapshot-compatible) ─────────────────
#
# Identical semantics to k_likely_runner_responses but reads from a SimState
# snapshot dictionary rather than a live GameContext.  Used by MCTSTurnTree
# rollouts and expansion where no live ctx is available.

func k_likely_runner_responses_from_snap(k: int, snap: Dictionary) -> Array:
	if snap.is_empty():
		return []

	var runner_cr:    int  = snap.get("runner_credits",        0) as int
	var runner_score: int  = snap.get("runner_score",          0) as int
	var pts_to_win:   int  = snap.get("pts_to_win",            7) as int
	var has_fracter:  bool = snap.get("runner_has_fracter",  false) as bool
	var has_killer:   bool = snap.get("runner_has_killer",   false) as bool
	var has_decoder:  bool = snap.get("runner_has_decoder",  false) as bool
	var has_ai:       bool = snap.get("runner_has_ai_breaker", false) as bool
	var breaker_ct:   int  = snap.get("runner_breaker_count",  0) as int
	var hq_ice:       int  = snap.get("hq_ice",  0) as int
	var rd_ice:       int  = snap.get("rd_ice",  0) as int

	# ── Run willingness ────────────────────────────────────────────────────────
	var willingness: float = 0.5
	if   runner_cr >= 8: willingness += 0.20
	elif runner_cr >= 5: willingness += 0.10
	elif runner_cr <= 2: willingness -= 0.20
	var pts_needed: int = pts_to_win - runner_score
	if   pts_needed <= 2: willingness += 0.20
	elif pts_needed <= 4: willingness += 0.10

	# ── Base capability from installed rig ────────────────────────────────────
	var cap_base: float
	if has_ai:          cap_base = 0.75
	elif breaker_ct >= 3: cap_base = 0.80
	elif breaker_ct >= 2: cap_base = 0.65
	elif breaker_ct >= 1: cap_base = 0.45
	else:               cap_base = 0.20
	if   runner_cr >= 8: cap_base += 0.10
	elif runner_cr <= 2: cap_base -= 0.15

	var candidates: Array = []

	# ── HQ ────────────────────────────────────────────────────────────────────
	var hq_cap: float = cap_base - float(hq_ice) * 0.12
	if not has_ai:
		if snap.get("hq_ice_barrier",   false) and not has_fracter:
			hq_cap -= 0.20 * (1.0 - p_subtype_accessible_snap("fracter", snap))
		if snap.get("hq_ice_sentry",    false) and not has_killer:
			hq_cap -= 0.20 * (1.0 - p_subtype_accessible_snap("killer",  snap))
		if snap.get("hq_ice_code_gate", false) and not has_decoder:
			hq_cap -= 0.20 * (1.0 - p_subtype_accessible_snap("decoder", snap))
	var hq_threat: float = clampf(willingness * clampf(hq_cap, 0.0, 1.0), 0.0, 1.0)
	if hq_threat > 0.05:
		candidates.append({"type": "run", "server_id": "hq", "probability": hq_threat})

	# ── RD ────────────────────────────────────────────────────────────────────
	var rd_cap: float = cap_base - float(rd_ice) * 0.12
	if not has_ai:
		if snap.get("rd_ice_barrier",   false) and not has_fracter:
			rd_cap -= 0.20 * (1.0 - p_subtype_accessible_snap("fracter", snap))
		if snap.get("rd_ice_sentry",    false) and not has_killer:
			rd_cap -= 0.20 * (1.0 - p_subtype_accessible_snap("killer",  snap))
		if snap.get("rd_ice_code_gate", false) and not has_decoder:
			rd_cap -= 0.20 * (1.0 - p_subtype_accessible_snap("decoder", snap))
	var rd_threat: float = clampf(willingness * clampf(rd_cap, 0.0, 1.0), 0.0, 1.0)
	if rd_threat > 0.05:
		candidates.append({"type": "run", "server_id": "rd", "probability": rd_threat})

	# ── Remotes ───────────────────────────────────────────────────────────────
	for remote in snap.get("remotes", []) as Array:
		var r: Dictionary = remote as Dictionary
		if not r.get("has_agenda", false) and r.get("root_type", "") == "":
			continue   # nothing of value in this remote
		var r_ice: int = r.get("ice_count", 0) as int
		var r_cap: float = cap_base - float(r_ice) * 0.12
		if not has_ai:
			if r.get("has_barrier",   false) and not has_fracter:
				r_cap -= 0.20 * (1.0 - p_subtype_accessible_snap("fracter", snap))
			if r.get("has_sentry",    false) and not has_killer:
				r_cap -= 0.20 * (1.0 - p_subtype_accessible_snap("killer",  snap))
			if r.get("has_code_gate", false) and not has_decoder:
				r_cap -= 0.20 * (1.0 - p_subtype_accessible_snap("decoder", snap))
		if r.get("has_agenda", false):
			r_cap += 0.15   # agenda in root strongly motivates a run
		var r_threat: float = clampf(willingness * clampf(r_cap, 0.0, 1.0), 0.0, 1.0)
		if r_threat > 0.05:
			candidates.append({
				"type":        "run",
				"server_id":   r.get("server_id", "rd") as String,
				"probability": r_threat,
			})

	# ── Install candidate ─────────────────────────────────────────────────────
	if runner_cr >= 3 and _prior_deck.size() > 0:
		var install_prob: float = clampf(
			1.0 - float(breaker_ct) / 3.0, 0.1, 0.6)
		candidates.append({"type": "install", "server_id": "", "probability": install_prob})

	# Sort, slice, normalise
	candidates.sort_custom(func(a, b):
		return float(a["probability"]) > float(b["probability"]))
	var top_k: Array = candidates.slice(0, k)
	var total: float = 0.0
	for e in top_k:
		total += float((e as Dictionary).get("probability", 0.0))
	if total > 0.0:
		for i in range(top_k.size()):
			var e: Dictionary = (top_k[i] as Dictionary).duplicate()
			e["probability"] = float(e["probability"]) / total
			top_k[i] = e
	return top_k
