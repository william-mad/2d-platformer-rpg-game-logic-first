extends SceneTree

const NpcLocationsClass := preload("res://scripts/systems/npc_locations.gd")

var _failures: Array[String] = []


class MockPersistentNpc:
	extends Node2D

	var persistent_id: String = ""
	var inventory_component: NpcInventoryComponent

	func _init(npc_id: String) -> void:
		persistent_id = npc_id
		inventory_component = NpcInventoryComponent.new()
		inventory_component.name = "NpcInventory"
		add_child(inventory_component)

	func get_npc_location_id() -> StringName:
		return StringName(persistent_id)

	func get_npc_scene_path() -> String:
		return ""

	func get_npc_location_save_data() -> Dictionary:
		return {}

	func apply_npc_location_save_data(_data: Dictionary) -> void:
		pass

	func get_inventory() -> InventoryModel:
		return inventory_component.get_inventory()

	func get_inventory_save_data() -> Dictionary:
		return inventory_component.get_save_data()

	func apply_inventory_save_data(data: Dictionary) -> InventoryResult:
		return inventory_component.apply_save_data(data)

	func reset_inventory() -> void:
		inventory_component.reset_inventory()


func _initialize() -> void:
	await process_frame
	_run_tests()
	if _failures.is_empty():
		print("NPC inventory persistence runtime tests passed.")
		quit(0)
		return
	for failure: String in _failures:
		push_error(failure)
	quit(1)


func _run_tests() -> void:
	_test_new_records_and_independent_defaults()
	_test_capture_restore_and_reservations()
	_test_missing_inventory_normalizes_to_empty()
	_test_malformed_inventory_preserves_live_state()
	_test_offscreen_update_and_save_round_trip()
	_test_rejected_registration_does_not_mutate_record()


func _make_locations() -> Node:
	var locations := NpcLocationsClass.new()
	root.add_child(locations)
	return locations


func _make_npc(npc_id: String) -> MockPersistentNpc:
	var npc := MockPersistentNpc.new(npc_id)
	root.add_child(npc)
	return npc


func _test_new_records_and_independent_defaults() -> void:
	var locations := _make_locations()
	var first := _make_npc("inventory.new.first")
	var second := _make_npc("inventory.new.second")
	_expect_true(locations.register_npc(first), "first new NPC registers")
	_expect_true(locations.register_npc(second), "second new NPC registers")
	var first_record: Dictionary = locations.get_record_snapshot("inventory.new.first")
	var second_record: Dictionary = locations.get_record_snapshot("inventory.new.second")
	_expect_equal(first_record.get("inventory", {}), InventoryModel.get_empty_save_data(), "new record gets valid empty inventory")
	_expect_equal(second_record.get("inventory", {}), InventoryModel.get_empty_save_data(), "second record gets valid empty inventory")
	_expect_false(
		is_same(locations.npc_records["inventory.new.first"]["inventory"], locations.npc_records["inventory.new.second"]["inventory"]),
		"new records do not share a mutable inventory dictionary"
	)
	first_record["inventory"]["quantities"]["slime_gel"] = 99
	_expect_equal(
		locations.get_record_snapshot("inventory.new.first")["inventory"],
		InventoryModel.get_empty_save_data(),
		"record snapshots cannot mutate canonical inventory"
	)
	locations.queue_free()
	first.queue_free()
	second.queue_free()


func _test_capture_restore_and_reservations() -> void:
	var locations := _make_locations()
	var live := _make_npc("inventory.handoff")
	_expect_true(live.get_inventory().add(&"raw_slime_meat", 4).success, "test stock can be added")
	_expect_true(live.get_inventory().add(&"slime_gel", 2).success, "second test stock can be added")
	_expect_true(
		live.get_inventory().reserve_items(&"cook.job.runtime", {&"raw_slime_meat": 2, &"slime_gel": 1}).success,
		"test reservation can be created"
	)
	_expect_true(locations.register_npc(live), "stocked new NPC registers")
	var captured: Dictionary = locations.get_record_snapshot("inventory.handoff")["inventory"]
	_expect_equal(int(captured["quantities"]["raw_slime_meat"]), 4, "live quantity is captured")
	_expect_equal(int(captured["reservations"]["cook.job.runtime"]["raw_slime_meat"]), 2, "live reservation is captured")

	locations.unregister_npc(live)
	live.queue_free()
	var restored := _make_npc("inventory.handoff")
	_expect_true(locations.register_npc(restored), "fresh live NPC restores from record")
	_expect_equal(restored.get_inventory().get_quantity(&"raw_slime_meat"), 4, "quantity restores into fresh component")
	_expect_equal(restored.get_inventory().get_reserved_quantity(&"raw_slime_meat"), 2, "reservation restores into fresh component")
	locations.queue_free()
	restored.queue_free()


func _test_missing_inventory_normalizes_to_empty() -> void:
	var locations := _make_locations()
	locations.apply_save_data({"records": {"inventory.legacy": {"npc_id": "inventory.legacy"}}})
	var live := _make_npc("inventory.legacy")
	live.get_inventory().add(&"cooked_slime_meat", 2)
	_expect_true(locations.register_npc(live), "legacy NPC record registers")
	_expect_equal(live.get_inventory().get_all_quantities(), {}, "missing old inventory restores as empty")
	_expect_equal(
		locations.get_record_snapshot("inventory.legacy")["inventory"],
		InventoryModel.get_empty_save_data(),
		"missing old inventory is normalized in the record"
	)
	locations.queue_free()
	live.queue_free()


func _test_malformed_inventory_preserves_live_state() -> void:
	var locations := _make_locations()
	locations.apply_save_data({"records": {"inventory.malformed": {
		"npc_id": "inventory.malformed",
		"inventory": {
			"version": 1,
			"quantities": {"raw_slime_meat": 2},
			"reservations": {"invalid": {"raw_slime_meat": 3}},
		},
	}}})
	var live := _make_npc("inventory.malformed")
	live.get_inventory().add(&"slime_gel", 3)
	_expect_true(locations.register_npc(live), "malformed record is repaired during accepted registration")
	_expect_equal(live.get_inventory().get_quantity(&"slime_gel"), 3, "malformed restore preserves valid live stock")
	_expect_equal(live.get_inventory().get_quantity(&"raw_slime_meat"), 0, "malformed restore applies no partial stock")
	var repaired: Dictionary = locations.get_record_snapshot("inventory.malformed")["inventory"]
	_expect_equal(int(repaired["quantities"].get("slime_gel", 0)), 3, "malformed record is replaced by live snapshot")
	_expect_true(repaired["reservations"].is_empty(), "malformed reservation is not retained")
	locations.queue_free()
	live.queue_free()


func _test_offscreen_update_and_save_round_trip() -> void:
	var locations := _make_locations()
	var live := _make_npc("inventory.roundtrip")
	live.get_inventory().add(&"raw_slime_meat", 5)
	live.get_inventory().reserve_items(&"persistent.reservation", {&"raw_slime_meat": 2})
	locations.register_npc(live)
	locations.unregister_npc(live)
	live.queue_free()

	var record: Dictionary = locations.get_record_snapshot("inventory.roundtrip")
	var inventory_before: Dictionary = record["inventory"].duplicate(true)
	record["node_state"] = {"unrelated_simulation_value": 42}
	locations.update_simulated_record("inventory.roundtrip", record)
	_expect_equal(
		locations.get_record_snapshot("inventory.roundtrip")["inventory"],
		inventory_before,
		"unrelated off-screen update preserves inventory"
	)

	var save_data: Dictionary = locations.get_save_data()
	var restored_locations := _make_locations()
	restored_locations.apply_save_data(save_data)
	_expect_equal(
		restored_locations.get_record_snapshot("inventory.roundtrip")["inventory"],
		inventory_before,
		"NPC save-data round trip preserves quantities and reservations"
	)
	locations.queue_free()
	restored_locations.queue_free()


func _test_rejected_registration_does_not_mutate_record() -> void:
	var locations := _make_locations()
	var canonical := _make_npc("inventory.duplicate")
	canonical.get_inventory().add(&"slime_gel", 2)
	_expect_true(locations.register_npc(canonical), "canonical duplicate-test NPC registers")
	var before_duplicate: Dictionary = locations.get_record_snapshot("inventory.duplicate")["inventory"]
	var duplicate := _make_npc("inventory.duplicate")
	_expect_false(locations.register_npc(duplicate), "duplicate live NPC is rejected")
	_expect_equal(locations.get_record_snapshot("inventory.duplicate")["inventory"], before_duplicate, "duplicate cannot overwrite record inventory")

	locations.apply_save_data({"records": {"inventory.wrong_scene": {
		"npc_id": "inventory.wrong_scene",
		"scene_path": "res://not_the_current_scene.tscn",
		"inventory": before_duplicate,
	}}})
	var wrong_scene := _make_npc("inventory.wrong_scene")
	_expect_false(locations.register_npc(wrong_scene), "wrong-scene NPC is rejected")
	_expect_equal(locations.get_record_snapshot("inventory.wrong_scene")["inventory"], before_duplicate, "wrong-scene NPC cannot overwrite record inventory")
	locations.queue_free()
	canonical.queue_free()
	duplicate.queue_free()
	wrong_scene.queue_free()


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		_fail("%s: expected %s, got %s" % [message, str(expected), str(actual)])


func _expect_true(value: bool, message: String) -> void:
	if not value:
		_fail(message)


func _expect_false(value: bool, message: String) -> void:
	if value:
		_fail(message)


func _fail(message: String) -> void:
	_failures.append(message)
