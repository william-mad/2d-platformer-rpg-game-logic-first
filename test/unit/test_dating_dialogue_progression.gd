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
			var expected_count: int = (
				profile.flirt_love_variants_per_gate
				if not profile.flirt_love_gate_responses.is_empty()
				else 1
			)
			assert_eq(
				responses.size(),
				expected_count,
				"%s gate %d should expose its configured variants" % [profile.speaker_name, gate_index]
			)


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


func test_mom_has_four_distinct_conversations_at_every_love_gate() -> void:
	assert_eq(MOM_PROFILE.flirt_love_variants_per_gate, 4, "Mom should configure four variants")
	var conversations_with_three_prompt_lines := 0
	for gate_index in NpcPlayerTalkDialogueProfile.FLIRT_LOVE_GATE_COUNT:
		var love := 0.0 if gate_index == 0 else float(gate_index * 10 + 1)
		var responses := MOM_PROFILE.get_flirt_love_gate_responses(love)
		assert_eq(responses.size(), 4, "Mom gate %d should have four conversations" % gate_index)
		var dialogue_ids: Dictionary = {}
		var opening_lines: Dictionary = {}
		var gate_answer_texts: Dictionary = {}
		for definition in responses:
			assert_eq(definition.get_validation_error(), "", "Mom dialogue should validate")
			dialogue_ids[definition.dialogue_id] = true
			var entry := definition.get_node(definition.entry_node_id)
			if entry != null:
				opening_lines[entry.speaker_text] = true
			var choice_node := _find_choice_node(definition)
			assert_not_null(choice_node, "Mom dialogue should reach an answer node")
			if choice_node == null:
				continue
			assert_eq(choice_node.choices.size(), 4, "each Mom conversation should have four answers")
			var answer_texts: Dictionary = {}
			var outcomes: Array[float] = []
			for choice in choice_node.choices:
				answer_texts[choice.text] = true
				gate_answer_texts[choice.text] = true
				var delta: Dictionary = choice.consequences.get("player_talk_opinion_delta", {})
				outcomes.append(float(delta.get("love", 999.0)))
			outcomes.sort()
			assert_eq(answer_texts.size(), 4, "all four player answers should be distinct")
			assert_eq(outcomes, [-1.0, 0.0, 1.0, 2.0], "answers should retain all outcomes")
			if _count_prompt_lines(definition) >= 3:
				conversations_with_three_prompt_lines += 1
		assert_eq(dialogue_ids.size(), 4, "Mom gate %d should use four unique resources" % gate_index)
		assert_eq(opening_lines.size(), 4, "Mom gate %d should have four unique openings" % gate_index)
		assert_eq(gate_answer_texts.size(), 16, "Mom gate %d should have 16 unique answers" % gate_index)
	assert_true(
		conversations_with_three_prompt_lines >= 10,
		"at least one conversation per gate should build memory before its answers"
	)


func test_mom_random_selection_avoids_immediate_conversation_repeats() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42091
	for gate_index in NpcPlayerTalkDialogueProfile.FLIRT_LOVE_GATE_COUNT:
		var love := 0.0 if gate_index == 0 else float(gate_index * 10 + 1)
		var previous_id: StringName = &""
		var seen_ids: Dictionary = {}
		for selection_index in 8:
			var definition := MOM_PROFILE.instantiate_response(
				NpcPlayerTalkDialogueProfile.CATEGORY_FLIRT,
				rng,
				previous_id,
				{},
				love
			)
			assert_not_null(definition, "Mom gate %d selection should instantiate" % gate_index)
			if definition == null:
				continue
			if previous_id != &"":
				assert_true(
					definition.dialogue_id != previous_id,
					"Mom gate %d should not immediately repeat a conversation" % gate_index
				)
			previous_id = definition.dialogue_id
			seen_ids[previous_id] = true
		assert_true(seen_ids.size() >= 3, "Mom gate %d should randomize its pool" % gate_index)


func test_mom_expression_portraits_follow_love_and_anger_once_per_dialogue() -> void:
	var neutral := MOM_PROFILE.get_portrait_presentation()
	assert_eq(neutral.get("portrait"), MOM_PROFILE.portrait, "normal Talk keeps Mom's base portrait")
	assert_eq(
		neutral.get("portrait_animation"),
		MOM_PROFILE.portrait_animation,
		"normal Talk keeps Mom's blink and mouth animation"
	)

	var love_cases := [
		[0.0, "mom_love_00_20.png"],
		[20.99, "mom_love_00_20.png"],
		[21.0, "mom_love_21_40.png"],
		[41.0, "mom_love_41_60.png"],
		[61.0, "mom_love_61_80.png"],
		[81.0, "mom_love_81_100.png"],
		[100.0, "mom_love_81_100.png"],
	]
	for portrait_case in love_cases:
		var presentation := MOM_PROFILE.get_portrait_presentation(
			NpcPlayerTalkDialogueProfile.CATEGORY_FLIRT,
			float(portrait_case[0]),
			-1.0
		)
		var texture := presentation.get("portrait") as Texture2D
		assert_not_null(texture, "love %.2f should have a Mom portrait" % float(portrait_case[0]))
		if texture != null:
			assert_true(
				texture.resource_path.ends_with(String(portrait_case[1])),
				"love %.2f should select %s" % portrait_case
			)
		assert_null(
			presentation.get("portrait_animation"),
			"expression portraits should not reuse misaligned base overlays"
		)

	var anger_cases := [
		[0.0, "mom_anger_00_19.png"],
		[19.99, "mom_anger_00_19.png"],
		[20.0, "mom_anger_20_39.png"],
		[40.0, "mom_anger_40_59.png"],
		[60.0, "mom_anger_60_79.png"],
		[80.0, "mom_anger_80_89.png"],
		[90.0, "mom_anger_90_100.png"],
		[94.99, "mom_anger_90_100.png"],
	]
	for portrait_case in anger_cases:
		var presentation := MOM_PROFILE.get_portrait_presentation(
			NpcPlayerTalkDialogueProfile.CATEGORY_INSULT,
			-1.0,
			float(portrait_case[0])
		)
		var texture := presentation.get("portrait") as Texture2D
		assert_not_null(texture, "anger %.2f should have a Mom portrait" % float(portrait_case[0]))
		if texture != null:
			assert_true(
				texture.resource_path.ends_with(String(portrait_case[1])),
				"anger %.2f should select %s" % portrait_case
			)
		assert_null(
			presentation.get("portrait_animation"),
			"anger portraits should not reuse misaligned base overlays"
		)


func test_maid_expression_portraits_prioritize_the_love_ladder() -> void:
	var love_cases := [
		[0.0, "maid_love_00_10.png"],
		[10.99, "maid_love_00_10.png"],
		[11.0, "maid_love_11_20.png"],
		[21.0, "maid_love_21_40.png"],
		[41.0, "maid_love_41_60.png"],
		[61.0, "maid_love_61_80.png"],
		[81.0, "maid_love_81_90.png"],
		[91.0, "maid_love_91_100.png"],
		[100.0, "maid_love_91_100.png"],
	]
	for portrait_case in love_cases:
		var presentation := MAID_PROFILE.get_portrait_presentation(
			NpcPlayerTalkDialogueProfile.CATEGORY_FLIRT,
			float(portrait_case[0]),
			-1.0
		)
		var texture := presentation.get("portrait") as Texture2D
		assert_not_null(texture, "love %.2f should have a Maid portrait" % float(portrait_case[0]))
		if texture != null:
			assert_true(
				texture.resource_path.ends_with(String(portrait_case[1])),
				"love %.2f should select %s" % portrait_case
			)

	var anger_cases := [
		[0.0, "maid_anger_00_29.png"],
		[29.99, "maid_anger_00_29.png"],
		[30.0, "maid_anger_30_59.png"],
		[60.0, "maid_anger_60_79.png"],
		[80.0, "maid_anger_80_100.png"],
		[94.99, "maid_anger_80_100.png"],
	]
	for portrait_case in anger_cases:
		var presentation := MAID_PROFILE.get_portrait_presentation(
			NpcPlayerTalkDialogueProfile.CATEGORY_INSULT,
			-1.0,
			float(portrait_case[0])
		)
		var texture := presentation.get("portrait") as Texture2D
		assert_not_null(texture, "anger %.2f should have a Maid portrait" % float(portrait_case[0]))
		if texture != null:
			assert_true(
				texture.resource_path.ends_with(String(portrait_case[1])),
				"anger %.2f should select %s" % portrait_case
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
		var choice_node := _find_choice_node(definition)
		assert_not_null(choice_node, "gate %d should reach an answer node" % gate_index)
		if choice_node == null:
			continue
		assert_eq(choice_node.speaker_id, &"mom", "Mom should own the answer prompt")
		assert_eq(choice_node.choices.size(), 4, "gate %d should show four answers" % gate_index)
		var outcomes: Array[float] = []
		var order: Array[String] = []
		for choice in choice_node.choices:
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


func _find_choice_node(definition: DialogueDefinition) -> DialogueNode:
	if definition == null:
		return null
	var current := definition.get_node(definition.entry_node_id)
	var visited: Dictionary = {}
	while current != null and current.choices.is_empty() and not current.terminal:
		if visited.has(current.node_id):
			return null
		visited[current.node_id] = true
		current = definition.get_node(current.next_node_id)
	return current if current != null and not current.choices.is_empty() else null


func _count_prompt_lines(definition: DialogueDefinition) -> int:
	if definition == null:
		return 0
	var current := definition.get_node(definition.entry_node_id)
	var visited: Dictionary = {}
	var line_count := 0
	while current != null:
		if visited.has(current.node_id):
			break
		visited[current.node_id] = true
		line_count += 1
		if not current.choices.is_empty() or current.terminal:
			break
		current = definition.get_node(current.next_node_id)
	return line_count


func _joined_choice_text(definition: DialogueDefinition) -> String:
	var choice_node := _find_choice_node(definition)
	if choice_node == null:
		return ""
	var texts := PackedStringArray()
	for choice in choice_node.choices:
		texts.append(choice.text)
	return " | ".join(texts)
