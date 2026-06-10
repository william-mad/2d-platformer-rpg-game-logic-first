class_name PlayerNpcTalkInteractor extends Area2D

signal interaction_started(player: Node2D, npc: Node2D, interaction_id: StringName)
signal interaction_applied(player: Node2D, npc: Node2D, interaction_id: StringName)
signal interaction_blocked(player: Node2D, npc: Node2D, interaction_id: StringName, reason: String)

@export_group("Interaction")
@export var interaction_action: StringName = &"up"
@export var interaction_id: StringName = &"talk"
@export var cooldown_seconds: float = 0.35
@export var max_distance: float = 120.0
@export var npc_groups: Array[StringName] = [&"npc"]

@export_group("Future Gates")
@export var allowed_npc_ids: Array[StringName] = []
@export var required_npc_tags: Array[StringName] = []

@export_group("Effects")
@export var request_talk_state: bool = true
@export var skip_requested_talk_state_need_payout: bool = true
@export var stat_delta: Dictionary = {
	"favor": 2.0,
	"love": 1.0,
	"talk_need": -25.0,
	"boredom": -10.0
}
@export var set_values: Dictionary = {}
@export var evaluate_set_value_reactions: bool = false

var player: Node2D
var nearby_npcs: Array[Node2D] = []
var cooldown: float = 0.0


func _ready() -> void:
	# The parent player owns this Area2D and receives the Up-key interaction.
	player = get_parent() as Node2D
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(delta: float) -> void:
	# Polls the interaction action and throttles repeated presses with a cooldown.
	cooldown = maxf(cooldown - delta, 0.0)

	if cooldown > 0.0:
		return

	if not Input.is_action_just_pressed(interaction_action):
		return

	_try_talk_interaction()


func _try_talk_interaction() -> void:
	# Finds the closest valid NPC, checks future gates, then applies the interaction.
	var target_npc := _get_closest_npc()
	if target_npc == null:
		return

	var block_reason := _get_block_reason(target_npc)
	if not block_reason.is_empty():
		interaction_blocked.emit(player, target_npc, interaction_id, block_reason)
		return

	interaction_started.emit(player, target_npc, interaction_id)
	_apply_interaction_effects(target_npc)
	interaction_applied.emit(player, target_npc, interaction_id)
	cooldown = cooldown_seconds


func _apply_interaction_effects(target_npc: Node2D) -> void:
	# Applies exported stat effects and optionally asks the NPC to enter Talk.
	var receiver := _get_event_receiver(target_npc)
	var machine := _get_machine(target_npc)

	if receiver != null and not stat_delta.is_empty():
		receiver.call("apply_social_event", stat_delta, player, false)
	elif machine != null and not stat_delta.is_empty():
		machine.apply_value_delta(stat_delta, player)

	if machine != null:
		for value_key in set_values.keys():
			machine.set_value(
				StringName(String(value_key)),
				float(set_values[value_key]),
				player,
				evaluate_set_value_reactions
		)

		if request_talk_state:
			var talk_started := machine.request_talk(player)
			if talk_started and skip_requested_talk_state_need_payout:
				machine.mark_next_talk_need_payout_applied()

	if target_npc.has_method("on_player_npc_interaction"):
		target_npc.call("on_player_npc_interaction", player, interaction_id, stat_delta, set_values)


func _get_closest_npc() -> Node2D:
	# Chooses the nearest tracked NPC body inside max_distance.
	var closest: Node2D = null
	var closest_distance := INF

	for npc in nearby_npcs:
		if not _is_valid_npc_candidate(npc):
			continue

		var distance := player.global_position.distance_to(npc.global_position)
		if distance > max_distance:
			continue

		if distance < closest_distance:
			closest_distance = distance
			closest = npc

	return closest


func _is_valid_npc_candidate(candidate: Node2D) -> bool:
	# Rejects missing/self bodies and accepts only configured NPC groups.
	if player == null or not is_instance_valid(player):
		return false

	if candidate == null or not is_instance_valid(candidate):
		return false

	if candidate == player:
		return false

	for group_name in npc_groups:
		if candidate.is_in_group(String(group_name)):
			return true

	return false


func _get_block_reason(target_npc: Node2D) -> String:
	# Central place for future gates like NPC id, tags, schedule, or custom methods.
	if not _npc_id_is_allowed(target_npc):
		return "npc_id_not_allowed"

	if not _npc_has_required_tags(target_npc):
		return "missing_required_tags"

	if target_npc.has_method("can_receive_player_interaction"):
		if not bool(target_npc.call("can_receive_player_interaction", player, interaction_id)):
			return "npc_gate_rejected"

	return ""


func _npc_id_is_allowed(target_npc: Node2D) -> bool:
	# Optional whitelist for interactions that should only work with named NPCs.
	if allowed_npc_ids.is_empty():
		return true

	var npc_id := _get_npc_id(target_npc)
	for allowed_id in allowed_npc_ids:
		if String(allowed_id) == String(npc_id):
			return true

	return false


func _npc_has_required_tags(target_npc: Node2D) -> bool:
	# Optional tag requirement for interactions like "family only" or "worker only".
	if required_npc_tags.is_empty():
		return true

	for required_tag in required_npc_tags:
		if _npc_has_tag(target_npc, required_tag):
			continue

		return false

	return true


func _npc_has_tag(target_npc: Node2D, tag: StringName) -> bool:
	# Checks both Godot groups and SocialNpc's npc_tags metadata.
	var tag_text := String(tag)
	if target_npc.is_in_group(tag_text):
		return true

	if not target_npc.has_meta("npc_tags"):
		return false

	var npc_tags = target_npc.get_meta("npc_tags")
	if not (npc_tags is Array):
		return false

	for npc_tag in npc_tags:
		if String(npc_tag) == tag_text:
			return true

	return false


func _get_npc_id(target_npc: Node2D) -> StringName:
	# Uses stable location ids when available, otherwise falls back to node name.
	if target_npc.has_method("get_npc_location_id"):
		return StringName(String(target_npc.call("get_npc_location_id")))

	if target_npc.has_meta("npc_location_id"):
		return StringName(String(target_npc.get_meta("npc_location_id")))

	return StringName(String(target_npc.name))


func _get_event_receiver(target_npc: Node) -> Node:
	# SocialNpc receives social events directly; plain machines can receive value deltas.
	if target_npc.has_method("apply_social_event"):
		return target_npc

	return _get_machine(target_npc)


func _get_machine(target_npc: Node) -> NpcStateMachine:
	# Accepts either the state machine itself or an NPC body with a child machine.
	var machine := target_npc as NpcStateMachine
	if machine != null:
		return machine

	return target_npc.get_node_or_null("NpcStateMachine") as NpcStateMachine


func _on_body_entered(body: Node2D) -> void:
	# Tracks nearby bodies; filtering happens when the player presses the action.
	if nearby_npcs.has(body):
		return

	nearby_npcs.append(body)


func _on_body_exited(body: Node2D) -> void:
	# Removes bodies that leave the interaction area.
	nearby_npcs.erase(body)
