class_name MealIngredientStorage
extends Node2D

@export var storage_id: StringName = &""
@export var controller_definition: NpcSpotDefinition


func get_controller_spot_id() -> StringName:
	if controller_definition == null:
		return &""
	return controller_definition.spot_id


func is_infinite_storage() -> bool:
	return (
		controller_definition != null
		and controller_definition.meal_cycle_infinite_ingredient_storage
	)


func get_batches_per_prep() -> int:
	if not is_infinite_storage():
		return 0
	return controller_definition.meal_cycle_storage_batches_per_prep
