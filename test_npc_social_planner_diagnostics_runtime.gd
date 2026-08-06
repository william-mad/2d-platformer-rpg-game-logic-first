extends "res://test/native_scene_tree_test.gd"

const SocialPlanner = preload(
	"res://scripts/systems/npc_social_planner.gd"
)


class LocalLocations:
	extends Node

	func get_live_npc(_npc_id: String) -> Node:
		return null

	func get_current_scene_path() -> String:
		return "res://town.tscn"


func test_public_descriptor_keeps_both_candidate_keys() -> void:
	var fixture := _choose_with_three_candidates()
	var planner: RefCounted = fixture.planner
	var descriptor: Dictionary = planner.call("get_last_selection_descriptor")

	assert_true(
		descriptor.has("candidate_decisions"),
		"canonical candidate diagnostics remain public"
	)
	assert_true(
		descriptor.has("candidates"),
		"legacy candidates key remains public"
	)
	assert_eq(
		descriptor.candidate_decisions,
		descriptor.candidates,
		"legacy and canonical keys expose the same decisions"
	)
	assert_eq(
		descriptor.candidate_decisions.size(),
		3,
		"each evaluated candidate contributes one decision"
	)
	assert_eq(
		float(descriptor.evaluated_game_hours),
		17.25,
		"descriptor records its game-time evaluation point"
	)
	assert_true(
		int(descriptor.evaluated_at_usec) >= 0,
		"descriptor includes a monotonic creation timestamp"
	)


func test_public_descriptor_is_a_deep_defensive_copy() -> void:
	var fixture := _choose_with_three_candidates()
	var planner: RefCounted = fixture.planner
	var first: Dictionary = planner.call("get_last_selection_descriptor")
	var first_decisions: Array = first.candidate_decisions
	first_decisions[0]["allowed"] = false
	first_decisions[0]["total_score"] = -9999.0
	first_decisions.append({"candidate_id": "injected"})

	var second: Dictionary = planner.call("get_last_selection_descriptor")
	assert_eq(
		second.candidate_decisions.size(),
		3,
		"consumer array mutations do not affect stored diagnostics"
	)
	assert_true(
		bool(second.candidate_decisions[0].allowed),
		"consumer nested mutations do not affect stored decisions"
	)
	assert_true(
		float(second.candidate_decisions[0].total_score) > -9999.0,
		"nested score data is copied at the public boundary"
	)


func test_planner_accumulates_one_internal_candidate_array() -> void:
	var fixture := _choose_with_three_candidates()
	var planner: RefCounted = fixture.planner
	var internal: Dictionary = planner.get("_last_selection_descriptor")

	assert_true(
		internal.has("candidate_decisions"),
		"planner retains its canonical diagnostic array"
	)
	assert_false(
		internal.has("candidates"),
		"legacy alias is not maintained during candidate evaluation"
	)
	assert_eq(
		internal.candidate_decisions.size(),
		3,
		"internal diagnostics contain exactly one decision per candidate"
	)


func _choose_with_three_candidates() -> Dictionary:
	var planner := SocialPlanner.new()
	planner.begin_simulation_pass()
	var locations := add_child_autofree(LocalLocations.new()) as LocalLocations
	var seeker := _record()
	var records := {
		"seeker": seeker,
		"charlie": _record(),
		"alpha": _record(),
		"bravo": _record(),
	}
	var rng := RandomNumberGenerator.new()
	rng.seed = 19
	var selected: Dictionary = planner.choose_candidate(
		&"seeker",
		seeker,
		records,
		locations,
		{"priority": 60, "minimum_npc_favor": 10.0},
		null,
		null,
		rng,
		Callable(),
		null,
		17.25,
		{}
	)
	assert_eq(
		String(selected.get("target_id", "")),
		"alpha",
		"diagnostic changes do not alter deterministic selection"
	)
	return {
		"planner": planner,
		"locations": locations,
	}


func _record() -> Dictionary:
	return {
		"scene_path": "res://town.tscn",
		"previous_scene_path": "",
		"last_position": Vector2.ZERO,
		"activity": {},
		"pending_travel": {},
		"social_visit_target_id": "",
		"social_session_id": "",
		"node_state": {
			"social_stats": {
				"hp": 100.0,
				"disabled": 0.0,
				"knockout": 0.0,
				"talk_need": 90.0,
			},
		},
	}
