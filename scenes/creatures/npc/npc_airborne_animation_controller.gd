class_name NpcAirborneAnimationController extends NpcAnimationController

@export_group("Airborne Animation")
@export var airborne_animation_enabled: bool = true
@export var airborne_animation_name: StringName = &"jump_fall"
@export var grounded_fallback_animation_name: StringName = &"idle"
@export_range(0.0, 100.0, 0.5, "suffix:px/s") var activation_velocity_threshold: float = 2.0
@export_range(1.0, 3000.0, 1.0, "suffix:px/s") var minimum_jump_speed_reference: float = 180.0
@export_range(1.0, 3000.0, 1.0, "suffix:px/s") var default_fall_speed_reference: float = 1000.0
@export var falling_requires_prior_ground_contact: bool = true

var _airborne_override_active: bool = false
var _resume_animation_name: StringName = &""
var _rise_speed_reference: float = 1.0
var _fall_speed_reference: float = 1.0
var _previous_vertical_velocity: float = 0.0
var _has_seen_ground: bool = false


func _ready() -> void:
	# The state machine owns movement at the default priority. Reading its result
	# afterward keeps the visual overlay independent from every individual state.
	process_physics_priority = 1
	super()


func _physics_process(_delta: float) -> void:
	_resolve_nodes()
	var body := npc as CharacterBody2D
	if not airborne_animation_enabled or body == null or animation_player == null:
		if _airborne_override_active:
			_finish_airborne_override()
		return

	var is_grounded := body.is_on_floor()
	if is_grounded:
		_has_seen_ground = true

	if _airborne_override_active:
		if is_grounded:
			_finish_airborne_override()
			return
		if (
			body.velocity.y < -activation_velocity_threshold
			and _previous_vertical_velocity >= -activation_velocity_threshold
		):
			_capture_jump_speed(body.velocity.y)
		_seek_airborne_pose(body.velocity.y)
		_previous_vertical_velocity = body.velocity.y
		return

	if (
		not is_grounded
		and absf(body.velocity.y) > activation_velocity_threshold
		and (
			body.velocity.y < 0.0
			or _has_seen_ground
			or not falling_requires_prior_ground_contact
		)
	):
		_begin_airborne_override(body.velocity.y)


func request_animation(requested_name: StringName, required: bool = true) -> bool:
	if not _airborne_override_active:
		return super(requested_name, required)
	if requested_name == &"":
		return false

	_resolve_nodes()
	if animation_player == null:
		if required:
			_warn_missing_animation_player_once(requested_name)
		return false

	var resolved_name := resolve_animation_name(requested_name)
	if resolved_name == &"":
		if required:
			_warn_missing_animation_once(requested_name)
		return false
	if resolved_name != airborne_animation_name:
		# State changes are still accepted in the air; only their visual playback is
		# deferred so landing resumes the animation belonging to the latest state.
		_resume_animation_name = resolved_name
	return true


func is_airborne_animation_active() -> bool:
	return _airborne_override_active


func _begin_airborne_override(vertical_velocity: float) -> void:
	if animation_player == null or not animation_player.has_animation(airborne_animation_name):
		return

	var current_animation := animation_player.current_animation
	if current_animation == &"":
		current_animation = animation_player.assigned_animation
	if current_animation != &"" and current_animation != airborne_animation_name:
		_resume_animation_name = current_animation

	_airborne_override_active = true
	_previous_vertical_velocity = vertical_velocity
	if vertical_velocity < -activation_velocity_threshold:
		_capture_jump_speed(vertical_velocity)
	else:
		_rise_speed_reference = minimum_jump_speed_reference
		_fall_speed_reference = default_fall_speed_reference

	animation_player.play(airborne_animation_name)
	animation_player.pause()
	_seek_airborne_pose(vertical_velocity)


func _capture_jump_speed(vertical_velocity: float) -> void:
	_rise_speed_reference = maxf(absf(vertical_velocity), minimum_jump_speed_reference)
	# A normal ballistic jump lands near its takeoff speed. Using that captured
	# speed lets small hit hops and large traversal jumps use all three fall poses.
	_fall_speed_reference = _rise_speed_reference


func _seek_airborne_pose(vertical_velocity: float) -> void:
	if not _airborne_override_active or animation_player == null:
		return
	var animation := animation_player.get_animation(airborne_animation_name)
	if animation == null:
		return

	var animation_length := maxf(animation.length, 0.001)
	var apex_position := animation_length * 0.5
	var animation_position: float
	if vertical_velocity < 0.0:
		var rise_progress := clampf(
			inverse_lerp(-_rise_speed_reference, 0.0, vertical_velocity),
			0.0,
			1.0
		)
		animation_position = lerpf(0.0, apex_position, rise_progress)
	else:
		var fall_progress := clampf(
			inverse_lerp(0.0, _fall_speed_reference, vertical_velocity),
			0.0,
			1.0
		)
		animation_position = lerpf(apex_position, animation_length, fall_progress)

	# Seeking exactly to a clip's end can resolve to its post-animation state.
	animation_player.seek(minf(animation_position, animation_length - 0.0001), true)


func _finish_airborne_override() -> void:
	_airborne_override_active = false
	_previous_vertical_velocity = 0.0
	if animation_player == null:
		_resume_animation_name = &""
		return

	var resume_name := _resume_animation_name
	_resume_animation_name = &""
	if resume_name != &"" and animation_player.has_animation(resume_name):
		animation_player.play(resume_name)
		return
	var fallback_name := resolve_animation_name(grounded_fallback_animation_name)
	if fallback_name != &"" and fallback_name != airborne_animation_name:
		animation_player.play(fallback_name)
		return
	animation_player.stop()
