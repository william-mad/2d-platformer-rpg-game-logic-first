class_name NpcBehaviorIntent extends RefCounted

const SOURCE_NEED := &"need"
const SOURCE_SOCIAL_AI := &"social_ai"
const SOURCE_SCHEDULE := &"schedule"
const SOURCE_EMERGENCY := &"emergency"
const SOURCE_EVENT_REACTION := &"event_reaction"
const SOURCE_PLAYER := &"player"
const SOURCE_SCRIPTED := &"scripted"
const SOURCE_TRAVEL := &"travel"
const SOURCE_MANUAL := &"manual"
const SOURCE_INTERNAL := &"internal"

const SUPPORTED_SOURCES := {
	"need": true,
	"social_ai": true,
	"schedule": true,
	"emergency": true,
	"event_reaction": true,
	"player": true,
	"scripted": true,
	"travel": true,
	"manual": true,
	"internal": true,
}

static var _sequence: int = 0

var intent_id: String = ""
var requested_primary_state: StringName = &""
var logical_action_kind: StringName = &""
var source: StringName = SOURCE_MANUAL
var reason: String = ""
var reason_code: StringName = &""
var feedback_text: String = ""
var origin_value: StringName = &""
var lifecycle_only: bool = false
var priority: int = 0
var target_persistent_id: String = ""
var action_session_id: String = ""
var created_at_usec: int = 0
var minimum_commitment_seconds: float = 0.0
var interrupt_priority_margin: int = 0
var metadata: Dictionary = {}


static func create(
	primary_state: StringName,
	logical_action: StringName,
	intent_source: StringName,
	intent_reason: String,
	intent_priority: int,
	target_id: String = "",
	session_id: String = "",
	commitment_seconds: float = 0.0,
	interrupt_margin: int = 0,
	intent_metadata: Dictionary = {},
	intent_reason_code: StringName = &"",
	intent_feedback_text: String = "",
	intent_origin_value: StringName = &"",
	is_lifecycle_only: bool = false
) -> NpcBehaviorIntent:
	var intent := NpcBehaviorIntent.new()
	_sequence += 1
	intent.created_at_usec = Time.get_ticks_usec()
	intent.intent_id = "intent:%d:%d" % [intent.created_at_usec, _sequence]
	intent.requested_primary_state = primary_state
	intent.logical_action_kind = (
		logical_action if logical_action != &"" else primary_state
	)
	intent.source = canonicalize_source(intent_source)
	intent.reason = intent_reason.strip_edges()
	intent.reason_code = intent_reason_code
	intent.feedback_text = intent_feedback_text.strip_edges()
	intent.origin_value = intent_origin_value
	intent.lifecycle_only = is_lifecycle_only
	intent.priority = intent_priority
	intent.target_persistent_id = target_id.strip_edges()
	intent.action_session_id = session_id.strip_edges()
	intent.minimum_commitment_seconds = maxf(commitment_seconds, 0.0)
	intent.interrupt_priority_margin = maxi(interrupt_margin, 0)
	var safe_metadata = _sanitize_debug_value(intent_metadata)
	intent.metadata = safe_metadata if safe_metadata is Dictionary else {}
	return intent


func refreshed_copy(overrides: Dictionary = {}) -> NpcBehaviorIntent:
	var refreshed := NpcBehaviorIntent.new()
	refreshed.intent_id = intent_id
	refreshed.created_at_usec = created_at_usec
	refreshed.requested_primary_state = StringName(String(overrides.get(
		"requested_primary_state", requested_primary_state
	)))
	refreshed.logical_action_kind = StringName(String(overrides.get(
		"logical_action_kind", logical_action_kind
	)))
	refreshed.source = canonicalize_source(StringName(String(overrides.get(
		"source", source
	))))
	refreshed.reason = String(overrides.get("reason", reason)).strip_edges()
	refreshed.reason_code = StringName(String(overrides.get(
		"reason_code", reason_code
	)))
	refreshed.feedback_text = String(overrides.get(
		"feedback_text", feedback_text
	)).strip_edges()
	refreshed.origin_value = StringName(String(overrides.get(
		"origin_value", origin_value
	)))
	refreshed.lifecycle_only = bool(overrides.get("lifecycle_only", lifecycle_only))
	refreshed.priority = int(overrides.get("priority", priority))
	refreshed.target_persistent_id = String(overrides.get(
		"target_persistent_id", target_persistent_id
	)).strip_edges()
	refreshed.action_session_id = String(overrides.get(
		"action_session_id", action_session_id
	)).strip_edges()
	refreshed.minimum_commitment_seconds = maxf(float(overrides.get(
		"minimum_commitment_seconds", minimum_commitment_seconds
	)), 0.0)
	refreshed.interrupt_priority_margin = maxi(int(overrides.get(
		"interrupt_priority_margin", interrupt_priority_margin
	)), 0)
	var refreshed_metadata = overrides.get("metadata", metadata)
	var safe_metadata = _sanitize_debug_value(refreshed_metadata)
	refreshed.metadata = safe_metadata if safe_metadata is Dictionary else {}
	return refreshed


func is_same_logical_intention(other: NpcBehaviorIntent) -> bool:
	if other == null:
		return false
	var own_session := action_session_id.strip_edges()
	var other_session := other.action_session_id.strip_edges()
	if not own_session.is_empty() and not other_session.is_empty():
		return own_session == other_session
	return (
		logical_action_kind == other.logical_action_kind
		and source == other.source
		and target_persistent_id.strip_edges()
			== other.target_persistent_id.strip_edges()
	)


func to_descriptor() -> Dictionary:
	var descriptor := {
		"intent_id": intent_id,
		"requested_primary_state": String(requested_primary_state),
		"logical_action_kind": String(logical_action_kind),
		"source": String(source),
		"reason": reason,
		"reason_code": String(reason_code),
		"feedback_text": feedback_text,
		"origin_value": String(origin_value),
		"lifecycle_only": lifecycle_only,
		"priority": priority,
		"created_at_usec": created_at_usec,
		"minimum_commitment_seconds": minimum_commitment_seconds,
		"interrupt_priority_margin": interrupt_priority_margin,
	}
	if not target_persistent_id.is_empty():
		descriptor["target_persistent_id"] = target_persistent_id
	if not action_session_id.is_empty():
		descriptor["action_session_id"] = action_session_id
	if not metadata.is_empty():
		descriptor["metadata"] = _sanitize_debug_value(metadata)
	return descriptor


func get_debug_summary() -> Dictionary:
	return to_descriptor()


static func canonicalize_source(value: StringName) -> StringName:
	match String(value):
		"scripted_event", "scripted_control":
			return SOURCE_SCRIPTED
		"world_simulation", "reconciliation", "lifecycle":
			return SOURCE_INTERNAL
		"travel_follow", "travel_companion":
			return SOURCE_TRAVEL
	var normalized := String(value).strip_edges().to_lower()
	if SUPPORTED_SOURCES.has(normalized):
		return StringName(normalized)
	return SOURCE_MANUAL if normalized.is_empty() else StringName(normalized)


static func is_autonomous_source(value: StringName) -> bool:
	var normalized := canonicalize_source(value)
	return normalized in [SOURCE_NEED, SOURCE_SOCIAL_AI]


static func _sanitize_debug_value(value):
	if value is Dictionary:
		var clean_dictionary: Dictionary = {}
		for key in value.keys():
			clean_dictionary[String(key)] = _sanitize_debug_value(value[key])
		return clean_dictionary
	if value is Array:
		var clean_array: Array = []
		for item in value:
			clean_array.append(_sanitize_debug_value(item))
		return clean_array
	if value is Object:
		return "<%s:%d>" % [value.get_class(), value.get_instance_id()]
	return value
