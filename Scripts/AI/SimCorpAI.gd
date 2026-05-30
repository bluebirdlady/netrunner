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


func choose_suffer_damage_or_etr(_damage: int, _ctx: GameContext) -> String:
	return "etr"


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
