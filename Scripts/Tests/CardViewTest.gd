extends Control

# ── CardViewTest ──────────────────────────────────────────────────────────────
# Displays a grid of real cards from the CardRegistry to verify the renderer.
# Shows one card of each type from System Gateway if available.
#
# Scene setup:
#   Control (this script)
#     VBoxContainer
#       HBoxContainer (buttons row)
#         Button (LoadButton) "Load Cards"
#         Button (RezzButton)  "Toggle Rezzed"
#       ScrollContainer
#         HFlowContainer (CardGrid)

@onready var load_button: Button          = $VBoxContainer/ButtonRow/LoadButton
@onready var rezz_button: Button          = $VBoxContainer/ButtonRow/RezzButton
@onready var card_grid:   HFlowContainer  = $VBoxContainer/ScrollContainer/CardGrid

var _card_views: Array = []
var _rezzed:     bool  = true

# System Gateway card ids to display — one of each type
const SHOWCASE_CARDS := [
	"hedge_fund",       # operation
	"palisade",         # ice: barrier
	"whitespace",       # ice: code gate
	"urtica_cipher",    # asset (trap)
	"nico_campaign",    # asset
	"offworld_office",  # agenda
	"spin_doctor",      # upgrade
	"cleaver",          # program: fracter
	"unity",            # program: decoder
	"carmen",           # program: killer
	"sure_gamble",      # event
	"daily_casts",      # resource
]


func _ready() -> void:
	load_button.pressed.connect(_on_load_pressed)
	rezz_button.pressed.connect(_on_rezz_pressed)

	if not CardRegistry.is_loaded:
		load_button.text = "Load Cards (registry not ready)"
		load_button.disabled = true
		CardRegistry.loaded.connect(func(_n): 
			load_button.disabled = false
			load_button.text = "Load Cards"
		)


func _on_load_pressed() -> void:
	# Clear existing cards
	for child in card_grid.get_children():
		child.queue_free()
	_card_views.clear()

	for card_id in SHOWCASE_CARDS:
		var record: CardRecord = CardRegistry.get_card(card_id)
		if record == null:
			# Show a placeholder label for missing cards
			var lbl := Label.new()
			lbl.text = "[%s\nnot found]" % card_id
			lbl.custom_minimum_size = Vector2(130, 182)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
			lbl.add_theme_font_size_override("font_size", 10)
			card_grid.add_child(lbl)
			continue

		var view := CardView.new()
		card_grid.add_child(view)
		view.setup(record, _rezzed)
		_card_views.append(view)

	# Also show a few cards by type for broader coverage
	_add_section("── Ice ──")
	for card in CardRegistry.get_ice().slice(0, 4):
		var view := CardView.new()
		card_grid.add_child(view)
		view.setup(card as CardRecord, _rezzed)
		_card_views.append(view)

	_add_section("── Agendas ──")
	for card in CardRegistry.get_agendas().slice(0, 4):
		var view := CardView.new()
		card_grid.add_child(view)
		view.setup(card as CardRecord, _rezzed)
		_card_views.append(view)


func _on_rezz_pressed() -> void:
	_rezzed = not _rezzed
	rezz_button.text = "Toggle Rezzed (now: %s)" % ("rezzed" if _rezzed else "unrezzed")
	for view in _card_views:
		(view as CardView).set_rezzed(_rezzed)


func _add_section(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(card_grid.size.x, 20)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	card_grid.add_child(lbl)
