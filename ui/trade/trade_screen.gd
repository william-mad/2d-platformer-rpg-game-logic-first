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
var _close_button: Button


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


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused is InventoryItemSlot:
		var no_slots: Array[InventoryItemSlot] = []
		if focused in _buy_slots and _move_trade_slot_focus(focused, _buy_slots, _sell_slots, event):
			get_viewport().set_input_as_handled()
		elif focused in _sell_slots and _move_trade_slot_focus(focused, _sell_slots, no_slots, event):
			get_viewport().set_input_as_handled()
		return
	if focused != _get_quantity_focus_control():
		return
	if event.is_action_pressed(&"ui_left"):
		_quantity.value = maxf(_quantity.value - 1.0, _quantity.min_value)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_right"):
		_quantity.value = minf(_quantity.value + 1.0, _quantity.max_value)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_up"):
		_defer_focus(_get_selected_trade_slot() if _get_selected_trade_slot() != null else _close_button)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_down"):
		_defer_focus(_get_first_enabled_trade_button())
		get_viewport().set_input_as_handled()


func _move_trade_slot_focus(
	slot: InventoryItemSlot,
	slots: Array[InventoryItemSlot],
	next_section: Array[InventoryItemSlot],
	event: InputEvent
) -> bool:
	var index := slots.find(slot)
	if index < 0:
		return false
	var column := index % 2
	if event.is_action_pressed(&"ui_left"):
		if column > 0:
			_defer_focus(slots[index - 1])
		elif slots == _sell_slots and not _buy_slots.is_empty():
			_defer_focus(_buy_slots[mini(index, _buy_slots.size() - 1)])
		else:
			return false
		return true
	if event.is_action_pressed(&"ui_right"):
		if index + 1 < slots.size() and column == 0:
			_defer_focus(slots[index + 1])
		elif not next_section.is_empty():
			_defer_focus(next_section[mini(index, next_section.size() - 1)])
		else:
			_defer_focus(_get_quantity_focus_control())
		return true
	if event.is_action_pressed(&"ui_up"):
		_defer_focus(slots[index - 2] if index >= 2 else _close_button)
		return true
	if event.is_action_pressed(&"ui_down"):
		_defer_focus(slots[index + 2] if index + 2 < slots.size() else _close_button)
		return true
	return false


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
		margin.add_theme_constant_override("margin_%s" % side, 14 if side in ["top", "bottom"] else 18)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 7)
	margin.add_child(root)
	var title := Label.new()
	title.text = "TRADE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
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
	columns.add_theme_constant_override("separation", 10)
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
	details_panel.custom_minimum_size = Vector2(190, 0)
	columns.add_child(details_panel)
	_details = Label.new()
	_details.custom_minimum_size = Vector2(190, 150)
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
	_close_button = Button.new()
	_close_button.text = "CLOSE"
	_close_button.pressed.connect(func() -> void: close_requested.emit())
	root.add_child(_close_button)


func _make_grid_section(title_text: String) -> Dictionary:
	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(230, 250)
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
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
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
	_configure_focus_navigation()
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
	_configure_focus_navigation()


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
	elif _close_button != null:
		_close_button.grab_focus.call_deferred()


func _configure_focus_navigation() -> void:
	if _close_button == null:
		return
	var first_detail := _get_quantity_focus_control()
	var no_slots: Array[InventoryItemSlot] = []
	_configure_trade_grid_navigation(_buy_slots, _sell_slots, first_detail)
	_configure_trade_grid_navigation(_sell_slots, no_slots, first_detail)
	var detail_controls: Array[Control] = [_get_quantity_focus_control()]
	if not _buy_button.disabled:
		detail_controls.append(_buy_button)
	if not _sell_button.disabled:
		detail_controls.append(_sell_button)
	for index in detail_controls.size():
		var control := detail_controls[index]
		var previous: Control = _get_selected_trade_slot() if index == 0 else detail_controls[index - 1]
		if previous == null:
			previous = _close_button
		var next: Control = _close_button if index == detail_controls.size() - 1 else detail_controls[index + 1]
		control.focus_neighbor_top = control.get_path_to(previous)
		control.focus_neighbor_bottom = control.get_path_to(next)
	var all_slots: Array[InventoryItemSlot] = []
	all_slots.append_array(_buy_slots)
	all_slots.append_array(_sell_slots)
	if not all_slots.is_empty():
		_close_button.focus_neighbor_top = _close_button.get_path_to(all_slots[-1])
		_close_button.focus_neighbor_bottom = _close_button.get_path_to(all_slots[0])


func _configure_trade_grid_navigation(
	slots: Array[InventoryItemSlot],
	next_section: Array[InventoryItemSlot],
	detail_control: Control
) -> void:
	for index in slots.size():
		var slot := slots[index]
		var column := index % 2
		if index + 1 < slots.size() and column == 0:
			slot.focus_neighbor_right = slot.get_path_to(slots[index + 1])
		elif not next_section.is_empty():
			slot.focus_neighbor_right = slot.get_path_to(next_section[mini(index, next_section.size() - 1)])
		else:
			slot.focus_neighbor_right = slot.get_path_to(detail_control)
		if index + 2 >= slots.size():
			slot.focus_neighbor_bottom = slot.get_path_to(_close_button)


func _get_selected_trade_slot() -> InventoryItemSlot:
	var slot := _find_slot(_buy_slots, _buy_selected_id)
	if slot == null:
		slot = _find_slot(_sell_slots, _sell_selected_id)
	return slot


func _get_first_enabled_trade_button() -> Control:
	if not _buy_button.disabled:
		return _buy_button
	if not _sell_button.disabled:
		return _sell_button
	return _close_button


func _defer_focus(control: Control) -> void:
	if control != null:
		control.grab_focus.call_deferred()


func _get_quantity_focus_control() -> Control:
	return _quantity.get_line_edit()
