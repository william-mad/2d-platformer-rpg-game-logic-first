class_name ProcessingRecipeDefinition
extends Resource

@export var recipe_id: StringName = &""
@export var display_name: String = ""
@export var input_items: Dictionary = {}
@export var output_items: Dictionary = {}


func validate(catalog: ItemCatalog) -> PackedStringArray:
	var errors := PackedStringArray()
	if recipe_id == &"":
		errors.append("Recipe ID is required.")
	if display_name.strip_edges().is_empty():
		errors.append("Recipe display name is required.")
	_validate_item_map(input_items, "input", catalog, errors)
	_validate_item_map(output_items, "output", catalog, errors)
	return errors


func _validate_item_map(items: Dictionary, label: String, catalog: ItemCatalog, errors: PackedStringArray) -> void:
	if items.is_empty():
		errors.append("Recipe %s items cannot be empty." % label)
		return
	for raw_id: Variant in items:
		var item_id := StringName(String(raw_id).strip_edges())
		var raw_quantity: Variant = items[raw_id]
		if item_id == &"" or catalog == null or not catalog.has_item(item_id):
			errors.append("Recipe %s references unknown item '%s'." % [label, String(item_id)])
		elif typeof(raw_quantity) != TYPE_INT or int(raw_quantity) <= 0:
			errors.append("Recipe %s quantity for '%s' must be a positive integer." % [label, String(item_id)])
