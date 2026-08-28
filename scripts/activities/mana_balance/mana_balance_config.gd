class_name ManaBalanceConfig
extends Resource

@export_group("Orb movement")
@export var orb_acceleration: float = 640.0
@export var orb_drag: float = 3.2
@export var orb_maximum_speed: float = 170.0
@export var orb_turn_acceleration_multiplier: float = 1.8
@export var orb_stop_speed_threshold: float = 0.75
@export var arena_size: Vector2 = Vector2(300.0, 210.0)

@export_group("Magical current")
@export var starting_force_strength: float = 90.0
@export var force_increase_per_success: float = 8.0
@export var maximum_force_strength: float = 220.0
@export var force_change_interval: float = 2.5

@export_group("Zones")
@export var perfect_radius: float = 22.0
@export var warning_radius: float = 48.0

@export_group("Concentration")
@export var concentration_fill_rate: float = 1.0
@export var warning_drain_rate: float = 0.25
@export var failure_drain_rate: float = 0.75
@export var required_concentration: float = 3.0

@export_group("Scoring")
@export var multiplier_seconds_per_step: float = 1.5
@export var maximum_multiplier: float = 3.0
@export var base_success_score: float = 100.0
@export var reset_delay_seconds: float = 0.4


func is_valid_config() -> bool:
	return (
		orb_acceleration >= 0.0
		and orb_drag >= 0.0
		and orb_maximum_speed > 0.0
		and orb_turn_acceleration_multiplier >= 1.0
		and orb_stop_speed_threshold >= 0.0
		and arena_size.x > warning_radius * 2.0
		and arena_size.y > warning_radius * 2.0
		and starting_force_strength >= 0.0
		and force_increase_per_success >= 0.0
		and maximum_force_strength >= starting_force_strength
		and force_change_interval > 0.0
		and perfect_radius > 0.0
		and warning_radius > perfect_radius
		and concentration_fill_rate > 0.0
		and warning_drain_rate >= 0.0
		and failure_drain_rate >= warning_drain_rate
		and required_concentration > 0.0
		and multiplier_seconds_per_step > 0.0
		and maximum_multiplier >= 1.0
		and base_success_score >= 0.0
		and reset_delay_seconds >= 0.0
	)


func get_orb_config() -> Dictionary:
	return {
		"acceleration": orb_acceleration,
		"drag": orb_drag,
		"maximum_speed": orb_maximum_speed,
		"turn_acceleration_multiplier": orb_turn_acceleration_multiplier,
		"stop_speed_threshold": orb_stop_speed_threshold,
	}
