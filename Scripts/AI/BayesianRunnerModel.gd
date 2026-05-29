class_name BayesianRunnerModel
extends RunnerThreatModel

# ── BayesianRunnerModel ───────────────────────────────────────────────────────
# Extends RunnerThreatModel with probabilistic deck modeling.
#
# The model is seeded from public information only:
#   • Runner identity (determines influence limit)
#   • The format's full card pool (which cards are legal)
#
# It does NOT see the player's actual deck list.  The prior is constructed
# from deckbuilding heuristics (influence cost, card cost, card type) and
# then updated via Bayesian observation as the runner installs and plays cards.
#
# Prior representation
# ─────────────────────────────────────────────────────────────────────────────
#   _prior_deck : { card_id: float }   — expected copies in a typical deck
#   A card with influence_cost == 0 is in-faction or neutral (no influence
#   budget needed).  A card with influence_cost > 0 is out-of-faction and
#   gets a lower expected-copy weight proportional to the identity's budget.
#
# Observation
# ─────────────────────────────────────────────────────────────────────────────
#   _observed_plays : { card_id: int }  — confirmed seen (played or installed)
#   Each observation removes one "unknown" copy from the remaining pool,
#   sharpening probability estimates over time.

const BREAKER_SUBTYPES := ["fracter", "killer", "decoder", "ai"]
const MAX_COPIES_PER_CARD := 3   # hard rules cap

# card_id → float  (expected copies in a typical deck from this identity/pool)
var _prior_deck:     Dictionary = {}
# card_id → int  (confirmed seen: played or installed by the runner)
var _observed_plays: Dictionary = {}
# Raw action log for debugging / future analysis
var _action_history: Array = []


# ── Initialization ────────────────────────────────────────────────────────────

# Seed the model from public information: identity + format card pool.
# identity_id    — runner identity slug (e.g. "the_catalyst_convention_breaker")
# pool_card_ids  — all card IDs legal in the current format/campaign pool
func seed_from_identity_and_pool(identity_id: String, pool_card_ids: Array) -> void:
	_prior_deck.clear()
	_observed_plays.clear()
	_action_history.clear()

	var identity: CardRecord = CardRegistry.get_card(identity_id)
	if identity == null:
		push_warning("BayesianRunnerModel: identity not found: %s" % identity_id)
		return

	var influence_limit: int = identity.influence_limit if identity.influence_limit > 0 else 15

	for card_id in pool_card_ids:
		var card: CardRecord = CardRegistry.get_card(card_id)
		if card == null:
			continue
		# Skip non-runner and identity cards
		if card.side == "corp" or card.card_type == "identity":
			continue
		var expected: float = _compute_prior_copies(card, influence_limit)
		if expected > 0.05:
			_prior_deck[card_id] = expected


# ── Prior computation ─────────────────────────────────────────────────────────

# Estimate expected copies of a card in a typical legal deck for this identity.
# Uses card.influence_cost as the in-faction/out-of-faction discriminator:
#   influence_cost == 0  →  in-faction or neutral card, no budget required
#   influence_cost  > 0  →  out-of-faction splash, weighed by identity budget
func _compute_prior_copies(card: CardRecord, influence_limit: int) -> float:
	var cost:     int = max(0, card.cost)
	var inf_cost: int = card.influence_cost

	if inf_cost == 0:
		# In-faction or neutral — freely playable, higher expected count
		if   cost <= 2: return 2.5
		elif cost <= 4: return 1.8
		else:           return 1.0
	else:
		# Out-of-faction — weighed by influence cost relative to identity budget
		var base: float
		match inf_cost:
			1:     base = 1.2
			2:     base = 0.6
			3:     base = 0.3
			_:     base = 0.1
		# Scale down further if identity has a tight influence budget
		var budget_factor: float = clampf(float(influence_limit) / 15.0, 0.2, 1.0)
		return base * budget_factor


# ── Observation ───────────────────────────────────────────────────────────────

# Record a revealed runner card to update the posterior.
# action_type : "install" | "play" | "run" | "draw" | "end_turn"
# params      : Dictionary — "card_id" required for install/play
func observe(action_type: String, params: Dictionary) -> void:
	_action_history.append({"type": action_type, "params": params})

	match action_type:
		"install", "play":
			var card_id: String = params.get("card_id", "") as String
			if card_id == "" or not _prior_deck.has(card_id):
				return
			var seen: int = _observed_plays.get(card_id, 0) as int
			_observed_plays[card_id] = min(seen + 1, MAX_COPIES_PER_CARD)


# ── Probability queries ───────────────────────────────────────────────────────

# P(grip contains at least one card with this subtype).
# Remaining pool = prior expected copies − observed copies.
func p_has_subtype_in_hand(subtype: String, ctx: GameContext) -> float:
	var pool_total:    float = 0.0
	var pool_matching: float = 0.0

	for card_id in _prior_deck:
		var expected: float = _prior_deck[card_id] as float
		var observed: int   = _observed_plays.get(card_id, 0) as int
		var left:     float = max(0.0, expected - float(observed))
		pool_total += left

		var record: CardRecord = CardRegistry.get_card(card_id)
		if record != null and record.has_subtype(subtype):
			pool_matching += left

	if pool_total <= 0.0 or pool_matching <= 0.0:
		return 0.0

	# P(at least one in grip of size N):
	# P(none) ≈ ((total - matching) / total) ^ N   (binomial approximation)
	var grip: int = ctx.runner_hand.size()
	if grip <= 0:
		return 0.0

	var p_none: float = pow(
		(pool_total - pool_matching) / pool_total,
		grip)
	return clampf(1.0 - p_none, 0.0, 1.0)


# How complete is the runner's rig relative to the deck's expected breaker suite?
# Returns 0.0 (empty rig) to 1.0 (fully rigged).
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

	# Sum expected breakers across the prior
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


# Returns up to k likely runner next-turn actions with probability weights.
# Each entry: { "type": String, "server_id": String, "probability": float }
# Probabilities are normalised to sum to 1.0 across the returned set.
func k_likely_runner_responses(k: int, ctx: GameContext) -> Array:
	var candidates: Array = []

	# Run candidates — scored by observable threat per server
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

	# Install candidate — runner likely to build rig if it's incomplete
	if ctx.runner_credits >= 3 and _prior_deck.size() > 0:
		var install_prob: float = clampf(1.0 - estimated_rig_completeness(ctx), 0.1, 0.6)
		candidates.append({
			"type":        "install",
			"server_id":   "",
			"probability": install_prob,
		})

	# Sort by probability descending
	candidates.sort_custom(func(a, b):
		return float(a["probability"]) > float(b["probability"]))

	# Take top k and normalise
	var top_k: Array = candidates.slice(0, k)
	var total := 0.0
	for entry in top_k:
		total += float(entry["probability"])
	if total > 0.0:
		for i in range(top_k.size()):
			var e: Dictionary = (top_k[i] as Dictionary).duplicate()
			e["probability"] = float(e["probability"]) / total
			top_k[i] = e

	return top_k
