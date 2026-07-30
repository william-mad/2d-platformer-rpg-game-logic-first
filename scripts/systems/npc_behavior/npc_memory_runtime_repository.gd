class_name NpcMemoryRuntimeRepositoryService extends Node

const RUNTIME_STATE_VERSION: int = 1

var cached_snapshots_by_npc_id: Dictionary = {}
var live_registrations_by_npc_id: Dictionary = {}

var _generation_by_npc_id: Dictionary = {}
var _next_token_id: int = 1


func register_live_memory(
	npc_id: String,
	memory: NpcShortTermMemory,
	now_game_hours: float = -1.0
) -> Dictionary:
	var clean_id := npc_id.strip_edges()
	if (
		not _is_valid_npc_id(clean_id)
		or memory == null
		or not is_instance_valid(memory)
	):
		return {"accepted": false, "reason": "invalid_registration"}

	var now := _resolve_now(now_game_hours)
	var current := _get_live_registration(clean_id)
	if not current.is_empty():
		var current_memory := _registration_memory(current)
		if current_memory == memory:
			return {
				"accepted": true,
				"result": "already_registered",
				"npc_id": clean_id,
				"ownership_token": String(current.get("ownership_token", "")),
				"generation": int(current.get("generation", 0)),
				"restored_count": 0,
			}
		_capture_registration(clean_id, current, now)

	var generation := int(_generation_by_npc_id.get(clean_id, 0)) + 1
	_generation_by_npc_id[clean_id] = generation
	var ownership_token := "npc-memory:%s:%d:%d" % [
		clean_id,
		generation,
		_next_token_id,
	]
	_next_token_id += 1
	live_registrations_by_npc_id[clean_id] = {
		"npc_id": clean_id,
		"memory_ref": weakref(memory),
		"ownership_token": ownership_token,
		"generation": generation,
	}

	var restored_count := 0
	var cached_value: Variant = cached_snapshots_by_npc_id.get(clean_id, {})
	if cached_value is Dictionary:
		var cached: Dictionary = cached_value
		var snapshot = cached.get("snapshot", [])
		if snapshot is Array and not snapshot.is_empty():
			var import_result := memory.import_snapshot(
				snapshot.duplicate(true),
				now,
				true
			)
			restored_count = int(import_result.get("imported_count", 0))

	return {
		"accepted": true,
		"result": "registered",
		"npc_id": clean_id,
		"ownership_token": ownership_token,
		"generation": generation,
		"restored_count": restored_count,
	}


func capture_live_memory(
	npc_id: String,
	ownership_token: String,
	now_game_hours: float = -1.0
) -> bool:
	var clean_id := npc_id.strip_edges()
	var registration := _get_live_registration(clean_id)
	if registration.is_empty():
		return false
	if String(registration.get("ownership_token", "")) != ownership_token:
		return false
	return _capture_registration(
		clean_id,
		registration,
		_resolve_now(now_game_hours)
	)


func unregister_live_memory(
	npc_id: String,
	ownership_token: String,
	_reason: StringName = &"",
	now_game_hours: float = -1.0
) -> bool:
	var clean_id := npc_id.strip_edges()
	var registration := _get_live_registration(clean_id)
	if registration.is_empty():
		return false
	if String(registration.get("ownership_token", "")) != ownership_token:
		return false
	_capture_registration(
		clean_id,
		registration,
		_resolve_now(now_game_hours)
	)
	live_registrations_by_npc_id.erase(clean_id)
	return true


func has_live_owner(npc_id: String) -> bool:
	return not _get_live_registration(npc_id.strip_edges()).is_empty()


func get_live_owner_descriptor(npc_id: String) -> Dictionary:
	var clean_id := npc_id.strip_edges()
	var registration := _get_live_registration(clean_id)
	if registration.is_empty():
		return {}
	return {
		"npc_id": clean_id,
		"ownership_token": String(registration.get("ownership_token", "")),
		"generation": int(registration.get("generation", 0)),
	}


func get_snapshot_for_npc(
	npc_id: String,
	now_game_hours: float = -1.0
) -> Array[Dictionary]:
	var clean_id := npc_id.strip_edges()
	if clean_id.is_empty():
		return []
	var now := _resolve_now(now_game_hours)
	var registration := _get_live_registration(clean_id)
	if not registration.is_empty():
		var memory := _registration_memory(registration)
		if memory != null:
			return memory.export_snapshot(now).duplicate(true)

	var cached_value: Variant = cached_snapshots_by_npc_id.get(clean_id, {})
	if not (cached_value is Dictionary):
		return []
	var cached: Dictionary = cached_value
	var snapshot = cached.get("snapshot", [])
	if not (snapshot is Array):
		return []
	var sanitized := _sanitize_snapshot(snapshot, now)
	if sanitized.size() != snapshot.size():
		var updated: Dictionary = cached.duplicate(true)
		updated["snapshot"] = sanitized.duplicate(true)
		cached_snapshots_by_npc_id[clean_id] = updated
	return sanitized


func clear_npc_memory(npc_id: String, reason: StringName = &"runtime_reset") -> bool:
	var clean_id := npc_id.strip_edges()
	if clean_id.is_empty():
		return false
	var changed := cached_snapshots_by_npc_id.erase(clean_id)
	var registration := _get_live_registration(clean_id)
	if not registration.is_empty():
		var memory := _registration_memory(registration)
		if memory != null:
			memory.clear_all(reason)
			changed = true
	return changed


func clear_all_runtime_memory(reason: StringName = &"new_game") -> void:
	for npc_id_value in live_registrations_by_npc_id.keys():
		var npc_id := String(npc_id_value)
		var registration := _get_live_registration(npc_id)
		if registration.is_empty():
			continue
		var memory := _registration_memory(registration)
		if memory != null:
			memory.clear_all(reason)
	cached_snapshots_by_npc_id.clear()


func clear_all(reason: StringName = &"") -> void:
	clear_all_runtime_memory(reason)


func export_runtime_state(now_game_hours: float = -1.0) -> Dictionary:
	var now := _resolve_now(now_game_hours)
	_cleanup_dead_registrations()
	var all_ids: Dictionary = {}
	for npc_id in cached_snapshots_by_npc_id.keys():
		all_ids[String(npc_id)] = true
	for npc_id in live_registrations_by_npc_id.keys():
		all_ids[String(npc_id)] = true
	var ordered_ids: Array[String] = []
	for npc_id in all_ids.keys():
		ordered_ids.append(String(npc_id))
	ordered_ids.sort()

	var entries: Dictionary = {}
	for npc_id in ordered_ids:
		var cached_value: Variant = cached_snapshots_by_npc_id.get(npc_id, {})
		var revision := 0
		var captured_game_hours := now
		if cached_value is Dictionary:
			var cached: Dictionary = cached_value
			revision = int(cached.get("revision", 0))
			captured_game_hours = float(
				cached.get("captured_game_hours", now)
			)
		if live_registrations_by_npc_id.has(npc_id):
			captured_game_hours = now
		entries[npc_id] = {
			"revision": revision,
			"captured_game_hours": captured_game_hours,
			"snapshot": get_snapshot_for_npc(npc_id, now),
		}
	return {
		"version": RUNTIME_STATE_VERSION,
		"captured_game_hours": now,
		"npc_memories": entries,
	}


func import_runtime_state(
	state: Dictionary,
	now_game_hours: float = -1.0
) -> Dictionary:
	if int(state.get("version", 0)) != RUNTIME_STATE_VERSION:
		return {"accepted": false, "reason": "unsupported_version"}
	var entries = state.get("npc_memories", {})
	if not (entries is Dictionary):
		return {"accepted": false, "reason": "malformed_entries"}
	var now := _resolve_now(now_game_hours)
	var ordered_ids: Array[String] = []
	for npc_id_value in entries.keys():
		var npc_id := String(npc_id_value).strip_edges()
		if _is_valid_npc_id(npc_id):
			ordered_ids.append(npc_id)
	ordered_ids.sort()

	var imported_count := 0
	var malformed_count := 0
	for npc_id in ordered_ids:
		var entry = entries.get(npc_id, {})
		if not (entry is Dictionary):
			malformed_count += 1
			continue
		var snapshot = entry.get("snapshot", [])
		if not (snapshot is Array):
			malformed_count += 1
			continue
		var sanitized := _sanitize_snapshot(snapshot, now)
		var previous: Variant = cached_snapshots_by_npc_id.get(npc_id, {})
		var previous_revision := (
			int(previous.get("revision", 0))
			if previous is Dictionary
			else 0
		)
		cached_snapshots_by_npc_id[npc_id] = {
			"npc_id": npc_id,
			"revision": maxi(
				previous_revision + 1,
				maxi(int(entry.get("revision", 0)), 0)
			),
			"captured_game_hours": float(
				entry.get("captured_game_hours", now)
			),
			"snapshot": sanitized.duplicate(true),
		}
		var registration := _get_live_registration(npc_id)
		if not registration.is_empty():
			var memory := _registration_memory(registration)
			if memory != null and not sanitized.is_empty():
				memory.import_snapshot(sanitized.duplicate(true), now, true)
		imported_count += 1
	return {
		"accepted": true,
		"imported_count": imported_count,
		"malformed_count": malformed_count,
	}


func get_debug_descriptor(now_game_hours: float = -1.0) -> Dictionary:
	var now := _resolve_now(now_game_hours)
	_cleanup_dead_registrations()
	var runtime_state := export_runtime_state(now)
	var entries: Dictionary = {}
	var memories: Dictionary = runtime_state.get("npc_memories", {})
	for npc_id_value in memories.keys():
		var npc_id := String(npc_id_value)
		var entry: Dictionary = memories[npc_id]
		entries[npc_id] = {
			"live": live_registrations_by_npc_id.has(npc_id),
			"generation": int(_generation_by_npc_id.get(npc_id, 0)),
			"revision": int(entry.get("revision", 0)),
			"memory_count": Array(entry.get("snapshot", [])).size(),
		}
	return {
		"cached_npc_count": cached_snapshots_by_npc_id.size(),
		"live_npc_count": live_registrations_by_npc_id.size(),
		"entries": entries,
	}


func _capture_registration(
	npc_id: String,
	registration: Dictionary,
	now_game_hours: float
) -> bool:
	var memory := _registration_memory(registration)
	if memory == null:
		return false
	var previous: Variant = cached_snapshots_by_npc_id.get(npc_id, {})
	var previous_revision := (
		int(previous.get("revision", 0))
		if previous is Dictionary
		else 0
	)
	cached_snapshots_by_npc_id[npc_id] = {
		"npc_id": npc_id,
		"revision": previous_revision + 1,
		"captured_game_hours": now_game_hours,
		"snapshot": memory.export_snapshot(now_game_hours).duplicate(true),
	}
	return true


func _get_live_registration(npc_id: String) -> Dictionary:
	if npc_id.is_empty():
		return {}
	var registration = live_registrations_by_npc_id.get(npc_id, {})
	if not (registration is Dictionary):
		live_registrations_by_npc_id.erase(npc_id)
		return {}
	if _registration_memory(registration) == null:
		live_registrations_by_npc_id.erase(npc_id)
		return {}
	return registration


func _registration_memory(registration: Dictionary) -> NpcShortTermMemory:
	var memory_ref = registration.get("memory_ref")
	if not (memory_ref is WeakRef):
		return null
	var value = memory_ref.get_ref()
	if value == null or not is_instance_valid(value):
		return null
	return value as NpcShortTermMemory


func _cleanup_dead_registrations() -> void:
	for npc_id_value in live_registrations_by_npc_id.keys():
		_get_live_registration(String(npc_id_value))


func _sanitize_snapshot(
	snapshot: Array,
	now_game_hours: float
) -> Array[Dictionary]:
	var temporary := NpcShortTermMemory.new()
	temporary.import_snapshot(snapshot.duplicate(true), now_game_hours)
	var sanitized := temporary.export_snapshot(now_game_hours)
	temporary.free()
	return sanitized


func _resolve_now(supplied_game_hours: float) -> float:
	if supplied_game_hours >= 0.0 and is_finite(supplied_game_hours):
		return supplied_game_hours
	if is_inside_tree():
		var world_time := get_node_or_null("/root/WorldTime")
		if world_time != null and world_time.has_method("get_total_hours"):
			return maxf(float(world_time.call("get_total_hours")), 0.0)
	return 0.0


func _is_valid_npc_id(candidate: String) -> bool:
	if candidate.is_empty() or candidate.begins_with("/") or candidate.contains("/"):
		return false
	if candidate.begins_with("npc:") and candidate.substr(4).is_valid_int():
		return false
	return true
