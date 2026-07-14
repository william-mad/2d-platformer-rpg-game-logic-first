class_name NpcStateRest extends NpcState

@export var rest_target_path: NodePath
@export var rest_value_name: StringName = &"tired"
@export_range(0.0, 100.0, 0.1) var tired_floor: float = 40.0
@export_range(0.0, 1.0, 0.01) var rest_in_place_chance: float = 0.4

var active_rest_target: Node2D
var resting_in_place: bool = false
var choice_rng := RandomNumberGenerator.new()


func on_action_session_refreshed() -> void:
	active_rest_target = machine.get_rest_target()
	resting_in_place = active_rest_target == null


func init() -> void:
	choice_rng.randomize()


func enter() -> void:
	# Chooses an assigned/preferred rest spot or occasionally rests where the NPC stands.
	super.enter()
	_breadcrumb(
		"npc_rest:enter",
		"%s tired=%.2f" % [_npc_label(), machine.get_value(rest_value_name)]
	)
	if _rest_state_disabled():
		_breadcrumb("npc_rest:disabled", _npc_label())
		active_rest_target = null
		resting_in_place = false
		next_state = get_state(&"Idle")
		stop_horizontal()
		return

	active_rest_target = _resolve_rest_target()
	resting_in_place = active_rest_target == null
	if active_rest_target != null and not is_close_to(active_rest_target.global_position, machine.stop_distance):
		_breadcrumb("npc_rest:walk_to_target", "%s -> %s" % [_npc_label(), active_rest_target.name])
		machine.call_deferred(
			"request_active_action_approach", action_session_id, "walk_to_rest", 20
		)
		return

	stop_horizontal()


func exit() -> void:
	_breadcrumb(
		"npc_rest:exit",
		"%s tired=%.2f in_place=%s" % [
			_npc_label(),
			machine.get_value(rest_value_name),
			str(resting_in_place),
		]
	)
	super.exit()


func physics_process(_delta: float) -> NpcState:
	if not action_session_is_current():
		return reconcile_invalid_action_session()
	# The state machine's 10-second fatigue tick lowers tired while this state remains active.
	stop_horizontal()

	if active_rest_target != null and not _target_can_be_rested_at(active_rest_target):
		_breadcrumb("npc_rest:target_rejected", "%s %s" % [_npc_label(), active_rest_target.name])
		machine.set_action_target(&"Rest", null, action_session_id)
		active_rest_target = _resolve_rest_target()
		resting_in_place = active_rest_target == null

	if active_rest_target != null and not is_close_to(active_rest_target.global_position, machine.stop_distance):
		machine.begin_active_action_approach(action_session_id)
		return get_state(&"MoveToTarget")

	if rest_value_name == &"" or machine.get_value(rest_value_name) <= tired_floor:
		machine.set_action_target(&"Rest", null, action_session_id)
		return get_state(&"Idle")

	return next_state


func can_continue_during_talk() -> bool:
	if rest_value_name == &"" or machine.get_value(rest_value_name) <= tired_floor:
		return false
	if active_rest_target == null:
		return resting_in_place
	return (
		is_instance_valid(active_rest_target)
		and _target_can_be_rested_at(active_rest_target)
		and is_close_to(active_rest_target.global_position, machine.stop_distance)
	)


func process_talk_overlay(_delta: float) -> StringName:
	stop_horizontal()
	if rest_value_name == &"" or machine.get_value(rest_value_name) <= tired_floor:
		machine.set_action_target(&"Rest", null, action_session_id)
		return &"Idle"
	if active_rest_target == null:
		return &"Rest" if resting_in_place else &"Idle"
	if not is_instance_valid(active_rest_target) or not _target_can_be_rested_at(active_rest_target):
		machine.set_action_target(&"Rest", null, action_session_id)
		return &"Idle"
	if not is_close_to(active_rest_target.global_position, machine.stop_distance):
		machine.begin_active_action_approach(action_session_id)
		return &"MoveToTarget"
	return &"Rest"


func is_resting_in_place() -> bool:
	return resting_in_place and active_rest_target == null


func get_tired_floor() -> float:
	return tired_floor


func _resolve_rest_target() -> Node2D:
	# Explicit assignments win; otherwise the NPC rolls in-place rest before weighted spot choice.
	if machine == null:
		return null

	var assigned_target := machine.get_rest_target()
	if _target_can_be_rested_at(assigned_target):
		_breadcrumb("npc_rest:target_assigned", "%s -> %s" % [_npc_label(), assigned_target.name])
		return assigned_target

	if String(rest_target_path) != "" and machine.npc != null:
		var configured_target := machine.npc.get_node_or_null(rest_target_path) as Node2D
		if _target_can_be_rested_at(configured_target):
			machine.set_action_target(&"Rest", configured_target, action_session_id)
			_breadcrumb("npc_rest:target_configured", "%s -> %s" % [_npc_label(), configured_target.name])
			return configured_target

	machine.set_action_target(&"Rest", null, action_session_id)
	if choice_rng.randf() < clampf(rest_in_place_chance, 0.0, 1.0):
		_breadcrumb("npc_rest:target_in_place", _npc_label())
		return null

	var preferred_spot := find_weighted_casual_spot(&"Rest", choice_rng)
	if preferred_spot != null:
		machine.set_action_target(&"Rest", preferred_spot, action_session_id)
		_breadcrumb("npc_rest:target_weighted", "%s -> %s" % [_npc_label(), preferred_spot.name])
		return preferred_spot

	return null


func _target_can_be_rested_at(rest_target: Node2D) -> bool:
	if rest_target == null or not is_instance_valid(rest_target):
		return false

	if rest_target.has_method("can_serve_npc_casual_activity"):
		var accepted := bool(rest_target.call("can_serve_npc_casual_activity", npc, &"Rest"))
		if not accepted:
			_breadcrumb("npc_rest:spot_reject", "%s %s" % [_npc_label(), rest_target.name])
		return accepted

	return true


func _rest_state_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_REST_STATE
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
