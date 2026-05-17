extends Node2D
class_name Rope

@export_category("Rope Targets")
@export var start_node: Node2D
@export var end_node: Node2D

@export_category("Rope Length")
@export var max_length: float = 300.0
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
@export var rope_width: float = 4.0

@export_category("State")
@export var active: bool = false

@onready var line: Line2D = $Line2D


func _ready() -> void:
	line.width = rope_width
	line.visible = active

	# Three points lets us create a slight sag:
	# start -> middle -> end
	line.clear_points()
	line.add_point(Vector2.ZERO)
	line.add_point(Vector2.ZERO)
	line.add_point(Vector2.ZERO)


func _physics_process(delta: float) -> void:
	if not active:
		line.visible = false
		return

	if start_node == null or end_node == null:
		line.visible = false
		return

	line.visible = true

	_apply_rope_mechanics(delta)
	_update_rope_visual()


func attach(new_start: Node2D, new_end: Node2D) -> void:
	start_node = new_start
	end_node = new_end
	active = true
	line.visible = true


func detach() -> void:
	active = false
	line.visible = false
	start_node = null
	end_node = null


func _apply_rope_mechanics(delta: float) -> void:
	var start_pos := start_node.global_position
	var end_pos := end_node.global_position

	var offset := end_pos - start_pos
	var distance := offset.length()

	if distance <= 0.01:
		return

	var direction_from_start_to_end := offset.normalized()
	var direction_from_end_to_start := -direction_from_start_to_end

	var tug_start_distance := max_length * tug_start_ratio

	# No tug if the rope is loose.
	if distance < tug_start_distance:
		return

	# 0.0 at tug_start_distance, 1.0 at max_length.
	var stretch_ratio := inverse_lerp(tug_start_distance, max_length, distance)
	stretch_ratio = clampf(stretch_ratio, 0.0, 1.0)

	var tug_speed := tug_strength * stretch_ratio * delta
	tug_speed = min(tug_speed, max_tug_speed * delta)

	# Pull the non-player/end object toward the player/start object.
	_apply_pull_to_body(end_node, direction_from_end_to_start, tug_speed, false)

	# Optional: also pull the player a little toward the attached object.
	if pull_player_too:
		_apply_pull_to_body(
			start_node,
			direction_from_start_to_end,
			tug_speed * player_pull_multiplier,
			true
		)

	# Hard limit: if the end object gets beyond max length,
	# snap it back to the rope's maximum distance.
	if hard_limit_enabled and distance > max_length:
		var limited_position := start_pos + direction_from_start_to_end * max_length
		end_node.global_position = limited_position


func _apply_pull_to_body(body: Node2D, direction: Vector2, amount: float, _is_start_body: bool) -> void:
	if body is CharacterBody2D:
		var character := body as CharacterBody2D

		# We add to velocity, but the character's own script should call move_and_slide().
		character.velocity += direction * amount * 60.0

		# Avoid insane rope speeds.
		if character.velocity.length() > max_tug_speed:
			character.velocity = character.velocity.normalized() * max_tug_speed

	elif body is RigidBody2D:
		var rigid := body as RigidBody2D

		# RigidBody2D should be moved through physics forces/impulses.
		rigid.apply_central_impulse(direction * amount * 20.0)

	else:
		# Fallback for Node2D, Area2D, etc.
		# This does not use physics collision; it just moves the node.
		body.global_position += direction * amount


func _update_rope_visual() -> void:
	var start_pos := start_node.global_position
	var end_pos := end_node.global_position
	var mid_pos := (start_pos + end_pos) * 0.5

	if use_sag:
		var distance := start_pos.distance_to(end_pos)
		var sag_ratio := clampf(distance / max_length, 0.0, 1.0)

		# More sag when loose, less sag when stretched.
		var sag := sag_amount * (1.0 - sag_ratio)

		mid_pos += Vector2.DOWN * sag

	# Line2D points are local to the Line2D node.
	# to_local() converts global positions into the rope's local space.
	line.set_point_position(0, line.to_local(start_pos))
	line.set_point_position(1, line.to_local(mid_pos))
	line.set_point_position(2, line.to_local(end_pos))
