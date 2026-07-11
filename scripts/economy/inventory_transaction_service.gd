class_name InventoryTransactionService
extends RefCounted


static func transfer_item(
		source: InventoryModel,
		destination: InventoryModel,
		item_id: StringName,
		quantity: int
) -> InventoryResult:
	if source == null or destination == null or source == destination:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"A transfer requires two distinct inventory models.",
			item_id,
			quantity
		)
	if quantity <= 0:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_QUANTITY,
			"Transfer quantity must be greater than zero.",
			item_id,
			quantity
		)
	var available := source.get_available_quantity(item_id)
	if available < quantity:
		return InventoryResult.failed(
			InventoryResult.Code.INSUFFICIENT_AVAILABLE_QUANTITY,
			"Source inventory does not have enough available quantity.",
			item_id,
			quantity,
			available
		)

	var source_before := source.get_save_data()
	var destination_before := destination.get_save_data()
	var remove_result := source.remove(item_id, quantity)
	if not remove_result.success:
		return remove_result
	var add_result := destination.add(item_id, quantity)
	if add_result.success:
		return InventoryResult.succeeded("Item quantity transferred.")

	# Restore both snapshots so a failed destination add cannot lose or duplicate stock.
	var source_rollback := source.apply_save_data(source_before)
	var destination_rollback := destination.apply_save_data(destination_before)
	if not source_rollback.success or not destination_rollback.success:
		push_error("Inventory transfer rollback failed; inventory invariants may be compromised.")
	return add_result
