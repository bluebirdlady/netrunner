class_name TournamentMenu
extends CanvasLayer

# ── TournamentMenu ────────────────────────────────────────────────────────────
# Displays the Open Circuit tournament screen.
# States: IDLE → LOADING → READY → IN_PROGRESS → COMPLETE
# Emits match_requested(opponent: Dictionary, ai_level: int) to start a game.
# Emits closed() when the player exits back to the campaign menu.

signal match_requested(opponent: Dictionary, ai_level: int)
signal closed()

const COLOR_BG        := Color(0.04, 0.05, 0.07)
const COLOR_ACCENT    := Color(0.85, 0.65, 0.15)   # gold for tournament
const COLOR_PANEL     := Color(0.07, 0.09, 0.11)
const COLOR_BORDER    := Color(0.35, 0.28, 0.10)
const COLOR_WIN       := Color(0.25, 0.80, 0.40)
const COLOR_LOSS      := Color(0.80, 0.25, 0.25)
const COLOR_PENDING   := Color(0.40, 0.45, 0.42)
const COLOR_INACTIVE  := Color(0.25, 0.28, 0.25)

const FACTION_COLORS := {
	"haas-bioroid":        Color(0.45, 0.55, 0.85),
	"jinteki":             Color(0.85, 0.25, 0.30),
	"nbn":                 Color(0.90, 0.75, 0.15),
	"weyland-consortium":  Color(0.30, 0.70, 0.35),
	"neutral-corp":        Color(0.55, 0.55, 0.55),
}

var _state:   TournamentState
var _fetcher: TournamentFetcher
var _ai_level: int = 3   # tournament always uses MCTS

# UI references
var _status_label:      Label
var _bracket_container: VBoxContainer
var _action_btn:        Button
var _refresh_btn:       Button
var _back_btn:          Button
var _record_label:      Label
var _rating_panel:      Control


func _ready() -> void:
	_build_ui()


func setup(state: TournamentState) -> void:
	_state = state
	_refresh()


# ── UI Construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	layer = 12

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	# Header
	var header := _build_header()
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.custom_minimum_size = Vector2(0, 100)
	header.offset_bottom = 100
	root.add_child(header)

	# Body — two columns
	var body := HBoxContainer.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.offset_top    = 110
	body.offset_left   = 40
	body.offset_right  = -40
	body.offset_bottom = -40
	body.add_theme_constant_override("separation", 24)
	root.add_child(body)

	# Left: bracket
	var bracket_panel := _make_panel()
	bracket_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bracket_panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	body.add_child(bracket_panel)

	var bracket_vbox := VBoxContainer.new()
	bracket_vbox.add_theme_constant_override("separation", 6)
	bracket_panel.add_child(bracket_vbox)

	var bracket_header := Label.new()
	bracket_header.text = "// OPEN CIRCUIT — ROUND ROBIN //"
	bracket_header.add_theme_font_size_override("font_size", 12)
	bracket_header.add_theme_color_override("font_color", COLOR_ACCENT)
	bracket_vbox.add_child(bracket_header)

	var sep := HSeparator.new()
	sep.add_theme_color_override("separation_color", COLOR_BORDER)
	bracket_vbox.add_child(sep)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", COLOR_INACTIVE)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bracket_vbox.add_child(_status_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bracket_vbox.add_child(scroll)

	_bracket_container = VBoxContainer.new()
	_bracket_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bracket_container.add_theme_constant_override("separation", 6)
	scroll.add_child(_bracket_container)

	# Right: status + controls
	var ctrl_panel := _make_panel()
	ctrl_panel.custom_minimum_size = Vector2(300, 0)
	ctrl_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(ctrl_panel)

	var ctrl_vbox := VBoxContainer.new()
	ctrl_vbox.add_theme_constant_override("separation", 16)
	ctrl_panel.add_child(ctrl_vbox)

	var ctrl_hdr := Label.new()
	ctrl_hdr.text = "// STATUS //"
	ctrl_hdr.add_theme_font_size_override("font_size", 12)
	ctrl_hdr.add_theme_color_override("font_color", COLOR_ACCENT)
	ctrl_vbox.add_child(ctrl_hdr)

	_record_label = Label.new()
	_record_label.text = "W: 0  |  L: 0"
	_record_label.add_theme_font_size_override("font_size", 20)
	_record_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	ctrl_vbox.add_child(_record_label)

	_rating_panel = _build_rating_panel()
	ctrl_vbox.add_child(_rating_panel)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ctrl_vbox.add_child(spacer)

	_action_btn = Button.new()
	_action_btn.text = "▶  FETCH OPPONENTS"
	_action_btn.add_theme_font_size_override("font_size", 14)
	_action_btn.add_theme_color_override("font_color", COLOR_ACCENT)
	_action_btn.pressed.connect(_on_action_pressed)
	ctrl_vbox.add_child(_action_btn)

	_refresh_btn = Button.new()
	_refresh_btn.text = "↺  REFRESH POOL"
	_refresh_btn.add_theme_font_size_override("font_size", 11)
	_refresh_btn.add_theme_color_override("font_color", COLOR_INACTIVE)
	_refresh_btn.pressed.connect(func(): _do_fetch(true))
	_refresh_btn.visible = false
	ctrl_vbox.add_child(_refresh_btn)

	_back_btn = Button.new()
	_back_btn.text = "← RETURN TO CAMPAIGN"
	_back_btn.add_theme_color_override("font_color", COLOR_INACTIVE)
	_back_btn.pressed.connect(func(): closed.emit())
	ctrl_vbox.add_child(_back_btn)


func _build_header() -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.06, 0.04)
	style.border_color = COLOR_BORDER
	style.border_width_bottom = 1
	style.content_margin_left   = 40
	style.content_margin_top    = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	panel.add_child(hbox)

	var title_vbox := VBoxContainer.new()
	title_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(title_vbox)

	var title := Label.new()
	title.text = "OPEN CIRCUIT"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", COLOR_ACCENT)
	title_vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Startup Format  //  Live NRDB Opponents  //  MCTS AI"
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", Color(0.50, 0.42, 0.20))
	title_vbox.add_child(subtitle)

	return panel


func _build_rating_panel() -> Control:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	return vbox


func _make_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color          = COLOR_PANEL
	style.border_color      = COLOR_BORDER
	style.border_width_top  = 1; style.border_width_left   = 1
	style.border_width_right= 1; style.border_width_bottom = 1
	style.corner_radius_top_left     = 6; style.corner_radius_top_right    = 6
	style.corner_radius_bottom_left  = 6; style.corner_radius_bottom_right = 6
	style.content_margin_left   = 20; style.content_margin_right  = 20
	style.content_margin_top    = 16; style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	return panel


# ── Refresh ───────────────────────────────────────────────────────────────────

func _refresh() -> void:
	if _state == null:
		return

	_rebuild_bracket()
	_refresh_record()
	_refresh_action_btn()

	if _state.is_complete():
		_show_rating()
	else:
		_hide_rating()


func _rebuild_bracket() -> void:
	for child in _bracket_container.get_children():
		child.queue_free()

	if not _state.has_active_tournament():
		_status_label.text = "No tournament in progress. Fetch opponents to begin."
		return

	_status_label.text = ""
	var opps   := _state.opponents()
	var results := _state.results()
	var current := _state.current_round()

	for i in range(opps.size()):
		var opp: Dictionary  = opps[i] as Dictionary
		var slot := _make_bracket_slot(i + 1, opp, results, current)
		_bracket_container.add_child(slot)


func _make_bracket_slot(round_num: int, opp: Dictionary, results: Array, current_round: int) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()

	var is_done    := round_num - 1 < results.size()
	var is_current := round_num - 1 == current_round and not _state.is_complete()
	var won        := is_done and (results[round_num - 1] as bool)

	style.bg_color = (
		Color(0.08, 0.12, 0.09) if (is_current and not is_done) else
		Color(0.10, 0.06, 0.06) if (is_done and not won) else
		Color(0.06, 0.10, 0.07) if (is_done and won) else
		Color(0.06, 0.07, 0.08)
	)
	var faction_col: Color = FACTION_COLORS.get(opp.get("faction", ""), COLOR_INACTIVE)
	style.border_color    = (
		COLOR_WIN   if (is_done and won) else
		COLOR_LOSS  if (is_done and not won) else
		COLOR_ACCENT if is_current else
		faction_col
	)
	style.border_width_left = 3
	style.corner_radius_top_left     = 3; style.corner_radius_top_right    = 3
	style.corner_radius_bottom_left  = 3; style.corner_radius_bottom_right = 3
	style.content_margin_left = 14; style.content_margin_right  = 14
	style.content_margin_top  = 10; style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	panel.add_child(hbox)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	hbox.add_child(info)

	var round_label := Label.new()
	round_label.text = "ROUND %d" % round_num
	round_label.add_theme_font_size_override("font_size", 9)
	round_label.add_theme_color_override("font_color",
		COLOR_WIN if (is_done and won) else
		COLOR_LOSS if (is_done and not won) else
		COLOR_ACCENT if is_current else
		COLOR_INACTIVE)
	info.add_child(round_label)

	var name_label := Label.new()
	name_label.text = opp.get("name", "Unknown Deck") as String
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color",
		Color(0.9, 0.9, 0.9) if (is_current or is_done) else COLOR_INACTIVE)
	info.add_child(name_label)

	var detail := Label.new()
	var author: String = opp.get("author", "") as String
	var faction: String = opp.get("faction", "") as String
	detail.text = "%s  ·  %s  ·  ♥ %d" % [
		faction.replace("-", " ").capitalize(),
		("by " + author) if author != "" else "anonymous",
		int(opp.get("likes", 0))
	]
	detail.add_theme_font_size_override("font_size", 10)
	detail.add_theme_color_override("font_color", COLOR_INACTIVE)
	info.add_child(detail)

	# Result badge on right
	var badge := Label.new()
	if is_done:
		badge.text = "WIN" if won else "LOSS"
		badge.add_theme_font_size_override("font_size", 13)
		badge.add_theme_color_override("font_color", COLOR_WIN if won else COLOR_LOSS)
	elif is_current:
		badge.text = "▶ NEXT"
		badge.add_theme_font_size_override("font_size", 11)
		badge.add_theme_color_override("font_color", COLOR_ACCENT)
	else:
		badge.text = "—"
		badge.add_theme_color_override("font_color", COLOR_INACTIVE)
	hbox.add_child(badge)

	return panel


func _refresh_record() -> void:
	if _state == null:
		return
	_record_label.text = "W: %d  |  L: %d" % [_state.wins(), _state.losses()]


func _refresh_action_btn() -> void:
	if _state == null:
		_action_btn.text     = "▶  FETCH OPPONENTS"
		_action_btn.disabled = false
		_refresh_btn.visible = false
		return

	if _state.is_complete():
		_action_btn.text     = "↺  NEW TOURNAMENT"
		_action_btn.disabled = false
		_refresh_btn.visible = true
	elif _state.has_active_tournament():
		_action_btn.text     = "▶  PLAY ROUND %d" % (_state.current_round() + 1)
		_action_btn.disabled = false
		_refresh_btn.visible = false
	else:
		_action_btn.text     = "▶  FETCH OPPONENTS"
		_action_btn.disabled = false
		_refresh_btn.visible = true


func _show_rating() -> void:
	for child in _rating_panel.get_children():
		child.queue_free()

	var rating := _state.get_rating()

	var sep := HSeparator.new()
	sep.add_theme_color_override("separation_color", COLOR_BORDER)
	_rating_panel.add_child(sep)

	var title_lbl := Label.new()
	title_lbl.text = rating.get("title", "") as String
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.add_theme_color_override("font_color", COLOR_ACCENT)
	title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rating_panel.add_child(title_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text = rating.get("subtitle", "") as String
	sub_lbl.add_theme_font_size_override("font_size", 11)
	sub_lbl.add_theme_color_override("font_color", Color(0.6, 0.55, 0.35))
	sub_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rating_panel.add_child(sub_lbl)

	var record_detail := Label.new()
	record_detail.text = "Final: %d–%d" % [_state.wins(), _state.losses()]
	record_detail.add_theme_font_size_override("font_size", 12)
	record_detail.add_theme_color_override("font_color", Color(0.7, 0.7, 0.5))
	_rating_panel.add_child(record_detail)


func _hide_rating() -> void:
	for child in _rating_panel.get_children():
		child.queue_free()


# ── Action button ─────────────────────────────────────────────────────────────

func _on_action_pressed() -> void:
	if _state.is_complete():
		# Start a fresh tournament — re-fetch.
		_state.clear()
		_do_fetch()
	elif _state.has_active_tournament():
		# Play the next round.
		var opp := _state.current_opponent()
		if not opp.is_empty():
			match_requested.emit(opp, _ai_level)
	else:
		_do_fetch()


func _do_fetch(force_refresh: bool = false) -> void:
	_action_btn.disabled  = true
	_refresh_btn.disabled = true
	_status_label.text    = "Connecting to NetrunnerDB…"
	_rebuild_bracket()

	_fetcher = TournamentFetcher.new()
	_fetcher.fetch_progress.connect(func(msg): _status_label.text = msg)

	var result: Dictionary = await _fetcher.fetch(force_refresh)

	_refresh_btn.disabled = false
	if not result.get("ok", false):
		_status_label.text   = "⚠  " + str(result.get("error", "Fetch failed"))
		_action_btn.disabled = false
		_action_btn.text     = "↺  RETRY"
		return

	var pool: Array = result.get("opponents", []) as Array
	_state.start_new_tournament(pool)
	_refresh()


# ── Called by controller after a game ends ────────────────────────────────────

func record_result(runner_wins: bool) -> void:
	_state.record_result(runner_wins)
	_refresh()
	if _state.is_complete():
		_show_rating()
