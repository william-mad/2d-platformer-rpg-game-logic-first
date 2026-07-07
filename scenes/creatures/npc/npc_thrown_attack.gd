class_name NpcThrownAttack extends Area2D

signal victim_hit(victim: Node, intended_target_hit: bool)

@export var damage: float = 3.0
@export var knockout_damage: float = 40.0
@export var flight_time: float = 0.65
@export var arc_height: float = 72.0
@export var lifetime: float = 3.0
@export var collision_radius: float = 6.0
@export var collision_mask_value: int = 131
@export var friendly_fire_favor_penalty: float = 5.0
@export var anger_drop_on_intended_target_hit: float = 8.0
@export var visual_color: Color = Color(1.0, 0.35, 0.18, 1.0)

var source_npc: Node
var intended_target: Node
var start_position: Vector2
var target_position: Vector2
var elapsed: float = 0.0
var launched: bool = false
var has_hit: bool = false


func _ready() -> void:
	# Default projectile is built in code so Fight can work without a separate scene.
	collision_layer = 0
	collision_mask = collision_mask_value
	monitoring = true
	monitorable = false

	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)

	_ensure_collision_shape()
	_ensure_visual()


func launch(
	from_position: Vector2,
	to_position: Vector2,
	attack_source: Node,
	attack_damage: float,
	attack_flight_time: float,
	attack_arc_height: float,
	attack_lifetime: float,
	attack_collision_mask: int,
	attack_friendly_fire_penalty: float,
	attack_intended_target: Node = null,
	attack_anger_drop_on_hit: float = 8.0,
	attack_knockout_damage: float = 0.0
) -> void:
	source_npc = attack_source
	intended_target = attack_intended_target
	damage = attack_damage
	knockout_damage = maxf(attack_knockout_damage, 0.0)
	flight_time = maxf(attack_flight_time, 0.001)
	arc_height = maxf(attack_arc_height, 0.0)
	lifetime = maxf(attack_lifetime, flight_time)
	collision_mask_value = attack_collision_mask
	collision_mask = collision_mask_value
	friendly_fire_favor_penalty = maxf(attack_friendly_fire_penalty, 0.0)
	anger_drop_on_intended_target_hit = maxf(attack_anger_drop_on_hit, 0.0)

	start_position = from_position
	target_position = to_position
	global_position = start_position
	elapsed = 0.0
	launched = true


func get_damage_source() -> Node:
	return source_npc if source_npc != null else self


func get_knockout_damage() -> float:
	return knockout_damage


func _physics_process(delta: float) -> void:
	if not launched:
		return

	elapsed += delta
	if elapsed >= lifetime:
		queue_free()
		return

	var progress := clampf(elapsed / maxf(flight_time, 0.001), 0.0, 1.0)
	var arc_offset := Vector2(0.0, -sin(progress * PI) * arc_height)
	global_position = start_position.lerp(target_position, progress) + arc_offset

	if progress >= 1.0:
		queue_free()


func _on_body_entered(body: Node2D) -> void:
	_try_hit(body)


func _on_area_entered(area: Area2D) -> void:
	_try_hit(area)


func _try_hit(hit_node: Node) -> void:
	if has_hit or hit_node == null or not is_instance_valid(hit_node):
		return

	if _is_source_or_child(hit_node):
		return

	var victim := _get_hit_victim(hit_node)
	if victim == null:
		_stop_on_world_hit(hit_node)
		return

	has_hit = true
	if hit_node is Damage_Area:
		hit_node.take_damage(self)
	elif hit_node.has_method("take_damage"):
		hit_node.call("take_damage", damage, global_position, source_npc, knockout_damage)

	_apply_friendly_fire_penalty(victim)
	_apply_anger_hit_relief(victim)
	victim_hit.emit(victim, _is_intended_target(victim))
	queue_free()


func _get_hit_victim(hit_node: Node) -> Node:
	if hit_node is Damage_Area:
		var victim_owner := hit_node.get_parent()
		if victim_owner != null and victim_owner.has_method("take_damage"):
			return victim_owner

	if hit_node.has_method("take_damage"):
		return hit_node

	return null


func _apply_friendly_fire_penalty(victim: Node) -> void:
	if friendly_fire_favor_penalty <= 0.0:
		return
	if source_npc == null or victim == null:
		return
	if not is_instance_valid(source_npc) or not is_instance_valid(victim):
		return
	if source_npc == victim:
		return
	if not source_npc.is_in_group("npc") or not victim.is_in_group("npc"):
		return
	# SocialNpc applies this victim -> attacker penalty in take_damage().
	if victim.has_method("change_relationship_favor_for"):
		return

	var penalty := -absf(friendly_fire_favor_penalty)
	var relationships := get_node_or_null("/root/Relationships")
	if relationships != null and relationships.has_method("change_favor"):
		relationships.call("change_favor", victim, source_npc, penalty, "friendly_fire", {
			"source": "npc_thrown_attack",
			"other_name": source_npc.name,
			"other_path": String(source_npc.get_path()) if source_npc.is_inside_tree() else "",
		})


func _apply_anger_hit_relief(victim: Node) -> void:
	if anger_drop_on_intended_target_hit <= 0.0:
		return
	if _victim_is_training_target(victim):
		return
	if source_npc == null or not is_instance_valid(source_npc):
		return
	if victim == null or not is_instance_valid(victim):
		return
	if intended_target != null and is_instance_valid(intended_target) and victim != intended_target:
		return

	if victim.is_in_group("npc") and source_npc.has_method("change_relationship_anger_for"):
		source_npc.call(
			"change_relationship_anger_for",
			victim,
			-absf(anger_drop_on_intended_target_hit),
			"fight_hit"
		)
		return

	var state_machine := source_npc.get_node_or_null("NpcStateMachine")
	if state_machine != null and state_machine.has_method("apply_value_delta"):
		state_machine.call("apply_value_delta", {"anger": -absf(anger_drop_on_intended_target_hit)}, victim, true)
		return

	if source_npc.has_method("apply_social_event"):
		source_npc.call("apply_social_event", {"anger": -absf(anger_drop_on_intended_target_hit)}, victim, false)


func _victim_is_training_target(victim: Node) -> bool:
	return (
		victim != null
		and is_instance_valid(victim)
		and (
			victim.is_in_group("training_dummy")
			or victim.is_in_group("attack_target")
		)
	)


func _is_intended_target(victim: Node) -> bool:
	return (
		intended_target != null
		and is_instance_valid(intended_target)
		and victim == intended_target
	)


func _stop_on_world_hit(hit_node: Node) -> void:
	if hit_node is PhysicsBody2D:
		has_hit = true
		queue_free()


func _is_source_or_child(node: Node) -> bool:
	var current := node
	while current != null:
		if current == source_npc:
			return true
		current = current.get_parent()

	return false


func _ensure_collision_shape() -> void:
	for child in get_children():
		if child is CollisionShape2D:
			return

	var shape := CircleShape2D.new()
	shape.radius = maxf(collision_radius, 1.0)

	var collision_shape := CollisionShape2D.new()
	collision_shape.shape = shape
	add_child(collision_shape)


func _ensure_visual() -> void:
	for child in get_children():
		if child is Polygon2D:
			return

	var visual := Polygon2D.new()
	visual.color = visual_color
	visual.polygon = PackedVector2Array([
		Vector2(0.0, -6.0),
		Vector2(7.0, 0.0),
		Vector2(0.0, 6.0),
		Vector2(-7.0, 0.0)
	])
	add_child(visual)
