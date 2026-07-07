class_name NpcStateIdle extends NpcState

@export var idle_wander_enabled: bool = true
@export var idle_wander_interval_seconds: float = 5.0
@export var idle_wander_interval_jitter: float = 1.0
@export var idle_wander_min_distance: float = 12.0
@export var idle_wander_max_distance: float = 28.0
@export var idle_wander_home_radius: float = 36.0
@export var idle_wander_arrive_distance: float = 4.0
@export_range(0.0, 1.0, 0.01) var idle_wander_chance: float = 0.85
@export var idle_wander_animation_name: StringName = &"walk"

var home_x: float = 0.0
var wander_target_x: float = 0.0
var wander_timer: float = 0.0
var wander_direction: float = 1.0
var is_wandering: bool = false
var rng := RandomNumberGenerator.new()


func enter() -> void:
	super.enter()
	stop_horizontal()
	if npc == null:
		return

	home_x = npc.global_position.x
	wander_target_x = home_x
	is_wandering = false
	rng.randomize()
	wander_direction = -1.0 if rng.randf() < 0.5 else 1.0
	_reset_wander_timer()


func exit() -> void:
	is_wandering = false
	stop_horizontal()


func physics_process(delta: float) -> NpcState:
	# Idle only decides to wander on a timer; movement frames just finish that small step.
	if not idle_wander_enabled or npc == null:
		stop_horizontal()
		return next_state

	if is_wandering:
		_update_idle_wander_motion()
		return next_state

	stop_horizontal()
	wander_timer -= delta
	if wander_timer > 0.0:
		return next_state

	_maybe_start_idle_wander()
	return next_state


func _maybe_start_idle_wander() -> void:
	_reset_wander_timer()
	if rng.randf() > idle_wander_chance:
		return

	var min_distance := maxf(idle_wander_min_distance, 0.0)
	var max_distance := maxf(idle_wander_max_distance, min_distance)
	var distance := rng.randf_range(min_distance, max_distance)
	var radius := maxf(idle_wander_home_radius, max_distance)

	wander_target_x = clampf(home_x + (wander_direction * distance), home_x - radius, home_x + radius)
	wander_direction *= -1.0

	if absf(wander_target_x - npc.global_position.x) <= idle_wander_arrive_distance:
		return

	is_wandering = true
	if idle_wander_animation_name != &"":
		play_animation(idle_wander_animation_name)


func _update_idle_wander_motion() -> void:
	var target_position := Vector2(wander_target_x, npc.global_position.y)
	var arrived := move_toward_position(
		target_position,
		machine.get_effective_walk_speed(),
		maxf(idle_wander_arrive_distance, 0.0)
	)

	if not arrived:
		return

	is_wandering = false
	stop_horizontal()
	if animation_name != &"":
		play_animation(animation_name)


func _reset_wander_timer() -> void:
	var jitter := maxf(idle_wander_interval_jitter, 0.0)
	wander_timer = maxf(
		idle_wander_interval_seconds + rng.randf_range(-jitter, jitter),
		0.1
	)
