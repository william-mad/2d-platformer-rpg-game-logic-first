class_name PlayerStateDash extends PlayerState

@export_group("Dash Feel")
@export var dash_speed: float = 1650.0
@export var dash_duration: float = 0.16
@export var dash_exit_speed_multiplier: float = 0.75
@export var dash_ease_power: float = 1.85
@export var air_vertical_velocity_multiplier: float = 0.22
@export var dash_gravity_multiplier: float = 0.0

@export_group("Input")
@export var double_tap_window: float = 0.25
@export var cooldown_time: float = 0.28

@export_group("Visuals")
@export var afterimage_enabled: bool = true
@export var afterimage_interval: float = 0.026
@export var afterimage_lifetime: float = 0.18
@export var afterimage_color: Color = Color(0.45, 0.8, 1.0, 0.42)
@export var streak_enabled: bool = true
@export var streak_length: float = 86.0
@export var streak_lifetime: float = 0.11
@export var streak_width: float = 6.0
@export var streak_color: Color = Color(0.7, 0.95, 1.0, 0.55)

var dash_timer: float = 0.0
var dash_elapsed: float = 0.0
var dash_direction: float = 1.0
var last_tap_direction: float = 0.0
var last_tap_time_msec: int = -100000
var cooldown_end_msec: int = 0
var previous_gravity_multiplier: float = 1.0
var afterimage_timer: float = 0.0


func init() -> void:
	pass


func enter() -> void:
	run.enable_running()
	dash_timer = dash_duration
	dash_elapsed = 0.0
	afterimage_timer = 0.0
	previous_gravity_multiplier = player.gravity_multiplier
	player.gravity_multiplier = dash_gravity_multiplier
	cooldown_end_msec = Time.get_ticks_msec() + int(cooldown_time * 1000.0)
	player.animation_player.play("run")
	player.velocity.x = dash_direction * get_current_dash_speed()
	if player.is_on_floor():
		player.velocity.y = minf(player.velocity.y, 0.0)
	else:
		player.velocity.y *= clampf(air_vertical_velocity_multiplier, 0.0, 1.0)
	player.ledgegrabcolider.disabled = true
	_spawn_dash_streak()
	_spawn_afterimage()
	next_state = null


func exit() -> void:
	player.gravity_multiplier = previous_gravity_multiplier
	if player.direction.x == 0.0:
		player.velocity.x = dash_direction * player.move_speed * dash_exit_speed_multiplier
	else:
		player.velocity.x = player.direction.x * player.move_speed * dash_exit_speed_multiplier


func handle_input(_event: InputEvent) -> PlayerState:
	if _event.is_action_released("attack"):
		clear_attack_charge()

	return null


func process(delta: float) -> PlayerState:
	dash_timer -= delta
	dash_elapsed += delta
	update_dash_visuals(delta)

	if dash_timer > 0.0:
		return null

	if player.is_on_floor():
		if player.direction.x != 0:
			return run

		return idle

	return fall


func physics_process(_delta: float) -> PlayerState:
	player.velocity.x = dash_direction * get_current_dash_speed()

	return null


func get_dash_state_from_input(_event: InputEvent) -> PlayerState:
	var tap_direction := get_tap_direction(_event)

	if tap_direction == 0.0:
		return null

	var now := Time.get_ticks_msec()

	if now < cooldown_end_msec:
		return null

	var is_double_tap := tap_direction == last_tap_direction and now - last_tap_time_msec <= int(double_tap_window * 1000.0)
	last_tap_direction = tap_direction
	last_tap_time_msec = now

	if not is_double_tap:
		return null

	dash_direction = tap_direction
	player.apply_facing_left(dash_direction < 0.0)
	last_tap_time_msec = -100000
	return self


func get_tap_direction(_event: InputEvent) -> float:
	if _event is InputEventKey and _event.echo:
		return 0.0

	if _event.is_action_pressed("left"):
		return -1.0

	if _event.is_action_pressed("right"):
		return 1.0

	return 0.0


func get_current_dash_speed() -> float:
	var duration := maxf(dash_duration, 0.001)
	var progress := clampf(dash_elapsed / duration, 0.0, 1.0)
	var eased_progress := pow(progress, maxf(dash_ease_power, 0.01))
	var exit_speed := player.move_speed * maxf(dash_exit_speed_multiplier, 0.0)
	return lerpf(dash_speed, exit_speed, eased_progress)


func update_dash_visuals(delta: float) -> void:
	if not afterimage_enabled:
		return

	afterimage_timer -= delta
	if afterimage_timer > 0.0:
		return

	afterimage_timer = maxf(afterimage_interval, 0.001)
	_spawn_afterimage()


func _spawn_afterimage() -> void:
	if not afterimage_enabled:
		return

	var source := player.sprite_2d
	if source == null or source.texture == null:
		return

	var ghost := Sprite2D.new()
	ghost.texture = source.texture
	ghost.hframes = source.hframes
	ghost.vframes = source.vframes
	ghost.frame = source.frame
	ghost.flip_h = source.flip_h
	ghost.flip_v = source.flip_v
	ghost.centered = source.centered
	ghost.offset = source.offset
	ghost.modulate = afterimage_color
	ghost.z_index = source.z_index - 1
	ghost.top_level = true
	ghost.global_transform = source.global_transform

	var parent := get_dash_visual_parent()
	parent.add_child(ghost)

	var tween := ghost.create_tween()
	tween.tween_property(ghost, "modulate:a", 0.0, maxf(afterimage_lifetime, 0.01))
	tween.tween_callback(Callable(ghost, "queue_free"))


func _spawn_dash_streak() -> void:
	if not streak_enabled:
		return

	var parent := get_dash_visual_parent()
	var streak := Line2D.new()
	streak.default_color = streak_color
	streak.width = maxf(streak_width, 1.0)
	streak.z_index = 30
	streak.top_level = true

	var center := player.sprite_2d.global_position if player.sprite_2d != null else player.global_position
	var start := center - Vector2(dash_direction * absf(streak_length), 0.0)
	var end := center + Vector2(dash_direction * 12.0, 0.0)
	streak.add_point(start)
	streak.add_point(end)
	parent.add_child(streak)

	var tween := streak.create_tween()
	tween.tween_property(streak, "width", 1.0, maxf(streak_lifetime, 0.01))
	tween.parallel().tween_property(streak, "modulate:a", 0.0, maxf(streak_lifetime, 0.01))
	tween.tween_callback(Callable(streak, "queue_free"))


func get_dash_visual_parent() -> Node:
	if player.get_parent() != null:
		return player.get_parent()

	return player
