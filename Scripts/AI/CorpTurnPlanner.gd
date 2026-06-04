class_name CorpTurnPlanner
extends RefCounted

# ── CorpTurnPlanner ───────────────────────────────────────────────────────────
# Plans the Corp's full turn — all remaining clicks — as a single unit using
# beam search over the SnapshotCandidateGenerator action space.
#
# Instead of evaluating each click independently (1-ply) or doing a 2-ply
# lookahead per action, the planner generates sequences of up to MAX_CLICKS
# Corp actions, evaluates the end state of each sequence with a runner
# response projection, and returns the first action of the best sequence found.
#
# Combos emerge naturally: "advance×N → score" is valued because evaluate()
# sees corp_score increase; "score → neurospike" is valued because evaluate()
# sees runner_hand = 0 → LOSE_VALUE.  No bespoke override is needed to detect
# these lines — they score higher than any credit-gain sequence on their own.
#
# See Planning/tai_limitation_fixes.txt (CorpTurnPlanner design specification)
# for full rationale, parameter guidance, and integration plan.
# ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_BEAM_WIDTH  := 5
const MAX_CLICKS_PER_TURN := 4   # guard against future extra-click grants

var _evaluator: CorpStateEvaluator
var beam_width: int = DEFAULT_BEAM_WIDTH


func _init(evaluator: CorpStateEvaluator) -> void:
	_evaluator = evaluator


# ── Public API ────────────────────────────────────────────────────────────────

# Primary entry point.  Returns the first action of the best planned turn
# under single-response runner evaluation.
# threat_server: the server the runner is most likely to attack next turn.
#   "" defaults to "rd".
# ctx: live GameContext for accurate tag-yield projection; null is safe.
func plan_first_action(
		initial_snap:  Dictionary,
		threat_server: String     = "rd",
		ctx:           GameContext = null) -> GameAction:
	var beams: Array = _run_beam(initial_snap, ctx)
	return _pick_best_single(beams, threat_server)


# Strategic variant: final evaluation uses k weighted runner responses from the
# Bayesian model rather than a single threat server.
func plan_first_action_weighted(
		initial_snap:     Dictionary,
		runner_responses: Array,
		ctx:              GameContext = null) -> GameAction:
	var beams: Array = _run_beam(initial_snap, ctx)
	return _pick_best_weighted(beams, runner_responses)


# Returns the full planned action sequence for debug/logging purposes.
# Callers should normally use plan_first_action().
func plan_full_sequence(
		initial_snap:  Dictionary,
		threat_server: String     = "rd",
		ctx:           GameContext = null) -> Array:   # Array[GameAction]
	var beams: Array = _run_beam(initial_snap, ctx)
	if beams.is_empty():
		return []
	var best: Dictionary = _best_beam_single(beams, threat_server)
	return best.get("sequence", []) as Array


# Returns up to max_seqs full sequences with DISTINCT first actions, ranked
# by end-state score.  Used by MCTSTurnTree to generate K diverse child nodes.
# Runs the beam at (max_seqs × 3) width to ensure enough diversity, then
# deduplicates by first-action description.
func plan_distinct_sequences(
		initial_snap: Dictionary,
		max_seqs:     int,
		ctx:          GameContext = null) -> Array:   # Array[Array[GameAction]]
	var old_width: int = beam_width
	beam_width = max_seqs * 3
	var all_beams: Array = _run_beam(initial_snap, ctx)
	beam_width = old_width

	var seen:   Dictionary = {}
	var result: Array      = []

	for b in all_beams:
		var seq: Array = (b as Dictionary).get("sequence", []) as Array
		if seq.is_empty():
			continue
		var key: String = (seq[0] as GameAction).describe()
		if seen.has(key):
			continue
		seen[key] = true
		result.append(seq)
		if result.size() >= max_seqs:
			break

	# Always return at least one sequence.
	if result.is_empty():
		var fallback: GameAction = plan_first_action(initial_snap, "rd", ctx)
		result.append([fallback])

	return result


# ── Beam expansion ────────────────────────────────────────────────────────────

# Expands the beam for corp_clicks_left rounds, pruning to beam_width after
# each round.  Returns the final beam Array[Dictionary].
# Each beam entry: { "state": Dictionary, "sequence": Array, "score": float }
func _run_beam(initial_snap: Dictionary, ctx: GameContext = null) -> Array:
	var beams: Array = [{
		"state":    initial_snap,
		"sequence": [],
		"score":    _evaluator.evaluate(initial_snap),
	}]

	var rounds: int = clamp(
		initial_snap.get("corp_clicks_left", 3) as int,
		0, MAX_CLICKS_PER_TURN)

	for _round in range(rounds):
		var next_beams: Array = []

		for b in beams:
			var beam:   Dictionary = b as Dictionary
			var bstate: Dictionary = beam.get("state", {}) as Dictionary

			# Terminal beams (no clicks left, or someone has won) pass through.
			if (bstate.get("corp_clicks_left", 0) as int) <= 0 \
					or _is_terminal(bstate):
				next_beams.append(beam)
				continue

			# Expand by one click.
			var old_seq: Array = beam.get("sequence", []) as Array
			for act in SnapshotCandidateGenerator.generate(bstate):
				var action:    GameAction  = act as GameAction
				var new_state: Dictionary  = _evaluator.project_corp_action(
					bstate, action, ctx)
				next_beams.append({
					"state":    new_state,
					"sequence": old_seq + [action],
					"score":    _evaluator.evaluate(new_state),
				})

		# Prune: keep top beam_width entries by intermediate score.
		next_beams.sort_custom(_sort_desc)
		beams = next_beams.slice(0, beam_width)

	return beams


# ── Final evaluation helpers ──────────────────────────────────────────────────

# Pick the first action of the best beam under single-response final eval.
func _pick_best_single(beams: Array, threat_server: String) -> GameAction:
	if beams.is_empty():
		return GameAction.gain_credits()
	var best: Dictionary = _best_beam_single(beams, threat_server)
	var seq: Array = best.get("sequence", []) as Array
	if seq.is_empty():
		return GameAction.gain_credits()
	return seq[0] as GameAction


# Find the beam with the highest final score under single-response evaluation.
func _best_beam_single(beams: Array, threat_server: String) -> Dictionary:
	var server: String = threat_server if threat_server != "" else "rd"
	var best_beam:  Dictionary = {}
	var best_score: float      = -INF
	for b in beams:
		var bs:   Dictionary = b as Dictionary
		var post: Dictionary = _evaluator.project_runner_response(
			bs.get("state", {}) as Dictionary, server, null)
		var fs: float = _evaluator.evaluate(post)
		if fs > best_score:
			best_score = fs
			best_beam  = bs
	return best_beam


# Pick the first action of the best beam under k-weighted runner response eval.
func _pick_best_weighted(beams: Array, runner_responses: Array) -> GameAction:
	if beams.is_empty():
		return GameAction.gain_credits()
	var best_beam:  Dictionary = {}
	var best_score: float      = -INF
	for b in beams:
		var bs: Dictionary = b as Dictionary
		var fs: float = _eval_weighted(
			bs.get("state", {}) as Dictionary, runner_responses)
		if fs > best_score:
			best_score = fs
			best_beam  = bs
	var seq: Array = best_beam.get("sequence", []) as Array
	if seq.is_empty():
		return GameAction.gain_credits()
	return seq[0] as GameAction


# Weighted average of evaluate() over k runner response scenarios.
func _eval_weighted(state: Dictionary, responses: Array) -> float:
	if responses.is_empty():
		# No runner model seeded — fall back to single-response with "rd".
		var post: Dictionary = _evaluator.project_runner_response(state, "rd", null)
		return _evaluator.evaluate(post)
	var weighted := 0.0
	for r in responses:
		var rd:   Dictionary = r as Dictionary
		var post: Dictionary = _evaluator.project_runner_response(
			state, rd.get("server_id", "rd") as String, null)
		weighted += (rd.get("probability", 0.0) as float) * _evaluator.evaluate(post)
	return weighted


# ── Helpers ───────────────────────────────────────────────────────────────────

# A state is terminal when either player has reached the win threshold, or
# there is no more Corp time left in the turn.
static func _is_terminal(state: Dictionary) -> bool:
	var pts: int = state.get("pts_to_win", 7) as int
	return (state.get("corp_score",   0) as int) >= pts \
		or (state.get("runner_score", 0) as int) >= pts


# Sort comparator: descending score (higher = better for Corp).
static func _sort_desc(a: Dictionary, b: Dictionary) -> bool:
	return (a.get("score", 0.0) as float) > (b.get("score", 0.0) as float)
