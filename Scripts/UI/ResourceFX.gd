class_name ResourceFX
extends Control

# ── ResourceFX ────────────────────────────────────────────────────────────────
# Plays a card-flash + flying-delta animation whenever a card ability changes a
# resource (credits, hand, clicks, hand_size).
#
# Added as the last child of GameUI so it renders above all other UI elements.
# Listens to ctx.ability_resolved; creates and destroys its own child nodes
# for each animation — no pooling needed for a turn-based game.

const COLOR_GAIN   := Color(0.3,  1.0,  0.4,  1.0)  # green
const COLOR_LOSS   := Color(1.0,  0.3,  0.3,  1.0)  # red
const CARD_SCALE   := Vector2(1.5, 1.5)               # popup card relative to CardView native size
const DELTA_SIZE   := 28                               # font size for +X / -X label

# Resource → icon path for the small inline symbol shown when no card is known
const RESOURCE_ICON := {
	"credits":   "res://Assets/Art/Game Symbols/Exported/NSG_CREDIT.png",
	"hand":      "res://Assets/Art/Game Symbols/Exported/NSG_CREDIT.png",  # no grip icon — use credit as placeholder
	"clicks":    "res://Assets/Art/Game Symbols/Exported/NSG_CLICK.png",
	"hand_size": "res://Assets/Art/Game Symbols/Exported/NSG_CREDIT.png",
}

var _resource_label:         Control = null
var _corp_hand_container:    Control = null
var _runner_hand_container:  Control = null


func setup(ctx: GameContext,
		resource_label: Control,
		corp_hand_container: Control,
		runner_hand_container: Control) -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_resource_label        = resource_label
	_corp_hand_container   = corp_hand_container
	_runner_hand_container = runner_hand_container
	ctx.ability_resolved.connect(_on_ability_resolved)


# ── Signal handler ────────────────────────────────────────────────────────────

func _on_ability_resolved(source_card_id: String, player: String,
		resource: String, delta: int) -> void:
	if source_card_id.is_empty():
		_show_delta_fly(delta, resource, player, _viewport_center())
		return
	_show_card_popup(source_card_id, player, resource, delta)


# ── Full popup: card thumbnail + flying delta ─────────────────────────────────

func _show_card_popup(card_id: String, player: String,
		resource: String, delta: int) -> void:
	var record: CardRecord = _lookup_record(card_id)

	var center  := _viewport_center()
	var card_w  := CardView.BASE_W * CardView.SCALE_FACTOR * CARD_SCALE.x
	var card_h  := CardView.BASE_H * CardView.SCALE_FACTOR * CARD_SCALE.y
	var card_pos := center - Vector2(card_w * 0.5, card_h * 0.5)

	# Card thumbnail
	var card_view := CardView.new()
	card_view.mouse_filter = MOUSE_FILTER_IGNORE
	card_view.scale        = Vector2.ZERO
	card_view.pivot_offset = Vector2(CardView.BASE_W * CardView.SCALE_FACTOR * 0.5,
	                                  CardView.BASE_H * CardView.SCALE_FACTOR * 0.5)
	card_view.position = card_pos
	add_child(card_view)
	if record != null:
		card_view.setup(record, true)

	# Delta label — starts invisible, parented to this overlay
	var delta_label := _make_delta_label(delta)
	var label_start := center + Vector2(-delta_label.size.x * 0.5, card_h * 0.3)
	delta_label.position = label_start
	add_child(delta_label)

	var target := _target_pos(resource, player)
	var flash_col := COLOR_GAIN if delta >= 0 else COLOR_LOSS

	# Animation sequence
	var tw := create_tween()
	tw.set_parallel(false)

	# 1. Pop card in
	tw.tween_property(card_view, "scale", CARD_SCALE, 0.14)\
	  .set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

	# 2. Flash border (two quick pulses)
	tw.tween_callback(func() -> void:
		var ft := create_tween().set_loops(2)
		ft.tween_property(card_view, "modulate", flash_col, 0.09)
		ft.tween_property(card_view, "modulate", Color.WHITE, 0.09)
	)
	tw.tween_interval(0.12)

	# 3. Reveal delta label
	tw.tween_property(delta_label, "modulate:a", 1.0, 0.08)

	# 4. Fly delta to resource area; fade card out in parallel
	tw.tween_interval(0.05)
	tw.tween_property(delta_label, "position", target, 0.38)\
	  .set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.parallel().tween_property(card_view, "modulate:a", 0.0, 0.28)

	# 5. Fade out delta at destination
	tw.tween_property(delta_label, "modulate:a", 0.0, 0.14)

	# 6. Cleanup
	tw.tween_callback(func() -> void:
		if is_instance_valid(card_view):  card_view.queue_free()
		if is_instance_valid(delta_label): delta_label.queue_free()
	)


# ── Fallback: flying number only (no source card known) ──────────────────────

func _show_delta_fly(delta: int, resource: String, player: String,
		start: Vector2) -> void:
	var delta_label := _make_delta_label(delta)
	delta_label.position = start - Vector2(delta_label.size.x * 0.5, delta_label.size.y * 0.5)
	add_child(delta_label)

	var target := _target_pos(resource, player)
	var tw := create_tween()
	tw.tween_property(delta_label, "modulate:a", 1.0, 0.10)
	tw.tween_property(delta_label, "position", target, 0.38)\
	  .set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(delta_label, "modulate:a", 0.0, 0.14)
	tw.tween_callback(delta_label.queue_free)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_delta_label(delta: int) -> Label:
	var lbl := Label.new()
	lbl.text = ("+%d" % delta) if delta >= 0 else ("%d" % delta)
	lbl.add_theme_color_override("font_color", COLOR_GAIN if delta >= 0 else COLOR_LOSS)
	lbl.add_theme_font_size_override("font_size", DELTA_SIZE)
	lbl.mouse_filter = MOUSE_FILTER_IGNORE
	lbl.modulate.a   = 0.0
	# Force layout so .size is valid before we use it for positioning
	lbl.size = lbl.get_minimum_size()
	return lbl


func _target_pos(resource: String, player: String) -> Vector2:
	# Returns an approximate screen position for the destination of the flying number.
	if resource == "hand":
		var container := _corp_hand_container if player == "corp" else _runner_hand_container
		if container != null:
			var r := container.get_global_rect()
			return Vector2(r.position.x + r.size.x * 0.3, r.position.y + r.size.y * 0.5)
	if _resource_label != null:
		return _resource_label.get_global_rect().get_center()
	return _viewport_center()


func _viewport_center() -> Vector2:
	var vr := get_viewport().get_visible_rect() if get_viewport() != null else Rect2(0, 0, 800, 600)
	return vr.get_center()


func _lookup_record(card_id: String) -> CardRecord:
	var reg: Node = Engine.get_main_loop().root.get_node_or_null("/root/CardRegistry")
	if reg == null or not reg.has_method("get_card"):
		return null
	return reg.get_card(card_id) as CardRecord
