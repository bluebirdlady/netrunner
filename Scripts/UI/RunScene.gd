# RunScene.gd
# Dedicated UI scene for a single run. Slides in over GameUI when a run begins,
# handles all run-time player decisions, then signals completion so Main can
# remove it and return to GameUI.
#
# Main.gd:
#   1. Instantiates RunScene and adds it as a child
#   2. Reassigns HumanDecisionMaker proxies to RunScene methods
#   3. Calls run_machine.execute(server_id) — which drives the scene
#   4. Connects run_complete signal to clean up and restore GameUI proxies

extends CanvasLayer
class_name RunScene

signal run_complete

# ── Signals used for async decision resolution ────────────────────────────────
signal encounter_action_resolved(action: Dictionary)
signal jack_out_resolved(choice: bool)
signal trash_resolved(choice: bool)
signal payment_resolved(option: Variant)
signal server_choice_resolved(server_id: String)
signal modal_resolved(indices: Array)
signal search_resolved(card: CardRecord)
signal suffer_damage_or_etr_resolved(take_damage: bool)

# ── Engine references ─────────────────────────────────────────────────────────
var ctx:              GameContext
var ability_registry: AbilityRegistry
var run_machine:      RunStateMachine

# ── State ─────────────────────────────────────────────────────────────────────
var _current_server:  Server = null
var _current_ice:     InstalledCard = null
var _access_overlay:  Control = null

# ── Node references (built programmatically) ──────────────────────────────────
var _phase_label:     Label
var _server_col:      VBoxContainer
var _rig_row:         HBoxContainer
var _credits_label:   Label
var _clicks_label:    Label
var _run_log:         TextEdit
var _action_area:     VBoxContainer
var _ice_cards:       Array = []   # Array[CardView] — one per ice, outermost first


# ── Setup ─────────────────────────────────────────────────────────────────────

func setup(game_ctx: GameContext, ab_registry: AbilityRegistry, rsm: RunStateMachine) -> void:
	ctx              = game_ctx
	ability_registry = ab_registry
	run_machine      = rsm

	# Connect run machine signals
	run_machine.phase_changed.connect(_on_phase_changed)
	run_machine.ice_approached.connect(_on_ice_approached)
	run_machine.ice_encountered.connect(_on_ice_encountered)
	run_machine.ice_rezzed.connect(_on_ice_rezzed)
	run_machine.subroutine_broken.connect(_on_subroutine_broken)
	run_machine.run_succeeded.connect(_on_run_succeeded)
	run_machine.run_ended_unsuccessfully.connect(_on_run_ended)
	run_machine.card_accessed.connect(_on_card_accessed)
	if run_machine.has_signal("encounter_started"):
		run_machine.encounter_started.connect(_on_encounter_started)
	if run_machine.has_signal("encounter_updated"):
		run_machine.encounter_updated.connect(_on_encounter_updated)

	# Register async display callback so the engine waits for each card
	# to be shown before proceeding to the next access or phase end.
	ctx.set_meta("on_card_display_done", Callable(self, "_display_accessed_card"))


func start_run(server_id: String) -> void:
	_current_server = ctx.get_server(server_id)
	_rebuild_server_column()
	_rebuild_rig_row()
	_update_resources()
	_log("▶ Run declared on %s" % _current_server.display_name())


# ── UI Construction ───────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10   # above GameUI
	_build_ui()


func _build_ui() -> void:
	# Dark full-screen background
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.04, 0.04, 0.07, 0.96)
	add_child(bg)

	# Root margin
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)

	# Top-level HBox: server column | run info panel
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	margin.add_child(hbox)

	# ── Left: server column ───────────────────────────────────────────────────
	var server_panel := PanelContainer.new()
	server_panel.custom_minimum_size = Vector2(200, 0)
	server_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	server_panel.clip_contents = false
	hbox.add_child(server_panel)

	var server_vbox := VBoxContainer.new()
	server_vbox.add_theme_constant_override("separation", 8)
	server_panel.add_child(server_vbox)

	var server_title := Label.new()
	server_title.text = "SERVER"
	server_title.add_theme_font_size_override("font_size", 11)
	server_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	server_vbox.add_child(server_title)

	# Scroll container so many ice cards don't squish vertically
	var server_scroll := ScrollContainer.new()
	server_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	server_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	server_scroll.clip_contents = false   # allow hovered cards to overflow
	server_vbox.add_child(server_scroll)

	_server_col = VBoxContainer.new()
	_server_col.add_theme_constant_override("separation", 6)
	_server_col.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	server_scroll.add_child(_server_col)

	# ── Centre: runner rig ────────────────────────────────────────────────────
	var rig_panel := PanelContainer.new()
	rig_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rig_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rig_panel.clip_contents = false
	hbox.add_child(rig_panel)

	var rig_vbox := VBoxContainer.new()
	rig_vbox.add_theme_constant_override("separation", 8)
	rig_panel.add_child(rig_vbox)

	# Phase + resources row
	var info_hbox := HBoxContainer.new()
	info_hbox.add_theme_constant_override("separation", 16)
	rig_vbox.add_child(info_hbox)

	_phase_label = Label.new()
	_phase_label.text = "INITIATION"
	_phase_label.add_theme_font_size_override("font_size", 18)
	_phase_label.add_theme_color_override("font_color", Color(0.9, 0.75, 0.3))
	_phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_hbox.add_child(_phase_label)

	_credits_label = Label.new()
	_credits_label.add_theme_font_size_override("font_size", 14)
	_credits_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
	info_hbox.add_child(_credits_label)

	_clicks_label = Label.new()
	_clicks_label.add_theme_font_size_override("font_size", 14)
	_clicks_label.add_theme_color_override("font_color", Color(0.9, 0.6, 0.3))
	info_hbox.add_child(_clicks_label)

	# Rig label
	var rig_title := Label.new()
	rig_title.text = "INSTALLED PROGRAMS & HARDWARE"
	rig_title.add_theme_font_size_override("font_size", 11)
	rig_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	rig_vbox.add_child(rig_title)

	var rig_scroll := ScrollContainer.new()
	rig_scroll.custom_minimum_size = Vector2(0, 180)
	rig_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rig_scroll.clip_contents = false   # allow hovered cards to overflow
	rig_vbox.add_child(rig_scroll)

	_rig_row = HBoxContainer.new()
	_rig_row.add_theme_constant_override("separation", 8)
	rig_scroll.add_child(_rig_row)

	# Run log
	var log_title := Label.new()
	log_title.text = "RUN LOG"
	log_title.add_theme_font_size_override("font_size", 11)
	log_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	rig_vbox.add_child(log_title)

	_run_log = TextEdit.new()
	_run_log.editable = false
	_run_log.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_run_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_run_log.add_theme_font_size_override("font_size", 11)
	rig_vbox.add_child(_run_log)

	# ── Right: action area ────────────────────────────────────────────────────
	var action_panel := PanelContainer.new()
	action_panel.custom_minimum_size = Vector2(260, 0)
	action_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(action_panel)

	var action_vbox := VBoxContainer.new()
	action_vbox.add_theme_constant_override("separation", 6)
	action_panel.add_child(action_vbox)

	var action_title := Label.new()
	action_title.text = "ACTIONS"
	action_title.add_theme_font_size_override("font_size", 11)
	action_title.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	action_vbox.add_child(action_title)

	_action_area = VBoxContainer.new()
	_action_area.add_theme_constant_override("separation", 6)
	_action_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	action_vbox.add_child(_action_area)


# ── Server column ─────────────────────────────────────────────────────────────

func _rebuild_server_column() -> void:
	for child in _server_col.get_children():
		child.queue_free()
	_ice_cards.clear()

	if _current_server == null:
		return

	var name_lbl := Label.new()
	name_lbl.text = _current_server.display_name()
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_server_col.add_child(name_lbl)

	# Ice — outermost first
	var ice_lbl := Label.new()
	ice_lbl.text = "ICE (outermost → innermost)"
	ice_lbl.add_theme_font_size_override("font_size", 10)
	ice_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	_server_col.add_child(ice_lbl)

	if _current_server.ice.is_empty():
		var no_ice := Label.new()
		no_ice.text = "(no ice)"
		no_ice.add_theme_font_size_override("font_size", 11)
		no_ice.add_theme_color_override("font_color", Color(0.4, 0.4, 0.5))
		_server_col.add_child(no_ice)
	else:
		for ice in _current_server.ice:
			var c: InstalledCard = ice as InstalledCard
			var card_view := CardView.new()
			card_view.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			_server_col.add_child(card_view)
			card_view.setup(c.card_record, c.is_rezzed)
			_ice_cards.append(card_view)

	# Root
	if not _current_server.root.is_empty():
		var root_lbl := Label.new()
		root_lbl.text = "ROOT"
		root_lbl.add_theme_font_size_override("font_size", 10)
		root_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		_server_col.add_child(root_lbl)
		for root_card in _current_server.root:
			var c: InstalledCard = root_card as InstalledCard
			var card_view := CardView.new()
			card_view.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			_server_col.add_child(card_view)
			card_view.setup(c.card_record, c.is_rezzed)


func _highlight_ice(ice_card: InstalledCard) -> void:
	# Dim all ice, highlight the current one
	for i in range(_current_server.ice.size()):
		if i < _ice_cards.size():
			var view: CardView = _ice_cards[i] as CardView
			var ice: InstalledCard = _current_server.ice[i] as InstalledCard
			var is_current := (ice == ice_card)
			view.modulate = Color(1, 1, 1, 1) if is_current else Color(0.4, 0.4, 0.4, 0.7)
			if is_current:
				view.scale = Vector2(1.1, 1.1)
			else:
				view.scale = Vector2(1.0, 1.0)


func _reset_ice_highlight() -> void:
	for view in _ice_cards:
		(view as CardView).modulate = Color(1, 1, 1, 1)
		(view as CardView).scale    = Vector2(1, 1)


# ── Runner rig ────────────────────────────────────────────────────────────────

func _rebuild_rig_row() -> void:
	for child in _rig_row.get_children():
		child.queue_free()

	for rig_card in ctx.runner_rig:
		var c: InstalledCard = rig_card as InstalledCard
		if c.card_record == null:
			continue

		var container := VBoxContainer.new()
		container.add_theme_constant_override("separation", 4)
		_rig_row.add_child(container)

		var card_view := CardView.new()
		container.add_child(card_view)
		card_view.setup(c.card_record, true)

		# Strength badge for icebreakers
		if c.card_record.has_strength():
			var str_lbl := Label.new()
			var base_str: int = c.card_record.strength
			var board_bonus: int = ctx.query_breaker_strength_bonus() if ctx.has_method("query_breaker_strength_bonus") else 0
			str_lbl.text = "STR %d" % (base_str + board_bonus)
			str_lbl.add_theme_font_size_override("font_size", 11)
			str_lbl.add_theme_color_override("font_color", Color(0.4, 0.9, 0.9))
			str_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			container.add_child(str_lbl)

		# Hosted counter badge
		var credits: int = c.get_counter("credits")
		var power: int   = c.get_counter("power")
		var virus: int   = c.get_counter("virus")
		if credits > 0 or power > 0 or virus > 0:
			var ctr_lbl := Label.new()
			var parts: Array = []
			if credits > 0: parts.append("%d¢" % credits)
			if power   > 0: parts.append("%d★" % power)
			if virus   > 0: parts.append("%d⚡" % virus)
			ctr_lbl.text = " ".join(parts)
			ctr_lbl.add_theme_font_size_override("font_size", 10)
			ctr_lbl.add_theme_color_override("font_color", Color(0.9, 0.7, 0.3))
			ctr_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			container.add_child(ctr_lbl)


# ── Resources ─────────────────────────────────────────────────────────────────

func _update_resources() -> void:
	_credits_label.text = "¢ %d" % ctx.runner_credits
	_clicks_label.text  = "● %d" % ctx.runner_clicks


# ── Action area helpers ───────────────────────────────────────────────────────

func _clear_actions() -> void:
	for child in _action_area.get_children():
		child.queue_free()


func _add_btn(label: String, callback: Callable, color: Color = Color(0.8, 0.8, 0.8)) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.alignment = HorizontalAlignment.HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_color_override("font_color", color)
	btn.pressed.connect(callback)
	_action_area.add_child(btn)
	return btn


func _add_section(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	_action_area.add_child(lbl)


func _log(msg: String) -> void:
	_run_log.text += msg + "\n"
	_run_log.scroll_vertical = _run_log.get_line_count()


# ── Run machine signal handlers ───────────────────────────────────────────────

func _on_phase_changed(phase: RunStateMachine.Phase) -> void:
	var names := ["INITIATION", "APPROACH ICE", "ENCOUNTER", "MOVEMENT", "SUCCESS", "END"]
	_phase_label.text = names[phase] if phase < names.size() else str(phase)
	_update_resources()
	_clear_actions()
	# Fire run_complete after a brief display pause when the run fully ends
	if phase == RunStateMachine.Phase.END:
		# Remove the display callback so it doesn't reference this freed scene
		if ctx.has_meta("on_card_display_done"):
			ctx.remove_meta("on_card_display_done")
		await get_tree().create_timer(0.8).timeout
		run_complete.emit()


func _on_ice_approached(ice_card: InstalledCard) -> void:
	_current_ice = ice_card
	# Refresh server column in case ice was just rezzed
	_rebuild_server_column()
	_highlight_ice(ice_card)
	var name := ice_card.display_name() if ice_card.is_rezzed else "unrezzed ice"
	_log("→ Approaching %s" % name)


func _on_ice_encountered(ice_card: InstalledCard) -> void:
	_current_ice = ice_card
	_highlight_ice(ice_card)
	_log("⚔ Encountering %s (str %d)" % [
		ice_card.display_name(),
		ice_card.card_record.strength if ice_card.card_record else 0
	])


func _on_ice_rezzed(ice_card: InstalledCard) -> void:
	_rebuild_server_column()
	_highlight_ice(ice_card)
	_log("🔓 Corp rezzes %s" % ice_card.display_name())


func _on_subroutine_broken(ice_card: InstalledCard, sub_index: int) -> void:
	_log("✓ Subroutine %d broken" % sub_index)


func _on_encounter_started(encounter: EncounterState) -> void:
	_update_resources()
	_rebuild_rig_row()


func _on_encounter_updated(encounter: EncounterState) -> void:
	_update_resources()
	_rebuild_rig_row()


func _on_run_succeeded(_server_id: String) -> void:
	_reset_ice_highlight()
	_log("✅ Run successful!")
	_update_resources()


func _on_run_ended(_reason: String) -> void:
	_reset_ice_highlight()
	_log("❌ Run ended")
	_update_resources()


# ── Access result display ────────────────────────────────────────────────────

# Called by the signal handler — kept for logging/minor side effects only.
# The engine now drives display sequencing via _display_accessed_card.
func _on_card_accessed(card_record: CardRecord, outcome: String) -> void:
	_log("📋 Accessed: %s [%s]" % [card_record.title if card_record else "?", outcome])


# Awaitable callback registered on ctx as "on_card_display_done".
# RunStateMachine calls this after each card_accessed signal and awaits it,
# so the engine pauses until the player has seen the card.
func _display_accessed_card(card_record: CardRecord, outcome: String) -> void:
	await _show_access_result(card_record, outcome)


func _show_access_result(card_record: CardRecord, outcome: String) -> void:
	# Build full-screen access overlay
	if _access_overlay != null:
		_access_overlay.queue_free()

	_access_overlay = Control.new()
	_access_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_access_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_access_overlay)

	# Dark background
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.75)
	_access_overlay.add_child(bg)

	# Centre column
	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_CENTER)
	col.offset_left   = -160
	col.offset_right  = 160
	col.offset_top    = -260
	col.offset_bottom = 260
	col.alignment     = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 16)
	_access_overlay.add_child(col)

	# Outcome banner
	var outcome_colors := {
		"stolen":   Color(0.95, 0.8,  0.2),
		"trashed":  Color(0.9,  0.3,  0.3),
		"accessed": Color(0.6,  0.85, 1.0),
	}
	var banner := Label.new()
	var outcome_upper := outcome.to_upper()
	banner.text = outcome_upper
	banner.add_theme_font_size_override("font_size", 28)
	banner.add_theme_color_override("font_color",
		outcome_colors.get(outcome, Color(0.8, 0.8, 0.8)))
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(banner)

	# Card image
	if card_record != null:
		var card_view := CardView.new()
		col.add_child(card_view)
		card_view.setup(card_record, true)
		# Scale up the card view for readability
		card_view.scale = Vector2(1.6, 1.6)
		# Centre-align within column
		card_view.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

		# Card title and type below
		var title_lbl := Label.new()
		title_lbl.text = card_record.title
		title_lbl.add_theme_font_size_override("font_size", 16)
		title_lbl.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
		title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(title_lbl)

		if card_record.is_agenda():
			var pts_lbl := Label.new()
			pts_lbl.text = "%d agenda point(s)" % card_record.agenda_points
			pts_lbl.add_theme_font_size_override("font_size", 13)
			pts_lbl.add_theme_color_override("font_color",
				outcome_colors.get(outcome, Color(0.8, 0.8, 0.8)))
			pts_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			col.add_child(pts_lbl)
	else:
		var unknown_lbl := Label.new()
		unknown_lbl.text = "(card)"
		unknown_lbl.add_theme_font_size_override("font_size", 14)
		unknown_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		unknown_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(unknown_lbl)

	# Dismiss button or auto-dismiss
	var is_agenda := card_record != null and card_record.is_agenda()
	if is_agenda:
		# Agendas wait for explicit dismiss — they're important
		var dismiss_btn := Button.new()
		dismiss_btn.text = "Continue"
		dismiss_btn.add_theme_font_size_override("font_size", 14)
		col.add_child(dismiss_btn)
		await dismiss_btn.pressed
	else:
		# Non-agendas auto-dismiss after a pause long enough to read the card
		await get_tree().create_timer(3.0).timeout

	if _access_overlay != null:
		_access_overlay.queue_free()
		_access_overlay = null


# ── Decision maker methods (proxies point here during run) ────────────────────

func show_encounter_prompt(encounter: EncounterState) -> Dictionary:
	_clear_actions()
	_update_resources()
	_rebuild_rig_row()

	var ice_name := encounter.ice_card.display_name() if encounter.ice_card else "ice"
	_add_section("%s  str %d" % [ice_name, encounter.effective_ice_strength()])

	# Subroutine status
	for i in range(encounter.subroutines.size()):
		var sub: Dictionary = encounter.subroutines[i] as Dictionary
		var broken_marker := "✓ " if encounter.is_broken(i) else "↳ "
		var color := Color(0.4, 0.7, 0.4) if encounter.is_broken(i) else Color(0.8, 0.2, 0.2)
		var lbl := Label.new()
		lbl.text = broken_marker + sub.get("label", "sub %d" % i)
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_color_override("font_color", color)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_action_area.add_child(lbl)

	# Bioroid click-break
	if encounter.ice_card != null and encounter.ice_card.card_record != null:
		if encounter.ice_card.card_record.has_subtype("bioroid") and ctx.runner_clicks > 0:
			_add_section("BIOROID — spend 1 click:")
			for i in range(encounter.subroutines.size()):
				if encounter.is_broken(i):
					continue
				var sub: Dictionary = encounter.subroutines[i] as Dictionary
				var idx := i
				_add_btn("[1●] Break: %s" % sub.get("label", "sub %d" % i),
					func(): encounter_action_resolved.emit({"type": "break_with_click", "sub_index": idx}),
					Color(0.9, 0.7, 0.3))

	# Icebreaker actions
	var breakers := encounter.breakers_for_ice()
	if not breakers.is_empty():
		_add_section("ICEBREAKERS:")
		for breaker in breakers:
			var b: InstalledCard = breaker as InstalledCard
			var b_str := encounter.get_breaker_strength(b)
			var can_reach := encounter.breaker_reaches(b)
			var reach_color := Color(0.4, 0.9, 0.5) if can_reach else Color(0.8, 0.4, 0.4)

			_add_section("%s  str %d %s" % [
				b.display_name(), b_str,
				"✓" if can_reach else "✗ (too weak)"
			])

			var ice_stypes: Array = encounter.ice_card.card_record.subtypes \
				if encounter.ice_card != null and encounter.ice_card.card_record != null else []
			ice_stypes = ice_stypes + (encounter.ice_card.extra_subtypes \
				if encounter.ice_card != null else [])
			var break_label: String = _break_btn_label(b, ice_stypes)
			var break_btn := _add_btn(break_label,
				func(): encounter_action_resolved.emit({"type": "break_all", "card_id": b.card_id}),
				reach_color)
			break_btn.disabled = not can_reach

			var boost_label: String = "Boost  (%s)" % _boost_cost_label(b)
			_add_btn(boost_label,
				func(): encounter_action_resolved.emit({"type": "boost_strength", "card_id": b.card_id, "times": 1}),
				Color(0.5, 0.7, 0.9))

	# Encounter-spendable hosted credits (e.g. cards with "encounter_spend_credits" flag).
	# Cards like Telework Contract, Pennyshaver, and Smartware Distributor hold their
	# credits for click actions or automatic payouts — they must NOT appear here.
	for rig_card in ctx.runner_rig:
		var rc: InstalledCard = rig_card as InstalledCard
		if rc == null or rc.card_record == null:
			continue
		var card_def: Dictionary = ability_registry._abilities.get(rc.card_id, {}) as Dictionary
		if not card_def.get("encounter_spend_credits", false):
			continue
		var hosted: int = rc.get_counter("credits")
		if hosted > 0:
			var cid := rc.card_id
			_add_btn("Spend 1¢ from %s  (%d remaining)" % [rc.display_name(), hosted],
				func(): encounter_action_resolved.emit({"type": "spend_hosted_credits", "card_id": cid, "amount": 1}),
				Color(0.9, 0.7, 0.3))

	# Leech-style: spend a virus counter to give the encountered ice -1 strength.
	# Only cards with "encounter_weaken_ice": true in abilities.json are eligible.
	for rig_card in ctx.runner_rig:
		var rc: InstalledCard = rig_card as InstalledCard
		if rc == null or rc.card_record == null:
			continue
		var card_def: Dictionary = ability_registry._abilities.get(rc.card_id, {}) as Dictionary
		if not card_def.get("encounter_weaken_ice", false):
			continue
		var counters: int = rc.get_counter("virus")
		if counters > 0:
			var cid := rc.card_id
			_add_btn("Use %s: ice gets -1 str  (%d virus left)" % [rc.display_name(), counters],
				func(): encounter_action_resolved.emit({"type": "weaken_ice", "card_id": cid}),
				Color(0.6, 0.9, 0.5))

	# Self-break ability (e.g. N-Pot: 3cr to break 1 sub, runner-only)
	if encounter.ice_card != null and ability_registry != null:
		var ice_def: Dictionary = ability_registry._abilities.get(encounter.ice_card.card_id, {}) as Dictionary
		var self_break: Dictionary = ice_def.get("runner_self_break", {}) as Dictionary
		if not self_break.is_empty():
			var sb_cost: int = self_break.get("cost_per_sub", 0)
			var has_unbroken := false
			for i in range(encounter.subroutines.size()):
				if not encounter.is_broken(i):
					has_unbroken = true
					break
			if has_unbroken:
				_add_section("SELF-BREAK (%dcr each):" % sb_cost)
				for i in range(encounter.subroutines.size()):
					if encounter.is_broken(i):
						continue
					var sub: Dictionary = encounter.subroutines[i] as Dictionary
					var captured_i := i
					var sb_btn := _add_btn(
						"%dcr: Break \"%s\"" % [sb_cost, sub.get("label", "sub %d" % i)],
						func(): encounter_action_resolved.emit({
							"type": "break_self_sub",
							"sub_index": captured_i,
							"cost": sb_cost
						}),
						Color(0.4, 0.85, 1.0)
					)
					sb_btn.disabled = ctx.runner_credits < sb_cost

	# Banner (and future suppress_etr_action programs): 2cr to suppress ETR subs on a barrier.
	for _ban_rig in ctx.runner_rig:
		var _ban_ic: InstalledCard = _ban_rig as InstalledCard
		if _ban_ic == null or _ban_ic.card_record == null:
			continue
		var _ban_def: Dictionary = ability_registry._abilities.get(_ban_ic.card_id, {}) \
			.get("suppress_etr_action", {}) as Dictionary
		if _ban_def.is_empty():
			continue
		# Gate: encountered ice must be a barrier and suppression not already active.
		var _ban_is_barrier := encounter.ice_card != null and \
			encounter.ice_card.card_record != null and \
			encounter.ice_card.card_record.has_subtype("barrier")
		if not _ban_is_barrier or encounter.barrier_etr_suppressed:
			continue
		var _ban_cost: int = _ban_def.get("cost", 2)
		var _ban_captured: InstalledCard = _ban_ic
		_add_section("BANNER:")
		var _ban_btn := _add_btn(
			"%s — %dcr: Suppress all ETR subs this encounter" % [_ban_captured.display_name(), _ban_cost],
			func(): encounter_action_resolved.emit({
				"type": "suppress_etr_subs",
				"card_id": _ban_captured.card_id
			}),
			Color(0.9, 0.75, 0.3))
		_ban_btn.disabled = ctx.runner_available_credits() < _ban_cost

	# Trojan interface break abilities (e.g. Slap Vandal: 1cr to break 1 sub, once per encounter).
	# Show buttons for each trojan hosted on the encountered ice that has an "interface_break" key.
	if encounter.ice_card != null and not encounter.ice_card.hosted_cards.is_empty():
		var _ib_section_shown := false
		for _ib_hc in encounter.ice_card.hosted_cards:
			var _ib_ic: InstalledCard = _ib_hc as InstalledCard
			if _ib_ic == null or _ib_ic.card_record == null:
				continue
			var _ib_def: Dictionary = ability_registry._abilities.get(_ib_ic.card_id, {}) \
				.get("interface_break", {}) as Dictionary
			if _ib_def.is_empty():
				continue
			var _ib_cost: int          = _ib_def.get("cost_per_sub", 1)
			var _ib_once: bool         = _ib_def.get("once_per_encounter", false)
			var _ib_already_used: bool = encounter.trojan_used_this_encounter.get(_ib_ic.card_id, false)
			if _ib_once and _ib_already_used:
				continue  # already fired this encounter — skip entirely
			if not _ib_section_shown:
				_add_section("TROJAN INTERFACE:")
				_ib_section_shown = true
			var _ib_card_captured: InstalledCard = _ib_ic
			var _ib_can_afford: bool = ctx.runner_available_credits() >= _ib_cost
			for _ib_i in range(encounter.subroutines.size()):
				if encounter.is_broken(_ib_i):
					continue
				var _ib_sub: Dictionary = encounter.subroutines[_ib_i] as Dictionary
				var _ib_captured_i: int = _ib_i
				var _ib_btn := _add_btn(
					"%s — %dcr: Break \"%s\"" % [_ib_card_captured.display_name(), _ib_cost,
						_ib_sub.get("label", "sub %d" % _ib_i)],
					func(): encounter_action_resolved.emit({
						"type": "trojan_break_sub",
						"card_id": _ib_card_captured.card_id,
						"sub_index": _ib_captured_i
					}),
					Color(0.7, 0.9, 0.5))
				_ib_btn.disabled = not _ib_can_afford

	# Umbrella (and future umbrella_break programs): show if installed, ice has hosted trojan, and ice is code gate.
	for _umb_rig in ctx.runner_rig:
		var _umb_ic: InstalledCard = _umb_rig as InstalledCard
		if _umb_ic == null or _umb_ic.card_record == null:
			continue
		var _umb_def: Dictionary = ability_registry._abilities.get(_umb_ic.card_id, {}) \
			.get("umbrella_break", {}) as Dictionary
		if _umb_def.is_empty():
			continue
		# Gate: ice must have at least one hosted trojan.
		var _umb_has_trojan := false
		if encounter.ice_card != null:
			for _umb_hc in encounter.ice_card.hosted_cards:
				if (_umb_hc as InstalledCard) != null:
					_umb_has_trojan = true
					break
		if not _umb_has_trojan:
			continue
		# Gate: ice must match required subtypes (default: code_gate).
		var _umb_required: Array = _umb_def.get("subtypes", ["code_gate"]) as Array
		var _umb_type_ok := false
		if encounter.ice_card != null and encounter.ice_card.card_record != null:
			var _umb_ice_stypes: Array = encounter.ice_card.card_record.subtypes + encounter.ice_card.extra_subtypes
			for _umb_rst in _umb_required:
				if _umb_ice_stypes.has(_umb_rst):
					_umb_type_ok = true
					break
		if not _umb_type_ok:
			continue
		var _umb_cost: int      = _umb_def.get("cost_per_sub", 2)
		var _umb_cap: int       = _umb_def.get("subs_per_use", 3)
		var _umb_unbroken: int  = encounter.unbroken_indices().size()
		var _umb_to_break: int  = mini(_umb_unbroken, _umb_cap)
		var _umb_total: int     = _umb_cost * _umb_to_break
		var _umb_can_afford: bool = ctx.runner_available_credits() >= _umb_cost  # at least 1
		var _umb_captured: InstalledCard = _umb_ic
		_add_section("UMBRELLA:")
		var _umb_btn := _add_btn(
			"%s — %dcr each: Break up to %d code gate sub(s)" % [
				_umb_captured.display_name(), _umb_cost, _umb_cap],
			func(): encounter_action_resolved.emit({
				"type": "umbrella_break",
				"card_id": _umb_captured.card_id
			}),
			Color(0.5, 0.75, 1.0))
		_umb_btn.disabled = not _umb_can_afford or _umb_unbroken == 0

	# Encounter paid abilities (e.g. Malandragem bypass, Physarum Entangler, Arruaceiras Crew).
	# Any runner-rig card (or trojan hosted on the current ice) with "encounter_ability" in abilities.json.
	var _enc_ab_cards: Array = ctx.runner_rig.duplicate()
	for _enc_srv in ctx.servers.values():
		for _enc_ice in (_enc_srv as Server).ice:
			for _enc_hosted in (_enc_ice as InstalledCard).hosted_cards:
				_enc_ab_cards.append(_enc_hosted)
	var _enc_ab_section_shown := false
	for _enc_rig_card in _enc_ab_cards:
		var _enc_rc: InstalledCard = _enc_rig_card as InstalledCard
		if _enc_rc == null or _enc_rc.card_record == null:
			continue
		var _enc_cdef: Dictionary = ability_registry._abilities.get(_enc_rc.card_id, {}) as Dictionary
		var _enc_adef: Dictionary = _enc_cdef.get("encounter_ability", {}) as Dictionary
		if _enc_adef.is_empty():
			continue
		var _enc_modes: Array = _enc_adef.get("modes", []) as Array
		for _enc_mi in range(_enc_modes.size()):
			var _enc_mode: Dictionary = _enc_modes[_enc_mi] as Dictionary
			# Check per-mode condition
			if not _eval_encounter_mode_condition(_enc_mode, encounter, ctx, _enc_rc):
				continue
			if not _enc_ab_section_shown:
				_add_section("ENCOUNTER ABILITIES:")
				_enc_ab_section_shown = true
			var _enc_card_captured: InstalledCard = _enc_rc
			var _enc_mode_idx_captured: int = _enc_mi
			var _enc_mode_lbl: String = _enc_mode.get("label", "%s ability %d" % [_enc_rc.display_name(), _enc_mi])
			var _enc_can_afford: bool = _can_afford_encounter_mode(_enc_mode, ctx, _enc_rc)
			var _enc_btn := _add_btn(
				_enc_mode_lbl,
				func(): encounter_action_resolved.emit({
					"type": "use_encounter_ability",
					"card_id": _enc_card_captured.card_id,
					"mode_index": _enc_mode_idx_captured
				}),
				Color(0.6, 0.8, 1.0)
			)
			_enc_btn.disabled = not _enc_can_afford

	# Spree: event set run_modifiers["spree_counters"]; offer trojan-move during encounter.
	var _spree_count: int = ctx.run_modifiers.get("spree_counters", 0)
	if _spree_count > 0:
		var _spree_trojans: Array = []
		for _sp_rig in ctx.runner_rig:
			var _sp_ic: InstalledCard = _sp_rig as InstalledCard
			if _sp_ic != null and _sp_ic.hosted_on_id != "":
				_spree_trojans.append(_sp_ic)
		# Also scan hosted_cards on server ice
		for _sp_srv in ctx.servers.values():
			for _sp_ice in (_sp_srv as Server).ice:
				for _sp_hosted in (_sp_ice as InstalledCard).hosted_cards:
					if not _spree_trojans.has(_sp_hosted):
						_spree_trojans.append(_sp_hosted)
		if not _spree_trojans.is_empty():
			_add_section("SPREE (%d counter(s)):" % _spree_count)
			_add_btn("1 counter: Move a trojan to ice protecting this server",
				func(): encounter_action_resolved.emit({"type": "spree_move_trojan"}),
				Color(0.9, 0.6, 0.3))

	_add_section("─────────────────")
	_add_btn("Pass — let subroutines fire",
		func(): encounter_action_resolved.emit({"type": "done"}),
		Color(0.7, 0.4, 0.4))

	var result: Dictionary = await encounter_action_resolved
	_clear_actions()
	return result


func show_jack_out_prompt() -> bool:
	_clear_actions()
	_add_section("Jack out?")
	_add_btn("Yes — Jack Out",
		func(): jack_out_resolved.emit(true),
		Color(0.9, 0.6, 0.3))
	_add_btn("No — Continue Run",
		func(): jack_out_resolved.emit(false),
		Color(0.4, 0.9, 0.5))

	var result: bool = await jack_out_resolved
	_clear_actions()
	return result


func show_suffer_damage_or_etr_prompt(amount: int, damage_type: String) -> bool:
	_clear_actions()
	_add_section("Semak-samun — end the run, or suffer %d %s damage to continue?" % [amount, damage_type])
	_add_btn("End the Run",
		func(): suffer_damage_or_etr_resolved.emit(false),
		Color(0.6, 0.6, 0.65))
	var dmg_btn := _add_btn(
		"Suffer %d %s Damage" % [amount, damage_type.capitalize()],
		func(): suffer_damage_or_etr_resolved.emit(true),
		Color(1.0, 0.4, 0.4))
	if ctx.runner_hand.size() < amount:
		dmg_btn.disabled = true
	var result: bool = await suffer_damage_or_etr_resolved
	_clear_actions()
	return result


func show_trash_prompt(card: CardRecord) -> bool:
	_clear_actions()
	var cost: int  = _compute_effective_trash_cost(card)
	var title := card.title if card else "card"
	var available: int = ctx.runner_trash_credits_available()
	_add_section("Trash %s for %d¢?" % [title, cost])
	_add_btn("Yes — Trash  (%d¢ available)" % available,
		func(): trash_resolved.emit(true),
		Color(0.9, 0.4, 0.4))
	_add_btn("No — Leave it",
		func(): trash_resolved.emit(false))

	var result: bool = await trash_resolved
	_clear_actions()
	return result


# Effective trash cost = base + modifiers from rezzed cards in the same server (e.g. Mahkota +2).
func _compute_effective_trash_cost(card: CardRecord) -> int:
	var cost: int = card.trash_cost if card else 0
	# Only apply server modifiers during an active run
	if not ctx.run_active:
		return cost
	var server: Server = ctx.get_server(ctx.run_target_server)
	if server == null or card == null or not card.is_asset():
		return cost
	if not ctx.has_meta("ability_registry"):
		return cost
	var ab_reg: AbilityRegistry = ctx.get_meta("ability_registry") as AbilityRegistry
	for root_card in server.root:
		var rc: InstalledCard = root_card as InstalledCard
		if rc == null or not rc.is_rezzed:
			continue
		var rc_def: Dictionary = ab_reg._abilities.get(rc.card_id, {}) as Dictionary
		cost += int(rc_def.get("trash_cost_increase_own_server_assets", 0))
	return cost


func show_payment_option_prompt(options: Array) -> Variant:
	_clear_actions()
	_add_section("Manegarm Skunkworks — pay to continue:")
	for opt in options:
		var o: Dictionary = opt as Dictionary
		var label := ""
		match o.get("type", ""):
			"clicks":  label = "Spend %d click(s)  (%d available)" % [o.get("amount", 0), ctx.runner_clicks]
			"credits": label = "Pay %d¢  (%d available)" % [o.get("amount", 0), ctx.runner_credits]
		var captured := o
		_add_btn(label, func(): payment_resolved.emit(captured), Color(0.9, 0.7, 0.3))
	_add_btn("End the run", func(): payment_resolved.emit(null), Color(0.7, 0.4, 0.4))

	var result: Variant = await payment_resolved
	_clear_actions()
	return result


func show_server_choice_prompt(allowed_servers: Array) -> String:
	_clear_actions()
	_add_section("Choose a server to run:")
	for server_id in allowed_servers:
		var display: String = {"hq": "HQ", "rd": "R&D", "archives": "Archives"}.get(server_id, server_id)
		var sid: String = server_id
		_add_btn(display, func(): server_choice_resolved.emit(sid))

	var result: String = await server_choice_resolved
	_clear_actions()
	return result


func show_modal_prompt(modes: Array, max_choices: int) -> Array:
	_clear_actions()
	_add_section("Choose %d option(s):" % max_choices)
	var chosen: Array = []
	for i in range(modes.size()):
		var mode: Dictionary = modes[i] as Dictionary
		var idx := i
		_add_btn(mode.get("label", "Option %d" % i), func():
			chosen.append(idx)
			if chosen.size() >= max_choices:
				modal_resolved.emit(chosen.duplicate())
		)

	var result: Array = await modal_resolved
	_clear_actions()
	return result


func show_search_prompt(candidates: Array) -> CardRecord:
	_clear_actions()
	_add_section("Search — take which card?")
	for candidate in candidates:
		var r: CardRecord = candidate as CardRecord
		if r == null:
			continue
		var cost_str := "%d¢" % r.cost if r.cost >= 0 else "free"
		var record := r
		_add_btn("%s  [%s] (%s)" % [r.title, r.card_type.capitalize(), cost_str],
			func(): search_resolved.emit(record))

	var result: CardRecord = await search_resolved
	_clear_actions()
	return result


# ── Discard to hand limit (run-time variant) ──────────────────────────────────

func show_discard_to_hand_limit_prompt(hand: Array, excess: int) -> Array:
	_clear_actions()
	_add_section("Discard %d card(s) to reach hand limit." % excess)

	var selected: Array = []
	var counter_lbl := Label.new()
	counter_lbl.text = "Selected: 0 / %d" % excess
	_action_area.add_child(counter_lbl)

	var confirm_btn := Button.new()
	confirm_btn.text = "Confirm"
	confirm_btn.disabled = true
	# will add after toggle buttons

	var toggle_buttons: Array = []

	for entry in hand:
		var ed: Dictionary = entry as Dictionary
		var cr: CardRecord = ed.get("card_record", null) as CardRecord
		if cr == null:
			continue
		var card_name: String = cr.title
		var tog := Button.new()
		tog.text = "[ ]  %s" % card_name
		tog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tog.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var captured_entry: Dictionary = entry as Dictionary
		tog.pressed.connect(func():
			if captured_entry in selected:
				selected.erase(captured_entry)
				tog.text = "[ ]  %s" % card_name
			else:
				if selected.size() < excess:
					selected.append(captured_entry)
					tog.text = "[✓]  %s" % card_name
			counter_lbl.text = "Selected: %d / %d" % [selected.size(), excess]
			confirm_btn.disabled = selected.size() != excess
		)
		_action_area.add_child(tog)
		toggle_buttons.append(tog)

	_action_area.add_child(confirm_btn)

	var done := [false]
	confirm_btn.pressed.connect(func(): done[0] = true)

	while not done[0]:
		await get_tree().process_frame

	_clear_actions()
	return selected


# ── Choose subroutines to break (run-time variant) ───────────────────────────

func show_choose_subs_to_break_prompt(candidates: Array, max_count: int, encounter: EncounterState) -> Array:
	_clear_actions()
	_add_section("Choose %d subroutine(s) to break:" % max_count)

	var selected: Array = []
	var counter_lbl := Label.new()
	counter_lbl.text = "Selected: 0 / %d" % max_count
	_action_area.add_child(counter_lbl)

	var confirm_btn := Button.new()
	confirm_btn.text = "Confirm"
	confirm_btn.disabled = true

	for idx in candidates:
		var sub_dict: Dictionary = encounter.subroutines[idx] as Dictionary
		var sub_label: String = sub_dict.get("label", "Subroutine %d" % idx)
		var tog := Button.new()
		tog.text = "[ ]  %s" % sub_label
		tog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tog.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var captured_idx: int = idx as int
		tog.pressed.connect(func():
			if captured_idx in selected:
				selected.erase(captured_idx)
				tog.text = "[ ]  %s" % sub_label
			else:
				if selected.size() < max_count:
					selected.append(captured_idx)
					tog.text = "[✓]  %s" % sub_label
			counter_lbl.text = "Selected: %d / %d" % [selected.size(), max_count]
			confirm_btn.disabled = selected.size() != max_count
		)
		_action_area.add_child(tog)

	_action_area.add_child(confirm_btn)

	var done := [false]
	confirm_btn.pressed.connect(func(): done[0] = true)

	while not done[0]:
		await get_tree().process_frame

	_clear_actions()
	return selected


# ── Encounter ability condition helpers ──────────────────────────────────────

## Returns true when the encounter_ability mode's condition is satisfied.
## Supports a subset of condition types sufficient for Step-2 cards.
func _eval_encounter_mode_condition(mode: Dictionary, encounter: EncounterState,
		game_ctx: GameContext, card: InstalledCard) -> bool:
	var cond: Dictionary = mode.get("condition", {}) as Dictionary
	if cond.is_empty():
		return true

	var ctype: String = cond.get("type", "")
	match ctype:
		"self_counter_gte":
			var counter: String = cond.get("counter", "power")
			var threshold: int  = cond.get("threshold", 1)
			return card.get_counter(counter) >= threshold

		"threat_gte":
			var value: int = cond.get("value", 4)
			return game_ctx.threat_level() >= value

		"not_triggered_this_turn_for_card":
			var key: String = cond.get("key", "")
			var full_key: String = card.runtime_instance_id + ":" + key
			return not game_ctx.once_per_turn_triggered.get(full_key, false)

		"encountered_ice_str_lte":
			var threshold: int = cond.get("threshold", 0)
			return encounter.effective_ice_strength() <= threshold

		"host_is_non_barrier":
			# True when the encountered ice has no "barrier" subtype.
			if encounter.ice_card == null or encounter.ice_card.card_record == null:
				return false
			var hsub: Array = encounter.ice_card.card_record.subtypes.duplicate()
			for hes in encounter.ice_card.extra_subtypes:
				if not hsub.has(hes):
					hsub.append(hes)
			return not hsub.has("barrier")

		"runner_has_clicks":
			var needed: int = cond.get("amount", 1)
			return game_ctx.runner_clicks >= needed

		"run_modifier_false":
			# True when a run_modifiers key is absent or false (i.e. the ability hasn't been used this run).
			var key: String = cond.get("key", "")
			return not game_ctx.run_modifiers.get(key, false)

		"and":
			var conditions: Array = cond.get("conditions", []) as Array
			for c in conditions:
				if not _eval_encounter_mode_condition({"condition": c as Dictionary}, encounter, game_ctx, card):
					return false
			return true

	# Unknown condition type — assume true (fail safe)
	return true


## Returns true when the runner can currently afford the cost of an encounter mode.
func _can_afford_encounter_mode(mode: Dictionary, game_ctx: GameContext, card: InstalledCard) -> bool:
	var credit_cost: int = mode.get("cost_credits", 0)
	var click_cost:  int = mode.get("cost_clicks", 0)
	var counter_type: String = (mode.get("cost_counter", {}) as Dictionary).get("type", "")
	var counter_amt:  int    = (mode.get("cost_counter", {}) as Dictionary).get("amount", 0)

	# physarum_entangler: cost = 1cr per unbroken sub — compute dynamically
	for _cam_eff in (mode.get("effects", []) as Array):
		if (_cam_eff as Dictionary).get("type", "") == "physarum_bypass_host_ice":
			var penc: EncounterState = game_ctx.get_meta("_current_encounter") as EncounterState \
				if game_ctx.has_meta("_current_encounter") else null
			if penc != null:
				credit_cost += penc.unbroken_indices().size()

	if credit_cost > 0 and game_ctx.runner_available_credits() < credit_cost:
		return false
	if click_cost > 0 and game_ctx.runner_clicks < click_cost:
		return false
	if counter_type != "" and counter_amt > 0 and card.get_counter(counter_type) < counter_amt:
		return false
	return true


# ── Encounter button cost-label helpers ──────────────────────────────────────
# Build human-readable cost strings from the ability definition so button labels
# are accurate regardless of card (not hardcoded to "1¢").

func _break_btn_label(b: InstalledCard, ice_subtypes: Array) -> String:
	# Returns the full break button text, e.g.:
	#   "Break 1 sub  (1¢)"          — subs_per_use: 1
	#   "Break up to 2 subs  (1¢ each)" — subs_per_use: 2
	#   "Break all subs  (1¢ each)"  — subs_per_use: 0 (uncapped)
	if ability_registry == null:
		return "Break subs  (?)"
	var bd_variant: Variant = ability_registry.get_break_for_ice(b.card_id, ice_subtypes)
	if bd_variant == null:
		return "Break subs  (?)"
	var bd: Dictionary = bd_variant as Dictionary
	var cap: int = bd.get("subs_per_use", 0)

	# ── Sub-count prefix ─────────────────────────────────────────────────────
	var prefix: String
	match cap:
		0:  prefix = "Break all subs"
		1:  prefix = "Break 1 sub"
		_:  prefix = "Break up to %d subs" % cap

	# ── Cost suffix ──────────────────────────────────────────────────────────
	var cost_str: String
	if (bd.get("cost_virus_counter", 0) as int) > 0:
		cost_str = "1 virus each" if cap != 1 else "1 virus"
	elif (bd.get("cost_virus_counter_flat", 0) as int) > 0:
		var fc: int = bd.get("cost_virus_counter_flat", 1)
		cost_str = "%d virus flat" % fc
	elif (bd.get("cost_power_counter_overhead", 0) as int) > 0:
		var pc: int = bd.get("cost_power_counter_overhead", 1)
		var cps: int = bd.get("cost_per_sub", 0)
		cost_str = "%d pwr + %d¢ each" % [pc, cps] if cps > 0 else "%d pwr counter" % pc
	elif bd.get("costs_stealth", false):
		var cost: int = bd.get("cost_per_sub", 1)
		cost_str = "%d stealth each" % cost if cap != 1 else "%d stealth" % cost
	else:
		var cost: int = bd.get("cost_per_sub", 1)
		if cost == 0:
			cost_str = "free"
		elif cap == 1:
			cost_str = "%d¢" % cost
		else:
			cost_str = "%d¢ each" % cost

	return "%s  (%s)" % [prefix, cost_str]


func _boost_cost_label(b: InstalledCard) -> String:
	if ability_registry == null:
		return "?"
	var bd_variant: Variant = ability_registry.get_boost(b.card_id)
	if bd_variant == null:
		return "?"
	var bd: Dictionary = bd_variant as Dictionary
	var gain: int = bd.get("strength_gained", 1)

	if (bd.get("cost_power_counter", 0) as int) > 0:
		return "1 pwr → +%d str" % gain
	if (bd.get("cost_trash_grip", 0) as int) > 0:
		return "trash 1 → +%d str" % gain
	if bd.get("costs_stealth", false):
		var cost: int = bd.get("cost", 1)
		return "%d stealth → +%d str" % [cost, gain]
	if bd.get("strength_gained_modifier", "") == "installed_icebreaker_count":
		var cost: int = bd.get("cost", 1)
		return "%d¢ → +str/icebreaker" % cost
	var cost: int = bd.get("cost", 1)
	return "%d¢ → +%d str" % [cost, gain]
