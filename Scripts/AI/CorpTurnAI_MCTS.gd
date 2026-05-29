class_name CorpTurnAI_MCTS
extends CorpTurnAI_Strategic

# ── CorpTurnAI_MCTS ───────────────────────────────────────────────────────────
# Expert difficulty AI — 4th tier.  Wraps MCTSTree over DeterminizationSampler
# to plan several turns ahead under hidden-information uncertainty.
#
# Inherits the Bayesian runner model from CorpTurnAI_Strategic so determinizations
# are seeded from observed runner behaviour rather than a uniform prior.
#
# Time-budget guard: if MCTS exceeds BUDGET_MS, the best action found so far
# (or the Strategic 2-ply fallback) is returned immediately.

const BUDGET_MS := 2000   # wall-clock limit per choose_action call

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
	var t_start: int = Time.get_ticks_msec()

	# Run MCTS. The coroutine chain resolves in-frame in simulation mode;
	# wall-clock time scales with DETERMINIZATIONS × ITERATIONS_PER_DET × ROLLOUT_DEPTH.
	var action: GameAction = await _mcts.choose_action(ctx, _card_pool, _bayes)

	var elapsed: int = Time.get_ticks_msec() - t_start

	# If MCTS returned a result within budget, use it.
	if action != null and elapsed < BUDGET_MS:
		return action

	# Time-budget exceeded or no result: fall back to Strategic 2-ply.
	ctx.send_log("[MCTS] budget exceeded (%d ms) — falling back to Strategic AI" % elapsed)
	return super.choose_action(ctx)
