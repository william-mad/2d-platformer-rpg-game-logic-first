class_name NpcLoveBar extends Control

const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")
const HEART_TEXTURE := preload(
	"res://images/sprites/assets/ui graphics/heart_16px.png"
)

@export_range(0.0, 10.0, 0.05, "suffix:s") var visible_duration: float = 1.8
@export_range(0.0, 5.0, 0.05, "suffix:s") var fade_duration: float = 0.45
@export_range(0.0, 16.0, 1.0, "suffix:px") var health_bar_gap: float = 2.0

@onready var heart_icon_slot: TextureRect = %HeartIconSlot
@onready var love_meter_frame: Control = %LoveMeterFrame
@onready var love_meter: ProgressBar = %LoveMeter

var _npc: Node2D
var _relationships: Node
var _visibility_tween: Tween


func _ready() -> void:
	_npc = get_parent() as Node2D
	heart_icon_slot.texture = HEART_TEXTURE
	love_meter.min_value = 0.0
	love_meter.max_value = 100.0
	_align_with_health_bar()
	visible = false
	modulate.a = 0.0
	_bind_relationships()

func _exit_tree() -> void:
	if _visibility_tween != null and _visibility_tween.is_valid():
		_visibility_tween.kill()
	var changed_callback := Callable(self, "_on_relationship_changed")
	if (
		_relationships != null
		and is_instance_valid(_relationships)
		and _relationships.has_signal(&"relationship_changed")
		and _relationships.is_connected(&"relationship_changed", changed_callback)
	):
		_relationships.disconnect(&"relationship_changed", changed_callback)


func _bind_relationships() -> void:
	_relationships = get_node_or_null("/root/Relationships")
	if _relationships == null or not _relationships.has_signal(&"relationship_changed"):
		return
	var changed_callback := Callable(self, "_on_relationship_changed")
	if not _relationships.is_connected(&"relationship_changed", changed_callback):
		_relationships.connect(&"relationship_changed", changed_callback)


func _on_relationship_changed(
	relationship_owner: Node,
	other: Node,
	changed_values: Dictionary,
	relationship: Dictionary
) -> void:
	var love_delta := _get_love_delta(changed_values)
	if is_zero_approx(love_delta):
		return
	if not _is_this_npcs_player_relationship(relationship_owner, other, relationship):
		return

	love_meter.value = clampf(
		float(relationship.get("love", love_meter.value)),
		love_meter.min_value,
		love_meter.max_value
	)
	_show_temporarily()


func _get_love_delta(changed_values: Dictionary) -> float:
	for metric_key in changed_values:
		if StringName(String(metric_key)) == &"love":
			return float(changed_values[metric_key])
	return 0.0


func _is_this_npcs_player_relationship(
	relationship_owner: Node,
	other: Node,
	relationship: Dictionary
) -> bool:
	if _npc == null or not is_instance_valid(_npc):
		return false
	var npc_id := NpcIdentity.get_stable_actor_id(_npc)
	if npc_id.is_empty():
		return false
	var owner_id := (
		NpcIdentity.get_stable_actor_id(relationship_owner)
		if relationship_owner != null and is_instance_valid(relationship_owner)
		else String(relationship.get("owner_id", "")).strip_edges()
	)
	if owner_id != npc_id:
		return false
	var other_id := (
		NpcIdentity.get_stable_actor_id(other)
		if other != null and is_instance_valid(other)
		else String(relationship.get("other_id", "")).strip_edges()
	)
	return NpcIdentity.is_player_id(other_id)


func _show_temporarily() -> void:
	if _visibility_tween != null and _visibility_tween.is_valid():
		_visibility_tween.kill()
	visible = true
	modulate.a = 1.0
	_visibility_tween = create_tween()
	_visibility_tween.tween_interval(maxf(visible_duration, 0.0))
	if fade_duration > 0.0:
		_visibility_tween.tween_property(
			self,
			"modulate:a",
			0.0,
			fade_duration
		).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_visibility_tween.tween_callback(_hide_after_fade)


func _hide_after_fade() -> void:
	visible = false
	modulate.a = 0.0
	_visibility_tween = null


func _align_with_health_bar() -> void:
	if _npc == null:
		return
	var hp_bar := _npc.get_node_or_null("HPBar") as Control
	if hp_bar == null:
		return
	# Share HP's complete footprint: the heart occupies the left 16px and the
	# shorter love meter fills the remaining width to the same right edge.
	size.x = hp_bar.size.x
	love_meter_frame.size.x = maxf(
		hp_bar.size.x - love_meter_frame.position.x,
		0.0
	)
	position = Vector2(
		hp_bar.position.x,
		hp_bar.position.y - size.y - health_bar_gap
	)
