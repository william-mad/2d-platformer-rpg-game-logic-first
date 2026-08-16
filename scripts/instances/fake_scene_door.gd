extends Area2D

## A narrative door that represents an off-map room without loading another scene.
## Interaction is handed to a Player-owned session in the shared dialogue controller.

@export var dialogue_definition: DialogueDefinition
@export var speaker_names: Dictionary = {}
@export var player_group: StringName = &"player"
@export var interaction_action: StringName = &"up"
@export var interaction_priority: int = 35
@export var interaction_prompt: String = "Open door"
@export var locked_feedback_text: String = "Door locked."

var player_inside: bool = false
var active_player: Node2D


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	call_deferred("_refresh_overlapping_player")
	if dialogue_definition == null:
		push_warning("FakeSceneDoor requires a DialogueDefinition.")


func _exit_tree() -> void:
	if active_player != null and is_instance_valid(active_player):
		if active_player.has_method("unregister_interaction_candidate"):
			active_player.call("unregister_interaction_candidate", self)
	active_player = null
	player_inside = false


func can_interact(actor: Node) -> bool:
	return (
		monitoring
		and dialogue_definition != null
		and actor != null
		and is_instance_valid(actor)
		and actor == _get_active_player()
		and actor.is_in_group(String(player_group))
		and player_inside
	)


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	var actor_2d := actor as Node2D
	if actor_2d == null:
		return false
	LockedDoorCue.show(actor_2d, locked_feedback_text)
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if dialogue_controller == null or not dialogue_controller.has_method("begin_modal_dialogue"):
		return false
	var result = dialogue_controller.call(
		"begin_modal_dialogue", self, dialogue_definition, speaker_names, actor
	)
	return result is Dictionary and bool(result.get("accepted", false))


func get_interaction_action(_actor: Node) -> StringName:
	return interaction_action


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return interaction_prompt


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group(String(player_group)):
		return
	player_inside = true
	active_player = body
	if body.has_method("register_interaction_candidate"):
		body.call("register_interaction_candidate", self)


func _on_body_exited(body: Node2D) -> void:
	if not body.is_in_group(String(player_group)):
		return
	if body.has_method("unregister_interaction_candidate"):
		body.call("unregister_interaction_candidate", self)
	if body == active_player:
		active_player = null
	player_inside = false


func _refresh_overlapping_player() -> void:
	for body in get_overlapping_bodies():
		if body is Node2D and body.is_in_group(String(player_group)):
			_on_body_entered(body)
			return


func _get_active_player() -> Node2D:
	if active_player != null and is_instance_valid(active_player):
		return active_player
	for body in get_overlapping_bodies():
		var body_2d := body as Node2D
		if body_2d != null and body_2d.is_in_group(String(player_group)):
			return body_2d
	return null
