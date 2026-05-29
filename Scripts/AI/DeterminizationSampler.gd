class_name DeterminizationSampler
extends RefCounted

# ── DeterminizationSampler ────────────────────────────────────────────────────
# Produces N plausible GameContext instances from the Corp's point of view by
# sampling hidden Runner information (grip contents and deck order).
#
# What the Corp sees:
#   - Runner grip SIZE  (ctx.runner_hand.size())
#   - All installed cards in the runner rig
#   - Cards the runner has played or discarded (public information)
#   - Everything on the Corp's side
#
# What the Corp does NOT see:
#   - Individual card identities in the runner's grip
#   - The order of the runner's remaining stack
#
# Sampling strategy:
#   1. Build the remaining card pool: all runner cards minus confirmed-seen ones.
#      If a BayesianRunnerModel is provided, weight by its posterior estimates.
#      Otherwise draw uniformly.
#   2. Draw grip_size cards from the pool without replacement → new grip.
#   3. Put leftover pool cards into runner_deck and shuffle.
#   4. Clone ctx and replace runner_hand / runner_deck with the sample.

# ── Public API ────────────────────────────────────────────────────────────────

# ctx        — the real game context (not modified)
# n          — number of determinizations to generate (recommended: 8–16)
# bayes      — optional BayesianRunnerModel; null = uniform sampling
# card_pool  — all CardRecord objects in the format (used to build the pool)
static func sample(
		ctx:       GameContext,
		n:         int,
		bayes:     BayesianRunnerModel,
		card_pool: Array) -> Array:

	var results: Array = []
	var grip_size: int = ctx.runner_hand.size()

	# Build weighted pool once — shared across all N samples.
	var pool_weights: Array = _build_pool(ctx, bayes, card_pool)
	if pool_weights.is_empty():
		# Fallback: return N clones with the grip left opaque (all nulls).
		for _i in range(n):
			results.append(ctx.clone_for_sim())
		return results

	for _i in range(n):
		var sim := ctx.clone_for_sim()
		_resample_runner_hidden_info(sim, grip_size, pool_weights.duplicate(true))
		results.append(sim)

	return results


# ── Pool construction ─────────────────────────────────────────────────────────

# Returns Array of { "record": CardRecord, "weight": float } for every card
# that could plausibly still be in the runner's unseen zones (grip + stack).
# Cards already public (rig, discard, score area, grip entries we know) are
# excluded from the pool.
static func _build_pool(
		ctx:       GameContext,
		bayes:     BayesianRunnerModel,
		card_pool: Array) -> Array:

	# Count confirmed public copies of each card_id.
	var public_counts: Dictionary = {}

	# Installed rig cards are known
	for ic in ctx.runner_rig:
		var c: InstalledCard = ic as InstalledCard
		if c != null and c.card_id != "":
			public_counts[c.card_id] = public_counts.get(c.card_id, 0) + 1

	# Runner discard is face-up
	for r in ctx.runner_discard:
		var cr: CardRecord = r as CardRecord
		if cr != null:
			public_counts[cr.id] = public_counts.get(cr.id, 0) + 1

	# Runner score area is public
	for r in ctx.runner_score_area:
		var cr: CardRecord = r as CardRecord
		if cr != null:
			public_counts[cr.id] = public_counts.get(cr.id, 0) + 1

	# Grip cards that are already revealed (e.g. Imp hosting, VP effects)
	# In standard play these are opaque — we skip them.

	# Build weighted entries from the Bayesian prior (or uniform fallback).
	var pool: Array = []

	if bayes != null and not bayes._prior_deck.is_empty():
		for card_id in bayes._prior_deck:
			var expected: float  = float(bayes._prior_deck[card_id])
			var observed: int    = bayes._observed_plays.get(card_id, 0) as int
			var pub:      int    = public_counts.get(card_id, 0)
			var remaining: float = max(0.0, expected - float(observed) - float(pub))
			if remaining <= 0.0:
				continue
			var record: CardRecord = CardRegistry.get_card(card_id)
			if record == null:
				continue
			pool.append({"record": record, "weight": remaining})
	else:
		# Uniform fallback: every legal runner card with weight 1.0 minus publics.
		for entry in card_pool:
			var record: CardRecord = entry as CardRecord
			if record == null or record.side != "runner" or record.card_type == "identity":
				continue
			var pub: int = public_counts.get(record.id, 0)
			var w: float = max(0.0, 1.0 - float(pub))
			if w <= 0.0:
				continue
			pool.append({"record": record, "weight": w})

	return pool


# ── Hidden-info replacement ───────────────────────────────────────────────────

# Replaces runner_hand and runner_deck on the cloned sim context with a
# freshly sampled draw from pool_weights (modified in-place during drawing).
static func _resample_runner_hidden_info(
		sim:          GameContext,
		grip_size:    int,
		pool_weights: Array) -> void:

	var drawn: Array[CardRecord] = []
	var leftover: Array[CardRecord] = []

	# Weighted draw without replacement for the grip.
	for _i in range(grip_size):
		if pool_weights.is_empty():
			break
		var record: CardRecord = _weighted_draw(pool_weights)
		if record != null:
			drawn.append(record)

	# Everything remaining in the pool goes to the stack.
	for entry in pool_weights:
		var e: Dictionary = entry as Dictionary
		var record: CardRecord = e.get("record", null) as CardRecord
		if record == null:
			continue
		# Each entry may represent fractional expected copies — round to nearest int,
		# minimum 0, maximum 3.
		var copies: int = clampi(roundi(float(e["weight"])), 0, 3)
		for _j in range(copies):
			leftover.append(record)

	# Shuffle the leftover stack order.
	leftover.shuffle()

	# Write into the sim context.
	sim.runner_hand.clear()
	for record in drawn:
		sim.runner_hand.append({"card_id": record.id, "card_record": record})

	sim.runner_deck.clear()
	for record in leftover:
		sim.runner_deck.append(record)


# ── Weighted sampling ─────────────────────────────────────────────────────────

# Draws one CardRecord from pool_weights proportional to weight,
# removes the drawn entry, and returns the record.
static func _weighted_draw(pool_weights: Array) -> CardRecord:
	var total: float = 0.0
	for entry in pool_weights:
		total += float((entry as Dictionary).get("weight", 0.0))
	if total <= 0.0:
		return null

	var roll: float = randf() * total
	var cumulative: float = 0.0
	for i in range(pool_weights.size()):
		var entry: Dictionary = pool_weights[i] as Dictionary
		cumulative += float(entry.get("weight", 0.0))
		if cumulative >= roll:
			pool_weights.remove_at(i)
			return entry.get("record", null) as CardRecord

	# Rounding edge: return last entry.
	var last: Dictionary = pool_weights[-1] as Dictionary
	pool_weights.remove_at(pool_weights.size() - 1)
	return last.get("record", null) as CardRecord
