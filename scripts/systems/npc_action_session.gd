class_name NpcActionSession extends RefCounted

const Identity = preload("res://scripts/systems/npc_identity.gd")

enum Status {
	PROPOSED,
	ACTIVE,
	CANCELLING,
	COMPLETED,
	FAILED,
}

const STATUS_NAMES := {
	Status.PROPOSED: "proposed",
	Status.ACTIVE: "active",
	Status.CANCELLING: "cancelling",
	Status.COMPLETED: "completed",
	Status.FAILED: "failed",
}

static var _sequence: int = 0

var session_id: String = ""
var action_kind: StringName = &""
var source: StringName = &"manual"
var target_persistent_id: String = ""
var spot_id: StringName = &""
var scene_path: String = ""
var priority: int = 0
var status: Status = Status.PROPOSED
var phase: StringName = &"proposed"
var arrival_state: StringName = &""
var start_world_time: float = 0.0
var reason: String = ""
var reservation_ids: PackedStringArray = PackedStringArray()
var released_reservation_ids: Dictionary = {}
var metadata: Dictionary = {}
var _live_target_ref: WeakRef


static func create(
	owner_id: String,
	action: StringName,
	action_source: StringName,
	live_target: Node = null,
	descriptor: Dictionary = {}
) -> NpcActionSession:
	var session := NpcActionSession.new()
	session.session_id = _descriptor_session_id(descriptor)
	if session.session_id.is_empty():
		session.session_id = make_session_id(owner_id, action_source, action)
	session.action_kind = StringName(String(descriptor.get("action_kind", descriptor.get("state_name", action))))
	session.source = StringName(String(descriptor.get("source", action_source)))
	session.target_persistent_id = String(descriptor.get(
		"target_persistent_id",
		descriptor.get("target_npc_id", "")
	)).strip_edges()
	session.spot_id = StringName(String(descriptor.get("spot_id", "")))
	session.scene_path = String(descriptor.get("scene_path", descriptor.get("target_scene_path", "")))
	session.priority = int(descriptor.get("priority", 0))
	var serialized_status := String(descriptor.get("status", "proposed"))
	session.status = status_from_name(serialized_status)
	session.phase = StringName(String(descriptor.get(
		"phase",
		serialized_status if not _is_lifecycle_status_name(serialized_status) else status_name(session.status)
	)))
	session.arrival_state = StringName(String(descriptor.get(
		"arrival_state",
		descriptor.get("resume_state", "")
	)))
	session.start_world_time = float(descriptor.get(
		"start_world_time",
		descriptor.get("last_total_hours", 0.0)
	))
	session.reason = String(descriptor.get("reason", ""))
	var reservation_values = descriptor.get("reservation_ids", [])
	if reservation_values is Array or reservation_values is PackedStringArray:
		for reservation_value in reservation_values:
			session.add_reservation_id(String(reservation_value))
	var released_values = descriptor.get("released_reservation_ids", [])
	if released_values is Array or released_values is PackedStringArray:
		for released_value in released_values:
			session.released_reservation_ids[String(released_value)] = true
	var descriptor_metadata = descriptor.get("metadata", {})
	if descriptor_metadata is Dictionary:
		session.metadata = descriptor_metadata.duplicate(true)
	for descriptor_key in descriptor:
		if String(descriptor_key).begins_with("schedule_"):
			session.metadata[String(descriptor_key)] = descriptor[descriptor_key]
	# Preserve scheduled identity/value hints used by exact-target activity states.
	for metadata_key in [
		"activity_id", "scheduled_activity_id", "schedule_activity_id",
		"value_name", "target_scene_path",
	]:
		if descriptor.has(metadata_key) and not session.metadata.has(metadata_key):
			session.metadata[metadata_key] = descriptor[metadata_key]
	session.set_live_target(live_target)
	if session.target_persistent_id.is_empty():
		session.target_persistent_id = get_persistent_id(live_target)
	return session


static func from_legacy_activity(owner_id: String, activity: Dictionary) -> NpcActionSession:
	if activity.is_empty():
		return null
	var translated := activity.duplicate(true)
	translated["action_kind"] = String(activity.get("state_name", activity.get("action_kind", "")))
	translated["source"] = String(activity.get("source", "schedule"))
	translated["status"] = String(activity.get("status", "active"))
	if _descriptor_session_id(translated).is_empty():
		translated["session_id"] = legacy_session_id(owner_id, activity)
	return create(owner_id, StringName(translated["action_kind"]), &"schedule", null, translated)


static func make_session_id(owner_id: String, action_source: StringName, action: StringName) -> String:
	_sequence += 1
	var clean_owner := owner_id.strip_edges()
	if clean_owner.is_empty():
		clean_owner = "npc"
	return "%s:%s:%s:%d:%d" % [
		clean_owner,
		String(action_source),
		String(action),
		Time.get_ticks_usec(),
		_sequence,
	]


static func legacy_session_id(owner_id: String, legacy: Dictionary) -> String:
	var identity := "%s|%s|%s|%s|%s" % [
		owner_id,
		String(legacy.get("state_name", legacy.get("action_kind", ""))),
		String(legacy.get("spot_id", "")),
		String(legacy.get("target_scene_path", legacy.get("scene_path", ""))),
		String(legacy.get("target_npc_id", "")),
	]
	return "legacy:%s:%s" % [owner_id, abs(identity.hash())]


func set_live_target(target: Node) -> void:
	_live_target_ref = weakref(target) if target != null and is_instance_valid(target) else null


func get_live_target() -> Node2D:
	if _live_target_ref == null:
		return null
	var target = _live_target_ref.get_ref()
	if target == null or not is_instance_valid(target):
		return null
	return target as Node2D


func add_reservation_id(reservation_id: String) -> void:
	var clean_id := reservation_id.strip_edges()
	if clean_id.is_empty() or reservation_ids.has(clean_id):
		return
	reservation_ids.append(clean_id)


func remove_reservation_id(reservation_id: String) -> bool:
	var clean_id := reservation_id.strip_edges()
	if clean_id.is_empty() or not reservation_ids.has(clean_id):
		return false
	reservation_ids.remove_at(reservation_ids.find(clean_id))
	released_reservation_ids.erase(clean_id)
	return true


func replace_reservation_ids(values) -> void:
	reservation_ids = PackedStringArray()
	if values is Array or values is PackedStringArray:
		for value in values:
			add_reservation_id(String(value))
	for released_id in released_reservation_ids.keys():
		if not reservation_ids.has(String(released_id)):
			released_reservation_ids.erase(released_id)


func claim_reservation_release(reservation_id: String) -> bool:
	var clean_id := reservation_id.strip_edges()
	if clean_id.is_empty() or released_reservation_ids.has(clean_id):
		return false
	released_reservation_ids[clean_id] = true
	return true


func to_descriptor() -> Dictionary:
	if session_id.is_empty() or action_kind == &"":
		return {}
	var descriptor := {
		"session_id": session_id,
		"action_kind": String(action_kind),
		"source": String(source),
		"priority": priority,
		"status": status_name(status),
		"phase": String(phase),
		"start_world_time": start_world_time,
	}
	if arrival_state != &"":
		descriptor["arrival_state"] = String(arrival_state)
	if not target_persistent_id.is_empty():
		descriptor["target_persistent_id"] = target_persistent_id
	if spot_id != &"":
		descriptor["spot_id"] = String(spot_id)
	if not scene_path.is_empty():
		descriptor["scene_path"] = scene_path
	if not reason.is_empty():
		descriptor["reason"] = reason
	if not reservation_ids.is_empty():
		descriptor["reservation_ids"] = Array(reservation_ids)
	if not released_reservation_ids.is_empty():
		descriptor["released_reservation_ids"] = released_reservation_ids.keys()
	if not metadata.is_empty():
		descriptor["metadata"] = metadata.duplicate(true)
		for metadata_key in metadata:
			if String(metadata_key).begins_with("schedule_"):
				descriptor[String(metadata_key)] = metadata[metadata_key]
	return descriptor


static func status_name(value: Status) -> String:
	return String(STATUS_NAMES.get(value, "failed"))


static func status_from_name(value: String) -> Status:
	match value.to_lower():
		"proposed": return Status.PROPOSED
		"active": return Status.ACTIVE
		"cancelling": return Status.CANCELLING
		"completed": return Status.COMPLETED
		_: return Status.FAILED


static func _is_lifecycle_status_name(value: String) -> bool:
	return value.to_lower() in ["proposed", "active", "cancelling", "completed", "failed"]


static func get_persistent_id(target: Node) -> String:
	return Identity.get_target_id(target, &"", true, false)


static func _descriptor_session_id(descriptor: Dictionary) -> String:
	for key in ["session_id", "action_session_id", "activity_id", "request_id"]:
		var value := String(descriptor.get(key, "")).strip_edges()
		if not value.is_empty():
			return value
	return ""


static func pending_travel_session_id(pending_travel: Dictionary) -> String:
	var activity = pending_travel.get("activity", {})
	if activity is Dictionary and not activity.is_empty():
		var activity_session := _descriptor_session_id(activity)
		if not activity_session.is_empty():
			return activity_session
	return String(pending_travel.get(
		"action_session_id",
		pending_travel.get("session_id", "")
	)).strip_edges()


static func live_npc_matches_pending_travel_session(
	npc: Node,
	pending_travel: Dictionary,
	required_state: StringName = &""
) -> bool:
	var expected_session_id := pending_travel_session_id(pending_travel)
	if expected_session_id.is_empty():
		return true
	if npc == null or not is_instance_valid(npc):
		return false
	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return false
	if machine.has_method("is_action_session_current_for_execution"):
		return bool(machine.call(
			"is_action_session_current_for_execution",
			expected_session_id,
			required_state
		))
	return (
		machine.has_method("get_active_action_session_id")
		and String(machine.call("get_active_action_session_id")).strip_edges()
			== expected_session_id
	)
