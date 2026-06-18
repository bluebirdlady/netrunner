class_name ArcSelectMenu
extends CanvasLayer

# ── ArcSelectMenu ──────────────────────────────────────────────────────────────
# Launch screen shown before any campaign loads.
# Lets the player choose between the Runner campaign and the Corp campaign.

signal runner_campaign_chosen
signal corp_campaign_chosen

const COLOR_BG       := Color(0.04, 0.05, 0.07)
const COLOR_RUNNER   := Color(0.25, 0.85, 0.45)
const COLOR_CORP     := Color(0.25, 0.65, 0.95)
const COLOR_MUTED    := Color(0.3, 0.35, 0.32)
const COLOR_BORDER   := Color(0.12, 0.22, 0.14)


func _ready() -> void:
	layer = 10
	_build_ui()


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	root.add_child(_make_scanlines())

	var center := VBoxContainer.new()
	center.set_anchors_preset(Control.PRESET_CENTER)
	center.custom_minimum_size = Vector2(480, 0)
	center.alignment           = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 24)
	root.add_child(center)

	# Title
	var title := Label.new()
	title.text = "NETRUNNER"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", Color(0.7, 0.9, 0.75))
	center.add_child(title)

	var sub := Label.new()
	sub.text = "// SELECT CAMPAIGN //"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", COLOR_MUTED)
	center.add_child(sub)

	center.add_child(HSeparator.new())

	# Runner Campaign button
	center.add_child(_make_arc_button(
		"// RUNNER CAMPAIGN",
		"CONVENTION BREAKER  —  System Gateway",
		"Hack corporations. Score agendas. Make them pay.",
		COLOR_RUNNER,
		func(): runner_campaign_chosen.emit()
	))

	# Corp Campaign button
	center.add_child(_make_arc_button(
		"// CORP CAMPAIGN",
		"PROFIT OVER PRINCIPLE  —  The Syndicate",
		"Build servers. Protect assets. Advance the agenda.",
		COLOR_CORP,
		func(): corp_campaign_chosen.emit()
	))


func _make_arc_button(header: String, title: String, desc: String,
		accent: Color, cb: Callable) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color           = Color(0.07, 0.09, 0.11)
	style.border_color       = accent.darkened(0.3)
	style.border_width_left  = 3
	style.set_corner_radius_all(4)
	style.content_margin_left   = 20
	style.content_margin_right  = 20
	style.content_margin_top    = 14
	style.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var header_lbl := Label.new()
	header_lbl.text = header
	header_lbl.add_theme_font_size_override("font_size", 11)
	header_lbl.add_theme_color_override("font_color", accent.darkened(0.1))
	vbox.add_child(header_lbl)

	var title_lbl := Label.new()
	title_lbl.text = title
	title_lbl.add_theme_font_size_override("font_size", 20)
	title_lbl.add_theme_color_override("font_color", accent)
	vbox.add_child(title_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = desc
	desc_lbl.add_theme_font_size_override("font_size", 10)
	desc_lbl.add_theme_color_override("font_color", COLOR_MUTED)
	vbox.add_child(desc_lbl)

	vbox.add_child(HSeparator.new())

	var btn := Button.new()
	btn.text = "▶  BEGIN"
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_color_override("font_color", accent)
	btn.add_theme_color_override("font_hover_color", accent.lightened(0.2))
	btn.pressed.connect(cb)
	vbox.add_child(btn)

	return panel


func _make_scanlines() -> Control:
	var scanlines := ColorRect.new()
	scanlines.set_anchors_preset(Control.PRESET_FULL_RECT)
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
void fragment() {
	float line = mod(FRAGCOORD.y, 4.0);
	float alpha = line < 2.0 ? 0.0 : 0.04;
	COLOR = vec4(0.0, 0.0, 0.0, alpha);
}"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	scanlines.material = mat
	return scanlines
