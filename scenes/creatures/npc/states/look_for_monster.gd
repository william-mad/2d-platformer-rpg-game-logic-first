class_name NpcStateLookForMonster extends NpcState

@export var search_duration: float = -1.0
@export var target_groups: Array[StringName] = [&"monster", &"monsters", &"enemy", &"enemies"]
@export var require_visibility: bool = true
@export var end_state_name: StringName = &"Idle"
@export_range(0, 1000, 1) var reaction_priority: int = 94

@export_group("Search Movement")
@export var use_search_wander: bool = true
@export var search_wander_interval_seconds: float = 1.0
@export var search_wander_distance: float = 90.0

var search_timer: float = 0.0
var monster_target: Node2D
var search_origin_x: float = 0.0
var search_target_x: float = 0.0
var search_wander_timer: float = 0.0
var rng := RandomNumberGenerator.new()


func enter() -> void:
	super.enter()
	rng.randomize()
	search_timer = search_duration
	if search_timer < 0.0:
		search_timer = machine.default_look_for_monster_time if machine != null else 4.0

	search_origin_x = _get_search_origin_x()
	search_target_x = search_origin_x
	search_wander_timer = 0.0
	monster_target = _find_monster_target()
	_breadcrumb(
		"npc_monster_search:enter",
		"%s target=%s seconds=%.2f" % [_npc_label(), _target_label(monster_target), search_timer]
	)


func physics_process(delta: float) -> NpcState:
	monster_target = _find_monster_target()
	if monster_target != null:
		if machine != null and machine.request_monster_reaction(
			monster_target,
			"look_for_monster",
			reaction_priority
		):
			_breadcrumb(
				"npc_monster_search:react",
				"%s target=%s" % [_npc_label(), _target_label(monster_target)]
			)
			return next_state

	search_timer -= delta
	if search_timer <= 0.0:
		_breadcrumb("npc_monster_search:timeout", _npc_label())
		return get_state(end_state_name)

	_process_search_wander(delta)
	return next_state


func is_searching_for_monster_target(candidate: Node2D) -> bool:
	return (
		candidate != null
		and is_instance_valid(candidate)
		and monster_target == candidate
	)


func _find_monster_target() -> Node2D:
	if machine != null:
		var active_target := _get_live_node_2d(machine.target)
		if _is_allowed_monster_target(active_target):
			return active_target
		if machine.target != null and not is_instance_valid(machine.target):
			machine.target = null

		var last_actor := _get_live_node_2d(machine.last_actor)
		if _is_allowed_monster_target(last_actor):
			return last_actor
		if machine.last_actor != null and not is_instance_valid(machine.last_actor):
			machine.last_actor = null

	if npc == null or not npc.is_inside_tree():
		return null

	var closest_target: Node2D = null
	var closest_distance_squared := INF
	for group_name in target_groups:
		for candidate in npc.get_tree().get_nodes_in_group(String(group_name)):
			var candidate_node := _get_live_node_2d(candidate)
			if not _is_allowed_monster_target(candidate_node):
				continue

			var distance_squared := npc.global_position.distance_squared_to(candidate_node.global_position)
			if distance_squared >= closest_distance_squared:
				continue

			closest_distance_squared = distance_squared
			closest_target = candidate_node

	return closest_target


func _get_live_node_2d(candidate) -> Node2D:
	# Keep this boundary untyped: a freed Object cannot be passed to a Node2D-typed
	# parameter, so validity must be checked before the cast.
	if candidate == null or not is_instance_valid(candidate):
		return null
	return candidate as Node2D


func _is_allowed_monster_target(candidate) -> bool:
	var candidate_node := _get_live_node_2d(candidate)
	if candidate_node == null:
		return false
	if candidate_node == npc:
		return false
	if candidate_node.is_queued_for_deletion():
		return false
	if machine != null and not machine.is_monster_target(candidate_node):
		return false
	if _target_is_defeated(candidate_node):
		return false
	if not candidate_node.has_method("take_damage"):
		return false
	if require_visibility and not _can_see_target(candidate_node):
		return false

	return true


func _can_see_target(candidate: Node2D) -> bool:
	if npc != null and npc.has_method("can_see"):
		return bool(npc.call("can_see", candidate))

	return true


func _target_is_defeated(candidate: Node) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return true

	var dead_value = candidate.get("dead")
	if typeof(dead_value) == TYPE_BOOL and bool(dead_value):
		return true

	var disabled_value = candidate.get("disabled")
	if typeof(disabled_value) == TYPE_BOOL and bool(disabled_value):
		return true

	if candidate.has_method("get_current_health"):
		return float(candidate.call("get_current_health")) <= 0.0

	if candidate.has_method("get_hp"):
		return float(candidate.call("get_hp")) <= 0.0

	var hp_value = candidate.get("hp")
	if typeof(hp_value) == TYPE_FLOAT or typeof(hp_value) == TYPE_INT:
		return float(hp_value) <= 0.0

	return false


func _process_search_wander(delta: float) -> void:
	if not use_search_wander or npc == null or machine == null:
		stop_horizontal()
		return

	search_wander_timer -= delta
	if search_wander_timer <= 0.0 or is_close_to(Vector2(search_target_x, npc.global_position.y), machine.stop_distance):
		search_wander_timer = maxf(search_wander_interval_seconds, 0.1)
		var distance := rng.randf_range(-absf(search_wander_distance), absf(search_wander_distance))
		search_target_x = search_origin_x + distance

	move_toward_position(
		Vector2(search_target_x, npc.global_position.y),
		machine.get_effective_walk_speed(),
		machine.stop_distance
	)


func _get_search_origin_x() -> float:
	if machine != null:
		if machine.target != null and is_instance_valid(machine.target):
			return machine.target.global_position.x
		if machine.last_actor != null and is_instance_valid(machine.last_actor):
			return machine.last_actor.global_position.x

	return npc.global_position.x if npc != null else 0.0


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
