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

	# 4. Install first program from hand.
	for entry in ctx.runner_hand:
		var r: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if r != null and r.card_type == "program":
			return GameAction.install(r, "runner_rig")

	# 5. Fallback.
	return GameAction.gain_credits()


func get_pre_click_rez_actions(_ctx: GameContext) -> Array:
	return []


# ── Run-time interface ────────────────────────────────────────────────────────

func choose_jack_out(_ctx: GameContext) -> bool:
	return false


func choose_encounter_action(_encounter: EncounterState, _ctx: GameContext) -> Dictionary:
	# Pass all subroutines — simplest safe behaviour.
	return {"type": "done"}


func choose_break_subroutines(_ice: InstalledCard, _subs: Array, _ctx: GameContext) -> Array:
	return []


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


func choose_pay_shred_etr(_count: int, _ctx: GameContext) -> bool:
	return false


func choose_optional_ability(_prompt: String, _ctx: GameContext) -> bool:
	return false


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


func choose_from_runner_score(candidates: Array, _ctx: GameContext) -> CardRecord:
	return candidates[0] if not candidates.is_empty() else null


func choose_suffer_damage_or_etr(_amount: int, _damage_type: String, _ctx: GameContext) -> bool:
	return true  # take the ETR


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
