class_name RunnerTurnPlanner
extends RefCounted

# ── RunnerTurnPlanner ─────────────────────────────────────────────────────────
# Plans the Runner's full remaining turn as a single unit using beam search
# over SimState snapshots.  Mirrors CorpTurnPlanner's architecture.
#
# Combos emerge naturally: "gain cr → install fracter → gain cr → run remote"
# scores higher than any credit-gain-only sequence because evaluate() sees
# runner_score increase after the agenda steal.
#
# Each beam entry: { "state": Dictionary, "sequence": Array[GameAction], "score": float }
# ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_BEAM_WIDTH  := 5
const MAX_CLICKS_PER_TURN := 4

var _evaluator: RunnerStateEvaluator
var beam_width: int = DEFAULT_BEAM_WIDTH


func _init(evaluator: RunnerStateEvaluator) -> void:
	_evaluator = evaluator


# ── Public API ────────────────────────────────────────────────────────────────

# Primary entry point.  Returns the first action of the best planned turn.
func plan_first_action(initial_snap: Dictionary, _ctx: GameContext = null) -> GameAction:
	var beams: Array = _run_beam(initial_snap)
	return _pick_best(beams)


# Returns the full planned sequence (for debug/logging purposes).
func plan_full_sequence(initial_snap: Dictionary) -> Array:
	var beams: Array = _run_beam(initial_snap)
	if beams.is_empty():
		return []
	var best: Dictionary = _best_beam(beams)
	return best.get("sequence", []) as Array


# ── Beam expansion ────────────────────────────────────────────────────────────

func _run_beam(initial_snap: Dictionary) -> Array:
	var beams: Array = [{
		"state":    initial_snap,
		"sequence": [],
		"score":    _evaluator.evaluate(initial_snap),
	}]

	var rounds: int = clampi(
		initial_snap.get("runner_clicks_left", 4) as int,
		0, MAX_CLICKS_PER_TURN)

	for _round in range(rounds):
		var next_beams: Array = []

		for b in beams:
			var beam:   Dictionary = b as Dictionary
			var bstate: Dictionary = beam.get("state", {}) as Dictionary

			# Terminal beams pass through unchanged.
			if (bstate.get("runner_clicks_left", 0) as int) <= 0 \
					or _is_terminal(bstate):
				next_beams.append(beam)
				continue

			var old_seq: Array = beam.get("sequence", []) as Array
			for act in RunnerCandidateGenerator.generate(bstate):
				var action:    GameAction = act as GameAction
				var new_state: Dictionary = _evaluator.project_runner_action(bstate, action)
				next_beams.append({
					"state":    new_state,
					"sequence": old_seq + [action],
					"score":    _evaluator.evaluate(new_state),
				})

		# Prune to beam_width by intermediate score.
		next_beams.sort_custom(_sort_desc)
		beams = next_beams.slice(0, beam_width)

	return beams


# ── Selection helpers ─────────────────────────────────────────────────────────

func _pick_best(beams: Array) -> GameAction:
	if beams.is_empty():
		return GameAction.gain_credits()
	var best: Dictionary = _best_beam(beams)
	var seq: Array = best.get("sequence", []) as Array
	if seq.is_empty():
		return GameAction.gain_credits()
	return seq[0] as GameAction


func _best_beam(beams: Array) -> Dictionary:
	var best_beam:  Dictionary = {}
	var best_score: float      = -INF
	for b in beams:
		var bs: Dictionary = b as Dictionary
		var sc: float      = bs.get("score", 0.0) as float
		if sc > best_score:
			best_score = sc
			best_beam  = bs
	return best_beam


static func _is_terminal(state: Dictionary) -> bool:
	var pts: int = state.get("pts_to_win", 7) as int
	return (state.get("runner_score", 0) as int) >= pts \
		or (state.get("corp_score",   0) as int) >= pts


static func _sort_desc(a: Dictionary, b: Dictionary) -> bool:
	return (a.get("score", 0.0) as float) > (b.get("score", 0.0) as float)
