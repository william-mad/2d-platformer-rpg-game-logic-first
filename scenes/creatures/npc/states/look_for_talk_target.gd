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


func exit() -> void:
	# Ranking diagnostics describe only the active search. Clear them on every
	# transition, including no-target, timeout, rejection, and Talk handoff.
	if machine != null:
		machine.clear_social_scoring_debug_descriptor()
	super.exit()


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
		var talk_state := get_state(talk_state_name) as NpcStateTalk
		if (
			talk_state != null
			and not talk_state.is_talk_start_distance_viable(talk_target)
		):
			machine.defer_talk_retry(talk_target)
			machine.cancel_active_action(
				search_session_id,
				"talk_target_outside_maximum_distance"
			)
			_breadcrumb(
				"npc_talk_search:start_not_viable",
				"%s target=%s" % [_npc_label(), _target_label(talk_target)]
			)
			return get_state(end_state_name)
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
	# An explicitly committed partner remains authoritative. Fresh autonomous
	# candidates are filtered first, then ranked by the state machine's shared scorer.
	if machine != null:
		var action_target := machine.get_active_action_target()
		if _is_allowed_talk_target(action_target, false):
			machine.clear_social_scoring_debug_descriptor()
			_breadcrumb("npc_talk_search:target_action", "%s -> %s" % [_npc_label(), _target_label(action_target)])
			return action_target

	if npc == null or not npc.is_inside_tree():
		return null

	var candidates: Array[Node2D] = []
	var seen_nodes: Dictionary = {}
	if machine != null:
		for perceived_target in machine.get_perceived_targets():
			_append_rankable_candidate(candidates, seen_nodes, perceived_target)

	for group_name in target_groups:
		for candidate in npc.get_tree().get_nodes_in_group(String(group_name)):
			_append_rankable_candidate(
				candidates,
				seen_nodes,
				candidate as Node2D
			)
	if machine != null:
		var ranked := machine.select_ranked_autonomous_social_target(candidates)
		var selected := ranked.get("target_node", null) as Node2D
		if selected != null:
			_breadcrumb("npc_talk_search:target_ranked", "%s -> %s" % [_npc_label(), _target_label(selected)])
		return selected
	return null


func _append_rankable_candidate(
	candidates: Array[Node2D],
	seen_nodes: Dictionary,
	candidate: Node2D
) -> void:
	if not _is_allowed_talk_target(candidate, true):
		return
	var instance_id := candidate.get_instance_id()
	if seen_nodes.has(instance_id):
		return
	seen_nodes[instance_id] = true
	candidates.append(candidate)


func _is_allowed_talk_target(
	candidate: Node2D,
	apply_social_memory: bool = true
) -> bool:
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
	if apply_social_memory and machine != null:
		var memory_decision := machine.get_autonomous_social_memory_decision(
			candidate
		)
		if not bool(memory_decision.get("allowed", true)):
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
