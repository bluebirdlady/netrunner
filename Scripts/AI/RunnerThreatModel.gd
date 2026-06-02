class_name RunnerThreatModel
extends RefCounted

# ── RunnerThreatModel ─────────────────────────────────────────────────────────
# Estimates runner threat to each Corp server based solely on observable board
# state.  Used by CorpTurnAI_Tactical to weight defensive action candidates.
#
# All estimators are heuristic — no deck knowledge is required.
# BayesianRunnerModel extends this class with probabilistic deck modeling.


# Returns 0.0–1.0: likelihood the runner successfully accesses the given server
# on their upcoming turn.
func threat(server_id: String, ctx: GameContext) -> float:
	var willingness: float = _run_willingness(ctx)
	var capability:  float = _estimate_run_success(server_id, ctx)
	return clampf(willingness * capability, 0.0, 1.0)


# Returns the server_id the runner most threatens right now.
func most_threatened_server(ctx: GameContext) -> String:
	var best_id:    String = "hq"
	var best_score: float  = -1.0

	for server_id in ctx.servers:
		var s: Server = ctx.servers[server_id] as Server
		if not s.is_remote() and server_id not in ["hq", "rd"]:
			continue
		var t: float = threat(server_id, ctx)
		if t > best_score:
			best_score = t
			best_id    = server_id

	return best_id


# ── Observable estimators ─────────────────────────────────────────────────────

func _run_willingness(ctx: GameContext) -> float:
	var score := 0.5   # neutral baseline

	# Economy pressure
	if   ctx.runner_credits >= 8: score += 0.20
	elif ctx.runner_credits >= 5: score += 0.10
	elif ctx.runner_credits <= 2: score -= 0.20

	# Agenda proximity — runner pushes harder when close to winning
	var pts_needed: int = ctx.agenda_points_to_win - ctx.runner_agenda_points()
	if   pts_needed <= 2: score += 0.20
	elif pts_needed <= 4: score += 0.10

	# Corp closing in — runner must act now
	var corp_pts_needed: int = ctx.agenda_points_to_win - ctx.corp_agenda_points()
	if corp_pts_needed <= 2: score += 0.15

	return clampf(score, 0.0, 1.0)


func _estimate_run_success(server_id: String, ctx: GameContext) -> float:
	var server: Server = ctx.get_server(server_id)
	if server == null:
		return 0.0

	var ice_count:   int = server.ice.size()
	var runner_cr:   int = ctx.runner_credits
	var breakers:    int = _count_installed_breakers(ctx)
	var ai_breakers: int = _count_ai_breakers(ctx)

	# Base capability from rig
	var base: float
	if ai_breakers > 0:
		base = 0.75
	elif breakers >= 3:
		base = 0.80
	elif breakers >= 2:
		base = 0.65
	elif breakers >= 1:
		base = 0.45
	else:
		base = 0.20   # unrigged runner relies on events

	base -= float(ice_count) * 0.12

	# Credit adjustment
	if   runner_cr >= 8: base += 0.10
	elif runner_cr <= 2: base -= 0.15

	# Subtype mismatch penalty: for each ice type on this server the runner's
	# installed rig cannot break, reduce success probability by 0.20.
	# AI breakers cover all subtypes and skip this check entirely.
	if ai_breakers == 0 and breakers > 0:
		var breaker_types := _breaker_subtypes_installed(ctx)
		var srv_subtypes  := _server_ice_subtypes(server)
		if srv_subtypes["barrier"]   and not breaker_types.get("fracter", false):
			base -= 0.20
		if srv_subtypes["sentry"]    and not breaker_types.get("killer",  false):
			base -= 0.20
		if srv_subtypes["code_gate"] and not breaker_types.get("decoder", false):
			base -= 0.20

	# Agenda in root: normally increases run motivation.
	# BANGUN exception: faceup agendas are traps — accessing them costs 2 meat + 1 tag.
	# Penalise heavily if the runner can't absorb the damage.
	if server.is_remote():
		for c in server.root:
			var ic: InstalledCard = c as InstalledCard
			if ic != null and ic.card_record != null and ic.card_record.is_agenda():
				if ic.is_face_up and ctx.corp_identity != null and \
						ctx.corp_identity.id == "bangun_when_disaster_strikes":
					# Deterrent: subtract instead of add, scaled by grip size
					var grip_size: int = ctx.runner_hand.size()
					if grip_size <= 2:
						base -= 0.35   # very likely to flatline
					elif grip_size <= 4:
						base -= 0.20
					else:
						base -= 0.08   # survivable but still costly
				else:
					base += 0.15
				break

	return clampf(base, 0.0, 1.0)


func _count_installed_breakers(ctx: GameContext) -> int:
	var count := 0
	for card in ctx.runner_rig:
		var ic: InstalledCard = card as InstalledCard
		if ic != null and ic.card_record != null:
			if ic.card_record.has_subtype("fracter") or \
			   ic.card_record.has_subtype("killer")  or \
			   ic.card_record.has_subtype("decoder"):
				count += 1
	return count


func _count_ai_breakers(ctx: GameContext) -> int:
	var count := 0
	for card in ctx.runner_rig:
		var ic: InstalledCard = card as InstalledCard
		if ic != null and ic.card_record != null and ic.card_record.has_subtype("ai"):
			count += 1
	return count


# Estimate the runner rig's overall power relative to a "full rig" of 3.
# Returns 0.0 (no rig) to 1.0 (fully rigged).
func _estimate_breaker_power(ctx: GameContext) -> float:
	var ai: int = _count_ai_breakers(ctx)
	if ai > 0:
		return 0.8
	return clampf(float(_count_installed_breakers(ctx)) / 3.0, 0.0, 1.0)


# Returns which standard breaker subtypes are present in the runner rig.
# Used to cross-reference against server ice subtypes.
func _breaker_subtypes_installed(ctx: GameContext) -> Dictionary:
	var result := {"fracter": false, "killer": false, "decoder": false, "ai": false}
	for card in ctx.runner_rig:
		var ic: InstalledCard = card as InstalledCard
		if ic == null or ic.card_record == null:
			continue
		# Use `if` (not `elif`) so a card with multiple subtypes is captured fully.
		if ic.card_record.has_subtype("ai"):       result["ai"]      = true
		if ic.card_record.has_subtype("fracter"):  result["fracter"] = true
		if ic.card_record.has_subtype("killer"):   result["killer"]  = true
		if ic.card_record.has_subtype("decoder"):  result["decoder"] = true
	return result


# Returns which standard ice subtypes are present on a server.
# The Corp knows its own ice regardless of rez status — card_record is always set.
func _server_ice_subtypes(server: Server) -> Dictionary:
	var result := {"barrier": false, "sentry": false, "code_gate": false}
	for ic in server.ice:
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null:
			continue
		if c.card_record.has_subtype("barrier"):   result["barrier"]   = true
		if c.card_record.has_subtype("sentry"):    result["sentry"]    = true
		if c.card_record.has_subtype("code_gate"): result["code_gate"] = true
	return result
