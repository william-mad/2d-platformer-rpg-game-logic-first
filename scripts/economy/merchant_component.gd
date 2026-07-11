class_name MerchantComponent
extends Node

@export var inventory_component_path: NodePath = NodePath("../NpcInventory")
@export var starting_inventory_profile: InventoryProfileDefinition
@export_range(0.0, 100.0, 0.01) var price_to_player_multiplier: float = 1.0
@export_range(0.0, 100.0, 0.01) var price_from_player_multiplier: float = 0.7

var _catalog := ItemCatalog.new()


func _ready() -> void:
	if not _catalog.load_definitions():
		push_warning("Merchant item catalog is invalid: %s" % str(_catalog.get_validation_errors()))


func get_inventory() -> InventoryModel:
	var component := get_node_or_null(inventory_component_path) as NpcInventoryComponent
	return component.get_inventory() if component != null else null


func is_item_tradable(item_id: StringName) -> bool:
	if item_id == &"" or item_id == TradeService.GOLD_ITEM_ID:
		return false
	var definition := _catalog.get_definition(item_id)
	return definition != null and definition.base_value > 0


func get_price_to_player(item_id: StringName) -> int:
	return _calculate_price(item_id, price_to_player_multiplier)


func get_price_from_player(item_id: StringName) -> int:
	return _calculate_price(item_id, price_from_player_multiplier)


func initialize_starting_inventory() -> InventoryResult:
	var inventory := get_inventory()
	if inventory == null:
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "Merchant inventory component is unavailable.")
	if starting_inventory_profile == null:
		return InventoryResult.succeeded("Merchant has no starting inventory profile.")
	var errors := starting_inventory_profile.validate(_catalog)
	if not errors.is_empty():
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "; ".join(errors))

	# Build the entire authored state off-line, then replace the new record's empty inventory once.
	var staged := InventoryModel.new()
	var apply_result := staged.apply_save_data(inventory.get_save_data())
	if not apply_result.success:
		return apply_result
	for raw_id: Variant in starting_inventory_profile.items:
		var add_result := staged.add(StringName(String(raw_id)), int(starting_inventory_profile.items[raw_id]))
		if not add_result.success:
			return add_result
	return inventory.apply_save_data(staged.get_save_data())


func _calculate_price(item_id: StringName, multiplier: float) -> int:
	if not is_item_tradable(item_id) or multiplier <= 0.0:
		return 0
	var definition := _catalog.get_definition(item_id)
	# Halfway values round away from zero in Godot; positive prices are then clamped to one.
	return maxi(1, roundi(float(definition.base_value) * multiplier))
