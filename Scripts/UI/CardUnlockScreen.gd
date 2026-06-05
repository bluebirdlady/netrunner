class_name CardUnlockScreen
extends CanvasLayer

# ── CardUnlockScreen ──────────────────────────────────────────────────────────
# Displays newly unlocked cards one at a time after a mission victory.
# Call show_unlocks(card_records, done_callback) to begin the sequence.
# ─────────────────────────────────────────────────────────────────────────────

# Faction accent colours — runner and Corp.
const FACTION_COLORS := {
	"anarch":                Color(0.90, 0.30, 0.12),
	"criminal":              Color(0.18, 0.52, 0.90),
	"shaper":                Color(0.18, 0.78, 0.35),
	"haas-bioroid":          Color(0.48, 0.48, 0.88),
	"jinteki":               Color(0.88, 0.22, 0.28),
	"nbn":                   Color(0.90, 0.78, 0.12),
	"weyland-consortium":    Color(0.28, 0.68, 0.32),
	"neutral-corp":          Color(0.52, 0.52, 0.52),
	"neutral-runner":        Color(0.52, 0.52, 0.52),
	"mini":                  Color(0.65, 0.48, 0.82),
}
const FACTION_DEFAULT := Color(0.50, 0.50, 0.50)

const COLOR_BG       := Color(0.03, 0.04, 0.06, 0.96)
const COLOR_PANEL    := Color(0.07, 0.09, 0.12)
const COLOR_BORDER   := Color(0.20, 0.17, 0.10)
const COLOR_GOLD     := Color(0.85, 0.65, 0.15)
const COLOR_TEXT     := Color(0.88, 0.88, 0.88)
const COLOR_SUBTEXT  := Color(0.55, 0.55, 0.60)
const COLOR_FLAVOR   := Color(0.48, 0.50, 0.58)

# ── State ─────────────────────────────────────────────────────────────────────

var _cards:    Array    = []   # Array[CardRecord]
var _index:    int      = 0
var _callback: Callable = Callable()

# ── UI node refs ──────────────────────────────────────────────────────────────

var _root_ctrl:       Control
var _panel:           PanelContainer
var _faction_stripe:  ColorRect
var _counter_label:   Label
var _card_view:       CardView
var _title_label:     Label
var _faction_label:   Label
var _type_cost_label: Label
var _text_label:      RichTextLabel
var _flavor_label:    Label
var _continue_btn:    Button
var _tween:           Tween


# ── Entry point ───────────────────────────────────────────────────────────────

func show_unlocks(card_records: Array, done_callback: Callable) -> void:
	_cards    = card_records.duplicate()
	_index    = 0
	_callback = done_callback
	if _cards.is_empty():
		done_callback.call()
		return
	_build_ui()
	_show_card(0)
	_play_enter_anim()


# ── UI Construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	layer = 25   # above everything including FictionViewer

	# ── Backdrop ────────────────────────────────────────────────────────────
	_root_ctrl = Control.new()
	_root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_ctrl.modulate.a = 0.0   # start invisible for fade-in
	add_child(_root_ctrl)

	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_ctrl.add_child(bg)

	# ── Outer container (centred, fixed width) ───────────────────────────────
	var outer := VBoxContainer.new()
	outer.set_anchors_preset(Control.PRESET_CENTER)
	outer.custom_minimum_size = Vector2(860, 0)
	outer.offset_left = -430
	outer.offset_right =  430
	# Vertical centring handled by offset_top at layout time; approximate here.
	outer.offset_top  = -300
	outer.offset_bottom = 350
	outer.add_theme_constant_override("separation", 10)
	_root_ctrl.add_child(outer)

	# ── Header ───────────────────────────────────────────────────────────────
	var header := Label.new()
	header.text = "// CARD UNLOCKED //"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 16)
	header.add_theme_color_override("font_color", COLOR_GOLD)
	outer.add_child(header)

	_counter_label = Label.new()
	_counter_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_counter_label.add_theme_font_size_override("font_size", 11)
	_counter_label.add_theme_color_override("font_color", COLOR_SUBTEXT)
	outer.add_child(_counter_label)

	# ── Main panel ───────────────────────────────────────────────────────────
	_panel = PanelContainer.new()
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color            = COLOR_PANEL
	panel_style.border_color        = COLOR_BORDER
	panel_style.border_width_top    = 1
	panel_style.border_width_left   = 1
	panel_style.border_width_right  = 1
	panel_style.border_width_bottom = 1
	panel_style.corner_radius_top_left     = 6
	panel_style.corner_radius_top_right    = 6
	panel_style.corner_radius_bottom_left  = 6
	panel_style.corner_radius_bottom_right = 6
	panel_style.content_margin_left   = 24
	panel_style.content_margin_right  = 24
	panel_style.content_margin_top    = 20
	panel_style.content_margin_bottom = 20
	_panel.add_theme_stylebox_override("panel", panel_style)
	outer.add_child(_panel)

	var inner_hbox := HBoxContainer.new()
	inner_hbox.add_theme_constant_override("separation", 28)
	_panel.add_child(inner_hbox)

	# ── Left: card art ───────────────────────────────────────────────────────
	var art_wrap := Control.new()
	art_wrap.custom_minimum_size = Vector2(230, 340)
	art_wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	inner_hbox.add_child(art_wrap)

	_card_view = CardView.new()
	_card_view.position = Vector2.ZERO
	_card_view.size     = Vector2(230, 340)
	art_wrap.add_child(_card_view)

	# ── Right: card details ──────────────────────────────────────────────────
	var detail_vbox := VBoxContainer.new()
	detail_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	detail_vbox.add_theme_constant_override("separation", 6)
	inner_hbox.add_child(detail_vbox)

	# Faction colour stripe
	_faction_stripe = ColorRect.new()
	_faction_stripe.custom_minimum_size = Vector2(0, 3)
	detail_vbox.add_child(_faction_stripe)

	var spacer_top := Control.new()
	spacer_top.custom_minimum_size = Vector2(0, 4)
	detail_vbox.add_child(spacer_top)

	# Title
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.add_theme_color_override("font_color", COLOR_TEXT)
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	detail_vbox.add_child(_title_label)

	# Faction
	_faction_label = Label.new()
	_faction_label.add_theme_font_size_override("font_size", 11)
	_faction_label.add_theme_color_override("font_color", COLOR_SUBTEXT)
	detail_vbox.add_child(_faction_label)

	# Type · cost
	_type_cost_label = Label.new()
	_type_cost_label.add_theme_font_size_override("font_size", 12)
	_type_cost_label.add_theme_color_override("font_color", COLOR_SUBTEXT)
	detail_vbox.add_child(_type_cost_label)

	var sep := HSeparator.new()
	detail_vbox.add_child(sep)

	# Card text
	_text_label = RichTextLabel.new()
	_text_label.bbcode_enabled  = true
	_text_label.fit_content     = false
	_text_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text_label.add_theme_font_size_override("normal_font_size", 13)
	_text_label.add_theme_color_override("default_color", COLOR_TEXT)
	_text_label.scroll_active = false
	detail_vbox.add_child(_text_label)

	# Flavor text
	_flavor_label = Label.new()
	_flavor_label.add_theme_font_size_override("font_size", 11)
	_flavor_label.add_theme_color_override("font_color", COLOR_FLAVOR)
	_flavor_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	detail_vbox.add_child(_flavor_label)

	# ── Continue button ──────────────────────────────────────────────────────
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	outer.add_child(btn_row)

	_continue_btn = Button.new()
	_continue_btn.custom_minimum_size = Vector2(180, 40)
	_continue_btn.add_theme_font_size_override("font_size", 14)
	_continue_btn.add_theme_color_override("font_color", COLOR_GOLD)
	_continue_btn.pressed.connect(_on_continue_pressed)
	btn_row.add_child(_continue_btn)


# ── Card display ──────────────────────────────────────────────────────────────

func _show_card(idx: int) -> void:
	var record: CardRecord = _cards[idx] as CardRecord

	# Counter label
	if _cards.size() == 1:
		_counter_label.text = ""
	else:
		_counter_label.text = "%d  /  %d" % [idx + 1, _cards.size()]

	# Art — CardView handles async loading gracefully
	_card_view.setup(record, true)

	# Faction colour
	var faction_col: Color = FACTION_COLORS.get(record.faction, FACTION_DEFAULT)
	_faction_stripe.color = faction_col

	# Title
	_title_label.text = record.title
	_title_label.add_theme_color_override("font_color", COLOR_TEXT)

	# Faction display name
	var faction_display: String = record.faction.replace("-", " ").replace("_", " ").capitalize()
	_faction_label.text = faction_display
	_faction_label.add_theme_color_override("font_color", faction_col)

	# Type · cost line
	var type_str: String = record.card_type.replace("_", " ").capitalize()
	var cost_str: String = ""
	if record.card_type in ["program", "hardware", "resource", "event", "operation", "asset", "upgrade", "ice"]:
		var c: int = record.cost
		cost_str = "  ·  %s" % ("?" if c < 0 else "%d[c]" % c)
	elif record.card_type == "agenda":
		var req: int = record.advancement_requirement
		var pts: int = record.agenda_points
		cost_str = "  ·  Adv %d  ·  %d pts" % [req, pts]
	_type_cost_label.text = type_str + cost_str

	# Card text — strip markup, show plain
	var card_text: String = record.stripped_text if record.stripped_text != "" else record.text
	# Convert [c], [click], etc. to readable symbols
	card_text = card_text.replace("[c]", "¢").replace("[credit]", "¢")
	card_text = card_text.replace("[click]", "●").replace("[trash]", "⊘")
	_text_label.text = card_text

	# Flavor text
	_flavor_label.visible = record.flavor_text != ""
	_flavor_label.text = ('"%s"' % record.flavor_text) if record.flavor_text != "" else ""

	# Button label
	var is_last: bool = idx >= _cards.size() - 1
	_continue_btn.text = "DONE  ✓" if is_last else "NEXT  →"

	# Update panel border to faction colour
	var panel_style: StyleBoxFlat = _panel.get_theme_stylebox("panel") as StyleBoxFlat
	if panel_style != null:
		panel_style.border_color = faction_col.darkened(0.35)


# ── Animation ─────────────────────────────────────────────────────────────────

func _play_enter_anim() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_root_ctrl, "modulate:a", 1.0, 0.25).set_ease(Tween.EASE_OUT)


func _play_exit_anim(on_done: Callable) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_root_ctrl, "modulate:a", 0.0, 0.18).set_ease(Tween.EASE_IN)
	_tween.tween_callback(on_done)


# ── Input ─────────────────────────────────────────────────────────────────────

func _on_continue_pressed() -> void:
	_index += 1
	if _index < _cards.size():
		# Brief fade between cards
		if _tween != null and _tween.is_valid():
			_tween.kill()
		_tween = create_tween()
		_tween.tween_property(_root_ctrl, "modulate:a", 0.6, 0.10)
		_tween.tween_callback(func(): _show_card(_index))
		_tween.tween_property(_root_ctrl, "modulate:a", 1.0, 0.15)
	else:
		_continue_btn.disabled = true
		_play_exit_anim(_callback)
