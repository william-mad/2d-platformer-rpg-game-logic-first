class_name InventoryProcessingService
extends RefCounted

var _catalog := ItemCatalog.new()
var _catalog_loaded: bool = false


func get_maximum_batches(inventory: InventoryModel, recipe: ProcessingRecipeDefinition) -> int:
	if inventory == null or recipe == null or not _ensure_catalog() or not recipe.validate(_catalog).is_empty():
		return 0
	var maximum := 9223372036854775807
	for raw_id: Variant in recipe.input_items:
		var item_id := StringName(String(raw_id))
		maximum = mini(maximum, inventory.get_available_quantity(item_id) / int(recipe.input_items[raw_id]))
	return maxi(maximum, 0)


func process(
		inventory: InventoryModel,
		recipe: ProcessingRecipeDefinition,
		batch_quantity: int
) -> InventoryResult:
	if inventory == null or recipe == null:
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "An inventory and processing recipe are required.")
	if batch_quantity <= 0:
		return InventoryResult.failed(InventoryResult.Code.INVALID_QUANTITY, "Processing quantity must be positive.", &"", batch_quantity)
	if not _ensure_catalog():
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "The item catalog is unavailable.")
	var errors := recipe.validate(_catalog)
	if not errors.is_empty():
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "; ".join(errors))
	if batch_quantity > get_maximum_batches(inventory, recipe):
		return InventoryResult.failed(InventoryResult.Code.INSUFFICIENT_AVAILABLE_QUANTITY, "Not enough unreserved recipe inputs are available.")

	var before := inventory.get_save_data()
	var staged := InventoryModel.new()
	var result := staged.apply_save_data(before)
	if not result.success:
		return result
	for raw_id: Variant in _sorted_keys(recipe.input_items):
		var item_id := StringName(String(raw_id))
		result = staged.remove(item_id, int(recipe.input_items[raw_id]) * batch_quantity)
		if not result.success:
			return result
	for raw_id: Variant in _sorted_keys(recipe.output_items):
		var item_id := StringName(String(raw_id))
		result = staged.add(item_id, int(recipe.output_items[raw_id]) * batch_quantity)
		if not result.success:
			return result

	result = inventory.apply_save_data(staged.get_save_data())
	if result.success:
		return InventoryResult.succeeded("Processed %d batch%s of %s." % [batch_quantity, "" if batch_quantity == 1 else "es", recipe.display_name])
	var rollback := inventory.apply_save_data(before)
	if not rollback.success:
		push_error("Inventory processing rollback failed after commit failure.")
	return result


func _sorted_keys(items: Dictionary) -> Array:
	var keys: Array = items.keys()
	keys.sort_custom(func(left: Variant, right: Variant) -> bool: return String(left) < String(right))
	return keys


func _ensure_catalog() -> bool:
	if _catalog_loaded:
		return true
	_catalog_loaded = _catalog.load_definitions()
	return _catalog_loaded
