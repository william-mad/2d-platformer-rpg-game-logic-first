class_name RopeTensionController
extends RefCounted

const YELLOW_STOP: float = 0.4
const RED_STOP: float = 0.7

var _rope
var _current_tension: float = 0.0


func setup(rope) -> void:
	_rope = rope
	reset()


func update(delta: float) -> bool:
	if (
		_rope == null
		or not _rope.active
		or not _rope._endpoints_are_valid()
	):
		_current_tension = 0.0
		return false

	refresh_measurement(delta)
	if _current_tension > maxf(float(_rope.maximum_tension), 0.05):
		_snap()
		return true
	_rope._update_load_bearing(_current_tension)
	return false


func refresh_measurement(delta: float) -> float:
	if (
		_rope == null
		or not _rope.active
		or not _rope._endpoints_are_valid()
	):
		_current_tension = 0.0
		return _current_tension

	var offset: Vector2 = (
		_rope._get_end_position() - _rope._get_start_position()
	)
	var distance := offset.length()
	if distance <= 0.001:
		_current_tension = 0.0
		return _current_tension

	var direction := offset / distance
	var start_velocity := _read_body_velocity(_rope.start_body)
	var end_velocity := _read_body_velocity(_rope.end_body)
	var actual_outward_speed := maxf(
		(end_velocity - start_velocity).dot(direction),
		0.0
	)
	var intended_start_velocity := _read_recent_requested_velocity(
		_rope.start_body,
		start_velocity
	)
	var intended_end_velocity := _read_recent_requested_velocity(
		_rope.end_body,
		end_velocity
	)
	var intended_outward_speed := maxf(
		(intended_end_velocity - intended_start_velocity).dot(direction),
		0.0
	)
	var projected_distance := (
		distance
		+ maxf(actual_outward_speed, intended_outward_speed)
		* maxf(delta, 0.0)
	)
	_current_tension = (
		maxf(projected_distance - float(_rope.get_rest_length()), 0.0)
		/ maxf(float(_rope.elasticity), 0.1)
	)
	return _current_tension


func reset() -> void:
	_current_tension = 0.0
	if _rope != null and _rope.line != null:
		_rope.line.default_color = _rope.tension_green


func get_current() -> float:
	return _current_tension


func get_ratio() -> float:
	if _rope == null:
		return 0.0
	return clampf(
		_current_tension / maxf(float(_rope.maximum_tension), 0.05),
		0.0,
		1.0
	)


func get_color(tension_ratio: float = -1.0) -> Color:
	if _rope == null:
		return Color.WHITE
	var ratio := (
		get_ratio()
		if tension_ratio < 0.0
		else clampf(tension_ratio, 0.0, 1.0)
	)
	if ratio <= YELLOW_STOP:
		return _rope.tension_green.lerp(
			_rope.tension_yellow,
			smoothstep(0.0, YELLOW_STOP, ratio)
		)
	if ratio <= RED_STOP:
		return _rope.tension_yellow.lerp(
			_rope.tension_red,
			smoothstep(YELLOW_STOP, RED_STOP, ratio)
		)
	return _rope.tension_red.lerp(
		_rope.tension_purple,
		smoothstep(RED_STOP, 1.0, ratio)
	)


func _read_recent_requested_velocity(
	body: Node2D,
	fallback_velocity: Vector2
) -> Vector2:
	if not _node_is_valid(body):
		return fallback_velocity
	var body_id := body.get_instance_id()
	if (
		not _rope._requested_velocities.has(body_id)
		or int(_rope._requested_velocity_frames.get(body_id, -1))
		< Engine.get_physics_frames() - 1
	):
		return fallback_velocity
	var requested_velocity: Vector2 = _rope._requested_velocities.get(
		body_id,
		fallback_velocity
	)
	return requested_velocity


static func _read_body_velocity(body: Node2D) -> Vector2:
	if not _node_is_valid(body):
		return Vector2.ZERO
	if body is CharacterBody2D:
		return (body as CharacterBody2D).velocity
	if body is RigidBody2D:
		return (body as RigidBody2D).linear_velocity
	return Vector2.ZERO


static func _node_is_valid(node) -> bool:
	return (
		node != null
		and is_instance_valid(node)
		and not node.is_queued_for_deletion()
	)


func _snap() -> void:
	if (
		_rope == null
		or not _rope.active
		or not _rope._endpoints_are_valid()
	):
		return
	var midpoint: Vector2 = (
		_rope._get_start_position() + _rope._get_end_position()
	) * 0.5
	var snap_tension := _current_tension
	_rope.detach()
	_show_snap_flash(midpoint)
	_play_snap_sound(midpoint)
	_rope.rope_snapped.emit(midpoint, snap_tension)


func _show_snap_flash(world_midpoint: Vector2) -> void:
	if _rope == null or not _rope.is_inside_tree():
		return
	var flash := Node2D.new()
	flash.name = "RopeSnapFlash"
	flash.top_level = true
	flash.z_index = (_rope.line.z_index + 1) if _rope.line != null else 1
	flash.scale = Vector2.ONE * 0.65
	_rope.add_child(flash)
	flash.global_position = world_midpoint

	var half_size := maxf(float(_rope.snap_flash_size), 2.0)
	for angle in [-PI * 0.25, PI * 0.25]:
		var arm := Line2D.new()
		arm.points = PackedVector2Array([
			Vector2(-half_size, 0.0),
			Vector2(half_size, 0.0),
		])
		arm.width = maxf(float(_rope.rope_width) * 2.0, 2.0)
		arm.default_color = _rope.tension_purple
		arm.rotation = angle
		flash.add_child(arm)

	var duration := maxf(float(_rope.snap_flash_seconds), 0.05)
	var tween := flash.create_tween()
	tween.set_parallel(true)
	tween.tween_property(
		flash,
		"scale",
		Vector2.ONE * 1.8,
		duration
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(
		flash,
		"modulate:a",
		0.0,
		duration
	)
	tween.finished.connect(Callable(flash, "queue_free"), CONNECT_ONE_SHOT)


func _play_snap_sound(world_midpoint: Vector2) -> void:
	if (
		_rope == null
		or _rope.snap_sound == null
		or not _rope.is_inside_tree()
	):
		return
	var audio := AudioStreamPlayer2D.new()
	audio.name = "RopeSnapAudio"
	audio.top_level = true
	audio.stream = _rope.snap_sound
	_rope.add_child(audio)
	audio.global_position = world_midpoint
	audio.finished.connect(Callable(audio, "queue_free"), CONNECT_ONE_SHOT)
	audio.play()
