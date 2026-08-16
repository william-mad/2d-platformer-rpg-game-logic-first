extends Node

@export var bathroom_door_path: NodePath
@export var occupant_npc_id: StringName = &"mom"
@export var npc_group: StringName = &"npc"
@export var bathroom_is_positive_x: bool = true

var _bathroom_door: InteriorDoor
var _scene_root: Node
var _tracked_occupant: WeakRef
var _reconcile_queued: bool = false


func _ready() -> void:
	_scene_root = get_parent()
	_bathroom_door = get_node_or_null(bathroom_door_path) as InteriorDoor
	if _bathroom_door == null:
		push_warning("RealHome bathroom privacy requires an InteriorDoor.")
		return

	_bathroom_door.passage_completed.connect(_on_passage_completed)
	get_tree().node_added.connect(_on_scene_tree_node_added)
	get_tree().node_removed.connect(_on_scene_tree_node_removed)
	reconcile_from_live_state()
	_queue_reconcile()


func reconcile_from_live_state() -> void:
	_reconcile_queued = false
	if _bathroom_door == null or not is_instance_valid(_bathroom_door):
		return

	var occupant := _find_live_occupant()
	_tracked_occupant = weakref(occupant) if occupant != null else null
	_bathroom_door.allow_player = occupant == null or not _is_on_bathroom_side(occupant)


func _on_passage_completed(actor: Node, completed_door_id: StringName) -> void:
	if (
		_bathroom_door == null
		or completed_door_id != _bathroom_door.door_id
		or not _is_occupant(actor)
	):
		return

	var occupant := actor as Node2D
	_tracked_occupant = weakref(occupant)
	_bathroom_door.allow_player = not _is_on_bathroom_side(occupant)


func _on_scene_tree_node_added(node: Node) -> void:
	if (
		node is Node2D
		and node.has_method("get_npc_location_id")
		and _belongs_to_scene(node)
	):
		_queue_reconcile()


func _on_scene_tree_node_removed(node: Node) -> void:
	var tracked_occupant := (
		_tracked_occupant.get_ref() as Node
		if _tracked_occupant != null
		else null
	)
	if tracked_occupant == node or _is_occupant(node):
		_tracked_occupant = null
		_queue_reconcile()


func _queue_reconcile() -> void:
	if _reconcile_queued or not is_inside_tree():
		return
	_reconcile_queued = true
	call_deferred("reconcile_from_live_state")


func _find_live_occupant() -> Node2D:
	if not is_inside_tree():
		return null
	for candidate in get_tree().get_nodes_in_group(String(npc_group)):
		if _belongs_to_scene(candidate) and _is_occupant(candidate):
			return candidate as Node2D
	return null


func _belongs_to_scene(node: Node) -> bool:
	return (
		_scene_root != null
		and is_instance_valid(_scene_root)
		and (node == _scene_root or _scene_root.is_ancestor_of(node))
	)


func _is_occupant(actor: Node) -> bool:
	if actor == null or not is_instance_valid(actor) or not actor.has_method("get_npc_location_id"):
		return false
	return StringName(String(actor.call("get_npc_location_id"))) == occupant_npc_id


func _is_on_bathroom_side(actor: Node2D) -> bool:
	var is_positive_x := actor.global_position.x > _bathroom_door.global_position.x
	return is_positive_x == bathroom_is_positive_x
