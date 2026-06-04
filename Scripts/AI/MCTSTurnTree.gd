class_name MCTSTurnTree
extends RefCounted

# ── MCTSTurnTree ──────────────────────────────────────────────────────────────
# Turn-granularity MCTS where each tree node is a game state at the START of a
# Corp turn (after the runner's previous turn) and each edge encodes a full
# (Corp turn sequence, runner turn response) pair.
#
# CorpTurnPlanner handles intra-turn planning (picking the best Corp sequence
# for a given node state).  The tree search handles inter-turn strategy: it
# evaluates multi-turn plans that a single-turn beam cannot see.
#
# The tree is DETERMINISTIC in structure: each Corp sequence maps to exactly
# one child node via the snapshot-based threat heuristic for the runner
# response.  Stochasticity lives in the rollouts, where runner responses are
# sampled from the Bayesian distribution.
#
# See Planning/tai_limitation_fixes.txt (MCTSTurnTree design specification)
# for full rationale, parameter guidance, and implementation plan.
# ─────────────────────────────────────────────────────────────────────────────

# ── Parameters ────────────────────────────────────────────────────────────────

const DEFAULT_ITERATIONS          := 200
const DEFAULT_EXPANSION_SEQUENCES := 5
const DEFAULT_ROLLOUT_DEPTH       := 4
const DEFAULT_EXPLORATION_C       := 1.5
const DEFAULT_ROLLOUT_BEAM_WIDTH  := 2

# Value normalisation bounds.  Scores outside this range clip to 0.02 / 0.98.
# Adjust after reviewing evaluate() output distributions across real games.
const EVAL_FLOOR := -150.0
const EVAL_CEIL  :=  150.0

var _evaluator: CorpStateEvaluator
var _planner:   CorpTurnPlanner
var _bayes:     BayesianRunnerModel

var iterations:          int   = DEFAULT_ITERATIONS
var expansion_sequences: int   = DEFAULT_EXPANSION_SEQUENCES
var rollout_depth:       int   = DEFAULT_ROLLOUT_DEPTH
var exploration_c:       float = DEFAULT_EXPLORATION_C
var rollout_beam_width:  int   = DEFAULT_ROLLOUT_BEAM_WIDTH


func _init(
		evaluator: CorpStateEvaluator,
		planner:   CorpTurnPlanner,
		bayes:     BayesianRunnerModel) -> void:
	_evaluator = evaluator
	_planner   = planner
	_bayes     = bayes


# ── Public API ────────────────────────────────────────────────────────────────

# Run the MCTS search and return the best first action.
# ctx is the live GameContext for the current Corp turn.
func search(ctx: GameContext) -> GameAction:
	var root_state: Dictionary = _evaluator.snapshot(ctx)

	var root: MCTSTurnNode = MCTSTurnNode.new()
	root.state = root_state

	for _i in range(iterations):
		# 1. Selection: walk tree by UCB1 to an unvisited or unexpanded node.
		var node: MCTSTurnNode = _select(root)

		# 2. Expansion: generate children when this node hasn't been explored yet.
		if not node.is_expanded and not _is_terminal(node.state):
			_expand(node, ctx)
			if not node.children.is_empty():
				# Pick one child at random for the rollout this iteration.
				node = node.children[randi() % node.children.size()] as MCTSTurnNode

		# 3. Rollout: simulate turns forward from this node.
		var raw_value: float = _rollout(node.state)
		var value: float     = _normalize(raw_value)

		# 4. Backpropagation: update visits and accumulated value up to root.
		_backpropagate(node, value)

	return _best_action(root)


# ── Selection ─────────────────────────────────────────────────────────────────

func _select(root: MCTSTurnNode) -> MCTSTurnNode:
	var node: MCTSTurnNode = root
	while node.is_expanded and not node.children.is_empty() \
			and not _is_terminal(node.state):
		node = _best_ucb1_child(node)
	return node


func _best_ucb1_child(node: MCTSTurnNode) -> MCTSTurnNode:
	var best:     MCTSTurnNode = null
	var best_ucb: float        = -INF
	for c in node.children:
		var child: MCTSTurnNode = c as MCTSTurnNode
		var ucb: float = child.ucb1(exploration_c, node.visits)
		if ucb > best_ucb:
			best_ucb = ucb
			best     = child
	return best if best != null else node.children[0] as MCTSTurnNode


# ── Expansion ─────────────────────────────────────────────────────────────────

# Generates child nodes: one per distinct Corp turn sequence.
# Uses the snapshot-based threat heuristic for the runner response so the
# tree structure is deterministic and independent of live ctx staleness.
# The live ctx is still used for CorpTurnPlanner (accurate tag-yield etc.)
# when available (root expansion); deeper nodes pass null.
func _expand(node: MCTSTurnNode, ctx: GameContext) -> void:
	node.is_expanded = true

	# Get K distinct Corp turn sequences from the planner.
	var sequences: Array = _planner.plan_distinct_sequences(
		node.state, expansion_sequences, ctx)

	# Derive the runner's most likely target from the Bayesian model when
	# available, otherwise fall back to the snapshot heuristic.
	var runner_threat: String = _bayes_threat_server(node.state)

	for seq in sequences:
		var seq_arr: Array = seq as Array
		if seq_arr.is_empty():
			continue

		# Project the full Corp turn sequence onto a new state.
		var corp_end: Dictionary = node.state.duplicate(true)
		for act in seq_arr:
			corp_end = _evaluator.project_corp_action(corp_end, act as GameAction, null)
			if _is_terminal(corp_end):
				break

		# Project the runner's turn (snapshot heuristic for the response server).
		var runner_end: Dictionary = _evaluator.project_runner_response(
			corp_end, runner_threat, null)

		# Apply runner economy and reset Corp clicks for the next turn.
		var child_state: Dictionary = _start_of_corp_turn(_apply_runner_economy(runner_end))

		var child: MCTSTurnNode      = MCTSTurnNode.new()
		child.state          = child_state
		child.parent         = node
		child.leading_action = seq_arr[0] as GameAction
		node.children.append(child)


# ── Rollout ───────────────────────────────────────────────────────────────────

# Simulates rollout_depth full turn pairs (Corp + Runner) using a fast policy.
# Returns a raw evaluator score (not yet normalised).
func _rollout(start_state: Dictionary) -> float:
	var state: Dictionary = start_state.duplicate(true)

	for _turn in range(rollout_depth):
		# ── Corp turn ──────────────────────────────────────────────────────────
		var threat: String = _bayes_threat_server(state)

		var old_bw: int    = _planner.beam_width
		_planner.beam_width = rollout_beam_width
		var sequence: Array = _planner.plan_full_sequence(state, threat, null)
		_planner.beam_width = old_bw

		for act in sequence:
			state = _evaluator.project_corp_action(state, act as GameAction, null)
			if _is_terminal(state):
				return CorpStateEvaluator.WIN_VALUE \
					if (state.get("corp_score", 0) as int) >= (state.get("pts_to_win", 7) as int) \
					else CorpStateEvaluator.LOSE_VALUE

		# ── Runner turn ────────────────────────────────────────────────────────
		state = _project_runner_turn(state)

		if _is_terminal(state):
			return CorpStateEvaluator.LOSE_VALUE \
				if (state.get("runner_score", 0) as int) >= (state.get("pts_to_win", 7) as int) \
				else CorpStateEvaluator.WIN_VALUE

		# Reset for next Corp turn.
		state = _start_of_corp_turn(state)

	return _evaluator.evaluate(state)


# ── Backpropagation ───────────────────────────────────────────────────────────

func _backpropagate(node: MCTSTurnNode, value: float) -> void:
	var current: MCTSTurnNode = node
	while current != null:
		current.visits      += 1
		current.total_value += value
		current = current.parent


# ── Action selection ──────────────────────────────────────────────────────────

# Return the leading action of the most-visited root child (robust UCT choice).
func _best_action(root: MCTSTurnNode) -> GameAction:
	if root.children.is_empty():
		return GameAction.gain_credits()

	var best_child:  MCTSTurnNode = null
	var best_visits: int          = -1
	for c in root.children:
		var child: MCTSTurnNode = c as MCTSTurnNode
		if child.visits > best_visits:
			best_visits = child.visits
			best_child  = child

	return best_child.leading_action \
		if best_child != null and best_child.leading_action != null \
		else GameAction.gain_credits()


# ── Helpers ───────────────────────────────────────────────────────────────────

# A state is terminal when either player has reached the agenda-points threshold.
static func _is_terminal(state: Dictionary) -> bool:
	var pts: int = state.get("pts_to_win", 7) as int
	return (state.get("corp_score",   0) as int) >= pts \
		or (state.get("runner_score", 0) as int) >= pts


# Normalise a raw evaluator score to [0, 1] for UCB1 comparisons.
func _normalize(raw: float) -> float:
	if raw >= CorpStateEvaluator.WIN_VALUE:  return 1.0
	if raw <= CorpStateEvaluator.LOSE_VALUE: return 0.0
	return clampf((raw - EVAL_FLOOR) / (EVAL_CEIL - EVAL_FLOOR), 0.02, 0.98)


# Returns the most likely runner target server from the current snapshot.
# Uses the Bayesian model (k_likely_runner_responses_from_snap) when it has
# been seeded; falls back to the snapshot heuristic otherwise.
func _bayes_threat_server(state: Dictionary) -> String:
	if _bayes != null and not _bayes._prior_deck.is_empty():
		var responses: Array = _bayes.k_likely_runner_responses_from_snap(1, state)
		if not responses.is_empty():
			var r: Dictionary = responses[0] as Dictionary
			if r.get("type", "run") == "run":
				return r.get("server_id", "rd") as String
	return _rollout_threat_server(state)


# Snapshot heuristic fallback: naked agenda first, then least-iced central.
func _rollout_threat_server(state: Dictionary) -> String:
	for remote in state.get("remotes", []) as Array:
		var r: Dictionary = remote as Dictionary
		if r.get("has_agenda", false) and (r.get("ice_count", 0) as int) == 0:
			return r.get("server_id", "rd") as String
	var rd_ice: int = state.get("rd_ice", 0) as int
	var hq_ice: int = state.get("hq_ice", 0) as int
	return "rd" if rd_ice <= hq_ice else "hq"


# Project the runner's turn from a SimState snapshot.
# Uses k_likely_runner_responses_from_snap for stochastic server selection
# when the Bayesian model has been seeded; falls back to the heuristic.
func _project_runner_turn(state: Dictionary) -> Dictionary:
	var server: String = "rd"

	if _bayes != null and not _bayes._prior_deck.is_empty():
		var responses: Array = _bayes.k_likely_runner_responses_from_snap(3, state)
		if not responses.is_empty():
			# Sample proportionally from the probability distribution.
			var roll: float  = randf()
			var cumulative: float = 0.0
			for r in responses:
				var rd: Dictionary = r as Dictionary
				cumulative += rd.get("probability", 0.0) as float
				if roll <= cumulative:
					if rd.get("type", "run") == "run":
						server = rd.get("server_id", "rd") as String
					break
	else:
		server = _rollout_threat_server(state)

	var ns: Dictionary = _evaluator.project_runner_response(state, server, null)
	return _apply_runner_economy(ns)


# Apply a simple runner economy model: runner gains ~2 credits per turn on
# average (accounts for Sure Gamble, Bravado, Liberated Account draws, etc.)
func _apply_runner_economy(state: Dictionary) -> Dictionary:
	var ns: Dictionary = state.duplicate(true)
	ns["runner_credits"] = (ns.get("runner_credits", 0) as int) + 2
	return ns


# Apply the Corp turn-start resets: restore clicks to 3 and model the
# mandatory draw (Corp draws 1 card unless deck is empty or hand is full).
func _start_of_corp_turn(state: Dictionary) -> Dictionary:
	var ns: Dictionary      = state.duplicate(true)
	ns["corp_clicks_left"]  = 3
	var hand:  int = ns.get("corp_hand",       0) as int
	var limit: int = ns.get("corp_hand_limit", 5) as int
	var deck:  int = ns.get("corp_deck",       0) as int
	if deck > 0 and hand < limit:
		ns["corp_hand"] = hand + 1
		ns["corp_deck"] = deck - 1
	return ns
