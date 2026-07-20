class_name PlayerEquipmentComponent
extends Node

signal equipment_changed(slot_id: StringName, previous_item_id: StringName, new_item_id: StringName)

const WEAPON_SLOT: StringName = &"weapon"
const WEAPON_RESERVATION_ID: StringName = &"player_equipment:weapon"

var _inventory: InventoryModel
var _catalog := ItemCatalog.new()
var _weapon_item_id: StringName = &""


func bind_inventory(inventory: InventoryModel) -> void:
	_inventory = inventory
	if not _catalog.load_definitions():
		push_warning("Player equipment catalog errors: %s" % str(_catalog.get_validation_errors()))


func can_equip(item_id: StringName) -> Dictionary:
	if _inventory == null:
		return _failed("inventory_unavailable", "Player inventory is unavailable.")
	var normalized_id := StringName(String(item_id).strip_edges())
	var definition := _catalog.get_definition(normalized_id)
	if definition == null:
		return _failed("item_not_found", "Item definition was not found.")
	var profile := definition.equipment_profile
	if profile == null or not profile.is_valid_profile():
		return _failed("not_equipment", "Item has no valid equipment profile.")
	if profile.slot_id != WEAPON_SLOT:
		return _failed("unsupported_slot", "Only the weapon equipment slot is supported.")
	if normalized_id == _weapon_item_id:
		return _succeeded("Item is already equipped.")
	if not _inventory.has_available(normalized_id, 1):
		return _failed("item_unavailable", "No available copy can be equipped.")
	return _succeeded("Item can be equipped.")


func equip(item_id: StringName) -> Dictionary:
	var check := can_equip(item_id)
	if not bool(check.get("success", false)):
		return check
	var new_item_id := StringName(String(item_id).strip_edges())
	if new_item_id == _weapon_item_id:
		return check

	var previous_item_id := _weapon_item_id
	var previous_had_reservation := _inventory.has_reservation(WEAPON_RESERVATION_ID)
	if previous_had_reservation:
		var release_result := _inventory.release_reservation(WEAPON_RESERVATION_ID)
		if not release_result.success:
			return _failed("release_failed", release_result.message)

	var reserve_result := _inventory.reserve_items(WEAPON_RESERVATION_ID, {new_item_id: 1})
	if not reserve_result.success:
		if previous_item_id != &"" and previous_had_reservation:
			var restore_result := _inventory.reserve_items(
				WEAPON_RESERVATION_ID, {previous_item_id: 1}
			)
			if not restore_result.success:
				_weapon_item_id = &""
				equipment_changed.emit(WEAPON_SLOT, previous_item_id, &"")
				return _failed("rollback_failed", "New weapon reservation failed and the previous reservation could not be restored.")
		return _failed("reserve_failed", reserve_result.message)

	_weapon_item_id = new_item_id
	equipment_changed.emit(WEAPON_SLOT, previous_item_id, new_item_id)
	return _succeeded("Weapon equipped.")


func unequip(slot_id: StringName) -> Dictionary:
	if slot_id != WEAPON_SLOT:
		return _failed("unsupported_slot", "Only the weapon equipment slot is supported.")
	if _inventory == null:
		return _failed("inventory_unavailable", "Player inventory is unavailable.")
	if _weapon_item_id == &"":
		if _inventory.has_reservation(WEAPON_RESERVATION_ID):
			var stale_release_result := _inventory.release_reservation(WEAPON_RESERVATION_ID)
			if not stale_release_result.success:
				return _failed("release_failed", stale_release_result.message)
		return _succeeded("Weapon slot is already empty.")

	var previous_item_id := _weapon_item_id
	if _inventory.has_reservation(WEAPON_RESERVATION_ID):
		var release_result := _inventory.release_reservation(WEAPON_RESERVATION_ID)
		if not release_result.success:
			return _failed("release_failed", release_result.message)
	_weapon_item_id = &""
	equipment_changed.emit(WEAPON_SLOT, previous_item_id, &"")
	return _succeeded("Weapon unequipped.")


func get_equipped_item_id(slot_id: StringName) -> StringName:
	return _weapon_item_id if slot_id == WEAPON_SLOT else &""


func get_equipped_profile(slot_id: StringName) -> EquipmentProfile:
	var item_id := get_equipped_item_id(slot_id)
	if item_id == &"":
		return null
	var definition := _catalog.get_definition(item_id)
	return definition.equipment_profile if definition != null else null


func is_equipped(item_id: StringName) -> bool:
	return _weapon_item_id != &"" and _weapon_item_id == StringName(String(item_id).strip_edges())


func get_save_data() -> Dictionary:
	return {"weapon": String(_weapon_item_id)}


func apply_save_data(data: Dictionary) -> Dictionary:
	if _inventory == null:
		return _failed("inventory_unavailable", "Player inventory is unavailable.")
	var previous_item_id := _weapon_item_id
	var saved_item_id: StringName = &""
	if data.has("weapon") and (typeof(data["weapon"]) == TYPE_STRING or typeof(data["weapon"]) == TYPE_STRING_NAME):
		saved_item_id = StringName(String(data["weapon"]).strip_edges())

	var reservation_is_exact := false
	if _inventory.has_reservation(WEAPON_RESERVATION_ID):
		var reservation := _inventory.get_reservation(WEAPON_RESERVATION_ID)
		reservation_is_exact = (
			saved_item_id != &""
			and reservation.size() == 1
			and int(reservation.get(String(saved_item_id), 0)) == 1
		)
		if not reservation_is_exact:
			_inventory.release_reservation(WEAPON_RESERVATION_ID)

	if saved_item_id == &"" or not _is_valid_owned_weapon(saved_item_id):
		_weapon_item_id = &""
		_emit_change_if_needed(previous_item_id)
		return _succeeded("Weapon slot restored empty.")

	if not reservation_is_exact:
		var reserve_result := _inventory.reserve_items(
			WEAPON_RESERVATION_ID, {saved_item_id: 1}
		)
		if not reserve_result.success:
			_weapon_item_id = &""
			_emit_change_if_needed(previous_item_id)
			return _failed("reconcile_failed", reserve_result.message)

	_weapon_item_id = saved_item_id
	_emit_change_if_needed(previous_item_id)
	return _succeeded("Equipment restored.")


func _is_valid_owned_weapon(item_id: StringName) -> bool:
	var definition := _catalog.get_definition(item_id)
	return (
		definition != null
		and definition.equipment_profile != null
		and definition.equipment_profile.is_valid_profile()
		and definition.equipment_profile.slot_id == WEAPON_SLOT
		and _inventory.get_quantity(item_id) >= 1
	)


func _emit_change_if_needed(previous_item_id: StringName) -> void:
	if previous_item_id != _weapon_item_id:
		equipment_changed.emit(WEAPON_SLOT, previous_item_id, _weapon_item_id)


func _succeeded(message: String) -> Dictionary:
	return {"success": true, "reason": "", "message": message}


func _failed(reason: String, message: String) -> Dictionary:
	return {"success": false, "reason": reason, "message": message}
