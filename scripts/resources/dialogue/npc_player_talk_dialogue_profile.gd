class_name NpcPlayerTalkDialogueProfile
extends Resource

const CATEGORY_CASUAL := &"casual"
const CATEGORY_COMPLIMENT := &"compliment"
const CATEGORY_FLIRT := &"flirt"
const CATEGORY_INSULT := &"insult"
const CATEGORY_GOSSIP := &"gossip"
const CHOICE_INSULT_ACTION_KEY := &"player_talk_insult_action"
const INSULT_ACTION_CHALLENGE_FIGHT := &"challenge_fight"
const DIALOGUE_GENDER_UNSPECIFIED := "unspecified"
const DIALOGUE_GENDER_MALE := "male"
const DIALOGUE_GENDER_FEMALE := "female"
const VALID_DIALOGUE_GENDERS: PackedStringArray = [
	DIALOGUE_GENDER_UNSPECIFIED,
	DIALOGUE_GENDER_MALE,
	DIALOGUE_GENDER_FEMALE,
]
const FLIRT_LOVE_GATE_COUNT := 10
const DEFAULT_FLIRT_LOVE_GATE_RESPONSES: Array[DialogueDefinition] = [
	preload("res://data/dialogue/dating_flirt_gate_00_10.tres"),
	preload("res://data/dialogue/dating_flirt_gate_11_20.tres"),
	preload("res://data/dialogue/dating_flirt_gate_21_30.tres"),
	preload("res://data/dialogue/dating_flirt_gate_31_40.tres"),
	preload("res://data/dialogue/dating_flirt_gate_41_50.tres"),
	preload("res://data/dialogue/dating_flirt_gate_51_60.tres"),
	preload("res://data/dialogue/dating_flirt_gate_61_70.tres"),
	preload("res://data/dialogue/dating_flirt_gate_71_80.tres"),
	preload("res://data/dialogue/dating_flirt_gate_81_90.tres"),
	preload("res://data/dialogue/dating_flirt_gate_91_100.tres"),
]
const INSULT_ANGER_GATE_COUNT := 10
const DEFAULT_INSULT_ANGER_GATE_RESPONSES: Array[DialogueDefinition] = [
	preload("res://data/dialogue/insult_anger_gate_00_09.tres"),
	preload("res://data/dialogue/insult_anger_gate_10_19.tres"),
	preload("res://data/dialogue/insult_anger_gate_20_29.tres"),
	preload("res://data/dialogue/insult_anger_gate_30_39.tres"),
	preload("res://data/dialogue/insult_anger_gate_40_49.tres"),
	preload("res://data/dialogue/insult_anger_gate_50_59.tres"),
	preload("res://data/dialogue/insult_anger_gate_60_69.tres"),
	preload("res://data/dialogue/insult_anger_gate_70_79.tres"),
	preload("res://data/dialogue/insult_anger_gate_80_89.tres"),
	preload("res://data/dialogue/insult_anger_gate_90_100.tres"),
]
const REQUIRED_CATEGORIES: Array[StringName] = [
	CATEGORY_CASUAL,
	CATEGORY_COMPLIMENT,
	CATEGORY_FLIRT,
	CATEGORY_INSULT,
	CATEGORY_GOSSIP,
]

@export var speaker_id: StringName = &"npc"
@export var speaker_name: String = "NPC"
## Stable, editor-visible identity used when dialogue text is instantiated.
## This is read only when opening a menu/response; it is never polled per frame.
@export_enum("unspecified", "male", "female") var dialogue_gender: String = (
	DIALOGUE_GENDER_UNSPECIFIED
)
@export var player_speaker_id: StringName = &"player"
@export var player_speaker_name: String = "Player"
@export var portrait: Texture2D
@export var portrait_animation: DialoguePortraitAnimationProfile
## Optional expression ladders selected once when a player-owned dialogue opens.
## Thresholds are ascending opinion values and must pair one-for-one with the
## textures. Empty ladders preserve the profile's normal portrait/animation.
@export var flirt_portrait_thresholds: PackedFloat32Array = PackedFloat32Array()
@export var flirt_portraits: Array[Texture2D] = []
@export var insult_portrait_thresholds: PackedFloat32Array = PackedFloat32Array()
@export var insult_portraits: Array[Texture2D] = []
@export var casual_responses: Array[DialogueDefinition] = []
@export var compliment_responses: Array[DialogueDefinition] = []
@export var flirt_responses: Array[DialogueDefinition] = []
## Optional character-specific replacements for the ten default dating gates.
## Empty profiles inherit the shared ladder, so every current and future NPC
## receives gated Flirt dialogue without duplicating the same resources.
## Custom responses are stored gate-by-gate. Set variants_per_gate above one to
## let a character randomly choose among several authored conversations at the
## same love level; selection happens only when dialogue opens.
@export_range(1, 8, 1) var flirt_love_variants_per_gate: int = 1
@export var flirt_love_gate_responses: Array[DialogueDefinition] = []
@export var insult_responses: Array[DialogueDefinition] = []
## Empty arrays inherit the shared ten-step ladder. A character can replace the
## complete array, disable escalation, or tune either Fight threshold here.
@export var insult_escalation_enabled: bool = true
@export var insult_anger_gate_responses: Array[DialogueDefinition] = []
@export var insult_fight_enabled: bool = true
@export_range(0.0, 100.0, 1.0) var insult_fight_challenge_anger: float = 80.0
@export_range(0.0, 100.0, 1.0) var insult_auto_fight_anger: float = 95.0
@export_range(0, 1000, 1) var insult_fight_priority: int = 94
@export var gossip_responses: Array[DialogueDefinition] = []
## Optional Talk-owned dialogue grouped by contextual purpose/reason. Reprimands
## currently use reason keys such as attacked_me, attacked_friend, and
## repeated_offense, plus authored event reasons such as false_monster_alarm.
## Other contextual Talk purposes can add their own profile fields later without
## teaching the Talk state about dialogue content.
@export var reprimand_responses: Dictionary = {}


func choose_response(
	category: StringName,
	rng: RandomNumberGenerator,
	previous_dialogue_id: StringName = &"",
	current_love: float = -1.0,
	current_anger: float = -1.0
) -> DialogueDefinition:
	var valid_responses: Array[DialogueDefinition] = []
	var response_pool := get_responses(category)
	if category == CATEGORY_FLIRT and current_love >= 0.0:
		response_pool = get_flirt_love_gate_responses(current_love)
	elif (
		category == CATEGORY_INSULT
		and insult_escalation_enabled
		and current_anger >= 0.0
	):
		response_pool = get_insult_anger_gate_responses(current_anger)
	for definition in response_pool:
		if definition == null or not definition.get_validation_error().is_empty():
			continue
		valid_responses.append(definition)
	if valid_responses.is_empty():
		return null

	var candidates := valid_responses
	if valid_responses.size() > 1 and previous_dialogue_id != &"":
		candidates = []
		for definition in valid_responses:
			if definition.dialogue_id != previous_dialogue_id:
				candidates.append(definition)
	if candidates.is_empty():
		return null

	var selection_rng := rng
	if selection_rng == null:
		selection_rng = RandomNumberGenerator.new()
		selection_rng.randomize()
	return candidates[selection_rng.randi_range(0, candidates.size() - 1)]


func instantiate_response(
	category: StringName,
	rng: RandomNumberGenerator,
	previous_dialogue_id: StringName = &"",
	context: Dictionary = {},
	current_love: float = -1.0,
	current_anger: float = -1.0
) -> DialogueDefinition:
	var template := choose_response(
		category,
		rng,
		previous_dialogue_id,
		current_love,
		current_anger
	)
	if template == null:
		return null
	var resolved_context := get_dialogue_identity_context()
	resolved_context.merge(context, true)
	var instance := template.instantiate_with_context(resolved_context)
	_rebind_generic_speaker_ids(instance)
	if (
		category == CATEGORY_INSULT
		and insult_escalation_enabled
		and current_anger >= 0.0
	):
		_remove_unavailable_insult_fight_choices(instance, current_anger)
	if (
		(category == CATEGORY_FLIRT and current_love >= 0.0)
		or (
			category == CATEGORY_INSULT
			and insult_escalation_enabled
			and current_anger >= 0.0
		)
	):
		_shuffle_first_choice_node(instance, rng)
	return instance


func get_flirt_love_gate_responses(current_love: float) -> Array[DialogueDefinition]:
	var gate_index := get_flirt_love_gate_index(current_love)
	if gate_index < 0:
		return []
	if flirt_love_gate_responses.is_empty():
		if gate_index >= DEFAULT_FLIRT_LOVE_GATE_RESPONSES.size():
			return []
		return [DEFAULT_FLIRT_LOVE_GATE_RESPONSES[gate_index]]

	var variants_per_gate := maxi(flirt_love_variants_per_gate, 1)
	var first_index := gate_index * variants_per_gate
	if first_index < 0 or first_index + variants_per_gate > flirt_love_gate_responses.size():
		return []
	var responses: Array[DialogueDefinition] = []
	for offset in variants_per_gate:
		responses.append(flirt_love_gate_responses[first_index + offset])
	return responses


static func get_flirt_love_gate_index(current_love: float) -> int:
	var safe_love := clampf(current_love, 0.0, 100.0)
	var whole_love := floori(safe_love)
	if whole_love <= 10:
		return 0
	return clampi(int(float(whole_love - 1) / 10.0), 1, FLIRT_LOVE_GATE_COUNT - 1)


func get_insult_anger_gate_responses(current_anger: float) -> Array[DialogueDefinition]:
	var gates := (
		insult_anger_gate_responses
		if not insult_anger_gate_responses.is_empty()
		else DEFAULT_INSULT_ANGER_GATE_RESPONSES
	)
	var gate_index := get_insult_anger_gate_index(current_anger)
	if gate_index < 0 or gate_index >= gates.size():
		return []
	return [gates[gate_index]]


static func get_insult_anger_gate_index(current_anger: float) -> int:
	return clampi(
		floori(clampf(current_anger, 0.0, 100.0) / 10.0),
		0,
		INSULT_ANGER_GATE_COUNT - 1
	)


func is_player_flirt_available(allowed_gender_tags: Array[StringName]) -> bool:
	return allowed_gender_tags.has(StringName(dialogue_gender))


func should_offer_insult_fight(current_anger: float) -> bool:
	return (
		insult_escalation_enabled
		and insult_fight_enabled
		and current_anger >= insult_fight_challenge_anger
	)


func should_auto_start_insult_fight(current_anger: float) -> bool:
	return (
		insult_escalation_enabled
		and insult_fight_enabled
		and current_anger >= insult_auto_fight_anger
	)


func get_dialogue_identity_context() -> Dictionary:
	match dialogue_gender:
		DIALOGUE_GENDER_FEMALE:
			return {
				"subject_pronoun": "she",
				"object_pronoun": "her",
				"possessive_adjective": "her",
				"possessive_pronoun": "hers",
				"reflexive_pronoun": "herself",
				"be_present": "is",
				"matter_present": "matters",
			}
		DIALOGUE_GENDER_MALE:
			return {
				"subject_pronoun": "he",
				"object_pronoun": "him",
				"possessive_adjective": "his",
				"possessive_pronoun": "his",
				"reflexive_pronoun": "himself",
				"be_present": "is",
				"matter_present": "matters",
			}
		_:
			return {
				"subject_pronoun": "they",
				"object_pronoun": "them",
				"possessive_adjective": "their",
				"possessive_pronoun": "theirs",
				"reflexive_pronoun": "themselves",
				"be_present": "are",
				"matter_present": "matter",
			}


func _remove_unavailable_insult_fight_choices(
	definition: DialogueDefinition,
	current_anger: float
) -> void:
	if definition == null or should_offer_insult_fight(current_anger):
		return
	var entry := definition.get_node(definition.entry_node_id)
	if entry == null:
		return
	for index in range(entry.choices.size() - 1, -1, -1):
		var choice := entry.choices[index]
		if (
			choice != null
			and StringName(String(choice.consequences.get(
				CHOICE_INSULT_ACTION_KEY,
				&""
			))) == INSULT_ACTION_CHALLENGE_FIGHT
		):
			entry.choices.remove_at(index)


func _rebind_generic_speaker_ids(definition: DialogueDefinition) -> void:
	if definition == null:
		return
	for dialogue_node in definition.nodes:
		if dialogue_node == null:
			continue
		if dialogue_node.speaker_id == &"npc":
			dialogue_node.speaker_id = speaker_id
		elif dialogue_node.speaker_id == &"player":
			dialogue_node.speaker_id = player_speaker_id


func _shuffle_first_choice_node(
	definition: DialogueDefinition,
	rng: RandomNumberGenerator
) -> void:
	if definition == null:
		return
	var choice_node := definition.get_node(definition.entry_node_id)
	var visited: Dictionary = {}
	while choice_node != null and choice_node.choices.is_empty():
		if choice_node.terminal or visited.has(choice_node.node_id):
			return
		visited[choice_node.node_id] = true
		choice_node = definition.get_node(choice_node.next_node_id)
	if choice_node == null or choice_node.choices.size() < 2:
		return
	var selection_rng := rng
	if selection_rng == null:
		selection_rng = RandomNumberGenerator.new()
		selection_rng.randomize()
	for index in range(choice_node.choices.size() - 1, 0, -1):
		var swap_index := selection_rng.randi_range(0, index)
		var held_choice := choice_node.choices[index]
		choice_node.choices[index] = choice_node.choices[swap_index]
		choice_node.choices[swap_index] = held_choice


func choose_reprimand_response(
	reason: StringName,
	rng: RandomNumberGenerator,
	previous_dialogue_id: StringName = &""
) -> DialogueDefinition:
	var valid_responses: Array[DialogueDefinition] = []
	for definition_value in get_reprimand_responses(reason):
		var definition := definition_value as DialogueDefinition
		if definition == null or not definition.get_validation_error().is_empty():
			continue
		valid_responses.append(definition)
	if valid_responses.is_empty():
		return null

	var candidates := valid_responses
	if valid_responses.size() > 1 and previous_dialogue_id != &"":
		candidates = []
		for definition in valid_responses:
			if definition.dialogue_id != previous_dialogue_id:
				candidates.append(definition)
	if candidates.is_empty():
		return null

	var selection_rng := rng
	if selection_rng == null:
		selection_rng = RandomNumberGenerator.new()
		selection_rng.randomize()
	return candidates[selection_rng.randi_range(0, candidates.size() - 1)]


func instantiate_reprimand_response(
	reason: StringName,
	rng: RandomNumberGenerator,
	previous_dialogue_id: StringName = &"",
	context: Dictionary = {}
) -> DialogueDefinition:
	var template := choose_reprimand_response(reason, rng, previous_dialogue_id)
	if template == null:
		return null
	var resolved_context := get_dialogue_identity_context()
	resolved_context.merge(context, true)
	return template.instantiate_with_context(resolved_context)


func get_reprimand_responses(reason: StringName) -> Array:
	if reprimand_responses.has(reason):
		var direct_value = reprimand_responses[reason]
		return direct_value if direct_value is Array else []
	var reason_text := String(reason)
	if reprimand_responses.has(reason_text):
		var text_value = reprimand_responses[reason_text]
		return text_value if text_value is Array else []
	return []


func has_reprimand_response(reason: StringName) -> bool:
	for definition_value in get_reprimand_responses(reason):
		var definition := definition_value as DialogueDefinition
		if definition != null and definition.get_validation_error().is_empty():
			return true
	return false


func get_responses(category: StringName) -> Array[DialogueDefinition]:
	match category:
		CATEGORY_CASUAL:
			return casual_responses
		CATEGORY_COMPLIMENT:
			return compliment_responses
		CATEGORY_FLIRT:
			return flirt_responses
		CATEGORY_INSULT:
			return insult_responses
		CATEGORY_GOSSIP:
			return gossip_responses
	return []


func get_speaker_names() -> Dictionary:
	return {
		speaker_id: speaker_name,
		player_speaker_id: player_speaker_name,
	}


func get_portrait_presentation(
	category: StringName = &"",
	current_love: float = -1.0,
	current_anger: float = -1.0
) -> Dictionary:
	var selected_portrait := portrait
	var selected_animation := portrait_animation
	var expression_portrait: Texture2D = null
	if category == CATEGORY_FLIRT and current_love >= 0.0:
		expression_portrait = _get_escalating_portrait(
			flirt_portrait_thresholds,
			flirt_portraits,
			current_love
		)
	elif category == CATEGORY_INSULT and current_anger >= 0.0:
		expression_portrait = _get_escalating_portrait(
			insult_portrait_thresholds,
			insult_portraits,
			current_anger
		)
	if expression_portrait != null:
		selected_portrait = expression_portrait
		# Base blink/talk overlays are pose-specific. A mismatched overlay is worse
		# than a static expressive portrait, so variants deliberately disable it.
		selected_animation = null
	return {
		"portrait": selected_portrait,
		"portrait_animation": selected_animation,
		"speaker_id": speaker_id,
		"player_speaker_id": player_speaker_id,
	}


func _get_escalating_portrait(
	thresholds: PackedFloat32Array,
	textures: Array[Texture2D],
	metric_value: float
) -> Texture2D:
	if thresholds.is_empty() or thresholds.size() != textures.size():
		return null
	var selected: Texture2D = null
	for index in thresholds.size():
		if metric_value < float(thresholds[index]):
			break
		selected = textures[index]
	return selected


func _get_portrait_ladder_validation_error(
	label: String,
	thresholds: PackedFloat32Array,
	textures: Array[Texture2D]
) -> String:
	if thresholds.is_empty() and textures.is_empty():
		return ""
	if thresholds.size() != textures.size() or textures.is_empty():
		return "player_talk_%s_portrait_ladder_size_invalid" % label
	for index in thresholds.size():
		var threshold := float(thresholds[index])
		if threshold < 0.0 or threshold > 100.0:
			return "player_talk_%s_portrait_threshold_invalid" % label
		if index > 0 and threshold <= float(thresholds[index - 1]):
			return "player_talk_%s_portrait_threshold_order_invalid" % label
		if textures[index] == null:
			return "player_talk_%s_portrait_missing" % label
	return ""


func get_validation_error() -> String:
	if String(speaker_id).strip_edges().is_empty():
		return "player_talk_speaker_id_empty"
	if speaker_name.strip_edges().is_empty():
		return "player_talk_speaker_name_empty"
	if not VALID_DIALOGUE_GENDERS.has(dialogue_gender):
		return "player_talk_dialogue_gender_invalid"
	if String(player_speaker_id).strip_edges().is_empty():
		return "player_talk_player_speaker_id_empty"
	if player_speaker_name.strip_edges().is_empty():
		return "player_talk_player_speaker_name_empty"
	if portrait_animation != null:
		var animation_error := portrait_animation.get_validation_error()
		if not animation_error.is_empty():
			return animation_error
	var flirt_portrait_error := _get_portrait_ladder_validation_error(
		"flirt",
		flirt_portrait_thresholds,
		flirt_portraits
	)
	if not flirt_portrait_error.is_empty():
		return flirt_portrait_error
	var insult_portrait_error := _get_portrait_ladder_validation_error(
		"insult",
		insult_portrait_thresholds,
		insult_portraits
	)
	if not insult_portrait_error.is_empty():
		return insult_portrait_error

	var dialogue_ids: Dictionary = {}
	for category in REQUIRED_CATEGORIES:
		var responses := get_responses(category)
		if responses.is_empty():
			return "player_talk_%s_responses_empty" % String(category)
		for definition in responses:
			if definition == null:
				return "player_talk_%s_response_missing" % String(category)
			var definition_error := definition.get_validation_error()
			if not definition_error.is_empty():
				return definition_error
			if dialogue_ids.has(definition.dialogue_id):
				return "player_talk_dialogue_id_duplicate"
			dialogue_ids[definition.dialogue_id] = true
	var dating_gates := (
		flirt_love_gate_responses
		if not flirt_love_gate_responses.is_empty()
		else DEFAULT_FLIRT_LOVE_GATE_RESPONSES
	)
	if flirt_love_variants_per_gate < 1:
		return "player_talk_flirt_love_variants_per_gate_invalid"
	var expected_dating_response_count := FLIRT_LOVE_GATE_COUNT
	if not flirt_love_gate_responses.is_empty():
		expected_dating_response_count *= flirt_love_variants_per_gate
	if dating_gates.size() != expected_dating_response_count:
		return "player_talk_flirt_love_gate_count_invalid"
	for gate_definition in dating_gates:
		if gate_definition == null:
			return "player_talk_flirt_love_gate_missing"
		var gate_error := gate_definition.get_validation_error()
		if not gate_error.is_empty():
			return gate_error
		if dialogue_ids.has(gate_definition.dialogue_id):
			return "player_talk_dialogue_id_duplicate"
		dialogue_ids[gate_definition.dialogue_id] = true
	var insult_gates := (
		insult_anger_gate_responses
		if not insult_anger_gate_responses.is_empty()
		else DEFAULT_INSULT_ANGER_GATE_RESPONSES
	)
	if insult_gates.size() != INSULT_ANGER_GATE_COUNT:
		return "player_talk_insult_anger_gate_count_invalid"
	for gate_definition in insult_gates:
		if gate_definition == null:
			return "player_talk_insult_anger_gate_missing"
		var gate_error := gate_definition.get_validation_error()
		if not gate_error.is_empty():
			return gate_error
		if dialogue_ids.has(gate_definition.dialogue_id):
			return "player_talk_dialogue_id_duplicate"
		dialogue_ids[gate_definition.dialogue_id] = true
	if insult_fight_challenge_anger > insult_auto_fight_anger:
		return "player_talk_insult_fight_threshold_order_invalid"
	for reason_value in reprimand_responses.keys():
		var reason := String(reason_value).strip_edges()
		if reason.is_empty():
			return "player_talk_reprimand_reason_empty"
		var responses = reprimand_responses[reason_value]
		if not (responses is Array) or responses.is_empty():
			return "player_talk_reprimand_%s_responses_empty" % reason
		for definition_value in responses:
			var definition := definition_value as DialogueDefinition
			if definition == null:
				return "player_talk_reprimand_%s_response_missing" % reason
			var definition_error := definition.get_validation_error()
			if not definition_error.is_empty():
				return definition_error
			if dialogue_ids.has(definition.dialogue_id):
				return "player_talk_dialogue_id_duplicate"
			dialogue_ids[definition.dialogue_id] = true
	return ""
