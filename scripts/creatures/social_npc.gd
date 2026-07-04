class_name SocialNpc extends CharacterBody2D

signal target_seen(target: Node2D)
signal target_lost(target: Node2D)
signal social_stats_changed(stats: Dictionary)

const STAT_KEY_ALIASES := {
	"sleepiness": "sleep_need",
	"work_need": "boredom",
	"talk_interest": "talk_need",
}

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
	"sleep_need": 0.0,
	"tired": 0.0,
	"boredom": 0.0,
	"bored": 0.0,
	"talk_need": 0.0,
	"lonely": 0.0,
	"sadness": 0.0,
	"suspicion": 0.0,
	"curiosity": 0.0,
	"hp": 100.0,
	"knockout": 0.0,
	"disabled": 0.0
}

@export_group("Identity")
@export var display_name: String = ""
@export var npc_tags: Array[StringName] = []
@export var show_name_tag: bool = true
@export var show_location_id_in_name_tag: bool = true

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
@export var damage_anger_multiplier: float = 4.0
@export_range(0.0, 100.0, 0.1, "suffix:%") var damage_fear_health_threshold_percent: float = 50.0
@export var low_health_fear_min_scale: float = 1.0
@export var low_health_fear_max_scale: float = 2.0
@export var damage_favor_penalty: float = 2.0
@export_range(0.0, 100.0, 0.1) var npc_relationship_fight_anger_threshold: float = 100.0
@export_range(0.0, 100.0, 0.1) var npc_relationship_flee_fear_threshold: float = 70.0

@export_group("Knockout")
@export var max_knockout: float = 100.0
@export var knockout_decay_per_second: float = 55.0
@export var downed_decay_per_second: float = 32.0

@export_group("Damage Hop")
@export var damage_hop_enabled: bool = true
@export_range(0.0, 600.0, 1.0, "suffix:px/s") var damage_hop_horizontal_speed: float = 140.0
@export_range(0.0, 600.0, 1.0, "suffix:px/s") var damage_hop_vertical_speed: float = 180.0
@export_range(0.0, 1.0, 0.01, "suffix:s") var damage_hop_duration: float = 0.22
@export_range(0.0, 3000.0, 10.0, "suffix:px/s^2") var damage_hop_horizontal_deceleration: float = 650.0

@export_group("Event Bus")
@export var listen_to_event_bus: bool = true
@export var listen_to_npc_event_bus_only: bool = true
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
		"state_request": "ReactToEvent",
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
@onready var knockout_bar: ProgressBar = get_node_or_null("KnockoutBar") as ProgressBar
@onready var name_label: Label = get_node_or_null("NameLabel") as Label
# Optional child component. If present, social values can drive the reusable NPC states.
@onready var npc_state_machine: NpcStateMachine = get_node_or_null("NpcStateMachine") as NpcStateMachine

var home_position: Vector2
var direction: int = 1
var reaction_timer: float = 0.0
var reaction_velocity_x: float = 0.0
var damage_hop_timer: float = 0.0
var seen_targets: Array[Node2D] = []
var syncing_state_machine_values: bool = false
var perception_enabled: bool = true
var sight_pivot_visible_before_sleep: bool = true
var sight_area_monitoring_before_sleep: bool = true
var knockout_bar_active: bool = false
var is_downed: bool = false
# Cached player reference so _update_favor_bar_visibility() does not scan the player
# group on every NPC every physics frame. Refreshed lazily when it becomes invalid.
var cached_player: Node2D


func _ready() -> void:
	add_to_group("npc")
	add_to_group("social_npc")

	if not _setup_location_tracking():
		return

	home_position = global_position
	direction = 1 if starts_moving_right else -1

	_ensure_social_stats()
	setup_hp_bar()
	setup_knockout_bar()
	_update_facing()
	_update_favor_bar()
	_update_favor_bar_visibility()
	_update_visual_mood()
	_setup_relationship_identity()
	_setup_npc_tags()
	_update_name_tag()

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
		_process_knockout_recovery(delta)
		_update_favor_bar_visibility()
		return

	_apply_gravity(delta)
	_process_knockout_recovery(delta)

	if is_downed:
		velocity.x = 0.0
		_update_favor_bar_visibility()
		move_and_slide()
		return

	if process_damage_hop(delta):
		pass
	elif reaction_timer > 0.0:
		reaction_timer -= delta
		velocity.x = reaction_velocity_x
	else:
		_process_patrol()

	_update_favor_bar_visibility()
	move_and_slide()


func can_see(target: Node2D) -> bool:
	if not perception_enabled or target == null or not is_instance_valid(target):
		return false

	return sight_area.get_overlapping_bodies().has(target)


func set_npc_perception_enabled(enabled: bool) -> void:
	# Sleep can suspend sight without permanently changing this NPC's authored vision setup.
	if perception_enabled == enabled:
		return

	perception_enabled = enabled
	if not enabled:
		sight_pivot_visible_before_sleep = sight_pivot.visible
		sight_area_monitoring_before_sleep = sight_area.monitoring
		sight_pivot.visible = false
		sight_area.set_deferred("monitoring", false)
		seen_targets.clear()
		return

	sight_pivot.visible = sight_pivot_visible_before_sleep
	sight_area.set_deferred("monitoring", sight_area_monitoring_before_sleep)


func is_npc_perception_enabled() -> bool:
	return perception_enabled


func apply_social_event(
	stat_delta: Dictionary,
	actor: Node2D = null,
	requires_actor_visibility: bool = true
) -> bool:
	if requires_actor_visibility and actor != null and not can_see(actor):
		return false

	var normalized_delta := _normalize_stat_delta(stat_delta)
	var favor_delta := float(normalized_delta.get("favor", 0.0))
	var changed_stats: Dictionary = {}

	for stat_key in normalized_delta.keys():
		var key := String(stat_key)
		var current_value := float(social_stats.get(key, 0.0))
		var next_value := current_value + float(normalized_delta[stat_key])
		var max_value := _get_stat_max_value(key)
		social_stats[key] = clampf(next_value, 0.0, max_value)

		var actual_delta := float(social_stats[key]) - current_value
		if not is_equal_approx(actual_delta, 0.0):
			changed_stats[key] = actual_delta

	update_hp_bar()
	if changed_stats.has("knockout") and get_knockout() > 0.0:
		knockout_bar_active = true
	update_knockout_bar()
	_update_knockout_state()
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


func take_damage(
	amount: float,
	damage_source_position: Vector2 = Vector2.ZERO,
	damage_source: Node = null,
	knockout_damage: float = 0.0
) -> void:
	if amount <= 0.0 or get_hp() <= 0.0:
		return

	var previous_hp := get_hp()
	var damage_actor := damage_source as Node2D
	var damage_came_from_npc := damage_actor != null and damage_actor.is_in_group("npc")
	var emotion_stats := _get_damage_emotion_stats(amount, previous_hp)
	var relationship_anger_delta := 0.0
	var relationship_fear_delta := 0.0
	if damage_came_from_npc and emotion_stats.has("anger"):
		relationship_anger_delta = float(emotion_stats.get("anger", 0.0))
		emotion_stats.erase("anger")
	if damage_came_from_npc and emotion_stats.has("fear"):
		relationship_fear_delta = float(emotion_stats.get("fear", 0.0))
		emotion_stats.erase("fear")

	var damage_stats := {
		"hp": -amount,
	}
	if not damage_came_from_npc:
		damage_stats["favor"] = -amount * damage_favor_penalty
	damage_stats.merge(emotion_stats, true)

	# Damage is handled as a social value change, so hp/fear/favor rules can drive any state.
	# Add hurt animations here later:
	# if animation_player != null:
	# 	animation_player.play("hurt")
	apply_social_event(damage_stats, damage_actor, false)

	var damage_taken := previous_hp - get_hp()
	if damage_came_from_npc and damage_taken > 0.0:
		change_relationship_favor_for(
			damage_actor,
			-damage_taken * damage_favor_penalty,
			"damaged_by_npc"
		)
		var relationship_anger := change_relationship_anger_for(
			damage_actor,
			relationship_anger_delta,
			"damaged_by_npc"
		)
		if (
			npc_state_machine != null
			and relationship_anger_delta > 0.0
			and relationship_anger >= npc_relationship_fight_anger_threshold
		):
			npc_state_machine.request_state(
				&"Fight",
				damage_actor,
				"npc_relationship_anger",
				94
			)
		var relationship_fear := change_relationship_fear_for(
			damage_actor,
			relationship_fear_delta,
			"damaged_by_npc"
		)
		if (
			npc_state_machine != null
			and relationship_fear_delta > 0.0
			and relationship_fear >= npc_relationship_flee_fear_threshold
			and relationship_anger < npc_relationship_fight_anger_threshold
		):
			npc_state_machine.request_state(
				&"Flee",
				damage_actor,
				"npc_relationship_fear",
				90
			)

	if damage_taken > 0.0 and get_hp() > 0.0:
		apply_knockout(knockout_damage, damage_actor, true)
		if not _is_in_downed_recovery():
			start_damage_hop(damage_source_position)
	DamageEvents.emit_damage_dealt(damage_taken, damage_source, self)

	if get_hp() <= 0.0:
		die()


func start_damage_hop(damage_source_position: Vector2) -> void:
	if not damage_hop_enabled or damage_hop_duration <= 0.0:
		return

	var away_direction := signf(global_position.x - damage_source_position.x)
	if is_zero_approx(away_direction):
		away_direction = -1.0 if direction >= 0 else 1.0

	damage_hop_timer = damage_hop_duration
	velocity.x = away_direction * damage_hop_horizontal_speed
	velocity.y = -damage_hop_vertical_speed


func process_damage_hop(delta: float) -> bool:
	# The state machine calls this before its active state, preventing state movement
	# from replacing the short hit impulse while still allowing normal gravity.
	if damage_hop_timer <= 0.0:
		return false

	damage_hop_timer = maxf(damage_hop_timer - maxf(delta, 0.0), 0.0)
	velocity.x = move_toward(
		velocity.x,
		0.0,
		damage_hop_horizontal_deceleration * maxf(delta, 0.0)
	)
	return true


func _get_damage_emotion_stats(amount: float, previous_hp: float) -> Dictionary:
	# Above the danger threshold, hits annoy the NPC; below it, fear rises with injury.
	var next_hp := clampf(previous_hp - amount, 0.0, max_hp)
	var damage_taken := maxf(previous_hp - next_hp, 0.0)
	var health_percent := _get_health_percent(next_hp)
	if health_percent >= damage_fear_health_threshold_percent:
		return {
			"anger": damage_taken * damage_anger_multiplier,
	}

	var danger_ratio := _get_low_health_danger_ratio(health_percent)
	var fear_scale := lerpf(
		low_health_fear_min_scale,
		maxf(low_health_fear_max_scale, low_health_fear_min_scale),
		danger_ratio
	)
	return {
		"fear": damage_taken * damage_fear_multiplier * fear_scale,
	}


func _get_health_percent(hp_value: float) -> float:
	if max_hp <= 0.0:
		return 0.0

	return (clampf(hp_value, 0.0, max_hp) / max_hp) * 100.0


func _get_low_health_danger_ratio(health_percent: float) -> float:
	var threshold := clampf(damage_fear_health_threshold_percent, 0.0, 100.0)
	if threshold <= 0.0:
		return 1.0

	return clampf((threshold - health_percent) / threshold, 0.0, 1.0)


func heal(amount: float) -> void:
	if amount <= 0.0 or get_hp() <= 0.0:
		return

	apply_social_event({"hp": amount}, null, false)


func die() -> void:
	if float(social_stats.get("disabled", 0.0)) >= 1.0:
		return

	social_stats["disabled"] = 1.0
	knockout_bar_active = false
	is_downed = false
	update_hp_bar()
	update_knockout_bar()
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
		"world_simulation_profile": _get_world_simulation_profile(),
		"starts_moving_right": starts_moving_right,
		"patrol_range": patrol_range,
		"walk_speed": walk_speed,
		"use_state_machine_when_available": use_state_machine_when_available,
		"relationship_id": String(get_relationship_id()),
		"location_id": String(location_id),
	}


func _get_world_simulation_profile() -> Dictionary:
	# Off-screen simulation reads the same per-NPC rates configured on this machine instance.
	if npc_state_machine == null:
		return {}

	var tired_rest_threshold := 50.0
	var tired_rest_rule = npc_state_machine.value_state_rules.get("tired_rest", {})
	if tired_rest_rule is Dictionary:
		tired_rest_threshold = float(tired_rest_rule.get("at_least", tired_rest_threshold))
	var tired_rest_floor := 40.0
	var rest_state := npc_state_machine.get_state(&"Rest")
	if rest_state != null and rest_state.has_method("get_tired_floor"):
		tired_rest_floor = float(rest_state.call("get_tired_floor"))

	var talk_interval_minutes := maxf(
		float(npc_state_machine.talk_need_growth_interval_game_minutes),
		0.001
	)
	return {
		"passive_needs_enabled": npc_state_machine.passive_needs_enabled,
		"passive_healing_per_game_day": npc_state_machine.passive_healing_per_game_day,
		"max_hp": max_hp,
		"rates_per_game_hour": {
			"sleep_need": npc_state_machine.sleep_need_growth_per_game_hour,
			"hunger": npc_state_machine.hunger_growth_per_game_hour,
			"boredom": npc_state_machine.boredom_growth_per_game_hour,
			"talk_need": (
				npc_state_machine.talk_need_growth_per_interval
				* (60.0 / talk_interval_minutes)
			),
		},
		"tired": {
			"enabled": npc_state_machine.tired_enabled,
			"value_name": String(npc_state_machine.tired_value_name),
			"action_growth_per_game_hour": npc_state_machine.tired_growth_per_action_game_hour,
			"fight_growth_per_game_hour": npc_state_machine.tired_growth_per_fight_game_hour,
			"rest_recovery_per_game_hour": npc_state_machine.tired_recovery_per_rest_game_hour,
			"rest_threshold": tired_rest_threshold,
			"rest_floor": tired_rest_floor,
			"inactive_states": npc_state_machine.tired_inactive_states.duplicate(),
		},
		"loneliness_recovery": {
			"enabled": npc_state_machine.loneliness_recovery_enabled,
			"value_name": String(npc_state_machine.loneliness_value_name),
			"talk_need_below": npc_state_machine.loneliness_recovery_talk_need_below,
			"full_recovery_game_hours": npc_state_machine.loneliness_full_recovery_game_hours,
		},
		"social_seeking": {
			"enabled": npc_state_machine.cross_scene_talk_enabled,
			"talk_need_threshold": npc_state_machine.cross_scene_talk_need_threshold,
			"priority": npc_state_machine.cross_scene_talk_priority,
			"minimum_npc_favor": npc_state_machine.cross_scene_minimum_npc_favor,
			"player_target_chance": npc_state_machine.cross_scene_player_target_chance,
		},
		"anger_decay": {
			"enabled": npc_state_machine.anger_decay_enabled,
			"value_name": String(npc_state_machine.anger_decay_value_name),
			"full_decay_game_hours": npc_state_machine.anger_full_decay_game_hours,
		},
		"fear_decay": {
			"enabled": npc_state_machine.fear_decay_enabled,
			"value_name": String(npc_state_machine.fear_decay_value_name),
			"panic_floor": npc_state_machine.fear_panic_floor,
			"panic_cooldown_game_hours": (
				npc_state_machine.fear_panic_cooldown_game_minutes / 60.0
			),
			"slow_decay_per_game_hour": npc_state_machine.fear_slow_decay_per_game_hour,
			"stop_value": maxf(
				npc_state_machine.get_flee_fear_threshold()
					- npc_state_machine.fear_decay_stop_below_flee_threshold_by,
				0.0
			),
		},
	}


func apply_npc_location_save_data(data: Dictionary) -> void:
	if data.has("social_stats") and data["social_stats"] is Dictionary:
		social_stats = _normalize_stat_values(data["social_stats"])
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

	_ensure_social_stats()
	if hp_bar != null:
		update_hp_bar()
	if favor_bar != null:
		_update_favor_bar()
	if body_visual != null:
		_update_visual_mood()
	if name_label != null:
		_update_name_tag()

	if npc_state_machine != null:
		syncing_state_machine_values = true
		npc_state_machine.replace_values(social_stats, null, {}, false)
		syncing_state_machine_values = false
		npc_state_machine.evaluate_persistent_combat_reactions()


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


func get_relationship_anger_for(other: Node, fallback: float = 0.0) -> float:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("get_anger"):
		return fallback

	return float(relationships.call("get_anger", self, other, fallback))


func change_relationship_anger_for(other: Node, delta: float, reason: String = "manual") -> float:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("change_anger"):
		return 0.0

	return float(relationships.call("change_anger", self, other, delta, reason))


func decay_relationship_anger(game_hours: float, full_decay_game_hours: float) -> void:
	if game_hours <= 0.0 or full_decay_game_hours <= 0.0:
		return

	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("decay_anger_for"):
		return

	var decay_amount := (100.0 / full_decay_game_hours) * game_hours
	relationships.call("decay_anger_for", self, decay_amount)


func get_relationship_fear_for(other: Node, fallback: float = 0.0) -> float:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("get_fear"):
		return fallback

	return float(relationships.call("get_fear", self, other, fallback))


func change_relationship_fear_for(other: Node, delta: float, reason: String = "manual") -> float:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("change_fear"):
		return 0.0

	return float(relationships.call("change_fear", self, other, delta, reason))


func should_flee_from_npc(other: Node) -> bool:
	return (
		other != null
		and other.is_in_group("npc")
		and get_relationship_anger_for(other, 0.0) < npc_relationship_fight_anger_threshold
		and get_relationship_fear_for(other, 0.0) >= npc_relationship_flee_fear_threshold
	)


func should_fight_npc(other: Node) -> bool:
	return (
		other != null
		and other.is_in_group("npc")
		and get_relationship_anger_for(other, 0.0) >= npc_relationship_fight_anger_threshold
	)


func decay_relationship_fear(
	game_hours: float,
	panic_floor: float,
	panic_cooldown_game_hours: float,
	slow_decay_per_game_hour: float,
	stop_value: float
) -> void:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("decay_fear_for"):
		return

	relationships.call(
		"decay_fear_for",
		self,
		game_hours,
		panic_floor,
		panic_cooldown_game_hours,
		slow_decay_per_game_hour,
		stop_value
	)


func has_met_npc(other: Node) -> bool:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("has_met"):
		return false

	return bool(relationships.call("has_met", self, other))


func get_hp() -> float:
	return clampf(float(social_stats.get("hp", max_hp)), 0.0, max_hp)


func get_knockout() -> float:
	return clampf(float(social_stats.get("knockout", 0.0)), 0.0, max_knockout)


func get_display_name() -> String:
	# Chooses the label text shown above the NPC, preferring explicit display_name.
	if not display_name.is_empty():
		return display_name

	if relationship_id != &"":
		return String(relationship_id).capitalize()

	if location_id != &"":
		return String(location_id).capitalize()

	return String(name)


func setup_hp_bar() -> void:
	if hp_bar == null:
		return

	hp_bar.setup_hp(max_hp, get_hp())


func update_hp_bar() -> void:
	if hp_bar == null:
		return

	hp_bar.set_hp(get_hp())


func setup_knockout_bar() -> void:
	if knockout_bar == null:
		knockout_bar = ProgressBar.new()
		knockout_bar.name = "KnockoutBar"
		knockout_bar.offset_left = -36.0
		knockout_bar.offset_top = -109.0
		knockout_bar.offset_right = 36.0
		knockout_bar.offset_bottom = -105.0
		knockout_bar.show_percentage = false
		add_child(knockout_bar)

	knockout_bar.min_value = 0.0
	knockout_bar.max_value = maxf(max_knockout, 1.0)
	update_knockout_bar()


func update_knockout_bar() -> void:
	if knockout_bar == null:
		return

	var current_knockout := get_knockout()
	knockout_bar.max_value = maxf(max_knockout, 1.0)
	knockout_bar.value = current_knockout
	knockout_bar.visible = knockout_bar_active and current_knockout > 0.0


func apply_knockout(amount: float, actor: Node2D = null, evaluate_reactions: bool = true) -> void:
	if amount <= 0.0 or get_hp() <= 0.0 or max_knockout <= 0.0:
		return

	knockout_bar_active = true
	_set_knockout(get_knockout() + amount, actor, evaluate_reactions)


func _process_knockout_recovery(delta: float) -> void:
	if not knockout_bar_active:
		return

	var current_knockout := get_knockout()
	if current_knockout <= 0.0:
		knockout_bar_active = false
		is_downed = false
		update_knockout_bar()
		return

	var decay_rate := downed_decay_per_second if _is_in_downed_recovery() else knockout_decay_per_second
	_set_knockout(
		move_toward(current_knockout, 0.0, maxf(decay_rate, 0.0) * maxf(delta, 0.0)),
		null,
		false
	)


func _set_knockout(next_value: float, actor: Node2D = null, evaluate_reactions: bool = true) -> void:
	var previous_value := get_knockout()
	var clamped_value := clampf(next_value, 0.0, maxf(max_knockout, 1.0))
	if is_equal_approx(previous_value, clamped_value):
		update_knockout_bar()
		return

	social_stats["knockout"] = clamped_value
	var changed_stats := {"knockout": clamped_value - previous_value}
	_update_knockout_state()
	update_knockout_bar()

	if _state_machine_active():
		syncing_state_machine_values = true
		npc_state_machine.replace_values(social_stats, actor, changed_stats, evaluate_reactions)
		syncing_state_machine_values = false

	social_stats_changed.emit(social_stats.duplicate())


func _update_knockout_state() -> void:
	var current_knockout := get_knockout()
	if current_knockout >= maxf(max_knockout, 1.0):
		is_downed = true
	elif current_knockout <= 0.0:
		is_downed = false


func _is_in_downed_recovery() -> bool:
	if is_downed:
		return true

	return npc_state_machine != null and npc_state_machine.is_in_state(&"Downed")


func _ensure_social_stats() -> void:
	var default_stats := {
		"favor": 50.0,
		"love": 0.0,
		"trust": 50.0,
		"fear": 0.0,
		"anger": 0.0,
		"hunger": 25.0,
		"energy": 100.0,
		"sleep_need": 0.0,
		"tired": 0.0,
		"boredom": 0.0,
		"bored": 0.0,
		"talk_need": 0.0,
		"lonely": 0.0,
		"sadness": 0.0,
		"suspicion": 0.0,
		"curiosity": 0.0,
		"hp": 100.0,
		"knockout": 0.0,
		"disabled": 0.0
	}

	social_stats = _normalize_stat_values(social_stats)

	for stat_key in default_stats.keys():
		if not social_stats.has(stat_key):
			social_stats[stat_key] = default_stats[stat_key]

	social_stats["hp"] = clampf(float(social_stats.get("hp", max_hp)), 0.0, max_hp)
	social_stats["knockout"] = clampf(float(social_stats.get("knockout", 0.0)), 0.0, max_knockout)
	knockout_bar_active = get_knockout() > 0.0
	_update_knockout_state()


func _get_stat_max_value(stat_key: String) -> float:
	if stat_key == "hp":
		return max_hp
	if stat_key == "knockout":
		return maxf(max_knockout, 1.0)

	return 100.0


func _normalize_stat_values(values: Dictionary) -> Dictionary:
	var normalized := values.duplicate(true)
	for old_key in STAT_KEY_ALIASES.keys():
		if not normalized.has(old_key):
			continue

		var new_key := String(STAT_KEY_ALIASES[old_key])
		if not normalized.has(new_key):
			normalized[new_key] = normalized[old_key]
		normalized.erase(old_key)

	return normalized


func _normalize_stat_delta(stat_delta: Dictionary) -> Dictionary:
	var normalized := {}
	for stat_key in stat_delta.keys():
		var key := _canonical_stat_key(stat_key)
		normalized[key] = float(normalized.get(key, 0.0)) + float(stat_delta[stat_key])

	return normalized


func _canonical_stat_key(stat_key) -> String:
	var key := String(stat_key)
	if STAT_KEY_ALIASES.has(key):
		return String(STAT_KEY_ALIASES[key])

	return key


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
	var player := _get_player()
	if player == null:
		favor_bar.visible = false
		return

	favor_bar.visible = global_position.distance_to(player.global_position) <= favor_bar_visible_distance


func _get_player() -> Node2D:
	# Returns the cached player when still valid; otherwise re-scans the group once.
	if cached_player != null and is_instance_valid(cached_player):
		return cached_player

	cached_player = get_tree().get_first_node_in_group("player") as Node2D
	return cached_player


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
	if not perception_enabled:
		return
	if body == self:
		return
	if seen_targets.has(body):
		return

	seen_targets.append(body)
	_try_meet_relationship_target(body)

	if npc_state_machine != null:
		npc_state_machine.notify_target_seen(body)
	target_seen.emit(body)


func _on_sight_area_body_exited(body: Node2D) -> void:
	if body == self:
		return
	seen_targets.erase(body)
	if not perception_enabled:
		return
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
	var resolved_id := get_relationship_id()
	if resolved_id == &"":
		return

	set_meta("relationship_id", String(resolved_id))


func _setup_npc_tags() -> void:
	# Stores tags as metadata and Godot groups so spots/interactions can gate on them.
	set_meta("npc_tags", npc_tags.duplicate())

	for npc_tag in npc_tags:
		var tag_text := String(npc_tag)
		if tag_text.is_empty():
			continue

		add_to_group(tag_text)


func _update_name_tag() -> void:
	# Refreshes the visible name label, optionally including the stable location id.
	if name_label == null:
		return

	name_label.visible = show_name_tag
	if not show_name_tag:
		return

	var label_text := get_display_name()
	var location_text := String(get_npc_location_id())
	if show_location_id_in_name_tag and not location_text.is_empty() and location_text != label_text:
		label_text = "%s [%s]" % [label_text, location_text]

	name_label.text = label_text


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
	if listen_to_npc_event_bus_only and event_bus.has_signal(&"npc_event_emitted"):
		if not event_bus.is_connected(&"npc_event_emitted", callback):
			event_bus.connect(&"npc_event_emitted", callback)
	elif not event_bus.is_connected(&"event_emitted", callback):
		event_bus.connect(&"event_emitted", callback)


func _disconnect_event_bus() -> void:
	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus == null:
		return

	var callback := Callable(self, "_on_event_bus_event")
	if event_bus.has_signal(&"npc_event_emitted") and event_bus.is_connected(&"npc_event_emitted", callback):
		event_bus.disconnect(&"npc_event_emitted", callback)
	if event_bus.is_connected(&"event_emitted", callback):
		event_bus.disconnect(&"event_emitted", callback)


func _on_event_bus_event(event_name: StringName, payload: Dictionary) -> void:
	# Sleeping NPCs ignore ambient/observed events; direct damage still reaches take_damage().
	if npc_state_machine != null and npc_state_machine.is_in_state(&"Sleep"):
		return

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
	if social_stats.has("knockout"):
		knockout_bar_active = knockout_bar_active or get_knockout() > 0.0
		_update_knockout_state()
	update_knockout_bar()
	_update_favor_bar()
	_update_visual_mood()
	social_stats_changed.emit(social_stats.duplicate())
