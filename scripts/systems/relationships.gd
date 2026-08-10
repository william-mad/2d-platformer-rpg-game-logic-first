extends Node

const Identity = preload("res://scripts/systems/npc_identity.gd")
const RelationshipStore = preload("res://scripts/systems/npc_relationship_store.gd")
const SocialStateSchema = preload("res://scripts/systems/npc_social_state_schema.gd")
const SAVE_VERSION: int = 3
const MAX_MIGRATED_ACTOR_CACHE_ENTRIES: int = 512
const MAX_MIGRATED_ALIAS_CACHE_ENTRIES: int = 2048

signal relationship_met(relationship_owner: Node, other: Node, relationship: Dictionary)
signal relationship_seen(relationship_owner: Node, other: Node, relationship: Dictionary)
signal relationship_changed(relationship_owner: Node, other: Node, changed_values: Dictionary, relationship: Dictionary)
signal favor_changed(relationship_owner: Node, other: Node, favor: float, delta: float, relationship: Dictionary)
signal anger_changed(relationship_owner: Node, other: Node, anger: float, delta: float, relationship: Dictionary)
signal fear_changed(relationship_owner: Node, other: Node, fear: float, delta: float, relationship: Dictionary)
signal relationship_graph_replaced

@export var default_favor: float = 50.0
@export var min_favor: float = 0.0
@export var max_favor: float = 100.0
@export var min_anger: float = 0.0
@export var max_anger: float = 100.0
@export var min_fear: float = 0.0
@export var max_fear: float = 100.0
@export var default_trust: float = 50.0
@export var min_trust: float = 0.0
@export var max_trust: float = 100.0
@export var default_love: float = 0.0
@export var min_love: float = 0.0
@export var max_love: float = 100.0
@export var default_suspicion: float = 0.0
@export var min_suspicion: float = 0.0
@export var max_suspicion: float = 100.0
@export var emit_event_bus_events: bool = true
@export var relationship_event_scope: StringName = &"scene"

var relationships: Dictionary = {}
var _migrated_actor_aliases: Dictionary = {}
var _migrated_relationship_aliases: Dictionary = {}


func meet(
	relationship_owner: Node,
	other: Node,
	starting_favor: float = -1.0,
	favor_delta: float = 0.0,
	context: Dictionary = {}
) -> Dictionary:
	if not _can_store_relationship(relationship_owner, other):
		return {}

	var owner_id := get_relationship_id(relationship_owner)
	var other_id := get_relationship_id(other)
	var created := not has_relationship_by_id(owner_id, other_id)
	var initial_favor := default_favor if starting_favor < 0.0 else starting_favor
	var relationship := _get_or_create_relationship(owner_id, other_id, relationship_owner, other, initial_favor)
	var stored_context := _get_storable_context(context)

	relationship["met"] = true
	relationship["meet_count"] = int(relationship.get("meet_count", 0)) + 1
	relationship["last_seen_msec"] = _now_msec()
	relationship["last_context"] = stored_context

	var relationship_copy := relationship.duplicate(true)
	relationship_seen.emit(relationship_owner, other, relationship_copy)

	if created:
		relationship_met.emit(relationship_owner, other, relationship_copy)
		_emit_relationship_event(&"relationship_met", relationship_owner, other, relationship_copy, {}, "meet")

	if not is_equal_approx(favor_delta, 0.0):
		change_favor(relationship_owner, other, favor_delta, String(stored_context.get("reason", "meet")), stored_context)

	return relationship.duplicate(true)


func meet_each_other(
	first: Node,
	second: Node,
	starting_favor: float = -1.0,
	favor_delta: float = 0.0,
	context: Dictionary = {}
) -> void:
	meet(first, second, starting_favor, favor_delta, context)
	meet(second, first, starting_favor, favor_delta, context)


func change_favor(
	relationship_owner: Node,
	other: Node,
	delta: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	var current_favor := get_favor(
		relationship_owner, other, default_favor
	)
	return set_favor(
		relationship_owner, other, current_favor + delta, reason, context
	)


func change_favor_by_id(
	relationship_owner: Node,
	other_id: String,
	delta: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	var owner_id := get_relationship_id(relationship_owner)
	var current_favor := get_favor_by_id(owner_id, other_id, default_favor)
	return set_favor_by_id(
		relationship_owner, other_id, current_favor + delta, reason, context
	)


func set_favor(
	relationship_owner: Node,
	other: Node,
	value: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	return set_opinion_metric(
		relationship_owner, other, &"favor", value, reason, context
	)


func set_favor_by_id(
	relationship_owner: Node,
	other_id: String,
	value: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	if not _can_store_relationship_by_id(relationship_owner, other_id):
		return default_favor
	var owner_id := get_relationship_id(relationship_owner).strip_edges()
	var runtime_context := context.duplicate()
	runtime_context["relationship_owner"] = relationship_owner
	return set_opinion_metric_by_id(
		owner_id, other_id, &"favor", value, reason, runtime_context
	)


func get_favor(relationship_owner: Node, other: Node, fallback: float = -1.0) -> float:
	var resolved_fallback := default_favor if fallback < 0.0 else fallback
	return get_opinion_metric(
		relationship_owner, other, &"favor", resolved_fallback
	)


func get_favor_by_id(owner_id: String, other_id: String, fallback: float = -1.0) -> float:
	var resolved_fallback := default_favor if fallback < 0.0 else fallback
	return get_opinion_metric_by_id(
		owner_id, other_id, &"favor", resolved_fallback
	)


## Generic directed-opinion API. The first actor is always the opinion owner;
## the second actor is always its explicit subject.
func get_opinion_metric(
	relationship_owner: Node,
	other: Node,
	metric_id: StringName,
	fallback = null
) -> float:
	if relationship_owner == null or other == null:
		return _get_opinion_fallback(metric_id, fallback)
	return get_opinion_metric_by_id(
		get_relationship_id(relationship_owner),
		get_relationship_id(other),
		metric_id,
		fallback
	)


func get_opinion_metric_by_id(
	owner_id: String,
	other_id: String,
	metric_id: StringName,
	fallback = null
) -> float:
	var missing_fallback := _get_opinion_fallback(metric_id, fallback)
	if not SocialStateSchema.is_directed_opinion_metric(metric_id):
		return missing_fallback
	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	if not has_relationship_by_id(clean_owner_id, clean_other_id):
		return missing_fallback
	var relationship: Dictionary = relationships[clean_owner_id][clean_other_id]
	var key := String(metric_id)
	var value := float(
		relationship.get(key, _get_opinion_default(metric_id))
	)
	return clampf(
		value,
		_get_opinion_minimum(metric_id),
		_get_opinion_maximum(metric_id)
	)


func set_opinion_metric(
	relationship_owner: Node,
	other: Node,
	metric_id: StringName,
	value: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	if not _can_store_relationship(relationship_owner, other):
		return _get_opinion_default(metric_id)
	var runtime_context := context.duplicate()
	runtime_context["relationship_owner"] = relationship_owner
	runtime_context["other"] = other
	return set_opinion_metric_by_id(
		get_relationship_id(relationship_owner),
		get_relationship_id(other),
		metric_id,
		value,
		reason,
		runtime_context
	)


func set_opinion_metric_by_id(
	owner_id: String,
	other_id: String,
	metric_id: StringName,
	value: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	return _set_opinion_metric_by_id(
		owner_id, other_id, metric_id, value, reason, context, true
	)


func _set_opinion_metric_by_id(
	owner_id: String,
	other_id: String,
	metric_id: StringName,
	value: float,
	reason: String,
	context: Dictionary,
	emit_met_on_create: bool
) -> float:
	var default_value := _get_opinion_default(metric_id)
	if (
		not SocialStateSchema.is_directed_opinion_metric(metric_id)
		or not _can_store_relationship_ids(owner_id, other_id)
	):
		return default_value

	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	var relationship_owner := _get_context_node(context, "relationship_owner")
	var other := _get_context_node(context, "other")
	var created := not has_relationship_by_id(clean_owner_id, clean_other_id)
	var relationship := _get_or_create_relationship_by_id(
		clean_owner_id,
		clean_other_id,
		relationship_owner,
		other,
		default_favor,
		context
	)
	if relationship.is_empty():
		return default_value

	var key := String(metric_id)
	var previous_value := float(relationship.get(key, default_value))
	var next_value := clampf(
		value,
		_get_opinion_minimum(metric_id),
		_get_opinion_maximum(metric_id)
	)
	var stored_context := _get_storable_context(context)
	if created and emit_met_on_create:
		relationship["met"] = true
		relationship["last_reason"] = reason
		relationship["last_context"] = stored_context
		var created_copy := relationship.duplicate(true)
		relationship_met.emit(relationship_owner, other, created_copy)
		_emit_relationship_event(
			&"relationship_met",
			relationship_owner,
			other,
			created_copy,
			{},
			reason
		)
	if is_equal_approx(previous_value, next_value):
		return next_value

	relationship[key] = next_value
	relationship["met"] = true
	relationship["updated_at_msec"] = _now_msec()
	relationship["last_reason"] = reason
	relationship["last_context"] = stored_context
	var delta := next_value - previous_value
	var changed_values: Dictionary = {}
	changed_values[key] = delta
	var relationship_copy := relationship.duplicate(true)
	relationship_changed.emit(
		relationship_owner,
		other,
		changed_values,
		relationship_copy
	)
	_emit_legacy_metric_signal(
		metric_id,
		relationship_owner,
		other,
		next_value,
		delta,
		relationship_copy
	)
	_emit_relationship_event(
		StringName("relationship_%s_changed" % key),
		relationship_owner,
		other,
		relationship_copy,
		changed_values,
		reason
	)
	return next_value


func change_opinion_metric(
	relationship_owner: Node,
	other: Node,
	metric_id: StringName,
	delta: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	if is_zero_approx(delta):
		return get_opinion_metric(
			relationship_owner, other, metric_id
		)
	var current_value := get_opinion_metric(
		relationship_owner,
		other,
		metric_id
	)
	return set_opinion_metric(
		relationship_owner,
		other,
		metric_id,
		current_value + delta,
		reason,
		context
	)


func change_opinion_metric_by_id(
	owner_id: String,
	other_id: String,
	metric_id: StringName,
	delta: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	if is_zero_approx(delta):
		return get_opinion_metric_by_id(owner_id, other_id, metric_id)
	var current_value := get_opinion_metric_by_id(
		owner_id,
		other_id,
		metric_id
	)
	return set_opinion_metric_by_id(
		owner_id,
		other_id,
		metric_id,
		current_value + delta,
		reason,
		context
	)


## Applies one actor-directed interaction through a single relationship record
## transaction. IDs are already canonical, so this path performs no actor
## resolution or legacy alias discovery.
func apply_opinion_deltas_by_id(
	owner_id: String,
	other_id: String,
	deltas: Dictionary,
	reason: String = "social_event",
	context: Dictionary = {}
) -> Dictionary:
	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	if not _can_store_relationship_ids(clean_owner_id, clean_other_id):
		return {
			"accepted": false,
			"eligible": false,
			"changed": false,
			"created": false,
			"changed_values": {},
			"relationship": {},
			"reason": "invalid_identity",
		}

	var normalized_deltas: Dictionary = {}
	for raw_metric_id in deltas.keys():
		var metric_id := StringName(String(raw_metric_id))
		if not SocialStateSchema.is_directed_opinion_metric(metric_id):
			continue
		var delta := float(deltas[raw_metric_id])
		if not is_finite(delta) or is_zero_approx(delta):
			continue
		var metric_key := String(metric_id)
		normalized_deltas[metric_key] = float(
			normalized_deltas.get(metric_key, 0.0)
		) + delta

	var metric_ids: Array[String] = []
	for metric_key in normalized_deltas.keys():
		if not is_zero_approx(float(normalized_deltas[metric_key])):
			metric_ids.append(String(metric_key))
	metric_ids.sort()
	if metric_ids.is_empty():
		return {
			"accepted": true,
			"eligible": false,
			"changed": false,
			"created": false,
			"changed_values": {},
			"relationship": {},
			"reason": "no_eligible_delta",
		}

	var relationship_owner := _get_context_node(context, "relationship_owner")
	var other := _get_context_node(context, "other")
	var created := not has_relationship_by_id(clean_owner_id, clean_other_id)
	var relationship: Dictionary = {}
	var opinion_policy := _get_opinion_policy()
	if not created:
		relationship = relationships[clean_owner_id][clean_other_id]
		RelationshipStore.normalize_row_in_place(relationship, opinion_policy)

	var next_values: Dictionary = {}
	var changed_values: Dictionary = {}
	for metric_key in metric_ids:
		var metric_id := StringName(metric_key)
		var default_value := RelationshipStore.get_metric_default(
			opinion_policy, metric_id
		)
		var minimum := RelationshipStore.get_metric_minimum(
			opinion_policy, metric_id
		)
		var maximum := RelationshipStore.get_metric_maximum(
			opinion_policy, metric_id
		)
		var previous_value := default_value
		if not created:
			previous_value = float(relationship.get(metric_key, default_value))
		previous_value = clampf(previous_value, minimum, maximum)
		var requested_value := (
			previous_value + float(normalized_deltas[metric_key])
		)
		var schema_bounded_value := clampf(
			requested_value,
			SocialStateSchema.get_directed_opinion_minimum(metric_id),
			SocialStateSchema.get_directed_opinion_maximum(metric_id)
		)
		if is_equal_approx(previous_value, schema_bounded_value):
			continue
		var next_value := clampf(
			requested_value,
			minimum,
			maximum
		)
		if is_equal_approx(previous_value, next_value):
			continue
		next_values[metric_key] = next_value
		changed_values[metric_key] = next_value - previous_value

	if changed_values.is_empty():
		return {
			"accepted": true,
			"eligible": true,
			"changed": false,
			"created": false,
			"changed_values": {},
			"relationship": {},
			"reason": "clamped",
		}

	if created:
		relationship = _get_or_create_relationship_by_id(
			clean_owner_id,
			clean_other_id,
			relationship_owner,
			other,
			default_favor,
			context
		)
	else:
		_update_relationship_identity_fields(
			relationship, relationship_owner, other, context
		)
	if relationship.is_empty():
		return {
			"accepted": false,
			"eligible": true,
			"changed": false,
			"created": false,
			"changed_values": {},
			"relationship": {},
			"reason": "relationship_unavailable",
		}

	for metric_key in metric_ids:
		if next_values.has(metric_key):
			relationship[metric_key] = next_values[metric_key]
	var stored_context := _get_storable_context(context)
	relationship["met"] = true
	relationship["updated_at_msec"] = _now_msec()
	relationship["last_reason"] = reason
	relationship["last_context"] = stored_context
	var relationship_copy := relationship.duplicate(true)
	if created:
		relationship_met.emit(
			relationship_owner, other, relationship_copy
		)
		_emit_relationship_event(
			&"relationship_met",
			relationship_owner,
			other,
			relationship_copy,
			{},
			reason
		)
	relationship_changed.emit(
		relationship_owner,
		other,
		changed_values,
		relationship_copy
	)
	for metric_key in metric_ids:
		if not changed_values.has(metric_key):
			continue
		_emit_legacy_metric_signal(
			StringName(metric_key),
			relationship_owner,
			other,
			float(next_values[metric_key]),
			float(changed_values[metric_key]),
			relationship_copy
		)
	_emit_relationship_event(
		&"relationship_changed",
		relationship_owner,
		other,
		relationship_copy,
		changed_values,
		reason
	)
	return {
		"accepted": true,
		"eligible": true,
		"changed": true,
		"created": created,
		"changed_values": changed_values,
		"relationship": relationship_copy,
		"reason": "changed",
	}


func change_anger(
	relationship_owner: Node,
	other: Node,
	delta: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	var current_anger := get_opinion_metric(
		relationship_owner, other, &"anger", min_anger
	)
	return set_anger(
		relationship_owner, other, current_anger + delta, reason, context
	)


func set_anger(
	relationship_owner: Node,
	other: Node,
	value: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	if not _can_store_relationship(relationship_owner, other):
		return min_anger
	var runtime_context := context.duplicate()
	runtime_context["relationship_owner"] = relationship_owner
	runtime_context["other"] = other
	return _set_opinion_metric_by_id(
		get_relationship_id(relationship_owner),
		get_relationship_id(other),
		&"anger",
		value,
		reason,
		runtime_context,
		false
	)


func get_anger(relationship_owner: Node, other: Node, fallback: float = 0.0) -> float:
	return get_opinion_metric(
		relationship_owner, other, &"anger", fallback
	)


func decay_anger_for(relationship_owner: Node, amount: float) -> void:
	if relationship_owner == null or amount <= 0.0:
		return

	var owner_id := get_relationship_id(relationship_owner).strip_edges()
	decay_anger_for_id(owner_id, amount, relationship_owner)


func decay_anger_for_id(owner_id: String, amount: float, relationship_owner: Node = null) -> void:
	# Off-screen simulation identifies relationship owners by their stable saved id.
	owner_id = owner_id.strip_edges()
	if amount <= 0.0:
		return
	if owner_id.is_empty() or not relationships.has(owner_id):
		return

	for other_id in relationships[owner_id].keys():
		var relationship: Dictionary = relationships[owner_id][other_id]
		var previous_anger := float(relationship.get("anger", min_anger))
		if previous_anger <= min_anger:
			continue

		var next_anger := maxf(previous_anger - amount, min_anger)
		var delta := next_anger - previous_anger
		relationship["anger"] = next_anger
		relationship["updated_at_msec"] = _now_msec()
		relationship["last_reason"] = "passive_decay"

		var changed_values := {"anger": delta}
		var relationship_copy := relationship.duplicate(true)
		relationship_changed.emit(relationship_owner, null, changed_values, relationship_copy)
		anger_changed.emit(relationship_owner, null, next_anger, delta, relationship_copy)


func change_fear(
	relationship_owner: Node,
	other: Node,
	delta: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	var current_fear := get_opinion_metric(
		relationship_owner, other, &"fear", min_fear
	)
	return set_fear(
		relationship_owner, other, current_fear + delta, reason, context
	)


func set_fear(
	relationship_owner: Node,
	other: Node,
	value: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	if not _can_store_relationship(relationship_owner, other):
		return min_fear
	var runtime_context := context.duplicate()
	runtime_context["relationship_owner"] = relationship_owner
	runtime_context["other"] = other
	return _set_opinion_metric_by_id(
		get_relationship_id(relationship_owner),
		get_relationship_id(other),
		&"fear",
		value,
		reason,
		runtime_context,
		false
	)


func get_fear(relationship_owner: Node, other: Node, fallback: float = 0.0) -> float:
	return get_opinion_metric(
		relationship_owner, other, &"fear", fallback
	)


func decay_fear_for(
	relationship_owner: Node,
	game_hours: float,
	panic_floor: float,
	panic_cooldown_game_hours: float,
	slow_decay_per_game_hour: float,
	stop_value: float
) -> void:
	if relationship_owner == null or game_hours <= 0.0:
		return

	var owner_id := get_relationship_id(relationship_owner).strip_edges()
	decay_fear_for_id(
		owner_id,
		game_hours,
		panic_floor,
		panic_cooldown_game_hours,
		slow_decay_per_game_hour,
		stop_value,
		relationship_owner
	)


func decay_fear_for_id(
	owner_id: String,
	game_hours: float,
	panic_floor: float,
	panic_cooldown_game_hours: float,
	slow_decay_per_game_hour: float,
	stop_value: float,
	relationship_owner: Node = null
) -> void:
	# Mirrors decay_fear_for() without requiring the owner NPC scene to be loaded.
	owner_id = owner_id.strip_edges()
	if game_hours <= 0.0:
		return
	if owner_id.is_empty() or not relationships.has(owner_id):
		return

	for other_id in relationships[owner_id].keys():
		var relationship: Dictionary = relationships[owner_id][other_id]
		var previous_fear := float(relationship.get("fear", min_fear))
		if previous_fear <= stop_value:
			continue

		var next_fear := previous_fear
		if previous_fear > panic_floor:
			if panic_cooldown_game_hours <= 0.0:
				next_fear = panic_floor
			else:
				var panic_decay_per_hour := (max_fear - panic_floor) / panic_cooldown_game_hours
				next_fear = maxf(previous_fear - panic_decay_per_hour * game_hours, panic_floor)
		else:
			next_fear = maxf(previous_fear - slow_decay_per_game_hour * game_hours, stop_value)

		if is_equal_approx(previous_fear, next_fear):
			continue

		var delta := next_fear - previous_fear
		relationship["fear"] = next_fear
		relationship["updated_at_msec"] = _now_msec()
		relationship["last_reason"] = "passive_decay"

		var changed_values := {"fear": delta}
		var relationship_copy := relationship.duplicate(true)
		relationship_changed.emit(relationship_owner, null, changed_values, relationship_copy)
		fear_changed.emit(relationship_owner, null, next_fear, delta, relationship_copy)


func has_met(relationship_owner: Node, other: Node) -> bool:
	var relationship := get_relationship(relationship_owner, other)
	return bool(relationship.get("met", false))


func get_relationship(relationship_owner: Node, other: Node) -> Dictionary:
	if relationship_owner == null or other == null:
		return {}

	return get_relationship_by_id(get_relationship_id(relationship_owner), get_relationship_id(other))


func get_relationship_by_id(owner_id: String, other_id: String) -> Dictionary:
	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	if not has_relationship_by_id(clean_owner_id, clean_other_id):
		return {}

	var relationship: Dictionary = relationships[clean_owner_id][clean_other_id].duplicate(true)
	_normalize_opinion_metrics_in_place(relationship)
	return relationship


func get_relationships_for(relationship_owner: Node) -> Dictionary:
	if relationship_owner == null:
		return {}

	return get_relationships_for_id(get_relationship_id(relationship_owner))


func get_relationships_for_id(owner_id: String) -> Dictionary:
	var clean_owner_id := owner_id.strip_edges()
	if clean_owner_id.is_empty() or not relationships.has(clean_owner_id):
		return {}

	var rows: Dictionary = relationships[clean_owner_id].duplicate(true)
	for other_id in rows.keys():
		var relationship = rows[other_id]
		if relationship is Dictionary:
			_normalize_opinion_metrics_in_place(relationship)
	return rows


## A presentation-safe, read-only directory built only from met relationships
## with persistence-safe actor IDs. Passing a viewer keeps actors connected to
## that viewer on either directed axis; it does not imply a symmetric opinion.
func get_known_actor_directory_snapshot(viewer_id: String = "") -> Dictionary:
	return RelationshipStore.get_known_actor_directory_snapshot(
		relationships,
		viewer_id
	)


func get_known_character_ids_snapshot(
	viewer_id: String = "",
	include_player: bool = false
) -> PackedStringArray:
	return RelationshipStore.get_known_character_ids_snapshot(
		relationships,
		viewer_id,
		include_player
	)


func has_relationship_by_id(owner_id: String, other_id: String) -> bool:
	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	if clean_owner_id.is_empty() or clean_other_id.is_empty():
		return false

	return relationships.has(clean_owner_id) and relationships[clean_owner_id].has(clean_other_id)


func get_relationship_id(actor: Node) -> String:
	return Identity.get_actor_id(actor, true)


## Cold registration boundary for exact live aliases left ambiguous during
## save import. Ordinary relationship access is deliberately migration-free.
func register_actor_identity(actor: Node) -> String:
	var actor_id := Identity.get_actor_id(actor, true)
	if not actor_id.is_empty():
		_migrate_actor_aliases(actor, actor_id)
	return actor_id


func clear_relationships() -> void:
	relationships.clear()
	_migrated_actor_aliases.clear()
	_migrated_relationship_aliases.clear()
	relationship_graph_replaced.emit()


func get_save_data() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"relationships": RelationshipStore.get_persistence_safe_graph_snapshot(
			relationships,
			_get_opinion_policy()
		),
	}


func apply_save_data(data: Dictionary) -> void:
	relationships.clear()
	_migrated_actor_aliases.clear()
	_migrated_relationship_aliases.clear()

	var saved_relationships = data.get("relationships", data)
	if not (saved_relationships is Dictionary):
		relationship_graph_replaced.emit()
		return

	for owner_id_key in saved_relationships.keys():
		var saved_for_owner = saved_relationships[owner_id_key]
		if not (saved_for_owner is Dictionary):
			continue

		var stored_owner_id := String(owner_id_key).strip_edges()
		if stored_owner_id.is_empty():
			continue

		for other_id_key in saved_for_owner.keys():
			var saved_relationship = saved_for_owner[other_id_key]
			if not (saved_relationship is Dictionary):
				continue

			var stored_other_id := String(other_id_key).strip_edges()
			if stored_other_id.is_empty():
				continue

			var relationship: Dictionary = saved_relationship.duplicate(true)
			var owner_id := _canonicalize_loaded_actor_id(
				stored_owner_id,
				relationship,
				true
			)
			var other_id := _canonicalize_loaded_actor_id(
				stored_other_id,
				relationship,
				false
			)
			if owner_id.is_empty() or other_id.is_empty():
				continue
			relationship["owner_id"] = owner_id
			relationship["other_id"] = other_id
			_normalize_opinion_metrics_in_place(relationship)
			relationship["met"] = bool(relationship.get("met", false))
			relationship["meet_count"] = int(relationship.get("meet_count", 0))
			relationship["owner_name"] = String(relationship.get("owner_name", ""))
			relationship["other_name"] = String(relationship.get("other_name", ""))
			relationship["owner_path"] = String(relationship.get("owner_path", ""))
			relationship["other_path"] = String(relationship.get("other_path", ""))
			relationship["last_reason"] = String(relationship.get("last_reason", ""))
			relationship["last_context"] = _get_storable_context(relationship.get("last_context", {}))
			_store_migrated_relationship(
				owner_id,
				other_id,
				relationship,
				stored_owner_id == owner_id and stored_other_id == other_id
			)
	relationship_graph_replaced.emit()


func _canonicalize_loaded_actor_id(
	stored_id: String,
	relationship: Dictionary,
	is_owner: bool
) -> String:
	var role := "owner" if is_owner else "other"
	var embedded_id := String(relationship.get("%s_id" % role, "")).strip_edges()
	if Identity.is_player_id(embedded_id):
		return String(Identity.PLAYER_ACTOR_ID)
	return Identity.canonicalize_saved_actor_id(
		stored_id,
		String(relationship.get("%s_name" % role, "")),
		String(relationship.get("%s_path" % role, ""))
	)


func _migrate_actor_aliases(actor: Node, canonical_id: String) -> void:
	if (
		actor == null
		or relationships.is_empty()
		or not Identity.is_stable_id(canonical_id)
	):
		return
	var aliases := Identity.get_actor_aliases(actor)
	var sorted_aliases := aliases.duplicate()
	sorted_aliases.sort()
	var migration_signature := "|".join(PackedStringArray(sorted_aliases))
	if (
		_migrated_actor_aliases.has(canonical_id)
		and String(_migrated_actor_aliases[canonical_id]) == migration_signature
	):
		return
	if aliases.is_empty():
		_cache_migrated_actor_signature(canonical_id, migration_signature)
		return

	for alias in aliases:
		migrate_relationship_alias(alias, canonical_id)
	_cache_migrated_actor_signature(canonical_id, migration_signature)


## Moves one exact legacy actor key to an explicit canonical key on both axes.
## No name/path guessing occurs here: callers must provide both IDs, and the
## destination must satisfy the shared persistence-safe identity contract.
func migrate_relationship_alias(
	legacy_id: String,
	canonical_id: String
) -> Dictionary:
	var clean_legacy_id := legacy_id.strip_edges()
	var clean_canonical_id := canonical_id.strip_edges()
	if clean_legacy_id.is_empty() or clean_canonical_id.is_empty():
		return {
			"accepted": false,
			"reason": "missing_identity",
			"migrated_rows": 0,
		}
	if not Identity.is_stable_id(clean_canonical_id):
		return {
			"accepted": false,
			"reason": "unstable_canonical_identity",
			"migrated_rows": 0,
		}
	if clean_legacy_id == clean_canonical_id:
		return {
			"accepted": true,
			"reason": "already_canonical",
			"migrated_rows": 0,
		}
	var migration_key := "%s\n%s" % [
		clean_legacy_id,
		clean_canonical_id,
	]
	if _migrated_relationship_aliases.has(migration_key):
		return {
			"accepted": true,
			"reason": "already_migrated",
			"migrated_rows": 0,
		}
	var migrated_owner_rows := 0
	var migrated_target_rows := 0
	if relationships.has(clean_legacy_id):
		var legacy_rows = relationships[clean_legacy_id]
		if legacy_rows is Dictionary:
			for other_id_key in legacy_rows.keys():
				var other_id := String(other_id_key).strip_edges()
				if other_id == clean_legacy_id:
					other_id = clean_canonical_id
				var relationship = legacy_rows[other_id_key]
				if relationship is Dictionary:
					_store_migrated_relationship(
						clean_canonical_id,
						other_id,
						relationship
					)
					migrated_owner_rows += 1
		relationships.erase(clean_legacy_id)

	for owner_id_key in relationships.keys():
		var owner_id := String(owner_id_key).strip_edges()
		var owner_rows = relationships[owner_id_key]
		if not (owner_rows is Dictionary) or not owner_rows.has(clean_legacy_id):
			continue
		var relationship = owner_rows[clean_legacy_id]
		if relationship is Dictionary:
			_store_migrated_relationship(
				owner_id,
				clean_canonical_id,
				relationship
			)
			migrated_target_rows += 1
		owner_rows.erase(clean_legacy_id)

	_cache_migrated_relationship_alias(migration_key)
	_migrated_actor_aliases.erase(clean_legacy_id)
	return {
		"accepted": true,
		"reason": "migrated",
		"migrated_rows": migrated_owner_rows + migrated_target_rows,
		"migrated_owner_rows": migrated_owner_rows,
		"migrated_target_rows": migrated_target_rows,
	}


func _cache_migrated_actor_signature(actor_id: String, signature: String) -> void:
	_migrated_actor_aliases[actor_id] = signature
	while _migrated_actor_aliases.size() > MAX_MIGRATED_ACTOR_CACHE_ENTRIES:
		_migrated_actor_aliases.erase(_migrated_actor_aliases.keys()[0])


func _cache_migrated_relationship_alias(migration_key: String) -> void:
	_migrated_relationship_aliases[migration_key] = true
	while _migrated_relationship_aliases.size() > MAX_MIGRATED_ALIAS_CACHE_ENTRIES:
		_migrated_relationship_aliases.erase(
			_migrated_relationship_aliases.keys()[0]
		)


func _store_migrated_relationship(
	owner_id: String,
	other_id: String,
	relationship: Dictionary,
	prefer_candidate_on_tie: bool = false
) -> void:
	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	if clean_owner_id.is_empty() or clean_other_id.is_empty():
		return
	if not relationships.has(clean_owner_id):
		relationships[clean_owner_id] = {}
	var rows: Dictionary = relationships[clean_owner_id]
	var candidate := relationship.duplicate(true)
	candidate["owner_id"] = clean_owner_id
	candidate["other_id"] = clean_other_id
	_normalize_opinion_metrics_in_place(candidate)
	if rows.has(clean_other_id):
		var existing = rows[clean_other_id]
		if existing is Dictionary:
			_normalize_opinion_metrics_in_place(existing)
		if (
			existing is Dictionary
			and (
				_relationship_recency(existing)
					> _relationship_recency(candidate)
				or (
					_relationship_recency(existing)
						== _relationship_recency(candidate)
					and not prefer_candidate_on_tie
				)
			)
		):
			existing["owner_id"] = clean_owner_id
			existing["other_id"] = clean_other_id
			return
	rows[clean_other_id] = candidate


func _relationship_recency(relationship: Dictionary) -> int:
	return maxi(
		int(relationship.get("updated_at_msec", 0)),
		maxi(
			int(relationship.get("last_seen_msec", 0)),
			int(relationship.get("created_at_msec", 0))
		)
	)


func _get_normalized_relationships_snapshot() -> Dictionary:
	return RelationshipStore.get_normalized_graph_snapshot(
		relationships,
		_get_opinion_policy()
	)


func _normalize_opinion_metrics_in_place(relationship: Dictionary) -> void:
	RelationshipStore.normalize_row_in_place(
		relationship,
		_get_opinion_policy()
	)


func _get_opinion_fallback(metric_id: StringName, fallback) -> float:
	if fallback != null:
		return float(fallback)
	return _get_opinion_default(metric_id)


func _get_opinion_default(metric_id: StringName) -> float:
	return RelationshipStore.get_metric_default(
		_get_opinion_policy(),
		metric_id
	)


func _get_opinion_minimum(metric_id: StringName) -> float:
	return RelationshipStore.get_metric_minimum(
		_get_opinion_policy(),
		metric_id
	)


func _get_opinion_maximum(metric_id: StringName) -> float:
	return RelationshipStore.get_metric_maximum(
		_get_opinion_policy(),
		metric_id
	)


func _get_opinion_policy() -> Dictionary:
	return {
		"defaults": {
			&"favor": default_favor,
			&"trust": default_trust,
			&"love": default_love,
			&"anger": min_anger,
			&"fear": min_fear,
			&"suspicion": default_suspicion,
		},
		"minimums": {
			&"favor": min_favor,
			&"trust": min_trust,
			&"love": min_love,
			&"anger": min_anger,
			&"fear": min_fear,
			&"suspicion": min_suspicion,
		},
		"maximums": {
			&"favor": max_favor,
			&"trust": max_trust,
			&"love": max_love,
			&"anger": max_anger,
			&"fear": max_fear,
			&"suspicion": max_suspicion,
		},
	}


func _emit_legacy_metric_signal(
	metric_id: StringName,
	relationship_owner: Node,
	other: Node,
	value: float,
	delta: float,
	relationship: Dictionary
) -> void:
	match metric_id:
		&"favor":
			favor_changed.emit(
				relationship_owner, other, value, delta, relationship
			)
		&"anger":
			anger_changed.emit(
				relationship_owner, other, value, delta, relationship
			)
		&"fear":
			fear_changed.emit(
				relationship_owner, other, value, delta, relationship
			)


func _get_or_create_relationship(
	owner_id: String,
	other_id: String,
	relationship_owner: Node,
	other: Node,
	starting_favor: float
) -> Dictionary:
	return _get_or_create_relationship_by_id(
		owner_id,
		other_id,
		relationship_owner,
		other,
		starting_favor,
		{}
	)


func _get_or_create_relationship_by_id(
	owner_id: String,
	other_id: String,
	relationship_owner: Node,
	other: Node,
	starting_favor: float,
	context: Dictionary = {}
) -> Dictionary:
	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	if clean_owner_id.is_empty() or clean_other_id.is_empty():
		return {}

	if not relationships.has(clean_owner_id):
		relationships[clean_owner_id] = {}

	if relationships[clean_owner_id].has(clean_other_id):
		_normalize_opinion_metrics_in_place(
			relationships[clean_owner_id][clean_other_id]
		)
		_update_relationship_identity_fields(
			relationships[clean_owner_id][clean_other_id],
			relationship_owner,
			other,
			context
		)
		return relationships[clean_owner_id][clean_other_id]

	var now := _now_msec()
	relationships[clean_owner_id][clean_other_id] = {
		"owner_id": clean_owner_id,
		"other_id": clean_other_id,
		"owner_name": _get_relationship_owner_name(relationship_owner, context),
		"other_name": _get_relationship_other_name(other, context),
		"owner_path": _get_relationship_owner_path(relationship_owner, context),
		"other_path": _get_relationship_other_path(other, context),
		"favor": clampf(starting_favor, min_favor, max_favor),
		"trust": _get_opinion_default(&"trust"),
		"love": _get_opinion_default(&"love"),
		"lust": _get_opinion_default(&"lust"),
		"shame": _get_opinion_default(&"shame"),
		"anger": min_anger,
		"fear": min_fear,
		"suspicion": _get_opinion_default(&"suspicion"),
		"met": false,
		"meet_count": 0,
		"created_at_msec": now,
		"updated_at_msec": now,
		"last_seen_msec": 0,
		"last_reason": "",
		"last_context": {},
	}

	return relationships[clean_owner_id][clean_other_id]


func _now_msec() -> int:
	# Relationship metadata is persisted, so process-uptime ticks cannot be
	# compared across runs. Epoch milliseconds preserve recency after a load.
	return int(Time.get_unix_time_from_system() * 1000.0)


func _update_relationship_identity_fields(
	relationship: Dictionary,
	relationship_owner: Node,
	other: Node,
	context: Dictionary
) -> void:
	var owner_name := _get_relationship_owner_name(relationship_owner, context)
	if not owner_name.is_empty():
		relationship["owner_name"] = owner_name

	var other_name := _get_relationship_other_name(other, context)
	if not other_name.is_empty():
		relationship["other_name"] = other_name

	var owner_path := _get_relationship_owner_path(relationship_owner, context)
	if not owner_path.is_empty():
		relationship["owner_path"] = owner_path

	var other_path := _get_relationship_other_path(other, context)
	if not other_path.is_empty():
		relationship["other_path"] = other_path


func _get_relationship_owner_name(relationship_owner: Node, context: Dictionary) -> String:
	var context_name := String(context.get("owner_name", ""))
	if not context_name.is_empty():
		return context_name
	if relationship_owner != null:
		return relationship_owner.name

	return ""


func _get_relationship_other_name(other: Node, context: Dictionary) -> String:
	var context_name := String(context.get("other_name", ""))
	if not context_name.is_empty():
		return context_name
	if other != null and is_instance_valid(other):
		return other.name

	return ""


func _get_relationship_owner_path(relationship_owner: Node, context: Dictionary) -> String:
	var context_path := String(context.get("owner_path", ""))
	if not context_path.is_empty():
		return context_path
	if relationship_owner != null and relationship_owner.is_inside_tree():
		return String(relationship_owner.get_path())

	return ""


func _get_relationship_other_path(other: Node, context: Dictionary) -> String:
	var context_path := String(context.get("other_path", ""))
	if not context_path.is_empty():
		return context_path
	if other != null and is_instance_valid(other) and other.is_inside_tree():
		return String(other.get_path())

	return ""


func _can_store_relationship(relationship_owner: Node, other: Node) -> bool:
	if relationship_owner == null or other == null:
		return false

	if relationship_owner == other:
		return false

	return is_instance_valid(relationship_owner) and is_instance_valid(other)


func _can_store_relationship_by_id(relationship_owner: Node, other_id: String) -> bool:
	if relationship_owner == null or not is_instance_valid(relationship_owner):
		return false

	var owner_id := get_relationship_id(relationship_owner).strip_edges()
	var target_id := other_id.strip_edges()
	if owner_id.is_empty() or target_id.is_empty():
		return false

	return owner_id != target_id


func _can_store_relationship_ids(owner_id: String, other_id: String) -> bool:
	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	return (
		not clean_owner_id.is_empty()
		and not clean_other_id.is_empty()
		and clean_owner_id != clean_other_id
	)


func _get_context_node(context: Dictionary, key: String) -> Node:
	var value = context.get(key, null)
	if value is Node and is_instance_valid(value):
		return value

	return null


func _get_storable_context(context_value) -> Dictionary:
	# Relationship context can be saved; live scene Objects are used only for immediate signals.
	if not (context_value is Dictionary):
		return {}

	var stored_context := {}
	for context_key in context_value.keys():
		var key_text := String(context_key)
		if key_text == "other" or key_text == "relationship_owner":
			continue

		var stored_value = _get_storable_context_value(context_value[context_key])
		if stored_value == null:
			continue

		stored_context[key_text] = stored_value

	return stored_context


func _get_storable_context_value(value):
	match typeof(value):
		TYPE_NIL:
			return null
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return String(value)
		TYPE_VECTOR2:
			return {
				"x": value.x,
				"y": value.y,
			}
		TYPE_DICTIONARY:
			return _get_storable_context(value)
		TYPE_ARRAY:
			var stored_array := []
			for item in value:
				var stored_item = _get_storable_context_value(item)
				if stored_item != null:
					stored_array.append(stored_item)
			return stored_array
		_:
			return null


func _emit_relationship_event(
	event_name: StringName,
	relationship_owner: Node,
	other: Node,
	relationship: Dictionary,
	changed_values: Dictionary,
	reason: String
) -> void:
	if not emit_event_bus_events:
		return

	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus == null or not event_bus.has_method("emit_event"):
		return

	var owner_node := relationship_owner as Node2D
	event_bus.call("emit_event", event_name, {
		"actor": relationship_owner,
		"target": other,
		"source": relationship_owner,
		"relationship": relationship,
		"changed_values": changed_values,
		"reason": reason,
		"position": owner_node.global_position if owner_node != null else Vector2.ZERO,
		"has_position": owner_node != null,
		"tags": [&"relationship", &"npc"],
	}, relationship_event_scope)
