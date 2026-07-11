class_name TradeScreen
extends PanelContainer

signal close_requested

var _player_inventory: InventoryModel
var _merchant: MerchantComponent
var _merchant_inventory: InventoryModel
var _catalog := ItemCatalog.new()

var _player_gold_label: Label
var _merchant_gold_label: Label
var _buy_list: ItemList
var _sell_list: ItemList
var _buy_price_label: Label
var _sell_price_label: Label
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
	_disconnect_inventory_signals()
	_player_inventory = player_inventory
	_merchant = merchant
	_merchant_inventory = merchant.get_inventory()
	_connect_inventory_signals()
	_feedback.text = ""
	visible = true
	_refresh()
	return true


func close_screen() -> void:
	if not visible:
		return
	visible = false
	_disconnect_inventory_signals()
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
	return _buy_list.item_count


func get_sell_item_count() -> int:
	return _sell_list.item_count


func _build_interface() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 90)
	margin.add_theme_constant_override("margin_top", 55)
	margin.add_theme_constant_override("margin_right", 90)
	margin.add_theme_constant_override("margin_bottom", 55)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)
	var title := Label.new()
	title.text = "Trade"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	root.add_child(title)
	var gold_row := HBoxContainer.new()
	root.add_child(gold_row)
	_player_gold_label = Label.new()
	_player_gold_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gold_row.add_child(_player_gold_label)
	_merchant_gold_label = Label.new()
	_merchant_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_merchant_gold_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gold_row.add_child(_merchant_gold_label)
	var columns := HBoxContainer.new()
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 24)
	root.add_child(columns)
	var buy_column := VBoxContainer.new()
	buy_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(buy_column)
	buy_column.add_child(_make_heading("Merchant stock"))
	_buy_list = ItemList.new()
	_buy_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_buy_list.item_selected.connect(_on_selection_changed)
	buy_column.add_child(_buy_list)
	_buy_price_label = Label.new()
	buy_column.add_child(_buy_price_label)
	_buy_button = Button.new()
	_buy_button.text = "Buy"
	_buy_button.pressed.connect(_on_buy_pressed)
	buy_column.add_child(_buy_button)
	var sell_column := VBoxContainer.new()
	sell_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(sell_column)
	sell_column.add_child(_make_heading("Your items"))
	_sell_list = ItemList.new()
	_sell_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sell_list.item_selected.connect(_on_selection_changed)
	sell_column.add_child(_sell_list)
	_sell_price_label = Label.new()
	sell_column.add_child(_sell_price_label)
	_sell_button = Button.new()
	_sell_button.text = "Sell"
	_sell_button.pressed.connect(_on_sell_pressed)
	sell_column.add_child(_sell_button)
	var quantity_row := HBoxContainer.new()
	root.add_child(quantity_row)
	var quantity_label := Label.new()
	quantity_label.text = "Quantity"
	quantity_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quantity_row.add_child(quantity_label)
	_quantity = SpinBox.new()
	_quantity.min_value = 1
	_quantity.max_value = 9999
	_quantity.value = 1
	_quantity.value_changed.connect(_on_quantity_changed)
	quantity_row.add_child(_quantity)
	_feedback = Label.new()
	_feedback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_feedback)
	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(func() -> void: close_requested.emit())
	root.add_child(close_button)


func _make_heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	return label


func _refresh() -> void:
	if _player_inventory == null or _merchant_inventory == null or _merchant == null:
		return
	var buy_selected := _selected_item_id(_buy_list)
	var sell_selected := _selected_item_id(_sell_list)
	_player_gold_label.text = "Your gold: %d" % _player_inventory.get_quantity(TradeService.GOLD_ITEM_ID)
	_merchant_gold_label.text = "Merchant gold: %d" % _merchant_inventory.get_quantity(TradeService.GOLD_ITEM_ID)
	_fill_list(_buy_list, _merchant_inventory)
	_fill_list(_sell_list, _player_inventory)
	_restore_selection(_buy_list, buy_selected)
	_restore_selection(_sell_list, sell_selected)
	_refresh_controls()


func _fill_list(list: ItemList, inventory: InventoryModel) -> void:
	list.clear()
	var entries: Array[Dictionary] = []
	for raw_id: Variant in inventory.get_all_quantities():
		var item_id := StringName(String(raw_id))
		var available := inventory.get_available_quantity(item_id)
		if available <= 0 or not _merchant.is_item_tradable(item_id):
			continue
		var definition := _catalog.get_definition(item_id)
		entries.append({"id": item_id, "name": definition.display_name if definition != null else String(item_id), "available": available})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["name"]) < String(b["name"]))
	for entry: Dictionary in entries:
		var index := list.add_item("%s  x%d" % [entry["name"], entry["available"]])
		list.set_item_metadata(index, entry["id"])


func _restore_selection(list: ItemList, item_id: StringName) -> void:
	for index in list.item_count:
		if StringName(String(list.get_item_metadata(index))) == item_id:
			list.select(index)
			return
	if list.item_count > 0:
		list.select(0)


func _selected_item_id(list: ItemList) -> StringName:
	var selected := list.get_selected_items()
	return StringName(String(list.get_item_metadata(selected[0]))) if not selected.is_empty() else &""


func _refresh_controls() -> void:
	var quantity := int(_quantity.value)
	var buy_id := _selected_item_id(_buy_list)
	var sell_id := _selected_item_id(_sell_list)
	var buy_price := _merchant.get_price_to_player(buy_id) if buy_id != &"" else 0
	var sell_price := _merchant.get_price_from_player(sell_id) if sell_id != &"" else 0
	_buy_price_label.text = "Price: %d gold each" % buy_price if buy_price > 0 else "No item selected"
	_sell_price_label.text = "Price: %d gold each" % sell_price if sell_price > 0 else "No item selected"
	_buy_button.disabled = buy_price <= 0 or _merchant_inventory.get_available_quantity(buy_id) < quantity or _player_inventory.get_available_quantity(TradeService.GOLD_ITEM_ID) < buy_price * quantity
	_sell_button.disabled = sell_price <= 0 or _player_inventory.get_available_quantity(sell_id) < quantity or _merchant_inventory.get_available_quantity(TradeService.GOLD_ITEM_ID) < sell_price * quantity


func _on_buy_pressed() -> void:
	var item_id := _selected_item_id(_buy_list)
	var result := TradeService.buy_from_merchant(_player_inventory, _merchant_inventory, item_id, int(_quantity.value), _merchant.get_price_to_player(item_id))
	_feedback.text = result.message
	_refresh()


func _on_sell_pressed() -> void:
	var item_id := _selected_item_id(_sell_list)
	var result := TradeService.sell_to_merchant(_player_inventory, _merchant_inventory, item_id, int(_quantity.value), _merchant.get_price_from_player(item_id))
	_feedback.text = result.message
	_refresh()


func _on_selection_changed(_value: Variant = null) -> void:
	_refresh_controls()


func _on_quantity_changed(_value: float) -> void:
	_refresh_controls()


func _connect_inventory_signals() -> void:
	for inventory: InventoryModel in [_player_inventory, _merchant_inventory]:
		inventory.item_quantity_changed.connect(_on_inventory_changed)
		inventory.reservation_changed.connect(_on_reservation_changed)
		inventory.inventory_reset.connect(_on_inventory_reset)


func _disconnect_inventory_signals() -> void:
	for inventory: InventoryModel in [_player_inventory, _merchant_inventory]:
		if inventory == null:
			continue
		var item_callback := Callable(self, "_on_inventory_changed")
		if inventory.item_quantity_changed.is_connected(item_callback):
			inventory.item_quantity_changed.disconnect(item_callback)
		var reservation_callback := Callable(self, "_on_reservation_changed")
		if inventory.reservation_changed.is_connected(reservation_callback):
			inventory.reservation_changed.disconnect(reservation_callback)
		var reset_callback := Callable(self, "_on_inventory_reset")
		if inventory.inventory_reset.is_connected(reset_callback):
			inventory.inventory_reset.disconnect(reset_callback)


func _on_inventory_changed(_item_id: StringName, _total: int, _available: int, _reason: StringName) -> void:
	if visible:
		_refresh()


func _on_reservation_changed(_reservation_id: StringName, _reason: StringName) -> void:
	if visible:
		_refresh()


func _on_inventory_reset() -> void:
	if visible:
		_refresh()
