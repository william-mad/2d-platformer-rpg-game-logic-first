extends Node2D
class_name Rope

@export_category("Rope Targets")
@export var start_body: Node2D
@export var end_body: Node2D
@export var start_visual_point: Node2D
@export var end_visual_point: Node2D

@export_category("Rope Length")
@export var max_length: float = 600.0
@export var tug_start_ratio: float = 0.75
@export var hard_limit_enabled: bool = true

@export_category("Tug Feel")
@export var tug_strength: float = 900.0
@export var max_tug_speed: float = 450.0
@export var pull_player_too: bool = false
@export var player_pull_multiplier: float = 0.35

@export_category("Visuals")
@export var use_sag: bool = true
@export var sag_amount: float = 45.0
@export var rope_width: float = 1.0
@export var rope_points: int = 8

@export_category("State")
@export var active: bool = false

@onready var line: Line2D = $Line2D


func _ready() -> void:
	line.width = rope_width
	line.visible = active

	line.clear_points()

	for i in range(rope_points):
		line.add_point(Vector2.ZERO)


func _physics_process(delta: float) -> void:
	if not active:
		line.visible = false
		return

	if start_body == null or end_body == null:
		line.visible = false
		return

	if start_visual_point == null or end_visual_point == null:
		line.visible = false
		return

	line.visible = true

	_apply_rope_mechanics(delta)
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


func detach() -> void:
	active = false
	line.visible = false

	start_body = null
	end_body = null
	start_visual_point = null
	end_visual_point = null


func _apply_rope_mechanics(delta: float) -> void:
	var start_pos := start_body.global_position
	var end_pos := end_body.global_position

	var offset := end_pos - start_pos
	var distance := offset.length()

	if distance <= 0.01:
		return

	var direction_from_start_to_end := offset.normalized()
	var direction_from_end_to_start := -direction_from_start_to_end

	var tug_start_distance := max_length * tug_start_ratio

	if distance < tug_start_distance:
		return

	var stretch_ratio := inverse_lerp(tug_start_distance, max_length, distance)
	stretch_ratio = clampf(stretch_ratio, 0.0, 1.0)

	var tug_speed := tug_strength * stretch_ratio * delta
	tug_speed = min(tug_speed, max_tug_speed * delta)

	_apply_pull_to_body(end_body, direction_from_end_to_start, tug_speed)

	if pull_player_too:
		_apply_pull_to_body(
			start_body,
			direction_from_start_to_end,
			tug_speed * player_pull_multiplier
		)

	if hard_limit_enabled and distance > max_length:
		var limited_position := start_pos + direction_from_start_to_end * max_length
		end_body.global_position = limited_position


func _apply_pull_to_body(body: Node2D, direction: Vector2, amount: float) -> void:
	if body is CharacterBody2D:
		var character := body as CharacterBody2D

		character.velocity += direction * amount * 60.0

		if character.velocity.length() > max_tug_speed:
			character.velocity = character.velocity.normalized() * max_tug_speed

	elif body is RigidBody2D:
		var rigid := body as RigidBody2D
		rigid.apply_central_impulse(direction * amount * 20.0)

	else:
		body.global_position += direction * amount


func _update_rope_visual() -> void:
	var start_pos := start_visual_point.global_position
	var end_pos := end_visual_point.global_position

	var distance := start_pos.distance_to(end_pos)
	var stretch_ratio := clampf(distance / max_length, 0.0, 1.0)

	# More sag when loose, less sag when stretched.
	var sag := 0.0
	if use_sag:
		sag = sag_amount * (1.0 - stretch_ratio)

	line.clear_points()

	for i in range(rope_points):
		var t := float(i) / float(rope_points - 1)

		var point := start_pos.lerp(end_pos, t)

		# Parabola shape:
		# 0 at ends, strongest in the middle.
		var curve := sin(t * PI)

		point += Vector2.DOWN * sag * curve

		line.add_point(line.to_local(point))
