class_name NpcSocialConfigurationValidator extends RefCounted

## Pure validation for the social system's authored/runtime configuration.
## Callers decide whether structured issues should be logged, shown in tooling,
## or treated as load failures; this class never mutates or prints by itself.

const FeedbackCatalog = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_catalog.gd"
)
const FeedbackCue = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_cue.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const Identity = preload("res://scripts/systems/npc_identity.gd")

const SEVERITY_ERROR: StringName = &"error"
const SEVERITY_WARNING: StringName = &"warning"

const DEFAULT_SOCIAL_CONFIGURATION := {
	"social_seeking": {
		"enabled": true,
		"talk_need_threshold": 70.0,
		"priority": 60,
		"minimum_npc_favor": 10.0,
	},
	"talk_handshake": {
		"requires_mutual_favor": true,
		"minimum_favor": 10.0,
		"priority": 70,
		"refuse_lower_priority_tasks": true,
		"refusal_cooldown_seconds": 8.0,
	},
	"social_acceptance": {
		"minimum_favor": 20.0,
		"maximum_anger": 70.0,
		"maximum_fear": 80.0,
	},
	"memory": {
		"recent_refusal_retry_delay_game_hours": 0.25,
		"recent_harm_social_delay_game_hours": 0.5,
		"recent_conversation_repeat_delay_game_hours": 0.125,
	},
}


static func validate_actor_id(
	actor_id: Variant,
	path: String = "actor_id"
) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	var clean_id := String(actor_id).strip_edges()
	if clean_id.is_empty():
		issues.append(_issue(
			SEVERITY_ERROR,
			&"missing_stable_actor_id",
			"A persistent social actor ID is required.",
			path
		))
	elif not is_stable_actor_id(clean_id):
		issues.append(_issue(
			SEVERITY_ERROR,
			&"unstable_actor_id",
			"Social actor IDs must not be scene paths or generated instance IDs.",
			path
		))
	return issues


static func is_stable_actor_id(actor_id: Variant) -> bool:
	return Identity.is_stable_id(String(actor_id))


static func validate_default_feedback_catalog(
	icon_textures_by_key: Dictionary = {}
) -> Array[Dictionary]:
	return validate_feedback_catalog(
		FeedbackCatalog.ENTRIES,
		icon_textures_by_key,
		"feedback_catalog"
	)


static func validate_feedback_catalog(
	entries: Dictionary,
	icon_textures_by_key: Dictionary = {},
	path: String = "feedback_catalog"
) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	for code_value in entries.keys():
		var code := String(code_value).strip_edges()
		var entry_path := _child_path(path, code)
		if not _is_lower_snake_identifier(code):
			issues.append(_issue(
				SEVERITY_ERROR,
				&"invalid_feedback_cue_code",
				"Cue codes must use non-empty lower_snake_case identifiers.",
				entry_path
			))
		var entry_value: Variant = entries[code_value]
		if not (entry_value is Dictionary):
			issues.append(_issue(
				SEVERITY_ERROR,
				&"invalid_feedback_catalog_entry",
				"Each cue catalog entry must be a dictionary.",
				entry_path
			))
			continue
		_validate_feedback_entry(
			issues,
			code,
			entry_value as Dictionary,
			entry_path
		)
	_validate_icon_map(issues, icon_textures_by_key, _child_path(path, "icons"))
	return issues


static func validate_cue_code(
	cue_code: Variant,
	entries: Dictionary = FeedbackCatalog.ENTRIES,
	path: String = "cue_code"
) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	var clean_code := String(cue_code).strip_edges()
	if not _is_lower_snake_identifier(clean_code):
		issues.append(_issue(
			SEVERITY_ERROR,
			&"invalid_feedback_cue_code",
			"Cue codes must use non-empty lower_snake_case identifiers.",
			path
		))
	elif not entries.has(clean_code) and not entries.has(StringName(clean_code)):
		issues.append(_issue(
			SEVERITY_ERROR,
			&"unknown_feedback_cue_code",
			"Cue code '%s' is not registered in the feedback catalog." % clean_code,
			path
		))
	return issues


static func validate_social_configuration(
	configuration: Dictionary,
	path: String = "social",
	include_cross_section_checks: bool = true
) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	var merged := DEFAULT_SOCIAL_CONFIGURATION.duplicate(true)
	for section_name in DEFAULT_SOCIAL_CONFIGURATION.keys():
		if not configuration.has(section_name):
			continue
		var supplied: Variant = configuration[section_name]
		if not (supplied is Dictionary):
			issues.append(_issue(
				SEVERITY_ERROR,
				&"invalid_social_settings_section",
				"Social configuration sections must be dictionaries.",
				_child_path(path, String(section_name))
			))
			continue
		(merged[section_name] as Dictionary).merge(supplied, true)

	var seeking: Dictionary = merged.social_seeking
	var handshake: Dictionary = merged.talk_handshake
	var acceptance: Dictionary = merged.social_acceptance
	var memory: Dictionary = merged.memory
	_validate_bool(issues, seeking, "enabled", _child_path(path, "social_seeking"))
	_validate_number_range(
		issues, seeking, "talk_need_threshold", 0.0, 100.0,
		_child_path(path, "social_seeking")
	)
	_validate_number_range(
		issues, seeking, "priority", 0.0, 1000.0,
		_child_path(path, "social_seeking")
	)
	_validate_number_range(
		issues, seeking, "minimum_npc_favor", 0.0, 100.0,
		_child_path(path, "social_seeking")
	)

	_validate_bool(
		issues, handshake, "requires_mutual_favor",
		_child_path(path, "talk_handshake")
	)
	_validate_bool(
		issues, handshake, "refuse_lower_priority_tasks",
		_child_path(path, "talk_handshake")
	)
	_validate_number_range(
		issues, handshake, "minimum_favor", 0.0, 100.0,
		_child_path(path, "talk_handshake")
	)
	_validate_number_range(
		issues, handshake, "priority", 0.0, 1000.0,
		_child_path(path, "talk_handshake")
	)
	_validate_number_range(
		issues, handshake, "refusal_cooldown_seconds", 0.0, 120.0,
		_child_path(path, "talk_handshake")
	)

	for acceptance_key in ["minimum_favor", "maximum_anger", "maximum_fear"]:
		_validate_number_range(
			issues, acceptance, acceptance_key, 0.0, 100.0,
			_child_path(path, "social_acceptance")
		)
	for memory_key in [
		"recent_refusal_retry_delay_game_hours",
		"recent_harm_social_delay_game_hours",
		"recent_conversation_repeat_delay_game_hours",
	]:
		_validate_number_range(
			issues, memory, memory_key, 0.0, 24.0,
			_child_path(path, "memory")
		)

	if include_cross_section_checks:
		_validate_threshold_order(issues, seeking, handshake, acceptance, path)
	_validate_profile_compatibility(
		issues,
		seeking,
		handshake,
		acceptance,
		memory,
		path,
		include_cross_section_checks
	)
	return issues


static func validate_world_profile(
	profile: Variant,
	actor_id: Variant = "",
	path: String = "world_simulation_profile"
) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	if not String(actor_id).strip_edges().is_empty():
		issues.append_array(validate_actor_id(actor_id, _child_path(path, "actor_id")))
	if not (profile is Dictionary):
		issues.append(_issue(
			SEVERITY_ERROR,
			&"invalid_world_simulation_profile",
			"The world simulation profile must be a dictionary.",
			path
		))
		return issues
	var configuration := {}
	var has_complete_social_context := true
	for section_name in DEFAULT_SOCIAL_CONFIGURATION.keys():
		if profile.has(section_name):
			configuration[section_name] = profile[section_name]
		else:
			has_complete_social_context = false
	# Legacy/offscreen profiles often contain only social_seeking. Validate every
	# supplied field and intrinsic impossibility, but do not compare it with
	# invented defaults for live-only sections that were not persisted.
	issues.append_array(validate_social_configuration(
		configuration,
		path,
		has_complete_social_context
	))
	return issues


static func configuration_from_state_machine(source: Object) -> Dictionary:
	if source == null:
		return DEFAULT_SOCIAL_CONFIGURATION.duplicate(true)
	return {
		"social_seeking": {
			"enabled": _first_property(source, [
				&"world_social_seeking_enabled", &"cross_scene_talk_enabled",
			], true),
			"talk_need_threshold": _first_property(source, [
				&"world_social_talk_need_threshold", &"cross_scene_talk_need_threshold",
			], 70.0),
			"priority": _first_property(source, [
				&"world_social_priority", &"cross_scene_talk_priority",
			], 60),
			"minimum_npc_favor": _first_property(source, [
				&"world_social_minimum_npc_favor", &"cross_scene_minimum_npc_favor",
			], 10.0),
		},
		"talk_handshake": {
			"requires_mutual_favor": _first_property(
				source, [&"npc_talk_requires_mutual_favor"], true
			),
			"minimum_favor": _first_property(
				source, [&"npc_talk_handshake_minimum_favor"], 10.0
			),
			"priority": _first_property(
				source, [&"npc_talk_handshake_priority"], 70
			),
			"refuse_lower_priority_tasks": _first_property(
				source, [&"npc_talk_refuse_lower_priority_tasks"], true
			),
			"refusal_cooldown_seconds": _first_property(
				source, [&"npc_talk_refusal_cooldown_seconds"], 8.0
			),
		},
		"social_acceptance": {
			"minimum_favor": _first_property(
				source, [&"npc_social_acceptance_minimum_favor"], 20.0
			),
			"maximum_anger": _first_property(
				source, [&"npc_social_acceptance_maximum_anger"], 70.0
			),
			"maximum_fear": _first_property(
				source, [&"npc_social_acceptance_maximum_fear"], 80.0
			),
		},
		"memory": {
			"recent_refusal_retry_delay_game_hours": _first_property(
				source, [&"recent_refusal_retry_delay_game_hours"], 0.25
			),
			"recent_harm_social_delay_game_hours": _first_property(
				source, [&"recent_harm_social_delay_game_hours"], 0.5
			),
			"recent_conversation_repeat_delay_game_hours": _first_property(
				source, [&"recent_conversation_repeat_delay_game_hours"], 0.125
			),
		},
	}


static func validate_state_machine_configuration(
	source: Object,
	actor_id: Variant = "",
	path: String = "npc_social_configuration"
) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	if source == null:
		issues.append(_issue(
			SEVERITY_ERROR,
			&"missing_social_configuration_source",
			"A state-machine configuration source is required.",
			path
		))
		return issues
	if not String(actor_id).strip_edges().is_empty():
		issues.append_array(validate_actor_id(actor_id, _child_path(path, "actor_id")))
	issues.append_array(validate_social_configuration(
		configuration_from_state_machine(source),
		path
	))
	return issues


static func has_errors(issues: Array[Dictionary]) -> bool:
	for issue in issues:
		if StringName(String(issue.get("severity", ""))) == SEVERITY_ERROR:
			return true
	return false


static func _validate_feedback_entry(
	issues: Array[Dictionary],
	code: String,
	entry: Dictionary,
	path: String
) -> void:
	var fallback_text := String(entry.get("fallback_text", "")).strip_edges()
	if fallback_text.is_empty():
		issues.append(_issue(
			SEVERITY_ERROR,
			&"missing_feedback_fallback_text",
			"Every feedback cue needs non-empty fallback text.",
			_child_path(path, "fallback_text")
		))
	var text_key := String(entry.get("text_key", "")).strip_edges()
	if not text_key.is_empty() and text_key != "npc_feedback.%s" % code:
		issues.append(_issue(
			SEVERITY_ERROR,
			&"invalid_feedback_text_key",
			"Cue text keys must match 'npc_feedback.<cue_code>'.",
			_child_path(path, "text_key")
		))
	var icon_key := String(entry.get("icon_key", "")).strip_edges()
	if not icon_key.is_empty() and not _is_lower_snake_identifier(icon_key):
		issues.append(_issue(
			SEVERITY_ERROR,
			&"invalid_feedback_icon_key",
			"Optional feedback icon keys must use lower_snake_case.",
			_child_path(path, "icon_key")
		))
	_validate_number_range(issues, entry, "priority", 0.0, 1000.0, path)
	_validate_number_range(
		issues, entry, "duration_seconds", 0.05, 3600.0, path
	)
	_validate_number_range(
		issues, entry, "maximum_lifetime_seconds", 0.05, 3600.0, path
	)
	_validate_number_range(
		issues, entry, "cooldown_seconds", 0.0, 3600.0, path
	)
	if (
		_is_finite_number(entry.get("duration_seconds", null))
		and _is_finite_number(entry.get("maximum_lifetime_seconds", null))
		and float(entry.maximum_lifetime_seconds) < float(entry.duration_seconds)
	):
		issues.append(_issue(
			SEVERITY_ERROR,
			&"feedback_lifetime_shorter_than_duration",
			"Maximum cue lifetime must be at least its visible duration.",
			_child_path(path, "maximum_lifetime_seconds")
		))
	var category := StringName(String(entry.get("category", "")))
	if not _supported_feedback_categories().has(category):
		issues.append(_issue(
			SEVERITY_ERROR,
			&"unsupported_feedback_category",
			"Feedback cue category '%s' is not supported." % String(category),
			_child_path(path, "category")
		))
	var replace_policy := StringName(String(entry.get("replace_policy", "")))
	if not FeedbackCue.SUPPORTED_REPLACE_POLICIES.has(replace_policy):
		issues.append(_issue(
			SEVERITY_ERROR,
			&"unsupported_feedback_replace_policy",
			"Feedback cue replace policy '%s' is not supported." % String(replace_policy),
			_child_path(path, "replace_policy")
		))


static func _validate_icon_map(
	issues: Array[Dictionary],
	icons: Dictionary,
	path: String
) -> void:
	for key_value in icons.keys():
		var key := String(key_value).strip_edges()
		if not _is_lower_snake_identifier(key):
			issues.append(_issue(
				SEVERITY_ERROR,
				&"invalid_feedback_icon_key",
				"Configured icon keys must use lower_snake_case.",
				_child_path(path, key)
			))
		var texture: Variant = icons[key_value]
		# Icons are optional; absent or explicitly null mappings use text fallback.
		if texture != null and not (texture is Texture2D):
			issues.append(_issue(
				SEVERITY_ERROR,
				&"invalid_feedback_icon_texture",
				"Configured feedback icons must be Texture2D resources.",
				_child_path(path, key)
			))


static func _validate_threshold_order(
	issues: Array[Dictionary],
	seeking: Dictionary,
	handshake: Dictionary,
	acceptance: Dictionary,
	path: String
) -> void:
	if not (
		_is_finite_number(seeking.get("minimum_npc_favor", null))
		and _is_finite_number(handshake.get("minimum_favor", null))
		and _is_finite_number(acceptance.get("minimum_favor", null))
	):
		return
	var seeking_minimum := float(seeking.minimum_npc_favor)
	var handshake_minimum := float(handshake.minimum_favor)
	var acceptance_minimum := float(acceptance.minimum_favor)
	if seeking_minimum > handshake_minimum:
		issues.append(_issue(
			SEVERITY_WARNING,
			&"social_favor_threshold_order",
			"Selection favor should not be stricter than the talk handshake.",
			_child_path(path, "social_seeking.minimum_npc_favor")
		))
	if handshake_minimum > acceptance_minimum:
		issues.append(_issue(
			SEVERITY_WARNING,
			&"social_favor_threshold_order",
			"Talk handshake favor should not be stricter than final acceptance.",
			_child_path(path, "talk_handshake.minimum_favor")
		))


static func _validate_profile_compatibility(
	issues: Array[Dictionary],
	seeking: Dictionary,
	handshake: Dictionary,
	acceptance: Dictionary,
	memory: Dictionary,
	path: String,
	include_cross_section_checks: bool = true
) -> void:
	var seeking_enabled := _bool_or(seeking.get("enabled", true), true)
	var mutual_favor := _bool_or(
		handshake.get("requires_mutual_favor", true),
		true
	)
	var seeking_minimum := _number_or(
		seeking.get("minimum_npc_favor", 10.0),
		10.0
	)
	var handshake_minimum := _number_or(
		handshake.get("minimum_favor", 10.0),
		10.0
	)
	if (
		include_cross_section_checks
		and seeking_enabled
		and not mutual_favor
		and seeking_minimum > 0.0
	):
		issues.append(_issue(
			SEVERITY_WARNING,
			&"mutual_favor_profile_mismatch",
			"World social selection still applies mutual favor while the live handshake disables it.",
			_child_path(path, "talk_handshake.requires_mutual_favor")
		))
	if seeking_enabled and seeking_minimum >= 100.0:
		issues.append(_issue(
			SEVERITY_WARNING,
			&"npc_social_selection_impossible",
			"The planner uses a strict favor comparison, so no NPC candidate can exceed 100.",
			_child_path(path, "social_seeking.minimum_npc_favor")
		))
	if mutual_favor and handshake_minimum >= 100.0:
		issues.append(_issue(
			SEVERITY_WARNING,
			&"npc_talk_handshake_impossible",
			"The mutual handshake uses a strict favor comparison, so no NPC can exceed 100.",
			_child_path(path, "talk_handshake.minimum_favor")
		))
	for maximum_key in ["maximum_anger", "maximum_fear"]:
		if seeking_enabled and _number_or(
			acceptance.get(maximum_key, 100.0),
			100.0
		) <= 0.0:
			issues.append(_issue(
				SEVERITY_WARNING,
				&"social_acceptance_blocks_all_candidates",
				"A zero %s threshold rejects even a neutral relationship." % maximum_key,
				_child_path(path, "social_acceptance.%s" % maximum_key)
			))

	var memory_windows := {
		"recent_refusal_retry_delay_game_hours": MemoryPolicy.get_policy(
			MemoryPolicy.EVENT_CONVERSATION_REFUSED
		).get("maximum_lifetime_game_hours", 0.0),
		"recent_harm_social_delay_game_hours": MemoryPolicy.get_policy(
			MemoryPolicy.EVENT_HARMED_BY_ACTOR
		).get("maximum_lifetime_game_hours", 0.0),
		"recent_conversation_repeat_delay_game_hours": MemoryPolicy.get_policy(
			MemoryPolicy.EVENT_CONVERSATION_COMPLETED
		).get("maximum_lifetime_game_hours", 0.0),
	}
	for setting_name in memory_windows.keys():
		var retry_delay := _number_or(memory.get(setting_name, 0.0), 0.0)
		var maximum_memory_lifetime := float(memory_windows[setting_name])
		if retry_delay > maximum_memory_lifetime:
			issues.append(_issue(
				SEVERITY_WARNING,
				&"social_retry_exceeds_memory_lifetime",
				"The retry delay exceeds the backing memory's maximum lifetime and cannot be fully enforced.",
				_child_path(path, "memory.%s" % String(setting_name))
			))


static func _validate_bool(
	issues: Array[Dictionary],
	section: Dictionary,
	key: String,
	path: String
) -> void:
	if typeof(section.get(key, null)) != TYPE_BOOL:
		issues.append(_issue(
			SEVERITY_ERROR,
			&"invalid_boolean_social_setting",
			"Social setting '%s' must be a boolean." % key,
			_child_path(path, key)
		))


static func _validate_number_range(
	issues: Array[Dictionary],
	section: Dictionary,
	key: String,
	minimum: float,
	maximum: float,
	path: String
) -> void:
	var value: Variant = section.get(key, null)
	if not _is_finite_number(value):
		issues.append(_issue(
			SEVERITY_ERROR,
			&"invalid_numeric_social_setting",
			"Setting '%s' must be a finite number." % key,
			_child_path(path, key)
		))
		return
	var numeric := float(value)
	if numeric < minimum or numeric > maximum:
		issues.append(_issue(
			SEVERITY_ERROR,
			&"social_setting_out_of_range",
			"Setting '%s' must be between %s and %s." % [key, minimum, maximum],
			_child_path(path, key)
		))


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) in [TYPE_INT, TYPE_FLOAT]
		and is_finite(float(value))
	)


static func _number_or(value: Variant, fallback: float) -> float:
	return float(value) if _is_finite_number(value) else fallback


static func _bool_or(value: Variant, fallback: bool) -> bool:
	return value as bool if typeof(value) == TYPE_BOOL else fallback


static func _supported_feedback_categories() -> Dictionary:
	return {
		FeedbackCue.CATEGORY_INTENTION: true,
		FeedbackCue.CATEGORY_NEED: true,
		FeedbackCue.CATEGORY_SOCIAL: true,
		FeedbackCue.CATEGORY_PROBLEM: true,
		FeedbackCue.CATEGORY_MEMORY: true,
		FeedbackCue.CATEGORY_EMERGENCY: true,
	}


static func _is_lower_snake_identifier(value: String) -> bool:
	if value.is_empty() or value != value.to_lower():
		return false
	for index in range(value.length()):
		var character := value.unicode_at(index)
		var is_lower_letter := character >= 97 and character <= 122
		var is_digit := character >= 48 and character <= 57
		if not is_lower_letter and not is_digit and character != 95:
			return false
		if index == 0 and not is_lower_letter:
			return false
	return true


static func _first_property(
	source: Object,
	property_names: Array[StringName],
	fallback: Variant
) -> Variant:
	var available := {}
	for descriptor in source.get_property_list():
		available[StringName(String(descriptor.get("name", "")))] = true
	for property_name in property_names:
		if available.has(property_name):
			return source.get(property_name)
	return fallback


static func _child_path(parent: String, child: String) -> String:
	if parent.is_empty():
		return child
	if child.is_empty():
		return parent
	return "%s.%s" % [parent, child]


static func _issue(
	severity: StringName,
	code: StringName,
	message: String,
	path: String
) -> Dictionary:
	return {
		"severity": severity,
		"code": code,
		"message": message,
		"path": path,
	}
