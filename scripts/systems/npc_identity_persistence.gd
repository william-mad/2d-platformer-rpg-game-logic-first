class_name NpcIdentityPersistence extends RefCounted

const Identity = preload("res://scripts/systems/npc_identity.gd")

const ACTOR_REFERENCE_KEYS := {
	"candidate_id": true,
	"location_id": true,
	"npc_id": true,
	"other_id": true,
	"owner_id": true,
	"relationship_id": true,
	"remembering_npc_id": true,
	"requester_id": true,
	"selected_candidate_id": true,
	"selected_target_id": true,
	"social_session_partner_id": true,
	"social_visit_target_id": true,
	"subject_id": true,
	"target_id": true,
	"target_npc_id": true,
	"target_persistent_id": true,
}


## Plans an exact-alias adoption without mutating runtime state. The caller can
## run all registration gates before committing it.
static func plan_location_record_adoption(
	records: Dictionary,
	live_npcs: Dictionary,
	actor: Node,
	canonical_id: String
) -> Dictionary:
	var clean_canonical_id := canonical_id.strip_edges()
	if not Identity.is_stable_id(clean_canonical_id):
		return {"adopted": false, "reason": "unstable_canonical_identity"}

	var aliases := Identity.get_actor_aliases(actor)
	aliases.sort()
	var eligible_aliases: Array[String] = []
	for alias in aliases:
		var clean_alias := alias.strip_edges()
		if clean_alias.is_empty() or clean_alias == clean_canonical_id:
			continue
		if not records.has(clean_alias) or not (records[clean_alias] is Dictionary):
			continue
		var claimant = live_npcs.get(clean_alias, null)
		if (
			claimant != null
			and is_instance_valid(claimant)
			and claimant != actor
		):
			continue
		eligible_aliases.append(clean_alias)

	if eligible_aliases.is_empty():
		return {"adopted": false, "reason": "no_matching_record"}

	var selected_id := ""
	var selected_record: Dictionary = {}
	if records.has(clean_canonical_id) and records[clean_canonical_id] is Dictionary:
		selected_id = clean_canonical_id
		selected_record = records[clean_canonical_id]
	for alias in eligible_aliases:
		var candidate: Dictionary = records[alias]
		if selected_id.is_empty() or _record_is_newer(candidate, selected_record):
			selected_id = alias
			selected_record = candidate

	var adopted_record := selected_record.duplicate(true)
	_canonicalize_adopted_record(
		adopted_record,
		clean_canonical_id,
		eligible_aliases
	)
	return {
		"adopted": true,
		"reason": "alias_record_adopted",
		"record": adopted_record,
		"selected_id": selected_id,
		"removed_aliases": eligible_aliases.duplicate(),
	}


static func commit_location_record_adoption(
	records: Dictionary,
	live_npcs: Dictionary,
	actor: Node,
	plan: Dictionary
) -> void:
	if not bool(plan.get("adopted", false)):
		return
	var aliases = plan.get("removed_aliases", [])
	if not (aliases is Array):
		return
	for alias_value in aliases:
		var alias := String(alias_value).strip_edges()
		if alias.is_empty():
			continue
		records.erase(alias)
		if live_npcs.get(alias, null) == actor:
			live_npcs.erase(alias)


## Returns a save-only copy. Runtime path fallbacks remain available for live
## handshakes, but unresolved actors and transient references do not cross the
## persistence boundary.
static func sanitize_location_records_for_save(records: Dictionary) -> Dictionary:
	var saved_records: Dictionary = {}
	var ordered_ids: Array[String] = []
	for record_id_value in records.keys():
		ordered_ids.append(String(record_id_value).strip_edges())
	ordered_ids.sort()
	for record_id in ordered_ids:
		if not Identity.is_stable_id(record_id):
			continue
		var value = records.get(record_id, {})
		if not (value is Dictionary):
			continue
		var record: Dictionary = value.duplicate(true)
		record["npc_id"] = record_id
		_canonicalize_saved_node_state(record, record_id)
		_clear_unsafe_persisted_action_chain(record)
		_sanitize_persisted_actor_references(record, record_id)
		saved_records[record_id] = record
	return saved_records


static func get_unstable_location_record_ids(
	records: Dictionary
) -> PackedStringArray:
	var unstable_ids := PackedStringArray()
	for record_id_value in records.keys():
		var record_id := String(record_id_value).strip_edges()
		if not record_id.is_empty() and not Identity.is_stable_id(record_id):
			unstable_ids.append(record_id)
	unstable_ids.sort()
	return unstable_ids


static func _record_is_newer(candidate: Dictionary, current: Dictionary) -> bool:
	var candidate_hours := float(candidate.get("last_simulated_total_hours", 0.0))
	var current_hours := float(current.get("last_simulated_total_hours", 0.0))
	if not is_equal_approx(candidate_hours, current_hours):
		return candidate_hours > current_hours
	return int(candidate.get("last_travel_msec", 0)) > int(
		current.get("last_travel_msec", 0)
	)


static func _canonicalize_adopted_record(
	record: Dictionary,
	canonical_id: String,
	aliases: Array[String]
) -> void:
	record["npc_id"] = canonical_id
	var alias_lookup: Dictionary = {}
	for alias in aliases:
		alias_lookup[alias] = true
	_rewrite_exact_actor_aliases(record, alias_lookup, canonical_id)
	_canonicalize_saved_node_state(record, canonical_id)


static func _canonicalize_saved_node_state(
	record: Dictionary,
	canonical_id: String
) -> void:
	var node_state_value = record.get("node_state", {})
	if not (node_state_value is Dictionary):
		return
	var node_state: Dictionary = node_state_value
	if node_state.has("location_id"):
		node_state["location_id"] = canonical_id
	var relationship_id := String(node_state.get("relationship_id", "")).strip_edges()
	if not relationship_id.is_empty() and not Identity.is_stable_id(relationship_id):
		node_state["relationship_id"] = canonical_id
	record["node_state"] = node_state


static func _clear_unsafe_persisted_action_chain(record: Dictionary) -> void:
	var unsafe_session_ids: Dictionary = {}
	for field_name in ["action", "activity", "pending_travel"]:
		var descriptor = record.get(field_name, {})
		if not (descriptor is Dictionary) or descriptor.is_empty():
			continue
		if _contains_unstable_actor_reference(descriptor):
			var session_id := _descriptor_session_id(descriptor)
			if not session_id.is_empty():
				unsafe_session_ids[session_id] = true

	for field_name in ["action", "activity", "pending_travel"]:
		var descriptor = record.get(field_name, {})
		if not (descriptor is Dictionary) or descriptor.is_empty():
			continue
		var session_id := _descriptor_session_id(descriptor)
		if (
			_contains_unstable_actor_reference(descriptor)
			or (
				not session_id.is_empty()
				and unsafe_session_ids.has(session_id)
			)
		):
			record[field_name] = {}


static func _contains_unstable_actor_reference(value: Variant) -> bool:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for key in dictionary.keys():
			var nested = dictionary[key]
			if (
				ACTOR_REFERENCE_KEYS.has(String(key))
				and (nested is String or nested is StringName)
			):
				var actor_id := String(nested).strip_edges()
				if not actor_id.is_empty() and not Identity.is_stable_id(actor_id):
					return true
			if (
				(nested is Dictionary or nested is Array)
				and _contains_unstable_actor_reference(nested)
			):
				return true
	elif value is Array:
		for nested in value:
			if (
				(nested is Dictionary or nested is Array)
				and _contains_unstable_actor_reference(nested)
			):
				return true
	return false


static func _descriptor_session_id(descriptor: Dictionary) -> String:
	for key in ["session_id", "action_session_id", "activity_id", "request_id"]:
		var session_id := String(descriptor.get(key, "")).strip_edges()
		if not session_id.is_empty():
			return session_id
	var nested_activity = descriptor.get("activity", {})
	if nested_activity is Dictionary:
		return _descriptor_session_id(nested_activity)
	return ""


static func _rewrite_exact_actor_aliases(
	value: Variant,
	aliases: Dictionary,
	canonical_id: String
) -> void:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for key in dictionary.keys():
			var nested = dictionary[key]
			if (
				ACTOR_REFERENCE_KEYS.has(String(key))
				and (nested is String or nested is StringName)
				and aliases.has(String(nested).strip_edges())
			):
				dictionary[key] = canonical_id
			elif nested is Dictionary or nested is Array:
				_rewrite_exact_actor_aliases(nested, aliases, canonical_id)
	elif value is Array:
		for nested in value:
			if nested is Dictionary or nested is Array:
				_rewrite_exact_actor_aliases(nested, aliases, canonical_id)


static func _sanitize_persisted_actor_references(
	value: Variant,
	canonical_owner_id: String
) -> void:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for key in dictionary.keys():
			var nested = dictionary[key]
			var key_text := String(key)
			if (
				ACTOR_REFERENCE_KEYS.has(key_text)
				and (nested is String or nested is StringName)
			):
				var actor_id := String(nested).strip_edges()
				if actor_id.is_empty():
					continue
				if key_text == "npc_id" and not Identity.is_stable_id(actor_id):
					dictionary[key] = canonical_owner_id
				elif not Identity.is_stable_id(actor_id):
					dictionary.erase(key)
			elif nested is Dictionary or nested is Array:
				_sanitize_persisted_actor_references(nested, canonical_owner_id)
	elif value is Array:
		for nested in value:
			if nested is Dictionary or nested is Array:
				_sanitize_persisted_actor_references(nested, canonical_owner_id)
