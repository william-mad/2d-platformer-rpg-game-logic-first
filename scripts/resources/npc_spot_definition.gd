class_name NpcSpotDefinition extends Resource

const ScheduleWindowPolicy = preload(
	"res://scripts/systems/npc_schedule_window_policy.gd"
)

@export_group("Identity")
@export var spot_id: StringName = &""
@export_file("*.tscn") var scene_path: String = ""
@export var position: Vector2 = Vector2.ZERO

@export_group("Activity")
@export var state_name: StringName = &""
@export var value_name: StringName = &""
@export var need_threshold: float = 0.0
@export var need_maximum: float = -1.0
@export var value_delta_per_game_hour: float = 0.0
@export var priority: int = 20
@export var target_assignment_method: StringName = &""
@export var require_npc_value_threshold: bool = true
@export var finish_when_npc_value_sated: bool = true
@export var timed_need_thresholds: Array[Dictionary] = []

@export_group("Routine Task")
@export var routine_animation_name: StringName = &""
@export_range(0.0, 1440.0, 1.0, "suffix:min") var routine_game_minutes: float = 30.0
@export var routine_finish_when_value_sated: bool = true

@export_group("Mutable Spot Value")
@export var spot_value_name: StringName = &""
@export var spot_value_initial: float = 0.0
@export var spot_value_minimum: float = 0.0
@export var spot_value_maximum: float = 100.0
@export var spot_value_done_threshold: float = 0.0
@export var spot_value_delta_per_game_hour: float = 0.0
@export var spot_value_daily_growth: float = 0.0
@export var need_threshold_at_spot_value_maximum: float = -1.0

@export_group("Cycle")
@export var next_spot_id_when_done: StringName = &""
@export var next_spot_value_when_done: float = 100.0

@export_group("Meal Cycle")
@export var meal_cycle_id: StringName = &""
@export var meal_cycle_stage: StringName = &""
@export var meal_cycle_controller_spot_id: StringName = &""
@export var meal_cycle_food_spot_id: StringName = &""
@export var meal_cycle_food_spot_ids: Array[StringName] = []
@export var meal_cycle_cleanup_spot_ids: Array[StringName] = []
@export_range(0.0, 1000.0, 0.1) var meal_cycle_cleanup_share: float = 0.0
@export var meal_cycle_schedule: Array[Dictionary] = []
@export var meal_cycle_recipe: ProcessingRecipeDefinition
@export var meal_cycle_prep_owner_ids: Array[StringName] = []
@export var meal_cycle_food_owner_ids: Array[StringName] = []
@export var meal_cycle_cleanup_owner_ids: Array[StringName] = []
@export_range(0.0, 20.0, 0.01) var meal_cycle_cleanup_work_multiplier: float = 1.0
@export var meal_cycle_infinite_ingredient_storage: bool = false
@export_range(1, 64, 1) var meal_cycle_storage_batches_per_prep: int = 1

@export_group("Sleep Skip Wake")
@export var wake_at_home_position: bool = true
@export var wake_spot_id: StringName = &""
@export_file("*.tscn") var wake_scene_path: String = ""
@export var wake_position: Vector2 = Vector2.ZERO

@export_group("Serving")
@export var owner_ids: Array[StringName] = []
# Legacy NPC-only list. Use owner_ids for new spots, especially when the player can also use it.
@export var owner_npc_ids: Array[StringName] = []
@export var called_npc_ids: Array[StringName] = []
@export_range(0, 32, 1) var capacity: int = 1

@export_group("Schedule")
@export var active_time_windows: Array[Dictionary] = []


func is_valid_definition() -> bool:
	return get_validation_errors().is_empty()


func get_validation_errors() -> Array[String]:
	var errors: Array[String] = []
	if spot_id == &"":
		errors.append("spot_id is empty")
	if state_name == &"":
		errors.append("state_name is empty")
	if scene_path.is_empty():
		errors.append("scene_path is empty")
	elif (
		not scene_path.begins_with("res://")
		or scene_path.get_extension().to_lower() != "tscn"
	):
		errors.append("scene_path is not a res:// .tscn path")
	elif not ResourceLoader.exists(scene_path):
		errors.append("scene_path does not exist: %s" % scene_path)
	if not is_finite(position.x) or not is_finite(position.y):
		errors.append("position must be finite")
	for index in active_time_windows.size():
		var window = active_time_windows[index]
		if not (window is Dictionary):
			errors.append("active_time_windows[%d] is not a dictionary" % index)
			continue
		for field_name in ["start_hour", "end_hour"]:
			if not window.has(field_name):
				errors.append("active_time_windows[%d] has no %s" % [index, field_name])
				continue
			var hour := float(window[field_name])
			if not is_finite(hour) or hour < 0.0 or hour > 24.0:
				errors.append(
					"active_time_windows[%d].%s must be between 0 and 24" % [
						index, field_name,
					]
				)
		var start_policy := ScheduleWindowPolicy.canonicalize_start_policy(
			window.get("start_policy", ScheduleWindowPolicy.START_POLICY_HARD)
		)
		if start_policy not in [
			ScheduleWindowPolicy.START_POLICY_HARD,
			ScheduleWindowPolicy.START_POLICY_FLEXIBLE,
		]:
			errors.append(
				"active_time_windows[%d].start_policy must be hard or flexible"
				% index
			)
		if window.has("grace_game_minutes"):
			var grace_value: Variant = window["grace_game_minutes"]
			if not _is_finite_number(grace_value) or float(grace_value) < 0.0:
				errors.append(
					"active_time_windows[%d].grace_game_minutes must be finite and non-negative"
					% index
				)
			elif (
				window.has("start_hour")
				and window.has("end_hour")
				and float(grace_value) / 60.0
					> ScheduleWindowPolicy.get_window_duration_hours(window)
			):
				errors.append(
					"active_time_windows[%d].grace_game_minutes exceeds the window duration"
					% index
				)
		if window.has("late_priority_bonus"):
			var bonus_value: Variant = window["late_priority_bonus"]
			if not _is_finite_number(bonus_value) or float(bonus_value) < 0.0:
				errors.append(
					"active_time_windows[%d].late_priority_bonus must be finite and non-negative"
					% index
				)
		var completion_policy := ScheduleWindowPolicy.canonicalize_completion_policy(
			window.get(
				"completion_policy",
				ScheduleWindowPolicy.COMPLETION_POLICY_STOP_AT_WINDOW_END
			)
		)
		if completion_policy not in [
			ScheduleWindowPolicy.COMPLETION_POLICY_STOP_AT_WINDOW_END,
			ScheduleWindowPolicy.COMPLETION_POLICY_FINISH_CURRENT,
		]:
			errors.append(
				"active_time_windows[%d].completion_policy must be stop_at_window_end or finish_current"
				% index
			)
		if window.has("maximum_overtime_game_minutes"):
			var overtime_value: Variant = window["maximum_overtime_game_minutes"]
			if not _is_finite_number(overtime_value) or float(overtime_value) < 0.0:
				errors.append(
					"active_time_windows[%d].maximum_overtime_game_minutes must be finite and non-negative"
					% index
				)
			elif float(overtime_value) > ScheduleWindowPolicy.MAXIMUM_OVERTIME_GAME_MINUTES:
				errors.append(
					"active_time_windows[%d].maximum_overtime_game_minutes exceeds the safe maximum of %.0f"
					% [index, ScheduleWindowPolicy.MAXIMUM_OVERTIME_GAME_MINUTES]
				)
	if meal_cycle_recipe != null:
		var catalog := ItemCatalog.new()
		if not catalog.load_definitions():
			errors.append(
				"meal_cycle_recipe cannot be validated because the item catalog is invalid: %s"
				% "; ".join(catalog.get_validation_errors())
			)
		else:
			for recipe_error in meal_cycle_recipe.validate(catalog):
				errors.append("meal_cycle_recipe: %s" % recipe_error)
			var edible_output_found := false
			for raw_item_id: Variant in meal_cycle_recipe.output_items:
				var item_id := StringName(String(raw_item_id).strip_edges())
				var raw_quantity: Variant = meal_cycle_recipe.output_items[raw_item_id]
				if (
					typeof(raw_quantity) == TYPE_INT
					and int(raw_quantity) > 0
					and catalog.get_food_value(item_id) > 0.0
				):
					edible_output_found = true
					break
			if not edible_output_found:
				errors.append(
					"meal_cycle_recipe must produce at least one edible output with positive hunger value"
				)
	if meal_cycle_infinite_ingredient_storage:
		if meal_cycle_recipe == null:
			errors.append("infinite meal ingredient storage requires meal_cycle_recipe")
		if meal_cycle_storage_batches_per_prep < 1 or meal_cycle_storage_batches_per_prep > 64:
			errors.append("meal_cycle_storage_batches_per_prep must be between 1 and 64")
	return errors


func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) in [TYPE_INT, TYPE_FLOAT]
		and is_finite(float(value))
	)


func allows_npc_id(npc_id: StringName) -> bool:
	if not called_npc_ids.is_empty():
		return _id_is_in_list(npc_id, called_npc_ids)

	return allows_owner_id(npc_id)


func allows_owner_id(owner_id: StringName) -> bool:
	var configured_owner_ids := get_owner_ids()
	if configured_owner_ids.is_empty():
		return true

	for configured_owner_id in configured_owner_ids:
		if String(configured_owner_id) == String(owner_id):
			return true

	return false


func get_owner_ids() -> Array[StringName]:
	var configured_owner_ids: Array[StringName] = []
	for owner_id in owner_ids:
		if not configured_owner_ids.has(owner_id):
			configured_owner_ids.append(owner_id)
	for owner_id in owner_npc_ids:
		if not configured_owner_ids.has(owner_id):
			configured_owner_ids.append(owner_id)

	return configured_owner_ids


func get_called_npc_ids() -> Array[StringName]:
	var configured_called_ids: Array[StringName] = []
	for called_id in called_npc_ids:
		if not configured_called_ids.has(called_id):
			configured_called_ids.append(called_id)

	return configured_called_ids


func _id_is_in_list(npc_id: StringName, ids: Array[StringName]) -> bool:
	for configured_id in ids:
		if String(configured_id) == String(npc_id):
			return true

	return false


func is_active_at(hour: float) -> bool:
	if active_time_windows.is_empty():
		return true

	for window in active_time_windows:
		if not (window is Dictionary):
			continue
		if _window_contains_hour(window, hour):
			return true

	return false


func get_assignment_method() -> StringName:
	if target_assignment_method != &"":
		return target_assignment_method
	if state_name == &"":
		return &""

	return StringName("assign_%s_target" % String(state_name).to_snake_case())


func get_meal_cycle_work_multiplier_for_stage(stage: String) -> float:
	if stage == "cleanup_work":
		return maxf(meal_cycle_cleanup_work_multiplier, 0.0)

	return 1.0


func _window_contains_hour(window: Dictionary, hour: float) -> bool:
	var start_hour := fposmod(float(window.get("start_hour", window.get("start", 0.0))), 24.0)
	var end_hour := fposmod(float(window.get("end_hour", window.get("end", 24.0))), 24.0)
	var normalized_hour := fposmod(hour, 24.0)

	if is_equal_approx(start_hour, end_hour):
		return true
	if start_hour < end_hour:
		return normalized_hour >= start_hour and normalized_hour < end_hour

	return normalized_hour >= start_hour or normalized_hour < end_hour
