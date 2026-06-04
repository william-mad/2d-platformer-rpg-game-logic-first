class_name NpcStateTestPad extends Area2D

@export var target_npc_path: NodePath
@export var stat_delta: Dictionary = {}
@export var set_values: Dictionary = {}
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

@export_group("Visual")
@export var pad_label: String = ""
@export var pad_color: Color = Color(0.25, 0.55, 1.0, 0.35)

@onready var zone_visual: Polygon2D = get_node_or_null("%ZoneVisual") as Polygon2D
@onready var label: Label = get_node_or_null("%Label") as Label

var cooldown: float = 0.0


func _ready() -> void:
	if zone_visual != null:
		zone_visual.color = pad_color

	if label != null:
		label.text = pad_label


func _process(delta: float) -> void:
	cooldown = maxf(cooldown - delta, 0.0)

	var player := _get_player_inside()
	if player == null:
		return

	if cooldown > 0.0:
		return

	if requires_interaction and not Input.is_action_just_pressed(interaction_action):
		return

	_apply_to_target(player)
	cooldown = cooldown_seconds


func _apply_to_target(player: Node2D) -> void:
	var target_node := get_node_or_null(target_npc_path)
	if target_node == null:
		return

	var machine := _get_machine(target_node)
	var receiver := _get_event_receiver(target_node)

	if machine != null:
		for value_key in set_values.keys():
			machine.set_value(StringName(String(value_key)), float(set_values[value_key]), player, false)

	if receiver != null and not stat_delta.is_empty():
		receiver.call("apply_social_event", stat_delta, player, false)

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
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			return body

	return null
