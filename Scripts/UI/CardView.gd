class_name CardView
extends Control

# ── CardView ──────────────────────────────────────────────────────────────────
# Displays a full-card image with rounded corners.
# On hover, scales up in-place from the card's centre. z_index raises it above
# siblings. No reparenting — the card stays in its layout position throughout.

signal clicked(card_record: CardRecord)

const BASE_W       := 130.0
const BASE_H       := 182.0
const SCALE_FACTOR := 1.15
const HOVER_SCALE  := 2.2

var CARD_W: float
var CARD_H: float

var _art_rect:         TextureRect
var _unrezzed_overlay: TextureRect
var _card_record:      CardRecord = null
var _is_rezzed:        bool       = true
var _hover_tween:        Tween      = null
var _is_hovering:        bool       = false
var _rest_position:      Vector2    = Vector2.ZERO
var _original_screen_pos: Vector2   = Vector2.ZERO

# Shared statics
static var _rounded_corner_shader: Shader         = null
static var _rounded_material:      ShaderMaterial = null
static var _art_manager:           Node           = null
static var _card_back_texture:     Texture2D      = preload("res://Assets/Art/corp_card_back.jpg")


# ── Public API ────────────────────────────────────────────────────────────────

func setup(record: CardRecord, rezzed: bool = true) -> void:
	if _art_rect == null:
		_build_ui()   # _ready() may not have fired yet if card isn't in the tree
	_card_record = record
	_is_rezzed   = rezzed
	_populate()


func set_rezzed(rezzed: bool) -> void:
	_is_rezzed = rezzed
	if _card_record != null:
		_populate()


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _init() -> void:
	# Set size immediately so layout works even before _ready() fires
	# (cards are often constructed and setup() called before being added to the tree)
	CARD_W = BASE_W * SCALE_FACTOR
	CARD_H = BASE_H * SCALE_FACTOR
	custom_minimum_size = Vector2(CARD_W, CARD_H)
	pivot_offset        = Vector2(CARD_W / 2.0, CARD_H / 2.0)


func _ready() -> void:
	# CARD_W/H already set in _init; build UI and connect signals here
	_build_ui()
	mouse_filter = MOUSE_FILTER_STOP
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

	var art_manager = _get_art_manager()
	if art_manager and art_manager.has_signal("texture_ready"):
		art_manager.texture_ready.connect(_on_texture_ready)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if _card_record:
			clicked.emit(_card_record)


# ── Hover ─────────────────────────────────────────────────────────────────────

func _on_mouse_entered() -> void:
	if _is_hovering:
		return
	_is_hovering         = true
	_rest_position       = position
	_original_screen_pos = get_screen_position()

	z_index = 100

	var half_w := (CARD_W * HOVER_SCALE) / 2.0
	var half_h := (CARD_H * HOVER_SCALE) / 2.0
	var centre  := _original_screen_pos + Vector2(CARD_W / 2.0, CARD_H / 2.0)
	var vp      := get_viewport().get_visible_rect()
	var nudge   := Vector2.ZERO
	if centre.x - half_w < vp.position.x:
		nudge.x = vp.position.x - (centre.x - half_w)
	elif centre.x + half_w > vp.position.x + vp.size.x:
		nudge.x = (vp.position.x + vp.size.x) - (centre.x + half_w)
	if centre.y - half_h < vp.position.y:
		nudge.y = vp.position.y - (centre.y - half_h)
	elif centre.y + half_h > vp.position.y + vp.size.y:
		nudge.y = (vp.position.y + vp.size.y) - (centre.y + half_h)

	if _hover_tween:
		_hover_tween.kill()
	_hover_tween = create_tween()
	_hover_tween.set_ease(Tween.EASE_OUT)
	_hover_tween.set_trans(Tween.TRANS_BACK)
	_hover_tween.tween_property(self, "scale", Vector2(HOVER_SCALE, HOVER_SCALE), 0.14)
	if nudge != Vector2.ZERO:
		_hover_tween.parallel().tween_property(self, "position", position + nudge, 0.14)


func _on_mouse_exited() -> void:
	if not _is_hovering:
		return
	_is_hovering = false

	if _hover_tween:
		_hover_tween.kill()
	_hover_tween = create_tween()
	_hover_tween.set_ease(Tween.EASE_OUT)
	_hover_tween.set_trans(Tween.TRANS_BACK)
	_hover_tween.tween_property(self, "scale", Vector2.ONE, 0.10)
	_hover_tween.parallel().tween_property(self, "position", _rest_position, 0.10)
	await _hover_tween.finished
	if is_instance_valid(self):
		z_index  = 0
		position = _rest_position


# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	_create_rounded_material()

	_art_rect = TextureRect.new()
	_art_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_art_rect.expand       = true
	_art_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_art_rect.material     = _rounded_material
	add_child(_art_rect)

	_unrezzed_overlay = TextureRect.new()
	_unrezzed_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_unrezzed_overlay.expand       = true
	_unrezzed_overlay.stretch_mode = TextureRect.STRETCH_SCALE
	_unrezzed_overlay.texture      = _card_back_texture
	_unrezzed_overlay.visible      = false
	_unrezzed_overlay.material     = _rounded_material
	add_child(_unrezzed_overlay)


# ── Rounded corner shader ─────────────────────────────────────────────────────

static func _create_rounded_material() -> void:
	if _rounded_material != null:
		return
	var shader_code := """
shader_type canvas_item;
uniform float corner_radius : hint_range(0, 0.2) = 0.06;
void fragment() {
	vec2 size = UV * 2.0 - 1.0;
	float rx = abs(size.x);
	float ry = abs(size.y);
	float r = corner_radius * 2.0;
	if (rx > 1.0 - r && ry > 1.0 - r) {
		float corner_dist = length(vec2(rx - (1.0 - r), ry - (1.0 - r)));
		if (corner_dist > r) {
			discard;
		}
	}
}
"""
	_rounded_corner_shader = Shader.new()
	_rounded_corner_shader.code = shader_code
	_rounded_material = ShaderMaterial.new()
	_rounded_material.shader = _rounded_corner_shader
	_rounded_material.set_shader_parameter("corner_radius", 0.06)


# ── Population ────────────────────────────────────────────────────────────────

static func _get_art_manager() -> Node:
	if _art_manager == null:
		var root = Engine.get_main_loop().root
		if root:
			_art_manager = root.get_node_or_null("/root/CardArt")
	return _art_manager


func _populate() -> void:
	if _card_record != null:
		var art_manager = _get_art_manager()
		if art_manager:
			_art_rect.texture = art_manager.get_texture(_card_record.printing_id)
		else:
			_art_rect.texture = null
	else:
		_art_rect.texture = null
	_unrezzed_overlay.visible = not _is_rezzed


func _on_texture_ready(printing_id: String, texture: Texture2D) -> void:
	if _card_record != null and printing_id == _card_record.printing_id:
		_art_rect.texture = texture
