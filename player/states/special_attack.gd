class_name PlayerSpecialAttack extends PlayerState

const SPECIAL_ATTACK_PROJECTILE_SCRIPT := preload("res://player/scripts/special_attack_projectile.gd")
const SPECIAL_ATTACK_WALL_SCRIPT := preload("res://player/scripts/special_attack_wall.gd")
const SPECIAL_ATTACK_BURST_SCRIPT := preload("res://player/scripts/special_attack_burst.gd")

enum Tier3Phase {
	NONE,
	SLAM,
	WINDUP,
	RECOVERY
}

@export var attack_tier: int = 1
@export var attack_duration: float = 0.45
@export var hitbox_duration: float = 0.16
@export var move_speed_multiplier: float = 0.25
@export_group("Tier 1 Projectile")
@export var tier_1_windup: float = 0.18
@export var tier_1_damage: float = 15.0
@export var tier_1_knockout_damage: float = 0.0
@export var tier_1_projectile_speed: float = 560.0
@export var tier_1_projectile_lifetime: float = 1.1
@export var tier_1_projectile_radius: float = 17.0
@export var tier_1_projectile_collision_mask: int = 129
@export var tier_1_spawn_offset: Vector2 = Vector2(30.0, -45.0)
@export_group("Tier 2 Wall")
@export var tier_2_windup: float = 0.2
@export var tier_2_damage: float = 25.0
@export var tier_2_knockout_damage: float = 0.0
@export var tier_2_wall_speed: float = 320.0
@export var tier_2_wall_lifetime: float = 0.9
@export var tier_2_wall_grow_time: float = 0.35
@export var tier_2_wall_start_size: Vector2 = Vector2(17.0, 35.0)
@export var tier_2_wall_final_size: Vector2 = Vector2(68.0, 140.0)
@export var tier_2_wall_push_speed: float = 460.0
@export var tier_2_wall_collision_mask: int = 129
@export var tier_2_wall_spawn_offset: Vector2 = Vector2(28.0, 0.0)
@export_group("Tier 3 Burst")
@export var tier_3_ground_windup: float = 0.24
@export var tier_3_recovery_time: float = 0.38
@export var tier_3_air_slam_speed: float = 1500.0
@export var tier_3_damage: float = 15.0
@export var tier_3_knockout_damage: float = 0.0
@export var tier_3_radius: float = 360.0
@export var tier_3_pulse_count: int = 2
@export var tier_3_pulse_interval: float = 0.16
@export var tier_3_effect_lifetime: float = 0.58
@export var tier_3_collision_mask: int = 128
@export var tier_3_screen_shake_strength: float = 8.0
@export var tier_3_screen_shake_duration: float = 0.28

var attack_timer: float = 0.0
var windup_timer: float = 0.0
var special_effect_spawned: bool = false
var tier_3_phase: Tier3Phase = Tier3Phase.NONE
var tier_3_timer: float = 0.0


func init() -> void:
	pass


func enter() -> void:
	tier_3_phase = Tier3Phase.NONE
	tier_3_timer = 0.0
	if attack_tier == 3:
		setup_tier_3_attack()
		next_state = null
		return

	attack_timer = attack_duration
	var current_windup := get_current_windup()
	if attack_tier == 1 or attack_tier == 2:
		attack_timer = maxf(attack_timer, current_windup + 0.08)

	windup_timer = current_windup
	special_effect_spawned = false
	next_state = null
	do_special_attack()


func exit() -> void:
	pass


func handle_input(_event: InputEvent) -> PlayerState:
	return null


func process(delta: float) -> PlayerState:
	if attack_tier == 3:
		return process_tier_3(delta)

	if (attack_tier == 1 or attack_tier == 2) and not special_effect_spawned:
		windup_timer -= delta
		if windup_timer <= 0.0:
			spawn_special_effect()

	attack_timer -= delta

	if attack_timer > 0.0:
		return null

	if player.is_on_floor():
		return idle

	return fall


func physics_process(_delta: float) -> PlayerState:
	if attack_tier == 3:
		return physics_process_tier_3()

	player.velocity.x = player.direction.x * player.get_run_speed() * move_speed_multiplier
	return null


func do_special_attack() -> void:
	match attack_tier:
		1:
			player.animation_player.play("attack_1")
		2:
			player.animation_player.play("attack_2")
		3:
			player.animation_player.play("attack_3")
		_:
			player.animation_player.play("attack_1")


func get_current_windup() -> float:
	match attack_tier:
		1:
			return maxf(tier_1_windup, 0.0)
		2:
			return maxf(tier_2_windup, 0.0)
		_:
			return 0.0


func spawn_special_effect() -> void:
	special_effect_spawned = true
	match attack_tier:
		1:
			spawn_tier_1_projectile()
		2:
			spawn_tier_2_wall()


func setup_tier_3_attack() -> void:
	attack_timer = 0.0
	windup_timer = 0.0
	special_effect_spawned = false
	if player.is_on_floor():
		begin_tier_3_ground_windup()
		return

	tier_3_phase = Tier3Phase.SLAM
	player.velocity.x = 0.0
	player.velocity.y = maxf(player.velocity.y, tier_3_air_slam_speed)
	player.animation_player.play("jump")


func begin_tier_3_ground_windup() -> void:
	tier_3_phase = Tier3Phase.WINDUP
	tier_3_timer = maxf(tier_3_ground_windup, 0.0)
	player.velocity.x = 0.0
	player.animation_player.play("attack_3")


func process_tier_3(delta: float) -> PlayerState:
	match tier_3_phase:
		Tier3Phase.SLAM:
			if player.is_on_floor():
				begin_tier_3_ground_windup()
			return null
		Tier3Phase.WINDUP:
			tier_3_timer -= delta
			if tier_3_timer <= 0.0 and not special_effect_spawned:
				spawn_tier_3_burst()
				tier_3_phase = Tier3Phase.RECOVERY
				tier_3_timer = maxf(tier_3_recovery_time, 0.0)
			return null
		Tier3Phase.RECOVERY:
			tier_3_timer -= delta
			if tier_3_timer > 0.0:
				return null

			if player.is_on_floor():
				return idle

			return fall

	return null


func physics_process_tier_3() -> PlayerState:
	match tier_3_phase:
		Tier3Phase.SLAM:
			player.velocity.x = 0.0
			if not player.is_on_floor():
				player.velocity.y = maxf(player.velocity.y, tier_3_air_slam_speed)
		Tier3Phase.WINDUP, Tier3Phase.RECOVERY:
			player.velocity.x = 0.0

	return null


func spawn_tier_1_projectile() -> void:
	if player == null or not player.is_inside_tree():
		return

	var facing_x := get_facing_x()
	var projectile := SPECIAL_ATTACK_PROJECTILE_SCRIPT.new()
	var parent := get_projectile_parent()
	parent.add_child(projectile)
	projectile.launch(
		player.global_position + Vector2(tier_1_spawn_offset.x * facing_x, tier_1_spawn_offset.y),
		Vector2(facing_x, 0.0),
		player,
		player.get_scaled_attack_damage(tier_1_damage),
		tier_1_projectile_speed,
		tier_1_projectile_lifetime,
		tier_1_projectile_radius,
		tier_1_projectile_collision_mask,
		tier_1_knockout_damage
	)


func spawn_tier_2_wall() -> void:
	if player == null or not player.is_inside_tree():
		return

	var facing_x := get_facing_x()
	var wall := SPECIAL_ATTACK_WALL_SCRIPT.new()
	var parent := get_projectile_parent()
	parent.add_child(wall)
	wall.launch(
		player.global_position + Vector2(tier_2_wall_spawn_offset.x * facing_x, tier_2_wall_spawn_offset.y),
		Vector2(facing_x, 0.0),
		player,
		player.get_scaled_attack_damage(tier_2_damage),
		tier_2_wall_speed,
		tier_2_wall_lifetime,
		tier_2_wall_grow_time,
		tier_2_wall_start_size,
		tier_2_wall_final_size,
		tier_2_wall_push_speed,
		tier_2_wall_collision_mask,
		tier_2_knockout_damage
	)


func spawn_tier_3_burst() -> void:
	special_effect_spawned = true
	if player == null or not player.is_inside_tree():
		return

	var burst := SPECIAL_ATTACK_BURST_SCRIPT.new()
	var parent := get_projectile_parent()
	parent.add_child(burst)
	burst.launch(
		player.global_position,
		player,
		player.get_scaled_attack_damage(tier_3_damage),
		tier_3_radius,
		tier_3_pulse_count,
		tier_3_pulse_interval,
		tier_3_effect_lifetime,
		tier_3_collision_mask,
		tier_3_screen_shake_strength,
		tier_3_screen_shake_duration,
		tier_3_knockout_damage
	)


func get_facing_x() -> float:
	return -1.0 if player.sprite_2d.flip_h else 1.0


func get_projectile_parent() -> Node:
	if player.get_tree().current_scene != null:
		return player.get_tree().current_scene

	if player.get_parent() != null:
		return player.get_parent()

	return player
