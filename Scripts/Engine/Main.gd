# Main.gd
extends Node

@onready var game_ui: CanvasLayer = $GameUI

signal game_finished

var ctx: GameContext
var ability_registry: AbilityRegistry
var turn_manager: TurnManager
var run_machine: RunStateMachine
var corp_brain: CorpTurnAI
var runner_brain: HumanDecisionMaker
var _run_scene: RunScene = null

# ── Campaign mode ─────────────────────────────────────────────────────────────
var campaign_mode:           bool     = false
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

	# Select Corp AI level — heuristic (0), tactical 1-ply (1), strategic 2-ply (2)
	match campaign_ai_level:
		1:
			corp_brain = CorpTurnAI_Tactical.new(ability_registry)
		2:
			corp_brain = CorpTurnAI_Strategic.new(ability_registry)
		_:
			corp_brain = CorpTurnAI.new(ability_registry)

	runner_brain = HumanDecisionMaker.new()

	ctx.corp_decision_maker   = corp_brain
	ctx.runner_decision_maker = runner_brain

	if campaign_mode:
		_populate_campaign_state()
		# Seed the Bayesian runner model from public info (identity + format pool),
		# not from the player's actual deck list.
		if corp_brain.has_method("seed_runner_model"):
			corp_brain.seed_runner_model(campaign_runner_id, campaign_available_pool)
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

	# Route UI actions to the runner brain, and observe them for the AI model
	game_ui.action_requested.connect(func(action: GameAction):
		if ctx.active_player == "runner":
			runner_brain.action_selected.emit(action)
			_observe_runner_action(action)
	)

	# Default proxies → GameUI (used outside of runs)
	_wire_proxies_to_game_ui()

	# Intercept run initiation to show RunScene
	_wire_run_via_turn_manager()

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
	runner_brain.choose_optional_ability_proxy = func(prompt_text: String) -> bool:
		return await game_ui.show_optional_ability_prompt(prompt_text)


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
	# Called by TurnManager just before run_machine.execute(server_id)
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
