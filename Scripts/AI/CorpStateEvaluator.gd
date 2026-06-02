class_name CorpStateEvaluator
extends RefCounted

# ── CorpStateEvaluator ────────────────────────────────────────────────────────
# Converts a live GameContext into a lightweight SimState snapshot and
# evaluates it from the Corp's perspective.  All projection methods are
# approximate first-order effects — they do not invoke the real TurnManager.
#
# SimState Dictionary schema
# ─────────────────────────────────────────────────────────────────────────────
#   corp_credits    : int
#   runner_credits  : int
#   corp_score      : int   — agenda points
#   runner_score    : int
#   pts_to_win      : int
#   turn_number     : int
#   runner_hand     : int   — grip size
#   corp_hand       : int
#   corp_hand_limit : int   — max hand size (identity-aware)
#   corp_deck       : int
#   runner_deck     : int
#   runner_tags     : int
#   runner_rig      : int   — total installed runner cards
#   runner_breaker_count  : int   — installed icebreakers only
#   runner_has_fracter    : bool
#   runner_has_killer     : bool
#   runner_has_decoder    : bool
#   runner_has_ai_breaker : bool
#   hq_ice          : int
#   hq_ice_barrier  : bool
#   hq_ice_sentry   : bool
#   hq_ice_code_gate: bool
#   rd_ice          : int
#   rd_ice_barrier  : bool
#   rd_ice_sentry   : bool
#   rd_ice_code_gate: bool
#   corp_identity   : String  — identity card ID
#   corp_discard_sz : int   — size of Archives
#   corp_net_damage_potential : int  — damage ops in hand + Shock in Archives
#   remotes         : Array[Dictionary]
#                     each: { server_id, ice_count, has_agenda, adv, req,
#                             has_barrier, has_sentry, has_code_gate }

const WIN_VALUE  :=  10000.0
const LOSE_VALUE := -10000.0

# Operations that deal direct damage — used when computing corp_net_damage_potential.
const DAMAGE_OP_IDS := ["neurospike", "punitive_counterstrike", "boom", "scorched_earth"]


# ── Private helpers ───────────────────────────────────────────────────────────

# Returns {barrier, sentry, code_gate} presence flags for all ice on a server.
func _server_ice_subtypes(server: Server) -> Dictionary:
	var result := {"barrier": false, "sentry": false, "code_gate": false}
	if server == null:
		return result
	for ic in server.ice:
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null:
			continue
		if c.card_record.has_subtype("barrier"):
			result["barrier"] = true
		if c.card_record.has_subtype("sentry"):
			result["sentry"] = true
		if c.card_record.has_subtype("code_gate"):
			result["code_gate"] = true
	return result


# ── Snapshot ──────────────────────────────────────────────────────────────────

func snapshot(ctx: GameContext) -> Dictionary:
	var hq_server: Server = ctx.get_server("hq")
	var rd_server: Server = ctx.get_server("rd")
	var identity_id: String = ctx.corp_identity.id if ctx.corp_identity != null else ""

	# ── Remote server entries (include ice subtype flags) ─────────────────────
	var remotes: Array = []
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if not s.is_remote():
			continue
		var agenda_ic: InstalledCard = null
		for c in s.root:
			var ic: InstalledCard = c as InstalledCard
			if ic != null and ic.card_record != null and ic.card_record.is_agenda():
				agenda_ic = ic
				break
		# Find any advanceable non-agenda (trap) in this server's root.
		var trap_ic: InstalledCard = null
		for c in s.root:
			var ic: InstalledCard = c as InstalledCard
			if ic != null and ic.card_record != null \
					and not ic.card_record.is_agenda() and ic.can_be_advanced():
				trap_ic = ic
				break
		var s_sub := _server_ice_subtypes(s)
		remotes.append({
			"server_id":     key,
			"ice_count":     s.ice.size(),
			"has_agenda":    agenda_ic != null,
			"adv":           agenda_ic.get_counter("advancement") if agenda_ic != null else 0,
			"req":           agenda_ic.card_record.advancement_requirement if agenda_ic != null else 0,
			"has_trap":      trap_ic != null,
			"trap_adv":      trap_ic.get_counter("advancement") if trap_ic != null else 0,
			"has_barrier":   s_sub["barrier"],
			"has_sentry":    s_sub["sentry"],
			"has_code_gate": s_sub["code_gate"],
		})

	# ── Central ice subtype presence ──────────────────────────────────────────
	var hq_sub := _server_ice_subtypes(hq_server)
	var rd_sub := _server_ice_subtypes(rd_server)

	# ── Runner rig quality ────────────────────────────────────────────────────
	var runner_breaker_count := 0
	var runner_has_fracter   := false
	var runner_has_killer    := false
	var runner_has_decoder   := false
	var runner_has_ai        := false
	for ic in ctx.runner_rig:
		var rr: InstalledCard = ic as InstalledCard
		if rr == null or rr.card_record == null:
			continue
		var cr: CardRecord = rr.card_record
		if cr.has_subtype("ai"):
			runner_has_ai         = true
			runner_breaker_count += 1
		elif cr.has_subtype("fracter"):
			runner_has_fracter    = true
			runner_breaker_count += 1
		elif cr.has_subtype("killer"):
			runner_has_killer     = true
			runner_breaker_count += 1
		elif cr.has_subtype("decoder"):
			runner_has_decoder    = true
			runner_breaker_count += 1

	# ── Installed upgrades ───────────────────────────────────────────────────
	var upgrade_count := 0
	for srv_entry in ctx.servers.values():
		var usrv: Server = srv_entry as Server
		if usrv == null:
			continue
		for uc in usrv.root:
			var uic: InstalledCard = uc as InstalledCard
			if uic != null and uic.card_record != null and uic.card_record.card_type == "upgrade":
				upgrade_count += 1

	# ── Corp damage potential ─────────────────────────────────────────────────
	var corp_dmg_potential := 0
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card != null and card.id in DAMAGE_OP_IDS:
			corp_dmg_potential += 1
	for discard_entry in ctx.corp_discard:
		var card: CardRecord = discard_entry as CardRecord
		if card != null and card.id == "shock":
			corp_dmg_potential += 1

	return {
		"corp_credits":    ctx.corp_credits,
		"runner_credits":  ctx.runner_credits,
		"corp_score":      ctx.corp_agenda_points(),
		"runner_score":    ctx.runner_agenda_points(),
		"pts_to_win":      ctx.agenda_points_to_win,
		"turn_number":     ctx.turn_number,
		"runner_hand":     ctx.runner_hand.size(),
		"corp_hand":       ctx.corp_hand.size(),
		"corp_hand_limit": ctx.corp_max_hand_size(),
		"corp_deck":       ctx.corp_deck.size(),
		"runner_deck":     ctx.runner_deck.size(),
		"runner_tags":     ctx.runner_tags,
		"runner_rig":      ctx.runner_rig.size(),
		"runner_breaker_count":    runner_breaker_count,
		"runner_has_fracter":      runner_has_fracter,
		"runner_has_killer":       runner_has_killer,
		"runner_has_decoder":      runner_has_decoder,
		"runner_has_ai_breaker":   runner_has_ai,
		"hq_ice":           hq_server.ice.size() if hq_server != null else 0,
		"hq_ice_barrier":   hq_sub["barrier"],
		"hq_ice_sentry":    hq_sub["sentry"],
		"hq_ice_code_gate": hq_sub["code_gate"],
		"rd_ice":           rd_server.ice.size() if rd_server != null else 0,
		"rd_ice_barrier":   rd_sub["barrier"],
		"rd_ice_sentry":    rd_sub["sentry"],
		"rd_ice_code_gate": rd_sub["code_gate"],
		"corp_identity":   identity_id,
		"corp_discard_sz": ctx.corp_discard.size(),
		"corp_net_damage_potential": corp_dmg_potential,
		"corp_installed_upgrades":   upgrade_count,
		"remotes":         remotes,
	}


# ── Evaluation ────────────────────────────────────────────────────────────────

# Returns a float score from the Corp's perspective.  Higher = better for Corp.
func evaluate(s: Dictionary) -> float:
	var corp_score:   int = s.get("corp_score",   0) as int
	var runner_score: int = s.get("runner_score", 0) as int
	var pts_to_win:   int = s.get("pts_to_win",   7) as int

	# Terminal check
	if corp_score   >= pts_to_win: return WIN_VALUE
	if runner_score >= pts_to_win: return LOSE_VALUE

	var identity: String = s.get("corp_identity", "") as String
	var score := 0.0

	# ── Game-phase multipliers ─────────────────────────────────────────────────
	var turn: int = s.get("turn_number", 1) as int
	var phase_econ_mult:  float = 1.0   # applied to economy and ice coverage
	var phase_score_mult: float = 1.0   # applied to score-progress component
	var late_penalty:     float = 0.0   # extra cost for falling behind late

	if turn <= 6:
		# Setup phase: economy and ice are the foundations; score urgency is low.
		phase_econ_mult  = 1.3
		phase_score_mult = 0.7
	elif turn >= 14:
		# Late game: urgency spikes; falling behind compounds each turn.
		phase_score_mult = 1.4
		var pts_behind: int = pts_to_win - corp_score
		late_penalty = float(pts_behind) * float(turn - 13) * 0.3

	# ── Progress toward winning ────────────────────────────────────────────────
	# Runner penalty is steeper — losing is worse than not winning yet.
	score += float(corp_score)   / float(pts_to_win) * 30.0 * phase_score_mult
	score -= float(runner_score) / float(pts_to_win) * 42.0 * phase_score_mult
	score -= late_penalty

	# ── Economy ────────────────────────────────────────────────────────────────
	# Corp credits have diminishing returns above ~10; capped so a large pile
	# does not dominate all other factors.
	var corp_cr: int = s.get("corp_credits", 0) as int
	score += (minf(float(corp_cr), 15.0) * 0.5 + maxf(float(corp_cr) - 15.0, 0.0) * 0.1) * phase_econ_mult
	score -= float(s.get("runner_credits", 0)) * 0.3

	# ── Ice coverage on centrals ───────────────────────────────────────────────
	score += float(s.get("hq_ice", 0)) * 1.5 * phase_econ_mult
	score += float(s.get("rd_ice", 0)) * 1.5 * phase_econ_mult

	# ── Remote scoring opportunities ───────────────────────────────────────────
	for remote in s.get("remotes", []) as Array:
		var r: Dictionary = remote as Dictionary
		if not r.get("has_agenda", false):
			continue
		var req:    int = r.get("req", 1) as int
		var adv:    int = r.get("adv", 0) as int
		var ice:    int = r.get("ice_count", 0) as int
		var needed: int = req - adv
		# Base value for having an agenda on the table — scoring trajectory.
		if   needed <= 0: score += 10.0
		elif needed == 1: score += 6.0
		elif needed == 2: score += 4.0
		else:             score += 2.0
		# Ice protection bonus (up to 2 layers)
		var ice_bonus_per_layer: float = 1.5
		# ── Jinteki: Replicating Perfection ──────────────────────────────────
		# Remote servers are inherently safer — runner must run a central first.
		if identity == "jinteki_replicating_perfection":
			ice_bonus_per_layer = 0.8
		score += float(min(ice, 2)) * ice_bonus_per_layer

	# ── Advancement trap threat ───────────────────────────────────────────────
	# Trap cards (Clearinghouse, Urtica Cipher, etc.) in iced remotes build
	# kill potential.  Score based on proximity to the runner's grip size.
	var runner_grip_t: int = s.get("runner_hand", 5) as int
	for remote in s.get("remotes", []) as Array:
		var r: Dictionary = remote as Dictionary
		if not r.get("has_trap", false) or (r.get("ice_count", 0) as int) == 0:
			continue
		var trap_adv: int = r.get("trap_adv", 0) as int
		if trap_adv <= 0:
			continue
		var threat: int = trap_adv - runner_grip_t
		if   threat >= 0:  score += 50.0                      # activatable for kill now
		elif threat == -1: score += 20.0                      # one advance from kill
		elif threat == -2: score += 8.0                       # two advances away
		else:              score += float(trap_adv) * 1.5     # building threat

	# ── Runner tags ────────────────────────────────────────────────────────────
	var runner_tags: int = s.get("runner_tags", 0) as int
	score += float(runner_tags) * 2.0

	# ── Installed upgrades ─────────────────────────────────────────────────────
	# Upgrades (Anoetic Void, Manegarm Skunkworks, etc.) provide run-time
	# defensive value that the runner response projector can't directly model.
	# Approximate as a flat per-upgrade bonus consistent with one ice layer.
	score += float(s.get("corp_installed_upgrades", 0)) * 1.5

	# ── Kill / flatline detection ──────────────────────────────────────────────
	# A runner with very few cards is vulnerable to a flatline.  Scale the bonus
	# by corp_net_damage_potential: tools in hand make the window exploitable now;
	# without them it is still a structurally dangerous state worth valuing.
	var runner_grip: int = s.get("runner_hand",               5) as int
	var corp_dmg:    int = s.get("corp_net_damage_potential",  0) as int

	if runner_grip <= 1:
		# Near-flatline: baseline 100 + up to 400 more with damage tools ready.
		score += 100.0 + 400.0 * clampf(float(corp_dmg) / 3.0, 0.0, 1.0)
	elif runner_grip <= 3 and runner_tags >= 1:
		# Tagged runner with low grip — punishment operations become decisive.
		score += 15.0

	# ── Corp hand size ─────────────────────────────────────────────────────────
	# Reward a healthy hand (more options), penalise a thin grip.
	var hand_limit: int = s.get("corp_hand_limit", 5) as int
	var corp_hand:  int = min(s.get("corp_hand", 0) as int, hand_limit)
	var hand_full_threshold := 3
	if corp_hand < hand_full_threshold:
		score -= float(hand_full_threshold - corp_hand) * 1.0
	elif corp_hand <= hand_limit:
		score += float(corp_hand - hand_full_threshold) * 0.4

	# ── Identity-specific bonuses ──────────────────────────────────────────────

	match identity:

		"weyland_consortium_built_to_last":
			for remote in s.get("remotes", []) as Array:
				var r: Dictionary = remote as Dictionary
				if r.get("has_agenda", false) and (r.get("adv", 0) as int) == 0:
					score += 1.5
			if corp_cr >= 4:
				score += 0.5

		"haas_bioroid_precision_design":
			score += float(corp_score) * 0.5
			var discard_sz: int = s.get("corp_discard_sz", 0) as int
			if discard_sz > 0:
				score += 0.4

		"jinteki_replicating_perfection":
			score += float(s.get("hq_ice", 0)) * 0.5
			score += float(s.get("rd_ice", 0)) * 0.5

		"jinteki_restoring_humanity":
			var discard_sz: int = s.get("corp_discard_sz", 0) as int
			if discard_sz > 0:
				score += 0.7

	return score


# ── Corp action projection ────────────────────────────────────────────────────

# Returns a new SimState after the Corp plays one click action.
# Does NOT create or modify live GameContext state.
func project_corp_action(s: Dictionary, action: GameAction, _ctx: GameContext) -> Dictionary:
	var ns: Dictionary = s.duplicate(true)
	var identity: String = s.get("corp_identity", "") as String

	match action.type:
		"gain_credits":
			ns["corp_credits"] = (s.get("corp_credits", 0) as int) + 1

		"draw_card":
			var hand_limit: int = s.get("corp_hand_limit", 5) as int
			ns["corp_hand"] = min((s.get("corp_hand", 0) as int) + 1, hand_limit)
			ns["corp_deck"] = max(0, (s.get("corp_deck", 0) as int) - 1)

		"install":
			var card:      CardRecord = action.params.get("card_record", null) as CardRecord
			var server_id_i: String   = action.params.get("server_id",   "") as String
			var zone_i:      String   = action.params.get("zone",        "") as String

			if card == null:
				# Symbolic ice install from MCTS deep candidates.
				# Only handle the ice case; any other null-card install is a no-op.
				if zone_i != "ice" or server_id_i == "":
					return ns
				ns["corp_hand"] = max(0, (s.get("corp_hand", 0) as int) - 1)
				var sym_cost: int = 0
				match server_id_i:
					"hq":
						sym_cost = s.get("hq_ice", 0) as int
						ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - sym_cost)
						ns["hq_ice"] = sym_cost + 1
					"rd":
						sym_cost = s.get("rd_ice", 0) as int
						ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - sym_cost)
						ns["rd_ice"] = sym_cost + 1
					_:
						var remotes_sym: Array = (ns.get("remotes", []) as Array).duplicate(true)
						for i in range(remotes_sym.size()):
							var r: Dictionary = (remotes_sym[i] as Dictionary).duplicate()
							if r.get("server_id", "") == server_id_i:
								sym_cost = r.get("ice_count", 0) as int
								ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - sym_cost)
								r["ice_count"] = sym_cost + 1
								remotes_sym[i] = r
								break
						ns["remotes"] = remotes_sym
				return ns

			ns["corp_hand"] = max(0, (s.get("corp_hand", 0) as int) - 1)

			if card.is_ice():
				var server_id: String = action.params.get("server_id", "") as String
				var ice_install_cost: int = 0
				match server_id:
					"hq": ice_install_cost = s.get("hq_ice", 0) as int
					"rd": ice_install_cost = s.get("rd_ice", 0) as int
					_:
						for remote in s.get("remotes", []) as Array:
							if (remote as Dictionary).get("server_id", "") == server_id:
								ice_install_cost = (remote as Dictionary).get("ice_count", 0) as int
								break
				ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - ice_install_cost)
				# Update ice count and subtype flags for the target server.
				match server_id:
					"hq":
						ns["hq_ice"] = (s.get("hq_ice", 0) as int) + 1
						if card.has_subtype("barrier"):   ns["hq_ice_barrier"]   = true
						if card.has_subtype("sentry"):    ns["hq_ice_sentry"]    = true
						if card.has_subtype("code_gate"): ns["hq_ice_code_gate"] = true
					"rd":
						ns["rd_ice"] = (s.get("rd_ice", 0) as int) + 1
						if card.has_subtype("barrier"):   ns["rd_ice_barrier"]   = true
						if card.has_subtype("sentry"):    ns["rd_ice_sentry"]    = true
						if card.has_subtype("code_gate"): ns["rd_ice_code_gate"] = true
					_:
						var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
						for i in range(remotes_copy.size()):
							var r: Dictionary = (remotes_copy[i] as Dictionary).duplicate()
							if r.get("server_id", "") == server_id:
								r["ice_count"] = (r.get("ice_count", 0) as int) + 1
								if card.has_subtype("barrier"):   r["has_barrier"]   = true
								if card.has_subtype("sentry"):    r["has_sentry"]    = true
								if card.has_subtype("code_gate"): r["has_code_gate"] = true
								remotes_copy[i] = r
								break
						ns["remotes"] = remotes_copy

			elif card.is_agenda():
				var proj_ice := 0
				if _ctx != null:
					for hentry in _ctx.corp_hand:
						var hc: CardRecord = (hentry as Dictionary).get("card_record", null) as CardRecord
						if hc != null and hc.is_ice():
							proj_ice = 1
							break
				if identity == "jinteki_replicating_perfection":
					proj_ice = max(proj_ice, 1)
				var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
				remotes_copy.append({
					"server_id":     "projected",
					"ice_count":     proj_ice,
					"has_agenda":    true,
					"adv":           0,
					"req":           card.advancement_requirement,
					"has_barrier":   false,
					"has_sentry":    false,
					"has_code_gate": false,
				})
				ns["remotes"] = remotes_copy

			elif card.card_type == "upgrade":
				# Upgrades install for free (rez cost is separate).
				# Record the new upgrade so evaluate() can credit its defensive value.
				ns["corp_installed_upgrades"] = (s.get("corp_installed_upgrades", 0) as int) + 1

		"advance":
			var adv_cost: int = 1
			var credit_gain: int = 0
			if identity == "weyland_consortium_built_to_last":
				for remote in s.get("remotes", []) as Array:
					var r: Dictionary = remote as Dictionary
					if r.get("has_agenda", false) and (r.get("adv", 0) as int) == 0:
						credit_gain = 2
						break
			ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - adv_cost + credit_gain)
			var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
			var advanced_agenda := false
			for i in range(remotes_copy.size()):
				var r: Dictionary = remotes_copy[i] as Dictionary
				if r.get("has_agenda", false):
					var new_r := r.duplicate()
					new_r["adv"] = (r.get("adv", 0) as int) + 1
					remotes_copy[i] = new_r
					advanced_agenda = true
					break
			# No agenda to advance — try advancing a trap card instead.
			if not advanced_agenda:
				for i in range(remotes_copy.size()):
					var r: Dictionary = remotes_copy[i] as Dictionary
					if r.get("has_trap", false) and (r.get("ice_count", 0) as int) > 0:
						var new_r := r.duplicate()
						new_r["trap_adv"] = (r.get("trap_adv", 0) as int) + 1
						remotes_copy[i] = new_r
						break
			ns["remotes"] = remotes_copy

		"use_installed_card":
			ns["corp_credits"] = (s.get("corp_credits", 0) as int) + 2

		"play_operation":
			var card: CardRecord = action.params.get("card_record", null) as CardRecord
			if card == null:
				return ns
			var cost: int = max(0, card.cost)
			ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - cost)
			ns["corp_hand"]    = max(0, (s.get("corp_hand",    0) as int) - 1)
			match card.id:
				"hedge_fund":
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 9
				"government_subsidy":
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 14
				"predictive_planogram":
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 3
				"hansei_review":
					ns["corp_hand"]      = (ns.get("corp_hand",      0) as int) + 4
					ns["runner_credits"] = (ns.get("runner_credits",  0) as int) + 2
				"spin_doctor":
					ns["corp_hand"] = (ns.get("corp_hand", 0) as int) + 2
					ns["corp_deck"] = (ns.get("corp_deck", 0) as int) + 2
				"neurospike":
					var dmg: int = ns.get("corp_score", 0) as int
					ns["runner_hand"] = max(0, (ns.get("runner_hand", 0) as int) - dmg)
				_:
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 2

	return ns


# ── Runner response projection ────────────────────────────────────────────────

# Returns a new SimState after the runner attempts to run threat_server.
func project_runner_response(s: Dictionary, threat_server: String, _ctx: GameContext) -> Dictionary:
	var ns: Dictionary = s.duplicate(true)
	var identity: String = s.get("corp_identity", "") as String

	# Determine ice count on target server
	var ice_count: int = 0
	if threat_server == "hq":
		ice_count = s.get("hq_ice", 0) as int
	elif threat_server == "rd":
		ice_count = s.get("rd_ice", 0) as int
	else:
		for remote in s.get("remotes", []) as Array:
			if (remote as Dictionary).get("server_id", "") == threat_server:
				ice_count = (remote as Dictionary).get("ice_count", 0) as int
				break

	var runner_cr: int = s.get("runner_credits", 0) as int

	# ── Rig-quality-aware success probability ──────────────────────────────────
	var runner_breakers: int = s.get("runner_breaker_count", 0) as int
	var has_fracter: bool    = s.get("runner_has_fracter",    false) as bool
	var has_killer:  bool    = s.get("runner_has_killer",     false) as bool
	var has_decoder: bool    = s.get("runner_has_decoder",    false) as bool
	var has_ai:      bool    = s.get("runner_has_ai_breaker", false) as bool

	# Base probability from rig completeness.
	# AI breakers cover all ice types so they rate the same as a full rig.
	var base_prob: float
	if   has_ai:                base_prob = 0.80
	elif runner_breakers == 0:  base_prob = 0.15
	elif runner_breakers == 1:  base_prob = 0.45
	elif runner_breakers == 2:  base_prob = 0.65
	else:                       base_prob = 0.85   # >= 3 dedicated breakers

	# Scale by ice count and available credits.
	base_prob = clampf(base_prob - float(ice_count) * 0.12 + float(runner_cr) * 0.015, 0.05, 0.95)

	# Subtype penalty: for each ice type on this server the runner cannot break,
	# reduce success probability by 0.15.  AI breakers skip this check entirely.
	if not has_ai and runner_breakers > 0:
		var svr_barrier:   bool = false
		var svr_sentry:    bool = false
		var svr_code_gate: bool = false
		if threat_server == "hq":
			svr_barrier   = s.get("hq_ice_barrier",   false) as bool
			svr_sentry    = s.get("hq_ice_sentry",    false) as bool
			svr_code_gate = s.get("hq_ice_code_gate", false) as bool
		elif threat_server == "rd":
			svr_barrier   = s.get("rd_ice_barrier",   false) as bool
			svr_sentry    = s.get("rd_ice_sentry",    false) as bool
			svr_code_gate = s.get("rd_ice_code_gate", false) as bool
		else:
			for remote in s.get("remotes", []) as Array:
				if (remote as Dictionary).get("server_id", "") == threat_server:
					svr_barrier   = (remote as Dictionary).get("has_barrier",   false) as bool
					svr_sentry    = (remote as Dictionary).get("has_sentry",    false) as bool
					svr_code_gate = (remote as Dictionary).get("has_code_gate", false) as bool
					break
		if svr_barrier   and not has_fracter: base_prob -= 0.20
		if svr_sentry    and not has_killer:  base_prob -= 0.20
		if svr_code_gate and not has_decoder: base_prob -= 0.20
		base_prob = maxf(base_prob, 0.05)

	var success_prob: float = base_prob

	# ── Jinteki: Replicating Perfection ──────────────────────────────────────
	# Runner must run a central before accessing any remote — model as a large
	# penalty on remote success probability.
	var is_remote_target := (threat_server not in ["hq", "rd"] and threat_server != "")
	if identity == "jinteki_replicating_perfection" and is_remote_target:
		success_prob = clampf(success_prob - 0.35, 0.0, 0.50)

	# Runner spends credits breaking ice
	var expected_spend: int = int(float(ice_count) * 2.5)
	ns["runner_credits"] = max(0, runner_cr - expected_spend)

	# On successful run, runner may steal an agenda.
	# "projected" remotes were just installed this turn — Corp still has clicks
	# to ice them, so skip the steal projection for them.
	if success_prob > 0.5:
		var has_agenda := false
		var is_projected := (threat_server == "projected")
		if threat_server in ["hq", "rd"]:
			has_agenda = (s.get("corp_deck", 0) as int) > 0
		else:
			for remote in s.get("remotes", []) as Array:
				if (remote as Dictionary).get("server_id", "") == threat_server:
					has_agenda = (remote as Dictionary).get("has_agenda", false) as bool
					break

		if has_agenda and not is_projected:
			ns["runner_score"] = (s.get("runner_score", 0) as int) + 2
			if threat_server not in ["hq", "rd"]:
				var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
				for i in range(remotes_copy.size()):
					var r: Dictionary = remotes_copy[i] as Dictionary
					if r.get("server_id", "") == threat_server:
						var new_r := r.duplicate()
						new_r["has_agenda"] = false
						remotes_copy[i] = new_r
						break
				ns["remotes"] = remotes_copy

	return ns
