class_name NpcShortTermMemory extends Node

const MemoryEvent = preload("res://scripts/systems/npc_behavior/npc_memory_event.gd")
const MemoryPolicy = preload("res://scripts/systems/npc_behavior/npc_memory_policy.gd")

signal memory_added(memory_descriptor: Dictionary)
signal memory_merged(memory_descriptor: Dictionary)
signal memory_resolved(memory_descriptor: Dictionary)
signal memory_expired(memory_descriptor: Dictionary)
signal memory_evicted(memory_descriptor: Dictionary)
signal memory_removed(memory_descriptor: Dictionary)
signal memory_changed

@export_range(0, 256, 1) var maximum_memories: int = 24
@export_range(0.05, 10.0, 0.05, "suffix:s") var expiration_check_interval_real_seconds: float = 0.5
@export_range(0, 8, 1) var debug_recent_memory_limit: int = 1

var _memories: Array[NpcMemoryEvent] = []
var _expiration_check_elapsed: float = 0.0


func _process(delta: float) -> void:
	_expiration_check_elapsed += maxf(delta, 0.0)
	if _expiration_check_elapsed < maxf(expiration_check_interval_real_seconds, 0.05):
		return
	_expiration_check_elapsed = 0.0
	prune_expired(_get_current_game_hours())


func remember(event: NpcMemoryEvent) -> Dictionary:
	if event == null:
		return {"accepted": false, "reason": "invalid_event"}
	var remembered := event.duplicate_event()
	var now_game_hours := (
		maxf(remembered.last_updated_game_hours, 0.0)
		if is_finite(remembered.last_updated_game_hours)
		else _get_current_game_hours()
	)
	if not MemoryPolicy.is_supported(remembered.event_type):
		return {"accepted": false, "reason": "unsupported_event_type"}
	_normalize_event(remembered, now_game_hours)
	prune_expired(now_game_hours)

	var equivalent := _find_merge_candidate(remembered, now_game_hours)
	if equivalent != null:
		_merge_event(equivalent, remembered, now_game_hours)
		var merged_descriptor := _descriptor(equivalent, now_game_hours)
		memory_merged.emit(merged_descriptor.duplicate(true))
		memory_changed.emit()
		return {
			"accepted": true,
			"result": "merged",
			"memory": merged_descriptor,
		}

	_memories.append(remembered)
	var added_descriptor := _descriptor(remembered, now_game_hours)
	memory_added.emit(added_descriptor.duplicate(true))
	var evicted := _enforce_capacity(now_game_hours, true)
	memory_changed.emit()
	return {
		"accepted": true,
		"result": "added",
		"memory": added_descriptor,
		"evicted_count": evicted,
	}


func remember_event(event_type: StringName, context: Dictionary = {}) -> Dictionary:
	var now_game_hours := _context_game_hours(context)
	return remember(MemoryEvent.create(event_type, context, now_game_hours))


func resolve_memory(memory_id: String, reason: StringName = &"") -> bool:
	var memory := _find_internal_by_id(memory_id)
	if memory == null or memory.resolved:
		return false
	memory.resolved = true
	memory.last_updated_game_hours = maxf(
		memory.last_updated_game_hours,
		_get_current_game_hours()
	)
	if reason != &"":
		memory.metadata["resolution_reason"] = String(reason)
	var descriptor := _descriptor(memory, _get_current_game_hours())
	memory_resolved.emit(descriptor.duplicate(true))
	memory_changed.emit()
	return true


func remove_memory(memory_id: String, reason: StringName = &"") -> bool:
	for index in _memories.size():
		var memory := _memories[index]
		if memory.memory_id != memory_id:
			continue
		_memories.remove_at(index)
		var descriptor := _descriptor(memory, _get_current_game_hours())
		if reason != &"":
			descriptor["removal_reason"] = String(reason)
		memory_removed.emit(descriptor.duplicate(true))
		memory_changed.emit()
		return true
	return false


func clear_all(reason: StringName = &"") -> void:
	if _memories.is_empty():
		return
	var now_game_hours := _get_current_game_hours()
	var removed := _memories
	_memories = []
	for memory in removed:
		var descriptor := _descriptor(memory, now_game_hours)
		if reason != &"":
			descriptor["removal_reason"] = String(reason)
		memory_removed.emit(descriptor.duplicate(true))
	memory_changed.emit()


func prune_expired(now_game_hours: float) -> int:
	var removed_count := 0
	for index in range(_memories.size() - 1, -1, -1):
		var memory := _memories[index]
		if not memory.is_expired(now_game_hours):
			continue
		_memories.remove_at(index)
		removed_count += 1
		memory_expired.emit(_descriptor(memory, now_game_hours).duplicate(true))
	if removed_count > 0:
		memory_changed.emit()
	return removed_count


func get_recent_memories(limit: int = -1) -> Array[NpcMemoryEvent]:
	var memories: Array[NpcMemoryEvent] = []
	var now_game_hours := _get_current_game_hours()
	for memory in _memories:
		if not memory.is_expired(now_game_hours):
			memories.append(memory.duplicate_event())
	memories.sort_custom(_recent_memory_before)
	var effective_limit := limit
	if effective_limit < 0:
		effective_limit = memories.size()
	if memories.size() > effective_limit:
		memories.resize(maxi(effective_limit, 0))
	return memories


func get_memory_by_id(memory_id: String) -> NpcMemoryEvent:
	var memory := _find_internal_by_id(memory_id)
	return memory.duplicate_event() if memory != null else null


func find_recent(
	event_type: StringName,
	subject_id: StringName = &"",
	target_id: StringName = &"",
	logical_action: StringName = &""
) -> Array[NpcMemoryEvent]:
	var results: Array[NpcMemoryEvent] = []
	var now_game_hours := _get_current_game_hours()
	for memory in _memories:
		if memory.is_expired(now_game_hours) or memory.event_type != event_type:
			continue
		if subject_id != &"" and memory.subject_id != subject_id:
			continue
		if target_id != &"" and memory.target_id != target_id:
			continue
		if logical_action != &"" and memory.logical_action != logical_action:
			continue
		results.append(memory.duplicate_event())
	results.sort_custom(_recent_memory_before)
	return results


func has_recent(
	event_type: StringName,
	subject_id: StringName = &"",
	target_id: StringName = &"",
	logical_action: StringName = &""
) -> bool:
	return not find_recent(event_type, subject_id, target_id, logical_action).is_empty()


func get_debug_descriptor(now_game_hours: float) -> Dictionary:
	var candidates: Array[NpcMemoryEvent] = []
	var unresolved_count := 0
	for memory in _memories:
		if memory.is_expired(now_game_hours):
			continue
		candidates.append(memory)
		if not memory.resolved:
			unresolved_count += 1
	candidates.sort_custom(_recent_memory_before)
	var recent: Array[Dictionary] = []
	var limit := mini(maxi(debug_recent_memory_limit, 0), candidates.size())
	for index in limit:
		recent.append(_descriptor(candidates[index], now_game_hours))
	return {
		"count": candidates.size(),
		"unresolved_count": unresolved_count,
		"recent": recent,
	}


func export_snapshot(now_game_hours: float) -> Array[Dictionary]:
	prune_expired(now_game_hours)
	var ordered := _memories.duplicate()
	ordered.sort_custom(_snapshot_memory_before)
	var snapshot: Array[Dictionary] = []
	for memory in ordered:
		snapshot.append(memory.to_dict())
	return snapshot


func import_snapshot(snapshot: Array, now_game_hours: float) -> Dictionary:
	var imported: Array[NpcMemoryEvent] = []
	var seen_ids: Dictionary = {}
	var malformed_count := 0
	var expired_count := 0
	var duplicate_id_count := 0
	for value in snapshot:
		if not (value is Dictionary):
			malformed_count += 1
			continue
		var memory := MemoryEvent.from_dict(value)
		if not MemoryPolicy.is_supported(memory.event_type):
			malformed_count += 1
			continue
		_normalize_event(memory, now_game_hours)
		if memory.is_expired(now_game_hours):
			expired_count += 1
			continue
		if seen_ids.has(memory.memory_id):
			duplicate_id_count += 1
			continue
		seen_ids[memory.memory_id] = true
		imported.append(memory)
	_memories = imported
	var evicted_count := _enforce_capacity(now_game_hours, false)
	memory_changed.emit()
	return {
		"imported_count": _memories.size(),
		"malformed_count": malformed_count,
		"expired_count": expired_count,
		"duplicate_id_count": duplicate_id_count,
		"evicted_count": evicted_count,
	}


func _normalize_event(memory: NpcMemoryEvent, now_game_hours: float) -> void:
	memory.ensure_memory_id()
	var policy := MemoryPolicy.get_policy(memory.event_type)
	if not is_finite(memory.created_game_hours):
		memory.created_game_hours = now_game_hours
	if not is_finite(memory.last_updated_game_hours):
		memory.last_updated_game_hours = memory.created_game_hours
	if not is_finite(memory.expires_game_hours):
		memory.expires_game_hours = memory.created_game_hours
	if not is_finite(memory.importance):
		memory.importance = float(policy.get("default_importance", 0.0))
	if not is_finite(memory.emotional_valence):
		memory.emotional_valence = float(
			policy.get("default_emotional_valence", 0.0)
		)
	memory.created_game_hours = maxf(memory.created_game_hours, 0.0)
	memory.last_updated_game_hours = maxf(
		memory.last_updated_game_hours,
		memory.created_game_hours
	)
	var duration := maxf(float(policy.get("default_duration_game_hours", 0.0)), 0.0)
	if memory.expires_game_hours <= memory.created_game_hours:
		memory.expires_game_hours = memory.created_game_hours + duration
	var lifetime_cap := memory.created_game_hours + maxf(
		float(policy.get("maximum_lifetime_game_hours", duration)),
		duration
	)
	memory.expires_game_hours = minf(memory.expires_game_hours, lifetime_cap)
	memory.importance = clampf(memory.importance, 0.0, 1.0)
	memory.emotional_valence = clampf(memory.emotional_valence, -1.0, 1.0)
	memory.occurrence_count = clampi(
		maxi(memory.occurrence_count, 1),
		1,
		maxi(int(policy.get("maximum_occurrences", 1)), 1)
	)
	memory.metadata = memory.metadata.duplicate(true)
	if memory.last_updated_game_hours <= 0.0 and now_game_hours > 0.0:
		memory.last_updated_game_hours = maxf(now_game_hours, memory.created_game_hours)


func _find_merge_candidate(
	incoming: NpcMemoryEvent,
	now_game_hours: float
) -> NpcMemoryEvent:
	var policy := MemoryPolicy.get_policy(incoming.event_type)
	var dedupe_window := maxf(float(policy.get("dedupe_window_game_hours", 0.0)), 0.0)
	var incoming_key := incoming.get_dedupe_key()
	if incoming_key.is_empty():
		return null
	var candidates: Array[NpcMemoryEvent] = []
	for memory in _memories:
		if memory.resolved or memory.get_dedupe_key() != incoming_key:
			continue
		if now_game_hours - memory.last_updated_game_hours > dedupe_window:
			continue
		candidates.append(memory)
	if candidates.is_empty():
		return null
	candidates.sort_custom(_recent_memory_before)
	return candidates[0]


func _merge_event(
	existing: NpcMemoryEvent,
	incoming: NpcMemoryEvent,
	now_game_hours: float
) -> void:
	var policy := MemoryPolicy.get_policy(existing.event_type)
	existing.last_updated_game_hours = maxf(
		maxf(existing.last_updated_game_hours, incoming.last_updated_game_hours),
		now_game_hours
	)
	existing.occurrence_count = mini(
		existing.occurrence_count + maxi(incoming.occurrence_count, 1),
		maxi(int(policy.get("maximum_occurrences", 1)), 1)
	)
	if existing.source == &"":
		existing.source = incoming.source
	if existing.reason_code == &"":
		existing.reason_code = incoming.reason_code
	if existing.intent_id.is_empty():
		existing.intent_id = incoming.intent_id
	if existing.action_session_id.is_empty():
		existing.action_session_id = incoming.action_session_id
	elif (
		not incoming.action_session_id.is_empty()
		and incoming.action_session_id != existing.action_session_id
	):
		existing.metadata["last_action_session_id"] = incoming.action_session_id
	for key in incoming.metadata.keys():
		if not existing.metadata.has(key):
			existing.metadata[key] = _copy_variant(incoming.metadata[key])
	var duration := maxf(float(policy.get("default_duration_game_hours", 0.0)), 0.0)
	var lifetime_cap := existing.created_game_hours + maxf(
		float(policy.get("maximum_lifetime_game_hours", duration)),
		duration
	)
	existing.expires_game_hours = minf(
		maxf(existing.expires_game_hours, now_game_hours + duration),
		lifetime_cap
	)


func _enforce_capacity(now_game_hours: float, emit_evictions: bool) -> int:
	var removed_count := 0
	var capacity := maxi(maximum_memories, 0)
	while _memories.size() > capacity:
		var candidates := _memories.duplicate()
		candidates.sort_custom(_eviction_memory_before)
		var evicted: NpcMemoryEvent = candidates[0]
		_memories.erase(evicted)
		removed_count += 1
		if emit_evictions:
			memory_evicted.emit(_descriptor(evicted, now_game_hours).duplicate(true))
	return removed_count


func _descriptor(memory: NpcMemoryEvent, now_game_hours: float) -> Dictionary:
	var descriptor := memory.to_descriptor(now_game_hours)
	descriptor["debug_feedback_text"] = MemoryPolicy.format_debug_text(descriptor)
	return descriptor


func _find_internal_by_id(memory_id: String) -> NpcMemoryEvent:
	var clean_id := memory_id.strip_edges()
	if clean_id.is_empty():
		return null
	for memory in _memories:
		if memory.memory_id == clean_id:
			return memory
	return null


func _context_game_hours(context: Dictionary) -> float:
	if context.has("now_game_hours"):
		var supplied = context.get("now_game_hours")
		if supplied is float or supplied is int:
			return maxf(float(supplied), 0.0)
	return _get_current_game_hours()


func _get_current_game_hours() -> float:
	if not is_inside_tree():
		return 0.0
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_total_hours"):
		return maxf(float(world_time.call("get_total_hours")), 0.0)
	return 0.0


static func _recent_memory_before(a: NpcMemoryEvent, b: NpcMemoryEvent) -> bool:
	if a.resolved != b.resolved:
		return not a.resolved
	if not is_equal_approx(a.importance, b.importance):
		return a.importance > b.importance
	if not is_equal_approx(a.last_updated_game_hours, b.last_updated_game_hours):
		return a.last_updated_game_hours > b.last_updated_game_hours
	return a.memory_id < b.memory_id


static func _eviction_memory_before(a: NpcMemoryEvent, b: NpcMemoryEvent) -> bool:
	if a.resolved != b.resolved:
		return a.resolved
	if not is_equal_approx(a.importance, b.importance):
		return a.importance < b.importance
	if not is_equal_approx(a.last_updated_game_hours, b.last_updated_game_hours):
		return a.last_updated_game_hours < b.last_updated_game_hours
	return a.memory_id < b.memory_id


static func _snapshot_memory_before(a: NpcMemoryEvent, b: NpcMemoryEvent) -> bool:
	if not is_equal_approx(a.created_game_hours, b.created_game_hours):
		return a.created_game_hours < b.created_game_hours
	return a.memory_id < b.memory_id


static func _copy_variant(value):
	return value.duplicate(true) if value is Dictionary or value is Array else value
