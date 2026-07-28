extends Node2D
class_name Rope

const ATTACHED_ROPES_META: StringName = &"_attached_rope_constraints"
const RIGID_SOLVED_FRAME_META: StringName = &"_rope_rigid_solved_frame"
const MIN_WEIGHT: float = 0.001
const DEFAULT_BODY_WEIGHT: float = 1.0
const DEFAULT_NPC_WEIGHT: float = 2.0
const NETWORK_SOLVER_ITERATIONS: int = 12
const NETWORK_RELAXATION: float = 0.85

enum ThrowState {
	READY,
	TAP_PENDING,
	SPINNING,
	FLYING,
}

@export_category("Rope Feel")
## Upper bound for the rope's resting length.
@export_range(1.0, 2000.0, 1.0, "suffix:px") var max_length: float = 600.0
## Free length added to the distance between endpoints when the rope attaches.
@export_range(0.0, 300.0, 0.5, "suffix:px") var extra_length: float = 60.0
## Additional elastic stretch allowed after the resting length.
@export_range(0.1, 100.0, 0.5, "suffix:px") var stretch_margin: float = 18.0
## Speed at which elastic stretch settles back toward the resting length.
@export_range(0.0, 1000.0, 1.0, "suffix:px/s") var elastic_return_speed: float = 80.0
@export_range(0.0, 2000.0, 1.0, "suffix:px/s") var overstretch_recovery_speed: float = 240.0
## Rate at which airborne swing momentum settles after horizontal input is released.
@export_range(0.0, 10.0, 0.05, "suffix:1/s") var passive_swing_damping: float = 0.5
## Horizontal air-control force projected onto a taut anchored rope's tangent.
@export_range(0.0, 3000.0, 10.0, "suffix:px/s²") var swing_input_acceleration: float = 900.0
## Input cannot add tangential speed beyond this; gravity may still carry it faster.
@export_range(0.0, 3000.0, 10.0, "suffix:px/s") var swing_input_speed_limit: float = 1100.0

@export_category("Terrain Throw")
## Releases shorter than this keep the original nearest-object attachment.
@export_range(0.05, 0.75, 0.01, "suffix:s") var quick_attach_seconds: float = 0.2
## Time at which the terrain throw reaches full range.
@export_range(0.1, 3.0, 0.05, "suffix:s") var full_charge_seconds: float = 1.0
@export_range(50.0, 2000.0, 10.0, "suffix:px/s") var minimum_throw_speed: float = 260.0
@export_range(50.0, 2500.0, 10.0, "suffix:px/s") var maximum_throw_speed: float = 930.0
@export_range(5.0, 85.0, 1.0, "suffix:deg") var throw_angle_degrees: float = 48.0
@export_range(0.0, 3000.0, 10.0, "suffix:px/s²") var throw_gravity: float = 900.0
@export_range(0.1, 2.0, 0.05, "suffix:s") var throw_flight_seconds: float = 0.9
@export_range(1.0, 5.0, 0.05) var throw_visual_speed_scale: float = 1.35
@export_range(4, 64, 1) var throw_preview_points: int = 28
@export_flags_2d_physics var terrain_collision_mask: int = 1
@export_range(4.0, 100.0, 1.0, "suffix:px") var spin_minimum_radius: float = 20.0
@export_range(4.0, 150.0, 1.0, "suffix:px") var spin_maximum_radius: float = 42.0
@export_range(0.0, 40.0, 0.5, "suffix:rad/s") var spin_angular_speed: float = 14.0

@export_category("Terrain Rope Length")
@export_range(1.0, 1000.0, 1.0, "suffix:px") var minimum_rope_length: float = 56.0
@export_range(0.0, 1000.0, 1.0, "suffix:px/s") var reel_in_speed: float = 75.0
@export_range(0.0, 1000.0, 1.0, "suffix:px/s") var pay_out_speed: float = 220.0

@export_category("Visuals")
@export var use_sag: bool = true
@export var sag_amount: float = 35.0
@export var rope_width: float = 1.0
@export_range(2, 32, 1) var rope_points: int = 8

var active: bool = false
var start_body: Node2D
var end_body: Node2D
var start_visual_point: Node2D
var end_visual_point: Node2D

var _configured_start_body: Node2D
var _configured_start_visual_point: Node2D
var _detector: Area2D
var _nearby_attachables: Array[Node2D] = []
var _constraint_length: float = 1.0
var _requested_velocities: Dictionary = {}
var _requested_velocity_frames: Dictionary = {}
var _throw_state: ThrowState = ThrowState.READY
var _throw_facing: float = 1.0
var _throw_charge_elapsed: float = 0.0
var _throw_charge_started_msec: int = 0
var _throw_spin_angle: float = 0.0
var _throw_flight_points: PackedVector2Array = PackedVector2Array()
var _throw_flight_elapsed: float = 0.0
var _throw_flight_duration: float = 0.0
var _throw_hit_body: Node2D
var _throw_hit_position: Vector2 = Vector2.ZERO
var _terrain_anchor_point: Marker2D
var _terrain_anchor_body: Node2D

@onready var line: Line2D = get_node_or_null("Line2D") as Line2D
@onready var throw_preview: Line2D = get_node_or_null("ThrowPreview") as Line2D
@onready var throw_end: Polygon2D = get_node_or_null("ThrowEnd") as Polygon2D


func _ready() -> void:
	if line != null:
		line.width = rope_width
		line.visible = active
	if throw_preview != null:
		throw_preview.visible = false
	if throw_end != null:
		throw_end.visible = false
	set_physics_process(active)


func _exit_tree() -> void:
	detach()
	_disconnect_detector()


func _physics_process(delta: float) -> void:
	if is_throw_charging():
		_advance_throw_charge(delta)
		return
	if is_throw_in_flight():
		_advance_throw_flight(delta)
		return
	if not active:
		return

	if not _endpoints_are_valid():
		detach()
		return

	_constrain_rigid_endpoint_once(start_body, delta)
	_constrain_rigid_endpoint_once(end_body, delta)
	_update_rope_visual()


func configure(
	new_start_body: Node2D,
	new_start_visual_point: Node2D,
	detector: Area2D
) -> void:
	_disconnect_detector()
	_configured_start_body = new_start_body
	_configured_start_visual_point = (
		new_start_visual_point if new_start_visual_point != null else new_start_body
	)
	_detector = detector
	_nearby_attachables.clear()

	if _detector == null:
		return

	var entered_callback := Callable(self, "_on_detector_body_entered")
	var exited_callback := Callable(self, "_on_detector_body_exited")
	if not _detector.body_entered.is_connected(entered_callback):
		_detector.body_entered.connect(entered_callback)
	if not _detector.body_exited.is_connected(exited_callback):
		_detector.body_exited.connect(exited_callback)

	for body in _detector.get_overlapping_bodies():
		if body is Node2D:
			track_attachable(body as Node2D)


func toggle_closest() -> bool:
	if active:
		detach()
		return true

	if not _node_is_valid(_configured_start_body):
		return false

	var target := find_closest_attachable()
	if target == null:
		return false

	return attach(
		_configured_start_body,
		target,
		_configured_start_visual_point,
		_resolve_attach_point(target)
	)


func begin_throw_charge(facing_direction: float) -> bool:
	if (
		active
		or has_pending_throw()
		or not _node_is_valid(_configured_start_body)
	):
		return false

	_throw_state = ThrowState.TAP_PENDING
	_throw_facing = -1.0 if facing_direction < 0.0 else 1.0
	_throw_charge_elapsed = 0.0
	_throw_charge_started_msec = Time.get_ticks_msec()
	_throw_spin_angle = 0.0
	_clear_throw_flight()
	_hide_throw_visuals()
	set_physics_process(true)
	return true


func set_throw_facing(facing_direction: float) -> void:
	if not is_throw_charging() or is_zero_approx(facing_direction):
		return
	_throw_facing = -1.0 if facing_direction < 0.0 else 1.0


func release_throw_charge() -> bool:
	if not is_throw_charging() or is_quick_throw_release():
		return false

	_throw_charge_elapsed = get_throw_hold_seconds()
	var path_result := _build_throw_path(get_throw_charge_ratio(), true)
	var points: PackedVector2Array = path_result.get(
		"points",
		PackedVector2Array()
	)
	if points.size() < 2:
		cancel_pending_throw()
		return false

	_throw_state = ThrowState.FLYING
	_throw_flight_points = points
	_throw_flight_elapsed = 0.0
	_throw_flight_duration = maxf(
		float(path_result.get("duration", throw_flight_seconds))
		/ maxf(throw_visual_speed_scale, 0.01),
		0.05
	)
	_throw_hit_body = path_result.get("hit_body") as Node2D
	_throw_hit_position = path_result.get(
		"hit_position",
		points[points.size() - 1]
	)
	if throw_preview != null:
		throw_preview.visible = false
		throw_preview.clear_points()
	if line != null:
		line.visible = true
	if throw_end != null:
		throw_end.visible = true
	_set_throw_end_world_position(points[0])
	_set_line_world_points(PackedVector2Array([
		_get_configured_start_position(),
		points[0],
	]))
	set_physics_process(true)
	return true


func cancel_pending_throw() -> void:
	if not has_pending_throw():
		return
	_throw_state = ThrowState.READY
	_throw_charge_elapsed = 0.0
	_throw_charge_started_msec = 0
	_clear_throw_flight()
	_hide_throw_visuals()
	set_physics_process(active)


func has_pending_throw() -> bool:
	return _throw_state != ThrowState.READY


func is_throw_charging() -> bool:
	return (
		_throw_state == ThrowState.TAP_PENDING
		or _throw_state == ThrowState.SPINNING
	)


func is_throw_spinning() -> bool:
	return _throw_state == ThrowState.SPINNING


func is_throw_in_flight() -> bool:
	return _throw_state == ThrowState.FLYING


func get_throw_hold_seconds() -> float:
	if not is_throw_charging():
		return _throw_charge_elapsed
	var wall_clock_seconds := (
		float(Time.get_ticks_msec() - _throw_charge_started_msec) / 1000.0
	)
	return maxf(_throw_charge_elapsed, wall_clock_seconds)


func is_quick_throw_release() -> bool:
	return get_throw_hold_seconds() < maxf(quick_attach_seconds, 0.0)


func get_throw_charge_ratio() -> float:
	var charge_start := maxf(quick_attach_seconds, 0.0)
	var charge_end := maxf(full_charge_seconds, charge_start + 0.001)
	return clampf(
		(get_throw_hold_seconds() - charge_start) / (charge_end - charge_start),
		0.0,
		1.0
	)


func has_terrain_anchor() -> bool:
	return (
		active
		and _node_is_valid(_terrain_anchor_point)
		and _node_is_valid(_terrain_anchor_body)
		and end_visual_point == _terrain_anchor_point
	)


func adjust_terrain_length(
	pull_in: bool,
	pay_out: bool,
	delta: float
) -> void:
	if (
		not has_terrain_anchor()
		or delta <= 0.0
		or pull_in == pay_out
	):
		return

	if pull_in:
		_constraint_length = maxf(
			minf(minimum_rope_length, max_length),
			_constraint_length - maxf(reel_in_speed, 0.0) * delta
		)
	else:
		_constraint_length = minf(
			maxf(max_length, 1.0),
			_constraint_length + maxf(pay_out_speed, 0.0) * delta
		)


func attach(
	new_start_body: Node2D,
	new_end_body: Node2D,
	new_start_visual_point: Node2D = null,
	new_end_visual_point: Node2D = null,
	rest_length_override: float = -1.0
) -> bool:
	if (
		not _node_is_valid(new_start_body)
		or not _node_is_valid(new_end_body)
		or new_start_body == new_end_body
	):
		return false

	cancel_pending_throw()
	if active:
		detach()

	start_body = new_start_body
	end_body = new_end_body
	start_visual_point = (
		new_start_visual_point if _node_is_valid(new_start_visual_point) else new_start_body
	)
	end_visual_point = (
		new_end_visual_point if _node_is_valid(new_end_visual_point) else new_end_body
	)

	var initial_distance := _get_start_position().distance_to(_get_end_position())
	var requested_rest_length := (
		rest_length_override
		if rest_length_override > 0.0
		else initial_distance + maxf(extra_length, 0.0)
	)
	_constraint_length = clampf(
		requested_rest_length,
		1.0,
		maxf(max_length, 1.0)
	)

	active = true
	_requested_velocities.clear()
	_requested_velocity_frames.clear()
	_record_requested_velocity(start_body, _read_body_velocity(start_body))
	_record_requested_velocity(end_body, _read_body_velocity(end_body))
	_register_on_body(start_body)
	_register_on_body(end_body)

	if line != null:
		line.visible = true
	set_physics_process(true)
	return true


func detach() -> void:
	cancel_pending_throw()
	_unregister_from_body(start_body)
	_unregister_from_body(end_body)
	var anchor_to_free := _terrain_anchor_point
	_terrain_anchor_point = null
	_terrain_anchor_body = null
	active = false
	set_physics_process(false)
	if line != null:
		line.visible = false
		line.clear_points()

	start_body = null
	end_body = null
	start_visual_point = null
	end_visual_point = null
	_constraint_length = 1.0
	_requested_velocities.clear()
	_requested_velocity_frames.clear()
	if _node_is_valid(anchor_to_free):
		anchor_to_free.queue_free()


func track_attachable(attachable: Node2D) -> void:
	if (
		not _node_is_valid(attachable)
		or attachable == _configured_start_body
		or not attachable.is_in_group(&"rope_attachable")
	):
		return
	if not _nearby_attachables.has(attachable):
		_nearby_attachables.append(attachable)


func untrack_attachable(attachable: Node2D) -> void:
	_nearby_attachables.erase(attachable)


func find_closest_attachable() -> Node2D:
	if not _node_is_valid(_configured_start_body):
		return null

	var origin := _get_visual_position(
		_configured_start_visual_point,
		_configured_start_body
	)
	var valid_attachables: Array[Node2D] = []
	var closest: Node2D
	var closest_distance_squared := INF

	for candidate in _nearby_attachables:
		if (
			not _node_is_valid(candidate)
			or candidate == _configured_start_body
			or not candidate.is_in_group(&"rope_attachable")
		):
			continue

		valid_attachables.append(candidate)
		var attach_point := _resolve_attach_point(candidate)
		var distance_squared := origin.distance_squared_to(
			_get_visual_position(attach_point, candidate)
		)
		if (
			distance_squared < closest_distance_squared
			or (
				is_equal_approx(distance_squared, closest_distance_squared)
				and (
					closest == null
					or candidate.get_instance_id() < closest.get_instance_id()
				)
			)
		):
			closest = candidate
			closest_distance_squared = distance_squared

	_nearby_attachables = valid_attachables
	return closest


func _advance_throw_charge(delta: float) -> void:
	_throw_charge_elapsed = minf(
		_throw_charge_elapsed + maxf(delta, 0.0),
		maxf(full_charge_seconds, quick_attach_seconds)
	)
	set_throw_facing(_throw_facing)
	if get_throw_hold_seconds() < maxf(quick_attach_seconds, 0.0):
		return

	_throw_state = ThrowState.SPINNING
	_throw_spin_angle = fposmod(
		_throw_spin_angle + maxf(spin_angular_speed, 0.0) * delta,
		TAU
	)
	var charge_ratio := get_throw_charge_ratio()
	var path_result := _build_throw_path(charge_ratio, true)
	var preview_points: PackedVector2Array = path_result.get(
		"points",
		PackedVector2Array()
	)
	_set_preview_world_points(preview_points)

	var origin := _get_configured_start_position()
	var spin_radius := lerpf(
		maxf(spin_minimum_radius, 0.0),
		maxf(spin_maximum_radius, spin_minimum_radius),
		smoothstep(0.0, 1.0, charge_ratio)
	)
	var spin_offset := Vector2(
		cos(_throw_spin_angle) * _throw_facing,
		sin(_throw_spin_angle)
	) * spin_radius
	var spinning_end_position := origin + spin_offset
	_set_throw_end_world_position(spinning_end_position)
	_set_line_world_points(PackedVector2Array([
		origin,
		spinning_end_position,
	]))
	if line != null:
		line.visible = true
	if throw_end != null:
		throw_end.visible = true


func _advance_throw_flight(delta: float) -> void:
	if _throw_flight_points.size() < 2:
		cancel_pending_throw()
		return

	_throw_flight_elapsed += maxf(delta, 0.0)
	var progress := clampf(
		_throw_flight_elapsed / maxf(_throw_flight_duration, 0.001),
		0.0,
		1.0
	)
	var scaled_index := progress * float(_throw_flight_points.size() - 1)
	var point_index := mini(
		int(floor(scaled_index)),
		_throw_flight_points.size() - 2
	)
	var segment_progress := scaled_index - float(point_index)
	var end_position := _throw_flight_points[point_index].lerp(
		_throw_flight_points[point_index + 1],
		segment_progress
	)
	_set_throw_end_world_position(end_position)
	_set_line_world_points(PackedVector2Array([
		_get_configured_start_position(),
		end_position,
	]))

	if progress >= 1.0:
		_complete_throw_flight()


func _complete_throw_flight() -> void:
	var hit_body := _throw_hit_body
	var hit_position := _throw_hit_position
	_throw_state = ThrowState.READY
	_throw_charge_elapsed = 0.0
	_throw_charge_started_msec = 0
	_clear_throw_flight()
	_hide_throw_visuals()

	if (
		not _node_is_valid(hit_body)
		or not _node_is_valid(_configured_start_body)
	):
		set_physics_process(false)
		return

	var anchor_point := Marker2D.new()
	anchor_point.name = "TerrainRopeAnchor"
	anchor_point.top_level = true
	add_child(anchor_point)
	anchor_point.global_position = hit_position
	_terrain_anchor_point = anchor_point
	_terrain_anchor_body = hit_body

	var start_position := _get_configured_start_position()
	var terrain_rest_length := clampf(
		maxf(
			start_position.distance_to(hit_position),
			minf(minimum_rope_length, max_length)
		),
		1.0,
		maxf(max_length, 1.0)
	)
	var attached := attach(
		_configured_start_body,
		hit_body,
		_configured_start_visual_point,
		anchor_point,
		terrain_rest_length
	)
	if attached:
		return

	_terrain_anchor_point = null
	_terrain_anchor_body = null
	anchor_point.queue_free()
	set_physics_process(false)


func _build_throw_path(
	charge_ratio: float,
	check_terrain: bool
) -> Dictionary:
	var origin := _get_configured_start_position()
	var eased_charge := smoothstep(0.0, 1.0, clampf(charge_ratio, 0.0, 1.0))
	var speed := lerpf(
		maxf(minimum_throw_speed, 0.0),
		maxf(maximum_throw_speed, minimum_throw_speed),
		eased_charge
	)
	var points := sample_ballistic_throw_arc(
		origin,
		_throw_facing,
		speed,
		throw_angle_degrees,
		throw_gravity,
		throw_flight_seconds,
		max_length,
		throw_preview_points
	)
	var result := {
		"points": points,
		"duration": maxf(throw_flight_seconds, 0.05),
		"hit_body": null,
		"hit_position": points[points.size() - 1] if not points.is_empty() else origin,
	}
	if not check_terrain or points.size() < 2 or not is_inside_tree():
		return result

	var space_state := get_world_2d().direct_space_state
	if space_state == null:
		return result

	var excluded_rids: Array[RID] = []
	if _configured_start_body is CollisionObject2D:
		excluded_rids.append(
			(_configured_start_body as CollisionObject2D).get_rid()
		)

	for index in range(1, points.size()):
		while true:
			var query := PhysicsRayQueryParameters2D.create(
				points[index - 1],
				points[index],
				terrain_collision_mask,
				excluded_rids
			)
			query.collide_with_areas = false
			query.collide_with_bodies = true
			var hit := space_state.intersect_ray(query)
			if hit.is_empty():
				break

			var hit_body := hit.get("collider") as Node2D
			if not _node_is_valid(hit_body):
				break
			if not _is_rope_immovable(hit_body):
				if hit_body is CollisionObject2D:
					excluded_rids.append(
						(hit_body as CollisionObject2D).get_rid()
					)
					continue
				break

			var hit_position: Vector2 = hit.get("position", points[index])
			points.resize(index)
			points.append(hit_position)
			result["points"] = points
			result["duration"] = (
				maxf(throw_flight_seconds, 0.05)
				* float(index) / float(maxi(throw_preview_points - 1, 1))
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


func _get_configured_start_position() -> Vector2:
	return _get_visual_position(
		_configured_start_visual_point,
		_configured_start_body
	)


func _set_preview_world_points(points: PackedVector2Array) -> void:
	if throw_preview == null:
		return
	throw_preview.clear_points()
	for point in points:
		throw_preview.add_point(throw_preview.to_local(point))
	throw_preview.visible = points.size() >= 2


func _set_line_world_points(points: PackedVector2Array) -> void:
	if line == null:
		return
	line.clear_points()
	for point in points:
		line.add_point(line.to_local(point))


func _set_throw_end_world_position(world_position: Vector2) -> void:
	if throw_end != null:
		throw_end.global_position = world_position


func _hide_throw_visuals() -> void:
	if throw_preview != null:
		throw_preview.visible = false
		throw_preview.clear_points()
	if throw_end != null:
		throw_end.visible = false
	if line != null and not active:
		line.visible = false
		line.clear_points()


func _clear_throw_flight() -> void:
	_throw_flight_points = PackedVector2Array()
	_throw_flight_elapsed = 0.0
	_throw_flight_duration = 0.0
	_throw_hit_body = null
	_throw_hit_position = Vector2.ZERO


func get_rest_length() -> float:
	return _constraint_length


func get_hard_length() -> float:
	return _constraint_length + maxf(stretch_margin, 0.1)


func is_attached_to(body: Node2D) -> bool:
	return active and (body == start_body or body == end_body)


func apply_anchored_swing_control(
	body: Node2D,
	proposed_velocity: Vector2,
	velocity_before_air_control: Vector2,
	horizontal_input: float,
	delta: float
) -> Vector2:
	if (
		not active
		or delta <= 0.0
		or not is_attached_to(body)
		or not _endpoints_are_valid()
	):
		return proposed_velocity
	if body is CharacterBody2D and (body as CharacterBody2D).is_on_floor():
		return proposed_velocity

	var other_body := end_body if body == start_body else start_body
	if not _is_rope_immovable(other_body):
		return proposed_velocity

	var body_position := (
		_get_start_position() if body == start_body else _get_end_position()
	)
	var anchor_position := (
		_get_end_position() if body == start_body else _get_start_position()
	)
	var offset_from_anchor := body_position - anchor_position
	var distance := offset_from_anchor.length()
	if distance <= 0.001:
		return proposed_velocity

	var radial_direction := offset_from_anchor / distance
	var projected_distance := (
		distance
		+ maxf(velocity_before_air_control.dot(radial_direction), 0.0) * delta
	)
	if projected_distance < _constraint_length:
		return proposed_velocity

	var tangent := Vector2(-radial_direction.y, radial_direction.x)
	var radial_speed := velocity_before_air_control.dot(radial_direction)
	var tangent_speed := velocity_before_air_control.dot(tangent)
	var clamped_input := clampf(horizontal_input, -1.0, 1.0)
	if is_zero_approx(clamped_input):
		var damping := exp(-maxf(passive_swing_damping, 0.0) * delta)
		tangent_speed *= damping
	else:
		var tangential_acceleration := (
			clamped_input
			* maxf(swing_input_acceleration, 0.0)
			* tangent.x
		)
		tangent_speed = _add_bounded_swing_input(
			tangent_speed,
			tangential_acceleration,
			swing_input_speed_limit,
			delta
		)

	return (
		radial_direction * radial_speed
		+ tangent * tangent_speed
	)


func preserve_passive_swing_velocity(
	body: Node2D,
	proposed_velocity: Vector2,
	velocity_before_air_control: Vector2,
	delta: float
) -> Vector2:
	return apply_anchored_swing_control(
		body,
		proposed_velocity,
		velocity_before_air_control,
		0.0,
		delta
	)


static func _add_bounded_swing_input(
	tangent_speed: float,
	tangential_acceleration: float,
	speed_limit: float,
	delta: float
) -> float:
	if delta <= 0.0 or is_zero_approx(tangential_acceleration):
		return tangent_speed

	var speed_change := tangential_acceleration * delta
	var limit := maxf(speed_limit, 0.0)
	if limit <= 0.0:
		return tangent_speed

	if absf(tangent_speed) > limit:
		if tangent_speed * speed_change >= 0.0:
			return tangent_speed
		var slowed_speed := tangent_speed + speed_change
		if (
			signf(slowed_speed) == signf(tangent_speed)
			and absf(slowed_speed) > limit
		):
			return slowed_speed
		return clampf(slowed_speed, -limit, limit)

	return clampf(tangent_speed + speed_change, -limit, limit)


static func constrain_attached_velocity(
	body: Node2D,
	proposed_velocity: Vector2,
	delta: float
) -> Vector2:
	if not _node_is_valid(body) or delta <= 0.0:
		return proposed_velocity

	var direct_ropes := _get_attached_ropes(body)
	if direct_ropes.is_empty():
		return proposed_velocity

	for rope in direct_ropes:
		rope._record_requested_velocity(body, proposed_velocity)

	var network := _collect_network(body)
	var bodies: Array = network.get("bodies", [])
	var ropes: Array = network.get("ropes", [])
	if ropes.is_empty():
		return proposed_velocity

	var intended_velocities: Dictionary = {}
	for network_body in bodies:
		if network_body == body:
			intended_velocities[network_body] = proposed_velocity
		else:
			intended_velocities[network_body] = _read_network_intent(
				network_body,
				ropes
			)

	var solved := _solve_network(intended_velocities, ropes, delta)
	var solved_velocity: Vector2 = solved.get(body, proposed_velocity)
	var body_is_grounded := (
		body is CharacterBody2D
		and (body as CharacterBody2D).is_on_floor()
	)
	return _limit_grounded_rope_lift(
		proposed_velocity,
		solved_velocity,
		body_is_grounded
	)


static func _limit_grounded_rope_lift(
	proposed_velocity: Vector2,
	solved_velocity: Vector2,
	is_grounded: bool
) -> Vector2:
	var upward_limit := minf(proposed_velocity.y, 0.0)
	if is_grounded and solved_velocity.y < upward_limit:
		solved_velocity.y = upward_limit
	return solved_velocity


static func solve_weighted_velocity_pair(
	start_velocity: Vector2,
	end_velocity: Vector2,
	direction_from_start_to_end: Vector2,
	start_weight: float,
	end_weight: float,
	start_is_immovable: bool = false,
	end_is_immovable: bool = false,
	coupling: float = 1.0,
	max_relative_separation_speed: float = 0.0
) -> PackedVector2Array:
	var direction := direction_from_start_to_end.normalized()
	var response := clampf(coupling, 0.0, 1.0)
	if direction.is_zero_approx() or response <= 0.0:
		return PackedVector2Array([start_velocity, end_velocity])

	var start_inverse_weight := (
		0.0 if start_is_immovable else 1.0 / maxf(start_weight, MIN_WEIGHT)
	)
	var end_inverse_weight := (
		0.0 if end_is_immovable else 1.0 / maxf(end_weight, MIN_WEIGHT)
	)
	var inverse_weight_sum := start_inverse_weight + end_inverse_weight
	if inverse_weight_sum <= 0.0:
		return PackedVector2Array([start_velocity, end_velocity])

	var relative_speed := (end_velocity - start_velocity).dot(direction)
	if relative_speed <= max_relative_separation_speed:
		return PackedVector2Array([start_velocity, end_velocity])

	var corrected_relative_speed := lerpf(
		relative_speed,
		max_relative_separation_speed,
		response
	)
	var impulse := (
		(relative_speed - corrected_relative_speed)
		/ inverse_weight_sum
	)
	var solved_start := (
		start_velocity
		+ direction * impulse * start_inverse_weight
	)
	var solved_end := (
		end_velocity
		- direction * impulse * end_inverse_weight
	)
	return PackedVector2Array([solved_start, solved_end])


func _calculate_constraint_response(
	delta: float,
	start_velocity: Vector2,
	end_velocity: Vector2
) -> Dictionary:
	var start_position := _get_start_position()
	var end_position := _get_end_position()
	var offset := end_position - start_position
	var distance := offset.length()
	if distance <= 0.001:
		return {"coupling": 0.0}

	var direction := offset / distance
	var relative_speed := (end_velocity - start_velocity).dot(direction)
	var give := maxf(stretch_margin, 0.1)
	var hard_length := _constraint_length + give
	var projected_distance := distance + maxf(relative_speed, 0.0) * delta
	var response_distance := maxf(distance, projected_distance)
	var response_ratio := clampf(
		(response_distance - _constraint_length) / give,
		0.0,
		1.0
	)
	var coupling := smoothstep(0.0, 1.0, response_ratio)
	var speed_limit := INF

	var actual_stretch_ratio := clampf(
		(distance - _constraint_length) / give,
		0.0,
		1.0
	)
	if actual_stretch_ratio > 0.0:
		speed_limit = -maxf(elastic_return_speed, 0.0) * actual_stretch_ratio

	if projected_distance > hard_length:
		var boundary_speed := (hard_length - distance) / delta
		speed_limit = minf(speed_limit, boundary_speed)
		coupling = 1.0

	if distance > hard_length:
		var overstretch := distance - hard_length
		var recovery_speed := minf(
			maxf(overstretch_recovery_speed, 0.0),
			maxf(elastic_return_speed, 0.0) + overstretch * 8.0
		)
		speed_limit = minf(speed_limit, -recovery_speed)
		coupling = 1.0

	if coupling <= 0.0 or is_inf(speed_limit):
		return {"coupling": 0.0}

	return {
		"coupling": coupling,
		"direction": direction,
		"speed_limit": speed_limit,
	}


static func _solve_network(
	intended_velocities: Dictionary,
	ropes: Array,
	delta: float
) -> Dictionary:
	var velocities := intended_velocities.duplicate()
	var responses: Dictionary = {}
	var weights: Dictionary = {}
	var immovable: Dictionary = {}
	for body in intended_velocities:
		var body_is_immovable := _is_rope_immovable(body)
		immovable[body] = body_is_immovable
		weights[body] = 1.0 if body_is_immovable else _get_rope_weight(body)

	for rope_value in ropes:
		var rope := rope_value as Rope
		if rope == null or not rope._endpoints_are_valid():
			continue
		responses[rope] = rope._calculate_constraint_response(
			delta,
			velocities.get(rope.start_body, Vector2.ZERO),
			velocities.get(rope.end_body, Vector2.ZERO)
		)

	if responses.is_empty():
		return velocities

	var iterations := 1 if responses.size() == 1 else NETWORK_SOLVER_ITERATIONS
	var relaxation := 1.0 if iterations == 1 else NETWORK_RELAXATION

	for _iteration in range(iterations):
		var corrections: Dictionary = {}
		for rope_value in ropes:
			var rope := rope_value as Rope
			if rope == null or not responses.has(rope):
				continue

			var response: Dictionary = responses[rope]
			var total_coupling := float(response.get("coupling", 0.0))
			if total_coupling <= 0.0:
				continue

			var iteration_coupling := (
				total_coupling
				if iterations == 1
				else 1.0 - pow(1.0 - total_coupling, 1.0 / float(iterations))
			)
			var start_velocity: Vector2 = velocities.get(
				rope.start_body,
				Vector2.ZERO
			)
			var end_velocity: Vector2 = velocities.get(
				rope.end_body,
				Vector2.ZERO
			)
			var solved_pair := solve_weighted_velocity_pair(
				start_velocity,
				end_velocity,
				response.get("direction", Vector2.ZERO),
				float(weights.get(rope.start_body, 1.0)),
				float(weights.get(rope.end_body, 1.0)),
				bool(immovable.get(rope.start_body, true)),
				bool(immovable.get(rope.end_body, true)),
				iteration_coupling,
				float(response.get("speed_limit", 0.0))
			)
			corrections[rope.start_body] = (
				corrections.get(rope.start_body, Vector2.ZERO)
				+ (solved_pair[0] - start_velocity) * relaxation
			)
			corrections[rope.end_body] = (
				corrections.get(rope.end_body, Vector2.ZERO)
				+ (solved_pair[1] - end_velocity) * relaxation
			)

		if corrections.is_empty():
			break
		for corrected_body in corrections:
			velocities[corrected_body] = (
				velocities.get(corrected_body, Vector2.ZERO)
				+ corrections[corrected_body]
			)

	return velocities


static func _collect_network(root_body: Node2D) -> Dictionary:
	var bodies: Array[Node2D] = []
	var ropes: Array[Rope] = []
	var pending: Array[Node2D] = [root_body]
	var seen_body_ids: Dictionary = {}
	var seen_rope_ids: Dictionary = {}

	while not pending.is_empty():
		var body: Node2D = pending.pop_back() as Node2D
		if not _node_is_valid(body):
			continue
		var body_id: int = body.get_instance_id()
		if seen_body_ids.has(body_id):
			continue
		seen_body_ids[body_id] = true
		bodies.append(body)

		for rope in _get_attached_ropes(body):
			var rope_id := rope.get_instance_id()
			if not seen_rope_ids.has(rope_id):
				seen_rope_ids[rope_id] = true
				ropes.append(rope)
			if _node_is_valid(rope.start_body):
				pending.append(rope.start_body)
			if _node_is_valid(rope.end_body):
				pending.append(rope.end_body)

	ropes.sort_custom(
		func(first: Rope, second: Rope) -> bool:
			return first.get_instance_id() < second.get_instance_id()
	)
	return {"bodies": bodies, "ropes": ropes}


static func _read_network_intent(body: Node2D, ropes: Array) -> Vector2:
	var newest_frame := -1
	var velocity := _read_body_velocity(body)
	var body_id := body.get_instance_id()
	for rope_value in ropes:
		var rope := rope_value as Rope
		if rope == null or not rope.is_attached_to(body):
			continue
		var recorded_frame := int(rope._requested_velocity_frames.get(body_id, -1))
		if recorded_frame >= newest_frame and rope._requested_velocities.has(body_id):
			newest_frame = recorded_frame
			velocity = rope._requested_velocities[body_id]
	return velocity


func _record_requested_velocity(body: Node2D, velocity: Vector2) -> void:
	if not _node_is_valid(body) or not is_attached_to(body):
		return
	var body_id := body.get_instance_id()
	_requested_velocities[body_id] = velocity
	_requested_velocity_frames[body_id] = Engine.get_physics_frames()


func _constrain_rigid_endpoint_once(body: Node2D, delta: float) -> void:
	if not body is RigidBody2D:
		return
	var rigid := body as RigidBody2D
	var physics_frame := Engine.get_physics_frames()
	if int(rigid.get_meta(RIGID_SOLVED_FRAME_META, -1)) == physics_frame:
		return
	rigid.set_meta(RIGID_SOLVED_FRAME_META, physics_frame)
	rigid.linear_velocity = constrain_attached_velocity(
		rigid,
		rigid.linear_velocity,
		delta
	)
	rigid.sleeping = false


func _register_on_body(body: Node2D) -> void:
	if not _node_is_valid(body):
		return
	var references: Array = body.get_meta(ATTACHED_ROPES_META, [])
	for reference in references:
		if reference is WeakRef and reference.get_ref() == self:
			return
	references.append(weakref(self))
	body.set_meta(ATTACHED_ROPES_META, references)


func _unregister_from_body(body: Node2D) -> void:
	if not _node_is_valid(body) or not body.has_meta(ATTACHED_ROPES_META):
		return
	var kept_references: Array = []
	for reference in body.get_meta(ATTACHED_ROPES_META, []):
		if not reference is WeakRef:
			continue
		var rope: Rope = reference.get_ref() as Rope
		if rope != null and rope != self:
			kept_references.append(reference)
	if kept_references.is_empty():
		body.remove_meta(ATTACHED_ROPES_META)
		if body.has_meta(RIGID_SOLVED_FRAME_META):
			body.remove_meta(RIGID_SOLVED_FRAME_META)
	else:
		body.set_meta(ATTACHED_ROPES_META, kept_references)


static func _get_attached_ropes(body: Node2D) -> Array[Rope]:
	var ropes: Array[Rope] = []
	if not _node_is_valid(body) or not body.has_meta(ATTACHED_ROPES_META):
		return ropes

	var kept_references: Array = []
	for reference in body.get_meta(ATTACHED_ROPES_META, []):
		if not reference is WeakRef:
			continue
		var rope := reference.get_ref() as Rope
		if rope == null or not rope.active or not rope.is_attached_to(body):
			continue
		kept_references.append(reference)
		ropes.append(rope)

	if kept_references.is_empty():
		body.remove_meta(ATTACHED_ROPES_META)
		if body.has_meta(RIGID_SOLVED_FRAME_META):
			body.remove_meta(RIGID_SOLVED_FRAME_META)
	else:
		body.set_meta(ATTACHED_ROPES_META, kept_references)
	return ropes


static func _get_rope_weight(body: Node2D) -> float:
	if not _node_is_valid(body):
		return 1.0
	if body.has_method("get_rope_weight"):
		return maxf(float(body.call("get_rope_weight")), MIN_WEIGHT)
	if _has_property(body, &"rope_weight"):
		return maxf(float(body.get(&"rope_weight")), MIN_WEIGHT)
	if body is RigidBody2D:
		return maxf((body as RigidBody2D).mass, MIN_WEIGHT)
	if body.is_in_group(&"npc"):
		return DEFAULT_NPC_WEIGHT
	return DEFAULT_BODY_WEIGHT


static func _is_rope_immovable(body: Node2D) -> bool:
	if not _node_is_valid(body):
		return true
	if body is StaticBody2D or body is AnimatableBody2D:
		return true
	if body.is_in_group(&"rope_immovable"):
		return true
	if body.has_method("is_rope_immovable"):
		return bool(body.call("is_rope_immovable"))
	if _has_property(body, &"rope_immovable"):
		return bool(body.get(&"rope_immovable"))
	if body is RigidBody2D:
		return (body as RigidBody2D).freeze
	return not (body is CharacterBody2D or body is RigidBody2D)


static func _read_body_velocity(body: Node2D) -> Vector2:
	if not _node_is_valid(body):
		return Vector2.ZERO
	if body is CharacterBody2D:
		return (body as CharacterBody2D).velocity
	if body is RigidBody2D:
		return (body as RigidBody2D).linear_velocity
	return Vector2.ZERO


static func _has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			return true
	return false


static func _node_is_valid(node: Node) -> bool:
	return (
		node != null
		and is_instance_valid(node)
		and not node.is_queued_for_deletion()
	)


func _endpoints_are_valid() -> bool:
	return _node_is_valid(start_body) and _node_is_valid(end_body)


func _get_start_position() -> Vector2:
	return _get_visual_position(start_visual_point, start_body)


func _get_end_position() -> Vector2:
	return _get_visual_position(end_visual_point, end_body)


func _update_rope_visual() -> void:
	if line == null:
		return
	var start_position := _get_start_position()
	var end_position := _get_end_position()
	var distance := start_position.distance_to(end_position)
	var taut_ratio := clampf(distance / maxf(_constraint_length, 1.0), 0.0, 1.0)
	var sag := sag_amount * (1.0 - taut_ratio) if use_sag else 0.0

	line.width = rope_width
	line.clear_points()
	var point_count := maxi(rope_points, 2)
	for index in range(point_count):
		var progress := float(index) / float(point_count - 1)
		var point := start_position.lerp(end_position, progress)
		point += Vector2.DOWN * sag * sin(progress * PI)
		line.add_point(line.to_local(point))


func _get_visual_position(visual_point: Node2D, fallback_body: Node2D) -> Vector2:
	if _node_is_valid(visual_point):
		return visual_point.global_position
	return fallback_body.global_position if _node_is_valid(fallback_body) else Vector2.ZERO


func _resolve_attach_point(body: Node2D) -> Node2D:
	if not _node_is_valid(body):
		return body
	if body.has_method("get_rope_attach_point"):
		var attach_point = body.call("get_rope_attach_point")
		if attach_point is Node2D and _node_is_valid(attach_point):
			return attach_point as Node2D
	return body


func _on_detector_body_entered(body: Node2D) -> void:
	track_attachable(body)


func _on_detector_body_exited(body: Node2D) -> void:
	untrack_attachable(body)


func _disconnect_detector() -> void:
	if not _node_is_valid(_detector):
		_detector = null
		return
	var entered_callback := Callable(self, "_on_detector_body_entered")
	var exited_callback := Callable(self, "_on_detector_body_exited")
	if _detector.body_entered.is_connected(entered_callback):
		_detector.body_entered.disconnect(entered_callback)
	if _detector.body_exited.is_connected(exited_callback):
		_detector.body_exited.disconnect(exited_callback)
	_detector = null
