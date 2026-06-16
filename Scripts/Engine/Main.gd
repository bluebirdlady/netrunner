# Main.gd
extends Node

@onready var game_ui: CanvasLayer = $GameUI

signal game_finished

var ctx: GameContext
var ability_registry: AbilityRegistry
var turn_manager: TurnManager
var run_machine: RunStateMachine
var corp_brain:   Object   # CorpTurnAI (runner mode) or CorpHumanBrain (corp mode)
var runner_brain: Object   # HumanDecisionMaker (runner mode) or SimRunnerAI (corp mode)
var _run_scene: RunScene = null

# ── Campaign mode ─────────────────────────────────────────────────────────────
var campaign_mode:           bool     = false
var corp_mode:               bool     = false   # true when the human player is the Corp
var campaign_runner_deck:    Array    = []
var campaign_runner_id:      String   = ""
var campaign_corp_deck:      Array    = []
var campaign_corp_id:        String   = ""
var campaign_ai_level:       int      = 0
var campaign_available_pool: Array    = []   # full format pool for AI prior (not the player's deck)
var game_over_callback:      Callable


func _ready() -> void:
	if campaign_mode:
		return   # CampaignController calls start_campaign_game() after ready

func start_standalone_game() -> void:
	_init_and_start()

func start_campaign_game() -> void:
	_init_and_start()


func _ready_standalone() -> void:
	_init_and_start()


func _init_and_start() -> void:
	ctx = GameContext.new()
	ability_registry = AbilityRegistry.new()
	if not ability_registry.load_from_file("res://Data/abilities.json"):
		push_error("Main: failed to load abilities.json")
	else:
		print("AbilityRegistry loaded %d card definitions" % ability_registry._abilities.size())

	if corp_mode:
		# Human plays Corp; SimRunnerAI plays Runner as opponent.
		corp_brain   = CorpHumanBrain.new()
		runner_brain = SimRunnerAI.new()
	else:
		# Human plays Runner; CorpTurnAI plays Corp at selected difficulty.
		match campaign_ai_level:
			1:
				corp_brain = CorpTurnAI_Tactical.new(ability_registry)
			2:
				corp_brain = CorpTurnAI_Strategic.new(ability_registry)
			3:
				corp_brain = CorpTurnAI_MCTS.new(ability_registry)
			_:
				corp_brain = CorpTurnAI.new(ability_registry)
		runner_brain = HumanDecisionMaker.new()

	ctx.corp_decision_maker   = corp_brain
	ctx.runner_decision_maker = runner_brain

	if campaign_mode:
		_populate_campaign_state()
		# Seed the AI opponent's model from public info (identity + format pool),
		# not from the player's actual deck list.
		if corp_brain.has_method("seed_runner_model"):
			corp_brain.seed_runner_model(campaign_runner_id, campaign_available_pool)
		if runner_brain.has_method("seed_corp_model"):
			runner_brain.seed_corp_model(campaign_corp_id, campaign_available_pool)
	else:
		_populate_test_state()

	ctx.servers["hq"]       = Server.make("hq")
	ctx.servers["rd"]       = Server.make("rd")
	ctx.servers["archives"] = Server.make("archives")

	turn_manager = TurnManager.new(ctx, ability_registry)
	run_machine  = RunStateMachine.new(ctx, ability_registry)
	ctx.set_meta("run_state_machine", run_machine)
	ctx.set_meta("ability_registry", ability_registry)
	ctx.set_meta("register_installed_card", Callable(turn_manager, "_register_card_listeners"))

	game_ui.setup(ctx, turn_manager, run_machine, ability_registry)
	# In Corp mode the human is never waiting for the AI to "think" —
	# disconnect the overlay that GameUI wires unconditionally in setup().
	if corp_mode and turn_manager.corp_thinking.is_connected(game_ui._on_corp_thinking):
		turn_manager.corp_thinking.disconnect(game_ui._on_corp_thinking)

	# VP36 Méliès U: refresh the identity card display whenever the identity flips.
	# The callback fires from flip_melies_u / flip_melies_u_back in AbilityInterpreter.
	ctx.set_meta("on_melies_u_flip", func(_flipped: bool, _server: String) -> void:
		game_ui._update_all_displays()
	)

	# Route UI actions to the active player's brain.
	# In Corp mode the human plays Corp; in Runner mode the human plays Runner.
	game_ui.action_requested.connect(func(action: GameAction):
		if corp_mode:
			if ctx.active_player == "corp":
				(corp_brain as CorpHumanBrain).action_selected.emit(action)
		else:
			if ctx.active_player == "runner":
				(runner_brain as HumanDecisionMaker).action_selected.emit(action)
				_observe_runner_action(action)
	)

	# Observe end of runner turn for the Corp AI model (runner mode only).
	turn_manager.turn_started.connect(func(player: String, _turn_num: int):
		if not corp_mode and player == "corp":
			_observe_runner_action(GameAction._make("end_turn", {}))
	)

	# Default proxies → GameUI (used outside of runs; runner-mode only).
	# In corp mode there are no runner-brain proxies to wire here;
	# CorpScene will wire corp_brain proxies in C2.
	if not corp_mode:
		_wire_proxies_to_game_ui()

	# Intercept run initiation to open the appropriate run scene.
	_wire_run_via_turn_manager()

	await _perform_mulligan_phase()
	_start_game_loop()


# ── Proxy wiring ──────────────────────────────────────────────────────────────

func _wire_proxies_to_game_ui() -> void:
	runner_brain.jack_out_proxy = func() -> bool:
		return await game_ui.show_jack_out_prompt()
	runner_brain.encounter_action_proxy = func(encounter: EncounterState) -> Dictionary:
		return await game_ui.show_encounter_prompt(encounter)
	runner_brain.trash_proxy = func(card: CardRecord) -> bool:
		return await game_ui.show_trash_prompt(card)
	runner_brain.choose_modes_proxy = func(modes: Array, max_choices: int) -> Array:
		return await game_ui.show_modal_prompt(modes, max_choices)
	runner_brain.choose_from_search_proxy = func(candidates: Array) -> CardRecord:
		return await game_ui.show_search_prompt(candidates)
	runner_brain.choose_payment_option_proxy = func(options: Array) -> Variant:
		return await game_ui.show_payment_option_prompt(options)
	runner_brain.choose_server_proxy = func(allowed: Array) -> String:
		return await game_ui.show_server_choice_prompt(allowed)
	runner_brain.choose_card_from_hand_proxy = func(hand: Array) -> Variant:
		return await game_ui.show_choose_from_hand_prompt(hand, "Pantograph: choose a card to install for free (or decline)")
	runner_brain.ice_swap_proxy = func(eligible_servers: Array) -> Variant:
		return await game_ui.show_ice_swap_prompt(eligible_servers)
	runner_brain.carnivore_proxy = func(card_record: CardRecord) -> bool:
		return await game_ui.show_carnivore_prompt(card_record)
	runner_brain.choose_pay_to_avoid_damage_proxy = func(cost: int, damage: int, damage_type: String) -> bool:
		return await game_ui.show_pay_to_avoid_damage_prompt(cost, damage, damage_type)
	runner_brain.choose_suffer_damage_or_etr_proxy = func(amount: int, damage_type: String) -> bool:
		return await game_ui.show_suffer_damage_or_etr_prompt(amount, damage_type)
	runner_brain.choose_optional_ability_proxy = func(prompt_text: String) -> bool:
		return await game_ui.show_optional_ability_prompt(prompt_text)
	runner_brain.spend_click_to_continue_proxy = func() -> bool:
		return await game_ui.show_optional_ability_prompt("Spend 1[click] to continue the run?")
	runner_brain.psi_bid_proxy = func(max_bid: int) -> int:
		return await game_ui.show_psi_bid_prompt(max_bid)
	runner_brain.choose_discard_to_hand_limit_proxy = func(hand: Array, excess: int) -> Array:
		return await game_ui.show_discard_to_hand_limit_prompt(hand, excess)
	runner_brain.choose_programs_to_trash_for_mu_proxy = func(programs: Array, excess_mu: int) -> Array:
		return await game_ui.show_mu_trash_prompt(programs, excess_mu)
	runner_brain.choose_subs_to_break_proxy = func(candidates: Array, max_count: int, encounter: EncounterState) -> Array:
		return await game_ui.show_choose_subs_to_break_prompt(candidates, max_count, encounter)
	runner_brain.host_ice_proxy = func(candidates: Array, _ctx: GameContext, prompt: String = "") -> InstalledCard:
		return await game_ui.show_host_ice_prompt(candidates, prompt if prompt != "" else "Choose a piece of ice to host this card on:")
	runner_brain.choose_card_order_proxy = func(cards: Array) -> Array:
		return await game_ui.show_card_order_prompt(cards)
	runner_brain.choose_top_or_bottom_proxy = func(card: CardRecord, label: String) -> String:
		return await game_ui.show_top_or_bottom_prompt(card, label)


func _wire_proxies_to_run_scene(run_scene: RunScene) -> void:
	runner_brain.jack_out_proxy = func() -> bool:
		return await run_scene.show_jack_out_prompt()
	runner_brain.encounter_action_proxy = func(encounter: EncounterState) -> Dictionary:
		return await run_scene.show_encounter_prompt(encounter)
	runner_brain.trash_proxy = func(card: CardRecord) -> bool:
		return await run_scene.show_trash_prompt(card)
	runner_brain.choose_modes_proxy = func(modes: Array, max_choices: int) -> Array:
		return await run_scene.show_modal_prompt(modes, max_choices)
	runner_brain.choose_from_search_proxy = func(candidates: Array) -> CardRecord:
		return await run_scene.show_search_prompt(candidates)
	runner_brain.choose_payment_option_proxy = func(options: Array) -> Variant:
		return await run_scene.show_payment_option_prompt(options)
	runner_brain.choose_server_proxy = func(allowed: Array) -> String:
		return await run_scene.show_server_choice_prompt(allowed)
	runner_brain.choose_card_from_hand_proxy = func(hand: Array) -> Variant:
		return await game_ui.show_choose_from_hand_prompt(hand, "Choose a card to install")
	runner_brain.choose_discard_to_hand_limit_proxy = func(hand: Array, excess: int) -> Array:
		return await run_scene.show_discard_to_hand_limit_prompt(hand, excess)
	runner_brain.choose_subs_to_break_proxy = func(candidates: Array, max_count: int, encounter: EncounterState) -> Array:
		return await run_scene.show_choose_subs_to_break_prompt(candidates, max_count, encounter)
	runner_brain.host_ice_proxy = func(candidates: Array, _ctx: GameContext, prompt: String = "") -> InstalledCard:
		return await game_ui.show_host_ice_prompt(candidates, prompt if prompt != "" else "Choose a piece of ice to host this card on:")
	runner_brain.choose_suffer_damage_or_etr_proxy = func(amount: int, damage_type: String) -> bool:
		return await run_scene.show_suffer_damage_or_etr_prompt(amount, damage_type)
	runner_brain.choose_pay_to_avoid_damage_proxy = func(cost: int, damage: int, damage_type: String) -> bool:
		var modes := [
			{"label": "Pay %d cr — prevent %d %s damage" % [cost, damage, damage_type.capitalize()]},
			{"label": "Take %d %s damage" % [damage, damage_type.capitalize()]}
		]
		var result: Array = await run_scene.show_modal_prompt(modes, 1)
		return result.size() > 0 and (result[0] as int) == 0
	runner_brain.choose_optional_ability_proxy = func(prompt_text: String) -> bool:
		return await game_ui.show_optional_ability_prompt(prompt_text)
	runner_brain.spend_click_to_continue_proxy = func() -> bool:
		return await game_ui.show_optional_ability_prompt("Spend 1[click] to continue the run?")
	runner_brain.choose_card_order_proxy = func(cards: Array) -> Array:
		return await game_ui.show_card_order_prompt(cards)
	runner_brain.choose_top_or_bottom_proxy = func(card: CardRecord, label: String) -> String:
		return await game_ui.show_top_or_bottom_prompt(card, label)


# ── Run scene lifecycle ───────────────────────────────────────────────────────

func _wire_run_via_turn_manager() -> void:
	# TurnManager calls run_machine.execute internally via _do_run.
	# We override the run proxy on the run_machine so we can intercept it.
	# The approach: hook into run_machine's pre-execution signal if available,
	# otherwise let TurnManager call execute directly and rely on RunScene
	# being created before the first encounter prompt fires.
	#
	# Since run_machine.execute is awaitable, we patch _do_run in TurnManager
	# by setting a run_started callback on ctx metadata.
	ctx.set_meta("on_run_started", Callable(self, "_on_run_will_start"))


func _on_run_will_start(server_id: String) -> void:
	if corp_mode:
		# C1: runs execute invisibly — SimRunnerAI makes all runner decisions
		# autonomously and CorpHumanBrain stubs handle rez/trace/psi defaults.
		# CorpScene will open here in C2.
		return
	_open_run_scene(server_id)


func _open_run_scene(server_id: String) -> void:
	if _run_scene != null:
		return

	_run_scene = RunScene.new()
	add_child(_run_scene)
	_run_scene.setup(ctx, ability_registry, run_machine)
	_run_scene.run_complete.connect(_on_run_scene_complete, CONNECT_ONE_SHOT)

	# Redirect all runner decisions to RunScene
	_wire_proxies_to_run_scene(_run_scene)

	# Tell RunScene which server we're running on
	_run_scene.start_run(server_id)


func _on_run_scene_complete() -> void:
	if _run_scene != null:
		_run_scene.queue_free()
		_run_scene = null

	# Restore proxies to GameUI
	_wire_proxies_to_game_ui()
	game_ui._update_all_displays()


# ── Runner action observation ─────────────────────────────────────────────────

# Forward observable runner actions to the Corp AI model (Strategic level only).
func _observe_runner_action(action: GameAction) -> void:
	if not corp_brain.has_method("observe_runner_action"):
		return
	var params: Dictionary = {}
	match action.type:
		"install":
			var cr: CardRecord = action.params.get("card_record", null) as CardRecord
			if cr != null:
				params["card_id"] = cr.id
		"play_operation":
			var cr: CardRecord = action.params.get("card_record", null) as CardRecord
			if cr != null:
				params["card_id"] = cr.id
		"run":
			params = action.params.duplicate()
		"draw_card":
			params = {"count": 1}   # runner drew one card via click action
		"end_turn":
			pass   # no params needed — model increments turn counter
	corp_brain.observe_runner_action(action.type, params)


# ── Game loop ─────────────────────────────────────────────────────────────────

func _start_game_loop() -> void:
	await turn_manager.run_game()
	await game_ui.game_over_acknowledged

	# Notify campaign controller on game end
	if campaign_mode and game_over_callback.is_valid():
		game_over_callback.call(ctx.winner == "runner")
	else:
		game_finished.emit()

# ── Mulligan phase (rule 1.6.6.a) ─────────────────────────────────────────────

func _perform_mulligan_phase() -> void:
	# Corp decides first, then Runner. Each may shuffle their hand back and redraw 5.
	var corp_mulligans: bool
	if corp_mode:
		corp_mulligans = await game_ui.show_mulligan_prompt(ctx.corp_name(), ctx.corp_hand)
	else:
		corp_mulligans = _corp_wants_mulligan()
	if corp_mulligans:
		for entry in ctx.corp_hand:
			var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
			if card != null:
				ctx.corp_deck.append(card)
		ctx.corp_hand.clear()
		ctx.corp_deck.shuffle()
		for _i in range(5):
			if not ctx.corp_deck.is_empty():
				var drawn: CardRecord = ctx.corp_deck.pop_front()
				ctx.corp_hand.append({"card_id": drawn.id, "card_record": drawn})
		ctx.send_log("Corp takes a mulligan.")
	else:
		ctx.send_log("Corp keeps their opening hand.")

	var runner_mulligans: bool
	if not corp_mode and runner_brain is HumanDecisionMaker:
		runner_mulligans = await game_ui.show_mulligan_prompt(ctx.runner_name(), ctx.runner_hand)
	else:
		runner_mulligans = _runner_wants_mulligan()

	if runner_mulligans:
		for entry in ctx.runner_hand:
			var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
			if card != null:
				ctx.runner_deck.append(card)
		ctx.runner_hand.clear()
		ctx.runner_deck.shuffle()
		for _i in range(5):
			if not ctx.runner_deck.is_empty():
				var drawn: CardRecord = ctx.runner_deck.pop_front()
				ctx.runner_hand.append({"card_id": drawn.id, "card_record": drawn})
		ctx.send_log("Runner takes a mulligan.")
		var new_hand_titles: Array = []
		for entry in ctx.runner_hand:
			var cr: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
			if cr != null:
				new_hand_titles.append(cr.title)
		ctx.send_log("New hand: %s" % ", ".join(new_hand_titles))
		game_ui._update_all_displays()
	else:
		ctx.send_log("Runner keeps their opening hand.")


func _corp_wants_mulligan() -> bool:
	var agendas      := 0
	var afford_ice   := 0
	for entry in ctx.corp_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card == null:
			continue
		if card.is_agenda():
			agendas += 1
		if card.is_ice() and card.cost <= ctx.corp_credits:
			afford_ice += 1
	return agendas > 2 or afford_ice < 2


func _runner_wants_mulligan() -> bool:
	# Mull if there are no events or resources in hand (no economy or run enablers).
	for entry in ctx.runner_hand:
		var card: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if card == null:
			continue
		if card.card_type in ["event", "resource"]:
			return false
	return true


# ── Test state ────────────────────────────────────────────────────────────────

func _populate_campaign_state() -> void:
	ctx.corp_credits   = 5
	ctx.runner_credits = 5
	ctx.corp_clicks    = 3
	ctx.runner_clicks  = 0

	# Identities from campaign config
	ctx.runner_identity = CardRegistry.get_card(campaign_runner_id)
	ctx.corp_identity   = CardRegistry.get_card(campaign_corp_id)

	_load_deck_from_ids(campaign_corp_deck,    ctx.corp_deck)
	_load_deck_from_ids(campaign_runner_deck,  ctx.runner_deck)
	ctx.corp_deck.shuffle()
	ctx.runner_deck.shuffle()

	for i in range(5):
		if not ctx.corp_deck.is_empty():
			var card: CardRecord = ctx.corp_deck.pop_front()
			ctx.corp_hand.append({"card_id": card.id, "card_record": card})
	for i in range(5):
		if not ctx.runner_deck.is_empty():
			var card: CardRecord = ctx.runner_deck.pop_front()
			ctx.runner_hand.append({"card_id": card.id, "card_record": card})


func _populate_test_state() -> void:
	ctx.corp_credits   = 5
	ctx.runner_credits = 5
	ctx.corp_clicks    = 3
	ctx.runner_clicks  = 0

	# ── Identities ────────────────────────────────────────────────────────────
	ctx.corp_identity   = CardRegistry.get_card("the_syndicate_profit_over_principle")
	ctx.runner_identity = CardRegistry.get_card("the_catalyst_convention_breaker")

	# ── System Gateway Starter Corp deck (34 cards — The Syndicate) ───────────
	var corp_deck_ids: Array = [
		"offworld_office", "offworld_office", "offworld_office",
		"send_a_message", "send_a_message",
		"superconducting_hub", "superconducting_hub",
		"nico_campaign", "nico_campaign",
		"urtica_cipher", "urtica_cipher",
		"regolith_mining_license", "regolith_mining_license",
		"hedge_fund", "hedge_fund", "hedge_fund",
		"government_subsidy", "government_subsidy",
		"seamless_launch", "seamless_launch",
		"manegarm_skunkworks",
		"bran_1_0", "bran_1_0",
		"diviner", "diviner",
		"karuna", "karuna",
		"palisade", "palisade", "palisade",
		"whitespace", "whitespace",
		"tithe", "tithe",
	]

	# ── System Gateway Starter Runner deck (30 cards — The Catalyst) ──────────
	var runner_deck_ids: Array = [
		"tread_lightly", "tread_lightly",
		"creative_commission", "creative_commission",
		"vrcation", "vrcation",
		"overclock", "overclock",
		"jailbreak", "jailbreak", "jailbreak",
		"sure_gamble", "sure_gamble", "sure_gamble",
		"docklands_pass",
		"pennyshaver",
		"red_team",
		"telework_contract", "telework_contract",
		"smartware_distributor", "smartware_distributor",
		"verbal_plasticity",
		"cleaver", "cleaver",
		"carmen", "carmen",
		"unity", "unity",
		"mayfly", "mayfly",
	]

	_load_deck_from_ids(corp_deck_ids, ctx.corp_deck)
	_load_deck_from_ids(runner_deck_ids, ctx.runner_deck)
	ctx.corp_deck.shuffle()
	ctx.runner_deck.shuffle()

	for i in range(5):
		if not ctx.corp_deck.is_empty():
			var card: CardRecord = ctx.corp_deck.pop_front()
			ctx.corp_hand.append({"card_id": card.id, "card_record": card})
	for i in range(5):
		if not ctx.runner_deck.is_empty():
			var card: CardRecord = ctx.runner_deck.pop_front()
			ctx.runner_hand.append({"card_id": card.id, "card_record": card})


func _load_deck_from_ids(ids: Array, deck: Array) -> void:
	for card_id in ids:
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record != null:
			deck.append(record)
		else:
			push_warning("_populate_test_state: card not found: %s" % card_id)
