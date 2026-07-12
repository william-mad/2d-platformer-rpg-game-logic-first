class_name PlayerBreadcrumbRecorder
extends Node

@export_range(0.05, 0.5, 0.01) var record_interval_seconds: float = 0.1
@export_range(4.0, 128.0, 1.0) var minimum_distance: float = 28.0
@export_range(2, 8, 1) var maximum_breadcrumbs: int = 2
@export_range(0.1, 10.0, 0.1) var minimum_traversal_duration: float = 0.1

var _player: CharacterBody2D
var _breadcrumbs: Array[Dictionary] = []
var _elapsed: float = 0.0
var _previous_on_floor: bool = false
var _last_grounded_position: Vector2
var _pending_traversal: Dictionary = {}
var _next_sequence: int = 1


func _ready() -> void:
	_player = get_parent() as CharacterBody2D
	_previous_on_floor = _player != null and _is_effectively_grounded()
	_last_grounded_position = _player.global_position if _player != null else Vector2.ZERO
	add_to_group(&"player_breadcrumb_recorder")
	if _previous_on_floor:
		_publish_grounded_breadcrumb(true)


func _physics_process(delta: float) -> void:
	if _player == null:
		return
	var on_floor := _is_effectively_grounded()
	if _previous_on_floor and not on_floor:
		_begin_pending_traversal()
	elif not _previous_on_floor and not on_floor:
		_update_pending_traversal(delta)
	elif not _previous_on_floor and on_floor:
		_complete_pending_traversal(delta)
		_last_grounded_position = _player.global_position
		_previous_on_floor = true
		_elapsed = 0.0
		return
	if not on_floor:
		_previous_on_floor = false
		return
	_last_grounded_position = _player.global_position
	_elapsed += delta
	if _elapsed < record_interval_seconds:
		_previous_on_floor = true
		return
	_elapsed = 0.0
	_publish_grounded_breadcrumb(false)
	_previous_on_floor = true


func get_delayed_breadcrumb(delay_seconds: float = 0.75) -> Dictionary:
	var now := Time.get_ticks_msec()
	var delay_msec := int(maxf(delay_seconds, 0.0) * 1000.0)
	for breadcrumb in _breadcrumbs:
		if now - int(breadcrumb.get("recorded_msec", now)) >= delay_msec:
			return breadcrumb.duplicate(true)
	return _breadcrumbs.back().duplicate(true) if not _breadcrumbs.is_empty() else {}


func get_latest_breadcrumb() -> Dictionary:
	return _breadcrumbs.front().duplicate(true) if not _breadcrumbs.is_empty() else {}


func get_latest_sequence() -> int:
	return _next_sequence - 1


func has_pending_traversal() -> bool:
	return not _pending_traversal.is_empty()


func get_latest_completed_traversal_sequence() -> int:
	for breadcrumb in _breadcrumbs:
		if bool(breadcrumb.get("completed_traversal", false)):
			return int(breadcrumb.get("sequence", 0))
	return 0


func get_next_completed_traversal_after(sequence: int) -> Dictionary:
	# Only the newest completed traversal is authoritative. A newer player
	# landing replaces any older transition Mom had not yet attempted.
	for breadcrumb in _breadcrumbs:
		if not bool(breadcrumb.get("completed_traversal", false)):
			continue
		if int(breadcrumb.get("sequence", 0)) > sequence:
			return breadcrumb.duplicate(true)
	return {}


func get_recent_safe_floor_breadcrumb() -> Dictionary:
	for breadcrumb in _breadcrumbs:
		if bool(breadcrumb.get("on_floor", false)):
			return breadcrumb.duplicate(true)
	return {}


func get_debug_breadcrumbs(maximum_count: int = 40) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var count := mini(maxi(maximum_count, 0), _breadcrumbs.size())
	for index in count:
		result.append(_breadcrumbs[index].duplicate(true))
	return result


func _publish_grounded_breadcrumb(force: bool) -> void:
	var moved_enough := _breadcrumbs.is_empty() or _player.global_position.distance_to(
		_breadcrumbs.front().get("position", _player.global_position)
	) >= minimum_distance
	if not force and not moved_enough:
		return
	var current_scene := get_tree().current_scene
	_append_breadcrumb({
		"position": _player.global_position,
		"velocity": _player.velocity,
		"on_floor": true,
		"jump_started": false,
		"drop_started": false,
		"completed_traversal": false,
		"facing": signf(_player.velocity.x) if not is_zero_approx(_player.velocity.x) else 1.0,
		"scene_path": current_scene.scene_file_path if current_scene != null else "",
		"recorded_msec": Time.get_ticks_msec(),
	})


func _begin_pending_traversal() -> void:
	var direction := signf(_player.velocity.x)
	if is_zero_approx(direction):
		direction = 1.0
	_pending_traversal = {
		"takeoff_position": _last_grounded_position,
		"takeoff_direction": direction,
		"initial_velocity": _player.velocity,
		"traversal_type": "jump" if _player.velocity.y < 0.0 else "drop",
		"duration": 0.0,
		"peak_y": _player.global_position.y,
	}


func _update_pending_traversal(delta: float) -> void:
	if _pending_traversal.is_empty():
		return
	_pending_traversal["duration"] = float(_pending_traversal.get("duration", 0.0)) + delta
	_pending_traversal["peak_y"] = minf(
		float(_pending_traversal.get("peak_y", _player.global_position.y)),
		_player.global_position.y
	)


func _complete_pending_traversal(delta: float) -> void:
	if _pending_traversal.is_empty():
		_publish_grounded_breadcrumb(true)
		return
	_update_pending_traversal(delta)
	var duration := float(_pending_traversal.get("duration", 0.0))
	var takeoff: Vector2 = _pending_traversal.get("takeoff_position", _player.global_position)
	var landing := _player.global_position
	var traversal_type := String(_pending_traversal.get("traversal_type", "drop"))
	var direction := signf(landing.x - takeoff.x)
	if is_zero_approx(direction):
		direction = float(_pending_traversal.get("takeoff_direction", 1.0))
	var current_scene := get_tree().current_scene
	_append_breadcrumb({
		"position": landing,
		"velocity": _player.velocity,
		"on_floor": true,
		"jump_started": traversal_type == "jump",
		"drop_started": traversal_type == "drop",
		"completed_traversal": true,
		"traversal_type": traversal_type,
		"takeoff_position": takeoff,
		"landing_position": landing,
		"initial_velocity": _pending_traversal.get("initial_velocity", Vector2.ZERO),
		"traversal_direction": direction,
		"duration": maxf(duration, minimum_traversal_duration),
		"peak_height": maxf(takeoff.y - float(_pending_traversal.get("peak_y", takeoff.y)), 0.0),
		"facing": direction,
		"scene_path": current_scene.scene_file_path if current_scene != null else "",
		"recorded_msec": Time.get_ticks_msec(),
	})
	_pending_traversal.clear()


func _append_breadcrumb(breadcrumb: Dictionary) -> void:
	breadcrumb["sequence"] = _next_sequence
	_next_sequence += 1
	if bool(breadcrumb.get("completed_traversal", false)):
		# The segment already contains both takeoff and landing, so no older route
		# geometry is needed after a new landing is published.
		_breadcrumbs.clear()
	else:
		# Retain at most the latest completed segment plus one current grounded
		# point. This prevents ordinary grounded samples from forming a route queue.
		for index in range(_breadcrumbs.size() - 1, -1, -1):
			if not bool(_breadcrumbs[index].get("completed_traversal", false)):
				_breadcrumbs.remove_at(index)
	_breadcrumbs.push_front(breadcrumb)
	if _breadcrumbs.size() > maximum_breadcrumbs:
		_breadcrumbs.resize(maximum_breadcrumbs)


func _is_effectively_grounded() -> bool:
	if _player == null:
		return false
	if _player.is_on_floor():
		return true
	var player_states = _player.get("states")
	if not (player_states is Array) or player_states.is_empty():
		return false
	var current_state = _player.get("current_state")
	return current_state is PlayerStateLedgeGrab
