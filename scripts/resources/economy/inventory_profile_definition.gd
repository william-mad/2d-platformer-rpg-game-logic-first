class_name InventoryProfileDefinition
extends Resource

@export var items: Dictionary = {}


func validate(catalog: ItemCatalog) -> PackedStringArray:
	var errors := PackedStringArray()
	if catalog == null:
		errors.append("An item catalog is required.")
		return errors
	for raw_id: Variant in items:
		var item_id := StringName(String(raw_id).strip_edges())
		var quantity := int(items[raw_id])
		if item_id == &"":
			errors.append("Inventory profile item IDs cannot be empty.")
		elif quantity <= 0:
			errors.append("Inventory profile quantity for '%s' must be positive." % String(item_id))
		elif not catalog.has_item(item_id):
			errors.append("Inventory profile references unknown item '%s'." % String(item_id))
	return errors
