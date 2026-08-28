class_name NpcPlayerTalkDialogueProfile
extends Resource

const CATEGORY_CASUAL := &"casual"
const CATEGORY_COMPLIMENT := &"compliment"
const CATEGORY_FLIRT := &"flirt"
const CATEGORY_INSULT := &"insult"
const CATEGORY_GOSSIP := &"gossip"
const REQUIRED_CATEGORIES: Array[StringName] = [
	CATEGORY_CASUAL,
	CATEGORY_COMPLIMENT,
	CATEGORY_FLIRT,
	CATEGORY_INSULT,
	CATEGORY_GOSSIP,
]

@export var speaker_id: StringName = &"npc"
@export var speaker_name: String = "NPC"
@export var player_speaker_id: StringName = &"player"
@export var player_speaker_name: String = "Player"
@export var portrait: Texture2D
@export var portrait_animation: DialoguePortraitAnimationProfile
@export var casual_responses: Array[DialogueDefinition] = []
@export var compliment_responses: Array[DialogueDefinition] = []
@export var flirt_responses: Array[DialogueDefinition] = []
@export var insult_responses: Array[DialogueDefinition] = []
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
	previous_dialogue_id: StringName = &""
) -> DialogueDefinition:
	var valid_responses: Array[DialogueDefinition] = []
	for definition in get_responses(category):
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
	context: Dictionary = {}
) -> DialogueDefinition:
	var template := choose_response(category, rng, previous_dialogue_id)
	return template.instantiate_with_context(context) if template != null else null


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
	return template.instantiate_with_context(context) if template != null else null


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


func get_portrait_presentation() -> Dictionary:
	return {
		"portrait": portrait,
		"portrait_animation": portrait_animation,
		"speaker_id": speaker_id,
		"player_speaker_id": player_speaker_id,
	}


func get_validation_error() -> String:
	if String(speaker_id).strip_edges().is_empty():
		return "player_talk_speaker_id_empty"
	if speaker_name.strip_edges().is_empty():
		return "player_talk_speaker_name_empty"
	if String(player_speaker_id).strip_edges().is_empty():
		return "player_talk_player_speaker_id_empty"
	if player_speaker_name.strip_edges().is_empty():
		return "player_talk_player_speaker_name_empty"
	if portrait_animation != null:
		var animation_error := portrait_animation.get_validation_error()
		if not animation_error.is_empty():
			return animation_error

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
