class_name FoodConsumptionService
extends RefCounted

var _catalog := ItemCatalog.new()
var _catalog_loaded: bool = false


func consume_for_player(
		inventory: InventoryModel,
		player: Node,
		item_id: StringName
) -> InventoryResult:
	return _consume(inventory, player, item_id, &"", false)


func consume_for_npc(
		inventory: InventoryModel,
		npc: Node,
		item_id: StringName,
		reservation_id: StringName = &""
) -> InventoryResult:
	return _consume(inventory, npc, item_id, reservation_id, true)


func select_best_available_food(inventory: InventoryModel) -> StringName:
	if inventory == null or not _ensure_catalog():
		return &""
	var candidates: Array[ItemDefinition] = []
	for raw_id: Variant in inventory.get_all_quantities():
		var item_id := StringName(String(raw_id))
		if inventory.get_available_quantity(item_id) <= 0 or not _catalog.is_food(item_id):
			continue
		var definition := _catalog.get_definition(item_id)
		if definition != null:
			candidates.append(definition)
	candidates.sort_custom(func(left: ItemDefinition, right: ItemDefinition) -> bool:
		if not is_equal_approx(left.hunger_reduction, right.hunger_reduction):
			return left.hunger_reduction > right.hunger_reduction
		var left_name := left.display_name.to_lower()
		var right_name := right.display_name.to_lower()
		if left_name != right_name:
			return left_name < right_name
		return String(left.id) < String(right.id)
	)
	return candidates[0].id if not candidates.is_empty() else &""


func _consume(
		inventory: InventoryModel,
		need_owner: Node,
		item_id: StringName,
		reservation_id: StringName,
		is_npc: bool
) -> InventoryResult:
	var validation := _validate(inventory, need_owner, item_id, reservation_id, is_npc)
	if validation != null:
		return validation
	var previous_hunger := _get_hunger(need_owner, is_npc)
	var food_value := _catalog.get_food_value(item_id)
	var requested_delta := -minf(food_value, previous_hunger)
	var actual_delta := _apply_hunger_delta(need_owner, requested_delta, is_npc)
	if actual_delta >= 0.0 or is_zero_approx(actual_delta):
		return InventoryResult.failed(
			InventoryResult.Code.NEED_ALREADY_SATISFIED,
			"The character is not hungry.", item_id, 1
		)

	var removal: InventoryResult
	if reservation_id != &"":
		removal = inventory.consume_reservation(reservation_id)
	else:
		removal = inventory.remove(item_id, 1)
	if removal.success:
		var definition := _catalog.get_definition(item_id)
		return InventoryResult.succeeded("Consumed %s." % definition.display_name)

	# The inventory mutation failed after the need changed. Restore through the
	# same public need API so HUD/state-machine signals remain consistent.
	var rollback_delta := _apply_hunger_delta(need_owner, previous_hunger - _get_hunger(need_owner, is_npc), is_npc)
	if not is_equal_approx(_get_hunger(need_owner, is_npc), previous_hunger):
		push_error("Food consumption hunger rollback failed (applied %.2f)." % rollback_delta)
	return removal


func _validate(
		inventory: InventoryModel,
		need_owner: Node,
		item_id: StringName,
		reservation_id: StringName,
		is_npc: bool
) -> InventoryResult:
	if inventory == null or need_owner == null or not is_instance_valid(need_owner):
		return InventoryResult.failed(InventoryResult.Code.INVALID_NEED_OWNER, "A valid inventory and need owner are required.", item_id, 1)
	if not _ensure_catalog() or not _catalog.is_food(item_id):
		return InventoryResult.failed(InventoryResult.Code.NOT_CONSUMABLE, "This item cannot be consumed.", item_id, 1)
	if _owner_is_definitively_dead(need_owner, is_npc):
		return InventoryResult.failed(InventoryResult.Code.INVALID_NEED_OWNER, "A definitively dead character cannot eat.", item_id, 1)
	if is_npc and not _is_canonical_live_npc(need_owner):
		return InventoryResult.failed(InventoryResult.Code.INVALID_NEED_OWNER, "Only the canonical live NPC can consume inventory food.", item_id, 1)
	if not _has_compatible_need_api(need_owner, is_npc):
		return InventoryResult.failed(InventoryResult.Code.INVALID_NEED_OWNER, "The character has no compatible hunger API.", item_id, 1)
	if _get_hunger(need_owner, is_npc) <= 0.0:
		return InventoryResult.failed(InventoryResult.Code.NEED_ALREADY_SATISFIED, "The character is not hungry.", item_id, 1)
	if reservation_id != &"":
		var reservation := inventory.get_reservation(reservation_id)
		if reservation.size() != 1 or int(reservation.get(String(item_id), 0)) != 1:
			return InventoryResult.failed(InventoryResult.Code.RESERVATION_NOT_FOUND, "The eating reservation is unavailable.", item_id, 1, 0, reservation_id)
	elif not inventory.has_available(item_id, 1):
		return InventoryResult.failed(InventoryResult.Code.INSUFFICIENT_AVAILABLE_QUANTITY, "No unreserved food is available.", item_id, 1, inventory.get_available_quantity(item_id))
	return null


func _has_compatible_need_api(need_owner: Node, is_npc: bool) -> bool:
	if is_npc:
		var machine := need_owner.get_node_or_null("NpcStateMachine")
		return machine != null and machine.has_method("get_value") and machine.has_method("apply_value_delta")
	return need_owner.has_method("apply_hunger_delta") and _get_hunger(need_owner, false) >= 0.0


func _get_hunger(need_owner: Node, is_npc: bool) -> float:
	if is_npc:
		var machine := need_owner.get_node_or_null("NpcStateMachine")
		return float(machine.call("get_value", &"hunger", 0.0)) if machine != null and machine.has_method("get_value") else -1.0
	var value: Variant = need_owner.get("hunger")
	return float(value) if typeof(value) in [TYPE_FLOAT, TYPE_INT] else -1.0


func _apply_hunger_delta(need_owner: Node, delta: float, is_npc: bool) -> float:
	var previous := _get_hunger(need_owner, is_npc)
	if is_npc:
		var machine := need_owner.get_node_or_null("NpcStateMachine")
		if machine == null or not machine.has_method("apply_value_delta"):
			return 0.0
		machine.call("apply_value_delta", {"hunger": delta}, null, false)
	elif need_owner.has_method("apply_hunger_delta"):
		need_owner.call("apply_hunger_delta", delta)
	else:
		return 0.0
	return _get_hunger(need_owner, is_npc) - previous


func _owner_is_definitively_dead(need_owner: Node, is_npc: bool) -> bool:
	if is_npc:
		var stats: Variant = need_owner.get("social_stats")
		return stats is Dictionary and float((stats as Dictionary).get("disabled", 0.0)) >= 1.0
	return bool(need_owner.get("dead"))


func _is_canonical_live_npc(npc: Node) -> bool:
	if not npc.has_method("get_npc_location_id"):
		return false
	var locations := npc.get_node_or_null("/root/NpcLocations")
	return locations != null and locations.has_method("get_live_npc") and locations.call("get_live_npc", String(npc.call("get_npc_location_id"))) == npc


func _ensure_catalog() -> bool:
	if _catalog_loaded:
		return true
	_catalog_loaded = _catalog.load_definitions()
	if not _catalog_loaded:
		push_warning("Food catalog could not be loaded: %s" % str(_catalog.get_validation_errors()))
	return _catalog_loaded
