class_name MomNpcFightState extends NpcStateFight

enum MomAttackMode {
	NONE,
	MELEE,
	PROJECTILE,
	SCREAM,
	MELEE_STAGGER_PROJECTILE,
	RANGED_JUMP_PROJECTILE,
	STRAIGHT_HIT_MELEE,
}

enum ProjectileHitFollowup {
	NONE,
	RANGED_JUMP,
	SLOW_MELEE,
}

@export_group("Mom Melee")
@export var melee_damage: float = 4.0
@export var melee_knockout_damage: float = 35.0
@export var melee_range_hitbox_multiplier: float = 3.0
@export var melee_height_hitbox_multiplier: float = 1.25
@export var melee_windup_seconds: float = 0.18
@export var melee_cooldown_seconds: float = 0.85
@export var melee_collision_mask: int = 130
@export var melee_swing_interval_seconds: float = 0.12
@export var melee_swing_angles_degrees: PackedFloat32Array = PackedFloat32Array([-30.0, 30.0, 0.0])
@export var melee_swing_visual_seconds: float = 0.18
@export var melee_swing_visual_width: float = 7.0
@export var melee_swing_visual_color: Color = Color(1.0, 0.9, 0.35, 0.9)

@export_group("Mom Fight Movement")
@export var match_target_move_speed: bool = true
@export var fallback_fight_move_speed: float = 700.0

@export_group("Mom Bystander Safety")
@export var avoid_bystanders_before_attack: bool = true
@export var allow_projectile_when_melee_blocked: bool = true
@export var bystander_melee_safe_padding: float = 24.0
@export var bystander_projectile_lane_width: float = 36.0

@export_group("Mom NPC Fight")
@export var npc_relationship_anger_drop_on_target_hit: float = 20.0

@export_group("Mom Scream")
@export var scream_enabled: bool = true
@export var scream_charge_seconds: float = 0.45
@export var scream_close_speed_multiplier: float = 0.16
@export var scream_radius: float = 420.0
@export var scream_flee_priority: int = 90
@export var scream_player_flee_seconds: float = 1.2
@export var scream_player_flee_speed: float = 700.0
@export var scream_attack_cooldown_seconds: float = 1.0
@export var scream_visual_seconds: float = 0.45
@export var scream_visual_start_scale: float = 0.03
@export var scream_visual_point_count: int = 48
@export var scream_visual_color: Color = Color(1.0, 0.25, 0.12, 0.8)
@export var scream_visual_width: float = 4.0
@export var scream_move_text: String = "move"
@export var scream_move_text_seconds: float = 0.75
@export var scream_move_text_offset: Vector2 = Vector2(-48.0, -112.0)
@export var scream_move_text_rise: float = 32.0
@export var scream_move_text_color: Color = Color(1.0, 0.95, 0.3, 1.0)

@export_group("Mom Projectile Aim")
@export var projectile_distance_threshold: float = 260.0
@export var projectile_aim_windup_seconds: float = 0.34
@export var projectile_cooldown_seconds: float = 1.35
@export var aim_indicator_enabled: bool = true
@export var aim_indicator_color: Color = Color(1.0, 0.38, 0.18, 0.82)
@export var aim_indicator_width: float = 2.0

@export_group("Mom Hit Followups")
@export var melee_hit_followup_enabled: bool = true
@export var melee_followup_backstep_seconds: float = 0.75
@export var melee_followup_backstep_speed_multiplier: float = 0.18
@export var melee_followup_projectile_cooldown_seconds: float = 0.95
@export var ranged_hit_followup_enabled: bool = true
@export var ranged_followup_delay_seconds: float = 0.16
@export var ranged_followup_jump_velocity: float = 560.0
@export var ranged_followup_jump_lunge_seconds: float = 0.45
@export_range(0.0, 1.0, 0.01) var ranged_followup_jump_target_fraction: float = 0.8
@export var ranged_followup_jump_max_horizontal_speed: float = 1100.0
@export var ranged_followup_flight_time: float = 0.34
@export var ranged_followup_cooldown_seconds: float = 0.8
@export var straight_hit_melee_followup_enabled: bool = true
@export var straight_hit_melee_walk_seconds: float = 1.0
@export var straight_hit_melee_speed_multiplier: float = 0.2
@export var straight_hit_melee_cooldown_seconds: float = 0.75

var active_attack_mode: MomAttackMode = MomAttackMode.NONE
var attack_windup_timer: float = 0.0
var melee_sequence_active: bool = false
var melee_hit_followup_queued: bool = false
var melee_swing_index: int = 0
var melee_swing_timer: float = 0.0
var ranged_followup_air_lunge_timer: float = 0.0
var current_aim_position: Vector2 = Vector2.ZERO
var aim_indicator: Line2D


func enter() -> void:
	active_attack_mode = MomAttackMode.NONE
	attack_windup_timer = 0.0
	melee_sequence_active = false
	melee_hit_followup_queued = false
	melee_swing_index = 0
	melee_swing_timer = 0.0
	ranged_followup_air_lunge_timer = 0.0
	super.enter()
	_ensure_aim_indicator()
	_set_aim_indicator_visible(false)


func exit() -> void:
	active_attack_mode = MomAttackMode.NONE
	melee_sequence_active = false
	melee_hit_followup_queued = false
	ranged_followup_air_lunge_timer = 0.0
	_set_aim_indicator_visible(false)
	super.exit()


func _update_chase() -> void:
	if _is_winding_up_attack():
		if active_attack_mode == MomAttackMode.SCREAM:
			_move_toward_scream_target()
			return

		if active_attack_mode == MomAttackMode.MELEE_STAGGER_PROJECTILE:
			_move_back_during_melee_followup()
			return

		if active_attack_mode == MomAttackMode.RANGED_JUMP_PROJECTILE:
			_face_fight_target()
			_tilt_jump_toward_target()
			return

		if active_attack_mode == MomAttackMode.STRAIGHT_HIT_MELEE:
			_walk_toward_straight_hit_melee()
			return

		_face_fight_target()
		stop_horizontal()
		return

	if npc == null or fight_target == null:
		return

	if _has_clear_attack_option():
		stop_horizontal()
		return

	var blocking_bystander := _get_movement_blocking_bystander()
	if blocking_bystander != null:
		_move_toward_scream_target()
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

	if ranged_followup_air_lunge_timer > 0.0:
		_continue_ranged_followup_air_lunge(delta)

	attack_cooldown_timer -= delta
	if attack_cooldown_timer > 0.0:
		return

	if fight_target == null or not is_instance_valid(fight_target):
		return

	if _can_start_melee_attack():
		_start_melee_attack()
		return

	if _can_start_projectile_attack():
		_start_projectile_attack()
		return

	if _get_movement_blocking_bystander() != null:
		_start_scream_attack()


func _start_melee_attack() -> void:
	active_attack_mode = MomAttackMode.MELEE
	attack_windup_timer = maxf(melee_windup_seconds, 0.0)
	melee_sequence_active = false
	melee_hit_followup_queued = false
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


func _start_scream_attack() -> void:
	if not scream_enabled:
		return

	active_attack_mode = MomAttackMode.SCREAM
	attack_windup_timer = maxf(scream_charge_seconds, 0.0)
	melee_sequence_active = false
	_set_aim_indicator_visible(false)
	_face_fight_target()
	_move_toward_scream_target()


func _can_start_melee_hit_followup() -> bool:
	return (
		melee_hit_followup_enabled
		and fight_target != null
		and is_instance_valid(fight_target)
		and npc != null
		and npc.is_inside_tree()
	)


func _start_melee_hit_followup() -> void:
	active_attack_mode = MomAttackMode.MELEE_STAGGER_PROJECTILE
	attack_windup_timer = maxf(melee_followup_backstep_seconds, 0.0)
	melee_sequence_active = false
	_set_aim_indicator_visible(true)
	_update_projectile_aim()
	_move_back_during_melee_followup()


func _start_ranged_hit_followup() -> void:
	if (
		not ranged_hit_followup_enabled
		or active_attack_mode != MomAttackMode.NONE
		or fight_target == null
		or not is_instance_valid(fight_target)
		or npc == null
		or not npc.is_inside_tree()
	):
		return

	active_attack_mode = MomAttackMode.RANGED_JUMP_PROJECTILE
	attack_windup_timer = maxf(ranged_followup_delay_seconds, 0.0)
	melee_sequence_active = false
	melee_hit_followup_queued = false
	_set_aim_indicator_visible(true)
	_face_fight_target()
	npc.velocity.y = minf(npc.velocity.y, -absf(ranged_followup_jump_velocity))
	ranged_followup_air_lunge_timer = maxf(ranged_followup_jump_lunge_seconds, ranged_followup_delay_seconds)
	_tilt_jump_toward_target()
	_update_projectile_aim()


func _start_straight_hit_melee_followup() -> void:
	if (
		not straight_hit_melee_followup_enabled
		or active_attack_mode != MomAttackMode.NONE
		or fight_target == null
		or not is_instance_valid(fight_target)
		or npc == null
		or not npc.is_inside_tree()
	):
		return

	active_attack_mode = MomAttackMode.STRAIGHT_HIT_MELEE
	attack_windup_timer = maxf(straight_hit_melee_walk_seconds, 0.0)
	melee_sequence_active = false
	melee_hit_followup_queued = false
	_set_aim_indicator_visible(false)
	_face_fight_target()
	_walk_toward_straight_hit_melee()


func _update_attack_windup(delta: float) -> void:
	if (
		not melee_sequence_active
		and active_attack_mode != MomAttackMode.NONE
		and active_attack_mode != MomAttackMode.SCREAM
		and active_attack_mode != MomAttackMode.MELEE_STAGGER_PROJECTILE
		and active_attack_mode != MomAttackMode.RANGED_JUMP_PROJECTILE
		and active_attack_mode != MomAttackMode.STRAIGHT_HIT_MELEE
		and _get_attack_blocking_bystander_for_mode(active_attack_mode) != null
	):
		_cancel_attack_for_bystander()
		return

	if active_attack_mode == MomAttackMode.MELEE and melee_sequence_active:
		_update_melee_sequence(delta)
		return

	if (
		active_attack_mode == MomAttackMode.PROJECTILE
		or active_attack_mode == MomAttackMode.MELEE_STAGGER_PROJECTILE
		or active_attack_mode == MomAttackMode.RANGED_JUMP_PROJECTILE
	):
		_update_projectile_aim()

	if active_attack_mode == MomAttackMode.RANGED_JUMP_PROJECTILE:
		_tilt_jump_toward_target()
	elif active_attack_mode == MomAttackMode.STRAIGHT_HIT_MELEE:
		_walk_toward_straight_hit_melee()

	attack_windup_timer -= delta
	if attack_windup_timer > 0.0:
		return

	match active_attack_mode:
		MomAttackMode.MELEE:
			_begin_melee_sequence()
		MomAttackMode.PROJECTILE:
			_throw_aimed_projectile(false, ProjectileHitFollowup.RANGED_JUMP)
			attack_cooldown_timer = maxf(projectile_cooldown_seconds, 0.05)
			active_attack_mode = MomAttackMode.NONE
			_set_aim_indicator_visible(false)
		MomAttackMode.SCREAM:
			_do_scream_attack()
			attack_cooldown_timer = maxf(scream_attack_cooldown_seconds, 0.05)
			active_attack_mode = MomAttackMode.NONE
		MomAttackMode.MELEE_STAGGER_PROJECTILE:
			_throw_aimed_projectile(false, ProjectileHitFollowup.RANGED_JUMP)
			attack_cooldown_timer = maxf(melee_followup_projectile_cooldown_seconds, 0.05)
			active_attack_mode = MomAttackMode.NONE
			_set_aim_indicator_visible(false)
		MomAttackMode.RANGED_JUMP_PROJECTILE:
			_throw_aimed_projectile(true, ProjectileHitFollowup.SLOW_MELEE)
			attack_cooldown_timer = maxf(ranged_followup_cooldown_seconds, 0.05)
			active_attack_mode = MomAttackMode.NONE
			_set_aim_indicator_visible(false)
		MomAttackMode.STRAIGHT_HIT_MELEE:
			melee_hit_followup_queued = false
			_do_melee_attack(0.0, true)
			if _try_start_melee_hit_followup():
				return

			attack_cooldown_timer = maxf(straight_hit_melee_cooldown_seconds, 0.05)
			active_attack_mode = MomAttackMode.NONE
			melee_hit_followup_queued = false
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

	if _try_start_melee_hit_followup():
		return

	melee_hit_followup_queued = false
	active_attack_mode = MomAttackMode.NONE
	attack_cooldown_timer = maxf(melee_cooldown_seconds, 0.05)
	_set_aim_indicator_visible(false)


func _try_start_melee_hit_followup() -> bool:
	if not melee_hit_followup_queued:
		return false

	melee_hit_followup_queued = false
	if not _can_start_melee_hit_followup():
		return false

	_start_melee_hit_followup()
	return true


func _get_melee_swing_angle_degrees(index: int) -> float:
	if melee_swing_angles_degrees.is_empty():
		return 0.0

	return melee_swing_angles_degrees[clampi(index, 0, melee_swing_angles_degrees.size() - 1)]


func _do_melee_attack(swing_angle_degrees: float, can_queue_hit_followup: bool = true) -> void:
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
		if victim == null or victim == npc or damaged_victims.has(victim):
			continue

		if not _target_group_is_allowed(victim):
			continue

		damaged_victims.append(victim)
		victim.call("take_damage", melee_damage, npc.global_position, npc, melee_knockout_damage)
		_apply_melee_anger_hit_relief(victim)
		if can_queue_hit_followup and _victim_is_current_target(victim):
			melee_hit_followup_queued = true


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


func _throw_aimed_projectile(
	straight_shot: bool = false,
	projectile_hit_followup: int = ProjectileHitFollowup.RANGED_JUMP
) -> void:
	if fight_target == null or not is_instance_valid(fight_target):
		return

	var projectile := _create_projectile()
	if projectile == null:
		return

	var target_position := current_aim_position
	var spawn_position := _get_projectile_spawn_position(target_position)
	var parent := _get_projectile_parent()
	parent.add_child(projectile)

	if projectile.has_signal("victim_hit"):
		projectile.connect(
			"victim_hit",
			Callable(self, "_on_projectile_victim_hit").bind(projectile_hit_followup),
			CONNECT_ONE_SHOT
		)

	var attack_flight_time := ranged_followup_flight_time if straight_shot else projectile_flight_time
	var attack_arc_height := 0.0 if straight_shot else projectile_arc_height

	if projectile.has_method("launch"):
		projectile.call(
			"launch",
			spawn_position,
			target_position,
			npc,
			projectile_damage,
			attack_flight_time,
			attack_arc_height,
			projectile_lifetime,
			projectile_collision_mask,
			friendly_fire_favor_penalty,
			fight_target,
			_get_anger_drop_for_victim(fight_target),
			projectile_knockout_damage
		)
	else:
		projectile.global_position = spawn_position


func _on_projectile_victim_hit(
	victim: Node,
	intended_target_hit: bool,
	projectile_hit_followup: int
) -> void:
	if projectile_hit_followup == ProjectileHitFollowup.NONE or not intended_target_hit:
		return
	if machine != null and machine.current_state != self:
		return
	if not _victim_is_current_target(victim):
		return

	match projectile_hit_followup:
		ProjectileHitFollowup.RANGED_JUMP:
			_start_ranged_hit_followup()
		ProjectileHitFollowup.SLOW_MELEE:
			_start_straight_hit_melee_followup()


func _apply_melee_anger_hit_relief(victim: Node) -> void:
	if _victim_is_training_target(victim):
		return

	var anger_drop := _get_anger_drop_for_victim(victim)
	if anger_drop <= 0.0:
		return
	if npc == null or not is_instance_valid(npc):
		return
	if victim == null or not is_instance_valid(victim):
		return
	if fight_target != null and is_instance_valid(fight_target) and victim != fight_target:
		return

	var anger_delta := -absf(anger_drop)
	if (
		(victim.is_in_group("npc") or victim.is_in_group("player"))
		and npc.has_method("change_relationship_anger_for")
	):
		npc.call("change_relationship_anger_for", victim, anger_delta, "fight_melee_hit")
		return

	var victim_actor := victim as Node2D
	if machine != null:
		machine.apply_value_delta({"anger": anger_delta}, victim_actor, true)
		return

	if npc.has_method("apply_social_event"):
		npc.call("apply_social_event", {"anger": anger_delta}, victim_actor, false)


func _get_anger_drop_for_victim(victim: Node) -> float:
	if _victim_is_training_target(victim):
		return 0.0

	if victim != null and is_instance_valid(victim) and victim.is_in_group("npc"):
		return maxf(npc_relationship_anger_drop_on_target_hit, 0.0)

	return maxf(anger_drop_on_target_hit, 0.0)


func _victim_is_training_target(victim: Node) -> bool:
	var victim_node := victim as Node2D
	return _target_is_training_target(victim_node)


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


func _victim_is_current_target(victim: Node) -> bool:
	return (
		victim != null
		and is_instance_valid(victim)
		and fight_target != null
		and is_instance_valid(fight_target)
		and victim == fight_target
	)


func _get_target_distance() -> float:
	if npc == null or fight_target == null or not is_instance_valid(fight_target):
		return INF

	return npc.global_position.distance_to(fight_target.global_position)


func _has_clear_attack_option() -> bool:
	return _can_start_melee_attack() or _can_start_projectile_attack()


func _can_start_melee_attack() -> bool:
	if not _target_is_melee_attack_ready():
		return false

	return _get_attack_blocking_bystander_for_mode(MomAttackMode.MELEE) == null


func _can_start_projectile_attack() -> bool:
	if not _target_is_projectile_reachable():
		return false
	if (
		not _target_is_projectile_attack_ready()
		and not (allow_projectile_when_melee_blocked and _target_is_melee_attack_ready())
	):
		return false

	return _get_attack_blocking_bystander_for_mode(MomAttackMode.PROJECTILE) == null


func _get_movement_blocking_bystander() -> Node2D:
	if _has_clear_attack_option():
		return null
	if _target_is_melee_attack_ready():
		var melee_blocker := _get_attack_blocking_bystander_for_mode(MomAttackMode.MELEE)
		if melee_blocker != null:
			return melee_blocker
	if _target_is_projectile_reachable():
		return _get_attack_blocking_bystander_for_mode(MomAttackMode.PROJECTILE)

	return null


func _get_attack_blocking_bystander_for_mode(attack_mode: int) -> Node2D:
	if not avoid_bystanders_before_attack:
		return null
	if npc == null or not npc.is_inside_tree():
		return null
	if fight_target == null or not is_instance_valid(fight_target):
		return null
	if attack_mode == MomAttackMode.MELEE and not _target_is_melee_attack_ready():
		return null
	if attack_mode == MomAttackMode.PROJECTILE and not _target_is_projectile_reachable():
		return null

	var bystander_group := _get_bystander_group_for_target()
	if bystander_group == &"":
		return null

	var closest_bystander: Node2D = null
	var closest_distance_squared := INF
	for candidate in npc.get_tree().get_nodes_in_group(bystander_group):
		var candidate_node := candidate as Node2D
		if not _is_valid_bystander(candidate_node):
			continue
		if not _bystander_blocks_attack_mode(candidate_node, attack_mode):
			continue

		var distance_squared := npc.global_position.distance_squared_to(candidate_node.global_position)
		if distance_squared >= closest_distance_squared:
			continue

		closest_distance_squared = distance_squared
		closest_bystander = candidate_node

	return closest_bystander


func _get_attack_blocking_bystander() -> Node2D:
	return _get_movement_blocking_bystander()


func _get_bystander_group_for_target() -> StringName:
	if fight_target == null or not is_instance_valid(fight_target):
		return &""
	if fight_target.is_in_group("player"):
		return &"npc"
	if fight_target.is_in_group("npc"):
		return &"player"

	return &""


func _is_valid_bystander(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	if candidate == npc or candidate == fight_target:
		return false
	if candidate.is_queued_for_deletion():
		return false

	return true


func _bystander_blocks_attack_mode(candidate: Node2D, attack_mode: int) -> bool:
	if candidate == null:
		return false
	if attack_mode == MomAttackMode.MELEE:
		return npc.global_position.distance_to(candidate.global_position) <= _get_bystander_melee_safe_distance()
	if attack_mode == MomAttackMode.PROJECTILE:
		return _bystander_blocks_projectile_lane(candidate)

	return false


func _get_bystander_melee_safe_distance() -> float:
	return _get_melee_reach_distance() + maxf(bystander_melee_safe_padding, 0.0)


func _target_is_in_attack_window() -> bool:
	return _target_is_melee_attack_ready() or _target_is_projectile_reachable()


func _target_is_melee_attack_ready() -> bool:
	return _get_target_distance() <= _get_melee_reach_distance()


func _target_is_projectile_attack_ready() -> bool:
	var distance := _get_target_distance()
	return distance >= projectile_distance_threshold and distance <= attack_range


func _target_is_projectile_reachable() -> bool:
	var distance := _get_target_distance()
	return distance >= attack_min_range and distance <= attack_range


func _bystander_blocks_projectile_lane(candidate: Node2D) -> bool:
	if bystander_projectile_lane_width <= 0.0:
		return false
	if candidate == null or fight_target == null or not is_instance_valid(fight_target):
		return false

	var from_position := npc.global_position
	var to_position := _get_attack_aim_position(fight_target)
	var shot_vector := to_position - from_position
	var shot_length_squared := shot_vector.length_squared()
	if shot_length_squared <= 0.001:
		return false

	var candidate_offset := candidate.global_position - from_position
	var progress := candidate_offset.dot(shot_vector) / shot_length_squared
	if progress <= 0.0 or progress >= 1.0:
		return false

	var closest_point := from_position + (shot_vector * progress)
	return candidate.global_position.distance_to(closest_point) <= bystander_projectile_lane_width


func _move_toward_scream_target() -> void:
	if npc == null or fight_target == null or not is_instance_valid(fight_target):
		return

	var close_speed := _get_fight_move_speed() * clampf(scream_close_speed_multiplier, 0.0, 1.0)
	var close_distance := maxf(_get_melee_reach_distance() * 0.8, machine.stop_distance)
	move_toward_position(fight_target.global_position, close_speed, close_distance)


func _move_back_during_melee_followup() -> void:
	if npc == null or fight_target == null or not is_instance_valid(fight_target):
		stop_horizontal()
		return

	_face_fight_target()
	var away_direction := signf(npc.global_position.x - fight_target.global_position.x)
	if away_direction == 0.0:
		away_direction = -_get_direction_to_target()

	var backstep_speed := _get_fight_move_speed() * clampf(melee_followup_backstep_speed_multiplier, 0.0, 1.0)
	npc.velocity.x = away_direction * backstep_speed


func _tilt_jump_toward_target() -> void:
	if npc == null or fight_target == null or not is_instance_valid(fight_target):
		stop_horizontal()
		return

	_face_fight_target()
	npc.velocity.x = _get_direction_to_target() * _get_ranged_followup_lunge_speed()


func _continue_ranged_followup_air_lunge(delta: float) -> void:
	ranged_followup_air_lunge_timer = maxf(ranged_followup_air_lunge_timer - delta, 0.0)
	if ranged_followup_air_lunge_timer <= 0.0:
		return

	_tilt_jump_toward_target()


func _get_ranged_followup_lunge_speed() -> float:
	if npc == null or fight_target == null or not is_instance_valid(fight_target):
		return 0.0

	var lunge_seconds := maxf(ranged_followup_jump_lunge_seconds, 0.001)
	var target_distance := absf(fight_target.global_position.x - npc.global_position.x)
	var desired_speed := (
		target_distance
		* clampf(ranged_followup_jump_target_fraction, 0.0, 1.0)
		/ lunge_seconds
	)
	return minf(desired_speed, maxf(ranged_followup_jump_max_horizontal_speed, 0.0))


func _walk_toward_straight_hit_melee() -> void:
	if npc == null or fight_target == null or not is_instance_valid(fight_target):
		stop_horizontal()
		return

	var walk_speed := _get_fight_move_speed() * clampf(straight_hit_melee_speed_multiplier, 0.0, 1.0)
	var stop_distance := maxf(_get_melee_reach_distance() * 0.85, machine.stop_distance)
	move_toward_position(fight_target.global_position, walk_speed, stop_distance)


func _do_scream_attack() -> void:
	if npc == null or not npc.is_inside_tree():
		return

	stop_horizontal()
	_spawn_scream_visual()
	_spawn_scream_move_text()
	for target in _get_scream_targets():
		_apply_scream_flee(target)


func _get_scream_targets() -> Array[Node2D]:
	var targets: Array[Node2D] = []
	if npc == null or not npc.is_inside_tree():
		return targets

	for group_name in [&"npc", &"player"]:
		for candidate in npc.get_tree().get_nodes_in_group(group_name):
			var candidate_node := candidate as Node2D
			if not _is_valid_scream_target(candidate_node):
				continue
			if npc.global_position.distance_to(candidate_node.global_position) > scream_radius:
				continue

			targets.append(candidate_node)

	return targets


func _is_valid_scream_target(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	if candidate == npc or candidate == fight_target:
		return false
	if candidate.is_queued_for_deletion():
		return false
	if not candidate.is_in_group("npc") and not candidate.is_in_group("player"):
		return false

	return true


func _apply_scream_flee(target: Node2D) -> void:
	if target == null or not is_instance_valid(target):
		return

	if target.is_in_group("npc"):
		var target_machine := target.get_node_or_null("NpcStateMachine")
		if target_machine != null and target_machine.has_method("request_state"):
			target_machine.call("request_state", &"Flee", npc, "mom_scream", scream_flee_priority)
		return

	if target.has_method("force_flee_from"):
		target.call("force_flee_from", npc, scream_player_flee_seconds, scream_player_flee_speed)
	elif target.has_method("apply_knockback"):
		target.call("apply_knockback", npc.global_position)


func _spawn_scream_visual() -> void:
	if scream_visual_seconds <= 0.0 or scream_radius <= 0.0:
		return

	var ring := Line2D.new()
	ring.name = "MomScreamRadius"
	ring.default_color = scream_visual_color
	ring.width = maxf(scream_visual_width, 1.0)
	ring.closed = true
	ring.z_index = 30
	ring.position = Vector2.ZERO
	var start_scale := clampf(scream_visual_start_scale, 0.0, 1.0)
	ring.scale = Vector2(start_scale, start_scale)

	var point_count := maxi(scream_visual_point_count, 12)
	for point_index in point_count:
		var angle := (TAU * float(point_index)) / float(point_count)
		ring.add_point(Vector2(cos(angle), sin(angle)) * scream_radius)

	npc.add_child(ring)

	var tween := ring.create_tween()
	tween.tween_property(ring, "scale", Vector2(1.08, 1.08), scream_visual_seconds).from(ring.scale)
	tween.parallel().tween_property(ring, "modulate:a", 0.0, scream_visual_seconds)
	tween.tween_callback(ring.queue_free)


func _spawn_scream_move_text() -> void:
	if npc == null or scream_move_text_seconds <= 0.0 or scream_move_text.is_empty():
		return

	var label := Label.new()
	label.name = "MomScreamMoveText"
	label.text = scream_move_text
	label.modulate = scream_move_text_color
	label.z_index = 31
	label.size = Vector2(96.0, 28.0)
	label.position = scream_move_text_offset
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	npc.add_child(label)

	var tween := label.create_tween()
	tween.tween_property(
		label,
		"position",
		scream_move_text_offset + Vector2(0.0, -absf(scream_move_text_rise)),
		scream_move_text_seconds
	)
	tween.parallel().tween_property(label, "modulate:a", 0.0, scream_move_text_seconds)
	tween.tween_callback(label.queue_free)


func _cancel_attack_for_bystander() -> void:
	active_attack_mode = MomAttackMode.NONE
	melee_sequence_active = false
	attack_windup_timer = 0.0
	attack_cooldown_timer = minf(attack_cooldown_timer, 0.1)
	_set_aim_indicator_visible(false)


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
		if victim_owner == npc:
			return null
		if victim_owner != null and victim_owner.has_method("take_damage"):
			return victim_owner

	if collider.has_method("take_damage"):
		if collider == npc:
			return null
		return collider

	return null
