class_name CorpTurnAI_MCTS
extends CorpTurnAI_Strategic

# ── CorpTurnAI_MCTS ───────────────────────────────────────────────────────────
# Expert difficulty AI — 4th tier.  Wraps MCTSTree over DeterminizationSampler
# to plan several turns ahead under hidden-information uncertainty.
#
# Inherits the Bayesian runner model from CorpTurnAI_Strategic so determinizations
# are seeded from observed runner behaviour rather than a uniform prior.
#
# The MCTS loop is fully synchronous — each node is scored by static evaluation
# rather than forward simulation, so the entire search completes in single-digit
# milliseconds.  SLOW_MS is a sanity-log threshold, not a hard cutoff.

const SLOW_MS := 100   # log a warning if the synchronous loop takes longer than this

# Runner card pool for DeterminizationSampler (CardRecord objects).
# Populated from card IDs via set_card_pool() called by Main.gd.
var _card_pool: Array = []

var _mcts: MCTSTree


func _init(ability_registry: AbilityRegistry) -> void:
	super._init(ability_registry)
	_mcts = MCTSTree.new(ability_registry)


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

	var action: GameAction = _mcts.choose_action(ctx, _card_pool, _bayes)

	var elapsed: int = Time.get_ticks_msec() - t_start
	if elapsed >= SLOW_MS:
		ctx.send_log("[MCTS] slow search warning: %d ms for %d iterations" % [
			elapsed, MCTSTree.DETERMINIZATIONS * MCTSTree.ITERATIONS_PER_DET])

	if action != null:
		if not ctx.simulation_mode:
			DecisionLogger.log_mcts(ctx, action, elapsed)
		return action

	# No result (empty candidate set): fall back to Strategic 2-ply.
	ctx.send_log("[MCTS] no action found — falling back to Strategic AI")
	return super.choose_action(ctx)
