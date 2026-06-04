class_name NpcStateMachine extends Node

signal state_changed(state_name: StringName, previous_state_name: StringName)
signal state_request_failed(state_name: StringName, reason: String)
signal target_changed(target: Node2D)
signal values_changed(values: Dictionary, changed_values: Dictionary, actor: Node2D)

@export_group("Setup")
@export var npc_path: NodePath
@export var initial_state_name: StringName = &"Idle"
@export var active: bool = true
@export var auto_move_and_slide: bool = true

@export_group("Movement")
@export var gravity: float = 1200.0
@export var walk_speed: float = 45.0
@export var run_speed: float = 90.0
@export var stop_distance: float = 12.0

@export_group("Default Durations")
@export var default_reaction_time: float = 0.6
@export var default_work_time: float = 3.0
@export var default_talk_time: float = 1.5
@export var default_flee_time: float = 2.0
@export var default_sleep_time: float = 0.0

@export_group("Optional Nodes")
@export var animation_player_path: NodePath
@export var sprite_path: NodePath
@export var debug_label_path: NodePath

@export_group("Values")
@export var clamp_percent_values: bool = true
@export var value_reactions_enabled: bool = true
@export var values: Dictionary = {
	"favor": 50.0,
	"love": 0.0,
	"trust": 50.0,
	"fear": 0.0,
	"anger": 0.0,
	"hunger": 25.0,
	"energy": 100.0,
	"sleepiness": 0.0,
	"work_need": 0.0,
	"talk_interest": 0.0,
	"curiosity": 0.0,
	"hp": 100.0,
	"disabled": 0.0
}

@export var value_state_rules: Dictionary = {
	"dead_hp": {
		"value": "hp",
		"state": "DisabledDead",
		"at_most": 0.0,
		"priority": 100
	},
	"disabled": {
		"value": "disabled",
		"state": "DisabledDead",
		"truthy": true,
		"priority": 100
	},
	"high_fear": {
		"value": "fear",
		"state": "Flee",
		"at_least": 70.0,
		"priority": 90
	},
	"sleepy": {
		"value": "sleepiness",
		"state": "Sleep",
		"at_least": 80.0,
		"priority": 70
	},
	"hungry": {
		"value": "hunger",
		"state": "Work",
		"at_least": 75.0,
		"priority": 50
	},
	"needs_work": {
		"value": "work_need",
		"state": "Work",
		"at_least": 60.0,
		"priority": 50
	},
	"wants_talk": {
		"value": "talk_interest",
		"state": "Talk",
		"at_least": 60.0,
		"priority": 45
	},
	"curious": {
		"value": "curiosity",
		"state": "ReactToPlayer",
		"at_least": 50.0,
		"priority": 40
	},
	"favor_dropped": {
		"value": "favor",
		"state": "ReactToPlayer",
		"delta_at_most": -1.0,
		"priority": 35
	}
}

@export_group("Player Sight")
@export var react_to_player_on_seen: bool = true
@export var player_seen_state_name: StringName = &"ReactToPlayer"

var npc: CharacterBody2D
var states: Array[NpcState] = []
var state_history: Array[NpcState] = []
var target: Node2D
var move_target: Node2D
var work_target: Node2D
var talk_target: Node2D
var state_after_move: StringName = &"Idle"
var last_actor: Node2D
var last_changed_values: Dictionary = {}

var current_state: NpcState:
	get:
		if state_history.is_empty():
			return null
		return state_history.front()

var previous_state: NpcState:
	get:
		if state_history.size() < 2:
			return null
		return state_history[1]

var _state_lookup: Dictionary = {}
var _animation_player: AnimationPlayer
var _sprite_2d: Sprite2D
var _debug_label: Label


func _ready() -> void:
	if npc == null:
		_resolve_npc()

	_cache_optional_nodes()
	initialize_states()

	if active and current_state == null:
		request_state(initial_state_name, null, "initial")


func _physics_process(delta: float) -> void:
	if not active or npc == null or current_state == null:
		return

	apply_gravity(delta)

	var state_at_start := current_state
	var requested_state := state_at_start.physics_process(delta)

	if requested_state != null and state_at_start == current_state:
		change_state(requested_state, "state_tick")

	if auto_move_and_slide:
		npc.move_and_slide()


func bind_npc(bound_npc: CharacterBody2D) -> void:
	npc = bound_npc
	_cache_optional_nodes()

	for state in states:
		state.npc = npc
		state.machine = self


func initialize_states() -> void:
	states = []
	_state_lookup = {}

	for child in get_children():
		var state := child as NpcState
		if state == null:
			continue

		states.append(state)
		_state_lookup[String(state.name)] = state
		state.npc = npc
		state.machine = self

	for state in states:
		state.init()

	if states.is_empty():
		set_physics_process(false)


func get_state(state_name: StringName) -> NpcState:
	return _state_lookup.get(String(state_name), null) as NpcState


func change_state(
	new_state: NpcState,
	reason: String = "",
	request_priority: int = 0
) -> bool:
	if new_state == null:
		return false

	if current_state == new_state:
		return false

	if current_state != null and not current_state.can_exit_to(new_state, request_priority):
		state_request_failed.emit(StringName(new_state.name), reason)
		return false

	var previous_name := &""
	if current_state != null:
		previous_name = StringName(current_state.name)
		current_state.exit()

	state_history.push_front(new_state)
	if state_history.size() > 3:
		state_history.resize(3)
	new_state.next_state = null
	new_state.enter()

	_update_debug_label()
	state_changed.emit(StringName(new_state.name), previous_name)
	return true


func request_state(
	state_name: StringName,
	actor: Node2D = null,
	reason: String = "manual",
	request_priority: int = 0
) -> bool:
	if state_name == &"":
		return false

	if actor != null:
		last_actor = actor
		set_target(actor)

	var requested_state := get_state(state_name)
	if requested_state == null:
		state_request_failed.emit(state_name, "Missing state: %s" % String(state_name))
		return false

	return change_state(requested_state, reason, request_priority)


func notify_target_seen(seen_target: Node2D) -> void:
	if not active or seen_target == null or not is_instance_valid(seen_target):
		return

	set_target(seen_target)
	last_actor = seen_target

	if current_state != null:
		var requested_state := current_state.target_seen(seen_target)
		if requested_state != null and change_state(requested_state, "target_seen"):
			return

	if evaluate_value_reactions(seen_target, {}):
		return

	if react_to_player_on_seen and seen_target.is_in_group("player"):
		request_state(player_seen_state_name, seen_target, "player_seen", 10)


func notify_target_lost(lost_target: Node2D) -> void:
	if not active or lost_target == null:
		return

	if current_state != null:
		var requested_state := current_state.target_lost(lost_target)
		if requested_state != null:
			change_state(requested_state, "target_lost")

	if lost_target == target:
		target = null
		target_changed.emit(null)


func set_target(new_target: Node2D) -> void:
	if new_target != null and not is_instance_valid(new_target):
		new_target = null

	target = new_target
	target_changed.emit(target)


func get_active_target() -> Node2D:
	if target != null and is_instance_valid(target):
		return target

	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player != null and is_instance_valid(player):
		return player

	return null


func assign_move_target(new_target: Node2D, arrive_state_name: StringName = &"Idle") -> bool:
	if new_target == null or not is_instance_valid(new_target):
		return false

	move_target = new_target
	state_after_move = arrive_state_name
	set_target(new_target)
	return request_state(&"MoveToTarget", new_target, "move_target", 20)


func assign_work_target(new_target: Node2D) -> bool:
	if new_target == null or not is_instance_valid(new_target):
		return false

	work_target = new_target
	return request_state(&"Work", new_target, "work_target", 20)


func request_talk(new_target: Node2D) -> bool:
	if new_target == null or not is_instance_valid(new_target):
		return false

	talk_target = new_target
	return request_state(&"Talk", new_target, "talk", 20)


func disable(reason: String = "disabled") -> void:
	set_value(&"disabled", 1.0, null, false)
	request_state(&"DisabledDead", null, reason, 100)


func enable() -> void:
	set_value(&"disabled", 0.0, null, false)
	request_state(&"Idle", null, "enabled", 1000)


func die() -> void:
	set_value(&"hp", 0.0, null, false)
	request_state(&"DisabledDead", null, "dead", 100)


func apply_social_event(
	stat_delta: Dictionary,
	actor: Node2D = null,
	requires_actor_visibility: bool = true
) -> bool:
	if requires_actor_visibility and actor != null and npc != null:
		if npc.has_method("can_see") and not bool(npc.call("can_see", actor)):
			return false

	return apply_value_delta(stat_delta, actor)


func replace_values(
	new_values: Dictionary,
	actor: Node2D = null,
	changed_values: Dictionary = {},
	evaluate_reactions: bool = true
) -> void:
	values = new_values.duplicate(true)
	last_actor = actor
	last_changed_values = changed_values.duplicate(true)
	values_changed.emit(values.duplicate(true), last_changed_values.duplicate(true), actor)

	_notify_current_state_values_changed(actor)

	if evaluate_reactions and value_reactions_enabled:
		evaluate_value_reactions(actor, last_changed_values)


func apply_value_delta(
	value_delta: Dictionary,
	actor: Node2D = null,
	evaluate_reactions: bool = true
) -> bool:
	var changed_values: Dictionary = {}

	for value_key in value_delta.keys():
		var key := String(value_key)
		var previous_value := _variant_to_float(values.get(key, 0.0))
		var next_value := previous_value + _variant_to_float(value_delta[value_key])

		if clamp_percent_values:
			next_value = clampf(next_value, 0.0, 100.0)

		values[key] = next_value

		var actual_delta := next_value - previous_value
		if not is_equal_approx(actual_delta, 0.0):
			changed_values[key] = actual_delta

	if changed_values.is_empty():
		return false

	last_actor = actor
	last_changed_values = changed_values.duplicate(true)
	values_changed.emit(values.duplicate(true), changed_values.duplicate(true), actor)
	_notify_current_state_values_changed(actor)

	if evaluate_reactions and value_reactions_enabled:
		evaluate_value_reactions(actor, changed_values)

	return true


func set_value(
	value_name: StringName,
	value: float,
	actor: Node2D = null,
	evaluate_reactions: bool = true
) -> void:
	var key := String(value_name)
	var previous_value := _variant_to_float(values.get(key, 0.0))
	var next_value := value

	if clamp_percent_values:
		next_value = clampf(next_value, 0.0, 100.0)

	values[key] = next_value

	var changed_values: Dictionary = {}
	var actual_delta := next_value - previous_value
	if not is_equal_approx(actual_delta, 0.0):
		changed_values[key] = actual_delta

	last_actor = actor
	last_changed_values = changed_values.duplicate(true)
	values_changed.emit(values.duplicate(true), changed_values.duplicate(true), actor)
	_notify_current_state_values_changed(actor)

	if evaluate_reactions and value_reactions_enabled:
		evaluate_value_reactions(actor, changed_values)


func get_value(value_name: StringName, default_value: float = 0.0) -> float:
	return _variant_to_float(values.get(String(value_name), default_value))


func get_last_delta(value_name: StringName, default_value: float = 0.0) -> float:
	return _variant_to_float(last_changed_values.get(String(value_name), default_value))


func evaluate_value_reactions(
	actor: Node2D = null,
	changed_values: Dictionary = {}
) -> bool:
	var matching_rule := _find_best_matching_rule(changed_values)
	if matching_rule.is_empty():
		return false

	var state_name := StringName(String(matching_rule.get("state", "")))
	var priority := int(matching_rule.get("priority", 0))
	var request_actor := actor

	if request_actor == null:
		request_actor = get_active_target()

	return request_state(
		state_name,
		request_actor,
		String(matching_rule.get("reason", "value_rule")),
		priority
	)


func play_animation(state_animation_name: StringName) -> void:
	if npc != null:
		if npc.has_method("_play_animation"):
			npc.call("_play_animation", state_animation_name)
			return

		if npc.has_method("play_animation"):
			npc.call("play_animation", state_animation_name)
			return

	if _animation_player == null:
		return

	if _animation_player.current_animation == state_animation_name:
		return

	if _animation_player.has_animation(state_animation_name):
		_animation_player.play(state_animation_name)


func face_x_direction(x_direction: float) -> void:
	if npc == null or x_direction == 0.0:
		return

	if npc.has_method("_face_x_direction"):
		npc.call("_face_x_direction", x_direction)
		return

	if npc.has_method("face_x_direction"):
		npc.call("face_x_direction", x_direction)
		return

	if npc.has_method("update_direction"):
		npc.call("update_direction", float(signf(x_direction)))
		return

	var direction := int(signf(x_direction))
	_set_npc_property_if_exists("direction", direction)

	if _sprite_2d != null:
		_sprite_2d.flip_h = direction < 0

	if npc.has_method("_update_facing"):
		npc.call("_update_facing")


func apply_gravity(delta: float) -> void:
	if npc == null:
		return

	if npc.has_method("apply_gravity"):
		npc.call("apply_gravity", delta)
		return

	if npc.has_method("_apply_gravity"):
		npc.call("_apply_gravity", delta)
		return

	var npc_gravity := gravity
	var custom_gravity = npc.get("gravity")
	if typeof(custom_gravity) == TYPE_FLOAT or typeof(custom_gravity) == TYPE_INT:
		npc_gravity = float(custom_gravity)

	if not npc.is_on_floor():
		npc.velocity.y += npc_gravity * delta
	elif npc.velocity.y > 0.0:
		npc.velocity.y = 0.0


func consume_state_after_move(default_state_name: StringName = &"Idle") -> StringName:
	var consumed_state := state_after_move

	if consumed_state == &"":
		consumed_state = default_state_name

	if consumed_state == &"":
		consumed_state = &"Idle"

	state_after_move = &"Idle"
	return consumed_state


func _resolve_npc() -> void:
	if String(npc_path) != "":
		npc = get_node_or_null(npc_path) as CharacterBody2D

	if npc == null:
		npc = get_parent() as CharacterBody2D

	if npc == null and owner != null:
		npc = owner as CharacterBody2D


func _cache_optional_nodes() -> void:
	if npc == null:
		return

	_animation_player = _get_optional_npc_node(animation_player_path, "AnimationPlayer") as AnimationPlayer
	_sprite_2d = _get_optional_npc_node(sprite_path, "Sprite2D") as Sprite2D
	_debug_label = _get_optional_npc_node(debug_label_path, "Label") as Label


func _get_optional_npc_node(configured_path: NodePath, fallback_name: String) -> Node:
	if npc == null:
		return null

	if String(configured_path) != "":
		return npc.get_node_or_null(configured_path)

	var fallback_node := npc.get_node_or_null(fallback_name)
	if fallback_node != null:
		return fallback_node

	return npc.get_node_or_null("%%%s" % fallback_name)


func _notify_current_state_values_changed(actor: Node2D) -> void:
	if current_state == null:
		return

	var requested_state := current_state.values_changed(
		values,
		last_changed_values,
		actor
	)

	if requested_state != null:
		change_state(requested_state, "state_values_changed")


func _find_best_matching_rule(changed_values: Dictionary) -> Dictionary:
	var best_rule: Dictionary = {}
	var best_priority := -999999

	for rule_name in value_state_rules.keys():
		var rule = value_state_rules[rule_name]
		if not (rule is Dictionary):
			continue

		var rule_dictionary: Dictionary = rule
		var value_key := String(rule_dictionary.get("value", rule_name))
		var value = values.get(value_key, rule_dictionary.get("default", 0.0))
		var value_changed := changed_values.has(value_key)
		var value_delta = changed_values.get(value_key, 0.0)

		if not _rule_matches(rule_dictionary, value, value_delta, value_changed):
			continue

		var priority := int(rule_dictionary.get("priority", 0))
		if priority <= best_priority:
			continue

		best_priority = priority
		best_rule = rule_dictionary.duplicate(true)
		best_rule["reason"] = String(rule_name)

	return best_rule


func _rule_matches(
	rule: Dictionary,
	value,
	value_delta,
	value_changed: bool
) -> bool:
	var has_condition := false

	if bool(rule.get("only_when_changed", false)) and not value_changed:
		return false

	if rule.has("truthy"):
		has_condition = true
		if _variant_is_truthy(value) != bool(rule["truthy"]):
			return false

	if rule.has("at_least"):
		has_condition = true
		if _variant_to_float(value) < _variant_to_float(rule["at_least"]):
			return false

	if rule.has("at_most"):
		has_condition = true
		if _variant_to_float(value) > _variant_to_float(rule["at_most"]):
			return false

	if rule.has("equals"):
		has_condition = true
		if value != rule["equals"]:
			return false

	if rule.has("not_equals"):
		has_condition = true
		if value == rule["not_equals"]:
			return false

	if rule.has("delta_at_least"):
		has_condition = true
		if not value_changed:
			return false
		if _variant_to_float(value_delta) < _variant_to_float(rule["delta_at_least"]):
			return false

	if rule.has("delta_at_most"):
		has_condition = true
		if not value_changed:
			return false
		if _variant_to_float(value_delta) > _variant_to_float(rule["delta_at_most"]):
			return false

	return has_condition


func _variant_to_float(value) -> float:
	match typeof(value):
		TYPE_BOOL:
			return 1.0 if bool(value) else 0.0
		TYPE_INT, TYPE_FLOAT:
			return float(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return float(String(value))
		_:
			return 0.0


func _variant_is_truthy(value) -> bool:
	match typeof(value):
		TYPE_BOOL:
			return bool(value)
		TYPE_INT, TYPE_FLOAT:
			return not is_equal_approx(float(value), 0.0)
		TYPE_STRING, TYPE_STRING_NAME:
			return not String(value).is_empty()
		_:
			return value != null


func _set_npc_property_if_exists(property_name: String, value) -> void:
	if npc == null:
		return

	for property in npc.get_property_list():
		if String(property.get("name", "")) == property_name:
			npc.set(property_name, value)
			return


func _update_debug_label() -> void:
	if _debug_label == null or current_state == null:
		return

	_debug_label.text = current_state.name
