extends Node

signal event_emitted(event_name: StringName, payload: Dictionary)
signal seen_event_emitted(event_name: StringName, payload: Dictionary)
signal local_event_emitted(event_name: StringName, payload: Dictionary)
signal scene_event_emitted(event_name: StringName, payload: Dictionary)
signal global_event_emitted(event_name: StringName, payload: Dictionary)
signal npc_event_emitted(event_name: StringName, payload: Dictionary)

const SCOPE_SEEN := &"seen"
const SCOPE_LOCAL := &"local"
const SCOPE_SCENE := &"scene"
const SCOPE_GLOBAL := &"global"

const EVENT_DAMAGE_DEALT := &"damage_dealt"

# Scope choices:
# seen: receivers react only when they can see seen_target, target, source, or actor.
# local: receivers react only inside radius from position.
# scene: receivers react only when they are under the same current scene root.
# global: every receiver can react, no distance or scene check.
@export var print_debug_events: bool = false
@export var damage_event_scope: StringName = SCOPE_LOCAL
@export var damage_event_radius: float = 380.0
@export_range(0.0, 5.0, 0.05, "suffix:s") var damage_event_min_interval_seconds: float = 1.0

var recent_damage_event_times: Dictionary = {}


func _ready() -> void:
	call_deferred("_connect_damage_events")


func emit_event(
	event_name: StringName,
	payload: Dictionary = {},
	scope: StringName = &""
) -> Dictionary:
	var event_payload := _prepare_event_payload(event_name, payload, scope)

	if print_debug_events:
		print("EventBus: ", event_name, " ", event_payload)

	event_emitted.emit(event_name, event_payload)
	_emit_scoped_signal(event_name, event_payload)

	if _is_npc_event_payload(event_payload):
		npc_event_emitted.emit(event_name, event_payload)

	return event_payload


func emit_seen_event(
	event_name: StringName,
	payload: Dictionary = {},
	seen_target: Node = null
) -> Dictionary:
	var event_payload := payload.duplicate()
	event_payload["seen_target"] = seen_target
	return emit_event(event_name, event_payload, SCOPE_SEEN)


func emit_local_event(
	event_name: StringName,
	payload: Dictionary = {},
	position: Vector2 = Vector2.ZERO,
	radius: float = 320.0,
	has_position: bool = true
) -> Dictionary:
	var event_payload := payload.duplicate()
	event_payload["position"] = position
	event_payload["has_position"] = has_position
	event_payload["radius"] = radius
	return emit_event(event_name, event_payload, SCOPE_LOCAL)


func emit_scene_event(
	event_name: StringName,
	payload: Dictionary = {},
	scene_root: Node = null
) -> Dictionary:
	var event_payload := payload.duplicate()
	event_payload["scene_root"] = scene_root
	return emit_event(event_name, event_payload, SCOPE_SCENE)


func emit_global_event(event_name: StringName, payload: Dictionary = {}) -> Dictionary:
	return emit_event(event_name, payload, SCOPE_GLOBAL)


func emit_npc_event(
	event_name: StringName,
	stat_delta: Dictionary = {},
	actor: Node = null,
	target: Node = null,
	source: Node = null,
	position: Vector2 = Vector2.ZERO,
	has_position: bool = false,
	radius: float = 0.0,
	state_request: StringName = &"",
	request_priority: int = 50,
	tags: Array = [],
	scope: StringName = SCOPE_LOCAL,
	scene_root: Node = null,
	seen_target: Node = null,
	required_tags: Array = []
) -> Dictionary:
	var event_source := source if source != null else actor
	var payload := {
		"npc_event": true,
		"stat_delta": stat_delta,
		"actor": actor,
		"target": target,
		"source": event_source,
		"position": position,
		"has_position": has_position,
		"radius": radius,
		"state_request": state_request,
		"priority": request_priority,
		"tags": tags,
		"scene_root": scene_root,
		"seen_target": seen_target,
		"required_tags": required_tags,
	}

	return emit_event(event_name, payload, scope)


func _prepare_event_payload(
	event_name: StringName,
	payload: Dictionary,
	scope: StringName
) -> Dictionary:
	var event_payload := payload.duplicate()
	var payload_scope = event_payload.get("scope", SCOPE_GLOBAL)
	var event_scope := _normalize_scope(scope if scope != &"" else payload_scope)

	event_payload["event_name"] = event_name
	event_payload["scope"] = event_scope
	event_payload["emitted_at_msec"] = Time.get_ticks_msec()

	_resolve_payload_position(event_payload)
	_resolve_payload_scene(event_payload)
	_resolve_payload_seen_target(event_payload)

	return event_payload


func _emit_scoped_signal(event_name: StringName, payload: Dictionary) -> void:
	var scope := _normalize_scope(payload.get("scope", SCOPE_GLOBAL))

	if scope == SCOPE_SEEN:
		seen_event_emitted.emit(event_name, payload)
	elif scope == SCOPE_LOCAL:
		local_event_emitted.emit(event_name, payload)
	elif scope == SCOPE_SCENE:
		scene_event_emitted.emit(event_name, payload)
	else:
		global_event_emitted.emit(event_name, payload)


func _connect_damage_events() -> void:
	var damage_events := get_node_or_null("/root/DamageEvents")
	if damage_events == null or not damage_events.has_signal(&"damage_dealt"):
		return

	var damage_callback := Callable(self, "_on_damage_dealt")
	if not damage_events.is_connected(&"damage_dealt", damage_callback):
		damage_events.connect(&"damage_dealt", damage_callback)


func _on_damage_dealt(amount: float, attacker: Node, target: Node) -> void:
	if not _can_emit_damage_event(attacker, target):
		return

	var position_node := _get_first_node2d([target, attacker])
	var has_position := position_node != null
	var event_position := position_node.global_position if has_position else Vector2.ZERO

	# DamageEvents stays the focused combat signal; EventBus turns it into a scoped world event.
	emit_event(EVENT_DAMAGE_DEALT, {
		"npc_event": true,
		"amount": amount,
		"actor": attacker,
		"attacker": attacker,
		"target": target,
		"source": attacker,
		"seen_target": target,
		"position": event_position,
		"has_position": has_position,
		"radius": damage_event_radius,
		"tags": [&"damage", &"combat"],
	}, damage_event_scope)


func _can_emit_damage_event(attacker: Node, target: Node) -> bool:
	var interval_msec := int(maxf(damage_event_min_interval_seconds, 0.0) * 1000.0)
	if interval_msec <= 0:
		return true

	var now := Time.get_ticks_msec()
	var key := "%s:%s" % [_get_node_event_id(attacker), _get_node_event_id(target)]
	var previous_time := int(recent_damage_event_times.get(key, -interval_msec))
	if now - previous_time < interval_msec:
		return false

	recent_damage_event_times[key] = now
	_prune_recent_damage_event_times(now, interval_msec)
	return true


func _get_node_event_id(node: Node) -> int:
	if node == null or not is_instance_valid(node):
		return 0

	return node.get_instance_id()


func _prune_recent_damage_event_times(now: int, interval_msec: int) -> void:
	if recent_damage_event_times.size() <= 64:
		return

	var prune_age := maxi(interval_msec * 4, 1000)
	for key in recent_damage_event_times.keys():
		if now - int(recent_damage_event_times[key]) > prune_age:
			recent_damage_event_times.erase(key)


func _resolve_payload_position(payload: Dictionary) -> void:
	var position_value = payload.get("position", null)
	if bool(payload.get("has_position", false)) and (position_value is Vector2):
		return

	var position_node := _get_first_node2d([
		payload.get("target", null),
		payload.get("source", null),
		payload.get("actor", null),
		payload.get("seen_target", null),
	])
	if position_node == null:
		payload["has_position"] = false
		return

	payload["position"] = position_node.global_position
	payload["has_position"] = true


func _resolve_payload_scene(payload: Dictionary) -> void:
	var scene_root := payload.get("scene_root", null) as Node
	if scene_root == null:
		var scene_node := _get_first_node([
			payload.get("target", null),
			payload.get("source", null),
			payload.get("actor", null),
			payload.get("seen_target", null),
		])
		if scene_node != null and scene_node.get_tree() != null:
			scene_root = scene_node.get_tree().current_scene
		elif get_tree() != null:
			scene_root = get_tree().current_scene

	payload["scene_root"] = scene_root
	if scene_root != null:
		payload["scene_path"] = scene_root.get_path()


func _resolve_payload_seen_target(payload: Dictionary) -> void:
	var seen_target := payload.get("seen_target", null) as Node
	if seen_target != null:
		return

	seen_target = _get_first_node([
		payload.get("target", null),
		payload.get("source", null),
		payload.get("actor", null),
	])
	payload["seen_target"] = seen_target


func _is_npc_event_payload(payload: Dictionary) -> bool:
	if bool(payload.get("npc_event", false)):
		return true

	if payload.has("stat_delta"):
		return true

	return String(payload.get("state_request", "")) != ""


func _normalize_scope(scope_value) -> StringName:
	var scope_text := String(scope_value)

	if scope_text == String(SCOPE_SEEN):
		return SCOPE_SEEN
	if scope_text == String(SCOPE_LOCAL):
		return SCOPE_LOCAL
	if scope_text == String(SCOPE_SCENE):
		return SCOPE_SCENE
	if scope_text == String(SCOPE_GLOBAL):
		return SCOPE_GLOBAL

	return SCOPE_GLOBAL


func _get_first_node(values: Array) -> Node:
	for value in values:
		var node := value as Node
		if node != null and is_instance_valid(node):
			return node

	return null


func _get_first_node2d(values: Array) -> Node2D:
	for value in values:
		var node := value as Node2D
		if node != null and is_instance_valid(node):
			return node

	return null
