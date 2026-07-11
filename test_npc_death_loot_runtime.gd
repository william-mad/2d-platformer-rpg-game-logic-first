extends SceneTree

const SocialNpcScene := preload("res://scenes/creatures/social_npc.tscn")
const LootScene := preload("res://scenes/items/world_loot_container.tscn")

var _failures: Array[String] = []
var _locations: Node


func _initialize() -> void:
	await process_frame
	_locations = root.get_node_or_null("NpcLocations")
	if _locations == null:
		_fail("NpcLocations autoload is required")
		_finish()
		return
	_locations.call("apply_save_data", {"records": {}})
	_test_death_drop_and_collection()
	_test_knockout_does_not_drop()
	_test_failed_spawn_preserves_inventory()
	_test_failed_transfer_preserves_loot()
	_test_duplicate_instance_cannot_drop()
	_finish()


func _test_death_drop_and_collection() -> void:
	var npc := _make_npc(&"loot.runtime.dead")
	var inventory := npc.get_inventory()
	inventory.add(&"raw_slime_meat", 5)
	inventory.add(&"slime_gel", 3)
	inventory.reserve_items(&"dead.activity", {&"raw_slime_meat": 2})
	var drop_component := npc.npc_inventory_drop
	_expect_true(drop_component.drop_inventory_on_death(), "definitive death API drops inventory")
	var loot := drop_component.get_spawned_loot_container()
	_expect_not_null(loot, "one world loot container is spawned")
	if loot == null:
		return
	_expect_equal(_count_loot_for_source(&"loot.runtime.dead"), 1, "death creates exactly one container")
	_expect_equal(loot.get_inventory().get_quantity(&"raw_slime_meat"), 5, "loot receives complete first quantity")
	_expect_equal(loot.get_inventory().get_quantity(&"slime_gel"), 3, "loot receives complete second quantity")
	_expect_true(loot.get_inventory().get_all_reservations().is_empty(), "dead-owner reservations are not copied")
	_expect_true(inventory.get_all_quantities().is_empty(), "NPC inventory clears after loot initialization")
	_expect_true(inventory.get_all_reservations().is_empty(), "NPC reservations are released")
	var record: Dictionary = _locations.call("get_record_snapshot", "loot.runtime.dead")
	_expect_true(record["inventory"]["quantities"].is_empty(), "persistent NPC record captures empty inventory")
	_expect_true(drop_component.drop_inventory_on_death(), "second death-drop call is idempotent")
	_expect_equal(_count_loot_for_source(&"loot.runtime.dead"), 1, "second call creates no duplicate")

	var player_inventory_component := PlayerInventoryComponent.new()
	root.add_child(player_inventory_component)
	var collection := loot.collect_into(player_inventory_component.get_inventory())
	_expect_true(collection.success, "player collection succeeds through transaction service")
	_expect_equal(player_inventory_component.get_inventory().get_quantity(&"raw_slime_meat"), 5, "player receives first loot quantity")
	_expect_equal(player_inventory_component.get_inventory().get_quantity(&"slime_gel"), 3, "player receives second loot quantity")
	_expect_true(loot.is_empty(), "successful collection empties loot")
	_expect_true(loot.is_queued_for_deletion(), "empty loot container schedules removal")

	var auto_dead := _make_npc(&"loot.runtime.auto_dead")
	auto_dead.get_inventory().add(&"cooked_slime_meat", 2)
	auto_dead.take_damage(999.0)
	_expect_true(auto_dead.npc_inventory_drop.has_completed_drop(), "HP-zero canonical die path invokes the drop")
	_expect_equal(_count_loot_for_source(&"loot.runtime.auto_dead"), 1, "canonical death spawns one container")


func _test_knockout_does_not_drop() -> void:
	var npc := _make_npc(&"loot.runtime.knockout")
	npc.get_inventory().add(&"slime_gel", 4)
	npc.apply_knockout(npc.max_knockout)
	_expect_true(npc.is_downed, "test NPC reaches downed state")
	_expect_false(npc.npc_inventory_drop.has_completed_drop(), "downed NPC does not drop")
	_expect_equal(npc.get_inventory().get_quantity(&"slime_gel"), 4, "downed NPC keeps inventory")
	_expect_equal(_count_loot_for_source(&"loot.runtime.knockout"), 0, "knockout spawns no loot")


func _test_failed_spawn_preserves_inventory() -> void:
	var npc := _make_npc(&"loot.runtime.failed")
	npc.get_inventory().add(&"raw_slime_meat", 2)
	npc.npc_inventory_drop.loot_container_scene = null
	_expect_false(npc.npc_inventory_drop.drop_inventory_on_death(), "missing loot scene rejects drop")
	_expect_equal(npc.get_inventory().get_quantity(&"raw_slime_meat"), 2, "failed drop preserves NPC inventory")
	_expect_false(npc.npc_inventory_drop.has_completed_drop(), "failed drop remains retryable")


func _test_failed_transfer_preserves_loot() -> void:
	var loot := LootScene.instantiate() as WorldLootContainer
	root.add_child(loot)
	var source := InventoryModel.new()
	source.add(&"slime_gel", 2)
	_expect_true(loot.initialize_from_inventory(source, &"loot.runtime.transfer_failure").success, "failure-test loot initializes")
	var full_destination := InventoryModel.new()
	full_destination.apply_save_data({
		"version": 1,
		"quantities": {"slime_gel": 9223372036854775807},
		"reservations": {},
	})
	var result := loot.collect_into(full_destination)
	_expect_false(result.success, "destination overflow rejects item transfer")
	_expect_equal(loot.get_inventory().get_quantity(&"slime_gel"), 2, "failed transfer leaves loot quantity")
	_expect_equal(full_destination.get_quantity(&"slime_gel"), 9223372036854775807, "failed transfer leaves destination unchanged")


func _test_duplicate_instance_cannot_drop() -> void:
	var canonical := _make_npc(&"loot.runtime.duplicate")
	canonical.get_inventory().add(&"slime_gel", 2)
	var duplicate := SocialNpcScene.instantiate() as SocialNpc
	duplicate.location_id = &"loot.runtime.duplicate"
	duplicate.get_node("NpcInventory").get_inventory().add(&"raw_slime_meat", 6)
	root.add_child(duplicate)
	_expect_true(duplicate.is_queued_for_deletion(), "duplicate live NPC is rejected")
	_expect_false(duplicate.npc_inventory_drop.drop_inventory_on_death(), "rejected duplicate cannot drop canonical inventory")
	_expect_equal(canonical.get_inventory().get_quantity(&"slime_gel"), 2, "canonical duplicate-test inventory remains owned")
	_expect_equal(_count_loot_for_source(&"loot.runtime.duplicate"), 0, "rejected duplicate spawns no loot")


func _make_npc(npc_id: StringName) -> SocialNpc:
	var npc := SocialNpcScene.instantiate() as SocialNpc
	npc.location_id = npc_id
	npc.display_name = String(npc_id)
	root.add_child(npc)
	return npc


func _count_loot_for_source(source_id: StringName) -> int:
	var count := 0
	for child: Node in root.get_children():
		var loot := child as WorldLootContainer
		if loot != null and not loot.is_queued_for_deletion() and loot.source_id == source_id:
			count += 1
	return count


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
		print("NPC death loot runtime tests passed.")
		quit(0)
		return
	for failure: String in _failures:
		push_error(failure)
	quit(1)
