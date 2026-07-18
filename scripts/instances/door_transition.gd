class_name DoorTransition extends Area2D

@export_file("*.tscn") var target_scene_path: String = ""
@export var target_spawn_id: StringName = &""
@export var interaction_action: StringName = &"up"
@export_group("Owners")
@export var owner_ids: Array[StringName] = []
@export var player_group: StringName = &"player"
@export var player_owner_id: StringName = &"player"

var player_inside: bool = false
var active_player: Node2D
var player_transition_accepted: bool = false


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(_delta: float) -> void:
	if not player_inside:
		return

	if Input.is_action_just_pressed(interaction_action):
		call_deferred("load_target_scene")


func load_target_scene() -> void:
	if player_transition_accepted:
		return
	if target_scene_path.is_empty():
		push_warning("DoorTransition has no target scene.")
		return

	var player := _get_active_player()
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null:
		if not scene_loader.has_method("request_player_scene_transition"):
			_log_transition_result(false, &"transaction_api_unavailable")
			return
		var result: Dictionary = scene_loader.call(
			"request_player_scene_transition",
			player,
			target_scene_path,
			target_spawn_id,
			&"door"
		)
		player_transition_accepted = bool(result.get("accepted", false))
		if (
			player_transition_accepted
			and scene_loader.has_signal(&"scene_load_finished")
		):
			scene_loader.connect(
				&"scene_load_finished", _on_scene_load_finished, CONNECT_ONE_SHOT
			)
		_log_transition_result(
			player_transition_accepted,
			StringName(result.get("reason", &"transition_rejected"))
		)
		return

	_load_target_scene_direct_fallback(player)


func _on_scene_load_finished(success: bool, scene_path: String) -> void:
	if scene_path == target_scene_path and not success:
		player_transition_accepted = false


func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group(String(player_group)) and _owner_id_is_allowed(player_owner_id):
		player_inside = true
		active_player = body
		_preload_target_scene()


func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group(String(player_group)):
		player_inside = false
		if body == active_player:
			active_player = null


func _owner_id_is_allowed(owner_id: StringName) -> bool:
	if owner_ids.is_empty():
		return true
	for configured_owner_id in owner_ids:
		if String(configured_owner_id) == String(owner_id):
			return true

	return false


func _load_target_scene_direct_fallback(player: Node) -> void:
	var runtime := get_node_or_null("/root/PlayerRuntime")
	if runtime != null and runtime.has_method("capture_player"):
		runtime.call("capture_player", player, target_spawn_id, target_scene_path)
	var error := get_tree().change_scene_to_file(target_scene_path)
	player_transition_accepted = error == OK
	if (
		error != OK
		and runtime != null
		and runtime.has_method("clear_pending_player_transfer")
	):
		runtime.call("clear_pending_player_transfer")
	_log_transition_result(
		player_transition_accepted,
		&"direct_fallback" if error == OK else &"direct_fallback_failed"
	)


func _get_active_player() -> Node2D:
	if active_player != null and is_instance_valid(active_player):
		return active_player

	for body in get_overlapping_bodies():
		var body_node := body as Node2D
		if body_node != null and body_node.is_in_group(String(player_group)):
			return body_node

	return null


func _preload_target_scene() -> void:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("preload_scene"):
		scene_loader.call("preload_scene", target_scene_path)


func _log_transition_result(accepted: bool, result: StringName) -> void:
	if not OS.is_debug_build():
		return
	print("Door player transition: source=%s target=%s spawn=%s accepted=%s result=%s" % [
		name, target_scene_path, String(target_spawn_id), str(accepted), String(result),
	])
