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


func test_gender_tags_drive_pronouns_and_flirt_availability() -> void:
	var allowed_tags: Array[StringName] = [&"female", &"unspecified"]
	assert_eq(MOM_PROFILE.dialogue_gender, "female", "Mom should carry the female tag")
	assert_eq(MAID_PROFILE.dialogue_gender, "female", "Maid should carry the female tag")
	assert_eq(DAD_PROFILE.dialogue_gender, "male", "Dad should carry the male tag")
	assert_eq(BOB_PROFILE.dialogue_gender, "male", "Bob should carry the male tag")
	assert_true(MOM_PROFILE.is_player_flirt_available(allowed_tags), "Mom should expose Flirt")
	assert_true(MAID_PROFILE.is_player_flirt_available(allowed_tags), "Maid should expose Flirt")
	assert_false(DAD_PROFILE.is_player_flirt_available(allowed_tags), "Dad should hide Flirt")
	assert_false(BOB_PROFILE.is_player_flirt_available(allowed_tags), "Bob should hide Flirt")

	var rng := RandomNumberGenerator.new()
	rng.seed = 91
	var female_dialogue := MOM_PROFILE.instantiate_response(
		NpcPlayerTalkDialogueProfile.CATEGORY_FLIRT,
		rng,
		&"",
		{},
		0.0
	)
	var male_dialogue := DAD_PROFILE.instantiate_response(
		NpcPlayerTalkDialogueProfile.CATEGORY_FLIRT,
		rng,
		&"",
		{},
		0.0
	)
	var female_choices := _joined_choice_text(female_dialogue)
	var male_choices := _joined_choice_text(male_dialogue)
	assert_true(female_choices.contains("her"), "female dialogue should resolve to her")
	assert_false(female_choices.contains("{object_pronoun}"), "female tokens should resolve")
	assert_true(male_choices.contains("him"), "male dialogue should resolve to him")
	assert_false(male_choices.contains("{object_pronoun}"), "male tokens should resolve")


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


func test_insult_anger_gates_have_escalation_and_deescalation() -> void:
	var boundary_cases := [
		[0.0, 0], [9.99, 0], [10.0, 1], [79.99, 7],
		[80.0, 8], [89.99, 8], [90.0, 9], [100.0, 9],
	]
	for gate_case in boundary_cases:
		assert_eq(
			NpcPlayerTalkDialogueProfile.get_insult_anger_gate_index(float(gate_case[0])),
			int(gate_case[1]),
			"anger %.2f should select gate %d" % [float(gate_case[0]), int(gate_case[1])]
		)

	var rng := RandomNumberGenerator.new()
	rng.seed = 730
	for gate_index in NpcPlayerTalkDialogueProfile.INSULT_ANGER_GATE_COUNT:
		var anger := float(gate_index * 10)
		var definition := MOM_PROFILE.instantiate_response(
			NpcPlayerTalkDialogueProfile.CATEGORY_INSULT,
			rng,
			&"",
			{},
			-1.0,
			anger
		)
		assert_not_null(definition, "anger gate %d should instantiate" % gate_index)
		if definition == null:
			continue
		var entry := definition.get_node(definition.entry_node_id)
		assert_not_null(entry, "anger gate %d should have an entry" % gate_index)
		if entry == null:
			continue
		var outcomes: Array[String] = []
		var has_fight_challenge := false
		for choice in entry.choices:
			var delta: Dictionary = choice.consequences.get("player_talk_opinion_delta", {})
			outcomes.append("%.0f/%.0f" % [
				float(delta.get("anger", 999.0)),
				float(delta.get("favor", 999.0)),
			])
			has_fight_challenge = (
				has_fight_challenge
				or StringName(choice.consequences.get("player_talk_insult_action", &""))
				== &"challenge_fight"
			)
		outcomes.sort()
		assert_eq(
			outcomes,
			["-2/-1", "-5/-1", "10/-4", "5/-3"],
			"anger gate %d should retain +10 through -5 choices" % gate_index
		)
		assert_eq(
			has_fight_challenge,
			gate_index >= 8,
			"Fight challenge should begin at the 80 anger gate"
		)
	assert_true(MOM_PROFILE.should_offer_insult_fight(80.0), "80 anger should accept a challenge")
	assert_false(MOM_PROFILE.should_auto_start_insult_fight(94.99), "under 95 should still use dialogue")
	assert_true(MOM_PROFILE.should_auto_start_insult_fight(95.0), "95 anger should start Fight immediately")
	var peaceful_override := MOM_PROFILE.duplicate(true) as NpcPlayerTalkDialogueProfile
	peaceful_override.insult_fight_enabled = false
	var overridden_dialogue := peaceful_override.instantiate_response(
		NpcPlayerTalkDialogueProfile.CATEGORY_INSULT,
		rng,
		&"",
		{},
		-1.0,
		80.0
	)
	var overridden_entry := overridden_dialogue.get_node(overridden_dialogue.entry_node_id)
	var overridden_has_challenge := false
	for choice in overridden_entry.choices:
		overridden_has_challenge = (
			overridden_has_challenge
			or StringName(choice.consequences.get("player_talk_insult_action", &""))
			== &"challenge_fight"
		)
	assert_false(overridden_has_challenge, "an NPC profile can disable Fight escalation")


func _joined_choice_text(definition: DialogueDefinition) -> String:
	if definition == null:
		return ""
	var entry := definition.get_node(definition.entry_node_id)
	if entry == null:
		return ""
	var texts := PackedStringArray()
	for choice in entry.choices:
		texts.append(choice.text)
	return " | ".join(texts)
