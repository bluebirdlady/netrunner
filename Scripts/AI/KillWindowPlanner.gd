class_name KillWindowPlanner
extends RefCounted

# ── KillWindowPlanner ─────────────────────────────────────────────────────────
# Detects lethal damage lines: sequences of Corp operations that flatline the
# runner THIS TURN.
#
# Checked at the very start of Phase_Main, before scoring or economy decisions.
# Returns [] when no kill is possible so the caller falls through normally.
#
# Supported kill patterns (evaluated in priority order):
#
#   1. Neurospike chain (immediate)
#      Condition: Corp already scored an agenda this turn
#                 (ctx.corp_last_scored_agenda_points > 0)
#      Damage: corp_last_scored_agenda_points net × number of affordable Spikes
#
#   2. Measured Response (immediate)
#      Condition: threat_level >= 4 AND runner ran successfully last turn
#      Damage: 4 meat (runner may pay 8cr to cancel; conservative — only
#              counted as lethal when runner cannot afford the payout)
#
#   3. Score-then-Spike combo
#      Condition: have an agenda in a protected remote (needed > 0 allowed —
#                 we have enough clicks to advance it to scoring AND spike)
#                 AND enough Neurospikes for lethal after scoring
#      Sequence: advance × needed, then Neurospike × n
#
# Does NOT invoke AbilityInterpreter — all conditions are read directly from
# GameContext fields.

const NEUROSPIKE_ID        := "neurospike"
const MEASURED_RESPONSE_ID := "measured_response"


# ── Public API ────────────────────────────────────────────────────────────────

# Returns line[0] or null when no kill line exists.
static func first_action(ctx: GameContext) -> GameAction:
	var line: Array = find_kill_line(ctx)
	return line[0] if not line.is_empty() else null


# Returns the full ordered kill sequence (Array[GameAction]), or [].
# Caller executes line[0] then re-queries each click (triggers may fire).
static func find_kill_line(ctx: GameContext) -> Array:
	var runner_grip: int = ctx.runner_hand.size()
	if runner_grip <= 0:
		return []   # already dead — nothing to do

	# ── Pattern 1: Neurospike chain (already scored this turn) ──────────────
	if ctx.corp_last_scored_agenda_points > 0:
		var spike_line: Array = _neurospike_chain(runner_grip, ctx)
		if not spike_line.is_empty():
			return spike_line

	# ── Pattern 2: Measured Response ─────────────────────────────────────────
	var mr_line: Array = _measured_response_kill(runner_grip, ctx)
	if not mr_line.is_empty():
		return mr_line

	# ── Pattern 3: Score-then-Spike combo ────────────────────────────────────
	# Need at least 2 clicks: 1 to advance/score + 1 to spike.
	if ctx.corp_clicks >= 2:
		var combo_line: Array = _score_then_spike(runner_grip, ctx)
		if not combo_line.is_empty():
			return combo_line

	return []


# ── Pattern implementations ───────────────────────────────────────────────────

# Build a chain of Neurospike plays when the Corp has already scored this turn.
static func _neurospike_chain(runner_grip: int, ctx: GameContext) -> Array:
	var dmg_per_spike: int = ctx.corp_last_scored_agenda_points
	if dmg_per_spike <= 0:
		return []

	# Collect all affordable Neurospikes from hand.
	var spikes: Array = _collect_ops(ctx, NEUROSPIKE_ID)
	if spikes.is_empty():
		return []

	# Check if chaining them delivers lethal damage.
	var total_dmg: int = dmg_per_spike * spikes.size()
	if total_dmg < runner_grip:
		return []

	# Trim to minimum spikes needed to kill.
	var line: Array = []
	var dealt: int  = 0
	for spike in spikes:
		line.append(GameAction.play_operation(spike as CardRecord))
		dealt += dmg_per_spike
		if dealt >= runner_grip:
			break

	return line


# Measured Response: 4 meat damage unless runner pays 8cr.
# Only treat as lethal when runner cannot afford the payout — otherwise
# the damage isn't guaranteed and we don't commit the kill click.
static func _measured_response_kill(runner_grip: int, ctx: GameContext) -> Array:
	if runner_grip > 4:
		return []   # MR caps at 4 meat; irrelevant if grip is larger
	if ctx.threat_level() < 4:
		return []
	if not ctx.runner_made_successful_run_last_turn:
		return []
	# Only commit as a kill when the runner cannot pay the 8cr avoidance cost.
	if ctx.runner_credits >= 8:
		return []

	var mr_ops: Array = _collect_ops(ctx, MEASURED_RESPONSE_ID)
	if mr_ops.is_empty():
		return []

	# Single MR deals 4 meat; if runner_grip > 4 we already returned above.
	return [GameAction.play_operation(mr_ops[0] as CardRecord)]


# Score an installed agenda (spending clicks to advance it) then play Neurospike(s).
# The spike damage = agenda.agenda_points (set as corp_last_scored_agenda_points
# by the engine when the agenda is scored).
static func _score_then_spike(runner_grip: int, ctx: GameContext) -> Array:
	var spikes: Array = _collect_ops(ctx, NEUROSPIKE_ID)
	if spikes.is_empty():
		return []

	# Find the agenda with the fewest advances needed that still delivers lethal.
	var best_line: Array  = []
	var best_cost: int    = 9999   # clicks needed (lower = better)

	for server in ctx.servers.values():
		var s: Server = server as Server
		if s == null or not s.is_remote():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c == null or c.card_record == null or not c.card_record.is_agenda():
				continue
			var adv:    int = c.get_counter("advancement")
			var req:    int = c.card_record.advancement_requirement
			var needed: int = req - adv
			var pts:    int = c.card_record.agenda_points

			if pts <= 0:
				continue   # 0-point agenda can't Neurospike-kill

			# Credits needed: 1 per advance click (Neurospike is free).
			var cred_needed: int = needed   # one credit per advance
			if ctx.corp_credits < cred_needed:
				continue

			# Clicks needed: advances + spikes.
			var spikes_needed: int = (runner_grip + pts - 1) / pts   # ceiling div
			if spikes_needed > spikes.size():
				continue   # don't have enough Neurospikes

			var clicks_needed: int = needed + spikes_needed
			if ctx.corp_clicks < clicks_needed:
				continue   # not enough clicks

			# This is a viable kill — prefer fewer total clicks.
			if clicks_needed < best_cost:
				best_cost = clicks_needed
				var line: Array = []
				for _i in range(needed):
					line.append(GameAction.advance(c.card_id))
				var dealt: int = 0
				for spike in spikes:
					line.append(GameAction.play_operation(spike as CardRecord))
					dealt += pts
					if dealt >= runner_grip:
						break
				best_line = line

	return best_line


# ── Helpers ───────────────────────────────────────────────────────────────────

# Returns all affordable copies of a given operation card ID from the Corp hand.
static func _collect_ops(ctx: GameContext, op_id: String) -> Array:
	var result: Array   = []
	var running_cost: int = 0   # cumulative credit spend as we pick ops

	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card == null or card.card_type != "operation" or card.id != op_id:
			continue
		var op_cost: int = max(0, card.cost)
		if ctx.corp_credits - running_cost < op_cost:
			continue   # can't afford this copy after earlier ones
		running_cost += op_cost
		result.append(card)

	return result
