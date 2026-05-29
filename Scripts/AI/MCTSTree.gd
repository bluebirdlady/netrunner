class_name MCTSTree
extends RefCounted

# ── MCTSTree ──────────────────────────────────────────────────────────────────
# UCB1-guided Monte Carlo Tree Search over determinized game states.
#
# Algorithm per determinization:
#   1. Selection   — walk tree with UCB1 until a non-fully-expanded node.
#   2. Expansion   — pick one untried action, project state via CorpStateEvaluator.
#   3. Rollout     — GameSimulator.advance(det_root, ROLLOUT_DEPTH) → evaluate.
#   4. Backprop    — update visit counts and total values up to root.
#
# After all iterations across all determinizations, aggregate root-child scores
# by action key and return the action with the highest average value.
#
# Rollout note: rollouts always start from the determinization root context
# rather than the exact expanded-node state. This is an approximation that
# avoids storing full GameContexts at every tree node. The UCB1 selection
# still guides search toward promising first actions; the rollout provides a
# value signal from that determinized world.

# ── Parameters ────────────────────────────────────────────────────────────────

const DETERMINIZATIONS:   int   = 8
const ITERATIONS_PER_DET: int   = 50
const ROLLOUT_DEPTH:       int   = 8
const UCB_C:               float = 1.414


# ── MCTSNode ──────────────────────────────────────────────────────────────────

class MCTSNode:
	var state_snapshot: Dictionary  # SimState from CorpStateEvaluator.snapshot()
	var action:         GameAction  # action that led to this node (null = root)
	var parent:         MCTSNode    # null for root
	var children:       Array       # Array[MCTSNode]
	var visits:         int   = 0
	var total_value:    float = 0.0
	var untried_actions: Array      # Array[GameAction] not yet expanded

	func _init(
			snapshot:    Dictionary,
			act:         GameAction,
			par:         MCTSNode,
			candidates:  Array) -> void:
		state_snapshot  = snapshot
		action          = act
		parent          = par
		children        = []
		untried_actions = candidates.duplicate()

	func is_terminal() -> bool:
		var corp_score:   int = state_snapshot.get("corp_score",   0) as int
		var runner_score: int = state_snapshot.get("runner_score", 0) as int
		var pts:          int = state_snapshot.get("pts_to_win",   7) as int
		return corp_score >= pts or runner_score >= pts

	func is_fully_expanded() -> bool:
		return untried_actions.is_empty()

	# UCB1 score — caller must ensure parent != null and parent.visits > 0.
	func ucb1(c: float) -> float:
		if visits == 0:
			return INF
		return (total_value / float(visits)) + c * sqrt(log(float(parent.visits)) / float(visits))

	# Best child by UCB1.
	func best_child(c: float) -> MCTSNode:
		var best:       MCTSNode = null
		var best_score: float   = -INF
		for child in children:
			var s: float = (child as MCTSNode).ucb1(c)
			if s > best_score:
				best_score = s
				best = child as MCTSNode
		return best


# ── MCTSTree internals ────────────────────────────────────────────────────────

var _evaluator:       CorpStateEvaluator
var _ability_registry: AbilityRegistry

# Accumulated across all determinizations: action_key → {action, visits, total}
var _action_scores: Dictionary = {}


func _init(ability_registry: AbilityRegistry) -> void:
	_ability_registry = ability_registry
	_evaluator        = CorpStateEvaluator.new()


# ── Public entry point ────────────────────────────────────────────────────────

# Returns the best Corp GameAction determined by MCTS over N determinizations.
# card_pool  — Array[CardRecord] of all legal cards (for DeterminizationSampler)
# bayes      — optional BayesianRunnerModel; null = uniform sampling
func choose_action(
		ctx:       GameContext,
		card_pool: Array,
		bayes:     BayesianRunnerModel) -> GameAction:
	_action_scores.clear()

	var determinizations: Array = DeterminizationSampler.sample(
		ctx, DETERMINIZATIONS, bayes, card_pool)

	for det_entry in determinizations:
		var det: GameContext = det_entry as GameContext
		if det == null:
			continue
		await _run_mcts_on_determinization(det, ctx)

	return _pick_best_action(ctx)


# ── MCTS per determinization ──────────────────────────────────────────────────

func _run_mcts_on_determinization(det_ctx: GameContext, real_ctx: GameContext) -> void:
	var root_snap:       Dictionary = _evaluator.snapshot(det_ctx)
	var root_candidates: Array      = _get_root_candidates(real_ctx)
	var root := MCTSNode.new(root_snap, null, null, root_candidates)

	for _i in range(ITERATIONS_PER_DET):
		var node: MCTSNode = _select(root)

		if not node.is_terminal() and not node.is_fully_expanded():
			node = _expand(node)

		var value: float = await _rollout(node, det_ctx)
		_backpropagate(node, value)

	# Accumulate root children scores into the global table.
	for child in root.children:
		var c: MCTSNode = child as MCTSNode
		if c.action == null:
			continue
		var key: String = _action_key(c.action)
		if not _action_scores.has(key):
			_action_scores[key] = {"action": c.action, "visits": 0, "total": 0.0}
		var entry: Dictionary = _action_scores[key] as Dictionary
		entry["visits"] = (entry.get("visits", 0) as int) + c.visits
		entry["total"]  = (entry.get("total",  0.0) as float) + c.total_value


# ── Selection ─────────────────────────────────────────────────────────────────

func _select(root: MCTSNode) -> MCTSNode:
	var node: MCTSNode = root
	while node.is_fully_expanded() and not node.children.is_empty() and not node.is_terminal():
		node = node.best_child(UCB_C)
	return node


# ── Expansion ─────────────────────────────────────────────────────────────────

func _expand(node: MCTSNode) -> MCTSNode:
	var action: GameAction = node.untried_actions.pop_back() as GameAction
	var new_snap: Dictionary = _evaluator.project_corp_action(
		node.state_snapshot, action, null)
	# At depth > 1, offer a small fixed candidate set (card records unavailable).
	var candidates: Array = _get_deep_candidates(new_snap)
	var child := MCTSNode.new(new_snap, action, node, candidates)
	node.children.append(child)
	return child


# ── Rollout ───────────────────────────────────────────────────────────────────

func _rollout(node: MCTSNode, det_ctx: GameContext) -> float:
	if node.is_terminal():
		return _evaluator.evaluate(node.state_snapshot)
	# Roll out from the determinization root — see class comment for rationale.
	var result: GameContext = await GameSimulator.advance(
		det_ctx, _ability_registry, ROLLOUT_DEPTH)
	return _evaluator.evaluate(_evaluator.snapshot(result))


# ── Backpropagation ───────────────────────────────────────────────────────────

func _backpropagate(node: MCTSNode, value: float) -> void:
	var current: MCTSNode = node
	while current != null:
		current.visits      += 1
		current.total_value += value
		current              = current.parent


# ── Action selection ──────────────────────────────────────────────────────────

func _pick_best_action(ctx: GameContext) -> GameAction:
	if _action_scores.is_empty():
		return SimCorpAI.new(_ability_registry).choose_action(ctx)

	var best_action: GameAction = null
	var best_avg:    float      = -INF

	for key in _action_scores:
		var entry:  Dictionary = _action_scores[key] as Dictionary
		var visits: int        = entry.get("visits", 0) as int
		if visits == 0:
			continue
		var avg: float = (entry.get("total", 0.0) as float) / float(visits)
		if avg > best_avg:
			best_avg    = avg
			best_action = entry.get("action", null) as GameAction

	return best_action if best_action != null else GameAction.gain_credits()


# ── Candidate action generators ───────────────────────────────────────────────

# Full candidate set at the root, built from the real live GameContext where
# card records and server state are available.
func _get_root_candidates(ctx: GameContext) -> Array:
	var actions: Array = []

	# Score or advance agendas first.
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s == null or not s.is_remote():
			continue
		var agenda: InstalledCard = s.get_agenda_or_asset()
		if agenda == null or agenda.card_record == null or not agenda.card_record.is_agenda():
			continue
		# Advance (auto-scores when requirement met).
		if ctx.corp_credits >= 1:
			actions.append(GameAction.advance(agenda.card_id))

	# Play affordable operations.
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card == null:
			continue
		if card.card_type == "operation" and ctx.corp_credits >= max(0, card.cost):
			actions.append(GameAction.play_operation(card))

	# Install ice onto unprotected centrals.
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card == null or not card.is_ice():
			continue
		for srv_id in ["hq", "rd"]:
			if ctx.get_server(srv_id).ice_count() == 0:
				actions.append(GameAction.install(card, srv_id))
				break
		break  # one ice install candidate is enough

	# Install agenda into an existing empty remote (avoids creating a new server).
	var empty_remote: Server = _find_empty_remote(ctx)
	if empty_remote != null:
		for entry in ctx.corp_hand:
			var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
			if card != null and card.is_agenda():
				actions.append(GameAction.install(card, empty_remote.server_id))
				break

	actions.append(GameAction.gain_credits())

	if not ctx.corp_deck.is_empty():
		actions.append(GameAction.draw_card())

	actions.append(GameAction.end_turn())
	return actions


# Minimal candidates for depth > 1 nodes where card records are unavailable.
func _get_deep_candidates(s: Dictionary) -> Array:
	var actions: Array = [GameAction.gain_credits(), GameAction.end_turn()]
	if (s.get("corp_deck", 0) as int) > 0:
		actions.append(GameAction.draw_card())
	# Advance if any remote has an agenda and Corp can afford it.
	if (s.get("corp_credits", 0) as int) >= 1:
		for remote in s.get("remotes", []) as Array:
			var r: Dictionary = remote as Dictionary
			if r.get("has_agenda", false):
				# We don't have a real card_id here; use a placeholder that the
				# evaluator handles via project_corp_action's "advance" branch.
				# This node will not be returned as the final action (only root
				# children are used for aggregation).
				actions.append(GameAction.advance("__sim_agenda__"))
				break
	return actions


# ── Helpers ───────────────────────────────────────────────────────────────────

func _find_empty_remote(ctx: GameContext) -> Server:
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s != null and s.is_remote() and s.root.is_empty() and s.ice.is_empty():
			return s
	return null


# Stable string key for a GameAction, used to aggregate scores across determinizations.
func _action_key(action: GameAction) -> String:
	if action == null:
		return "null"
	var key: String = action.type
	var card: CardRecord = action.params.get("card_record", null) as CardRecord
	if card != null:
		key += "|" + card.id
	var server: String = action.params.get("server_id", "") as String
	if server != "":
		key += "|" + server
	var card_id: String = action.params.get("card_id", "") as String
	if card_id != "" and card == null:
		key += "|" + card_id
	return key
