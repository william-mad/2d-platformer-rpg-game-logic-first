class_name MomNpcFightState extends NpcStateFight

enum MomAttackMode {
	NONE,
	MELEE,
	PROJECTILE,
}

@export_group("Mom Melee")
@export var melee_damage: float = 4.0
@export var melee_range_hitbox_multiplier: float = 3.0
@export var melee_height_hitbox_multiplier: float = 1.25
@export var melee_windup_seconds: float = 0.18
@export var melee_cooldown_seconds: float = 0.85
@export var melee_collision_mask: int = 2
@export var melee_swing_interval_seconds: float = 0.12
@export var melee_swing_angles_degrees: PackedFloat32Array = PackedFloat32Array([-30.0, 30.0, 0.0])
@export var melee_swing_visual_seconds: float = 0.18
@export var melee_swing_visual_width: float = 7.0
@export var melee_swing_visual_color: Color = Color(1.0, 0.9, 0.35, 0.9)

@export_group("Mom Fight Movement")
@export var match_target_move_speed: bool = true
@export var fallback_fight_move_speed: float = 700.0

@export_group("Mom Projectile Aim")
@export var projectile_distance_threshold: float = 260.0
@export var projectile_aim_windup_seconds: float = 0.34
@export var projectile_cooldown_seconds: float = 1.35
@export var aim_indicator_enabled: bool = true
@export var aim_indicator_color: Color = Color(1.0, 0.38, 0.18, 0.82)
@export var aim_indicator_width: float = 2.0

var active_attack_mode: MomAttackMode = MomAttackMode.NONE
var attack_windup_timer: float = 0.0
var melee_sequence_active: bool = false
var melee_swing_index: int = 0
var melee_swing_timer: float = 0.0
var current_aim_position: Vector2 = Vector2.ZERO
var aim_indicator: Line2D


func enter() -> void:
	active_attack_mode = MomAttackMode.NONE
	attack_windup_timer = 0.0
	melee_sequence_active = false
	melee_swing_index = 0
	melee_swing_timer = 0.0
	super.enter()
	_ensure_aim_indicator()
	_set_aim_indicator_visible(false)


func exit() -> void:
	active_attack_mode = MomAttackMode.NONE
	melee_sequence_active = false
	_set_aim_indicator_visible(false)
	super.exit()


func _update_chase() -> void:
	if _is_winding_up_attack():
		_face_fight_target()
		stop_horizontal()
		return

	if npc == null or fight_target == null:
		return

	var distance := _get_target_distance()
	_face_fight_target()

	if distance <= _get_melee_reach_distance():
		stop_horizontal()
		return

	if distance >= projectile_distance_threshold and distance <= attack_range:
		stop_horizontal()
		return

	var chase_stop_distance := maxf(_get_melee_reach_distance() * 0.9, machine.stop_distance)
	var chase_speed := _get_fight_move_speed()
	move_toward_position(fight_target.global_position, chase_speed, chase_stop_distance)


func _update_attack(delta: float) -> void:
	if _is_winding_up_attack():
		_update_attack_windup(delta)
		return

	attack_cooldown_timer -= delta
	if attack_cooldown_timer > 0.0:
		return

	if fight_target == null or not is_instance_valid(fight_target):
		return

	var distance := _get_target_distance()
	if distance <= _get_melee_reach_distance():
		_start_melee_attack()
		return

	if distance >= projectile_distance_threshold and distance <= attack_range:
		_start_projectile_attack()


func _start_melee_attack() -> void:
	active_attack_mode = MomAttackMode.MELEE
	attack_windup_timer = maxf(melee_windup_seconds, 0.0)
	melee_sequence_active = false
	melee_swing_index = 0
	melee_swing_timer = 0.0
	_set_aim_indicator_visible(false)
	_face_fight_target()
	stop_horizontal()


func _start_projectile_attack() -> void:
	active_attack_mode = MomAttackMode.PROJECTILE
	attack_windup_timer = maxf(projectile_aim_windup_seconds, 0.0)
	_face_fight_target()
	stop_horizontal()
	_update_projectile_aim()
	_set_aim_indicator_visible(true)


func _update_attack_windup(delta: float) -> void:
	if active_attack_mode == MomAttackMode.MELEE and melee_sequence_active:
		_update_melee_sequence(delta)
		return

	if active_attack_mode == MomAttackMode.PROJECTILE:
		_update_projectile_aim()

	attack_windup_timer -= delta
	if attack_windup_timer > 0.0:
		return

	match active_attack_mode:
		MomAttackMode.MELEE:
			_begin_melee_sequence()
		MomAttackMode.PROJECTILE:
			_throw_aimed_projectile()
			attack_cooldown_timer = maxf(projectile_cooldown_seconds, 0.05)
			active_attack_mode = MomAttackMode.NONE
			_set_aim_indicator_visible(false)


func _begin_melee_sequence() -> void:
	melee_sequence_active = true
	melee_swing_index = 0
	melee_swing_timer = 0.0
	_update_melee_sequence(0.0)


func _update_melee_sequence(delta: float) -> void:
	melee_swing_timer -= delta
	if melee_swing_timer > 0.0:
		return

	var swing_count := maxi(melee_swing_angles_degrees.size(), 1)
	if melee_swing_index >= swing_count:
		_finish_melee_sequence()
		return

	_do_melee_attack(_get_melee_swing_angle_degrees(melee_swing_index))
	melee_swing_index += 1

	if melee_swing_index >= swing_count:
		_finish_melee_sequence()
	else:
		melee_swing_timer = maxf(melee_swing_interval_seconds, 0.01)


func _finish_melee_sequence() -> void:
	melee_sequence_active = false
	active_attack_mode = MomAttackMode.NONE
	attack_cooldown_timer = maxf(melee_cooldown_seconds, 0.05)
	_set_aim_indicator_visible(false)


func _get_melee_swing_angle_degrees(index: int) -> float:
	if melee_swing_angles_degrees.is_empty():
		return 0.0

	return melee_swing_angles_degrees[clampi(index, 0, melee_swing_angles_degrees.size() - 1)]


func _do_melee_attack(swing_angle_degrees: float) -> void:
	if npc == null or not npc.is_inside_tree():
		return

	var body_shape := _get_body_collision_shape()
	var hitbox_size := _get_body_hitbox_size(body_shape)
	var direction_x := _get_direction_to_target()
	var swing_direction := _get_melee_swing_direction(direction_x, swing_angle_degrees)
	var melee_range := _get_melee_range()
	var melee_height := maxf(hitbox_size.y * melee_height_hitbox_multiplier, hitbox_size.y)
	var body_center := body_shape.global_position if body_shape != null else npc.global_position - Vector2(0.0, hitbox_size.y * 0.5)
	var attack_center := body_center + swing_direction * ((hitbox_size.x * 0.5) + (melee_range * 0.5))

	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(melee_range, melee_height)

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = rectangle
	query.transform = Transform2D(swing_direction.angle(), attack_center)
	query.collision_mask = melee_collision_mask
	query.collide_with_areas = true
	query.collide_with_bodies = true

	_spawn_melee_swing_visual(body_center, swing_direction, hitbox_size.x * 0.5, melee_range)

	var damaged_victims: Array[Node] = []
	var results := npc.get_world_2d().direct_space_state.intersect_shape(query, 32)
	for result in results:
		var collider := result.get("collider") as Node
		var victim := _get_attack_victim(collider)
		if victim == null or damaged_victims.has(victim):
			continue

		if not _target_group_is_allowed(victim):
			continue

		damaged_victims.append(victim)
		victim.call("take_damage", melee_damage, npc.global_position, npc)


func _get_melee_swing_direction(direction_x: float, swing_angle_degrees: float) -> Vector2:
	var base_direction := Vector2(signf(direction_x), 0.0)
	if base_direction.x == 0.0:
		base_direction = Vector2.RIGHT

	return base_direction.rotated(deg_to_rad(swing_angle_degrees * base_direction.x)).normalized()


func _spawn_melee_swing_visual(
	body_center: Vector2,
	swing_direction: Vector2,
	body_half_width: float,
	melee_range: float
) -> void:
	if npc == null:
		return

	var slash := Line2D.new()
	slash.name = "MomMeleeSwing"
	slash.default_color = melee_swing_visual_color
	slash.width = maxf(melee_swing_visual_width, 1.0)
	slash.z_index = 20

	var start_position := body_center + swing_direction * body_half_width
	var end_position := start_position + swing_direction * melee_range
	slash.add_point(npc.to_local(start_position))
	slash.add_point(npc.to_local(end_position))
	npc.add_child(slash)

	var tween := slash.create_tween()
	tween.tween_property(slash, "width", maxf(melee_swing_visual_width * 0.35, 1.0), melee_swing_visual_seconds)
	tween.parallel().tween_property(slash, "modulate:a", 0.0, melee_swing_visual_seconds)
	tween.tween_callback(slash.queue_free)


func _throw_aimed_projectile() -> void:
	if fight_target == null or not is_instance_valid(fight_target):
		return

	var projectile := _create_projectile()
	if projectile == null:
		return

	var target_position := current_aim_position
	var spawn_position := _get_projectile_spawn_position(target_position)
	var parent := _get_projectile_parent()
	parent.add_child(projectile)

	if projectile.has_method("launch"):
		projectile.call(
			"launch",
			spawn_position,
			target_position,
			npc,
			projectile_damage,
			projectile_flight_time,
			projectile_arc_height,
			projectile_lifetime,
			projectile_collision_mask,
			friendly_fire_favor_penalty,
			fight_target,
			anger_drop_on_target_hit
		)
	else:
		projectile.global_position = spawn_position


func _update_projectile_aim() -> void:
	if fight_target == null or not is_instance_valid(fight_target):
		_set_aim_indicator_visible(false)
		return

	current_aim_position = _get_attack_aim_position(fight_target)
	_face_fight_target()
	_update_aim_indicator()


func _update_aim_indicator() -> void:
	if not aim_indicator_enabled or aim_indicator == null or npc == null:
		return

	var spawn_position := _get_projectile_spawn_position(current_aim_position)
	aim_indicator.clear_points()
	aim_indicator.add_point(npc.to_local(spawn_position))
	aim_indicator.add_point(npc.to_local(current_aim_position))


func _ensure_aim_indicator() -> void:
	if not aim_indicator_enabled or npc == null:
		return

	if aim_indicator != null and is_instance_valid(aim_indicator):
		return

	aim_indicator = Line2D.new()
	aim_indicator.name = "MomAimIndicator"
	aim_indicator.default_color = aim_indicator_color
	aim_indicator.width = maxf(aim_indicator_width, 1.0)
	aim_indicator.visible = false
	npc.add_child(aim_indicator)


func _set_aim_indicator_visible(is_visible: bool) -> void:
	if aim_indicator != null and is_instance_valid(aim_indicator):
		aim_indicator.visible = is_visible and aim_indicator_enabled


func _is_winding_up_attack() -> bool:
	return active_attack_mode != MomAttackMode.NONE


func _face_fight_target() -> void:
	var direction_x := _get_direction_to_target()
	if direction_x != 0.0:
		face_x_direction(direction_x)


func _get_direction_to_target() -> float:
	if npc == null or fight_target == null or not is_instance_valid(fight_target):
		return 1.0

	var direction_x := signf(fight_target.global_position.x - npc.global_position.x)
	return direction_x if direction_x != 0.0 else 1.0


func _get_target_distance() -> float:
	if npc == null or fight_target == null or not is_instance_valid(fight_target):
		return INF

	return npc.global_position.distance_to(fight_target.global_position)


func _get_fight_move_speed() -> float:
	if match_target_move_speed:
		var target_move_speed := _get_float_property(fight_target, &"move_speed", -1.0)
		if target_move_speed > 0.0:
			return target_move_speed

	return maxf(fallback_fight_move_speed, 0.0)


func _get_float_property(node: Node, property_name: StringName, fallback: float) -> float:
	if node == null or not is_instance_valid(node):
		return fallback

	for property in node.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return float(node.get(property_name))

	return fallback


func _get_melee_reach_distance() -> float:
	var body_shape := _get_body_collision_shape()
	var hitbox_size := _get_body_hitbox_size(body_shape)
	return (hitbox_size.x * 0.5) + _get_melee_range()


func _get_melee_range() -> float:
	var body_shape := _get_body_collision_shape()
	var hitbox_size := _get_body_hitbox_size(body_shape)
	return maxf(hitbox_size.x * melee_range_hitbox_multiplier, 1.0)


func _get_body_collision_shape() -> CollisionShape2D:
	if npc == null:
		return null

	var named_shape := npc.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if named_shape != null and not named_shape.disabled:
		return named_shape

	for child in npc.get_children():
		var collision_shape := child as CollisionShape2D
		if collision_shape != null and not collision_shape.disabled:
			return collision_shape

	return null


func _get_body_hitbox_size(body_shape: CollisionShape2D) -> Vector2:
	if body_shape == null or body_shape.shape == null:
		return Vector2(48.0, 64.0)

	var size := Vector2(48.0, 64.0)
	if body_shape.shape is RectangleShape2D:
		size = (body_shape.shape as RectangleShape2D).size
	elif body_shape.shape is CapsuleShape2D:
		var capsule := body_shape.shape as CapsuleShape2D
		size = Vector2(capsule.radius * 2.0, capsule.height)
	elif body_shape.shape is CircleShape2D:
		var diameter := (body_shape.shape as CircleShape2D).radius * 2.0
		size = Vector2(diameter, diameter)

	return Vector2(
		maxf(absf(size.x * body_shape.global_scale.x), 1.0),
		maxf(absf(size.y * body_shape.global_scale.y), 1.0)
	)


func _get_attack_victim(collider: Node) -> Node:
	if collider == null or not is_instance_valid(collider):
		return null

	if collider == npc:
		return null

	if collider is Damage_Area:
		var victim_owner := collider.get_parent()
		if victim_owner != null and victim_owner.has_method("take_damage"):
			return victim_owner

	if collider.has_method("take_damage"):
		return collider

	return null
