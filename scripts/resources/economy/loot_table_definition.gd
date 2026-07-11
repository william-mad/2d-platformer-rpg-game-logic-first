class_name LootTableDefinition
extends Resource

@export var entries: Array[LootTableEntry] = []


func roll_loot(rng: RandomNumberGenerator = null) -> Dictionary:
	var catalog := ItemCatalog.new()
	if not catalog.load_definitions():
		push_warning("Loot table could not load a valid item catalog: %s" % str(catalog.get_validation_errors()))
	var active_rng := rng
	if active_rng == null:
		active_rng = RandomNumberGenerator.new()
		active_rng.randomize()

	var result: Dictionary = {}
	for index: int in entries.size():
		var entry := entries[index]
		if entry == null:
			push_warning("Loot table entry %d is null and was skipped." % index)
			continue
		var validation_error := entry.get_validation_error(catalog)
		if not validation_error.is_empty():
			push_warning("Loot table entry %d is invalid (%s) and was skipped." % [index, validation_error])
			continue
		if entry.drop_chance <= 0.0 or active_rng.randf() >= entry.drop_chance:
			continue
		var quantity := active_rng.randi_range(entry.minimum_quantity, entry.maximum_quantity)
		if quantity <= 0:
			continue
		var key := String(entry.item_id).strip_edges()
		result[key] = int(result.get(key, 0)) + quantity
	return result
