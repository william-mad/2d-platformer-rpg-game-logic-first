class_name MonsterLootComponent
extends Node

@export var loot_table: LootTableDefinition
@export var initialize_on_ready: bool = true

var _loot_initialized: bool = false


func _ready() -> void:
	if initialize_on_ready:
		call_deferred("initialize_loot_once")


func initialize_loot_once(rng: RandomNumberGenerator = null) -> bool:
	if _loot_initialized:
		return true
	var owner_node := get_parent()
	if owner_node == null or not owner_node.has_method("get_inventory"):
		push_error("Monster loot initialization requires an owner inventory API.")
		return false
	var inventory = owner_node.call("get_inventory") as InventoryModel
	if inventory == null:
		push_error("Monster '%s' has no authoritative inventory model." % owner_node.name)
		return false

	# Restored or explicitly authored stock always wins over generated loot.
	if not inventory.get_all_quantities().is_empty():
		_loot_initialized = true
		return true
	if loot_table == null:
		_loot_initialized = true
		return true

	var rolled_items := loot_table.roll_loot(rng)
	var staged := InventoryModel.new()
	var stage_restore := staged.apply_save_data(inventory.get_save_data())
	if not stage_restore.success:
		push_error("Monster '%s' inventory could not be staged: %s" % [owner_node.name, stage_restore.message])
		return false
	var item_ids: Array = rolled_items.keys()
	item_ids.sort()
	for raw_item_id: Variant in item_ids:
		var item_id := StringName(String(raw_item_id))
		var add_result := staged.add(item_id, int(rolled_items[raw_item_id]))
		if not add_result.success:
			push_error("Monster '%s' loot item '%s' failed: %s" % [owner_node.name, String(item_id), add_result.message])
			return false
	var commit := inventory.apply_save_data(staged.get_save_data())
	if not commit.success:
		push_error("Monster '%s' loot commit failed: %s" % [owner_node.name, commit.message])
		return false
	_loot_initialized = true
	return true


func has_initialized_loot() -> bool:
	return _loot_initialized
