extends Node2D
class_name Rope

@export_category("Rope Targets")
@export var start_body: Node2D
@export var end_body: Node2D
@export var start_visual_point: Node2D
@export var end_visual_point: Node2D

@export_category("Rope Feel")
@export var max_length: float = 200.0
@export var pull_strength: float = 1800.0
@export var max_pull_speed: float = 500.0
@export var hard_limit_slack: float = 4.0

@export_category("Visuals")
@export var use_sag: bool = true
@export var sag_amount: float = 35.0
@export var rope_width: float = 1.0
@export var rope_points: int = 8

@export_category("State")
@export var active: bool = false

@onready var line: Line2D = $Line2D


func _ready() -> void:
	line.width = rope_width
	line.visible = active
	set_physics_process(active)


func _physics_process(delta: float) -> void:
	if not active:
		return

	if start_body == null or end_body == null:
		detach()
		return

	if start_visual_point == null or end_visual_point == null:
		detach()
		return

	line.visible = true

	_apply_rope_pull(delta)
	_update_rope_visual()


func attach(
	new_start_body: Node2D,
	new_end_body: Node2D,
	new_start_visual_point: Node2D = null,
	new_end_visual_point: Node2D = null
) -> void:
	start_body = new_start_body
	end_body = new_end_body

	start_visual_point = new_start_visual_point if new_start_visual_point != null else new_start_body
	end_visual_point = new_end_visual_point if new_end_visual_point != null else new_end_body

	active = true
	line.visible = true
	set_physics_process(true)


func detach() -> void:
	active = false
	line.visible = false
	set_physics_process(false)

	start_body = null
	end_body = null
	start_visual_point = null
	end_visual_point = null


func _apply_rope_pull(delta: float) -> void:
	var start_pos := _get_visual_position(start_visual_point, start_body)
	var end_pos := _get_visual_position(end_visual_point, end_body)
	var end_body_to_visual := end_pos - end_body.global_position

	var offset := end_pos - start_pos
	var distance := offset.length()

	if distance <= 0.01:
		return

	var direction_from_start_to_end := offset.normalized()
	var direction_to_player := -direction_from_start_to_end

	var tug_start_distance := max_length * 0.85

	# Soft tug near the end of the rope.
	if distance > tug_start_distance:
		var pull_ratio := inverse_lerp(tug_start_distance, max_length, distance)
		pull_ratio = clampf(pull_ratio, 0.0, 1.0)

		var target_speed := max_pull_speed * pull_ratio
		_apply_soft_pull(end_body, direction_to_player, target_speed, delta)

	# Hard cap past max length.
	if distance > max_length + hard_limit_slack:
		var capped_end_visual_position := start_pos + direction_from_start_to_end * max_length
		var capped_body_position := capped_end_visual_position - end_body_to_visual
		_clamp_body_to_rope_limit(end_body, capped_body_position, direction_from_start_to_end)


func _apply_pull_to_body(body: Node2D, direction: Vector2, target_speed: float, delta: float) -> void:
	if body is CharacterBody2D:
		var character := body as CharacterBody2D

		var current_rope_speed := character.velocity.dot(direction)
		var desired_rope_speed := target_speed

		var new_rope_speed := move_toward(
			current_rope_speed,
			desired_rope_speed,
			pull_strength * delta
		)

		var speed_change := new_rope_speed - current_rope_speed
		character.velocity += direction * speed_change

	elif body is RigidBody2D:
		_apply_rigid_velocity_pull(body as RigidBody2D, direction, target_speed, delta)

	else:
		body.global_position += direction * target_speed * delta


func _update_rope_visual() -> void:
	var start_pos := _get_visual_position(start_visual_point, start_body)
	var end_pos := _get_visual_position(end_visual_point, end_body)

	var distance := start_pos.distance_to(end_pos)
	var stretch_ratio := clampf(distance / max_length, 0.0, 1.0)

	var sag := 0.0
	if use_sag:
		sag = sag_amount * (1.0 - stretch_ratio)

	line.width = rope_width
	line.clear_points()

	var point_count: int = maxi(rope_points, 2)

	for i in range(point_count):
		var t := float(i) / float(point_count - 1)
		var point := start_pos.lerp(end_pos, t)

		var curve := sin(t * PI)
		point += Vector2.DOWN * sag * curve

		line.add_point(line.to_local(point))


func _get_visual_position(visual_point: Node2D, fallback_body: Node2D) -> Vector2:
	if visual_point != null and is_instance_valid(visual_point):
		return visual_point.global_position

	return fallback_body.global_position


func _clamp_body_to_rope_limit(
	body: Node2D,
	capped_global_position: Vector2,
	away_direction: Vector2
) -> void:
	if body.has_method("clamp_rope_distance"):
		body.call("clamp_rope_distance", capped_global_position, away_direction)
		return

	body.global_position = capped_global_position
	_remove_velocity_away_from_player(body, away_direction)


func _remove_velocity_away_from_player(body: Node2D, away_direction: Vector2) -> void:
	if body is CharacterBody2D:
		var character := body as CharacterBody2D
		var speed_away := character.velocity.dot(away_direction)

		if speed_away > 0.0:
			character.velocity -= away_direction * speed_away

	elif body is RigidBody2D:
		var rigid := body as RigidBody2D
		var speed_away := rigid.linear_velocity.dot(away_direction)

		if speed_away > 0.0:
			rigid.linear_velocity -= away_direction * speed_away


func _apply_soft_pull(body: Node2D, direction: Vector2, target_speed: float, delta: float) -> void:
	if body.has_method("apply_rope_pull_velocity"):
		body.call("apply_rope_pull_velocity", direction, target_speed, delta)
		return

	if body is CharacterBody2D:
		var character := body as CharacterBody2D

		var current_speed := character.velocity.dot(direction)
		var new_speed := move_toward(
			current_speed,
			target_speed,
			pull_strength * delta
		)

		var speed_change := new_speed - current_speed
		character.velocity += direction * speed_change

	elif body is RigidBody2D:
		_apply_rigid_velocity_pull(body as RigidBody2D, direction, target_speed, delta)

	else:
		body.global_position += direction * target_speed * delta


func _apply_rigid_velocity_pull(
	rigid: RigidBody2D,
	direction: Vector2,
	target_speed: float,
	delta: float
) -> void:
	rigid.sleeping = false

	var current_speed := rigid.linear_velocity.dot(direction)
	var new_speed := move_toward(
		current_speed,
		target_speed,
		pull_strength * delta
	)

	var speed_change := new_speed - current_speed
	rigid.linear_velocity += direction * speed_change
