class_name NpcStateInvitePlayer extends NpcState

@export_range(8.0, 160.0, 1.0, "suffix:px") var invitation_distance: float = 42.0
@export_range(0.5, 60.0, 0.1, "suffix:s") var approach_timeout_seconds: float = 20.0
@export_range(0.5, 60.0, 0.1, "suffix:s") var prompt_timeout_seconds: float = 20.0
@export var player_group: StringName = &"player"
@export var end_state_name: StringName = &"Idle"

@export_group("Interrupts")
@export_range(0, 1000, 1) var minimum_emergency_interrupt_priority: int = 90
@export var emergency_interrupt_states: Array[StringName] = [
	&"DisabledDead",
	&"Downed",
	&"Collapse",
	&"Flee",
	&"Fight",
]

var lesson_spot: Node2D
var player: Node2D
var approach_timer: float = 0.0
var prompt_timer: float = 0.0
var invitation_started: bool = false


func enter() -> void:
	super.enter()
	if _magic_lesson_disabled():
		_breadcrumb("npc_invite_player:disabled_enter", _npc_label())
		next_state = get_state(end_state_name)
		stop_horizontal()
		return

	lesson_spot = _resolve_lesson_spot()
	player = _find_player()
	approach_timer = approach_timeout_seconds
	prompt_timer = prompt_timeout_seconds
	invitation_started = false
	stop_horizontal()


func exit() -> void:
	stop_horizontal()
	var prompt_pending := (
		_lesson_spot_has("is_invitation_pending_for")
		and bool(lesson_spot.call("is_invitation_pending_for", npc, player))
	)
	var lesson_active := (
		_lesson_spot_has("is_lesson_active_for")
		and bool(lesson_spot.call("is_lesson_active_for", npc, player))
	)
	if prompt_pending or lesson_active:
		lesson_spot.call("cancel_lesson", &"state_exit")
	if machine != null and machine.get("invitation_spot") == lesson_spot:
		machine.set("invitation_spot", null)


func physics_process(delta: float) -> NpcState:
	if _magic_lesson_disabled():
		_cancel_if_possible(&"debug_disabled")
		return get_state(end_state_name)

	if not _participants_are_valid():
		_cancel_if_possible(&"invalid_participant")
		return get_state(end_state_name)

	if _lesson_spot_has("lesson_is_done_for") and bool(lesson_spot.call("lesson_is_done_for", npc, player)):
		return get_state(end_state_name)

	if _lesson_spot_has("is_lesson_active_for") and bool(lesson_spot.call("is_lesson_active_for", npc, player)):
		_hold_inviter()
		return next_state

	if not invitation_started:
		return _process_approach(delta)

	_hold_inviter()
	prompt_timer -= delta
	if prompt_timer <= 0.0:
		_cancel_if_possible(&"invite_timeout")
		return get_state(end_state_name)

	if _lesson_spot_has("is_invitation_pending_for") and bool(lesson_spot.call("is_invitation_pending_for", npc, player)):
		return next_state

	return get_state(end_state_name)


func can_be_interrupted_by_scheduled_activity(_request_priority: int) -> bool:
	return false


func can_exit_to(new_state: NpcState, request_priority: int) -> bool:
	if new_state == null:
		return false
	if String(new_state.name) == String(end_state_name):
		return true
	if _is_emergency_interrupt_state(StringName(String(new_state.name))):
		return true

	return request_priority >= minimum_emergency_interrupt_priority


func _process_approach(delta: float) -> NpcState:
	if not _lesson_can_start():
		return get_state(end_state_name)

	var distance := absf(player.global_position.x - npc.global_position.x)
	if distance > invitation_distance:
		approach_timer -= delta
		if approach_timer <= 0.0:
			_cancel_if_possible(&"approach_timeout")
			return get_state(end_state_name)

		move_toward_position(player.global_position, machine.walk_speed, invitation_distance)
		return next_state

	_hold_inviter()
	invitation_started = true
	prompt_timer = prompt_timeout_seconds
	if not bool(lesson_spot.call("begin_invitation", npc, player)):
		return get_state(end_state_name)

	return next_state


func _hold_inviter() -> void:
	stop_horizontal()
	if player != null and is_instance_valid(player):
		face_x_direction(player.global_position.x - npc.global_position.x)


func _lesson_can_start() -> bool:
	if not _lesson_spot_has("can_start_lesson"):
		return false

	return bool(lesson_spot.call("can_start_lesson", npc, player))


func _cancel_if_possible(reason: StringName) -> void:
	if _lesson_spot_has("cancel_lesson"):
		lesson_spot.call("cancel_lesson", reason)


func _resolve_lesson_spot() -> Node2D:
	if machine == null:
		return null

	var configured_spot = machine.get("invitation_spot")
	if configured_spot is Node2D and is_instance_valid(configured_spot):
		return configured_spot

	var active_target := machine.get_active_target()
	if active_target != null and active_target.has_method("begin_invitation"):
		return active_target

	return null


func _find_player() -> Node2D:
	if npc == null or not npc.is_inside_tree():
		return null

	return npc.get_tree().get_first_node_in_group(String(player_group)) as Node2D


func _participants_are_valid() -> bool:
	return (
		npc != null
		and is_instance_valid(npc)
		and lesson_spot != null
		and is_instance_valid(lesson_spot)
		and player != null
		and is_instance_valid(player)
	)


func _lesson_spot_has(method_name: StringName) -> bool:
	return lesson_spot != null and is_instance_valid(lesson_spot) and lesson_spot.has_method(method_name)


func _is_emergency_interrupt_state(state_name: StringName) -> bool:
	for emergency_state_name in emergency_interrupt_states:
		if String(emergency_state_name) == String(state_name):
			return true

	return false


func _magic_lesson_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_MAGIC_LESSON_ACTIVITY
	)


func _npc_label() -> String:
	if npc != null and is_instance_valid(npc):
		if npc.has_method("get_npc_location_id"):
			var npc_id := String(npc.call("get_npc_location_id")).strip_edges()
			if not npc_id.is_empty():
				return "%s(%s)" % [npc.name, npc_id]
		return npc.name
	return name


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
