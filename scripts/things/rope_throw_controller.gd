class_name RopeThrowController
extends RefCounted

enum State {
	READY,
	TAP_PENDING,
	SPINNING,
	FLYING,
}

var _rope
var _state: State = State.READY
var _end_id: StringName = &""
var _throw_allowed: bool = false
var _facing: float = 1.0
var _charge_elapsed: float = 0.0
var _charge_started_msec: int = 0
var _spin_angle: float = 0.0
var _flight_points: PackedVector2Array = PackedVector2Array()
var _flight_elapsed: float = 0.0
var _flight_duration: float = 0.0
var _hit_body: Node2D
var _hit_position: Vector2 = Vector2.ZERO


func setup(rope) -> void:
	_rope = rope


func advance(delta: float) -> void:
	if is_charging():
		_advance_charge(delta)
	elif is_in_flight():
		_advance_flight(delta)


func begin(
	end_id: StringName,
	facing_direction: float,
	allow_charged_throw: bool
) -> bool:
	if _rope == null or has_pending_throw():
		return false

	_state = State.TAP_PENDING
	_end_id = end_id
	_throw_allowed = allow_charged_throw
	_facing = -1.0 if facing_direction < 0.0 else 1.0
	_charge_elapsed = 0.0
	_charge_started_msec = Time.get_ticks_msec()
	_spin_angle = 0.0
	_clear_flight()
	_hide_visuals()
	return true


func set_facing(facing_direction: float) -> void:
	if not is_charging() or is_zero_approx(facing_direction):
		return
	_facing = -1.0 if facing_direction < 0.0 else 1.0


func release() -> bool:
	if not is_charging() or should_quick_attach():
		return false

	_charge_elapsed = get_hold_seconds()
	var path_result := _build_path(get_charge_ratio(), true)
	var points: PackedVector2Array = path_result.get(
		"points",
		PackedVector2Array()
	)
	if points.size() < 2:
		cancel()
		return false

	_state = State.FLYING
	_flight_points = points
	_flight_elapsed = 0.0
	_flight_duration = maxf(
		float(path_result.get(
			"duration",
			float(_rope.throw_flight_seconds)
		))
		/ maxf(float(_rope.throw_visual_speed_scale), 0.01),
		0.05
	)
	_hit_body = path_result.get("hit_body") as Node2D
	_hit_position = path_result.get(
		"hit_position",
		points[points.size() - 1]
	)
	if _rope.throw_preview != null:
		_rope.throw_preview.visible = false
		_rope.throw_preview.clear_points()
	if _rope.line != null:
		_rope.line.visible = true
	if _rope.throw_end != null:
		_rope.throw_end.visible = true
	_set_throw_end_world_position(points[0])
	_set_line_world_points(PackedVector2Array([
		_rope.get_throw_origin(),
		points[0],
	]))
	return true


func cancel() -> void:
	if not has_pending_throw():
		return
	_state = State.READY
	_end_id = &""
	_throw_allowed = false
	_charge_elapsed = 0.0
	_charge_started_msec = 0
	_clear_flight()
	_hide_visuals()


func has_pending_throw() -> bool:
	return _state != State.READY


func is_charging() -> bool:
	return _state == State.TAP_PENDING or _state == State.SPINNING


func is_spinning() -> bool:
	return _state == State.SPINNING


func is_in_flight() -> bool:
	return _state == State.FLYING


func get_pending_end() -> StringName:
	return _end_id


func get_hold_seconds() -> float:
	if not is_charging():
		return _charge_elapsed
	var wall_clock_seconds := (
		float(Time.get_ticks_msec() - _charge_started_msec) / 1000.0
	)
	return maxf(_charge_elapsed, wall_clock_seconds)


func should_quick_attach() -> bool:
	return (
		not _throw_allowed
		or get_hold_seconds() < maxf(float(_rope.quick_attach_seconds), 0.0)
	)


func get_charge_ratio() -> float:
	var charge_start := maxf(float(_rope.quick_attach_seconds), 0.0)
	var charge_end := maxf(
		float(_rope.full_charge_seconds),
		charge_start + 0.001
	)
	return clampf(
		(get_hold_seconds() - charge_start) / (charge_end - charge_start),
		0.0,
		1.0
	)


func _advance_charge(delta: float) -> void:
	_charge_elapsed = minf(
		_charge_elapsed + maxf(delta, 0.0),
		maxf(
			float(_rope.full_charge_seconds),
			float(_rope.quick_attach_seconds)
		)
	)
	set_facing(_facing)
	if (
		not _throw_allowed
		or get_hold_seconds() < maxf(float(_rope.quick_attach_seconds), 0.0)
	):
		return

	_state = State.SPINNING
	_spin_angle = fposmod(
		_spin_angle + maxf(float(_rope.spin_angular_speed), 0.0) * delta,
		TAU
	)
	var charge_ratio := get_charge_ratio()
	var path_result := _build_path(charge_ratio, true)
	var preview_points: PackedVector2Array = path_result.get(
		"points",
		PackedVector2Array()
	)
	_set_preview_world_points(preview_points)

	var origin: Vector2 = _rope.get_throw_origin()
	var spin_radius := lerpf(
		maxf(float(_rope.spin_minimum_radius), 0.0),
		maxf(
			float(_rope.spin_maximum_radius),
			float(_rope.spin_minimum_radius)
		),
		smoothstep(0.0, 1.0, charge_ratio)
	)
	var spin_offset := Vector2(
		cos(_spin_angle) * _facing,
		sin(_spin_angle)
	) * spin_radius
	var spinning_end_position := origin + spin_offset
	_set_throw_end_world_position(spinning_end_position)
	_set_line_world_points(PackedVector2Array([
		origin,
		spinning_end_position,
	]))
	if _rope.line != null:
		_rope.line.visible = true
	if _rope.throw_end != null:
		_rope.throw_end.visible = true


func _advance_flight(delta: float) -> void:
	if _flight_points.size() < 2:
		cancel()
		return

	_flight_elapsed += maxf(delta, 0.0)
	var progress := clampf(
		_flight_elapsed / maxf(_flight_duration, 0.001),
		0.0,
		1.0
	)
	var scaled_index := progress * float(_flight_points.size() - 1)
	var point_index := mini(
		int(floor(scaled_index)),
		_flight_points.size() - 2
	)
	var segment_progress := scaled_index - float(point_index)
	var end_position := _flight_points[point_index].lerp(
		_flight_points[point_index + 1],
		segment_progress
	)
	_set_throw_end_world_position(end_position)
	_set_line_world_points(PackedVector2Array([
		_rope.get_throw_origin(),
		end_position,
	]))

	if progress >= 1.0:
		_complete_flight()


func _complete_flight() -> void:
	var completed_end := _end_id
	var hit_body := _hit_body
	var hit_position := _hit_position
	_state = State.READY
	_end_id = &""
	_throw_allowed = false
	_charge_elapsed = 0.0
	_charge_started_msec = 0
	_clear_flight()
	_hide_visuals()

	if hit_body == null or not is_instance_valid(hit_body):
		_rope.refresh_processing()
		return
	_rope.complete_thrown_end(
		completed_end,
		hit_body,
		hit_position
	)


func _build_path(
	charge_ratio: float,
	check_collision: bool
) -> Dictionary:
	var origin: Vector2 = _rope.get_throw_origin()
	var eased_charge := smoothstep(
		0.0,
		1.0,
		clampf(charge_ratio, 0.0, 1.0)
	)
	var speed := lerpf(
		maxf(float(_rope.minimum_throw_speed), 0.0),
		maxf(
			float(_rope.maximum_throw_speed),
			float(_rope.minimum_throw_speed)
		),
		eased_charge
	)
	var points := sample_ballistic_throw_arc(
		origin,
		_facing,
		speed,
		float(_rope.throw_angle_degrees),
		float(_rope.throw_gravity),
		float(_rope.throw_flight_seconds),
		float(_rope.max_length),
		int(_rope.throw_preview_points)
	)
	var result := {
		"points": points,
		"duration": maxf(float(_rope.throw_flight_seconds), 0.05),
		"hit_body": null,
		"hit_position": (
			points[points.size() - 1] if not points.is_empty() else origin
		),
	}
	if (
		not check_collision
		or points.size() < 2
		or not _rope.is_inside_tree()
	):
		return result

	var space_state: PhysicsDirectSpaceState2D = (
		_rope.get_world_2d().direct_space_state
	)
	if space_state == null:
		return result

	var collision_mask := (
		int(_rope.terrain_collision_mask)
		if _end_id == _rope.END_X
		else (
			int(_rope.attachable_collision_mask)
			| int(_rope.terrain_collision_mask)
		)
	)
	var excluded_rids: Array[RID] = _rope.get_throw_excluded_rids()

	for index in range(1, points.size()):
		while true:
			var query := PhysicsRayQueryParameters2D.create(
				points[index - 1],
				points[index],
				collision_mask,
				excluded_rids
			)
			query.collide_with_areas = false
			query.collide_with_bodies = true
			var hit: Dictionary = space_state.intersect_ray(query)
			if hit.is_empty():
				break

			var hit_body := hit.get("collider") as Node2D
			if hit_body == null or not is_instance_valid(hit_body):
				break
			if not _rope.is_valid_throw_target(_end_id, hit_body):
				if _end_id == _rope.END_S:
					var blocked_position: Vector2 = hit.get(
						"position",
						points[index]
					)
					points.resize(index)
					points.append(blocked_position)
					result["points"] = points
					result["duration"] = (
						maxf(float(_rope.throw_flight_seconds), 0.05)
						* float(index)
						/ float(maxi(
							int(_rope.throw_preview_points) - 1,
							1
						))
					)
					result["hit_position"] = blocked_position
					return result
				if hit_body is CollisionObject2D:
					excluded_rids.append(
						(hit_body as CollisionObject2D).get_rid()
					)
					continue
				break

			var hit_position: Vector2 = hit.get("position", points[index])
			if _end_id == _rope.END_S:
				hit_position = _rope.get_attachment_world_position(hit_body)
			points.resize(index)
			points.append(hit_position)
			result["points"] = points
			result["duration"] = (
				maxf(float(_rope.throw_flight_seconds), 0.05)
				* float(index)
				/ float(maxi(int(_rope.throw_preview_points) - 1, 1))
			)
			result["hit_body"] = hit_body
			result["hit_position"] = hit_position
			return result

	return result


static func sample_ballistic_throw_arc(
	origin: Vector2,
	facing_direction: float,
	speed: float,
	angle_degrees: float,
	gravity: float,
	flight_seconds: float,
	maximum_reach: float,
	point_count: int
) -> PackedVector2Array:
	var points := PackedVector2Array()
	var samples := maxi(point_count, 2)
	var facing := -1.0 if facing_direction < 0.0 else 1.0
	var angle := deg_to_rad(clampf(angle_degrees, 0.0, 89.0))
	var launch_velocity := Vector2(
		cos(angle) * facing,
		-sin(angle)
	) * maxf(speed, 0.0)
	var duration := maxf(flight_seconds, 0.001)
	var reach := maxf(maximum_reach, 1.0)
	points.append(origin)

	for index in range(1, samples):
		var time := duration * float(index) / float(samples - 1)
		var point := (
			origin
			+ launch_velocity * time
			+ Vector2.DOWN * 0.5 * maxf(gravity, 0.0) * time * time
		)
		var offset := point - origin
		if offset.length() >= reach:
			points.append(origin + offset.normalized() * reach)
			break
		points.append(point)

	return points


func _set_preview_world_points(points: PackedVector2Array) -> void:
	if _rope.throw_preview == null:
		return
	_rope.throw_preview.clear_points()
	for point in points:
		_rope.throw_preview.add_point(_rope.throw_preview.to_local(point))
	_rope.throw_preview.visible = points.size() >= 2


func _set_line_world_points(points: PackedVector2Array) -> void:
	if _rope.line == null:
		return
	_rope.line.clear_points()
	for point in points:
		_rope.line.add_point(_rope.line.to_local(point))


func _set_throw_end_world_position(world_position: Vector2) -> void:
	if _rope.throw_end != null:
		_rope.throw_end.global_position = world_position


func _hide_visuals() -> void:
	if _rope == null:
		return
	if _rope.throw_preview != null:
		_rope.throw_preview.visible = false
		_rope.throw_preview.clear_points()
	if _rope.throw_end != null:
		_rope.throw_end.visible = false
	if _rope.line != null and not bool(_rope.active):
		_rope.line.visible = false
		_rope.line.clear_points()


func _clear_flight() -> void:
	_flight_points = PackedVector2Array()
	_flight_elapsed = 0.0
	_flight_duration = 0.0
	_hit_body = null
	_hit_position = Vector2.ZERO
