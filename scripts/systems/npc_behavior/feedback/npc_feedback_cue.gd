class_name NpcFeedbackCue extends RefCounted

const CATEGORY_INTENTION: StringName = &"intention"
const CATEGORY_NEED: StringName = &"need"
const CATEGORY_SOCIAL: StringName = &"social"
const CATEGORY_PROBLEM: StringName = &"problem"
const CATEGORY_MEMORY: StringName = &"memory"
const CATEGORY_EMERGENCY: StringName = &"emergency"

const REPLACE_LOWER: StringName = &"replace_lower"
const QUEUE: StringName = &"queue"
const IGNORE_IF_DUPLICATE: StringName = &"ignore_if_duplicate"
const REFRESH_EXISTING: StringName = &"refresh_existing"

const SUPPORTED_REPLACE_POLICIES := {
	REPLACE_LOWER: true,
	QUEUE: true,
	IGNORE_IF_DUPLICATE: true,
	REFRESH_EXISTING: true,
}

static var _sequence: int = 0

var cue_id: String = ""
var cue_code: StringName = &""
var category: StringName = CATEGORY_INTENTION

var text_key: StringName = &""
var fallback_text: String = ""
var icon_key: StringName = &""

var priority: int = 0
var duration_seconds: float = 1.5
var maximum_lifetime_seconds: float = 4.0
var cooldown_seconds: float = 0.0

var replace_policy: StringName = IGNORE_IF_DUPLICATE
var source_intent_id: String = ""
var source_session_id: String = ""
var source_memory_id: String = ""

var created_at_usec: int = 0
var metadata: Dictionary = {}


static func create(
	code: StringName,
	options: Dictionary = {}
):
	var cue = load(
		"res://scripts/systems/npc_behavior/feedback/npc_feedback_cue.gd"
	).new()
	_sequence += 1
	cue.created_at_usec = int(options.get(
		"created_at_usec",
		Time.get_ticks_usec()
	))
	cue.cue_id = String(options.get(
		"cue_id",
		"cue:%d:%d" % [cue.created_at_usec, _sequence]
	)).strip_edges()
	cue.cue_code = code
	cue.category = StringName(String(options.get(
		"category",
		CATEGORY_INTENTION
	)))
	cue.text_key = StringName(String(options.get("text_key", "")))
	cue.fallback_text = String(options.get("fallback_text", "")).strip_edges()
	cue.icon_key = StringName(String(options.get("icon_key", "")))
	cue.priority = int(options.get("priority", 0))
	cue.duration_seconds = maxf(float(options.get(
		"duration_seconds",
		1.5
	)), 0.05)
	cue.maximum_lifetime_seconds = maxf(float(options.get(
		"maximum_lifetime_seconds",
		4.0
	)), cue.duration_seconds)
	cue.cooldown_seconds = maxf(float(options.get(
		"cooldown_seconds",
		0.0
	)), 0.0)
	cue.replace_policy = StringName(String(options.get(
		"replace_policy",
		IGNORE_IF_DUPLICATE
	)))
	if not SUPPORTED_REPLACE_POLICIES.has(cue.replace_policy):
		cue.replace_policy = IGNORE_IF_DUPLICATE
	cue.source_intent_id = String(options.get(
		"source_intent_id",
		""
	)).strip_edges()
	cue.source_session_id = String(options.get(
		"source_session_id",
		""
	)).strip_edges()
	cue.source_memory_id = String(options.get(
		"source_memory_id",
		""
	)).strip_edges()
	var supplied_metadata = options.get("metadata", {})
	cue.metadata = (
		_copy_data(supplied_metadata)
		if supplied_metadata is Dictionary
		else {}
	)
	return cue


func duplicate_cue():
	return create(cue_code, {
		"cue_id": cue_id,
		"category": category,
		"text_key": text_key,
		"fallback_text": fallback_text,
		"icon_key": icon_key,
		"priority": priority,
		"duration_seconds": duration_seconds,
		"maximum_lifetime_seconds": maximum_lifetime_seconds,
		"cooldown_seconds": cooldown_seconds,
		"replace_policy": replace_policy,
		"source_intent_id": source_intent_id,
		"source_session_id": source_session_id,
		"source_memory_id": source_memory_id,
		"created_at_usec": created_at_usec,
		"metadata": metadata,
	})


func is_valid() -> bool:
	return (
		not cue_id.is_empty()
		and cue_code != &""
		and not fallback_text.is_empty()
		and duration_seconds > 0.0
	)


func get_identity_key() -> String:
	var explicit_key := String(metadata.get("identity_key", "")).strip_edges()
	if not explicit_key.is_empty():
		return explicit_key
	if not source_memory_id.is_empty():
		return "%s:memory:%s" % [String(cue_code), source_memory_id]
	if not source_intent_id.is_empty():
		return "%s:intent:%s" % [String(cue_code), source_intent_id]
	if not source_session_id.is_empty():
		return "%s:session:%s" % [String(cue_code), source_session_id]
	return String(cue_code)


func get_cooldown_key() -> String:
	var explicit_key := String(metadata.get("cooldown_key", "")).strip_edges()
	return explicit_key if not explicit_key.is_empty() else get_identity_key()


func to_descriptor() -> Dictionary:
	return {
		"cue_id": cue_id,
		"cue_code": cue_code,
		"category": category,
		"text_key": text_key,
		"fallback_text": fallback_text,
		"icon_key": icon_key,
		"priority": priority,
		"duration_seconds": duration_seconds,
		"maximum_lifetime_seconds": maximum_lifetime_seconds,
		"cooldown_seconds": cooldown_seconds,
		"replace_policy": replace_policy,
		"source_intent_id": source_intent_id,
		"source_session_id": source_session_id,
		"source_memory_id": source_memory_id,
		"created_at_usec": created_at_usec,
		"identity_key": get_identity_key(),
		"cooldown_key": get_cooldown_key(),
		"metadata": metadata.duplicate(true),
	}


static func _copy_data(value):
	if value is Dictionary:
		var copied: Dictionary = {}
		for key in value.keys():
			copied[String(key)] = _copy_data(value[key])
		return copied
	if value is Array:
		var copied: Array = []
		for item in value:
			copied.append(_copy_data(item))
		return copied
	if value is Object:
		return null
	return value
