extends SceneTree

var failures: PackedStringArray = PackedStringArray()


class MerchantNpcStub extends Node:
	var inventory_component: NpcInventoryComponent
	var merchant: MerchantComponent

	func _init() -> void:
		name = "MerchantNpcStub"
		inventory_component = NpcInventoryComponent.new()
		inventory_component.name = "NpcInventory"
		add_child(inventory_component)
		merchant = MerchantComponent.new()
		merchant.name = "Merchant"
		merchant.starting_inventory_profile = load("res://data/inventory_profiles/merchant_basic_inventory.tres")
		add_child(merchant)

	func get_npc_location_id() -> StringName:
		return &"trade_test_merchant"

	func get_inventory_save_data() -> Dictionary:
		return inventory_component.get_save_data()

	func apply_inventory_save_data(data: Dictionary) -> InventoryResult:
		return inventory_component.apply_save_data(data)

	func reset_inventory() -> void:
		inventory_component.reset_inventory()

	func initialize_merchant_starting_inventory() -> InventoryResult:
		return merchant.initialize_starting_inventory()

	func get_npc_location_save_data() -> Dictionary:
		return {}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var player := InventoryModel.new()
	_expect(player.add(TradeService.GOLD_ITEM_ID, 50).success, "gold can be added")
	_expect(player.add(&"raw_slime_meat", 4).success, "sale item can be added")
	var saved := player.get_save_data()
	var loaded := InventoryModel.new()
	_expect(loaded.apply_save_data(saved).success and loaded.get_quantity(TradeService.GOLD_ITEM_ID) == 50, "gold saves and loads as inventory quantity")

	var npc_locations: Node = load("res://scripts/systems/npc_locations.gd").new()
	root.add_child(npc_locations)
	var first := MerchantNpcStub.new()
	root.add_child(first)
	await process_frame
	_expect(npc_locations.register_npc(first), "new merchant record registers")
	var merchant_inventory := first.inventory_component.get_inventory()
	_expect(merchant_inventory.get_quantity(TradeService.GOLD_ITEM_ID) == 100, "starting merchant gold initialized")
	_expect(merchant_inventory.get_quantity(&"cooked_slime_meat") == 5, "starting stock initialized")
	_expect(first.merchant.get_price_to_player(&"cooked_slime_meat") == 4, "sell-to-player price uses base value")
	_expect(first.merchant.get_price_from_player(&"raw_slime_meat") == 1, "buy-from-player price uses deterministic rounding")

	var result := TradeService.buy_from_merchant(player, merchant_inventory, &"cooked_slime_meat", 2, 4)
	_expect(result.success, "purchase succeeds")
	_expect(player.get_quantity(&"cooked_slime_meat") == 2 and player.get_quantity(TradeService.GOLD_ITEM_ID) == 42, "purchase transfers item and gold")
	_expect(merchant_inventory.get_quantity(&"cooked_slime_meat") == 3 and merchant_inventory.get_quantity(TradeService.GOLD_ITEM_ID) == 108, "merchant receives purchase payment")

	result = TradeService.sell_to_merchant(player, merchant_inventory, &"raw_slime_meat", 2, 1)
	_expect(result.success, "sale succeeds")
	_expect(player.get_quantity(&"raw_slime_meat") == 2 and player.get_quantity(TradeService.GOLD_ITEM_ID) == 44, "sale transfers item and gold")
	_expect(merchant_inventory.get_quantity(&"raw_slime_meat") == 2 and merchant_inventory.get_quantity(TradeService.GOLD_ITEM_ID) == 106, "merchant receives sold item")

	var before_player := player.get_save_data()
	var before_merchant := merchant_inventory.get_save_data()
	result = TradeService.buy_from_merchant(player, merchant_inventory, &"cooked_slime_meat", 1, 1000)
	_expect(not result.success and player.get_save_data() == before_player and merchant_inventory.get_save_data() == before_merchant, "insufficient player gold leaves both inventories unchanged")
	_expect(merchant_inventory.reserve_items(&"stock_hold", {&"cooked_slime_meat": 3}).success, "merchant stock reservation created")
	result = TradeService.buy_from_merchant(player, merchant_inventory, &"cooked_slime_meat", 1, 4)
	_expect(not result.success, "reserved merchant stock cannot be sold")
	_expect(merchant_inventory.release_reservation(&"stock_hold").success, "stock reservation released")
	_expect(player.reserve_items(&"gold_hold", {TradeService.GOLD_ITEM_ID: 44}).success, "player gold reservation created")
	result = TradeService.buy_from_merchant(player, merchant_inventory, &"cooked_slime_meat", 1, 4)
	_expect(not result.success, "reserved player gold cannot be spent")
	_expect(player.release_reservation(&"gold_hold").success, "gold reservation released")
	result = TradeService.sell_to_merchant(player, merchant_inventory, TradeService.GOLD_ITEM_ID, 1, 1)
	_expect(not result.success, "gold cannot be sold for gold")
	var poor_merchant := InventoryModel.new()
	result = TradeService.sell_to_merchant(player, poor_merchant, &"raw_slime_meat", 1, 1)
	_expect(not result.success, "merchant without gold cannot buy")

	var trade_screen := load("res://ui/trade/trade_screen.tscn").instantiate() as TradeScreen
	root.add_child(trade_screen)
	await process_frame
	_expect(trade_screen.open_screen(player, first.merchant), "trade screen opens")
	_expect(trade_screen.get_player_gold_text() == "Your gold: 44", "trade screen displays player gold")
	_expect(trade_screen.get_buy_item_count() > 0 and trade_screen.get_sell_item_count() > 0, "trade screen displays tradable stock")
	result = TradeService.buy_from_merchant(player, merchant_inventory, &"cooked_slime_meat", 1, 4)
	_expect(result.success and trade_screen.get_player_gold_text() == "Your gold: 40", "trade screen updates from inventory signals")
	trade_screen.close_screen()
	_expect(trade_screen.open_screen(player, first.merchant) and trade_screen.get_player_gold_text() == "Your gold: 40", "reopened trade screen reflects current state")
	trade_screen.close_screen()

	npc_locations.unregister_npc(first)
	first.queue_free()
	await process_frame
	var second := MerchantNpcStub.new()
	root.add_child(second)
	await process_frame
	_expect(npc_locations.register_npc(second), "restored merchant record registers")
	var restored := second.inventory_component.get_inventory()
	_expect(restored.get_quantity(&"cooked_slime_meat") == 2 and restored.get_quantity(TradeService.GOLD_ITEM_ID) == 110, "merchant stock and gold persist without starting-stock refill")

	if failures.is_empty():
		print("TRADE_RUNTIME_OK")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
