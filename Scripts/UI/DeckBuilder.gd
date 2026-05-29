class_name DeckBuilder
extends CanvasLayer

# ── DeckBuilder ───────────────────────────────────────────────────────────────
# Collection browser for building a runner deck from unlocked cards.
# Features: card art hover, filters by type/faction, search bar, influence tracking.
# Emits deck_saved(identity_id, cards_dict) when player confirms.

signal deck_saved(identity_id: String, cards: Dictionary)
signal cancelled

# Inner class used by the Save Build dialog to avoid while-loop coroutine capture issues.
class _Dialog extends RefCounted:
	signal submitted(name: String)

const FALLBACK_MIN_DECK := 30
const FALLBACK_MAX_COPIES := 3

const COLOR_BG      := Color(0.04, 0.05, 0.07)
const COLOR_PANEL   := Color(0.07, 0.09, 0.11)
const COLOR_BORDER  := Color(0.15, 0.28, 0.18)
const COLOR_ACCENT  := Color(0.25, 0.85, 0.45)
const COLOR_WARN    := Color(0.85, 0.45, 0.25)
const COLOR_IN_DECK := Color(0.2, 0.6, 0.3)
const COLOR_DISABLED:= Color(0.25, 0.28, 0.25)

var _state:         CampaignState
var _identity:      CardRecord = null
var _card_pool:     Array = []   # Array[CardRecord] all unlocked non-identity cards
var _identity_records: Array = []   # Array[CardRecord] unlocked identity cards
var _pool_counts:   Dictionary = {}   # card_id → max owned
var _deck_cards:    Dictionary = {}   # card_id → count in deck
var _filtered:      Array = []   # current filtered view

# Filter state
var _filter_type:    String = ""    # "" = all
var _filter_faction: String = ""    # "" = all
var _search_text:    String = ""

# UI nodes
var _collection_grid:      GridContainer
var _identity_section:     VBoxContainer   # lives above the collection scroll
var _deck_list:            VBoxContainer
var _deck_title_label:     Label
var _stats_label:          Label
var _search_field:         LineEdit
var _save_btn:             Button
var _influence_label:      Label
var _saved_decks_container: VBoxContainer  # list of named builds in the right panel
var _format_label:         Label              # current format (Gateway / Startup / Standard)
var _ban_label:            Label              # banned-card warning (hidden when no bans)


func _ready() -> void:
	layer = 20
	_build_ui()


func setup(state: CampaignState) -> void:
	_state = state
	_pool_counts = state.get_unlocked_card_pool()

	# Load current deck
	var deck_data := state.get_current_deck()
	_deck_cards = deck_data.get("cards", {}).duplicate() as Dictionary

	# Separate pool into identities and regular cards
	_identity_records = []
	_card_pool = []
	for card_id in _pool_counts:
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record == null:
			continue
		if record.is_identity():
			_identity_records.append(record)
		else:
			_card_pool.append(record)

	# Sort identities alphabetically; regular cards by type → title
	_identity_records.sort_custom(func(a: CardRecord, b: CardRecord): return a.title < b.title)
	_card_pool.sort_custom(func(a: CardRecord, b: CardRecord):
		if a.card_type != b.card_type:
			return a.card_type < b.card_type
		return a.title < b.title
	)

	# Set active identity to the saved deck's choice (or first available)
	var saved_identity_id: String = state.get_runner_identity_id()
	_identity = CardRegistry.get_card(saved_identity_id)
	if _identity == null and not _identity_records.is_empty():
		_identity = _identity_records[0]

	_apply_filters()
	_refresh_stats()
	_rebuild_saved_decks_panel()


# ── Filtering ─────────────────────────────────────────────────────────────────

func _apply_filters() -> void:
	_filtered = _card_pool.filter(func(r: CardRecord):
		if _filter_type != "" and r.card_type != _filter_type:
			return false
		if _filter_faction != "" and r.faction != _filter_faction:
			return false
		if _search_text != "" and not r.title.to_lower().contains(_search_text.to_lower()):
			return false
		return true
	)
	_rebuild_identity_section()
	_rebuild_collection_grid()


# ── Stats ─────────────────────────────────────────────────────────────────────

func _deck_size() -> int:
	var total := 0
	for count in _deck_cards.values():
		total += int(count)
	return total


func _influence_used() -> int:
	if _identity == null:
		return 0
	var identity_faction: String = _identity.faction
	var used := 0
	for card_id in _deck_cards:
		var count: int = int(_deck_cards[card_id])
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record == null:
			continue
		if record.faction != identity_faction:
			used += record.influence_cost * count
	return used


func _min_deck_size() -> int:
	if _identity != null and _identity.minimum_deck_size > 0:
		return _identity.minimum_deck_size
	return FALLBACK_MIN_DECK


func _influence_limit() -> int:
	if _identity == null:
		return 15
	return _identity.influence_limit if _identity.influence_limit > 0 else 15


func _current_format() -> String:
	var all_ids: Array = _deck_cards.keys().duplicate()
	if _identity != null:
		all_ids.append(_identity.id)
	return BanListManager.detect_format(all_ids)


func _get_banned_in_deck() -> Array:
	var all_ids: Array = _deck_cards.keys().duplicate()
	if _identity != null:
		all_ids.append(_identity.id)
	var fmt := BanListManager.detect_format(all_ids)
	return BanListManager.banned_in_deck(all_ids, fmt)


func _is_deck_legal() -> bool:
	return _deck_size() >= _min_deck_size() \
		and _influence_used() <= _influence_limit() \
		and _get_banned_in_deck().is_empty()


func _refresh_stats() -> void:
	var size   := _deck_size()
	var min_sz := _min_deck_size()
	var inf_u  := _influence_used()
	var inf_l  := _influence_limit()
	var banned := _get_banned_in_deck()
	var legal  := size >= min_sz and inf_u <= inf_l and banned.is_empty()

	var inf_color := COLOR_ACCENT if inf_u <= inf_l else COLOR_WARN

	_stats_label.text = "Cards: %d / %d min" % [size, min_sz]
	_stats_label.add_theme_color_override("font_color",
		COLOR_ACCENT if size >= min_sz else COLOR_WARN)

	_influence_label.text = "Influence: %d / %d" % [inf_u, inf_l]
	_influence_label.add_theme_color_override("font_color", inf_color)

	# Format label
	var fmt := _current_format()
	const FMT_NAMES := {
		"gateway":  "System Gateway — No Bans",
		"startup":  "Startup",
		"standard": "Standard",
	}
	_format_label.text = "Format: %s" % FMT_NAMES.get(fmt, fmt.capitalize())
	_format_label.add_theme_color_override("font_color",
		Color(0.40, 0.70, 0.45) if fmt == "gateway" else Color(0.72, 0.84, 0.78))

	# Ban warning (hidden when deck is clean)
	if banned.is_empty():
		_ban_label.visible = false
	else:
		var ban_names: Array = banned.map(func(id: String) -> String:
			var r: CardRecord = CardRegistry.get_card(id)
			return r.title if r != null else id
		)
		_ban_label.text = "⚠ Banned: %s" % ", ".join(ban_names)
		_ban_label.visible = true

	_save_btn.disabled = not legal
	_save_btn.add_theme_color_override("font_color",
		COLOR_ACCENT if legal else COLOR_DISABLED)

	_rebuild_deck_list()


# ── UI Construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	# Scanlines
	root.add_child(_make_scanlines())

	# Header
	var header := _build_header()
	header.set_anchors_preset(Control.PRESET_TOP_WIDE)
	header.custom_minimum_size = Vector2(0, 52)
	header.offset_bottom = 52
	root.add_child(header)

	# Main layout: collection (left) + deck (right)
	var main_hbox := HBoxContainer.new()
	main_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_hbox.offset_top    = 60
	main_hbox.offset_left   = 12
	main_hbox.offset_right  = -12
	main_hbox.offset_bottom = -12
	main_hbox.add_theme_constant_override("separation", 12)
	root.add_child(main_hbox)

	# Left: filter bar + identity section + collection grid
	var left_vbox := VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.add_theme_constant_override("separation", 6)
	main_hbox.add_child(left_vbox)

	left_vbox.add_child(_build_filter_bar())

	# Identity cards live here — rebuilt by _rebuild_identity_section()
	_identity_section = VBoxContainer.new()
	_identity_section.add_theme_constant_override("separation", 4)
	left_vbox.add_child(_identity_section)

	var collection_scroll := ScrollContainer.new()
	collection_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	collection_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_vbox.add_child(collection_scroll)

	_collection_grid = GridContainer.new()
	_collection_grid.columns = 6
	_collection_grid.add_theme_constant_override("h_separation", 8)
	_collection_grid.add_theme_constant_override("v_separation", 8)
	_collection_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	collection_scroll.add_child(_collection_grid)

	# Right: deck list + stats
	var right_panel := _make_panel(360, true)
	main_hbox.add_child(right_panel)

	var right_vbox := VBoxContainer.new()
	right_vbox.add_theme_constant_override("separation", 6)
	right_panel.add_child(right_vbox)

	var deck_hdr_row := HBoxContainer.new()
	right_vbox.add_child(deck_hdr_row)

	_deck_title_label = Label.new()
	_deck_title_label.text = "// YOUR DECK //"
	_deck_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_deck_title_label.add_theme_font_size_override("font_size", 12)
	_deck_title_label.add_theme_color_override("font_color", Color(0.3, 0.6, 0.35))
	deck_hdr_row.add_child(_deck_title_label)

	var clear_btn := Button.new()
	clear_btn.text = "✕ Clear"
	clear_btn.add_theme_font_size_override("font_size", 10)
	clear_btn.add_theme_color_override("font_color", COLOR_WARN)
	clear_btn.pressed.connect(func():
		_deck_cards.clear()
		_apply_filters()
		_refresh_stats()
	)
	deck_hdr_row.add_child(clear_btn)

	# Stats row
	var stats_row := HBoxContainer.new()
	right_vbox.add_child(stats_row)

	_stats_label = Label.new()
	_stats_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats_label.add_theme_font_size_override("font_size", 11)
	stats_row.add_child(_stats_label)

	_influence_label = Label.new()
	_influence_label.add_theme_font_size_override("font_size", 11)
	stats_row.add_child(_influence_label)

	# Format row — shows detected rules environment
	_format_label = Label.new()
	_format_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_format_label.add_theme_font_size_override("font_size", 10)
	right_vbox.add_child(_format_label)

	# Ban warning — hidden until a banned card is detected in the deck
	_ban_label = Label.new()
	_ban_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ban_label.add_theme_font_size_override("font_size", 10)
	_ban_label.add_theme_color_override("font_color", COLOR_WARN)
	_ban_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ban_label.visible = false
	right_vbox.add_child(_ban_label)

	var sep := HSeparator.new()
	sep.add_theme_color_override("separation_color", COLOR_BORDER)
	right_vbox.add_child(sep)

	# Deck list scroll
	var deck_scroll := ScrollContainer.new()
	deck_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	deck_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_vbox.add_child(deck_scroll)

	_deck_list = VBoxContainer.new()
	_deck_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_deck_list.add_theme_constant_override("separation", 2)
	deck_scroll.add_child(_deck_list)

	# Save / Cancel buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	right_vbox.add_child(btn_row)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func(): cancelled.emit(); queue_free())
	btn_row.add_child(cancel_btn)

	_save_btn = Button.new()
	_save_btn.text = "▶  Save Deck"
	_save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_btn.pressed.connect(_on_save_pressed)
	btn_row.add_child(_save_btn)

	# ── Saved builds section ──────────────────────────────────────────────────
	var builds_sep := HSeparator.new()
	builds_sep.add_theme_color_override("separation_color", COLOR_BORDER)
	right_vbox.add_child(builds_sep)

	var builds_hdr_row := HBoxContainer.new()
	right_vbox.add_child(builds_hdr_row)

	var builds_lbl := Label.new()
	builds_lbl.text = "SAVED BUILDS"
	builds_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	builds_lbl.add_theme_font_size_override("font_size", 9)
	builds_lbl.add_theme_color_override("font_color", Color(0.3, 0.55, 0.35))
	builds_hdr_row.add_child(builds_lbl)

	var save_build_btn := Button.new()
	save_build_btn.text = "💾  Save Build"
	save_build_btn.add_theme_font_size_override("font_size", 10)
	save_build_btn.pressed.connect(_start_save_build_dialog)
	builds_hdr_row.add_child(save_build_btn)

	var builds_scroll := ScrollContainer.new()
	builds_scroll.custom_minimum_size = Vector2(0, 110)
	builds_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	builds_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_vbox.add_child(builds_scroll)

	_saved_decks_container = VBoxContainer.new()
	_saved_decks_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_saved_decks_container.add_theme_constant_override("separation", 4)
	builds_scroll.add_child(_saved_decks_container)


func _build_header() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.10)
	style.border_color = COLOR_BORDER
	style.border_width_bottom = 1
	style.content_margin_left = 20
	style.content_margin_top  = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)

	var title := Label.new()
	title.text = "// DECK BUILDER"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOR_ACCENT)
	panel.add_child(title)

	return panel


func _build_filter_bar() -> HBoxContainer:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	# Search
	_search_field = LineEdit.new()
	_search_field.placeholder_text = "Search cards..."
	_search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_field.text_changed.connect(func(t: String):
		_search_text = t
		_apply_filters()
	)
	hbox.add_child(_search_field)

	# Type filter
	var type_opts := OptionButton.new()
	type_opts.custom_minimum_size = Vector2(120, 0)
	for pair in [["All Types", ""], ["Identity", "identity"], ["Event", "event"],
				 ["Program", "program"], ["Hardware", "hardware"], ["Resource", "resource"]]:
		type_opts.add_item(pair[0])
		type_opts.set_item_metadata(type_opts.item_count - 1, pair[1])
	type_opts.item_selected.connect(func(idx: int):
		_filter_type = type_opts.get_item_metadata(idx)
		_apply_filters()
	)
	hbox.add_child(type_opts)

	# Faction filter
	var faction_opts := OptionButton.new()
	faction_opts.custom_minimum_size = Vector2(130, 0)
	for pair in [["All Factions", ""], ["Anarch", "anarch"],
				 ["Criminal", "criminal"], ["Shaper", "shaper"]]:
		faction_opts.add_item(pair[0])
		faction_opts.set_item_metadata(faction_opts.item_count - 1, pair[1])
	faction_opts.item_selected.connect(func(idx: int):
		_filter_faction = faction_opts.get_item_metadata(idx)
		_apply_filters()
	)
	hbox.add_child(faction_opts)

	# Clear button
	var clear_btn := Button.new()
	clear_btn.text = "✕ Clear"
	clear_btn.pressed.connect(func():
		_search_field.text = ""
		_search_text   = ""
		_filter_type   = ""
		_filter_faction = ""
		type_opts.selected   = 0
		faction_opts.selected = 0
		_apply_filters()
	)
	hbox.add_child(clear_btn)

	return hbox


# ── Identity section ──────────────────────────────────────────────────────────

func _rebuild_identity_section() -> void:
	if _identity_section == null:
		return
	for child in _identity_section.get_children():
		child.queue_free()

	# Hide when the player has narrowed to a specific non-identity type
	var show: bool = _filter_type == "" or _filter_type == "identity"
	_identity_section.visible = show
	if not show or _identity_records.is_empty():
		return

	# Apply search text to identities too
	var visible_ids: Array = _identity_records.filter(func(r: CardRecord):
		return _search_text == "" or r.title.to_lower().contains(_search_text.to_lower())
	)
	if visible_ids.is_empty():
		return

	var hdr := Label.new()
	hdr.text = "IDENTITY"
	hdr.add_theme_font_size_override("font_size", 9)
	hdr.add_theme_color_override("font_color", Color(0.3, 0.55, 0.35))
	_identity_section.add_child(hdr)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_identity_section.add_child(row)

	var id_fmt := _current_format()
	var id_banned := BanListManager.get_banned_ids(id_fmt)
	for record in visible_ids:
		row.add_child(_make_identity_card(record, record.id in id_banned))

	var sep := HSeparator.new()
	sep.add_theme_color_override("separation_color", COLOR_BORDER)
	_identity_section.add_child(sep)


func _make_identity_card(record: CardRecord, is_banned: bool = false) -> Control:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)
	container.custom_minimum_size = Vector2(130, 0)

	var card_view := CardView.new()
	container.add_child(card_view)
	card_view.setup(record, true)

	var is_active: bool = _identity != null and _identity.id == record.id

	var select_btn := Button.new()
	select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if is_active:
		select_btn.text = "◈  ACTIVE"
		select_btn.disabled = true
		select_btn.add_theme_color_override("font_color", COLOR_ACCENT)
	else:
		select_btn.text = "▶  SELECT"
		select_btn.pressed.connect(func():
			_identity = record
			_rebuild_identity_section()
			_refresh_stats()
		)
	container.add_child(select_btn)

	if is_banned:
		var ban_lbl := Label.new()
		ban_lbl.text = "⚠ BANNED"
		ban_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ban_lbl.add_theme_font_size_override("font_size", 9)
		ban_lbl.add_theme_color_override("font_color", COLOR_WARN)
		container.add_child(ban_lbl)

	return container


# ── Collection grid ───────────────────────────────────────────────────────────

func _rebuild_collection_grid() -> void:
	for child in _collection_grid.get_children():
		child.queue_free()

	# When filtering to "identity" only, the regular card grid is empty — that's fine.
	if _filter_type == "identity":
		return

	# Compute the current ban list once for the whole grid rebuild.
	var grid_banned := BanListManager.get_banned_ids(_current_format())
	for record in _filtered:
		_collection_grid.add_child(_make_collection_card(record, grid_banned))


func _make_collection_card(record: CardRecord, banned_ids: Array = []) -> Control:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)
	container.custom_minimum_size = Vector2(130, 0)

	# Card art
	var card_view := CardView.new()
	container.add_child(card_view)
	card_view.setup(record, true)

	# Count row: [-] [n/max] [+]
	var count_row := HBoxContainer.new()
	count_row.alignment = BoxContainer.ALIGNMENT_CENTER
	count_row.add_theme_constant_override("separation", 4)
	container.add_child(count_row)

	var in_deck: int       = int(_deck_cards.get(record.id, 0))
	var max_own: int       = int(_pool_counts.get(record.id, 0))
	var copy_cap: int      = record.deck_limit if record.deck_limit > 0 else FALLBACK_MAX_COPIES
	var effective_max: int = min(max_own, copy_cap)
	var inf_cost: int      = record.influence_cost
	var is_faction: bool   = _identity != null and record.faction == _identity.faction
	var is_banned: bool    = record.id in banned_ids

	var minus_btn := Button.new()
	minus_btn.text = "−"
	minus_btn.custom_minimum_size = Vector2(28, 0)
	minus_btn.disabled = in_deck <= 0
	minus_btn.pressed.connect(func(): _change_count(record.id, -1))
	count_row.add_child(minus_btn)

	var count_label := Label.new()
	count_label.text = "%d/%d" % [in_deck, effective_max]
	count_label.custom_minimum_size = Vector2(36, 0)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_label.add_theme_font_size_override("font_size", 11)
	count_label.add_theme_color_override("font_color",
		COLOR_IN_DECK if in_deck > 0 else Color(0.4, 0.45, 0.4))
	count_row.add_child(count_label)

	var plus_btn := Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size = Vector2(28, 0)
	# Banned cards may not be added, but existing copies can still be removed.
	plus_btn.disabled = in_deck >= effective_max or is_banned
	plus_btn.pressed.connect(func(): _change_count(record.id, +1))
	count_row.add_child(plus_btn)

	# Influence pip (show for out-of-faction cards)
	if inf_cost > 0 and not is_faction:
		var inf_label := Label.new()
		inf_label.text = "●".repeat(inf_cost)
		inf_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		inf_label.add_theme_font_size_override("font_size", 9)
		inf_label.add_theme_color_override("font_color", Color(0.8, 0.5, 0.2))
		container.add_child(inf_label)

	if is_banned:
		var ban_lbl := Label.new()
		ban_lbl.text = "⚠ BANNED"
		ban_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ban_lbl.add_theme_font_size_override("font_size", 9)
		ban_lbl.add_theme_color_override("font_color", COLOR_WARN)
		container.add_child(ban_lbl)

	return container


# ── Deck list ─────────────────────────────────────────────────────────────────

func _rebuild_deck_list() -> void:
	for child in _deck_list.get_children():
		child.queue_free()

	# Update deck panel title to reflect chosen identity
	if _deck_title_label != null:
		var id_name: String = _identity.title.to_upper() if _identity != null else "YOUR DECK"
		_deck_title_label.text = "// %s //" % id_name

	# Identity row at the top of the deck list
	if _identity != null:
		var id_hdr := Label.new()
		id_hdr.text = "IDENTITY"
		id_hdr.add_theme_font_size_override("font_size", 9)
		id_hdr.add_theme_color_override("font_color", Color(0.3, 0.55, 0.35))
		_deck_list.add_child(id_hdr)

		var id_row := HBoxContainer.new()
		id_row.add_theme_constant_override("separation", 6)

		var id_icon := Label.new()
		id_icon.text = "◈"
		id_icon.add_theme_font_size_override("font_size", 12)
		id_icon.add_theme_color_override("font_color", COLOR_ACCENT)
		id_row.add_child(id_icon)

		var id_name_lbl := Label.new()
		id_name_lbl.text = _identity.title
		id_name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		id_name_lbl.add_theme_font_size_override("font_size", 11)
		id_name_lbl.add_theme_color_override("font_color", COLOR_ACCENT)
		id_row.add_child(id_name_lbl)

		_deck_list.add_child(id_row)

		var id_sep := HSeparator.new()
		id_sep.add_theme_color_override("separation_color", COLOR_BORDER)
		_deck_list.add_child(id_sep)

	# Group by card type
	var by_type: Dictionary = {}
	for card_id in _deck_cards:
		var count: int = int(_deck_cards[card_id])
		if count <= 0:
			continue
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record == null:
			continue
		var ctype: String = record.card_type
		if ctype not in by_type:
			by_type[ctype] = []
		by_type[ctype].append({"record": record, "count": count})

	# Resolve the current ban list once for all deck entries.
	var dl_banned := BanListManager.get_banned_ids(_current_format())

	var type_order := ["event", "program", "hardware", "resource"]
	for ctype in type_order:
		if ctype not in by_type:
			continue
		var entries: Array = by_type[ctype]
		entries.sort_custom(func(a, b): return a["record"].title < b["record"].title)

		var header := Label.new()
		header.text = ctype.to_upper()
		header.add_theme_font_size_override("font_size", 9)
		header.add_theme_color_override("font_color", Color(0.3, 0.55, 0.35))
		_deck_list.add_child(header)

		for entry in entries:
			var record: CardRecord  = entry["record"]
			var count: int          = entry["count"]
			var entry_banned: bool  = record.id in dl_banned
			_deck_list.add_child(_make_deck_entry(record, count, entry_banned))


func _make_deck_entry(record: CardRecord, count: int, is_banned: bool = false) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var count_lbl := Label.new()
	count_lbl.text = "%d×" % count
	count_lbl.custom_minimum_size = Vector2(22, 0)
	count_lbl.add_theme_font_size_override("font_size", 11)
	count_lbl.add_theme_color_override("font_color", COLOR_IN_DECK)
	row.add_child(count_lbl)

	var name_lbl := Label.new()
	# Prefix banned entries so they're obvious even in a long list.
	name_lbl.text = ("⚠ " if is_banned else "") + record.title
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.add_theme_color_override("font_color",
		COLOR_WARN if is_banned else Color(0.8, 0.9, 0.82))
	row.add_child(name_lbl)

	# Influence cost if out-of-faction
	var is_faction: bool = _identity != null and record.faction == _identity.faction
	if record.influence_cost > 0 and not is_faction:
		var inf_lbl := Label.new()
		inf_lbl.text = "●".repeat(record.influence_cost)
		inf_lbl.add_theme_font_size_override("font_size", 9)
		inf_lbl.add_theme_color_override("font_color", Color(0.8, 0.5, 0.2))
		row.add_child(inf_lbl)

	# Remove button
	var rm_btn := Button.new()
	rm_btn.text = "−"
	rm_btn.custom_minimum_size = Vector2(24, 0)
	rm_btn.pressed.connect(func(): _change_count(record.id, -1))
	row.add_child(rm_btn)

	return row


# ── Card count changes ────────────────────────────────────────────────────────

func _change_count(card_id: String, delta: int) -> void:
	var current: int  = int(_deck_cards.get(card_id, 0))
	var max_own: int  = int(_pool_counts.get(card_id, 0))
	var record: CardRecord = CardRegistry.get_card(card_id)
	var copy_cap: int = record.deck_limit if record != null and record.deck_limit > 0 else FALLBACK_MAX_COPIES
	var new_count: int = clamp(current + delta, 0, min(max_own, copy_cap))

	if new_count == 0:
		_deck_cards.erase(card_id)
	else:
		_deck_cards[card_id] = new_count

	_apply_filters()
	_refresh_stats()


# ── Save / load current deck ──────────────────────────────────────────────────

func _on_save_pressed() -> void:
	var identity_id: String = _identity.id if _identity != null else _state.get_runner_identity_id()
	_state.save_deck(identity_id, _deck_cards)
	deck_saved.emit(identity_id, _deck_cards)
	queue_free()


# ── Named build save / load / delete ─────────────────────────────────────────

func _rebuild_saved_decks_panel() -> void:
	if _saved_decks_container == null or _state == null:
		return
	for child in _saved_decks_container.get_children():
		child.queue_free()

	var decks: Array = _state.get_saved_decks()
	if decks.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No saved builds yet."
		empty_lbl.add_theme_font_size_override("font_size", 10)
		empty_lbl.add_theme_color_override("font_color", Color(0.35, 0.38, 0.38))
		_saved_decks_container.add_child(empty_lbl)
		return

	for deck_data in decks:
		_saved_decks_container.add_child(_make_saved_deck_entry(deck_data as Dictionary))


func _make_saved_deck_entry(deck_data: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var name_lbl := Label.new()
	name_lbl.text = deck_data.get("name", "Unnamed")
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 10)
	name_lbl.add_theme_color_override("font_color", Color(0.78, 0.88, 0.80))
	name_lbl.clip_text = true
	row.add_child(name_lbl)

	# Total card count
	var saved_cards: Dictionary = deck_data.get("cards", {}) as Dictionary
	var card_total := 0
	for c in saved_cards.values():
		card_total += int(c)
	var count_lbl := Label.new()
	count_lbl.text = "%d" % card_total
	count_lbl.add_theme_font_size_override("font_size", 10)
	count_lbl.add_theme_color_override("font_color", Color(0.45, 0.5, 0.45))
	row.add_child(count_lbl)

	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.add_theme_font_size_override("font_size", 10)
	load_btn.pressed.connect(func(): _load_named_deck(deck_data))
	row.add_child(load_btn)

	var del_btn := Button.new()
	del_btn.text = "✕"
	del_btn.add_theme_font_size_override("font_size", 10)
	del_btn.add_theme_color_override("font_color", COLOR_WARN)
	del_btn.pressed.connect(func():
		_state.delete_named_deck(deck_data.get("name", ""))
		_rebuild_saved_decks_panel()
	)
	row.add_child(del_btn)

	return row


func _load_named_deck(deck_data: Dictionary) -> void:
	# Restore identity
	var identity_id: String = deck_data.get("identity", "")
	if identity_id != "":
		var id_record: CardRecord = CardRegistry.get_card(identity_id)
		if id_record != null:
			_identity = id_record

	# Restore cards, clamping to current pool and each card's deck limit
	var saved_cards: Dictionary = deck_data.get("cards", {}) as Dictionary
	_deck_cards = {}
	for card_id in saved_cards:
		var pool_count: int = int(_pool_counts.get(card_id, 0))
		if pool_count <= 0:
			continue   # card not unlocked in this save
		var record: CardRecord = CardRegistry.get_card(card_id)
		var copy_cap: int = record.deck_limit if record != null and record.deck_limit > 0 else FALLBACK_MAX_COPIES
		var final_count: int = mini(int(saved_cards[card_id]), mini(pool_count, copy_cap))
		if final_count > 0:
			_deck_cards[card_id] = final_count

	_apply_filters()
	_refresh_stats()


func _start_save_build_dialog() -> void:
	var dlg := _Dialog.new()
	dlg.submitted.connect(_on_save_build_dialog_closed, CONNECT_ONE_SHOT)
	_open_save_build_dialog(dlg)


func _open_save_build_dialog(dlg: _Dialog) -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.6)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(320, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.12)
	style.border_color = COLOR_BORDER
	for side in [0, 1, 2, 3]:
		style.set("border_width_%s" % ["top","right","bottom","left"][side], 1)
	style.corner_radius_top_left     = 6
	style.corner_radius_top_right    = 6
	style.corner_radius_bottom_left  = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left   = 18
	style.content_margin_right  = 18
	style.content_margin_top    = 16
	style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	backdrop.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = "Save Current Build"
	title_lbl.add_theme_font_size_override("font_size", 13)
	title_lbl.add_theme_color_override("font_color", COLOR_ACCENT)
	vbox.add_child(title_lbl)

	var name_field := LineEdit.new()
	name_field.text = _identity.title if _identity != null else "My Build"
	name_field.placeholder_text = "Build name..."
	name_field.add_theme_font_size_override("font_size", 12)
	vbox.add_child(name_field)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_row.add_child(cancel_btn)

	var confirm_btn := Button.new()
	confirm_btn.text = "Save"
	confirm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_btn.add_theme_color_override("font_color", COLOR_ACCENT)
	btn_row.add_child(confirm_btn)

	# Emit signal directly — no lambda captures, no nested awaits.
	cancel_btn.pressed.connect(func():
		backdrop.queue_free()
		dlg.submitted.emit("")
	)
	confirm_btn.pressed.connect(func():
		var t: String = name_field.text.strip_edges()
		backdrop.queue_free()
		dlg.submitted.emit(t)
	)
	name_field.text_submitted.connect(func(t: String):
		backdrop.queue_free()
		dlg.submitted.emit(t.strip_edges())
	)

	name_field.call_deferred("grab_focus")
	name_field.call_deferred("select_all")


func _on_save_build_dialog_closed(name: String) -> void:
	if name.strip_edges().is_empty():
		return
	var identity_id: String = _identity.id if _identity != null else ""
	_state.save_named_deck(name.strip_edges(), identity_id, _deck_cards.duplicate())
	_rebuild_saved_decks_panel()


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_panel(min_width: int = 0, expand_v: bool = false) -> PanelContainer:
	var panel := PanelContainer.new()
	if min_width > 0:
		panel.custom_minimum_size = Vector2(min_width, 0)
	if expand_v:
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.border_color = COLOR_BORDER
	for side in [0, 1, 2, 3]:
		style.set("border_width_%s" % ["top","right","bottom","left"][side], 1)
	style.corner_radius_top_left     = 6
	style.corner_radius_top_right    = 6
	style.corner_radius_bottom_left  = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left   = 14
	style.content_margin_right  = 14
	style.content_margin_top    = 12
	style.content_margin_bottom = 12
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
