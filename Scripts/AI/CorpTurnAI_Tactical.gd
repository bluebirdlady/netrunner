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
var _planner:      CorpTurnPlanner


func _init(ability_registry: AbilityRegistry) -> void:
	super._init(ability_registry)
	_evaluator    = CorpStateEvaluator.new()
	_threat_model = RunnerThreatModel.new()
	_planner      = CorpTurnPlanner.new(_evaluator)
	_planner.beam_width = 5


# ── Main override ─────────────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
	# Hard override 1: kill window — lethal damage takes absolute priority.
	var kill_action: GameAction = KillWindowPlanner.first_action(ctx)
	if kill_action != null:
		if not ctx.simulation_mode:
			ctx.send_log("[Tactical] Kill line detected — executing: %s" % kill_action.describe())
		return kill_action

	# Hard override 2: scoring line — finish advancing an agenda this turn.
	var scoring_action: GameAction = FastAdvancePlanner.first_action(ctx)
	if scoring_action != null:
		if not ctx.simulation_mode:
			ctx.send_log("[Tactical] Scoring line detected — executing: %s" % scoring_action.describe())
		return scoring_action

	# Whole-turn beam search (beam_width=5).
	var snap:   Dictionary = _evaluator.snapshot(ctx)
	var threat: String     = _threat_model.most_threatened_server(ctx)
	var action: GameAction = _planner.plan_first_action(snap, threat, ctx)
	if not ctx.simulation_mode:
		DecisionLogger.log_scored(ctx, action, [], 1)
	return action


# ── Candidate generation ──────────────────────────────────────────────────────
# Only generates actions that do NOT require creating live server objects.
# New-remote installs are handled by the parent fallback.

func _generate_candidates(ctx: GameContext) -> Array:
	var candidates: Array = []

	# ── Identity helper ───────────────────────────────────────────────────────
	var is_built_to_last: bool = (
		ctx.corp_identity != null and
		ctx.corp_identity.id == "weyland_consortium_built_to_last"
	)

	# ── Score a ready agenda ──────────────────────────────────────────────────
	var ready: InstalledCard = _find_ready_agenda(ctx)
	if ready != null:
		candidates.append(GameAction.advance(ready.card_id))

	# ── Advance almost-scored agenda ──────────────────────────────────────────
	var almost: InstalledCard = _find_almost_scored_agenda(ctx)
	# Weyland: Built to Last — first advance on a fresh agenda gains 2cr (net free).
	# Always include it as a candidate even at 0 credits if it's the first advance.
	var almost_is_fresh: bool = almost != null and almost.get_counter("advancement") == 0
	if almost != null and (ctx.corp_credits >= 1 or (is_built_to_last and almost_is_fresh)):
		candidates.append(GameAction.advance(almost.card_id))

	# ── Play operations from hand ─────────────────────────────────────────────
	# All affordable operations become candidates; the evaluator picks the best.
	for op in _find_playable_operations(ctx):
		candidates.append(GameAction.play_operation(op as CardRecord))

	# ── Install agenda ────────────────────────────────────────────────────────
	var is_rp: bool = (
		ctx.corp_identity != null and
		ctx.corp_identity.id == "jinteki_replicating_perfection"
	)
	var agenda: CardRecord = _find_agenda_in_hand(ctx)
	if agenda != null and ctx.corp_credits >= max(0, agenda.cost):
		var protected: Server = _find_protected_empty_remote(ctx)
		if protected != null:
			# Install into an already-iced remote — best case.
			candidates.append(GameAction.install(agenda, protected.server_id))
		else:
			# No ready remote: install into a new one only if backup ice is in hand.
			# Jinteki RP: runner must run a central first, so unprotected remotes are safer.
			var backup_ice: CardRecord = _find_ice_in_hand(ctx)
			var can_open_remote: bool = is_rp or (backup_ice != null and ctx.corp_credits >= max(0, agenda.cost) + 1)
			if can_open_remote:
				candidates.append(GameAction.install(agenda, "new_remote"))

	# ── Install upgrade in best available server ─────────────────────────────────
	var upgrade: CardRecord = _find_upgrade_in_hand(ctx)
	if upgrade != null and ctx.corp_credits >= max(0, upgrade.cost):
		var up_srv: Server = _find_best_upgrade_server(ctx)
		if up_srv != null:
			candidates.append(GameAction.install(upgrade, up_srv.server_id))

	# ── Install asset in new remote ───────────────────────────────────────────
	var asset: CardRecord = _find_asset_in_hand(ctx)
	if asset != null and ctx.corp_credits >= max(0, asset.cost):
		candidates.append(GameAction.install(asset, "new_remote"))

	# ── Ice on centrals and remotes ──────────────────────────────────────────────
	# Collect up to 2 distinct ice cards, deduplicated by primary subtype, so the
	# evaluator can compare e.g. a barrier and a sentry for the same server.
	var ice_options: Array = _unique_ice_from_hand(ctx, 2)
	if not ice_options.is_empty():
		var hq_srv: Server = ctx.get_server("hq")
		var rd_srv: Server = ctx.get_server("rd")
		var hq_ice: int = hq_srv.ice.size() if hq_srv != null else 0
		var rd_ice: int = rd_srv.ice.size() if rd_srv != null else 0
		# Raise reinforcement cap to 3 when the runner already broke through this turn.
		var hq_cap: int = 3 if ctx.runner_hq_successful_run_this_turn       else 2
		var rd_cap: int = 3 if ctx.runner_successful_run_on_rd_this_turn else 2
		for ice_opt in ice_options:
			var ic: CardRecord = ice_opt as CardRecord
			if hq_ice < hq_cap and ctx.corp_credits >= hq_ice:
				candidates.append(GameAction.install(ic, "hq", "ice"))
			if rd_ice < rd_cap and ctx.corp_credits >= rd_ice:
				candidates.append(GameAction.install(ic, "rd", "ice"))
		# For remotes the subtype distinction matters less at this ply depth —
		# use the first (highest-priority) ice option.
		var first_ice: CardRecord = ice_options[0] as CardRecord
		var vuln: Server = _find_agenda_remote_needing_ice(ctx)
		if vuln != null:
			candidates.append(GameAction.install(first_ice, vuln.server_id, "ice"))
		var unprotected: Server = _find_remote_needing_ice(ctx)
		if unprotected != null:
			candidates.append(GameAction.install(first_ice, unprotected.server_id, "ice"))
		# Scoring-slot preparation: if there's an agenda in hand but no iced empty
		# remote exists, offer to create one now.  Without this, the naked-install
		# penalty causes indefinite agenda accumulation in HQ — the Corp can never
		# build the protected slot it needs to install safely.
		if agenda != null and _find_protected_empty_remote(ctx) == null:
			candidates.append(GameAction.install(first_ice, "new_remote", "ice"))

	# ── Installed card click actions ──────────────────────────────────────────
	var click_card: InstalledCard = _find_corp_click_action(ctx)
	if click_card != null:
		candidates.append(GameAction.use_installed_card(
			click_card.runtime_instance_id, click_card.card_id))

	# ── Corp identity click action (e.g. Synapse Global: click + tag → 2cr) ──
	var id_action: GameAction = _get_identity_click_action(ctx)
	if id_action != null:
		candidates.append(id_action)

	# ── Advance any protected agenda ──────────────────────────────────────────
	var any_agenda: InstalledCard = _find_any_installed_agenda(ctx)
	if any_agenda != null and ctx.corp_credits >= 1:
		candidates.append(GameAction.advance(any_agenda.card_id))

	# ── Advance advanceable non-agenda (trap) cards ───────────────────────────
	# Let the evaluator weigh building trap threat vs. other options.
	if ctx.corp_credits >= 1 and ctx.runner_hand.size() <= 5:
		var trap: InstalledCard = _find_advanceable_non_agenda(ctx)
		if trap != null:
			candidates.append(GameAction.advance(trap.card_id))

	# ── Economy ───────────────────────────────────────────────────────────────
	candidates.append(GameAction.gain_credits())

	# ── Draw ──────────────────────────────────────────────────────────────────
	# Only draw when there is room in hand.  Uses the identity-aware limit so
	# HB (max 6) draws one click later than other identities (max 5).
	# Leave 1 slot as a buffer so we don't draw into mandatory-discard territory.
	if not ctx.corp_deck.is_empty() and ctx.corp_hand.size() < ctx.corp_max_hand_size() - 1:
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
	var score: float = _evaluator.evaluate(post_runner)

	# ── Naked-agenda install penalty ───────────────────────────────────────────
	# evaluate() is called on post_runner where the agenda has already been stolen,
	# so the evaluator's naked-agenda penalty never fires for Tactical's 1-ply
	# scores.  Apply a direct penalty here before returning so naked installs
	# reliably score worse than gaining a credit.
	if _is_naked_agenda_install(action, snap):
		score -= 40.0

	# ── Scoring-slot preparation bonus ─────────────────────────────────────────
	# Installing ice into a brand-new remote when an agenda is stuck in hand is
	# worth more than the evaluator can see in one ply — it enables next click's
	# safe agenda install.  Boost it enough to beat gaining a credit.
	if _is_scoring_slot_prep(action, ctx):
		score += 20.0

	return score


func _is_scoring_slot_prep(action: GameAction, ctx: GameContext) -> bool:
	# True when the action creates a brand-new iced remote AND the Corp has an
	# agenda in hand that has nowhere safe to go yet.
	if action == null or action.type != "install":
		return false
	if action.params.get("zone", "") != "ice" or action.params.get("server_id", "") != "new_remote":
		return false
	if _find_protected_empty_remote(ctx) != null:
		return false   # a slot already exists — this is just ordinary ice
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card != null and card.is_agenda():
			return true
	return false


func _is_naked_agenda_install(action: GameAction, snap: Dictionary) -> bool:
	if action == null or action.type != "install":
		return false
	var cr: CardRecord = action.params.get("card_record", null) as CardRecord
	if cr == null or not cr.is_agenda():
		return false
	# new_remote installs always start with 0 ice
	var server_id: String = action.params.get("server_id", "")
	if server_id == "new_remote":
		return true
	# Check existing remotes in the snapshot for 0 ice
	for remote in snap.get("remotes", []) as Array:
		var r: Dictionary = remote as Dictionary
		if r.get("server_id", "") == server_id and (r.get("ice_count", 0) as int) == 0:
			return true
	return false


# ── Ice candidate helpers ─────────────────────────────────────────────────────

# Returns up to max_count distinct ice cards from the Corp hand, deduplicated
# by primary ice subtype so candidates don't explode when holding many of the
# same type (e.g. three Palisades).
func _unique_ice_from_hand(ctx: GameContext, max_count: int) -> Array:
	var seen: Array  = []
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
