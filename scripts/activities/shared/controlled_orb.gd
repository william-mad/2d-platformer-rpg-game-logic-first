class_name ControlledActivityOrb
extends CharacterBody2D

signal orb_moved(current_position: Vector2, current_velocity: Vector2)

var acceleration: float = 500.0
var drag: float = 350.0
var maximum_speed: float = 180.0
var input_source: InteractiveActivityInputSource
var external_force: Vector2 = Vector2.ZERO
var movement_enabled: bool = false
var _has_movement_bounds: bool = false
var _movement_bounds: Rect2 = Rect2()


func configure(config: Dictionary) -> bool:
	var configured_acceleration := float(config.get("acceleration", acceleration))
	var configured_drag := float(config.get("drag", drag))
	var configured_maximum_speed := float(config.get("maximum_speed", maximum_speed))
	if configured_acceleration < 0.0 or configured_drag < 0.0:
		return false
	if configured_maximum_speed <= 0.0:
		return false
	acceleration = configured_acceleration
	drag = configured_drag
	maximum_speed = configured_maximum_speed
	return true


func set_input_source(source: InteractiveActivityInputSource) -> void:
	input_source = source


func set_movement_enabled(enabled: bool) -> void:
	movement_enabled = enabled


func add_external_force(force: Vector2) -> void:
	external_force += force


func set_external_force(force: Vector2) -> void:
	external_force = force


func reset_orb(target_position: Vector2) -> void:
	position = target_position
	velocity = Vector2.ZERO


func set_movement_bounds(bounds: Rect2) -> void:
	_movement_bounds = bounds.abs()
	_has_movement_bounds = _movement_bounds.size.x > 0.0 and _movement_bounds.size.y > 0.0
	if _has_movement_bounds:
		_apply_movement_bounds()


func clear_movement_bounds() -> void:
	_has_movement_bounds = false
	_movement_bounds = Rect2()


func get_orb_position() -> Vector2:
	return position


func get_orb_velocity() -> Vector2:
	return velocity


func get_orb_speed() -> float:
	return velocity.length()


func get_normalized_distance_from(point: Vector2, radius: float) -> float:
	if radius <= 0.0:
		return 0.0
	return position.distance_to(point) / radius


func _physics_process(delta: float) -> void:
	if not movement_enabled:
		return
	var safe_delta := maxf(delta, 0.0)
	var input_direction := Vector2.ZERO
	if input_source != null:
		input_direction = input_source.get_movement_vector()
	velocity += input_direction * acceleration * safe_delta
	velocity += external_force * safe_delta
	velocity = velocity.move_toward(Vector2.ZERO, drag * safe_delta)
	velocity = velocity.limit_length(maximum_speed)
	move_and_slide()
	if _has_movement_bounds:
		_apply_movement_bounds()
	orb_moved.emit(position, velocity)


func _apply_movement_bounds() -> void:
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
