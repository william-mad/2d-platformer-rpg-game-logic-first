class_name NpcStateLookForTalkTarget extends NpcState

@export var search_duration: float = -1.0
@export var target_groups: Array[StringName] = [&"npc", &"player"]
@export var require_relationship_favor_for_npcs: bool = true
@export_range(0.0, 100.0, 0.1) var minimum_relationship_favor: float = 10.0
@export var talk_state_name: StringName = &"Talk"
@export var end_state_name: StringName = &"Idle"

var search_timer: float = 0.0
var talk_target: Node2D


func enter() -> void:
	# Picks the best available person and starts a limited search/move timer.
	super.enter()
	if _talk_search_disabled():
		_breadcrumb("npc_talk_search:disabled", _npc_label())
		talk_target = null
		search_timer = 0.0
		next_state = get_state(end_state_name)
		stop_horizontal()
		return

	talk_target = _find_talk_target()
	search_timer = search_duration

	if search_timer < 0.0:
		search_timer = machine.default_look_for_talk_time
	_breadcrumb(
		"npc_talk_search:enter",
		"%s target=%s seconds=%.2f" % [_npc_label(), _target_label(talk_target), search_timer]
	)


func physics_process(delta: float) -> NpcState:
	if not action_session_is_current():
		return reconcile_invalid_action_session()
	# Moves toward the chosen person; once close enough, hands off to Talk.
	if _talk_search_disabled():
		_breadcrumb("npc_talk_search:disabled_tick", _npc_label())
		return get_state(end_state_name)
	if talk_target == null or not is_instance_valid(talk_target):
		_breadcrumb("npc_talk_search:no_target", _npc_label())
		return get_state(end_state_name)

	search_timer -= delta
	if search_timer <= 0.0:
		_breadcrumb("npc_talk_search:timeout", "%s target=%s" % [_npc_label(), _target_label(talk_target)])
		return get_state(end_state_name)

	var approach_distance := _get_talk_approach_distance()
	if is_close_to(talk_target.global_position, approach_distance):
		var talk_priority := machine.get_effective_task_priority() if machine != null else -1
		var search_session_id := action_session_id
		var initiating_source := &"social_ai"
		if machine != null:
			var search_descriptor := machine.get_active_action_descriptor()
			initiating_source = StringName(String(search_descriptor.get("source", "social_ai")))
		if machine != null and machine.request_talk(
			talk_target, talk_priority, true, initiating_source
		):
			if not machine.complete_social_search_handoff(search_session_id):
				push_warning("Accepted Talk did not complete social-search handoff: npc=%s session=%s" % [
					_npc_label(), search_session_id,
				])
			_breadcrumb("npc_talk_search:talk_start", "%s target=%s" % [_npc_label(), _target_label(talk_target)])
			return next_state

		_breadcrumb("npc_talk_search:talk_reject", "%s target=%s" % [_npc_label(), _target_label(talk_target)])
		return get_state(end_state_name)

	move_toward_position(talk_target.global_position, machine.get_effective_walk_speed(), approach_distance)
	return next_state


func is_searching_for_talk_target(candidate: Node2D) -> bool:
	return (
		candidate != null
		and is_instance_valid(candidate)
		and talk_target == candidate
	)


func _find_talk_target() -> Node2D:
	# Prefer the explicitly requested partner, then select from perception.
	if machine != null:
		var action_target := machine.get_active_action_target()
		if _is_allowed_talk_target(action_target):
			_breadcrumb("npc_talk_search:target_action", "%s -> %s" % [_npc_label(), _target_label(action_target)])
			return action_target
		for perceived_target in machine.get_perceived_targets():
			if _is_allowed_talk_target(perceived_target):
				return perceived_target

	if npc == null or not npc.is_inside_tree():
		return null

	var closest_target: Node2D = null
	var closest_distance := INF

	for group_name in target_groups:
		for candidate in npc.get_tree().get_nodes_in_group(String(group_name)):
			var candidate_node := candidate as Node2D
			if not _is_allowed_talk_target(candidate_node):
				continue

			var distance := npc.global_position.distance_to(candidate_node.global_position)
			if distance >= closest_distance:
				continue

			closest_distance = distance
			closest_target = candidate_node

	if closest_target != null:
		_breadcrumb("npc_talk_search:target_closest", "%s -> %s" % [_npc_label(), _target_label(closest_target)])
	return closest_target


func _is_allowed_talk_target(candidate: Node2D) -> bool:
	# Rejects missing/self targets and filters NPCs by relationship favor.
	if candidate == null or not is_instance_valid(candidate):
		return false

	if candidate == npc:
		return false

	var group_allowed := false
	for group_name in target_groups:
		if candidate.is_in_group(String(group_name)):
			group_allowed = true
			break

	if not group_allowed:
		return false

	if machine != null and not machine.can_talk_to_target(
		candidate,
		minimum_relationship_favor,
		require_relationship_favor_for_npcs
	):
		return false

	if require_relationship_favor_for_npcs and candidate.is_in_group("npc"):
		return _get_relationship_favor_for(candidate) > minimum_relationship_favor

	return true


func _get_relationship_favor_for(candidate: Node) -> float:
	# Reads the searching NPC's favor toward this candidate; missing rows default to neutral.
	if npc != null and npc.has_method("get_relationship_favor_for"):
		return float(npc.call("get_relationship_favor_for", candidate, 50.0))

	var relationships := get_node_or_null("/root/Relationships")
	if relationships != null and relationships.has_method("get_favor"):
		return float(relationships.call("get_favor", npc, candidate, 50.0))

	return 50.0


func _get_talk_approach_distance() -> float:
	# Keeps the search arrival distance aligned with the actual Talk state's preferred range.
	var fallback_distance := machine.stop_distance if machine != null else 12.0
	var talk_state := get_state(talk_state_name)
	if talk_state != null and talk_state.has_method("get_talk_approach_distance"):
		return maxf(float(talk_state.call("get_talk_approach_distance")), fallback_distance)

	return fallback_distance


func _talk_search_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_TALK_SEARCH
	)


func _npc_label() -> String:
	if npc != null and is_instance_valid(npc):
		if npc.has_method("get_npc_location_id"):
			var npc_id := String(npc.call("get_npc_location_id")).strip_edges()
			if not npc_id.is_empty():
				return "%s(%s)" % [npc.name, npc_id]
		return npc.name
	return name


func _target_label(target: Node2D) -> String:
	if target == null or not is_instance_valid(target):
		return "none"
	if target.has_method("get_npc_location_id"):
		var npc_id := String(target.call("get_npc_location_id")).strip_edges()
		if not npc_id.is_empty():
			return "%s(%s)" % [target.name, npc_id]
	return target.name


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
