class_name Slime
extends Monster

enum State {
	IDLE,
	ALERT,
	CHASE,
	DEAD
}

@export_group("Senses")
@export_range(24.0, 1600.0, 1.0, "suffix:px") var alert_radius: float = 520.0
@export_range(24.0, 1600.0, 1.0, "suffix:px") var chase_radius: float = 260.0
@export_range(0.1, 30.0, 0.1, "suffix:s") var focus_refresh_seconds: float = 3.0

@export_group("Movement")
@export var gravity: float = 1500.0
@export var idle_ground_speed: float = 20.0
@export var idle_ground_acceleration: float = 90.0
@export var idle_hop_horizontal_speed: float = 55.0
@export var idle_hop_vertical_speed: float = 125.0
@export var idle_hop_interval_seconds: float = 2.1
@export var alert_hop_horizontal_speed: float = 95.0
@export var alert_hop_vertical_speed: float = 185.0
@export var alert_hop_interval_seconds: float = 1.15
@export var chase_hop_horizontal_speed: float = 245.0
@export var chase_hop_vertical_speed: float = 335.0
@export var chase_hop_interval_seconds: float = 0.82

@export_group("Timing")
@export_range(0.0, 1.0, 0.01, "suffix:s") var jump_windup_seconds: float = 0.22
@export_range(0.0, 1.0, 0.01, "suffix:s") var chase_jump_extra_windup_seconds: float = 0.08
@export_range(0.0, 1.0, 0.01, "suffix:s") var landing_recovery_seconds: float = 0.12
@export_range(0.0, 1.0, 0.01, "suffix:s") var state_transition_windup_seconds: float = 0.18
@export_range(0.0, 1.0, 0.01) var hop_timing_jitter_ratio: float = 0.35

@export_group("Hurt")
@export_range(0.0, 2.0, 0.01, "suffix:s") var hurt_stagger_seconds: float = 0.18
@export var hurt_stagger_deceleration: float = 900.0

@export_group("Visual Indicator")
@export var idle_color: Color = Color(0.32, 0.82, 0.46, 1.0)
@export var alert_color: Color = Color(0.96, 0.82, 0.22, 1.0)
@export var chase_color: Color = Color(1.0, 0.36, 0.24, 1.0)
@export var windup_color: Color = Color(0.7, 1.0, 0.7, 1.0)
@export var hurt_color: Color = Color(0.95, 0.95, 1.0, 1.0)
@export var dead_color: Color = Color(0.32, 0.36, 0.34, 0.8)

@export_group("Death Cleanup")
@export_range(0.0, 5.0, 0.05, "suffix:s") var death_fade_delay_seconds: float = 0.55
@export_range(0.05, 5.0, 0.05, "suffix:s") var death_fade_seconds: float = 0.7
@export var death_sink_pixels: float = 14.0

@onready var body_visual: Node2D = get_node_or_null("BodyVisual") as Node2D
@onready var body_polygon: Polygon2D = get_node_or_null("BodyVisual/Body") as Polygon2D
@onready var animation_player: AnimationPlayer = get_node_or_null("AnimationPlayer") as AnimationPlayer
@onready var state_label: Label = get_node_or_null("StateLabel") as Label

var state: State = State.IDLE
var focus_target: Node2D
var focus_refresh_timer: float = 0.0
var hop_timer: float = 0.0
var windup_timer: float = 0.0
var landing_recovery_timer: float = 0.0
var state_transition_timer: float = 0.0
var hurt_stagger_timer: float = 0.0
var pending_jump_velocity: Vector2 = Vector2.ZERO
var idle_direction: float = 1.0
var airborne_from_jump: bool = false
var rng := RandomNumberGenerator.new()
var death_tween: Tween


func _ready() -> void:
	super._ready()
	if progression_kill_reward_id == &"":
		progression_kill_reward_id = &"enemy_kill.slime"
	add_to_group(&"slime")
	rng.seed = Time.get_ticks_usec() + get_instance_id()
	idle_direction = -1.0 if rng.randf() < 0.5 else 1.0
	_set_state(State.IDLE, true)
	hop_timer = _jittered_interval(idle_hop_interval_seconds)


func _physics_process(delta: float) -> void:
	if dead or state == State.DEAD:
		return

	apply_gravity(delta, gravity)
	process_touch_damage(delta)
	_process_hurt_stagger(delta)

	if hurt_stagger_timer <= 0.0:
		_refresh_focus_target(delta)
		_update_state_from_proximity()
		_process_hop_state(delta)

	move_and_slide()


func _refresh_focus_target(delta: float) -> void:
	focus_refresh_timer = maxf(focus_refresh_timer - delta, 0.0)
	if focus_target != null and not _target_is_within_alert_space(focus_target):
		focus_target = null
		focus_refresh_timer = 0.0

	if focus_refresh_timer > 0.0 and focus_target != null and is_valid_target(focus_target):
		return

	focus_refresh_timer = maxf(focus_refresh_seconds, 0.05)
	focus_target = get_closest_target(alert_radius)


func _update_state_from_proximity() -> void:
	if focus_target == null or not is_valid_target(focus_target):
		_set_state(State.IDLE)
		return

	var distance := global_position.distance_to(focus_target.global_position)
	if distance <= chase_radius:
		_set_state(State.CHASE)
	elif distance <= alert_radius:
		_set_state(State.ALERT)
	else:
		_set_state(State.IDLE)


func _process_hop_state(delta: float) -> void:
	if state_transition_timer > 0.0:
		state_transition_timer = maxf(state_transition_timer - delta, 0.0)
		velocity.x = move_toward(velocity.x, 0.0, idle_ground_acceleration * delta)
		_apply_visual_squish(1.08, 0.92, _get_state_color().lerp(windup_color, 0.35))
		return

	if not is_on_floor():
		airborne_from_jump = true
		_restore_visual_shape()
		return

	if airborne_from_jump:
		airborne_from_jump = false
		landing_recovery_timer = maxf(landing_recovery_seconds, 0.0)
		_play_state_animation(&"land")

	if landing_recovery_timer > 0.0:
		landing_recovery_timer = maxf(landing_recovery_timer - delta, 0.0)
		velocity.x = move_toward(velocity.x, 0.0, idle_ground_acceleration * delta)
		_apply_visual_squish(1.1, 0.88, _get_state_color())
		return

	if windup_timer > 0.0:
		windup_timer = maxf(windup_timer - delta, 0.0)
		velocity.x = move_toward(velocity.x, 0.0, idle_ground_acceleration * delta)
		_apply_visual_squish(1.18, 0.78, windup_color)
		if windup_timer <= 0.0:
			_release_pending_jump()
		return

	hop_timer = maxf(hop_timer - delta, 0.0)
	if hop_timer <= 0.0:
		_start_jump_windup()
		return

	_process_ground_idle(delta)


func _process_ground_idle(delta: float) -> void:
	if state != State.IDLE:
		velocity.x = move_toward(velocity.x, 0.0, idle_ground_acceleration * delta)
		_restore_visual_shape()
		return

	if is_on_wall() or rng.randf() < 0.004:
		idle_direction *= -1.0

	velocity.x = move_toward(
		velocity.x,
		idle_ground_speed * idle_direction,
		idle_ground_acceleration * delta
	)
	_restore_visual_shape()


func _start_jump_windup() -> void:
	pending_jump_velocity = _get_jump_velocity_for_state()
	windup_timer = _get_windup_seconds_for_state()
	velocity.x = 0.0
	_play_state_animation(&"windup")


func _release_pending_jump() -> void:
	velocity = pending_jump_velocity
	airborne_from_jump = true
	hop_timer = _jittered_interval(_get_hop_interval_for_state())
	_face_jump_direction(pending_jump_velocity.x)
	_restore_visual_shape()
	_play_state_animation(_get_jump_animation_name_for_state())


func _get_jump_velocity_for_state() -> Vector2:
	var direction := _get_target_direction()
	match state:
		State.ALERT:
			return Vector2(alert_hop_horizontal_speed * direction, -alert_hop_vertical_speed)
		State.CHASE:
			return Vector2(chase_hop_horizontal_speed * direction, -chase_hop_vertical_speed)
		_:
			if is_on_wall() or rng.randf() < 0.2:
				idle_direction *= -1.0
			return Vector2(idle_hop_horizontal_speed * idle_direction, -idle_hop_vertical_speed)


func _get_target_direction() -> float:
	if focus_target == null or not is_instance_valid(focus_target):
		return idle_direction

	var direction := signf(focus_target.global_position.x - global_position.x)
	if is_zero_approx(direction):
		return idle_direction

	idle_direction = direction
	return direction


func _get_hop_interval_for_state() -> float:
	match state:
		State.ALERT:
			return alert_hop_interval_seconds
		State.CHASE:
			return chase_hop_interval_seconds
		_:
			return idle_hop_interval_seconds


func _get_windup_seconds_for_state() -> float:
	var windup := jump_windup_seconds
	if state == State.CHASE:
		windup += chase_jump_extra_windup_seconds

	return maxf(windup, 0.0)


func _jittered_interval(base_seconds: float) -> float:
	var safe_base := maxf(base_seconds, 0.05)
	var jitter := safe_base * clampf(hop_timing_jitter_ratio, 0.0, 1.0)
	return rng.randf_range(safe_base - jitter, safe_base + jitter)


func _set_state(new_state: State, force: bool = false) -> void:
	if not force and state == new_state:
		return

	state = new_state
	if state != State.DEAD:
		state_transition_timer = maxf(state_transition_windup_seconds, 0.0)
		hop_timer = minf(hop_timer, _jittered_interval(_get_hop_interval_for_state()))

	_apply_state_visual()
	_play_state_animation(_get_state_animation_name())


func _target_is_within_alert_space(target: Node2D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	if not is_valid_target(target):
		return false

	return global_position.distance_to(target.global_position) <= alert_radius


func _process_hurt_stagger(delta: float) -> void:
	if hurt_stagger_timer <= 0.0:
		return

	hurt_stagger_timer = maxf(hurt_stagger_timer - delta, 0.0)
	velocity.x = move_toward(velocity.x, 0.0, hurt_stagger_deceleration * delta)
	_apply_visual_squish(0.92, 1.06, hurt_color)

	if hurt_stagger_timer <= 0.0:
		_restore_visual_shape()


func _on_damaged(
	_damage_taken: float,
	damage_source_position: Vector2,
	_damage_source: Node,
	_knockout_damage: float
) -> void:
	hurt_stagger_timer = maxf(hurt_stagger_seconds, 0.0)
	apply_knockback_from(damage_source_position)
	_play_state_animation(&"hurt")


func _on_died() -> void:
	_set_state(State.DEAD, true)
	_apply_visual_squish(1.25, 0.45, dead_color)
	_play_state_animation(&"dead")
	set_physics_process(false)
	_start_death_cleanup()


func _on_touch_damage_dealt(target: Node2D) -> void:
	if target != null and is_instance_valid(target):
		focus_target = target
		focus_refresh_timer = maxf(focus_refresh_seconds, 0.05)


func _start_death_cleanup() -> void:
	if death_tween != null and death_tween.is_valid():
		death_tween.kill()

	if not is_inside_tree():
		queue_free()
		return

	death_tween = create_tween()
	death_tween.tween_interval(maxf(death_fade_delay_seconds, 0.0))
	death_tween.tween_property(self, "modulate", Color(modulate.r, modulate.g, modulate.b, 0.0), maxf(death_fade_seconds, 0.05))
	death_tween.parallel().tween_property(self, "position:y", position.y + death_sink_pixels, maxf(death_fade_seconds, 0.05))
	if body_visual != null:
		death_tween.parallel().tween_property(body_visual, "scale", Vector2(1.35, 0.18), maxf(death_fade_seconds, 0.05))
	death_tween.tween_callback(Callable(self, "queue_free"))


func _face_jump_direction(direction_x: float) -> void:
	if is_zero_approx(direction_x):
		return

	idle_direction = signf(direction_x)


func _get_state_color() -> Color:
	match state:
		State.ALERT:
			return alert_color
		State.CHASE:
			return chase_color
		State.DEAD:
			return dead_color
		_:
			return idle_color


func _apply_state_visual() -> void:
	_restore_visual_shape()
	if state_label != null:
		state_label.text = _get_state_name()


func _restore_visual_shape() -> void:
	_apply_visual_squish(1.0, 1.0, _get_state_color())


func _apply_visual_squish(scale_x: float, scale_y: float, color: Color) -> void:
	if body_visual != null:
		body_visual.scale = Vector2(scale_x, scale_y)
	if body_polygon != null:
		body_polygon.color = color


func _get_state_name() -> String:
	match state:
		State.ALERT:
			return "alert"
		State.CHASE:
			return "chase"
		State.DEAD:
			return "dead"
		_:
			return "idle"


func _get_state_animation_name() -> StringName:
	match state:
		State.ALERT:
			return &"alert"
		State.CHASE:
			return &"chase"
		State.DEAD:
			return &"dead"
		_:
			return &"idle"


func _get_jump_animation_name_for_state() -> StringName:
	return &"big_hop" if state == State.CHASE else &"small_hop"


func _play_state_animation(animation_name: StringName) -> void:
	if animation_player == null or animation_name == &"":
		return
	if not animation_player.has_animation(animation_name):
		return
	if animation_player.current_animation == animation_name:
		return

	animation_player.play(animation_name)
