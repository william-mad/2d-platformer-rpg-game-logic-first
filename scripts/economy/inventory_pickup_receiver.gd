class_name InventoryPickupReceiver
extends Node

@export var world_position_offset: Vector2 = Vector2(0.0, -28.0)


func get_inventory() -> InventoryModel:
	var inventory_owner := get_parent()
	if inventory_owner == null or not inventory_owner.has_method("get_inventory"):
		return null
	return inventory_owner.call("get_inventory") as InventoryModel


func can_receive_world_loot() -> bool:
	var inventory_owner := get_parent() as Node2D
	if inventory_owner == null or not is_instance_valid(inventory_owner):
		return false
	if not inventory_owner.is_inside_tree() or inventory_owner.is_queued_for_deletion():
		return false
	if get_inventory() == null:
		return false
	if inventory_owner.is_in_group(&"player"):
		return not bool(inventory_owner.get("dead"))
	var npc := inventory_owner as SocialNpc
	if npc == null or float(npc.social_stats.get("disabled", 0.0)) >= 1.0:
		return false
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_live_npc"):
		return false
	return locations.call("get_live_npc", String(npc.get_npc_location_id())) == npc


func get_receiver_world_position() -> Vector2:
	var inventory_owner := get_parent() as Node2D
	return inventory_owner.global_position + world_position_offset if inventory_owner != null else Vector2.ZERO


func get_receiver_id() -> StringName:
	var inventory_owner := get_parent()
	if inventory_owner == null:
		return &""
	if inventory_owner.is_in_group(&"player"):
		if inventory_owner.has_method("get_save_id"):
			return StringName("player:%s" % String(inventory_owner.call("get_save_id")))
		return &"player"
	if inventory_owner.has_method("get_npc_location_id"):
		return StringName(String(inventory_owner.call("get_npc_location_id")))
	return StringName("entity:%s" % inventory_owner.get_instance_id())
