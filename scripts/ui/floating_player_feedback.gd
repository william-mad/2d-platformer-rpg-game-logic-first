class_name FloatingPlayerFeedback extends RefCounted

## Shared world-space feedback attached to a Player or another Node2D.
## Basic use: FloatingPlayerFeedback.show(player, "Door locked.")

const NODE_NAME: StringName = &"FloatingPlayerFeedback"
const DEFAULT_OFFSET := Vector2(0.0, -142.0)
const DEFAULT_SIZE := Vector2(160.0, 28.0)
const DEFAULT_COLOR := Color(1.0, 0.82, 0.42, 1.0)
const DEFAULT_SECONDS: float = 0.9
const DEFAULT_HOLD_SECONDS: float = 0.15
const DEFAULT_RISE: float = 32.0


static func show(
	actor: Node2D,
	message: String,
	offset: Vector2 = DEFAULT_OFFSET,
	size: Vector2 = DEFAULT_SIZE,
	color: Color = DEFAULT_COLOR,
	seconds: float = DEFAULT_SECONDS,
	hold_seconds: float = DEFAULT_HOLD_SECONDS,
	rise: float = DEFAULT_RISE
) -> Label:
	if actor == null or not is_instance_valid(actor) or message.strip_edges().is_empty():
		return null
	clear(actor)

	var label := Label.new()
	label.name = NODE_NAME
	label.text = message
	label.z_index = 100
	label.size = size
	label.position = offset - size * 0.5
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	label.add_theme_constant_override("outline_size", 2)
	label.add_theme_font_size_override("font_size", 16)
	actor.add_child(label)

	var duration := maxf(seconds, 0.1)
	var hold := clampf(hold_seconds, 0.0, duration - 0.05)
	var tween := label.create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(
		label, "position", label.position + Vector2(0.0, -absf(rise)), duration
	)
	tween.parallel().tween_property(label, "modulate:a", 0.0, duration - hold).set_delay(hold)
	tween.tween_callback(label.queue_free)
	return label


static func clear(actor: Node2D) -> void:
	if actor == null or not is_instance_valid(actor):
		return
	var existing := actor.get_node_or_null(NodePath(String(NODE_NAME)))
	if existing != null:
		existing.free()
