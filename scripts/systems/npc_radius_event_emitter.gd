class_name NpcRadiusEventEmitter extends Node

signal radius_event_emitted(event_name: StringName, payload: Dictionary)

@export var event_name: StringName = &"world_sound"
@export_range(1.0, 10000.0, 1.0, "suffix:px") var radius: float = 800.0
@export var sensory_kind: StringName = &"sound"
@export var state_request: StringName = &"ReactToEvent"
@export_range(0, 1000, 1) var request_priority: int = 45
@export var tags: Array[StringName] = [&"sound"]
@export var local_stat_delta: Dictionary = {}
@export var directed_opinion_delta: Dictionary = {}


func emit_radius_event(
	actor: Node = null,
	source: Node = null,
	target: Node = null,
	event_position: Vector2 = Vector2.ZERO,
	extra_payload: Dictionary = {}
) -> Dictionary:
	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus == null or not event_bus.has_method("emit_local_event"):
		return {}

	var resolved_source := source if source != null else get_parent()
	var payload := extra_payload.duplicate(true)
	payload.merge({
		"npc_event": true,
		"sensory_kind": sensory_kind,
		"actor": actor,
		"source": resolved_source,
		"target": target,
		"state_request": state_request,
		"priority": request_priority,
		"tags": tags.duplicate(),
		"local_stat_delta": local_stat_delta.duplicate(true),
		"directed_opinion_delta": directed_opinion_delta.duplicate(true),
	}, true)
	var emitted = event_bus.call(
		"emit_local_event",
		event_name,
		payload,
		event_position,
		radius,
		true
	)
	var result: Dictionary = emitted if emitted is Dictionary else {}
	radius_event_emitted.emit(event_name, result)
	return result
