class_name PlayerStateRoll extends PlayerState

@export_group("Roll Feel")
@export_range(0.05, 1.0, 0.01, "suffix:s") var roll_duration: float = 0.28
@export var minimum_roll_speed: float = 650.0
@export_range(0.0, 1.5, 0.05) var dash_speed_retention: float = 0.55
@export_range(0.0, 1.0, 0.05) var roll_exit_speed_multiplier: float = 0.45
@export_range(0.1, 4.0, 0.05) var speed_ease_power: float = 1.6

@export_group("Collision")
@export_range(1, 32, 1) var normal_player_layer: int = 2
@export_range(1, 32, 1) var roll_collision_layer: int = 12

@export_group("Visuals")
@export var animation_name: StringName = &"crouch"
@export_range(0.0, 2.0, 0.05) var visual_turns: float = 1.0

var roll_direction: float = 1.0
var entry_speed: float = 0.0
var elapsed: float = 0.0
var previous_collision_layer: int = 0
var roll_visual: Sprite2D = null
var previous_visual_rotation: float = 0.0


func prepare_from_dash(direction_x: float, dash_speed: float) -> void:
	if not is_zero_approx(direction_x):
		roll_direction = signf(direction_x)
	entry_speed = absf(dash_speed)


func enter() -> void:
	next_state = null
	elapsed = 0.0
	run.enable_running()
	player.ledgegrabcolider.disabled = true

	previous_collision_layer = player.collision_layer
	player.set_collision_layer_value(normal_player_layer, false)
	player.set_collision_layer_value(roll_collision_layer, true)

	if animation_name != &"" and player.animation_player.has_animation(animation_name):
		player.animation_player.play(animation_name)
	roll_visual = player.get_active_visual_sprite()
	if roll_visual != null:
		previous_visual_rotation = roll_visual.rotation

	var retained_dash_speed := entry_speed * maxf(dash_speed_retention, 0.0)
	entry_speed = maxf(minimum_roll_speed, retained_dash_speed)
	player.velocity.x = roll_direction * entry_speed


func exit() -> void:
	player.collision_layer = previous_collision_layer
	if roll_visual != null and is_instance_valid(roll_visual):
		roll_visual.rotation = previous_visual_rotation
	roll_visual = null


func handle_input(event: InputEvent) -> PlayerState:
	if event.is_action_released("attack"):
		clear_attack_charge()
	return null


func process(delta: float) -> PlayerState:
	elapsed = minf(elapsed + delta, roll_duration)
	_update_roll_visual()
	if elapsed >= roll_duration:
		if not player.is_on_floor():
			return fall
		return get_ground_movement_state_for_profile(true)
	return null


func physics_update_before_move(_delta: float) -> void:
	player.velocity.x = roll_direction * _get_current_roll_speed()


func _get_current_roll_speed() -> float:
	var progress := clampf(elapsed / maxf(roll_duration, 0.001), 0.0, 1.0)
	var eased_progress := pow(progress, maxf(speed_ease_power, 0.01))
	var exit_speed := player.move_speed * maxf(roll_exit_speed_multiplier, 0.0)
	return lerpf(entry_speed, exit_speed, eased_progress)


func _update_roll_visual() -> void:
	if roll_visual == null or not is_instance_valid(roll_visual):
		return
	var progress := clampf(elapsed / maxf(roll_duration, 0.001), 0.0, 1.0)
	roll_visual.rotation = previous_visual_rotation + TAU * visual_turns * roll_direction * progress
