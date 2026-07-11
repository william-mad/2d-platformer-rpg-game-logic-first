class_name PlayerInventoryScreen
extends Control

@onready var items_container: VBoxContainer = %ItemsContainer

var _inventory: InventoryModel
var _catalog: ItemCatalog = ItemCatalog.new()
var _display_dirty: bool = true


func _ready() -> void:
	visible = false
	if not _catalog.load_definitions():
		push_warning("Player inventory screen loaded an item catalog with validation errors: %s" % str(_catalog.get_validation_errors()))


func bind_inventory(inventory: InventoryModel) -> void:
	if _inventory == inventory:
		return
	_disconnect_inventory_signals()
	_inventory = inventory
	_connect_inventory_signals()
	_display_dirty = true
	if visible:
		_refresh_items()


func unbind_inventory(inventory: InventoryModel = null) -> void:
	if inventory != null and _inventory != inventory:
		return
	_disconnect_inventory_signals()
	_inventory = null
	_display_dirty = true


func has_bound_inventory() -> bool:
	return _inventory != null


func is_bound_to(inventory: InventoryModel) -> bool:
	return _inventory == inventory


func open_screen() -> void:
	if _inventory == null:
		return
	visible = true
	if _display_dirty:
		_refresh_items()


func close_screen() -> void:
	visible = false


func is_open() -> bool:
	return visible


func _connect_inventory_signals() -> void:
	if _inventory == null:
		return
	_inventory.item_quantity_changed.connect(_on_item_quantity_changed)
	_inventory.reservation_changed.connect(_on_reservation_changed)
	_inventory.inventory_reset.connect(_on_inventory_reset)


func _disconnect_inventory_signals() -> void:
	if _inventory == null:
		return
	var item_callback := Callable(self, "_on_item_quantity_changed")
	if _inventory.item_quantity_changed.is_connected(item_callback):
		_inventory.item_quantity_changed.disconnect(item_callback)
	var reservation_callback := Callable(self, "_on_reservation_changed")
	if _inventory.reservation_changed.is_connected(reservation_callback):
		_inventory.reservation_changed.disconnect(reservation_callback)
	var reset_callback := Callable(self, "_on_inventory_reset")
	if _inventory.inventory_reset.is_connected(reset_callback):
		_inventory.inventory_reset.disconnect(reset_callback)


func _on_item_quantity_changed(
	_item_id: StringName,
	_total_quantity: int,
	_available_quantity: int,
	_reason: StringName
) -> void:
	_mark_display_dirty()


func _on_reservation_changed(_reservation_id: StringName, _reason: StringName) -> void:
	_mark_display_dirty()


func _on_inventory_reset() -> void:
	_mark_display_dirty()


func _mark_display_dirty() -> void:
	_display_dirty = true
	if visible:
		_refresh_items()


func _refresh_items() -> void:
	_clear_rows()
	_display_dirty = false
	if _inventory == null:
		_add_empty_label("Inventory is unavailable.")
		return

	var entries: Array[Dictionary] = []
	var unresolved_ids: PackedStringArray = PackedStringArray()
	var quantities := _inventory.get_all_quantities()
	for raw_item_id: Variant in quantities:
		var quantity := int(quantities[raw_item_id])
		if quantity <= 0:
			continue
		var item_id := StringName(String(raw_item_id))
		var definition := _catalog.get_definition(item_id)
		var display_name := String(item_id)
		if definition != null and not definition.display_name.is_empty():
			display_name = definition.display_name
		else:
			unresolved_ids.append(String(item_id))
		entries.append({
			"id": item_id,
			"name": display_name,
			"sort_name": display_name.to_lower(),
			"definition": definition,
			"quantity": quantity,
		})

	entries.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if left["sort_name"] == right["sort_name"]:
			return String(left["id"]) < String(right["id"])
		return String(left["sort_name"]) < String(right["sort_name"])
	)

	if entries.is_empty():
		_add_empty_label("Inventory is empty.")
	else:
		for entry: Dictionary in entries:
			_add_item_row(entry)
	if not unresolved_ids.is_empty():
		push_warning("Player inventory contains unresolved item IDs: %s" % ", ".join(unresolved_ids))


func _clear_rows() -> void:
	for child: Node in items_container.get_children():
		items_container.remove_child(child)
		child.queue_free()


func _add_empty_label(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(0.76, 0.78, 0.82, 1.0))
	label.add_theme_font_size_override("font_size", 18)
	items_container.add_child(label)


func _add_item_row(entry: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0.0, 42.0)
	row.add_theme_constant_override("separation", 12)
	var definition := entry["definition"] as ItemDefinition
	if definition != null and definition.icon != null:
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(32.0, 32.0)
		icon.texture = definition.icon
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(icon)

	var name_label := Label.new()
	name_label.text = String(entry["name"])
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 17)
	row.add_child(name_label)

	var item_id: StringName = entry["id"]
	var total := int(entry["quantity"])
	var reserved := _inventory.get_reserved_quantity(item_id)
	var quantity_label := Label.new()
	quantity_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	quantity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	quantity_label.custom_minimum_size.x = 220.0
	if reserved > 0:
		quantity_label.text = "%d total  |  %d available  |  %d reserved" % [
			total,
			_inventory.get_available_quantity(item_id),
			reserved,
		]
	else:
		quantity_label.text = str(total)
	row.add_child(quantity_label)
	items_container.add_child(row)
