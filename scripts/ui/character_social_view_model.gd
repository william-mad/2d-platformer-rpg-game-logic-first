class_name CharacterSocialViewModel extends RefCounted

const Identity = preload("res://scripts/systems/npc_identity.gd")
const SocialSchema = preload("res://scripts/systems/npc_social_state_schema.gd")

const PLAYER_ID := "__player__"
const LEGACY_DIRECTED_LOCAL_KEYS := {
	"favor": true,
	"love": true,
	"trust": true,
	"fear": true,
	"suspicion": true,
}
const DEFAULT_ACCENT := Color(0.78, 0.68, 0.42, 1.0)
const PLAYER_ACCENT := Color(0.54, 0.87, 0.68, 1.0)

var _relationships: Object
var _locations: Object
var _records: Dictionary = {}
var _actor_directory: Dictionary = {}
var _known_owner_ids: Array[String] = []
var _profile_cache: Dictionary = {}


func _init(relationships: Object = null, locations: Object = null) -> void:
	_relationships = relationships
	_locations = locations


func configure(relationships: Object, locations: Object) -> void:
	_relationships = relationships
	_locations = locations
	refresh()


func refresh() -> void:
	# The location API keeps snapshot reads side-effect free. Refresh live records
	# once when this low-frequency menu page opens, never as a UI poll.
	if _locations != null and _locations.has_method("synchronize_live_records"):
		_locations.call("synchronize_live_records")
	_records = _get_records_snapshot()
	_actor_directory = _get_actor_directory_snapshot()
	_profile_cache.clear()
	var known_ids: Dictionary = {}
	if (
		_relationships != null
		and _relationships.has_method("get_known_character_ids_snapshot")
	):
		var directory_ids = _relationships.call(
			"get_known_character_ids_snapshot", PLAYER_ID, false
		)
		if directory_ids is PackedStringArray or directory_ids is Array:
			for actor_id_value in directory_ids:
				var actor_id := String(actor_id_value).strip_edges()
				if Identity.is_stable_id(actor_id) and not Identity.is_player_id(actor_id):
					known_ids[actor_id] = true

	# Compatibility fallback for older relationship authorities without a
	# viewer-filtered actor directory.
	var player_rows := _get_relationships_for_id(PLAYER_ID)
	for target_key in player_rows.keys():
		var target_id := String(target_key).strip_edges()
		var row = player_rows[target_key]
		if _is_known_stable_npc(target_id, row):
			known_ids[target_id] = true

	for record_key in _records.keys():
		var owner_id := String(record_key).strip_edges()
		if not Identity.is_stable_id(owner_id) or Identity.is_player_id(owner_id):
			continue
		var owner_rows := _get_relationships_for_id(owner_id)
		if _is_real_met_row(owner_rows.get(PLAYER_ID, {})):
			known_ids[owner_id] = true

	_known_owner_ids.clear()
	for owner_key in known_ids.keys():
		_known_owner_ids.append(String(owner_key))
	_known_owner_ids.sort_custom(Callable(self, "_sort_actor_ids"))


func get_known_owner_ids() -> Array[String]:
	return _known_owner_ids.duplicate()


func get_subject_ids(owner_id: String) -> Array[String]:
	var subjects: Array[String] = [PLAYER_ID]
	for known_id in _known_owner_ids:
		if known_id != owner_id:
			subjects.append(known_id)
	return subjects


func get_actor_profile(actor_id: String) -> Dictionary:
	var clean_id := actor_id.strip_edges()
	if clean_id.is_empty():
		return _fallback_profile("unknown", "Unknown")
	if _profile_cache.has(clean_id):
		return (_profile_cache[clean_id] as Dictionary).duplicate(true)

	var profile := _build_profile(clean_id)
	_profile_cache[clean_id] = profile.duplicate(true)
	return profile


func get_opinion(owner_id: String, subject_id: String) -> Dictionary:
	var clean_owner := owner_id.strip_edges()
	var clean_subject := subject_id.strip_edges()
	var owner_profile := get_actor_profile(clean_owner)
	var subject_profile := get_actor_profile(clean_subject)
	var result := {
		"recorded": false,
		"owner_id": clean_owner,
		"subject_id": clean_subject,
		"owner_profile": owner_profile,
		"subject_profile": subject_profile,
		"direction": _direction_text(owner_profile, subject_profile),
		"metrics": [],
		"relationship": {},
	}
	if clean_owner.is_empty() or clean_subject.is_empty() or clean_owner == clean_subject:
		return result

	var relationship := _get_relationship_by_id(clean_owner, clean_subject)
	if not _is_real_met_row(relationship):
		return result

	var metrics: Array[Dictionary] = []
	for metric_text in SocialSchema.get_directed_opinion_metrics():
		var metric_id := StringName(metric_text)
		if not relationship.has(metric_id) and not relationship.has(String(metric_id)):
			continue
		var definition := SocialSchema.get_directed_opinion_definition(metric_id)
		if definition.is_empty():
			continue
		metrics.append({
			"id": metric_id,
			"label": String(definition.get("label", String(metric_id).capitalize())),
			"minimum": float(definition.get("minimum", 0.0)),
			"maximum": float(definition.get("maximum", 100.0)),
			"value": float(relationship.get(metric_id, relationship.get(String(metric_id), 0.0))),
			"polarity": int((definition.get("presentation", {}) as Dictionary).get("polarity", 0)),
		})
	result["recorded"] = true
	result["metrics"] = metrics
	result["relationship"] = relationship.duplicate(true)
	return result


func get_owner_characteristics(owner_id: String) -> Array[Dictionary]:
	var record := _get_record(owner_id)
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return []
	var values = node_state.get("social_stats", node_state.get("values", {}))
	if not (values is Dictionary):
		return []

	var characteristics: Array[Dictionary] = []
	for value_id in SocialSchema.VALUE_ORDER:
		var key := String(value_id)
		if LEGACY_DIRECTED_LOCAL_KEYS.has(key):
			continue
		if not values.has(value_id) and not values.has(key):
			continue
		var definition := SocialSchema.get_definition(value_id)
		if definition.is_empty():
			continue
		var scope := StringName(definition.get("scope", &""))
		if scope == SocialSchema.SCOPE_DIRECTED_OPINION:
			continue
		var presentation = definition.get("presentation", {})
		if presentation is Dictionary and not bool(presentation.get("show_in_character_page", true)):
			continue
		characteristics.append({
			"id": value_id,
			"label": String(definition.get("label", key.capitalize())),
			"section": String((presentation as Dictionary).get("section", "characteristics")),
			"format": String((presentation as Dictionary).get("format", "meter")),
			"minimum": float(definition.get("minimum", 0.0)),
			"maximum": float(definition.get("maximum", 100.0)),
			"value": float(values.get(value_id, values.get(key, 0.0))),
		})
	return characteristics


func get_owner_runtime_summary(owner_id: String) -> Dictionary:
	var record := _get_record(owner_id)
	if record.is_empty():
		return {}
	var scene_path := String(record.get("scene_path", ""))
	var state_name := "Idle"
	var activity = record.get("activity", {})
	if activity is Dictionary and not activity.is_empty():
		state_name = String(activity.get("state_name", "Active"))
	else:
		var node_state = record.get("node_state", {})
		if node_state is Dictionary:
			state_name = String(node_state.get("current_state_name", node_state.get("state_name", state_name)))
	return {
		"live": _is_npc_live(owner_id),
		"scene_name": scene_path.get_file().get_basename().replace("_", " ").capitalize(),
		"state_name": state_name,
	}


func _get_records_snapshot() -> Dictionary:
	if _locations == null or not _locations.has_method("get_records_snapshot"):
		return {}
	var records = _locations.call("get_records_snapshot")
	return records.duplicate(true) if records is Dictionary else {}


func _get_actor_directory_snapshot() -> Dictionary:
	if (
		_relationships == null
		or not _relationships.has_method("get_known_actor_directory_snapshot")
	):
		return {}
	var directory = _relationships.call(
		"get_known_actor_directory_snapshot", PLAYER_ID
	)
	return directory.duplicate(true) if directory is Dictionary else {}


func _get_record(actor_id: String) -> Dictionary:
	var clean_id := actor_id.strip_edges()
	if clean_id.is_empty():
		return {}
	var record = _records.get(clean_id, {})
	if record is Dictionary:
		return record.duplicate(true)
	if _locations != null and _locations.has_method("get_record_snapshot"):
		record = _locations.call("get_record_snapshot", clean_id)
		if record is Dictionary:
			return record.duplicate(true)
	return {}


func _get_relationships_for_id(owner_id: String) -> Dictionary:
	if _relationships == null or not _relationships.has_method("get_relationships_for_id"):
		return {}
	var rows = _relationships.call("get_relationships_for_id", owner_id)
	return rows.duplicate(true) if rows is Dictionary else {}


func _get_relationship_by_id(owner_id: String, subject_id: String) -> Dictionary:
	if _relationships == null or not _relationships.has_method("get_relationship_by_id"):
		return {}
	var relationship = _relationships.call("get_relationship_by_id", owner_id, subject_id)
	return relationship.duplicate(true) if relationship is Dictionary else {}


func _is_npc_live(owner_id: String) -> bool:
	return (
		_locations != null
		and _locations.has_method("is_npc_live")
		and bool(_locations.call("is_npc_live", owner_id))
	)


func _is_known_stable_npc(actor_id: String, row) -> bool:
	return (
		not Identity.is_player_id(actor_id)
		and Identity.is_stable_id(actor_id)
		and _is_real_met_row(row)
	)


func _is_real_met_row(row) -> bool:
	return row is Dictionary and not row.is_empty() and bool(row.get("met", false))


func _sort_actor_ids(first: String, second: String) -> bool:
	var first_key := _profile_sort_key(first)
	var second_key := _profile_sort_key(second)
	return first_key < second_key


func _profile_sort_key(actor_id: String) -> String:
	var profile := get_actor_profile(actor_id)
	return "%s\n%s" % [
		String(profile.get("display_name", actor_id)).to_lower(),
		actor_id.to_lower(),
	]


func _build_profile(actor_id: String) -> Dictionary:
	if Identity.is_player_id(actor_id):
		return {
			"actor_id": PLAYER_ID,
			"display_name": "Player",
			"subtitle": "You",
			"description": "The person these relationships are connected to.",
			"portrait_path": "",
			"accent_color": PLAYER_ACCENT,
		}

	var record := _get_record(actor_id)
	var profile_value = record.get("character_profile", {})
	var profile: Dictionary = (
		profile_value.duplicate(true) if profile_value is Dictionary else {}
	)
	var fallback_name := String(record.get("node_name", "")).strip_edges()
	var directory_entry = _actor_directory.get(actor_id, {})
	if directory_entry is Dictionary:
		var directory_name := String(
			directory_entry.get("display_name", "")
		).strip_edges()
		if not directory_name.is_empty():
			fallback_name = directory_name
	if fallback_name.is_empty():
		fallback_name = _get_relationship_name(actor_id)
	if fallback_name.is_empty():
		fallback_name = actor_id.replace("_", " ").capitalize()
	profile["actor_id"] = actor_id
	profile["display_name"] = String(profile.get("display_name", fallback_name)).strip_edges()
	if String(profile["display_name"]).is_empty():
		profile["display_name"] = fallback_name
	profile["subtitle"] = String(profile.get("subtitle", "Known character")).strip_edges()
	profile["description"] = String(profile.get("description", "")).strip_edges()
	profile["portrait_path"] = String(profile.get("portrait_path", "")).strip_edges()
	var accent = profile.get("accent_color", DEFAULT_ACCENT)
	profile["accent_color"] = accent if accent is Color else DEFAULT_ACCENT
	return profile


func _get_relationship_name(actor_id: String) -> String:
	var player_row = _get_relationships_for_id(PLAYER_ID).get(actor_id, {})
	if player_row is Dictionary:
		var target_name := String(player_row.get("other_name", "")).strip_edges()
		if not target_name.is_empty():
			return target_name
	var owner_row = _get_relationships_for_id(actor_id).get(PLAYER_ID, {})
	if owner_row is Dictionary:
		var owner_name := String(owner_row.get("owner_name", "")).strip_edges()
		if not owner_name.is_empty():
			return owner_name
	return ""


func _fallback_profile(actor_id: String, display_name: String) -> Dictionary:
	return {
		"actor_id": actor_id,
		"display_name": display_name,
		"subtitle": "",
		"description": "",
		"portrait_path": "",
		"accent_color": DEFAULT_ACCENT,
	}


func _direction_text(owner_profile: Dictionary, subject_profile: Dictionary) -> String:
	return "%s  ->  %s" % [
		String(owner_profile.get("display_name", "Unknown")).to_upper(),
		String(subject_profile.get("display_name", "Unknown")).to_upper(),
	]
