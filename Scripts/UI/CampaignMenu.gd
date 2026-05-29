class_name CampaignMenu
extends CanvasLayer

# ── CampaignMenu ──────────────────────────────────────────────────────────────
# Hub screen showing available missions, completion state, and arc context.
# Emits mission_selected(mission_id) when a mission is chosen.
# Emits fiction_requested(fiction_id) for re-reading unlocked fiction.

signal mission_selected(mission_id: String, ai_level: int)
signal fiction_requested(fiction_id: String)
signal starter_match_requested()

var _campaign_state: CampaignState
var _fiction_viewer: FictionViewer
var _mission_list_container: VBoxContainer
var _fiction_list_container: VBoxContainer

const COLOR_BG        := Color(0.04, 0.05, 0.07)
const COLOR_ACCENT    := Color(0.25, 0.85, 0.45)
const COLOR_INACTIVE  := Color(0.3, 0.35, 0.3)
const COLOR_COMPLETE  := Color(0.3, 0.55, 0.35)
const COLOR_AVAILABLE := Color(0.2, 0.75, 0.4)
const COLOR_PANEL     := Color(0.07, 0.09, 0.11)
const COLOR_BORDER    := Color(0.15, 0.28, 0.18)


func _ready() -> void:
	_build_ui()


func setup(campaign_state: CampaignState) -> void:
	_campaign_state = campaign_state
	_fiction_viewer = FictionViewer.new()
	add_child(_fiction_viewer)
	_refresh()


func _refresh() -> void:
	if _mission_list_container == null:
		push_error("CampaignMenu: mission list container not found")
		return
	# Clear existing children
	for child in _mission_list_container.get_children():
		child.queue_free()
	_populate_missions(_mission_list_container)
	_populate_fiction_archive()


# ── UI Construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	layer = 10

	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# Background
	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	# Scanline effect — same as FictionViewer
	var scanlines := _make_scanlines()
	root.add_child(scanlines)

	# Header
	var header := _build_header()
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.custom_minimum_size = Vector2(0, 100)
	header.offset_bottom = 100
	root.add_child(header)

	# Main content area
	var content := HBoxContainer.new()
	content.name = "Content"
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.offset_top    = 110
	content.offset_left   = 40
	content.offset_right  = -40
	content.offset_bottom = -40
	content.add_theme_constant_override("separation", 32)
	root.add_child(content)

	# Left: mission list
	var mission_panel := _make_panel()
	mission_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mission_panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	content.add_child(mission_panel)

	var mission_vbox := VBoxContainer.new()
	mission_vbox.add_theme_constant_override("separation", 6)
	mission_panel.add_child(mission_vbox)

	var mission_header := Label.new()
	mission_header.text = "// AVAILABLE RUNS //"
	mission_header.add_theme_font_size_override("font_size", 12)
	mission_header.add_theme_color_override("font_color", Color(0.3, 0.6, 0.35))
	mission_vbox.add_child(mission_header)

	var sep := HSeparator.new()
	sep.add_theme_color_override("separation_color", COLOR_BORDER)
	mission_vbox.add_child(sep)

	var mission_list := VBoxContainer.new()
	mission_list.name = "MissionList"
	mission_list.add_theme_constant_override("separation", 8)
	mission_vbox.add_child(mission_list)
	_mission_list_container = mission_list

	# Right: fiction archive
	var fiction_panel := _make_panel()
	fiction_panel.custom_minimum_size = Vector2(340, 0)
	fiction_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(fiction_panel)

	var fiction_vbox := VBoxContainer.new()
	fiction_vbox.add_theme_constant_override("separation", 6)
	fiction_panel.add_child(fiction_vbox)

	var fiction_header := Label.new()
	fiction_header.text = "// TRANSMISSIONS //"
	fiction_header.add_theme_font_size_override("font_size", 12)
	fiction_header.add_theme_color_override("font_color", Color(0.3, 0.6, 0.35))
	fiction_vbox.add_child(fiction_header)

	var sep2 := HSeparator.new()
	sep2.add_theme_color_override("separation_color", COLOR_BORDER)
	fiction_vbox.add_child(sep2)

	var fiction_list := VBoxContainer.new()
	fiction_list.name = "FictionList"
	fiction_list.add_theme_constant_override("separation", 4)
	fiction_vbox.add_child(fiction_list)
	_fiction_list_container = fiction_list


func _build_header() -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.10)
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

	var title_label := Label.new()
	title_label.text = "CONVENTION BREAKER"
	title_label.add_theme_font_size_override("font_size", 28)
	title_label.add_theme_color_override("font_color", COLOR_ACCENT)
	title_vbox.add_child(title_label)

	var subtitle_label := Label.new()
	subtitle_label.text = "A Runner Campaign  //  System Gateway"
	subtitle_label.add_theme_font_size_override("font_size", 11)
	subtitle_label.add_theme_color_override("font_color", Color(0.35, 0.5, 0.38))
	title_vbox.add_child(subtitle_label)

	# In _build_header() after the deck builder button
	var classic_btn := Button.new()
	classic_btn.text = "// STARTER MATCH"
	classic_btn.add_theme_color_override("font_color", Color(0.7, 0.7, 0.4))
	classic_btn.pressed.connect(func(): starter_match_requested.emit())
	hbox.add_child(classic_btn)

	# Deck builder button in header
	var deck_btn := Button.new()
	deck_btn.text = "// BUILD DECK"
	deck_btn.add_theme_color_override("font_color", Color(0.4, 0.8, 0.55))
	deck_btn.pressed.connect(_open_deck_builder)
	hbox.add_child(deck_btn)

	return panel


func _open_deck_builder() -> void:
	if _campaign_state == null:
		return
	var builder := DeckBuilder.new()
	add_child(builder)
	builder.setup(_campaign_state)
	builder.deck_saved.connect(func(_id, _cards):
		# Refresh the menu after saving
		_refresh()
	)
	builder.cancelled.connect(func(): pass)


func _populate_missions(container: VBoxContainer) -> void:
	if _campaign_state == null:
		print("CampaignMenu: no campaign state")
		return

	var available := _campaign_state.get_available_missions()
	print("Available missions count: ", available.size())
	for mission in available:
		print(" - ", mission.get("id", "no id"))
		container.add_child(_make_mission_card(mission))

	# Also show completed missions (greyed out with re-play option)
	# This ensures nothing is ever blocked off
	var all_missions: Array = []  # would come from campaign_state if needed
	if available.is_empty():
		var empty := Label.new()
		empty.text = "No runs available."
		empty.add_theme_color_override("font_color", COLOR_INACTIVE)
		container.add_child(empty)

	# Populate fiction archive
	_populate_fiction_archive()


func _make_mission_card(mission: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var is_complete := _campaign_state.is_mission_complete(mission.get("id", ""))

	var style := StyleBoxFlat.new()
	style.bg_color     = Color(0.08, 0.11, 0.09) if not is_complete else Color(0.06, 0.09, 0.07)
	style.border_color = COLOR_AVAILABLE if not is_complete else COLOR_COMPLETE
	style.border_width_left = 3
	style.corner_radius_top_left     = 4
	style.corner_radius_top_right    = 4
	style.corner_radius_bottom_left  = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left   = 16
	style.content_margin_right  = 16
	style.content_margin_top    = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title := Label.new()
	title.text = mission.get("title", "???").to_upper()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color",
		COLOR_AVAILABLE if not is_complete else COLOR_COMPLETE)
	title_row.add_child(title)

	if is_complete:
		var badge := Label.new()
		badge.text = "✓ CLEARED"
		badge.add_theme_font_size_override("font_size", 10)
		badge.add_theme_color_override("font_color", COLOR_COMPLETE)
		title_row.add_child(badge)

	var ai_level: int = mission.get("ai_level", 0) as int
	if ai_level >= 1:
		var ai_badge := Label.new()
		ai_badge.text = "◈ TACTICAL AI" if ai_level == 1 else "◈ PREDICTIVE AI"
		ai_badge.add_theme_font_size_override("font_size", 10)
		ai_badge.add_theme_color_override("font_color",
			Color(0.85, 0.65, 0.2) if ai_level == 1 else Color(0.9, 0.42, 0.25))
		title_row.add_child(ai_badge)

	var subtitle := Label.new()
	subtitle.text = mission.get("subtitle", "")
	subtitle.add_theme_font_size_override("font_size", 10)
	subtitle.add_theme_color_override("font_color", Color(0.35, 0.5, 0.38))
	vbox.add_child(subtitle)

	# Opponent info
	var opponent_id: String = mission.get("opponent_id", "")
	var opponent := _campaign_state.get_opponent(opponent_id)
	if not opponent.is_empty():
		var opp_label := Label.new()
		opp_label.text = "TARGET: %s" % opponent.get("name", "Unknown")
		opp_label.add_theme_font_size_override("font_size", 11)
		opp_label.add_theme_color_override("font_color", Color(0.75, 0.4, 0.35))
		vbox.add_child(opp_label)

		var desc := Label.new()
		desc.text = opponent.get("description", "")
		desc.add_theme_font_size_override("font_size", 10)
		desc.add_theme_color_override("font_color", Color(0.45, 0.5, 0.45))
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(desc)

	var mid: String         = mission.get("id", "")
	var default_level: int  = mission.get("ai_level", 0) as int

	if not is_complete:
		# First run — locked to the mission's designed AI level
		var run_btn := Button.new()
		run_btn.text = "▶  INITIATE RUN"
		run_btn.add_theme_color_override("font_color", COLOR_AVAILABLE)
		run_btn.pressed.connect(func(): _on_mission_run_pressed(mid, default_level))
		vbox.add_child(run_btn)
	else:
		# Mission cleared — let the player choose a difficulty for replay
		var diff_sep := HSeparator.new()
		diff_sep.add_theme_color_override("separation_color", COLOR_BORDER)
		vbox.add_child(diff_sep)

		var diff_label := Label.new()
		diff_label.text = "REPLAY DIFFICULTY:"
		diff_label.add_theme_font_size_override("font_size", 9)
		diff_label.add_theme_color_override("font_color", Color(0.35, 0.45, 0.38))
		vbox.add_child(diff_label)

		var btn_row := HBoxContainer.new()
		btn_row.add_theme_constant_override("separation", 4)
		vbox.add_child(btn_row)

		var difficulty_tiers := [
			{"label": "▶  STANDARD",   "level": 0, "color": COLOR_COMPLETE},
			{"label": "▶  TACTICAL",   "level": 1, "color": Color(0.85, 0.65, 0.2)},
			{"label": "▶  PREDICTIVE", "level": 2, "color": Color(0.9, 0.42, 0.25)},
		]
		for tier in difficulty_tiers:
			var btn := Button.new()
			btn.text = tier["label"] as String
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.add_theme_font_size_override("font_size", 10)
			btn.add_theme_color_override("font_color", tier["color"] as Color)
			var lvl: int = tier["level"] as int
			btn.pressed.connect(func(): _on_mission_run_pressed(mid, lvl))
			btn_row.add_child(btn)

	return panel


func _populate_fiction_archive() -> void:
	if _fiction_list_container == null:
		return
	for child in _fiction_list_container.get_children():
		child.queue_free()

	# Show all fiction ids that are read
	var fiction_entries := [
		{"id": "act1_pre",  "title": "Starter",         "act": 1},
		{"id": "act1_post", "title": "Breach Detected",  "act": 1},
		{"id": "act2a_pre", "title": "Rush Job",          "act": 2},
		{"id": "act2a_post","title": "A Helping Hand",    "act": 2},
		{"id": "act2b_pre", "title": "Gachapon",          "act": 2},
		{"id": "act2b_post","title": "What You Found",    "act": 2},
	]

	for entry in fiction_entries:
		var fid: String = entry["id"]
		var is_read := _campaign_state.is_fiction_read(fid)
		var btn := Button.new()
		btn.text = ("📄  %s" % entry["title"]) if is_read else "//  [ENCRYPTED]"
		btn.disabled = not is_read
		btn.add_theme_color_override("font_color",
			Color(0.6, 0.8, 0.62) if is_read else Color(0.25, 0.3, 0.25))
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		if is_read:
			btn.pressed.connect(func(): _on_fiction_reread(fid))
		_fiction_list_container.add_child(btn)


# ── Event handlers ────────────────────────────────────────────────────────────

func _on_mission_run_pressed(mission_id: String, ai_level: int) -> void:
	# Show pre-match fiction (first read only), then emit mission_selected with level.
	var mission := _campaign_state.get_mission(mission_id)
	var fiction_id: String = mission.get("fiction_pre", "")
	var already_read: bool = _campaign_state.is_fiction_read(fiction_id)
	if fiction_id != "" and not already_read and _fiction_viewer != null:
		_fiction_viewer.show_fiction(
			_campaign_state.get_fiction_text(fiction_id),
			func(): mission_selected.emit(mission_id, ai_level)
		)
		_refresh()   # update "read" state in fiction archive
	else:
		mission_selected.emit(mission_id, ai_level)


func _on_fiction_reread(fiction_id: String) -> void:
	if _fiction_viewer != null:
		_fiction_viewer.show_fiction(
			_campaign_state.get_fiction_text(fiction_id),
			func(): pass
		)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color          = COLOR_PANEL
	style.border_color      = COLOR_BORDER
	style.border_width_top  = 1
	style.border_width_left = 1
	style.border_width_right  = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left     = 6
	style.corner_radius_top_right    = 6
	style.corner_radius_bottom_left  = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left   = 20
	style.content_margin_right  = 20
	style.content_margin_top    = 16
	style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _make_scanlines() -> Control:
	var scanlines := ColorRect.new()
	scanlines.set_anchors_preset(Control.PRESET_FULL_RECT)
	var shader_code := """
shader_type canvas_item;
void fragment() {
	float line = mod(FRAGCOORD.y, 4.0);
	float alpha = line < 2.0 ? 0.0 : 0.04;
	COLOR = vec4(0.0, 0.0, 0.0, alpha);
}
"""
	var shader := Shader.new()
	shader.code = shader_code
	var mat := ShaderMaterial.new()
	mat.shader = shader
	scanlines.material = mat
	return scanlines
