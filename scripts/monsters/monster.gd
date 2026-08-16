class_name Monster
extends CharacterBody2D

signal died(monster)
signal death_drop_requested(monster)

@export_group("Identity")
@export var monster_groups: Array[StringName] = [&"monster", &"monsters", &"enemy", &"enemies"]
@export var target_groups: Array[StringName] = [&"player", &"npc"]

@export_group("Health")
@export var max_hp: float = 8.0
@export var knockback_force: Vector2 = Vector2(150.0, -120.0)
@export var knockback_time: float = 0.14

@export_group("Touch Damage")
@export var touch_damage_enabled: bool = true
@export var touch_damage: float = 1.0
@export var touch_knockout_damage: float = 10.0
@export var touch_damage_interval_seconds: float = 0.8

@export_group("Death")
@export var request_item_drop_on_death: bool = false
@export var progression_kill_reward_id: StringName = &""

@export_group("Rope")
@export_range(0.01, 1000.0, 0.01) var rope_weight: float = 2.0

@onready var body_collision: CollisionShape2D = get_node_or_null("CollisionShape2D") as CollisionShape2D
@onready var damage_area: Area2D = get_node_or_null("Damage_Area") as Area2D
@onready var touch_damage_area: Area2D = get_node_or_null("TouchDamageArea") as Area2D
@onready var hp_bar: CreatureHpBar = get_node_or_null("HPBar") as CreatureHpBar
@onready var inventory_component: NpcInventoryComponent = get_node_or_null("NpcInventory") as NpcInventoryComponent
@onready var inventory_drop_component: NpcInventoryDropComponent = get_node_or_null("NpcInventoryDrop") as NpcInventoryDropComponent
@onready var monster_loot_component: MonsterLootComponent = get_node_or_null("MonsterLoot") as MonsterLootComponent
@onready var rope_attach_point: Marker2D = get_node_or_null("RopeAttachPoint") as Marker2D

var hp: float = 0.0
var dead: bool = false
var knockback_timer: float = 0.0
var last_damage_source: Node
var last_damage_tags: Array[StringName] = []

var _touch_damage_cooldowns: Dictionary = {}


func _ready() -> void:
	hp = maxf(max_hp, 1.0)
	for group_name in monster_groups:
		var group_text := String(group_name)
		if not group_text.is_empty():
			add_to_group(group_text)

	add_to_group(&"attack_target")
	_setup_hp_bar()
	if monster_loot_component != null:
		monster_loot_component.initialize_loot_once()


func take_damage(
	amount: float,
	damage_source_position: Vector2 = Vector2.ZERO,
	damage_source: Node = null,
	knockout_damage: float = 0.0
) -> void:
	if dead or amount <= 0.0:
		return

	var previous_hp := hp
	hp = maxf(hp - amount, 0.0)
	var damage_taken := previous_hp - hp
	last_damage_source = damage_source
	_emit_damage_dealt(damage_taken, damage_source, self)
	_update_hp_bar()

	if hp <= 0.0:
		die()
		return

	_on_damaged(damage_taken, damage_source_position, damage_source, knockout_damage)


func die() -> void:
	if dead:
		return

	Rope.detach_all_from_body(self)
	dead = true
	hp = 0.0
	velocity = Vector2.ZERO
	knockback_timer = 0.0
	_disable_hitboxes()
	_update_hp_bar()
	if inventory_drop_component != null and not inventory_drop_component.drop_inventory_on_death():
		push_warning("Monster '%s' died but its inventory drop could not be completed." % name)
	_on_died()
	died.emit(self)
	_award_progression_on_death()

	if request_item_drop_on_death:
		death_drop_requested.emit(self)


func heal(amount: float) -> void:
	if dead or amount <= 0.0:
		return

	hp = minf(hp + amount, max_hp)
	_update_hp_bar()


func get_current_health() -> float:
	return hp


func get_inventory() -> InventoryModel:
	if inventory_component == null:
		return null
	return inventory_component.get_inventory()


func get_loot_source_id() -> StringName:
	return StringName("monster:%s" % get_instance_id())


func set_last_damage_tags(tags: Array[StringName]) -> void:
	last_damage_tags = tags.duplicate()


func get_last_damage_tags() -> Array[StringName]:
	return last_damage_tags.duplicate()


func get_attack_aim_position() -> Vector2:
	if body_collision != null and not body_collision.disabled:
		return body_collision.global_position

	return global_position


func get_rope_attach_point() -> Node2D:
	return rope_attach_point if rope_attach_point != null else self


func apply_knockback_from(damage_source_position: Vector2) -> void:
	var knockback_direction := signf(global_position.x - damage_source_position.x)
	if is_zero_approx(knockback_direction):
		knockback_direction = 1.0

	velocity = Vector2(knockback_force.x * knockback_direction, knockback_force.y)
	knockback_timer = maxf(knockback_time, 0.0)


func apply_gravity(delta: float, gravity_value: float) -> void:
	if not is_on_floor():
		velocity.y += gravity_value * delta
	elif velocity.y > 0.0:
		velocity.y = 0.0


func process_touch_damage(delta: float) -> void:
	_tick_touch_damage_cooldowns(delta)
	if dead or not touch_damage_enabled or touch_damage <= 0.0:
		return
	if touch_damage_area == null or not touch_damage_area.monitoring:
		return

	for body in touch_damage_area.get_overlapping_bodies():
		_try_touch_damage(body)

	for area in touch_damage_area.get_overlapping_areas():
		_try_touch_damage(area)


func get_closest_target(max_distance: float = INF) -> Node2D:
	if not is_inside_tree():
		return null

	var closest_target: Node2D = null
	var closest_distance_squared := INF
	var max_distance_squared := max_distance * max_distance

	for group_name in target_groups:
		for candidate in get_tree().get_nodes_in_group(String(group_name)):
			var candidate_node := candidate as Node2D
			if not _is_valid_combat_target(candidate_node):
				continue

			var distance_squared := global_position.distance_squared_to(candidate_node.global_position)
			if distance_squared > max_distance_squared or distance_squared >= closest_distance_squared:
				continue

			closest_distance_squared = distance_squared
			closest_target = candidate_node

	return closest_target


func is_valid_target(candidate: Node2D) -> bool:
	return _is_valid_combat_target(candidate)


func _setup_hp_bar() -> void:
	if hp_bar == null:
		return

	hp_bar.setup_hp(max_hp, hp)


func _update_hp_bar() -> void:
	if hp_bar == null:
		return

	hp_bar.set_hp(hp)


func _emit_damage_dealt(amount: float, attacker: Node, target: Node) -> void:
	if amount <= 0.0:
		return

	var damage_events := get_node_or_null("/root/DamageEvents")
	if damage_events != null and damage_events.has_method("emit_damage_dealt"):
		damage_events.call("emit_damage_dealt", amount, attacker, target)


func _tick_touch_damage_cooldowns(delta: float) -> void:
	for key in _touch_damage_cooldowns.keys():
		var remaining := maxf(float(_touch_damage_cooldowns[key]) - delta, 0.0)
		if remaining <= 0.0:
			_touch_damage_cooldowns.erase(key)
		else:
			_touch_damage_cooldowns[key] = remaining


func _try_touch_damage(hit_node: Node) -> void:
	var target := _resolve_touch_damage_target(hit_node)
	if not _is_valid_combat_target(target):
		return

	var target_key := target.get_instance_id()
	if float(_touch_damage_cooldowns.get(target_key, 0.0)) > 0.0:
		return

	target.call("take_damage", touch_damage, global_position, self, touch_knockout_damage)
	_touch_damage_cooldowns[target_key] = maxf(touch_damage_interval_seconds, 0.05)
	_on_touch_damage_dealt(target)


func _resolve_touch_damage_target(hit_node: Node) -> Node2D:
	if hit_node == null or not is_instance_valid(hit_node):
		return null
	if _is_self_or_child(hit_node):
		return null

	if hit_node is Damage_Area:
		var damage_owner := hit_node.get_parent() as Node2D
		if damage_owner != null and damage_owner.has_method("take_damage"):
			return damage_owner

	var hit_node_2d := hit_node as Node2D
	if hit_node_2d != null and hit_node_2d.has_method("take_damage"):
		return hit_node_2d

	var parent := hit_node.get_parent() as Node2D
	if parent != null and parent.has_method("take_damage"):
		return parent

	return null


func _is_valid_combat_target(candidate: Node2D) -> bool:
	if candidate == null or not is_instance_valid(candidate):
		return false
	if candidate == self or _is_self_or_child(candidate):
		return false
	if not candidate.has_method("take_damage"):
		return false
	if _candidate_is_dead(candidate):
		return false
	if not _candidate_allows_monster_targeting(candidate):
		return false
	if candidate.is_in_group("monster") and not _target_groups_include_monsters():
		return false

	return _candidate_matches_target_groups(candidate)


func _candidate_matches_target_groups(candidate: Node) -> bool:
	if target_groups.is_empty():
		return true

	for group_name in target_groups:
		if candidate.is_in_group(String(group_name)):
			return true

	return false


func _target_groups_include_monsters() -> bool:
	for group_name in target_groups:
		var group_text := String(group_name)
		if group_text == "monster" or group_text == "monsters":
			return true

	return false


func _candidate_allows_monster_targeting(candidate: Node2D) -> bool:
	if candidate.has_method("can_be_targeted_by_monster"):
		return bool(candidate.call("can_be_targeted_by_monster"))
	if candidate.has_method("is_hidden_from_monsters"):
		return not bool(candidate.call("is_hidden_from_monsters"))

	return not bool(candidate.get_meta("hidden_from_monsters", false))


func _candidate_is_dead(candidate: Node) -> bool:
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


func _is_self_or_child(node: Node) -> bool:
	var current := node
	while current != null:
		if current == self:
			return true
		current = current.get_parent()

	return false


func _disable_hitboxes() -> void:
	touch_damage_enabled = false
	_set_area_enabled(damage_area, false)
	_set_area_enabled(touch_damage_area, false)
	if body_collision != null:
		body_collision.set_deferred("disabled", true)

	collision_layer = 0
	collision_mask = 0


func _set_area_enabled(area: Area2D, enabled: bool) -> void:
	if area == null:
		return

	area.set_deferred("monitoring", enabled)
	area.set_deferred("monitorable", enabled)
	for child in area.get_children():
		var shape := child as CollisionShape2D
		if shape != null:
			shape.set_deferred("disabled", not enabled)


func _on_damaged(
	_damage_taken: float,
	damage_source_position: Vector2,
	_damage_source: Node,
	_knockout_damage: float
) -> void:
	apply_knockback_from(damage_source_position)


func _on_touch_damage_dealt(_target: Node2D) -> void:
	pass


func _on_died() -> void:
	pass


func _award_progression_on_death() -> void:
	if not _last_damage_source_is_player():
		return

	var reward_id := _get_progression_kill_reward_id()
	if reward_id == &"":
		return

	var progression := get_node_or_null("/root/ProgressionSystem")
	if progression == null or not progression.has_method("award_reward"):
		return

	progression.call("award_reward", reward_id, {
		"monster": name,
		"monster_groups": _stringify_string_names(monster_groups),
		"attack_tags": _stringify_string_names(last_damage_tags),
	})


func _get_progression_kill_reward_id() -> StringName:
	if progression_kill_reward_id != &"":
		return progression_kill_reward_id
	if is_in_group("slime"):
		return &"enemy_kill.slime"

	return &""


func _last_damage_source_is_player() -> bool:
	if last_damage_source == null or not is_instance_valid(last_damage_source):
		return false

	return last_damage_source.is_in_group("player")


func _stringify_string_names(values: Array) -> Array[String]:
	var strings: Array[String] = []
	for value in values:
		strings.append(String(value))
	return strings
