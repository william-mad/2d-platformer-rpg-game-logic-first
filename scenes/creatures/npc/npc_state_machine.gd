class_name NpcStateMachine extends Node

signal state_changed(state_name: StringName, previous_state_name: StringName)
signal state_request_failed(state_name: StringName, reason: String)
signal target_changed(target: Node2D)
signal values_changed(values: Dictionary, changed_values: Dictionary, actor: Node2D)

const VALUE_ALIASES := {
	"sleepiness": "sleep_need",
	"work_need": "boredom",
	"talk_interest": "talk_need",
}

const STATE_ALIASES := {
	"ReactToPlayer": "ReactToEvent",
	"NoticeActor": "ReactToEvent",
}

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
# Work uses these as "time to clear a full work-needed spot."
@export var default_work_time: float = 3.0
@export_range(0.0, 24.0, 0.05, "suffix:h") var default_work_game_hours: float = 4.5
@export var default_eat_time: float = 2.0
@export_range(0.0, 1440.0, 1.0, "suffix:min") var default_eat_game_minutes: float = 60.0
@export var default_rest_time: float = 2.0
@export var default_talk_time: float = 1.5
@export_range(0.0, 1440.0, 1.0, "suffix:min") var default_talk_game_minutes: float = 10.0
@export var default_look_for_talk_time: float = 4.0
@export var default_flee_time: float = 4.0
@export var default_sleep_time: float = 4.0
@export_range(0.0, 24.0, 0.05, "suffix:h") var default_sleep_game_hours: float = 8.0
@export var default_collapse_time: float = 3.0

@export_group("Passive Needs")
@export var passive_needs_enabled: bool = true
@export_range(0.0, 100.0, 0.1, "suffix:/h") var sleep_need_growth_per_game_hour: float = 5.1
@export_range(0.0, 100.0, 0.1, "suffix:/h") var hunger_growth_per_game_hour: float = 7.0
@export_range(0.0, 100.0, 0.1, "suffix:/h") var boredom_growth_per_game_hour: float = 8.0
@export_range(0.0, 100.0, 0.1) var talk_need_growth_per_interval: float = 8.0
@export_range(0.1, 1440.0, 0.1, "suffix:min") var talk_need_growth_interval_game_minutes: float = 20.0
@export var passive_needs_tick_seconds: float = 10.0
@export var stagger_passive_need_ticks: bool = true
@export var sleep_need_paused_states: Array[StringName] = [&"Sleep", &"Collapse"]
@export var hunger_paused_states: Array[StringName] = [&"Eat"]
@export var boredom_paused_states: Array[StringName] = [&"Work"]
@export var talk_need_paused_states: Array[StringName] = [&"Talk"]

@export_group("Fear Decay")
@export var fear_decay_enabled: bool = true
@export var fear_decay_value_name: StringName = &"fear"
@export_range(0.0, 100.0, 0.1) var fear_panic_floor: float = 90.0
@export_range(0.0, 1440.0, 1.0, "suffix:min") var fear_panic_cooldown_game_minutes: float = 10.0
@export_range(0.0, 100.0, 0.1, "suffix:/h") var fear_slow_decay_per_game_hour: float = 5.0
@export_range(0.0, 10.0, 0.1) var fear_decay_stop_below_flee_threshold_by: float = 0.1

@export_group("Anger Decay")
@export var anger_decay_enabled: bool = true
@export var anger_decay_value_name: StringName = &"anger"
@export_range(0.1, 24.0, 0.1, "suffix:h") var anger_full_decay_game_hours: float = 4.0

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
	"sleep_need": 0.0,
	"boredom": 0.0,
	"bored": 0.0,
	"talk_need": 0.0,
	"lonely": 0.0,
	"sadness": 0.0,
	"suspicion": 0.0,
	"curiosity": 0.0,
	"hp": 100.0,
	"disabled": 0.0
}

# Rules are checked only when values change, when a target is seen, or when code asks for a state.
# Add new entries here to make a value drive a state without changing the state scripts.
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
		"delta_at_least": 0.001,
		"only_when_changed": true,
		"priority": 90
	},
	"anger_fight": {
		"value": "anger",
		"state": "Fight",
		"at_least": 100.0,
		"priority": 94
	},
	"sleep_collapse": {
		"value": "sleep_need",
		"state": "Collapse",
		"at_least": 100.0,
		"priority": 95
	},
	"sleep_rest_before_noon": {
		"value": "sleep_need",
		"state": "Rest",
		"at_least": 51.0,
		"at_most": 70.0,
		"before_hour": 12.0,
		"requires_idle": true,
		"priority": 30
	},
	"hungry": {
		"value": "hunger",
		"state": "Eat",
		"at_least": 75.0,
		"requires_idle": true,
		"priority": 50
	},
	"boredom_do_anything": {
		"value": "boredom",
		"state": "DoAnything",
		"at_least": 91.0,
		"at_most": 99.0,
		"requires_idle": true,
		"priority": 55
	},
	"talk_to_seen_target": {
		"value": "talk_need",
		"state": "Talk",
		"at_least": 61.0,
		"requires_target": true,
		"target_groups": [&"npc", &"player"],
		"min_relationship_favor": 20.0,
		"priority": 45
	},
	"talk_search_for_people": {
		"value": "talk_need",
		"state": "LookForTalkTarget",
		"at_least": 90.0,
		"requires_idle": true,
		"priority": 40
	},
	"curious": {
		"value": "curiosity",
		"state": "ReactToEvent",
		"at_least": 50.0,
		"priority": 40
	},
	"favor_dropped": {
		"value": "favor",
		"state": "ReactToEvent",
		"delta_at_most": -1.0,
		"priority": 35
	}
}

# Extra value changes that happen when a need crosses a hard threshold.
# Example: reaching talk_need 100 can also add lonely +1.
@export var value_threshold_effects: Dictionary = {
	"talk_need_lonely_cap": {
		"value": "talk_need",
		"at_least": 100.0,
		"delta": {
			"talk_need": -40.0,
			"lonely": 1.0
		}
	},
	"boredom_bored_cap": {
		"value": "boredom",
		"at_least": 100.0,
		"delta": {
			"bored": 1.0
		}
	}
}

@export_group("Player Sight")
# Legacy export name kept for old scenes. Leave false for needs-driven NPCs.
@export var react_to_player_on_seen: bool = false
@export var player_seen_state_name: StringName = &"ReactToEvent"
@export var flee_from_seen_player_when_afraid: bool = true
@export var seen_player_flee_state_name: StringName = &"Flee"
@export var seen_player_flee_priority: int = 90

var npc: CharacterBody2D
var states: Array[NpcState] = []
var state_history: Array[NpcState] = []
# These targets are shared between states so any NPC scene can request movement, work, or talk.
var target: Node2D
var move_target: Node2D
var work_target: Node2D
var eat_target: Node2D
var rest_target: Node2D
var sleep_target: Node2D
var talk_target: Node2D
var state_after_move: StringName = &"Idle"
var last_actor: Node2D
var last_changed_values: Dictionary = {}
var idle_value_reaction_queued: bool = false
var passive_need_elapsed_seconds: float = 0.0
var next_talk_need_payout_already_applied: bool = false

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
	values = _normalize_value_dictionary(values)
	_stagger_passive_need_tick()

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
	if _process_npc_damage_hop(delta):
		_update_passive_needs(delta)
		if auto_move_and_slide:
			npc.move_and_slide()
		return

	# Only the active state runs per-frame behavior; value-rule decisions stay event-driven.
	var state_at_start := current_state
	var requested_state := state_at_start.physics_process(delta)

	if requested_state != null and state_at_start == current_state:
		change_state(requested_state, "state_tick")

	_update_passive_needs(delta)

	if auto_move_and_slide:
		npc.move_and_slide()


func _process_npc_damage_hop(delta: float) -> bool:
	if npc == null or not npc.has_method("process_damage_hop"):
		return false

	return bool(npc.call("process_damage_hop", delta))


func bind_npc(bound_npc: CharacterBody2D) -> void:
	npc = bound_npc
	_cache_optional_nodes()

	for state in states:
		state.npc = npc
		state.machine = self


func initialize_states() -> void:
	states = []
	_state_lookup = {}

	# This mirrors the player setup: each child node is one reusable state.
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
	var key := _canonical_state_key(state_name)
	return _state_lookup.get(key, null) as NpcState


func change_state(
	new_state: NpcState,
	reason: String = "",
	request_priority: int = 0
) -> bool:
	# Switches the active child state and gives the old state a clean exit.
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

	# Some need rules only run while idle. Re-check them after any state returns to Idle.
	if value_reactions_enabled and String(new_state.name) == "Idle":
		_queue_idle_value_reaction_check()

	return true


func request_state(
	state_name: StringName,
	actor: Node2D = null,
	reason: String = "manual",
	request_priority: int = 0
) -> bool:
	# External code can call this to force a state without waiting for value rules.
	if state_name == &"":
		return false
	if String(state_name) == "Talk":
		var requested_partner := actor if actor != null else talk_target
		if requested_partner == npc:
			talk_target = null
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
	if seen_target == npc:
		return

	set_target(seen_target)
	last_actor = seen_target

	if current_state != null:
		var requested_state := current_state.target_seen(seen_target)
		if requested_state != null and change_state(requested_state, "target_seen"):
			return

	if _maybe_flee_from_seen_player(seen_target):
		return
	if _maybe_flee_from_seen_npc(seen_target):
		return

	if evaluate_value_reactions(seen_target, {}):
		return

	if react_to_player_on_seen and seen_target.is_in_group("player"):
		request_state(player_seen_state_name, seen_target, "player_seen", 10)


func _maybe_flee_from_seen_player(seen_target: Node2D) -> bool:
	# Seeing the player can start a flee burst if fear was already high.
	if not flee_from_seen_player_when_afraid:
		return false

	if seen_target == null or not seen_target.is_in_group("player"):
		return false

	if seen_player_flee_state_name == &"":
		return false

	if get_value(fear_decay_value_name) < _get_flee_fear_threshold():
		return false

	return request_state(
		seen_player_flee_state_name,
		seen_target,
		"fear_seen_player",
		seen_player_flee_priority
	)


func _maybe_flee_from_seen_npc(seen_target: Node2D) -> bool:
	if seen_target == null or not seen_target.is_in_group("npc"):
		return false
	if npc == null or not npc.has_method("should_flee_from_npc"):
		return false
	if not bool(npc.call("should_flee_from_npc", seen_target)):
		return false

	return request_state(
		seen_player_flee_state_name,
		seen_target,
		"fear_seen_npc",
		seen_player_flee_priority
	)


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
	if new_target == npc:
		new_target = null

	target = new_target
	target_changed.emit(target)


func get_active_target() -> Node2D:
	if target != null and is_instance_valid(target) and target != npc:
		return target

	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player != null and is_instance_valid(player):
		return player

	return null


func is_in_state(state_name: StringName) -> bool:
	return current_state != null and String(current_state.name) == String(state_name)


func get_flee_fear_threshold() -> float:
	return _get_flee_fear_threshold()


func assign_move_target(new_target: Node2D, arrive_state_name: StringName = &"Idle") -> bool:
	# Sends the NPC to a target, then lets MoveToTarget return into the requested state.
	if new_target == null or not is_instance_valid(new_target):
		return false

	move_target = new_target
	state_after_move = arrive_state_name
	set_target(new_target)
	return request_state(&"MoveToTarget", new_target, "move_target", 20)


func assign_work_target(new_target: Node2D) -> bool:
	# Stores a work spot so Work can walk there before clearing its work_needed.
	if new_target == null or not is_instance_valid(new_target):
		return false

	work_target = new_target
	return request_state(&"Work", new_target, "work_target", 20)


func assign_eat_target(new_target: Node2D) -> bool:
	# Stores an eat spot so Eat can walk there before lowering hunger.
	if new_target == null or not is_instance_valid(new_target):
		return false

	eat_target = new_target
	return request_state(&"Eat", new_target, "eat_target", 20)


func assign_rest_target(new_target: Node2D) -> bool:
	# Stores a rest spot for medium sleep need before a full bed/sleep response.
	if new_target == null or not is_instance_valid(new_target):
		return false

	rest_target = new_target
	return request_state(&"Rest", new_target, "rest_target", 20)


func assign_sleep_target(new_target: Node2D) -> bool:
	# Stores a sleep spot so Sleep can walk there before starting the long timer.
	if new_target == null or not is_instance_valid(new_target):
		return false

	sleep_target = new_target
	return request_state(&"Sleep", new_target, "sleep_target", 20)


func request_talk(new_target: Node2D) -> bool:
	# Starts Talk with a known partner, such as the player or another NPC.
	if new_target == null or not is_instance_valid(new_target) or new_target == npc:
		if talk_target == npc:
			talk_target = null
		return false

	talk_target = new_target
	return request_state(&"Talk", new_target, "talk", 20)


func can_talk_to_target(
	candidate: Node2D,
	minimum_npc_favor: float = 20.0,
	require_npc_favor: bool = true
) -> bool:
	# Shared gate for autonomous talk choices; direct scripted/player talk can still call request_talk.
	if candidate == null or not is_instance_valid(candidate):
		return false

	if candidate == npc:
		return false

	if not candidate.is_in_group("npc"):
		return true

	if not require_npc_favor:
		return true

	return _get_relationship_favor_for_target(candidate) > minimum_npc_favor


func mark_next_talk_need_payout_applied() -> void:
	# Player-pressed talk can apply stats instantly, then use Talk only for timing/hooks.
	next_talk_need_payout_already_applied = true


func consume_next_talk_need_payout_already_applied() -> bool:
	var was_already_applied := next_talk_need_payout_already_applied
	next_talk_need_payout_already_applied = false
	return was_already_applied


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
	values = _normalize_value_dictionary(new_values)
	last_actor = actor
	last_changed_values = _normalize_value_delta(changed_values)
	values_changed.emit(values.duplicate(true), last_changed_values.duplicate(true), actor)

	_notify_current_state_values_changed(actor)

	if evaluate_reactions and value_reactions_enabled:
		evaluate_value_reactions(actor, last_changed_values)


func apply_value_delta(
	value_delta: Dictionary,
	actor: Node2D = null,
	evaluate_reactions: bool = true
) -> bool:
	# Use deltas for events: {"fear": 20.0} raises fear and may trigger a rule.
	values = _normalize_value_dictionary(values)
	var normalized_delta := _normalize_value_delta(value_delta)
	var changed_values: Dictionary = {}

	for value_key in normalized_delta.keys():
		var key := String(value_key)
		var previous_value := _variant_to_float(values.get(key, 0.0))
		var next_value := previous_value + _variant_to_float(normalized_delta[value_key])

		if clamp_percent_values:
			next_value = clampf(next_value, 0.0, 100.0)

		values[key] = next_value

		var actual_delta := next_value - previous_value
		if not is_equal_approx(actual_delta, 0.0):
			changed_values[key] = actual_delta

	_apply_threshold_effects(changed_values)

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
	values = _normalize_value_dictionary(values)
	var key := _canonical_value_key(value_name)
	var previous_value := _variant_to_float(values.get(key, 0.0))
	var next_value := value

	if clamp_percent_values:
		next_value = clampf(next_value, 0.0, 100.0)

	values[key] = next_value

	var changed_values: Dictionary = {}
	var actual_delta := next_value - previous_value
	if not is_equal_approx(actual_delta, 0.0):
		changed_values[key] = actual_delta

	_apply_threshold_effects(changed_values)
	if changed_values.is_empty():
		return

	last_actor = actor
	last_changed_values = changed_values.duplicate(true)
	values_changed.emit(values.duplicate(true), changed_values.duplicate(true), actor)
	_notify_current_state_values_changed(actor)

	if evaluate_reactions and value_reactions_enabled:
		evaluate_value_reactions(actor, changed_values)


func get_value(value_name: StringName, default_value: float = 0.0) -> float:
	values = _normalize_value_dictionary(values)
	return _variant_to_float(values.get(_canonical_value_key(value_name), default_value))


func get_last_delta(value_name: StringName, default_value: float = 0.0) -> float:
	return _variant_to_float(last_changed_values.get(_canonical_value_key(value_name), default_value))


func evaluate_value_reactions(
	actor = null,
	changed_values: Dictionary = {}
) -> bool:
	# Picks the highest-priority matching rule, so Dead/Flee can outrank Talk/Work.
	var safe_actor: Node2D = null
	if actor != null and is_instance_valid(actor):
		safe_actor = actor as Node2D
	elif actor != null:
		last_actor = null

	var matching_rule := _find_best_matching_rule(changed_values, safe_actor)
	if matching_rule.is_empty():
		return false

	var state_name := StringName(String(matching_rule.get("state", "")))
	var priority := int(matching_rule.get("priority", 0))
	var request_actor := _get_rule_request_actor(safe_actor, matching_rule)
	if bool(matching_rule.get("requires_target", false)) and request_actor == null:
		return false

	return request_state(
		state_name,
		request_actor,
		String(matching_rule.get("reason", "value_rule")),
		priority
	)


func play_animation(state_animation_name: StringName) -> void:
	# Animation hook:
	# 1. If the NPC script has _play_animation/play_animation, let it decide.
	# 2. Otherwise, play an AnimationPlayer child if it has the requested name.
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


func get_real_seconds_for_game_hours(game_hours: float, fallback_seconds: float) -> float:
	# Converts in-game hours into real seconds using the WorldTime day length.
	if game_hours <= 0.0:
		return fallback_seconds

	var real_seconds_per_day := _get_real_seconds_per_day()
	if real_seconds_per_day <= 0.0:
		return fallback_seconds

	return real_seconds_per_day * (game_hours / 24.0)


func get_real_seconds_for_game_minutes(game_minutes: float, fallback_seconds: float) -> float:
	# Convenience wrapper for short actions like talk/eat that are tuned in minutes.
	return get_real_seconds_for_game_hours(game_minutes / 60.0, fallback_seconds)


func get_game_hours_for_real_seconds(real_seconds: float, fallback_game_hours: float = 0.0) -> float:
	# Converts real elapsed seconds back into game hours for passive need growth.
	if real_seconds <= 0.0:
		return 0.0

	var real_seconds_per_day := _get_real_seconds_per_day()
	if real_seconds_per_day <= 0.0:
		return fallback_game_hours

	return (real_seconds / real_seconds_per_day) * 24.0


func _update_passive_needs(delta: float) -> void:
	# Raises background needs in game-time chunks instead of every physics frame.
	if not passive_needs_enabled:
		passive_need_elapsed_seconds = 0.0
		return

	passive_need_elapsed_seconds += delta
	var tick_seconds := maxf(passive_needs_tick_seconds, 0.0)
	if tick_seconds > 0.0 and passive_need_elapsed_seconds < tick_seconds:
		return

	var elapsed_seconds := passive_need_elapsed_seconds
	passive_need_elapsed_seconds = 0.0
	_apply_passive_need_growth(elapsed_seconds)


func _apply_passive_need_growth(real_seconds: float) -> void:
	# Passive needs rise in shared 10-second batches so time-driven changes stay cheap.
	var game_hours := get_game_hours_for_real_seconds(real_seconds)
	if game_hours <= 0.0:
		return

	var value_delta := {}
	if (
		sleep_need_growth_per_game_hour > 0.0
		and not _current_state_matches_any(sleep_need_paused_states)
	):
		value_delta["sleep_need"] = sleep_need_growth_per_game_hour * game_hours

	if (
		hunger_growth_per_game_hour > 0.0
		and not _current_state_matches_any(hunger_paused_states)
	):
		value_delta["hunger"] = hunger_growth_per_game_hour * game_hours

	if (
		boredom_growth_per_game_hour > 0.0
		and not _current_state_matches_any(boredom_paused_states)
	):
		value_delta["boredom"] = boredom_growth_per_game_hour * game_hours

	if (
		talk_need_growth_per_interval > 0.0
		and talk_need_growth_interval_game_minutes > 0.0
		and not _current_state_matches_any(talk_need_paused_states)
	):
		var game_minutes := game_hours * 60.0
		value_delta["talk_need"] = (
			talk_need_growth_per_interval
			* (game_minutes / talk_need_growth_interval_game_minutes)
		)

	var fear_delta := _get_fear_decay_delta(game_hours)
	if not is_equal_approx(fear_delta, 0.0):
		value_delta[String(fear_decay_value_name)] = fear_delta
	if fear_decay_enabled and npc != null and npc.has_method("decay_relationship_fear"):
		var flee_threshold := _get_flee_fear_threshold()
		var fear_stop_value := maxf(
			flee_threshold - fear_decay_stop_below_flee_threshold_by,
			0.0
		)
		npc.call(
			"decay_relationship_fear",
			game_hours,
			fear_panic_floor,
			fear_panic_cooldown_game_minutes / 60.0,
			fear_slow_decay_per_game_hour,
			fear_stop_value
		)

	var anger_delta := _get_anger_decay_delta(game_hours)
	if not is_equal_approx(anger_delta, 0.0):
		value_delta[String(anger_decay_value_name)] = anger_delta
	if anger_decay_enabled and npc != null and npc.has_method("decay_relationship_anger"):
		npc.call("decay_relationship_anger", game_hours, anger_full_decay_game_hours)

	if value_delta.is_empty():
		return

	apply_value_delta(value_delta, null, true)


func _get_anger_decay_delta(game_hours: float) -> float:
	# Anger cools on the same passive tick as needs: 100 -> 0 over the configured game hours.
	if not anger_decay_enabled or anger_decay_value_name == &"" or game_hours <= 0.0:
		return 0.0

	var current_anger := get_value(anger_decay_value_name)
	if current_anger <= 0.0:
		return 0.0

	var decay_per_hour := 100.0 / maxf(anger_full_decay_game_hours, 0.001)
	return -minf(current_anger, decay_per_hour * game_hours)


func _get_fear_decay_delta(game_hours: float) -> float:
	# Fear cools only on passive ticks: quickly to 90, then slowly below flee threshold.
	if not fear_decay_enabled or fear_decay_value_name == &"" or game_hours <= 0.0:
		return 0.0

	var current_fear := get_value(fear_decay_value_name)
	var flee_threshold := _get_flee_fear_threshold()
	var stop_value := maxf(flee_threshold - fear_decay_stop_below_flee_threshold_by, 0.0)
	if current_fear <= stop_value:
		return 0.0

	var next_fear := current_fear
	if current_fear > fear_panic_floor:
		var panic_hours := fear_panic_cooldown_game_minutes / 60.0
		if panic_hours <= 0.0:
			next_fear = fear_panic_floor
		else:
			var panic_decay_per_hour := (100.0 - fear_panic_floor) / panic_hours
			next_fear = maxf(current_fear - (panic_decay_per_hour * game_hours), fear_panic_floor)
	else:
		next_fear = maxf(current_fear - (fear_slow_decay_per_game_hour * game_hours), stop_value)

	return next_fear - current_fear


func _get_flee_fear_threshold() -> float:
	var fallback_threshold := 70.0
	for rule_name in value_state_rules.keys():
		var rule = value_state_rules[rule_name]
		if not (rule is Dictionary):
			continue

		var rule_dictionary: Dictionary = rule
		if String(rule_dictionary.get("state", "")) != "Flee":
			continue
		if _canonical_value_key(rule_dictionary.get("value", "")) != _canonical_value_key(fear_decay_value_name):
			continue
		if rule_dictionary.has("at_least"):
			return _variant_to_float(rule_dictionary["at_least"])

	return fallback_threshold


func _stagger_passive_need_tick() -> void:
	if not stagger_passive_need_ticks:
		return

	var tick_seconds := maxf(passive_needs_tick_seconds, 0.0)
	if tick_seconds <= 0.0:
		return

	var offset_ratio := float(int(get_instance_id()) % 1000) / 1000.0
	passive_need_elapsed_seconds = -tick_seconds * offset_ratio


func _current_state_matches_any(state_names: Array[StringName]) -> bool:
	for state_name in state_names:
		if _current_state_is(state_name):
			return true

	return false


func _get_real_seconds_per_day() -> float:
	# Reads the current global day length. A missing clock falls back to old timers.
	if not is_inside_tree() or get_tree() == null:
		return 0.0

	var world_time := get_tree().root.get_node_or_null("WorldTime")
	if world_time == null:
		return 0.0

	var value = world_time.get("real_seconds_per_day")
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return float(value)

	return 0.0


func _queue_idle_value_reaction_check() -> void:
	# Defers the idle rule check so the state stack finishes changing first.
	if idle_value_reaction_queued:
		return

	idle_value_reaction_queued = true
	call_deferred("_run_idle_value_reaction_check")


func _run_idle_value_reaction_check() -> void:
	# Runs need reactions that were waiting for the NPC to become idle again.
	idle_value_reaction_queued = false

	if not is_inside_tree() or not active or not value_reactions_enabled or current_state == null:
		return

	if String(current_state.name) != "Idle":
		return

	evaluate_value_reactions(last_actor, {})


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


func _find_best_matching_rule(changed_values: Dictionary, actor: Node2D = null) -> Dictionary:
	# Picks the highest-priority rule that can actually run right now.
	var best_rule: Dictionary = {}
	var best_priority := -999999

	for rule_name in value_state_rules.keys():
		var rule = value_state_rules[rule_name]
		if not (rule is Dictionary):
			continue

		var rule_dictionary: Dictionary = rule
		var value_key := _canonical_value_key(rule_dictionary.get("value", rule_name))
		var value = values.get(value_key, rule_dictionary.get("default", 0.0))
		var value_changed := changed_values.has(value_key)
		var value_delta = changed_values.get(value_key, 0.0)

		if not _rule_matches(rule_dictionary, value, value_delta, value_changed):
			continue

		var state_name := StringName(String(rule_dictionary.get("state", "")))
		if state_name == &"" or get_state(state_name) == null:
			continue

		if bool(rule_dictionary.get("requires_target", false)):
			if _get_rule_request_actor(actor, rule_dictionary) == null:
				continue

		var priority := int(rule_dictionary.get("priority", 0))
		if priority <= best_priority:
			continue

		best_priority = priority
		best_rule = rule_dictionary.duplicate(true)
		best_rule["reason"] = String(rule_name)

	return best_rule


func _apply_threshold_effects(changed_values: Dictionary) -> void:
	# Applies one-shot side effects, such as talk_need 100 adding lonely.
	if changed_values.is_empty():
		return

	var effect_delta := _collect_threshold_effect_delta(changed_values)
	if effect_delta.is_empty():
		return

	var normalized_delta := _normalize_value_delta(effect_delta)
	for value_key in normalized_delta.keys():
		var key := String(value_key)
		var previous_value := _variant_to_float(values.get(key, 0.0))
		var next_value := previous_value + _variant_to_float(normalized_delta[value_key])

		if clamp_percent_values:
			next_value = clampf(next_value, 0.0, 100.0)

		values[key] = next_value

		var actual_delta := next_value - previous_value
		if not is_equal_approx(actual_delta, 0.0):
			changed_values[key] = _variant_to_float(changed_values.get(key, 0.0)) + actual_delta


func _collect_threshold_effect_delta(changed_values: Dictionary) -> Dictionary:
	# Builds a combined delta from every threshold effect crossed this value change.
	var effect_delta := {}

	for effect_name in value_threshold_effects.keys():
		var effect = value_threshold_effects[effect_name]
		if not (effect is Dictionary):
			continue

		var effect_dictionary: Dictionary = effect
		var value_key := _canonical_value_key(effect_dictionary.get("value", effect_name))
		if not changed_values.has(value_key):
			continue

		var current_value := _variant_to_float(values.get(value_key, 0.0))
		var changed_delta := _variant_to_float(changed_values.get(value_key, 0.0))
		var previous_value := current_value - changed_delta

		if not _threshold_effect_matches(effect_dictionary, previous_value, current_value):
			continue

		var delta = effect_dictionary.get("delta", {})
		if not (delta is Dictionary):
			continue

		var normalized_delta := _normalize_value_delta(delta)
		for delta_key in normalized_delta.keys():
			var key := String(delta_key)
			effect_delta[key] = (
				_variant_to_float(effect_delta.get(key, 0.0))
				+ _variant_to_float(normalized_delta[delta_key])
			)

	return effect_delta


func _threshold_effect_matches(effect: Dictionary, previous_value: float, current_value: float) -> bool:
	# Returns true only when a value crosses into the configured cap/threshold.
	var has_condition := false

	if effect.has("at_least"):
		has_condition = true
		var threshold := _variant_to_float(effect["at_least"])
		if previous_value >= threshold or current_value < threshold:
			return false

	if effect.has("at_most"):
		has_condition = true
		var threshold := _variant_to_float(effect["at_most"])
		if previous_value <= threshold or current_value > threshold:
			return false

	return has_condition


func _get_rule_request_actor(actor: Node2D, rule: Dictionary) -> Node2D:
	# Chooses which seen/active target should be passed into the requested state.
	if _rule_allows_target(rule, actor):
		return actor

	if _rule_allows_target(rule, target):
		return target

	if bool(rule.get("requires_target", false)):
		return null

	var fallback_target := get_active_target()
	if _rule_allows_target(rule, fallback_target):
		return fallback_target

	return null


func _rule_allows_target(rule: Dictionary, candidate: Node2D) -> bool:
	# Checks whether a candidate target belongs to any group allowed by the rule.
	if candidate == null or not is_instance_valid(candidate):
		return false
	if candidate == npc:
		return false

	var allowed_groups = rule.get("target_groups", [])
	if not (allowed_groups is Array) or allowed_groups.is_empty():
		return _rule_allows_target_relationship(rule, candidate)

	for group_name in allowed_groups:
		if candidate.is_in_group(String(group_name)):
			return _rule_allows_target_relationship(rule, candidate)

	return false


func _rule_allows_target_relationship(rule: Dictionary, candidate: Node2D) -> bool:
	# Optional rule gate for NPC targets: avoid social talk with characters this NPC dislikes.
	if not candidate.is_in_group("npc"):
		return true
	if not rule.has("min_relationship_favor"):
		return true

	return _get_relationship_favor_for_target(candidate) > _variant_to_float(rule["min_relationship_favor"])


func _get_relationship_favor_for_target(candidate: Node) -> float:
	if npc != null and npc.has_method("get_relationship_favor_for"):
		return float(npc.call("get_relationship_favor_for", candidate, 50.0))

	var relationships := get_node_or_null("/root/Relationships")
	if relationships != null and relationships.has_method("get_favor"):
		return float(relationships.call("get_favor", npc, candidate, 50.0))

	return 50.0


func _rule_matches(
	rule: Dictionary,
	value,
	value_delta,
	value_changed: bool
) -> bool:
	# Checks numeric, idle, delta, and time conditions for one value-state rule.
	var has_condition := false

	if bool(rule.get("requires_idle", false)) and not _current_state_is(&"Idle"):
		return false

	if not _rule_time_matches(rule):
		return false

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


func _current_state_is(state_name: StringName) -> bool:
	# Keeps idle-gated rules readable.
	return current_state != null and String(current_state.name) == String(state_name)


func _rule_time_matches(rule: Dictionary) -> bool:
	# Supports rules like "rest only before noon" using the WorldTime autoload.
	if not _rule_has_time_condition(rule):
		return true

	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_method("get_snapshot"):
		return false

	var snapshot: Dictionary = world_time.call("get_snapshot")
	var hour := _variant_to_float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))

	if rule.has("time_windows") and not _time_windows_match(rule["time_windows"], hour):
		return false

	if rule.has("before_hour") and hour >= _variant_to_float(rule["before_hour"]):
		return false

	if rule.has("after_hour") and hour < _variant_to_float(rule["after_hour"]):
		return false

	if rule.has("periods"):
		var periods = rule["periods"]
		if periods is Array:
			var current_period := String(snapshot.get("period", ""))
			var period_matches := false
			for period in periods:
				if String(period) == current_period:
					period_matches = true
					break
			if not period_matches:
				return false

	return true


func _rule_has_time_condition(rule: Dictionary) -> bool:
	# Fast check before asking WorldTime for a snapshot.
	return (
		rule.has("before_hour")
		or rule.has("after_hour")
		or rule.has("periods")
		or rule.has("time_windows")
	)


func _time_windows_match(windows, hour: float) -> bool:
	if not (windows is Array):
		return false

	for window in windows:
		if not (window is Dictionary):
			continue

		if _time_window_matches(window, hour):
			return true

	return false


func _time_window_matches(window: Dictionary, hour: float) -> bool:
	var start_hour := _variant_to_float(window.get("start_hour", window.get("start", 0.0)))
	var end_hour := _variant_to_float(window.get("end_hour", window.get("end", 24.0)))
	start_hour = fposmod(start_hour, 24.0)
	end_hour = fposmod(end_hour, 24.0)
	var normalized_hour := fposmod(hour, 24.0)

	if is_equal_approx(start_hour, end_hour):
		return true

	if start_hour < end_hour:
		return normalized_hour >= start_hour and normalized_hour < end_hour

	return normalized_hour >= start_hour or normalized_hour < end_hour


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


func _normalize_value_dictionary(source_values: Dictionary) -> Dictionary:
	var normalized := source_values.duplicate(true)
	for old_key in VALUE_ALIASES.keys():
		if not normalized.has(old_key):
			continue

		var new_key := String(VALUE_ALIASES[old_key])
		if not normalized.has(new_key):
			normalized[new_key] = normalized[old_key]
		normalized.erase(old_key)

	return normalized


func _normalize_value_delta(value_delta: Dictionary) -> Dictionary:
	var normalized := {}
	for value_key in value_delta.keys():
		var key := _canonical_value_key(value_key)
		normalized[key] = _variant_to_float(normalized.get(key, 0.0)) + _variant_to_float(value_delta[value_key])

	return normalized


func _canonical_value_key(value_key) -> String:
	var key := String(value_key)
	if VALUE_ALIASES.has(key):
		return String(VALUE_ALIASES[key])

	return key


func _canonical_state_key(state_name) -> String:
	var key := String(state_name)
	if STATE_ALIASES.has(key):
		return String(STATE_ALIASES[key])

	return key


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
