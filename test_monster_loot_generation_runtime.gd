extends SceneTree

const SlimeScene := preload("res://scenes/monsters/slime.tscn")

var _failures: Array[String] = []


class MockLootOwner:
	extends Node

	var inventory: InventoryModel = InventoryModel.new()

	func get_inventory() -> InventoryModel:
		return inventory


func _initialize() -> void:
	await process_frame
	_test_table_roll_rules()
	_test_component_exactly_once_and_precedence()
	_test_slime_death_drop_and_collection()
	_finish()


func _test_table_roll_rules() -> void:
	var guaranteed := _entry(&"slime_gel", 1.0, 2, 2)
	var never := _entry(&"raw_slime_meat", 0.0, 4, 4)
	var duplicate := _entry(&"slime_gel", 1.0, 3, 3)
	var invalid := _entry(&"missing_catalog_item", 1.0, 9, 9)
	var table := LootTableDefinition.new()
	table.entries = [guaranteed, never, duplicate, invalid]
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var result := table.roll_loot(rng)
	_expect_equal(int(result.get("slime_gel", 0)), 5, "guaranteed duplicate entries combine")
	_expect_false(result.has("raw_slime_meat"), "zero-chance entry never appears")
	_expect_false(result.has("missing_catalog_item"), "invalid entry is skipped")

	var bounded := LootTableDefinition.new()
	bounded.entries = [_entry(&"slime_gel", 1.0, 1, 3)]
	for seed_value: int in [1, 2, 3, 4, 5]:
		var bounded_rng := RandomNumberGenerator.new()
		bounded_rng.seed = seed_value
		var quantity := int(bounded.roll_loot(bounded_rng).get("slime_gel", 0))
		_expect_true(quantity >= 1 and quantity <= 3, "rolled quantity stays inside authored bounds")


func _test_component_exactly_once_and_precedence() -> void:
	var owner := MockLootOwner.new()
	var component := MonsterLootComponent.new()
	component.initialize_on_ready = false
	var table := LootTableDefinition.new()
	table.entries = [_entry(&"slime_gel", 1.0, 2, 2)]
	component.loot_table = table
	owner.add_child(component)
	root.add_child(owner)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	_expect_true(component.initialize_loot_once(rng), "monster loot initializes")
	_expect_equal(owner.inventory.get_quantity(&"slime_gel"), 2, "component adds rolled loot")
	_expect_true(component.initialize_loot_once(rng), "second initialization call is accepted as no-op")
	_expect_equal(owner.inventory.get_quantity(&"slime_gel"), 2, "second call does not reroll")

	var authored_owner := MockLootOwner.new()
	authored_owner.inventory.add(&"raw_slime_meat", 7)
	var authored_component := MonsterLootComponent.new()
	authored_component.initialize_on_ready = false
	authored_component.loot_table = table
	authored_owner.add_child(authored_component)
	root.add_child(authored_owner)
	_expect_true(authored_component.initialize_loot_once(rng), "existing inventory skips generated loot")
	_expect_equal(authored_owner.inventory.get_quantity(&"raw_slime_meat"), 7, "authored inventory is preserved")
	_expect_equal(authored_owner.inventory.get_quantity(&"slime_gel"), 0, "generated inventory does not overwrite precedence")


func _test_slime_death_drop_and_collection() -> void:
	var slime := SlimeScene.instantiate() as Slime
	root.add_child(slime)
	var inventory := slime.get_inventory()
	_expect_true(slime.monster_loot_component.has_initialized_loot(), "slime initializes loot during legitimate ready")
	_expect_true(inventory.get_quantity(&"slime_gel") >= 1, "sample slime table guarantees slime gel")
	var before_damage := inventory.get_save_data()
	slime.take_damage(1.0, Vector2.ZERO, null, 999.0)
	_expect_equal(inventory.get_save_data(), before_damage, "nonlethal hit does not reroll or drop loot")
	var expected_quantities := inventory.get_all_quantities()
	slime.die()
	var loot := slime.inventory_drop_component.get_spawned_loot_container()
	_expect_not_null(loot, "generated slime inventory reaches existing death-drop container")
	if loot == null:
		return
	_expect_equal(loot.get_inventory().get_all_quantities(), expected_quantities, "death container receives generated quantities exactly")
	_expect_true(inventory.get_all_quantities().is_empty(), "slime inventory clears through existing death drop")
	var player_inventory := PlayerInventoryComponent.new()
	root.add_child(player_inventory)
	_expect_true(loot.collect_into(player_inventory.get_inventory()).success, "generated monster loot collects through transaction service")
	for raw_item_id: Variant in expected_quantities:
		_expect_equal(
			player_inventory.get_inventory().get_quantity(StringName(String(raw_item_id))),
			int(expected_quantities[raw_item_id]),
			"player receives generated quantity for %s" % String(raw_item_id)
		)

	var authored_slime := SlimeScene.instantiate() as Slime
	var authored_inventory := authored_slime.get_node("NpcInventory") as NpcInventoryComponent
	authored_inventory.get_inventory().add(&"raw_slime_meat", 6)
	root.add_child(authored_slime)
	_expect_equal(authored_slime.get_inventory().get_quantity(&"raw_slime_meat"), 6, "pre-authored slime inventory survives initialization")
	_expect_equal(authored_slime.get_inventory().get_quantity(&"slime_gel"), 0, "pre-authored slime does not roll table")


func _entry(
	item_id: StringName,
	chance: float,
	minimum: int,
	maximum: int
) -> LootTableEntry:
	var entry := LootTableEntry.new()
	entry.item_id = item_id
	entry.drop_chance = chance
	entry.minimum_quantity = minimum
	entry.maximum_quantity = maximum
	return entry


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		_fail("%s: expected %s, got %s" % [message, str(expected), str(actual)])


func _expect_not_null(value: Variant, message: String) -> void:
	if value == null:
		_fail(message)


func _expect_true(value: bool, message: String) -> void:
	if not value:
		_fail(message)


func _expect_false(value: bool, message: String) -> void:
	if value:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("Monster loot generation runtime tests passed.")
		quit(0)
		return
	for failure: String in _failures:
		push_error(failure)
	quit(1)
