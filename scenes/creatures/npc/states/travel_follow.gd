class_name NpcStateTravelFollow
extends NpcState

@export var stop_distance: float = 64.0
@export var moving_player_stop_distance: float = 40.0
@export var traversal_component_path: NodePath = NodePath("NpcPlatformTraversal")
@export var show_follow_debug_paths: bool = false
@export_range(2, 8, 1) var debug_breadcrumb_count: int = 2
@export_range(0.05, 0.5, 0.01) var debug_overlay_refresh_seconds: float = 0.1

var _traversal: NpcPlatformTraversal
var _prepared_breadcrumb_recorder: PlayerBreadcrumbRecorder
var _options := NpcPlatformTraversal.TraversalOptions.new()
var _traversal_session_id: int = 0


func enter() -> void:
	super.enter()
	if not _ensure_traversal_component():
		return
	_traversal_session_id = _traversal.acquire(self, &"travel_follow_enter")
	if _traversal_session_id <= 0:
		return
	_sync_traversal_options()
	if (
		_prepared_breadcrumb_recorder != null
		and is_instance_valid(_prepared_breadcrumb_recorder)
	):
		_traversal.set_breadcrumb_provider(
			self,
			_traversal_session_id,
			_prepared_breadcrumb_recorder
		)
	else:
		_prepared_breadcrumb_recorder = null
	var player := _get_player()
	if player != null:
		_traversal.set_target_actor(self, _traversal_session_id, player)


func exit() -> void:
	if _traversal != null and _traversal_session_id > 0:
		_traversal.release(self, _traversal_session_id, &"follow_state_exit")
	_traversal_session_id = 0


func physics_process(delta: float) -> NpcState:
	if not _ensure_traversal_component():
		stop_horizontal()
		return next_state
	if not _traversal.is_owned_by(self, _traversal_session_id):
		return next_state
	var player := _get_player()
	if player == null:
		_traversal.clear_target(self, _traversal_session_id, &"player_unavailable")
		return next_state
	if _traversal.get_target_actor() != player:
		_traversal.set_target_actor(self, _traversal_session_id, player)
	_sync_traversal_options()
	_traversal.physics_update(self, _traversal_session_id, delta, _options)
	var coordinator := npc.get_node_or_null("TravelCompanion") as TravelCompanionComponent
	if coordinator != null and coordinator.can_release_follow_to_idle():
		machine.request_state(&"Idle", null, "companion_caught_up", 60)
	return next_state


func get_player_interaction_block_reason(_actor: Node2D = null) -> String:
	if _traversal != null and _traversal.is_traversal_committed():
		return "npc_travel_transition"
	return ""


func prepare_travel_context(recorder: PlayerBreadcrumbRecorder) -> void:
	_prepared_breadcrumb_recorder = recorder


func get_traversal_session_id() -> int:
	return _traversal_session_id


func owns_traversal() -> bool:
	return (
		_traversal != null
		and _traversal.is_owned_by(self, _traversal_session_id)
	)


func is_traversal_committed() -> bool:
	return _traversal != null and _traversal.is_traversal_committed()


func has_pending_traversal() -> bool:
	return _traversal != null and _traversal.has_pending_traversal()


func can_release_to_idle() -> bool:
	return _traversal != null and _traversal.can_release_target()


func clear_travel_context() -> void:
	_prepared_breadcrumb_recorder = null


func _ensure_traversal_component() -> bool:
	if _traversal != null and is_instance_valid(_traversal):
		return true
	if npc == null:
		return false
	if machine != null:
		_traversal = machine.get_platform_traversal()
	if _traversal == null and traversal_component_path != NodePath():
		_traversal = npc.get_node_or_null(traversal_component_path) as NpcPlatformTraversal
	if _traversal == null:
		return false
	return _traversal.bind_character(npc, machine)


func _get_player() -> Node2D:
	if machine == null or not machine.is_inside_tree():
		return null
	return machine.get_tree().get_first_node_in_group(&"player") as Node2D


func _sync_traversal_options() -> void:
	var desired_stop_distance := stop_distance
	var coordinator := npc.get_node_or_null("TravelCompanion") as TravelCompanionComponent
	if coordinator != null and coordinator.is_player_movement_grace_active():
		desired_stop_distance = minf(stop_distance, moving_player_stop_distance)
	_options.desired_stop_distance = maxf(desired_stop_distance, 0.0)
	_traversal.debug_enabled = show_follow_debug_paths
	_traversal.debug_breadcrumb_count = debug_breadcrumb_count
	_traversal.debug_refresh_seconds = debug_overlay_refresh_seconds
