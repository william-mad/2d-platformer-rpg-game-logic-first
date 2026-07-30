class_name NpcMemoryPolicy extends RefCounted

const EVENT_CONVERSATION_REFUSED: StringName = &"conversation_refused"
const EVENT_CONVERSATION_COMPLETED: StringName = &"conversation_completed"
const EVENT_ACTION_FAILED: StringName = &"action_failed"
const EVENT_TARGET_UNAVAILABLE: StringName = &"target_unavailable"
const EVENT_MOVEMENT_FAILED: StringName = &"movement_failed"
const EVENT_INTENTION_TARGET_LOST: StringName = &"intention_target_lost"

const MERGE_INCREMENT: StringName = &"increment"

const POLICIES := {
	EVENT_CONVERSATION_REFUSED: {
		"default_duration_game_hours": 1.5,
		"default_importance": 0.55,
		"default_emotional_valence": -0.45,
		"dedupe_window_game_hours": 0.25,
		"maximum_lifetime_game_hours": 3.0,
		"merge_mode": MERGE_INCREMENT,
		"maximum_occurrences": 4,
		"debug_feedback_text": "refused to talk",
	},
	EVENT_CONVERSATION_COMPLETED: {
		"default_duration_game_hours": 0.75,
		"default_importance": 0.35,
		"default_emotional_valence": 0.25,
		"dedupe_window_game_hours": 0.25,
		"maximum_lifetime_game_hours": 1.5,
		"merge_mode": MERGE_INCREMENT,
		"maximum_occurrences": 3,
		"debug_feedback_text": "talked with",
	},
	EVENT_ACTION_FAILED: {
		"default_duration_game_hours": 0.5,
		"default_importance": 0.45,
		"default_emotional_valence": -0.25,
		"dedupe_window_game_hours": 0.125,
		"maximum_lifetime_game_hours": 1.0,
		"merge_mode": MERGE_INCREMENT,
		"maximum_occurrences": 5,
		"debug_feedback_text": "could not complete",
	},
	EVENT_TARGET_UNAVAILABLE: {
		"default_duration_game_hours": 0.5,
		"default_importance": 0.4,
		"default_emotional_valence": -0.2,
		"dedupe_window_game_hours": 0.125,
		"maximum_lifetime_game_hours": 1.0,
		"merge_mode": MERGE_INCREMENT,
		"maximum_occurrences": 4,
		"debug_feedback_text": "target unavailable",
	},
	EVENT_MOVEMENT_FAILED: {
		"default_duration_game_hours": 0.5,
		"default_importance": 0.5,
		"default_emotional_valence": -0.3,
		"dedupe_window_game_hours": 0.125,
		"maximum_lifetime_game_hours": 1.0,
		"merge_mode": MERGE_INCREMENT,
		"maximum_occurrences": 5,
		"debug_feedback_text": "could not reach",
	},
	EVENT_INTENTION_TARGET_LOST: {
		"default_duration_game_hours": 0.75,
		"default_importance": 0.55,
		"default_emotional_valence": -0.35,
		"dedupe_window_game_hours": 0.25,
		"maximum_lifetime_game_hours": 1.5,
		"merge_mode": MERGE_INCREMENT,
		"maximum_occurrences": 3,
		"debug_feedback_text": "lost track of",
	},
}


static func is_supported(event_type: StringName) -> bool:
	return POLICIES.has(event_type)


static func get_policy(event_type: StringName) -> Dictionary:
	var policy = POLICIES.get(event_type, {})
	return policy.duplicate(true) if policy is Dictionary else {}


static func get_dedupe_key(event) -> String:
	if event == null or not is_supported(event.event_type):
		return ""
	var parts: Array[String] = [String(event.event_type), String(event.subject_id)]
	match event.event_type:
		EVENT_CONVERSATION_REFUSED, EVENT_CONVERSATION_COMPLETED:
			parts.append(String(event.target_id))
		EVENT_ACTION_FAILED, EVENT_TARGET_UNAVAILABLE, EVENT_INTENTION_TARGET_LOST:
			parts.append(String(event.target_id))
			parts.append(String(event.logical_action))
		EVENT_MOVEMENT_FAILED:
			parts.append(String(event.target_id))
			parts.append(String(event.logical_action))
			parts.append(String(event.place_id))
	return "|".join(parts)


static func format_debug_text(descriptor: Dictionary) -> String:
	var event_type := StringName(String(descriptor.get("event_type", "")))
	var policy := get_policy(event_type)
	if policy.is_empty():
		return ""
	var subject := _display_id(String(descriptor.get("subject_id", "")))
	var target := _display_id(String(descriptor.get("target_id", "")))
	var place := _display_id(String(descriptor.get("place_id", "")))
	var action := _humanize(String(descriptor.get("logical_action", "")))
	match event_type:
		EVENT_CONVERSATION_REFUSED:
			return "%s refused to talk" % _or_fallback(subject, "Someone")
		EVENT_CONVERSATION_COMPLETED:
			return "Talked with %s" % _or_fallback(subject, "someone")
		EVENT_ACTION_FAILED:
			var failed_action := _or_fallback(action, "action")
			return (
				"Could not %s %s" % [failed_action, target]
				if not target.is_empty()
				else "Could not %s" % failed_action
			)
		EVENT_TARGET_UNAVAILABLE:
			return "%s unavailable" % _or_fallback(target, "Target")
		EVENT_MOVEMENT_FAILED:
			var destination := target if not target.is_empty() else place
			return "Could not reach %s" % _or_fallback(destination, "destination")
		EVENT_INTENTION_TARGET_LOST:
			return "Lost track of %s" % _or_fallback(target, "target")
	return String(policy.get("debug_feedback_text", ""))


static func _display_id(value: String) -> String:
	var clean := value.strip_edges()
	if clean.is_empty():
		return ""
	if clean.contains("/"):
		clean = clean.get_file()
	if clean.contains(":"):
		clean = clean.get_slice(":", clean.get_slice_count(":") - 1)
	return _humanize(clean)


static func _humanize(value: String) -> String:
	var words := value.replace("_", " ").replace("-", " ").strip_edges()
	if words.is_empty():
		return ""
	return words.left(1).to_upper() + words.substr(1)


static func _or_fallback(value: String, fallback: String) -> String:
	return value if not value.is_empty() else fallback
