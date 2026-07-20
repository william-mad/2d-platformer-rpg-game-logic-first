class_name PlayerInventoryScreen
extends Control

const SLOT_SCENE: PackedScene = preload("res://ui/inventory/inventory_item_slot.tscn")
const LOOT_SCENE: PackedScene = preload("res://scenes/items/world_loot_container.tscn")

@export var dump_spawn_offset: Vector2 = Vector2(76.0, -24.0)
@export var dump_source_exclusion_seconds: float = 0.75

@onready var items_grid: GridContainer = %ItemsGrid
@onready var empty_label: Label = %EmptyLabel
@onready var details_label: Label = %DetailsLabel
@onready var consume_button: Button = %ConsumeButton
@onready var equipment_button: Button = %EquipmentButton
@onready var dump_quantity: SpinBox = %DumpQuantity
@onready var dump_button: Button = %DumpButton
@onready var feedback_label: Label = %FeedbackLabel

var _inventory: InventoryModel
var _player_owner: Node2D
var _equipment: PlayerEquipmentComponent
var _catalog := ItemCatalog.new()
var _display_dirty: bool = true
var _selected_item_id: StringName = &""
var _slots: Array[InventoryItemSlot] = []
var _food_service := FoodConsumptionService.new()


func _ready() -> void:
	visible = false
	dump_button.pressed.connect(_on_dump_pressed)
	consume_button.pressed.connect(_on_consume_pressed)
	equipment_button.pressed.connect(_on_equipment_pressed)
	dump_quantity.value_changed.connect(func(_value: float) -> void: _refresh_dump_controls())
	if not _catalog.load_definitions():
		push_warning("Player inventory catalog errors: %s" % str(_catalog.get_validation_errors()))


func bind_inventory(inventory: InventoryModel, player_owner: Node2D = null) -> void:
	_disconnect_player_signals()
	if _inventory != inventory:
		_disconnect_inventory_signals()
		_inventory = inventory
		_connect_inventory_signals()
	_player_owner = player_owner
	_equipment = (
		_player_owner.get_node_or_null("PlayerEquipment") as PlayerEquipmentComponent
		if _player_owner != null
		else null
	)
	_connect_player_signals()
	_display_dirty = true
	if visible:
		_refresh_items()


func unbind_inventory(inventory: InventoryModel = null) -> void:
	if inventory != null and _inventory != inventory:
		return
	_disconnect_inventory_signals()
	_disconnect_player_signals()
	_inventory = null
	_player_owner = null
	_equipment = null
	_display_dirty = true


func has_bound_inventory() -> bool:
	return _inventory != null


func is_bound_to(inventory: InventoryModel) -> bool:
	return _inventory == inventory


func open_screen() -> void:
	if _inventory == null:
		return
	visible = true
	feedback_label.text = ""
	if _display_dirty:
		_refresh_items()
	_focus_selected_or_first()


func close_screen() -> void:
	visible = false


func is_open() -> bool:
	return visible


func _refresh_items() -> void:
	_clear_slots()
	_display_dirty = false
	if _inventory == null:
		empty_label.text = "Inventory is unavailable."
		empty_label.visible = true
		_refresh_details(null)
		return
	var entries: Array[Dictionary] = []
	for raw_id: Variant in _inventory.get_all_quantities():
		var item_id := StringName(String(raw_id))
		var total := _inventory.get_quantity(item_id)
		if total <= 0:
			continue
		var definition := _catalog.get_definition(item_id)
		entries.append({"id": item_id, "definition": definition, "total": total, "sort": _sort_key(item_id, definition)})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["sort"]) < String(b["sort"]))
	empty_label.visible = entries.is_empty()
	empty_label.text = "Inventory is empty."
	for entry: Dictionary in entries:
		var slot := SLOT_SCENE.instantiate() as InventoryItemSlot
		items_grid.add_child(slot)
		var item_id: StringName = entry["id"]
		slot.configure(item_id, entry["definition"], entry["total"], _inventory.get_available_quantity(item_id), _inventory.get_reserved_quantity(item_id))
		slot.inspected.connect(_on_slot_inspected)
		_slots.append(slot)
	if not _has_slot(_selected_item_id):
		_selected_item_id = _slots[0].item_id if not _slots.is_empty() else &""
	_refresh_details(_get_selected_slot())
	_focus_selected_or_first()


func _on_slot_inspected(slot: InventoryItemSlot) -> void:
	_selected_item_id = slot.item_id
	_refresh_details(slot)


func _refresh_details(slot: InventoryItemSlot) -> void:
	if slot == null:
		details_label.text = "Select an item to view details."
		consume_button.visible = false
		consume_button.disabled = true
		equipment_button.visible = false
		equipment_button.disabled = true
		dump_quantity.max_value = 1
		dump_quantity.value = 1
		dump_button.disabled = true
		return
	var definition := slot.definition
	var name_text := definition.display_name if definition != null else String(slot.item_id)
	var description := definition.description if definition != null else "No item definition found."
	var category := String(definition.category) if definition != null else "unknown"
	var base_value := definition.base_value if definition != null else 0
	var food_text := ""
	var equipment_text := ""
	var is_food := definition != null and definition.edible and definition.hunger_reduction > 0.0
	if is_food:
		var current_hunger := float(_player_owner.get("hunger")) if _player_owner != null else 0.0
		food_text = "\nFood benefit: -%.0f hunger | Current hunger: %.0f" % [definition.hunger_reduction, current_hunger]
	var profile := definition.equipment_profile if definition != null else null
	var is_equipment := profile != null
	var is_equipped := is_equipment and _equipment != null and _equipment.is_equipped(slot.item_id)
	if is_equipment:
		equipment_text = "\nEquipment slot: %s\nDamage: ×%.2f | Knockout: ×%.2f" % [
			String(profile.slot_id).capitalize(),
			profile.damage_multiplier,
			profile.knockout_multiplier,
		]
		if is_equipped:
			equipment_text += "\nEquipped: %s" % String(profile.slot_id).capitalize()
	details_label.text = "%s\n%s\nTotal: %d | Available: %d | Reserved: %d\nType: %s | Base value: %d gold%s%s" % [name_text, description, slot.total_quantity, slot.available_quantity, slot.reserved_quantity, category, base_value, food_text, equipment_text]
	consume_button.visible = is_food
	consume_button.disabled = not is_food or slot.available_quantity <= 0 or _player_owner == null or float(_player_owner.get("hunger")) <= 0.0
	equipment_button.visible = is_equipment
	equipment_button.text = "Unequip" if is_equipped else "Equip"
	equipment_button.disabled = not is_equipment or _equipment == null or (not is_equipped and slot.available_quantity <= 0)
	dump_quantity.max_value = maxi(1, slot.available_quantity)
	dump_quantity.value = clampi(int(dump_quantity.value), 1, maxi(1, slot.available_quantity))
	_refresh_dump_controls()


func _on_consume_pressed() -> void:
	var slot := _get_selected_slot()
	if slot == null or _inventory == null or _player_owner == null:
		feedback_label.text = "Select an available food item."
		return
	var result := _food_service.consume_for_player(_inventory, _player_owner, slot.item_id)
	feedback_label.text = "You are not hungry." if result.code == InventoryResult.Code.NEED_ALREADY_SATISFIED else result.message
	if visible and not _display_dirty:
		_refresh_details(_get_selected_slot())


func _on_equipment_pressed() -> void:
	var slot := _get_selected_slot()
	if slot == null or _equipment == null:
		feedback_label.text = "Equipment is unavailable."
		return
	var result := (
		_equipment.unequip(&"weapon")
		if _equipment.is_equipped(slot.item_id)
		else _equipment.equip(slot.item_id)
	)
	feedback_label.text = String(result.get("message", "Equipment could not be changed."))
	_refresh_items()


func _refresh_dump_controls() -> void:
	var slot := _get_selected_slot()
	dump_button.disabled = slot == null or slot.available_quantity <= 0 or int(dump_quantity.value) > slot.available_quantity or _player_owner == null


func _on_dump_pressed() -> void:
	var slot := _get_selected_slot()
	if slot == null or _inventory == null:
		feedback_label.text = "Select an item first."
		return
	var quantity := int(dump_quantity.value)
	if quantity <= 0 or not _inventory.has_available(slot.item_id, quantity):
		feedback_label.text = "That quantity is no longer available."
		return
	if _player_owner == null or not is_instance_valid(_player_owner) or not _player_owner.is_inside_tree():
		feedback_label.text = "The world is unavailable."
		return
	var world_parent := get_tree().current_scene
	if world_parent == null:
		feedback_label.text = "No world scene is available."
		return
	var loot := LOOT_SCENE.instantiate() as WorldLootContainer
	if loot == null:
		feedback_label.text = "Could not create world loot."
		return
	var staged := InventoryModel.new()
	var add_result := staged.add(slot.item_id, quantity)
	if not add_result.success:
		loot.free()
		feedback_label.text = add_result.message
		return
	var receiver := _player_owner.get_node_or_null("InventoryPickupReceiver") as InventoryPickupReceiver
	var receiver_id := receiver.get_receiver_id() if receiver != null else &"player"
	loot.source_type = &"player_dump"
	var initialization := loot.initialize_loot(staged.get_save_data(), receiver_id)
	if not initialization.success:
		loot.free()
		feedback_label.text = initialization.message
		return
	loot.exclude_receiver(receiver_id, dump_source_exclusion_seconds)
	var removal := _inventory.remove(slot.item_id, quantity)
	if not removal.success:
		loot.free()
		feedback_label.text = removal.message
		return
	world_parent.add_child(loot)
	loot.global_position = _player_owner.global_position + dump_spawn_offset
	feedback_label.text = "Dumped %d × %s into the world." % [quantity, slot.definition.display_name if slot.definition != null else String(slot.item_id)]


func _mark_display_dirty() -> void:
	_display_dirty = true
	if visible:
		_refresh_items()


func _connect_inventory_signals() -> void:
	if _inventory == null:
		return
	_inventory.item_quantity_changed.connect(_on_item_quantity_changed)
	_inventory.reservation_changed.connect(_on_reservation_changed)
	_inventory.inventory_reset.connect(_on_inventory_reset)


func _disconnect_inventory_signals() -> void:
	if _inventory == null:
		return
	for signal_name: StringName in [&"item_quantity_changed", &"reservation_changed", &"inventory_reset"]:
		var callback := Callable(self, "_on_%s" % String(signal_name))
		if _inventory.is_connected(signal_name, callback):
			_inventory.disconnect(signal_name, callback)


func _on_item_quantity_changed(_id: StringName, _total: int, _available: int, _reason: StringName) -> void:
	_mark_display_dirty()


func _on_reservation_changed(_id: StringName, _reason: StringName) -> void:
	_mark_display_dirty()


func _on_inventory_reset() -> void:
	_mark_display_dirty()


func _connect_player_signals() -> void:
	if _player_owner == null:
		return
	if _player_owner.has_signal(&"hunger_changed") and not _player_owner.is_connected(&"hunger_changed", _on_player_hunger_changed):
		_player_owner.connect(&"hunger_changed", _on_player_hunger_changed)
	if _equipment != null and not _equipment.equipment_changed.is_connected(_on_equipment_changed):
		_equipment.equipment_changed.connect(_on_equipment_changed)


func _disconnect_player_signals() -> void:
	if _player_owner != null and is_instance_valid(_player_owner) and _player_owner.has_signal(&"hunger_changed") and _player_owner.is_connected(&"hunger_changed", _on_player_hunger_changed):
		_player_owner.disconnect(&"hunger_changed", _on_player_hunger_changed)
	if _equipment != null and is_instance_valid(_equipment) and _equipment.equipment_changed.is_connected(_on_equipment_changed):
		_equipment.equipment_changed.disconnect(_on_equipment_changed)


func _on_player_hunger_changed(_current_hunger: float, _changed_by: float) -> void:
	if visible:
		_refresh_details(_get_selected_slot())


func _on_equipment_changed(
	_slot_id: StringName,
	_previous_item_id: StringName,
	_new_item_id: StringName
) -> void:
	_mark_display_dirty()


func _clear_slots() -> void:
	for child: Node in items_grid.get_children():
		items_grid.remove_child(child)
		child.queue_free()
	_slots.clear()


func _sort_key(item_id: StringName, definition: ItemDefinition) -> String:
	if definition == null:
		return "zzz|%s" % String(item_id)
	return "%s|%s|%s" % [String(definition.trade_group), definition.display_name.to_lower(), String(item_id)]


func _has_slot(item_id: StringName) -> bool:
	return _slots.any(func(slot: InventoryItemSlot) -> bool: return slot.item_id == item_id)


func _get_selected_slot() -> InventoryItemSlot:
	for slot: InventoryItemSlot in _slots:
		if slot.item_id == _selected_item_id:
			return slot
	return null


func _focus_selected_or_first() -> void:
	if not visible:
		return
	call_deferred("_focus_current_slot")


func _focus_current_slot() -> void:
	if not visible:
		return
	var slot := _get_selected_slot()
	if slot == null and not _slots.is_empty():
		slot = _slots[0]
	if slot != null and is_instance_valid(slot) and slot.is_inside_tree():
		slot.grab_focus()
