class_name PlayerSpecialAttackBurst extends Area2D

@export var damage: float = 15.0
@export var knockout_damage: float = 0.0
@export var radius: float = 360.0
@export var pulse_count: int = 2
@export var pulse_interval: float = 0.16
@export var lifetime: float = 0.55
@export var collision_mask_value: int = 128
@export var shake_strength: float = 8.0
@export var shake_duration: float = 0.28
@export var shake_step: float = 0.035
@export var particle_amount: int = 56
@export var particle_color: Color = Color(0.55, 0.9, 1.0, 0.9)
@export var ring_color: Color = Color(0.35, 0.75, 1.0, 0.95)

var source_player: Node
var elapsed: float = 0.0
var pulse_timer: float = 0.0
var pulses_done: int = 0
var pulse_visuals: Array[Dictionary] = []
var particles: CPUParticles2D


func _ready() -> void:
	collision_layer = 0
	collision_mask = collision_mask_value
	monitoring = true
	monitorable = false

	_ensure_collision_shape()
	_ensure_particles()


func launch(
	center_position: Vector2,
	attack_source: Node,
	attack_damage: float = 15.0,
	attack_radius: float = 360.0,
	attack_pulse_count: int = 2,
	attack_pulse_interval: float = 0.16,
	attack_lifetime: float = 0.55,
	attack_collision_mask: int = 128,
	attack_shake_strength: float = 8.0,
	attack_shake_duration: float = 0.28,
	attack_knockout_damage: float = 0.0
) -> void:
	source_player = attack_source
	damage = attack_damage
	knockout_damage = maxf(attack_knockout_damage, 0.0)
	radius = maxf(attack_radius, 1.0)
	pulse_count = maxi(attack_pulse_count, 1)
	pulse_interval = maxf(attack_pulse_interval, 0.0)
	lifetime = maxf(attack_lifetime, pulse_interval * float(pulse_count))
	collision_mask_value = attack_collision_mask
	collision_mask = collision_mask_value
	shake_strength = maxf(attack_shake_strength, 0.0)
	shake_duration = maxf(attack_shake_duration, 0.0)

	global_position = center_position
	elapsed = 0.0
	pulse_timer = 0.0
	pulses_done = 0
	pulse_visuals.clear()

	_ensure_collision_shape()
	_ensure_particles()
	_shake_camera()
	_do_pulse()


func get_damage_source() -> Node:
	return source_player if source_player != null else self


func get_knockout_damage() -> float:
	return knockout_damage


func _process(delta: float) -> void:
	elapsed += delta
	_update_pulse_visuals(delta)

	if pulses_done < pulse_count:
		pulse_timer -= delta
		if pulse_timer <= 0.0:
			_do_pulse()

	if elapsed >= lifetime and pulse_visuals.is_empty():
		queue_free()

	queue_redraw()


func _draw() -> void:
	for pulse in pulse_visuals:
		var age := float(pulse.get("age", 0.0))
		var visual_lifetime := float(pulse.get("lifetime", 0.32))
		var progress := clampf(age / maxf(visual_lifetime, 0.001), 0.0, 1.0)
		var alpha := 1.0 - progress
		var ring_radius := lerpf(radius * 0.18, radius, progress)
		var color := ring_color
		color.a *= alpha

		draw_arc(Vector2.ZERO, ring_radius, 0.0, TAU, 64, color, 3.0)
		draw_circle(Vector2.ZERO, ring_radius * 0.35, Color(color.r, color.g, color.b, alpha * 0.08))


func _do_pulse() -> void:
	if pulses_done >= pulse_count:
		return

	pulses_done += 1
	pulse_timer = pulse_interval
	pulse_visuals.append({
		"age": 0.0,
		"lifetime": maxf(pulse_interval * 2.0, 0.28),
	})
	_emit_particles()
	_damage_radius_once()


func _damage_radius_once() -> void:
	if not is_inside_tree():
		return

	var circle := CircleShape2D.new()
	circle.radius = radius

	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = circle
	query.transform = Transform2D(0.0, global_position)
	query.collision_mask = collision_mask_value
	query.collide_with_areas = true
	query.collide_with_bodies = false

	var damaged_victims: Array[Node] = []
	var results := get_world_2d().direct_space_state.intersect_shape(query, 96)
	for result in results:
		var collider := result.get("collider") as Node
		if collider == null or not is_instance_valid(collider):
			continue

		if _is_source_or_child(collider):
			continue

		var victim := _get_hit_victim(collider)
		if victim == null or damaged_victims.has(victim):
			continue

		damaged_victims.append(victim)
		if collider is Damage_Area:
			collider.take_damage(self)
		elif collider.has_method("take_damage"):
			collider.call("take_damage", damage, global_position, get_damage_source(), knockout_damage)


func _get_hit_victim(hit_node: Node) -> Node:
	if hit_node is Damage_Area:
		var victim_owner := hit_node.get_parent()
		if victim_owner != null and victim_owner.has_method("take_damage"):
			return victim_owner

	if hit_node.has_method("take_damage"):
		return hit_node

	return null


func _is_source_or_child(node: Node) -> bool:
	var current := node
	while current != null:
		if current == source_player:
			return true

		current = current.get_parent()

	return false


func _update_pulse_visuals(delta: float) -> void:
	for i in range(pulse_visuals.size() - 1, -1, -1):
		var pulse := pulse_visuals[i]
		pulse["age"] = float(pulse.get("age", 0.0)) + delta
		if float(pulse["age"]) >= float(pulse.get("lifetime", 0.32)):
			pulse_visuals.remove_at(i)
		else:
			pulse_visuals[i] = pulse


func _ensure_collision_shape() -> void:
	var collision_shape := _get_collision_shape()
	if collision_shape == null:
		collision_shape = CollisionShape2D.new()
		add_child(collision_shape)

	var circle := collision_shape.shape as CircleShape2D
	if circle == null:
		circle = CircleShape2D.new()
		collision_shape.shape = circle

	circle.radius = radius


func _get_collision_shape() -> CollisionShape2D:
	for child in get_children():
		var collision_shape := child as CollisionShape2D
		if collision_shape != null:
			return collision_shape

	return null


func _ensure_particles() -> void:
	if particles != null:
		particles.amount = maxi(particle_amount, 1)
		particles.texture = _create_particle_texture()
		return

	particles = CPUParticles2D.new()
	particles.amount = maxi(particle_amount, 1)
	particles.lifetime = 0.36
	particles.one_shot = true
	particles.explosiveness = 0.94
	particles.randomness = 0.35
	particles.direction = Vector2.UP
	particles.spread = 180.0
	particles.gravity = Vector2(0.0, 360.0)
	particles.initial_velocity_min = 90.0
	particles.initial_velocity_max = 300.0
	particles.scale_amount_min = 2.0
	particles.scale_amount_max = 5.0
	particles.color = particle_color
	particles.texture = _create_particle_texture()
	add_child(particles)


func _emit_particles() -> void:
	if particles == null:
		return

	particles.emitting = false
	particles.emitting = true


func _create_particle_texture() -> Texture2D:
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for y in range(8):
		for x in range(8):
			var point := Vector2(float(x) - 3.5, float(y) - 3.5)
			var distance := point.length()
			var alpha := clampf(1.0 - (distance / 4.0), 0.0, 1.0)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))

	return ImageTexture.create_from_image(image)


func _shake_camera() -> void:
	var camera := _get_camera()
	if camera == null or shake_strength <= 0.0 or shake_duration <= 0.0:
		return

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var original_offset := camera.offset
	var step := maxf(shake_step, 0.01)
	var steps := maxi(int(ceil(shake_duration / step)), 1)
	var tween := camera.create_tween()
	for i in range(steps):
		var fade := 1.0 - (float(i) / float(steps))
		var offset := Vector2(
			rng.randf_range(-shake_strength, shake_strength),
			rng.randf_range(-shake_strength, shake_strength)
		) * fade
		tween.tween_property(camera, "offset", original_offset + offset, step)

	tween.tween_property(camera, "offset", original_offset, step)


func _get_camera() -> Camera2D:
	var viewport := get_viewport()
	if viewport != null:
		var current_camera := viewport.get_camera_2d()
		if current_camera != null:
			return current_camera

	if source_player != null and is_instance_valid(source_player):
		for child in source_player.get_children():
			var camera := child as Camera2D
			if camera != null:
				return camera

	return null
