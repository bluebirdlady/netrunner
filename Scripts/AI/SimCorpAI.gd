class_name SimCorpAI
extends CorpTurnAI

# ── SimCorpAI ─────────────────────────────────────────────────────────────────
# Headless Corp decision maker for simulation rollouts.
# Extends CorpTurnAI (which already returns synchronously from all turn-time
# methods) and overrides / fills in the few remaining async-or-missing methods
# so that every call completes in-frame with no signals or frame yields.


func _init(registry: AbilityRegistry) -> void:
	super(registry)
	_run_ai.silent = true


# ── Trigger ordering ──────────────────────────────────────────────────────────

func choose_trigger_order(_triggers: Array, _ctx: GameContext) -> int:
	return 0


# ── Target selection ──────────────────────────────────────────────────────────

func choose_target(candidates: Array, _context: Dictionary) -> Variant:
	return candidates[0] if not candidates.is_empty() else null


func choose_derez_target(candidates: Array, _ctx: GameContext) -> InstalledCard:
	return candidates[0] if not candidates.is_empty() else null


func choose_host_ice(candidates: Array, _ctx: GameContext) -> InstalledCard:
	return candidates[0] if not candidates.is_empty() else null


func choose_ice_swap(candidates: Array, _ctx: GameContext) -> InstalledCard:
	return candidates[0] if not candidates.is_empty() else null


func choose_from_heap(candidates: Array, _ctx: GameContext) -> CardRecord:
	return candidates[0] if not candidates.is_empty() else null


# ── Counter / cost choices ────────────────────────────────────────────────────

func choose_spend_counter_amount(_max: int, _ctx: GameContext) -> int:
	return 0


# ── Damage / tag avoidance ────────────────────────────────────────────────────

func choose_pay_to_avoid_tag(_cost: int, _ctx: GameContext) -> bool:
	return false


func choose_pay_to_avoid_damage(_cost: int, _amount: int, _ctx: GameContext) -> bool:
	return false


# ── Trace ──────────────────────────────────────────────────────────────────────

# Boost a trace just enough to guarantee success against the Runner's maximum
# possible total (link + all available credits), if affordable; otherwise
# spend nothing. This is a simple, slightly conservative heuristic — it
# overestimates the Runner's likely response but avoids wasting credits on
# traces the AI cannot win outright.
func choose_trace_boost(base_strength: int, ctx: GameContext) -> int:
	var runner_max: int = ctx.runner_total_link() + ctx.runner_credits
	var needed: int = (runner_max + 1) - base_strength
	if needed <= 0:
		return 0
	return min(needed, ctx.corp_credits)


func choose_suffer_damage_or_etr(_damage: int, _ctx: GameContext) -> String:
	return "etr"


# ── Wall to Wall ───────────────────────────────────────────────────────────────

# Single-choice case (Corp has another rezzed asset): advance ice toward agendas.
func choose_wall_to_wall_option(choices: Array, _ctx: GameContext) -> String:
	if "place_adv_on_ice" in choices:
		return "place_adv_on_ice"
	return choices[0] if not choices.is_empty() else ""


# No-other-rezzed-assets case: take draw + credit + advance, skip returning to HQ.
func choose_wall_to_wall_options_multi(choices: Array, max_count: int, _ctx: GameContext) -> Array:
	var picks: Array = []
	for c in choices:
		if c == "return_self_to_hq":
			continue
		picks.append(c)
		if picks.size() >= max_count:
			break
	return picks


func choose_take_tag_or_end_run(_ctx: GameContext) -> String:
	return "etr"


# ── Access choices ────────────────────────────────────────────────────────────

func choose_access_target(candidates: Array, _ctx: GameContext) -> InstalledCard:
	return candidates[0] if not candidates.is_empty() else null


# ── Runner rig interaction ────────────────────────────────────────────────────

func choose_trash_from_rig(candidates: Array, _ctx: GameContext) -> InstalledCard:
	return candidates[0] if not candidates.is_empty() else null


func choose_programs_to_host(candidates: Array, _max: int, _ctx: GameContext) -> Array:
	return []


# ── Misc ──────────────────────────────────────────────────────────────────────

func choose_carnivore(_ctx: GameContext) -> String:
	return "trash"


func choose_flip_identity(_ctx: GameContext) -> bool:
	return false


func choose_payment_option(options: Array, _ctx: GameContext) -> String:
	return options[0] if not options.is_empty() else "credits"


func choose_server(candidates: Array, _ctx: GameContext) -> String:
	return candidates[0] if not candidates.is_empty() else "hq"
