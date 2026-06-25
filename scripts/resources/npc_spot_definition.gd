class_name NpcSpotDefinition extends Resource

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

@export_group("Serving")
@export var owner_npc_ids: Array[StringName] = []
@export_range(0, 32, 1) var capacity: int = 1

@export_group("Schedule")
@export var active_time_windows: Array[Dictionary] = []


func is_valid_definition() -> bool:
	return spot_id != &"" and not scene_path.is_empty() and state_name != &""


func allows_npc_id(npc_id: StringName) -> bool:
	if owner_npc_ids.is_empty():
		return true

	for owner_id in owner_npc_ids:
		if String(owner_id) == String(npc_id):
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


func _window_contains_hour(window: Dictionary, hour: float) -> bool:
	var start_hour := fposmod(float(window.get("start_hour", window.get("start", 0.0))), 24.0)
	var end_hour := fposmod(float(window.get("end_hour", window.get("end", 24.0))), 24.0)
	var normalized_hour := fposmod(hour, 24.0)

	if is_equal_approx(start_hour, end_hour):
		return true
	if start_hour < end_hour:
		return normalized_hour >= start_hour and normalized_hour < end_hour

	return normalized_hour >= start_hour or normalized_hour < end_hour
