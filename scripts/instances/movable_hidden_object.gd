class_name MovableHiddenObject extends CharacterBody2D

@export var move_with_player_while_hidden: bool = true

@export_category("Movement")
@export var gravity: float = 1500.0
@export var max_hidden_move_speed: float = 90.0
@export var hidden_move_acceleration: float = 650.0
@export var hidden_move_deceleration: float = 900.0
@export var max_fall_speed: float = 700.0

@export_category("Rope")
@export_range(0.01, 1000.0, 0.01) var rope_weight: float = 3.0

@onready var hide_area: Area2D = %HideArea
@onready var rope_attach_point: Marker2D = %RopeAttachPoint
@onready var hidden_player_point: Marker2D = %HiddenPlayerPoint

var hidden_control_active: bool = false
var requested_hidden_velocity_x: float = 0.0


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

	if not is_on_floor():
		velocity.y = minf(velocity.y + gravity * delta, max_fall_speed)
	elif velocity.y > 0.0:
		velocity.y = 0.0

	var velocity_after_gravity := velocity
	velocity.x = move_toward(velocity.x, target_velocity_x, acceleration * delta)
	velocity = Rope.finalize_attached_body_velocity(
		self,
		velocity,
		velocity_after_gravity,
		delta
	)
	move_and_slide()

	hidden_control_active = false


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


func get_hidden_player_position() -> Vector2:
	return hidden_player_point.global_position


func get_rope_attach_point() -> Node2D:
	return rope_attach_point
