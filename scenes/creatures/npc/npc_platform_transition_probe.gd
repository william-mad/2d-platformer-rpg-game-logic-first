class_name NpcPlatformTransitionProbe
extends RefCounted

var npc: CharacterBody2D
var body_shape: Shape2D
var shape_offset: Vector2 = Vector2(0.0, -32.0)
var body_half_size: Vector2 = Vector2(24.0, 32.0)
var collision_mask: int = 1
var floor_probe_depth: float = 96.0
var near_foot_distance: float = 12.0
var far_floor_distance: float = 96.0
var obstacle_probe_distance: float = 34.0
var upward_clearance_distance: float = 90.0
var landing_search_above: float = 150.0
var landing_search_below: float = 240.0
var landing_margin: float = 10.0
var maximum_supported_floor_difference: float = 18.0
var arc_samples: int = 10


func configure(character: CharacterBody2D, mask: int) -> bool:
	npc = character
	collision_mask = mask
	if npc == null:
		return false
	var collision_shape := npc.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision_shape == null or collision_shape.shape == null:
		return false
	body_shape = collision_shape.shape
	shape_offset = collision_shape.position
	body_half_size = _get_shape_half_size(body_shape)
	return true


func inspect_local(direction: float) -> Dictionary:
	if npc == null or body_shape == null or is_zero_approx(direction):
		return {}
	var facing := signf(direction)
	var feet := npc.global_position
	var leading_x := feet.x + facing * (body_half_size.x + near_foot_distance)
	var far_x := feet.x + facing * (body_half_size.x + far_floor_distance)
	var obstacle_end_x := feet.x + facing * (body_half_size.x + obstacle_probe_distance)
	var near_floor := _ray(Vector2(leading_x, feet.y - 8.0), Vector2(leading_x, feet.y + floor_probe_depth))
	var far_floor := _ray(Vector2(far_x, feet.y - 8.0), Vector2(far_x, feet.y + floor_probe_depth))
	var feet_obstacle := _ray(Vector2(feet.x, feet.y - 8.0), Vector2(obstacle_end_x, feet.y - 8.0))
	var torso_obstacle := _ray(Vector2(feet.x, feet.y - body_half_size.y), Vector2(obstacle_end_x, feet.y - body_half_size.y))
	var head_y := feet.y - body_half_size.y * 1.8
	var head_obstacle := _ray(Vector2(feet.x, head_y), Vector2(obstacle_end_x, head_y))
	# Body motion honors one-way platforms, unlike a raw upward ray/shape query.
	# This lets Mom pass upward through a one-way landing while still detecting a
	# genuinely solid ceiling.
	var ceiling_blocked := _body_motion_collides(
		feet,
		feet + Vector2(0.0, -upward_clearance_distance)
	)
	var has_near_floor := not near_floor.is_empty()
	var has_far_floor := not far_floor.is_empty()
	var feet_blocked := not feet_obstacle.is_empty()
	var torso_blocked := not torso_obstacle.is_empty()
	var head_blocked := not head_obstacle.is_empty()
	return {
		"normal_ground": has_near_floor and has_far_floor and not feet_blocked and not torso_blocked,
		"chasm": not has_near_floor,
		"approaching_ledge": has_near_floor and not has_far_floor,
		"candidate_floor_across_gap": not has_near_floor and has_far_floor,
		"short_obstacle": feet_blocked and not torso_blocked and not head_blocked,
		"raised_platform": feet_blocked and torso_blocked and not head_blocked,
		"tall_wall": feet_blocked and torso_blocked and head_blocked,
		"ceiling_blocked": ceiling_blocked,
		"near_floor": near_floor,
		"far_floor": far_floor,
	}


func solve_transition(
	target_position: Vector2,
	minimum_jump_velocity: float,
	preferred_jump_velocity: float,
	maximum_jump_velocity: float,
	maximum_horizontal_speed: float,
	maximum_route_distance: float,
	gravity_strength: float,
	minimum_raised_horizontal_speed: float = 0.0
) -> Dictionary:
	return _solve_transition_from(
		npc.global_position if npc != null else Vector2.ZERO,
		target_position,
		minimum_jump_velocity,
		preferred_jump_velocity,
		maximum_jump_velocity,
		maximum_horizontal_speed,
		maximum_route_distance,
		gravity_strength,
		minimum_raised_horizontal_speed
	)


func find_nearby_same_height_spot(
	preferred_direction: float,
	search_step: float,
	maximum_search_distance: float
) -> Dictionary:
	if npc == null or body_shape == null:
		return {}
	var direction := signf(preferred_direction)
	if is_zero_approx(direction):
		direction = 1.0
	var step := maxf(search_step, body_half_size.x * 2.0)
	var offsets := [direction * step, -direction * step, direction * minf(step * 2.0, maximum_search_distance)]
	for offset_value in offsets:
		var horizontal_offset := float(offset_value)
		if absf(horizontal_offset) > maximum_search_distance:
			continue
		var proposed := Vector2(npc.global_position.x + horizontal_offset, npc.global_position.y)
		var candidate_landing := _find_landing(proposed)
		if candidate_landing.is_empty():
			continue
		var candidate_position: Vector2 = candidate_landing.get("position", proposed)
		if not _walk_path_is_clear(npc.global_position, candidate_position):
			continue
		return {"valid": true, "position": candidate_position}
	return {}


func build_completed_traversal_fallback(
	target_position: Vector2,
	jump_velocity: float,
	maximum_horizontal_speed: float,
	gravity_strength: float,
	minimum_raised_horizontal_speed: float = 0.0
) -> Dictionary:
	# The player has already completed this exact traversal, so this fallback
	# relaxes only the virtual mid-arc sweep. Landing support, body space, flight
	# time, and horizontal capability remain mandatory; real movement collisions
	# can still abort the committed jump.
	if npc == null or body_shape == null:
		return {}
	var landing := _find_landing(target_position)
	if landing.is_empty():
		return {}
	var landing_position: Vector2 = landing.get("position", target_position)
	var safe_jump_velocity := maxf(jump_velocity, 1.0)
	var flight_time := _get_flight_time(
		safe_jump_velocity,
		landing_position.y - npc.global_position.y,
		gravity_strength
	)
	if flight_time <= 0.0:
		return {}
	var horizontal_delta := landing_position.x - npc.global_position.x
	var horizontal_velocity := horizontal_delta / flight_time
	var landing_offset_y := landing_position.y - npc.global_position.y
	if (
		landing_offset_y < -20.0
		and absf(horizontal_delta) > 1.0
		and absf(horizontal_velocity) < minimum_raised_horizontal_speed
	):
		var fast_speed := minf(minimum_raised_horizontal_speed, maximum_horizontal_speed)
		var fast_time := absf(horizontal_delta) / maxf(fast_speed, 0.001)
		var required_jump_velocity := (
			0.5 * gravity_strength * fast_time * fast_time - landing_offset_y
		) / maxf(fast_time, 0.001)
		if required_jump_velocity >= 1.0 and required_jump_velocity <= jump_velocity * 1.8:
			safe_jump_velocity = required_jump_velocity
			flight_time = fast_time
			horizontal_velocity = signf(horizontal_delta) * fast_speed
	if absf(horizontal_velocity) > maximum_horizontal_speed:
		return {}
	# A short initial motion catches an actual low ceiling while correctly
	# allowing upward passage through one-way platforms.
	var initial_velocity := Vector2(horizontal_velocity, -safe_jump_velocity)
	var initial_time := minf(0.12, flight_time * 0.2)
	var initial_position := (
		npc.global_position
		+ initial_velocity * initial_time
		+ Vector2(0.0, 0.5 * gravity_strength * initial_time * initial_time)
	)
	if _body_motion_collides(npc.global_position, initial_position):
		return {}
	return {
		"valid": true,
		"takeoff_position": npc.global_position,
		"landing_position": landing_position,
		"velocity": initial_velocity,
		"horizontal_direction": signf(horizontal_velocity),
		"horizontal_speed": absf(horizontal_velocity),
		"jump_velocity": safe_jump_velocity,
		"flight_time": flight_time,
		"candidate": -1,
		"relaxed_completed_traversal": true,
	}


func _solve_transition_from(
	start_position: Vector2,
	target_position: Vector2,
	minimum_jump_velocity: float,
	preferred_jump_velocity: float,
	maximum_jump_velocity: float,
	maximum_horizontal_speed: float,
	maximum_route_distance: float,
	gravity_strength: float,
	minimum_raised_horizontal_speed: float = 0.0
) -> Dictionary:
	if npc == null or body_shape == null:
		return {}
	var offset := target_position - start_position
	var direction := signf(offset.x)
	if is_zero_approx(direction):
		direction = 1.0
	var smallest_velocity := clampf(
		preferred_jump_velocity,
		minimum_jump_velocity,
		maximum_jump_velocity
	)
	var velocity_candidates := [
		smallest_velocity,
		lerpf(smallest_velocity, maximum_jump_velocity, 0.35),
		maxf(maximum_jump_velocity, smallest_velocity),
	]
	var distance_fractions := [0.4, 0.7, 1.0]
	var target_is_raised := target_position.y < start_position.y - 20.0
	for index in 3:
		var proposed_distance := minf(absf(offset.x), maximum_route_distance)
		if not target_is_raised:
			proposed_distance = minf(
				absf(offset.x),
				maximum_route_distance * float(distance_fractions[index])
			)
		if proposed_distance <= body_half_size.x * 2.0:
			proposed_distance = minf(absf(offset.x), maximum_route_distance)
		var proposed_x := start_position.x + direction * proposed_distance
		var landing := _find_landing(Vector2(proposed_x, target_position.y))
		if landing.is_empty():
			continue
		var landing_position: Vector2 = landing.get("position", target_position)
		if landing_position.distance_to(target_position) >= start_position.distance_to(target_position):
			continue
		var jump_velocity := float(velocity_candidates[index])
		var flight_time := _get_flight_time(
			jump_velocity,
			landing_position.y - start_position.y,
			gravity_strength
		)
		if flight_time <= 0.0:
			continue
		var horizontal_velocity := (landing_position.x - start_position.x) / flight_time
		var horizontal_delta := landing_position.x - start_position.x
		var landing_offset_y := landing_position.y - start_position.y
		if (
			target_is_raised
			and absf(horizontal_delta) > 1.0
			and absf(horizontal_velocity) < minimum_raised_horizontal_speed
		):
			var fast_speed := minf(minimum_raised_horizontal_speed, maximum_horizontal_speed)
			var fast_time := absf(horizontal_delta) / maxf(fast_speed, 0.001)
			var required_jump_velocity := (
				0.5 * gravity_strength * fast_time * fast_time - landing_offset_y
			) / maxf(fast_time, 0.001)
			if required_jump_velocity >= minimum_jump_velocity and required_jump_velocity <= maximum_jump_velocity:
				jump_velocity = required_jump_velocity
				flight_time = fast_time
				horizontal_velocity = signf(horizontal_delta) * fast_speed
		if absf(horizontal_velocity) > maximum_horizontal_speed:
			continue
		if not _arc_is_clear(
			start_position,
			Vector2(horizontal_velocity, -jump_velocity),
			gravity_strength,
			flight_time
		):
			continue
		return {
			"valid": true,
			"takeoff_position": start_position,
			"landing_position": landing_position,
			"velocity": Vector2(horizontal_velocity, -jump_velocity),
			"horizontal_direction": signf(horizontal_velocity),
			"horizontal_speed": absf(horizontal_velocity),
			"jump_velocity": jump_velocity,
			"flight_time": flight_time,
			"candidate": index,
		}
	return {}


func _walk_path_is_clear(start: Vector2, destination: Vector2) -> bool:
	if absf(destination.y - start.y) > maximum_supported_floor_difference * 2.0:
		return false
	var sample_count := 4
	for sample_index in range(sample_count + 1):
		var weight := float(sample_index) / float(sample_count)
		var sample_x := lerpf(start.x, destination.x, weight)
		var expected_y := lerpf(start.y, destination.y, weight)
		var floor_hit := _ray(
			Vector2(sample_x, expected_y - 16.0),
			Vector2(sample_x, expected_y + floor_probe_depth)
		)
		if floor_hit.is_empty():
			return false
		var floor_position: Vector2 = floor_hit.get("position", Vector2(sample_x, expected_y))
		if absf(floor_position.y - expected_y) > maximum_supported_floor_difference:
			return false
		if not _body_space_is_empty(floor_position - Vector2(0.0, 3.0)):
			return false
	return true


func _arc_is_clear(start: Vector2, velocity: Vector2, gravity_strength: float, flight_time: float) -> bool:
	var previous_position := start
	var sample_count := clampi(arc_samples, 8, 12)
	# The final sample is validated as a supported landing, so route casting stops
	# one sample early to avoid treating the intended floor contact as an obstacle.
	for sample_index in range(1, sample_count):
		var time := flight_time * (float(sample_index) / float(sample_count))
		var position := start + velocity * time + Vector2(0.0, 0.5 * gravity_strength * time * time)
		if not _shape_motion_is_clear(previous_position, position):
			return false
		previous_position = position
	var prelanding_time := flight_time * 0.96
	var prelanding_position := (
		start
		+ velocity * prelanding_time
		+ Vector2(0.0, 0.5 * gravity_strength * prelanding_time * prelanding_time)
	)
	if not _shape_motion_is_clear(previous_position, prelanding_position):
		return false
	return true


func _shape_motion_is_clear(from_feet: Vector2, to_feet: Vector2) -> bool:
	return not _body_motion_collides(from_feet, to_feet)


func _body_motion_collides(from_feet: Vector2, to_feet: Vector2) -> bool:
	if npc == null:
		return true
	var parameters := PhysicsTestMotionParameters2D.new()
	# The RID already contains Mom's collision-shape offset, so this transform is
	# the CharacterBody2D origin/feet position rather than the shape center.
	parameters.from = Transform2D(npc.global_rotation, from_feet)
	parameters.motion = to_feet - from_feet
	parameters.margin = 0.06
	parameters.recovery_as_collision = false
	var result := PhysicsTestMotionResult2D.new()
	return PhysicsServer2D.body_test_motion(npc.get_rid(), parameters, result)


func _find_landing(proposed_position: Vector2) -> Dictionary:
	var center_floor := _ray(
		Vector2(proposed_position.x, proposed_position.y - landing_search_above),
		Vector2(proposed_position.x, proposed_position.y + landing_search_below)
	)
	if center_floor.is_empty():
		return {}
	var center_position: Vector2 = center_floor.get("position", proposed_position)
	# Probe just inside the body's footprint. Requiring support outside the body
	# rejected platforms that were wide enough for Mom to stand on.
	var support_offset := maxf(
		body_half_size.x - maxf(landing_margin, 0.0),
		body_half_size.x * 0.7
	)
	var left_floor := _ray(
		center_position + Vector2(-support_offset, -16.0),
		center_position + Vector2(-support_offset, 32.0)
	)
	var right_floor := _ray(
		center_position + Vector2(support_offset, -16.0),
		center_position + Vector2(support_offset, 32.0)
	)
	if left_floor.is_empty() or right_floor.is_empty():
		return {}
	var left_position: Vector2 = left_floor.get("position", center_position)
	var right_position: Vector2 = right_floor.get("position", center_position)
	if absf(left_position.y - right_position.y) > maximum_supported_floor_difference:
		return {}
	if not _body_space_is_empty(center_position - Vector2(0.0, 3.0)):
		return {}
	return {"position": center_position, "left": left_position, "right": right_position}


func _body_space_is_empty(feet_position: Vector2) -> bool:
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = body_shape
	query.transform = Transform2D(0.0, feet_position + shape_offset)
	query.collision_mask = collision_mask
	query.exclude = [npc.get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return npc.get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty()


func _get_flight_time(jump_velocity: float, landing_offset_y: float, gravity_strength: float) -> float:
	var gravity_value := maxf(gravity_strength, 0.001)
	var discriminant := jump_velocity * jump_velocity + 2.0 * gravity_value * landing_offset_y
	if discriminant < 0.0:
		return -1.0
	return (jump_velocity + sqrt(discriminant)) / gravity_value


func _ray(from: Vector2, to: Vector2) -> Dictionary:
	var query := PhysicsRayQueryParameters2D.create(from, to, collision_mask, [npc.get_rid()])
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return npc.get_world_2d().direct_space_state.intersect_ray(query)


func _get_shape_half_size(shape: Shape2D) -> Vector2:
	if shape is RectangleShape2D:
		return (shape as RectangleShape2D).size * 0.5
	if shape is CapsuleShape2D:
		var capsule := shape as CapsuleShape2D
		return Vector2(capsule.radius, capsule.height * 0.5)
	if shape is CircleShape2D:
		var radius := (shape as CircleShape2D).radius
		return Vector2(radius, radius)
	return Vector2(24.0, 32.0)
