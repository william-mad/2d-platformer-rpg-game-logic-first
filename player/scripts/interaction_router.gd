class_name InteractionRouter extends Node

signal focused_interactable_changed(previous: Node, current: Node)
signal interaction_dispatched(interactable: Node, consumed: bool)

@export var enabled: bool = true
@export var interaction_action: StringName = &"up"
@export_range(0.05, 1.0, 0.05, "suffix:s") var focus_refresh_seconds: float = 0.15
@export_range(0.0, 128.0, 1.0, "suffix:px") var focus_switch_distance_margin: float = 16.0

var _actor: Node
var _candidates: Dictionary = {}
var _focused_interactable: WeakRef
var _refresh_timer: float = 0.0
var _last_block_reason: StringName = &""
var _last_interaction_consumed: bool = false
var _last_interactable: WeakRef
var _interaction_action_pressed: bool = false


func _ready() -> void:
	_actor = get_parent()
	set_process(false)


func _process(delta: float) -> void:
	if (
		_interaction_action_pressed
		and interaction_action != &""
		and InputMap.has_action(interaction_action)
		and not Input.is_action_pressed(interaction_action)
	):
		_interaction_action_pressed = false
	if _candidates.is_empty():
		set_process(false)
		return
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = maxf(focus_refresh_seconds, 0.05)
	refresh_focus()


func set_interaction_enabled(should_enable: bool) -> void:
	enabled = should_enable
	if not enabled:
		_interaction_action_pressed = false
		_set_focused_interactable(null)
		set_process(false)
	else:
		set_process(not _candidates.is_empty())
		refresh_focus()


func register_candidate(candidate: Node) -> bool:
	if not is_inside_tree() or not _candidate_has_contract(candidate):
		return false
	var candidate_id := int(candidate.get_instance_id())
	var existing_ref := _candidates.get(candidate_id) as WeakRef
	if existing_ref != null and existing_ref.get_ref() == candidate:
		return true
	_candidates[candidate_id] = weakref(candidate)
	_refresh_timer = 0.0
	set_process(enabled)
	refresh_focus()
	return true


func unregister_candidate(candidate: Node) -> void:
	if candidate == null:
		return
	var candidate_id := int(candidate.get_instance_id())
	var candidate_ref := _candidates.get(candidate_id) as WeakRef
	if candidate_ref == null or candidate_ref.get_ref() != candidate:
		return
	_candidates.erase(candidate_id)
	if not is_inside_tree():
		_focused_interactable = null
		set_process(false)
		return
	if _get_focused_interactable_without_refresh() == candidate:
		_set_focused_interactable(null)
	refresh_focus()
	if _candidates.is_empty():
		set_process(false)


func notify_candidate_changed(candidate: Node = null) -> void:
	if not is_inside_tree():
		return
	if candidate != null:
		var candidate_ref := _candidates.get(int(candidate.get_instance_id())) as WeakRef
		if candidate_ref == null or candidate_ref.get_ref() != candidate:
			return
	refresh_focus()


func route_input(event: InputEvent) -> bool:
	if not is_inside_tree() or interaction_action == &"":
		return false
	if event.is_action_released(interaction_action):
		_interaction_action_pressed = (
			Input.is_action_pressed(interaction_action)
			if InputMap.has_action(interaction_action)
			else false
		)
		return false
	if not enabled:
		return false
	if not event.is_action_pressed(interaction_action):
		return false
	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
		return false
	if _interaction_action_pressed:
		return true
	_interaction_action_pressed = true

	_last_interaction_consumed = false
	_last_interactable = null
	if (
		_actor.has_method("consume_owned_interaction_input")
		and bool(_actor.call("consume_owned_interaction_input"))
	):
		_last_block_reason = &"interaction_input_owned"
		_set_focused_interactable(null)
		return true
	_last_block_reason = _get_world_interaction_block_reason()
	if not _last_block_reason.is_empty():
		_set_focused_interactable(null)
		return true

	refresh_focus()
	var focused := _get_focused_interactable_without_refresh()
	if focused == null:
		_last_block_reason = &"no_eligible_candidate"
		return false

	# A selected candidate gets the press exactly once. If it rejects at execution
	# time, no lower-priority fallback runs until the player's next press.
	_last_interactable = weakref(focused)
	var interaction_result = focused.call("interact", _actor)
	_last_interaction_consumed = interaction_result is bool and bool(interaction_result)
	_last_block_reason = &"" if _last_interaction_consumed else &"candidate_rejected"
	var dispatched_candidate := (
		_last_interactable.get_ref() as Node if _last_interactable != null else null
	)
	if is_inside_tree() and not _get_world_interaction_block_reason().is_empty():
		_set_focused_interactable(null)
	interaction_dispatched.emit(dispatched_candidate, _last_interaction_consumed)
	if dispatched_candidate == null:
		_set_focused_interactable(null)
	return true


func refresh_focus() -> Node:
	if not is_inside_tree():
		_focused_interactable = null
		return null
	_cleanup_invalid_candidates()
	if not enabled or _actor == null or not is_instance_valid(_actor):
		_set_focused_interactable(null)
		return null
	if not _get_world_interaction_block_reason().is_empty():
		_set_focused_interactable(null)
		return null

	var current := _get_focused_interactable_without_refresh()
	if _candidate_is_eligible(current):
		var current_priority := _get_candidate_priority(current)
		var higher_priority_candidate := _find_best_candidate(current_priority + 1)
		if higher_priority_candidate != null:
			_set_focused_interactable(higher_priority_candidate)
			return higher_priority_candidate
		var closest_peer := _find_best_candidate(current_priority)
		if closest_peer != null and _get_candidate_priority(closest_peer) == current_priority:
			var current_distance := sqrt(_get_candidate_distance_squared(current))
			var peer_distance := sqrt(_get_candidate_distance_squared(closest_peer))
			if peer_distance + focus_switch_distance_margin < current_distance:
				_set_focused_interactable(closest_peer)
				return closest_peer
		return current

	var best_candidate := _find_best_candidate()
	_set_focused_interactable(best_candidate)
	return best_candidate


func get_focused_interactable() -> Node:
	return refresh_focus()


func get_interaction_prompt() -> String:
	var focused := refresh_focus()
	if focused == null or not focused.has_method("get_interaction_prompt"):
		return ""
	return String(focused.call("get_interaction_prompt", _actor))


func is_interaction_action_pressed() -> bool:
	return _interaction_action_pressed


func get_debug_snapshot() -> Dictionary:
	var focused := refresh_focus()
	var last_interactable := _last_interactable.get_ref() as Node if _last_interactable != null else null
	var current_block_reason := _get_world_interaction_block_reason()
	return {
		"enabled": enabled,
		"world_interaction_permitted": enabled and current_block_reason.is_empty(),
		"current_block_reason": current_block_reason,
		"focused_interactable": focused,
		"focused_prompt": get_interaction_prompt() if focused != null else "",
		"candidate_count": _candidates.size(),
		"interaction_action_pressed": _interaction_action_pressed,
		"last_block_reason": _last_block_reason,
		"last_interactable": last_interactable,
		"last_interaction_consumed": _last_interaction_consumed,
	}


func get_debug_description() -> String:
	var snapshot := get_debug_snapshot()
	var focused := snapshot.get("focused_interactable") as Node
	return "interaction_allowed=%s focused=%s blocked=%s last_consumed=%s" % [
		str(bool(snapshot.get("world_interaction_permitted", false))),
		focused.name if focused != null else "none",
		String(snapshot.get("current_block_reason", &"")),
		str(bool(snapshot.get("last_interaction_consumed", false))),
	]


func _find_best_candidate(minimum_priority: int = -2147483648) -> Node:
	var best_candidate: Node
	var best_priority := -2147483648
	var best_distance := INF
	var best_instance_id := 9223372036854775807
	for candidate_ref_value in _candidates.values():
		var candidate_ref := candidate_ref_value as WeakRef
		var candidate := candidate_ref.get_ref() as Node if candidate_ref != null else null
		if not _candidate_is_eligible(candidate):
			continue
		var priority := _get_candidate_priority(candidate)
		if priority < minimum_priority:
			continue
		var distance := _get_candidate_distance_squared(candidate)
		var instance_id := int(candidate.get_instance_id())
		if (
			best_candidate == null
			or priority > best_priority
			or (priority == best_priority and distance < best_distance)
			or (
				priority == best_priority
				and is_equal_approx(distance, best_distance)
				and instance_id < best_instance_id
			)
		):
			best_candidate = candidate
			best_priority = priority
			best_distance = distance
			best_instance_id = instance_id
	return best_candidate


func _candidate_has_contract(candidate: Node) -> bool:
	return (
		candidate != null
		and is_instance_valid(candidate)
		and candidate.has_method("can_interact")
		and candidate.has_method("interact")
	)


func _candidate_is_eligible(candidate: Node) -> bool:
	if not _candidate_has_contract(candidate):
		return false
	if candidate.is_queued_for_deletion() or not candidate.is_inside_tree():
		return false
	if candidate.process_mode == Node.PROCESS_MODE_DISABLED:
		return false
	if not get_tree().paused and not candidate.can_process():
		return false
	var canvas_item := candidate as CanvasItem
	if canvas_item != null and not canvas_item.is_visible_in_tree():
		return false
	var area := candidate as Area2D
	if area != null and not area.monitoring:
		return false
	return bool(candidate.call("can_interact", _actor))


func _get_candidate_priority(candidate: Node) -> int:
	if candidate.has_method("get_interaction_priority"):
		return int(candidate.call("get_interaction_priority", _actor))
	return 0


func _get_candidate_distance_squared(candidate: Node) -> float:
	var actor_2d := _actor as Node2D
	if actor_2d == null:
		return 0.0
	var interaction_position := Vector2.ZERO
	var has_interaction_position := false
	if candidate.has_method("get_interaction_position"):
		var requested_position = candidate.call("get_interaction_position", _actor)
		if requested_position is Vector2:
			interaction_position = requested_position
			has_interaction_position = true
	if not has_interaction_position:
		var candidate_2d := candidate as Node2D
		if candidate_2d == null:
			return INF
		interaction_position = candidate_2d.global_position
	return actor_2d.global_position.distance_squared_to(interaction_position)


func _cleanup_invalid_candidates() -> void:
	for candidate_id in _candidates.keys():
		var candidate_ref := _candidates.get(candidate_id) as WeakRef
		var candidate := candidate_ref.get_ref() as Node if candidate_ref != null else null
		if candidate == null or not is_instance_valid(candidate) or candidate.is_queued_for_deletion():
			_candidates.erase(candidate_id)


func _get_focused_interactable_without_refresh() -> Node:
	if _focused_interactable == null:
		return null
	var focused := _focused_interactable.get_ref() as Node
	if focused == null or not is_instance_valid(focused) or focused.is_queued_for_deletion():
		_focused_interactable = null
		return null
	return focused


func _set_focused_interactable(candidate: Node) -> void:
	var previous := _get_focused_interactable_without_refresh()
	if previous == candidate:
		return
	if previous != null and previous.has_method("set_interaction_focused"):
		previous.call("set_interaction_focused", _actor, false)
	_focused_interactable = weakref(candidate) if candidate != null else null
	if candidate != null and candidate.has_method("set_interaction_focused"):
		candidate.call("set_interaction_focused", _actor, true)
	focused_interactable_changed.emit(previous, candidate)


func _get_world_interaction_block_reason() -> StringName:
	if not is_inside_tree():
		return &"interaction_router_outside_tree"
	if not enabled:
		return &"interaction_router_disabled"
	if _actor == null or not is_instance_valid(_actor) or not _actor.is_inside_tree():
		return &"invalid_actor"
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null:
		return &"gameplay_flow_missing"
	if gameplay_flow.has_method("get_player_world_interaction_block_reason"):
		return StringName(gameplay_flow.call(
			"get_player_world_interaction_block_reason", _actor
		))
	if gameplay_flow.has_method("can_player_accept_world_interaction"):
		return (
			&"" if bool(gameplay_flow.call("can_player_accept_world_interaction", _actor))
			else &"gameplay_flow_rejected"
		)
	return &"interaction_authority_unavailable"
