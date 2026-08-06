extends "res://test/native_scene_tree_test.gd"

const Catalog = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_catalog.gd"
)
const Cue = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_cue.gd"
)
const Validator = preload(
	"res://scripts/systems/npc_behavior/npc_social_configuration_validator.gd"
)


class SocialSettingsSource:
	extends RefCounted

	var cross_scene_talk_enabled: bool = true
	var cross_scene_talk_need_threshold: float = 70.0
	var cross_scene_talk_priority: int = 60
	var cross_scene_minimum_npc_favor: float = 10.0
	var npc_talk_requires_mutual_favor: bool = true
	var npc_talk_handshake_minimum_favor: float = 10.0
	var npc_talk_handshake_priority: int = 70
	var npc_talk_refuse_lower_priority_tasks: bool = true
	var npc_talk_refusal_cooldown_seconds: float = 8.0
	var npc_social_acceptance_minimum_favor: float = 20.0
	var npc_social_acceptance_maximum_anger: float = 70.0
	var npc_social_acceptance_maximum_fear: float = 80.0
	var recent_refusal_retry_delay_game_hours: float = 0.25
	var recent_harm_social_delay_game_hours: float = 0.5
	var recent_conversation_repeat_delay_game_hours: float = 0.125


func test_current_defaults_and_catalog_are_valid() -> void:
	assert_true(
		Validator.validate_social_configuration(
			Validator.DEFAULT_SOCIAL_CONFIGURATION
		).is_empty(),
		"current social defaults produce no errors or warnings"
	)
	assert_true(
		Validator.validate_default_feedback_catalog().is_empty(),
		"the current feedback catalog satisfies its public contract"
	)
	assert_true(
		Validator.validate_state_machine_configuration(
			SocialSettingsSource.new(),
			"mom"
		).is_empty(),
		"legacy inspector property names map to the same valid settings"
	)


func test_actor_identity_rejects_scene_and_generated_ids() -> void:
	for unstable_id in [
		"/root/Town/Mom",
		"res://scenes/mom.tscn",
		"Town\\Mom",
		"instance:1234",
		"npc:9876",
		"@CharacterBody2D@41",
	]:
		assert_true(
			_has_code(
				Validator.validate_actor_id(unstable_id),
				&"unstable_actor_id"
			),
			"%s is not persistence-safe" % unstable_id
		)
	for stable_id in ["mom", "village_guard_2", "__player__"]:
		assert_true(
			Validator.validate_actor_id(stable_id).is_empty(),
			"%s is a supported authored identity" % stable_id
		)
	assert_true(
		_has_code(Validator.validate_actor_id(""), &"missing_stable_actor_id"),
		"an empty identity has a distinct actionable issue"
	)


func test_feedback_validation_checks_codes_text_and_shapes_without_requiring_icons() -> void:
	var valid_without_texture := {
		"social_wait": _cue_entry(&"social_wait"),
	}
	assert_true(
		Validator.validate_feedback_catalog(valid_without_texture, {}).is_empty(),
		"catalog icons are optional presentation enhancements"
	)
	assert_true(
		Validator.validate_feedback_catalog(
			valid_without_texture,
			{"social_wait": null}
		).is_empty(),
		"an explicit null icon mapping still uses text fallback"
	)
	assert_true(
		_has_code(
			Validator.validate_feedback_catalog(
				valid_without_texture,
				{"social_wait": "not a texture"}
			),
			&"invalid_feedback_icon_texture"
		),
		"present but malformed icon mappings are distinguished from missing icons"
	)

	var malformed := {
		"Bad Code": {
			"fallback_text": "",
			"icon_key": &"bad icon",
			"priority": 10,
			"duration_seconds": 2.0,
			"maximum_lifetime_seconds": 1.0,
			"cooldown_seconds": 0.0,
			"category": &"unsupported",
			"replace_policy": &"unsupported",
		},
	}
	var issues := Validator.validate_feedback_catalog(malformed)
	for expected_code in [
		&"invalid_feedback_cue_code",
		&"missing_feedback_fallback_text",
		&"invalid_feedback_icon_key",
		&"feedback_lifetime_shorter_than_duration",
		&"unsupported_feedback_category",
		&"unsupported_feedback_replace_policy",
	]:
		assert_true(_has_code(issues, expected_code), "reports %s" % expected_code)


func test_feedback_code_lookup_distinguishes_unknown_from_malformed() -> void:
	assert_true(
		Validator.validate_cue_code(&"social_need_high").is_empty(),
		"known catalog code validates"
	)
	assert_true(
		_has_code(
			Validator.validate_cue_code(&"future_social_cue"),
			&"unknown_feedback_cue_code"
		),
		"well-shaped but unregistered code is reported"
	)
	assert_true(
		_has_code(
			Validator.validate_cue_code(&"Future Cue"),
			&"invalid_feedback_cue_code"
		),
		"malformed code is reported before catalog lookup"
	)


func test_threshold_order_and_impossible_profiles_are_visible() -> void:
	var configuration := Validator.DEFAULT_SOCIAL_CONFIGURATION.duplicate(true)
	configuration.social_seeking.minimum_npc_favor = 100.0
	configuration.talk_handshake.minimum_favor = 90.0
	configuration.social_acceptance.maximum_anger = 0.0
	var issues := Validator.validate_social_configuration(configuration)
	assert_true(_has_code(issues, &"social_favor_threshold_order"))
	assert_true(_has_code(issues, &"npc_social_selection_impossible"))
	assert_true(_has_code(issues, &"social_acceptance_blocks_all_candidates"))
	assert_false(
		Validator.has_errors(issues),
		"internally consistent but self-defeating profiles are warnings"
	)


func test_ranges_types_and_memory_lifetime_mismatch_are_structured() -> void:
	var configuration := Validator.DEFAULT_SOCIAL_CONFIGURATION.duplicate(true)
	configuration.social_seeking.talk_need_threshold = 101.0
	configuration.social_seeking.enabled = "yes"
	configuration.memory.recent_harm_social_delay_game_hours = 3.0
	var issues := Validator.validate_social_configuration(
		configuration,
		"npc.mom.social"
	)
	assert_true(_has_code(issues, &"social_setting_out_of_range"))
	assert_true(_has_code(issues, &"invalid_boolean_social_setting"))
	assert_true(_has_code(issues, &"social_retry_exceeds_memory_lifetime"))
	assert_true(Validator.has_errors(issues), "invalid authored types/ranges are errors")
	var range_issue := _first_with_code(issues, &"social_setting_out_of_range")
	assert_true(
		String(range_issue.path).begins_with("npc.mom.social"),
		"every issue retains a caller-owned configuration path"
	)
	for issue in issues:
		for required_key in ["severity", "code", "message", "path"]:
			assert_true(issue.has(required_key), "issue includes %s" % required_key)


func test_partial_world_profiles_do_not_invent_live_threshold_mismatches() -> void:
	var partial_issues := Validator.validate_world_profile({
		"social_seeking": {
			"minimum_npc_favor": 25.0,
		},
	}, "mom")
	assert_false(
		_has_code(partial_issues, &"social_favor_threshold_order"),
		"a legacy world-only profile is not compared with invented handshake defaults"
	)
	var impossible_issues := Validator.validate_world_profile({
		"social_seeking": {
			"minimum_npc_favor": 100.0,
		},
	}, "mom")
	assert_true(
		_has_code(impossible_issues, &"npc_social_selection_impossible"),
		"intrinsically impossible offscreen selection remains visible"
	)
	assert_true(
		_has_code(
			Validator.validate_world_profile("invalid", "mom"),
			&"invalid_world_simulation_profile"
		),
		"malformed world profile roots are structured errors"
	)


func _cue_entry(icon_key: StringName) -> Dictionary:
	return {
		"fallback_text": "Waiting",
		"icon_key": icon_key,
		"priority": 20,
		"duration_seconds": 1.0,
		"maximum_lifetime_seconds": 2.0,
		"cooldown_seconds": 0.0,
		"category": Cue.CATEGORY_SOCIAL,
		"replace_policy": Cue.IGNORE_IF_DUPLICATE,
	}


func _has_code(issues: Array[Dictionary], code: StringName) -> bool:
	return not _first_with_code(issues, code).is_empty()


func _first_with_code(
	issues: Array[Dictionary],
	code: StringName
) -> Dictionary:
	for issue in issues:
		if StringName(String(issue.get("code", ""))) == code:
			return issue
	return {}
