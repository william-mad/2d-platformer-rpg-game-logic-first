class_name NpcInventoryDropComponent
extends Node

@export var loot_container_scene: PackedScene = preload("res://scenes/items/world_loot_container.tscn")

var _drop_completed: bool = false
var _drop_in_progress: bool = false
var _spawned_loot: WorldLootContainer


func drop_inventory_on_death() -> bool:
	if _drop_completed:
		return true
	if _drop_in_progress:
		return false
	_drop_in_progress = true

	var owner_entity := get_parent() as Node2D
	var npc_id := _get_owner_id(owner_entity)
	if owner_entity == null or not _is_canonical_live_owner(owner_entity, npc_id):
		push_warning("Rejected inventory death drop from non-canonical NPC '%s'." % String(npc_id))
		_drop_in_progress = false
		return false
	var inventory = owner_entity.call("get_inventory") as InventoryModel
	if inventory == null:
		push_error("NPC '%s' cannot drop inventory because its live inventory is missing." % String(npc_id))
		_drop_in_progress = false
		return false

	if inventory.get_all_quantities().is_empty():
		_capture_empty_record(npc_id)
		_drop_completed = true
		_drop_in_progress = false
		return true
	if loot_container_scene == null:
		push_error("NPC '%s' inventory death drop failed: loot container scene is missing." % String(npc_id))
		_drop_in_progress = false
		return false

	var loot := loot_container_scene.instantiate() as WorldLootContainer
	if loot == null:
		push_error("NPC '%s' inventory death drop failed: loot container could not be instantiated." % String(npc_id))
		_drop_in_progress = false
		return false
	var initialization := loot.initialize_from_inventory(inventory, npc_id)
	if not initialization.success:
		push_error("NPC '%s' inventory death drop failed: %s" % [String(npc_id), initialization.message])
		loot.queue_free()
		_drop_in_progress = false
		return false

	var world_parent := _get_world_parent(owner_entity)
	if world_parent == null:
		push_error("NPC '%s' inventory death drop failed: no current world parent." % String(npc_id))
		loot.queue_free()
		_drop_in_progress = false
		return false
	world_parent.add_child(loot)
	loot.global_position = owner_entity.global_position
	_spawned_loot = loot

	# World loot owns the full totals now; the dead owner can release its obsolete
	# reservations and relinquish the authoritative live inventory.
	var release_result := inventory.release_all_reservations()
	if not release_result.success:
		push_error("NPC '%s' could not release death reservations: %s" % [String(npc_id), release_result.message])
	inventory.clear()
	_capture_empty_record(npc_id)
	_drop_completed = true
	_drop_in_progress = false
	return true


func has_completed_drop() -> bool:
	return _drop_completed


func get_spawned_loot_container() -> WorldLootContainer:
	if _spawned_loot == null or not is_instance_valid(_spawned_loot):
		return null
	return _spawned_loot


func _is_canonical_live_owner(owner_entity: Node2D, npc_id: StringName) -> bool:
	if owner_entity is Monster:
		return owner_entity.is_inside_tree() and not owner_entity.is_queued_for_deletion()
	var owner_npc := owner_entity as SocialNpc
	if owner_npc == null:
		return false
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or npc_id == &"":
		return false
	if not locations.has_method("get_live_npc"):
		return false
	return locations.call("get_live_npc", String(npc_id)) == owner_npc


func _capture_empty_record(npc_id: StringName) -> void:
	if not (get_parent() is SocialNpc):
		return
	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_method("get_npc_location"):
		locations.call("get_npc_location", String(npc_id))


func _get_owner_id(owner_entity: Node2D) -> StringName:
	if owner_entity == null:
		return &""
	if owner_entity.has_method("get_loot_source_id"):
		return StringName(String(owner_entity.call("get_loot_source_id")))
	var owner_npc := owner_entity as SocialNpc
	if owner_npc == null:
		return StringName("entity:%s" % owner_entity.get_instance_id())
	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_method("get_npc_id"):
		return StringName(String(locations.call("get_npc_id", owner_npc)))
	return owner_npc.get_npc_location_id()


func _get_world_parent(owner_npc: Node) -> Node:
	if owner_npc == null or not owner_npc.is_inside_tree():
		return null
	var current_scene := get_tree().current_scene
	if current_scene != null:
		return current_scene
	return owner_npc.get_parent()
