class_name NpcPlayerTalkDialogueProfile
extends Resource

const CATEGORY_CASUAL := &"casual"
const CATEGORY_COMPLIMENT := &"compliment"
const CATEGORY_FLIRT := &"flirt"
const CATEGORY_INSULT := &"insult"
const CATEGORY_GOSSIP := &"gossip"
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
## Optional character-specific replacements for the ten default dating gates.
## Empty profiles inherit the shared ladder, so every current and future NPC
## receives gated Flirt dialogue without duplicating the same resources.
@export var flirt_love_gate_responses: Array[DialogueDefinition] = []
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
	previous_dialogue_id: StringName = &"",
	current_love: float = -1.0
) -> DialogueDefinition:
	var valid_responses: Array[DialogueDefinition] = []
	var response_pool := get_responses(category)
	if category == CATEGORY_FLIRT and current_love >= 0.0:
		response_pool = get_flirt_love_gate_responses(current_love)
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
	current_love: float = -1.0
) -> DialogueDefinition:
	var template := choose_response(
		category,
		rng,
		previous_dialogue_id,
		current_love
	)
	if template == null:
		return null
	var instance := template.instantiate_with_context(context)
	_rebind_generic_speaker_ids(instance)
	if category == CATEGORY_FLIRT and current_love >= 0.0:
		_shuffle_entry_choices(instance, rng)
	return instance


func get_flirt_love_gate_responses(current_love: float) -> Array[DialogueDefinition]:
	var gates := (
		flirt_love_gate_responses
		if not flirt_love_gate_responses.is_empty()
		else DEFAULT_FLIRT_LOVE_GATE_RESPONSES
	)
	var gate_index := get_flirt_love_gate_index(current_love)
	if gate_index < 0 or gate_index >= gates.size():
		return []
	return [gates[gate_index]]


static func get_flirt_love_gate_index(current_love: float) -> int:
	var safe_love := clampf(current_love, 0.0, 100.0)
	var whole_love := floori(safe_love)
	if whole_love <= 10:
		return 0
	return clampi(int(float(whole_love - 1) / 10.0), 1, FLIRT_LOVE_GATE_COUNT - 1)


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


func _shuffle_entry_choices(
	definition: DialogueDefinition,
	rng: RandomNumberGenerator
) -> void:
	if definition == null:
		return
	var entry := definition.get_node(definition.entry_node_id)
	if entry == null or entry.choices.size() < 2:
		return
	var selection_rng := rng
	if selection_rng == null:
		selection_rng = RandomNumberGenerator.new()
		selection_rng.randomize()
	for index in range(entry.choices.size() - 1, 0, -1):
		var swap_index := selection_rng.randi_range(0, index)
		var held_choice := entry.choices[index]
		entry.choices[index] = entry.choices[swap_index]
		entry.choices[swap_index] = held_choice


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
	var dating_gates := (
		flirt_love_gate_responses
		if not flirt_love_gate_responses.is_empty()
		else DEFAULT_FLIRT_LOVE_GATE_RESPONSES
	)
	if dating_gates.size() != FLIRT_LOVE_GATE_COUNT:
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
