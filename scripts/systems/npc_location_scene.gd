class_name NpcLocationScene extends Node

@export_file("*.tscn") var scene_path: String = ""
@export var spawn_parent_path: NodePath = NodePath("..")
@export var ground_y: float = 368.0
@export var spawn_x_min: float = -900.0
@export var spawn_x_max: float = 900.0

var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	_breadcrumb("npc_location_scene:ready", get_tracked_scene_path())
	_apply_realtest1_node_switches()
	if (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_NPC_LOCATION_SCENE_REGISTRATION
	):
		_breadcrumb("npc_location_scene:registration_skip", get_tracked_scene_path())
		return
	call_deferred("_activate_scene_tracker")


func get_tracked_scene_path() -> String:
	if not scene_path.is_empty():
		return scene_path

	var current_scene := get_tree().current_scene
	if current_scene == null:
		return ""

	return current_scene.scene_file_path


func get_spawn_parent() -> Node:
	var spawn_parent := get_node_or_null(spawn_parent_path)
	if spawn_parent != null:
		return spawn_parent

	return get_tree().current_scene


func get_random_ground_spawn_position(_npc_id: String) -> Vector2:
	return Vector2(rng.randf_range(spawn_x_min, spawn_x_max), ground_y)


func _activate_scene_tracker() -> void:
	var tracker := get_node_or_null("/root/NpcLocations")
	if tracker == null or not tracker.has_method("activate_scene"):
		_breadcrumb("npc_location_scene:activate_missing_tracker", get_tracked_scene_path())
		return

	_breadcrumb("npc_location_scene:activate_start", get_tracked_scene_path())
	tracker.call("activate_scene", self)
	_breadcrumb("npc_location_scene:activate_end", get_tracked_scene_path())


func _apply_realtest1_node_switches() -> void:
	if not DebugToolsConfig.TROUBLESHOOTING_MODE or not _is_realtest1():
		return
	if DebugToolsConfig.DEBUG_DISABLE_REALTEST1_MOM_NPC:
		_queue_free_scene_node("MomNpc", "realtest1:mom_disabled")
	if DebugToolsConfig.DEBUG_DISABLE_REALTEST1_TALK_PARTNER:
		_queue_free_scene_node("TalkPartnerNpc", "realtest1:talk_partner_disabled")


func _queue_free_scene_node(node_name: String, reason: String) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var node := scene.get_node_or_null(node_name)
	if node == null:
		return
	_breadcrumb("npc_location_scene:queue_free", reason)
	node.queue_free()


func _is_realtest1() -> bool:
	return get_tracked_scene_path() == "res://scenes/testscenes/realtest1.tscn"


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
