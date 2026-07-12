extends SceneTree

class PlayerNeedStub extends Node:
	signal hunger_changed(current_hunger: float, changed_by: float)

	var hunger: float = 50.0
	var dead: bool = false

	func apply_hunger_delta(delta: float) -> float:
		var previous := hunger
		hunger = clampf(hunger + delta, 0.0, 100.0)
		var changed := hunger - previous
		if not is_zero_approx(changed):
			hunger_changed.emit(hunger, changed)
		return changed


var failures: PackedStringArray = []


func _initialize() -> void:
	var service := FoodConsumptionService.new()
	var inventory := InventoryModel.new()
	var player := PlayerNeedStub.new()
	root.add_child(player)
	_expect(inventory.add(&"raw_slime_meat", 2).success, "raw food can be added")
	_expect(inventory.add(&"cooked_slime_meat", 2).success, "cooked food can be added")
	_expect(service.select_best_available_food(inventory) == &"cooked_slime_meat", "highest food value is selected first")
	var npc_inventory_component := NpcInventoryComponent.new()
	root.add_child(npc_inventory_component)
	var npc_inventory := npc_inventory_component.get_inventory()
	npc_inventory.add(&"raw_slime_meat", 1)
	npc_inventory.add(&"cooked_slime_meat", 1)
	_expect(npc_inventory_component.get_best_available_food() == &"cooked_slime_meat", "NPC food cache prefers cooked food deterministically")
	npc_inventory.reserve_items(&"npc_eat_test", {&"cooked_slime_meat": 1})
	_expect(npc_inventory_component.get_best_available_food() == &"raw_slime_meat", "NPC food cache excludes reserved food")
	npc_inventory.release_reservation(&"npc_eat_test")
	var result := service.consume_for_player(inventory, player, &"raw_slime_meat")
	_expect(result.success, "raw food consumption succeeds")
	_expect(inventory.get_quantity(&"raw_slime_meat") == 1 and is_equal_approx(player.hunger, 40.0), "raw food removes one and lowers hunger by 10")
	_expect(inventory.reserve_items(&"held_food", {&"raw_slime_meat": 1}).success, "remaining raw food can be reserved")
	result = service.consume_for_player(inventory, player, &"raw_slime_meat")
	_expect(not result.success and inventory.get_quantity(&"raw_slime_meat") == 1, "reserved food cannot be consumed")
	player.hunger = 0.0
	var before := inventory.get_save_data()
	result = service.consume_for_player(inventory, player, &"cooked_slime_meat")
	_expect(result.code == InventoryResult.Code.NEED_ALREADY_SATISFIED and inventory.get_save_data() == before, "satisfied player cannot waste food")
	player.hunger = 50.0
	var rollback_inventory := InventoryModel.new()
	rollback_inventory.add(&"cooked_slime_meat", 1)
	player.hunger_changed.connect(func(_current: float, changed: float) -> void:
		if changed < 0.0 and not rollback_inventory.has_reservation(&"race_hold"):
			rollback_inventory.reserve_items(&"race_hold", {&"cooked_slime_meat": 1})
	)
	result = service.consume_for_player(rollback_inventory, player, &"cooked_slime_meat")
	_expect(not result.success, "post-need inventory failure is reported")
	_expect(rollback_inventory.get_quantity(&"cooked_slime_meat") == 1 and is_equal_approx(player.hunger, 50.0), "failed removal restores hunger and preserves food")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FOOD_CONSUMPTION_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
