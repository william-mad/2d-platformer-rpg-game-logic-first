class_name SocialNpc extends CharacterBody2D

signal target_seen(target: Node2D)
signal target_lost(target: Node2D)
signal social_stats_changed(stats: Dictionary)

@export_group("Movement")
@export var gravity: float = 1200.0
@export var walk_speed: float = 45.0
@export var patrol_range: float = 240.0
@export var starts_moving_right: bool = true

@export_group("Social Stats")
@export var favor_min: float = 0.0
@export var favor_max: float = 100.0
@export var favor_bar_visible_distance: float = 180.0
@export var social_stats: Dictionary = {
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

@export_group("Relationships")
@export var use_relationships: bool = true
@export var relationship_id: StringName = &""
@export var default_relationship_favor: float = 50.0
@export var meet_relationship_favor_delta: float = 0.0
@export var relationship_target_groups: Array[StringName] = [&"npc"]

@export_group("Location")
@export var use_npc_location_tracking: bool = true
# Travelling NPCs need a stable id and source scene path so the tracker can move one copy between scenes.
@export var location_id: StringName = &""
@export_file("*.tscn") var npc_scene_path: String = ""

@export_group("Health")
@export var max_hp: float = 100.0
@export var damage_fear_multiplier: float = 4.0
@export var damage_favor_penalty: float = 2.0

@export_group("Event Bus")
@export var listen_to_event_bus: bool = true
# Reaction rule scopes: "seen", "local", "scene", or "global".
@export var event_bus_reactions: Dictionary = {
	"damage_dealt": {
		"scope": "local",
		"radius": 320.0,
		"ignore_self_as_actor": true,
		"ignore_self_as_target": true,
		"stat_delta": {
			"fear": 15.0,
			"curiosity": 10.0,
			"trust": -4.0
		},
		"state_request": "ReactToPlayer",
		"priority": 45
	}
}

@export_group("Reactions")
@export var reaction_pause_time: float = 0.6
@export var negative_reaction_speed_multiplier: float = 1.5

@export_group("State Machine")
@export var use_state_machine_when_available: bool = true

@onready var body_visual: Polygon2D = %BodyVisual
@onready var sight_pivot: Node2D = %SightPivot
@onready var sight_area: Area2D = %SightArea
@onready var favor_bar: ProgressBar = %FavorBar
@onready var hp_bar: CreatureHpBar = get_node_or_null("HPBar") as CreatureHpBar
# Optional child component. If present, social values can drive the reusable NPC states.
@onready var npc_state_machine: NpcStateMachine = get_node_or_null("NpcStateMachine") as NpcStateMachine

var home_position: Vector2
var direction: int = 1
var reaction_timer: float = 0.0
var reaction_velocity_x: float = 0.0
var seen_targets: Array[Node2D] = []
var syncing_state_machine_values: bool = false


func _ready() -> void:
	add_to_group("social_npc")

	if not _setup_location_tracking():
		return

	home_position = global_position
	direction = 1 if starts_moving_right else -1

	_ensure_social_stats()
	setup_hp_bar()
	_update_facing()
	_update_favor_bar()
	_update_favor_bar_visibility()
	_update_visual_mood()
	_setup_relationship_identity()

	sight_area.body_entered.connect(_on_sight_area_body_entered)
	sight_area.body_exited.connect(_on_sight_area_body_exited)
	_setup_state_machine()
	_setup_event_bus()


func _exit_tree() -> void:
	_unregister_location_tracking()
	_disconnect_event_bus()


func _physics_process(delta: float) -> void:
	if _state_machine_active():
		# When the reusable machine is active, it owns movement and move_and_slide().
		_update_favor_bar_visibility()
		return

	_apply_gravity(delta)

	if reaction_timer > 0.0:
		reaction_timer -= delta
		velocity.x = reaction_velocity_x
	else:
		_process_patrol()

	_update_favor_bar_visibility()
	move_and_slide()


func can_see(target: Node2D) -> bool:
	if target == null or not is_instance_valid(target):
		return false

	return sight_area.get_overlapping_bodies().has(target)


func apply_social_event(
	stat_delta: Dictionary,
	actor: Node2D = null,
	requires_actor_visibility: bool = true
) -> bool:
	if requires_actor_visibility and actor != null and not can_see(actor):
		return false

	var favor_delta := float(stat_delta.get("favor", 0.0))
	var changed_stats: Dictionary = {}

	for stat_key in stat_delta.keys():
		var key := String(stat_key)
		var current_value := float(social_stats.get(key, 0.0))
		var next_value := current_value + float(stat_delta[stat_key])
		var max_value := max_hp if key == "hp" else 100.0
		social_stats[key] = clampf(next_value, 0.0, max_value)

		var actual_delta := float(social_stats[key]) - current_value
		if not is_equal_approx(actual_delta, 0.0):
			changed_stats[key] = actual_delta

	update_hp_bar()
	_update_favor_bar()
	_update_visual_mood()

	if _state_machine_active():
		# Keep SocialNpc as the stat owner, then sync those values into the state machine.
		syncing_state_machine_values = true
		npc_state_machine.replace_values(social_stats, actor, changed_stats)
		syncing_state_machine_values = false
	else:
		_react_to_event(actor, favor_delta)

	social_stats_changed.emit(social_stats.duplicate())
	return true


func take_damage(amount: float, _damage_source_position: Vector2 = Vector2.ZERO, damage_source: Node = null) -> void:
	if amount <= 0.0 or get_hp() <= 0.0:
		return

	var previous_hp := get_hp()
	var damage_actor := damage_source as Node2D
	var damage_stats := {
		"hp": -amount,
		"fear": amount * damage_fear_multiplier,
		"favor": -amount * damage_favor_penalty,
	}

	# Damage is handled as a social value change, so hp/fear/favor rules can drive any state.
	# Add hurt animations here later:
	# if animation_player != null:
	# 	animation_player.play("hurt")
	apply_social_event(damage_stats, damage_actor, false)

	var damage_taken := previous_hp - get_hp()
	DamageEvents.emit_damage_dealt(damage_taken, damage_source, self)

	if get_hp() <= 0.0:
		die()


func heal(amount: float) -> void:
	if amount <= 0.0 or get_hp() <= 0.0:
		return

	apply_social_event({"hp": amount}, null, false)


func die() -> void:
	if float(social_stats.get("disabled", 0.0)) >= 1.0:
		return

	social_stats["disabled"] = 1.0
	update_hp_bar()
	social_stats_changed.emit(social_stats.duplicate())

	# Add disabled/death animations here later:
	# if animation_player != null:
	# 	animation_player.play("disabled")
	if npc_state_machine != null:
		syncing_state_machine_values = true
		npc_state_machine.replace_values(social_stats, null, {"disabled": 1.0}, false)
		syncing_state_machine_values = false
		npc_state_machine.disable("dead")
	else:
		velocity = Vector2.ZERO
		set_physics_process(false)


func get_favor() -> float:
	return float(social_stats.get("favor", 0.0))


func get_relationship_id() -> StringName:
	if relationship_id != &"":
		return relationship_id

	if location_id != &"":
		return location_id

	if is_inside_tree():
		return StringName(String(get_path()))

	return StringName("npc:%s" % get_instance_id())


func get_npc_location_id() -> StringName:
	if location_id != &"":
		return location_id

	if relationship_id != &"":
		return relationship_id

	if is_inside_tree():
		return StringName(String(get_path()))

	return StringName("npc:%s" % get_instance_id())


func get_npc_scene_path() -> String:
	if not npc_scene_path.is_empty():
		return npc_scene_path

	if not scene_file_path.is_empty():
		return scene_file_path

	return ""


func get_npc_location_save_data() -> Dictionary:
	return {
		"social_stats": social_stats.duplicate(true),
		"starts_moving_right": starts_moving_right,
		"patrol_range": patrol_range,
		"walk_speed": walk_speed,
		"use_state_machine_when_available": use_state_machine_when_available,
		"relationship_id": String(relationship_id),
		"location_id": String(location_id),
	}


func apply_npc_location_save_data(data: Dictionary) -> void:
	if data.has("social_stats") and data["social_stats"] is Dictionary:
		social_stats = data["social_stats"].duplicate(true)
	if data.has("starts_moving_right"):
		starts_moving_right = bool(data["starts_moving_right"])
	if data.has("patrol_range"):
		patrol_range = float(data["patrol_range"])
	if data.has("walk_speed"):
		walk_speed = float(data["walk_speed"])
	if data.has("use_state_machine_when_available"):
		use_state_machine_when_available = bool(data["use_state_machine_when_available"])
	if data.has("relationship_id"):
		relationship_id = StringName(String(data["relationship_id"]))
	if data.has("location_id"):
		location_id = StringName(String(data["location_id"]))


func set_npc_location_position(spawn_position: Vector2) -> void:
	global_position = spawn_position
	home_position = spawn_position


func get_relationship_favor_for(other: Node, fallback: float = -1.0) -> float:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("get_favor"):
		return default_relationship_favor if fallback < 0.0 else fallback

	var default_favor := default_relationship_favor if fallback < 0.0 else fallback
	return float(relationships.call("get_favor", self, other, default_favor))


func change_relationship_favor_for(other: Node, delta: float, reason: String = "manual") -> float:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("change_favor"):
		return default_relationship_favor

	return float(relationships.call("change_favor", self, other, delta, reason))


func set_relationship_favor_for(other: Node, value: float, reason: String = "manual") -> float:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("set_favor"):
		return value

	return float(relationships.call("set_favor", self, other, value, reason))


func has_met_npc(other: Node) -> bool:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("has_met"):
		return false

	return bool(relationships.call("has_met", self, other))


func get_hp() -> float:
	return clampf(float(social_stats.get("hp", max_hp)), 0.0, max_hp)


func setup_hp_bar() -> void:
	if hp_bar == null:
		return

	hp_bar.setup_hp(max_hp, get_hp())


func update_hp_bar() -> void:
	if hp_bar == null:
		return

	hp_bar.set_hp(get_hp())


func _ensure_social_stats() -> void:
	var default_stats := {
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

	for stat_key in default_stats.keys():
		if not social_stats.has(stat_key):
			social_stats[stat_key] = default_stats[stat_key]

	social_stats["hp"] = clampf(float(social_stats.get("hp", max_hp)), 0.0, max_hp)


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y += gravity * delta
	elif velocity.y > 0.0:
		velocity.y = 0.0


func _process_patrol() -> void:
	if global_position.x > home_position.x + patrol_range:
		direction = -1
	elif global_position.x < home_position.x - patrol_range:
		direction = 1

	velocity.x = direction * walk_speed
	_update_facing()


func _react_to_event(actor: Node2D, favor_delta: float) -> void:
	reaction_timer = reaction_pause_time
	reaction_velocity_x = 0.0

	if actor == null or not is_instance_valid(actor):
		return

	var actor_direction := signf(actor.global_position.x - global_position.x)
	if actor_direction == 0.0:
		return

	if favor_delta < 0.0:
		direction = int(-actor_direction)
		reaction_velocity_x = direction * walk_speed * negative_reaction_speed_multiplier
	else:
		direction = int(actor_direction)

	_update_facing()


func _update_facing() -> void:
	if direction == 0:
		direction = 1

	sight_pivot.scale.x = direction


func _update_favor_bar() -> void:
	favor_bar.min_value = favor_min
	favor_bar.max_value = favor_max
	favor_bar.value = clampf(get_favor(), favor_min, favor_max)


func _update_favor_bar_visibility() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player == null or not is_instance_valid(player):
		favor_bar.visible = false
		return

	favor_bar.visible = global_position.distance_to(player.global_position) <= favor_bar_visible_distance


func _update_visual_mood() -> void:
	var favor_ratio := inverse_lerp(favor_min, favor_max, get_favor())
	favor_ratio = clampf(favor_ratio, 0.0, 1.0)

	if favor_ratio < 0.34:
		body_visual.color = Color(0.85, 0.18, 0.14, 1.0)
	elif favor_ratio < 0.67:
		body_visual.color = Color(0.9, 0.78, 0.25, 1.0)
	else:
		body_visual.color = Color(0.25, 0.75, 0.35, 1.0)


func _on_sight_area_body_entered(body: Node2D) -> void:
	if seen_targets.has(body):
		return

	seen_targets.append(body)
	_try_meet_relationship_target(body)

	if npc_state_machine != null:
		npc_state_machine.notify_target_seen(body)
	target_seen.emit(body)


func _on_sight_area_body_exited(body: Node2D) -> void:
	seen_targets.erase(body)
	if npc_state_machine != null:
		npc_state_machine.notify_target_lost(body)
	target_lost.emit(body)


func _setup_state_machine() -> void:
	if npc_state_machine == null:
		return

	# The same SocialNpc scene still works without this child; this path opts into state behavior.
	npc_state_machine.bind_npc(self)

	var callback := Callable(self, "_on_npc_state_machine_values_changed")
	if not npc_state_machine.values_changed.is_connected(callback):
		npc_state_machine.values_changed.connect(callback)

	syncing_state_machine_values = true
	npc_state_machine.replace_values(social_stats)
	syncing_state_machine_values = false


func _setup_relationship_identity() -> void:
	if relationship_id == &"":
		return

	set_meta("relationship_id", String(relationship_id))


func _setup_location_tracking() -> bool:
	if not use_npc_location_tracking:
		return true

	var tracker := _get_npc_location_tracker()
	if tracker == null or not tracker.has_method("register_npc"):
		return true

	if not bool(tracker.call("register_npc", self)):
		queue_free()
		return false

	set_meta("npc_location_id", String(get_npc_location_id()))
	return true


func _unregister_location_tracking() -> void:
	if not use_npc_location_tracking:
		return

	var tracker := _get_npc_location_tracker()
	if tracker == null or not tracker.has_method("unregister_npc"):
		return

	tracker.call("unregister_npc", self)


func _try_meet_relationship_target(target: Node2D) -> void:
	if not use_relationships or target == null or target == self:
		return

	if not _is_relationship_target(target):
		return

	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("meet"):
		return

	# Relationship favor is per other NPC, separate from the broad social_stats favor value.
	relationships.call("meet", self, target, default_relationship_favor, meet_relationship_favor_delta, {
		"reason": "seen",
		"scope": "sight",
	})


func _is_relationship_target(target: Node) -> bool:
	for group_name in relationship_target_groups:
		if target.is_in_group(String(group_name)):
			return true

	return false


func _get_relationship_system() -> Node:
	return get_node_or_null("/root/Relationships")


func _get_npc_location_tracker() -> Node:
	return get_node_or_null("/root/NpcLocations")


func _setup_event_bus() -> void:
	if not listen_to_event_bus:
		return

	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus == null:
		return

	var callback := Callable(self, "_on_event_bus_event")
	if not event_bus.is_connected(&"event_emitted", callback):
		event_bus.connect(&"event_emitted", callback)


func _disconnect_event_bus() -> void:
	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus == null:
		return

	var callback := Callable(self, "_on_event_bus_event")
	if event_bus.is_connected(&"event_emitted", callback):
		event_bus.disconnect(&"event_emitted", callback)


func _on_event_bus_event(event_name: StringName, payload: Dictionary) -> void:
	var reaction_rule := _get_event_reaction_rule(event_name)
	if reaction_rule.is_empty():
		reaction_rule = _get_payload_reaction_rule(payload)

	if reaction_rule.is_empty():
		return

	if not _event_reaction_matches(reaction_rule, payload):
		return

	var actor := _get_event_actor(payload)
	var stat_delta := _get_rule_dictionary(reaction_rule, "stat_delta")

	# Event reactions are one-shot value changes, so they stay responsive without frame polling.
	if not stat_delta.is_empty():
		apply_social_event(
			stat_delta,
			actor,
			bool(reaction_rule.get("requires_actor_visibility", false))
		)

	var state_name := _get_rule_state_name(reaction_rule)
	if state_name != &"" and npc_state_machine != null:
		npc_state_machine.request_state(
			state_name,
			actor,
			"event_bus:%s" % String(event_name),
			int(reaction_rule.get("priority", 0))
		)


func _get_event_reaction_rule(event_name: StringName) -> Dictionary:
	if event_bus_reactions.has(event_name) and event_bus_reactions[event_name] is Dictionary:
		return event_bus_reactions[event_name]

	var event_key := String(event_name)
	if event_bus_reactions.has(event_key) and event_bus_reactions[event_key] is Dictionary:
		return event_bus_reactions[event_key]

	return {}


func _get_payload_reaction_rule(payload: Dictionary) -> Dictionary:
	if not bool(payload.get("npc_event", false)):
		return {}

	var reaction_rule := {
		"scope": payload.get("scope", "global"),
		"radius": float(payload.get("radius", 0.0)),
		"stat_delta": _get_rule_dictionary(payload, "stat_delta"),
		"state_request": payload.get("state_request", &""),
		"priority": int(payload.get("priority", 0)),
		"required_tags": payload.get("required_tags", []),
		"requires_actor_visibility": bool(payload.get("requires_actor_visibility", false)),
		"ignore_self_as_actor": bool(payload.get("ignore_self_as_actor", false)),
		"ignore_self_as_target": bool(payload.get("ignore_self_as_target", false)),
	}

	if _get_rule_dictionary(reaction_rule, "stat_delta").is_empty() and _get_rule_state_name(reaction_rule) == &"":
		return {}

	return reaction_rule


func _event_reaction_matches(reaction_rule: Dictionary, payload: Dictionary) -> bool:
	if not _event_scope_allowed_by_rule(reaction_rule, payload):
		return false

	if not _event_scope_reaches_this_npc(reaction_rule, payload):
		return false

	if bool(reaction_rule.get("ignore_self_as_actor", false)):
		var actor_node := _get_payload_node(payload, "actor")
		if actor_node == self:
			return false

	if bool(reaction_rule.get("ignore_self_as_target", false)):
		var target_node := _get_payload_node(payload, "target")
		if target_node == self:
			return false

	return _event_has_required_tags(payload, reaction_rule.get("required_tags", []))


func _event_scope_allowed_by_rule(reaction_rule: Dictionary, payload: Dictionary) -> bool:
	var event_scope := _get_payload_scope(payload)

	if reaction_rule.has("scope"):
		return _scope_values_match(reaction_rule["scope"], event_scope)

	if reaction_rule.has("scopes"):
		var allowed_scopes = reaction_rule["scopes"]
		if not (allowed_scopes is Array):
			return false

		for allowed_scope in allowed_scopes:
			if _scope_values_match(allowed_scope, event_scope):
				return true

		return false

	return true


func _event_scope_reaches_this_npc(reaction_rule: Dictionary, payload: Dictionary) -> bool:
	match _get_payload_scope(payload):
		&"seen":
			return _can_see_event_payload(payload)
		&"local":
			return _is_inside_event_radius(reaction_rule, payload)
		&"scene":
			return _is_inside_event_scene(payload)
		&"global":
			return true

	return false


func _can_see_event_payload(payload: Dictionary) -> bool:
	var seen_target := _get_payload_node(payload, "seen_target") as Node2D
	if _can_see_event_node(seen_target):
		return true

	var target := _get_payload_node(payload, "target") as Node2D
	if _can_see_event_node(target):
		return true

	var source := _get_payload_node(payload, "source") as Node2D
	if _can_see_event_node(source):
		return true

	var actor := _get_payload_node(payload, "actor") as Node2D
	return _can_see_event_node(actor)


func _can_see_event_node(event_node: Node2D) -> bool:
	if event_node == null or event_node == self:
		return false

	return can_see(event_node)


func _is_inside_event_radius(reaction_rule: Dictionary, payload: Dictionary) -> bool:
	var radius := float(reaction_rule.get("radius", payload.get("radius", 0.0)))
	if radius <= 0.0:
		return false

	if not bool(payload.get("has_position", false)):
		return false

	var position_value = payload.get("position", null)
	if not (position_value is Vector2):
		return false

	var event_position: Vector2 = position_value
	return global_position.distance_to(event_position) <= radius


func _is_inside_event_scene(payload: Dictionary) -> bool:
	var scene_root := _get_payload_node(payload, "scene_root")
	if scene_root == null:
		return false

	return scene_root == get_tree().current_scene or scene_root.is_ancestor_of(self)


func _get_payload_scope(payload: Dictionary) -> StringName:
	return StringName(String(payload.get("scope", "global")))


func _scope_values_match(first_scope, second_scope) -> bool:
	return String(first_scope) == String(second_scope)


func _event_has_required_tags(payload: Dictionary, required_tags) -> bool:
	if not (required_tags is Array) or required_tags.is_empty():
		return true

	var event_tags = payload.get("tags", [])
	if not (event_tags is Array):
		return false

	for required_tag in required_tags:
		if event_tags.has(required_tag):
			continue

		var required_text := String(required_tag)
		if event_tags.has(required_text) or event_tags.has(StringName(required_text)):
			continue

		return false

	return true


func _get_event_actor(payload: Dictionary) -> Node2D:
	var actor := _get_payload_node(payload, "actor") as Node2D
	if actor != null:
		return actor

	return _get_payload_node(payload, "source") as Node2D


func _get_payload_node(payload: Dictionary, key: String) -> Node:
	var node := payload.get(key, null) as Node
	if node != null and is_instance_valid(node):
		return node

	return null


func _get_rule_dictionary(reaction_rule: Dictionary, key: String) -> Dictionary:
	var value = reaction_rule.get(key, {})
	if value is Dictionary:
		return value

	return {}


func _get_rule_state_name(reaction_rule: Dictionary) -> StringName:
	var value = reaction_rule.get("state_request", &"")
	var state_name := String(value)
	if state_name.is_empty():
		return &""

	return StringName(state_name)


func _state_machine_active() -> bool:
	return use_state_machine_when_available and npc_state_machine != null and npc_state_machine.active


func _on_npc_state_machine_values_changed(
	values: Dictionary,
	_changed_values: Dictionary,
	_actor: Node2D
) -> void:
	if syncing_state_machine_values:
		return

	# States can also change values, so mirror them back into the social NPC display.
	social_stats = values.duplicate(true)
	update_hp_bar()
	_update_favor_bar()
	_update_visual_mood()
	social_stats_changed.emit(social_stats.duplicate())
