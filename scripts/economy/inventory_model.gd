class_name InventoryModel
extends RefCounted

signal item_quantity_changed(item_id: StringName, total_quantity: int, available_quantity: int, reason: StringName)
signal reservation_changed(reservation_id: StringName, reason: StringName)
signal inventory_reset()

const SAVE_VERSION: int = 1

# String keys and positive integer values keep the authoritative state JSON-safe.
var _quantities: Dictionary = {}
var _reservations: Dictionary = {}


static func get_empty_save_data() -> Dictionary:
	# Keep the empty record schema owned by the inventory model itself.
	return _build_save_data({}, {})


func get_quantity(item_id: StringName) -> int:
	return int(_quantities.get(_normalize_id(item_id), 0))


func get_reserved_quantity(item_id: StringName) -> int:
	var key := _normalize_id(item_id)
	var total := 0
	for reservation: Dictionary in _reservations.values():
		total += int(reservation.get(key, 0))
	return total


func get_available_quantity(item_id: StringName) -> int:
	return get_quantity(item_id) - get_reserved_quantity(item_id)


func has_available(item_id: StringName, quantity: int) -> bool:
	return _is_valid_id(_normalize_id(item_id)) and quantity > 0 and get_available_quantity(item_id) >= quantity


func has_reservation(reservation_id: StringName) -> bool:
	return _reservations.has(_normalize_id(reservation_id))


func get_reservation(reservation_id: StringName) -> Dictionary:
	var reservation: Dictionary = _reservations.get(_normalize_id(reservation_id), {})
	return reservation.duplicate(true)


func get_all_quantities() -> Dictionary:
	return _quantities.duplicate(true)


func get_all_reservations() -> Dictionary:
	return _reservations.duplicate(true)


func add(item_id: StringName, quantity: int) -> InventoryResult:
	var key := _normalize_id(item_id)
	var validation := _validate_item_and_quantity(key, quantity)
	if validation != null:
		return validation
	var current := int(_quantities.get(key, 0))
	if current > 9223372036854775807 - quantity:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_QUANTITY,
			"Adding this quantity would exceed the supported integer range.", StringName(key), quantity)
	_quantities[key] = current + quantity
	_emit_item_change(key, &"add")
	return InventoryResult.succeeded("Item quantity added.")


func remove(item_id: StringName, quantity: int) -> InventoryResult:
	var key := _normalize_id(item_id)
	var validation := _validate_item_and_quantity(key, quantity)
	if validation != null:
		return validation
	var available := get_available_quantity(StringName(key))
	if available < quantity:
		return InventoryResult.failed(
			InventoryResult.Code.INSUFFICIENT_AVAILABLE_QUANTITY,
			"Not enough available quantity to remove.", StringName(key), quantity, available)
	var remaining := int(_quantities.get(key, 0)) - quantity
	if remaining == 0:
		_quantities.erase(key)
	else:
		_quantities[key] = remaining
	_emit_item_change(key, &"remove")
	return InventoryResult.succeeded("Item quantity removed.")


func reserve_items(reservation_id: StringName, requested_items: Dictionary) -> InventoryResult:
	var reservation_key := _normalize_id(reservation_id)
	if not _is_valid_id(reservation_key):
		return InventoryResult.failed(InventoryResult.Code.RESERVATION_ID_REQUIRED, "A non-empty reservation ID is required.")
	if _reservations.has(reservation_key):
		return InventoryResult.failed(
			InventoryResult.Code.RESERVATION_ALREADY_EXISTS,
			"Reservation ID already exists.", &"", 0, 0, StringName(reservation_key))
	var normalized_result := _normalize_requested_items(requested_items, StringName(reservation_key))
	if normalized_result["error"] != null:
		return normalized_result["error"] as InventoryResult
	var normalized: Dictionary = normalized_result["items"]
	for key: String in normalized:
		var requested := int(normalized[key])
		var available := get_available_quantity(StringName(key))
		if available < requested:
			return InventoryResult.failed(
				InventoryResult.Code.INSUFFICIENT_AVAILABLE_QUANTITY,
				"Not enough available quantity to reserve.", StringName(key), requested, available, StringName(reservation_key))
	_reservations[reservation_key] = normalized.duplicate(true)
	for key: String in normalized:
		_emit_item_change(key, &"reserve")
	reservation_changed.emit(StringName(reservation_key), &"reserve")
	return InventoryResult.succeeded("Items reserved.", StringName(reservation_key))


func consume_reservation(reservation_id: StringName) -> InventoryResult:
	var key := _normalize_id(reservation_id)
	if not _reservations.has(key):
		return InventoryResult.failed(
			InventoryResult.Code.RESERVATION_NOT_FOUND,
			"Reservation was not found.", &"", 0, 0, StringName(key))
	var reservation: Dictionary = _reservations[key]
	# Recheck the invariant so corruption can never produce a partial consumption.
	for item_key: String in reservation:
		if int(_quantities.get(item_key, 0)) < int(reservation[item_key]):
			return InventoryResult.failed(
				InventoryResult.Code.INVALID_RESERVATION_DATA,
				"Reservation exceeds stored inventory.", StringName(item_key), int(reservation[item_key]), int(_quantities.get(item_key, 0)), StringName(key))
	for item_key: String in reservation:
		var remaining := int(_quantities[item_key]) - int(reservation[item_key])
		if remaining == 0:
			_quantities.erase(item_key)
		else:
			_quantities[item_key] = remaining
	_reservations.erase(key)
	for item_key: String in reservation:
		_emit_item_change(item_key, &"consume_reservation")
	reservation_changed.emit(StringName(key), &"consume_reservation")
	return InventoryResult.succeeded("Reservation consumed.", StringName(key))


func release_reservation(reservation_id: StringName) -> InventoryResult:
	var key := _normalize_id(reservation_id)
	if not _reservations.has(key):
		return InventoryResult.failed(
			InventoryResult.Code.RESERVATION_NOT_FOUND,
			"Reservation was not found.", &"", 0, 0, StringName(key))
	var reservation: Dictionary = _reservations[key]
	_reservations.erase(key)
	for item_key: String in reservation:
		_emit_item_change(item_key, &"release_reservation")
	reservation_changed.emit(StringName(key), &"release_reservation")
	return InventoryResult.succeeded("Reservation released.", StringName(key))


func release_all_reservations() -> InventoryResult:
	if _reservations.is_empty():
		return InventoryResult.succeeded("Inventory has no reservations to release.")
	var reservation_ids := _sorted_keys(_reservations)
	var affected_items: Dictionary = {}
	for reservation: Dictionary in _reservations.values():
		for item_key: String in reservation:
			affected_items[item_key] = true
	_reservations.clear()
	for item_key: String in _sorted_keys(affected_items):
		_emit_item_change(item_key, &"release_all_reservations")
	for reservation_key: String in reservation_ids:
		reservation_changed.emit(StringName(reservation_key), &"release_all_reservations")
	return InventoryResult.succeeded("All reservations released.")


func clear() -> void:
	_quantities.clear()
	_reservations.clear()
	inventory_reset.emit()


func get_save_data() -> Dictionary:
	return _build_save_data(
		_sorted_copy(_quantities),
		_sorted_nested_copy(_reservations)
	)


func apply_save_data(data: Dictionary) -> InventoryResult:
	var parsed := _parse_save_data(data)
	if parsed["error"] != null:
		return parsed["error"] as InventoryResult
	_quantities = parsed["quantities"]
	_reservations = parsed["reservations"]
	inventory_reset.emit()
	for item_key: String in _sorted_keys(_quantities):
		_emit_item_change(item_key, &"load")
	for reservation_key: String in _sorted_keys(_reservations):
		reservation_changed.emit(StringName(reservation_key), &"load")
	return InventoryResult.succeeded("Inventory loaded.")


func _validate_item_and_quantity(key: String, quantity: int) -> InventoryResult:
	if not _is_valid_id(key):
		return InventoryResult.failed(InventoryResult.Code.INVALID_ITEM_ID, "A non-empty item ID is required.")
	if quantity <= 0:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_QUANTITY,
			"Quantity must be greater than zero.", StringName(key), quantity)
	return null


func _normalize_requested_items(requested_items: Dictionary, reservation_id: StringName) -> Dictionary:
	if requested_items.is_empty():
		return {"items": {}, "error": InventoryResult.failed(
			InventoryResult.Code.INVALID_RESERVATION_DATA, "A reservation must contain at least one item.", &"", 0, 0, reservation_id)}
	var normalized: Dictionary = {}
	for raw_key: Variant in requested_items:
		if typeof(raw_key) != TYPE_STRING and typeof(raw_key) != TYPE_STRING_NAME:
			return {"items": {}, "error": InventoryResult.failed(
				InventoryResult.Code.INVALID_ITEM_ID, "Reservation item IDs must be strings.", &"", 0, 0, reservation_id)}
		var key := String(raw_key).strip_edges()
		if not _is_valid_id(key):
			return {"items": {}, "error": InventoryResult.failed(
				InventoryResult.Code.INVALID_ITEM_ID, "A non-empty item ID is required.", &"", 0, 0, reservation_id)}
		if normalized.has(key):
			return {"items": {}, "error": InventoryResult.failed(
				InventoryResult.Code.INVALID_RESERVATION_DATA, "Duplicate normalized item ID in reservation.", StringName(key), 0, 0, reservation_id)}
		var raw_quantity: Variant = requested_items[raw_key]
		if typeof(raw_quantity) != TYPE_INT or int(raw_quantity) <= 0:
			return {"items": {}, "error": InventoryResult.failed(
				InventoryResult.Code.INVALID_QUANTITY, "Reservation quantities must be positive integers.", StringName(key), int(raw_quantity) if typeof(raw_quantity) == TYPE_INT else 0, 0, reservation_id)}
		normalized[key] = int(raw_quantity)
	return {"items": normalized, "error": null}


func _parse_save_data(data: Dictionary) -> Dictionary:
	var failure := func(message: String) -> Dictionary:
		return {"quantities": {}, "reservations": {}, "error": InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, message)}
	if data.is_empty():
		return failure.call("Empty save data is not a versioned inventory save.")
	if not data.has("version") or not _is_whole_number_equal(data["version"], SAVE_VERSION):
		return failure.call("Unsupported or malformed inventory save version.")
	if not data.has("quantities") or typeof(data["quantities"]) != TYPE_DICTIONARY:
		return failure.call("Inventory save quantities must be a dictionary.")
	if not data.has("reservations") or typeof(data["reservations"]) != TYPE_DICTIONARY:
		return failure.call("Inventory save reservations must be a dictionary.")
	var quantities_result := _parse_positive_quantity_map(data["quantities"], "quantity")
	if quantities_result["error"] != "":
		return failure.call(quantities_result["error"])
	var parsed_quantities: Dictionary = quantities_result["values"]
	var parsed_reservations: Dictionary = {}
	var reserved_totals: Dictionary = {}
	for raw_reservation_id: Variant in (data["reservations"] as Dictionary):
		if typeof(raw_reservation_id) != TYPE_STRING and typeof(raw_reservation_id) != TYPE_STRING_NAME:
			return failure.call("Reservation IDs must be strings.")
		var reservation_key := String(raw_reservation_id).strip_edges()
		if not _is_valid_id(reservation_key) or parsed_reservations.has(reservation_key):
			return failure.call("Reservation IDs must be non-empty and unique after normalization.")
		var raw_reservation: Variant = data["reservations"][raw_reservation_id]
		if typeof(raw_reservation) != TYPE_DICTIONARY or (raw_reservation as Dictionary).is_empty():
			return failure.call("Each reservation must be a non-empty dictionary.")
		var reservation_result := _parse_positive_quantity_map(raw_reservation, "reservation quantity")
		if reservation_result["error"] != "":
			return failure.call(reservation_result["error"])
		var reservation: Dictionary = reservation_result["values"]
		for item_key: String in reservation:
			var already_reserved := int(reserved_totals.get(item_key, 0))
			var total_quantity := int(parsed_quantities.get(item_key, 0))
			var reservation_quantity := int(reservation[item_key])
			if reservation_quantity > total_quantity or already_reserved > total_quantity - reservation_quantity:
				return failure.call("Combined reservations exceed total quantity for item '%s'." % item_key)
			reserved_totals[item_key] = already_reserved + reservation_quantity
		parsed_reservations[reservation_key] = reservation
	return {"quantities": parsed_quantities, "reservations": parsed_reservations, "error": null}


func _parse_positive_quantity_map(raw_map: Dictionary, label: String) -> Dictionary:
	var values: Dictionary = {}
	for raw_key: Variant in raw_map:
		if typeof(raw_key) != TYPE_STRING and typeof(raw_key) != TYPE_STRING_NAME:
			return {"values": {}, "error": "Inventory item IDs must be strings."}
		var key := String(raw_key).strip_edges()
		if not _is_valid_id(key) or values.has(key):
			return {"values": {}, "error": "Item IDs must be non-empty and unique after normalization."}
		var raw_value: Variant = raw_map[raw_key]
		if not _is_positive_whole_number(raw_value):
			return {"values": {}, "error": "Stored %s for '%s' must be a positive whole number." % [label, key]}
		values[key] = int(raw_value)
	return {"values": values, "error": ""}


func _is_positive_whole_number(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return int(value) > 0
	if typeof(value) == TYPE_FLOAT:
		var number := float(value)
		# Beyond 2^53 a JSON float cannot represent every integer exactly.
		return is_finite(number) and number > 0.0 and number == floor(number) and number <= 9007199254740991.0
	return false


func _is_whole_number_equal(value: Variant, expected: int) -> bool:
	if typeof(value) == TYPE_INT:
		return int(value) == expected
	if typeof(value) == TYPE_FLOAT:
		var number := float(value)
		return is_finite(number) and number == float(expected)
	return false


func _emit_item_change(key: String, reason: StringName) -> void:
	item_quantity_changed.emit(StringName(key), int(_quantities.get(key, 0)), get_available_quantity(StringName(key)), reason)


func _normalize_id(value: StringName) -> String:
	return String(value).strip_edges()


func _is_valid_id(key: String) -> bool:
	return not key.is_empty()


func _sorted_keys(source: Dictionary) -> Array:
	var keys: Array = source.keys()
	keys.sort()
	return keys


func _sorted_copy(source: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key: String in _sorted_keys(source):
		result[key] = source[key]
	return result


func _sorted_nested_copy(source: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key: String in _sorted_keys(source):
		result[key] = _sorted_copy(source[key])
	return result


static func _build_save_data(quantities: Dictionary, reservations: Dictionary) -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"quantities": quantities,
		"reservations": reservations,
	}
