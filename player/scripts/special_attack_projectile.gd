class_name PlayerSpecialAttackProjectile extends Area2D

@export var damage: float = 15.0
@export var speed: float = 560.0
@export var lifetime: float = 1.1
@export var collision_radius: float = 17.0
@export var collision_mask_value: int = 129
@export var outer_color: Color = Color(0.25, 0.72, 1.0, 0.85)
@export var inner_color: Color = Color(0.82, 1.0, 1.0, 0.95)
@export var rim_color: Color = Color(0.05, 0.25, 1.0, 0.9)

var source_player: Node
var direction: Vector2 = Vector2.RIGHT
var elapsed: float = 0.0
var launched: bool = false
var has_hit: bool = false


func _ready() -> void:
	collision_layer = 0
	collision_mask = collision_mask_value
	monitoring = true
	monitorable = false

	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)

	_ensure_collision_shape()
	queue_redraw()


func launch(
	from_position: Vector2,
	travel_direction: Vector2,
	attack_source: Node,
	attack_damage: float = 15.0,
	attack_speed: float = 560.0,
	attack_lifetime: float = 1.1,
	attack_radius: float = 17.0,
	attack_collision_mask: int = 129
) -> void:
	source_player = attack_source
	damage = attack_damage
	speed = maxf(attack_speed, 0.0)
	lifetime = maxf(attack_lifetime, 0.01)
	collision_radius = maxf(attack_radius, 1.0)
	collision_mask_value = attack_collision_mask
	collision_mask = collision_mask_value
	direction = travel_direction.normalized()

	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT

	global_position = from_position
	elapsed = 0.0
	launched = true
	has_hit = false

	_ensure_collision_shape()
	queue_redraw()


func get_damage_source() -> Node:
	return source_player if source_player != null else self


func _physics_process(delta: float) -> void:
	if not launched:
		return

	elapsed += delta
	if elapsed >= lifetime:
		queue_free()
		return

	global_position += direction * speed * delta


func _draw() -> void:
	draw_circle(Vector2.ZERO, collision_radius, outer_color)
	draw_circle(Vector2.ZERO, collision_radius * 0.58, inner_color)
	draw_arc(Vector2.ZERO, collision_radius * 0.76, 0.0, TAU, 28, rim_color, 2.0)


func _on_body_entered(body: Node2D) -> void:
	_try_hit(body)


func _on_area_entered(area: Area2D) -> void:
	_try_hit(area)


func _try_hit(hit_node: Node) -> void:
	if has_hit or hit_node == null or not is_instance_valid(hit_node):
		return

	if _is_source_or_child(hit_node):
		return

	if hit_node is Damage_Area:
		has_hit = true
		hit_node.take_damage(self)
		queue_free()
		return

	if hit_node.has_method("take_damage"):
		has_hit = true
		hit_node.call("take_damage", damage, global_position, get_damage_source())
		queue_free()
		return

	if hit_node is PhysicsBody2D:
		has_hit = true
		queue_free()


func _is_source_or_child(node: Node) -> bool:
	var current := node
	while current != null:
		if current == source_player:
			return true

		current = current.get_parent()

	return false


func _ensure_collision_shape() -> void:
	var collision_shape := _get_collision_shape()
	if collision_shape == null:
		collision_shape = CollisionShape2D.new()
		add_child(collision_shape)

	var circle := collision_shape.shape as CircleShape2D
	if circle == null:
		circle = CircleShape2D.new()
		collision_shape.shape = circle

	circle.radius = collision_radius


func _get_collision_shape() -> CollisionShape2D:
	for child in get_children():
		var collision_shape := child as CollisionShape2D
		if collision_shape != null:
			return collision_shape

	return null
