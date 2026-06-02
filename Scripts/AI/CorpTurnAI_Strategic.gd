class_name CorpTurnAI_Strategic
extends CorpTurnAI_Tactical

# ── CorpTurnAI_Strategic ──────────────────────────────────────────────────────
# Hard difficulty AI.  Extends CorpTurnAI_Tactical with:
#   • BayesianRunnerModel — probabilistic deck-aware runner hand modeling
#   • 2-ply beam search:
#       Ply 1 — Corp action (all candidates from _generate_candidates)
#       Ply 2 — Runner response (top BEAM_RUNNER_RESPONSES, prob-weighted)
#       Ply 3 — Corp counter (1-ply search + kill-window detection)
#   • Runner model seeded from the known campaign runner deck composition
#   • Observation hook called by Main.gd whenever the runner acts

const BEAM_RUNNER_RESPONSES := 5   # runner response branches per Corp action

# BayesianRunnerModel replaces the parent's plain RunnerThreatModel.
var _bayes: BayesianRunnerModel


func _init(ability_registry: AbilityRegistry) -> void:
	super._init(ability_registry)
	_bayes = BayesianRunnerModel.new()
	# Override the parent's observable-only threat model with Bayesian version
	_threat_model = _bayes


# ── Runner model wiring ───────────────────────────────────────────────────────

# Seed the Bayesian prior from public information only:
# the runner's identity and the format's full card pool.
# Called by Main.gd before game_loop starts.
func seed_runner_model(identity_id: String, pool_card_ids: Array) -> void:
	_bayes.seed_from_identity_and_pool(identity_id, pool_card_ids)


# Update the posterior whenever the runner installs or plays a card.
# Called by Main.gd via the action_requested signal.
func observe_runner_action(action_type: String, params: Dictionary) -> void:
	_bayes.observe(action_type, params)


# ── 2-ply beam search ─────────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
	var candidates: Array = _generate_candidates(ctx)
	if candidates.is_empty():
		return super.choose_action(ctx)

	var snap: Dictionary = _evaluator.snapshot(ctx)

	var best_action: GameAction = null
	var best_ev:     float      = -INF
	var log_entries: Array      = []

	for action in candidates:
		var ev: float = _expected_value(action as GameAction, snap, ctx)
		if not ctx.simulation_mode:
			log_entries.append({"action": action as GameAction, "score": ev})
		if ev > best_ev:
			best_ev     = ev
			best_action = action as GameAction

	if best_action != null:
		if not ctx.simulation_mode:
			DecisionLogger.log_scored(ctx, best_action, log_entries, 2)
		return best_action

	return super.choose_action(ctx)


# ── Expected value (2-ply lookahead) ─────────────────────────────────────────

func _expected_value(action: GameAction, snap: Dictionary, ctx: GameContext) -> float:
	# Ply 1 — project state after Corp plays this action
	var post_corp: Dictionary = _evaluator.project_corp_action(snap, action, ctx)

	# Get top-k runner responses with probability weights
	var responses: Array = _bayes.k_likely_runner_responses(BEAM_RUNNER_RESPONSES, ctx)

	if responses.is_empty():
		# Bayesian model not seeded — fall back to 1-ply (parent behaviour)
		var fallback_server: String = _threat_model.most_threatened_server(ctx)
		var post_runner: Dictionary = _evaluator.project_runner_response(
			post_corp, fallback_server, ctx)
		return _evaluator.evaluate(post_runner)

	var weighted_ev := 0.0

	for response in responses:
		var r:         Dictionary = response as Dictionary
		var prob:      float      = float(r.get("probability", 0.0))
		var server_id: String     = r.get("server_id",   "hq") as String
		var resp_type: String     = r.get("type",         "run") as String

		# Ply 2 — project state after runner acts
		var post_runner: Dictionary
		if resp_type == "run":
			post_runner = _evaluator.project_runner_response(post_corp, server_id, ctx)
		else:
			# Runner installs — rig grows but no immediate score change
			post_runner = post_corp.duplicate(true)
			post_runner["runner_rig"] = (post_corp.get("runner_rig", 0) as int) + 1

		# Ply 3 — evaluate post-runner state with forward-looking position bonus
		var counter_ev: float = _best_corp_counter_ev(post_runner, ctx)
		weighted_ev += prob * counter_ev

	return weighted_ev


func _best_corp_counter_ev(state: Dictionary, _ctx: GameContext) -> float:
	var base_ev: float = _evaluator.evaluate(state)

	# Kill-window detection: runner at ≤2 cards with damage ops available.
	# evaluate() already handles runner_hand <= 1; this catches the one-click-
	# from-kill case that static evaluation alone misses.
	var runner_grip: int = state.get("runner_hand",               5) as int
	var corp_dmg:    int = state.get("corp_net_damage_potential",  0) as int
	if runner_grip <= 2 and corp_dmg >= 1:
		base_ev += 150.0

	# 1-ply search: project each snapshot-inferred candidate and take the best.
	# project_corp_action handles symbolic null-card ice installs from Stage 4.
	for action in _snapshot_candidates(state):
		var projected: Dictionary = _evaluator.project_corp_action(state, action, null)
		var ev: float = _evaluator.evaluate(projected)
		if ev > base_ev:
			base_ev = ev

	return base_ev


# Snapshot-based candidate list for ply-3 evaluation.
# Mirrors MCTSTree._get_deep_candidates() so ply-3 and tree search
# consider the same action space.
func _snapshot_candidates(s: Dictionary) -> Array:
	var corp_cr:   int = s.get("corp_credits", 0) as int
	var corp_hand: int = s.get("corp_hand",    0) as int
	var actions: Array = [GameAction.gain_credits()]

	if (s.get("corp_deck", 0) as int) > 0:
		actions.append(GameAction.draw_card())

	# Advance if any remote has an agenda and Corp can afford it.
	if corp_cr >= 1:
		for remote in s.get("remotes", []) as Array:
			var r: Dictionary = remote as Dictionary
			if r.get("has_agenda", false):
				actions.append(GameAction.advance("__sim_agenda__"))
				break

	# Symbolic ice installs (null card_record, zone = "ice").
	if corp_hand > 0:
		var hq_ice: int = s.get("hq_ice", 0) as int
		var rd_ice: int = s.get("rd_ice", 0) as int
		if hq_ice < 3 and corp_cr >= hq_ice:
			actions.append(GameAction.install(null, "hq", "ice"))
		if rd_ice < 3 and corp_cr >= rd_ice:
			actions.append(GameAction.install(null, "rd", "ice"))
		# Ice the most vulnerable remote.
		for remote in s.get("remotes", []) as Array:
			var r: Dictionary = remote as Dictionary
			var srv:   String = r.get("server_id", "") as String
			var has_ag: bool  = r.get("has_agenda", false) as bool
			var ice_ct: int   = r.get("ice_count",  0) as int
			if (has_ag or srv == "projected") and ice_ct == 0:
				actions.append(GameAction.install(null, srv, "ice"))
				break

	return actions
