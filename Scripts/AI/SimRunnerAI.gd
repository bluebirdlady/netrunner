class_name SimRunnerAI
extends RefCounted

# ── SimRunnerAI ───────────────────────────────────────────────────────────────
# Lightweight synchronous Runner decision maker for simulation rollouts.
# Every method returns immediately — no awaits, no signals, no UI.
#
# Heuristic priority for choose_action:
#   1. Run a remote server if it contains an accessible agenda and credits allow
#   2. Gain credits if below threshold
#   3. Draw if hand is small and stack is non-empty
#   4. Install first program from hand if any
#   5. Gain credits (fallback)

const CREDIT_THRESHOLD          := 5
const MIN_HAND_SIZE             := 3
const CAMPAIGN_CREDIT_THRESHOLD := 8   # more aggressive economy in campaign mode
const CAMPAIGN_MIN_HAND_SIZE    := 4

# Pure economy events: safe to play whenever credits are below threshold.
# Excludes draw events (Diesel), run events, and events with adversarial choices (Wildcat Strike).
const ECONOMY_EVENT_IDS := [
	"sure_gamble", "hedge_fund", "lucky_find", "bravado", "creative_commission"
]
# Approximate net credit gain for ranking; unlisted events default to 2.
const ECONOMY_EVENT_NET_GAIN := {
	"sure_gamble": 4, "hedge_fund": 4, "lucky_find": 6, "bravado": 4, "creative_commission": 3
}
# Run-enhancing events keyed to their mandatory target server ("" = any server).
# These are played AS the run action, not before it.
const RUN_EVENT_SERVERS := {
	"legwork":            "hq",
	"wanton_destruction": "hq",
	"the_makers_eye":     "rd",
	"dirty_laundry":      "",
}
# ICE subtype → required breaker subtype for coverage checks.
const ICE_TO_BREAKER := {"barrier": "fracter", "code_gate": "decoder", "sentry": "killer"}

# When true, SimRunnerAI acts as a live campaign opponent: plays events,
# installs programs, and runs both centrals and remotes.
# When false (default), optimises for MCTS rollout speed: no installs, no events.
var campaign_runner_mode: bool = false

# Lazy-initialised; only created when campaign_runner_mode is first used.
var _evaluator: RunnerStateEvaluator = null
var _planner:   RunnerTurnPlanner    = null


# ── Turn-time interface ───────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
	if campaign_runner_mode:
		return _campaign_choose_action(ctx)

	# ── MCTS rollout path (fast, no installs) ─────────────────────────────────
	# 1. Run a vulnerable remote (agenda present, affordable or unprotected).
	var target := _find_run_target(ctx)
	if target != "":
		return GameAction.run(target)

	# 2. Gain credits if below threshold.
	if ctx.runner_credits < CREDIT_THRESHOLD:
		return GameAction.gain_credits()

	# 3. Draw if hand is small.
	if ctx.runner_hand.size() < MIN_HAND_SIZE and not ctx.runner_deck.is_empty():
		return GameAction.draw_card()

	# 4. Do NOT install programs in simulation rollouts.
	# SimRunnerAI never breaks ice (choose_encounter_action returns "done"),
	# so installed programs have no effect on rollout outcomes. Installing
	# them burns expensive _register_card_listeners + notify_event calls on
	# every rollout click — tens of thousands per MCTS choose_action call.
	# Skip installs and gain credits instead; rollout fidelity is unchanged.

	# 5. Fallback.
	return GameAction.gain_credits()


# ── Campaign mode action selection ────────────────────────────────────────────

func _campaign_choose_action(ctx: GameContext) -> GameAction:
	# Delegate to the turn planner, which evaluates all remaining clicks as a
	# unit via beam search and returns the first action of the best sequence.
	if _evaluator == null:
		_evaluator = RunnerStateEvaluator.new()
	if _planner == null:
		_planner = RunnerTurnPlanner.new(_evaluator)
	var snap: Dictionary = _evaluator.snapshot(ctx)
	if (snap.get("runner_clicks_left", 0) as int) <= 0:
		return GameAction.gain_credits()
	return _planner.plan_first_action(snap, ctx)


func _find_economy_event(ctx: GameContext) -> GameAction:
	# Play the highest net-gain affordable economy event from hand.
	var best_record: CardRecord = null
	var best_net: int = -999
	for entry in ctx.runner_hand:
		var ed: Dictionary = entry as Dictionary
		var record: CardRecord = ed.get("card_record", null) as CardRecord
		if record == null or record.card_type != "event":
			continue
		if record.id not in ECONOMY_EVENT_IDS:
			continue
		var cost: int = record.cost if record.cost >= 0 else 0
		if cost > ctx.runner_credits:
			continue
		var net: int = ECONOMY_EVENT_NET_GAIN.get(record.id, 2)
		if net > best_net:
			best_net    = net
			best_record = record
	if best_record != null:
		return GameAction.play_operation(best_record)
	return null


func _find_run_event_for_server(ctx: GameContext, server_id: String) -> GameAction:
	# Returns a run-enhancing event to play AS the run action on the given server.
	# Events with target "" work on any server (e.g. Dirty Laundry).
	for entry in ctx.runner_hand:
		var ed: Dictionary = entry as Dictionary
		var record: CardRecord = ed.get("card_record", null) as CardRecord
		if record == null or record.card_type != "event":
			continue
		if not RUN_EVENT_SERVERS.has(record.id):
			continue
		var cost: int = record.cost if record.cost >= 0 else 0
		if cost > ctx.runner_credits:
			continue
		var target: String = RUN_EVENT_SERVERS[record.id] as String
		if target == "" or target == server_id:
			return GameAction.play_operation(record)
	return null


func _find_central_run_target(ctx: GameContext) -> String:
	# Prefer R&D, then HQ; skip servers where we lack breaker coverage (campaign mode).
	for server_id in ["rd", "hq"]:
		if server_id in ctx.runner_centrals_run_this_turn:
			continue
		if campaign_runner_mode:
			var s: Server = ctx.servers.get(server_id, null) as Server
			if s != null and not _can_runner_break_server(s, ctx):
				continue
		return server_id
	return ""


func _count_installed_programs(ctx: GameContext) -> int:
	var count := 0
	for ic in ctx.runner_rig:
		var c: InstalledCard = ic as InstalledCard
		if c != null and c.card_record != null and c.card_record.card_type == "program":
			count += 1
	return count


func _find_installable_program(ctx: GameContext) -> GameAction:
	# Score candidates by gap-filling priority:
	#   2 = fills a missing breaker type against currently rezzed ICE
	#   1 = any icebreaker subtype (future proofing)
	#   0 = utility program (Rezeki, etc.)
	# Within the same score tier, prefer lower cost.

	# Build the set of breaker subtypes already installed.
	var covered: Array = []
	for rig_any in ctx.runner_rig:
		var b: InstalledCard = rig_any as InstalledCard
		if b == null or b.card_record == null or b.card_record.card_type != "program":
			continue
		for sub in b.card_record.subtypes:
			if sub not in covered:
				covered.append(sub)

	# Determine which breaker subtypes are actually needed (rezzed ICE present, no matching breaker).
	var needed: Array = []
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s == null:
			continue
		for ice_any in s.ice:
			var ic: InstalledCard = ice_any as InstalledCard
			if ic == null or not ic.is_rezzed or ic.card_record == null:
				continue
			for subtype in ic.card_record.subtypes:
				var req: String = ICE_TO_BREAKER.get(subtype, "")
				if req != "" and req not in covered and req not in needed:
					needed.append(req)

	var best_record: CardRecord = null
	var best_score: int = -1
	var best_cost: int = 999
	for entry in ctx.runner_hand:
		var ed: Dictionary = entry as Dictionary
		var record: CardRecord = ed.get("card_record", null) as CardRecord
		if record == null or record.card_type != "program":
			continue
		var cost: int = record.cost if record.cost >= 0 else 0
		if cost > ctx.runner_credits:
			continue
		var score := 0
		for sub in record.subtypes:
			if sub in needed:
				score = 2
				break
			if sub in ["fracter", "decoder", "killer", "ai"]:
				score = maxi(score, 1)
		if score > best_score or (score == best_score and cost < best_cost):
			best_score  = score
			best_cost   = cost
			best_record = record
	if best_record != null:
		return GameAction.install(best_record, "runner_rig", "program")
	return null


func get_pre_click_rez_actions(_ctx: GameContext) -> Array:
	return []


# ── Run-time interface ────────────────────────────────────────────────────────

func choose_jack_out(_ctx: GameContext) -> bool:
	# Never jack out mid-run in campaign mode — run quality is filtered at choose_action
	# time by _can_runner_break_server before the run starts.
	return false


func choose_encounter_action(encounter: EncounterState, ctx: GameContext) -> Dictionary:
	if campaign_runner_mode:
		return _campaign_choose_encounter_action(encounter, ctx)

	# ── MCTS rollout path ─────────────────────────────────────────────────────
	# MS-L004: Use Endurance to break remaining subs if it has ≥2 power counters
	# and there are unbroken subroutines. Only as a last resort in simulation rollouts.
	var unbroken: Array = encounter.unbroken_indices()
	if not unbroken.is_empty():
		for rig_card in ctx.runner_rig:
			var hw: InstalledCard = rig_card as InstalledCard
			if hw == null or hw.card_id != "endurance":
				continue
			if hw.get_counter("power") >= 2:
				# Break up to 2 unbroken subs per use
				var to_break: Array = unbroken.slice(0, mini(2, unbroken.size()))
				return {"type": "hardware_break", "card_id": "endurance", "sub_indices": to_break}
	# Uprising: F2P — if not tagged and affordable, pay 2cr to break 1 sub.
	if not unbroken.is_empty() and not ctx.runner_is_tagged():
		var f2p_def: Dictionary = {}
		if ctx.has_meta("ability_registry"):
			var f2p_ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
			var f2p_card_def: Dictionary = f2p_ab_reg._abilities.get(encounter.ice_card.card_id, {}) as Dictionary
			f2p_def = f2p_card_def.get("runner_paid_break_ability", {}) as Dictionary
		if not f2p_def.is_empty():
			var f2p_cost: int = f2p_def.get("cost_credits", 2)
			var f2p_subs: int = f2p_def.get("subs_per_use", 1)
			if ctx.runner_available_credits() >= f2p_cost:
				return {"type": "f2p_break", "sub_indices": unbroken.slice(0, mini(f2p_subs, unbroken.size()))}

	# Default: pass all subroutines — simplest safe behaviour.
	return {"type": "done"}


# ── Campaign encounter action (subtype-aware) ─────────────────────────────────

func _campaign_choose_encounter_action(encounter: EncounterState, ctx: GameContext) -> Dictionary:
	var unbroken: Array = encounter.unbroken_indices()
	if unbroken.is_empty():
		return {"type": "done"}

	# EncounterState.breakers_for_ice() handles fracter/barrier, decoder/code_gate,
	# killer/sentry, ai/any, fracter_only_break restrictions, same_server_only
	# trojans, and runtime-granted extra subtypes. Use it as the single source of truth.
	var matched: Array = encounter.breakers_for_ice()
	if matched.is_empty():
		return {"type": "done"}

	for b in matched:
		var breaker: InstalledCard = b as InstalledCard
		if breaker == null:
			continue

		if encounter.breaker_reaches(breaker):
			# Breaker is at or above ICE strength — break the next unbroken sub.
			return {"type": "break_subroutine", "card_id": breaker.card_id, "sub_index": unbroken[0]}

		# Breaker is below ICE strength — try to pump it.
		var boost: Dictionary = _campaign_boost_action(breaker, encounter, ctx)
		if not boost.is_empty():
			return boost
		# This breaker can't be pumped enough; try the next matched breaker.

	return {"type": "done"}


func _campaign_boost_action(breaker: InstalledCard, encounter: EncounterState,
		ctx: GameContext) -> Dictionary:
	var ab_reg: AbilityRegistry = null
	if ctx.has_meta("ability_registry"):
		ab_reg = ctx.get_meta("ability_registry") as AbilityRegistry
	if ab_reg == null:
		return {}

	var boost_def: Variant = ab_reg.get_boost(breaker.card_id)
	if boost_def == null:
		return {}   # no boost ability at all

	var boost: Dictionary = boost_def as Dictionary
	var str_gap: int  = encounter.effective_ice_strength() - encounter.get_breaker_strength(breaker)
	if str_gap <= 0:
		return {}   # already reaches (caller should not have asked)

	var str_per_use: int = max(1, int(boost.get("strength_gained", 1)))
	var times: int       = int(ceil(float(str_gap) / float(str_per_use)))

	# ── Power-counter boost (e.g. Propeller: 1 counter → +2 str) ─────────────
	var pwr_cost: int = int(boost.get("cost_power_counter", 0))
	if pwr_cost > 0:
		if breaker.get_counter("power") >= pwr_cost * times:
			return {"type": "boost_strength", "card_id": breaker.card_id, "times": times}
		return {}

	# ── Virus-counter boost (e.g. Hantu: 1 virus → +2 str at 0cr cost) ──────
	var counter_type: String = boost.get("counter", "")
	if counter_type == "virus":
		if breaker.get_counter("virus") >= times:
			return {"type": "boost_strength", "card_id": breaker.card_id, "times": times}
		return {}

	# ── Standard credit boost (most icebreakers) ──────────────────────────────
	# Exclude stealth, grip-trash, and other exotic cost types — the AI cannot
	# easily sequence those without access to stealth credit pools or hand size checks.
	if boost.get("costs_stealth", false) or boost.has("cost_trash_grip"):
		return {}
	var cost: int = int(boost.get("cost", -1))
	if cost < 0:
		return {}   # unknown cost format
	var total_cost: int = cost * times
	if ctx.runner_available_credits() >= total_cost:
		return {"type": "boost_strength", "card_id": breaker.card_id, "times": times}

	return {}


func choose_break_subroutines(ice: InstalledCard, subs: Array, ctx: GameContext) -> Array:
	if not campaign_runner_mode:
		return []
	if ice == null or ice.card_record == null or subs.is_empty():
		return []

	# Replicate EncounterState._breaker_matches_ice logic without access to an
	# EncounterState instance. Merge printed and runtime-granted ICE subtypes.
	var ice_subtypes: Array = ice.card_record.subtypes.duplicate()
	for es in ice.extra_subtypes:
		if not ice_subtypes.has(es):
			ice_subtypes.append(es)

	const MATCHES: Dictionary = {"fracter": "barrier", "decoder": "code_gate", "killer": "sentry"}

	var has_match: bool = false
	for rig_card in ctx.runner_rig:
		var c: InstalledCard = rig_card as InstalledCard
		if c == null or c.card_record == null or c.card_record.card_type != "program":
			continue
		var b_subs: Array = c.card_record.subtypes
		for bt in MATCHES:
			if b_subs.has(bt) and ice_subtypes.has(MATCHES[bt]):
				has_match = true
				break
		if not has_match and b_subs.has("ai"):
			has_match = true
		if has_match:
			break

	if not has_match:
		return []

	var indices: Array = []
	for i in range(subs.size()):
		indices.append(i)
	return indices


func choose_spend_click_to_continue(ctx: GameContext) -> bool:
	# Spend the click to continue if available — almost always correct in simulation.
	return ctx.runner_clicks > 0


func choose_trigger_order(_triggers: Array, _ctx: GameContext) -> int:
	return 0


# ── Access / trash ────────────────────────────────────────────────────────────

func choose_trash(card: CardRecord, ctx: GameContext) -> bool:
	if card == null:
		return false
	return card.is_asset() and card.has_trash_cost() and ctx.runner_credits >= card.trash_cost


func choose_access_target(candidates: Array, _ctx: GameContext) -> Variant:
	return candidates[0] if not candidates.is_empty() else null


# ── Misc choices ──────────────────────────────────────────────────────────────

func choose_server(allowed_servers: Array, _ctx: GameContext) -> String:
	return allowed_servers[0] if not allowed_servers.is_empty() else "hq"


func choose_card_from_hand(hand: Array, _ctx: GameContext) -> Variant:
	return hand[0] if not hand.is_empty() else null


func choose_from_search(candidates: Array, _ctx: GameContext) -> CardRecord:
	return candidates[0] if not candidates.is_empty() else null


func choose_from_heap(candidates: Array, _ctx: GameContext) -> CardRecord:
	return candidates[0] if not candidates.is_empty() else null


func choose_modes(modes: Array, _max_choices: int, _ctx: GameContext) -> Array:
	return [modes[0]] if not modes.is_empty() else []


func choose_flip_identity(_ctx: GameContext) -> bool:
	return false


func choose_payment_option(options: Array, _ctx: GameContext) -> Variant:
	return options[0] if not options.is_empty() else "credits"


func choose_take_tag_or_end_run(_amount: int, _ctx: GameContext) -> bool:
	return false  # end the run


func choose_pay_to_avoid_tag(_cost: int, _ctx: GameContext) -> bool:
	return false


func choose_pay_to_avoid_damage(_cost: int, _damage: int, _damage_type: String, _ctx: GameContext) -> bool:
	return false


# ── Trace ──────────────────────────────────────────────────────────────────────

# Spend just enough credits to bring link+boost above the trace strength
# (i.e. make the trace fail), if affordable while keeping a small buffer;
# otherwise spend nothing.
func choose_trace_link_boost(trace_strength: int, link: int, ctx: GameContext) -> int:
	var needed: int = (trace_strength + 1) - link
	if needed <= 0:
		return 0
	if needed <= ctx.runner_credits:
		return needed
	return 0


# ── Pay-or-end-the-run ────────────────────────────────────────────────────────

# Pay to avoid ending the run if affordable while keeping a small credit buffer.
func choose_pay_to_avoid_etr(cost: int, ctx: GameContext) -> bool:
	return cost <= ctx.runner_credits


func choose_pay_shred_etr(_count: int, _ctx: GameContext) -> bool:
	return false


func choose_optional_ability(_prompt: String, _ctx: GameContext) -> bool:
	return false


func choose_yes_no(_prompt: String, _ctx: GameContext) -> bool:
	return false


# Uprising: Harmony AR Therapy — greedy first-N fallback for rollouts.
func choose_multiple_from_heap(candidates: Array, max_count: int, _ctx: GameContext) -> Array:
	if candidates.size() <= max_count:
		return candidates.duplicate()
	return candidates.slice(0, max_count)


# Uprising: Euler / Odore — prefer the free alt interface when it covers all
# unbroken subs in one activation, otherwise use the primary interface.
func choose_break_interface(_breaker: InstalledCard, _primary: Dictionary, alt: Dictionary,
		unbroken_count: int, _ctx: GameContext) -> int:
	if alt.get("cost_per_sub", 1) == 0 and unbroken_count <= alt.get("subs_per_use", 1):
		return 1
	return 0


func choose_psi_bid(max_bid: int, _ctx: GameContext) -> int:
	# Weighted toward 0: saves credits and is the most common human bid.
	var roll := randi() % 6   # 0-5
	if roll < 3:
		return 0
	elif roll < 5:
		return min(1, max_bid)
	else:
		return min(2, max_bid)


# ── AirbladeX (JSRF Ed.) interrupt decisions ─────────────────────────────────

# Sim default: don't spend counters on damage prevention (preserve for when-encountered).
func use_airbladex_prevent_net_damage(_damage_type: String, _amount_remaining: int,
		_ctx: GameContext) -> bool:
	return false


# Sim default: always prevent when-encountered abilities when counters are available.
func use_airbladex_prevent_when_encountered(_ice_card: InstalledCard,
		_ability_def: Dictionary, _ctx: GameContext) -> bool:
	return true


func choose_tags_to_remove(_max_count: int, _ctx: GameContext) -> int:
	return 0


func choose_install_faceup(_card_record: CardRecord, _ctx: GameContext) -> bool:
	return false


func choose_runner_card_type(types: Array, _ctx: GameContext) -> String:
	return types[0] if not types.is_empty() else ""


func choose_sabotage_discard(ctx: GameContext) -> Dictionary:
	if ctx.corp_hand.is_empty():
		return {}
	return {"source": "hand", "index": 0}


func choose_window_action(_ctx: GameContext, _actor: String, _can_rez_ice: bool) -> GameAction:
	return GameAction.pass_window()


func choose_host_ice(_ctx: GameContext) -> InstalledCard:
	return null


func choose_target_ice(candidates: Array, _card_name: String, _ctx: GameContext) -> InstalledCard:
	return candidates[0] if not candidates.is_empty() else null


func choose_ice_swap(_eligible_servers: Array, _ctx: GameContext) -> Variant:
	return null


func choose_carnivore(_card_record: CardRecord, _ctx: GameContext) -> bool:
	return false


func choose_spend_counter_amount(_card: InstalledCard, _counter_type: String, _max_amount: int, _ctx: GameContext) -> int:
	return 0


func choose_trash_from_rig(candidates: Array, _ctx: GameContext) -> InstalledCard:
	return candidates[0] if not candidates.is_empty() else null


func choose_programs_to_host(_candidates: Array, _ctx: GameContext) -> Array:
	return []


func choose_forfeit_agenda(candidates: Array, _ctx: GameContext) -> InstalledCard:
	return candidates[0] if not candidates.is_empty() else null


func choose_derez_target(candidates: Array, _ctx: GameContext) -> InstalledCard:
	return candidates[0] if not candidates.is_empty() else null


func choose_programs_to_trash_for_mu(programs: Array, excess_mu: int, _ctx: GameContext) -> Array:
	# §10.3.1e MU enforcement: trash fewest programs to bring MU back within limit.
	# Sort by MU cost descending (trash high-MU first to minimise card loss), break
	# ties by install cost ascending (prefer keeping expensive cards).
	var scored: Array = []
	for p in programs:
		var c: InstalledCard = p as InstalledCard
		if c == null or c.card_record == null:
			continue
		scored.append({"card": c, "mu": c.card_record.memory_cost,
			"cost": max(0, c.card_record.cost)})
	scored.sort_custom(func(a, b):
		return a.mu > b.mu if a.mu != b.mu else a.cost < b.cost)
	var result: Array = []
	var freed := 0
	for s in scored:
		if freed >= excess_mu:
			break
		result.append(s.card)
		freed += s.mu
	return result


func choose_discard_to_hand_limit(hand: Array, excess: int, _ctx: GameContext) -> Array:
	# Discard cards of lowest strategic value first.
	# Priority order (discard cheapest/lowest-type first):
	#   resources (score 0) < events (100) < hardware (200) < programs (300)
	#   within a type, lower cost = discard first.
	var scored: Array = []
	for e in hand:
		var ed: Dictionary = e as Dictionary
		var cr: CardRecord = ed.get("card_record", null) as CardRecord
		if cr == null:
			continue
		var type_score: int
		match cr.card_type:
			"resource": type_score = 0
			"event":    type_score = 100
			"hardware": type_score = 200
			"program":  type_score = 300
			_:          type_score = 0
		var card_score: int = type_score + (cr.cost if cr.cost >= 0 else 0)
		scored.append({"entry": ed, "score": card_score})
	scored.sort_custom(func(a, b): return a.score < b.score)
	var result: Array = []
	for i in range(mini(excess, scored.size())):
		result.append(scored[i].entry)
	return result


func choose_from_runner_score(candidates: Array, _ctx: GameContext) -> CardRecord:
	return candidates[0] if not candidates.is_empty() else null


func choose_suffer_damage_or_etr(_amount: int, _damage_type: String, _ctx: GameContext) -> bool:
	return true  # take the ETR


func choose_card_order(cards: Array, _ctx: GameContext) -> Array:
	return cards.duplicate()  # AI: keep current order


func choose_top_or_bottom(_card: CardRecord, _context_label: String, _ctx: GameContext) -> String:
	return "bottom"  # AI: always hide it at the bottom


# ── Parhelion: Charge ─────────────────────────────────────────────────────────

# Heuristic: charge the card that would benefit most from an extra power counter.
# Priority: WAKE Implant (more R&D accesses) > card nearest depletion > first candidate.
func choose_card_to_charge(candidates: Array, _ctx: GameContext) -> InstalledCard:
	if candidates.is_empty():
		return null
	# Priority order (MS-L006 fix):
	#   1. Endurance — every counter = potential sub break; highly tactically valuable
	#   2. The Twinning — each counter = +1 central breach access; compounding value
	#   3. Revolver — delays depletion of the killer's counters
	#   4. WAKE Implant — more R&D accesses
	#   5. Environmental Testing — accelerates the 9cr payout
	#   6. Card nearest depletion (fewest counters) — keep tools alive
	const PRIORITY_IDS: Array = [
		"endurance", "the_twinning", "revolver",
		"wake_implant_v2a_jrj", "environmental_testing"
	]
	for priority_id in PRIORITY_IDS:
		for c in candidates:
			var ic: InstalledCard = c as InstalledCard
			if ic != null and ic.card_id == priority_id:
				return ic
	# Fallback: card with fewest counters (prevent depletion)
	var best: InstalledCard = candidates[0] as InstalledCard
	for c in candidates:
		var ic: InstalledCard = c as InstalledCard
		if ic != null and ic.get_counter("power") < best.get_counter("power"):
			best = ic
	return best


# ── Helpers ───────────────────────────────────────────────────────────────────

func _has_breaker_for_ice(ic: InstalledCard, ctx: GameContext) -> bool:
	# Returns true if the runner has a rig program that can break this ICE's subroutines.
	# AI breakers handle all types. For others, any one subtype match is sufficient.
	if ic == null or ic.card_record == null:
		return true
	for rig_any in ctx.runner_rig:
		var b: InstalledCard = rig_any as InstalledCard
		if b != null and b.card_record != null and b.card_record.subtypes.has("ai"):
			return true
	for subtype in ic.card_record.subtypes:
		var needed: String = ICE_TO_BREAKER.get(subtype, "")
		if needed == "":
			continue
		for rig_any in ctx.runner_rig:
			var b: InstalledCard = rig_any as InstalledCard
			if b != null and b.card_record != null and b.card_record.subtypes.has(needed):
				return true
	for subtype in ic.card_record.subtypes:
		if ICE_TO_BREAKER.has(subtype):
			return false  # classifiable subtype present but no matching breaker found
	return true  # no classifiable subtypes — assume passable


func _can_runner_break_server(server: Server, ctx: GameContext) -> bool:
	# Returns true if the runner has breaker coverage for every rezzed ICE on the server
	# and enough credits to cover estimated break costs plus an unrezzed ICE buffer.
	# Budget: 2cr per rezzed piece (break cost) + 1cr per unrezzed (Corp may rez during the run).
	var rezzed_count := 0
	var unrezzed_count := 0
	for ice_any in server.ice:
		var ic: InstalledCard = ice_any as InstalledCard
		if ic == null:
			continue
		if not ic.is_rezzed:
			unrezzed_count += 1
			continue
		rezzed_count += 1
		if not _has_breaker_for_ice(ic, ctx):
			return false
	return ctx.runner_credits >= rezzed_count * 2 + unrezzed_count


func _find_run_target(ctx: GameContext) -> String:
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s == null or not s.is_remote():
			continue
		var agenda: InstalledCard = s.get_agenda_or_asset()
		if agenda == null or agenda.card_record == null or not agenda.card_record.is_agenda():
			continue
		if campaign_runner_mode:
			if not _can_runner_break_server(s, ctx):
				continue
		else:
			var ice_count: int = s.ice_count()
			if not (ice_count == 0 or ctx.runner_credits >= ice_count * 2):
				continue
		return s.server_id
	return ""
