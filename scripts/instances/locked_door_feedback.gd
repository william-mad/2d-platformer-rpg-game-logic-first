extends Node

## Interaction adapter for a door that currently denies the Player.
## It owns presentation only; the configured door remains the access authority.

@export var door_path: NodePath
@export var interaction_area_path: NodePath
@export var player_group: StringName = &"player"
@export var interaction_action: StringName = &"up"
@export var interaction_priority: int = 40
@export var feedback_text: String = "Door locked."

@export_group("Floating Text")
@export var feedback_offset: Vector2 = Vector2(0.0, -142.0)
@export var feedback_size: Vector2 = Vector2(160.0, 28.0)
@export var feedback_color: Color = Color(1.0, 0.82, 0.42, 1.0)
@export_range(0.1, 5.0, 0.05, "suffix:s") var feedback_seconds: float = 0.9
@export_range(0.0, 4.0, 0.05, "suffix:s") var feedback_hold_seconds: float = 0.15
@export_range(0.0, 128.0, 1.0, "suffix:px") var feedback_rise: float = 32.0

var _door: Node
var _interaction_area: Area2D
var _tracked_players: Dictionary = {}


func _ready() -> void:
	_door = get_node_or_null(door_path)
	_interaction_area = get_node_or_null(interaction_area_path) as Area2D
	if _door == null or _interaction_area == null:
		push_warning("LockedDoorFeedback requires a door and an Area2D interaction area.")
		return

	_interaction_area.body_entered.connect(_on_interaction_area_body_entered)
	_interaction_area.body_exited.connect(_on_interaction_area_body_exited)
	call_deferred("_sync_overlapping_players")


func _exit_tree() -> void:
	for player_ref_value in _tracked_players.values():
		var player_ref := player_ref_value as WeakRef
		var player := player_ref.get_ref() as Node if player_ref != null else null
		if player != null and player.has_method("unregister_interaction_candidate"):
			player.call("unregister_interaction_candidate", self)
	_tracked_players.clear()


func can_interact(actor: Node) -> bool:
	return _is_tracked_player(actor) and _door_is_locked_for(actor)


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	var actor_2d := actor as Node2D
	if actor_2d == null:
		return false
	_show_locked_feedback(actor_2d)
	return true


func get_interaction_action(_actor: Node) -> StringName:
	return interaction_action


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return feedback_text


func get_interaction_position(_actor: Node) -> Vector2:
	var door_2d := _door as Node2D
	return door_2d.global_position if door_2d != null else Vector2.ZERO


func _sync_overlapping_players() -> void:
	if _interaction_area == null or not is_instance_valid(_interaction_area):
		return
	for body in _interaction_area.get_overlapping_bodies():
		_on_interaction_area_body_entered(body)


func _on_interaction_area_body_entered(body: Node2D) -> void:
	if not body.is_in_group(String(player_group)):
		return
	var body_id := int(body.get_instance_id())
	var existing_ref := _tracked_players.get(body_id) as WeakRef
	if existing_ref != null and existing_ref.get_ref() == body:
		return
	_tracked_players[body_id] = weakref(body)
	if body.has_method("register_interaction_candidate"):
		body.call("register_interaction_candidate", self)


func _on_interaction_area_body_exited(body: Node2D) -> void:
	if not body.is_in_group(String(player_group)):
		return
	if body.has_method("unregister_interaction_candidate"):
		body.call("unregister_interaction_candidate", self)
	_tracked_players.erase(int(body.get_instance_id()))


func _is_tracked_player(actor: Node) -> bool:
	if actor == null or not is_instance_valid(actor):
		return false
	var actor_ref := _tracked_players.get(int(actor.get_instance_id())) as WeakRef
	return actor_ref != null and actor_ref.get_ref() == actor


func _door_is_locked_for(actor: Node) -> bool:
	var interior_door := _door as InteriorDoor
	if interior_door != null:
		return not interior_door.can_actor_use(actor)

	var travel_door := _door as NpcTravelDoor
	if travel_door == null or not actor.is_in_group(String(travel_door.player_group)):
		return false
	if travel_door.owner_ids.is_empty():
		return false
	for owner_id in travel_door.owner_ids:
		if String(owner_id) == String(travel_door.player_owner_id):
			return false
	return true


func _show_locked_feedback(actor: Node2D) -> void:
	LockedDoorCue.show_custom(
		actor,
		feedback_text,
		feedback_offset,
		feedback_size,
		feedback_color,
		feedback_seconds,
		feedback_hold_seconds,
		feedback_rise
	)
