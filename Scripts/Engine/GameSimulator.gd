class_name GameSimulator
extends RefCounted

# ── GameSimulator ─────────────────────────────────────────────────────────────
# Headless forward model: clone a GameContext, inject sim AIs, run N turns.
# The coroutine chain resolves in-frame — no signals, no frame yields —
# so the caller receives control back the same frame it awaits.
#
# Usage:
#   var final_ctx: GameContext = await GameSimulator.advance(ctx, ability_registry, 10)

static func advance(
		ctx:              GameContext,
		ability_registry: AbilityRegistry,
		turns:            int = 10) -> GameContext:

	var sim := ctx.clone_for_sim()
	# Clear ability listeners so rollout sims don't fire triggers that reference
	# cards by runtime_instance_id in ways the rolled-out state can't satisfy
	# (e.g. Botulus counter ticks, unimplemented effect types). Rollouts are
	# rough approximations — CorpStateEvaluator doesn't use per-card counter state.
	sim._event_listeners.clear()
	sim._state_modifiers.clear()
	sim.corp_decision_maker   = SimCorpAI.new(ability_registry)
	sim.runner_decision_maker = SimRunnerAI.new()

	var tm := TurnManager.new(sim, ability_registry)
	await tm.run_game(turns)

	return sim
