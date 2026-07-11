extends Node

signal relationship_met(relationship_owner: Node, other: Node, relationship: Dictionary)
signal relationship_seen(relationship_owner: Node, other: Node, relationship: Dictionary)
signal relationship_changed(relationship_owner: Node, other: Node, changed_values: Dictionary, relationship: Dictionary)
signal favor_changed(relationship_owner: Node, other: Node, favor: float, delta: float, relationship: Dictionary)
signal anger_changed(relationship_owner: Node, other: Node, anger: float, delta: float, relationship: Dictionary)
signal fear_changed(relationship_owner: Node, other: Node, fear: float, delta: float, relationship: Dictionary)

@export var default_favor: float = 50.0
@export var min_favor: float = 0.0
@export var max_favor: float = 100.0
@export var min_anger: float = 0.0
@export var max_anger: float = 100.0
@export var min_fear: float = 0.0
@export var max_fear: float = 100.0
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
	var stored_context := _get_storable_context(context)

	relationship["met"] = true
	relationship["meet_count"] = int(relationship.get("meet_count", 0)) + 1
	relationship["last_seen_msec"] = Time.get_ticks_msec()
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
	var current_favor := get_favor(relationship_owner, other, default_favor)
	return set_favor(relationship_owner, other, current_favor + delta, reason, context)


func change_favor_by_id(
	relationship_owner: Node,
	other_id: String,
	delta: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	var owner_id := get_relationship_id(relationship_owner)
	var current_favor := get_favor_by_id(owner_id, other_id, default_favor)
	return set_favor_by_id(relationship_owner, other_id, current_favor + delta, reason, context)


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
	var stored_context := _get_storable_context(context)
	var previous_favor := float(relationship.get("favor", default_favor))
	var next_favor := clampf(value, min_favor, max_favor)

	if created:
		relationship["met"] = true
		relationship["last_reason"] = reason
		relationship["last_context"] = stored_context
		var created_copy := relationship.duplicate(true)
		relationship_met.emit(relationship_owner, other, created_copy)
		_emit_relationship_event(&"relationship_met", relationship_owner, other, created_copy, {}, reason)

	if is_equal_approx(previous_favor, next_favor):
		return next_favor

	relationship["favor"] = next_favor
	relationship["updated_at_msec"] = Time.get_ticks_msec()
	relationship["last_reason"] = reason
	relationship["last_context"] = stored_context

	var delta := next_favor - previous_favor
	var changed_values := {"favor": delta}
	var relationship_copy := relationship.duplicate(true)
	relationship_changed.emit(relationship_owner, other, changed_values, relationship_copy)
	favor_changed.emit(relationship_owner, other, next_favor, delta, relationship_copy)
	_emit_relationship_event(&"relationship_favor_changed", relationship_owner, other, relationship_copy, changed_values, reason)

	return next_favor


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
	var target_id := other_id.strip_edges()
	var created := not has_relationship_by_id(owner_id, target_id)
	var other := _get_context_node(context, "other")
	var stored_context := _get_storable_context(context)
	var relationship := _get_or_create_relationship_by_id(
		owner_id,
		target_id,
		relationship_owner,
		other,
		default_favor,
		context
	)
	if relationship.is_empty():
		return default_favor

	var previous_favor := float(relationship.get("favor", default_favor))
	var next_favor := clampf(value, min_favor, max_favor)

	if created:
		relationship["met"] = true
		relationship["last_reason"] = reason
		relationship["last_context"] = stored_context
		var created_copy := relationship.duplicate(true)
		relationship_met.emit(relationship_owner, other, created_copy)
		_emit_relationship_event(&"relationship_met", relationship_owner, other, created_copy, {}, reason)

	if is_equal_approx(previous_favor, next_favor):
		return next_favor

	relationship["favor"] = next_favor
	relationship["updated_at_msec"] = Time.get_ticks_msec()
	relationship["last_reason"] = reason
	relationship["last_context"] = stored_context

	var delta := next_favor - previous_favor
	var changed_values := {"favor": delta}
	var relationship_copy := relationship.duplicate(true)
	relationship_changed.emit(relationship_owner, other, changed_values, relationship_copy)
	favor_changed.emit(relationship_owner, other, next_favor, delta, relationship_copy)
	_emit_relationship_event(&"relationship_favor_changed", relationship_owner, other, relationship_copy, changed_values, reason)

	return next_favor


func get_favor(relationship_owner: Node, other: Node, fallback: float = -1.0) -> float:
	if relationship_owner == null or other == null:
		return default_favor if fallback < 0.0 else fallback

	return get_favor_by_id(
		get_relationship_id(relationship_owner),
		get_relationship_id(other),
		fallback
	)


func get_favor_by_id(owner_id: String, other_id: String, fallback: float = -1.0) -> float:
	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	var missing_fallback := default_favor if fallback < 0.0 else fallback
	if clean_owner_id.is_empty() or clean_other_id.is_empty():
		return missing_fallback
	if not relationships.has(clean_owner_id):
		return missing_fallback

	var relationships_for_owner: Dictionary = relationships[clean_owner_id]
	if not relationships_for_owner.has(clean_other_id):
		return missing_fallback

	var relationship: Dictionary = relationships_for_owner[clean_other_id]
	if not relationship.has("favor"):
		return default_favor

	return float(relationship["favor"])


func change_anger(
	relationship_owner: Node,
	other: Node,
	delta: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	var current_anger := get_anger(relationship_owner, other)
	return set_anger(relationship_owner, other, current_anger + delta, reason, context)


func set_anger(
	relationship_owner: Node,
	other: Node,
	value: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	if not _can_store_relationship(relationship_owner, other):
		return min_anger

	var owner_id := get_relationship_id(relationship_owner)
	var other_id := get_relationship_id(other)
	var relationship := _get_or_create_relationship(
		owner_id,
		other_id,
		relationship_owner,
		other,
		default_favor
	)
	var previous_anger := float(relationship.get("anger", min_anger))
	var next_anger := clampf(value, min_anger, max_anger)
	if is_equal_approx(previous_anger, next_anger):
		return next_anger

	relationship["anger"] = next_anger
	relationship["met"] = true
	relationship["updated_at_msec"] = Time.get_ticks_msec()
	relationship["last_reason"] = reason
	relationship["last_context"] = _get_storable_context(context)

	var delta := next_anger - previous_anger
	var changed_values := {"anger": delta}
	var relationship_copy := relationship.duplicate(true)
	relationship_changed.emit(relationship_owner, other, changed_values, relationship_copy)
	anger_changed.emit(relationship_owner, other, next_anger, delta, relationship_copy)
	_emit_relationship_event(
		&"relationship_anger_changed",
		relationship_owner,
		other,
		relationship_copy,
		changed_values,
		reason
	)
	return next_anger


func get_anger(relationship_owner: Node, other: Node, fallback: float = 0.0) -> float:
	var relationship := get_relationship(relationship_owner, other)
	if relationship.is_empty():
		return fallback

	return float(relationship.get("anger", fallback))


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
		relationship["updated_at_msec"] = Time.get_ticks_msec()
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
	var current_fear := get_fear(relationship_owner, other)
	return set_fear(relationship_owner, other, current_fear + delta, reason, context)


func set_fear(
	relationship_owner: Node,
	other: Node,
	value: float,
	reason: String = "manual",
	context: Dictionary = {}
) -> float:
	if not _can_store_relationship(relationship_owner, other):
		return min_fear

	var owner_id := get_relationship_id(relationship_owner)
	var other_id := get_relationship_id(other)
	var relationship := _get_or_create_relationship(
		owner_id,
		other_id,
		relationship_owner,
		other,
		default_favor
	)
	var previous_fear := float(relationship.get("fear", min_fear))
	var next_fear := clampf(value, min_fear, max_fear)
	if is_equal_approx(previous_fear, next_fear):
		return next_fear

	relationship["fear"] = next_fear
	relationship["met"] = true
	relationship["updated_at_msec"] = Time.get_ticks_msec()
	relationship["last_reason"] = reason
	relationship["last_context"] = _get_storable_context(context)

	var delta := next_fear - previous_fear
	var changed_values := {"fear": delta}
	var relationship_copy := relationship.duplicate(true)
	relationship_changed.emit(relationship_owner, other, changed_values, relationship_copy)
	fear_changed.emit(relationship_owner, other, next_fear, delta, relationship_copy)
	_emit_relationship_event(
		&"relationship_fear_changed",
		relationship_owner,
		other,
		relationship_copy,
		changed_values,
		reason
	)
	return next_fear


func get_fear(relationship_owner: Node, other: Node, fallback: float = 0.0) -> float:
	var relationship := get_relationship(relationship_owner, other)
	if relationship.is_empty():
		return fallback

	return float(relationship.get("fear", fallback))


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
		relationship["updated_at_msec"] = Time.get_ticks_msec()
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

	return relationships[clean_owner_id][clean_other_id].duplicate(true)


func get_relationships_for(relationship_owner: Node) -> Dictionary:
	if relationship_owner == null:
		return {}

	return get_relationships_for_id(get_relationship_id(relationship_owner))


func get_relationships_for_id(owner_id: String) -> Dictionary:
	var clean_owner_id := owner_id.strip_edges()
	if clean_owner_id.is_empty() or not relationships.has(clean_owner_id):
		return {}

	return relationships[clean_owner_id].duplicate(true)


func has_relationship_by_id(owner_id: String, other_id: String) -> bool:
	var clean_owner_id := owner_id.strip_edges()
	var clean_other_id := other_id.strip_edges()
	if clean_owner_id.is_empty() or clean_other_id.is_empty():
		return false

	return relationships.has(clean_owner_id) and relationships[clean_owner_id].has(clean_other_id)


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
			relationship["anger"] = clampf(float(relationship.get("anger", min_anger)), min_anger, max_anger)
			relationship["fear"] = clampf(float(relationship.get("fear", min_fear)), min_fear, max_fear)
			relationship["met"] = bool(relationship.get("met", false))
			relationship["meet_count"] = int(relationship.get("meet_count", 0))
			relationship["owner_name"] = String(relationship.get("owner_name", ""))
			relationship["other_name"] = String(relationship.get("other_name", ""))
			relationship["owner_path"] = String(relationship.get("owner_path", ""))
			relationship["other_path"] = String(relationship.get("other_path", ""))
			relationship["last_reason"] = String(relationship.get("last_reason", ""))
			relationship["last_context"] = _get_storable_context(relationship.get("last_context", {}))
			relationships[owner_id][other_id] = relationship


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
		_update_relationship_identity_fields(
			relationships[clean_owner_id][clean_other_id],
			relationship_owner,
			other,
			context
		)
		return relationships[clean_owner_id][clean_other_id]

	var now := Time.get_ticks_msec()
	relationships[clean_owner_id][clean_other_id] = {
		"owner_id": clean_owner_id,
		"other_id": clean_other_id,
		"owner_name": _get_relationship_owner_name(relationship_owner, context),
		"other_name": _get_relationship_other_name(other, context),
		"owner_path": _get_relationship_owner_path(relationship_owner, context),
		"other_path": _get_relationship_other_path(other, context),
		"favor": clampf(starting_favor, min_favor, max_favor),
		"anger": min_anger,
		"fear": min_fear,
		"met": false,
		"meet_count": 0,
		"created_at_msec": now,
		"updated_at_msec": now,
		"last_seen_msec": 0,
		"last_reason": "",
		"last_context": {},
	}

	return relationships[clean_owner_id][clean_other_id]


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
