class_name SlimeHourlySpawner
extends Node2D

@export var slime_scene: PackedScene = preload("res://scenes/monsters/slime.tscn")
@export_range(0.0, 1.0, 0.01) var spawn_chance_per_hour: float = 0.15
@export_range(1, 24, 1, "suffix:h") var spawn_attempt_interval_hours: int = 1
@export_range(0, 50, 1) var max_live_slimes: int = 5
@export var spawn_count_group: StringName = &"slime"
@export var scene_min_x: float = -4200.0
@export var scene_max_x: float = 2700.0
@export var ground_y: float = 368.0
@export var edge_inset: float = 96.0
@export var spawn_parent_path: NodePath

var rng := RandomNumberGenerator.new()
var last_attempt_total_hour: int = -1


func _ready() -> void:
	rng.randomize()
	_connect_world_time()


func spawn_slime_at_random_edge() -> Slime:
	var side := -1 if rng.randf() < 0.5 else 1
	var spawn_x := scene_min_x + edge_inset if side < 0 else scene_max_x - edge_inset
	return spawn_slime(Vector2(spawn_x, ground_y))


func spawn_slime(spawn_position: Vector2) -> Slime:
	if slime_scene == null:
		return null

	var slime := slime_scene.instantiate() as Slime
	if slime == null:
		return null

	var parent := _get_spawn_parent()
	parent.add_child(slime)
	slime.global_position = spawn_position
	return slime


func try_spawn_for_hour(hour: int, snapshot: Dictionary = {}) -> Slime:
	var total_hour := _get_total_hour(hour, snapshot)
	if total_hour == last_attempt_total_hour:
		return null

	last_attempt_total_hour = total_hour
	if spawn_attempt_interval_hours > 1 and total_hour % spawn_attempt_interval_hours != 0:
		return null
	if _get_live_slime_count() >= max_live_slimes:
		return null
	if rng.randf() > spawn_chance_per_hour:
		return null

	return spawn_slime_at_random_edge()


func _connect_world_time() -> void:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_signal(&"hour_changed"):
		return

	var callback := Callable(self, "_on_world_hour_changed")
	if not world_time.is_connected(&"hour_changed", callback):
		world_time.connect(&"hour_changed", callback)


func _on_world_hour_changed(hour: int, snapshot: Dictionary) -> void:
	try_spawn_for_hour(hour, snapshot)


func _get_total_hour(hour: int, snapshot: Dictionary) -> int:
	if snapshot.has("total_hours"):
		return int(floor(float(snapshot["total_hours"])))

	var day := int(snapshot.get("day", 0))
	return day * 24 + hour


func _get_live_slime_count() -> int:
	if not is_inside_tree():
		return 0

	var count := 0
	for candidate in get_tree().get_nodes_in_group(String(spawn_count_group)):
		var node := candidate as Node
		if node == null or not is_instance_valid(node):
			continue

		var candidate_dead = node.get("dead")
		if typeof(candidate_dead) == TYPE_BOOL and bool(candidate_dead):
			continue

		count += 1

	return count


func _get_spawn_parent() -> Node:
	if not String(spawn_parent_path).is_empty():
		var configured_parent := get_node_or_null(spawn_parent_path)
		if configured_parent != null:
			return configured_parent

	if get_tree() != null and get_tree().current_scene != null:
		return get_tree().current_scene

	return get_parent()
