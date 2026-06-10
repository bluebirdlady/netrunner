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

const CREDIT_THRESHOLD := 5
const MIN_HAND_SIZE    := 3


# ── Turn-time interface ───────────────────────────────────────────────────────

func choose_action(ctx: GameContext) -> GameAction:
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


func get_pre_click_rez_actions(_ctx: GameContext) -> Array:
	return []


# ── Run-time interface ────────────────────────────────────────────────────────

func choose_jack_out(_ctx: GameContext) -> bool:
	return false


func choose_encounter_action(encounter: EncounterState, ctx: GameContext) -> Dictionary:
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


func choose_break_subroutines(_ice: InstalledCard, _subs: Array, _ctx: GameContext) -> Array:
	return []


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

func _find_run_target(ctx: GameContext) -> String:
	for key in ctx.servers:
		var s: Server = ctx.servers[key] as Server
		if s == null or not s.is_remote():
			continue
		var agenda: InstalledCard = s.get_agenda_or_asset()
		if agenda == null or agenda.card_record == null or not agenda.card_record.is_agenda():
			continue
		# Consider the remote runnable if it has no ice or the runner has enough credits.
		var ice_count: int = s.ice_count()
		if ice_count == 0 or ctx.runner_credits >= ice_count * 2:
			return s.server_id
	return ""
