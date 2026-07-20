extends SceneTree

const ScreenScene := preload("res://ui/inventory/player_inventory_screen.tscn")

var _failures: Array[String] = []


class InventoryPlayerStub:
	extends Node2D

	var hunger: float = 20.0


func _initialize() -> void:
	await process_frame
	var component := PlayerInventoryComponent.new()
	root.add_child(component)
	var inventory := component.get_inventory()
	var player_owner := InventoryPlayerStub.new()
	root.add_child(player_owner)
	var equipment := PlayerEquipmentComponent.new()
	equipment.name = "PlayerEquipment"
	player_owner.add_child(equipment)
	equipment.bind_inventory(inventory)
	var screen := ScreenScene.instantiate() as PlayerInventoryScreen
	root.add_child(screen)
	screen.bind_inventory(inventory, player_owner)

	screen.open_screen()
	_expect_true(_contains_text(screen, "Inventory is empty."), "empty inventory shows its empty state")
	screen.close_screen()

	_expect_true(inventory.add(&"raw_slime_meat", 5).success, "raw meat can be added")
	_expect_true(inventory.add(&"slime_gel", 8).success, "slime gel can be added")
	_expect_true(inventory.reserve_items(&"ui.runtime", {&"raw_slime_meat": 2}).success, "reservation can be added")
	screen.open_screen()
	var raw_meat_slot := _find_slot(screen, &"raw_slime_meat")
	_expect_true(raw_meat_slot != null, "raw meat slot is shown")
	if raw_meat_slot != null:
		screen.call("_on_slot_inspected", raw_meat_slot)
	_expect_true(_contains_text(screen, "Raw Slime Meat"), "catalog display name is shown")
	_expect_true(
		_contains_text(screen, "Total: 5 | Available: 3 | Reserved: 2"),
		"structured quantity counts are shown"
	)

	inventory.add(&"cooked_slime_meat", 3)
	var cooked_meat_slot := _find_slot(screen, &"cooked_slime_meat")
	_expect_true(cooked_meat_slot != null, "open list refreshes from inventory signals")
	if cooked_meat_slot != null:
		screen.call("_on_slot_inspected", cooked_meat_slot)
	_expect_true(_contains_text(screen, "Cooked Slime Meat"), "refreshed item details can be inspected")
	screen.close_screen()
	inventory.add(&"slime_gel", 1)
	screen.open_screen()
	var slime_gel_slot := _find_slot(screen, &"slime_gel")
	_expect_true(slime_gel_slot != null, "slime gel slot remains available")
	if slime_gel_slot != null:
		screen.call("_on_slot_inspected", slime_gel_slot)
	_expect_true(
		_contains_text(screen, "Total: 9 | Available: 9 | Reserved: 0"),
		"closed changes appear with structured counts when reopened"
	)

	_expect_true(inventory.add(&"wooden_sword", 1).success, "Wooden Sword can be added")
	var sword_slot := _find_slot(screen, &"wooden_sword")
	_expect_true(sword_slot != null, "Wooden Sword appears in the inventory grid")
	if sword_slot != null:
		screen.call("_on_slot_inspected", sword_slot)
	var equipment_button := screen.get_node("%EquipmentButton") as Button
	_expect_true(equipment_button.visible, "Equip button is visible for an unequipped weapon")
	_expect_equal(equipment_button.text, "Equip", "unequipped weapon uses the Equip label")
	_expect_true(not equipment_button.disabled, "Equip button is enabled for an available weapon")
	screen.call("_on_equipment_pressed")
	_expect_true(_contains_text(screen, "Total: 1"), "equipped sword total is shown")
	_expect_true(_contains_text(screen, "Available: 0"), "equipped sword availability is shown")
	_expect_true(_contains_text(screen, "Reserved: 1"), "equipped sword reservation is shown")
	_expect_true(_contains_text(screen, "Equipped: Weapon"), "equipped weapon indicator is shown")
	_expect_true(equipment_button.visible, "Unequip button remains visible for the equipped weapon")
	_expect_equal(equipment_button.text, "Unequip", "equipped weapon uses the Unequip label")
	_expect_true(not equipment_button.disabled, "Unequip button is enabled")

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


func _find_slot(node: Node, item_id: StringName) -> InventoryItemSlot:
	var slot := node as InventoryItemSlot
	if slot != null and slot.item_id == item_id:
		return slot
	for child: Node in node.get_children():
		var found := _find_slot(child, item_id)
		if found != null:
			return found
	return null


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
