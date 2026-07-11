class_name LootTableEntry
extends Resource

@export var item_id: StringName = &""
@export_range(0.0, 1.0, 0.01) var drop_chance: float = 1.0
@export_range(0, 999999, 1) var minimum_quantity: int = 1
@export_range(0, 999999, 1) var maximum_quantity: int = 1


func get_validation_error(catalog: ItemCatalog) -> String:
	if String(item_id).strip_edges().is_empty():
		return "item ID is empty"
	if catalog == null or not catalog.has_item(item_id):
		return "unknown item ID '%s'" % String(item_id)
	if drop_chance < 0.0 or drop_chance > 1.0:
		return "drop chance %.3f is outside 0..1" % drop_chance
	if minimum_quantity < 0:
		return "minimum quantity is negative"
	if maximum_quantity < minimum_quantity:
		return "maximum quantity is below minimum quantity"
	return ""
