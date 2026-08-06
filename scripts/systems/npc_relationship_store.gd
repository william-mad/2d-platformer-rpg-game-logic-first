class_name NpcRelationshipStore extends RefCounted

const Identity = preload("res://scripts/systems/npc_identity.gd")
const SocialStateSchema = preload("res://scripts/systems/npc_social_state_schema.gd")


static func get_metric_default(policy: Dictionary, metric_id: StringName) -> float:
	var configured := SocialStateSchema.get_directed_opinion_default(metric_id)
	var defaults = policy.get("defaults", {})
	if defaults is Dictionary and defaults.has(metric_id):
		configured = float(defaults[metric_id])
	return clampf(
		configured,
		get_metric_minimum(policy, metric_id),
		get_metric_maximum(policy, metric_id)
	)


static func get_metric_minimum(policy: Dictionary, metric_id: StringName) -> float:
	var configured := SocialStateSchema.get_directed_opinion_minimum(metric_id)
	var minimums = policy.get("minimums", {})
	if minimums is Dictionary and minimums.has(metric_id):
		configured = float(minimums[metric_id])
	return configured


static func get_metric_maximum(policy: Dictionary, metric_id: StringName) -> float:
	var minimum := get_metric_minimum(policy, metric_id)
	var configured := SocialStateSchema.get_directed_opinion_maximum(metric_id)
	var maximums = policy.get("maximums", {})
	if maximums is Dictionary and maximums.has(metric_id):
		configured = float(maximums[metric_id])
	return maxf(configured, minimum)


static func normalize_row_in_place(row: Dictionary, policy: Dictionary) -> void:
	for metric_text in SocialStateSchema.get_directed_opinion_metrics():
		var metric_id := StringName(metric_text)
		var key := String(metric_id)
		row[key] = clampf(
			float(row.get(key, get_metric_default(policy, metric_id))),
			get_metric_minimum(policy, metric_id),
			get_metric_maximum(policy, metric_id)
		)


static func normalize_row_copy(row: Dictionary, policy: Dictionary) -> Dictionary:
	var copy := row.duplicate(true)
	normalize_row_in_place(copy, policy)
	return copy


static func get_normalized_graph_snapshot(
	relationships: Dictionary,
	policy: Dictionary
) -> Dictionary:
	var snapshot := relationships.duplicate(true)
	for owner_id in snapshot.keys():
		var rows = snapshot[owner_id]
		if not (rows is Dictionary):
			continue
		for other_id in rows.keys():
			var row = rows[other_id]
			if row is Dictionary:
				normalize_row_in_place(row, policy)
	return snapshot


## Returns a normalized save snapshot containing only authored actor identities.
## Runtime relationship APIs intentionally still support path/instance rows for
## legacy combat and alias migration; this is the persistence safety boundary.
static func get_persistence_safe_graph_snapshot(
	relationships: Dictionary,
	policy: Dictionary
) -> Dictionary:
	var snapshot: Dictionary = {}
	var owner_ids: Array[String] = []
	for owner_id_key in relationships.keys():
		var owner_id := String(owner_id_key).strip_edges()
		if Identity.is_stable_id(owner_id) and not owner_ids.has(owner_id):
			owner_ids.append(owner_id)
	owner_ids.sort()
	for owner_id in owner_ids:
		var rows = relationships.get(owner_id, {})
		if not (rows is Dictionary):
			continue
		var saved_rows: Dictionary = {}
		var other_ids: Array[String] = []
		for other_id_key in rows.keys():
			var other_id := String(other_id_key).strip_edges()
			if Identity.is_stable_id(other_id) and not other_ids.has(other_id):
				other_ids.append(other_id)
		other_ids.sort()
		for other_id in other_ids:
			var row = rows.get(other_id, {})
			if not (row is Dictionary):
				continue
			var embedded_owner_id := String(
				row.get("owner_id", owner_id)
			).strip_edges()
			var embedded_other_id := String(
				row.get("other_id", other_id)
			).strip_edges()
			if (
				not Identity.is_stable_id(embedded_owner_id)
				or not Identity.is_stable_id(embedded_other_id)
			):
				continue
			var saved_row := normalize_row_copy(row, policy)
			# Dictionary keys are authoritative for graph addressing.
			saved_row["owner_id"] = owner_id
			saved_row["other_id"] = other_id
			saved_rows[other_id] = saved_row
		if not saved_rows.is_empty():
			snapshot[owner_id] = saved_rows
	return snapshot


static func get_known_actor_directory_snapshot(
	relationships: Dictionary,
	viewer_id: String = ""
) -> Dictionary:
	var directory: Dictionary = {}
	var clean_viewer_id := viewer_id.strip_edges()
	var owner_ids: Array[String] = []
	for owner_id_key in relationships.keys():
		owner_ids.append(String(owner_id_key).strip_edges())
	owner_ids.sort()
	for owner_id in owner_ids:
		var rows = relationships.get(owner_id, {})
		if not (rows is Dictionary):
			continue
		var other_ids: Array[String] = []
		for other_id_key in rows.keys():
			other_ids.append(String(other_id_key).strip_edges())
		other_ids.sort()
		for other_id in other_ids:
			var row = rows.get(other_id, {})
			if not (row is Dictionary) or not bool(row.get("met", false)):
				continue
			var stored_owner_id := String(
				row.get("owner_id", owner_id)
			).strip_edges()
			var stored_other_id := String(
				row.get("other_id", other_id)
			).strip_edges()
			if (
				stored_owner_id == stored_other_id
				or not Identity.is_stable_id(stored_owner_id)
				or not Identity.is_stable_id(stored_other_id)
			):
				continue
			if (
				not clean_viewer_id.is_empty()
				and stored_owner_id != clean_viewer_id
				and stored_other_id != clean_viewer_id
			):
				continue
			_merge_actor_entry(directory, stored_owner_id, row, true)
			_merge_actor_entry(directory, stored_other_id, row, false)
	return directory.duplicate(true)


static func get_known_character_ids_snapshot(
	relationships: Dictionary,
	viewer_id: String = "",
	include_player: bool = false
) -> PackedStringArray:
	var clean_viewer_id := viewer_id.strip_edges()
	var directory := get_known_actor_directory_snapshot(
		relationships,
		clean_viewer_id
	)
	var actor_ids := PackedStringArray()
	for actor_id_key in directory.keys():
		var actor_id := String(actor_id_key).strip_edges()
		if actor_id.is_empty() or actor_id == clean_viewer_id:
			continue
		if not include_player and Identity.is_player_id(actor_id):
			continue
		actor_ids.append(actor_id)
	actor_ids.sort()
	return actor_ids


static func _merge_actor_entry(
	directory: Dictionary,
	actor_id: String,
	row: Dictionary,
	is_owner: bool
) -> void:
	if not Identity.is_stable_id(actor_id):
		return
	var role := "owner" if is_owner else "other"
	var candidate_recency := _row_recency(row)
	var display_name := String(row.get("%s_name" % role, "")).strip_edges()
	var last_known_path := String(row.get("%s_path" % role, "")).strip_edges()
	var existing = directory.get(actor_id, {})
	if existing is Dictionary and not existing.is_empty():
		var existing_recency := int(existing.get("updated_at_msec", 0))
		if candidate_recency < existing_recency:
			return
		if display_name.is_empty():
			display_name = String(existing.get("display_name", ""))
		if last_known_path.is_empty():
			last_known_path = String(existing.get("last_known_path", ""))
	if display_name.is_empty():
		display_name = _fallback_display_name(actor_id)
	directory[actor_id] = {
		"actor_id": actor_id,
		"display_name": display_name,
		"last_known_path": last_known_path,
		"is_player": Identity.is_player_id(actor_id),
		"last_seen_msec": int(row.get("last_seen_msec", 0)),
		"updated_at_msec": candidate_recency,
	}


static func _row_recency(row: Dictionary) -> int:
	return maxi(
		int(row.get("updated_at_msec", 0)),
		maxi(
			int(row.get("last_seen_msec", 0)),
			int(row.get("created_at_msec", 0))
		)
	)


static func _fallback_display_name(actor_id: String) -> String:
	if Identity.is_player_id(actor_id):
		return "Player"
	return actor_id.replace("_", " ").capitalize()
