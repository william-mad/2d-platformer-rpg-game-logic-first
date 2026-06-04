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

@export_group("Reactions")
@export var reaction_pause_time: float = 0.6
@export var negative_reaction_speed_multiplier: float = 1.5

@export_group("State Machine")
@export var use_state_machine_when_available: bool = true

@onready var body_visual: Polygon2D = %BodyVisual
@onready var sight_pivot: Node2D = %SightPivot
@onready var sight_area: Area2D = %SightArea
@onready var favor_bar: ProgressBar = %FavorBar
@onready var npc_state_machine: NpcStateMachine = get_node_or_null("NpcStateMachine") as NpcStateMachine

var home_position: Vector2
var direction: int = 1
var reaction_timer: float = 0.0
var reaction_velocity_x: float = 0.0
var seen_targets: Array[Node2D] = []
var syncing_state_machine_values: bool = false


func _ready() -> void:
	add_to_group("social_npc")

	home_position = global_position
	direction = 1 if starts_moving_right else -1

	_ensure_social_stats()
	_update_facing()
	_update_favor_bar()
	_update_favor_bar_visibility()
	_update_visual_mood()

	sight_area.body_entered.connect(_on_sight_area_body_entered)
	sight_area.body_exited.connect(_on_sight_area_body_exited)
	_setup_state_machine()


func _physics_process(delta: float) -> void:
	if _state_machine_active():
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
		social_stats[key] = clampf(next_value, 0.0, 100.0)

		var actual_delta := float(social_stats[key]) - current_value
		if not is_equal_approx(actual_delta, 0.0):
			changed_stats[key] = actual_delta

	_update_favor_bar()
	_update_visual_mood()

	if _state_machine_active():
		syncing_state_machine_values = true
		npc_state_machine.replace_values(social_stats, actor, changed_stats)
		syncing_state_machine_values = false
	else:
		_react_to_event(actor, favor_delta)

	social_stats_changed.emit(social_stats.duplicate())
	return true


func get_favor() -> float:
	return float(social_stats.get("favor", 0.0))


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

	npc_state_machine.bind_npc(self)

	var callback := Callable(self, "_on_npc_state_machine_values_changed")
	if not npc_state_machine.values_changed.is_connected(callback):
		npc_state_machine.values_changed.connect(callback)

	syncing_state_machine_values = true
	npc_state_machine.replace_values(social_stats)
	syncing_state_machine_values = false


func _state_machine_active() -> bool:
	return use_state_machine_when_available and npc_state_machine != null and npc_state_machine.active


func _on_npc_state_machine_values_changed(
	values: Dictionary,
	_changed_values: Dictionary,
	_actor: Node2D
) -> void:
	if syncing_state_machine_values:
		return

	social_stats = values.duplicate(true)
	_update_favor_bar()
	_update_visual_mood()
	social_stats_changed.emit(social_stats.duplicate())
