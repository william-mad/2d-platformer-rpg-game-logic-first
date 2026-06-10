class_name MovableHiddenObject extends CharacterBody2D

@export var move_with_player_while_hidden: bool = true

@export_category("Movement")
@export var gravity: float = 1500.0
@export var max_hidden_move_speed: float = 90.0
@export var hidden_move_acceleration: float = 650.0
@export var hidden_move_deceleration: float = 900.0
@export var rope_pull_acceleration: float = 1200.0
@export var max_rope_pull_speed: float = 260.0
@export var max_fall_speed: float = 700.0

@onready var hide_area: Area2D = %HideArea
@onready var rope_attach_point: Marker2D = %RopeAttachPoint
@onready var hidden_player_point: Marker2D = %HiddenPlayerPoint

var hidden_control_active: bool = false
var requested_hidden_velocity_x: float = 0.0
var rope_pull_active: bool = false
var requested_rope_velocity: Vector2 = Vector2.ZERO


func _ready() -> void:
	floor_snap_length = maxf(floor_snap_length, 4.0)


func _physics_process(delta: float) -> void:
	var target_velocity_x := 0.0
	var acceleration := hidden_move_deceleration

	if hidden_control_active:
		target_velocity_x += clampf(
			requested_hidden_velocity_x,
			-max_hidden_move_speed,
			max_hidden_move_speed
		)
		acceleration = hidden_move_acceleration

	if rope_pull_active:
		var rope_velocity_x := clampf(
			requested_rope_velocity.x,
			-max_rope_pull_speed,
			max_rope_pull_speed
		)

		if absf(rope_velocity_x) > absf(target_velocity_x):
			target_velocity_x = rope_velocity_x

		acceleration = maxf(acceleration, rope_pull_acceleration)

	if not is_on_floor():
		velocity.y = minf(velocity.y + gravity * delta, max_fall_speed)
	elif velocity.y > 0.0:
		velocity.y = 0.0

	velocity.x = move_toward(velocity.x, target_velocity_x, acceleration * delta)
	move_and_slide()

	hidden_control_active = false
	rope_pull_active = false
	requested_rope_velocity = Vector2.ZERO


func contains_player(player: Node2D) -> bool:
	return hide_area.get_overlapping_bodies().has(player)


func should_move_with_player_while_hidden() -> bool:
	return move_with_player_while_hidden


func set_hidden_move_velocity_x(move_velocity_x: float) -> void:
	requested_hidden_velocity_x = move_velocity_x
	hidden_control_active = true


func stop_hidden_control() -> void:
	hidden_control_active = false
	requested_hidden_velocity_x = 0.0
	velocity.x = 0.0


func apply_rope_pull_velocity(direction: Vector2, target_speed: float, _delta: float) -> void:
	requested_rope_velocity = direction * minf(target_speed, max_rope_pull_speed)
	rope_pull_active = true


func clamp_rope_distance(capped_global_position: Vector2, away_direction: Vector2) -> void:
	var correction := capped_global_position - global_position
	if correction.length_squared() > 0.01:
		move_and_collide(correction)

	var speed_away := velocity.dot(away_direction)
	if speed_away > 0.0:
		velocity -= away_direction * speed_away


func get_hidden_player_position() -> Vector2:
	return hidden_player_point.global_position


func get_rope_attach_point() -> Node2D:
	return rope_attach_point
