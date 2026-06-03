class_name MCTSTree
extends RefCounted

# ── MCTSTree ──────────────────────────────────────────────────────────────────
# UCB1-guided Monte Carlo Tree Search over determinized game states.
#
# Algorithm per determinization:
#   1. Selection   — walk tree with UCB1 until a non-fully-expanded node.
#   2. Expansion   — pick one untried action, project state via CorpStateEvaluator.
#   3. Evaluation  — score the expanded node's state snapshot directly.
#   4. Backprop    — update visit counts and total values up to root.
#
# After all iterations across all determinizations, aggregate root-child scores
# by action key and return the action with the highest average value.
#
# Value-network approach: each node is scored by evaluating its projected
# state snapshot directly rather than running a forward simulation.  This
# ensures the value signal reflects the consequence of the candidate action
# (not the root state), makes the loop fully synchronous, and allows far
# more iterations within the same time budget.

# ── Parameters ────────────────────────────────────────────────────────────────

const DETERMINIZATIONS:   int   = 10
const ITERATIONS_PER_DET: int   = 200
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
		_run_mcts_on_determinization(det, ctx)

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

		var value: float = _rollout(node)
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


# ── Evaluation ────────────────────────────────────────────────────────────────

func _rollout(node: MCTSNode) -> float:
	return _evaluator.evaluate(node.state_snapshot)


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
	var identity_id: String = ctx.corp_identity.id if ctx.corp_identity != null else ""

	# Score or advance agendas.
	# Weyland: Built to Last gets +2cr on the first advance of each card, so
	# advancing a fresh agenda (0 counters) costs nothing net — always offer it.
	var is_built_to_last: bool = (identity_id == "weyland_consortium_built_to_last")
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s == null or not s.is_remote():
			continue
		var agenda: InstalledCard = s.get_agenda_or_asset()
		if agenda == null or agenda.card_record == null or not agenda.card_record.is_agenda():
			continue
		# Advance: free for Weyland first-advance; costs 1cr otherwise.
		var is_first_advance: bool = (agenda.get_counter("advancement") == 0)
		var can_afford: bool = ctx.corp_credits >= 1 or (is_built_to_last and is_first_advance)
		if can_afford:
			actions.append(GameAction.advance(agenda.card_id))

	# Play affordable operations.
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card == null:
			continue
		if card.card_type == "operation" and ctx.corp_credits >= max(0, card.cost):
			actions.append(GameAction.play_operation(card))

	# Install ice: up to 2 distinct ice types per server, with a higher cap when
	# the runner already ran through a server this turn.
	var ice_options: Array = _unique_ice_from_hand(ctx, 2)
	if not ice_options.is_empty():
		var hq_srv: Server = ctx.get_server("hq")
		var rd_srv: Server = ctx.get_server("rd")
		var hq_ice: int = hq_srv.ice_count() if hq_srv != null else 0
		var rd_ice: int = rd_srv.ice_count() if rd_srv != null else 0
		var hq_cap: int = 3 if ctx.runner_hq_successful_run_this_turn       else 2
		var rd_cap: int = 3 if ctx.runner_successful_run_on_rd_this_turn else 2
		for ice_opt in ice_options:
			var ic: CardRecord = ice_opt as CardRecord
			if hq_ice < hq_cap and ctx.corp_credits >= hq_ice:
				actions.append(GameAction.install(ic, "hq", "ice"))
			if rd_ice < rd_cap and ctx.corp_credits >= rd_ice:
				actions.append(GameAction.install(ic, "rd", "ice"))
		# Protect unprotected agenda remotes — one candidate using the first ice option.
		var first_ice: CardRecord = ice_options[0] as CardRecord
		for key in ctx.servers:
			var s: Server = ctx.servers[key] as Server
			if s == null or not s.is_remote() or s.ice_count() > 0:
				continue
			var agenda_ic: InstalledCard = s.get_agenda_or_asset()
			if agenda_ic != null and agenda_ic.card_record != null and agenda_ic.card_record.is_agenda():
				actions.append(GameAction.install(first_ice, s.server_id, "ice"))
				break
		# Pre-ice an empty existing remote to enable the "ice first → install agenda"
		# planning sequence.  Without this, the MCTS has no way to prepare a safe
		# scoring slot when all existing remotes are empty and naked.
		for key in ctx.servers:
			var s: Server = ctx.servers[key] as Server
			if s == null or not s.is_remote() or s.has_ice() or not s.root.is_empty():
				continue
			actions.append(GameAction.install(first_ice, s.server_id, "ice"))
			break

	# Install agenda: prefer an already-iced empty remote (safe), then a totally
	# empty remote, then create a new one with ice backup in hand.
	var agenda_to_install: CardRecord = null
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card != null and card.is_agenda():
			agenda_to_install = card
			break
	if agenda_to_install != null:
		var iced_slot: Server = _find_iced_empty_remote(ctx)
		if iced_slot != null:
			# Best case: slot already protected — just add the agenda.
			actions.append(GameAction.install(agenda_to_install, iced_slot.server_id))
		else:
			var empty_remote: Server = _find_empty_remote(ctx)
			if empty_remote != null:
				actions.append(GameAction.install(agenda_to_install, empty_remote.server_id))
			else:
				# No existing remote — offer creating a new one.
				# The evaluator projects an ice layer if ice is in hand, so MCTS will
				# score this correctly even though the server doesn't exist yet.
				actions.append(GameAction.install(agenda_to_install, "new_remote"))

	# Advance advanceable non-agenda (trap) cards when runner grip is in threat range.
	if ctx.runner_hand.size() <= 5 and ctx.corp_credits >= 1:
		var trap_found := false
		for key in ctx.servers:
			if trap_found:
				break
			var s: Server = ctx.servers[key] as Server
			if s == null or not s.is_remote() or not s.has_ice():
				continue
			for card in s.root:
				var c: InstalledCard = card as InstalledCard
				if c.card_record != null and not c.card_record.is_agenda() and c.can_be_advanced():
					actions.append(GameAction.advance(c.card_id))
					trap_found = true
					break

	# Install upgrade in best server (evaluator values installed upgrades at +1.5 each).
	var upgrade_card: CardRecord = null
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card != null and card.card_type == "upgrade":
			upgrade_card = card
			break
	if upgrade_card != null:
		var up_srv: Server = _find_best_upgrade_server(ctx)
		if up_srv != null:
			actions.append(GameAction.install(upgrade_card, up_srv.server_id))

	actions.append(GameAction.gain_credits())

	# Only draw when there is comfortable room in hand (identity-aware limit).
	# HB has a limit of 6, all others 5.  Leave 1 slot as a buffer.
	if not ctx.corp_deck.is_empty() and ctx.corp_hand.size() < ctx.corp_max_hand_size() - 1:
		actions.append(GameAction.draw_card())

	return actions


# Snapshot-inferred candidates for depth > 1 nodes (no live card records).
# Symbolic ice installs use a null card_record with zone = "ice"; the evaluator
# handles them as credit/count approximations without subtype detail.
# end_turn is intentionally excluded — it ends the Corp's turn and is useless
# as an intra-turn planning step.
func _get_deep_candidates(s: Dictionary) -> Array:
	var actions: Array = [GameAction.gain_credits()]
	var corp_cr:   int = s.get("corp_credits", 0) as int
	var corp_hand: int = s.get("corp_hand",    0) as int

	if (s.get("corp_deck", 0) as int) > 0:
		actions.append(GameAction.draw_card())

	# Advance if any remote has an agenda and Corp can afford it.
	if corp_cr >= 1:
		for remote in s.get("remotes", []) as Array:
			var r: Dictionary = remote as Dictionary
			if r.get("has_agenda", false):
				actions.append(GameAction.advance("__sim_agenda__"))
				break

	# Symbolic ice installs — these are the critical candidates that enable
	# multi-click planning sequences like "ice a new remote, then install agenda."
	if corp_hand > 0:
		var hq_ice: int = s.get("hq_ice", 0) as int
		var rd_ice: int = s.get("rd_ice", 0) as int
		if hq_ice < 3 and corp_cr >= hq_ice:
			actions.append(GameAction.install(null, "hq", "ice"))
		if rd_ice < 3 and corp_cr >= rd_ice:
			actions.append(GameAction.install(null, "rd", "ice"))
		# Ice the most vulnerable remote: an unprotected agenda server or a
		# "projected" new remote (created by a root-level agenda install this turn).
		for remote in s.get("remotes", []) as Array:
			var r: Dictionary = remote as Dictionary
			var srv: String  = r.get("server_id", "") as String
			var has_ag: bool = r.get("has_agenda", false) as bool
			var ice_ct: int  = r.get("ice_count",  0) as int
			if (has_ag or srv == "projected") and ice_ct == 0:
				actions.append(GameAction.install(null, srv, "ice"))
				break

		# Symbolic agenda install into an iced empty remote.
		# Enables the key planning sequence: "ice remote → install agenda → advance."
		# null card_record + zone="root" is handled by project_corp_action.
		for remote in s.get("remotes", []) as Array:
			var r: Dictionary = remote as Dictionary
			if not r.get("has_agenda", false) and (r.get("ice_count", 0) as int) > 0:
				actions.append(GameAction.install(null, r.get("server_id", "") as String, "root"))
				break

	return actions


# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns up to max_count distinct ice cards from the Corp hand, deduplicated
# by primary ice subtype so candidates don't explode when holding many of the
# same type.
func _unique_ice_from_hand(ctx: GameContext, max_count: int) -> Array:
	var seen: Array   = []
	var result: Array = []
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card == null or not card.is_ice():
			continue
		var sub: String = _primary_ice_subtype(card)
		if sub in seen:
			continue
		seen.append(sub)
		result.append(card)
		if result.size() >= max_count:
			break
	return result


func _primary_ice_subtype(card: CardRecord) -> String:
	for sub in ["barrier", "sentry", "code_gate"]:
		if card.has_subtype(sub):
			return sub
	return "other"


# Returns the server that would benefit most from an upgrade install.
# Only considers remote servers — installing upgrades in centrals (HQ/RD)
# causes misplaced cards like Malapert Data Vault landing in HQ.
# Mirrors CorpTurnAI._find_best_upgrade_server().
func _find_best_upgrade_server(ctx: GameContext) -> Server:
	# 1. Iced remote with agenda — directly protects the scoring server.
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s == null or not s.is_remote() or not s.has_ice():
			continue
		var ic: InstalledCard = s.get_agenda_or_asset()
		if ic != null and ic.card_record != null and ic.card_record.is_agenda():
			return s
	# 2. Any remote with an agenda (even uniced — still better than a central).
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s == null or not s.is_remote():
			continue
		var ic: InstalledCard = s.get_agenda_or_asset()
		if ic != null and ic.card_record != null and ic.card_record.is_agenda():
			return s
	return null


func _find_empty_remote(ctx: GameContext) -> Server:
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s != null and s.is_remote() and s.root.is_empty() and s.ice.is_empty():
			return s
	return null


# A remote that has at least one piece of ice but nothing in its root —
# an ideal slot for an agenda install on the next click.
func _find_iced_empty_remote(ctx: GameContext) -> Server:
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s != null and s.is_remote() and s.root.is_empty() and s.has_ice():
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
