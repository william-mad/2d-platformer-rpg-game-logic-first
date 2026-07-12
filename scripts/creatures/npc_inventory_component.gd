class_name NpcInventoryComponent
extends Node

var _inventory: InventoryModel = InventoryModel.new()
var _food_service := FoodConsumptionService.new()
var _best_available_food: StringName = &""


func _init() -> void:
	_inventory.item_quantity_changed.connect(_on_inventory_changed)
	_inventory.reservation_changed.connect(_on_reservation_changed)
	_inventory.inventory_reset.connect(_on_inventory_reset)
	_refresh_food_cache()


func get_inventory() -> InventoryModel:
	return _inventory


func get_save_data() -> Dictionary:
	return _inventory.get_save_data()


func apply_save_data(data: Dictionary) -> InventoryResult:
	# InventoryModel validates the complete snapshot before replacing live state.
	return _inventory.apply_save_data(data)


func reset_inventory() -> void:
	_inventory.clear()


func has_available_food() -> bool:
	return _best_available_food != &""


func get_best_available_food() -> StringName:
	return _best_available_food


func _refresh_food_cache() -> void:
	_best_available_food = _food_service.select_best_available_food(_inventory)


func _on_inventory_changed(_item_id: StringName, _total: int, _available: int, _reason: StringName) -> void:
	_refresh_food_cache()


func _on_reservation_changed(_reservation_id: StringName, _reason: StringName) -> void:
	_refresh_food_cache()


func _on_inventory_reset() -> void:
	_refresh_food_cache()
