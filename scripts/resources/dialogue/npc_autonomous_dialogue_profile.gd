class_name NpcAutonomousDialogueProfile
extends Resource

@export var speaker_id: StringName = &"npc"
@export var speaker_name: String = "NPC"
@export var player_speaker_id: StringName = &"player"
@export var player_speaker_name: String = "Player"
@export var portrait: Texture2D
@export var conversations: Array[DialogueDefinition] = []


func choose_conversation(
	rng: RandomNumberGenerator,
	previous_dialogue_id: StringName = &""
) -> DialogueDefinition:
	var valid_conversations: Array[DialogueDefinition] = []
	for definition in conversations:
		if definition == null or not definition.get_validation_error().is_empty():
			continue
		valid_conversations.append(definition)
	if valid_conversations.is_empty():
		return null

	var candidates := valid_conversations
	if valid_conversations.size() > 1 and previous_dialogue_id != &"":
		candidates = []
		for definition in valid_conversations:
			if definition.dialogue_id != previous_dialogue_id:
				candidates.append(definition)
	if candidates.is_empty():
		return null

	var selection_rng := rng
	if selection_rng == null:
		selection_rng = RandomNumberGenerator.new()
		selection_rng.randomize()
	return candidates[selection_rng.randi_range(0, candidates.size() - 1)]


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
		return "autonomous_dialogue_speaker_id_empty"
	if speaker_name.strip_edges().is_empty():
		return "autonomous_dialogue_speaker_name_empty"
	if String(player_speaker_id).strip_edges().is_empty():
		return "autonomous_dialogue_player_speaker_id_empty"
	if player_speaker_name.strip_edges().is_empty():
		return "autonomous_dialogue_player_speaker_name_empty"
	if conversations.is_empty():
		return "autonomous_dialogue_conversations_empty"

	var dialogue_ids: Dictionary = {}
	for definition in conversations:
		if definition == null:
			return "autonomous_dialogue_conversation_missing"
		var definition_error := definition.get_validation_error()
		if not definition_error.is_empty():
			return definition_error
		if dialogue_ids.has(definition.dialogue_id):
			return "autonomous_dialogue_id_duplicate"
		dialogue_ids[definition.dialogue_id] = true
	return ""
