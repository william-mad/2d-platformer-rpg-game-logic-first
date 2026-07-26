class_name NpcStateTestPad extends Area2D

@export var target_npc_path: NodePath
@export var extra_target_npc_paths: Array[NodePath] = []
@export var stat_delta: Dictionary = {}
@export var set_values: Dictionary = {}
@export_range(-1.0, 100.0, 0.1) var set_player_relationship_fear: float = -1.0
@export var state_request: StringName = &""
@export var request_priority: int = 200

@export_group("Special Requests")
@export var move_target_path: NodePath
@export var move_arrive_state_name: StringName = &"Idle"
@export var request_talk_to_player: bool = false

@export_group("Interaction")
@export var interaction_action: StringName = &"up"
@export var requires_interaction: bool = true
@export var cooldown_seconds: float = 0.35
@export var interaction_priority: int = 20

@export_group("Visual")
@export var pad_label: String = ""
@export var pad_color: Color = Color(0.25, 0.55, 1.0, 0.35)

@onready var zone_visual: Polygon2D = get_node_or_null("%ZoneVisual") as Polygon2D
@onready var label: Label = get_node_or_null("%Label") as Label

var cooldown: float = 0.0
var nearby_players: Array[Node2D] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if zone_visual != null:
		zone_visual.color = pad_color

	if label != null:
		label.text = pad_label


func _process(delta: float) -> void:
	cooldown = maxf(cooldown - delta, 0.0)
	if requires_interaction:
		return

	var player := _get_player_inside()
	if player == null:
		return

	if cooldown > 0.0:
		return

	_apply_to_target(player)
	cooldown = cooldown_seconds


func can_interact(actor: Node) -> bool:
	var player := actor as Node2D
	return requires_interaction and player != null and nearby_players.has(player) and cooldown <= 0.0


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	_apply_to_target(actor as Node2D)
	cooldown = cooldown_seconds
	return true


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return pad_label if not pad_label.is_empty() else "Test interaction"


func _apply_to_target(player: Node2D) -> void:
	_apply_to_target_path(target_npc_path, player)

	for extra_target_path in extra_target_npc_paths:
		_apply_to_target_path(extra_target_path, player)


func _apply_to_target_path(target_path: NodePath, player: Node2D) -> void:
	# Pads can drive one NPC or many NPCs, which makes the test room useful for comparing rule variations.
	if String(target_path) == "":
		return

	var target_node := get_node_or_null(target_path)
	if target_node == null:
		return

	var machine := _get_machine(target_node)
	var receiver := _get_event_receiver(target_node)

	if machine != null:
		for value_key in set_values.keys():
			machine.set_value(StringName(String(value_key)), float(set_values[value_key]), player, false)

	if receiver != null and not stat_delta.is_empty():
		receiver.call("apply_social_event", stat_delta, player, false)
	if set_player_relationship_fear >= 0.0:
		var relationships := get_node_or_null("/root/Relationships")
		if relationships != null and relationships.has_method("set_fear"):
			relationships.call(
				"set_fear",
				target_node,
				player,
				set_player_relationship_fear,
				"test_pad"
			)

	if machine == null:
		return

	if String(move_target_path) != "":
		var move_target := get_node_or_null(move_target_path) as Node2D
		if move_target != null:
			machine.assign_move_target(move_target, move_arrive_state_name)

	if request_talk_to_player:
		machine.request_talk(player)

	if state_request != &"":
		machine.request_state(state_request, player, "test_pad", request_priority)


func _get_event_receiver(target_node: Node) -> Node:
	if target_node.has_method("apply_social_event"):
		return target_node

	return _get_machine(target_node)


func _get_machine(target_node: Node) -> NpcStateMachine:
	var machine := target_node as NpcStateMachine
	if machine != null:
		return machine

	return target_node.get_node_or_null("NpcStateMachine") as NpcStateMachine


func _get_player_inside() -> Node2D:
	for body in nearby_players.duplicate():
		if body == null or not is_instance_valid(body):
			nearby_players.erase(body)
			continue
		return body

	return null


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	if not nearby_players.has(body):
		nearby_players.append(body)
	if requires_interaction and body.has_method("register_interaction_candidate"):
		body.call("register_interaction_candidate", self)


func _on_body_exited(body: Node2D) -> void:
	nearby_players.erase(body)
	if body.has_method("unregister_interaction_candidate"):
		body.call("unregister_interaction_candidate", self)
