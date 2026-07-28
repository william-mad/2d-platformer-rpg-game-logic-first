class_name InventoryTransactionService
extends RefCounted


static func transfer_item(
		source: InventoryModel,
		destination: InventoryModel,
		item_id: StringName,
		quantity: int
) -> InventoryResult:
	var requested_items := {
		String(item_id): quantity,
	}
	return transfer_items(source, destination, requested_items)


static func transfer_items(
		source: InventoryModel,
		destination: InventoryModel,
		requested_items: Dictionary
) -> InventoryResult:
	if source == null or destination == null or source == destination:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"A transfer requires two distinct inventory models.",
			&"",
			0
		)
	if requested_items.is_empty():
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_QUANTITY,
			"A transfer must request at least one item."
		)

	var source_before := source.get_save_data()
	var destination_before := destination.get_save_data()
	var source_staged := InventoryModel.new()
	var destination_staged := InventoryModel.new()
	var result := source_staged.apply_save_data(source_before)
	if not result.success:
		return result
	result = destination_staged.apply_save_data(destination_before)
	if not result.success:
		return result

	var normalized_items: Dictionary = {}
	var sorted_ids: Array[String] = []
	for raw_id: Variant in requested_items:
		if typeof(raw_id) != TYPE_STRING and typeof(raw_id) != TYPE_STRING_NAME:
			return InventoryResult.failed(
				InventoryResult.Code.INVALID_ITEM_ID,
				"Transfer item IDs must be strings."
			)
		var item_key := String(raw_id).strip_edges()
		if item_key.is_empty() or normalized_items.has(item_key):
			return InventoryResult.failed(
				InventoryResult.Code.INVALID_ITEM_ID,
				"Transfer item IDs must be non-empty and unique after normalization.",
				StringName(item_key)
			)
		var raw_quantity: Variant = requested_items[raw_id]
		if typeof(raw_quantity) != TYPE_INT or int(raw_quantity) <= 0:
			return InventoryResult.failed(
				InventoryResult.Code.INVALID_QUANTITY,
				"Transfer quantities must be positive integers.",
				StringName(item_key),
				int(raw_quantity) if typeof(raw_quantity) == TYPE_INT else 0
			)
		normalized_items[item_key] = int(raw_quantity)
		sorted_ids.append(item_key)
	sorted_ids.sort()

	# Validate every source quantity before either authoritative inventory is touched.
	for item_key: String in sorted_ids:
		var quantity := int(normalized_items[item_key])
		var available := source.get_available_quantity(StringName(item_key))
		if available < quantity:
			return InventoryResult.failed(
				InventoryResult.Code.INSUFFICIENT_AVAILABLE_QUANTITY,
				"Source inventory does not have enough available quantity.",
				StringName(item_key),
				quantity,
				available
			)

	# Stage the complete operation first, including destination overflow checks.
	for item_key: String in sorted_ids:
		result = source_staged.remove(StringName(item_key), int(normalized_items[item_key]))
		if not result.success:
			return result
	for item_key: String in sorted_ids:
		result = destination_staged.add(StringName(item_key), int(normalized_items[item_key]))
		if not result.success:
			return result

	result = source.apply_save_data(source_staged.get_save_data())
	if not result.success:
		_restore_snapshots(source, destination, source_before, destination_before)
		return result
	result = destination.apply_save_data(destination_staged.get_save_data())
	if not result.success:
		_restore_snapshots(source, destination, source_before, destination_before)
		return result

	return InventoryResult.succeeded(
		"Transferred %d item type%s." % [
			sorted_ids.size(),
			"" if sorted_ids.size() == 1 else "s",
		]
	)


static func _restore_snapshots(
		source: InventoryModel,
		destination: InventoryModel,
		source_before: Dictionary,
		destination_before: Dictionary
) -> void:
	var source_rollback := source.apply_save_data(source_before)
	var destination_rollback := destination.apply_save_data(destination_before)
	if not source_rollback.success or not destination_rollback.success:
		push_error("Inventory transfer rollback failed; inventory invariants may be compromised.")
