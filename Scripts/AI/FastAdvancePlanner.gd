class_name FastAdvancePlanner
extends RefCounted

# ── FastAdvancePlanner ────────────────────────────────────────────────────────
# Detects Corp scoring lines: the sequence of click actions needed to score
# an installed agenda this turn.
#
# A "scoring line" is an ordered Array[GameAction].  The caller should execute
# line[0], then re-query (in case triggers change state between clicks).
#
# What this understands:
#   1. Standard advancement (click → advance × N, each costing 1cr)
#   2. Operations that grant extra clicks (keyed by card id below)
#   3. Operations that place advancement counters directly
#
# Does NOT invoke AbilityInterpreter — all checks are structural.
# ─────────────────────────────────────────────────────────────────────────────

# Operations that grant extra clicks when played.
# Value = net extra clicks after paying the 1-click cost to play the operation.
# e.g. biotic_labor grants 2 clicks for 1 play-click → net +1.
const EXTRA_CLICK_OPS: Dictionary = {
	# "biotic_labor": 1,  # add when implemented
}

# Operations that place advancement counters on an installed card.
# Value = { counters: int, cost: int }
# Only include ops whose primary purpose is counter placement.
const ADV_COUNTER_OPS: Dictionary = {
	# populated as fast-advance operations are added to the game
}


# ── Public API ────────────────────────────────────────────────────────────────

# Returns line[0] (the next action in the scoring sequence), or null if no
# scoring line exists this turn.
static func first_action(ctx: GameContext) -> GameAction:
	var line: Array = find_scoring_line_this_turn(ctx)
	return line[0] if not line.is_empty() else null


# Returns the full scoring line or [] if no agenda can be scored this turn.
# The line includes any preparatory operation plays (extra clicks, counter ops)
# followed by the required number of advance actions.
static func find_scoring_line_this_turn(ctx: GameContext) -> Array:
	# Simulate the click and credit budget after playing any helpful operations.
	var sim_clicks:  int   = ctx.corp_clicks
	var sim_credits: int   = ctx.corp_credits
	var prep_ops:    Array = []

	# Check hand for click-granting or counter-placing operations.
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card == null or card.card_type != "operation":
			continue
		var op_cost: int = max(0, card.cost)
		if card.id in EXTRA_CLICK_OPS and sim_credits >= op_cost:
			var net_clicks: int = EXTRA_CLICK_OPS[card.id] as int
			sim_clicks  += net_clicks   # net = gained − 1 (play cost already in net)
			sim_credits -= op_cost
			prep_ops.append(GameAction.play_operation(card))
		elif card.id in ADV_COUNTER_OPS and sim_credits >= op_cost:
			# Counter-placing ops are handled in _agenda_scoring_line below.
			pass

	# Find the installed agenda that can be scored soonest.
	var best_line:   Array = []
	var best_needed: int   = 9999

	for server in ctx.servers.values():
		var s: Server = server as Server
		if s == null or not s.is_remote():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c == null or c.card_record == null or not c.card_record.is_agenda():
				continue
			var line: Array = _agenda_scoring_line(c, sim_clicks, sim_credits, prep_ops, ctx)
			if line.is_empty():
				continue
			# Count how many advance actions are in this line (shorter = better).
			var adv_count: int = 0
			for a in line:
				if (a as GameAction).type == "advance":
					adv_count += 1
			if adv_count < best_needed:
				best_needed = adv_count
				best_line   = line

	return best_line


# Returns the number of full Corp turns until the nearest installed agenda can
# be scored, assuming 3 clicks per turn for pure advancement.
#   0  = can score this turn with remaining clicks
#   1  = can score next turn (≤ 3 more advances needed)
#   n  = n full turns needed
#  -1  = no installed agenda
static func turns_to_score(ctx: GameContext) -> int:
	var min_turns: int = 9999
	var found: bool    = false

	for server in ctx.servers.values():
		var s: Server = server as Server
		if s == null or not s.is_remote():
			continue
		for card in s.root:
			var c: InstalledCard = card as InstalledCard
			if c == null or c.card_record == null or not c.card_record.is_agenda():
				continue
			found = true
			var adv:    int = c.get_counter("advancement")
			var req:    int = c.card_record.advancement_requirement
			var needed: int = req - adv
			if needed <= ctx.corp_clicks:
				return 0   # can score this turn — early out
			var remaining: int = needed - ctx.corp_clicks
			var turns: int = (remaining + 2) / 3   # ceiling division by 3
			if turns < min_turns:
				min_turns = turns

	return min_turns if found else -1


# ── Private helpers ───────────────────────────────────────────────────────────

# Tries to build a scoring line for a specific installed agenda given the
# simulated click/credit budget.  Returns [] if it cannot be scored this turn.
static func _agenda_scoring_line(
		c:          InstalledCard,
		sim_clicks: int,
		sim_creds:  int,
		prep_ops:   Array,
		ctx:        GameContext) -> Array:

	var adv:    int = c.get_counter("advancement")
	var req:    int = c.card_record.advancement_requirement
	var needed: int = req - adv

	if needed <= 0:
		# Already ready — single advance action scores it.
		return [GameAction.advance(c.card_id)]

	# Each standard advance costs 1 click + 1 credit.
	if sim_clicks >= needed and sim_creds >= needed:
		# Count credits from ADV_COUNTER_OPS already played in prep_ops.
		# (Those free up advance-clicks by placing counters, reducing needed.)
		# For now, no counter ops are implemented, so skip.
		var line: Array = prep_ops.duplicate()
		for _i in range(needed):
			line.append(GameAction.advance(c.card_id))
		return line

	return []
