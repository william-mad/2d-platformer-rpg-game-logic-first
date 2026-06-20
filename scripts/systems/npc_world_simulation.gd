extends Node

signal activity_started(npc_id: StringName, spot_id: StringName)
signal activity_finished(npc_id: StringName, spot_id: StringName)

const SPOT_DATA_DIRECTORY := "res://data/npc_spots"

@export var simulation_interval_seconds: float = 10.0

var spot_definitions: Dictionary = {}
var live_spots: Dictionary = {}
var simulation_timer: float = 0.0


func _ready() -> void:
	_load_spot_definitions()
	simulation_timer = simulation_interval_seconds


func _process(delta: float) -> void:
	simulation_timer -= delta
	if simulation_timer > 0.0:
		return

	simulation_timer = maxf(simulation_interval_seconds, 0.1)
	simulate_now()


func simulate_now() -> void:
	# Only saved records are simulated; unloaded NPC scenes never need a running state machine.
	var locations := get_node_or_null("/root/NpcLocations")
	var world_time := get_node_or_null("/root/WorldTime")
	if locations == null or world_time == null:
		return
	if not locations.has_method("get_all_locations") or not world_time.has_method("get_snapshot"):
		return

	var snapshot: Dictionary = world_time.call("get_snapshot")
	var total_hours := float(snapshot.get("total_hours", 0.0))
	var hour := float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))
	var records: Dictionary = locations.call("get_all_locations")

	for npc_id_key in records.keys():
		var npc_id := StringName(String(npc_id_key))
		var record = records[npc_id_key]
		if not (record is Dictionary):
			continue

		var pending_travel = record.get("pending_travel", {})
		if pending_travel is Dictionary and not pending_travel.is_empty():
			_update_pending_travel(npc_id, record, pending_travel, hour, locations)
			continue

		var activity = record.get("activity", {})
		if activity is Dictionary and not activity.is_empty():
			_update_activity(npc_id, record, activity, total_hours, hour, locations)
		else:
			_try_start_activity(npc_id, record, total_hours, hour, locations)


func register_live_spot(spot_id: StringName, spot: Node2D) -> void:
	if spot_id == &"" or spot == null:
		return

	live_spots[spot_id] = spot


func unregister_live_spot(spot_id: StringName, spot: Node2D) -> void:
	if spot_id == &"" or live_spots.get(spot_id, null) != spot:
		return

	live_spots.erase(spot_id)


func resume_live_activity(npc_id: StringName, npc: Node) -> void:
	# Reconnects a spawned NPC to the real spot and normal state machine for the loaded scene.
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_npc_location"):
		return

	var record: Dictionary = locations.call("get_npc_location", String(npc_id))
	var pending_travel = record.get("pending_travel", {})
	if pending_travel is Dictionary and not pending_travel.is_empty():
		_resume_pending_travel(npc_id, npc, pending_travel, locations)
		return

	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return

	var spot_id := StringName(String(activity.get("spot_id", "")))
	var spot := live_spots.get(spot_id, null) as Node2D
	if spot == null or not is_instance_valid(spot):
		return

	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition == null:
		return

	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return

	var assignment_method := definition.get_assignment_method()
	if assignment_method != &"" and machine.has_method(assignment_method):
		machine.call(assignment_method, spot)
	elif machine.has_method("request_state"):
		machine.call("request_state", definition.state_name, spot, "world_activity", definition.priority)


func get_spot_definition(spot_id: StringName) -> NpcSpotDefinition:
	return spot_definitions.get(spot_id, null) as NpcSpotDefinition


func _load_spot_definitions() -> void:
	spot_definitions.clear()
	var directory := DirAccess.open(SPOT_DATA_DIRECTORY)
	if directory == null:
		return

	directory.list_dir_begin()
	var file_name := directory.get_next()
	while not file_name.is_empty():
		if not directory.current_is_dir() and file_name.get_extension().to_lower() == "tres":
			var resource_path := "%s/%s" % [SPOT_DATA_DIRECTORY, file_name]
			var definition := load(resource_path) as NpcSpotDefinition
			if definition != null and definition.is_valid_definition():
				spot_definitions[definition.spot_id] = definition
		file_name = directory.get_next()
	directory.list_dir_end()


func _try_start_activity(
	npc_id: StringName,
	record: Dictionary,
	total_hours: float,
	hour: float,
	locations: Node
) -> void:
	if _record_is_disabled(record):
		return

	var definition := _find_best_definition(npc_id, record, hour)
	if definition == null:
		return
	if locations.has_method("is_npc_available_for_scheduled_activity"):
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			definition.state_name
		)):
			return

	var activity := {
		"spot_id": String(definition.spot_id),
		"state_name": String(definition.state_name),
		"value_name": String(definition.value_name),
		"last_total_hours": total_hours,
		"return_scene_path": String(record.get("scene_path", "")),
		"return_position": record.get("last_position", Vector2.ZERO),
	}

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if live_npc != null and String(record.get("scene_path", "")) != definition.scene_path:
		var departure_door := _find_departure_door(definition.scene_path, live_npc)
		if departure_door == null or not locations.has_method("prepare_scheduled_travel"):
			return

		var pending_travel := {
			"mode": "start",
			"target_scene_path": definition.scene_path,
			"target_position": definition.position,
			"requested_state_name": String(definition.state_name),
			"activity": activity,
		}
		if bool(locations.call(
			"prepare_scheduled_travel",
			String(npc_id),
			pending_travel,
			departure_door
		)):
			activity_started.emit(npc_id, definition.spot_id)
		return

	if not locations.has_method("begin_scheduled_activity"):
		return
	if not bool(locations.call(
		"begin_scheduled_activity",
		String(npc_id),
		activity,
		definition.scene_path,
		definition.position
	)):
		return

	activity_started.emit(npc_id, definition.spot_id)


func _update_pending_travel(
	npc_id: StringName,
	record: Dictionary,
	pending_travel: Dictionary,
	hour: float,
	locations: Node
) -> void:
	var mode := String(pending_travel.get("mode", "start"))
	if mode == "start":
		var pending_activity = pending_travel.get("activity", {})
		var spot_id := StringName(String(pending_activity.get("spot_id", "")))
		var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
		if definition == null or not definition.is_active_at(hour):
			if locations.has_method("cancel_pending_scheduled_travel"):
				locations.call("cancel_pending_scheduled_travel", String(npc_id))
			return

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if live_npc == null:
		_commit_pending_travel_offscreen(npc_id, pending_travel, locations)
		return

	_resume_pending_travel(npc_id, live_npc, pending_travel, locations)


func _resume_pending_travel(
	npc_id: StringName,
	npc: Node2D,
	pending_travel: Dictionary,
	locations: Node
) -> void:
	var target_scene_path := String(pending_travel.get("target_scene_path", ""))
	var departure_door := _find_departure_door(target_scene_path, npc)
	if departure_door == null:
		return
	if _npc_is_moving_to_door(npc, departure_door):
		return

	var requested_state_name := StringName(String(pending_travel.get("requested_state_name", "")))
	if locations.has_method("is_npc_available_for_scheduled_activity"):
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			requested_state_name
		)):
			return
	if locations.has_method("resume_pending_scheduled_travel"):
		locations.call("resume_pending_scheduled_travel", String(npc_id), departure_door)


func _commit_pending_travel_offscreen(
	npc_id: StringName,
	pending_travel: Dictionary,
	locations: Node
) -> void:
	var target_scene_path := String(pending_travel.get("target_scene_path", ""))
	var target_position = pending_travel.get("target_position", Vector2.ZERO)
	if not (target_position is Vector2):
		target_position = Vector2.ZERO

	if String(pending_travel.get("mode", "start")) == "finish":
		if locations.has_method("finish_scheduled_activity"):
			locations.call(
				"finish_scheduled_activity",
				String(npc_id),
				target_scene_path,
				target_position
			)
		return

	var activity = pending_travel.get("activity", {})
	if activity is Dictionary and not activity.is_empty():
		if locations.has_method("begin_scheduled_activity"):
			locations.call(
				"begin_scheduled_activity",
				String(npc_id),
				activity,
				target_scene_path,
				target_position
			)


func _update_activity(
	npc_id: StringName,
	record: Dictionary,
	activity: Dictionary,
	total_hours: float,
	hour: float,
	locations: Node
) -> void:
	var spot_id := StringName(String(activity.get("spot_id", "")))
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition == null or not definition.is_active_at(hour):
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return

	var value_name := String(definition.value_name)
	if not value_name.is_empty() and _get_saved_stat(record, value_name) <= 0.0:
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return

	if locations.has_method("is_npc_live") and bool(locations.call("is_npc_live", String(npc_id))):
		return

	var last_total_hours := float(activity.get("last_total_hours", total_hours))
	var elapsed_game_hours := maxf(total_hours - last_total_hours, 0.0)
	activity["last_total_hours"] = total_hours

	if elapsed_game_hours > 0.0 and not value_name.is_empty():
		_set_saved_stat(
			record,
			value_name,
			_get_saved_stat(record, value_name) + definition.value_delta_per_game_hour * elapsed_game_hours
		)

	record["activity"] = activity
	record["last_position"] = definition.position
	if locations.has_method("update_simulated_record"):
		locations.call("update_simulated_record", String(npc_id), record)

	if not value_name.is_empty() and _get_saved_stat(record, value_name) <= 0.0:
		_finish_activity(npc_id, record, activity, spot_id, locations)


func _finish_activity(
	npc_id: StringName,
	record: Dictionary,
	activity: Dictionary,
	spot_id: StringName,
	locations: Node
) -> void:
	var return_scene_path := String(activity.get("return_scene_path", record.get("scene_path", "")))
	var return_position = activity.get("return_position", record.get("last_position", Vector2.ZERO))
	if not (return_position is Vector2):
		return_position = Vector2.ZERO

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if live_npc != null and return_scene_path != String(record.get("scene_path", "")):
		var departure_door := _find_departure_door(return_scene_path, live_npc)
		if departure_door == null or not locations.has_method("prepare_scheduled_travel"):
			return

		var pending_travel := {
			"mode": "finish",
			"target_scene_path": return_scene_path,
			"target_position": return_position,
			"requested_state_name": "",
			"spot_id": String(spot_id),
		}
		locations.call(
			"prepare_scheduled_travel",
			String(npc_id),
			pending_travel,
			departure_door
		)
		return

	if locations.has_method("finish_scheduled_activity"):
		locations.call(
			"finish_scheduled_activity",
			String(npc_id),
			return_scene_path,
			return_position
		)
	activity_finished.emit(npc_id, spot_id)


func _find_departure_door(target_scene_path: String, npc: Node2D) -> Node2D:
	if target_scene_path.is_empty() or npc == null or not is_instance_valid(npc):
		return null

	var closest_door: Node2D
	var closest_distance := INF
	for door_node in get_tree().get_nodes_in_group("npc_travel_door"):
		var door := door_node as Node2D
		if door == null or not is_instance_valid(door):
			continue
		if String(door.get("target_scene_path")) != target_scene_path:
			continue

		var distance := npc.global_position.distance_squared_to(door.global_position)
		if distance < closest_distance:
			closest_distance = distance
			closest_door = door

	return closest_door


func _npc_is_moving_to_door(npc: Node2D, door: Node2D) -> bool:
	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return false
	var current_state = machine.get("current_state")
	if current_state == null or String(current_state.name) != "MoveToTarget":
		return false

	return machine.get("move_target") == door


func _find_best_definition(
	npc_id: StringName,
	record: Dictionary,
	hour: float
) -> NpcSpotDefinition:
	var best_definition: NpcSpotDefinition
	for definition_value in spot_definitions.values():
		var definition := definition_value as NpcSpotDefinition
		if definition == null or not definition.allows_npc_id(npc_id):
			continue
		if not definition.is_active_at(hour):
			continue
		if definition.value_name != &"":
			var current_value := _get_saved_stat(record, String(definition.value_name))
			if current_value < definition.need_threshold:
				continue
		if best_definition == null or definition.priority > best_definition.priority:
			best_definition = definition

	return best_definition


func _record_is_disabled(record: Dictionary) -> bool:
	return _get_saved_stat(record, "disabled") >= 1.0 or _get_saved_stat(record, "hp") <= 0.0


func _get_saved_stat(record: Dictionary, value_name: String) -> float:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return 0.0
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		return 0.0

	return float(social_stats.get(value_name, 0.0))


func _set_saved_stat(record: Dictionary, value_name: String, value: float) -> void:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		node_state = {}
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		social_stats = {}

	social_stats[value_name] = clampf(value, 0.0, 100.0)
	node_state["social_stats"] = social_stats
	record["node_state"] = node_state
