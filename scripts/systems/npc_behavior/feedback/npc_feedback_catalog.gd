class_name NpcFeedbackCatalog extends RefCounted

const Cue = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_cue.gd"
)

const PLAYER_REFUSAL_OPINION: StringName = &"opinion"
const PLAYER_REFUSAL_REPEATED: StringName = &"repeated"
const PLAYER_REFUSAL_BUSY: StringName = &"busy"

const PLAYER_INTERACTION_REFUSAL_LINES := {
	PLAYER_REFUSAL_OPINION: [
		"Not now.",
		"Leave me alone.",
		"No.",
	],
	PLAYER_REFUSAL_REPEATED: [
		"Again?!",
		"We just talked.",
	],
	PLAYER_REFUSAL_BUSY: [
		"I'm busy.",
		"Not right now.",
	],
}

const PLAYER_INTERACTION_REFUSAL_SOFT_LINES := {
	PLAYER_REFUSAL_OPINION: [
		"Please, not right now.",
		"I just need a little space.",
	],
	PLAYER_REFUSAL_REPEATED: [
		"Let's talk again in a bit.",
		"Give me just a moment.",
	],
	PLAYER_REFUSAL_BUSY: [
		"Sorry, give me a minute.",
		"We'll talk soon.",
	],
}

const PLAYER_INTERACTION_REFUSAL_CATEGORIES := {
	"npc_recently_harmed_by_player": PLAYER_REFUSAL_OPINION,
	"recently_harmed_by_requester": PLAYER_REFUSAL_OPINION,
	"requester_favor_too_low": PLAYER_REFUSAL_OPINION,
	"requester_anger_too_high": PLAYER_REFUSAL_OPINION,
	"requester_fear_too_high": PLAYER_REFUSAL_OPINION,
	"mutual_favor_too_low": PLAYER_REFUSAL_OPINION,
	"npc_ignoring_player": PLAYER_REFUSAL_REPEATED,
	"player_interaction_cooldown": PLAYER_REFUSAL_REPEATED,
	"recently_talked_with_requester": PLAYER_REFUSAL_REPEATED,
	"recent_conversation_refusal": PLAYER_REFUSAL_REPEATED,
	"npc_scripted_controlled": PLAYER_REFUSAL_BUSY,
	"npc_fighting": PLAYER_REFUSAL_BUSY,
	"npc_fleeing": PLAYER_REFUSAL_BUSY,
	"npc_roped": PLAYER_REFUSAL_BUSY,
	"npc_invitation_reserved": PLAYER_REFUSAL_BUSY,
	"npc_invitation_approach": PLAYER_REFUSAL_BUSY,
	"npc_travel_transition": PLAYER_REFUSAL_BUSY,
	"npc_scene_handoff": PLAYER_REFUSAL_BUSY,
	"npc_state_unavailable": PLAYER_REFUSAL_BUSY,
	"npc_scheduled_activity": PLAYER_REFUSAL_BUSY,
	"npc_lesson_or_class_handoff": PLAYER_REFUSAL_BUSY,
	"interaction_hold_rejected": PLAYER_REFUSAL_BUSY,
	"talk_request_rejected": PLAYER_REFUSAL_BUSY,
	"talker_cannot_enter_talk": PLAYER_REFUSAL_BUSY,
	"active_interaction": PLAYER_REFUSAL_BUSY,
	"existing_social_session": PLAYER_REFUSAL_BUSY,
	"protected_primary_activity": PLAYER_REFUSAL_BUSY,
	"protected_intention": PLAYER_REFUSAL_BUSY,
	"protected_action": PLAYER_REFUSAL_BUSY,
	"talk_incompatible_primary_state": PLAYER_REFUSAL_BUSY,
	"talk_state_incompatible": PLAYER_REFUSAL_BUSY,
	"npc_gate_rejected": PLAYER_REFUSAL_BUSY,
}

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
	"player_interaction_refused_opinion": {
		"fallback_text": "Not now.",
		"icon_key": &"",
		"priority": 85,
		"duration_seconds": 1.6,
		"maximum_lifetime_seconds": 3.0,
		"cooldown_seconds": 0.75,
		"category": Cue.CATEGORY_SOCIAL,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"player_interaction_refused_repeated": {
		"fallback_text": "Again?!",
		"icon_key": &"",
		"priority": 80,
		"duration_seconds": 1.6,
		"maximum_lifetime_seconds": 3.0,
		"cooldown_seconds": 0.75,
		"category": Cue.CATEGORY_SOCIAL,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	},
	"player_interaction_refused_busy": {
		"fallback_text": "I'm busy.",
		"icon_key": &"",
		"priority": 75,
		"duration_seconds": 1.6,
		"maximum_lifetime_seconds": 3.0,
		"cooldown_seconds": 0.75,
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


static func get_player_interaction_refusal_category(
	reason_code: StringName
) -> StringName:
	var reason := String(reason_code).strip_edges()
	if PLAYER_INTERACTION_REFUSAL_CATEGORIES.has(reason):
		return PLAYER_INTERACTION_REFUSAL_CATEGORIES[reason]
	if reason.begins_with("npc_state_"):
		return PLAYER_REFUSAL_BUSY
	if reason.begins_with("partner_social_decline:"):
		return PLAYER_REFUSAL_OPINION
	if reason.begins_with("partner_temporarily_unavailable:"):
		return PLAYER_REFUSAL_BUSY
	return &""


static func get_player_interaction_refusal_lines(
	category: StringName,
	softened: bool = false
) -> PackedStringArray:
	var pools := (
		PLAYER_INTERACTION_REFUSAL_SOFT_LINES
		if softened
		else PLAYER_INTERACTION_REFUSAL_LINES
	)
	var lines_value: Variant = pools.get(
		category,
		[]
	)
	return PackedStringArray(lines_value) if lines_value is Array else PackedStringArray()


static func is_player_interaction_refusal_presentable(
	reason_code: StringName
) -> bool:
	return get_player_interaction_refusal_category(reason_code) != &""


static func create_player_interaction_refusal_cue(
	reason_code: StringName,
	context: Dictionary = {}
) -> Cue:
	var category := get_player_interaction_refusal_category(reason_code)
	var softened := bool(context.get("softened", false))
	var lines := get_player_interaction_refusal_lines(category, softened)
	if category == &"" or lines.is_empty():
		return null
	var cue_code := StringName("player_interaction_refused_%s" % String(category))
	var selected_text := lines[randi() % lines.size()]
	var identity_key := "player_interaction_refusal:%s" % String(category)
	return create_cue(cue_code, {
		"fallback_text": selected_text,
		"icon_key": &"",
		"metadata": {
			"identity_key": identity_key,
			"cooldown_key": identity_key,
			"reason_code": reason_code,
			"refusal_category": category,
			"refusal_tone": &"soft" if softened else &"standard",
			"directed_favor": float(context.get("directed_favor", -1.0)),
		},
	})


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
