class_name InteriorDoor extends Node2D

signal passage_granted(actor: Node, door_id: StringName)
signal passage_completed(actor: Node, door_id: StringName)
signal passage_cancelled(actor: Node, door_id: StringName, reason: StringName)
signal access_denied(actor: Node, door_id: StringName, reason: StringName)
signal door_opened(door_id: StringName)
signal door_closed(door_id: StringName)

@export var door_id: StringName = &""

@export_group("Actor Access")
@export var allow_player: bool = true
@export var player_group: StringName = &"player"
@export var npc_group: StringName = &"npc"
@export var interaction_action: StringName = &"up"
@export var player_requires_interaction: bool = true
@export var auto_open_for_npcs: bool = true
@export var interaction_priority: int = 30
@export var interaction_prompt: String = "Open door"

@export_group("NPC Permissions")
@export var allowed_npc_ids: Array[StringName] = []
@export var blocked_npc_ids: Array[StringName] = []
@export var required_npc_tags: Array[StringName] = []

@export_group("Passage")
@export_range(0.05, 60.0, 0.05, "or_greater") var passage_timeout_seconds: float = 5.0
@export_range(0.0, 5.0, 0.05, "or_greater") var close_delay_seconds: float = 0.2
@export_range(0.0, 512.0, 1.0, "or_greater") var clearance_distance: float = 56.0
@export_range(1.0, 1024.0, 1.0, "or_greater") var request_area_width: float = 144.0
@export_range(-512.0, 512.0, 1.0) var request_area_horizontal_offset: float = 0.0

@onready var door_barrier: StaticBody2D = $DoorBarrier
@onready var request_area: Area2D = $RequestArea
@onready var clearance_area: Area2D = $ClearanceArea
@onready var animation_player: AnimationPlayer = $AnimationPlayer

var _request_actors: Dictionary = {}
var _denied_request_actors: Dictionary = {}
var _grants: Dictionary = {}
var _next_grant_serial: int = 0
var _close_serial: int = 0
var _active_close_serial: int = 0
var _door_is_open: bool = false
var _is_exiting: bool = false


func _ready() -> void:
	_configure_request_area()
	request_area.body_entered.connect(_on_request_area_body_entered)
	request_area.body_exited.connect(_on_request_area_body_exited)
	clearance_area.body_exited.connect(_on_clearance_area_body_exited)
	animation_player.animation_finished.connect(_on_animation_finished)


func _configure_request_area() -> void:
	var request_shape_node := request_area.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if request_shape_node == null:
		return
	request_shape_node.position.x = request_area_horizontal_offset
	var rectangle := request_shape_node.shape as RectangleShape2D
	if rectangle == null:
		return
	var local_rectangle := rectangle.duplicate() as RectangleShape2D
	local_rectangle.size.x = request_area_width
	request_shape_node.shape = local_rectangle


func _physics_process(_delta: float) -> void:
	var now_msec := Time.get_ticks_msec()
	for actor_id_variant in _grants.keys():
		var actor_id := int(actor_id_variant)
		var grant: Dictionary = _grants.get(actor_id, {})
		var actor := _get_grant_actor(grant)
		if actor == null:
			_cancel_grant(actor_id, &"actor_freed")
			continue

		var elapsed_seconds := float(now_msec - int(grant.get("start_time_msec", now_msec))) / 1000.0
		if elapsed_seconds >= passage_timeout_seconds:
			_cancel_grant(actor_id, &"timeout")
			continue

		var entry_side := int(grant.get("entry_side", -1))
		var current_side := _side_of_door(actor)
		if current_side != 0 and current_side != entry_side:
			grant["crossed"] = true
			_grants[actor_id] = grant

		if (
			bool(grant.get("crossed", false))
			and current_side == -entry_side
			and absf((actor as Node2D).global_position.x - global_position.x) >= clearance_distance
		):
			_complete_grant(actor_id)


func _exit_tree() -> void:
	_is_exiting = true
	_close_serial += 1
	for actor_id in _grants.keys():
		_cancel_grant(int(actor_id), &"door_exiting")


func can_actor_use(actor: Node) -> bool:
	if actor == null or not is_instance_valid(actor):
		return false
	if actor.is_in_group(String(player_group)):
		return allow_player
	if actor.is_in_group(String(npc_group)):
		return can_npc_use(actor)
	return false


func can_interact(actor: Node) -> bool:
	if not player_requires_interaction or not request_area.monitoring:
		return false
	if actor == null or not is_instance_valid(actor):
		return false
	if not actor.is_in_group(String(player_group)) or not can_actor_use(actor):
		return false
	if _get_tracked_actor(_request_actors, int(actor.get_instance_id())) != actor:
		return false
	return not is_actor_granted(actor)


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	var result := request_passage(actor)
	return bool(result.get("accepted", false))


func get_interaction_action(_actor: Node) -> StringName:
	return interaction_action


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return interaction_prompt


func can_npc_use(npc: Node) -> bool:
	if npc == null or not is_instance_valid(npc):
		return false
	var npc_id := _get_npc_id(npc)
	return _npc_id_is_allowed(npc_id) and _npc_has_required_tags(npc)


func can_npc_id_use(npc_id: StringName) -> bool:
	# ID-only callers cannot prove live tag membership.
	return _npc_id_is_allowed(npc_id) and required_npc_tags.is_empty()


func request_passage(actor: Node) -> Dictionary:
	if actor == null or not is_instance_valid(actor):
		return {"accepted": false, "reason": &"invalid_actor", "door_id": door_id}

	var actor_id := int(actor.get_instance_id())
	if is_actor_granted(actor):
		return {"accepted": true, "reason": &"already_granted", "door_id": door_id}

	# An instance ID can eventually be reused, so discard an orphaned record first.
	if _grants.has(actor_id):
		_cancel_grant(actor_id, &"actor_freed")

	var denial_reason := _get_denial_reason(actor)
	if not denial_reason.is_empty():
		return _deny_access(actor, denial_reason)

	var actor_body := actor as PhysicsBody2D
	if actor_body == null:
		return _deny_access(actor, &"not_physics_body")

	_next_grant_serial += 1
	var grant_serial := _next_grant_serial
	var exit_callback := _on_granted_actor_tree_exiting.bind(actor_id, grant_serial)
	actor.tree_exiting.connect(exit_callback, CONNECT_ONE_SHOT)
	_grants[actor_id] = {
		"actor": weakref(actor),
		"entry_side": _entry_side_for(actor_body),
		"start_time_msec": Time.get_ticks_msec(),
		"crossed": false,
		"serial": grant_serial,
		"tree_exiting_callback": exit_callback,
	}

	door_barrier.add_collision_exception_with(actor_body)
	actor_body.add_collision_exception_with(door_barrier)
	_close_serial += 1
	_open_door()
	passage_granted.emit(actor, door_id)
	return {"accepted": true, "reason": &"granted", "door_id": door_id}


func is_actor_granted(actor: Node) -> bool:
	if actor == null or not is_instance_valid(actor):
		return false
	var grant: Dictionary = _grants.get(int(actor.get_instance_id()), {})
	return _get_grant_actor(grant) == actor


func _on_request_area_body_entered(actor: Node2D) -> void:
	_track_request_actor(actor)

	if actor.is_in_group(String(player_group)):
		if not player_requires_interaction:
			request_passage(actor)
		elif actor.has_method("register_interaction_candidate"):
			actor.call("register_interaction_candidate", self)
		return
	if actor.is_in_group(String(npc_group)) and auto_open_for_npcs:
		request_passage(actor)


func _on_request_area_body_exited(actor: Node2D) -> void:
	if actor.is_in_group(String(player_group)) and actor.has_method("unregister_interaction_candidate"):
		actor.call("unregister_interaction_candidate", self)
	var actor_id := int(actor.get_instance_id())
	if _get_tracked_actor(_request_actors, actor_id) == actor:
		_request_actors.erase(actor_id)
	_denied_request_actors.erase(actor_id)


func _track_request_actor(actor: Node2D) -> void:
	var actor_id := int(actor.get_instance_id())
	if _get_tracked_actor(_request_actors, actor_id) == actor:
		return
	_request_actors[actor_id] = weakref(actor)
	_denied_request_actors.erase(actor_id)


func _on_clearance_area_body_exited(actor: Node2D) -> void:
	var actor_id := int(actor.get_instance_id())
	var grant: Dictionary = _grants.get(actor_id, {})
	if _get_grant_actor(grant) != actor:
		return

	var entry_side := int(grant.get("entry_side", -1))
	var current_side := _side_of_door(actor)
	if current_side == -entry_side:
		_complete_grant(actor_id)
	elif current_side == entry_side:
		_cancel_grant(actor_id, &"turned_back")
	else:
		_cancel_grant(actor_id, &"clearance_exited")


func _on_granted_actor_tree_exiting(actor_id: int, grant_serial: int) -> void:
	var grant: Dictionary = _grants.get(actor_id, {})
	if int(grant.get("serial", -1)) != grant_serial:
		return
	_cancel_grant(actor_id, &"actor_freed")


func _complete_grant(actor_id: int) -> void:
	var grant: Dictionary = _grants.get(actor_id, {})
	var actor := _get_grant_actor(grant)
	if actor == null:
		_cancel_grant(actor_id, &"actor_freed")
		return
	_remove_grant(actor_id)
	passage_completed.emit(actor, door_id)


func _cancel_grant(actor_id: int, reason: StringName) -> void:
	if not _grants.has(actor_id):
		return
	var actor := _get_grant_actor(_grants.get(actor_id, {}))
	_remove_grant(actor_id)
	passage_cancelled.emit(actor, door_id, reason)


func _remove_grant(actor_id: int) -> void:
	var grant: Dictionary = _grants.get(actor_id, {})
	if grant.is_empty():
		return

	var actor := _get_grant_actor(grant)
	var actor_body := actor as PhysicsBody2D
	if actor_body != null:
		door_barrier.remove_collision_exception_with(actor_body)
		actor_body.remove_collision_exception_with(door_barrier)
		var exit_callback: Callable = grant.get("tree_exiting_callback", Callable())
		if exit_callback.is_valid() and actor.tree_exiting.is_connected(exit_callback):
			actor.tree_exiting.disconnect(exit_callback)

	_grants.erase(actor_id)
	if _grants.is_empty():
		_schedule_close()


func _deny_access(actor: Node, reason: StringName) -> Dictionary:
	var actor_id := int(actor.get_instance_id())
	var actor_is_waiting := _get_tracked_actor(_request_actors, actor_id) == actor
	if not actor_is_waiting or _get_tracked_actor(_denied_request_actors, actor_id) != actor:
		access_denied.emit(actor, door_id, reason)
	if actor_is_waiting:
		_denied_request_actors[actor_id] = weakref(actor)
	return {"accepted": false, "reason": reason, "door_id": door_id}


func _get_denial_reason(actor: Node) -> StringName:
	if actor.is_in_group(String(player_group)):
		return &"" if allow_player else &"player_not_allowed"
	if actor.is_in_group(String(npc_group)):
		return &"" if can_npc_use(actor) else &"npc_not_allowed"
	return &"unsupported_actor"


func _npc_id_is_allowed(npc_id: StringName) -> bool:
	for blocked_id in blocked_npc_ids:
		if String(blocked_id) == String(npc_id):
			return false
	if allowed_npc_ids.is_empty():
		return true
	for allowed_id in allowed_npc_ids:
		if String(allowed_id) == String(npc_id):
			return true
	return false


func _npc_has_required_tags(npc: Node) -> bool:
	if required_npc_tags.is_empty():
		return true
	var metadata_tags = npc.get_meta("npc_tags", [])
	for required_tag in required_npc_tags:
		if npc.is_in_group(String(required_tag)):
			continue
		var found_in_metadata := false
		if metadata_tags is Array:
			for metadata_tag in metadata_tags:
				if String(metadata_tag) == String(required_tag):
					found_in_metadata = true
					break
		if not found_in_metadata:
			return false
	return true


func _get_npc_id(npc: Node) -> StringName:
	if npc.has_method("get_npc_location_id"):
		var npc_id := StringName(String(npc.call("get_npc_location_id")))
		if not npc_id.is_empty():
			return npc_id
	return StringName(str(npc.get_instance_id()))


func _entry_side_for(actor: PhysicsBody2D) -> int:
	var side := _side_of_door(actor)
	if side != 0:
		return side
	var character := actor as CharacterBody2D
	if character != null and not is_zero_approx(character.velocity.x):
		return -1 if character.velocity.x > 0.0 else 1
	return -1


func _side_of_door(actor: Node2D) -> int:
	var horizontal_offset := actor.global_position.x - global_position.x
	if horizontal_offset > 0.5:
		return 1
	if horizontal_offset < -0.5:
		return -1
	return 0


func _get_tracked_actor(tracker: Dictionary, actor_id: int) -> Node:
	var actor_ref = tracker.get(actor_id)
	if actor_ref is WeakRef:
		return actor_ref.get_ref() as Node
	return null


func _get_grant_actor(grant: Dictionary) -> Node:
	var actor_ref = grant.get("actor")
	if actor_ref is WeakRef:
		return actor_ref.get_ref() as Node
	return null


func _open_door() -> void:
	if _door_is_open:
		if animation_player.current_animation == &"close" and animation_player.has_animation(&"open"):
			animation_player.play(&"open")
		return
	if animation_player.has_animation(&"open"):
		animation_player.play(&"open")
	_door_is_open = true
	door_opened.emit(door_id)


func _schedule_close() -> void:
	_close_serial += 1
	var close_serial := _close_serial
	if _is_exiting:
		return
	if close_delay_seconds <= 0.0:
		_finish_close_delay(close_serial)
		return
	var close_timer := get_tree().create_timer(close_delay_seconds)
	close_timer.timeout.connect(_finish_close_delay.bind(close_serial), CONNECT_ONE_SHOT)


func _finish_close_delay(close_serial: int) -> void:
	if _is_exiting or close_serial != _close_serial or not _grants.is_empty():
		return
	_active_close_serial = close_serial
	if animation_player.has_animation(&"close"):
		animation_player.play(&"close")
	else:
		_mark_door_closed(close_serial)


func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name == &"close":
		_mark_door_closed(_active_close_serial)


func _mark_door_closed(close_serial: int) -> void:
	if close_serial != _close_serial or not _grants.is_empty() or not _door_is_open:
		return
	_door_is_open = false
	door_closed.emit(door_id)
