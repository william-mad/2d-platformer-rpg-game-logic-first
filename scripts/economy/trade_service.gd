class_name TradeService
extends RefCounted

const GOLD_ITEM_ID: StringName = &"gold_coin"
const MAX_INT: int = 9223372036854775807


static func buy_from_merchant(
	player_inventory: InventoryModel,
	merchant_inventory: InventoryModel,
	item_id: StringName,
	quantity: int,
	unit_price: int
) -> InventoryResult:
	return _exchange(merchant_inventory, player_inventory, player_inventory, merchant_inventory, item_id, quantity, unit_price)


static func sell_to_merchant(
	player_inventory: InventoryModel,
	merchant_inventory: InventoryModel,
	item_id: StringName,
	quantity: int,
	unit_price: int
) -> InventoryResult:
	return _exchange(player_inventory, merchant_inventory, merchant_inventory, player_inventory, item_id, quantity, unit_price)


static func _exchange(
	item_source: InventoryModel,
	item_destination: InventoryModel,
	gold_source: InventoryModel,
	gold_destination: InventoryModel,
	item_id: StringName,
	quantity: int,
	unit_price: int
) -> InventoryResult:
	if item_source == null or item_destination == null or item_source == item_destination:
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "A trade requires two distinct inventories.")
	if item_id == &"" or item_id == GOLD_ITEM_ID:
		return InventoryResult.failed(InventoryResult.Code.INVALID_ITEM_ID, "Gold cannot be traded as an ordinary item.", item_id, quantity)
	if quantity <= 0 or unit_price <= 0:
		return InventoryResult.failed(InventoryResult.Code.INVALID_QUANTITY, "Trade quantity and unit price must be positive.", item_id, quantity)
	if quantity > MAX_INT / unit_price:
		return InventoryResult.failed(InventoryResult.Code.INVALID_QUANTITY, "Trade total exceeds the supported integer range.", item_id, quantity)
	var total_price := quantity * unit_price
	if item_source.get_available_quantity(item_id) < quantity:
		return InventoryResult.failed(InventoryResult.Code.INSUFFICIENT_AVAILABLE_QUANTITY, "Seller lacks available unreserved stock.", item_id, quantity, item_source.get_available_quantity(item_id))
	if gold_source.get_available_quantity(GOLD_ITEM_ID) < total_price:
		return InventoryResult.failed(InventoryResult.Code.INSUFFICIENT_AVAILABLE_QUANTITY, "Buyer lacks available unreserved gold.", GOLD_ITEM_ID, total_price, gold_source.get_available_quantity(GOLD_ITEM_ID))

	var source_before := item_source.get_save_data()
	var destination_before := item_destination.get_save_data()
	var staged_source := InventoryModel.new()
	var staged_destination := InventoryModel.new()
	var staged_result := staged_source.apply_save_data(source_before)
	if not staged_result.success:
		return staged_result
	staged_result = staged_destination.apply_save_data(destination_before)
	if not staged_result.success:
		return staged_result

	var staged_gold_source := staged_source if gold_source == item_source else staged_destination
	var staged_gold_destination := staged_destination if gold_destination == item_destination else staged_source
	staged_result = InventoryTransactionService.transfer_item(staged_source, staged_destination, item_id, quantity)
	if staged_result.success:
		staged_result = InventoryTransactionService.transfer_item(staged_gold_source, staged_gold_destination, GOLD_ITEM_ID, total_price)
	if not staged_result.success:
		return staged_result

	var commit_source := item_source.apply_save_data(staged_source.get_save_data())
	var commit_destination := item_destination.apply_save_data(staged_destination.get_save_data())
	if commit_source.success and commit_destination.success:
		return InventoryResult.succeeded("Trade completed.")

	var rollback_source := item_source.apply_save_data(source_before)
	var rollback_destination := item_destination.apply_save_data(destination_before)
	if not rollback_source.success or not rollback_destination.success:
		push_error("Trade rollback failed; inventory invariants may be compromised.")
	return commit_source if not commit_source.success else commit_destination
