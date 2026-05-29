class_name IceToken
extends Control

signal clicked(ice_card: InstalledCard)

var ice_card: InstalledCard = null
var _ui_built := false
var bg: Panel
var name_label: Label
var info_label: Label

func _ensure_ui() -> void:
	if _ui_built:
		return
	_ui_built = true
	
	custom_minimum_size = Vector2(120, 44)
	size = Vector2(120, 44)
	
	bg = Panel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.modulate = Color(0.1, 0.1, 0.15)
	add_child(bg)
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 2)
	add_child(vbox)
	
	name_label = Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	vbox.add_child(name_label)
	
	info_label = Label.new()
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.add_theme_font_size_override("font_size", 10)
	info_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(info_label)

func setup(card: InstalledCard) -> void:
	_ensure_ui()
	ice_card = card
	# Advancement tokens are always public information
	var adv: int = card.get_counter("advancement")
	var adv_str: String = "  ▲%d" % adv if adv > 0 else ""

	if card.is_rezzed and card.card_record:
		var record = card.card_record
		name_label.text = record.title

		# Find ice subtype — include runtime-granted extra subtypes (e.g. Chromatophores)
		var subtype = ""
		var all_ice_subtypes: Array = record.subtypes.duplicate()
		for es in card.extra_subtypes:
			if not all_ice_subtypes.has(es):
				all_ice_subtypes.append(es)
		for st in all_ice_subtypes:
			var st_lower = (st as String).to_lower().replace("_", " ")
			if st_lower in ["barrier", "code gate", "sentry"]:
				subtype = st_lower.capitalize()
				break

		var strength = record.strength if record.strength > 0 else "?"
		var rez_cost = record.cost
		info_label.text = "[%s]  ⚡%s  Rez: %d₵%s" % [subtype, strength, rez_cost, adv_str]
		bg.modulate = Color(0.2, 0.2, 0.25)
	else:
		name_label.text = "???"
		info_label.text = "ICE%s" % adv_str
		bg.modulate = Color(0.1, 0.1, 0.15)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if ice_card:
			clicked.emit(ice_card)
