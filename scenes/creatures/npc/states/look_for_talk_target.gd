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
	talk_target = _find_talk_target()
	search_timer = search_duration

	if search_timer < 0.0:
		search_timer = machine.default_look_for_talk_time


func physics_process(delta: float) -> NpcState:
	# Moves toward the chosen person; once close enough, hands off to Talk.
	if talk_target == null or not is_instance_valid(talk_target):
		return get_state(end_state_name)

	search_timer -= delta
	if search_timer <= 0.0:
		return get_state(end_state_name)

	var approach_distance := _get_talk_approach_distance()
	if is_close_to(talk_target.global_position, approach_distance):
		if machine != null and machine.request_talk(talk_target):
			return next_state

		return get_state(end_state_name)

	move_toward_position(talk_target.global_position, machine.walk_speed, approach_distance)
	return next_state


func _find_talk_target() -> Node2D:
	# Prefer known active targets, then scan allowed groups for the closest person.
	if machine != null and _is_allowed_talk_target(machine.target):
		return machine.target

	if machine != null and _is_allowed_talk_target(machine.last_actor):
		return machine.last_actor

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
