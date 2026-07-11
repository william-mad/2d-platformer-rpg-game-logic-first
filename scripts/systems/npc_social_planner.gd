class_name NpcSocialPlanner
extends RefCounted


const PLAYER_SOCIAL_TARGET_ID := "__player__"

var _favor_cache: Dictionary = {}


func begin_simulation_pass() -> void:
	_favor_cache.clear()


func end_simulation_pass() -> void:
	_favor_cache.clear()


func choose_candidate(
	npc_id: StringName,
	record: Dictionary,
	records: Dictionary,
	locations: Node,
	settings: Dictionary,
	relationships: Node,
	player: Node2D,
	rng: RandomNumberGenerator,
	candidate_evaluated: Callable = Callable()
) -> Dictionary:
	var seeker_scene_path := String(record.get("scene_path", ""))
	var local_candidates: Array[Dictionary] = []
	var remote_candidates: Array[Dictionary] = []
	if player != null and is_instance_valid(player):
		var player_scene_path := String(locations.call("get_current_scene_path"))
		_add_candidate({
			"target_id": PLAYER_SOCIAL_TARGET_ID,
			"scene_path": player_scene_path,
			"position": player.global_position,
			"is_player": true,
		}, seeker_scene_path, local_candidates, remote_candidates)

	var owner_id := _get_record_relationship_id(npc_id, record)
	var minimum_favor := float(settings.get("minimum_npc_favor", 10.0))
	for target_id_key in records.keys():
		var target_id := String(target_id_key)
		if target_id == String(npc_id):
			continue
		var target_record = records[target_id_key]
		if not (target_record is Dictionary) or _record_is_disabled(target_record):
			continue
		if candidate_evaluated.is_valid():
			candidate_evaluated.call()
		var target_relationship_id := _get_record_relationship_id(
			StringName(target_id),
			target_record
		)
		if relationships != null and relationships.has_method("get_favor_by_id"):
			var seeker_favor := _get_cached_favor(
				relationships,
				owner_id,
				target_relationship_id,
				50.0
			)
			var target_favor := _get_cached_favor(
				relationships,
				target_relationship_id,
				owner_id,
				50.0
			)
			if seeker_favor <= minimum_favor or target_favor <= minimum_favor:
				continue
		var target_position = target_record.get("last_position", Vector2.ZERO)
		if locations.has_method("get_live_npc"):
			var target_live := locations.call("get_live_npc", target_id) as Node2D
			if target_live != null:
				target_position = target_live.global_position
		_add_candidate({
			"target_id": target_id,
			"scene_path": String(target_record.get("scene_path", "")),
			"position": target_position,
			"is_player": false,
		}, seeker_scene_path, local_candidates, remote_candidates)

	var candidates := local_candidates if not local_candidates.is_empty() else remote_candidates
	if candidates.is_empty():
		return {}
	var preferred_target_id := String(record.get("social_visit_target_id", ""))
	for candidate in candidates:
		if not preferred_target_id.is_empty() and String(candidate.get("target_id", "")) == preferred_target_id:
			return candidate

	var player_chance := clampf(float(settings.get("player_target_chance", 0.35)), 0.0, 1.0)
	if rng.randf() < player_chance:
		for candidate in candidates:
			if bool(candidate.get("is_player", false)):
				return candidate
	return candidates[rng.randi_range(0, candidates.size() - 1)]


func _get_cached_favor(
	relationships: Node,
	owner_id: String,
	other_id: String,
	fallback: float
) -> float:
	var favors_for_owner = _favor_cache.get(owner_id, null)
	if favors_for_owner is Dictionary and favors_for_owner.has(other_id):
		return float(favors_for_owner[other_id])

	var favor := float(relationships.call("get_favor_by_id", owner_id, other_id, fallback))
	if not (favors_for_owner is Dictionary):
		favors_for_owner = {}
		_favor_cache[owner_id] = favors_for_owner
	favors_for_owner[other_id] = favor
	return favor


func _add_candidate(
	candidate: Dictionary,
	seeker_scene_path: String,
	local_candidates: Array[Dictionary],
	remote_candidates: Array[Dictionary]
) -> void:
	if String(candidate.get("scene_path", "")).is_empty():
		return
	if String(candidate.get("scene_path", "")) == seeker_scene_path:
		local_candidates.append(candidate)
	else:
		remote_candidates.append(candidate)


func _get_record_relationship_id(npc_id: StringName, record: Dictionary) -> String:
	var node_state = record.get("node_state", {})
	if node_state is Dictionary:
		var relationship_id := String(node_state.get("relationship_id", ""))
		if not relationship_id.is_empty():
			return relationship_id
	return String(npc_id)


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
