class_name CampaignController
extends Node

const MainScene = preload("res://Scenes/UI/Main.tscn")   # Adjust path to your actual .tscn file
var _main: Node = null

# ── CampaignController ────────────────────────────────────────────────────────
# Top-level campaign flow. Owns the CampaignState, CampaignMenu, FictionViewer,
# and launches games via Main when a mission is selected.
#
# Scene tree expectation:
#   CampaignController (this node)
#     └─ [dynamic children added at runtime]
#
# Usage: instance this as the root scene, or add it to an existing root.

var _state:   CampaignState
var _menu:    CampaignMenu
var _current_mission_id: String = ""

var _tournament_state: TournamentState
var _tournament_menu:  TournamentMenu


func _ready() -> void:
	_state = CampaignState.new()
	if not _state.load_campaign():
		push_error("CampaignController: failed to load campaign.json")
		return
	_show_menu()


# ── Navigation ────────────────────────────────────────────────────────────────

func _show_menu() -> void:
	# Clean up any active game
	if _main != null and is_instance_valid(_main):
		_main.queue_free()
		_main = null

	if _menu == null or not is_instance_valid(_menu):
		_menu = CampaignMenu.new()
		add_child(_menu)
		_menu.mission_selected.connect(_on_mission_selected)
		_menu.starter_match_requested.connect(launch_starter_match)
		_menu.tournament_requested.connect(_show_tournament)

	_menu.setup(_state)
	_menu.visible = true


func _on_mission_selected(mission_id: String, ai_level_override: int) -> void:
	_current_mission_id = mission_id
	_menu.visible = false

	var mission  := _state.get_mission(mission_id)
	var opponent := _state.get_opponent(mission.get("opponent_id", ""))

	if mission.is_empty() or opponent.is_empty():
		push_error("CampaignController: mission or opponent not found: %s" % mission_id)
		_show_menu()
		return

	_launch_game(mission, opponent, ai_level_override)


func _launch_game(mission: Dictionary, opponent: Dictionary, ai_level_override: int = -1) -> void:
	_main = MainScene.instantiate()
	add_child(_main)

	# Configure from campaign data
	_main.campaign_mode           = true
	_main.campaign_runner_deck    = _state.get_runner_deck()
	_main.campaign_runner_id      = _state.get_runner_identity_id()
	_main.campaign_corp_deck      = opponent.get("deck", []) as Array
	_main.campaign_corp_id        = opponent.get("identity", "")
	# Use the player's chosen level for replays; fall back to mission default on first run.
	_main.campaign_ai_level       = ai_level_override if ai_level_override >= 0 else mission.get("ai_level", 0) as int
	# Full format pool (public info): starter + all unlockable cards.
	# The AI uses this to build a prior — it does NOT see the player's deck.
	_main.campaign_available_pool = _state.get_full_card_pool()
	_main.game_over_callback      = Callable(self, "_on_game_over")

	# Main initialises itself in _ready — we call its campaign setup after
	await get_tree().process_frame
	_main.start_campaign_game()


func _on_game_over(runner_wins: bool) -> void:
	# Complete mission and collect any newly unlocked cards for display.
	var newly_unlocked: Array = []
	if runner_wins:
		newly_unlocked = _state.complete_mission(_current_mission_id)

	var mission := _state.get_mission(_current_mission_id)
	var fiction_post: String = mission.get("fiction_post", "")

	# Chain: post-fiction → card unlocks → campaign menu.
	# Each step calls the next via its done-callback.

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
			_state.get_fiction_text(fiction_post),
			func():
				viewer.queue_free()
				_show_unlocks.call()
		)
	else:
		_show_unlocks.call()
		
# Add this function
func launch_starter_match() -> void:
	# Clean up any active menu or game
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
	_main.campaign_runner_deck    = _state.get_runner_deck()
	_main.campaign_runner_id      = _state.get_runner_identity_id()
	_main.campaign_corp_deck      = opponent.get("deck", []) as Array
	_main.campaign_corp_id        = opponent.get("identity", "")
	_main.campaign_ai_level       = ai_level
	_main.campaign_available_pool = _state.get_full_card_pool()
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
