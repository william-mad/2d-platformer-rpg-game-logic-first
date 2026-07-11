class_name InventoryItemSlot
extends Button

signal inspected(slot: InventoryItemSlot)

const FALLBACK_ICON: Texture2D = preload("res://images/sprites/assets/gpticons/book.png")

@onready var icon_rect: TextureRect = %Icon
@onready var quantity_label: Label = %QuantityLabel
@onready var reserved_label: Label = %ReservedIndicator
@onready var price_label: Label = %PriceLabel
@onready var lock_overlay: Label = %LockOverlay

var item_id: StringName = &""
var definition: ItemDefinition
var total_quantity: int = 0
var available_quantity: int = 0
var reserved_quantity: int = 0
var unit_price: int = 0
var locked: bool = false
var lock_reason: String = ""
var visually_disabled: bool = false


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func() -> void: inspected.emit(self))
	focus_entered.connect(func() -> void: inspected.emit(self))
	pressed.connect(func() -> void: inspected.emit(self))


func configure(
		new_item_id: StringName,
		new_definition: ItemDefinition,
		total: int,
		available: int,
		reserved: int,
		price: int = 0,
		is_locked: bool = false,
		new_lock_reason: String = "",
		is_disabled: bool = false
) -> void:
	item_id = new_item_id
	definition = new_definition
	total_quantity = total
	available_quantity = available
	reserved_quantity = reserved
	unit_price = price
	locked = is_locked
	lock_reason = new_lock_reason
	visually_disabled = is_disabled
	tooltip_text = definition.display_name if definition != null else String(item_id)
	_refresh_visuals()


func _refresh_visuals() -> void:
	if not is_node_ready():
		return
	icon_rect.texture = definition.icon if definition != null and definition.icon != null else FALLBACK_ICON
	quantity_label.text = "x%d" % total_quantity
	reserved_label.visible = reserved_quantity > 0
	reserved_label.text = "R%d" % reserved_quantity
	price_label.visible = unit_price > 0
	price_label.text = "%dg" % unit_price
	lock_overlay.visible = locked
	lock_overlay.text = "LOCK"
	modulate = Color(0.62, 0.62, 0.62, 1.0) if visually_disabled else Color.WHITE
