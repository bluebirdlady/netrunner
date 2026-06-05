class_name SnapshotCandidateGenerator
extends RefCounted

# ── SnapshotCandidateGenerator ────────────────────────────────────────────────
# Generates legal Corp click actions from a projected SimState snapshot without
# access to a live GameContext.  This is the enabling component for whole-turn
# beam search and turn-level MCTS.
#
# The snapshot must contain the extended fields populated by
# CorpStateEvaluator.snapshot() and maintained by project_corp_action():
#   corp_hand_cards               : Array[CardRecord]
#   corp_hand_ppc                 : Dictionary (card_id → bool)
#   corp_identity_click_available : bool
#   remotes[*].agenda_card_id     : String
#   remotes[*].agenda_points      : int
#   remotes[*].root_type          : String
#
# See Planning/tai_limitation_fixes.txt (SCG design specification) for full
# rationale and design decisions.
# ─────────────────────────────────────────────────────────────────────────────

# Hard cap on total candidates per call.  Keeps beam-search ply cost bounded.
const MAX_CANDIDATES := 20
# Ice layers per central before we stop adding more.
const ICE_MAX        := 3


# ── Public API ────────────────────────────────────────────────────────────────

# Returns a pruned Array[GameAction] of legal Corp actions in the given state.
# Returns [] only when corp_clicks_left == 0.  Never returns null.
# Pure: does not modify snap.
static func generate(snap: Dictionary) -> Array:
	if (snap.get("corp_clicks_left", 0) as int) <= 0:
		return []

	var candidates: Array = []

	_add_basic_actions(candidates, snap)
	_add_operations(candidates, snap)
	_add_archives_operations(candidates, snap)
	_add_ice_installs(candidates, snap)
	_add_agenda_installs(candidates, snap)
	_add_asset_installs(candidates, snap)
	_add_upgrade_installs(candidates, snap)
	_add_advance_actions(candidates, snap)
	_add_identity_click(candidates, snap)
	_add_installed_asset_abilities(candidates, snap)
	_add_basic_corp_actions(candidates, snap)

	# Trim to cap — basic economy actions go first so they are never lost.
	if candidates.size() > MAX_CANDIDATES:
		candidates = candidates.slice(0, MAX_CANDIDATES)

	return candidates


# ── Action generators ─────────────────────────────────────────────────────────

static func _add_basic_actions(out: Array, snap: Dictionary) -> void:
	out.append(GameAction.gain_credits())
	if (snap.get("corp_deck", 0) as int) > 0:
		out.append(GameAction.draw_card())


static func _add_operations(out: Array, snap: Dictionary) -> void:
	var corp_cr: int   = snap.get("corp_credits", 0) as int
	var ppc: Dictionary = snap.get("corp_hand_ppc", {}) as Dictionary

	for entry in snap.get("corp_hand_cards", []) as Array:
		var c: CardRecord = entry as CardRecord
		if c == null or c.card_type != "operation":
			continue
		if corp_cr < max(0, c.cost):
			continue
		# Pre-play condition guard (e.g. Oppo Research, Active Policing).
		if not (ppc.get(c.id, true) as bool):
			continue
		out.append(GameAction.play_operation(c))


static func _add_ice_installs(out: Array, snap: Dictionary) -> void:
	var corp_cr: int  = snap.get("corp_credits", 0) as int
	var hq_ice:  int  = snap.get("hq_ice",       0) as int
	var rd_ice:  int  = snap.get("rd_ice",        0) as int
	var remotes: Array = snap.get("remotes", []) as Array

	for entry in snap.get("corp_hand_cards", []) as Array:
		var c: CardRecord = entry as CardRecord
		if c == null or not c.is_ice():
			continue

		# Central: HQ — positional cost = number of existing HQ ice.
		if hq_ice < ICE_MAX and corp_cr >= hq_ice:
			out.append(GameAction.install(c, "hq", "ice"))

		# Central: RD
		if rd_ice < ICE_MAX and corp_cr >= rd_ice:
			out.append(GameAction.install(c, "rd", "ice"))

		# Best remote target (at most one, priority-ordered).
		var best_remote: String = _best_ice_remote(remotes, corp_cr)
		if best_remote != "":
			out.append(GameAction.install(c, best_remote, "ice"))


static func _add_agenda_installs(out: Array, snap: Dictionary) -> void:
	var remotes: Array = snap.get("remotes", []) as Array

	for entry in snap.get("corp_hand_cards", []) as Array:
		var c: CardRecord = entry as CardRecord
		if c == null or not c.is_agenda():
			continue

		# Prefer existing iced empty-root remotes (up to 3).
		var placed := 0
		for r in remotes:
			var rd: Dictionary = r as Dictionary
			if rd.get("root_type", "") != "":
				continue   # slot occupied
			if (rd.get("ice_count", 0) as int) >= 1:
				out.append(GameAction.install(c, rd.get("server_id", "") as String, "root"))
				placed += 1
				if placed >= 3:
					break

		# Always offer new_remote; evaluator penalises if it ends up naked.
		out.append(GameAction.install(c, "new_remote", "root"))


static func _add_asset_installs(out: Array, snap: Dictionary) -> void:
	var remotes: Array = snap.get("remotes", []) as Array

	for entry in snap.get("corp_hand_cards", []) as Array:
		var c: CardRecord = entry as CardRecord
		if c == null or c.card_type != "asset":
			continue

		# Any empty root slot, then new_remote.
		var placed := 0
		for r in remotes:
			var rd: Dictionary = r as Dictionary
			if rd.get("root_type", "") != "":
				continue
			out.append(GameAction.install(c, rd.get("server_id", "") as String, "root"))
			placed += 1
			if placed >= 2:
				break
		out.append(GameAction.install(c, "new_remote", "root"))


static func _add_advance_actions(out: Array, snap: Dictionary) -> void:
	if (snap.get("corp_credits", 0) as int) < 1:
		return

	for r in snap.get("remotes", []) as Array:
		var rd: Dictionary = r as Dictionary

		# Agenda advance (includes the final advance that scores it).
		if rd.get("has_agenda", false):
			var card_id: String = rd.get("agenda_card_id", "") as String
			if card_id == "":
				card_id = "__sim_agenda__"
			out.append(GameAction.advance(card_id))

		# Trap advance (only when protected by at least one ice).
		if rd.get("has_trap", false) and (rd.get("ice_count", 0) as int) > 0:
			out.append(GameAction.advance("__sim_trap__"))


static func _add_identity_click(out: Array, snap: Dictionary) -> void:
	if snap.get("corp_identity_click_available", false):
		var id_name: String = snap.get("corp_identity", "") as String
		if id_name != "":
			out.append(GameAction.use_installed_card("identity_corp", id_name))


# ── Helpers ───────────────────────────────────────────────────────────────────

# ── Previously-excluded action types ─────────────────────────────────────────

# Upgrades — install into the agenda remote (protecting the scoring server),
# any iced central, or new_remote for future use (e.g. Crisium Grid).
static func _add_upgrade_installs(out: Array, snap: Dictionary) -> void:
	var remotes: Array = snap.get("remotes", []) as Array
	var corp_cr: int   = snap.get("corp_credits", 0) as int

	for entry in snap.get("corp_hand_cards", []) as Array:
		var c: CardRecord = entry as CardRecord
		if c == null or c.card_type != "upgrade":
			continue
		# Prefer the iced agenda remote — upgrades there protect the scoring play.
		var placed := 0
		for r in remotes:
			var rd: Dictionary = r as Dictionary
			if rd.get("has_agenda", false) and (rd.get("ice_count", 0) as int) >= 1:
				out.append(GameAction.install(c, rd.get("server_id", "") as String, "root"))
				placed += 1
				if placed >= 2:
					break
		# Centrals (e.g. Crisium Grid on HQ / RD).
		if snap.get("hq_ice", 0) as int > 0:
			out.append(GameAction.install(c, "hq", "root"))
		if snap.get("rd_ice", 0) as int > 0:
			out.append(GameAction.install(c, "rd", "root"))
		# New remote as a last resort.
		out.append(GameAction.install(c, "new_remote", "root"))


# Operations playable from Archives (e.g. Petty Cash).
# corp_archives_ops is populated by CorpStateEvaluator.snapshot().
static func _add_archives_operations(out: Array, snap: Dictionary) -> void:
	for entry in snap.get("corp_archives_ops", []) as Array:
		var c: CardRecord = entry as CardRecord
		if c == null:
			continue
		out.append(GameAction.play_from_archives(c.id))


# Click abilities on rezzed installed assets (e.g. Rashida Jaheem: click+trash → draw 3, gain 2cr).
# corp_installed_click_assets is populated by CorpStateEvaluator.snapshot().
static func _add_installed_asset_abilities(out: Array, snap: Dictionary) -> void:
	for entry in snap.get("corp_installed_click_assets", []) as Array:
		var e: Dictionary = entry as Dictionary
		var inst_id: String = e.get("instance_id", "") as String
		var card_id: String = e.get("card_id",     "") as String
		if inst_id == "" or card_id == "":
			continue
		out.append(GameAction.use_installed_card(inst_id, card_id))


# §10.1.2 purge + §10.5.3 trash-resource basic Corp actions.
# Purge only when virus pressure is high (threshold mirrors CorpTurnAI heuristic).
# Trash-resource only when runner is tagged; generates one action per resource,
# most expensive first (cap at 2 to keep candidate count bounded).
static func _add_basic_corp_actions(out: Array, snap: Dictionary) -> void:
	var corp_cr:    int = snap.get("corp_credits",    0) as int
	var corp_clicks: int = snap.get("corp_clicks_left", 0) as int
	var runner_tagged: bool = (snap.get("runner_tags", 0) as int) > 0

	# §10.1.2 — Purge virus counters (costs 3 clicks)
	if corp_clicks >= 3:
		var virus_total: int = snap.get("runner_virus_total", 0) as int
		if virus_total > 4:   # only worthwhile above threat threshold
			out.append(GameAction.purge_virus())

	# §10.5.3 — Trash a runner resource (costs 1 click + 2cr, runner must be tagged)
	if runner_tagged and corp_clicks >= 1 and corp_cr >= 2:
		var resources: Array = snap.get("runner_resources", []) as Array
		# Sort by cost descending — trash the most valuable resource first
		var sorted_resources: Array = resources.duplicate()
		sorted_resources.sort_custom(func(a, b):
			return (a as Dictionary).get("cost", 0) > (b as Dictionary).get("cost", 0))
		var added := 0
		for r in sorted_resources:
			var rd: Dictionary = r as Dictionary
			out.append(GameAction.trash_runner_resource(
				rd.get("instance_id", "") as String,
				rd.get("card_id", "") as String))
			added += 1
			if added >= 2:   # cap: evaluate at most 2 resource targets
				break


# Returns the best remote server_id for an ice install, or "" if none viable.
# Priority: naked agenda > lightly-iced agenda > new_remote (scoring slot).
static func _best_ice_remote(remotes: Array, corp_cr: int) -> String:
	# Priority 1: naked agenda remote — most urgent protection need.
	for r in remotes:
		var rd: Dictionary = r as Dictionary
		if rd.get("has_agenda", false) and (rd.get("ice_count", 0) as int) == 0:
			return rd.get("server_id", "") as String   # first ice is free (cost 0)

	# Priority 2: singly-iced agenda remote — layering up protection.
	for r in remotes:
		var rd: Dictionary = r as Dictionary
		if rd.get("has_agenda", false) and (rd.get("ice_count", 0) as int) == 1:
			if corp_cr >= 1:   # second ice costs 1
				return rd.get("server_id", "") as String

	# Priority 3: new_remote — building a future scoring slot.
	return "new_remote"
