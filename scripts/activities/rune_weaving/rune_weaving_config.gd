class_name RuneWeavingConfig
extends Resource

@export_group("Cursor")
@export var cursor_speed: float = 270.0
@export var cursor_acceleration: float = 1800.0
@export var cursor_drag: float = 2400.0
@export var cursor_turn_acceleration_multiplier: float = 1.6
@export var cursor_stop_speed_threshold: float = 6.0

@export_group("Targets")
@export var activation_radius: float = 26.0
@export var snap_cursor_to_activated_node: bool = true
@export_range(2, 20, 1) var starting_node_count: int = 3
@export_range(2, 20, 1) var maximum_node_count: int = 7
@export var field_size: Vector2 = Vector2(420.0, 250.0)
@export var target_margin: float = 28.0
@export var minimum_target_spacing: float = 72.0

@export_group("Preview and memory")
@export var preview_duration: float = 2.5
@export var minimum_preview_duration: float = 0.75
@export var preview_reduction_per_difficulty: float = 0.3
@export_range(0, 20, 1) var rounds_with_visible_sequence: int = 2

@export_group("Scoring and difficulty")
@export var mistake_penalty: float = 15.0
@export var base_completion_score: float = 100.0
@export var speed_bonus: float = 75.0
@export var target_seconds_per_node: float = 1.5
@export var streak_multiplier: float = 0.25
@export_range(1, 20, 1) var difficulty_increase_interval: int = 2

@export_group("Presentation timing")
@export var round_transition_delay: float = 0.65
@export var feedback_duration: float = 0.4


func is_valid_config() -> bool:
	var usable_size := get_target_bounds().size
	return (
		cursor_speed > 0.0
		and cursor_acceleration > 0.0
		and cursor_drag >= 0.0
		and cursor_turn_acceleration_multiplier >= 1.0
		and cursor_stop_speed_threshold >= 0.0
		and activation_radius > 0.0
		and starting_node_count >= 2
		and maximum_node_count >= starting_node_count
		and field_size.x > target_margin * 2.0
		and field_size.y > target_margin * 2.0
		and minimum_target_spacing > activation_radius * 2.0
		and usable_size.x > 0.0
		and usable_size.y > 0.0
		and get_grid_capacity() >= maximum_node_count
		and preview_duration >= 0.0
		and minimum_preview_duration >= 0.0
		and minimum_preview_duration <= preview_duration
		and preview_reduction_per_difficulty >= 0.0
		and rounds_with_visible_sequence >= 0
		and mistake_penalty >= 0.0
		and base_completion_score >= 0.0
		and speed_bonus >= 0.0
		and target_seconds_per_node > 0.0
		and streak_multiplier >= 0.0
		and difficulty_increase_interval > 0
		and round_transition_delay >= 0.0
		and feedback_duration >= 0.0
	)


func get_cursor_config() -> Dictionary:
	return {
		"acceleration": cursor_acceleration,
		"drag": cursor_drag,
		"maximum_speed": cursor_speed,
		"turn_acceleration_multiplier": cursor_turn_acceleration_multiplier,
		"stop_speed_threshold": cursor_stop_speed_threshold,
	}


func get_cursor_bounds() -> Rect2:
	return Rect2(-field_size * 0.5, field_size)


func get_target_bounds() -> Rect2:
	var usable_size := field_size - Vector2.ONE * target_margin * 2.0
	return Rect2(-usable_size * 0.5, usable_size)


func get_grid_capacity() -> int:
	if minimum_target_spacing <= 0.0:
		return 0
	var usable_size := get_target_bounds().size
	var columns := floori(usable_size.x / minimum_target_spacing) + 1
	var rows := floori(usable_size.y / minimum_target_spacing) + 1
	return maxi(columns, 0) * maxi(rows, 0)


func get_difficulty_level(completed_runes: int) -> int:
	return maxi(completed_runes, 0) / maxi(difficulty_increase_interval, 1)


func get_node_count(completed_runes: int) -> int:
	return mini(
		maximum_node_count,
		starting_node_count + get_difficulty_level(completed_runes)
	)


func get_preview_duration(completed_runes: int) -> float:
	return maxf(
		minimum_preview_duration,
		preview_duration
			- preview_reduction_per_difficulty * float(get_difficulty_level(completed_runes))
	)


func should_hide_sequence_after_preview(completed_runes: int) -> bool:
	return completed_runes >= rounds_with_visible_sequence
