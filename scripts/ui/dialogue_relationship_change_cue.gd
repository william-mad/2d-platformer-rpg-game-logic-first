class_name DialogueRelationshipChangeCue extends Control

const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")
const HEART_FRAME_SECONDS: float = 0.09
const HEART_FRAMES: Array[Texture2D] = [
	preload("res://images/sprites/assets/ui graphics/beating_heart_64px1.png"),
	preload("res://images/sprites/assets/ui graphics/beating_heart_64px2.png"),
	preload("res://images/sprites/assets/ui graphics/beating_heart_64px3.png"),
	preload("res://images/sprites/assets/ui graphics/beating_heart_64px4.png"),
	preload("res://images/sprites/assets/ui graphics/beating_heart_64px5.png"),
	preload("res://images/sprites/assets/ui graphics/beating_heart_64px6.png"),
]
const HEART_BASE_ALPHAS: Array[float] = [1.0, 0.72, 0.48]
const HEART_RISE_DISTANCES: Array[float] = [28.0, 46.0, 34.0]
const HEART_RISE_DURATIONS: Array[float] = [1.25, 1.55, 1.0]
const HEART_FADE_DELAYS: Array[float] = [0.3, 0.12, 0.02]

@export_range(0.1, 5.0, 0.05, "suffix:s") var rise_duration: float = 1.25
@export_range(0.0, 64.0, 1.0, "suffix:px") var rise_distance: float = 28.0
@export_range(0.0, 2.0, 0.05, "suffix:s") var fade_delay: float = 0.3

@onready var cue_group: Control = %CueGroup
@onready var heart_icon: TextureRect = %HeartIcon
@onready var heart_echo_2: TextureRect = %HeartEcho2
@onready var heart_echo_3: TextureRect = %HeartEcho3
@onready var delta_label: Label = %DeltaLabel

var _relationships: Node
var _cue_tween: Tween
var _heart_icons: Array[TextureRect] = []
var _heart_start_positions: Array[Vector2] = []
var _delta_label_start_position: Vector2
var _heart_elapsed: float = 0.0
var _heart_frame_index: int = 0


func _ready() -> void:
	_heart_icons = [heart_icon, heart_echo_2, heart_echo_3]
	for icon in _heart_icons:
		_heart_start_positions.append(icon.position)
	_delta_label_start_position = delta_label.position
	_set_heart_frame(0)
	cue_group.visible = false
	set_process(false)
	_bind_relationships()


func _exit_tree() -> void:
	if _cue_tween != null and _cue_tween.is_valid():
		_cue_tween.kill()
	var callback := Callable(self, "_on_relationship_changed")
	if (
		_relationships != null
		and is_instance_valid(_relationships)
		and _relationships.has_signal(&"relationship_changed")
		and _relationships.is_connected(&"relationship_changed", callback)
	):
		_relationships.disconnect(&"relationship_changed", callback)


func _process(delta: float) -> void:
	_heart_elapsed += delta
	while _heart_elapsed >= HEART_FRAME_SECONDS:
		_heart_elapsed -= HEART_FRAME_SECONDS
		_heart_frame_index = (_heart_frame_index + 1) % HEART_FRAMES.size()
		_set_heart_frame(_heart_frame_index)


func is_showing() -> bool:
	return cue_group != null and cue_group.visible


func _bind_relationships() -> void:
	_relationships = get_node_or_null("/root/Relationships")
	if _relationships == null or not _relationships.has_signal(&"relationship_changed"):
		return
	var callback := Callable(self, "_on_relationship_changed")
	if not _relationships.is_connected(&"relationship_changed", callback):
		_relationships.connect(&"relationship_changed", callback)


func _on_relationship_changed(
	relationship_owner: Node,
	other: Node,
	changed_values: Dictionary,
	relationship: Dictionary
) -> void:
	var love_delta := _get_love_delta(changed_values)
	if is_zero_approx(love_delta):
		return
	if not _is_npc_to_player_relationship(relationship_owner, other, relationship):
		return
	var context = relationship.get("last_context", {})
	if not (context is Dictionary):
		return
	if String(context.get("source", "")) not in [
		"player_talk_dialogue",
		"player_talk_dialogue_choice",
	]:
		return
	show_love_change(love_delta)


func show_love_change(actual_delta: float) -> void:
	if is_zero_approx(actual_delta):
		return
	if _cue_tween != null and _cue_tween.is_valid():
		_cue_tween.kill()
	delta_label.text = _format_signed_delta(actual_delta)
	cue_group.modulate = Color.WHITE
	cue_group.visible = true
	var heart_count := clampi(int(ceil(absf(actual_delta))), 1, _heart_icons.size())
	for icon_index in _heart_icons.size():
		var icon := _heart_icons[icon_index]
		icon.position = _heart_start_positions[icon_index]
		icon.modulate = Color(1.0, 1.0, 1.0, HEART_BASE_ALPHAS[icon_index])
		icon.visible = icon_index < heart_count
	delta_label.position = _delta_label_start_position
	delta_label.modulate = Color.WHITE
	_heart_elapsed = 0.0
	_heart_frame_index = 0
	_set_heart_frame(0)
	set_process(true)
	var dialogue_ui := get_parent() as CanvasLayer
	if dialogue_ui != null:
		dialogue_ui.visible = true

	_cue_tween = create_tween().set_parallel(true)
	for icon_index in heart_count:
		var icon := _heart_icons[icon_index]
		var icon_duration := (
			rise_duration if icon_index == 0 else HEART_RISE_DURATIONS[icon_index]
		)
		var icon_distance := (
			rise_distance if icon_index == 0 else HEART_RISE_DISTANCES[icon_index]
		)
		var icon_fade_delay := (
			fade_delay if icon_index == 0 else HEART_FADE_DELAYS[icon_index]
		)
		_cue_tween.tween_property(
			icon,
			"position:y",
			_heart_start_positions[icon_index].y - icon_distance,
			icon_duration
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_cue_tween.tween_property(
			icon,
			"modulate:a",
			0.0,
			maxf(icon_duration - icon_fade_delay, 0.01)
		).set_delay(icon_fade_delay).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_cue_tween.tween_property(
		delta_label,
		"position:y",
		_delta_label_start_position.y - rise_distance,
		rise_duration
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_cue_tween.tween_property(
		delta_label,
		"modulate:a",
		0.0,
		maxf(rise_duration - fade_delay, 0.01)
	).set_delay(fade_delay).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_cue_tween.chain().tween_callback(_finish_cue)


func _finish_cue() -> void:
	cue_group.visible = false
	cue_group.modulate.a = 0.0
	set_process(false)
	_cue_tween = null
	var dialogue_ui := get_parent()
	if (
		dialogue_ui != null
		and StringName(dialogue_ui.get("active_session_id")) == &""
	):
		dialogue_ui.visible = false


func _get_love_delta(changed_values: Dictionary) -> float:
	for metric_key in changed_values:
		if StringName(String(metric_key)) == &"love":
			return float(changed_values[metric_key])
	return 0.0


func _is_npc_to_player_relationship(
	relationship_owner: Node,
	other: Node,
	relationship: Dictionary
) -> bool:
	var owner_id := (
		NpcIdentity.get_stable_actor_id(relationship_owner)
		if relationship_owner != null and is_instance_valid(relationship_owner)
		else String(relationship.get("owner_id", "")).strip_edges()
	)
	var other_id := (
		NpcIdentity.get_stable_actor_id(other)
		if other != null and is_instance_valid(other)
		else String(relationship.get("other_id", "")).strip_edges()
	)
	return not owner_id.is_empty() and not NpcIdentity.is_player_id(owner_id) and NpcIdentity.is_player_id(other_id)


func _format_signed_delta(delta: float) -> String:
	var magnitude := absf(delta)
	var amount_text := (
		str(int(round(magnitude)))
		if is_equal_approx(magnitude, round(magnitude))
		else "%.1f" % magnitude
	)
	return "%s%s" % ["+" if delta > 0.0 else "-", amount_text]


func _set_heart_frame(frame_index: int) -> void:
	if _heart_icons.is_empty() or HEART_FRAMES.is_empty():
		return
	var texture := HEART_FRAMES[clampi(frame_index, 0, HEART_FRAMES.size() - 1)]
	for icon in _heart_icons:
		icon.texture = texture
