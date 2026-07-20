extends SceneTree

const ScreenScene := preload("res://ui/inventory/player_inventory_screen.tscn")

var _failures: Array[String] = []


class EquipmentPlayerStub:
	extends Node2D

	signal hunger_changed(current_hunger: float, changed_by: float)

	var hunger: float = 20.0


class AttackSourceStub:
	extends Node

	var equipment: PlayerEquipmentComponent

	func get_attack_equipment_modifiers(attack_definition: AttackDefinition) -> Dictionary:
		var modifiers := {"damage_multiplier": 1.0, "knockout_multiplier": 1.0}
		var profile := equipment.get_equipped_profile(&"weapon") if equipment != null else null
		if profile != null and profile.is_valid_profile() and profile.applies_to_attack(attack_definition.tags):
			modifiers["damage_multiplier"] = profile.damage_multiplier
			modifiers["knockout_multiplier"] = profile.knockout_multiplier
		return modifiers


class TransferPlayerStub:
	extends Node2D

	var inventory := InventoryModel.new()
	var equipment := PlayerEquipmentComponent.new()

	func _init() -> void:
		equipment.name = "PlayerEquipment"
		add_child(equipment)
		equipment.bind_inventory(inventory)

	func get_save_data() -> Dictionary:
		return {
			"inventory": inventory.get_save_data(),
			"equipment": equipment.get_save_data(),
		}

	func apply_save_data(data: Dictionary) -> void:
		var inventory_data = data.get("inventory", {})
		if inventory_data is Dictionary:
			inventory.apply_save_data(inventory_data)
		var equipment_data = data.get("equipment", {})
		equipment.apply_save_data(equipment_data if equipment_data is Dictionary else {})


func _initialize() -> void:
	await process_frame
	_test_catalog_and_profile()
	_test_equip_unequip_and_replacement()
	_test_save_reconciliation()
	_test_scene_transition_transfer()
	_test_combat_modifiers()
	await _test_inventory_ui()
	_finish()


func _test_catalog_and_profile() -> void:
	var catalog := ItemCatalog.new()
	_expect(catalog.load_definitions(), "item catalog validates")
	var sword := catalog.get_definition(&"wooden_sword")
	_expect(sword != null, "Wooden Sword exists in the catalog")
	if sword == null:
		return
	_expect(sword.maximum_stack == 1, "Wooden Sword has a single-item stack")
	_expect(sword.equipment_profile != null and sword.equipment_profile.is_valid_profile(), "Wooden Sword has a valid equipment profile")
	_expect(sword.equipment_profile.slot_id == &"weapon", "Wooden Sword uses the weapon slot")
	_expect(sword.equipment_profile.applicable_attack_tags == [&"melee"], "Wooden Sword explicitly targets melee attacks")


func _test_equip_unequip_and_replacement() -> void:
	var inventory := InventoryModel.new()
	_expect(inventory.add(&"wooden_sword", 1).success, "Wooden Sword can be added")
	var equipment := PlayerEquipmentComponent.new()
	equipment.bind_inventory(inventory)
	var change_count := [0]
	equipment.equipment_changed.connect(func(_slot: StringName, _old: StringName, _new: StringName) -> void: change_count[0] += 1)

	_expect(bool(equipment.equip(&"wooden_sword").get("success")), "Wooden Sword equips")
	_expect(equipment.get_equipped_item_id(&"weapon") == &"wooden_sword", "weapon slot contains Wooden Sword")
	_expect(inventory.get_reservation(PlayerEquipmentComponent.WEAPON_RESERVATION_ID) == {"wooden_sword": 1}, "equipment owns exactly one stable reservation")
	_expect(inventory.get_quantity(&"wooden_sword") == 1, "equipped item remains in total inventory")
	_expect(inventory.get_available_quantity(&"wooden_sword") == 0, "equipped item is unavailable")
	_expect(not inventory.remove(&"wooden_sword", 1).success, "reserved weapon cannot be removed or dumped")
	var merchant_inventory := InventoryModel.new()
	merchant_inventory.add(TradeService.GOLD_ITEM_ID, 100)
	_expect(not TradeService.sell_to_merchant(inventory, merchant_inventory, &"wooden_sword", 1, 10).success, "reserved weapon cannot be sold")
	_expect(bool(equipment.equip(&"wooden_sword").get("success")), "equipping current weapon is idempotent")
	_expect(change_count[0] == 1, "idempotent equip emits no duplicate change")

	var replacement_profile := EquipmentProfile.new()
	replacement_profile.slot_id = &"weapon"
	var replacement := ItemDefinition.new()
	replacement.id = &"test_blade"
	replacement.display_name = "Test Blade"
	replacement.equipment_profile = replacement_profile
	var catalog: ItemCatalog = equipment.get("_catalog")
	_expect(catalog.register_definition(replacement), "focused replacement definition registers")
	_expect(inventory.add(&"test_blade", 1).success, "replacement weapon can be added")
	_expect(bool(equipment.equip(&"test_blade").get("success")), "weapon can be replaced")
	_expect(inventory.get_available_quantity(&"wooden_sword") == 1, "replacement releases previous weapon")
	_expect(inventory.get_available_quantity(&"test_blade") == 0, "replacement reserves new weapon")

	_expect(bool(equipment.equip(&"wooden_sword").get("success")), "Wooden Sword can be re-equipped")
	var mutate_on_release := true
	inventory.reservation_changed.connect(func(reservation_id: StringName, reason: StringName) -> void:
		if mutate_on_release and reservation_id == PlayerEquipmentComponent.WEAPON_RESERVATION_ID and reason == &"release_reservation":
			mutate_on_release = false
			inventory.remove(&"test_blade", 1)
	)
	var failed_replace := equipment.equip(&"test_blade")
	_expect(not bool(failed_replace.get("success")), "failed new reservation reports failure")
	_expect(equipment.get_equipped_item_id(&"weapon") == &"wooden_sword", "failed replacement preserves previous equipment state")
	_expect(inventory.get_reservation(PlayerEquipmentComponent.WEAPON_RESERVATION_ID) == {"wooden_sword": 1}, "failed replacement restores previous reservation")

	_expect(bool(equipment.unequip(&"weapon").get("success")), "weapon unequips")
	_expect(equipment.get_equipped_item_id(&"weapon") == &"", "unequip clears weapon slot")
	_expect(not inventory.has_reservation(PlayerEquipmentComponent.WEAPON_RESERVATION_ID), "unequip releases equipment reservation")
	_expect(inventory.get_available_quantity(&"wooden_sword") == 1, "unequip restores availability")
	_expect(bool(equipment.unequip(&"weapon").get("success")), "empty-slot unequip is idempotent")
	equipment.free()


func _test_save_reconciliation() -> void:
	var inventory := InventoryModel.new()
	inventory.add(&"wooden_sword", 1)
	var equipment := PlayerEquipmentComponent.new()
	equipment.bind_inventory(inventory)
	equipment.equip(&"wooden_sword")
	var inventory_save := inventory.get_save_data()
	var equipment_save := equipment.get_save_data()

	var restored_inventory := InventoryModel.new()
	_expect(restored_inventory.apply_save_data(inventory_save).success, "inventory reservation restores")
	var restored_equipment := PlayerEquipmentComponent.new()
	restored_equipment.bind_inventory(restored_inventory)
	_expect(bool(restored_equipment.apply_save_data(equipment_save).get("success")), "semantic equipment state restores")
	_expect(restored_equipment.get_equipped_item_id(&"weapon") == &"wooden_sword", "restored weapon is equipped")
	_expect(restored_inventory.get_all_reservations().size() == 1, "existing exact reservation is adopted without duplication")

	var missing_reservation_inventory := InventoryModel.new()
	missing_reservation_inventory.add(&"wooden_sword", 1)
	var missing_reservation_equipment := PlayerEquipmentComponent.new()
	missing_reservation_equipment.bind_inventory(missing_reservation_inventory)
	_expect(bool(missing_reservation_equipment.apply_save_data(equipment_save).get("success")), "missing reservation is recreated")
	_expect(missing_reservation_inventory.get_reservation(PlayerEquipmentComponent.WEAPON_RESERVATION_ID) == {"wooden_sword": 1}, "recreated reservation is exact")

	var stale_inventory := InventoryModel.new()
	stale_inventory.add(&"wooden_sword", 1)
	stale_inventory.add(&"slime_gel", 2)
	stale_inventory.reserve_items(PlayerEquipmentComponent.WEAPON_RESERVATION_ID, {&"slime_gel": 1})
	stale_inventory.reserve_items(&"unrelated", {&"slime_gel": 1})
	var stale_equipment := PlayerEquipmentComponent.new()
	stale_equipment.bind_inventory(stale_inventory)
	_expect(bool(stale_equipment.apply_save_data(equipment_save).get("success")), "wrong equipment reservation is repaired")
	_expect(stale_inventory.get_reservation(PlayerEquipmentComponent.WEAPON_RESERVATION_ID) == {"wooden_sword": 1}, "wrong reservation now references saved weapon")
	_expect(stale_inventory.get_reservation(&"unrelated") == {"slime_gel": 1}, "unrelated reservation is untouched")

	var missing_weapon_inventory := InventoryModel.new()
	missing_weapon_inventory.add(&"slime_gel", 1)
	missing_weapon_inventory.reserve_items(PlayerEquipmentComponent.WEAPON_RESERVATION_ID, {&"slime_gel": 1})
	var missing_weapon_equipment := PlayerEquipmentComponent.new()
	missing_weapon_equipment.bind_inventory(missing_weapon_inventory)
	_expect(bool(missing_weapon_equipment.apply_save_data(equipment_save).get("success")), "missing saved weapon clears safely")
	_expect(missing_weapon_equipment.get_equipped_item_id(&"weapon") == &"", "missing saved weapon leaves slot empty")
	_expect(not missing_weapon_inventory.has_reservation(PlayerEquipmentComponent.WEAPON_RESERVATION_ID), "missing saved weapon removes stale equipment reservation")

	_expect(bool(restored_equipment.apply_save_data({}).get("success")), "older save without equipment remains valid")
	_expect(restored_equipment.get_equipped_item_id(&"weapon") == &"", "older save restores empty weapon slot")
	_expect(not restored_inventory.has_reservation(PlayerEquipmentComponent.WEAPON_RESERVATION_ID), "older save clears stale equipment reservation")
	equipment.free()
	restored_equipment.free()
	missing_reservation_equipment.free()
	stale_equipment.free()
	missing_weapon_equipment.free()


func _test_combat_modifiers() -> void:
	var inventory := InventoryModel.new()
	inventory.add(&"wooden_sword", 1)
	var equipment := PlayerEquipmentComponent.new()
	equipment.bind_inventory(inventory)
	equipment.equip(&"wooden_sword")
	var player := AttackSourceStub.new()
	player.equipment = equipment

	var melee := AttackDefinition.new()
	melee.damage = 4.0
	melee.knockout_damage = 8.0
	melee.active_seconds = 10.0
	melee.tags = [&"melee"]
	var hitbox := PlayerAttackHitbox.new()
	root.add_child(hitbox)
	hitbox.activate(melee, player, 1.0)
	_expect(is_equal_approx(hitbox.damage, 6.0), "equipped melee damage uses 1.5 multiplier")
	_expect(is_equal_approx(hitbox.knockout_damage, 8.0), "Wooden Sword leaves knockout damage unchanged")
	_expect(is_equal_approx(melee.damage, 4.0), "shared AttackDefinition damage is unchanged")

	var ranged := AttackDefinition.new()
	ranged.damage = 4.0
	ranged.knockout_damage = 8.0
	ranged.active_seconds = 10.0
	ranged.tags = [&"ranged"]
	hitbox.activate(ranged, player, 1.0)
	_expect(is_equal_approx(hitbox.damage, 4.0), "non-melee attack damage is unchanged")
	equipment.unequip(&"weapon")
	hitbox.activate(melee, player, 1.0)
	_expect(is_equal_approx(hitbox.damage, 4.0), "unequipped melee damage returns to normal")
	hitbox.cancel()
	hitbox.queue_free()
	player.free()
	equipment.free()


func _test_scene_transition_transfer() -> void:
	var runtime := root.get_node_or_null("PlayerRuntime")
	_expect(runtime != null, "PlayerRuntime is available for transition validation")
	if runtime == null:
		return
	runtime.call("clear_pending_player_transfer")
	var source := TransferPlayerStub.new()
	root.add_child(source)
	source.inventory.add(&"wooden_sword", 1)
	source.equipment.equip(&"wooden_sword")
	runtime.call("capture_player", source)
	var destination := TransferPlayerStub.new()
	root.add_child(destination)
	_expect(bool(runtime.call("apply_to_player", destination)), "PlayerRuntime applies captured player data")
	_expect(destination.equipment.get_equipped_item_id(&"weapon") == &"wooden_sword", "scene transition preserves equipped weapon")
	_expect(destination.inventory.get_reservation(PlayerEquipmentComponent.WEAPON_RESERVATION_ID) == {"wooden_sword": 1}, "scene transition preserves exactly one equipment reservation")
	source.free()
	destination.free()


func _test_inventory_ui() -> void:
	var inventory := InventoryModel.new()
	inventory.add(&"wooden_sword", 1)
	var owner := EquipmentPlayerStub.new()
	root.add_child(owner)
	var equipment := PlayerEquipmentComponent.new()
	equipment.name = "PlayerEquipment"
	owner.add_child(equipment)
	equipment.bind_inventory(inventory)
	var screen := ScreenScene.instantiate() as PlayerInventoryScreen
	root.add_child(screen)
	screen.bind_inventory(inventory, owner)
	screen.open_screen()
	await process_frame
	var equipment_button := screen.get_node("%EquipmentButton") as Button
	_expect(equipment_button.visible and equipment_button.text == "Equip", "equipment item shows Equip button")
	_expect(_contains_text(screen, "Equipment slot: Weapon"), "equipment details show slot")
	screen.call("_on_equipment_pressed")
	await process_frame
	_expect(equipment_button.text == "Unequip", "equipped item immediately shows Unequip")
	_expect((screen.get_node("%DumpButton") as Button).disabled, "equipped item cannot be dumped from the inventory UI")
	_expect(_contains_text(screen, "Equipped: Weapon"), "equipped indicator is shown")
	_expect(_contains_text(screen, "Total: 1 | Available: 0 | Reserved: 1"), "equipped item keeps total and displays reservation counts")
	screen.call("_on_equipment_pressed")
	await process_frame
	_expect(equipment_button.text == "Equip", "unequipped item immediately shows Equip")
	screen.free()
	owner.free()


func _contains_text(node: Node, expected_fragment: String) -> bool:
	var label := node as Label
	if label != null and expected_fragment in label.text:
		return true
	for child: Node in node.get_children():
		if _contains_text(child, expected_fragment):
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("PLAYER_EQUIPMENT_RUNTIME_OK")
		quit(0)
		return
	for failure: String in _failures:
		push_error(failure)
	quit(1)
