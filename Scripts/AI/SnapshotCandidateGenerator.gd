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
	var corp_cr: int    = snap.get("corp_credits", 0) as int
	var ppc: Dictionary = snap.get("corp_hand_ppc", {}) as Dictionary
	var remotes: Array  = snap.get("remotes", []) as Array

	# Pre-compute whether any remote currently has an installed agenda — needed
	# to gate advance-placement operations (Seamless Launch, Big Deal) that are
	# useless without a target.
	var has_installed_agenda: bool = false
	for _rn in remotes:
		if (_rn as Dictionary).get("has_agenda", false):
			has_installed_agenda = true
			break

	# Pre-compute whether the Runner is tagged — needed to gate ops whose
	# additional cost is removing a Runner tag (Unleash, Backroom Machinations).
	var runner_has_tag: bool = (snap.get("runner_tags", 0) as int) >= 1

	# Pre-compute how many non-ice / non-operation cards are in HQ — needed to
	# gate Mitosis, which installs from HQ and is useless if nothing is there.
	var installable_in_hq: int = 0
	for _hc in snap.get("corp_hand_cards", []) as Array:
		var _hcr: CardRecord = _hc as CardRecord
		if _hcr != null and _hcr.card_type not in ["ice", "operation", "identity"]:
			installable_in_hq += 1

	# Pre-compute qualifying FtM/FullyOp remotes: ICE + root card present.
	# FtM places 1 counter per qualifying remote (worthwhile at 3+).
	# Fully Operational gains 2cr per qualifying remote (worthwhile at 1+).
	var ftm_qualifying: int = 0
	for _fr in remotes:
		var _frd: Dictionary = _fr as Dictionary
		if (_frd.get("ice_count", 0) as int) > 0 \
				and (_frd.get("root_type", "") as String) != "":
			ftm_qualifying += 1

	# Pre-compute threat and run flags for conditional operation gates.
	var corp_sc: int  = snap.get("corp_score",   0) as int
	var run_sc:  int  = snap.get("runner_score", 0) as int
	var threat4: bool = corp_sc >= 4 or run_sc >= 4
	var runner_ran_last_turn: bool = snap.get("runner_ran_last_turn", false) as bool

	# Seamless Launch and Big Deal use add_counters_to_target with
	# exclude_installed_this_turn — they cannot target an agenda installed this
	# very Corp turn.  has_pre_existing_agenda is baked into the snap at turn
	# start so it reflects only agendas that were already installed then.
	var has_pre_existing_agenda: bool = snap.get("has_pre_existing_agenda", false) as bool

	for entry in snap.get("corp_hand_cards", []) as Array:
		var c: CardRecord = entry as CardRecord
		if c == null or c.card_type != "operation":
			continue
		if corp_cr < max(0, c.cost):
			continue
		# Pre-play condition guard (e.g. Oppo Research, Active Policing).
		if not (ppc.get(c.id, true) as bool):
			continue
		# Advance-placement operations are useless without an installed agenda.
		# Offering them when no agenda is installed wastes a click and a card,
		# and causes the MCTS to advance non-agenda cards (e.g. ICE) for no benefit.
		if c.id in ["seamless_launch", "big_deal"] and not has_pre_existing_agenda:
			continue
		if c.id in ["business_as_usual", "touch_ups"] and not has_installed_agenda:
			continue
		# Mitosis installs up to 2 cards from HQ — pointless if fewer than 2
		# non-operation cards are available to install.
		if c.id == "mitosis" and installable_in_hq < 2:
			continue
		# Flood the Market places 1 counter per qualifying remote; only worthwhile
		# when at least 3 qualifying remotes exist and an agenda is already installed.
		if c.id == "flood_the_market" and (not has_installed_agenda or ftm_qualifying < 3):
			continue
		# Fully Operational gives 0 benefit with no qualifying remotes.
		if c.id == "fully_operational" and ftm_qualifying < 1:
			continue
		# Measured Response only fires at Threat 4 (AND runner ran last turn — checked
		# in projection since that field is not available in the pre-play gate).
		if c.id == "measured_response" and not threat4:
			continue
		# Public Trail only fires if the runner made a successful run last turn.
		if c.id == "public_trail" and not runner_ran_last_turn:
			continue
		# Ops whose additional cost is removing a Runner tag (Unleash, Backroom Machinations).
		if c.id in ["unleash", "backroom_machinations"] and not runner_has_tag:
			continue
		# Double operations (additional_cost_clicks: 1) require 2 clicks total.
		if c.id in ["retirement_plan", "secure_and_protect", "pivot"] \
				and (snap.get("corp_clicks_left", 0) as int) < 2:
			continue
		# Reanimation Protocol is only useful if archives has at least 1 card.
		if c.id == "reanimation_protocol" and (snap.get("corp_discard_sz", 0) as int) < 1:
			continue
		# Focus Group advances an installed card — useless without an agenda target.
		if c.id == "focus_group" and not has_installed_agenda:
			continue
		# Triple operations (additional_cost_clicks: 2) require 3 clicks total.
		if c.id in ["kakurenbo", "mutually_assured_destruction"] \
				and (snap.get("corp_clicks_left", 0) as int) < 3:
			continue
		# Kakurenbo installs from Archives — useless if Archives is empty.
		if c.id == "kakurenbo" and (snap.get("corp_discard_sz", 0) as int) < 1:
			continue
		# MAD only worthwhile when the Corp can immediately exploit the resulting
		# tags — gate on tag exploit being in hand.
		if c.id == "mutually_assured_destruction" \
				and not (snap.get("tag_exploit_in_hand", false) as bool):
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

		# Central: R&D first — leaving R&D open is strictly more dangerous than
		# leaving HQ open because every R&D run hits the top card directly, while
		# HQ runs hit a random card that may not be an agenda.  When both centrals
		# are equally unprotected, generating R&D before HQ makes R&D the default
		# winner of evaluator tiebreaks without needing a separate score delta.
		if rd_ice < ICE_MAX and corp_cr >= rd_ice:
			out.append(GameAction.install(c, "rd", "ice"))

		# Central: HQ — positional cost = number of existing HQ ice.
		if hq_ice < ICE_MAX and corp_cr >= hq_ice:
			out.append(GameAction.install(c, "hq", "ice"))

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

		# Offer new_remote only when no naked agenda is already exposed and there
		# are clicks remaining to add ICE protection.  On the final click there
		# is no opportunity to ice the new server before the runner's turn, so a
		# naked new_remote install is always immediately stealable.
		var has_naked_agenda: bool = false
		for rn in remotes:
			var rnd: Dictionary = rn as Dictionary
			if rnd.get("has_agenda", false) and (rnd.get("ice_count", 0) as int) == 0:
				has_naked_agenda = true
				break
		var clicks_left: int = snap.get("corp_clicks_left", 0) as int
		if not has_naked_agenda and clicks_left > 1:
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
