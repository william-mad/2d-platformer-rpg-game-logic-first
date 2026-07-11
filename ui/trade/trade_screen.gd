class_name TradeScreen
extends PanelContainer

signal close_requested

const SLOT_SCENE: PackedScene = preload("res://ui/inventory/inventory_item_slot.tscn")

var _player_inventory: InventoryModel
var _merchant: MerchantComponent
var _merchant_inventory: InventoryModel
var _catalog := ItemCatalog.new()
var _buy_slots: Array[InventoryItemSlot] = []
var _sell_slots: Array[InventoryItemSlot] = []
var _buy_selected_id: StringName = &""
var _sell_selected_id: StringName = &""
var _refreshing: bool = false

var _player_gold_label: Label
var _merchant_gold_label: Label
var _buy_grid: GridContainer
var _sell_grid: GridContainer
var _buy_empty: Label
var _sell_empty: Label
var _details: Label
var _quantity: SpinBox
var _buy_button: Button
var _sell_button: Button
var _feedback: Label


func _ready() -> void:
	visible = false
	_catalog.load_definitions()
	_build_interface()


func open_screen(player_inventory: InventoryModel, merchant: MerchantComponent) -> bool:
	if player_inventory == null or merchant == null or merchant.get_inventory() == null:
		return false
	_disconnect_signals()
	_player_inventory = player_inventory
	_merchant = merchant
	_merchant_inventory = merchant.get_inventory()
	_connect_signals()
	_feedback.text = ""
	visible = true
	_refresh()
	_focus_first_slot()
	return true


func close_screen() -> void:
	if not visible:
		return
	visible = false
	_disconnect_signals()
	if _merchant != null:
		_merchant.clear_trade_player()
	_player_inventory = null
	_merchant_inventory = null
	_merchant = null


func is_open() -> bool:
	return visible


func get_player_gold_text() -> String:
	return _player_gold_label.text


func get_merchant_gold_text() -> String:
	return _merchant_gold_label.text


func get_buy_item_count() -> int:
	return _buy_slots.size()


func get_sell_item_count() -> int:
	return _sell_slots.size()


func _build_interface() -> void:
	var margin := MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 42 if side in ["top", "bottom"] else 70)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)
	var title := Label.new()
	title.text = "TRADE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	root.add_child(title)
	var gold_row := HBoxContainer.new()
	root.add_child(gold_row)
	_player_gold_label = Label.new()
	_player_gold_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gold_row.add_child(_player_gold_label)
	_merchant_gold_label = Label.new()
	_merchant_gold_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_merchant_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	gold_row.add_child(_merchant_gold_label)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 18)
	root.add_child(columns)
	var buy_section := _make_grid_section("BUY — NPC stock")
	columns.add_child(buy_section["root"])
	_buy_grid = buy_section["grid"]
	_buy_empty = buy_section["empty"]
	var sell_section := _make_grid_section("SELL — Your items")
	columns.add_child(sell_section["root"])
	_sell_grid = sell_section["grid"]
	_sell_empty = sell_section["empty"]
	var details_panel := VBoxContainer.new()
	details_panel.custom_minimum_size = Vector2(260, 0)
	columns.add_child(details_panel)
	_details = Label.new()
	_details.custom_minimum_size = Vector2(260, 230)
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.text = "Select an item to view details."
	details_panel.add_child(_details)
	var quantity_label := Label.new()
	quantity_label.text = "Quantity"
	details_panel.add_child(quantity_label)
	_quantity = SpinBox.new()
	_quantity.min_value = 1
	_quantity.max_value = 9999
	_quantity.value = 1
	_quantity.value_changed.connect(func(_value: float) -> void: _refresh_controls())
	details_panel.add_child(_quantity)
	_buy_button = Button.new()
	_buy_button.text = "Buy selected"
	_buy_button.pressed.connect(_on_buy_pressed)
	details_panel.add_child(_buy_button)
	_sell_button = Button.new()
	_sell_button.text = "Sell selected"
	_sell_button.pressed.connect(_on_sell_pressed)
	details_panel.add_child(_sell_button)
	_feedback = Label.new()
	_feedback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_feedback)
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(func() -> void: close_requested.emit())
	root.add_child(close_button)


func _make_grid_section(title_text: String) -> Dictionary:
	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(340, 330)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := Label.new()
	title.text = title_text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(stack)
	var empty := Label.new()
	empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(empty)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	stack.add_child(grid)
	return {"root": root, "grid": grid, "empty": empty}


func _refresh() -> void:
	if _refreshing or _player_inventory == null or _merchant_inventory == null or _merchant == null:
		return
	_refreshing = true
	_clear_grid(_buy_grid, _buy_slots)
	_clear_grid(_sell_grid, _sell_slots)
	_player_gold_label.text = "Your available gold: %d" % _player_inventory.get_available_quantity(TradeService.GOLD_ITEM_ID)
	_merchant_gold_label.text = "NPC available gold: %d  |  Favor: %d" % [_merchant_inventory.get_available_quantity(TradeService.GOLD_ITEM_ID), roundi(_merchant.get_current_favor())]
	_fill_buy_grid()
	_fill_sell_grid()
	_buy_empty.visible = _buy_slots.is_empty()
	_buy_empty.text = "No stock available."
	_sell_empty.visible = _sell_slots.is_empty()
	_sell_empty.text = "No items this NPC will buy."
	if not _slot_exists(_buy_slots, _buy_selected_id):
		_buy_selected_id = _buy_slots[0].item_id if not _buy_slots.is_empty() else &""
	if not _slot_exists(_sell_slots, _sell_selected_id):
		_sell_selected_id = _sell_slots[0].item_id if not _sell_slots.is_empty() else &""
	_refresh_controls()
	_refreshing = false


func _fill_buy_grid() -> void:
	for entry: Dictionary in _trade_entries(_merchant_inventory, false):
		var item_id: StringName = entry["id"]
		var locked := not _merchant.can_player_buy(item_id)
		var slot := SLOT_SCENE.instantiate() as InventoryItemSlot
		_buy_grid.add_child(slot)
		slot.configure(item_id, entry["definition"], entry["total"], entry["available"], entry["reserved"], _merchant.get_price_to_player(item_id), locked, _merchant.get_buy_lock_reason(item_id), false)
		slot.inspected.connect(func(inspected_slot: InventoryItemSlot) -> void:
			_buy_selected_id = inspected_slot.item_id
			_show_slot_details(inspected_slot, true)
		)
		_buy_slots.append(slot)


func _fill_sell_grid() -> void:
	for entry: Dictionary in _trade_entries(_player_inventory, true):
		var item_id: StringName = entry["id"]
		if not _merchant.can_player_sell(item_id):
			continue
		var slot := SLOT_SCENE.instantiate() as InventoryItemSlot
		_sell_grid.add_child(slot)
		slot.configure(item_id, entry["definition"], entry["total"], entry["available"], entry["reserved"], _merchant.get_price_from_player(item_id))
		slot.inspected.connect(func(inspected_slot: InventoryItemSlot) -> void:
			_sell_selected_id = inspected_slot.item_id
			_show_slot_details(inspected_slot, false)
		)
		_sell_slots.append(slot)


func _trade_entries(inventory: InventoryModel, require_available: bool) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for raw_id: Variant in inventory.get_all_quantities():
		var item_id := StringName(String(raw_id))
		var definition := _catalog.get_definition(item_id)
		var available := inventory.get_available_quantity(item_id)
		if not _merchant.is_item_tradable(item_id) or (require_available and available <= 0):
			continue
		entries.append({"id": item_id, "definition": definition, "total": inventory.get_quantity(item_id), "available": available, "reserved": inventory.get_reserved_quantity(item_id), "sort": "%s|%s|%s" % [String(definition.trade_group), definition.display_name.to_lower(), String(item_id)]})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["sort"]) < String(b["sort"]))
	return entries


func _show_slot_details(slot: InventoryItemSlot, buying: bool) -> void:
	var definition := slot.definition
	var direction := "Buy price" if buying else "Sell price"
	var lock_text := "\n%s" % slot.lock_reason if not slot.lock_reason.is_empty() else ""
	_details.text = "%s\n%s\nTotal: %d | Available: %d | Reserved: %d\nType: %s | Base value: %d gold\n%s: %d gold%s" % [definition.display_name, definition.description, slot.total_quantity, slot.available_quantity, slot.reserved_quantity, String(definition.trade_group), definition.base_value, direction, slot.unit_price, lock_text]
	_refresh_controls()


func _refresh_controls() -> void:
	if _merchant == null:
		return
	var quantity := int(_quantity.value)
	var buy_slot := _find_slot(_buy_slots, _buy_selected_id)
	var sell_slot := _find_slot(_sell_slots, _sell_selected_id)
	var buy_total := buy_slot.unit_price * quantity if buy_slot != null else 0
	var sell_total := sell_slot.unit_price * quantity if sell_slot != null else 0
	_buy_button.disabled = buy_slot == null or buy_slot.locked or buy_slot.available_quantity < quantity or _player_inventory.get_available_quantity(TradeService.GOLD_ITEM_ID) < buy_total
	_sell_button.disabled = sell_slot == null or sell_slot.available_quantity < quantity or _merchant_inventory.get_available_quantity(TradeService.GOLD_ITEM_ID) < sell_total


func _on_buy_pressed() -> void:
	var slot := _find_slot(_buy_slots, _buy_selected_id)
	if slot == null:
		return
	var result := _merchant.buy_from_npc(_player_inventory, slot.item_id, int(_quantity.value))
	_feedback.text = result.message
	_refresh()


func _on_sell_pressed() -> void:
	var slot := _find_slot(_sell_slots, _sell_selected_id)
	if slot == null:
		return
	var result := _merchant.sell_to_npc(_player_inventory, slot.item_id, int(_quantity.value))
	_feedback.text = result.message
	_refresh()


func _connect_signals() -> void:
	for inventory: InventoryModel in [_player_inventory, _merchant_inventory]:
		inventory.item_quantity_changed.connect(_on_inventory_changed)
		inventory.reservation_changed.connect(_on_reservation_changed)
		inventory.inventory_reset.connect(_on_inventory_reset)
	var relationships := get_node_or_null("/root/Relationships")
	if relationships != null and not relationships.favor_changed.is_connected(_on_favor_changed):
		relationships.favor_changed.connect(_on_favor_changed)


func _disconnect_signals() -> void:
	for inventory: InventoryModel in [_player_inventory, _merchant_inventory]:
		if inventory == null:
			continue
		for pair: Array in [[&"item_quantity_changed", _on_inventory_changed], [&"reservation_changed", _on_reservation_changed], [&"inventory_reset", _on_inventory_reset]]:
			if inventory.is_connected(pair[0], pair[1]):
				inventory.disconnect(pair[0], pair[1])
	var relationships := get_node_or_null("/root/Relationships")
	if relationships != null and relationships.favor_changed.is_connected(_on_favor_changed):
		relationships.favor_changed.disconnect(_on_favor_changed)


func _on_inventory_changed(_id: StringName, _total: int, _available: int, _reason: StringName) -> void:
	if visible:
		_refresh()


func _on_reservation_changed(_id: StringName, _reason: StringName) -> void:
	if visible:
		_refresh()


func _on_inventory_reset() -> void:
	if visible:
		_refresh()


func _on_favor_changed(owner: Node, other: Node, _favor: float, _delta: float, _relationship: Dictionary) -> void:
	if visible and _merchant != null and owner == _merchant.get_parent() and other == _merchant.get_trade_player():
		_refresh()


func _clear_grid(grid: GridContainer, slots: Array[InventoryItemSlot]) -> void:
	for child: Node in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	slots.clear()


func _slot_exists(slots: Array[InventoryItemSlot], item_id: StringName) -> bool:
	return _find_slot(slots, item_id) != null


func _find_slot(slots: Array[InventoryItemSlot], item_id: StringName) -> InventoryItemSlot:
	for slot: InventoryItemSlot in slots:
		if slot.item_id == item_id:
			return slot
	return null


func _focus_first_slot() -> void:
	var slot := _find_slot(_buy_slots, _buy_selected_id)
	if slot == null:
		slot = _find_slot(_sell_slots, _sell_selected_id)
	if slot != null:
		slot.grab_focus.call_deferred()
