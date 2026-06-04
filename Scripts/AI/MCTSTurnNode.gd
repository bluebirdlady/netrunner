class_name MCTSTurnNode
extends RefCounted

# ── MCTSTurnNode ──────────────────────────────────────────────────────────────
# One node in the turn-level MCTS tree.
#
# Each node represents a game state at the START of a Corp turn (i.e. after
# the runner's previous turn has been resolved).  The edge from parent to this
# node encodes a (Corp full-turn sequence, runner response) pair.
#
# leading_action is the FIRST action of the Corp sequence that reached this
# node from its parent.  It is returned by MCTSTurnTree._best_action() as the
# chosen action for the current turn.
# ─────────────────────────────────────────────────────────────────────────────

var state:          Dictionary    # SimState snapshot at Corp turn start
var parent:         MCTSTurnNode  # null for the root node
var leading_action: GameAction    # first Corp action of the edge; null for root
var children:       Array         # Array[MCTSTurnNode]
var visits:         int   = 0     # N(s): times this node has been visited
var total_value:    float = 0.0   # W(s): sum of normalised rollout values
var is_expanded:    bool  = false # whether children have been generated yet


# Q(s): average rollout value — exploit term for UCB1.
func q_value() -> float:
	return total_value / float(visits) if visits > 0 else 0.0


# UCB1 score for use in _select().  Parent visits must be > 0 before calling.
func ucb1(exploration_c: float, parent_visits: int) -> float:
	if visits == 0:
		return INF   # unvisited children always explored first
	return q_value() + exploration_c * sqrt(log(float(parent_visits)) / float(visits))
