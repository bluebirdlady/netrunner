class_name CampaignController
extends Node

const MainScene      = preload("res://Scenes/UI/Main.tscn")
const ArcSelectScene = preload("res://Scripts/UI/ArcSelectMenu.gd")
var _main: Node = null

# ── CampaignController ────────────────────────────────────────────────────────
# Top-level campaign flow. Owns the CampaignState, CampaignMenu, FictionViewer,
# and launches games via Main when a mission is selected.
#
# Supports both arcs (runner / corp) selected at startup via ArcSelectMenu.

var _state:       CampaignState   # runner arc save
var _corp_state:  CampaignState   # corp arc save
var _is_corp:     bool = false

var _arc_menu:   CanvasLayer   = null
var _menu:       CampaignMenu  = null
var _current_mission_id: String = ""

var _tournament_state: TournamentState
var _tournament_menu:  TournamentMenu


func _ready() -> void:
	_arc_menu = ArcSelectScene.new()
	add_child(_arc_menu)
	_arc_menu.connect("runner_campaign_chosen", _on_runner_arc_chosen)
	_arc_menu.connect("corp_campaign_chosen",   _on_corp_arc_chosen)


# ── Arc selection ─────────────────────────────────────────────────────────────

func _on_runner_arc_chosen() -> void:
	_arc_menu.queue_free()
	_arc_menu = null
	_is_corp = false
	_state = CampaignState.new()
	if not _state.load_campaign():
		push_error("CampaignController: failed to load campaign.json")
		return
	_show_menu()


func _on_corp_arc_chosen() -> void:
	_arc_menu.queue_free()
	_arc_menu = null
	_is_corp = true
	_corp_state = CampaignState.new()
	if not _corp_state.load_corp_campaign():
		push_error("CampaignController: failed to load corp_campaign.json")
		return
	_show_menu()


func _active_state() -> CampaignState:
	return _corp_state if _is_corp else _state


# ── Navigation ────────────────────────────────────────────────────────────────

func _show_menu() -> void:
	if _main != null and is_instance_valid(_main):
		_main.queue_free()
		_main = null

	if _menu == null or not is_instance_valid(_menu):
		_menu = CampaignMenu.new()
		add_child(_menu)
		_menu.mission_selected.connect(_on_mission_selected)
		_menu.starter_match_requested.connect(launch_starter_match)
		_menu.tournament_requested.connect(_show_tournament)

	_menu.setup(_active_state())
	_menu.visible = true


func _on_mission_selected(mission_id: String, ai_level_override: int) -> void:
	_current_mission_id = mission_id
	_menu.visible = false

	var mission  := _active_state().get_mission(mission_id)
	var opponent := _active_state().get_opponent(mission.get("opponent_id", ""))

	if mission.is_empty() or opponent.is_empty():
		push_error("CampaignController: mission or opponent not found: %s" % mission_id)
		_show_menu()
		return

	_launch_game(mission, opponent, ai_level_override)


func _launch_game(mission: Dictionary, opponent: Dictionary, ai_level_override: int = -1) -> void:
	_main = MainScene.instantiate()
	add_child(_main)

	_main.campaign_mode = true

	if _is_corp:
		# Corp campaign: human plays Corp, SimRunnerAI plays the runner opponent.
		_main.corp_mode            = true
		_main.campaign_corp_deck   = _active_state().get_corp_deck()
		_main.campaign_corp_id     = _active_state().get_corp_identity_id()
		_main.campaign_runner_deck = opponent.get("deck", []) as Array
		_main.campaign_runner_id   = opponent.get("identity", "")
		_main.campaign_ai_level    = 0   # unused in corp mode
	else:
		# Runner campaign: human plays Runner, CorpTurnAI plays the corp opponent.
		_main.corp_mode            = false
		_main.campaign_runner_deck = _active_state().get_runner_deck()
		_main.campaign_runner_id   = _active_state().get_runner_identity_id()
		_main.campaign_corp_deck   = opponent.get("deck", []) as Array
		_main.campaign_corp_id     = opponent.get("identity", "")
		_main.campaign_ai_level    = ai_level_override if ai_level_override >= 0 \
				else mission.get("ai_level", 0) as int

	_main.campaign_available_pool = _active_state().get_full_card_pool()
	_main.game_over_callback      = Callable(self, "_on_game_over")

	await get_tree().process_frame
	_main.start_campaign_game()


func _on_game_over(runner_wins: bool) -> void:
	# Corp campaign completes when Corp wins (runner_wins == false).
	# Runner campaign completes when Runner wins (runner_wins == true).
	var mission_won: bool = (not runner_wins) if _is_corp else runner_wins
	var newly_unlocked: Array = []
	if mission_won:
		newly_unlocked = _active_state().complete_mission(_current_mission_id)

	var mission := _active_state().get_mission(_current_mission_id)
	var fiction_post: String = mission.get("fiction_post", "")

	var _go_to_menu := func():
		_show_menu()

	var _show_unlocks := func():
		if newly_unlocked.is_empty():
			_go_to_menu.call()
			return
		var unlock_screen := CardUnlockScreen.new()
		add_child(unlock_screen)
		unlock_screen.show_unlocks(newly_unlocked, func():
			unlock_screen.queue_free()
			_go_to_menu.call()
		)

	if fiction_post != "":
		var viewer := FictionViewer.new()
		add_child(viewer)
		viewer.show_fiction(
			_active_state().get_fiction_text(fiction_post),
			func():
				viewer.queue_free()
				_show_unlocks.call()
		)
	else:
		_show_unlocks.call()


func launch_starter_match() -> void:
	if _menu != null and is_instance_valid(_menu):
		_menu.queue_free()
		_menu = null
	if _main != null and is_instance_valid(_main):
		_main.queue_free()
		_main = null

	_main = MainScene.instantiate()
	add_child(_main)
	_main.campaign_mode = false
	_main.game_finished.connect(_on_starter_match_finished, CONNECT_ONE_SHOT)
	_main.start_standalone_game()


func _on_starter_match_finished() -> void:
	if _main != null:
		_main.queue_free()
		_main = null
	_show_menu()


# ── Tournament flow ───────────────────────────────────────────────────────────

func _show_tournament() -> void:
	if _is_corp:
		return   # tournament not available in corp campaign

	if _menu != null:
		_menu.visible = false

	if _tournament_state == null:
		_tournament_state = TournamentState.new()
		_tournament_state.load_or_new()

	if _tournament_menu == null or not is_instance_valid(_tournament_menu):
		_tournament_menu = TournamentMenu.new()
		add_child(_tournament_menu)
		_tournament_menu.match_requested.connect(_on_tournament_match_requested)
		_tournament_menu.closed.connect(_on_tournament_closed)

	_tournament_menu.setup(_tournament_state)
	_tournament_menu.visible = true


func _on_tournament_match_requested(opponent: Dictionary, ai_level: int) -> void:
	if _tournament_menu != null:
		_tournament_menu.visible = false

	_main = MainScene.instantiate()
	add_child(_main)

	_main.campaign_mode           = true
	_main.campaign_runner_deck    = _active_state().get_runner_deck()
	_main.campaign_runner_id      = _active_state().get_runner_identity_id()
	_main.campaign_corp_deck      = opponent.get("deck", []) as Array
	_main.campaign_corp_id        = opponent.get("identity", "")
	_main.campaign_ai_level       = ai_level
	_main.campaign_available_pool = _active_state().get_full_card_pool()
	_main.game_over_callback      = Callable(self, "_on_tournament_game_over")

	await get_tree().process_frame
	_main.start_campaign_game()


func _on_tournament_game_over(runner_wins: bool) -> void:
	if _main != null:
		_main.queue_free()
		_main = null

	if _tournament_menu != null and is_instance_valid(_tournament_menu):
		_tournament_menu.record_result(runner_wins)
		_tournament_menu.visible = true
	else:
		_show_tournament()


func _on_tournament_closed() -> void:
	if _tournament_menu != null:
		_tournament_menu.visible = false
	_show_menu()
