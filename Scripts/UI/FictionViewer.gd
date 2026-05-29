class_name FictionViewer
extends CanvasLayer

# ── FictionViewer ─────────────────────────────────────────────────────────────
# Full-screen fiction reader with typewriter effect and cyberpunk aesthetic.
# Call show_fiction(text, on_complete_callable) to display a piece of fiction.
# The callable is invoked when the player dismisses the viewer.

signal dismissed

const CHAR_DELAY_NORMAL := 0.018   # seconds per character while typing
const CHAR_DELAY_FAST   := 0.004   # when player holds skip
const SCAN_LINE_ALPHA   := 0.04    # subtle CRT scanline overlay opacity

var _full_text: String = ""
var _displayed: int    = 0
var _typing:    bool   = false
var _on_complete: Callable

var _bg:         ColorRect
var _scanlines:  Control
var _text_label: RichTextLabel
var _prompt:     Label
var _tween:      Tween = null
var _char_timer: float = 0.0


# ── Public API ────────────────────────────────────────────────────────────────

func show_fiction(text: String, on_complete: Callable) -> void:
	_full_text   = text
	_displayed   = 0
	_typing      = true
	_on_complete = on_complete
	_text_label.text = ""
	_prompt.visible  = false
	_prompt.text     = "[ PRESS ENTER OR SPACE TO CONTINUE ]"
	visible          = true
	set_process(true)


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer   = 50
	visible = false
	_build_ui()
	set_process(false)


func _process(delta: float) -> void:
	if not _typing:
		return

	var speed := CHAR_DELAY_FAST if Input.is_action_pressed("ui_accept") else CHAR_DELAY_NORMAL
	_char_timer += delta

	while _char_timer >= speed and _displayed < _full_text.length():
		_char_timer -= speed
		_displayed  += 1
		_text_label.text = _full_text.substr(0, _displayed)
		_update_scroll()

	if _displayed >= _full_text.length():
		_finish_typing()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_select"):
		if _typing:
			# Skip to end
			_displayed  = _full_text.length()
			_text_label.text = _full_text
			_finish_typing()
		else:
			_dismiss()
		get_viewport().set_input_as_handled()


# ── Internals ─────────────────────────────────────────────────────────────────

func _finish_typing() -> void:
	_typing = false
	set_process(false)
	_text_label.text = _full_text
	# Blink the prompt in
	_prompt.visible  = true
	_prompt.modulate.a = 0.0
	var tween := create_tween()
	tween.set_loops()
	tween.tween_property(_prompt, "modulate:a", 1.0, 0.5)
	tween.tween_property(_prompt, "modulate:a", 0.3, 0.5)


func _dismiss() -> void:
	visible = false
	if _on_complete.is_valid():
		_on_complete.call()
	dismissed.emit()


# ── UI Construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Full-screen dark background
	_bg = ColorRect.new()
	_bg.color = Color(0.04, 0.05, 0.07, 0.97)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)

	# Subtle vignette
	var vignette := _make_vignette()
	add_child(vignette)

	# Scrolling text container
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left   = 160
	scroll.offset_right  = -160
	scroll.offset_top    = 80
	scroll.offset_bottom = -80
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# Make the container expand vertically inside its parent
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)

	_text_label = RichTextLabel.new()
	_text_label.bbcode_enabled   = true
	_text_label.fit_content      = true
	_text_label.scroll_active    = false
	_text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER 
		# Typewriter-green monospace feel
	_text_label.add_theme_color_override("default_color",       Color(0.72, 0.92, 0.72))
	_text_label.add_theme_color_override("font_shadow_color",   Color(0.2, 0.6, 0.2, 0.4))
	_text_label.add_theme_constant_override("shadow_offset_x",  1)
	_text_label.add_theme_constant_override("shadow_offset_y",  1)
	_text_label.add_theme_font_size_override("normal_font_size", 15)
	_text_label.add_theme_constant_override("line_separation",   6)
	scroll.add_child(_text_label)

	# Continue prompt at the bottom
	_prompt = Label.new()
	_prompt.text = "[ PRESS ENTER OR SPACE TO CONTINUE ]"
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_prompt.offset_top    = -48
	_prompt.offset_bottom = -16
	_prompt.add_theme_font_size_override("font_size", 11)
	_prompt.add_theme_color_override("font_color", Color(0.4, 0.65, 0.4))
	_prompt.visible = false
	add_child(_prompt)

	# Scanline overlay
	_scanlines = _make_scanlines()
	add_child(_scanlines)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scanlines.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _update_scroll() -> void:
	var scroll = _text_label.get_parent() as ScrollContainer
	if scroll == null:
		return
	await get_tree().process_frame
	# Just accessing the v_scroll bar's max_value forces a refresh
	var _dummy = scroll.get_v_scroll_bar().max_value

func _make_vignette() -> Control:
	var vignette := ColorRect.new()
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Use a shader for the radial vignette
	var shader_code := """
shader_type canvas_item;
void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float vignette = 1.0 - dot(uv * 0.6, uv * 0.6);
	vignette = clamp(vignette, 0.0, 1.0);
	COLOR = vec4(0.0, 0.0, 0.0, 1.0 - vignette * 0.85);
}
"""
	var shader := Shader.new()
	shader.code = shader_code
	var mat := ShaderMaterial.new()
	mat.shader = shader
	vignette.material = mat
	return vignette


func _make_scanlines() -> Control:
	var scanlines := ColorRect.new()
	scanlines.set_anchors_preset(Control.PRESET_FULL_RECT)
	var shader_code := """
shader_type canvas_item;
void fragment() {
	float line = mod(FRAGCOORD.y, 4.0);
	float alpha = line < 2.0 ? 0.0 : 0.05;
	COLOR = vec4(0.0, 0.0, 0.0, alpha);
}
"""
	var shader := Shader.new()
	shader.code = shader_code
	var mat := ShaderMaterial.new()
	mat.shader = shader
	scanlines.material = mat
	return scanlines
