extends "res://test/native_scene_tree_test.gd"

const MOM_PROFILE := preload("res://data/dialogue/mom_player_talk_dialogue_profile.tres")
const DAD_PROFILE := preload("res://data/dialogue/dad_player_talk_dialogue_profile.tres")
const MAID_PROFILE := preload("res://data/dialogue/maid_player_talk_dialogue_profile.tres")
const BOB_PROFILE := preload("res://data/dialogue/bob_player_talk_dialogue_profile.tres")
const GENERIC_PROFILE := preload("res://data/dialogue/generic_player_talk_dialogue_profile.tres")
const TalkInteractor := preload("res://player/scripts/npc_talk_interactor.gd")


func test_all_character_profiles_inherit_the_ten_gate_dating_ladder() -> void:
	for profile in [MOM_PROFILE, DAD_PROFILE, MAID_PROFILE, BOB_PROFILE, GENERIC_PROFILE]:
		assert_eq(profile.get_validation_error(), "", "%s profile should validate" % profile.speaker_name)
		for gate_index in NpcPlayerTalkDialogueProfile.FLIRT_LOVE_GATE_COUNT:
			var love := 0.0 if gate_index == 0 else float(gate_index * 10 + 1)
			var responses: Array[DialogueDefinition] = profile.get_flirt_love_gate_responses(love)
			assert_eq(responses.size(), 1, "%s gate %d should have one dialogue" % [profile.speaker_name, gate_index])


func test_love_boundaries_select_the_requested_successive_gates() -> void:
	var cases := [
		[0.0, 0], [10.99, 0], [11.0, 1], [20.99, 1],
		[21.0, 2], [30.99, 2], [31.0, 3], [40.99, 3],
		[41.0, 4], [50.99, 4], [51.0, 5], [60.99, 5],
		[61.0, 6], [70.99, 6], [71.0, 7], [80.99, 7],
		[81.0, 8], [90.99, 8], [91.0, 9], [100.0, 9],
	]
	for gate_case in cases:
		assert_eq(
			NpcPlayerTalkDialogueProfile.get_flirt_love_gate_index(float(gate_case[0])),
			int(gate_case[1]),
			"love %.2f should select gate %d" % [float(gate_case[0]), int(gate_case[1])]
		)


func test_each_gate_builds_four_shuffled_answers_with_all_outcomes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 81723
	var seen_orders: Dictionary = {}
	for gate_index in NpcPlayerTalkDialogueProfile.FLIRT_LOVE_GATE_COUNT:
		var love := 0.0 if gate_index == 0 else float(gate_index * 10 + 1)
		var definition := MOM_PROFILE.instantiate_response(
			NpcPlayerTalkDialogueProfile.CATEGORY_FLIRT,
			rng,
			&"",
			{},
			love
		)
		assert_not_null(definition, "gate %d should instantiate" % gate_index)
		if definition == null:
			continue
		var entry := definition.get_node(definition.entry_node_id)
		assert_not_null(entry, "gate %d should have an entry" % gate_index)
		if entry == null:
			continue
		assert_eq(entry.speaker_id, &"mom", "generic gate speaker should rebind to Mom")
		assert_eq(entry.choices.size(), 4, "gate %d should show four answers" % gate_index)
		var outcomes: Array[float] = []
		var order: Array[String] = []
		for choice in entry.choices:
			var delta: Dictionary = choice.consequences.get("player_talk_opinion_delta", {})
			outcomes.append(float(delta.get("love", 999.0)))
			order.append(String(choice.choice_id))
		outcomes.sort()
		assert_eq(outcomes, [-1.0, 0.0, 1.0, 2.0], "gate %d should retain all four love outcomes" % gate_index)
		seen_orders["|".join(order)] = true
	assert_true(seen_orders.size() > 1, "successive gates should shuffle answer placement")


func test_favor_modifies_flirt_love_exactly_once_at_the_boundaries() -> void:
	var cases := [
		[1.0, 0.0, -1.0],
		[0.0, 10.0, -2.0],
		[2.0, 11.0, 1.0],
		[1.0, 39.0, 0.0],
		[2.0, 40.0, 2.0],
		[1.0, 70.0, 1.0],
		[1.0, 71.0, 2.0],
		[2.0, 100.0, 4.0],
		[-1.0, 100.0, -1.0],
	]
	for modifier_case in cases:
		assert_eq(
			TalkInteractor.resolve_flirt_love_delta(
				float(modifier_case[0]),
				float(modifier_case[1])
			),
			float(modifier_case[2]),
			"base %.0f at favor %.0f should resolve to %.0f" % modifier_case
		)
