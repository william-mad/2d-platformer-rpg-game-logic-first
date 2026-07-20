class_name PlayerAttackHitbox
extends Area2D

const CombatLayers := preload("res://scripts/systems/combat_layers.gd")

var damage: float = 0.0
var knockout_damage: float = 0.0
var source_player: Node
var active_definition: AttackDefinition
var damaged_victims: Array[Node] = []
var activation_serial: int = 0


func _ready() -> void:
	CombatLayers.mark_attack_spell(self)
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	visible = false
	monitorable = false
	monitoring = false
	_ensure_collision_shape()


func activate(definition: AttackDefinition, attack_source: Node, facing_x: float) -> void:
	cancel()
	if definition == null:
		return

	activation_serial += 1
	var current_serial := activation_serial
	active_definition = definition
	source_player = attack_source
	var equipment_modifiers: Dictionary = {}
	if attack_source != null and attack_source.has_method("get_attack_equipment_modifiers"):
		var returned_modifiers = attack_source.call("get_attack_equipment_modifiers", definition)
		if returned_modifiers is Dictionary:
			equipment_modifiers = returned_modifiers
	var damage_multiplier := _validated_multiplier(
		equipment_modifiers.get("damage_multiplier", 1.0)
	)
	var knockout_multiplier := _validated_multiplier(
		equipment_modifiers.get("knockout_multiplier", 1.0)
	)
	damage = definition.damage * damage_multiplier
	knockout_damage = maxf(definition.knockout_damage, 0.0) * knockout_multiplier
	collision_mask = definition.collision_mask
	damaged_victims.clear()
	_apply_definition_shape(definition, facing_x)
	_apply_definition_tags(definition)
	set_active(true)

	await get_tree().create_timer(maxf(definition.active_seconds, 0.0)).timeout
	if current_serial == activation_serial:
		_deactivate()


func cancel() -> void:
	activation_serial += 1
	_deactivate()


func set_active(value: bool = true) -> void:
	monitoring = value
	visible = value


func _deactivate() -> void:
	set_active(false)
	damaged_victims.clear()
	active_definition = null
	source_player = null
	damage = 0.0
	knockout_damage = 0.0


func get_damage_source() -> Node:
	if source_player != null and is_instance_valid(source_player):
		return source_player

	var damage_source := get_parent()
	return damage_source if damage_source != null else self


func get_knockout_damage() -> float:
	return knockout_damage


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
	if victim != null:
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


func _is_source_or_child(node: Node) -> bool:
	var current := node
	while current != null:
		if current == source_player:
			return true
		current = current.get_parent()

	return false


func _apply_definition_shape(definition: AttackDefinition, facing_x: float) -> void:
	var collision_shape := _ensure_collision_shape()
	var rectangle := collision_shape.shape as RectangleShape2D
	if rectangle == null:
		rectangle = RectangleShape2D.new()
		collision_shape.shape = rectangle

	rectangle.size = Vector2(maxf(definition.hitbox_size.x, 1.0), maxf(definition.hitbox_size.y, 1.0))
	var direction_x := -1.0 if facing_x < 0.0 else 1.0
	collision_shape.position = Vector2(absf(definition.hitbox_offset.x) * direction_x, definition.hitbox_offset.y)


func _apply_definition_tags(definition: AttackDefinition) -> void:
	if definition.tags.is_empty():
		if has_meta("progression_tags"):
			remove_meta("progression_tags")
		return

	set_meta("progression_tags", definition.tags)


func _ensure_collision_shape() -> CollisionShape2D:
	for child in get_children():
		var existing_collision_shape := child as CollisionShape2D
		if existing_collision_shape != null:
			return existing_collision_shape

	var new_collision_shape := CollisionShape2D.new()
	add_child(new_collision_shape)
	return new_collision_shape


func _validated_multiplier(value: Variant) -> float:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return 1.0
	var multiplier := float(value)
	return multiplier if is_finite(multiplier) and multiplier >= 0.0 else 1.0
