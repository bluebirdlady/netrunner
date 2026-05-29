class_name CorpStateEvaluator
extends RefCounted

# ── CorpStateEvaluator ────────────────────────────────────────────────────────
# Converts a live GameContext into a lightweight SimState snapshot and
# evaluates it from the Corp's perspective.  All projection methods are
# approximate first-order effects — they do not invoke the real TurnManager.
#
# SimState Dictionary schema
# ─────────────────────────────────────────────────────────────────────────────
#   corp_credits   : int
#   runner_credits : int
#   corp_score     : int   — agenda points
#   runner_score   : int
#   pts_to_win     : int
#   turn_number    : int
#   runner_hand    : int   — grip size
#   corp_hand      : int
#   corp_deck      : int
#   runner_deck    : int
#   runner_tags    : int
#   runner_rig     : int   — total installed runner cards
#   hq_ice         : int
#   rd_ice         : int
#   remotes        : Array[Dictionary]
#                    each: { server_id, ice_count, has_agenda, adv, req }

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

	return {
		"corp_credits":   ctx.corp_credits,
		"runner_credits": ctx.runner_credits,
		"corp_score":     ctx.corp_agenda_points(),
		"runner_score":   ctx.runner_agenda_points(),
		"pts_to_win":     ctx.agenda_points_to_win,
		"turn_number":    ctx.turn_number,
		"runner_hand":    ctx.runner_hand.size(),
		"corp_hand":      ctx.corp_hand.size(),
		"corp_deck":      ctx.corp_deck.size(),
		"runner_deck":    ctx.runner_deck.size(),
		"runner_tags":    ctx.runner_tags,
		"runner_rig":     ctx.runner_rig.size(),
		"hq_ice":         hq_server.ice.size() if hq_server != null else 0,
		"rd_ice":         rd_server.ice.size() if rd_server != null else 0,
		"remotes":        remotes,
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

	var score := 0.0

	# Progress toward winning (runner penalty is steeper — losing is worse)
	score += float(corp_score)   / float(pts_to_win) * 30.0
	score -= float(runner_score) / float(pts_to_win) * 42.0

	# Economy
	score += float(s.get("corp_credits",   0)) * 0.5
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
		if   needed <= 0: score += 8.0
		elif needed == 1: score += 4.0
		elif needed == 2: score += 2.0
		score += float(min(ice, 2)) * 1.0

	# Runner tags — Corp can punish
	score += float(s.get("runner_tags", 0)) * 2.0

	# Corp hand size penalty
	var corp_hand: int = s.get("corp_hand", 0) as int
	if corp_hand < 3:
		score -= float(3 - corp_hand) * 1.0

	return score


# ── Corp action projection ────────────────────────────────────────────────────

# Returns a new SimState after the Corp plays one click action.
# Does NOT create or modify live GameContext state.
func project_corp_action(s: Dictionary, action: GameAction, _ctx: GameContext) -> Dictionary:
	var ns: Dictionary = s.duplicate(true)

	match action.type:
		"gain_credits":
			# Corp gains exactly 1 credit per click — do not overestimate.
			ns["corp_credits"] = (s.get("corp_credits", 0) as int) + 1

		"draw_card":
			ns["corp_hand"] = (s.get("corp_hand", 0) as int) + 1
			ns["corp_deck"] = max(0, (s.get("corp_deck", 0) as int) - 1)

		"install":
			var card: CardRecord = action.params.get("card_record", null) as CardRecord
			if card == null:
				return ns
			# Always costs 1 card from hand.
			ns["corp_hand"] = max(0, (s.get("corp_hand", 0) as int) - 1)

			if card.is_ice():
				# Ice install cost = 1 credit per ice already on the target server.
				# card.cost is the REZ cost, which has nothing to do with install cost.
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
				# Agendas install for free — card.cost is irrelevant here.
				# If the Corp has ICE in hand it can protect the new remote next click,
				# so project it with 1 layer of ice to avoid heavily penalising the
				# install in the runner-response step.
				var proj_ice := 0
				if _ctx != null:
					for hentry in _ctx.corp_hand:
						var hc: CardRecord = (hentry as Dictionary).get("card_record", null) as CardRecord
						if hc != null and hc.is_ice():
							proj_ice = 1
							break
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
			ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - 1)
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
			# Deduct cost first, then apply the card's specific gain on top.
			ns["corp_credits"] = max(0, (s.get("corp_credits", 0) as int) - cost)
			ns["corp_hand"]    = max(0, (s.get("corp_hand",    0) as int) - 1)
			match card.id:
				"hedge_fund":
					# Costs 5, gains 9 — net +4 on top of post-cost baseline
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 9
				"government_subsidy":
					# Costs 3, gains 14 — net +11
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 14
				"predictive_planogram":
					# Corp path: gain 3 credits (conservative; could also draw 3)
					ns["corp_credits"] = (ns.get("corp_credits", 0) as int) + 3
				"hansei_review":
					# Corp draws 4, runner gains 2 credits
					ns["corp_hand"]    = (ns.get("corp_hand",    0) as int) + 4
					ns["runner_credits"] = (ns.get("runner_credits", 0) as int) + 2
				"spin_doctor":
					# Draw 2, shuffle 2 from Archives back to R&D
					ns["corp_hand"] = (ns.get("corp_hand", 0) as int) + 2
					ns["corp_deck"] = (ns.get("corp_deck", 0) as int) + 2
				"neurospike":
					# Deal corp_score net damage; clamp to runner grip
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

	var runner_cr:  int   = s.get("runner_credits", 0) as int
	var runner_rig: int   = s.get("runner_rig",     0) as int

	# Estimate run success probability
	var success_prob: float = 0.0
	if runner_rig >= 1 and runner_cr >= 3:
		success_prob = clampf(0.7 - float(ice_count) * 0.15 + float(runner_cr) * 0.02, 0.1, 0.95)
	elif runner_cr >= 5:
		success_prob = clampf(0.5 - float(ice_count) * 0.10, 0.05, 0.70)

	# Runner spends credits breaking ice
	var expected_spend: int = int(float(ice_count) * 2.5)
	ns["runner_credits"] = max(0, runner_cr - expected_spend)

	# On successful run, runner may steal an agenda
	if success_prob > 0.5:
		var has_agenda := false
		if threat_server in ["hq", "rd"]:
			has_agenda = (s.get("corp_deck", 0) as int) > 0
		else:
			for remote in s.get("remotes", []) as Array:
				if (remote as Dictionary).get("server_id", "") == threat_server:
					has_agenda = (remote as Dictionary).get("has_agenda", false) as bool
					break

		if has_agenda:
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
