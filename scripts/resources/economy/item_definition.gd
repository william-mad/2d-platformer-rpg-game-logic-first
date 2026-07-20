class_name ItemDefinition
extends Resource

@export_group("Identity")
@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var category: StringName = &""
@export var tags: Array[StringName] = []

@export_group("Inventory and Economy")
@export_range(1, 9999, 1) var maximum_stack: int = 99
@export_range(0, 999999, 1) var base_value: int = 0
@export_range(0.0, 10000.0, 0.01) var unit_weight: float = 0.0
@export var icon: Texture2D
@export var tradable: bool = true
@export var trade_group: StringName = &"general"
@export_range(0.0, 100.0, 1.0) var minimum_favor_to_buy: float = 0.0
@export_range(0.0, 100.0, 1.0) var minimum_favor_to_sell: float = 0.0

@export_group("Food")
@export var edible: bool = false
@export var requires_processing: bool = false
@export_range(0.0, 100.0, 0.1) var hunger_reduction: float = 0.0
@export_range(-100.0, 100.0, 0.1) var health_change: float = 0.0
@export_range(-100.0, 100.0, 0.1) var tired_change: float = 0.0

@export_group("Equipment")
@export var equipment_profile: EquipmentProfile


func is_valid_definition() -> bool:
	return not String(id).strip_edges().is_empty() \
		and maximum_stack >= 1 \
		and base_value >= 0 \
		and unit_weight >= 0.0 \
		and (equipment_profile == null or equipment_profile.is_valid_profile())


func has_tag(tag: StringName) -> bool:
	return tag in tags
