class_name NpcStateFight extends NpcState

@export var anger_value_name: StringName = &"anger"
@export_range(0.0, 100.0, 0.1) var calm_anger_threshold: float = 60.0
@export var target_groups: Array[StringName] = [&"player", &"npc"]
@export var monster_target_groups: Array[StringName] = [&"monster", &"monsters", &"enemy", &"enemies"]
@export var training_target_groups: Array[StringName] = [&"training_dummy", &"attack_target"]
@export var require_player_normal_layer: bool = true
@export_range(1, 32, 1) var normal_player_layer: int = 2
@export var target_refresh_seconds: float = 0.25
@export_range(0.0, 100.0, 0.1, "suffix:%") var stop_fighting_below_health_percent: float = 20.0

@export_group("Movement")
@export var chase_speed_multiplier: float = 1.08
@export var preferred_attack_distance: float = 150.0
@export var attack_position_tolerance: float = 24.0
@export var last_known_pause_seconds: float = 2.0
@export var search_wander_interval_seconds: float = 1.4
@export var search_wander_distance: float = 90.0

@export_group("Thrown Attack")
@export var projectile_scene: PackedScene
@export var attack_cooldown_seconds: float = 2.0
@export var attack_range: float = 280.0
@export var attack_min_range: float = 24.0
@export var projectile_damage: float = 3.0
@export var projectile_knockout_damage: float = 40.0
@export var projectile_flight_time: float = 0.65
@export var projectile_arc_height: float = 72.0
@export var projectile_lifetime: float = 3.0
@export var projectile_collision_mask: int = 131
@export var projectile_spawn_offset: Vector2 = Vector2(18.0, -48.0)
@export var friendly_fire_favor_penalty: float = 5.0
@export var anger_drop_on_target_hit: float = 8.0

@export_group("Interrupts")
@export var minimum_interrupt_priority: int = 95

var fight_target: Node2D
var last_known_position: Vector2
var has_last_known_position: bool = false
var target_refresh_timer: float = 0.0
var attack_cooldown_timer: float = 0.0
var last_known_pause_timer: float = 0.0
var paused_at_last_known_position: bool = false
var search_wander_timer: float = 0.0
var search_target_x: float = 0.0
var rng := RandomNumberGenerator.new()
var fight_target_was_monster: bool = false


func enter() -> void:
	# This is the default fight brain; replace this child state script for custom NPC combat.
	super.enter()
	rng.randomize()
	target_refresh_timer = 0.0
	attack_cooldown_timer = minf(attack_cooldown_timer, 0.25)
	last_known_pause_timer = 0.0
	paused_at_last_known_position = false
	search_wander_timer = 0.0
	fight_target_was_monster = false
	_set_fight_target(_find_fight_target())
	_remember_target_position()


func exit() -> void:
	stop_horizontal()


func values_changed(
	_values: Dictionary,
	_changed_values: Dictionary,
	_actor: Node2D
) -> NpcState:
	var finished_state := _get_finished_fight_state()
	if finished_state != null:
		return finished_state
	if _should_stop_for_low_health():
		return get_state(&"Idle")
	if _anger_is_calm():
		return get_state(&"Idle")

	return next_state


func physics_process(delta: float) -> NpcState:
	if not action_session_is_current():
		return reconcile_invalid_action_session()
	var finished_state := _get_finished_fight_state()
	if finished_state != null:
		return finished_state
	if _should_stop_for_low_health():
		return get_state(&"Idle")
	if _anger_is_calm():
		return get_state(&"Idle")

	_update_target(delta)
	if _has_fight_target():
		_remember_target_position()
		_update_chase()
		_update_attack(delta)
	else:
		_update_search(delta)

	return next_state


func can_exit_to(new_state: NpcState, request_priority: int) -> bool:
	# Fight holds control until anger cools, but death/collapse-level requests can still win.
	if _should_stop_for_low_health():
		return true
	if _anger_is_calm():
		return true
	if new_state != null and String(new_state.name) == "DisabledDead":
		return true

	return request_priority >= minimum_interrupt_priority


func can_start_fight_with(candidate: Node2D) -> bool:
	return can_start_fight() and _can_target_for_fight(candidate)


func can_start_fight() -> bool:
	return not _should_stop_for_low_health()


func _update_target(delta: float) -> void:
	target_refresh_timer -= delta
	if target_refresh_timer > 0.0:
		return

	target_refresh_timer = maxf(target_refresh_seconds, 0.01)
	if _has_fight_target():
		return

	_set_fight_target(_find_fight_target())


func _find_fight_target() -> Node2D:
	if machine != null:
		var action_target := machine.get_active_action_target()
		if _can_target_for_fight(action_target):
			return action_target
		var selected_target := machine.get_selected_threat()
		if _can_target_for_fight(selected_target):
			return selected_target

	if npc == null or not npc.is_inside_tree():
		return null

	var npc_position := npc.global_position
	var closest_target: Node2D = null
	var closest_distance_squared := INF
	for group_name in _get_target_search_groups():
		# get_nodes_in_group accepts StringName directly; avoid per-iteration String coercion.
		for candidate in npc.get_tree().get_nodes_in_group(group_name):
			var candidate_node := candidate as Node2D
			if not _can_target_for_fight(candidate_node):
				continue

			# distance_squared_to avoids a sqrt per candidate; ordering is identical.
			var distance_squared := npc_position.distance_squared_to(candidate_node.global_position)
			if distance_squared >= closest_distance_squared:
				continue

			closest_distance_squared = distance_squared
			closest_target = candidate_node

	return closest_target


func _can_target_for_fight(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	if candidate == npc:
		return false
	if _target_is_defeated(candidate):
		return false

	if _target_is_monster(candidate):
		return candidate.has_method("take_damage")

	if not _target_group_is_allowed(candidate):
		return false
	if _target_is_training_target(candidate):
		return candidate.has_method("take_damage")
	if candidate.is_in_group("npc"):
		return (
			npc != null
			and npc.has_method("get_relationship_anger_for")
			and float(npc.call("get_relationship_anger_for", candidate, 0.0))
			> calm_anger_threshold
		)

	if candidate.is_in_group("player") and require_player_normal_layer:
		return _target_is_on_collision_layer(candidate, normal_player_layer)

	return true


func _target_group_is_allowed(candidate: Node2D) -> bool:
	if _target_is_monster(candidate):
		return true

	if target_groups.is_empty():
		return true

	for group_name in target_groups:
		if candidate.is_in_group(String(group_name)):
			return true

	return false


func _target_is_on_collision_layer(candidate: Node2D, layer_index: int) -> bool:
	var collision_object := candidate as CollisionObject2D
	if collision_object == null:
		return true

	return collision_object.get_collision_layer_value(layer_index)


func _has_fight_target() -> bool:
	if not _can_target_for_fight(fight_target):
		fight_target = null
		return false

	return true


func _remember_target_position() -> void:
	if fight_target == null or not is_instance_valid(fight_target):
		return

	last_known_position = fight_target.global_position
	has_last_known_position = true
	paused_at_last_known_position = false
	last_known_pause_timer = 0.0


func _update_chase() -> void:
	if npc == null or fight_target == null:
		return

	var x_distance := fight_target.global_position.x - npc.global_position.x
	var distance := absf(x_distance)
	var direction_to_target := signf(x_distance)
	if direction_to_target != 0.0:
		face_x_direction(direction_to_target)

	if distance < attack_min_range:
		move_away_from_position(fight_target.global_position, machine.get_effective_walk_speed())
		return

	var desired_distance := maxf(preferred_attack_distance, attack_min_range)
	var tolerance := maxf(attack_position_tolerance, machine.stop_distance)
	if distance <= desired_distance + tolerance and distance >= desired_distance - tolerance:
		stop_horizontal()
		return

	var desired_x := fight_target.global_position.x - (direction_to_target * desired_distance)
	var desired_position := Vector2(desired_x, npc.global_position.y)
	var chase_speed := machine.get_effective_run_speed() * maxf(chase_speed_multiplier, 0.0)
	move_toward_position(desired_position, chase_speed, tolerance)


func _update_attack(delta: float) -> void:
	attack_cooldown_timer -= delta
	if attack_cooldown_timer > 0.0:
		return

	if fight_target == null or not is_instance_valid(fight_target):
		return

	var distance := npc.global_position.distance_to(fight_target.global_position)
	if distance > attack_range or distance < attack_min_range:
		return

	_throw_attack(fight_target)
	attack_cooldown_timer = maxf(attack_cooldown_seconds, 0.05)


func _throw_attack(attack_target: Node2D) -> void:
	if attack_target == null or not is_instance_valid(attack_target):
		return

	var target_position := _get_attack_aim_position(attack_target)
	var projectile := _create_projectile()
	if projectile == null:
		return

	var spawn_position := _get_projectile_spawn_position(target_position)
	var parent := _get_projectile_parent()
	parent.add_child(projectile)

	if projectile.has_method("launch"):
		projectile.call(
			"launch",
			spawn_position,
			target_position,
			npc,
			projectile_damage,
			projectile_flight_time,
			projectile_arc_height,
			projectile_lifetime,
			projectile_collision_mask,
			friendly_fire_favor_penalty,
			attack_target,
			anger_drop_on_target_hit,
			projectile_knockout_damage
		)
	else:
		projectile.global_position = spawn_position


func _create_projectile() -> Node2D:
	if projectile_scene != null:
		return projectile_scene.instantiate() as Node2D

	return NpcThrownAttack.new()


func _get_projectile_parent() -> Node:
	if npc != null and npc.is_inside_tree() and npc.get_tree().current_scene != null:
		return npc.get_tree().current_scene
	if npc != null and npc.get_parent() != null:
		return npc.get_parent()

	return self


func _get_projectile_spawn_position(target_position: Vector2) -> Vector2:
	var direction_x := signf(target_position.x - npc.global_position.x)
	if direction_x == 0.0:
		direction_x = 1.0

	return npc.global_position + Vector2(projectile_spawn_offset.x * direction_x, projectile_spawn_offset.y)


func _get_attack_aim_position(attack_target: Node2D) -> Vector2:
	# Aim at the visible body center now, not just the older remembered location.
	var aim_position := attack_target.global_position
	if attack_target.has_method("get_attack_aim_position"):
		var target_aim_position = attack_target.call("get_attack_aim_position")
		if target_aim_position is Vector2:
			return target_aim_position

	var collision_shape := _get_attack_target_collision_shape(attack_target)
	if collision_shape != null and not collision_shape.disabled:
		aim_position = collision_shape.global_position

	return aim_position


func _get_attack_target_collision_shape(attack_target: Node2D) -> CollisionShape2D:
	for shape_name in ["colider_stand", "CollisionShape2D", "colider_crouch"]:
		var named_shape := attack_target.get_node_or_null(shape_name) as CollisionShape2D
		if named_shape != null and not named_shape.disabled:
			return named_shape

	for child in attack_target.get_children():
		var child_shape := child as CollisionShape2D
		if child_shape != null and not child_shape.disabled:
			return child_shape

	return null


func _update_search(delta: float) -> void:
	if npc == null:
		return

	if (
		has_last_known_position
		and not paused_at_last_known_position
		and not is_close_to(last_known_position, machine.stop_distance)
	):
		paused_at_last_known_position = false
		move_toward_position(last_known_position, machine.get_effective_walk_speed(), machine.stop_distance)
		return

	if has_last_known_position and not paused_at_last_known_position:
		paused_at_last_known_position = true
		last_known_pause_timer = maxf(last_known_pause_seconds, 0.0)
		stop_horizontal()
		return

	if last_known_pause_timer > 0.0:
		last_known_pause_timer -= delta
		stop_horizontal()
		return

	search_wander_timer -= delta
	if search_wander_timer <= 0.0:
		_pick_search_wander_target()

	var target_position := Vector2(search_target_x, npc.global_position.y)
	if move_toward_position(target_position, machine.get_effective_walk_speed(), machine.stop_distance):
		stop_horizontal()


func _pick_search_wander_target() -> void:
	search_wander_timer = maxf(search_wander_interval_seconds, 0.1)
	var search_origin := last_known_position.x if has_last_known_position else npc.global_position.x
	var distance := rng.randf_range(-absf(search_wander_distance), absf(search_wander_distance))
	search_target_x = search_origin + distance


func _anger_is_calm() -> bool:
	if fight_target != null and _target_is_defeated(fight_target):
		return true
	if _target_is_monster(fight_target):
		return false
	if _target_is_training_target(fight_target):
		return false
	if machine == null or anger_value_name == &"":
		return false
	if (
		fight_target != null
		and is_instance_valid(fight_target)
		and fight_target.is_in_group("npc")
		and npc != null
		and npc.has_method("get_relationship_anger_for")
	):
		return (
			float(npc.call("get_relationship_anger_for", fight_target, 0.0))
			<= calm_anger_threshold
		)

	return machine.get_value(anger_value_name) <= calm_anger_threshold


func _get_finished_fight_state() -> NpcState:
	if fight_target == null or not _target_is_defeated(fight_target):
		return null
	if (
		(_target_is_monster(fight_target) or fight_target_was_monster)
		and _should_look_for_monster_after_fight()
	):
		return get_state(machine.look_for_monster_state_name)

	return get_state(&"Idle")


func _set_fight_target(new_target: Node2D) -> void:
	fight_target = new_target
	if machine != null:
		machine.select_combat_target(new_target)
		machine.set_action_target(&"Fight", new_target, action_session_id)
	if fight_target != null:
		fight_target_was_monster = _target_is_monster(fight_target)


func _should_look_for_monster_after_fight() -> bool:
	if machine == null or not machine.has_method("should_look_for_monster_after_fight"):
		return false

	return bool(machine.call("should_look_for_monster_after_fight"))


func _should_stop_for_low_health() -> bool:
	if stop_fighting_below_health_percent <= 0.0:
		return false

	return _get_npc_health_percent() < stop_fighting_below_health_percent


func _get_npc_health_percent() -> float:
	var current_hp := 100.0
	if npc != null and npc.has_method("get_hp"):
		current_hp = float(npc.call("get_hp"))
	elif machine != null:
		current_hp = machine.get_value(&"hp", 100.0)

	var max_hp := _get_node_float_property(npc, &"max_hp", 100.0)
	if max_hp <= 0.0:
		max_hp = 100.0

	return (clampf(current_hp, 0.0, max_hp) / max_hp) * 100.0


func _get_target_search_groups() -> Array[StringName]:
	var groups: Array[StringName] = []
	for group_name in target_groups:
		if not groups.has(group_name):
			groups.append(group_name)
	return groups


func _target_is_monster(candidate: Node) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false

	for group_name in monster_target_groups:
		if candidate.is_in_group(String(group_name)):
			return true

	return false


func _target_is_defeated(candidate: Node) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return true

	var dead_value = candidate.get("dead")
	if typeof(dead_value) == TYPE_BOOL and bool(dead_value):
		return true

	var disabled_value = candidate.get("disabled")
	if typeof(disabled_value) == TYPE_BOOL and bool(disabled_value):
		return true

	if candidate.has_method("get_current_health"):
		return float(candidate.call("get_current_health")) <= 0.0

	if candidate.has_method("get_hp"):
		return float(candidate.call("get_hp")) <= 0.0

	var hp_value = candidate.get("hp")
	if typeof(hp_value) == TYPE_FLOAT or typeof(hp_value) == TYPE_INT:
		return float(hp_value) <= 0.0

	return false


func _get_node_float_property(node: Node, property_name: StringName, fallback: float) -> float:
	if node == null:
		return fallback

	for property in node.get_property_list():
		if String(property.get("name", "")) != String(property_name):
			continue
		var value = node.get(property_name)
		if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
			return float(value)
		return fallback

	return fallback


func _target_is_training_target(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false

	for group_name in training_target_groups:
		if candidate.is_in_group(String(group_name)):
			return true

	return false
