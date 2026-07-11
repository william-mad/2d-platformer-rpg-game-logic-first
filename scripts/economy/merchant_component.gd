class_name MerchantComponent
extends Node

@export var inventory_component_path: NodePath = NodePath("../NpcInventory")
@export var starting_inventory_profile: InventoryProfileDefinition
@export_range(0, 9999, 1) var starting_gold: int = 20
@export var sold_item_groups: Array[StringName] = []
@export var accepted_item_groups: Array[StringName] = []

@export_group("Directed Favor Pricing")
@export var worst_price_to_player_multiplier: float = 2.0
@export var neutral_price_to_player_multiplier: float = 1.25
@export var best_price_to_player_multiplier: float = 0.9
@export var worst_price_from_player_multiplier: float = 0.25
@export var neutral_price_from_player_multiplier: float = 0.5
@export var best_price_from_player_multiplier: float = 0.75

var _catalog := ItemCatalog.new()
var _trade_player: Node


func _ready() -> void:
	if not _catalog.load_definitions():
		push_warning("NPC trade item catalog is invalid: %s" % str(_catalog.get_validation_errors()))


func bind_trade_player(player: Node) -> void:
	_trade_player = player


func clear_trade_player() -> void:
	_trade_player = null


func get_trade_player() -> Node:
	return _trade_player if _trade_player != null and is_instance_valid(_trade_player) else null


func get_inventory() -> InventoryModel:
	var component := get_node_or_null(inventory_component_path) as NpcInventoryComponent
	return component.get_inventory() if component != null else null


func get_current_favor() -> float:
	var npc := get_parent()
	var fallback := float(npc.get("default_relationship_favor")) if npc != null else 50.0
	var relationships := get_node_or_null("/root/Relationships")
	if relationships == null or _trade_player == null or not is_instance_valid(_trade_player):
		return clampf(fallback, 0.0, 100.0)
	return clampf(float(relationships.call("get_favor", npc, _trade_player, fallback)), 0.0, 100.0)


func is_item_tradable(item_id: StringName) -> bool:
	if item_id == &"" or item_id == TradeService.GOLD_ITEM_ID:
		return false
	var definition := _catalog.get_definition(item_id)
	return definition != null and definition.tradable and definition.base_value > 0


func can_player_buy(item_id: StringName) -> bool:
	var definition := _catalog.get_definition(item_id)
	return is_item_tradable(item_id) and _group_allowed(definition.trade_group, sold_item_groups) and get_current_favor() >= definition.minimum_favor_to_buy


func can_player_sell(item_id: StringName) -> bool:
	var definition := _catalog.get_definition(item_id)
	return is_item_tradable(item_id) and _group_allowed(definition.trade_group, accepted_item_groups) and get_current_favor() >= definition.minimum_favor_to_sell


func get_buy_lock_reason(item_id: StringName) -> String:
	var definition := _catalog.get_definition(item_id)
	if definition == null or not is_item_tradable(item_id):
		return "Not tradable."
	if not _group_allowed(definition.trade_group, sold_item_groups):
		return "This NPC does not sell this item type."
	if get_current_favor() < definition.minimum_favor_to_buy:
		return "Locked: requires %d favor.\nCurrent favor: %d." % [roundi(definition.minimum_favor_to_buy), roundi(get_current_favor())]
	return ""


func get_sell_refusal_reason(item_id: StringName) -> String:
	var definition := _catalog.get_definition(item_id)
	if definition == null or not is_item_tradable(item_id):
		return "Not tradable."
	if not _group_allowed(definition.trade_group, accepted_item_groups):
		return "This NPC does not buy this item type."
	if get_current_favor() < definition.minimum_favor_to_sell:
		return "Requires %d favor; current favor is %d." % [roundi(definition.minimum_favor_to_sell), roundi(get_current_favor())]
	return ""


func get_price_to_player(item_id: StringName) -> int:
	return _calculate_price(item_id, _favor_multiplier(true))


func get_price_from_player(item_id: StringName) -> int:
	return _calculate_price(item_id, _favor_multiplier(false))


func buy_from_npc(player_inventory: InventoryModel, item_id: StringName, quantity: int) -> InventoryResult:
	if not can_player_buy(item_id):
		return InventoryResult.failed(InventoryResult.Code.INVALID_ITEM_ID, get_buy_lock_reason(item_id), item_id, quantity)
	return TradeService.buy_from_merchant(player_inventory, get_inventory(), item_id, quantity, get_price_to_player(item_id))


func sell_to_npc(player_inventory: InventoryModel, item_id: StringName, quantity: int) -> InventoryResult:
	if not can_player_sell(item_id):
		return InventoryResult.failed(InventoryResult.Code.INVALID_ITEM_ID, get_sell_refusal_reason(item_id), item_id, quantity)
	return TradeService.sell_to_merchant(player_inventory, get_inventory(), item_id, quantity, get_price_from_player(item_id))


func initialize_starting_inventory() -> InventoryResult:
	var inventory := get_inventory()
	if inventory == null:
		return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "NPC inventory component is unavailable.")
	var staged := InventoryModel.new()
	var apply_result := staged.apply_save_data(inventory.get_save_data())
	if not apply_result.success:
		return apply_result
	if starting_inventory_profile != null:
		var errors := starting_inventory_profile.validate(_catalog)
		if not errors.is_empty():
			return InventoryResult.failed(InventoryResult.Code.INVALID_SAVE_DATA, "; ".join(errors))
		for raw_id: Variant in starting_inventory_profile.items:
			var item_id := StringName(String(raw_id))
			if staged.get_quantity(item_id) > 0:
				continue
			var add_result := staged.add(item_id, int(starting_inventory_profile.items[raw_id]))
			if not add_result.success:
				return add_result
	if starting_gold > 0 and staged.get_quantity(TradeService.GOLD_ITEM_ID) == 0:
		var gold_result := staged.add(TradeService.GOLD_ITEM_ID, starting_gold)
		if not gold_result.success:
			return gold_result
	return inventory.apply_save_data(staged.get_save_data())


func _favor_multiplier(to_player: bool) -> float:
	var favor := get_current_favor()
	if favor <= 50.0:
		var weight := favor / 50.0
		return lerpf(worst_price_to_player_multiplier, neutral_price_to_player_multiplier, weight) if to_player else lerpf(worst_price_from_player_multiplier, neutral_price_from_player_multiplier, weight)
	var weight := (favor - 50.0) / 50.0
	return lerpf(neutral_price_to_player_multiplier, best_price_to_player_multiplier, weight) if to_player else lerpf(neutral_price_from_player_multiplier, best_price_from_player_multiplier, weight)


func _calculate_price(item_id: StringName, multiplier: float) -> int:
	if not is_item_tradable(item_id) or multiplier <= 0.0:
		return 0
	var definition := _catalog.get_definition(item_id)
	# Godot roundi rounds positive halfway values away from zero; tradable prices have a one-gold floor.
	return maxi(1, roundi(float(definition.base_value) * multiplier))


func _group_allowed(group: StringName, allowed_groups: Array[StringName]) -> bool:
	return allowed_groups.is_empty() or group in allowed_groups
