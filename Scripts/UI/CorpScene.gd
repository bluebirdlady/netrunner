# CorpScene.gd
extends CanvasLayer
class_name CorpScene

# ── CorpScene ─────────────────────────────────────────────────────────────────
# Full-screen Corp-player UI. Active for the entire game when corp_mode = true.
# Displays servers from the Corp's perspective (all own cards face-up) and
# provides Corp action menu, multi-step install flow, and reactive prompts
# (rez, paid ability window, discard) wired through CorpHumanBrain proxies.

signal action_requested(action: GameAction)
signal game_over_acknowledged

# Async resolution signals — one per awaited proxy call
signal _rez_resolved(choice: bool)
signal _window_resolved(action: GameAction)
signal _discard_resolved(entry: Dictionary)
signal _trash_choice_resolved(instance_id: String)
signal _optional_resolved(choice: bool)
signal _modes_resolved(indices: Array)
signal _psi_resolved(bid: int)
signal _trace_resolved(boost: int)
signal _server_resolved(server_id: String)
signal _card_from_hand_resolved(entry: Variant)
signal _forfeit_resolved(card: Variant)
signal _trash_from_rig_resolved(card: InstalledCard)
signal _runner_type_resolved(type_str: String)

# ── Symbol constants (matching GameUI) ────────────────────────────────────────
const SYM_BASE   := "res://Assets/Art/Game Symbols/Exported/"
const SYM_CREDIT := SYM_BASE + "NSG_CREDIT.png"
const SYM_CLICK  := SYM_BASE + "NSG_CLICK.png"
const SYM_AGENDA := SYM_BASE + "NSG_AGENDA.png"
const SYM_TAG    := SYM_BASE + "NSG_TAG.png"
const SYM_HQ     := SYM_BASE + "NSG_HQ_Icon.png"
const SYM_RD     := SYM_BASE + "NSG_RD_Icon.png"
const SYM_ARC    := SYM_BASE + "NSG_Archives_Icon.png"

const BBQ_CR  := "[img height=16]" + SYM_CREDIT + "[/img]"
const BBQ_CL  := "[img height=16]" + SYM_CLICK  + "[/img]"
const BBQ_AG  := "[img height=16]" + SYM_AGENDA + "[/img]"
const BBQ_TG  := "[img height=16]" + SYM_TAG    + "[/img]"
const BBQ_HQ  := "[img height=18]" + SYM_HQ     + "[/img]"
const BBQ_RD  := "[img height=18]" + SYM_RD     + "[/img]"
const BBQ_ARC := "[img height=18]" + SYM_ARC    + "[/img]"

# ── Engine refs ───────────────────────────────────────────────────────────────
var _ctx:              GameContext
var _ability_registry: AbilityRegistry
var _run_machine:      RunStateMachine

# ── Node refs (built in _build_layout) ───────────────────────────────────────
var _resource_label:     RichTextLabel
var _servers_container:  HBoxContainer
var _hq_hand_container:  HBoxContainer
var _log_text:           RichTextLabel
var _action_menu:        VBoxContainer
var _run_status_panel:   PanelContainer   # shows active run state; hidden when idle
var _run_status_label:   RichTextLabel

# ── Install flow state ────────────────────────────────────────────────────────
var _install_card: CardRecord = null   # card chosen in step 1


# ── Setup ─────────────────────────────────────────────────────────────────────

func setup(ctx: GameContext, turn_manager: TurnManager, run_machine: RunStateMachine,
		ability_registry: AbilityRegistry = null) -> void:
	_ctx              = ctx
	_run_machine      = run_machine
	_ability_registry = ability_registry

	_build_layout()

	turn_manager.turn_started.connect(_on_turn_started)
	turn_manager.action_executed.connect(_on_action_executed)
	turn_manager.action_rejected.connect(_on_action_rejected)
	turn_manager.game_over.connect(_on_game_over)

	run_machine.phase_changed.connect(_on_run_phase_changed)
	run_machine.ice_approached.connect(func(ice: InstalledCard):
		_log_run("Runner approaches %s." % (ice.card_record.title if ice.is_rezzed else "unrezzed ICE"))
		_update_run_status_approach(ice)
	)
	run_machine.ice_encountered.connect(func(ice: InstalledCard):
		if ice.is_rezzed:
			_log_run("Runner encounters %s." % ice.card_record.title)
	)
	run_machine.encounter_started.connect(func(enc: EncounterState):
		_update_run_status_encounter(enc)
	)
	run_machine.encounter_updated.connect(func(enc: EncounterState):
		_update_run_status_encounter(enc)
	)
	run_machine.ice_rezzed.connect(func(ice: InstalledCard):
		_log_run("You rez %s." % ice.card_record.title)
		_update_all_displays()
	)
	run_machine.run_succeeded.connect(func(srv: String):
		_log_run("Runner makes a successful run on %s." % srv.to_upper())
		_clear_run_status()
		_update_all_displays()
	)
	run_machine.run_ended_unsuccessfully.connect(func(reason: String):
		_log_run("Run ended — %s." % reason)
		_clear_run_status()
		_update_all_displays()
	)
	run_machine.timing_window_opened.connect(func(_actor: String):
		_set_run_status_phase("PAID ABILITY WINDOW")
	)
	run_machine.timing_window_closed.connect(func():
		_set_run_status_phase("")
	)

	_log("// NETRUNNER — CORPORATE INTERFACE //\n// CORP FEED ACTIVE //\n")
	_update_all_displays()


# ── Layout construction ───────────────────────────────────────────────────────

func _build_layout() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left",   8)
	margin.add_theme_constant_override("margin_right",  8)
	margin.add_theme_constant_override("margin_top",    6)
	margin.add_theme_constant_override("margin_bottom", 6)
	add_child(margin)

	var main_hbox := HBoxContainer.new()
	main_hbox.add_theme_constant_override("separation", 8)
	margin.add_child(main_hbox)

	# ── Left panel: board state ───────────────────────────────────────────────
	var state_panel := PanelContainer.new()
	state_panel.custom_minimum_size = Vector2(720, 0)
	state_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hbox.add_child(state_panel)

	var state_bg := StyleBoxFlat.new()
	state_bg.bg_color = Color(0.05, 0.06, 0.10, 1.0)
	state_bg.border_color = Color(0.0, 0.60, 0.85, 0.6)
	state_bg.set_border_width_all(1)
	state_bg.set_corner_radius_all(3)
	state_panel.add_theme_stylebox_override("panel", state_bg)

	var state_vbox := VBoxContainer.new()
	state_vbox.add_theme_constant_override("separation", 6)
	state_panel.add_child(state_vbox)

	# Resource / status line
	_resource_label = RichTextLabel.new()
	_resource_label.bbcode_enabled = true
	_resource_label.fit_content    = true
	_resource_label.scroll_active  = false
	_resource_label.add_theme_font_size_override("normal_font_size", 13)
	state_vbox.add_child(_resource_label)

	state_vbox.add_child(HSeparator.new())

	# Servers area (horizontal scroll)
	var servers_scroll := ScrollContainer.new()
	servers_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	servers_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	servers_scroll.custom_minimum_size    = Vector2(0, 300)
	servers_scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	state_vbox.add_child(servers_scroll)

	_servers_container = HBoxContainer.new()
	_servers_container.add_theme_constant_override("separation", 10)
	servers_scroll.add_child(_servers_container)

	state_vbox.add_child(HSeparator.new())

	# HQ hand label
	var hq_lbl := Label.new()
	hq_lbl.text = "HQ (your hand):"
	hq_lbl.add_theme_font_size_override("font_size", 11)
	hq_lbl.add_theme_color_override("font_color", Color(0.5, 0.75, 1.0))
	state_vbox.add_child(hq_lbl)

	var hq_scroll := ScrollContainer.new()
	hq_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	hq_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_DISABLED
	hq_scroll.custom_minimum_size    = Vector2(0, 120)
	state_vbox.add_child(hq_scroll)

	_hq_hand_container = HBoxContainer.new()
	_hq_hand_container.add_theme_constant_override("separation", 6)
	hq_scroll.add_child(_hq_hand_container)

	# Runner rig label
	var rig_lbl := Label.new()
	rig_lbl.text = "Runner rig:"
	rig_lbl.add_theme_font_size_override("font_size", 11)
	rig_lbl.add_theme_color_override("font_color", Color(0.75, 0.5, 0.5))
	state_vbox.add_child(rig_lbl)

	# ── Right panel: log + action menu ────────────────────────────────────────
	var control_vbox := VBoxContainer.new()
	control_vbox.custom_minimum_size    = Vector2(320, 0)
	control_vbox.size_flags_horizontal  = Control.SIZE_SHRINK_END
	control_vbox.add_theme_constant_override("separation", 6)
	main_hbox.add_child(control_vbox)

	_log_text = RichTextLabel.new()
	_log_text.bbcode_enabled = true
	_log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_text.add_theme_color_override("font_color", Color(0.55, 0.85, 0.65))
	_log_text.add_theme_color_override("background_color", Color(0.04, 0.06, 0.08))
	_log_text.add_theme_font_size_override("font_size", 12)
	control_vbox.add_child(_log_text)

	# Run status panel — visible during active SimRunner runs
	_run_status_panel = PanelContainer.new()
	_run_status_panel.visible = false
	var rs_style := StyleBoxFlat.new()
	rs_style.bg_color            = Color(0.06, 0.08, 0.14, 0.95)
	rs_style.border_color        = Color(0.85, 0.55, 0.1, 0.9)
	rs_style.set_border_width_all(1)
	rs_style.set_corner_radius_all(2)
	rs_style.content_margin_left   = 8
	rs_style.content_margin_right  = 8
	rs_style.content_margin_top    = 6
	rs_style.content_margin_bottom = 6
	_run_status_panel.add_theme_stylebox_override("panel", rs_style)
	control_vbox.add_child(_run_status_panel)

	_run_status_label = RichTextLabel.new()
	_run_status_label.bbcode_enabled = true
	_run_status_label.fit_content    = true
	_run_status_label.scroll_active  = false
	_run_status_label.add_theme_font_size_override("normal_font_size", 11)
	_run_status_panel.add_child(_run_status_label)

	var action_scroll := ScrollContainer.new()
	action_scroll.custom_minimum_size   = Vector2(0, 320)
	action_scroll.size_flags_vertical   = Control.SIZE_SHRINK_END
	action_scroll.vertical_scroll_mode  = ScrollContainer.SCROLL_MODE_AUTO
	action_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	control_vbox.add_child(action_scroll)

	_action_menu = VBoxContainer.new()
	_action_menu.add_theme_constant_override("separation", 4)
	action_scroll.add_child(_action_menu)


# ── Display updates ───────────────────────────────────────────────────────────

func _update_all_displays() -> void:
	if _ctx == null:
		return
	_update_resources()
	_update_servers()
	_update_hq_hand()
	_populate_action_menu()


func _update_resources() -> void:
	var corp_pts   := _ctx.corp_agenda_points()
	var runner_pts := _ctx.runner_agenda_points()
	var pts_to_win := _ctx.agenda_points_to_win
	var corp_name  := _ctx.corp_name()
	var runner_name := _ctx.runner_name()

	var corp_pts_str   := "[color=#aaffaa]%d / %d pts[/color]" % [corp_pts,   pts_to_win]
	var runner_pts_str := "[color=#ffaaaa]%d / %d pts[/color]" % [runner_pts, pts_to_win]

	var runner_hand_count := _ctx.runner_hand.size() if "runner_hand" in _ctx else 0
	var corp_rd_count := _ctx.corp_deck.size() if "corp_deck" in _ctx else 0

	var tag_str := ""
	if _ctx.runner_tags > 0:
		tag_str = "  %s[color=#ff9944]%d[/color]" % [BBQ_TG, _ctx.runner_tags]

	_resource_label.text = (
		"[b]%s (YOU)[/b]  %s%d  %s%d  %s  R&D: %d cards\n" % [
			corp_name, BBQ_CR, _ctx.corp_credits, BBQ_CL, _ctx.corp_clicks,
			corp_pts_str, corp_rd_count
		] +
		"[b]%s[/b]  %s%d  %s  grip: %d%s" % [
			runner_name, BBQ_CR, _ctx.runner_credits, runner_pts_str,
			runner_hand_count, tag_str
		]
	)


func _update_servers() -> void:
	for child in _servers_container.get_children():
		child.queue_free()

	if _ctx == null:
		return

	var central_order := {"hq": 0, "rd": 1, "archives": 2}
	var server_ids: Array = _ctx.servers.keys()
	server_ids.sort_custom(func(a, b):
		var ao: int = central_order.get(a, 999)
		var bo: int = central_order.get(b, 999)
		return ao < bo if ao != bo else a < b
	)

	for server_id in server_ids:
		var server: Server = _ctx.servers[server_id] as Server
		_servers_container.add_child(_create_server_column(server_id, server))


func _create_server_column(server_id: String, server: Server) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(130, 0)
	col.add_theme_constant_override("separation", 4)

	# Server name
	var name_lbl := RichTextLabel.new()
	name_lbl.bbcode_enabled = true
	name_lbl.fit_content    = true
	name_lbl.scroll_active  = false
	name_lbl.add_theme_font_size_override("normal_font_size", 13)
	var icon_tag := ""
	match server_id:
		"hq":       icon_tag = BBQ_HQ  + " "
		"rd":       icon_tag = BBQ_RD  + " "
		"archives": icon_tag = BBQ_ARC + " "
	name_lbl.text = "[center]%s%s[/center]" % [icon_tag, server.display_name()]
	col.add_child(name_lbl)

	# Corp identity above HQ
	if server_id == "hq" and _ctx.corp_identity != null:
		var id_view := CardView.new()
		id_view.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		id_view.setup(_ctx.corp_identity, true)
		col.add_child(id_view)

	# ICE stack (outermost first = index 0), Corp sees all face-up
	if not server.ice.is_empty():
		var ice_lbl := Label.new()
		ice_lbl.text = "ICE (%d):" % server.ice.size()
		ice_lbl.add_theme_font_size_override("font_size", 10)
		ice_lbl.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
		col.add_child(ice_lbl)

		for ice_card in server.ice:
			var ic: InstalledCard = ice_card as InstalledCard
			if ic == null:
				continue
			var ice_col := VBoxContainer.new()
			ice_col.add_theme_constant_override("separation", 2)
			ice_col.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			col.add_child(ice_col)

			var iv := CardView.new()
			iv.setup(ic.card_record, true)   # Corp always sees own ICE face-up
			ice_col.add_child(iv)

			var status_lbl := Label.new()
			status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			status_lbl.add_theme_font_size_override("font_size", 10)
			if ic.is_rezzed:
				status_lbl.text = "REZZED"
				status_lbl.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
			else:
				status_lbl.text = "unrezzed"
				status_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			ice_col.add_child(status_lbl)

			for ctr_type in ["virus", "power", "credits"]:
				var ctr_amt: int = ic.get_counter(ctr_type)
				if ctr_amt <= 0:
					continue
				var ctr_lbl := Label.new()
				ctr_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				ctr_lbl.add_theme_font_size_override("font_size", 10)
				match ctr_type:
					"credits": ctr_lbl.add_theme_color_override("font_color", Color(0.85, 0.75, 0.2))
					"power":   ctr_lbl.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
					"virus":   ctr_lbl.add_theme_color_override("font_color", Color(0.65, 0.3, 0.9))
				ctr_lbl.text = "%s: %d" % [ctr_type.capitalize(), ctr_amt]
				ice_col.add_child(ctr_lbl)

	# Root cards — agendas, assets, upgrades — all face-up to Corp
	for root_card in server.root:
		var rc: InstalledCard = root_card as InstalledCard
		if rc == null or rc.card_record == null:
			continue

		var card_col := VBoxContainer.new()
		card_col.add_theme_constant_override("separation", 2)
		card_col.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(card_col)

		var rv := CardView.new()
		rv.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		rv.setup(rc.card_record, true)
		card_col.add_child(rv)

		# Rez status for non-agendas
		if not rc.card_record.is_agenda():
			var rs_lbl := Label.new()
			rs_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			rs_lbl.add_theme_font_size_override("font_size", 10)
			if rc.is_rezzed:
				rs_lbl.text = "REZZED"
				rs_lbl.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
			else:
				rs_lbl.text = "unrezzed"
				rs_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			card_col.add_child(rs_lbl)

		# Advancement counter + requirement
		var adv: int = rc.get_counter("advancement")
		if adv > 0 or rc.card_record.is_agenda():
			var adv_lbl := Label.new()
			adv_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			adv_lbl.add_theme_font_size_override("font_size", 11)
			var req: int = rc.card_record.advancement_requirement
			if req > 0:
				var ready_color := Color(1.0, 0.85, 0.2) if adv >= req else Color(0.7, 0.7, 0.7)
				adv_lbl.add_theme_color_override("font_color", ready_color)
				adv_lbl.text = "▲ %d / %d" % [adv, req]
			else:
				adv_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.5))
				adv_lbl.text = "▲ %d" % adv
			card_col.add_child(adv_lbl)

		for ctr_type in ["credits", "power", "virus"]:
			var ctr_amt: int = rc.get_counter(ctr_type)
			if ctr_amt <= 0:
				continue
			var ctr_lbl := Label.new()
			ctr_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			ctr_lbl.add_theme_font_size_override("font_size", 10)
			match ctr_type:
				"credits": ctr_lbl.add_theme_color_override("font_color", Color(0.85, 0.75, 0.2))
				"power":   ctr_lbl.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
				"virus":   ctr_lbl.add_theme_color_override("font_color", Color(0.65, 0.3, 0.9))
			ctr_lbl.text = "%s: %d" % [ctr_type.capitalize(), ctr_amt]
			card_col.add_child(ctr_lbl)

	return col


func _update_hq_hand() -> void:
	for child in _hq_hand_container.get_children():
		child.queue_free()

	for entry in _ctx.corp_hand:
		var ed: Dictionary = entry as Dictionary
		var record: CardRecord = ed.get("card_record", null) as CardRecord
		if record == null:
			continue
		var cv := CardView.new()
		cv.setup(record, true)
		_hq_hand_container.add_child(cv)


# ── Action menu ───────────────────────────────────────────────────────────────

func _populate_action_menu() -> void:
	for child in _action_menu.get_children():
		child.queue_free()
	_install_card = null   # reset any stale install state

	if _ctx == null:
		return

	if _ctx.active_player == "runner":
		var lbl := Label.new()
		lbl.text = "// SimRunner is acting… //"
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		_action_menu.add_child(lbl)
		return

	if _ctx.corp_clicks <= 0:
		var lbl := Label.new()
		lbl.text = "No clicks remaining."
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_action_menu.add_child(lbl)
		return

	# ── Basic ────────────────────────────────────────────────────────────────
	_add_section("── BASIC ──")
	_add_btn("Gain 1 Credit  (have %d¢)" % _ctx.corp_credits, GameAction.gain_credits())
	_add_btn("Draw 1 Card  (have %d in HQ)" % _ctx.corp_hand.size(), GameAction.draw_card())

	if _ctx.corp_clicks >= 3:
		_add_btn("Purge Virus Counters  [3 clicks]", GameAction.purge_virus())

	if _ctx.runner_is_tagged() and _ctx.corp_credits >= 2:
		var resources := _ctx.get_runner_installed_by_type("resource")
		if not resources.is_empty():
			_add_section("── TRASH RESOURCE ──")
			for res_card in resources:
				var rc: InstalledCard = res_card as InstalledCard
				if rc == null or rc.card_record == null:
					continue
				var cap_rc := rc
				_add_btn(
					"Trash %s  [1 click + 2¢]" % rc.card_record.title,
					GameAction.trash_runner_resource(rc.runtime_instance_id, rc.card_id)
				)

	# ── Rez (paid ability — no click cost) ───────────────────────────────────
	var rezzable: Array = _rezzable_non_ice()
	if not rezzable.is_empty():
		_add_section("── REZ ──")
		for ic in rezzable:
			var c: InstalledCard = ic as InstalledCard
			if c == null or c.card_record == null:
				continue
			var cost: int = c.card_record.cost if c.card_record.cost >= 0 else 0
			var affordable: bool = _ctx.corp_credits >= cost
			var cap_c := c
			var btn := _make_btn(
				"Rez %s  %d¢  [%s]" % [c.card_record.title, cost, c.server_id],
				func(): action_requested.emit(GameAction.rez_card(cap_c.card_id, cap_c.runtime_instance_id))
			)
			btn.disabled = not affordable
			_action_menu.add_child(btn)

	# ── Score ─────────────────────────────────────────────────────────────────
	var scoreable: Array = _scoreable_agendas()
	if not scoreable.is_empty():
		_add_section("── SCORE ──")
		for ic in scoreable:
			var c: InstalledCard = ic as InstalledCard
			if c == null or c.card_record == null:
				continue
			var cap_c := c
			_add_btn(
				"Score: %s  [1 click + 1¢]" % c.card_record.title,
				GameAction.advance(cap_c.card_id)
			)

	# ── Install ───────────────────────────────────────────────────────────────
	var installable := _installable_hq_cards()
	if not installable.is_empty():
		_add_section("── INSTALL ──")
		var install_btn := Button.new()
		install_btn.text = "Install from HQ…  (%d installable)" % installable.size()
		install_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		install_btn.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
		install_btn.pressed.connect(_show_install_step1)
		_action_menu.add_child(install_btn)

	# ── Play operation ────────────────────────────────────────────────────────
	var operations := _operations_in_hq()
	if not operations.is_empty():
		_add_section("── OPERATIONS ──")
		for entry in operations:
			var ed: Dictionary = entry as Dictionary
			var record: CardRecord = ed.get("card_record", null) as CardRecord
			if record == null:
				continue
			var cost: int = record.cost if record.cost >= 0 else 0
			var affordable: bool = _ctx.corp_credits >= cost
			var cap_r := record
			var btn := _make_btn(
				"%s  %d¢" % [record.title, cost],
				func(): action_requested.emit(GameAction.play_operation(cap_r))
			)
			btn.disabled = not affordable
			_action_menu.add_child(btn)

	# ── Advance ───────────────────────────────────────────────────────────────
	var advanceable := _advanceable_cards()
	if not advanceable.is_empty():
		_add_section("── ADVANCE ──")
		for ic in advanceable:
			var c: InstalledCard = ic as InstalledCard
			if c == null or c.card_record == null:
				continue
			var adv: int    = c.get_counter("advancement")
			var req: int    = c.card_record.advancement_requirement
			var suffix: String = " (%d/%d)" % [adv, req] if req > 0 else " (%d adv)" % adv
			var affordable: bool = _ctx.corp_credits >= 1
			var cap_c := c
			var btn := _make_btn(
				"Advance: %s%s  [1 click + 1¢]" % [c.card_record.title, suffix],
				func(): action_requested.emit(GameAction.advance(cap_c.card_id))
			)
			btn.disabled = not affordable
			_action_menu.add_child(btn)

	# ── Installed card click abilities ────────────────────────────────────────
	if _ability_registry != null:
		var any_click_ability := false
		for ic in _ctx.all_installed():
			var c: InstalledCard = ic as InstalledCard
			if c == null or c.card_record == null or not c.is_rezzed:
				continue
			var def: Dictionary = _ability_registry._abilities.get(c.card_id, {}) as Dictionary
			var click_def: Dictionary = def.get("click_action", {}) as Dictionary
			if click_def.is_empty():
				continue
			# Check if the action requires a counter drain and if there are counters
			var effects: Array = click_def.get("effects", []) as Array
			var needs_counter := effects.any(func(e):
				return (e as Dictionary).get("type", "") in [
					"take_hosted_credits_amount", "take_all_hosted_credits", "gain_credits_per_counter"
				]
			)
			var counter_type := "credits"
			for eff in effects:
				if (eff as Dictionary).get("type", "") == "gain_credits_per_counter":
					counter_type = (eff as Dictionary).get("counter", "credits")
					break
			var hosted: int = c.get_counter(counter_type)
			if needs_counter and hosted <= 0:
				continue
			if not any_click_ability:
				_add_section("── CLICK ABILITIES ──")
				any_click_ability = true
			var label: String = click_def.get("label", "Use %s" % c.display_name())
			if hosted > 0 and needs_counter:
				label = "%s  [%d %s]" % [label, hosted, counter_type]
			var cap_c := c
			_add_btn(label, GameAction.use_installed_card(cap_c.runtime_instance_id, cap_c.card_id))

	# ── End turn ─────────────────────────────────────────────────────────────
	_add_section("──────────")
	_add_btn("End Turn  (%d clicks left)" % _ctx.corp_clicks, GameAction.end_turn())


# ── Helpers: what can the Corp do right now? ──────────────────────────────────

func _installable_hq_cards() -> Array:
	var result: Array = []
	for entry in _ctx.corp_hand:
		var ed: Dictionary = entry as Dictionary
		var record: CardRecord = ed.get("card_record", null) as CardRecord
		if record == null:
			continue
		if record.card_type in ["ice", "agenda", "asset", "upgrade"]:
			result.append(entry)
	return result


func _operations_in_hq() -> Array:
	var result: Array = []
	for entry in _ctx.corp_hand:
		var ed: Dictionary = entry as Dictionary
		var record: CardRecord = ed.get("card_record", null) as CardRecord
		if record != null and record.card_type == "operation":
			result.append(entry)
	return result


func _advanceable_cards() -> Array:
	var result: Array = []
	for ic in _ctx.all_installed():
		var c: InstalledCard = ic as InstalledCard
		if c != null and c.can_be_advanced():
			# Exclude agendas already at or above their requirement (those go in Score section)
			if c.card_record != null and c.card_record.is_agenda():
				var req: int = c.card_record.advancement_requirement
				if req > 0 and c.get_counter("advancement") >= req:
					continue
			result.append(c)
	return result


func _scoreable_agendas() -> Array:
	var result: Array = []
	for ic in _ctx.all_installed():
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null:
			continue
		if not c.card_record.is_agenda():
			continue
		var req: int = c.card_record.advancement_requirement
		if req > 0 and c.get_counter("advancement") >= req:
			result.append(c)
	return result


func _rezzable_non_ice() -> Array:
	var result: Array = []
	for ic in _ctx.all_installed():
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null:
			continue
		if c.is_rezzed:
			continue
		if c.card_record.is_agenda():
			continue
		if c.card_record.is_ice():
			continue   # ICE rezzed only during runs via choose_rez_proxy
		result.append(c)
	return result


# ── Multi-step install flow ───────────────────────────────────────────────────

func _show_install_step1() -> void:
	_clear_menu()

	var installable := _installable_hq_cards()

	_add_section_to(_action_menu, "── INSTALL: Choose card ──")

	# Group by type
	var ice_cards: Array   = []
	var other_cards: Array = []
	for entry in installable:
		var record: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
		if record == null:
			continue
		if record.card_type == "ice":
			ice_cards.append(entry)
		else:
			other_cards.append(entry)

	if not ice_cards.is_empty():
		_add_section_to(_action_menu, "  ICE")
		for entry in ice_cards:
			var record: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
			if record == null:
				continue
			var cost_str := "%d¢" % record.cost if record.cost >= 0 else "free"
			var cap_r := record
			var btn := Button.new()
			btn.text = "%s  [%s]  %s" % [record.title, cost_str, record.subtypes.front() if not record.subtypes.is_empty() else ""]
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
			btn.pressed.connect(func(): _show_install_step2(cap_r))
			_action_menu.add_child(btn)

	if not other_cards.is_empty():
		_add_section_to(_action_menu, "  AGENDAS / ASSETS / UPGRADES")
		for entry in other_cards:
			var record: CardRecord = (entry as Dictionary).get("card_record", null) as CardRecord
			if record == null:
				continue
			var cost_str := "%d¢" % record.cost if record.cost >= 0 else "free"
			var cap_r := record
			var btn := Button.new()
			btn.text = "%s  [%s]  %s" % [record.title, cost_str, record.card_type.capitalize()]
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.55))
			btn.pressed.connect(func(): _show_install_step2(cap_r))
			_action_menu.add_child(btn)

	_add_cancel_btn()


func _show_install_step2(record: CardRecord) -> void:
	_install_card = record
	_clear_menu()
	_add_section_to(_action_menu, "── INSTALL %s: Choose server ──" % record.title.to_upper())

	# Determine allowed server types
	var is_ice     := record.card_type == "ice"
	var is_upgrade := record.card_type == "upgrade"
	var central_ok := is_ice or is_upgrade   # agendas/assets: remotes only

	var central_order := {"hq": 0, "rd": 1, "archives": 2}
	var server_ids: Array = _ctx.servers.keys()
	server_ids.sort_custom(func(a, b):
		var ao: int = central_order.get(a, 999)
		var bo: int = central_order.get(b, 999)
		return ao < bo if ao != bo else a < b
	)

	for server_id in server_ids:
		if not central_ok and not (server_id as String).begins_with("remote_"):
			continue
		var server: Server = _ctx.servers[server_id] as Server
		var ice_cost: int  = server.ice_install_cost() if is_ice else 0
		var total_cost: int = (record.cost if record.cost >= 0 else 0) + ice_cost
		var summary: String = _server_summary(server, is_ice)
		var affordable := _ctx.corp_credits >= total_cost
		var cap_id: String = server_id as String
		var cap_r: CardRecord  = record
		var btn := _make_btn(
			"%s — %d¢ total  %s" % [server.display_name(), total_cost, summary],
			func(): _finish_install(cap_r, cap_id)
		)
		btn.disabled = not affordable
		_action_menu.add_child(btn)

	# "New Remote" option for non-centrals
	var next_remote: String = "remote_%d" % _ctx.servers.keys().filter(
		func(k): return (k as String).begins_with("remote_")
	).size()
	var new_cost: int = (record.cost if record.cost >= 0 else 0)
	var cap_r2: CardRecord = record
	var cap_nr: String     = next_remote
	var btn_new := _make_btn(
		"New Remote (Server %s) — %d¢" % [next_remote.replace("remote_", ""), new_cost],
		func(): _finish_install(cap_r2, cap_nr)
	)
	btn_new.disabled = _ctx.corp_credits < new_cost
	_action_menu.add_child(btn_new)

	_add_cancel_btn()


func _finish_install(record: CardRecord, server_id: String) -> void:
	var zone: String
	if record.card_type == "ice":
		zone = "ice"
	elif record.card_type == "upgrade":
		# Upgrades can go in root (default) or as ICE (unusual but legal for some)
		zone = "root"
	else:
		zone = "root"

	action_requested.emit(GameAction.install(record, server_id, zone))
	_install_card = null
	# Action menu will refresh via _on_action_executed


func _server_summary(server: Server, for_ice: bool) -> String:
	var parts: Array = []
	if not server.ice.is_empty():
		parts.append("%d ICE" % server.ice.size())
	if not server.root.is_empty():
		var names: Array = []
		for rc in server.root:
			var c: InstalledCard = rc as InstalledCard
			if c != null and c.card_record != null:
				names.append(c.card_record.title)
		parts.append(", ".join(names))
	return "[%s]" % ", ".join(parts) if not parts.is_empty() else "[empty]"


func _clear_menu() -> void:
	for child in _action_menu.get_children():
		child.queue_free()


func _add_cancel_btn() -> void:
	var btn := Button.new()
	btn.text = "← Cancel"
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_color_override("font_color", Color(0.7, 0.5, 0.5))
	btn.pressed.connect(_populate_action_menu)
	_action_menu.add_child(btn)


# ── Mulligan prompt ───────────────────────────────────────────────────────────

signal _mulligan_resolved(took_mulligan: bool)

func show_mulligan_prompt(player_name: String, hand_cards: Array) -> bool:
	_clear_menu()
	_add_section_to(_action_menu, "── OPENING HAND — %s ──" % player_name.to_upper())

	for entry in hand_cards:
		var cr: CardRecord = null
		if entry is Dictionary:
			cr = (entry as Dictionary).get("card_record", null) as CardRecord
		elif entry is CardRecord:
			cr = entry as CardRecord
		var lbl := Label.new()
		lbl.text = "  • %s" % (cr.title if cr else "Unknown")
		lbl.add_theme_font_size_override("font_size", 11)
		_action_menu.add_child(lbl)

	var btn_row := HBoxContainer.new()
	_action_menu.add_child(btn_row)

	var keep_btn := Button.new()
	keep_btn.text = "Keep"
	keep_btn.pressed.connect(func(): _mulligan_resolved.emit(false), CONNECT_ONE_SHOT)
	btn_row.add_child(keep_btn)

	var mull_btn := Button.new()
	mull_btn.text = "Mulligan"
	mull_btn.pressed.connect(func(): _mulligan_resolved.emit(true), CONNECT_ONE_SHOT)
	btn_row.add_child(mull_btn)

	var took: bool = await _mulligan_resolved
	_clear_menu()
	return took


# ── Reactive prompts (called via CorpHumanBrain proxies) ─────────────────────

func show_corp_rez_prompt(card: InstalledCard, _ctx_arg: GameContext) -> bool:
	_clear_menu()

	var title_text := card.card_record.title if card.card_record else "card"
	var cost_val   := card.card_record.cost  if card.card_record and card.card_record.cost >= 0 else 0
	var type_text  := card.card_record.card_type.capitalize() if card.card_record else ""
	var subs_text  := ", ".join(card.card_record.subtypes) if card.card_record else ""

	_add_section_to(_action_menu, "── REZ OPPORTUNITY ──")

	var info_lbl := Label.new()
	info_lbl.text = "%s  (%s%s)" % [
		title_text, type_text,
		" — %s" % subs_text if subs_text != "" else ""
	]
	info_lbl.add_theme_font_size_override("font_size", 12)
	info_lbl.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	info_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_action_menu.add_child(info_lbl)

	var cost_lbl := Label.new()
	cost_lbl.text = "Cost: %d¢  (you have %d¢)" % [cost_val, _ctx.corp_credits]
	cost_lbl.add_theme_font_size_override("font_size", 11)
	cost_lbl.add_theme_color_override("font_color",
		Color(0.3, 1.0, 0.5) if _ctx.corp_credits >= cost_val else Color(0.9, 0.4, 0.4))
	_action_menu.add_child(cost_lbl)

	var btn_row := HBoxContainer.new()
	_action_menu.add_child(btn_row)

	var rez_btn := Button.new()
	rez_btn.text = "Rez"
	rez_btn.disabled = _ctx.corp_credits < cost_val
	rez_btn.pressed.connect(func(): _rez_resolved.emit(true))
	btn_row.add_child(rez_btn)

	var pass_btn := Button.new()
	pass_btn.text = "Decline"
	pass_btn.pressed.connect(func(): _rez_resolved.emit(false))
	btn_row.add_child(pass_btn)

	var choice: bool = await _rez_resolved
	_clear_menu()
	_populate_action_menu()
	return choice


func show_corp_window_action_prompt(ctx_arg: GameContext, actor: String,
		can_rez_ice: bool) -> GameAction:
	_clear_menu()

	_add_section_to(_action_menu, "── PAID ABILITY WINDOW ──")

	var actor_lbl := Label.new()
	actor_lbl.text = "Window: %s" % actor
	actor_lbl.add_theme_font_size_override("font_size", 11)
	actor_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	_action_menu.add_child(actor_lbl)

	# Offer rez for unrezzed, affordable cards (ICE only if can_rez_ice)
	var offered := false
	for ic in _ctx.all_installed():
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null or c.is_rezzed or c.card_record.is_agenda():
			continue
		if c.card_record.is_ice() and not can_rez_ice:
			continue
		var cost: int = c.card_record.cost if c.card_record.cost >= 0 else 0
		var affordable := _ctx.corp_credits >= cost
		var cap_c := c
		var btn := _make_btn(
			"Rez %s  %d¢" % [c.card_record.title, cost],
			func(): _window_resolved.emit(GameAction.rez_card(cap_c.card_id, cap_c.runtime_instance_id))
		)
		btn.disabled = not affordable
		_action_menu.add_child(btn)
		offered = true

	if not offered:
		var none_lbl := Label.new()
		none_lbl.text = "(no rez opportunities)"
		none_lbl.add_theme_font_size_override("font_size", 10)
		none_lbl.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
		_action_menu.add_child(none_lbl)

	var pass_btn := Button.new()
	pass_btn.text = "Pass Window"
	pass_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	pass_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	pass_btn.pressed.connect(func(): _window_resolved.emit(GameAction.pass_window()))
	_action_menu.add_child(pass_btn)

	var result: GameAction = await _window_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_discard_prompt(hand: Array, excess: int, _ctx_arg: GameContext) -> Dictionary:
	_clear_menu()

	_add_section_to(_action_menu, "── DISCARD TO HAND LIMIT ──")

	var info_lbl := Label.new()
	info_lbl.text = "Discard %d card%s from HQ:" % [excess, "s" if excess != 1 else ""]
	info_lbl.add_theme_font_size_override("font_size", 11)
	_action_menu.add_child(info_lbl)

	for entry in hand:
		var ed: Dictionary = entry as Dictionary
		var record: CardRecord = ed.get("card_record", null) as CardRecord
		if record == null:
			continue
		var cap_e := ed
		var btn := Button.new()
		btn.text = record.title
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_color_override("font_color", Color(0.9, 0.7, 0.6))
		btn.pressed.connect(func(): _discard_resolved.emit(cap_e))
		_action_menu.add_child(btn)

	var result: Dictionary = await _discard_resolved
	_clear_menu()
	_populate_action_menu()
	return result


# ── Run status panel ─────────────────────────────────────────────────────────

func _on_run_phase_changed(phase: int) -> void:
	var phase_names := {
		0: "INITIATION",
		1: "APPROACHING ICE",
		2: "ENCOUNTERING ICE",
		3: "MOVEMENT",
		4: "SUCCESSFUL RUN",
		5: "RUN ENDED",
	}
	var label: String = phase_names.get(phase, "RUN IN PROGRESS")
	_set_run_status_phase(label)
	if phase in [4, 5]:
		_clear_run_status()
	else:
		_run_status_panel.visible = true


func _set_run_status_phase(phase_label: String) -> void:
	if _run_status_panel == null:
		return
	if phase_label == "":
		return
	_run_status_panel.visible = true
	var current: String = _run_status_label.text
	# Only update the first line (phase) — keep ICE/sub info below
	var lines: PackedStringArray = current.split("\n")
	var new_text := "[color=#e08820]%s[/color]" % phase_label
	if lines.size() > 1:
		new_text += "\n" + "\n".join(lines.slice(1))
	_run_status_label.text = new_text


func _update_run_status_approach(ice: InstalledCard) -> void:
	_run_status_panel.visible = true
	var ice_name := ice.card_record.title if ice.is_rezzed and ice.card_record != null else "Unrezzed ICE"
	var cost_str := ""
	if not ice.is_rezzed and ice.card_record != null:
		cost_str = "  (rez: %d¢)" % ice.card_record.cost
	_run_status_label.text = (
		"[color=#e08820]APPROACHING ICE[/color]\n" +
		"[color=#aaccff]%s[/color]%s" % [ice_name, cost_str]
	)


func _update_run_status_encounter(enc: EncounterState) -> void:
	_run_status_panel.visible = true
	var ice_name := enc.ice_card.card_record.title if enc.ice_card != null and enc.ice_card.card_record != null else "ICE"
	var str_text := "str %d" % enc.ice_strength
	var lines: Array[String] = []
	lines.append("[color=#e08820]ENCOUNTERING ICE[/color]")
	lines.append("[color=#aaccff]%s[/color]  %s" % [ice_name, str_text])
	for i in range(enc.subroutines.size()):
		var sub: Dictionary = enc.subroutines[i] as Dictionary
		var broken: bool = enc.is_broken(i)
		var marker := "[color=#44cc66]✓[/color] " if broken else "↳ "
		var color  := "#555555" if broken else "#cccccc"
		lines.append("  %s[color=%s]%s[/color]" % [marker, color, sub.get("label", "sub %d" % i)])
	_run_status_label.text = "\n".join(lines)


func _clear_run_status() -> void:
	if _run_status_panel != null:
		_run_status_panel.visible = false
		_run_status_label.text = ""


# ── C3 reactive prompts ───────────────────────────────────────────────────────

func show_corp_optional_prompt(prompt_text: String, _ctx_arg: GameContext) -> bool:
	_clear_menu()
	_add_section_to(_action_menu, "── OPTIONAL ABILITY ──")

	var lbl := Label.new()
	lbl.text = prompt_text
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.8))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(280, 0)
	_action_menu.add_child(lbl)

	var btn_row := HBoxContainer.new()
	_action_menu.add_child(btn_row)
	var yes_btn := Button.new()
	yes_btn.text = "Yes"
	yes_btn.pressed.connect(func(): _optional_resolved.emit(true))
	btn_row.add_child(yes_btn)
	var no_btn := Button.new()
	no_btn.text = "No"
	no_btn.pressed.connect(func(): _optional_resolved.emit(false))
	btn_row.add_child(no_btn)

	var result: bool = await _optional_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_modes_prompt(modes: Array, max_choices: int, _ctx_arg: GameContext) -> Array:
	_clear_menu()
	_add_section_to(_action_menu, "── CHOOSE %d OPTION%s ──" % [max_choices, "S" if max_choices != 1 else ""])

	var chosen: Array = []

	for i in range(modes.size()):
		var mode: Dictionary = modes[i] as Dictionary
		var idx := i
		var btn := Button.new()
		btn.text = mode.get("label", "Option %d" % i)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
		btn.pressed.connect(func():
			if not chosen.has(idx):
				chosen.append(idx)
			if chosen.size() >= max_choices:
				_modes_resolved.emit(chosen.duplicate())
		)
		_action_menu.add_child(btn)

	var result: Array = await _modes_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_psi_prompt(max_bid: int, _ctx_arg: GameContext) -> int:
	_clear_menu()
	_add_section_to(_action_menu, "── PSI GAME ──")

	var info_lbl := Label.new()
	info_lbl.text = "Choose your bid  (you have %d¢)" % _ctx.corp_credits
	info_lbl.add_theme_font_size_override("font_size", 11)
	info_lbl.add_theme_color_override("font_color", Color(0.8, 0.75, 1.0))
	_action_menu.add_child(info_lbl)

	var btn_row := HBoxContainer.new()
	_action_menu.add_child(btn_row)
	var cap_max: int = min(max_bid, _ctx.corp_credits)
	for bid_val in range(cap_max + 1):
		var cap_b := bid_val
		var btn := Button.new()
		btn.text = "%d¢" % bid_val
		btn.pressed.connect(func(): _psi_resolved.emit(cap_b))
		btn_row.add_child(btn)

	var result: int = await _psi_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_trace_boost_prompt(base_strength: int, _ctx_arg: GameContext) -> int:
	_clear_menu()
	_add_section_to(_action_menu, "── TRACE — BASE STR %d ──" % base_strength)

	var info_lbl := Label.new()
	info_lbl.text = "Boost trace strength?  (you have %d¢)" % _ctx.corp_credits
	info_lbl.add_theme_font_size_override("font_size", 11)
	info_lbl.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
	_action_menu.add_child(info_lbl)

	var btn_row := HBoxContainer.new()
	_action_menu.add_child(btn_row)
	var max_boost: int = min(_ctx.corp_credits, 5)
	for boost_val in range(max_boost + 1):
		var cap_v := boost_val
		var btn := Button.new()
		btn.text = "+%d¢" % boost_val if boost_val > 0 else "No boost"
		btn.pressed.connect(func(): _trace_resolved.emit(cap_v))
		btn_row.add_child(btn)

	var result: int = await _trace_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_server_prompt(allowed: Array, _ctx_arg: GameContext) -> String:
	_clear_menu()
	_add_section_to(_action_menu, "── CHOOSE A SERVER ──")

	for sid in allowed:
		var server_id: String = sid as String
		var display: String
		match server_id:
			"hq":       display = "HQ"
			"rd":       display = "R&D"
			"archives": display = "Archives"
			_:
				var num: String = server_id.replace("remote_", "")
				display = "Server %s" % num
		var cap_sid := server_id
		var btn := Button.new()
		btn.text = display
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
		btn.pressed.connect(func(): _server_resolved.emit(cap_sid))
		_action_menu.add_child(btn)

	var result: String = await _server_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_card_from_hand_prompt(hand: Array, _ctx_arg: GameContext) -> Variant:
	_clear_menu()
	_add_section_to(_action_menu, "── CHOOSE A CARD FROM HQ ──")

	for entry in hand:
		var ed: Dictionary = entry as Dictionary
		var record: CardRecord = ed.get("card_record", null) as CardRecord
		if record == null:
			continue
		var cap_e := ed
		var btn := Button.new()
		btn.text = "%s  (%s)" % [record.title, record.card_type.capitalize()]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
		btn.pressed.connect(func(): _card_from_hand_resolved.emit(cap_e))
		_action_menu.add_child(btn)

	var result: Variant = await _card_from_hand_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_forfeit_agenda_prompt(agendas: Array, _ctx_arg: GameContext) -> Variant:
	_clear_menu()
	_add_section_to(_action_menu, "── FORFEIT AGENDA? ──")

	for ic in agendas:
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null:
			continue
		var pts: int = c.card_record.agenda_points
		var cap_c := c
		var btn := Button.new()
		btn.text = "%s  [%d pt%s]" % [c.card_record.title, pts, "s" if pts != 1 else ""]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
		btn.pressed.connect(func(): _forfeit_resolved.emit(cap_c))
		_action_menu.add_child(btn)

	var decline_btn := Button.new()
	decline_btn.text = "Decline"
	decline_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	decline_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	decline_btn.pressed.connect(func(): _forfeit_resolved.emit(null))
	_action_menu.add_child(decline_btn)

	var result: Variant = await _forfeit_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_trash_from_rig_prompt(candidates: Array, _ctx_arg: GameContext) -> InstalledCard:
	_clear_menu()
	_add_section_to(_action_menu, "── TRASH AS SCORING COST ──")

	var info_lbl := Label.new()
	info_lbl.text = "Choose 1 installed card to trash:"
	info_lbl.add_theme_font_size_override("font_size", 11)
	_action_menu.add_child(info_lbl)

	for ic in candidates:
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null:
			continue
		var rez_str := "REZZED" if c.is_rezzed else "unrezzed"
		var cap_c := c
		var btn := Button.new()
		btn.text = "%s  [%s — %s]" % [c.card_record.title, rez_str, c.server_id]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_color_override("font_color", Color(0.9, 0.6, 0.5))
		btn.pressed.connect(func(): _trash_from_rig_resolved.emit(cap_c))
		_action_menu.add_child(btn)

	var result: InstalledCard = await _trash_from_rig_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_trash_choice_prompt(candidates: Array, _ctx_arg: GameContext) -> String:
	_clear_menu()
	_add_section_to(_action_menu, "── TRASH AN INSTALLED CARD ──")

	var info_lbl := Label.new()
	info_lbl.text = "Choose 1 installed card to trash:"
	info_lbl.add_theme_font_size_override("font_size", 11)
	_action_menu.add_child(info_lbl)

	for ic in candidates:
		var c: InstalledCard = ic as InstalledCard
		if c == null or c.card_record == null:
			continue
		var rez_str := "REZZED" if c.is_rezzed else "unrezzed"
		var cap_id: String = c.runtime_instance_id
		var btn := Button.new()
		btn.text = "%s  [%s — %s]" % [c.card_record.title, rez_str, c.server_id]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_color_override("font_color", Color(0.9, 0.6, 0.5))
		btn.pressed.connect(func(): _trash_choice_resolved.emit(cap_id))
		_action_menu.add_child(btn)

	var result: String = await _trash_choice_resolved
	_clear_menu()
	_populate_action_menu()
	return result


func show_corp_runner_card_type_prompt(types: Array, _ctx_arg: GameContext) -> String:
	_clear_menu()
	_add_section_to(_action_menu, "── DECLARE RUNNER CARD TYPE ──")

	var info_lbl := Label.new()
	info_lbl.text = "Choose a type to name:"
	info_lbl.add_theme_font_size_override("font_size", 11)
	_action_menu.add_child(info_lbl)

	for t in types:
		var type_str: String = t as String
		var cap_t := type_str
		var btn := Button.new()
		btn.text = type_str.capitalize()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
		btn.pressed.connect(func(): _runner_type_resolved.emit(cap_t))
		_action_menu.add_child(btn)

	var result: String = await _runner_type_resolved
	_clear_menu()
	_populate_action_menu()
	return result


# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_turn_started(player: String, turn_number: int) -> void:
	if player == "corp":
		_log("\n// YOUR TURN %d //" % turn_number)
	else:
		_log("\n// RUNNER TURN %d //" % turn_number)
	_update_all_displays()


func _on_action_executed(_player: String, _action: GameAction) -> void:
	_update_all_displays()


func _on_action_rejected(player: String, _action: GameAction, reason: String) -> void:
	if player == "corp":
		_log("  ✗ %s" % reason)


func _on_game_over(winner: String, reason: String) -> void:
	_log("\n// TRANSMISSION ENDED //")
	var winner_name: String = _ctx.player_name(winner)
	_log("OUTCOME: %s WINS" % winner_name.to_upper())
	_log("REASON:  %s" % reason)

	_clear_menu()

	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.0)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(overlay)

	var tween := create_tween()
	tween.tween_property(overlay, "color:a", 0.75, 0.8)
	await tween.finished

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	overlay.add_child(vbox)

	var is_corp_win := winner == "corp"
	var headline := Label.new()
	headline.text = "[ CORP WINS ]" if is_corp_win else "[ RUNNER WINS ]"
	headline.add_theme_font_size_override("font_size", 42)
	headline.add_theme_color_override("font_color",
		Color(0.3, 0.8, 1.0) if is_corp_win else Color(0.9, 0.3, 0.3))
	headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(headline)

	var sub := Label.new()
	sub.text = winner_name
	sub.add_theme_font_size_override("font_size", 20)
	sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(sub)

	var reason_lbl := Label.new()
	reason_lbl.text = reason
	reason_lbl.add_theme_font_size_override("font_size", 13)
	reason_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	reason_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reason_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reason_lbl.custom_minimum_size = Vector2(400, 0)
	vbox.add_child(reason_lbl)

	var pulse := create_tween()
	pulse.set_loops()
	pulse.tween_property(headline, "modulate:a", 0.6, 1.2)
	pulse.tween_property(headline, "modulate:a", 1.0, 1.2)

	await get_tree().create_timer(1.5).timeout

	var continue_lbl := Label.new()
	continue_lbl.text = "// CLICK TO CONTINUE //"
	continue_lbl.add_theme_font_size_override("font_size", 11)
	continue_lbl.add_theme_color_override("font_color", Color(0.38, 0.38, 0.5))
	continue_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	continue_lbl.modulate.a = 0.0
	vbox.add_child(continue_lbl)

	var fade := create_tween()
	fade.tween_property(continue_lbl, "modulate:a", 1.0, 0.5)

	var continue_btn := Button.new()
	continue_btn.flat = true
	continue_btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	var empty := StyleBoxEmpty.new()
	continue_btn.add_theme_stylebox_override("normal",  empty)
	continue_btn.add_theme_stylebox_override("hover",   empty)
	continue_btn.add_theme_stylebox_override("pressed", empty)
	continue_btn.add_theme_stylebox_override("focus",   empty)
	overlay.add_child(continue_btn)

	await continue_btn.pressed
	pulse.kill()
	game_over_acknowledged.emit()


# ── Logging ───────────────────────────────────────────────────────────────────

func _log(msg: String) -> void:
	_log_text.text += msg + "\n"
	_log_text.scroll_vertical = _log_text.get_line_count()


func _log_run(msg: String) -> void:
	_log_text.text += "  » " + msg + "\n"
	_log_text.scroll_vertical = _log_text.get_line_count()


# ── UI helpers ────────────────────────────────────────────────────────────────

func _add_section(text: String) -> void:
	_add_section_to(_action_menu, text)


func _add_section_to(container: VBoxContainer, text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.3, 0.6, 0.8))
	container.add_child(lbl)


func _add_btn(label_text: String, action: GameAction) -> void:
	var btn := _make_btn(label_text, func(): action_requested.emit(action))
	_action_menu.add_child(btn)


func _make_btn(label_text: String, cb: Callable) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
	btn.add_theme_color_override("font_hover_color", Color(0.9, 1.0, 0.9))
	btn.pressed.connect(cb)
	return btn
