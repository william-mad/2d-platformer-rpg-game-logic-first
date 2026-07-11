class_name NpcInventoryComponent
extends Node

var _inventory: InventoryModel = InventoryModel.new()


func get_inventory() -> InventoryModel:
	return _inventory


func get_save_data() -> Dictionary:
	return _inventory.get_save_data()


func apply_save_data(data: Dictionary) -> InventoryResult:
	# InventoryModel validates the complete snapshot before replacing live state.
	return _inventory.apply_save_data(data)


func reset_inventory() -> void:
	_inventory.clear()
