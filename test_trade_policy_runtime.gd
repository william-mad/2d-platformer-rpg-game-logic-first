extends Node

class TradePlayerStub extends Node2D:
	var inventory := InventoryModel.new()

	func get_relationship_id() -> StringName:
		return &"trade_policy_player"

	func get_inventory() -> InventoryModel:
		return inventory


class TradeNpcStub extends Node2D:
	var default_relationship_favor: float = 50.0
	var inventory_component: NpcInventoryComponent
	var merchant: MerchantComponent

	func _init() -> void:
		inventory_component = NpcInventoryComponent.new()
		inventory_component.name = "NpcInventory"
		add_child(inventory_component)
		merchant = MerchantComponent.new()
		merchant.name = "Merchant"
		add_child(merchant)

	func get_relationship_id() -> StringName:
		return &"trade_policy_npc"

	func get_inventory() -> InventoryModel:
		return inventory_component.get_inventory()


func _ready() -> void:
	await get_tree().process_frame
	var failures: PackedStringArray = []
	var relationships := get_node("/root/Relationships")
	relationships.call("clear_relationships")
	var npc := TradeNpcStub.new()
	add_child(npc)
	var player := TradePlayerStub.new()
	add_child(player)
	var merchant := npc.merchant
	merchant.bind_trade_player(player)
	merchant.initialize_starting_inventory()
	_expect(npc.get_inventory().get_quantity(&"gold_coin") == 20, "new universal trader receives 20 starting gold", failures)
	npc.get_inventory().add(&"cooked_slime_meat", 2)
	relationships.call("set_favor", npc, player, 18.0, "test")
	_expect(not merchant.can_player_buy(&"cooked_slime_meat"), "cooked meat is locked below 35 favor", failures)
	_expect("requires 35 favor" in merchant.get_buy_lock_reason(&"cooked_slime_meat"), "lock reason exposes required favor", failures)
	var player_before := player.inventory.get_save_data()
	var npc_before := npc.get_inventory().get_save_data()
	var result := merchant.buy_from_npc(player.inventory, &"cooked_slime_meat", 1)
	_expect(not result.success and player.inventory.get_save_data() == player_before and npc.get_inventory().get_save_data() == npc_before, "locked trade leaves both inventories unchanged", failures)
	relationships.call("set_favor", npc, player, 0.0, "test")
	_expect(merchant.get_price_to_player(&"cooked_slime_meat") == 8 and merchant.get_price_from_player(&"cooked_slime_meat") == 1, "favor 0 uses 2.0x charge and 0.25x payment", failures)
	relationships.call("set_favor", npc, player, 50.0, "test")
	_expect(merchant.get_price_to_player(&"cooked_slime_meat") == 5 and merchant.get_price_from_player(&"cooked_slime_meat") == 2, "favor 50 uses 1.25x charge and 0.50x payment", failures)
	relationships.call("set_favor", npc, player, 100.0, "test")
	_expect(merchant.get_price_to_player(&"cooked_slime_meat") == 4 and merchant.get_price_from_player(&"cooked_slime_meat") == 3, "favor 100 uses rounded 0.90x charge and 0.75x payment", failures)
	_expect(merchant.can_player_buy(&"cooked_slime_meat"), "high favor unlocks cooked meat", failures)
	_finish(failures)


func _expect(condition: bool, message: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(message)


func _finish(failures: PackedStringArray) -> void:
	if failures.is_empty():
		print("TRADE_POLICY_RUNTIME_OK")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
