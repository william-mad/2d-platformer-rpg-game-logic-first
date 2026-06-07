extends Node

signal relationship_met(relationship_owner: Node, other: Node, relationship: Dictionary)
signal relationship_seen(relationship_owner: Node, other: Node, relationship: Dictionary)
signal relationship_changed(relationship_owner: Node, other: Node, changed_values: Dictionary, relationship: Dictionary)
signal favor_changed(relationship_owner: Node, other: Node, favor: float, delta: float, relationship: Dictionary)

@export var default_favor: float = 50.0
@export var min_favor: float = 0.0
@export var max_favor: float = 100.0
@export var emit_event_bus_events: bool = true
@export var relationship_event_scope: StringName = &"scene"

var relationships: Dictionary = {}


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

	relationship["met"] = true
	relationship["meet_count"] = int(relationship.get("meet_count", 0)) + 1
	relationship["last_seen_msec"] = Time.get_ticks_msec()
	relationship["last_context"] = context.duplicate(true)

	var relationship_copy := relationship.duplicate(true)
	relationship_seen.emit(relationship_owner, other, relationship_copy)

	if created:
		relationship_met.emit(relationship_owner, other, relationship_copy)
		_emit_relationship_event(&"relationship_met", relationship_owner, other, relationship_copy, {}, "meet")

	if not is_equal_approx(favor_delta, 0.0):
		change_favor(relationship_owner, other, favor_delta, String(context.get("reason", "meet")))

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
	var current_favor := get_favor(relationship_owner, other, default_favor)
	return set_favor(relationship_owner, other, current_favor + delta, reason, context)


func set_favor(
	relationship_owner: Node,
	other: Node,
	value: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	if not _can_store_relationship(relationship_owner, other):
		return default_favor

	var owner_id := get_relationship_id(relationship_owner)
	var other_id := get_relationship_id(other)
	var created := not has_relationship_by_id(owner_id, other_id)
	var relationship := _get_or_create_relationship(owner_id, other_id, relationship_owner, other, default_favor)
	var previous_favor := float(relationship.get("favor", default_favor))
	var next_favor := clampf(value, min_favor, max_favor)

	if created:
		relationship["met"] = true
		relationship["last_reason"] = reason
		relationship["last_context"] = context.duplicate(true)
		var created_copy := relationship.duplicate(true)
		relationship_met.emit(relationship_owner, other, created_copy)
		_emit_relationship_event(&"relationship_met", relationship_owner, other, created_copy, {}, reason)

	if is_equal_approx(previous_favor, next_favor):
		return next_favor

	relationship["favor"] = next_favor
	relationship["updated_at_msec"] = Time.get_ticks_msec()
	relationship["last_reason"] = reason
	relationship["last_context"] = context.duplicate(true)

	var delta := next_favor - previous_favor
	var changed_values := {"favor": delta}
	var relationship_copy := relationship.duplicate(true)
	relationship_changed.emit(relationship_owner, other, changed_values, relationship_copy)
	favor_changed.emit(relationship_owner, other, next_favor, delta, relationship_copy)
	_emit_relationship_event(&"relationship_favor_changed", relationship_owner, other, relationship_copy, changed_values, reason)

	return next_favor


func get_favor(relationship_owner: Node, other: Node, fallback: float = -1.0) -> float:
	var relationship := get_relationship(relationship_owner, other)
	if relationship.is_empty():
		return default_favor if fallback < 0.0 else fallback

	return float(relationship.get("favor", default_favor))


func has_met(relationship_owner: Node, other: Node) -> bool:
	var relationship := get_relationship(relationship_owner, other)
	return bool(relationship.get("met", false))


func get_relationship(relationship_owner: Node, other: Node) -> Dictionary:
	if relationship_owner == null or other == null:
		return {}

	return get_relationship_by_id(get_relationship_id(relationship_owner), get_relationship_id(other))


func get_relationship_by_id(owner_id: String, other_id: String) -> Dictionary:
	if not has_relationship_by_id(owner_id, other_id):
		return {}

	return relationships[owner_id][other_id].duplicate(true)


func get_relationships_for(relationship_owner: Node) -> Dictionary:
	if relationship_owner == null:
		return {}

	var owner_id := get_relationship_id(relationship_owner)
	if not relationships.has(owner_id):
		return {}

	return relationships[owner_id].duplicate(true)


func has_relationship_by_id(owner_id: String, other_id: String) -> bool:
	return relationships.has(owner_id) and relationships[owner_id].has(other_id)


func get_relationship_id(actor: Node) -> String:
	if actor == null:
		return ""

	if actor.has_method("get_relationship_id"):
		var method_id := String(actor.call("get_relationship_id"))
		if not method_id.is_empty():
			return method_id

	if actor.has_meta("relationship_id"):
		var meta_id := String(actor.get_meta("relationship_id"))
		if not meta_id.is_empty():
			return meta_id

	if actor.is_inside_tree():
		return String(actor.get_path())

	return "instance:%s" % actor.get_instance_id()


func clear_relationships() -> void:
	relationships.clear()


func get_save_data() -> Dictionary:
	return {
		"relationships": relationships.duplicate(true),
	}


func apply_save_data(data: Dictionary) -> void:
	relationships.clear()

	var saved_relationships = data.get("relationships", data)
	if not (saved_relationships is Dictionary):
		return

	for owner_id_key in saved_relationships.keys():
		var saved_for_owner = saved_relationships[owner_id_key]
		if not (saved_for_owner is Dictionary):
			continue

		var owner_id := String(owner_id_key).strip_edges()
		if owner_id.is_empty():
			continue

		relationships[owner_id] = {}
		for other_id_key in saved_for_owner.keys():
			var saved_relationship = saved_for_owner[other_id_key]
			if not (saved_relationship is Dictionary):
				continue

			var other_id := String(other_id_key).strip_edges()
			if other_id.is_empty():
				continue

			var relationship: Dictionary = saved_relationship.duplicate(true)
			relationship["owner_id"] = String(relationship.get("owner_id", owner_id))
			relationship["other_id"] = String(relationship.get("other_id", other_id))
			relationship["favor"] = clampf(float(relationship.get("favor", default_favor)), min_favor, max_favor)
			relationship["met"] = bool(relationship.get("met", false))
			relationship["meet_count"] = int(relationship.get("meet_count", 0))
			relationships[owner_id][other_id] = relationship


func _get_or_create_relationship(
	owner_id: String,
	other_id: String,
	relationship_owner: Node,
	other: Node,
	starting_favor: float
) -> Dictionary:
	if not relationships.has(owner_id):
		relationships[owner_id] = {}

	if relationships[owner_id].has(other_id):
		return relationships[owner_id][other_id]

	var now := Time.get_ticks_msec()
	relationships[owner_id][other_id] = {
		"owner_id": owner_id,
		"other_id": other_id,
		"owner_name": relationship_owner.name,
		"other_name": other.name,
		"owner_path": String(relationship_owner.get_path()) if relationship_owner.is_inside_tree() else "",
		"other_path": String(other.get_path()) if other.is_inside_tree() else "",
		"favor": clampf(starting_favor, min_favor, max_favor),
		"met": false,
		"meet_count": 0,
		"created_at_msec": now,
		"updated_at_msec": now,
		"last_seen_msec": 0,
		"last_reason": "",
		"last_context": {},
	}

	return relationships[owner_id][other_id]


func _can_store_relationship(relationship_owner: Node, other: Node) -> bool:
	if relationship_owner == null or other == null:
		return false

	if relationship_owner == other:
		return false

	return is_instance_valid(relationship_owner) and is_instance_valid(other)


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
