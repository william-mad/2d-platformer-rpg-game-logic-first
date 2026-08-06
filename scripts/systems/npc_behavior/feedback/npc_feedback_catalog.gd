class_name NpcFeedbackCatalog extends RefCounted

const Cue = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_cue.gd"
)

const ENTRIES := {
	"hunger_high": {
		"fallback_text": "Hungry",
		"icon_key": &"hunger",
		"priority": 30,
		"duration_seconds": 1.75,
		"maximum_lifetime_seconds": 4.0,
		"cooldown_seconds": 8.0,
		"category": Cue.CATEGORY_NEED,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"tired_high": {
		"fallback_text": "Tired",
		"icon_key": &"tired",
		"priority": 30,
		"duration_seconds": 1.75,
		"maximum_lifetime_seconds": 4.0,
		"cooldown_seconds": 8.0,
		"category": Cue.CATEGORY_NEED,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"boredom_high": {
		"fallback_text": "Needs a break",
		"icon_key": &"recreation",
		"priority": 25,
		"duration_seconds": 1.75,
		"maximum_lifetime_seconds": 4.0,
		"cooldown_seconds": 8.0,
		"category": Cue.CATEGORY_NEED,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"social_need_high": {
		"fallback_text": "Looking for company",
		"icon_key": &"social",
		"priority": 20,
		"duration_seconds": 1.75,
		"maximum_lifetime_seconds": 4.0,
		"cooldown_seconds": 8.0,
		"category": Cue.CATEGORY_SOCIAL,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"conversation_refused": {
		"fallback_text": "Recently refused",
		"icon_key": &"social_problem",
		"priority": 60,
		"duration_seconds": 2.0,
		"maximum_lifetime_seconds": 6.0,
		"cooldown_seconds": 6.0,
		"category": Cue.CATEGORY_MEMORY,
		"replace_policy": Cue.REFRESH_EXISTING,
	},
	"recent_conversation_refusal": {
		"fallback_text": "Recently refused",
		"icon_key": &"social_problem",
		"priority": 60,
		"duration_seconds": 2.0,
		"maximum_lifetime_seconds": 6.0,
		"cooldown_seconds": 6.0,
		"category": Cue.CATEGORY_MEMORY,
		"replace_policy": Cue.REFRESH_EXISTING,
	},
	"harmed_by_actor": {
		"fallback_text": "Upset with you",
		"icon_key": &"harm_memory",
		"priority": 75,
		"duration_seconds": 2.0,
		"maximum_lifetime_seconds": 6.0,
		"cooldown_seconds": 6.0,
		"category": Cue.CATEGORY_MEMORY,
		"replace_policy": Cue.REFRESH_EXISTING,
	},
	"schedule_running_late": {
		"fallback_text": "Running late",
		"icon_key": &"schedule_late",
		"priority": 55,
		"duration_seconds": 1.75,
		"maximum_lifetime_seconds": 5.0,
		"cooldown_seconds": 8.0,
		"category": Cue.CATEGORY_INTENTION,
		"replace_policy": Cue.QUEUE,
	},
	"schedule_finishing_up": {
		"fallback_text": "Finishing up",
		"icon_key": &"schedule_overtime",
		"priority": 50,
		"duration_seconds": 1.75,
		"maximum_lifetime_seconds": 5.0,
		"cooldown_seconds": 0.0,
		"category": Cue.CATEGORY_INTENTION,
		"replace_policy": Cue.QUEUE,
	},
	"target_unavailable": {
		"fallback_text": "That place is unavailable",
		"icon_key": &"target_problem",
		"priority": 65,
		"duration_seconds": 2.0,
		"maximum_lifetime_seconds": 6.0,
		"cooldown_seconds": 6.0,
		"category": Cue.CATEGORY_PROBLEM,
		"replace_policy": Cue.REFRESH_EXISTING,
	},
	"movement_failed": {
		"fallback_text": "Can't reach that",
		"icon_key": &"movement_problem",
		"priority": 70,
		"duration_seconds": 2.0,
		"maximum_lifetime_seconds": 6.0,
		"cooldown_seconds": 6.0,
		"category": Cue.CATEGORY_PROBLEM,
		"replace_policy": Cue.REFRESH_EXISTING,
	},
	"intention_target_lost": {
		"fallback_text": "Lost track of that",
		"icon_key": &"target_problem",
		"priority": 65,
		"duration_seconds": 2.0,
		"maximum_lifetime_seconds": 6.0,
		"cooldown_seconds": 6.0,
		"category": Cue.CATEGORY_PROBLEM,
		"replace_policy": Cue.REFRESH_EXISTING,
	},
	"recent_target_failure": {
		"fallback_text": "Waiting before trying again",
		"icon_key": &"target_problem",
		"priority": 50,
		"duration_seconds": 1.8,
		"maximum_lifetime_seconds": 6.0,
		"cooldown_seconds": 7.0,
		"category": Cue.CATEGORY_PROBLEM,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"all_social_candidates_suppressed": {
		"fallback_text": "Waiting before talking again",
		"icon_key": &"social_wait",
		"priority": 45,
		"duration_seconds": 1.8,
		"maximum_lifetime_seconds": 6.0,
		"cooldown_seconds": 8.0,
		"category": Cue.CATEGORY_SOCIAL,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"all_targets_recently_failed": {
		"fallback_text": "Waiting before trying again",
		"icon_key": &"target_wait",
		"priority": 50,
		"duration_seconds": 1.8,
		"maximum_lifetime_seconds": 6.0,
		"cooldown_seconds": 8.0,
		"category": Cue.CATEGORY_PROBLEM,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"trying_another_place": {
		"fallback_text": "Trying another place",
		"icon_key": &"target_retry",
		"priority": 35,
		"duration_seconds": 1.5,
		"maximum_lifetime_seconds": 4.0,
		"cooldown_seconds": 8.0,
		"category": Cue.CATEGORY_INTENTION,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"emergency": {
		"fallback_text": "In danger",
		"icon_key": &"emergency",
		"priority": 100,
		"duration_seconds": 2.0,
		"maximum_lifetime_seconds": 4.0,
		"cooldown_seconds": 3.0,
		"category": Cue.CATEGORY_EMERGENCY,
		"replace_policy": Cue.REPLACE_LOWER,
	},
	"anger_high": {
		"fallback_text": "In danger",
		"icon_key": &"emergency",
		"priority": 100,
		"duration_seconds": 2.0,
		"maximum_lifetime_seconds": 4.0,
		"cooldown_seconds": 3.0,
		"category": Cue.CATEGORY_EMERGENCY,
		"replace_policy": Cue.REPLACE_LOWER,
	},
}


static func has_code(cue_code: StringName) -> bool:
	return ENTRIES.has(String(cue_code))


static func resolve(cue_code: StringName) -> Dictionary:
	var code := String(cue_code).strip_edges()
	var entry_value: Variant = ENTRIES.get(code, {})
	var entry: Dictionary = (
		entry_value.duplicate(true)
		if entry_value is Dictionary
		else {}
	)
	if entry.is_empty():
		entry = {
			"fallback_text": "Status changed",
			"icon_key": &"",
			"priority": 0,
			"duration_seconds": 1.25,
			"maximum_lifetime_seconds": 4.0,
			"cooldown_seconds": 2.0,
			"category": Cue.CATEGORY_INTENTION,
			"replace_policy": Cue.IGNORE_IF_DUPLICATE,
			"known": false,
		}
	else:
		entry["known"] = true
	entry["cue_code"] = StringName(code)
	entry["text_key"] = StringName("npc_feedback.%s" % code)
	return entry


static func create_cue(
	cue_code: StringName,
	context: Dictionary = {}
) -> Cue:
	var options := resolve(cue_code)
	for key in [
		"cue_id",
		"category",
		"text_key",
		"fallback_text",
		"icon_key",
		"priority",
		"duration_seconds",
		"maximum_lifetime_seconds",
		"cooldown_seconds",
		"replace_policy",
		"source_intent_id",
		"source_session_id",
		"source_memory_id",
		"created_at_usec",
	]:
		if context.has(key):
			options[key] = context[key]
	var metadata_value: Variant = context.get("metadata", {})
	options["metadata"] = (
		metadata_value.duplicate(true)
		if metadata_value is Dictionary
		else {}
	)
	return Cue.create(cue_code, options)
