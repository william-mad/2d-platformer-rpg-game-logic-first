extends SceneTree

var failures: PackedStringArray = []


func _initialize() -> void:
	var recipe := load("res://data/recipes/cook_slime_meat.tres") as ProcessingRecipeDefinition
	var service := InventoryProcessingService.new()
	var inventory := InventoryModel.new()
	inventory.add(&"raw_slime_meat", 5)
	inventory.reserve_items(&"held_raw", {&"raw_slime_meat": 2})
	_expect(service.get_maximum_batches(inventory, recipe) == 3, "maximum excludes reserved raw meat")
	var result := service.process(inventory, recipe, 3)
	_expect(result.success, "three processing batches succeed atomically")
	_expect(inventory.get_quantity(&"raw_slime_meat") == 2, "three raw meat are removed")
	_expect(inventory.get_reserved_quantity(&"raw_slime_meat") == 2, "unrelated reservation is preserved")
	_expect(inventory.get_quantity(&"cooked_slime_meat") == 3, "three cooked meat are produced")
	var before := inventory.get_save_data()
	result = service.process(inventory, recipe, 1)
	_expect(not result.success and inventory.get_save_data() == before, "insufficient unreserved input leaves inventory unchanged")
	var overflow_inventory := InventoryModel.new()
	overflow_inventory.add(&"raw_slime_meat", 1)
	overflow_inventory.apply_save_data({"version": 1, "quantities": {"raw_slime_meat": 1, "cooked_slime_meat": 9223372036854775807}, "reservations": {}})
	var overflow_before := overflow_inventory.get_save_data()
	result = service.process(overflow_inventory, recipe, 1)
	_expect(not result.success and overflow_inventory.get_save_data() == overflow_before, "failed output addition restores all inputs")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("INVENTORY_PROCESSING_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
