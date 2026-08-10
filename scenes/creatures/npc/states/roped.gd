class_name NpcStateRoped extends NpcState

## Emitted once per uninterrupted rope session after attached/dragged are synced.
signal rope_reaction_started(session_id: int)

enum RopedPhase {
	REACTION,
	LIGHT_STRUGGLE,
	HARD_STRUGGLE,
	DANGLING,
	HARD_LANDING,
}

const NpcBehaviorIntentModel = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_intent.gd"
)

const ATTACHED_REASON := "rope_attached_by_player"
const FIRST_DRAG_REASON := "rope_first_drag_by_player"
const CONTINUED_DRAG_REASON := "rope_continued_drag_by_player"
const HARD_OVERRIDE_MINIMUM_PRIORITIES := {
	&"Collapse": 95,
	&"Downed": 99,
	&"DisabledDead": 100,
}

@export_group("Ownership")
## Fight requests are normally 94; 95 lets a rope take control from Fight/Flee.
@export_range(0, 1000, 1) var request_priority: int = 95
## Downed starts at 99 and death/disabled at 100.
@export_range(0, 1000, 1) var minimum_interrupt_priority: int = 99

@export_group("Struggle")
@export var struggle_enabled: bool = true
@export_range(0.0, 3.0, 0.05) var struggle_speed_multiplier: float = 1.0
@export_range(0.0, 3.0, 0.05) var dragged_speed_multiplier: float = 1.0
@export_range(0.0, 3000.0, 10.0, "suffix:px/s²") var struggle_acceleration := 800.0
## Prevents rapid direction/facing flips while crossing an endpoint's X position.
@export_range(0.0, 64.0, 0.5, "suffix:px") var direction_switch_deadzone := 6.0
## A short grounded reaction window before voluntary struggle begins.
@export_range(0.0, 3.0, 0.05, "suffix:s") var reaction_delay_seconds := 0.35
@export var reaction_animation_name: StringName = &"idle"
## Dragged/load-bearing is the default hard-struggle condition.
@export var dragged_animation_name: StringName = &"run"
## Idle is a safe stand-in; Mom's airborne controller supplies jump/fall poses.
@export var airborne_dangle_animation_name: StringName = &"idle"

@export_group("Hard Air Drag Landing")
@export var down_on_hard_air_drag_landing: bool = true
## Gravity-compensated acceleration catches horizontal or vertical rope yanks.
@export_range(0.0, 50000.0, 100.0, "suffix:px/s²") var hard_air_drag_acceleration_threshold := 3000.0
@export_range(0.0, 2.0, 0.01, "suffix:s") var minimum_hard_drag_airtime := 0.08
## Existing Downed behavior/recovery owns the result; 1.0 fills its knockout meter.
@export_range(0.01, 1.0, 0.01) var hard_landing_knockout_fraction := 1.0

@export_group("Directed Opinion")
@export var attached_opinion_delta: Dictionary = {}
@export var dragged_opinion_delta: Dictionary = {}
@export var continued_drag_opinion_delta: Dictionary = {}
@export_range(0.1, 60.0, 0.1, "suffix:s") var continued_drag_interval_seconds := 4.0

## These describe the uninterrupted physical rope session, not state entry.
var attached: bool = false
var dragged: bool = false

var _session_serial: int = 0
var _attached_opinion_sent: bool = false
var _first_drag_opinion_sent: bool = false
var _continued_drag_timer: float = 0.0
var _reaction_delay_remaining: float = 0.0
var _request_queued: bool = false
var _idle_request_queued: bool = false
var _initialized: bool = false
var _last_struggle_direction: float = 0.0
## Voluntary movement intent must stay separate from the velocity Rope solved last
## frame. Feeding the solved velocity back as intent makes repeated pulls erase
## the endpoint's weight.
var _struggle_intent_velocity_x: float = 0.0
var _struggle_intent_initialized: bool = false
var _active_struggle_animation: StringName = &""
var _current_roped_phase: int = -1
var _airborne_episode_active: bool = false
var _airborne_episode_seconds: float = 0.0
var _air_motion_sample_valid: bool = false
var _previous_air_motion_velocity: Vector2 = Vector2.ZERO
var _previous_air_motion_dragged: bool = false
var _proposed_motion_sample_valid: bool = false
var _proposed_motion_velocity: Vector2 = Vector2.ZERO
var _proposed_motion_dragged: bool = false
var _peak_air_drag_acceleration: float = 0.0
var _hard_air_drag_latched: bool = false
var _hard_landing_pending: bool = false


func init() -> void:
	if _initialized or npc == null or machine == null:
		return
	_initialized = true

	var rope_callback := Callable(self, "_on_rope_status_changed")
	if (
		npc.has_signal(&"rope_status_changed")
		and not npc.is_connected(&"rope_status_changed", rope_callback)
	):
		npc.connect(&"rope_status_changed", rope_callback)

	var state_callback := Callable(self, "_on_machine_state_changed")
	if not machine.state_changed.is_connected(state_callback):
		machine.state_changed.connect(state_callback)

	_sync_initial_rope_status()
	set_physics_process(attached)


func enter() -> void:
	# Session flags deliberately survive enter/exit so a hard override cannot
	# replay attachment or first-drag opinions.
	begin_enter_without_animation()
	_sync_initial_rope_status()
	_initialize_struggle_direction()
	_initialize_struggle_intent()
	_seed_motion_sample_if_needed()
	_current_roped_phase = -1
	_update_roped_phase()
	_refresh_struggle_animation(true)


func exit() -> void:
	_active_struggle_animation = &""
	_current_roped_phase = -1
	_reset_airborne_episode_tracking()


func physics_process(delta: float) -> NpcState:
	if not attached or not _npc_is_roped():
		if attached:
			_end_rope_session()
		return get_state(&"Idle")

	_sample_pre_state_air_motion(delta)
	var phase := get_roped_phase()
	_update_roped_phase(phase)
	_refresh_struggle_animation()
	match phase:
		RopedPhase.DANGLING:
			# Preserve physical velocity: gravity, inertia, Rope, and rope_weight own air.
			pass
		RopedPhase.REACTION, RopedPhase.HARD_LANDING:
			_apply_passive_grounded_intent()
		_:
			_apply_struggle_movement(delta)
	_capture_proposed_motion_sample()
	return next_state


func can_exit_to(new_state: NpcState, outgoing_priority: int) -> bool:
	if not attached:
		return true
	if new_state != null:
		var new_state_name := StringName(new_state.name)
		if HARD_OVERRIDE_MINIMUM_PRIORITIES.has(new_state_name):
			return outgoing_priority >= int(
				HARD_OVERRIDE_MINIMUM_PRIORITIES[new_state_name]
			)
	return outgoing_priority >= minimum_interrupt_priority


func get_player_interaction_block_reason(_actor: Node2D = null) -> String:
	return "npc_roped" if attached else ""


func can_attempt_break_free() -> bool:
	return (
		attached
		and npc != null
		and bool(npc.get(&"can_break_free_from_rope"))
		and npc.has_method(&"try_break_free_from_rope")
	)


func try_break_free() -> bool:
	if not can_attempt_break_free():
		return false
	return bool(npc.call(&"try_break_free_from_rope"))


## Override these hooks in a specialized Roped state to select behavior
## from anger, fear, personality, or any other NPC stat without changing Rope.
func get_struggle_speed() -> float:
	if machine == null:
		return 0.0
	var dragged_multiplier := dragged_speed_multiplier if dragged else 1.0
	return (
		machine.get_effective_walk_speed()
		* maxf(struggle_speed_multiplier, 0.0)
		* maxf(dragged_multiplier, 0.0)
	)


func get_reaction_delay_seconds() -> float:
	return maxf(reaction_delay_seconds, 0.0)


func get_struggle_animation_name() -> StringName:
	return get_roped_phase_animation_name(get_roped_phase())


func get_roped_phase() -> int:
	if _hard_landing_pending:
		return RopedPhase.HARD_LANDING
	if not is_grounded_for_rope_behavior():
		return RopedPhase.DANGLING
	if _reaction_delay_remaining > 0.0:
		return RopedPhase.REACTION
	if is_struggling_hard():
		return RopedPhase.HARD_STRUGGLE
	return RopedPhase.LIGHT_STRUGGLE


func get_roped_phase_animation_name(phase: int) -> StringName:
	match phase:
		RopedPhase.REACTION:
			return reaction_animation_name
		RopedPhase.HARD_STRUGGLE:
			return dragged_animation_name if dragged_animation_name != &"" else animation_name
		RopedPhase.DANGLING:
			return airborne_dangle_animation_name
		RopedPhase.HARD_LANDING:
			# The real Downed state owns its animation after the handoff.
			return reaction_animation_name
		_:
			return animation_name


func get_roped_phase_animation_fallback(phase: int) -> StringName:
	if phase == RopedPhase.HARD_STRUGGLE:
		return animation_name
	return reaction_animation_name


func is_grounded_for_rope_behavior() -> bool:
	return npc != null and npc.is_on_floor()


func is_struggling_hard() -> bool:
	return dragged


func on_rope_reaction_started() -> void:
	pass


func measure_air_drag_acceleration(
	previous_velocity: Vector2,
	current_velocity: Vector2,
	delta: float
) -> float:
	if delta <= 0.0:
		return 0.0
	var measured_acceleration := (current_velocity - previous_velocity) / delta
	return (measured_acceleration - get_expected_air_gravity_acceleration()).length()


func measure_post_intent_air_acceleration(
	proposed_velocity: Vector2,
	current_velocity: Vector2,
	delta: float
) -> float:
	if delta <= 0.0:
		return 0.0
	# Gravity and Roped's own reaction/struggle intent are already present in the
	# proposed velocity. The remaining same-frame delta is constraint/collision
	# acceleration, so neither is counted twice.
	return (current_velocity - proposed_velocity).length() / delta


func get_expected_air_gravity_acceleration() -> Vector2:
	var gravity_strength := machine.gravity if machine != null else 0.0
	if npc != null:
		var custom_gravity = npc.get(&"gravity")
		if custom_gravity is int or custom_gravity is float:
			gravity_strength = float(custom_gravity)
	return Vector2(0.0, maxf(gravity_strength, 0.0))


func should_down_after_hard_air_drag(
	peak_acceleration: float,
	airborne_seconds: float
) -> bool:
	return (
		down_on_hard_air_drag_landing
		and peak_acceleration >= maxf(hard_air_drag_acceleration_threshold, 0.0)
		and airborne_seconds >= maxf(minimum_hard_drag_airtime, 0.0)
	)


func get_struggle_direction() -> float:
	return _resolve_struggle_direction_from_ropes()


func _physics_process(delta: float) -> void:
	if not _initialized or not attached:
		return

	_try_send_initial_opinions()
	if dragged:
		_continued_drag_timer -= maxf(delta, 0.0)
		if _continued_drag_timer <= 0.0:
			_send_opinion(
				continued_drag_opinion_delta,
				CONTINUED_DRAG_REASON,
				&"continued_drag"
			)
			_reset_continued_drag_timer()
	else:
		_reset_continued_drag_timer()

	_update_reaction_delay(delta)
	if machine != null and machine.is_primary_state(&"Roped"):
		_update_airborne_drag_episode(delta)

	_queue_roped_request(&"rope_reacquire")


func _on_rope_status_changed(is_roped: bool, is_being_dragged: bool) -> void:
	if not is_roped:
		if attached:
			_end_rope_session()
		return

	if not attached:
		_begin_rope_session(is_being_dragged)
	else:
		_set_dragged(is_being_dragged)
	_try_send_initial_opinions()
	_queue_roped_request(&"rope_attached")


func _on_machine_state_changed(
	_new_state_name: StringName,
	_previous_state_name: StringName
) -> void:
	if attached:
		_queue_roped_request(&"rope_reacquire")


func _begin_rope_session(initially_dragged: bool = false) -> void:
	attached = true
	dragged = initially_dragged
	set_physics_process(true)
	_session_serial += 1
	_reaction_delay_remaining = get_reaction_delay_seconds()
	_last_struggle_direction = 0.0
	_initialize_struggle_direction()
	_struggle_intent_initialized = false
	_initialize_struggle_intent()
	_current_roped_phase = -1
	_hard_landing_pending = false
	_reset_airborne_episode_tracking()
	# Capture the pre-solve velocity immediately, including for an attachment that
	# starts in the air. Roped entry is deferred, so resetting this there would
	# discard the launch frame that may contain the only hard yank.
	_seed_motion_sample_if_needed()
	_attached_opinion_sent = false
	_first_drag_opinion_sent = false
	_reset_continued_drag_timer()
	rope_reaction_started.emit(_session_serial)
	on_rope_reaction_started()


func _end_rope_session() -> void:
	attached = false
	dragged = false
	set_physics_process(false)
	_reaction_delay_remaining = 0.0
	_last_struggle_direction = 0.0
	_struggle_intent_velocity_x = 0.0
	_struggle_intent_initialized = false
	_current_roped_phase = -1
	_hard_landing_pending = false
	_reset_airborne_episode_tracking()
	_attached_opinion_sent = false
	_first_drag_opinion_sent = false
	_reset_continued_drag_timer()

	if machine != null and machine.is_primary_state(&"Roped"):
		_queue_idle_after_detach()


func _set_dragged(is_being_dragged: bool) -> void:
	if dragged == is_being_dragged:
		return
	dragged = is_being_dragged
	_reset_continued_drag_timer()
	if machine != null and machine.is_primary_state(&"Roped"):
		_update_roped_phase()
		_refresh_struggle_animation()


func _update_roped_phase(resolved_phase: int = -1) -> void:
	var next_phase := get_roped_phase() if resolved_phase < 0 else resolved_phase
	if next_phase == _current_roped_phase:
		return
	_current_roped_phase = next_phase
	if next_phase in [
		RopedPhase.REACTION,
		RopedPhase.DANGLING,
		RopedPhase.HARD_LANDING,
	]:
		# These phases never inherit a prior rope-solved/yanked velocity as intent.
		_struggle_intent_velocity_x = 0.0
		_struggle_intent_initialized = true


func _apply_passive_grounded_intent() -> void:
	if npc == null:
		return
	_struggle_intent_velocity_x = 0.0
	_struggle_intent_initialized = true
	npc.velocity.x = 0.0


func _update_reaction_delay(delta: float) -> void:
	if _reaction_delay_remaining <= 0.0 or delta <= 0.0:
		return
	# Airborne presentation is dangling; the grounded reaction resumes on landing.
	if not is_grounded_for_rope_behavior():
		return
	_reaction_delay_remaining = maxf(_reaction_delay_remaining - delta, 0.0)
	if _reaction_delay_remaining <= 0.0 and machine != null and machine.is_primary_state(&"Roped"):
		_update_roped_phase()
		_refresh_struggle_animation()


func _update_airborne_drag_episode(delta: float) -> void:
	if npc == null or delta <= 0.0:
		return
	if is_grounded_for_rope_behavior():
		_proposed_motion_sample_valid = false
		_finish_airborne_drag_episode()
		return

	var current_velocity := npc.velocity
	_ensure_airborne_episode_started()

	_airborne_episode_seconds += delta
	if _proposed_motion_sample_valid:
		var acceleration := measure_post_intent_air_acceleration(
			_proposed_motion_velocity,
			current_velocity,
			delta
		)
		_record_air_drag_acceleration(
			acceleration,
			dragged or _proposed_motion_dragged
		)

	_previous_air_motion_velocity = current_velocity
	_previous_air_motion_dragged = dragged
	_air_motion_sample_valid = true
	_proposed_motion_sample_valid = false


func _sample_pre_state_air_motion(delta: float) -> void:
	if npc == null or delta <= 0.0 or is_grounded_for_rope_behavior():
		return
	_ensure_airborne_episode_started()
	if _air_motion_sample_valid:
		var acceleration := measure_air_drag_acceleration(
			_previous_air_motion_velocity,
			npc.velocity,
			delta
		)
		_record_air_drag_acceleration(
			acceleration,
			dragged or _previous_air_motion_dragged
		)
	_previous_air_motion_velocity = npc.velocity
	_previous_air_motion_dragged = dragged
	_air_motion_sample_valid = true


func _capture_proposed_motion_sample() -> void:
	if npc == null:
		_proposed_motion_sample_valid = false
		return
	_proposed_motion_velocity = npc.velocity
	_proposed_motion_dragged = dragged
	_proposed_motion_sample_valid = true


func _ensure_airborne_episode_started() -> void:
	if _airborne_episode_active:
		return
	_airborne_episode_active = true
	_airborne_episode_seconds = 0.0
	_peak_air_drag_acceleration = 0.0
	_hard_air_drag_latched = false
	_update_roped_phase(RopedPhase.DANGLING)
	_refresh_struggle_animation()


func _record_air_drag_acceleration(acceleration: float, qualifies_as_dragged: bool) -> void:
	if not qualifies_as_dragged:
		return
	_peak_air_drag_acceleration = maxf(
		_peak_air_drag_acceleration,
		maxf(acceleration, 0.0)
	)
	if acceleration >= maxf(hard_air_drag_acceleration_threshold, 0.0):
		_hard_air_drag_latched = true


func _finish_airborne_drag_episode() -> void:
	if not _airborne_episode_active:
		# Keep a post-movement grounded baseline so the pre-state sampler can compare
		# the first airborne frame without counting Roped's own authored intent.
		_previous_air_motion_velocity = npc.velocity if npc != null else Vector2.ZERO
		_previous_air_motion_dragged = dragged
		_air_motion_sample_valid = npc != null
		return

	var peak_acceleration := _peak_air_drag_acceleration
	var airborne_seconds := _airborne_episode_seconds
	var hard_landing := (
		_hard_air_drag_latched
		and should_down_after_hard_air_drag(peak_acceleration, airborne_seconds)
	)
	_reset_airborne_episode_tracking()
	if not hard_landing:
		_update_roped_phase()
		_refresh_struggle_animation()
		return

	_hard_landing_pending = true
	_update_roped_phase(RopedPhase.HARD_LANDING)
	_refresh_struggle_animation()
	_apply_hard_landing_knockout()


func _reset_airborne_episode_tracking() -> void:
	_airborne_episode_active = false
	_airborne_episode_seconds = 0.0
	_air_motion_sample_valid = false
	_previous_air_motion_velocity = Vector2.ZERO
	_previous_air_motion_dragged = false
	_proposed_motion_sample_valid = false
	_proposed_motion_velocity = Vector2.ZERO
	_proposed_motion_dragged = false
	_peak_air_drag_acceleration = 0.0
	_hard_air_drag_latched = false


func _seed_motion_sample_if_needed() -> void:
	if npc == null or _air_motion_sample_valid:
		return
	_previous_air_motion_velocity = npc.velocity
	_previous_air_motion_dragged = dragged
	_air_motion_sample_valid = true


func _apply_hard_landing_knockout() -> void:
	if npc == null or machine == null or not attached:
		_hard_landing_pending = false
		return
	var actor := _get_player()
	var max_knockout := 100.0
	var max_value = npc.get(&"max_knockout")
	if max_value is int or max_value is float:
		max_knockout = maxf(float(max_value), 0.0)
	if max_knockout <= 0.0:
		_finish_hard_landing_handoff()
		return
	var current_knockout := machine.get_value(&"knockout", 0.0)
	if npc.has_method(&"get_knockout"):
		current_knockout = maxf(float(npc.call(&"get_knockout")), 0.0)
	var target_knockout := max_knockout * clampf(hard_landing_knockout_fraction, 0.01, 1.0)
	var knockout_amount := maxf(target_knockout - current_knockout, 0.0)

	if knockout_amount > 0.0 and npc.has_method(&"apply_knockout"):
		npc.call(&"apply_knockout", knockout_amount, actor, true)
	elif knockout_amount > 0.0:
		var machine_target := target_knockout
		if machine.clamp_percent_values:
			machine_target = minf(machine_target, 100.0)
		machine.set_value(&"knockout", machine_target, actor, true)

	var committed_knockout := machine.get_value(&"knockout", 0.0)
	if npc.has_method(&"get_knockout"):
		committed_knockout = maxf(float(npc.call(&"get_knockout")), 0.0)
	if committed_knockout > 0.0 and not machine.is_primary_state(&"Downed"):
		machine.request_state(&"Downed", actor, "rope_hard_drag_landing", 99)
	_finish_hard_landing_handoff()


func _finish_hard_landing_handoff() -> void:
	_hard_landing_pending = false
	# The stock SocialNpc transitions synchronously. If a custom fixture is immune,
	# lacks Downed, or rejects the handoff, resume Roped instead of freezing forever.
	if machine != null and machine.is_primary_state(&"Roped"):
		_update_roped_phase()
		_refresh_struggle_animation()


func _apply_struggle_movement(delta: float) -> void:
	if npc == null or delta <= 0.0:
		return

	_initialize_struggle_intent()
	var acceleration_step := maxf(struggle_acceleration, 0.0) * delta
	var direction := get_struggle_direction() if struggle_enabled else 0.0
	if is_zero_approx(direction):
		_struggle_intent_velocity_x = move_toward(
			_struggle_intent_velocity_x,
			0.0,
			acceleration_step
		)
		npc.velocity.x = _struggle_intent_velocity_x
		return

	face_x_direction(direction)
	var target_velocity := direction * maxf(get_struggle_speed(), 0.0)
	_struggle_intent_velocity_x = move_toward(
		_struggle_intent_velocity_x,
		target_velocity,
		acceleration_step
	)
	npc.velocity.x = _struggle_intent_velocity_x


func _initialize_struggle_intent() -> void:
	if _struggle_intent_initialized:
		return
	_struggle_intent_initialized = true
	_struggle_intent_velocity_x = 0.0
	if npc == null:
		return

	# Preserve pre-attachment locomotion only within the NPC's own voluntary
	# speed range. A rope yank may be much faster and must never become intent.
	var voluntary_speed_limit := maxf(get_struggle_speed(), 0.0)
	_struggle_intent_velocity_x = clampf(
		npc.velocity.x,
		-voluntary_speed_limit,
		voluntary_speed_limit
	)


func _resolve_struggle_direction_from_ropes() -> float:
	var ropes := _get_attached_ropes()
	if ropes.is_empty():
		return 0.0

	var candidates: Array[Dictionary] = []
	var has_load_bearing_rope := false
	for rope in ropes:
		var endpoint_offset = _get_rope_horizontal_offset(rope)
		if endpoint_offset == null:
			continue
		var load_bearing := rope.is_load_bearing()
		has_load_bearing_rope = has_load_bearing_rope or load_bearing
		candidates.append({
			"offset": float(endpoint_offset),
			"load_bearing": load_bearing,
			"tension": maxf(rope.get_current_tension(), 0.0),
		})

	if candidates.is_empty():
		return 0.0

	var direction_score := 0.0
	for candidate in candidates:
		if has_load_bearing_rope and not bool(candidate["load_bearing"]):
			continue
		var offset := float(candidate["offset"])
		if absf(offset) <= maxf(direction_switch_deadzone, 0.0):
			continue
		var weight := (
			maxf(float(candidate["tension"]), 0.05)
			if bool(candidate["load_bearing"])
			else 1.0
		)
		direction_score += signf(offset) * weight

	if not is_zero_approx(direction_score):
		_last_struggle_direction = signf(direction_score)
	_initialize_struggle_direction()
	return _last_struggle_direction


func _get_rope_horizontal_offset(rope: Rope):
	if (
		rope == null
		or not is_instance_valid(rope)
		or not rope.active
		or not rope.is_attached_to(npc)
	):
		return null

	var own_visual: Node2D
	var own_body: Node2D
	var other_visual: Node2D
	var other_body: Node2D
	if rope.start_body == npc:
		own_visual = rope.start_visual_point
		own_body = rope.start_body
		other_visual = rope.end_visual_point
		other_body = rope.end_body
	elif rope.end_body == npc:
		own_visual = rope.end_visual_point
		own_body = rope.end_body
		other_visual = rope.start_visual_point
		other_body = rope.start_body
	else:
		return null

	var own_position = _get_endpoint_position(own_visual, own_body)
	var other_position = _get_endpoint_position(other_visual, other_body)
	if own_position == null or other_position == null:
		return null
	return (own_position as Vector2).x - (other_position as Vector2).x


func _get_endpoint_position(visual: Node2D, body: Node2D):
	if _node_is_usable(visual):
		return visual.global_position
	if _node_is_usable(body):
		return body.global_position
	return null


func _get_attached_ropes() -> Array[Rope]:
	var ropes: Array[Rope] = []
	if npc == null or not npc.has_method(&"get_attached_ropes"):
		return ropes
	var attached_rope_values = npc.call(&"get_attached_ropes")
	if not (attached_rope_values is Array):
		return ropes
	for rope_value in attached_rope_values:
		var rope := rope_value as Rope
		if rope != null and is_instance_valid(rope):
			ropes.append(rope)
	return ropes


func _initialize_struggle_direction() -> void:
	if not is_zero_approx(_last_struggle_direction):
		return
	var facing_direction := 1.0
	if npc != null:
		var direction_value = npc.get(&"direction")
		if direction_value is int or direction_value is float:
			facing_direction = signf(float(direction_value))
	_last_struggle_direction = facing_direction if not is_zero_approx(facing_direction) else 1.0


func _refresh_struggle_animation(force: bool = false) -> void:
	var phase := get_roped_phase()
	var requested_animation := get_struggle_animation_name()
	if requested_animation == &"":
		requested_animation = get_roped_phase_animation_fallback(phase)
	if requested_animation == &"":
		return
	if not force and requested_animation == _active_struggle_animation:
		return
	_active_struggle_animation = requested_animation

	var accepted := (
		machine.play_fixed_animation(requested_animation)
		if machine != null
		else false
	)
	if not accepted and machine != null:
		var fallback_animation := get_roped_phase_animation_fallback(phase)
		if fallback_animation != &"" and fallback_animation != requested_animation:
			machine.play_fixed_animation(fallback_animation)


func _node_is_usable(node: Node) -> bool:
	return (
		node != null
		and is_instance_valid(node)
		and not node.is_queued_for_deletion()
	)


func _try_send_initial_opinions() -> void:
	if not attached:
		return
	if not _attached_opinion_sent:
		_attached_opinion_sent = _send_opinion(
			attached_opinion_delta,
			ATTACHED_REASON,
			&"attached"
		)
	if dragged and not _first_drag_opinion_sent:
		_first_drag_opinion_sent = _send_opinion(
			dragged_opinion_delta,
			FIRST_DRAG_REASON,
			&"first_drag"
		)


func _send_opinion(
	opinion_delta: Dictionary,
	reason: String,
	phase: StringName
) -> bool:
	if opinion_delta.is_empty():
		return true
	var player := _get_player()
	if player == null or machine == null:
		return false

	machine.apply_explicit_directed_social_event(
		{},
		opinion_delta,
		player,
		false,
		reason,
		{
			"source": "roped_state",
			"rope_session_id": _session_serial,
			"rope_phase": String(phase),
			"is_being_dragged": dragged,
			"attached_rope_count": _get_attached_rope_count(),
		}
	)
	# A valid batched transaction is one event attempt even when values are
	# clamped or zero; do not retry it every frame.
	return true


func _queue_roped_request(reason: StringName) -> void:
	if (
		_request_queued
		or not attached
		or machine == null
		or not machine.active
		or machine.is_primary_state(&"Roped")
		or _hard_override_is_active()
		or _scripted_control_is_active()
	):
		return
	_request_queued = true
	call_deferred("_request_roped_if_needed", reason)


func _request_roped_if_needed(reason: StringName) -> void:
	_request_queued = false
	if (
		not attached
		or machine == null
		or not machine.active
		or machine.is_primary_state(&"Roped")
		or _hard_override_is_active()
		or _scripted_control_is_active()
		or not machine.can_transition_to_state(&"Roped", request_priority)
	):
		return

	var intent := NpcBehaviorIntentModel.create(
		&"Roped",
		&"Roped",
		NpcBehaviorIntentModel.SOURCE_EMERGENCY,
		String(reason),
		request_priority
	)
	intent.reason_code = reason
	intent.feedback_text = "Roped"
	intent.metadata = {"rope_session_id": _session_serial}
	machine.request_behavior_intent(intent, _get_player())


func _queue_idle_after_detach() -> void:
	if _idle_request_queued:
		return
	_idle_request_queued = true
	call_deferred("_request_idle_after_detach")


func _request_idle_after_detach() -> void:
	_idle_request_queued = false
	if (
		attached
		or machine == null
		or not machine.active
		or not machine.is_primary_state(&"Roped")
	):
		return
	machine.request_state(&"Idle", null, "rope_detached", 0)


func _hard_override_is_active() -> bool:
	if machine == null or machine.current_state == null:
		return false
	return HARD_OVERRIDE_MINIMUM_PRIORITIES.has(
		StringName(machine.current_state.name)
	)


func _scripted_control_is_active() -> bool:
	return (
		machine != null
		and machine.has_method(&"has_scripted_control_claim")
		and bool(machine.call(&"has_scripted_control_claim"))
	)


func _sync_initial_rope_status() -> void:
	if npc == null or not npc.has_method(&"is_roped"):
		return
	_on_rope_status_changed(
		bool(npc.call(&"is_roped")),
		bool(npc.call(&"is_being_dragged_by_rope"))
			if npc.has_method(&"is_being_dragged_by_rope")
			else false
	)


func _npc_is_roped() -> bool:
	return (
		npc != null
		and npc.has_method(&"is_roped")
		and bool(npc.call(&"is_roped"))
	)


func _get_player() -> Node2D:
	if machine == null or not machine.is_inside_tree():
		return null
	return machine.get_tree().get_first_node_in_group(&"player") as Node2D


func _get_attached_rope_count() -> int:
	if npc == null or not npc.has_method(&"get_attached_ropes"):
		return 0
	var ropes = npc.call(&"get_attached_ropes")
	return ropes.size() if ropes is Array else 0


func _reset_continued_drag_timer() -> void:
	_continued_drag_timer = maxf(continued_drag_interval_seconds, 0.1)
