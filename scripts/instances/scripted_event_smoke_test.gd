extends Marker2D

const EVENT_REASON: StringName = &"scripted_event_smoke_test"
const RUNTIME_CHECK_ARGUMENT := "--scripted-event-smoke-test"
const INPUT_ACTION: StringName = &"debug_scripted_event_smoke"

enum Phase {
	IDLE,
	MOVING,
	PRESENTING,
}

@export var enable_in_release_build: bool = false
@export_range(1.0, 30.0, 0.1, "suffix:s") var movement_timeout_seconds := 15.0
@export_range(0.0, 64.0, 0.5, "suffix:px") var arrival_tolerance := 16.0

var _phase := Phase.IDLE
var _running := false
var _cleanup_done := true
var _accepting_scripted_commands := false
var _runtime_check_mode := false
var _world_lock_token := 0
var _npc_claim_token := 0
var _movement_elapsed := 0.0
var _presentation_started_usec := 0
var _presentation_elapsed := 0.0
var _saw_movement := false
var _saw_walk_animation := false
var _saw_talk_animation := false

var _gameplay_flow: Node
var _world_time: Node
var _mom: Node2D
var _player: Node2D
var _machine: Node
var _animation_player: AnimationPlayer
var _presentation_timer: Timer
var _mom_start_position := Vector2.ZERO
var _world_hours_at_start := 0.0
var _player_hunger_at_start := 0.0
var _player_sleep_at_start := 0.0
var _mom_hunger_at_start := 0.0
var _mom_sleep_at_start := 0.0
var _mom_passive_elapsed_at_start := 0.0


func _ready() -> void:
	_runtime_check_mode = OS.get_cmdline_user_args().has(RUNTIME_CHECK_ARGUMENT)
	var enabled := OS.is_debug_build() or enable_in_release_build or _runtime_check_mode
	if not enabled:
		set_process(false)
		set_process_unhandled_input(false)
		return

	_presentation_timer = Timer.new()
	_presentation_timer.name = "PresentationTimer"
	_presentation_timer.one_shot = true
	_presentation_timer.wait_time = 5.0
	_presentation_timer.ignore_time_scale = true
	add_child(_presentation_timer)
	_presentation_timer.timeout.connect(_on_presentation_timeout)
	if _runtime_check_mode:
		call_deferred("_start_runtime_check")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(INPUT_ACTION):
		start_event()
		get_viewport().set_input_as_handled()


func start_event() -> bool:
	if _running:
		_print_aborted("already_running", _world_lock_token, _npc_claim_token)
		return false
	if not _resolve_dependencies():
		_print_aborted("required_node_missing", 0, 0)
		_quit_runtime_check(1)
		return false

	var existing_claim: Dictionary = _gameplay_flow.call("get_npc_control_claim", _mom)
	if not existing_claim.is_empty():
		var owner_ref := existing_claim.get("owner") as WeakRef
		var owner: Object = owner_ref.get_ref() if owner_ref != null else null
		var reason := "mom_already_claimed" if owner != self else "stale_own_claim"
		_print_aborted(reason, 0, int(existing_claim.get("token_id", 0)))
		_quit_runtime_check(1)
		return false

	_running = true
	_cleanup_done = false
	_accepting_scripted_commands = false
	_phase = Phase.IDLE
	_reset_observations()

	_world_lock_token = int(_gameplay_flow.call(
		"acquire_world_progression_lock", self, EVENT_REASON
	))
	if _world_lock_token == 0:
		_abort_event("world_lock_rejected")
		return false

	_npc_claim_token = int(_gameplay_flow.call(
		"acquire_npc_control_claim", self, _mom, EVENT_REASON, false
	))
	if _npc_claim_token == 0:
		_abort_event("npc_claim_rejected")
		return false

	_capture_progression_baseline()
	_accepting_scripted_commands = true
	print("Scripted event smoke: Event started world_lock=%d npc_claim=%d" % [
		_world_lock_token, _npc_claim_token,
	])
	var movement_accepted := bool(_machine.call(
		"request_scripted_state",
		_npc_claim_token,
		&"MoveToTarget",
		self,
		&"ScriptedHold",
		EVENT_REASON
	))
	if not movement_accepted:
		print("Scripted event smoke: Movement rejected world_lock=%d npc_claim=%d" % [
			_world_lock_token, _npc_claim_token,
		])
		_abort_event("movement_rejected")
		return false

	_phase = Phase.MOVING
	_mom_start_position = _mom.global_position
	print("Scripted event smoke: Movement accepted world_lock=%d npc_claim=%d" % [
		_world_lock_token, _npc_claim_token,
	])
	return true


func _process(delta: float) -> void:
	if not _running:
		return
	var failure := _validate_live_invariants()
	if not failure.is_empty():
		_abort_event(failure)
		return

	if _phase == Phase.MOVING:
		_update_movement_phase(delta)
	elif _phase == Phase.PRESENTING:
		_update_presentation_phase()


func _update_movement_phase(delta: float) -> void:
	_movement_elapsed += delta
	_saw_movement = _saw_movement or _mom.global_position.distance_to(_mom_start_position) > 1.0
	_saw_walk_animation = _saw_walk_animation or _current_animation() in [&"walk", &"walk_1"]
	var state_name := _current_state_name()
	if state_name == &"MoveToTarget":
		if _movement_elapsed > movement_timeout_seconds:
			_abort_event("movement_timeout")
		return
	if state_name != &"ScriptedHold":
		_abort_event("scripted_state_replaced")
		return
	if absf(_mom.global_position.x - global_position.x) > arrival_tolerance:
		_abort_event("arrival_outside_marker")
		return

	print("Scripted event smoke: Arrival confirmed world_lock=%d npc_claim=%d" % [
		_world_lock_token, _npc_claim_token,
	])
	if not _issue_presentation_commands():
		_abort_event("presentation_command_rejected")
		return
	_phase = Phase.PRESENTING
	_presentation_started_usec = Time.get_ticks_usec()
	_presentation_timer.start(5.0)
	print("Scripted event smoke: Presentation phase started world_lock=%d npc_claim=%d" % [
		_world_lock_token, _npc_claim_token,
	])


func _update_presentation_phase() -> void:
	if _current_state_name() != &"ScriptedHold":
		_abort_event("scripted_hold_replaced")
		return
	if StringName(_machine.call("get_scripted_hold_animation")) != &"talk":
		_abort_event("talk_presentation_replaced")


func _issue_presentation_commands() -> bool:
	if not _accepting_scripted_commands or not _owns_npc_claim(_npc_claim_token):
		return false
	var facing_accepted := bool(
		_machine.call("set_scripted_facing_target", _npc_claim_token, _player)
	)
	var animation_accepted := bool(
		_machine.call("set_scripted_hold_animation", _npc_claim_token, &"talk")
	)
	_saw_talk_animation = animation_accepted
	return facing_accepted and animation_accepted


func _on_presentation_timeout() -> void:
	if not _running or _phase != Phase.PRESENTING:
		return
	_presentation_elapsed = float(Time.get_ticks_usec() - _presentation_started_usec) / 1000000.0
	if _presentation_elapsed < 4.75 or _presentation_elapsed > 5.5:
		_abort_event("presentation_duration_invalid")
		return
	_complete_event()


func _complete_event() -> void:
	var world_token := _world_lock_token
	var claim_token := _npc_claim_token
	_cleanup_event()
	var failure := _validate_completion(world_token, claim_token)
	if not failure.is_empty():
		_print_aborted(failure, world_token, claim_token)
		_quit_runtime_check(1)
		return
	print("Scripted event smoke: Event completed world_lock=%d npc_claim=%d" % [
		world_token, claim_token,
	])
	_quit_runtime_check(0)


func _abort_event(reason: String) -> void:
	var world_token := _world_lock_token
	var claim_token := _npc_claim_token
	_cleanup_event()
	_print_aborted(reason, world_token, claim_token)
	_quit_runtime_check(1)


func _cleanup_event() -> void:
	if _cleanup_done:
		return
	_cleanup_done = true
	if _presentation_timer != null:
		_presentation_timer.stop()
	_accepting_scripted_commands = false

	if _machine != null and is_instance_valid(_machine) and _owns_npc_claim(_npc_claim_token):
		_machine.call("set_scripted_hold_animation", _npc_claim_token, &"idle")
		_machine.call("set_scripted_facing_target", _npc_claim_token, null)
	if _owns_npc_claim(_npc_claim_token):
		_gameplay_flow.call("release_npc_control_claim", _npc_claim_token, self)
	if _owns_world_lock(_world_lock_token):
		_gameplay_flow.call("release_world_progression_lock", _world_lock_token, self)

	_world_lock_token = 0
	_npc_claim_token = 0
	_phase = Phase.IDLE
	_running = false


func _validate_live_invariants() -> String:
	if get_tree().paused:
		return "scene_tree_paused"
	if not _node_is_live(_mom):
		return "mom_disappeared"
	if not _node_is_live(_player):
		return "player_disappeared"
	if not is_inside_tree() or is_queued_for_deletion():
		return "destination_disappeared"
	if not _owns_world_lock(_world_lock_token):
		return "world_lock_lost"
	if not _owns_npc_claim(_npc_claim_token):
		return "npc_claim_lost"
	if not _player.is_physics_processing():
		return "player_physics_stopped"
	if not is_equal_approx(float(_world_time.call("get_total_hours")), _world_hours_at_start):
		return "world_time_advanced"
	if not is_equal_approx(float(_player.get("hunger")), _player_hunger_at_start):
		return "player_hunger_advanced"
	if not is_equal_approx(float(_player.get("sleep_need")), _player_sleep_at_start):
		return "player_sleep_advanced"
	if not is_equal_approx(float(_machine.call("get_value", &"hunger")), _mom_hunger_at_start):
		return "mom_hunger_advanced"
	if not is_equal_approx(float(_machine.call("get_value", &"sleep_need")), _mom_sleep_at_start):
		return "mom_sleep_advanced"
	if not is_equal_approx(
		float(_machine.get("passive_need_elapsed_seconds")), _mom_passive_elapsed_at_start
	):
		return "mom_passive_timer_advanced"
	return ""


func _validate_completion(world_token: int, claim_token: int) -> String:
	if not _saw_movement:
		return "runtime_check_no_movement"
	if not _saw_walk_animation:
		return "runtime_check_no_walk_animation"
	if not _saw_talk_animation:
		return "runtime_check_no_talk_animation"
	if _presentation_elapsed < 4.75 or _presentation_elapsed > 5.5:
		return "runtime_check_bad_duration"
	if _node_is_live(_mom) and _current_state_name() != &"Idle":
		return "runtime_check_mom_not_idle"
	if _node_is_live(_mom) and _gameplay_flow.call("is_npc_control_claimed", _mom):
		return "runtime_check_claim_not_released"
	if _owns_npc_claim(claim_token):
		return "runtime_check_claim_token_not_released"
	if _owns_world_lock(world_token):
		return "runtime_check_world_token_not_released"
	if get_tree().paused or not _node_is_live(_player) or not _player.is_physics_processing():
		return "runtime_check_player_physics_inactive"
	return ""


func _resolve_dependencies() -> bool:
	_gameplay_flow = get_node_or_null("/root/GameplayFlow")
	_world_time = get_node_or_null("/root/WorldTime")
	var locations := get_node_or_null("/root/NpcLocations")
	if _gameplay_flow == null or _world_time == null or locations == null:
		return false
	if not locations.has_method("get_live_npc"):
		return false
	_mom = locations.call("get_live_npc", "mom") as Node2D
	if not _node_is_live(_mom):
		for candidate in get_tree().get_nodes_in_group(&"npc"):
			if candidate.has_method("get_npc_location_id"):
				if StringName(candidate.call("get_npc_location_id")) == &"mom":
					_mom = candidate as Node2D
					break
	_player = get_tree().get_first_node_in_group(&"player") as Node2D
	if not _node_is_live(_mom) or not _node_is_live(_player):
		return false
	_machine = _mom.get_node_or_null("NpcStateMachine")
	_animation_player = _mom.get_node_or_null("AnimationPlayer") as AnimationPlayer
	return (
		_machine != null
		and _animation_player != null
		and _gameplay_flow.has_method("acquire_world_progression_lock")
		and _gameplay_flow.has_method("acquire_npc_control_claim")
		and _machine.has_method("request_scripted_state")
		and _machine.has_method("set_scripted_facing_target")
		and _machine.has_method("set_scripted_hold_animation")
		and _machine.has_method("get_scripted_hold_animation")
	)


func _capture_progression_baseline() -> void:
	_world_hours_at_start = float(_world_time.call("get_total_hours"))
	_player_hunger_at_start = float(_player.get("hunger"))
	_player_sleep_at_start = float(_player.get("sleep_need"))
	_mom_hunger_at_start = float(_machine.call("get_value", &"hunger"))
	_mom_sleep_at_start = float(_machine.call("get_value", &"sleep_need"))
	_mom_passive_elapsed_at_start = float(_machine.get("passive_need_elapsed_seconds"))


func _owns_world_lock(token: int) -> bool:
	if token == 0 or _gameplay_flow == null or not is_instance_valid(_gameplay_flow):
		return false
	for lock_data in _gameplay_flow.call("get_world_progression_locks"):
		if int(lock_data.get("token_id", 0)) != token:
			continue
		var owner_ref := lock_data.get("owner") as WeakRef
		return owner_ref != null and owner_ref.get_ref() == self
	return false


func _owns_npc_claim(token: int) -> bool:
	if (
		token == 0
		or _mom == null
		or not is_instance_valid(_mom)
		or _gameplay_flow == null
		or not is_instance_valid(_gameplay_flow)
	):
		return false
	var claim: Dictionary = _gameplay_flow.call("get_npc_control_claim", _mom)
	if int(claim.get("token_id", 0)) != token:
		return false
	var owner_ref := claim.get("owner") as WeakRef
	return owner_ref != null and owner_ref.get_ref() == self


func _current_state_name() -> StringName:
	if _machine == null or not is_instance_valid(_machine):
		return &""
	var state := _machine.get("current_state") as Node
	return StringName(state.name) if state != null else &""


func _current_animation() -> StringName:
	if _animation_player == null or not is_instance_valid(_animation_player):
		return &""
	return StringName(_animation_player.current_animation)


func _node_is_live(node: Node) -> bool:
	return (
		node != null
		and is_instance_valid(node)
		and node.is_inside_tree()
		and not node.is_queued_for_deletion()
	)


func _reset_observations() -> void:
	_movement_elapsed = 0.0
	_presentation_started_usec = 0
	_presentation_elapsed = 0.0
	_saw_movement = false
	_saw_walk_animation = false
	_saw_talk_animation = false


func _print_aborted(reason: String, world_token: int, claim_token: int) -> void:
	print("Scripted event smoke: Event aborted reason=%s world_lock=%d npc_claim=%d" % [
		reason, world_token, claim_token,
	])


func _start_runtime_check() -> void:
	await get_tree().process_frame
	start_event()


func _quit_runtime_check(exit_code: int) -> void:
	if _runtime_check_mode:
		get_tree().quit(exit_code)


func _exit_tree() -> void:
	if _running:
		var world_token := _world_lock_token
		var claim_token := _npc_claim_token
		_cleanup_event()
		_print_aborted("event_node_exited", world_token, claim_token)
