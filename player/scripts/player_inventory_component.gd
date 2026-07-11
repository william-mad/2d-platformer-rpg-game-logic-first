class_name PlayerInventoryComponent
extends Node

signal inventory_changed

@export_group("Development")
@export var development_add_sample_items: bool = false
@export var development_add_trade_gold: bool = false

var _inventory: InventoryModel = InventoryModel.new()
var _development_samples_added: bool = false
var _development_trade_gold_added: bool = false


func _init() -> void:
	_inventory.item_quantity_changed.connect(_on_inventory_mutated)
	_inventory.reservation_changed.connect(_on_reservation_mutated)
	_inventory.inventory_reset.connect(_on_inventory_reset)


func _ready() -> void:
	if development_add_sample_items and OS.is_debug_build():
		add_development_sample_items()
	if development_add_trade_gold and OS.is_debug_build():
		add_development_trade_gold()


func get_inventory() -> InventoryModel:
	return _inventory


func get_save_data() -> Dictionary:
	return _inventory.get_save_data()


func apply_save_data(data: Dictionary) -> InventoryResult:
	return _inventory.apply_save_data(data)


func reset_inventory() -> void:
	_inventory.clear()


func add_development_sample_items() -> bool:
	if not OS.is_debug_build() or _development_samples_added:
		return false
	var catalog := ItemCatalog.new()
	if not catalog.load_definitions():
		push_warning("Development player inventory samples were not added because the item catalog is invalid.")
		return false
	var samples := {
		&"raw_slime_meat": 5,
		&"slime_gel": 8,
		&"cooked_slime_meat": 3,
	}
	for item_id: StringName in samples:
		if not catalog.has_item(item_id):
			push_warning("Development player inventory sample item is missing: %s" % String(item_id))
			return false
	for item_id: StringName in samples:
		var result := _inventory.add(item_id, int(samples[item_id]))
		if not result.success:
			push_warning("Could not add development inventory sample '%s': %s" % [String(item_id), result.message])
			return false
	_development_samples_added = true
	return true


func add_development_trade_gold(quantity: int = 50) -> bool:
	if not OS.is_debug_build() or _development_trade_gold_added or quantity <= 0:
		return false
	var catalog := ItemCatalog.new()
	if not catalog.load_definitions() or not catalog.has_item(TradeService.GOLD_ITEM_ID):
		push_warning("Development trade gold was not added because gold_coin is unavailable.")
		return false
	var result := _inventory.add(TradeService.GOLD_ITEM_ID, quantity)
	if not result.success:
		push_warning("Could not add development trade gold: %s" % result.message)
		return false
	_development_trade_gold_added = true
	return true


func _on_inventory_mutated(
	_item_id: StringName,
	_total_quantity: int,
	_available_quantity: int,
	_reason: StringName
) -> void:
	inventory_changed.emit()


func _on_reservation_mutated(_reservation_id: StringName, _reason: StringName) -> void:
	inventory_changed.emit()


func _on_inventory_reset() -> void:
	inventory_changed.emit()
