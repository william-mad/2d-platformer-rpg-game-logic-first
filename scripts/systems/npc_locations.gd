extends Node

const NpcActionSessionModel = preload("res://scripts/systems/npc_action_session.gd")

signal npc_registered(npc_id: String, npc: Node, scene_path: String)
signal npc_travelled(npc_id: String, from_scene_path: String, to_scene_path: String)
signal npc_spawned(npc_id: String, npc: Node, scene_path: String)

@export var return_check_seconds: float = 60.0
@export_range(0.0, 1.0, 0.01) var return_chance_per_check: float = 0.18
@export var randomize_spawn_positions: bool = true

var npc_records: Dictionary = {}
var live_npcs: Dictionary = {}
var active_scene_context: Node
var active_scene_path: String = ""
var return_timer: float = 0.0

var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	_update_return_processing()


func _process(delta: float) -> void:
	return_timer += delta
	if return_timer < return_check_seconds:
		return

	return_timer = 0.0
	_try_return_travelling_npcs()


func register_npc(npc: Node) -> bool:
	if npc == null or not is_instance_valid(npc):
		return false

	var npc_id := get_npc_id(npc)
	if npc_id.is_empty():
		return true

	_breadcrumb("npc_locations:register_start", npc_id)
	var current_scene_path := get_current_scene_path()
	var npc_scene_path := _get_npc_scene_path(npc)
	var created_record := not npc_records.has(npc_id)
	var existing_record: Dictionary = npc_records.get(npc_id, {})
	var expected_scene_path := String(existing_record.get("scene_path", current_scene_path))
	if not created_record and not expected_scene_path.is_empty() and expected_scene_path != current_scene_path:
		_breadcrumb(
			"npc_locations:register_scene_mismatch",
			"%s expected=%s current=%s" % [npc_id, expected_scene_path.get_file(), current_scene_path.get_file()]
		)
		return false

	var existing_npc = live_npcs.get(npc_id, null) as Node
	if existing_npc != null and is_instance_valid(existing_npc) and not existing_npc.is_queued_for_deletion() and existing_npc != npc:
		_breadcrumb("npc_locations:register_duplicate", npc_id)
		return false
	if not _has_live_inventory_api(npc):
		if npc is SocialNpc:
			push_error("Persistent SocialNpc '%s' is missing its required inventory component API." % npc_id)
			return false

	var record: Dictionary
	if created_record:
		record = _build_initial_record(npc_id, npc, current_scene_path, npc_scene_path)
		if npc.has_method("initialize_merchant_starting_inventory"):
			var initialization = npc.call("initialize_merchant_starting_inventory")
			if initialization is InventoryResult and not (initialization as InventoryResult).success:
				push_error("Merchant '%s' starting inventory failed: %s" % [npc_id, (initialization as InventoryResult).message])
				return false
	else:
		# Registration works on a copy so even component/wiring failures cannot
		# partially mutate the canonical record before the instance is committed.
		record = existing_record.duplicate(true)
		_refresh_record_from_node(record, npc, npc_scene_path)
		if not _restore_record_inventory_to_live_npc(npc_id, npc, record):
			return false
		var should_randomize_position := bool(record.get("spawn_random", false)) and active_scene_path == current_scene_path
		_apply_record_to_npc(npc, record, should_randomize_position)
		if should_randomize_position:
			record["spawn_random"] = false

	live_npcs[npc_id] = npc
	record["scene_path"] = current_scene_path
	if not _capture_live_npc_into_record(npc_id, npc, record):
		live_npcs.erase(npc_id)
		return false
	npc_records[npc_id] = record

	npc_registered.emit(npc_id, npc, current_scene_path)
	_resume_scheduled_activity_deferred(npc_id, npc)
	_breadcrumb("npc_locations:register_end", "%s %s" % [npc_id, current_scene_path.get_file()])
	_record_watchdog_marker(&"npc_locations:register", "%s %s" % [npc_id, current_scene_path.get_file()])
	return true


func unregister_npc(npc: Node) -> void:
	if npc == null:
		return

	var npc_id := get_npc_id(npc)
	if npc_id.is_empty():
		return

	var existing_npc = live_npcs.get(npc_id, null) as Node
	if existing_npc == npc:
		_breadcrumb("npc_locations:unregister", npc_id)
		if npc_records.has(npc_id):
			var record: Dictionary = npc_records[npc_id]
			_capture_live_npc_into_record(npc_id, npc, record)
			var activity = record.get("activity", {})
			if activity is Dictionary and not activity.is_empty():
				var activity_scene := String(activity.get("target_scene_path", ""))
				var activity_position = activity.get("target_position", null)
				if activity_scene.is_empty() or not (activity_position is Vector2):
					var endpoint := _get_activity_endpoint(activity)
					activity_scene = String(endpoint.get("scene_path", activity_scene))
					activity_position = endpoint.get("position", activity_position)
				if activity_scene == String(record.get("scene_path", "")) and activity_position is Vector2:
					# Once this scene unloads, finish the unseen walk instead of restarting it on re-entry.
					record["last_position"] = activity_position
			npc_records[npc_id] = record

		live_npcs.erase(npc_id)


func request_travel(npc: Node, target_scene_path: String) -> bool:
	if npc == null or target_scene_path.is_empty():
		return false

	if target_scene_path == get_current_scene_path():
		return false

	var npc_id := get_npc_id(npc)
	if npc_id.is_empty():
		return false

	if not npc_records.has(npc_id):
		register_npc(npc)

	if not npc_records.has(npc_id):
		return false

	var record: Dictionary = npc_records[npc_id]
	_capture_live_npc_into_record(npc_id, npc, record)
	_move_record_to_scene(npc_id, record, target_scene_path, true)
	_record_watchdog_marker(&"npc_locations:travel", "%s -> %s" % [npc_id, target_scene_path.get_file()])

	live_npcs.erase(npc_id)
	npc.queue_free()
	return true


func activate_scene(scene_context: Node) -> void:
	active_scene_context = scene_context
	active_scene_path = _get_context_scene_path(scene_context)
	_breadcrumb("npc_locations:activate", "%s records=%d" % [active_scene_path.get_file(), npc_records.size()])
	_record_watchdog_marker(&"npc_locations:activate", "%s records=%d" % [active_scene_path.get_file(), npc_records.size()])
	call_deferred("_spawn_missing_npcs_for_active_scene")


func get_npc_location(npc_id: String) -> Dictionary:
	if not npc_records.has(npc_id):
		return {}

	_refresh_live_record(npc_id)
	return npc_records[npc_id].duplicate(true)


func synchronize_live_records() -> void:
	_refresh_live_records_for_save()


func get_records_snapshot() -> Dictionary:
	return npc_records.duplicate(true)


func get_record_snapshot(npc_id: String) -> Dictionary:
	if npc_id.is_empty() or not npc_records.has(npc_id):
		return {}

	return npc_records[npc_id].duplicate(true)


func get_record_ids_snapshot() -> PackedStringArray:
	var npc_ids := PackedStringArray()
	npc_ids.resize(npc_records.size())
	var index := 0
	for npc_id_key in npc_records:
		npc_ids[index] = String(npc_id_key)
		index += 1

	return npc_ids


func get_all_locations() -> Dictionary:
	# Compatibility API: new callers should synchronize explicitly, then query a snapshot.
	synchronize_live_records()
	return get_records_snapshot()


func is_npc_live(npc_id: String) -> bool:
	var npc = live_npcs.get(npc_id, null) as Node
	return npc != null and is_instance_valid(npc) and not npc.is_queued_for_deletion()


func get_live_npc(npc_id: String) -> Node:
	if not is_npc_live(npc_id):
		return null

	return live_npcs.get(npc_id, null) as Node


func is_npc_available_for_scheduled_activity(
	npc_id: String,
	requested_state_name: StringName = &"",
	requested_priority: int = 0,
	requested_activity: Dictionary = {}
) -> bool:
	# Off-screen NPCs are represented by their record and are available by default.
	var npc := get_live_npc(npc_id)
	if npc == null:
		_breadcrumb("npc_locations:availability", "%s offscreen accept" % npc_id)
		return true

	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		_breadcrumb("npc_locations:availability", "%s no_machine accept" % npc_id)
		return true

	var current_state = machine.get("current_state")
	if current_state == null or String(current_state.name) == "Idle":
		_breadcrumb("npc_locations:availability", "%s idle accept %s" % [npc_id, String(requested_state_name)])
		return true

	var current_state_name := String(current_state.name)
	if not requested_activity.is_empty() and machine.has_method("is_following_activity_descriptor"):
		if bool(machine.call("is_following_activity_descriptor", requested_activity)):
			_breadcrumb(
				"npc_locations:availability",
				"%s already_%s_identity accept" % [npc_id, String(requested_state_name)]
			)
			return true
	elif requested_state_name != &"" and current_state_name == String(requested_state_name):
		# Legacy callers without a target identity fall through to the state's normal
		# interruption policy. State name alone is not proof of the same activity.
		_breadcrumb(
			"npc_locations:availability",
			"%s ambiguous_%s check_interrupt" % [npc_id, current_state_name]
		)

	# Each state declares this itself, so even low-priority routines such as Work can
	# interrupt opt-in states without overriding danger, combat, collapse, or death.
	if current_state.has_method("can_be_interrupted_by_scheduled_activity"):
		var accepted := bool(current_state.call(
			"can_be_interrupted_by_scheduled_activity",
			requested_priority
		))
		_breadcrumb(
			"npc_locations:availability",
			"%s %s->%s %s" % [
				npc_id,
				current_state_name,
				String(requested_state_name),
				"accept" if accepted else "reject",
			]
		)
		return accepted

	_breadcrumb("npc_locations:availability", "%s %s reject" % [npc_id, current_state_name])
	return false


func prepare_scheduled_travel(
	npc_id: String,
	pending_travel: Dictionary,
	departure_door: Node2D
) -> bool:
	# Keeps the NPC in its current scene until it physically reaches the departure door.
	if not npc_records.has(npc_id) or pending_travel.is_empty():
		_breadcrumb("npc_locations:prepare_travel_reject", npc_id)
		return false

	var target_scene_path := String(pending_travel.get("target_scene_path", ""))
	if target_scene_path.is_empty():
		_breadcrumb("npc_locations:prepare_travel_empty_target", npc_id)
		return false

	_breadcrumb("npc_locations:prepare_travel", "%s -> %s" % [npc_id, target_scene_path.get_file()])
	var npc := get_live_npc(npc_id) as Node2D
	if npc == null or departure_door == null or not is_instance_valid(departure_door):
		_breadcrumb("npc_locations:prepare_travel_missing_live_target", npc_id)
		return false
	var original_record: Dictionary = (npc_records[npc_id] as Dictionary).duplicate(true)
	var record: Dictionary = original_record.duplicate(true)
	if not _capture_live_npc_into_record(npc_id, npc, record):
		_breadcrumb("npc_locations:prepare_travel_capture_reject", npc_id)
		return false

	var accepted := false
	var already_at_door := (
		departure_door is Area2D
		and (departure_door as Area2D).overlaps_body(npc)
		and departure_door.has_method("try_travel_npc")
	)
	if already_at_door:
		# Reaching an eligible travel door is itself acceptance; completion is checked
		# synchronously after the pending record is installed below.
		accepted = true
	else:
		var machine := npc.get_node_or_null("NpcStateMachine")
		if machine == null or not machine.has_method("assign_move_target"):
			_breadcrumb("npc_locations:prepare_travel_no_machine", npc_id)
			return false
		accepted = _request_pending_travel_movement(
			machine, npc_id, pending_travel, departure_door, record
		)

	if not accepted:
		_breadcrumb("npc_locations:prepare_travel_assignment_reject", npc_id)
		return false

	record["pending_travel"] = pending_travel.duplicate(true)
	var accepted_machine := npc.get_node_or_null("NpcStateMachine")
	if accepted_machine != null and accepted_machine.has_method("get_active_action_descriptor"):
		record["action"] = accepted_machine.call("get_active_action_descriptor")
	npc_records[npc_id] = record
	if already_at_door:
		var travelled := bool(departure_door.call("try_travel_npc", npc))
		if not travelled:
			npc_records[npc_id] = original_record
			_breadcrumb("npc_locations:prepare_travel_door_reject", npc_id)
			return false
	_breadcrumb("npc_locations:prepare_travel_accept", npc_id)
	return true


func resume_pending_scheduled_travel(npc_id: String, departure_door: Node2D) -> bool:
	var npc := get_live_npc(npc_id) as Node2D
	if npc == null or departure_door == null or not is_instance_valid(departure_door):
		_breadcrumb("npc_locations:resume_pending_reject", npc_id)
		return false

	if departure_door is Area2D and (departure_door as Area2D).overlaps_body(npc):
		if departure_door.has_method("try_travel_npc"):
			_breadcrumb("npc_locations:resume_pending_door", npc_id)
			return bool(departure_door.call("try_travel_npc", npc))

	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null or not machine.has_method("assign_move_target"):
		_breadcrumb("npc_locations:resume_pending_no_machine", npc_id)
		return false

	var record: Dictionary = npc_records.get(npc_id, {})
	var pending = record.get("pending_travel", {})
	var accepted := _request_pending_travel_movement(
		machine,
		npc_id,
		pending if pending is Dictionary else {},
		departure_door,
		record
	)
	_breadcrumb("npc_locations:resume_pending_move", "%s %s" % [npc_id, "accept" if accepted else "reject"])
	return accepted


func _request_pending_travel_movement(
	machine: Node,
	npc_id: String,
	pending_travel: Dictionary,
	departure_door: Node2D,
	record: Dictionary
) -> bool:
	if machine.has_method("request_action_movement_from_descriptor"):
		var descriptor: Dictionary = {}
		var destination_kind := StringName(String(pending_travel.get(
			"requested_state_name", "Idle"
		)))
		var nested_activity = pending_travel.get("activity", {})
		if nested_activity is Dictionary and not nested_activity.is_empty():
			descriptor = nested_activity.duplicate(true)
			descriptor["action_kind"] = String(nested_activity.get(
				"state_name", destination_kind
			))
			descriptor["source"] = String(nested_activity.get("source", "schedule"))
			descriptor["target_persistent_id"] = String(nested_activity.get("spot_id", ""))
		elif String(pending_travel.get("mode", "")) == "social":
			descriptor = {
				"session_id": String(pending_travel.get("social_session_id", "")),
				"action_kind": "LookForTalkTarget",
				"source": "social_ai",
				"target_persistent_id": String(pending_travel.get("social_target_id", "")),
				"scene_path": String(pending_travel.get("target_scene_path", "")),
				"priority": int(pending_travel.get("requested_priority", 60)),
				"status": "proposed",
				"start_world_time": _get_world_total_hours(),
			}
			destination_kind = &"LookForTalkTarget"
		else:
			var existing_action = record.get("action", {})
			if existing_action is Dictionary:
				descriptor = existing_action.duplicate(true)
			if descriptor.is_empty():
				descriptor = {
					"action_kind": String(
						destination_kind if destination_kind not in [&"", &"Idle"] else &"MoveToTarget"
					),
					"source": "manual",
					"priority": int(pending_travel.get("requested_priority", 20)),
					"status": "proposed",
					"start_world_time": _get_world_total_hours(),
				}
		return bool(machine.call(
			"request_action_movement_from_descriptor",
			descriptor,
			departure_door,
			destination_kind
		))
	return bool(machine.call("assign_move_target", departure_door, &"Idle"))


func complete_pending_scheduled_travel(npc: Node, door_target_scene_path: String) -> bool:
	if npc == null or door_target_scene_path.is_empty():
		return false

	var npc_id := get_npc_id(npc)
	if npc_id.is_empty() or not npc_records.has(npc_id):
		return false

	_refresh_live_record(npc_id)
	var record: Dictionary = npc_records[npc_id]
	var pending = record.get("pending_travel", {})
	if not (pending is Dictionary) or pending.is_empty():
		return false
	if String(pending.get("target_scene_path", "")) != door_target_scene_path:
		return false

	var mode := String(pending.get("mode", "start"))
	var target_position = pending.get("target_position", Vector2.ZERO)
	if not (target_position is Vector2):
		target_position = Vector2.ZERO

	if mode == "finish":
		return finish_scheduled_activity(
			npc_id,
			door_target_scene_path,
			target_position,
			String(pending.get("action_session_id", ""))
		)
	if mode == "social":
		return _complete_social_travel(
			npc_id,
			npc,
			door_target_scene_path,
			target_position,
			String(pending.get("social_target_id", "")),
			String(pending.get("social_session_id", ""))
		)

	var activity = pending.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return false
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		activity["last_total_hours"] = float(snapshot.get("total_hours", 0.0))

	return begin_scheduled_activity(npc_id, activity, door_target_scene_path, target_position)


func cancel_pending_scheduled_travel(npc_id: String) -> void:
	if not npc_records.has(npc_id):
		return

	var record: Dictionary = npc_records[npc_id]
	var pending = record.get("pending_travel", {})
	if pending is Dictionary:
		var pending_activity = pending.get("activity", {})
		if pending_activity is Dictionary and not pending_activity.is_empty():
			_notify_activity_claim_release(
				StringName(String(pending_activity.get("spot_id", ""))),
				"pending_travel_cancelled",
				NpcActionSessionModel._descriptor_session_id(pending_activity),
				StringName(npc_id)
			)
	record["pending_travel"] = {}
	npc_records[npc_id] = record


func rollback_scheduled_activity(
	npc_id: String,
	expected_activity: Dictionary,
	reason: String = "activity_rejected"
) -> bool:
	if not npc_records.has(npc_id):
		return false
	var record: Dictionary = npc_records[npc_id]
	var current_activity = record.get("activity", {})
	if not (current_activity is Dictionary) or not _activity_records_match(
		current_activity,
		expected_activity
	):
		return false
	var expected_session_id := NpcActionSessionModel._descriptor_session_id(expected_activity)
	var current_action = record.get("action", {})
	if not expected_session_id.is_empty() and current_action is Dictionary:
		var current_action_id := NpcActionSessionModel._descriptor_session_id(current_action)
		if not current_action_id.is_empty() and current_action_id != expected_session_id:
			_breadcrumb(
				"npc_locations:activity_rollback_stale",
				"%s callback=%s active=%s" % [npc_id, expected_session_id, current_action_id]
			)
			return false
	record["activity"] = {}
	if current_action is Dictionary:
		var current_action_id := NpcActionSessionModel._descriptor_session_id(current_action)
		if expected_session_id.is_empty() or current_action_id == expected_session_id:
			record["action"] = {}
	var pending = record.get("pending_travel", {})
	if pending is Dictionary:
		var pending_activity = pending.get("activity", {})
		if pending_activity is Dictionary and _activity_records_match(
			pending_activity,
			expected_activity
		):
			record["pending_travel"] = {}
	npc_records[npc_id] = record
	var live_npc := get_live_npc(npc_id)
	if live_npc != null and not expected_session_id.is_empty():
		var machine := live_npc.get_node_or_null("NpcStateMachine")
		if machine != null and machine.has_method("cancel_active_action"):
			if bool(machine.call("cancel_active_action", expected_session_id, reason)):
				if machine.has_method("clear_terminal_action"):
					machine.call("clear_terminal_action", expected_session_id)
	_breadcrumb("npc_locations:activity_rollback", "%s %s" % [npc_id, reason])
	return true


func _rollback_pending_activity_record(npc_id: String, expected_activity: Dictionary) -> void:
	if not npc_records.has(npc_id):
		return
	var record: Dictionary = npc_records[npc_id]
	var pending = record.get("pending_travel", {})
	if not (pending is Dictionary):
		return
	var pending_activity = pending.get("activity", {})
	if not (pending_activity is Dictionary) or not _activity_records_match(
		pending_activity,
		expected_activity
	):
		return
	record["pending_travel"] = {}
	npc_records[npc_id] = record


func _activity_records_match(left: Dictionary, right: Dictionary) -> bool:
	var left_spot := String(left.get("spot_id", ""))
	var right_spot := String(right.get("spot_id", ""))
	if left_spot.is_empty() or left_spot != right_spot:
		return false
	var left_state := String(left.get("state_name", ""))
	var right_state := String(right.get("state_name", ""))
	if not left_state.is_empty() and not right_state.is_empty() and left_state != right_state:
		return false
	for id_key in ["session_id", "action_session_id", "activity_id", "request_id"]:
		var left_id := String(left.get(id_key, ""))
		var right_id := String(right.get(id_key, ""))
		if not left_id.is_empty() and not right_id.is_empty() and left_id != right_id:
			return false
	return true


func move_simulated_npc_for_social_visit(
	npc_id: String,
	target_scene_path: String,
	target_position: Vector2,
	social_target_id: String,
	session_id: String = ""
) -> bool:
	# Unloaded NPC travel is represented in records; live NPCs must walk through a door.
	if not npc_records.has(npc_id) or target_scene_path.is_empty() or is_npc_live(npc_id):
		return false
	var record: Dictionary = npc_records[npc_id]
	var from_scene_path := String(record.get("scene_path", ""))
	record["pending_travel"] = {}
	record["activity"] = {}
	var social_action := NpcActionSessionModel.create(npc_id, &"LookForTalkTarget", &"social_ai", null, {
		"session_id": session_id,
		"action_kind": "LookForTalkTarget",
		"source": "social_ai",
		"target_persistent_id": social_target_id,
		"scene_path": target_scene_path,
		"status": "active",
		"start_world_time": _get_world_total_hours(),
	})
	record["action"] = social_action.to_descriptor()
	record["social_visit_target_id"] = social_target_id
	record["last_position"] = target_position
	record["spawn_random"] = false
	if from_scene_path == target_scene_path:
		npc_records[npc_id] = record
		if target_scene_path == active_scene_path:
			call_deferred("_spawn_missing_npcs_for_active_scene")
		return true

	_move_record_to_scene(npc_id, record, target_scene_path, false)
	return true


func _complete_social_travel(
	npc_id: String,
	npc: Node,
	target_scene_path: String,
	target_position: Vector2,
	social_target_id: String,
	requested_session_id: String = ""
) -> bool:
	if not npc_records.has(npc_id):
		return false
	var record: Dictionary = npc_records[npc_id]
	_capture_live_npc_into_record(npc_id, npc, record)
	record["pending_travel"] = {}
	record["activity"] = {}
	var social_session_id := requested_session_id
	if social_session_id.is_empty():
		social_session_id = String(record.get("social_session_id", ""))
	if social_session_id.is_empty():
		social_session_id = String(record.get("action", {}).get("session_id", ""))
	var social_action := NpcActionSessionModel.create(npc_id, &"LookForTalkTarget", &"social_ai", null, {
		"session_id": social_session_id,
		"action_kind": "LookForTalkTarget",
		"source": "social_ai",
		"target_persistent_id": social_target_id,
		"scene_path": target_scene_path,
		"status": "active",
		"start_world_time": _get_world_total_hours(),
	})
	record["action"] = social_action.to_descriptor()
	record["social_visit_target_id"] = social_target_id
	record["last_position"] = target_position
	record["spawn_random"] = false

	var live_npc := get_live_npc(npc_id)
	if live_npc != null:
		live_npcs.erase(npc_id)
		live_npc.queue_free()
	_move_record_to_scene(npc_id, record, target_scene_path, false)
	return true


func begin_scheduled_activity(
	npc_id: String,
	activity: Dictionary,
	target_scene_path: String,
	target_position: Vector2
) -> bool:
	if not npc_records.has(npc_id) or target_scene_path.is_empty() or activity.is_empty():
		_breadcrumb("npc_locations:begin_activity_reject", npc_id)
		return false
	# Canonicalize identity before validation or live assignment. Compatibility callers
	# may still omit IDs, but every participant in this transaction receives the same one.
	activity = activity.duplicate(true)
	var proposed_session := NpcActionSessionModel.create(
		npc_id,
		StringName(String(activity.get("state_name", activity.get("action_kind", "")))),
		StringName(String(activity.get("source", "schedule"))),
		null,
		activity
	)
	if proposed_session == null or proposed_session.action_kind == &"":
		_breadcrumb("npc_locations:begin_activity_session_reject", npc_id)
		return false
	var proposed_session_id := proposed_session.session_id
	activity["session_id"] = proposed_session_id
	activity["action_session_id"] = proposed_session_id
	activity["activity_id"] = String(activity.get("activity_id", proposed_session_id))
	activity["source"] = String(activity.get("source", "schedule"))
	activity["status"] = "proposed"

	_breadcrumb(
		"npc_locations:begin_activity_start",
		"%s %s -> %s" % [npc_id, String(activity.get("spot_id", "")), target_scene_path.get_file()]
	)
	var record: Dictionary = (npc_records[npc_id] as Dictionary).duplicate(true)
	var from_scene_path := String(record.get("scene_path", ""))
	var live_npc := get_live_npc(npc_id)
	if live_npc != null and not _capture_live_npc_into_record(npc_id, live_npc, record):
		_breadcrumb("npc_locations:begin_activity_capture_reject", npc_id)
		return false
	var spawn_position := _get_activity_arrival_position(
		from_scene_path,
		target_scene_path,
		target_position
	)
	# A live NPC starting an activity in the current scene must walk to its spot.
	# The target position is only a spawn/simulation endpoint for unloaded travel.
	if (
		live_npc != null
		and target_scene_path == get_current_scene_path()
	):
		spawn_position = _get_node_position(live_npc)

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("accept_scheduled_activity_proposal"):
		_breadcrumb("npc_locations:begin_activity_no_transaction_coordinator", npc_id)
		return false
	var requires_live_assignment := (
		live_npc != null
		and target_scene_path == get_current_scene_path()
	)
	var proposal_result = simulator.call(
		"accept_scheduled_activity_proposal",
		StringName(npc_id),
		activity,
		target_scene_path,
		live_npc,
		requires_live_assignment,
		self
	)
	if not (proposal_result is Dictionary) or not bool(proposal_result.get("accepted", false)):
		if proposal_result is Dictionary and bool(proposal_result.get("clear_pending", false)):
			_rollback_pending_activity_record(npc_id, activity)
		var rejection_reason := (
			String(proposal_result.get("reason", "proposal_rejected"))
			if proposal_result is Dictionary
			else "invalid_proposal_result"
		)
		_breadcrumb(
			"npc_locations:begin_activity_assignment_reject",
			"%s %s" % [npc_id, rejection_reason]
		)
		return false

	var committed_activity := activity.duplicate(true)
	var action_session := NpcActionSessionModel.from_legacy_activity(npc_id, committed_activity)
	if action_session == null:
		_breadcrumb("npc_locations:begin_activity_session_reject", npc_id)
		return false
	action_session.status = NpcActionSession.Status.ACTIVE
	var action_descriptor := action_session.to_descriptor()
	var session_id := action_session.session_id
	committed_activity["session_id"] = session_id
	committed_activity["action_session_id"] = session_id
	committed_activity["activity_id"] = String(committed_activity.get("activity_id", session_id))
	committed_activity["source"] = String(committed_activity.get("source", "schedule"))
	committed_activity["status"] = "active"
	record["activity"] = committed_activity
	record["action"] = action_descriptor
	record["pending_travel"] = {}
	record["previous_scene_path"] = ""
	record["scene_path"] = target_scene_path
	record["last_position"] = spawn_position
	record["spawn_random"] = false
	record["last_travel_msec"] = Time.get_ticks_msec()
	npc_records[npc_id] = record
	if simulator.has_method("confirm_scheduled_activity_proposal"):
		simulator.call(
			"confirm_scheduled_activity_proposal",
			StringName(npc_id),
			committed_activity
		)

	if live_npc != null and target_scene_path != get_current_scene_path():
		live_npcs.erase(npc_id)
		live_npc.queue_free()
		live_npc = null

	if from_scene_path != target_scene_path:
		npc_travelled.emit(npc_id, from_scene_path, target_scene_path)
		_emit_location_event(npc_id, from_scene_path, target_scene_path)

	if target_scene_path == active_scene_path:
		if live_npc != null:
			if not bool(proposal_result.get("live_assigned", false)):
				_resume_scheduled_activity_deferred(npc_id, live_npc)
		else:
			call_deferred("_spawn_missing_npcs_for_active_scene")

	_update_return_processing()
	_breadcrumb("npc_locations:begin_activity_end", "%s %s" % [npc_id, String(activity.get("spot_id", ""))])
	return true


func update_simulated_record(npc_id: String, record: Dictionary) -> void:
	if not npc_records.has(npc_id) or is_npc_live(npc_id):
		return

	npc_records[npc_id] = record.duplicate(true)


func sync_live_action_descriptor(npc_id: String, npc: Node, descriptor: Dictionary) -> bool:
	if npc_id.is_empty() or not npc_records.has(npc_id):
		return false
	var registered_npc = live_npcs.get(npc_id, null)
	if registered_npc != null and registered_npc != npc:
		return false
	var record: Dictionary = npc_records[npc_id]
	var activity = record.get("activity", {})
	if activity is Dictionary and not activity.is_empty():
		var activity_session_id := NpcActionSessionModel._descriptor_session_id(activity)
		var action_session_id := NpcActionSessionModel._descriptor_session_id(descriptor)
		if (
			not activity_session_id.is_empty()
			and action_session_id != activity_session_id
		):
			record["activity"] = {}
	record["action"] = descriptor.duplicate(true)
	npc_records[npc_id] = record
	return true


func update_simulated_social_pair(
	first_npc_id: String,
	first_record: Dictionary,
	second_npc_id: String,
	second_record: Dictionary
) -> bool:
	# Validate the whole pair before either saved record changes.
	if (
		first_npc_id.is_empty()
		or second_npc_id.is_empty()
		or first_npc_id == second_npc_id
		or first_record.is_empty()
		or second_record.is_empty()
		or not npc_records.has(first_npc_id)
		or not npc_records.has(second_npc_id)
		or is_npc_live(first_npc_id)
		or is_npc_live(second_npc_id)
	):
		return false

	npc_records[first_npc_id] = first_record.duplicate(true)
	npc_records[second_npc_id] = second_record.duplicate(true)
	return true


func set_scheduled_activity_field(
	npc_id: String,
	field_name: StringName,
	value
) -> bool:
	if not npc_records.has(npc_id) or field_name == &"":
		return false

	_refresh_live_record(npc_id)
	var record: Dictionary = npc_records[npc_id]
	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return false

	var updated_activity: Dictionary = activity
	updated_activity[String(field_name)] = value
	record["activity"] = updated_activity
	npc_records[npc_id] = record
	return true


func transition_scheduled_activity(
	npc_id: StringName,
	expected_session_id: StringName,
	updates: Dictionary
) -> Dictionary:
	var npc_key := String(npc_id).strip_edges()
	var expected_session := String(expected_session_id).strip_edges()
	if npc_key.is_empty() or expected_session.is_empty():
		return {"accepted": false, "reason": "invalid_identity"}
	if updates.is_empty():
		return {"accepted": false, "reason": "updates_empty"}
	for protected_field in [
		"session_id", "action_session_id", "activity_id", "spot_id",
		"reservation_ids", "source", "priority",
	]:
		if updates.has(protected_field):
			return {"accepted": false, "reason": "identity_update_forbidden"}
	if not npc_records.has(npc_key):
		return {"accepted": false, "reason": "npc_record_missing"}

	var current_record: Dictionary = npc_records[npc_key]
	var activity_value = current_record.get("activity", {})
	if not (activity_value is Dictionary) or activity_value.is_empty():
		return {"accepted": false, "reason": "scheduled_activity_missing"}
	var activity: Dictionary = activity_value
	var activity_session := NpcActionSessionModel._descriptor_session_id(activity)
	if activity_session != expected_session:
		_log_lesson_transition(
			npc_key, expected_session, activity, updates, false, "stale_activity_session"
		)
		return {"accepted": false, "reason": "stale_activity_session"}

	var action_value = current_record.get("action", {})
	var action: Dictionary = action_value if action_value is Dictionary else {}
	if not action.is_empty():
		var action_session := NpcActionSessionModel._descriptor_session_id(action)
		if action_session != expected_session:
			_log_lesson_transition(
				npc_key, expected_session, activity, updates, false, "activity_action_session_mismatch"
			)
			return {"accepted": false, "reason": "activity_action_session_mismatch"}

	var old_phase := String(activity.get("lesson_phase", "inviting"))
	var expected_phases = updates.get("expected_lesson_phases", [])
	if expected_phases is Array or expected_phases is PackedStringArray:
		if not expected_phases.is_empty():
			var phase_allowed := false
			for expected_phase in expected_phases:
				if String(expected_phase) == old_phase:
					phase_allowed = true
					break
			if not phase_allowed:
				_log_lesson_transition(
					npc_key, expected_session, activity, updates, false, "unexpected_lesson_phase"
				)
				return {"accepted": false, "reason": "unexpected_lesson_phase"}

	var spot_id := StringName(String(activity.get("spot_id", "")))
	var purpose := StringName(String(activity.get("reservation_purpose", "activity")))
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("session_owns_spot"):
		return {"accepted": false, "reason": "reservation_service_missing"}
	if not bool(simulator.call(
		"session_owns_spot", npc_id, expected_session, spot_id, purpose
	)):
		_log_lesson_transition(
			npc_key, expected_session, activity, updates, false, "lesson_reservation_missing"
		)
		return {"accepted": false, "reason": "lesson_reservation_missing"}

	var reservation_id := ""
	if simulator.has_method("make_spot_reservation_id"):
		reservation_id = String(simulator.call(
			"make_spot_reservation_id", expected_session, spot_id, purpose
		))
	var activity_reservation_ids = activity.get("reservation_ids", [])
	if (
		not reservation_id.is_empty()
		and (activity_reservation_ids is Array or activity_reservation_ids is PackedStringArray)
		and not activity_reservation_ids.has(reservation_id)
	):
		_log_lesson_transition(
			npc_key, expected_session, activity, updates, false, "activity_reservation_reference_missing"
		)
		return {"accepted": false, "reason": "activity_reservation_reference_missing"}
	if not action.is_empty() and not reservation_id.is_empty():
		var action_reservation_ids = action.get("reservation_ids", [])
		if (
			not (action_reservation_ids is Array or action_reservation_ids is PackedStringArray)
			or not action_reservation_ids.has(reservation_id)
		):
			_log_lesson_transition(
				npc_key, expected_session, activity, updates, false, "action_reservation_reference_missing"
			)
			return {"accepted": false, "reason": "action_reservation_reference_missing"}

	var updated_record := current_record.duplicate(true)
	var updated_activity: Dictionary = activity.duplicate(true)
	var allowed_activity_fields := [
		"lesson_phase", "target_scene_path", "target_position", "lesson_scene_path",
		"lesson_position", "last_total_hours", "lesson_score",
	]
	for field_name in allowed_activity_fields:
		if updates.has(field_name):
			updated_activity[field_name] = updates[field_name]
	updated_record["activity"] = updated_activity

	var updated_action := action.duplicate(true)
	if updated_action.is_empty():
		var restored_action := NpcActionSessionModel.from_legacy_activity(npc_key, updated_activity)
		if restored_action == null:
			return {"accepted": false, "reason": "action_restore_failed"}
		restored_action.status = NpcActionSession.Status.ACTIVE
		updated_action = restored_action.to_descriptor()
	var metadata = updated_action.get("metadata", {})
	if not (metadata is Dictionary):
		metadata = {}
	else:
		metadata = metadata.duplicate(true)
	for lesson_field in ["lesson_phase", "lesson_scene_path", "lesson_position", "lesson_score"]:
		if updates.has(lesson_field):
			metadata[lesson_field] = updates[lesson_field]
	var metadata_updates = updates.get("action_metadata", {})
	if metadata_updates is Dictionary:
		for key in metadata_updates.keys():
			metadata[String(key)] = metadata_updates[key]
	updated_action["metadata"] = metadata
	if updates.has("target_scene_path"):
		updated_action["scene_path"] = String(updates["target_scene_path"])
	updated_record["action"] = updated_action

	var relocate_npc := bool(updates.get("relocate_npc", false))
	var from_scene_path := String(current_record.get("scene_path", ""))
	var target_scene_path := String(updated_activity.get("target_scene_path", from_scene_path))
	var target_position = updated_activity.get("target_position", current_record.get(
		"last_position", Vector2.ZERO
	))
	if relocate_npc:
		if target_scene_path.is_empty() or not (target_position is Vector2):
			return {"accepted": false, "reason": "invalid_relocation_destination"}
		var live_npc := get_live_npc(npc_key)
		if live_npc != null and not _capture_live_npc_into_record(npc_key, live_npc, updated_record):
			return {"accepted": false, "reason": "live_npc_capture_failed"}
		# Capture refreshes the action descriptor; restore the validated transition copy.
		updated_record["activity"] = updated_activity
		updated_record["action"] = updated_action
		updated_record["previous_scene_path"] = ""
		updated_record["scene_path"] = target_scene_path
		updated_record["last_position"] = target_position
		updated_record["spawn_random"] = false
		updated_record["pending_travel"] = {}
		updated_record["last_travel_msec"] = Time.get_ticks_msec()

	var live_npc := get_live_npc(npc_key)
	if live_npc != null:
		var machine := live_npc.get_node_or_null("NpcStateMachine")
		if machine != null and machine.has_method("update_active_action_metadata"):
			if not bool(machine.call(
				"update_active_action_metadata",
				expected_session,
				metadata,
				String(updated_action.get("scene_path", "")),
				false
			)):
				return {"accepted": false, "reason": "live_action_session_mismatch"}

	npc_records[npc_key] = updated_record
	if relocate_npc and live_npc != null:
		live_npcs.erase(npc_key)
		live_npc.queue_free()
	if relocate_npc and from_scene_path != target_scene_path:
		npc_travelled.emit(npc_key, from_scene_path, target_scene_path)
		_emit_location_event(npc_key, from_scene_path, target_scene_path)
	if relocate_npc and target_scene_path == active_scene_path:
		call_deferred("_spawn_missing_npcs_for_active_scene")
	_update_return_processing()
	_log_lesson_transition(npc_key, expected_session, activity, updates, true, "accepted")
	return {
		"accepted": true,
		"reason": "accepted",
		"session_id": expected_session,
		"reservation_id": reservation_id,
		"old_lesson_phase": old_phase,
		"lesson_phase": String(updated_activity.get("lesson_phase", old_phase)),
		"scene_path": String(updated_record.get("scene_path", "")),
	}


func _log_lesson_transition(
	npc_id: String,
	session_id: String,
	activity: Dictionary,
	updates: Dictionary,
	accepted: bool,
	reason: String
) -> void:
	if not OS.is_debug_build():
		return
	var old_phase := String(activity.get("lesson_phase", "inviting"))
	var new_phase := String(updates.get("lesson_phase", old_phase))
	var reservation_ids = activity.get("reservation_ids", [])
	print("Magic lesson transition: npc=%s session=%s phase=%s->%s scene=%s reservation=%s accepted=%s reason=%s" % [
		npc_id, session_id, old_phase, new_phase,
		String(updates.get("target_scene_path", activity.get("target_scene_path", ""))),
		str(reservation_ids), str(accepted), reason,
	])


func apply_simulated_record(
	npc_id: String,
	record: Dictionary,
	apply_to_live_npc: bool = true
) -> void:
	# Time skips can update both unloaded records and live NPC bodies in one place.
	if npc_id.is_empty() or record.is_empty():
		return

	var previous_scene_path := ""
	if npc_records.has(npc_id) and npc_records[npc_id] is Dictionary:
		previous_scene_path = String(npc_records[npc_id].get("scene_path", ""))
	var accepted_live_npc := get_live_npc(npc_id)
	if accepted_live_npc != null:
		_capture_live_inventory_into_record(npc_id, accepted_live_npc, record)

	npc_records[npc_id] = record.duplicate(true)
	if not apply_to_live_npc:
		_update_return_processing()
		return

	var live_npc := get_live_npc(npc_id)
	if live_npc == null:
		if String(record.get("scene_path", "")) == active_scene_path:
			call_deferred("_spawn_missing_npcs_for_active_scene")
		_update_return_processing()
		return

	var target_scene_path := String(record.get("scene_path", ""))
	var live_scene_path := _get_live_npc_scene_path(live_npc, previous_scene_path)
	if not target_scene_path.is_empty() and target_scene_path != live_scene_path:
		live_npcs.erase(npc_id)
		live_npc.queue_free()
		if target_scene_path == active_scene_path:
			call_deferred("_spawn_missing_npcs_for_active_scene")
		_update_return_processing()
		return

	if live_npc.has_method("apply_npc_location_save_data"):
		live_npc.call("apply_npc_location_save_data", record.get("node_state", {}))
	var position_value = record.get("last_position", null)
	if position_value is Vector2:
		_place_npc(live_npc, position_value)
		record["last_position"] = _get_node_position(live_npc)
		npc_records[npc_id] = record.duplicate(true)
	_update_return_processing()


func finish_scheduled_activity(
	npc_id: String,
	return_scene_path: String,
	return_position: Vector2,
	expected_session_id: String = ""
) -> bool:
	if not npc_records.has(npc_id):
		_breadcrumb("npc_locations:finish_activity_reject", npc_id)
		return false

	_breadcrumb("npc_locations:finish_activity_start", "%s -> %s" % [npc_id, return_scene_path.get_file()])
	_refresh_live_record(npc_id)
	var record: Dictionary = npc_records[npc_id]
	var committed_activity = record.get("activity", {})
	var committed_session_id := (
		NpcActionSessionModel._descriptor_session_id(committed_activity)
		if committed_activity is Dictionary
		else ""
	)
	var record_action = record.get("action", {})
	var record_action_session_id := (
		NpcActionSessionModel._descriptor_session_id(record_action)
		if record_action is Dictionary
		else ""
	)
	if not expected_session_id.is_empty() and committed_session_id != expected_session_id:
		_breadcrumb(
			"npc_locations:finish_activity_stale",
			"%s callback=%s active=%s" % [npc_id, expected_session_id, committed_session_id]
		)
		return false
	if (
		not expected_session_id.is_empty()
		and not record_action_session_id.is_empty()
		and record_action_session_id != expected_session_id
	):
		_breadcrumb(
			"npc_locations:finish_activity_stale_action",
			"%s callback=%s active=%s" % [npc_id, expected_session_id, record_action_session_id]
		)
		return false
	var committed_spot_id := &""
	if committed_activity is Dictionary:
		committed_spot_id = StringName(String(committed_activity.get("spot_id", "")))
	var from_scene_path := String(record.get("scene_path", ""))
	var destination_scene_path := return_scene_path if not return_scene_path.is_empty() else from_scene_path
	var live_npc := get_live_npc(npc_id)
	var spawn_position := _get_activity_arrival_position(
		from_scene_path,
		destination_scene_path,
		return_position
	)
	# Finishing an activity in the same loaded scene should not snap the NPC back
	# to the position where the activity originally began.
	if (
		live_npc != null
		and from_scene_path == destination_scene_path
		and destination_scene_path == get_current_scene_path()
	):
		spawn_position = _get_node_position(live_npc)
	record["activity"] = {}
	record["action"] = {}
	record["pending_travel"] = {}
	record["previous_scene_path"] = ""
	record["scene_path"] = destination_scene_path
	record["last_position"] = spawn_position
	record["spawn_random"] = false
	record["last_travel_msec"] = Time.get_ticks_msec()
	npc_records[npc_id] = record
	_notify_activity_claim_release(
		committed_spot_id, "activity_finished", committed_session_id, StringName(npc_id)
	)

	if live_npc != null and String(record["scene_path"]) != get_current_scene_path():
		live_npcs.erase(npc_id)
		live_npc.queue_free()
		live_npc = null

	destination_scene_path = String(record["scene_path"])
	if from_scene_path != destination_scene_path:
		npc_travelled.emit(npc_id, from_scene_path, destination_scene_path)
		_emit_location_event(npc_id, from_scene_path, destination_scene_path)

	if destination_scene_path == active_scene_path:
		if live_npc == null:
			call_deferred("_spawn_missing_npcs_for_active_scene")

	_update_return_processing()
	_breadcrumb("npc_locations:finish_activity_end", "%s -> %s" % [npc_id, destination_scene_path.get_file()])
	return true


func get_save_data() -> Dictionary:
	synchronize_live_records()
	return {
		"active_scene_path": active_scene_path,
		"return_timer": return_timer,
		"records": npc_records.duplicate(true),
	}


func apply_save_data(data: Dictionary) -> void:
	_breadcrumb("npc_locations:apply_save_start", "")
	live_npcs.clear()
	npc_records.clear()
	active_scene_context = null
	active_scene_path = ""
	return_timer = 0.0

	var saved_records = data.get("records", data)
	if not (saved_records is Dictionary):
		_update_return_processing()
		return

	for npc_id_key in saved_records.keys():
		var saved_record = saved_records[npc_id_key]
		if not (saved_record is Dictionary):
			continue

		var npc_id := String(npc_id_key).strip_edges()
		if npc_id.is_empty():
			npc_id = String(saved_record.get("npc_id", "")).strip_edges()
		if npc_id.is_empty():
			continue

		_breadcrumb("npc_locations:restore_record", npc_id)
		npc_records[npc_id] = _normalize_loaded_record(npc_id, saved_record)

	_update_return_processing()
	_breadcrumb("npc_locations:apply_save_end", "records=%d" % npc_records.size())


func get_npc_id(npc: Node) -> String:
	if npc == null:
		return ""

	if npc.has_method("get_npc_location_id"):
		var method_id := String(npc.call("get_npc_location_id")).strip_edges()
		if not method_id.is_empty():
			return method_id

	if npc.has_meta("npc_location_id"):
		var meta_id := String(npc.get_meta("npc_location_id")).strip_edges()
		if not meta_id.is_empty():
			return meta_id

	if npc.has_method("get_relationship_id"):
		var relationship_id := String(npc.call("get_relationship_id")).strip_edges()
		if not relationship_id.is_empty():
			return relationship_id

	if npc.is_inside_tree():
		return String(npc.get_path())

	return ""


func get_current_scene_path() -> String:
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return ""

	return current_scene.scene_file_path


func _build_initial_record(
	npc_id: String,
	npc: Node,
	current_scene_path: String,
	npc_scene_path: String
) -> Dictionary:
	return {
		"npc_id": npc_id,
		"node_name": npc.name,
		"npc_scene_path": npc_scene_path,
		"home_scene_path": current_scene_path,
		"home_position": _get_node_position(npc),
		"scene_path": current_scene_path,
		"previous_scene_path": "",
		"last_position": _get_node_position(npc),
		"node_state": _get_npc_state(npc),
		"activity": {},
		"action": {},
		"pending_travel": {},
		"social_visit_target_id": "",
		"social_session_id": "",
		"social_session_partner_id": "",
		"last_completed_social_session_id": "",
		"inventory": _fresh_empty_inventory_save_data(),
		"last_simulated_total_hours": _get_world_total_hours(),
		"spawn_random": false,
		"last_travel_msec": 0,
	}


func _refresh_record_from_node(record: Dictionary, npc: Node, npc_scene_path: String) -> void:
	record["node_name"] = npc.name
	if String(record.get("npc_scene_path", "")).is_empty() and not npc_scene_path.is_empty():
		record["npc_scene_path"] = npc_scene_path


func _refresh_live_records_for_save() -> void:
	for npc_id_key in live_npcs.keys():
		var npc_id := String(npc_id_key)
		var live_npc = live_npcs[npc_id_key] as Node
		if live_npc == null or not is_instance_valid(live_npc) or live_npc.is_queued_for_deletion():
			live_npcs.erase(npc_id_key)
			continue

		var current_scene_path := get_current_scene_path()
		var npc_scene_path := _get_npc_scene_path(live_npc)
		var record: Dictionary = {}

		if npc_records.has(npc_id) and npc_records[npc_id] is Dictionary:
			record = npc_records[npc_id]
		else:
			record = _build_initial_record(npc_id, live_npc, current_scene_path, npc_scene_path)
		var repaired_activity := _repair_mismatched_activity_record(record)
		if repaired_activity:
			var repaired_position = record.get("last_position", null)
			if repaired_position is Vector2:
				_place_npc(live_npc, repaired_position)
			var machine := live_npc.get_node_or_null("NpcStateMachine")
			if machine != null and machine.has_method("request_state"):
				machine.call_deferred("request_state", &"Idle", null, "repair_activity_location", 100)

		var recorded_scene_path := String(record.get("scene_path", ""))
		current_scene_path = _get_live_npc_scene_path(
			live_npc,
			recorded_scene_path if not recorded_scene_path.is_empty() else current_scene_path
		)

		_refresh_record_from_node(record, live_npc, npc_scene_path)
		record["scene_path"] = current_scene_path
		_capture_live_npc_into_record(npc_id, live_npc, record)
		npc_records[npc_id] = record


func _get_live_npc_scene_path(npc: Node, fallback: String) -> String:
	# During change_scene(), the new current scene can exist briefly while the old NPC is exiting.
	# Only claim the current scene when the NPC is actually parented beneath it.
	if npc == null or not is_instance_valid(npc) or not npc.is_inside_tree():
		return fallback

	var current_scene := get_tree().current_scene
	if current_scene == null:
		return fallback
	if current_scene == npc or current_scene.is_ancestor_of(npc):
		return current_scene.scene_file_path

	return fallback


func _refresh_live_record(npc_id: String) -> void:
	var live_npc := get_live_npc(npc_id)
	if live_npc == null or not npc_records.has(npc_id):
		return

	var record: Dictionary = npc_records[npc_id]
	_capture_live_npc_into_record(npc_id, live_npc, record)
	npc_records[npc_id] = record


func _capture_live_npc_into_record(npc_id: String, npc: Node, record: Dictionary) -> bool:
	_refresh_record_from_node(record, npc, _get_npc_scene_path(npc))
	record["last_position"] = _get_node_position(npc)
	record["node_state"] = _get_npc_state(npc)
	record["last_simulated_total_hours"] = _get_world_total_hours()
	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine != null and machine.has_method("get_active_action_descriptor"):
		record["action"] = machine.call("get_active_action_descriptor")
	return _capture_live_inventory_into_record(npc_id, npc, record)


func _capture_live_inventory_into_record(npc_id: String, npc: Node, record: Dictionary) -> bool:
	if not _has_live_inventory_api(npc):
		if npc is SocialNpc:
			push_error("Persistent SocialNpc '%s' cannot be captured without its inventory component API." % npc_id)
			return false
		if not record.has("inventory"):
			record["inventory"] = _fresh_empty_inventory_save_data()
		return true
	var inventory_data = npc.call("get_inventory_save_data")
	if not (inventory_data is Dictionary) or inventory_data.is_empty():
		push_error("Persistent NPC '%s' returned invalid empty inventory save data." % npc_id)
		return false
	record["inventory"] = inventory_data.duplicate(true)
	return true


func _restore_record_inventory_to_live_npc(npc_id: String, npc: Node, record: Dictionary) -> bool:
	if not _has_live_inventory_api(npc):
		if npc is SocialNpc:
			push_error("Persistent SocialNpc '%s' cannot restore inventory: component API is missing." % npc_id)
			return false
		return true
	if not record.has("inventory"):
		npc.call("reset_inventory")
		return _capture_live_inventory_into_record(npc_id, npc, record)

	var saved_inventory = record["inventory"]
	var result: InventoryResult
	if saved_inventory is Dictionary:
		result = npc.call("apply_inventory_save_data", saved_inventory)
	else:
		result = InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"NPC record inventory must be a dictionary."
		)
	if result != null and result.success:
		return true

	var code_text := "unknown"
	var message_text := "Inventory restoration returned no result."
	if result != null:
		code_text = str(result.code)
		message_text = result.message
	push_warning(
		"NPC inventory restore failed for '%s' (code %s): %s Preserving live inventory."
		% [npc_id, code_text, message_text]
	)
	return _capture_live_inventory_into_record(npc_id, npc, record)


func _has_live_inventory_api(npc: Node) -> bool:
	return (
		npc != null
		and npc.has_method("get_inventory_save_data")
		and npc.has_method("apply_inventory_save_data")
		and npc.has_method("reset_inventory")
	)


func _fresh_empty_inventory_save_data() -> Dictionary:
	return InventoryModel.get_empty_save_data()


func _normalize_loaded_record(npc_id: String, saved_record: Dictionary) -> Dictionary:
	var record := saved_record.duplicate(true)
	record["npc_id"] = String(record.get("npc_id", npc_id))
	record["node_name"] = String(record.get("node_name", npc_id))
	record["npc_scene_path"] = String(record.get("npc_scene_path", ""))
	record["home_scene_path"] = String(record.get("home_scene_path", ""))
	record["scene_path"] = String(record.get("scene_path", ""))
	record["previous_scene_path"] = String(record.get("previous_scene_path", ""))
	record["spawn_random"] = bool(record.get("spawn_random", false))
	record["social_visit_target_id"] = String(record.get("social_visit_target_id", ""))
	record["social_session_id"] = String(record.get("social_session_id", ""))
	record["social_session_partner_id"] = String(record.get("social_session_partner_id", ""))
	record["last_completed_social_session_id"] = String(
		record.get("last_completed_social_session_id", "")
	)

	if not (record.get("last_position", null) is Vector2):
		record["last_position"] = Vector2.ZERO
	if not (record.get("home_position", null) is Vector2):
		var home_activity = record.get("activity", {})
		var activity_return_position = (
			home_activity.get("return_position", null)
			if home_activity is Dictionary
			else null
		)
		if activity_return_position is Vector2:
			record["home_position"] = activity_return_position
		else:
			record["home_position"] = record["last_position"]
	if String(record.get("home_scene_path", "")).is_empty():
		var home_scene_activity = record.get("activity", {})
		var activity_return_scene := (
			String(home_scene_activity.get("return_scene_path", ""))
			if home_scene_activity is Dictionary
			else ""
		)
		if not activity_return_scene.is_empty():
			record["home_scene_path"] = activity_return_scene

	if not (record.get("node_state", null) is Dictionary):
		record["node_state"] = {}
	if not (record.get("activity", null) is Dictionary):
		record["activity"] = {}
	if not (record.get("action", null) is Dictionary):
		record["action"] = {}
	var loaded_action: Dictionary = record["action"]
	var loaded_activity: Dictionary = record["activity"]
	if loaded_action.is_empty() and not loaded_activity.is_empty():
		var translated_action := NpcActionSessionModel.from_legacy_activity(npc_id, loaded_activity)
		if translated_action != null:
			record["action"] = translated_action.to_descriptor()
			loaded_activity["session_id"] = translated_action.session_id
			loaded_activity["action_session_id"] = translated_action.session_id
			loaded_activity["activity_id"] = String(loaded_activity.get(
				"activity_id", translated_action.session_id
			))
			record["activity"] = loaded_activity
	elif not loaded_action.is_empty():
		var normalized_action := NpcActionSessionModel.create(
			npc_id,
			StringName(String(loaded_action.get("action_kind", loaded_action.get("state_name", "")))),
			StringName(String(loaded_action.get("source", "manual"))),
			null,
			loaded_action
		)
		if normalized_action != null and normalized_action.action_kind != &"":
			record["action"] = normalized_action.to_descriptor()
	if not (record.get("pending_travel", null) is Dictionary):
		record["pending_travel"] = {}
	_normalize_record_spot_reservations(npc_id, record)
	_normalize_lesson_action_metadata(record)
	if not record.has("inventory"):
		# Missing inventory is the supported old-save case; malformed present data is
		# deferred until an accepted live component can validate it atomically.
		record["inventory"] = _fresh_empty_inventory_save_data()
	if not record.has("last_simulated_total_hours"):
		record["last_simulated_total_hours"] = _get_world_total_hours()

	if String(record.get("scene_path", "")).is_empty():
		record["scene_path"] = String(record.get("home_scene_path", ""))

	if not String(record.get("previous_scene_path", "")).is_empty():
		record["last_travel_msec"] = Time.get_ticks_msec()
	else:
		record["last_travel_msec"] = int(record.get("last_travel_msec", 0))

	_repair_mismatched_activity_record(record)
	return record


func _repair_mismatched_activity_record(record: Dictionary) -> bool:
	# A committed activity belongs to its target scene. Older transition races could save
	# the target coordinates under the source scene, making the NPC appear to disappear.
	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return false

	var target_scene_path := String(activity.get("target_scene_path", ""))
	if target_scene_path.is_empty():
		var endpoint := _get_activity_endpoint(activity)
		target_scene_path = String(endpoint.get("scene_path", ""))
	if target_scene_path.is_empty() or target_scene_path == String(record.get("scene_path", "")):
		return false

	var return_scene_path := String(activity.get("return_scene_path", ""))
	var return_position = activity.get("return_position", null)
	if return_scene_path == String(record.get("scene_path", "")) and return_position is Vector2:
		record["last_position"] = return_position

	record["activity"] = {}
	record["action"] = {}
	record["pending_travel"] = {}
	return true


func _normalize_record_spot_reservations(npc_id: String, record: Dictionary) -> void:
	var descriptors: Array[Dictionary] = []
	for key in [&"action", &"activity"]:
		var descriptor = record.get(key, {})
		if descriptor is Dictionary and not descriptor.is_empty():
			descriptors.append(descriptor)
	var pending = record.get("pending_travel", {})
	if pending is Dictionary and not pending.is_empty():
		var pending_activity = pending.get("activity", {})
		if pending_activity is Dictionary and not pending_activity.is_empty():
			descriptors.append(pending_activity)
	var repairs := 0
	for descriptor in descriptors:
		var session_id := NpcActionSessionModel._descriptor_session_id(descriptor)
		var spot_id := String(descriptor.get("spot_id", "")).strip_edges()
		if session_id.is_empty() or spot_id.is_empty():
			continue
		var purpose := String(descriptor.get("reservation_purpose", "activity"))
		var exact_id := "%s|%s|%s" % [session_id, spot_id, purpose]
		var status := String(descriptor.get("status", "active"))
		var terminal := status in ["completed", "failed", "cancelled", "cancelling"]
		var normalized_ids: Array[String] = []
		var values = descriptor.get("reservation_ids", [])
		if values is Array or values is PackedStringArray:
			for value in values:
				var reservation_id := String(value).strip_edges()
				if reservation_id.is_empty():
					continue
				if reservation_id.begins_with("spot:") or reservation_id.begins_with("%s|" % session_id):
					repairs += 1
					continue
				if reservation_id not in normalized_ids:
					normalized_ids.append(reservation_id)
		if not terminal:
			normalized_ids.append(exact_id)
		descriptor["reservation_ids"] = normalized_ids
	if OS.is_debug_build() and repairs > 0:
		print("NPC reservation migration: npc=%s repaired_ids=%d" % [npc_id, repairs])


func _normalize_lesson_action_metadata(record: Dictionary) -> void:
	var activity = record.get("activity", {})
	var action = record.get("action", {})
	if not (activity is Dictionary) or activity.is_empty():
		return
	if not (action is Dictionary) or action.is_empty():
		return
	if not activity.has("lesson_phase"):
		return
	if (
		NpcActionSessionModel._descriptor_session_id(activity)
		!= NpcActionSessionModel._descriptor_session_id(action)
	):
		return
	var metadata = action.get("metadata", {})
	if not (metadata is Dictionary):
		metadata = {}
	else:
		metadata = metadata.duplicate(true)
	metadata["lesson_phase"] = String(activity.get("lesson_phase", "inviting"))
	action["metadata"] = metadata
	record["action"] = action


func _move_record_to_scene(
	npc_id: String,
	record: Dictionary,
	target_scene_path: String,
	spawn_random: bool
) -> void:
	var from_scene_path := String(record.get("scene_path", ""))
	if from_scene_path == target_scene_path:
		return

	record["previous_scene_path"] = from_scene_path
	record["scene_path"] = target_scene_path
	record["spawn_random"] = spawn_random
	record["last_travel_msec"] = Time.get_ticks_msec()
	npc_records[npc_id] = record

	npc_travelled.emit(npc_id, from_scene_path, target_scene_path)
	_emit_location_event(npc_id, from_scene_path, target_scene_path)

	if target_scene_path == active_scene_path:
		call_deferred("_spawn_missing_npcs_for_active_scene")

	_update_return_processing()


func _try_return_travelling_npcs() -> void:
	var now := Time.get_ticks_msec()
	var min_travel_age_msec := int(return_check_seconds * 1000.0)
	var returned_count := 0

	for npc_id in npc_records.keys():
		var record: Dictionary = npc_records[npc_id]
		var activity = record.get("activity", {})
		if activity is Dictionary and not activity.is_empty():
			continue
		var previous_scene_path := String(record.get("previous_scene_path", ""))
		var scene_path := String(record.get("scene_path", ""))
		if previous_scene_path.is_empty() or previous_scene_path == scene_path:
			continue

		var last_travel_msec := int(record.get("last_travel_msec", 0))
		if now - last_travel_msec < min_travel_age_msec:
			continue

		if rng.randf() > return_chance_per_check:
			continue

		_return_npc_to_previous_scene(String(npc_id), record)
		returned_count += 1

	_update_return_processing()
	if returned_count > 0:
		_record_watchdog_marker(&"npc_locations:return", "%d" % returned_count)


func _return_npc_to_previous_scene(npc_id: String, record: Dictionary) -> void:
	var return_scene_path := String(record.get("previous_scene_path", ""))
	if return_scene_path.is_empty():
		return

	var live_npc = live_npcs.get(npc_id, null) as Node
	if live_npc != null and is_instance_valid(live_npc):
		_capture_live_npc_into_record(npc_id, live_npc, record)
		live_npc.queue_free()
		live_npcs.erase(npc_id)

	_move_record_to_scene(npc_id, record, return_scene_path, true)


func _spawn_missing_npcs_for_active_scene() -> void:
	if active_scene_context == null or not is_instance_valid(active_scene_context):
		_breadcrumb("npc_locations:spawn_missing_no_context", active_scene_path.get_file())
		return

	_breadcrumb("npc_locations:spawn_missing_start", active_scene_path.get_file())
	var spawned_count := 0
	var refreshed_count := 0
	for npc_id in npc_records.keys():
		var record: Dictionary = npc_records[npc_id]
		if String(record.get("scene_path", "")) != active_scene_path:
			continue
		if _realtest1_npc_is_disabled(String(npc_id)):
			_breadcrumb("npc_locations:spawn_skip_realtest1", String(npc_id))
			continue

		var live_npc = live_npcs.get(npc_id, null) as Node
		if live_npc != null and is_instance_valid(live_npc) and not live_npc.is_queued_for_deletion():
			var should_randomize_position := bool(record.get("spawn_random", false))
			_apply_record_to_npc(live_npc, record, should_randomize_position)
			_capture_live_npc_into_record(String(npc_id), live_npc, record)
			record["spawn_random"] = false
			npc_records[npc_id] = record
			_resume_scheduled_activity_deferred(String(npc_id), live_npc)
			refreshed_count += 1
			continue

		if _spawn_record_in_active_scene(String(npc_id), record):
			spawned_count += 1

	if spawned_count > 0 or refreshed_count > 0:
		_record_watchdog_marker(
			&"npc_locations:spawn_missing",
			"spawned=%d refreshed=%d" % [spawned_count, refreshed_count]
		)
	_breadcrumb("npc_locations:spawn_missing_end", "spawned=%d refreshed=%d" % [spawned_count, refreshed_count])


func _spawn_record_in_active_scene(npc_id: String, record: Dictionary) -> bool:
	_breadcrumb("npc_locations:spawn_record_start", npc_id)
	var npc_scene_path := String(record.get("npc_scene_path", ""))
	if npc_scene_path.is_empty():
		_breadcrumb("npc_locations:spawn_record_no_scene", npc_id)
		return false

	var packed_scene := load(npc_scene_path) as PackedScene
	if packed_scene == null:
		push_warning("Could not load NPC scene: %s" % npc_scene_path)
		_breadcrumb("npc_locations:spawn_record_load_failed", "%s %s" % [npc_id, npc_scene_path])
		return false

	var parent := _get_context_spawn_parent(active_scene_context)
	if parent == null:
		_breadcrumb("npc_locations:spawn_record_no_parent", npc_id)
		return false

	var npc := packed_scene.instantiate()
	npc.name = String(record.get("node_name", npc_id))

	if _has_property(npc, &"location_id"):
		npc.set("location_id", StringName(npc_id))
	if _has_property(npc, &"npc_scene_path"):
		npc.set("npc_scene_path", npc_scene_path)
	if npc.has_method("apply_npc_location_save_data"):
		npc.call("apply_npc_location_save_data", record.get("node_state", {}))
	if _has_property(npc, &"location_id"):
		npc.set("location_id", StringName(npc_id))
	if _has_property(npc, &"npc_scene_path"):
		npc.set("npc_scene_path", npc_scene_path)

	var spawn_position := _get_spawn_position(active_scene_context, npc_id, record)
	record["last_position"] = spawn_position
	record["spawn_random"] = false
	npc_records[npc_id] = record

	var npc_2d := npc as Node2D
	if npc_2d != null:
		npc_2d.position = spawn_position

	parent.add_child(npc)

	_place_npc(npc, spawn_position)

	live_npcs[npc_id] = npc
	record["last_position"] = spawn_position
	npc_records[npc_id] = record

	npc_spawned.emit(npc_id, npc, active_scene_path)
	_resume_scheduled_activity_deferred(npc_id, npc)
	_breadcrumb("npc_locations:spawn_record_end", npc_id)
	return true


func _apply_record_to_npc(npc: Node, record: Dictionary, use_random_position: bool) -> void:
	if npc.has_method("apply_npc_location_save_data"):
		npc.call("apply_npc_location_save_data", record.get("node_state", {}))
	var machine := npc.get_node_or_null("NpcStateMachine")
	var action_descriptor = record.get("action", {})
	if (
		machine != null
		and action_descriptor is Dictionary
		and not action_descriptor.is_empty()
		and machine.has_method("restore_action_descriptor")
	):
		machine.call("restore_action_descriptor", action_descriptor)

	if use_random_position:
		_place_npc(npc, _get_spawn_position(active_scene_context, get_npc_id(npc), record))
		return

	var position_value = record.get("last_position", null)
	if position_value is Vector2:
		_place_npc(npc, position_value)


func _place_npc(npc: Node, spawn_position: Vector2) -> void:
	if npc.has_method("set_npc_location_position"):
		npc.call("set_npc_location_position", spawn_position)
		return

	var npc_2d := npc as Node2D
	if npc_2d != null:
		npc_2d.global_position = spawn_position


func _get_spawn_position(scene_context: Node, npc_id: String, record: Dictionary) -> Vector2:
	if (
		bool(record.get("spawn_random", false))
		and randomize_spawn_positions
		and scene_context != null
		and scene_context.has_method("get_random_ground_spawn_position")
	):
		return scene_context.call("get_random_ground_spawn_position", npc_id)

	var position_value = record.get("last_position", Vector2.ZERO)
	if position_value is Vector2:
		return position_value

	return Vector2.ZERO


func _get_context_spawn_parent(scene_context: Node) -> Node:
	if scene_context != null and scene_context.has_method("get_spawn_parent"):
		var spawn_parent := scene_context.call("get_spawn_parent") as Node
		if spawn_parent != null:
			return spawn_parent

	return get_tree().current_scene


func _get_context_scene_path(scene_context: Node) -> String:
	if scene_context != null and scene_context.has_method("get_tracked_scene_path"):
		return String(scene_context.call("get_tracked_scene_path"))

	return get_current_scene_path()


func _get_npc_scene_path(npc: Node) -> String:
	if npc.has_method("get_npc_scene_path"):
		var method_path := String(npc.call("get_npc_scene_path")).strip_edges()
		if not method_path.is_empty():
			return method_path

	if _has_property(npc, &"npc_scene_path"):
		var property_path := String(npc.get("npc_scene_path")).strip_edges()
		if not property_path.is_empty():
			return property_path

	if not npc.scene_file_path.is_empty():
		return npc.scene_file_path

	return ""


func _get_npc_state(npc: Node) -> Dictionary:
	if npc.has_method("get_npc_location_save_data"):
		var state = npc.call("get_npc_location_save_data")
		if state is Dictionary:
			return state.duplicate(true)

	return {}


func _get_node_position(node: Node) -> Vector2:
	var node_2d := node as Node2D
	if node_2d == null:
		return Vector2.ZERO

	return node_2d.global_position


func _get_world_total_hours() -> float:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_method("get_snapshot"):
		return 0.0

	var snapshot: Dictionary = world_time.call("get_snapshot")
	return float(snapshot.get("total_hours", 0.0))


func _get_activity_arrival_position(
	from_scene_path: String,
	target_scene_path: String,
	fallback: Vector2
) -> Vector2:
	if target_scene_path != active_scene_path or from_scene_path == target_scene_path:
		return fallback

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("get_arrival_position"):
		return simulator.call("get_arrival_position", from_scene_path, fallback) as Vector2

	return fallback


func _get_activity_endpoint(activity: Dictionary) -> Dictionary:
	# Older saves may not contain the destination fields now stored directly on activities.
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("get_spot_definition"):
		return {}

	var spot_id := StringName(String(activity.get("spot_id", "")))
	var definition = simulator.call("get_spot_definition", spot_id)
	if definition == null:
		return {}

	return {
		"scene_path": String(definition.get("scene_path")),
		"position": definition.get("position"),
	}


func _emit_location_event(npc_id: String, from_scene_path: String, to_scene_path: String) -> void:
	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus == null or not event_bus.has_method("emit_scene_event"):
		return

	event_bus.call("emit_scene_event", &"npc_location_changed", {
		"npc_id": npc_id,
		"from_scene_path": from_scene_path,
		"to_scene_path": to_scene_path,
		"tags": [&"npc", &"location"],
	}, get_tree().current_scene)


func _has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return true

	return false


func _notify_activity_claim_release(
	spot_id: StringName,
	reason: String,
	session_id: String = "",
	npc_id: StringName = &""
) -> void:
	if spot_id == &"":
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("release_scheduled_activity_claim"):
		simulator.call("release_scheduled_activity_claim", spot_id, reason, session_id, npc_id)


func _resume_scheduled_activity_deferred(npc_id: String, npc: Node) -> void:
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("resume_live_activity"):
		_breadcrumb("npc_locations:resume_activity_no_sim", npc_id)
		return

	_breadcrumb("npc_locations:resume_activity_deferred", npc_id)
	simulator.call_deferred("resume_live_activity", StringName(npc_id), npc)


func _update_return_processing() -> void:
	set_process(_has_travelling_records())


func _has_travelling_records() -> bool:
	for npc_id in npc_records.keys():
		var record = npc_records[npc_id]
		if not (record is Dictionary):
			continue

		var previous_scene_path := String(record.get("previous_scene_path", ""))
		if previous_scene_path.is_empty():
			continue

		if previous_scene_path != String(record.get("scene_path", "")):
			return true

	return false


func _record_watchdog_marker(source: StringName, detail: String = "") -> void:
	var watchdog := get_node_or_null("/root/PerformanceWatchdog")
	if watchdog != null and watchdog.has_method("record_marker"):
		watchdog.call("record_marker", source, detail)


func _realtest1_npc_is_disabled(npc_id: String) -> bool:
	if not DebugToolsConfig.TROUBLESHOOTING_MODE:
		return false
	if active_scene_path != "res://scenes/testscenes/realtest1.tscn":
		return false
	if npc_id == "mom" and DebugToolsConfig.DEBUG_DISABLE_REALTEST1_MOM_NPC:
		return true
	if npc_id == "talk_partner_npc" and DebugToolsConfig.DEBUG_DISABLE_REALTEST1_TALK_PARTNER:
		return true
	return false


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
