class_name TravelCompanionComponent
extends Node

const SAFE_FOLLOW_ACTIVATION_STATES := {
	"Idle": true,
}
const TRAVEL_START_PROTECTED_STATES := {
	"Fight": true,
	"LookForMonster": true,
	"Flee": true,
	"Collapse": true,
	"Downed": true,
	"DisabledDead": true,
	"ScriptedHold": true,
}

@export var can_travel_with_player: bool = true
@export var minimum_favor_required: float = 0.0
@export var travel_policy: TravelPolicy

@export_group("Follow Coordination")
@export var follow_start_horizontal_distance: float = 170.0
@export var follow_stop_horizontal_distance: float = 80.0
@export var follow_start_vertical_separation: float = 80.0
@export var follow_stop_vertical_separation: float = 45.0
@export_range(0.05, 1.0, 0.05) var request_retry_seconds: float = 0.25
@export var coordinator_debug_enabled: bool = false

var _npc: CharacterBody2D
var _machine: NpcStateMachine
var _player_ref: WeakRef
var _context_active: bool = false
var _travel_start_cleanup_done: bool = false
var _request_retry_timer: float = 0.0
var _follow_required: bool = false
var _follow_reason: String = "travel_inactive"
var _activation_block_reason: String = ""
var _release_block_reason: String = ""
var _last_horizontal_distance: float = INF
var _last_vertical_separation: float = INF
var _last_traversal_debt: bool = false


func _ready() -> void:
	_npc = get_parent() as CharacterBody2D
	_machine = _npc.get_node_or_null("NpcStateMachine") as NpcStateMachine if _npc != null else null


func _exit_tree() -> void:
	_deactivate_context(false)


func _physics_process(delta: float) -> void:
	_request_retry_timer = maxf(_request_retry_timer - delta, 0.0)
	if not _context_active:
		return
	if not _is_authoritative_active_companion():
		_deactivate_context(false)
		return
	evaluate_follow_need()


func get_unavailable_reason(npc: Node, player: Node) -> String:
	if not can_travel_with_player:
		return "This NPC cannot travel."
	if npc == null or player == null:
		return "Traveler unavailable."
	var machine := npc.get_node_or_null("NpcStateMachine") as NpcStateMachine
	if machine == null or not npc.has_method("get_inventory"):
		return "Traveler is missing movement or inventory support."
	if machine.get_value(&"disabled") >= 1.0 or machine.get_value(&"hp") <= 0.0:
		return "Traveler is not able to leave."
	if String(machine.current_state.name if machine.current_state != null else "") in ["Downed", "DisabledDead"]:
		return "Traveler must recover first."
	if npc.has_method("get_relationship_favor_for"):
		if float(npc.call("get_relationship_favor_for", player, 0.0)) < minimum_favor_required:
			return "More favor is required."
	return ""


func activate_travel_context(player: Node = null, cleanup_previous_activity: bool = true) -> bool:
	_resolve_nodes()
	if _npc == null or _machine == null or _machine.current_state == null:
		return false
	var context_was_active := _context_active
	if player != null and is_instance_valid(player):
		_player_ref = weakref(player)
	_context_active = true
	_request_retry_timer = 0.0
	if cleanup_previous_activity and not _travel_start_cleanup_done:
		_cleanup_previous_activity_once()
	if not context_was_active:
		_prepare_traversal_tracking()
	evaluate_follow_need()
	return true


func deactivate_travel_context(request_normal_planning: bool = true) -> void:
	_deactivate_context(request_normal_planning)


func evaluate_follow_need() -> Dictionary:
	_resolve_nodes()
	var player := _get_player()
	if not _context_active:
		_follow_required = false
		_follow_reason = "travel_inactive"
		return get_debug_snapshot()
	if not _is_authoritative_active_companion():
		_follow_required = false
		_follow_reason = "not_active_companion"
		return get_debug_snapshot()
	if _npc == null or _machine == null or _machine.current_state == null:
		_follow_required = false
		_follow_reason = "companion_not_ready"
		return get_debug_snapshot()
	if player == null:
		_follow_required = false
		_follow_reason = "player_unavailable"
		return get_debug_snapshot()

	_last_horizontal_distance = absf(player.global_position.x - _npc.global_position.x)
	_last_vertical_separation = absf(player.global_position.y - _npc.global_position.y)
	var traversal := _get_traversal()
	_last_traversal_debt = (
		traversal != null
		and traversal.has_pending_traversal()
	)
	var current_name := String(_machine.current_state.name)
	var currently_following := current_name == "TravelFollow"
	var horizontal_threshold := (
		follow_stop_horizontal_distance
		if currently_following
		else follow_start_horizontal_distance
	)
	var vertical_threshold := (
		follow_stop_vertical_separation
		if currently_following
		else follow_start_vertical_separation
	)

	if _last_traversal_debt:
		_follow_required = true
		_follow_reason = "traversal_debt"
	elif _last_vertical_separation > vertical_threshold:
		_follow_required = true
		_follow_reason = "vertical_separation"
	elif _last_horizontal_distance > horizontal_threshold:
		_follow_required = true
		_follow_reason = "horizontal_distance"
	else:
		_follow_required = false
		_follow_reason = "inside_stop_threshold" if currently_following else "inside_start_threshold"

	_activation_block_reason = ""
	_release_block_reason = ""
	if currently_following:
		_evaluate_follow_release(traversal)
	elif _follow_required:
		_evaluate_follow_activation(current_name)
	return get_debug_snapshot()


func is_follow_required() -> bool:
	return _follow_required


func can_release_follow_to_idle() -> bool:
	var traversal := _get_traversal()
	if (
		not _context_active
		or _follow_required
		or _machine == null
		or _machine.current_state == null
		or String(_machine.current_state.name) != "TravelFollow"
	):
		return false
	if _machine.interaction_overlay != null:
		return false
	return traversal != null and traversal.can_release_target()


func get_debug_snapshot() -> Dictionary:
	return {
		"active_companion": _is_authoritative_active_companion(),
		"follow_required": _follow_required,
		"follow_reason": _follow_reason,
		"horizontal_distance": _last_horizontal_distance,
		"vertical_separation": _last_vertical_separation,
		"traversal_debt": _last_traversal_debt,
		"primary_state": (
			String(_machine.current_state.name)
			if _machine != null and _machine.current_state != null
			else ""
		),
		"activation_block_reason": _activation_block_reason,
		"release_block_reason": _release_block_reason,
	}


func _evaluate_follow_activation(current_name: String) -> void:
	if _machine.interaction_overlay != null:
		_activation_block_reason = "interaction_overlay_active"
		return
	if not SAFE_FOLLOW_ACTIVATION_STATES.has(current_name):
		_activation_block_reason = "state_owns_control:%s" % current_name
		return
	if _request_retry_timer > 0.0:
		_activation_block_reason = "request_retry_delay"
		return
	if _machine.request_state(&"TravelFollow", null, _follow_reason, 60):
		_request_retry_timer = maxf(request_retry_seconds, 0.05)
		_debug_event("follow_started")
	else:
		_request_retry_timer = maxf(request_retry_seconds, 0.05)
		_activation_block_reason = _machine.last_state_request_failure_reason


func _evaluate_follow_release(traversal: NpcPlatformTraversal) -> void:
	if _follow_required:
		_release_block_reason = _follow_reason
		return
	if _machine.interaction_overlay != null:
		_release_block_reason = "interaction_overlay_active"
		return
	if traversal == null or not traversal.can_release_target():
		_release_block_reason = "traversal_or_settle_incomplete"
		return
	_release_block_reason = ""


func _cleanup_previous_activity_once() -> void:
	_travel_start_cleanup_done = true
	var current_name := String(_machine.current_state.name)
	if TRAVEL_START_PROTECTED_STATES.has(current_name):
		return
	_machine.cancel_and_clear_active_action_for_override("travel_context_activated")
	if current_name != "Idle":
		_machine.request_state(&"Idle", null, "travel_context_activated", 90)


func _prepare_traversal_tracking() -> void:
	var recorder := get_tree().get_first_node_in_group(
		&"player_breadcrumb_recorder"
	) as PlayerBreadcrumbRecorder
	var follow := _machine.get_state(&"TravelFollow") as NpcStateTravelFollow
	if follow != null:
		follow.prepare_travel_context(recorder)
	var traversal := _get_traversal()
	if traversal == null:
		return
	traversal.reset_for_context(self, &"travel_context_activated")


func _deactivate_context(request_normal_planning: bool) -> void:
	if not _context_active and not _travel_start_cleanup_done:
		return
	_resolve_nodes()
	var traversal := _get_traversal()
	var follow := (
		_machine.get_state(&"TravelFollow") as NpcStateTravelFollow
		if _machine != null
		else null
	)
	_context_active = false
	_travel_start_cleanup_done = false
	_player_ref = null
	_follow_required = false
	_follow_reason = "travel_inactive"
	_request_retry_timer = 0.0
	if (
		request_normal_planning
		and _machine != null
		and _machine.current_state != null
		and String(_machine.current_state.name) == "TravelFollow"
	):
		_machine.request_state(&"Idle", null, "travel_ended", 100)
	if follow != null:
		follow.clear_travel_context()
	if traversal != null and not traversal.has_owner():
		traversal.reset_for_context(self, &"travel_context_ended")
	if (
		request_normal_planning
		and _machine != null
		and (
			_machine.current_state == null
			or String(_machine.current_state.name) != "TravelFollow"
		)
	):
		_machine.resume_ordinary_planning_if_idle()


func _get_traversal() -> NpcPlatformTraversal:
	if _machine != null:
		return _machine.get_platform_traversal()
	return null


func _get_player() -> Node2D:
	if _player_ref != null:
		var cached := _player_ref.get_ref() as Node2D
		if cached != null and is_instance_valid(cached) and cached.is_inside_tree():
			return cached
	var player := get_tree().get_first_node_in_group(&"player") as Node2D
	if player == null:
		var recorder := get_tree().get_first_node_in_group(
			&"player_breadcrumb_recorder"
		) as PlayerBreadcrumbRecorder
		player = recorder.get_parent() as Node2D if recorder != null else null
	if player != null:
		_player_ref = weakref(player)
	return player


func _is_authoritative_active_companion() -> bool:
	if _npc == null:
		return false
	var runtime := get_node_or_null("/root/PlayerRuntime")
	return (
		runtime != null
		and runtime.has_method("is_active_companion")
		and bool(runtime.call("is_active_companion", _npc))
	)


func _resolve_nodes() -> void:
	if _npc == null or not is_instance_valid(_npc):
		_npc = get_parent() as CharacterBody2D
	if _npc != null and (_machine == null or not is_instance_valid(_machine)):
		_machine = _npc.get_node_or_null("NpcStateMachine") as NpcStateMachine


func _debug_event(event_name: String) -> void:
	if not coordinator_debug_enabled or not OS.is_debug_build():
		return
	print("TravelCompanion[%s] %s %s" % [
		_npc.name if _npc != null else "NPC",
		event_name,
		str(get_debug_snapshot()),
	])
