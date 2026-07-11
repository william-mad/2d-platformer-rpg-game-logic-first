extends SceneTree

const ScreenScene := preload("res://ui/inventory/player_inventory_screen.tscn")

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var component := PlayerInventoryComponent.new()
	root.add_child(component)
	var screen := ScreenScene.instantiate() as PlayerInventoryScreen
	root.add_child(screen)
	screen.bind_inventory(component.get_inventory())

	screen.open_screen()
	_expect_true(_contains_text(screen, "Inventory is empty."), "empty inventory shows its empty state")
	screen.close_screen()

	var inventory := component.get_inventory()
	_expect_true(inventory.add(&"raw_slime_meat", 5).success, "raw meat can be added")
	_expect_true(inventory.add(&"slime_gel", 8).success, "slime gel can be added")
	_expect_true(inventory.reserve_items(&"ui.runtime", {&"raw_slime_meat": 2}).success, "reservation can be added")
	screen.open_screen()
	_expect_true(_contains_text(screen, "Raw Slime Meat"), "catalog display name is shown")
	_expect_true(_contains_text(screen, "5 total"), "total quantity is shown")
	_expect_true(_contains_text(screen, "3 available"), "available quantity is shown")
	_expect_true(_contains_text(screen, "2 reserved"), "reserved quantity is shown")

	inventory.add(&"cooked_slime_meat", 3)
	_expect_true(_contains_text(screen, "Cooked Slime Meat"), "open list refreshes from inventory signals")
	screen.close_screen()
	inventory.add(&"slime_gel", 1)
	screen.open_screen()
	_expect_true(_contains_text(screen, "9"), "closed changes appear when reopened")

	var restored := InventoryModel.new()
	var restore_result := restored.apply_save_data(component.get_save_data())
	_expect_true(restore_result.success, "component inventory save data restores")
	_expect_equal(restored.get_quantity(&"raw_slime_meat"), 5, "quantity survives serialization")
	_expect_equal(restored.get_reserved_quantity(&"raw_slime_meat"), 2, "reservation survives serialization")
	_finish()


func _contains_text(node: Node, expected_fragment: String) -> bool:
	var label := node as Label
	if label != null and expected_fragment in label.text:
		return true
	for child: Node in node.get_children():
		if _contains_text(child, expected_fragment):
			return true
	return false


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		_fail("%s: expected %s, got %s" % [message, str(expected), str(actual)])


func _expect_true(value: bool, message: String) -> void:
	if not value:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("Player inventory UI runtime tests passed.")
		quit(0)
		return
	for failure: String in _failures:
		push_error(failure)
	quit(1)
