class_name ActivityCursor
extends Node2D

signal cursor_moved(current_position: Vector2, current_velocity: Vector2)

var acceleration: float = 1800.0
var drag: float = 2400.0
var maximum_speed: float = 270.0
var turn_acceleration_multiplier: float = 1.6
var stop_speed_threshold: float = 6.0
var input_source: InteractiveActivityInputSource
var movement_enabled: bool = false
var velocity: Vector2 = Vector2.ZERO
var _has_movement_bounds: bool = false
var _movement_bounds: Rect2 = Rect2()


func configure(config: Dictionary) -> bool:
	var configured_acceleration := float(config.get("acceleration", acceleration))
	var configured_drag := float(config.get("drag", drag))
	var configured_maximum_speed := float(config.get("maximum_speed", maximum_speed))
	var configured_turn_multiplier := float(config.get(
		"turn_acceleration_multiplier", turn_acceleration_multiplier
	))
	var configured_stop_threshold := float(config.get(
		"stop_speed_threshold", stop_speed_threshold
	))
	if configured_acceleration <= 0.0 or configured_drag < 0.0:
		return false
	if (
		configured_maximum_speed <= 0.0
		or configured_turn_multiplier < 1.0
		or configured_stop_threshold < 0.0
	):
		return false
	acceleration = configured_acceleration
	drag = configured_drag
	maximum_speed = configured_maximum_speed
	turn_acceleration_multiplier = configured_turn_multiplier
	stop_speed_threshold = configured_stop_threshold
	return true


func set_input_source(source: InteractiveActivityInputSource) -> void:
	input_source = source


func set_movement_enabled(enabled: bool) -> void:
	movement_enabled = enabled
	if not enabled:
		velocity = Vector2.ZERO


func reset_cursor(target_position: Vector2 = Vector2.ZERO) -> void:
	position = target_position
	velocity = Vector2.ZERO
	_apply_movement_bounds()
	cursor_moved.emit(position, velocity)


func set_movement_bounds(bounds: Rect2) -> void:
	_movement_bounds = bounds.abs()
	_has_movement_bounds = (
		_movement_bounds.size.x > 0.0 and _movement_bounds.size.y > 0.0
	)
	_apply_movement_bounds()


func clear_movement_bounds() -> void:
	_has_movement_bounds = false
	_movement_bounds = Rect2()


func get_cursor_position() -> Vector2:
	return position


func get_cursor_velocity() -> Vector2:
	return velocity


func _physics_process(delta: float) -> void:
	if not movement_enabled:
		return
	var safe_delta := maxf(delta, 0.0)
	var input_direction := Vector2.ZERO
	if input_source != null:
		input_direction = input_source.get_movement_vector()
	if input_direction.is_zero_approx():
		velocity = velocity.move_toward(Vector2.ZERO, drag * safe_delta)
		if velocity.length_squared() <= stop_speed_threshold * stop_speed_threshold:
			velocity = Vector2.ZERO
	else:
		var movement_acceleration := acceleration
		if not velocity.is_zero_approx() and velocity.dot(input_direction) < 0.0:
			movement_acceleration *= turn_acceleration_multiplier
		velocity = velocity.move_toward(
			input_direction * maximum_speed,
			movement_acceleration * safe_delta
		)
	position += velocity * safe_delta
	_apply_movement_bounds()
	cursor_moved.emit(position, velocity)


func _apply_movement_bounds() -> void:
	if not _has_movement_bounds:
		return
	var bounds_end := _movement_bounds.end
	var clamped_position := Vector2(
		clampf(position.x, _movement_bounds.position.x, bounds_end.x),
		clampf(position.y, _movement_bounds.position.y, bounds_end.y)
	)
	if not is_equal_approx(clamped_position.x, position.x):
		velocity.x = 0.0
	if not is_equal_approx(clamped_position.y, position.y):
		velocity.y = 0.0
	position = clamped_position
