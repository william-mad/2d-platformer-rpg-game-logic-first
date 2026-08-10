class_name RopeStatusNotifier
extends RefCounted

## A small amount of strain should count as load, while hysteresis prevents
## notifications from flickering when a rope rests close to the threshold.
const DRAG_ENTER_TENSION: float = 0.05
const DRAG_EXIT_TENSION: float = 0.025
const BODY_CALLBACK: StringName = &"receive_rope_state"

var _rope
var _load_bearing: bool = false
var _pending_notifications: Array[Dictionary] = []
var _is_delivering_notifications: bool = false


func setup(rope) -> void:
	_rope = rope
	_load_bearing = false
	_pending_notifications.clear()
	_is_delivering_notifications = false


func capture_topology() -> Dictionary:
	return {
		"bodies": _get_endpoint_bodies(),
		"load_bearing": _load_bearing,
	}


func reset_silently() -> void:
	_load_bearing = false


func set_tension_silently(tension: float) -> void:
	_load_bearing = _resolve_load_bearing(tension)


func reconcile_topology(
	previous: Dictionary,
	reason: StringName
) -> void:
	var previous_bodies: Array = previous.get("bodies", [])
	var previous_load := bool(previous.get("load_bearing", false))
	var current_bodies := _get_endpoint_bodies()
	var candidates: Array[Node2D] = []

	for body_value in previous_bodies:
		var body := body_value as Node2D
		if _node_is_valid(body) and not candidates.has(body):
			candidates.append(body)
	for body in current_bodies:
		if not candidates.has(body):
			candidates.append(body)

	for body in candidates:
		var was_attached := previous_bodies.has(body)
		var is_attached := current_bodies.has(body)
		if (
			was_attached != is_attached
			or (
				was_attached
				and is_attached
				and previous_load != _load_bearing
			)
		):
			_queue_body_notification(body, reason)
	_deliver_queued_notifications()


func update_tension(tension: float) -> void:
	if _rope == null or not _rope.active:
		_load_bearing = false
		return

	var next_load_bearing := _resolve_load_bearing(tension)
	if next_load_bearing == _load_bearing:
		return

	_load_bearing = next_load_bearing
	for body in _get_endpoint_bodies():
		_queue_body_notification(body, &"load_changed")
	_deliver_queued_notifications()


func is_load_bearing() -> bool:
	return _rope != null and _rope.active and _load_bearing


func _resolve_load_bearing(tension: float) -> bool:
	return (
		tension > DRAG_EXIT_TENSION
		if _load_bearing
		else tension >= DRAG_ENTER_TENSION
	)


func _get_endpoint_bodies() -> Array[Node2D]:
	var bodies: Array[Node2D] = []
	if _rope == null or not _rope.active:
		return bodies
	if _node_is_valid(_rope.start_body):
		bodies.append(_rope.start_body)
	if (
		_node_is_valid(_rope.end_body)
		and not bodies.has(_rope.end_body)
	):
		bodies.append(_rope.end_body)
	return bodies


func _queue_body_notification(body: Node2D, reason: StringName) -> void:
	if not _node_is_valid(body) or not body.has_method(BODY_CALLBACK):
		return
	for index in range(_pending_notifications.size()):
		var pending: Dictionary = _pending_notifications[index]
		var reference := pending.get("body") as WeakRef
		if reference != null and reference.get_ref() == body:
			pending["reason"] = reason
			_pending_notifications[index] = pending
			return
	_pending_notifications.append({
		"body": weakref(body),
		"reason": reason,
	})


func _deliver_queued_notifications() -> void:
	if _is_delivering_notifications:
		return
	_is_delivering_notifications = true
	while not _pending_notifications.is_empty():
		var pending: Dictionary = _pending_notifications.pop_front()
		var reference := pending.get("body") as WeakRef
		var body := reference.get_ref() as Node2D if reference != null else null
		if _node_is_valid(body) and body.has_method(BODY_CALLBACK):
			body.call(
				BODY_CALLBACK,
				_rope,
				StringName(pending.get("reason", &"updated"))
			)
	_is_delivering_notifications = false


static func _node_is_valid(node) -> bool:
	return (
		node != null
		and is_instance_valid(node)
		and not node.is_queued_for_deletion()
	)
