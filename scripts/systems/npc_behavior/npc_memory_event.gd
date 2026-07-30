class_name NpcMemoryEvent extends RefCounted

const MemoryPolicy = preload("res://scripts/systems/npc_behavior/npc_memory_policy.gd")

static var _sequence: int = 0

var memory_id: String = ""
var event_type: StringName = &""
var source: StringName = &""
var reason_code: StringName = &""

var subject_id: StringName = &""
var target_id: StringName = &""
var place_id: StringName = &""

var logical_action: StringName = &""
var intent_id: String = ""
var action_session_id: String = ""

var created_game_hours: float = 0.0
var last_updated_game_hours: float = 0.0
var expires_game_hours: float = 0.0

var importance: float = 0.0
var emotional_valence: float = 0.0
var occurrence_count: int = 1
var resolved: bool = false
var metadata: Dictionary = {}


static func create(
	new_event_type: StringName,
	context: Dictionary = {},
	now_game_hours: float = 0.0
) -> NpcMemoryEvent:
	var event := NpcMemoryEvent.new()
	event.event_type = new_event_type
	event.ensure_memory_id()
	event.source = _to_string_name(context.get("source", &"gameplay"))
	event.reason_code = _to_string_name(context.get("reason_code", &""))
	event.subject_id = _to_string_name(context.get("subject_id", &""))
	event.target_id = _to_string_name(context.get("target_id", &""))
	event.place_id = _to_string_name(context.get("place_id", &""))
	event.logical_action = _to_string_name(context.get("logical_action", &""))
	event.intent_id = String(context.get("intent_id", "")).strip_edges()
	event.action_session_id = String(context.get("action_session_id", "")).strip_edges()
	event.created_game_hours = maxf(
		float(context.get("created_game_hours", now_game_hours)),
		0.0
	)
	event.last_updated_game_hours = maxf(
		float(context.get("last_updated_game_hours", event.created_game_hours)),
		event.created_game_hours
	)
	var policy := MemoryPolicy.get_policy(new_event_type)
	var duration := maxf(float(policy.get("default_duration_game_hours", 0.0)), 0.0)
	event.expires_game_hours = maxf(
		float(context.get(
			"expires_game_hours",
			event.created_game_hours + duration
		)),
		event.created_game_hours
	)
	event.importance = clampf(
		float(context.get("importance", policy.get("default_importance", 0.0))),
		0.0,
		1.0
	)
	event.emotional_valence = clampf(
		float(context.get(
			"emotional_valence",
			policy.get("default_emotional_valence", 0.0)
		)),
		-1.0,
		1.0
	)
	event.occurrence_count = maxi(int(context.get("occurrence_count", 1)), 1)
	event.resolved = bool(context.get("resolved", false))
	var context_metadata = context.get("metadata", {})
	event.metadata = context_metadata.duplicate(true) if context_metadata is Dictionary else {}
	return event


func ensure_memory_id() -> String:
	if not memory_id.strip_edges().is_empty():
		memory_id = memory_id.strip_edges()
		return memory_id
	_sequence += 1
	var type_part := String(event_type)
	if type_part.is_empty():
		type_part = "event"
	memory_id = "memory:%s:%d:%d" % [type_part, Time.get_ticks_usec(), _sequence]
	return memory_id


func duplicate_event() -> NpcMemoryEvent:
	return from_dict(to_dict())


func get_dedupe_key() -> String:
	return MemoryPolicy.get_dedupe_key(self)


func is_expired(now_game_hours: float) -> bool:
	return expires_game_hours <= now_game_hours


func get_remaining_hours(now_game_hours: float) -> float:
	return maxf(expires_game_hours - now_game_hours, 0.0)


func to_descriptor(now_game_hours: float) -> Dictionary:
	var descriptor := to_dict()
	descriptor["remaining_game_hours"] = get_remaining_hours(now_game_hours)
	descriptor["expired"] = is_expired(now_game_hours)
	return descriptor


func to_dict() -> Dictionary:
	return {
		"memory_id": memory_id,
		"event_type": String(event_type),
		"source": String(source),
		"reason_code": String(reason_code),
		"subject_id": String(subject_id),
		"target_id": String(target_id),
		"place_id": String(place_id),
		"logical_action": String(logical_action),
		"intent_id": intent_id,
		"action_session_id": action_session_id,
		"created_game_hours": created_game_hours,
		"last_updated_game_hours": last_updated_game_hours,
		"expires_game_hours": expires_game_hours,
		"importance": importance,
		"emotional_valence": emotional_valence,
		"occurrence_count": occurrence_count,
		"resolved": resolved,
		"metadata": metadata.duplicate(true),
	}


static func from_dict(data: Dictionary) -> NpcMemoryEvent:
	var event_type_value := _to_string_name(data.get("event_type", &""))
	var policy := MemoryPolicy.get_policy(event_type_value)
	var created := maxf(_safe_float(data.get("created_game_hours", 0.0), 0.0), 0.0)
	var duration := maxf(float(policy.get("default_duration_game_hours", 0.0)), 0.0)
	var event := NpcMemoryEvent.new()
	event.memory_id = String(data.get("memory_id", "")).strip_edges()
	event.event_type = event_type_value
	event.source = _to_string_name(data.get("source", &""))
	event.reason_code = _to_string_name(data.get("reason_code", &""))
	event.subject_id = _to_string_name(data.get("subject_id", &""))
	event.target_id = _to_string_name(data.get("target_id", &""))
	event.place_id = _to_string_name(data.get("place_id", &""))
	event.logical_action = _to_string_name(data.get("logical_action", &""))
	event.intent_id = String(data.get("intent_id", "")).strip_edges()
	event.action_session_id = String(data.get("action_session_id", "")).strip_edges()
	event.created_game_hours = created
	event.last_updated_game_hours = maxf(
		_safe_float(data.get("last_updated_game_hours", created), created),
		created
	)
	event.expires_game_hours = maxf(
		_safe_float(data.get("expires_game_hours", created + duration), created + duration),
		created
	)
	event.importance = clampf(
		_safe_float(data.get("importance", policy.get("default_importance", 0.0)), 0.0),
		0.0,
		1.0
	)
	event.emotional_valence = clampf(
		_safe_float(
			data.get(
				"emotional_valence",
				policy.get("default_emotional_valence", 0.0)
			),
			0.0
		),
		-1.0,
		1.0
	)
	event.occurrence_count = maxi(int(data.get("occurrence_count", 1)), 1)
	event.resolved = bool(data.get("resolved", false))
	var serialized_metadata = data.get("metadata", {})
	event.metadata = (
		serialized_metadata.duplicate(true)
		if serialized_metadata is Dictionary
		else {}
	)
	return event


static func _to_string_name(value) -> StringName:
	return StringName(String(value).strip_edges())


static func _safe_float(value, fallback: float) -> float:
	if value is float or value is int:
		var number := float(value)
		return number if is_finite(number) else fallback
	return fallback
