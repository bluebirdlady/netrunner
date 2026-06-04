class_name CorpTurnAI_MCTS
extends CorpTurnAI_Strategic

# ── CorpTurnAI_MCTS ───────────────────────────────────────────────────────────
# Expert difficulty AI — 4th tier.  Uses MCTSTurnTree: a turn-granularity MCTS
# where each node is a game state at the start of a Corp turn and each edge is a
# (Corp full-turn sequence, runner response) pair.
#
# CorpTurnPlanner handles intra-turn optimisation; MCTSTurnTree handles
# inter-turn strategy across rollout_depth full turn pairs.
#
# The legacy click-level MCTSTree (Scripts/AI/MCTSTree.gd) is retained as
# reference but is no longer called from this tier.

const SLOW_MS := 200   # log a warning if search takes longer than this (ms)

# Runner card pool — still populated for seed_runner_model compatibility.
var _card_pool: Array = []

var _turn_tree: MCTSTurnTree


func _init(ability_registry: AbilityRegistry) -> void:
	super._init(ability_registry)
	# _planner and _evaluator are inherited from CorpTurnAI_Tactical/_Strategic.
	_turn_tree = MCTSTurnTree.new(_evaluator, _planner, _bayes)
	_turn_tree.iterations          = 100   # halved from 200; ~1s per action vs ~2-3s
	_turn_tree.expansion_sequences = 5
	_turn_tree.rollout_depth       = 3    # reduced from 4; saves ~25% per rollout
	_turn_tree.rollout_beam_width  = 2


# ── Card pool wiring ──────────────────────────────────────────────────────────

# Called by Main.gd with the full format pool so DeterminizationSampler can
# sample plausible runner hands.  Converts card IDs → CardRecord objects.
func set_card_pool(pool_entries: Array) -> void:
	_card_pool.clear()
	for entry in pool_entries:
		var record: CardRecord
		if entry is CardRecord:
			record = entry as CardRecord
		elif entry is String:
			record = CardRegistry.get_card(entry as String)
		else:
			continue
		if record != null and record.side == "runner" and record.card_type != "identity":
			_card_pool.append(record)


# Override seed_runner_model to also populate the card pool from the same IDs.
func seed_runner_model(identity_id: String, pool_card_ids: Array) -> void:
	super.seed_runner_model(identity_id, pool_card_ids)
	set_card_pool(pool_card_ids)


# ── Main decision loop ────────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
	# Hard override 1: kill window — lethal combos bypass the MCTS search.
	var kill_action: GameAction = KillWindowPlanner.first_action(ctx)
	if kill_action != null:
		if not ctx.simulation_mode:
			ctx.send_log("[MCTS] Kill line detected — executing: %s" % kill_action.describe())
		return kill_action

	# Hard override 2: scoring line — bypass search when the answer is clear.
	var scoring_action: GameAction = FastAdvancePlanner.first_action(ctx)
	if scoring_action != null:
		if not ctx.simulation_mode:
			ctx.send_log("[MCTS] Scoring line detected — executing: %s" % scoring_action.describe())
		return scoring_action

	var t_start: int = Time.get_ticks_msec()

	var action: GameAction = _turn_tree.search(ctx)

	var elapsed: int = Time.get_ticks_msec() - t_start
	if elapsed >= SLOW_MS and not ctx.simulation_mode:
		ctx.send_log("[MCTS] slow search: %d ms (%d iterations, depth %d)" % [
			elapsed, _turn_tree.iterations, _turn_tree.rollout_depth])

	if action != null:
		if not ctx.simulation_mode:
			DecisionLogger.log_mcts(ctx, action, elapsed)
		return action

	# Fallback: no action returned (should not occur — MCTSTurnTree always returns
	# at least gain_credits as a last resort).
	ctx.send_log("[MCTS] no action found — falling back to Strategic beam search")
	return super.choose_action(ctx)
