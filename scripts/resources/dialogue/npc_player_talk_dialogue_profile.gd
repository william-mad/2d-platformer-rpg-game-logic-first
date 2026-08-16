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
@export var casual_responses: Array[DialogueDefinition] = []
@export var compliment_responses: Array[DialogueDefinition] = []
@export var flirt_responses: Array[DialogueDefinition] = []
@export var insult_responses: Array[DialogueDefinition] = []
@export var gossip_responses: Array[DialogueDefinition] = []


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
	return ""
