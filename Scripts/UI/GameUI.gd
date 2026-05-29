# GameUI.gd
extends CanvasLayer

# Outbound signal to feed actions back into the main game orchestrator
signal action_requested(action: GameAction)
signal rez_prompt_resolved(choice: bool)
signal jack_out_prompt_resolved(choice: bool)
signal trash_prompt_resolved(choice: bool)
signal encounter_action_resolved(action: Dictionary)
signal mode_choice_resolved(indices: Array)
signal modal_choice_resolved(indices: Array)
signal server_choice_resolved(server_id: String)
signal search_choice_resolved(card: CardRecord)
signal payment_option_resolved(option: Variant)
signal game_over_acknowledged

# ── NSG Game Symbol paths ─────────────────────────────────────────────────────
const SYM_BASE   := "res://Assets/Art/Game Symbols/Exported/"
const SYM_CREDIT := SYM_BASE + "NSG_CREDIT.png"
const SYM_CLICK  := SYM_BASE + "NSG_CLICK.png"
const SYM_AGENDA := SYM_BASE + "NSG_AGENDA.png"
const SYM_TAG    := SYM_BASE + "NSG_TAG.png"
const SYM_HQ     := SYM_BASE + "NSG_HQ_Icon.png"
const SYM_RD     := SYM_BASE + "NSG_RD_Icon.png"
const SYM_ARC    := SYM_BASE + "NSG_Archives_Icon.png"

# Pre-built BBCode image tags — computed once, never on every frame
const BBQ_CR  := "[img height=16]" + SYM_CREDIT + "[/img]"
const BBQ_CL  := "[img height=16]" + SYM_CLICK  + "[/img]"
const BBQ_AG  := "[img height=16]" + SYM_AGENDA + "[/img]"
const BBQ_TG  := "[img height=16]" + SYM_TAG    + "[/img]"
const SYM_MU  := SYM_BASE + "NSG_Mu.png"
const BBQ_MU  := "[img height=16]" + SYM_MU     + "[/img]"
const BBQ_HQ  := "[img height=18]" + SYM_HQ     + "[/img]"
const BBQ_RD  := "[img height=18]" + SYM_RD     + "[/img]"
const BBQ_ARC := "[img height=18]" + SYM_ARC    + "[/img]"

# Inline BBCode image tag at a given pixel height (for dynamic use only)
func _sym(path: String, h: int = 16) -> String:
	return "[img height=%d]%s[/img]" % [h, path]

# Onready references using unique names (% badge in inspector)
@onready var resource_label = $MarginContainer/MainContainer/StatePanel/StateVBox/ResourceLabel
@onready var servers_container = $MarginContainer/MainContainer/StatePanel/StateVBox/ServersArea/ServersContainer
@onready var runner_hand_container = $MarginContainer/MainContainer/StatePanel/StateVBox/RunnerHandContainer
@onready var corp_hand_container = $MarginContainer/MainContainer/StatePanel/StateVBox/CorpHandContainer
@onready var log_text = $MarginContainer/MainContainer/ControlPanel/LogText
@onready var action_menu = $MarginContainer/MainContainer/ControlPanel/ActionMenu

var _ctx: GameContext
var _ability_registry: AbilityRegistry = null
var _score_popup: Control = null

## Initializes UI wiring by subscribing directly to engine component signals
func setup(ctx: GameContext, turn_manager: TurnManager, run_machine: RunStateMachine, ability_registry: AbilityRegistry = null) -> void:
	_ctx = ctx
	_ability_registry = ability_registry

	# Ensure the state panel is wide enough
	var state_panel: PanelContainer = resource_label.get_parent().get_parent() as PanelContainer
	if state_panel:
		state_panel.custom_minimum_size = Vector2(700, 0)
		state_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Cyberpunk log styling
	log_text.add_theme_color_override("font_color", Color(0.55, 0.85, 0.65))
	log_text.add_theme_color_override("background_color", Color(0.04, 0.06, 0.08))
	log_text.add_theme_font_size_override("font_size", 12)

	# Seed log with a cyberpunk header
	log_text.text = "// NETRUNNER TACTICAL INTERFACE //\n// RUNNER FEED ACTIVE //\n\n"
	
	# Wire up engine signals to automatically refresh components
	if not turn_manager.turn_started.is_connected(_on_turn_started):
		turn_manager.turn_started.connect(_on_turn_started)
	if not turn_manager.action_executed.is_connected(_on_action_executed):
		turn_manager.action_executed.connect(_on_action_executed)
	if not turn_manager.action_rejected.is_connected(_on_action_rejected):
		turn_manager.action_rejected.connect(_on_action_rejected)
	if not turn_manager.game_over.is_connected(_on_game_over):
		turn_manager.game_over.connect(_on_game_over)
	
	# Connect RunStateMachine updates to the runner-visible log
	run_machine.ice_approached.connect(func(ice: InstalledCard):
		if ice.is_rezzed:
			_log_run("Approaching %s." % ice.card_record.title)
		else:
			_log_run("Approaching unrezzed ICE.")
	)
	run_machine.ice_encountered.connect(func(ice: InstalledCard):
		if ice.is_rezzed:
			_log_run("Encountering %s." % ice.card_record.title)
	)
	run_machine.ice_rezzed.connect(func(ice: InstalledCard):
		_log_run("Corp rezzes %s." % ice.card_record.title)
	)
	run_machine.run_succeeded.connect(func(srv: String):
		_log_run("Run successful on %s." % srv.to_upper())
		_update_all_displays()
	)
	run_machine.run_ended_unsuccessfully.connect(func(reason: String):
		_log_run("Run ended — %s." % reason)
		_update_all_displays()
	)

	# Initialize visual configurations
	resource_label.meta_clicked.connect(_on_score_area_clicked)
	_update_all_displays()





## Forces a full structural re-render of current resources and card locations
func _update_all_displays() -> void:
	if _ctx == null:
		return
		
	# 1. Update text fields
	var corp_label:   String = _ctx.corp_name()
	var runner_label: String = _ctx.runner_name()
	var corp_pts   := _ctx.corp_agenda_points()
	var runner_pts := _ctx.runner_agenda_points()
	var corp_pts_link   := "[url=score_corp][color=#aaffaa]%d pts[/color][/url]" % corp_pts
	var runner_pts_link := "[url=score_runner][color=#aaffaa]%d pts[/color][/url]" % runner_pts
	var mu_link := "[url=rig][color=#88ccff]%d/%d[/color][/url]" % [_ctx.runner_mu_used(), _ctx.runner_total_mu()]
	# Show core damage indicator if runner has taken any core damage
	var core_dmg_suffix := ""
	if _ctx.runner_core_damage_taken > 0:
		core_dmg_suffix = "  [color=#ff7777]♥%d[/color]" % _ctx.runner_max_hand_size()
	resource_label.text = (
		"[b]%s[/b]  %s%d  %s%d  %s%s\n" % [corp_label, BBQ_CR, _ctx.corp_credits, BBQ_CL, _ctx.corp_clicks, BBQ_AG, corp_pts_link] +
		"[b]%s[/b]  %s%d  %s%d  %s%s  %s%d  %s%s%s" % [runner_label, BBQ_CR, _ctx.runner_credits, BBQ_CL, _ctx.runner_clicks, BBQ_AG, runner_pts_link, BBQ_TG, _ctx.runner_tags, BBQ_MU, mu_link, core_dmg_suffix]
	)
	
	#corp_hand_label.text = "Corp HQ Hand (%d cards):\n%s" % [_ctx.corp_hand.size(), _format_hand(_ctx.corp_hand)]
	#runner_hand_label.text = "Runner Grip (%d cards):\n%s" % [_ctx.runner_hand.size(), _format_hand(_ctx.runner_hand)]
	
	# 2. Update hands (new)
	_update_hands()
	
	# 3. Rebuild the visual server hierarchy (still Tree for now)
	_update_servers()
	
	# 4. Regenerate valid action options
	_populate_action_menu()

func _update_hands() -> void:
	# Clear existing cards
	for child in corp_hand_container.get_children():
		child.queue_free()
	for child in runner_hand_container.get_children():
		child.queue_free()

	# Runner identity — shown at left of grip, always face-up
	if _ctx.runner_identity != null:
		var id_view := CardView.new()
		runner_hand_container.add_child(id_view)
		id_view.setup(_ctx.runner_identity, true)
		var sep := VSeparator.new()
		sep.custom_minimum_size = Vector2(8, 0)
		runner_hand_container.add_child(sep)

	# Corp hand
	for entry in _ctx.corp_hand:
		var record = entry.get("card_record") if entry is Dictionary else null
		if record:
			var card_view = CardView.new()
			corp_hand_container.add_child(card_view)
			card_view.setup(record, true)   # hand cards are always face-up

	# Runner hand — includes faceup-hosted cards (Bling, Madani, etc.) as if in grip.
	for entry in _ctx.get_runner_effective_hand():
		var record = entry.get("card_record") if entry is Dictionary else null
		if record:
			var card_view = CardView.new()
			runner_hand_container.add_child(card_view)
			card_view.setup(record, true)
			card_view.clicked.connect(_on_runner_hand_card_clicked)
			# Tint hosted cards so the player can distinguish them from grip cards.
			if (entry as Dictionary).has("hosted_on"):
				card_view.modulate = Color(0.75, 0.85, 1.0)

func _on_runner_hand_card_clicked(card_record: CardRecord) -> void:
	if _ctx.active_player != "runner":
		_append_log("Not your turn to play cards.")
		return
	# Determine action based on card type
	var action: GameAction = null
	match card_record.card_type:
		"event":
			action = GameAction.play_operation(card_record)
		"program", "hardware", "resource":
			action = GameAction.install(card_record, "runner_rig")
		_:
			_append_log("Cannot play/install card type: %s" % card_record.card_type)
			return
	if action:
		action_requested.emit(action)

func _format_hand(hand: Array) -> String:
	if hand.is_empty():
		return "  [Empty]"
	var lines: Array[String] = []
	for entry in hand:
		if entry is Dictionary:
			var record: CardRecord = entry.get("card_record", null)
			if record:
				lines.append("  - %s (%s)" % [record.title, record.card_type.capitalize()])
	return "\n".join(lines)


func _update_servers() -> void:
	# Clear existing columns
	for child in servers_container.get_children():
		child.queue_free()
	
	if _ctx == null or not ("servers" in _ctx):
		return
	
	# Sort servers: centrals first (HQ, R&D, Archives), then remotes by name
	var central_order = {"hq": 0, "rd": 1, "archives": 2}
	var server_ids = _ctx.servers.keys()
	server_ids.sort_custom(func(a, b):
		var a_order = central_order.get(a, 999)
		var b_order = central_order.get(b, 999)
		if a_order == b_order:
			return a < b
		return a_order < b_order
	)
	
	for server_id in server_ids:
		var server: Server = _ctx.servers[server_id]
		# Skip empty remote servers (optional – you may want to show empty slots)
		if server.is_remote() and server.is_empty():
			continue
		
		var column = _create_server_column(server_id, server)
		servers_container.add_child(column)


func _create_server_column(server_id: String, server: Server) -> VBoxContainer:
	var col = VBoxContainer.new()
	# Fixed minimum width per column so the HBoxContainer has a natural (measurable)
	# size. The parent ScrollContainer scrolls horizontally when the total exceeds
	# the panel width — prevents overflow off the right edge with many remote servers.
	col.custom_minimum_size = Vector2(120, 0)
	col.add_theme_constant_override("separation", 4)

	# Server name label — use icon for central servers
	var name_label := RichTextLabel.new()
	name_label.bbcode_enabled = true
	name_label.fit_content    = true
	name_label.scroll_active  = false
	name_label.add_theme_font_size_override("normal_font_size", 14)
	var icon_tag := ""
	match server_id:
		"hq":       icon_tag = BBQ_HQ  + " "
		"rd":       icon_tag = BBQ_RD  + " "
		"archives": icon_tag = BBQ_ARC + " "
	name_label.text = "[center]%s%s[/center]" % [icon_tag, server.display_name()]
	col.add_child(name_label)

	# Run button — visible only on runner's turn with clicks remaining
	if _ctx.active_player == "runner" and _ctx.runner_clicks > 0:
		var ice_count: int = server.ice_count()
		var rezzed: int = 0
		for ice in server.ice:
			if (ice as InstalledCard).is_rezzed:
				rezzed += 1
		var ice_info := "[%d ice, %d rezzed]" % [ice_count, rezzed] if ice_count > 0 else "[no ice]"
		var run_btn := Button.new()
		run_btn.text = "▶ Run  %s" % ice_info
		run_btn.add_theme_font_size_override("font_size", 11)
		run_btn.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
		run_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var captured_id := server_id
		run_btn.pressed.connect(func(): action_requested.emit(GameAction.run(captured_id)))
		col.add_child(run_btn)

	# Corp identity — displayed face-up above HQ, per standard Netrunner layout
	if server_id == "hq" and _ctx.corp_identity != null:
		var id_view := CardView.new()
		id_view.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(id_view)
		id_view.setup(_ctx.corp_identity, true)

	# Ice stack – only add if there are ice cards
	var ice_container = VBoxContainer.new()
	ice_container.alignment = BoxContainer.ALIGNMENT_CENTER
	for ice_card in server.ice:
		var token = IceToken.new()
		ice_container.add_child(token)
		token.setup(ice_card)
	if ice_container.get_child_count() > 0:
		col.add_child(ice_container)

	# Root cards — show face-up only if rezzed (runner perspective: face-down unless rezzed)
	if not server.root.is_empty():
		for root_card in server.root:
			# Wrap card + optional advancement badge in a vertical column
			var card_col := VBoxContainer.new()
			card_col.add_theme_constant_override("separation", 2)
			card_col.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			col.add_child(card_col)

			var root_view := CardView.new()
			root_view.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			card_col.add_child(root_view)
			# is_face_up (BANGUN faceup agendas) counts as visible to the Runner
			var visible_to_runner: bool = root_card.is_rezzed or root_card.is_face_up
			root_view.setup(root_card.card_record, visible_to_runner)

			# Advancement tokens are always public information — show for all players
			var adv: int = root_card.get_counter("advancement")
			if adv > 0:
				var adv_lbl := Label.new()
				adv_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				adv_lbl.add_theme_font_size_override("font_size", 12)
				adv_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
				# Show the advancement requirement only when the card face is visible;
				# revealing it on a face-down card would expose hidden agenda identity.
				var req: int = root_card.card_record.advancement_requirement \
					if (visible_to_runner and root_card.card_record != null) else -1
				adv_lbl.text = "▲ %d / %d" % [adv, req] if req > 0 else "▲ %d" % adv
				card_col.add_child(adv_lbl)

	return col

## Generates click choices dynamically based on which side holds active framework clicks
func _populate_action_menu() -> void:
	for child in action_menu.get_children():
		child.queue_free()

	if _ctx == null:
		return

	if _ctx.active_player == "corp" and _ctx.corp_clicks > 0:
		# Corp turn — AI controlled, just show status
		var lbl := Label.new()
		lbl.text = "[%s] thinking... (%d clicks remaining)" % [_ctx.corp_name(), _ctx.corp_clicks]
		action_menu.add_child(lbl)

	elif _ctx.active_player == "runner" and _ctx.runner_clicks > 0:
		_add_section_label("── BASIC ACTIONS ──")
		_add_action_btn("Gain 1 Credit  (have %d¢)" % _ctx.runner_credits, GameAction.gain_credits())
		_add_action_btn("Draw 1 Card  (have %d)" % _ctx.runner_hand.size(), GameAction.draw_card())

		# Installed card click actions (e.g. Red Team)
		var has_card_actions := false
		for card in _ctx.runner_rig:
			var c: InstalledCard = card as InstalledCard
			if c == null or c.card_record == null:
				continue
			if _ability_registry == null:
				continue
			var card_def: Dictionary = _ability_registry._abilities.get(c.card_id, {}) as Dictionary
			if not card_def.has("click_action"):
				continue
			var click_def: Dictionary = card_def["click_action"] as Dictionary
			# Determine what counter type this action drains (credits or virus etc.)
			var effects_list: Array = click_def.get("effects", []) as Array
			var drains_counter: bool = effects_list.any(func(e):
				var t: String = (e as Dictionary).get("type", "")
				return t in ["take_hosted_credits_amount", "take_all_hosted_credits",
							 "gain_credits_per_counter"]
			)
			var counter_type: String = "credits"
			for eff in effects_list:
				var e: Dictionary = eff as Dictionary
				if e.get("type", "") == "gain_credits_per_counter":
					counter_type = e.get("counter", "virus")
					break
			var hosted: int = c.get_counter(counter_type)
			if drains_counter and hosted <= 0:
				continue
			var base_label: String = click_def.get("label", "Use %s" % c.display_name())
			var label: String = "%s  [%d %s]" % [base_label, hosted, counter_type] if hosted > 0 else base_label
			if not has_card_actions:
				_add_section_label("── INSTALLED ──")
				has_card_actions = true
			_add_action_btn(label, GameAction.use_installed_card(c.runtime_instance_id, c.card_id))

		_add_section_label("──────────")
		_add_action_btn("End Turn  (%d clicks left)" % _ctx.runner_clicks, GameAction.end_turn())

	else:
		var lbl := Label.new()
		lbl.text = "Processing..."
		action_menu.add_child(lbl)


func _add_section_label(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 10)
	lbl.add_theme_color_override("font_color", Color(0.3, 0.6, 0.8))
	action_menu.add_child(lbl)


func _add_action_btn(label_text: String, action: GameAction) -> void:
	var btn := Button.new()
	btn.text = label_text
	btn.alignment = HorizontalAlignment.HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
	btn.add_theme_color_override("font_hover_color", Color(0.9, 1.0, 0.9))
	btn.pressed.connect(func(): action_requested.emit(action))
	action_menu.add_child(btn)


func _log_game(message: String) -> void:
	log_text.text += message + "\n"
	log_text.scroll_vertical = log_text.get_line_count()

func _log_run(message: String) -> void:
	log_text.text += "  » " + message + "\n"
	log_text.scroll_vertical = log_text.get_line_count()

func _append_log(message: String) -> void:
	log_text.text += message + "\n"
	log_text.scroll_vertical = log_text.get_line_count()


# ── System Signal Hook Interceptions ──────────────────────────────────────────

func _on_turn_started(player: String, turn_number: int) -> void:
	if player == "corp":
		_log_game("\n// CORP TURN %d //" % turn_number)
		_show_toast("// %s — TURN %d //" % [_ctx.corp_name().to_upper(), turn_number],
			Color(0.15, 0.22, 0.35), 2.2)
	else:
		_log_game("\n// YOUR TURN %d //" % turn_number)
	_update_all_displays()


func _on_action_executed(player: String, action: GameAction) -> void:
	_update_all_displays()
	if player == "corp":
		_handle_corp_action_display(action)
	else:
		_handle_runner_action_display(action)


func _handle_corp_action_display(action: GameAction) -> void:
	match action.type:
		"install":
			var r: CardRecord = action.params.get("card_record", null)
			var zone: String  = action.params.get("zone", "root")
			if zone == "ice":
				_log_game("  Corp installs ICE.")
				_show_corp_event("installs ICE", null, Color(0.2, 0.3, 0.5))
			elif r != null and r.is_agenda():
				_log_game("  Corp installs a card in a new remote.")
				_show_corp_event("installs in remote", null, Color(0.2, 0.3, 0.5))
			else:
				_log_game("  Corp installs a card.")
				_show_corp_event("installs a card", null, Color(0.2, 0.3, 0.5))
		"advance":
			_log_game("  Corp advances an installed card.")
			_show_corp_event("advances ▲", null, Color(0.25, 0.3, 0.45))
		"play_operation":
			var r: CardRecord = action.params.get("card_record", null)
			if r != null:
				_log_game("  Corp plays %s." % r.title)
				_show_corp_event_with_card("plays operation", r, Color(0.22, 0.28, 0.48))
		"rez_card":
			# Find the card that was just rezzed to show it
			var card_id: String = action.params.get("card_id", "")
			var iid: String     = action.params.get("card_instance_id", "")
			var installed: InstalledCard = null
			if iid != "":
				installed = _ctx.get_installed_card_by_instance_id(iid)
			if installed == null and card_id != "":
				installed = _ctx.get_installed_card_by_id(card_id)
			if installed != null and installed.card_record != null:
				_log_game("  Corp rezzes %s." % installed.card_record.title)
				_show_corp_event_with_card("REZZES", installed.card_record, Color(0.18, 0.28, 0.45))
			else:
				_log_game("  Corp rezzes a card.")
		"gain_credits":
			_log_game("  Corp takes a credit.")
		"draw_card":
			_log_game("  Corp draws a card.")
		"use_installed_card":
			_log_game("  Corp uses an installed card.")
		"end_turn":
			_log_game("  Corp ends turn.")
		"score_agenda":
			var r: CardRecord = action.params.get("card_record", null)
			if r != null:
				_log_game("  !! Corp scores %s!" % r.title)
				_show_agenda_scored(r)


func _handle_runner_action_display(action: GameAction) -> void:
	match action.type:
		"gain_credits":
			_log_game("  You take a credit.")
		"draw_card":
			_log_game("  You draw a card.")
		"install":
			var r: CardRecord = action.params.get("card_record", null)
			if r != null:
				_log_game("  You install %s." % r.title)
		"play_operation":
			var r: CardRecord = action.params.get("card_record", null)
			if r != null:
				_log_game("  You play %s." % r.title)
		"run":
			var server_id: String = action.params.get("server_id", "?")
			_log_game("  You initiate a run on %s." % server_id.to_upper())
		"use_installed_card":
			_log_game("  You use an installed card.")
		"end_turn":
			_log_game("  You end your turn.")


func _show_corp_event(label: String, _card: CardRecord, color: Color) -> void:
	_show_toast("CORP: %s" % label.to_upper(), color, 1.6)


func _show_corp_event_with_card(label: String, card: CardRecord, color: Color) -> void:
	if card == null:
		_show_corp_event(label, null, color)
		return
	# Show a compact card popup alongside the toast
	_show_corp_card_reveal(label, card, color)


func _show_corp_card_reveal(label: String, card: CardRecord, color: Color) -> void:
	const POPUP_W  := 260.0
	const MARGIN   := 16.0

	var panel := PanelContainer.new()
	panel.modulate.a = 0.0
	panel.custom_minimum_size = Vector2(POPUP_W, 0)
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical   = Control.GROW_DIRECTION_END
	panel.offset_right    = -MARGIN
	panel.offset_top      = MARGIN
	self.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color             = Color(0.04, 0.05, 0.10, 0.96)
	style.border_color         = Color(0.0, 0.78, 0.95, 0.9)
	style.border_width_left    = 3
	style.border_width_top     = 1
	style.border_width_right   = 1
	style.border_width_bottom  = 1
	style.corner_radius_top_left     = 0
	style.corner_radius_top_right    = 2
	style.corner_radius_bottom_left  = 0
	style.corner_radius_bottom_right = 2
	style.content_margin_left   = 10
	style.content_margin_right  = 10
	style.content_margin_top    = 8
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)

	var outer_vbox := VBoxContainer.new()
	outer_vbox.add_theme_constant_override("separation", 6)
	panel.add_child(outer_vbox)

	var lbl_header := Label.new()
	lbl_header.text = "// CORP %s //" % label.to_upper()
	lbl_header.add_theme_font_size_override("font_size", 9)
	lbl_header.add_theme_color_override("font_color", Color(0.0, 0.82, 0.95))
	outer_vbox.add_child(lbl_header)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color(0.0, 0.6, 0.75, 0.5))
	outer_vbox.add_child(sep)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	outer_vbox.add_child(hbox)

	var card_view := CardView.new()
	card_view.custom_minimum_size    = Vector2(52, 73)
	card_view.size_flags_horizontal  = Control.SIZE_SHRINK_BEGIN
	card_view.size_flags_vertical    = Control.SIZE_SHRINK_BEGIN
	hbox.add_child(card_view)
	card_view.setup(card, true)

	var info_vbox := VBoxContainer.new()
	info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_vbox.add_theme_constant_override("separation", 3)
	hbox.add_child(info_vbox)

	var lbl_title := Label.new()
	lbl_title.text = card.title
	lbl_title.add_theme_font_size_override("font_size", 13)
	lbl_title.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	lbl_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_vbox.add_child(lbl_title)

	if card.agenda_points > 0:
		var lbl_pts := Label.new()
		lbl_pts.text = "[ %d AGENDA PT%s ]" % [card.agenda_points, "S" if card.agenda_points != 1 else ""]
		lbl_pts.add_theme_font_size_override("font_size", 10)
		lbl_pts.add_theme_color_override("font_color", Color(1.0, 0.75, 0.2))
		info_vbox.add_child(lbl_pts)

	var tween := create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, 0.18)
	await tween.finished
	await get_tree().create_timer(3.0).timeout
	if not is_instance_valid(panel):
		return
	tween = create_tween()
	tween.tween_property(panel, "modulate:a", 0.0, 0.3)
	await tween.finished
	if is_instance_valid(panel):
		panel.queue_free()


func _show_agenda_scored(card: CardRecord) -> void:
	var panel := PanelContainer.new()
	panel.modulate.a = 0.0
	panel.custom_minimum_size = Vector2(320, 0)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical   = Control.GROW_DIRECTION_BOTH
	self.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color            = Color(0.06, 0.03, 0.03, 0.97)
	style.border_color        = Color(0.95, 0.35, 0.1, 1.0)
	style.border_width_top    = 3
	style.border_width_left   = 1
	style.border_width_right  = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left     = 0
	style.corner_radius_top_right    = 0
	style.corner_radius_bottom_left  = 2
	style.corner_radius_bottom_right = 2
	style.content_margin_left   = 24
	style.content_margin_right  = 24
	style.content_margin_top    = 16
	style.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var lbl_header := Label.new()
	lbl_header.text = "// CORP SCORES //"
	lbl_header.add_theme_font_size_override("font_size", 10)
	lbl_header.add_theme_color_override("font_color", Color(0.95, 0.45, 0.15))
	lbl_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl_header)

	var lbl_title := Label.new()
	lbl_title.text = card.title
	lbl_title.add_theme_font_size_override("font_size", 26)
	lbl_title.add_theme_color_override("font_color", Color(0.95, 0.92, 0.88))
	lbl_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(lbl_title)

	if card.agenda_points > 0:
		var lbl_pts := Label.new()
		lbl_pts.text = "[ %d AGENDA PT%s ]" % [card.agenda_points, "S" if card.agenda_points != 1 else ""]
		lbl_pts.add_theme_font_size_override("font_size", 13)
		lbl_pts.add_theme_color_override("font_color", Color(1.0, 0.78, 0.2))
		lbl_pts.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(lbl_pts)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color(0.7, 0.25, 0.1, 0.6))
	vbox.add_child(sep)

	var corp_pts: int  = _ctx.corp_agenda_points()
	var pts_to_win: int = _ctx.agenda_points_to_win
	var lbl_score := Label.new()
	lbl_score.text = "CORP: %d / %d" % [corp_pts, pts_to_win]
	lbl_score.add_theme_font_size_override("font_size", 14)
	lbl_score.add_theme_color_override("font_color", Color(0.85, 0.55, 0.3))
	lbl_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl_score)

	var tween := create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, 0.15)
	await tween.finished
	await get_tree().create_timer(3.0).timeout
	if not is_instance_valid(panel):
		return
	tween = create_tween()
	tween.tween_property(panel, "modulate:a", 0.0, 0.4)
	await tween.finished
	if is_instance_valid(panel):
		panel.queue_free()


# ── Game Over ─────────────────────────────────────────────────────────────────

func _on_game_over(winner: String, reason: String) -> void:
	_log_game("\n// TRANSMISSION ENDED //")
	var winner_name: String = _ctx.player_name(winner)
	_log_game("OUTCOME: %s WINS" % winner_name.to_upper())
	_log_game("REASON:  %s" % reason)

	for child in action_menu.get_children():
		child.queue_free()

	# Full-screen game over overlay
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

	var is_runner_win := winner == "runner"
	var headline := Label.new()
	headline.text = "[ RUNNER WINS ]" if is_runner_win else "[ CORP WINS ]"
	headline.add_theme_font_size_override("font_size", 42)
	headline.add_theme_color_override("font_color",
		Color(0.3, 1.0, 0.5) if is_runner_win else Color(0.9, 0.3, 0.3))
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

	# Pulse the headline
	var pulse := create_tween()
	pulse.set_loops()
	pulse.tween_property(headline, "modulate:a", 0.6, 1.2)
	pulse.tween_property(headline, "modulate:a", 1.0, 1.2)

	# Hold so the player can read the outcome, then prompt to continue
	await get_tree().create_timer(1.5).timeout

	var continue_lbl := Label.new()
	continue_lbl.text = "// CLICK TO CONTINUE //"
	continue_lbl.add_theme_font_size_override("font_size", 11)
	continue_lbl.add_theme_color_override("font_color", Color(0.38, 0.38, 0.5))
	continue_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	continue_lbl.modulate.a = 0.0
	vbox.add_child(continue_lbl)

	tween = create_tween()
	tween.tween_property(continue_lbl, "modulate:a", 1.0, 0.5)

	# Invisible full-rect button captures any click
	var continue_btn := Button.new()
	continue_btn.flat = true
	continue_btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	var empty_style := StyleBoxEmpty.new()
	continue_btn.add_theme_stylebox_override("normal",  empty_style)
	continue_btn.add_theme_stylebox_override("hover",   empty_style)
	continue_btn.add_theme_stylebox_override("pressed", empty_style)
	continue_btn.add_theme_stylebox_override("focus",   empty_style)
	overlay.add_child(continue_btn)

	await continue_btn.pressed
	pulse.kill()
	game_over_acknowledged.emit()

var _toast_queue: Array = []
var _toast_showing: bool = false

func _show_toast(message: String, color: Color, duration: float = 1.8) -> void:
	_toast_queue.append({"message": message, "color": color, "duration": duration})
	if not _toast_showing:
		_process_toast_queue()


func _process_toast_queue() -> void:
	if _toast_queue.is_empty():
		_toast_showing = false
		return
	_toast_showing = true
	var entry: Dictionary = _toast_queue.pop_front() as Dictionary
	await _display_toast(entry["message"] as String, entry["color"] as Color, entry["duration"] as float)
	_process_toast_queue()


func _display_toast(message: String, bg_color: Color, duration: float) -> void:
	const POPUP_W := 280.0
	const MARGIN  := 16.0

	var panel := PanelContainer.new()
	panel.modulate.a = 0.0
	panel.custom_minimum_size = Vector2(POPUP_W, 0)
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical   = Control.GROW_DIRECTION_END
	panel.offset_right    = -MARGIN
	panel.offset_top      = MARGIN
	self.add_child(panel)

	var stylebox := StyleBoxFlat.new()
	stylebox.bg_color            = Color(0.04, 0.05, 0.10, 0.93)
	stylebox.border_color        = Color(bg_color.r * 1.8 + 0.1, bg_color.g * 1.8 + 0.1, bg_color.b * 2.0 + 0.2, 0.9)
	stylebox.border_width_left   = 3
	stylebox.border_width_top    = 1
	stylebox.border_width_right  = 1
	stylebox.border_width_bottom = 1
	stylebox.corner_radius_top_left     = 0
	stylebox.corner_radius_top_right    = 2
	stylebox.corner_radius_bottom_left  = 0
	stylebox.corner_radius_bottom_right = 2
	stylebox.content_margin_left   = 12
	stylebox.content_margin_right  = 12
	stylebox.content_margin_top    = 7
	stylebox.content_margin_bottom = 7
	panel.add_theme_stylebox_override("panel", stylebox)

	var lbl := Label.new()
	lbl.text = message
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(0.0, 0.88, 1.0))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	panel.add_child(lbl)

	var tween := create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, 0.18)
	await tween.finished

	await get_tree().create_timer(duration).timeout

	if not is_instance_valid(panel):
		return
	tween = create_tween()
	tween.tween_property(panel, "modulate:a", 0.0, 0.25)
	await tween.finished

	if is_instance_valid(panel):
		panel.queue_free()

func _on_action_rejected(player: String, action: GameAction, reason: String) -> void:
	# Action rejected — only log runner rejections (Corp rejections are internal)
	if player == "runner":
		_log_game("  ✗ Action rejected: %s" % reason)


# ── Asynchronous Choice Prompt Engine ─────────────────────────────────────────

## Pops open an inline blocking prompt allowing the corp player to evaluate a Rez window
func show_rez_prompt(ice_card: InstalledCard) -> bool:
	var title_text := ice_card.card_record.title if ice_card.card_record else "ICE"
	var cost_val := ice_card.card_record.cost if ice_card.card_record else 0
	
	# Corp rez prompt — not logged to runner-visible log
	
	var prompt_box := HBoxContainer.new()
	var prompt_lbl := Label.new()
	prompt_lbl.text = "Rez %s for %d cr? " % [title_text, cost_val]
	
	var yes_btn := Button.new()
	yes_btn.text = "Yes"
	var no_btn := Button.new()
	no_btn.text = "No"
	
	prompt_box.add_child(prompt_lbl)
	prompt_box.add_child(yes_btn)
	prompt_box.add_child(no_btn)
	action_menu.add_child(prompt_box)
	
	var selection: bool = await _choice_with_signal(yes_btn, no_btn, prompt_box, rez_prompt_resolved)
	return selection


func _choice_with_signal(yes: Button, no: Button, container: HBoxContainer, resolution_signal: Signal) -> bool:
	var output := false
	# Use a one-shot signal helper: whichever button fires first resolves the await
	var resolved := false
	var _yes_cb: Callable
	var _no_cb: Callable
	_yes_cb = func():
		if not resolved:
			resolved = true
			output = true
			resolution_signal.emit(true)
	_no_cb = func():
		if not resolved:
			resolved = true
			output = false
			resolution_signal.emit(false)
	yes.pressed.connect(_yes_cb, CONNECT_ONE_SHOT)
	no.pressed.connect(_no_cb, CONNECT_ONE_SHOT)
	await resolution_signal
	container.queue_free()
	return output

## Pops open a confirmation layout giving the Runner an option to escape the current run
func show_jack_out_prompt() -> bool:
	_append_log("PROMPT: %s, do you want to jack out of this run?" % _ctx.runner_name())
	
	var prompt_box := HBoxContainer.new()
	var prompt_lbl := Label.new()
	prompt_lbl.text = "Jack Out of Server? "
	
	var yes_btn := Button.new()
	yes_btn.text = "Yes (Jack Out)"
	var no_btn := Button.new()
	no_btn.text = "No (Continue Run)"
	
	prompt_box.add_child(prompt_lbl)
	prompt_box.add_child(yes_btn)
	prompt_box.add_child(no_btn)
	action_menu.add_child(prompt_box)
	
	var selection: bool = await _choice_with_signal(yes_btn, no_btn, prompt_box, jack_out_prompt_resolved)
	return selection

func group_signals(connections: Array) -> void:
	var wrapper := RefCounted.new()
	wrapper.add_user_signal("resolved")
	
	for conn in connections:
		var process_callable = func():
			conn["callable"].call()
			wrapper.emit_signal("resolved")
		conn["sig"].connect(process_callable, CONNECT_ONE_SHOT)
		
	await wrapper.to_signal(wrapper, "resolved")

## Pops open a prompt asking the Runner whether to trash an accessed card
func show_trash_prompt(card: CardRecord) -> bool:
	var title_text := card.title if card else "card"
	var cost_val := card.trash_cost if card else 0
	
	_append_log("PROMPT: %s, trash %s for %d credits?" % [_ctx.runner_name(), title_text, cost_val])
	
	var prompt_box := HBoxContainer.new()
	var prompt_lbl := Label.new()
	prompt_lbl.text = "Trash %s for %d cr? " % [title_text, cost_val]
	
	var yes_btn := Button.new()
	yes_btn.text = "Yes (Trash)"
	var no_btn := Button.new()
	no_btn.text = "No"
	
	prompt_box.add_child(prompt_lbl)
	prompt_box.add_child(yes_btn)
	prompt_box.add_child(no_btn)
	action_menu.add_child(prompt_box)
	
	var selection: bool = await _choice_with_signal(yes_btn, no_btn, prompt_box, trash_prompt_resolved)
	return selection

## Shows icebreaker controls during an ice encounter.
## Returns a Dictionary encounter action: {type, card_id, ...} or {type: "done"}
func show_encounter_prompt(encounter: EncounterState) -> Dictionary:
	var ice_name := encounter.ice_card.display_name() if encounter.ice_card else "ice"
	var ice_str  := str(encounter.ice_strength)
	_append_log("ENCOUNTER: %s (str %s) — choose an action." % [ice_name, ice_str])

	# Build a prompt container
	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var info_label := Label.new()
	info_label.text = "%s  str %s" % [ice_name, ice_str]
	info_label.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(info_label)

	# List subroutines
	for i in range(encounter.subroutines.size()):
		var sub: Dictionary = encounter.subroutines[i] as Dictionary
		var lbl := Label.new()
		var broken_marker := "[BROKEN] " if encounter.is_broken(i) else ""
		lbl.text = "  ↳ %s%s" % [broken_marker, sub.get("label", "sub %d" % i)]
		lbl.add_theme_font_size_override("font_size", 10)
		prompt_box.add_child(lbl)

	# Breaker buttons
	var breakers := encounter.breakers_for_ice()
	if breakers.is_empty():
		var no_breaker_lbl := Label.new()
		no_breaker_lbl.text = "(no matching icebreaker installed)"
		no_breaker_lbl.add_theme_font_size_override("font_size", 10)
		prompt_box.add_child(no_breaker_lbl)
	else:
		for breaker in breakers:
			var b: InstalledCard = breaker as InstalledCard
			var b_str := str(encounter.get_breaker_strength(b))
			var row := HBoxContainer.new()
			prompt_box.add_child(row)

			var b_lbl := Label.new()
			b_lbl.text = "%s (str %s)" % [b.display_name(), b_str]
			b_lbl.add_theme_font_size_override("font_size", 10)
			b_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(b_lbl)

			var break_btn := Button.new()
			break_btn.text = "Break All"
			break_btn.pressed.connect(func():
				encounter_action_resolved.emit({"type": "break_all", "card_id": b.card_id})
			)
			row.add_child(break_btn)

			var boost_btn := Button.new()
			boost_btn.text = "Boost +str"
			boost_btn.pressed.connect(func():
				encounter_action_resolved.emit({"type": "boost_strength", "card_id": b.card_id, "times": 1})
			)
			row.add_child(boost_btn)

	# Bioroid click-break — show if ice is a bioroid and runner has clicks
	if encounter.ice_card != null and encounter.ice_card.card_record != null:
		if encounter.ice_card.card_record.has_subtype("bioroid") and _ctx.runner_clicks > 0:
			var bioroid_lbl := Label.new()
			bioroid_lbl.text = "BIOROID — spend 1 click to break a subroutine:"
			bioroid_lbl.add_theme_font_size_override("font_size", 10)
			bioroid_lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
			prompt_box.add_child(bioroid_lbl)
			for i in range(encounter.subroutines.size()):
				if encounter.is_broken(i):
					continue
				var sub: Dictionary = encounter.subroutines[i] as Dictionary
				var click_btn := Button.new()
				click_btn.text = "[1 click] Break: %s" % sub.get("label", "sub %d" % i)
				var idx := i
				click_btn.pressed.connect(func():
					encounter_action_resolved.emit({"type": "break_with_click", "sub_index": idx})
				)
				prompt_box.add_child(click_btn)

	# Leech hosted credits — show if any Leech is installed with credits
	for rig_card in _ctx.runner_rig:
		var rc: InstalledCard = rig_card as InstalledCard
		if rc == null or rc.card_record == null:
			continue
		var hosted: int = rc.get_counter("credits")
		if hosted > 0:
			var leech_row := HBoxContainer.new()
			prompt_box.add_child(leech_row)
			var leech_lbl := Label.new()
			leech_lbl.text = "%s (%d hosted cr)" % [rc.display_name(), hosted]
			leech_lbl.add_theme_font_size_override("font_size", 10)
			leech_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			leech_row.add_child(leech_lbl)
			var spend_btn := Button.new()
			spend_btn.text = "Spend 1 cr"
			var cid := rc.card_id  # capture
			spend_btn.pressed.connect(func():
				encounter_action_resolved.emit({"type": "spend_hosted_credits", "card_id": cid, "amount": 1})
			)
			leech_row.add_child(spend_btn)

	# Self-break ability (e.g. N-Pot: 3cr to break 1 sub, runner-only)
	if _ability_registry != null and encounter.ice_card != null:
		var ice_def: Dictionary = _ability_registry._abilities.get(encounter.ice_card.card_id, {}) as Dictionary
		var self_break: Dictionary = ice_def.get("runner_self_break", {}) as Dictionary
		if not self_break.is_empty():
			var sb_cost: int = self_break.get("cost_per_sub", 0)
			var has_unbroken := false
			for i in range(encounter.subroutines.size()):
				if not encounter.is_broken(i):
					has_unbroken = true
					break
			if has_unbroken:
				var sb_header := Label.new()
				sb_header.text = "SELF-BREAK (%dcr each):" % sb_cost
				sb_header.add_theme_font_size_override("font_size", 10)
				sb_header.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
				prompt_box.add_child(sb_header)
				for i in range(encounter.subroutines.size()):
					if encounter.is_broken(i):
						continue
					var sub: Dictionary = encounter.subroutines[i] as Dictionary
					var sb_btn := Button.new()
					sb_btn.text = "%dcr: Break \"%s\"" % [sb_cost, sub.get("label", "sub %d" % i)]
					sb_btn.add_theme_font_size_override("font_size", 10)
					sb_btn.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
					if _ctx.runner_credits < sb_cost:
						sb_btn.disabled = true
					var captured_i := i
					sb_btn.pressed.connect(func():
						encounter_action_resolved.emit({
							"type": "break_self_sub",
							"sub_index": captured_i,
							"cost": sb_cost
						})
					)
					prompt_box.add_child(sb_btn)

	# Pass button
	var pass_btn := Button.new()
	pass_btn.text = "Pass (let subs fire)"
	pass_btn.pressed.connect(func():
		encounter_action_resolved.emit({"type": "done"})
	)
	prompt_box.add_child(pass_btn)

	# Await the player's choice
	var result: Dictionary = await encounter_action_resolved
	prompt_box.queue_free()
	return result

## Shows a modal choice prompt for cards like Predictive Planogram.
## Returns an Array of chosen mode indices.
func show_modal_prompt(modes: Array, max_choices: int) -> Array:
	_append_log("MODAL: Choose %d option(s):" % max_choices)

	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var info_lbl := Label.new()
	info_lbl.text = "Choose %d:" % max_choices
	info_lbl.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(info_lbl)

	var chosen: Array = []

	for i in range(modes.size()):
		var mode: Dictionary = modes[i] as Dictionary
		var btn := Button.new()
		btn.text = mode.get("label", "Option %d" % i)
		var idx := i  # capture for lambda
		btn.pressed.connect(func():
			chosen.append(idx)
			if chosen.size() >= max_choices:
				modal_choice_resolved.emit(chosen.duplicate())
		)
		prompt_box.add_child(btn)

	var result: Array = await modal_choice_resolved
	prompt_box.queue_free()
	return result

## Shows a modal choice prompt for cards like Predictive Planogram.
## Returns Array of chosen mode indices.
func show_modes_prompt(modes: Array, max_choices: int) -> Array:
	_append_log("MODAL: Choose %d option(s):" % max_choices)

	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var info_lbl := Label.new()
	info_lbl.text = "Choose %d:" % max_choices
	info_lbl.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(info_lbl)

	var chosen: Array = []

	for i in range(modes.size()):
		var mode: Dictionary = modes[i] as Dictionary
		var btn := Button.new()
		btn.text = mode.get("label", "Option %d" % i)
		var idx := i
		btn.pressed.connect(func():
			if not chosen.has(idx):
				chosen.append(idx)
			if chosen.size() >= max_choices:
				mode_choice_resolved.emit(chosen)
		)
		prompt_box.add_child(btn)

	var result: Array = await mode_choice_resolved
	prompt_box.queue_free()
	return result

## Shows a server selection prompt for run-initiating events like Jailbreak.
func show_server_choice_prompt(allowed_servers: Array) -> String:
	_append_log("Choose a server to run:")

	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var lbl := Label.new()
	lbl.text = "Run on which server?"
	lbl.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(lbl)

	for server_id in allowed_servers:
		var display: String = {"hq": "HQ", "rd": "R&D", "archives": "Archives"}.get(server_id, "")
		if display == "":
			# Remote server: "remote_0" → "Remote 1" (1-indexed for readability)
			var parts: PackedStringArray = server_id.split("_")
			if parts.size() >= 2 and parts[0] == "remote":
				display = "Remote %d" % (parts[1].to_int() + 1)
			else:
				display = server_id
		var btn := Button.new()
		btn.text = display
		var sid: String = server_id  # capture raw ID — ctx.get_server() expects this
		btn.pressed.connect(func():
			server_choice_resolved.emit(sid)
		)
		prompt_box.add_child(btn)

	var result: String = await server_choice_resolved
	prompt_box.queue_free()
	return result

## Shows a deck search prompt — player picks one card from matching results.
func show_search_prompt(candidates: Array) -> CardRecord:
	_append_log("SEARCH: Choose a card to add to your grip:")

	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var lbl := Label.new()
	lbl.text = "Take which card?"
	lbl.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(lbl)

	for candidate in candidates:
		var r: CardRecord = candidate as CardRecord
		if r == null:
			continue
		var cost_str := "%d¢" % r.cost if r.cost >= 0 else "free"
		var btn := Button.new()
		btn.text = "%s  [%s] (%s)" % [r.title, r.card_type.capitalize(), cost_str]
		var record := r  # capture
		btn.pressed.connect(func():
			search_choice_resolved.emit(record)
		)
		prompt_box.add_child(btn)

	var result: CardRecord = await search_choice_resolved
	prompt_box.queue_free()
	return result

## Shows a Manegarm Skunkworks payment prompt.
## Returns the chosen Dictionary option, or null if the runner ends the run.
func show_payment_option_prompt(options: Array) -> Variant:
	_append_log("MANEGARM: Choose how to continue the run:")

	var prompt_box := VBoxContainer.new()
	action_menu.add_child(prompt_box)

	var lbl := Label.new()
	lbl.text = "Manegarm Skunkworks — pay to continue:"
	lbl.add_theme_font_size_override("font_size", 11)
	prompt_box.add_child(lbl)

	for opt in options:
		var o: Dictionary = opt as Dictionary
		var btn := Button.new()
		match o.get("type", ""):
			"clicks":
				btn.text = "Spend %d click(s) (%d available)" % [o.get("amount", 0), _ctx.runner_clicks]
			"credits":
				btn.text = "Pay %d credits (%d available)" % [o.get("amount", 0), _ctx.runner_credits]
			_:
				btn.text = str(o)
		var captured := o
		btn.pressed.connect(func():
			payment_option_resolved.emit(captured)
		)
		prompt_box.add_child(btn)

	# Always offer the option to end the run
	var end_btn := Button.new()
	end_btn.text = "End the run"
	end_btn.pressed.connect(func():
		payment_option_resolved.emit(null)
	)
	prompt_box.add_child(end_btn)

	var result: Variant = await payment_option_resolved
	prompt_box.queue_free()
	return result


# ── Score area viewer ─────────────────────────────────────────────────────────

func _on_score_area_clicked(meta: Variant) -> void:
	var which: String = str(meta)
	if which == "score_corp":
		_show_score_popup("Corp Score Area — %s" % _ctx.corp_name(), _ctx.corp_score_area)
	elif which == "score_runner":
		_show_score_popup("Runner Score Area — %s" % _ctx.runner_name(), _ctx.runner_score_area)
	elif which == "rig":
		_show_rig_popup()


func _show_rig_popup() -> void:
	if _score_popup != null and is_instance_valid(_score_popup):
		_score_popup.queue_free()
		_score_popup = null
		return

	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.45)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)
	_score_popup = backdrop

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(700, 200)
	backdrop.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	# Title bar
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = "RIG  //  %s/%s MU used" % [_ctx.runner_mu_used(), _ctx.runner_total_mu()]
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.pressed.connect(func():
		if is_instance_valid(_score_popup):
			_score_popup.queue_free()
			_score_popup = null
	)
	title_row.add_child(close_btn)

	if _ctx.runner_rig.is_empty():
		var empty := Label.new()
		empty.text = "Rig is empty."
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		vbox.add_child(empty)
	else:
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(0, 240)
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		vbox.add_child(scroll)

		var card_row := HBoxContainer.new()
		card_row.add_theme_constant_override("separation", 10)
		scroll.add_child(card_row)

		for installed in _ctx.runner_rig:
			var c: InstalledCard = installed as InstalledCard
			if c == null or c.card_record == null:
				continue
			var col := VBoxContainer.new()
			col.add_theme_constant_override("separation", 4)
			card_row.add_child(col)

			var card_view := CardView.new()
			col.add_child(card_view)
			card_view.setup(c.card_record, true)

			# MU cost
			if c.card_record.memory_cost > 0:
				var mu_lbl := Label.new()
				mu_lbl.text = "%d MU" % c.card_record.memory_cost
				mu_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				mu_lbl.add_theme_font_size_override("font_size", 11)
				mu_lbl.add_theme_color_override("font_color", Color(0.5, 0.75, 1.0))
				col.add_child(mu_lbl)

			# Hosted credits if any
			var credits: int = c.get_counter("credits")
			if credits > 0:
				var cr_lbl := Label.new()
				cr_lbl.text = "%d cr" % credits
				cr_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				cr_lbl.add_theme_font_size_override("font_size", 11)
				cr_lbl.add_theme_color_override("font_color", Color(0.8, 1.0, 0.6))
				col.add_child(cr_lbl)


			# Strength if icebreaker
			if c.card_record.card_type == "program":
				# Use the actual strength property from CardRecord
				var base_str: int = c.card_record.strength
				var str_bonus: int = _ctx.query_breaker_strength_bonus()
				
				# Just show card name subtype for now
				var sub_lbl := Label.new()
				# CardRecord.subtypes is an Array of strings; join them or take first
				var subtype_text: String = ""
				if not c.card_record.subtypes.is_empty():
					subtype_text = c.card_record.subtypes[0]  # or join(", ")
				sub_lbl.text = subtype_text
				if sub_lbl.text != "":
					sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
					sub_lbl.add_theme_font_size_override("font_size", 10)
					sub_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
					col.add_child(sub_lbl)

	backdrop.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			if is_instance_valid(_score_popup):
				_score_popup.queue_free()
				_score_popup = null
	)


func _show_score_popup(title: String, cards: Array) -> void:
	# Dismiss any existing popup first
	if _score_popup != null and is_instance_valid(_score_popup):
		_score_popup.queue_free()
		_score_popup = null
		return   # second click on same area toggles closed

	# Backdrop — clicking it closes the popup
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.45)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)
	_score_popup = backdrop

	# Panel
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(600, 200)
	backdrop.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	# Title bar with close button
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = title
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_lbl)

	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.pressed.connect(func():
		if is_instance_valid(_score_popup):
			_score_popup.queue_free()
			_score_popup = null
	)
	title_row.add_child(close_btn)

	# Card display row
	if cards.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No agendas scored yet."
		empty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		vbox.add_child(empty_lbl)
	else:
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(0, 220)
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		vbox.add_child(scroll)

		var card_row := HBoxContainer.new()
		card_row.add_theme_constant_override("separation", 8)
		scroll.add_child(card_row)

		for card_record in cards:
			var cr: CardRecord = card_record as CardRecord
			if cr == null:
				continue
			var col := VBoxContainer.new()
			col.add_theme_constant_override("separation", 4)
			card_row.add_child(col)

			var card_view := CardView.new()
			col.add_child(card_view)
			card_view.setup(cr, true)

			var pts_lbl := Label.new()
			pts_lbl.text = "%d pt%s" % [cr.agenda_points, "s" if cr.agenda_points != 1 else ""]
			pts_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			pts_lbl.add_theme_font_size_override("font_size", 12)
			pts_lbl.add_theme_color_override("font_color", Color(0.8, 1.0, 0.8))
			col.add_child(pts_lbl)

	# Close on backdrop click
	backdrop.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed:
			if is_instance_valid(_score_popup):
				_score_popup.queue_free()
				_score_popup = null
	)


# ── Choose-from-hand prompt ───────────────────────────────────────────────────

func show_choose_from_hand_prompt(hand: Array, prompt_text: String) -> Variant:
	var resolved: Variant = null
	var done := false

	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.5)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(600, 0)
	backdrop.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var lbl := Label.new()
	lbl.text = prompt_text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(lbl)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 220)
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var card_row := HBoxContainer.new()
	card_row.add_theme_constant_override("separation", 8)
	scroll.add_child(card_row)

	for entry in hand:
		var e: Dictionary = entry as Dictionary
		var record: CardRecord = e.get("card_record", null) as CardRecord
		if record == null:
			continue
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 4)
		card_row.add_child(col)

		var cv := CardView.new()
		col.add_child(cv)
		cv.setup(record, true)

		var btn := Button.new()
		btn.text = "Install"
		btn.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
		var captured: Variant = entry
		btn.pressed.connect(func():
			resolved = captured
			done = true
		)
		col.add_child(btn)

	var decline_btn := Button.new()
	decline_btn.text = "Decline"
	decline_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	decline_btn.pressed.connect(func():
		resolved = null
		done = true
	)
	vbox.add_child(decline_btn)

	while not done:
		await get_tree().process_frame

	backdrop.queue_free()
	_update_all_displays()
	return resolved


# ── Tāo ice swap prompt ───────────────────────────────────────────────────────

func show_ice_swap_prompt(eligible_servers: Array) -> Variant:
	var result: Variant = null
	var done := false

	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.5)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(520, 0)
	backdrop.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Tāo: choose two ICE on the same server to swap (or decline)"
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.95, 0.75))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(lbl)

	var selected_server: Server = null
	var selected_positions: Array = []
	var confirm_btn: Button

	var status_lbl := Label.new()
	status_lbl.text = "Select a server, then click two ICE positions."
	status_lbl.add_theme_font_size_override("font_size", 11)
	status_lbl.add_theme_color_override("font_color", Color(0.5, 0.7, 0.55))
	vbox.add_child(status_lbl)

	# Server buttons
	var server_vbox := VBoxContainer.new()
	server_vbox.add_theme_constant_override("separation", 6)
	vbox.add_child(server_vbox)

	var ice_row_container := VBoxContainer.new()
	vbox.add_child(ice_row_container)

	var rebuild_ice_row: Callable 
	rebuild_ice_row = func():
		for child in ice_row_container.get_children():
			child.queue_free()
		if selected_server == null:
			return
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		ice_row_container.add_child(row)
		for i in range(selected_server.ice.size()):
			var ice: InstalledCard = selected_server.ice[i] as InstalledCard
			var btn := Button.new()
			var name_str: String = ice.display_name() if ice.is_rezzed else "Unrezzed ICE"
			btn.text = "[%d] %s" % [i, name_str]
			var is_sel: bool = i in selected_positions
			btn.add_theme_color_override("font_color",
				Color(0.3, 1.0, 0.5) if is_sel else Color(0.7, 0.85, 0.72))
			var captured_i := i
			btn.pressed.connect(func():
				if captured_i in selected_positions:
					selected_positions.erase(captured_i)
				elif selected_positions.size() < 2:
					selected_positions.append(captured_i)
				rebuild_ice_row.call()
				if confirm_btn != null:
					confirm_btn.disabled = selected_positions.size() != 2
				status_lbl.text = "Selected: %s" % str(selected_positions) if not selected_positions.is_empty() \
					else "Click two ICE positions to select them."
			)
			row.add_child(btn)

	for server in eligible_servers:
		var s: Server = server as Server
		var srv_btn := Button.new()
		srv_btn.text = s.display_name()
		srv_btn.add_theme_color_override("font_color", Color(0.6, 0.85, 0.7))
		srv_btn.pressed.connect(func():
			selected_server = s
			selected_positions.clear()
			rebuild_ice_row.call()
			status_lbl.text = "Click two ICE positions to swap."
			if confirm_btn != null:
				confirm_btn.disabled = true
		)
		server_vbox.add_child(srv_btn)

	# Action buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var decline_btn := Button.new()
	decline_btn.text = "Decline"
	decline_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	decline_btn.pressed.connect(func():
		result = null
		done = true
	)
	btn_row.add_child(decline_btn)

	confirm_btn = Button.new()
	confirm_btn.text = "Swap"
	confirm_btn.disabled = true
	confirm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_btn.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	confirm_btn.pressed.connect(func():
		if selected_server != null and selected_positions.size() == 2:
			result = {
				"server": selected_server,
				"pos_a": selected_positions[0],
				"pos_b": selected_positions[1]
			}
		done = true
	)
	btn_row.add_child(confirm_btn)

	while not done:
		await get_tree().process_frame

	backdrop.queue_free()
	_update_all_displays()
	return result


# ── Pay-to-avoid-damage prompt (Measured Response) ───────────────────────────

func show_pay_to_avoid_damage_prompt(cost: int, damage: int, damage_type: String) -> bool:
	var result := false
	var done   := false

	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.5)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(360, 0)
	backdrop.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Corp plays Measured Response!\nPay %d cr to prevent %d %s damage?" % [
		cost, damage, damage_type.capitalize()
	]
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.65, 0.3))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(lbl)

	var credits_lbl := Label.new()
	credits_lbl.text = "You have %d credit(s)." % _ctx.runner_credits
	credits_lbl.add_theme_font_size_override("font_size", 11)
	credits_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	vbox.add_child(credits_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var no_btn := Button.new()
	no_btn.text = "Take %d Damage" % damage
	no_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	no_btn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	no_btn.pressed.connect(func():
		result = false
		done = true
	)
	btn_row.add_child(no_btn)

	var yes_btn := Button.new()
	yes_btn.text = "Pay %d cr" % cost
	yes_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	yes_btn.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
	if _ctx.runner_credits < cost:
		yes_btn.disabled = true
	yes_btn.pressed.connect(func():
		result = true
		done = true
	)
	btn_row.add_child(yes_btn)

	while not done:
		await get_tree().process_frame

	backdrop.queue_free()
	return result


# ── Optional ability prompt (e.g. Cacophony end-of-turn counter spend) ───────

func show_optional_ability_prompt(prompt_text: String) -> bool:
	var result := false
	var done   := false

	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.5)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(340, 0)
	backdrop.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var lbl := Label.new()
	lbl.text = prompt_text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var no_btn := Button.new()
	no_btn.text = "Decline"
	no_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	no_btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	no_btn.pressed.connect(func():
		result = false
		done = true
	)
	btn_row.add_child(no_btn)

	var yes_btn := Button.new()
	yes_btn.text = "Activate"
	yes_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	yes_btn.add_theme_color_override("font_color", Color(0.4, 0.9, 0.5))
	yes_btn.pressed.connect(func():
		result = true
		done = true
	)
	btn_row.add_child(yes_btn)

	while not done:
		await get_tree().process_frame

	backdrop.queue_free()
	return result


# ── Carnivore prompt ──────────────────────────────────────────────────────────

func show_carnivore_prompt(card_record: CardRecord) -> bool:
	var result := false
	var done   := false

	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.5)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(380, 0)
	backdrop.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var lbl := Label.new()
	lbl.text = "Carnivore: trash 2 cards from your grip to trash\n%s?" % card_record.title
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.6, 0.4))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(lbl)

	var grip_lbl := Label.new()
	grip_lbl.text = "You have %d card(s) in grip." % _ctx.runner_hand.size()
	grip_lbl.add_theme_font_size_override("font_size", 11)
	grip_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	vbox.add_child(grip_lbl)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var no_btn := Button.new()
	no_btn.text = "Pass"
	no_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	no_btn.pressed.connect(func():
		result = false
		done = true
	)
	btn_row.add_child(no_btn)

	var yes_btn := Button.new()
	yes_btn.text = "Use Carnivore (trash 2)"
	yes_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	yes_btn.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))
	yes_btn.pressed.connect(func():
		result = true
		done = true
	)
	btn_row.add_child(yes_btn)

	while not done:
		await get_tree().process_frame

	backdrop.queue_free()
	return result
