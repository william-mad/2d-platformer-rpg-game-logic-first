class_name NpcIdentity extends RefCounted

## Canonical identity shared by relationships, activity sessions, and memories.
const PLAYER_ACTOR_ID: StringName = &"__player__"


## Returns an authored, save-safe actor identity. Scene paths and generated
## instance identities are deliberately excluded.
static func get_stable_actor_id(actor: Node) -> String:
	if actor == null or not is_instance_valid(actor):
		return ""
	if actor.is_in_group("player"):
		return String(PLAYER_ACTOR_ID)

	# Production actors return from their explicit contract before reflection.
	# Legacy property-only actors retain the exact historical candidate order.
	var candidate := _get_method_identity(actor, &"get_npc_location_id")
	if is_stable_id(candidate):
		return candidate
	candidate = _get_meta_identity(actor, &"npc_location_id")
	if is_stable_id(candidate):
		return candidate
	candidate = _get_property_identity(actor, &"location_id")
	if is_stable_id(candidate):
		return candidate
	candidate = _get_method_identity(actor, &"get_relationship_id")
	if is_stable_id(candidate):
		return candidate
	candidate = _get_meta_identity(actor, &"relationship_id")
	if is_stable_id(candidate):
		return candidate
	candidate = _get_property_identity(actor, &"relationship_id")
	if is_stable_id(candidate):
		return candidate
	candidate = _get_method_identity(actor, &"get_persistent_actor_id")
	if is_stable_id(candidate):
		return candidate
	candidate = _get_property_identity(actor, &"persistent_id")
	if is_stable_id(candidate):
		return candidate
	return ""


## Relationship callers historically supported actors without authored IDs.
## Keep that runtime fallback while ensuring all player instances share one ID.
static func get_actor_id(
	actor: Node,
	allow_transient_fallback: bool = false,
	allow_generated_instance_fallback: bool = true
) -> String:
	var stable_id := get_stable_actor_id(actor)
	if not stable_id.is_empty() or not allow_transient_fallback:
		return stable_id
	if actor == null or not is_instance_valid(actor):
		return ""

	# Preserve a legacy actor's own fallback before synthesizing a new one.
	for candidate in _get_actor_identity_candidates(actor):
		if not candidate.is_empty():
			return candidate
	if actor.is_inside_tree():
		return String(actor.get_path())
	if allow_generated_instance_fallback:
		return "instance:%s" % actor.get_instance_id()
	return ""


## Returns every identity by which an existing actor may have been stored.
## The canonical identity itself is omitted so callers can migrate aliases.
static func get_actor_aliases(actor: Node) -> Array[String]:
	var aliases: Array[String] = []
	if actor == null or not is_instance_valid(actor):
		return aliases
	var canonical_id := get_actor_id(actor, true)
	for candidate in _get_actor_identity_candidates(actor):
		_append_unique_alias(aliases, candidate, canonical_id)
	if actor.is_inside_tree():
		_append_unique_alias(aliases, String(actor.get_path()), canonical_id)
	_append_unique_alias(
		aliases,
		"instance:%s" % actor.get_instance_id(),
		canonical_id
	)
	_append_unique_alias(
		aliases,
		"npc:%s" % actor.get_instance_id(),
		canonical_id
	)
	return aliases


## Resolves authored spot identities, including the Eat override exposed by a
## combined work/eat spot. Explicit spot APIs remain authoritative.
static func get_spot_id(
	target: Node,
	action_kind: StringName = &""
) -> String:
	if target == null or not is_instance_valid(target):
		return ""

	if String(action_kind).to_lower() == "eat" and has_property(
		target,
		&"eat_world_definition"
	):
		var eat_spot_id := _get_definition_spot_id(
			target.get("eat_world_definition")
		)
		if not eat_spot_id.is_empty():
			return eat_spot_id

	for method_name in [
		&"get_world_spot_id",
		&"get_persistent_spot_id",
		&"get_spot_id",
	]:
		var method_id := _get_method_identity(target, method_name)
		if not method_id.is_empty():
			return method_id

	if has_property(target, &"spot_id"):
		var property_id := String(target.get("spot_id")).strip_edges()
		if not property_id.is_empty():
			return property_id
	if has_property(target, &"world_definition"):
		return _get_definition_spot_id(target.get("world_definition"))
	return ""


## Generic action targets may be either actors or spots. This keeps the legacy
## runtime fallback for exact live-node sessions, but persisted actors use the
## same canonical identity as relationships and memory.
static func get_target_id(
	target: Node,
	action_kind: StringName = &"",
	allow_transient_fallback: bool = true,
	allow_generated_instance_fallback: bool = true
) -> String:
	if target == null or not is_instance_valid(target):
		return ""
	if target.is_in_group("player"):
		return String(PLAYER_ACTOR_ID)
	var spot_id := get_spot_id(target, action_kind)
	if not spot_id.is_empty():
		return spot_id
	return get_actor_id(
		target,
		allow_transient_fallback,
		allow_generated_instance_fallback
	)


static func is_stable_id(candidate: String) -> bool:
	var clean_id := candidate.strip_edges()
	if (
		clean_id.is_empty()
		or clean_id.begins_with("@")
		or clean_id.contains("/")
		or clean_id.contains("\\")
	):
		return false
	if clean_id.begins_with("instance:"):
		return false
	if clean_id.begins_with("npc:") and clean_id.substr(4).is_valid_int():
		return false
	return true


static func is_player_id(candidate: String) -> bool:
	return candidate.strip_edges() == String(PLAYER_ACTOR_ID)


## Old relationship saves keyed the player by its scene-tree path. Only migrate
## rows with explicit player evidence; arbitrary path-keyed NPC rows stay intact.
static func canonicalize_saved_actor_id(
	stored_id: String,
	actor_name: String = "",
	actor_path: String = ""
) -> String:
	var clean_id := stored_id.strip_edges()
	if clean_id.is_empty() or is_player_id(clean_id):
		return clean_id
	var clean_name := actor_name.strip_edges().to_lower()
	var clean_path := actor_path.strip_edges()
	var id_is_player_path := _looks_like_player_path(clean_id)
	var path_matches_id := not clean_path.is_empty() and clean_path == clean_id
	if (
		id_is_player_path
		and (clean_name == "player" or path_matches_id)
	):
		return String(PLAYER_ACTOR_ID)
	return clean_id


static func has_property(object: Object, property_name: StringName) -> bool:
	if object == null:
		return false
	for descriptor in object.get_property_list():
		if StringName(descriptor.get("name", &"")) == property_name:
			return true
	return false


static func _get_actor_identity_candidates(actor: Node) -> Array[String]:
	var candidates: Array[String] = []
	_append_unique(candidates, _get_method_identity(actor, &"get_npc_location_id"))
	_append_unique(candidates, _get_meta_identity(actor, &"npc_location_id"))
	_append_unique(candidates, _get_property_identity(actor, &"location_id"))
	_append_unique(candidates, _get_method_identity(actor, &"get_relationship_id"))
	_append_unique(candidates, _get_meta_identity(actor, &"relationship_id"))
	_append_unique(candidates, _get_property_identity(actor, &"relationship_id"))
	_append_unique(candidates, _get_method_identity(actor, &"get_persistent_actor_id"))
	_append_unique(candidates, _get_property_identity(actor, &"persistent_id"))
	return candidates


static func _get_method_identity(actor: Node, method_name: StringName) -> String:
	if actor == null or not actor.has_method(method_name):
		return ""
	return String(actor.call(method_name)).strip_edges()


static func _get_meta_identity(actor: Node, metadata_name: StringName) -> String:
	if actor == null or not actor.has_meta(metadata_name):
		return ""
	return String(actor.get_meta(metadata_name)).strip_edges()


static func _get_property_identity(actor: Node, property_name: StringName) -> String:
	if actor == null or not has_property(actor, property_name):
		return ""
	return String(actor.get(property_name)).strip_edges()


static func _get_definition_spot_id(definition) -> String:
	if definition == null:
		return ""
	if definition is Dictionary:
		return String(definition.get("spot_id", "")).strip_edges()
	if definition is Object and has_property(definition, &"spot_id"):
		return String(definition.get("spot_id")).strip_edges()
	return ""


static func _append_unique(values: Array[String], candidate: String) -> void:
	var clean_id := candidate.strip_edges()
	if not clean_id.is_empty() and not values.has(clean_id):
		values.append(clean_id)


static func _append_unique_alias(
	aliases: Array[String],
	candidate: String,
	canonical_id: String
) -> void:
	var clean_id := candidate.strip_edges()
	if (
		not clean_id.is_empty()
		and clean_id != canonical_id
		and not aliases.has(clean_id)
	):
		aliases.append(clean_id)


static func _looks_like_player_path(candidate: String) -> bool:
	var normalized := candidate.strip_edges().replace("\\", "/").trim_suffix("/")
	if not normalized.contains("/"):
		return false
	return normalized.get_file().to_lower() == "player"
