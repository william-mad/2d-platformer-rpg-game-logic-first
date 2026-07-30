class_name ManualSlimeSpawner
extends Area2D

@export var slime_scene: PackedScene = preload("res://scenes/monsters/slime.tscn")
@export var spawn_action: StringName = &"charm"
@export var ready_text: String = "C: SLIME"
@export var spawned_text: String = "SLIME!"
@export var spawn_offset: Vector2 = Vector2(0.0, 0.0)
@export_range(0.0, 3.0, 0.05, "suffix:s") var spawn_cooldown_seconds: float = 0.35
@export var spawn_parent_path: NodePath
@export var interaction_priority: int = 20

@onready var label: Label = get_node_or_null("%Label") as Label
@onready var zone_visual: Polygon2D = get_node_or_null("%ZoneVisual") as Polygon2D
@onready var spawn_point: Node2D = get_node_or_null("%SpawnPoint") as Node2D
@onready var spawn_link: Line2D = get_node_or_null("%SpawnLink") as Line2D

var player_inside: bool = false
var cooldown_timer: float = 0.0
var feedback_timer: float = 0.0
var active_player: Node2D
var interaction_focused: bool = false


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_refresh_spawn_point_visual()
	_update_label(ready_text)
	set_process(false)
	call_deferred("_refresh_player_inside")


func _process(delta: float) -> void:
	cooldown_timer = maxf(cooldown_timer - delta, 0.0)
	if feedback_timer > 0.0:
		feedback_timer = maxf(feedback_timer - delta, 0.0)
		if feedback_timer <= 0.0:
			_update_label(ready_text)

	if cooldown_timer <= 0.0 and feedback_timer <= 0.0:
		set_process(false)


func can_interact(actor: Node) -> bool:
	return actor == active_player and player_inside and cooldown_timer <= 0.0 and slime_scene != null


func get_interaction_action(_actor: Node) -> StringName:
	return spawn_action


func interact(actor: Node) -> bool:
	return can_interact(actor) and _spawn_slime() != null


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return ready_text


func set_interaction_focused(_actor: Node, focused: bool) -> void:
	interaction_focused = focused
	_update_label_visibility()


func _spawn_slime() -> Slime:
	if slime_scene == null:
		return null

	var slime := slime_scene.instantiate() as Slime
	if slime == null:
		return null

	var parent := _get_spawn_parent()
	parent.add_child(slime)
	slime.global_position = _get_spawn_position()
	cooldown_timer = maxf(spawn_cooldown_seconds, 0.0)
	_show_feedback(spawned_text)
	return slime


func _show_feedback(message: String) -> void:
	feedback_timer = 0.6
	set_process(true)
	_update_label(message)
	if zone_visual != null:
		zone_visual.color = Color(0.38, 0.9, 0.42, 0.45)


func _update_label(message: String) -> void:
	if label != null:
		label.text = message

	if zone_visual != null and message == ready_text:
		zone_visual.color = Color(0.35, 0.72, 0.36, 0.36)
	_update_label_visibility()


func _update_label_visibility() -> void:
	if label != null:
		label.visible = interaction_focused or feedback_timer > 0.0


func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player_inside = true
		active_player = body
		if body.has_method("register_interaction_candidate"):
			body.call("register_interaction_candidate", self)


func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group("player"):
		if body.has_method("unregister_interaction_candidate"):
			body.call("unregister_interaction_candidate", self)
		player_inside = false
		if body == active_player:
			active_player = null


func _refresh_player_inside() -> void:
	if active_player != null and is_instance_valid(active_player) and active_player.has_method("unregister_interaction_candidate"):
		active_player.call("unregister_interaction_candidate", self)
	player_inside = false
	active_player = null
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			player_inside = true
			active_player = body
			if body.has_method("register_interaction_candidate"):
				body.call("register_interaction_candidate", self)
			break

	set_process(cooldown_timer > 0.0 or feedback_timer > 0.0)


func _get_spawn_position() -> Vector2:
	if spawn_point != null:
		return spawn_point.global_position

	return global_position + spawn_offset


func _refresh_spawn_point_visual() -> void:
	if spawn_point != null:
		spawn_point.position = spawn_offset

	if spawn_link != null:
		spawn_link.points = PackedVector2Array([Vector2.ZERO, spawn_offset])


func _get_spawn_parent() -> Node:
	if not String(spawn_parent_path).is_empty():
		var configured_parent := get_node_or_null(spawn_parent_path)
		if configured_parent != null:
			return configured_parent

	if get_tree() != null and get_tree().current_scene != null:
		return get_tree().current_scene

	return get_parent()
