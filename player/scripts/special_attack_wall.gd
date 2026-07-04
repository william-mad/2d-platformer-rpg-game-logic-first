class_name PlayerSpecialAttackWall extends Area2D

@export var damage: float = 25.0
@export var knockout_damage: float = 0.0
@export var speed: float = 320.0
@export var lifetime: float = 0.9
@export var grow_time: float = 0.35
@export var start_size: Vector2 = Vector2(17.0, 35.0)
@export var final_size: Vector2 = Vector2(68.0, 140.0)
@export var push_speed: float = 460.0
@export var collision_mask_value: int = 129
@export var fill_color: Color = Color(0.25, 0.9, 0.72, 0.45)
@export var core_color: Color = Color(0.75, 1.0, 0.92, 0.32)
@export var edge_color: Color = Color(0.03, 0.45, 0.32, 0.9)

var source_player: Node
var direction: Vector2 = Vector2.RIGHT
var elapsed: float = 0.0
var launched: bool = false
var current_size: Vector2 = start_size
var damaged_victims: Array[Node] = []


func _ready() -> void:
	collision_layer = 0
	collision_mask = collision_mask_value
	monitoring = true
	monitorable = false

	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)

	_update_wall_shape()
	queue_redraw()


func launch(
	from_position: Vector2,
	travel_direction: Vector2,
	attack_source: Node,
	attack_damage: float = 25.0,
	attack_speed: float = 320.0,
	attack_lifetime: float = 0.9,
	attack_grow_time: float = 0.35,
	attack_start_size: Vector2 = Vector2(17.0, 35.0),
	attack_final_size: Vector2 = Vector2(68.0, 140.0),
	attack_push_speed: float = 460.0,
	attack_collision_mask: int = 129,
	attack_knockout_damage: float = 0.0
) -> void:
	source_player = attack_source
	damage = attack_damage
	knockout_damage = maxf(attack_knockout_damage, 0.0)
	speed = maxf(attack_speed, 0.0)
	lifetime = maxf(attack_lifetime, 0.01)
	grow_time = maxf(attack_grow_time, 0.0)
	start_size = _sanitize_size(attack_start_size)
	final_size = _sanitize_size(attack_final_size)
	push_speed = maxf(attack_push_speed, 0.0)
	collision_mask_value = attack_collision_mask
	collision_mask = collision_mask_value
	direction = travel_direction.normalized()

	if is_zero_approx(direction.x):
		direction = Vector2.RIGHT
	else:
		direction = Vector2(signf(direction.x), 0.0)

	global_position = from_position
	elapsed = 0.0
	launched = true
	current_size = start_size
	damaged_victims.clear()

	_update_wall_shape()
	queue_redraw()


func get_damage_source() -> Node:
	return source_player if source_player != null else self


func get_knockout_damage() -> float:
	return knockout_damage


func _physics_process(delta: float) -> void:
	if not launched:
		return

	elapsed += delta
	if elapsed >= lifetime:
		queue_free()
		return

	_update_growth()
	global_position += direction * speed * delta
	_push_overlapping_victims()


func _draw() -> void:
	var rect := _get_wall_rect()
	draw_rect(rect, fill_color, true)
	draw_rect(_get_inner_rect(rect), core_color, true)
	draw_rect(rect, edge_color, false, 2.0)


func _on_body_entered(body: Node2D) -> void:
	_try_hit(body)


func _on_area_entered(area: Area2D) -> void:
	_try_hit(area)


func _try_hit(hit_node: Node) -> void:
	if hit_node == null or not is_instance_valid(hit_node):
		return

	if _is_source_or_child(hit_node):
		return

	var victim := _get_hit_victim(hit_node)
	if victim == null:
		_stop_on_world_hit(hit_node)
		return

	_push_victim(victim)
	if damaged_victims.has(victim):
		return

	damaged_victims.append(victim)
	if hit_node is Damage_Area:
		hit_node.take_damage(self)
	elif hit_node.has_method("take_damage"):
		hit_node.call("take_damage", damage, global_position, get_damage_source(), knockout_damage)


func _get_hit_victim(hit_node: Node) -> Node:
	if hit_node is Damage_Area:
		var victim_owner := hit_node.get_parent()
		if victim_owner != null and victim_owner.has_method("take_damage"):
			return victim_owner

	if hit_node.has_method("take_damage"):
		return hit_node

	return null


func _push_overlapping_victims() -> void:
	for area in get_overlapping_areas():
		if area == null or not is_instance_valid(area):
			continue

		if _is_source_or_child(area):
			continue

		var victim := _get_hit_victim(area)
		if victim != null:
			_push_victim(victim)


func _push_victim(victim: Node) -> void:
	var character := victim as CharacterBody2D
	if character == null or not is_instance_valid(character):
		return

	var pushed_velocity := character.velocity
	var target_x := direction.x * push_speed
	if direction.x > 0.0:
		pushed_velocity.x = maxf(pushed_velocity.x, target_x)
	else:
		pushed_velocity.x = minf(pushed_velocity.x, target_x)

	character.velocity = pushed_velocity


func _stop_on_world_hit(hit_node: Node) -> void:
	if hit_node is PhysicsBody2D:
		queue_free()


func _is_source_or_child(node: Node) -> bool:
	var current := node
	while current != null:
		if current == source_player:
			return true

		current = current.get_parent()

	return false


func _update_growth() -> void:
	var growth_progress := 1.0
	if grow_time > 0.0:
		growth_progress = clampf(elapsed / grow_time, 0.0, 1.0)

	current_size = start_size.lerp(final_size, growth_progress)
	_update_wall_shape()
	queue_redraw()


func _update_wall_shape() -> void:
	current_size = _sanitize_size(current_size)
	var collision_shape := _get_collision_shape()
	if collision_shape == null:
		collision_shape = CollisionShape2D.new()
		add_child(collision_shape)

	var rectangle := collision_shape.shape as RectangleShape2D
	if rectangle == null:
		rectangle = RectangleShape2D.new()
		collision_shape.shape = rectangle

	rectangle.size = current_size
	collision_shape.position = Vector2(current_size.x * 0.5 * direction.x, -current_size.y * 0.5)


func _get_collision_shape() -> CollisionShape2D:
	for child in get_children():
		var collision_shape := child as CollisionShape2D
		if collision_shape != null:
			return collision_shape

	return null


func _get_wall_rect() -> Rect2:
	if direction.x < 0.0:
		return Rect2(Vector2(-current_size.x, -current_size.y), current_size)

	return Rect2(Vector2(0.0, -current_size.y), current_size)


func _get_inner_rect(rect: Rect2) -> Rect2:
	var inset := Vector2(
		minf(rect.size.x * 0.2, 10.0),
		minf(rect.size.y * 0.12, 14.0)
	)
	return Rect2(rect.position + inset, rect.size - (inset * 2.0))


func _sanitize_size(size: Vector2) -> Vector2:
	return Vector2(maxf(size.x, 1.0), maxf(size.y, 1.0))
