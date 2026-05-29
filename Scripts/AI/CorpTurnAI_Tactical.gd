class_name CorpTurnAI_Tactical
extends CorpTurnAI

# ── CorpTurnAI_Tactical ───────────────────────────────────────────────────────
# Medium difficulty AI.  Extends heuristic CorpTurnAI with:
#   • Candidate action generation (no new-server side effects during planning)
#   • 1-ply lookahead: project Corp action → project runner response → evaluate
#   • RunnerThreatModel for threat-aware server prioritisation
#
# Falls back to CorpTurnAI.choose_action() for cases that require live server
# creation (new-remote installs, asset installs) so those paths stay correct.

var _evaluator:    CorpStateEvaluator
var _threat_model: RunnerThreatModel


func _init(ability_registry: AbilityRegistry) -> void:
	super._init(ability_registry)
	_evaluator    = CorpStateEvaluator.new()
	_threat_model = RunnerThreatModel.new()


# ── Main override ─────────────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
	var candidates: Array = _generate_candidates(ctx)
	if candidates.is_empty():
		return super.choose_action(ctx)

	var snap:          Dictionary = _evaluator.snapshot(ctx)
	var threat_server: String     = _threat_model.most_threatened_server(ctx)

	var best_action: GameAction = null
	var best_score:  float      = -INF

	for action in candidates:
		var s: float = _score_candidate(action as GameAction, snap, threat_server, ctx)
		if s > best_score:
			best_score  = s
			best_action = action as GameAction

	if best_action != null:
		return best_action

	# No candidate beat the baseline — let the heuristic parent decide
	# (handles new-remote install, asset install, etc.)
	return super.choose_action(ctx)


# ── Candidate generation ──────────────────────────────────────────────────────
# Only generates actions that do NOT require creating live server objects.
# New-remote installs are handled by the parent fallback.

func _generate_candidates(ctx: GameContext) -> Array:
	var candidates: Array = []

	# ── Score a ready agenda ──────────────────────────────────────────────────
	var ready: InstalledCard = _find_ready_agenda(ctx)
	if ready != null:
		candidates.append(GameAction.advance(ready.card_id))

	# ── Advance almost-scored agenda ──────────────────────────────────────────
	var almost: InstalledCard = _find_almost_scored_agenda(ctx)
	if almost != null and ctx.corp_credits >= 1:
		candidates.append(GameAction.advance(almost.card_id))

	# ── Play operations from hand ─────────────────────────────────────────────
	# All affordable operations become candidates; the evaluator picks the best.
	for op in _find_playable_operations(ctx):
		candidates.append(GameAction.play_operation(op as CardRecord))

	# ── Install agenda ────────────────────────────────────────────────────────
	var agenda: CardRecord = _find_agenda_in_hand(ctx)
	if agenda != null and ctx.corp_credits >= max(0, agenda.cost):
		var protected: Server = _find_protected_empty_remote(ctx)
		if protected != null:
			# Install into an already-iced remote — best case.
			candidates.append(GameAction.install(agenda, protected.server_id))
		else:
			# No ready remote: install into a new one if we have ICE to follow up.
			# Use the "new_remote" sentinel; TurnManager creates the server on execute.
			var backup_ice: CardRecord = _find_ice_in_hand(ctx)
			if backup_ice != null and ctx.corp_credits >= max(0, agenda.cost) + 1:
				candidates.append(GameAction.install(agenda, "new_remote"))

	# ── Install asset in new remote ───────────────────────────────────────────
	var asset: CardRecord = _find_asset_in_hand(ctx)
	if asset != null and ctx.corp_credits >= max(0, asset.cost):
		candidates.append(GameAction.install(asset, "new_remote"))

	# ── Ice on centrals (first layer AND reinforcement up to 2 layers) ────────
	var ice: CardRecord = _find_ice_in_hand(ctx)
	if ice != null:
		var hq_srv: Server = ctx.get_server("hq")
		var rd_srv: Server = ctx.get_server("rd")
		var hq_ice: int    = hq_srv.ice.size() if hq_srv != null else 0
		var rd_ice: int    = rd_srv.ice.size() if rd_srv != null else 0
		# Install on HQ if it has fewer than 2 layers and we can afford it
		if hq_ice < 2 and ctx.corp_credits >= hq_ice:  # install cost = existing ice count
			candidates.append(GameAction.install(ice, "hq", "ice"))
		# Install on R&D if it has fewer than 2 layers and we can afford it
		if rd_ice < 2 and ctx.corp_credits >= rd_ice:
			candidates.append(GameAction.install(ice, "rd", "ice"))
		# Ice on vulnerable agenda remote
		var vuln: Server = _find_agenda_remote_needing_ice(ctx)
		if vuln != null:
			candidates.append(GameAction.install(ice, vuln.server_id, "ice"))
		# Ice on unprotected non-empty remote
		var unprotected: Server = _find_remote_needing_ice(ctx)
		if unprotected != null:
			candidates.append(GameAction.install(ice, unprotected.server_id, "ice"))

	# ── Installed card click actions ──────────────────────────────────────────
	var click_card: InstalledCard = _find_corp_click_action(ctx)
	if click_card != null:
		candidates.append(GameAction.use_installed_card(
			click_card.runtime_instance_id, click_card.card_id))

	# ── Advance any protected agenda ──────────────────────────────────────────
	var any_agenda: InstalledCard = _find_any_installed_agenda(ctx)
	if any_agenda != null and ctx.corp_credits >= 1:
		candidates.append(GameAction.advance(any_agenda.card_id))

	# ── Economy ───────────────────────────────────────────────────────────────
	candidates.append(GameAction.gain_credits())

	# ── Draw ──────────────────────────────────────────────────────────────────
	if ctx.corp_hand.size() < 4 and not ctx.corp_deck.is_empty():
		candidates.append(GameAction.draw_card())

	return candidates


# ── 1-ply lookahead scoring ───────────────────────────────────────────────────

func _score_candidate(
		action:        GameAction,
		snap:          Dictionary,
		threat_server: String,
		ctx:           GameContext) -> float:

	# Project state after Corp plays this action
	var post_corp:   Dictionary = _evaluator.project_corp_action(snap, action, ctx)
	# Project runner's most likely response on the most threatened server
	var post_runner: Dictionary = _evaluator.project_runner_response(post_corp, threat_server, ctx)
	return _evaluator.evaluate(post_runner)
