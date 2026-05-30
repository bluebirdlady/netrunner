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
#   hq_ice          : int
#   rd_ice          : int
#   corp_identity   : String  — identity card ID
#   corp_discard_sz : int   — size of Archives (facedown card count approximation)
#   remotes         : Array[Dictionary]
#                     each: { server_id, ice_count, has_agenda, adv, req }

const WIN_VALUE  :=  10000.0
const LOSE_VALUE := -10000.0


# ── Snapshot ──────────────────────────────────────────────────────────────────

func snapshot(ctx: GameContext) -> Dictionary:
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
		remotes.append({
			"server_id":  key,
			"ice_count":  s.ice.size(),
			"has_agenda": agenda_ic != null,
			"adv":        agenda_ic.get_counter("advancement") if agenda_ic != null else 0,
			"req":        agenda_ic.card_record.advancement_requirement if agenda_ic != null else 0,
		})

	var hq_server: Server = ctx.get_server("hq")
	var rd_server: Server = ctx.get_server("rd")
	var identity_id: String = ctx.corp_identity.id if ctx.corp_identity != null else ""

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
		"hq_ice":          hq_server.ice.size() if hq_server != null else 0,
		"rd_ice":          rd_server.ice.size() if rd_server != null else 0,
		"corp_identity":   identity_id,
		"corp_discard_sz": ctx.corp_discard.size(),
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

	# Progress toward winning (runner penalty is steeper — losing is worse)
	score += float(corp_score)   / float(pts_to_win) * 30.0
	score -= float(runner_score) / float(pts_to_win) * 42.0

	# Economy — credits have diminishing returns above ~10.
	# Capped so that accumulating 30+ credits doesn't dominate all other factors.
	var corp_cr: int = s.get("corp_credits", 0) as int
	score += minf(float(corp_cr), 15.0) * 0.5 + maxf(float(corp_cr) - 15.0, 0.0) * 0.1
	score -= float(s.get("runner_credits", 0)) * 0.3

	# Ice coverage on centrals
	score += float(s.get("hq_ice", 0)) * 1.5
	score += float(s.get("rd_ice", 0)) * 1.5

	# Remote scoring opportunities
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
		# Ice on remotes is somewhat less critical than under other identities.
		if identity == "jinteki_replicating_perfection":
			ice_bonus_per_layer = 0.8   # ice still helps but the passive deters runs
		score += float(min(ice, 2)) * ice_bonus_per_layer

	# Runner tags — Corp can punish
	score += float(s.get("runner_tags", 0)) * 2.0

	# Corp hand size — reward a healthy hand (more options), penalise low grip.
	# Use the identity-aware hand limit so HB (limit 6) scores correctly.
	var hand_limit: int = s.get("corp_hand_limit", 5) as int
	var corp_hand:  int = min(s.get("corp_hand", 0) as int, hand_limit)
	var hand_full_threshold := 3
	if corp_hand < hand_full_threshold:
		score -= float(hand_full_threshold - corp_hand) * 1.0
	elif corp_hand <= hand_limit:
		score += float(corp_hand - hand_full_threshold) * 0.4

	# ── Identity-specific bonuses ─────────────────────────────────────────────

	match identity:

		"weyland_consortium_built_to_last":
			# First advance generates +2cr — reward having advanceable agendas
			# and a healthy credit base to keep advancing every turn.
			for remote in s.get("remotes", []) as Array:
				var r: Dictionary = remote as Dictionary
				if r.get("has_agenda", false) and (r.get("adv", 0) as int) == 0:
					# Unadvanced agenda: first advance will be free (net +1cr).
					score += 1.5
			# Slight credit floor bonus — Weyland wants to keep pressing advances.
			if corp_cr >= 4:
				score += 0.5

		"haas_bioroid_precision_design":
			# +1 max hand size already captured via hand_limit=6 above.
			# Archives-to-HQ recovery on score: each scored agenda has residual
			# value because a card was recovered — approximate as +0.5 per point.
			score += float(corp_score) * 0.5
			# Reward having a non-empty Archives (cards to recover on next score).
			var discard_sz: int = s.get("corp_discard_sz", 0) as int
			if discard_sz > 0:
				score += 0.4

		"jinteki_replicating_perfection":
			# Runner must run a central before running any remote.
			# Reward having centrals iced (forces runner to spend resources before
			# accessing remotes, making remotes much safer).
			# This is captured by the existing central ice score, but amplify it.
			score += float(s.get("hq_ice", 0)) * 0.5   # extra on top of base 1.5
			score += float(s.get("rd_ice", 0)) * 0.5
			# Unprotected remotes are safer than they look — reduce the implicit
			# penalty for having an agenda with no ice.
			# (already handled by reduced ice_bonus_per_layer above)

		"jinteki_restoring_humanity":
			# Gain 1cr at end of discard phase if Archives has a facedown card.
			# Model as passive income: small bonus when Archives is non-empty.
			var discard_sz: int = s.get("corp_discard_sz", 0) as int
			if discard_sz > 0:
				score += 0.7   # ~1 extra credit per turn when discarding to limit

	return score


# ── Corp action projection ────────────────────────────────────────────────────

# Returns a new SimState after the Corp plays one click action.
# Does NOT create or modify live GameContext state.
func project_corp_action(s: Dictionary, action: GameAction, _ctx: GameContext) -> Dictionary:
	var ns: Dictionary = s.duplicate(true)
	var identity: String = s.get("corp_identity", "") as String

	match action.type:
		"gain_credits":
			# Corp gains exactly 1 credit per click — do not overestimate.
			ns["corp_credits"] = (s.get("corp_credits", 0) as int) + 1

		"draw_card":
			# Cap at hand_limit — drawing past limit means discarding, net zero benefit.
			var hand_limit: int = s.get("corp_hand_limit", 5) as int
			ns["corp_hand"] = min((s.get("corp_hand", 0) as int) + 1, hand_limit)
			ns["corp_deck"] = max(0, (s.get("corp_deck", 0) as int) - 1)

		"install":
			var card: CardRecord = action.params.get("card_record", null) as CardRecord
			if card == null:
				return ns
			# Always costs 1 card from hand.
			ns["corp_hand"] = max(0, (s.get("corp_hand", 0) as int) - 1)

			if card.is_ice():
				# Ice install cost = 1 credit per ice already on the target server.
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
				# Update ice coverage
				match server_id:
					"hq": ns["hq_ice"] = (s.get("hq_ice", 0) as int) + 1
					"rd": ns["rd_ice"] = (s.get("rd_ice", 0) as int) + 1
					_:
						var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
						for i in range(remotes_copy.size()):
							var r: Dictionary = (remotes_copy[i] as Dictionary).duplicate()
							if r.get("server_id", "") == server_id:
								r["ice_count"] = (r.get("ice_count", 0) as int) + 1
								remotes_copy[i] = r
								break
						ns["remotes"] = remotes_copy

			elif card.is_agenda():
				# Agendas install for free.
				# Project 1 ice layer if ice is in hand (Corp will protect next click).
				var proj_ice := 0
				if _ctx != null:
					for hentry in _ctx.corp_hand:
						var hc: CardRecord = (hentry as Dictionary).get("card_record", null) as CardRecord
						if hc != null and hc.is_ice():
							proj_ice = 1
							break
				# ── Jinteki: Replicating Perfection ──────────────────────────
				# Remote is passively safer; project it as if it already has 1
				# effective layer of protection even without physical ice.
				if identity == "jinteki_replicating_perfection":
					proj_ice = max(proj_ice, 1)
				var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
				remotes_copy.append({
					"server_id":  "projected",
					"ice_count":  proj_ice,
					"has_agenda": true,
					"adv":        0,
					"req":        card.advancement_requirement,
				})
				ns["remotes"] = remotes_copy
			# Assets/upgrades also install for free — no credit deduction needed.

		"advance":
			var adv_cost: int = 1
			var credit_gain: int = 0

			# ── Weyland: Built to Last ────────────────────────────────────────
			# First advance on a card (adv == 0) grants +2cr, making it a net
			# +1cr action rather than -1cr.  Find the target agenda's current
			# advancement counter to apply the bonus correctly.
			if identity == "weyland_consortium_built_to_last":
				for remote in s.get("remotes", []) as Array:
					var r: Dictionary = remote as Dictionary
					if r.get("has_agenda", false) and (r.get("adv", 0) as int) == 0:
						credit_gain = 2   # Built to Last triggers
						break

			ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - adv_cost + credit_gain)
			var remotes_copy: Array = (ns.get("remotes", []) as Array).duplicate(true)
			for i in range(remotes_copy.size()):
				var r: Dictionary = remotes_copy[i] as Dictionary
				if r.get("has_agenda", false):
					var new_r := r.duplicate()
					new_r["adv"] = (r.get("adv", 0) as int) + 1
					remotes_copy[i] = new_r
					break
			ns["remotes"] = remotes_copy

		"use_installed_card":
			# Approximate: installed click actions typically generate ~2 credits
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
					var dmg: int = max(1, ns.get("corp_score", 0) as int)
					ns["runner_hand"] = max(0, (ns.get("runner_hand", 0) as int) - dmg)
				_:
					# Generic operation: approximate value as 2cr-equivalent
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

	var runner_cr:  int = s.get("runner_credits", 0) as int
	var runner_rig: int = s.get("runner_rig",     0) as int

	# Estimate run success probability
	var success_prob: float = 0.0
	if runner_rig >= 1 and runner_cr >= 3:
		success_prob = clampf(0.7 - float(ice_count) * 0.15 + float(runner_cr) * 0.02, 0.1, 0.95)
	elif runner_cr >= 5:
		success_prob = clampf(0.5 - float(ice_count) * 0.10, 0.05, 0.70)

	# ── Jinteki: Replicating Perfection ──────────────────────────────────────
	# Runner must run a central before accessing any remote.  For centrals this
	# is unchanged.  For remotes it means the runner needs an extra run first,
	# spending credits and clicks — model as a large success-probability penalty.
	var is_remote_target := (threat_server not in ["hq", "rd"] and threat_server != "")
	if identity == "jinteki_replicating_perfection" and is_remote_target:
		success_prob = clampf(success_prob - 0.35, 0.0, 0.50)

	# Runner spends credits breaking ice
	var expected_spend: int = int(float(ice_count) * 2.5)
	ns["runner_credits"] = max(0, runner_cr - expected_spend)

	# On successful run, runner may steal an agenda.
	# "projected" remotes were just installed this turn — the Corp still has clicks
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
