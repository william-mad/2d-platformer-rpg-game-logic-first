extends SceneTree

const StateMachine = preload("res://scenes/creatures/npc/npc_state_machine.gd")
const LookForTalkTarget = preload(
	"res://scenes/creatures/npc/states/look_for_talk_target.gd"
)

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var npc := CharacterBody2D.new()
	npc.name = "descriptor_test_npc"
	npc.add_to_group("npc")
	var machine := StateMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	npc.add_child(machine)
	root.add_child(npc)
	await process_frame

	_test_legacy_social_setting_alias(machine)
	_test_validation_is_structured_and_warning_keys_are_stable(machine)
	_test_social_descriptors_are_timestamped(machine)
	_test_stamped_social_feedback_deduplicates_semantically(machine)
	_test_live_feedback_discards_heavy_candidate_arrays(machine)
	_test_memory_revision_clears_social_descriptors(machine)
	_test_talk_search_exit_clears_scoring_descriptor(machine)

	npc.queue_free()
	await process_frame
	if _failures.is_empty():
		print("NPC social descriptor freshness runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_legacy_social_setting_alias(machine: StateMachine) -> void:
	machine.set(&"cross_scene_talk_enabled", false)
	_expect(
		not machine.world_social_seeking_enabled,
		"legacy serialized setting updates the accurately named setting"
	)
	_expect(
		not bool(machine.get(&"cross_scene_talk_enabled")),
		"legacy setting remains readable during migration"
	)
	machine.world_social_seeking_enabled = true


func _test_validation_is_structured_and_warning_keys_are_stable(
	machine: StateMachine
) -> void:
	var issues := machine.refresh_social_configuration_validation()
	_expect(
		_has_issue_code(issues, &"missing_stable_actor_id"),
		"identity-free actors retain a structured stable-ID issue"
	)
	var first_issue := {
		"severity": &"error",
		"code": &"missing_stable_actor_id",
		"message": "A persistent social actor ID is required.",
		"path": "npc.@Node2D@1.actor_id",
	}
	var second_issue := first_issue.duplicate(true)
	second_issue["path"] = "npc.@Node2D@999.actor_id"
	_expect(
		StateMachine._get_social_configuration_warning_key(first_issue, true)
			== StateMachine._get_social_configuration_warning_key(second_issue, true),
		"generated legacy actor paths collapse to one stable warning key"
	)
	_expect(
		StateMachine._get_social_configuration_warning_key(first_issue, false)
			!= StateMachine._get_social_configuration_warning_key(second_issue, false),
		"authored missing-ID paths remain individually visible"
	)


func _test_social_descriptors_are_timestamped(machine: StateMachine) -> void:
	machine.select_ranked_autonomous_social_target([])
	var scoring := machine.get_social_scoring_debug_descriptor()
	_expect(scoring.has("evaluated_game_hours"), "live social scoring records game time")
	_expect(int(scoring.get("evaluated_at_usec", 0)) > 0, "live social scoring records real time")

	var requester := Node2D.new()
	requester.name = "requester"
	requester.add_to_group("npc")
	root.add_child(requester)
	machine.evaluate_npc_talk_request(requester)
	var acceptance := machine.get_social_acceptance_debug_descriptor()
	_expect(acceptance.has("evaluated_game_hours"), "talk acceptance records game time")
	_expect(int(acceptance.get("evaluated_at_usec", 0)) > 0, "talk acceptance records real time")
	requester.queue_free()


func _test_stamped_social_feedback_deduplicates_semantically(
	machine: StateMachine
) -> void:
	var emissions := {"count": 0}
	var on_feedback := func(
		policy_kind: StringName,
		descriptor: Dictionary
	) -> void:
		if policy_kind == &"social" and not descriptor.is_empty():
			emissions.count += 1
	machine.policy_feedback_changed.connect(on_feedback)
	var first := {
		"all_candidates_suppressed": true,
		"reason_code": &"no_social_target_due_to_recent_memory",
		"suppressed_count": 1,
		"suppressed_by_reason": {"recent_conversation_refusal": 1},
		"earliest_retry_game_hours": 999999.0,
		"remaining_retry_hours": 0.25,
		"evaluated_game_hours": 10.0,
		"evaluated_at_usec": 100,
		"simulation_pass_id": 7,
		"published_at_usec": 200,
	}
	machine.set_social_selection_feedback(first)
	var refreshed: Dictionary = first.duplicate(true)
	refreshed["remaining_retry_hours"] = 0.2
	refreshed["evaluated_game_hours"] = 10.05
	refreshed["evaluated_at_usec"] = 300
	refreshed["simulation_pass_id"] = 8
	refreshed["published_at_usec"] = 400
	machine.set_social_selection_feedback(refreshed)
	_expect(
		int(emissions.count) == 1,
		"new production freshness stamps do not re-emit an unchanged outcome"
	)
	var stored: Dictionary = machine.get("_social_selection_feedback")
	_expect(
		int(stored.get("published_at_usec", 0)) == 400,
		"silent semantic dedup still retains the newest freshness envelope"
	)
	refreshed["suppressed_count"] = 2
	machine.set_social_selection_feedback(refreshed)
	_expect(
		int(emissions.count) == 2,
		"a changed aggregate social outcome still emits feedback"
	)
	machine.policy_feedback_changed.disconnect(on_feedback)
	machine.set_social_selection_feedback({})


func _test_memory_revision_clears_social_descriptors(machine: StateMachine) -> void:
	machine.set_social_selection_feedback({
		"all_candidates_suppressed": true,
		"reason_code": &"no_social_target_due_to_recent_memory",
		"earliest_retry_game_hours": 999999.0,
		"evaluated_game_hours": 1.0,
		"evaluated_at_usec": Time.get_ticks_usec(),
	})
	_expect(
		not (machine.call("_get_active_social_selection_feedback") as Dictionary).is_empty(),
		"active social feedback is present before the memory revision"
	)
	machine.call("_on_memory_changed")
	_expect(
		(machine.call("_get_active_social_selection_feedback") as Dictionary).is_empty(),
		"memory revision clears social selection feedback"
	)
	_expect(
		machine.get_social_scoring_debug_descriptor().is_empty(),
		"memory revision clears social scoring diagnostics"
	)
	_expect(
		machine.get_social_acceptance_debug_descriptor().is_empty(),
		"memory revision clears social acceptance diagnostics"
	)


func _test_live_feedback_discards_heavy_candidate_arrays(machine: StateMachine) -> void:
	machine.set_social_selection_feedback({
		"all_candidates_suppressed": true,
		"reason_code": &"no_social_target_due_to_recent_memory",
		"earliest_retry_game_hours": 999999.0,
		"candidate_decisions": [{"candidate_id": "mom"}],
		"candidates": [{"candidate_id": "mom"}],
		"suppressed_by_reason": {"recent_conversation_refusal": 1},
	})
	var stored: Dictionary = machine.get("_social_selection_feedback")
	_expect(
		not stored.has("candidate_decisions") and not stored.has("candidates"),
		"live UI feedback does not retain the world's candidate arrays"
	)
	_expect(
		int((stored.get("suppressed_by_reason", {}) as Dictionary).get(
			"recent_conversation_refusal",
			0
		)) == 1,
		"compact feedback retains aggregate suppression diagnostics"
	)


func _test_talk_search_exit_clears_scoring_descriptor(
	machine: StateMachine
) -> void:
	machine.select_ranked_autonomous_social_target([])
	_expect(
		not machine.get_social_scoring_debug_descriptor().is_empty(),
		"talk search exposes scoring diagnostics while it is active"
	)
	var search_state := LookForTalkTarget.new()
	search_state.machine = machine
	search_state.exit()
	_expect(
		machine.get_social_scoring_debug_descriptor().is_empty(),
		"leaving talk search clears scoring diagnostics"
	)
	search_state.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _has_issue_code(
	issues: Array[Dictionary],
	code: StringName
) -> bool:
	for issue in issues:
		if StringName(String(issue.get("code", ""))) == code:
			return true
	return false
