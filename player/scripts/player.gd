class_name Player extends CharacterBody2D

# Emitted when hp hits 0. GameOverScreen (autoload) listens and shows the game-over flow.
signal player_defeated

#region //onready variables:
@onready var sprite_2d: Sprite2D = $Sprite2D
@onready var colider_stand: CollisionShape2D = $colider_stand
@onready var colider_crouch: CollisionShape2D = $colider_crouch
@onready var ongrounddetection: RayCast2D = $ongrounddetection
@onready var small_platform_detection: RayCast2D = $"small platform detection"
@onready var ledgegrabcolider: CollisionShape2D = %ledgegrabcolider
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var attack_1: Attack_1 = %Attack_1
@onready var attack_2: Attack_2 = %Attack_2
@onready var attack_3: Attack_3 = %Attack_3
@onready var ledgedetec: RayCast2D = %ledgedetec

#endregion


#region //rope mechanics:
@onready var rope: Rope = $rope
@onready var rope_detector: Area2D = %RopeDetector
@onready var rope_origin: Marker2D = %RopeOrigin
#endregion

#region //export variables
@export var move_speed : float = 700
@export var knockback_force: Vector2 = Vector2(220, -160)
@export var knockback_time: float = 0.15
@export_group("Knockout")
@export var max_knockout: float = 100.0
@export var knockout_decay_per_second: float = 55.0
@export var downed_decay_per_second: float = 32.0
#endregion

#region //playerstats:
@export var max_hp : float = 20
@export_range(1.0, 100.0, 0.1, "suffix:hp/day") var passive_healing_per_game_day: float = 10.0
var hp : float = 20
var mana_charge_rate : float = 100
var max_mana : float = 300
var mana_amount: float = 0.0
@export var mana_2_starts_full: bool = true
@export var mana_2_charge_rate: float = 50.0
var mana_2_amount: float = 0.0
@export_group("Needs")
@export var player_needs_enabled: bool = true
@export_range(0.0, 100.0, 0.1) var hunger: float = 20.0
@export_range(0.0, 100.0, 0.1) var sleep_need: float = 10.0
@export_range(0.0, 100.0, 0.1, "suffix:/h") var hunger_growth_per_game_hour: float = 7.0
@export_range(0.0, 100.0, 0.1, "suffix:/h") var sleep_need_growth_per_game_hour: float = 5.1
var dash: bool = false
var double_jump: bool = false
var ground_slam: bool = false
var transformation: bool = false
# Set to true once hp reaches 0 so the player stops acting and take_damage becomes a no-op.
var dead: bool = false
var knockout_amount: float = 0.0
var knockout_active: bool = false
var is_downed: bool = false
var active_spot_action: StringName = &""
var active_spot: Node
#endregion

#region //save system:
@export var save_id: String = "player"
# Add variable names here in the Inspector when a new simple player value should save automatically.
@export var extra_saved_value_names: Array[StringName] = []
#endregion





#state machine variables
var states : Array[ PlayerState ]
var current_state : PlayerState : 
	get : return states.front()
var previous_state : PlayerState:
	get : return states [ 1 ]

#standard variables
var direction : Vector2 = Vector2.ZERO
var gravity : float = 1500.0
var gravity_multiplier : float = 1.0
var nearby_attachables: Array[Node2D] = []
var current_rope_target: Node2D = null
var knockback_timer: float = 0.0

func _ready() -> void:
	add_to_group(&"saveable")
	rope_detector.body_entered.connect(_on_rope_detector_body_entered)
	rope_detector.body_exited.connect(_on_rope_detector_body_exited)
	PlayerHud.visible = true
	hp = max_hp
	knockout_amount = 0.0
	knockout_active = false
	is_downed = false
	mana_amount = 0.0
	mana_2_amount = max_mana if mana_2_starts_full else 0.0
	sync_stats_to_hud()
	#initialize states
	initialize_states()
	_apply_pending_runtime_state()
	pass


func get_save_id() -> String:
	return save_id


func get_save_data() -> Dictionary:
	# SaveSystem calls this when SaveSystem.save_game() runs.
	# Add stable keys here for important player data that needs special restore behavior.
	return {
		"global_position": global_position,
		"hp": hp,
		"max_hp": max_hp,
		"mana_amount": mana_amount,
		"mana_2_amount": mana_2_amount,
		"max_mana": max_mana,
		"hunger": hunger,
		"sleep_need": sleep_need,
		"dash": dash,
		"double_jump": double_jump,
		"ground_slam": ground_slam,
		"transformation": transformation,
		"facing_left": sprite_2d.flip_h,
		"extra_values": _collect_extra_save_values(),
	}


func apply_save_data(data: Dictionary) -> void:
	# SaveSystem calls this after the saved scene finishes loading.
	# Keep this forgiving so older save files can still load after you add new values.
	if data.has("global_position") and data["global_position"] is Vector2:
		global_position = data["global_position"]

	max_hp = float(data.get("max_hp", max_hp))
	hp = clampf(float(data.get("hp", hp)), 0.0, max_hp)

	max_mana = float(data.get("max_mana", max_mana))
	mana_amount = clampf(float(data.get("mana_amount", mana_amount)), 0.0, max_mana)
	mana_2_amount = clampf(float(data.get("mana_2_amount", mana_2_amount)), 0.0, max_mana)
	hunger = clampf(float(data.get("hunger", hunger)), 0.0, 100.0)
	sleep_need = clampf(float(data.get("sleep_need", sleep_need)), 0.0, 100.0)

	dash = bool(data.get("dash", dash))
	double_jump = bool(data.get("double_jump", double_jump))
	ground_slam = bool(data.get("ground_slam", ground_slam))
	transformation = bool(data.get("transformation", transformation))

	if data.has("facing_left"):
		apply_facing_left(bool(data["facing_left"]))

	var extra_values = data.get("extra_values", {})
	if extra_values is Dictionary:
		_apply_extra_save_values(extra_values)

	velocity = Vector2.ZERO
	knockback_timer = 0.0
	knockout_amount = 0.0
	knockout_active = false
	is_downed = false
	# A freshly loaded player is alive and responsive even if the previous run ended in defeat.
	dead = false
	set_physics_process(true)
	set_process(true)
	set_process_unhandled_input(true)
	sync_stats_to_hud()


func _apply_pending_runtime_state() -> void:
	var runtime := get_node_or_null("/root/PlayerRuntime")
	if runtime != null and runtime.has_method("apply_to_player"):
		runtime.call("apply_to_player", self)


func sync_stats_to_hud() -> void:
	hp = clampf(hp, 0.0, max_hp)
	mana_amount = clampf(mana_amount, 0.0, max_mana)
	mana_2_amount = clampf(mana_2_amount, 0.0, max_mana)
	hunger = clampf(hunger, 0.0, 100.0)
	sleep_need = clampf(sleep_need, 0.0, 100.0)

	PlayerHud.setup_hp(max_hp, hp)
	PlayerHud.setup_mana(max_mana, mana_amount, mana_2_amount)
	if PlayerHud.has_method("setup_knockout"):
		PlayerHud.call("setup_knockout", max_knockout, knockout_amount, knockout_active)
	if PlayerHud.has_method("setup_needs"):
		PlayerHud.call("setup_needs", 100.0, hunger, sleep_need)


func _collect_extra_save_values() -> Dictionary:
	var values := {}
	for value_name in extra_saved_value_names:
		# This keeps experimentation safe: a typo is skipped instead of breaking the save.
		if _has_player_property(value_name):
			values[String(value_name)] = get(value_name)

	return values


func _apply_extra_save_values(values: Dictionary) -> void:
	for value_name in extra_saved_value_names:
		var key := String(value_name)
		if values.has(key) and _has_player_property(value_name):
			set(value_name, values[key])


func _has_player_property(property_name: StringName) -> bool:
	for property in get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return true

	return false
	
func _unhandled_input( event: InputEvent) -> void:
	if is_downed:
		return

	change_state(current_state.handle_input( event ))
	#REMOVEEEEE later for propper attack state.
	if event.is_action_pressed("attach_rope"):
		toggle_rope()

	
	pass


func _process(_delta: float) -> void:
	update_direction()
	update_knockout(_delta)
	update_mana_2_charge(_delta)
	update_mana_charge(_delta)
	update_player_needs(_delta)
	update_passive_healing(_delta)
	change_state(current_state.process(_delta))
	
	
func _physics_process(_delta: float) -> void:
	velocity.y += gravity * _delta * gravity_multiplier

	if knockback_timer > 0.0:
		knockback_timer -= _delta
		move_and_slide()
		return

	move_and_slide()
	change_state(current_state.physics_process(_delta))
	pass


func initialize_states () -> void:
	states = []
	for c in $States.get_children():
		if c is PlayerState:
			states.append(c)
			c.player = self
			
		pass
	if states.size() == 0:
		return
		
	
	
	for state in states:
		state.init()
		
	change_state(current_state)
	current_state.enter()
	$Label.text = current_state.name
	pass
	

func change_state( new_state : PlayerState ) -> void:
	if new_state == null:
		return

	elif new_state == current_state:
		return

	if current_state:
		current_state.exit()

	states.push_front(new_state)
	current_state.enter()
	states.resize( 3 )
	$Label.text = current_state.name
	pass
		


func update_direction()->void:
	
	var previous_direction: Vector2 = direction
	
	
	var x_axis= Input.get_axis("left", "right")
	var y_axis= Input.get_axis("jump", "crouch")
	direction = Vector2(x_axis, y_axis)
	
	if previous_direction.x != direction.x:
		if direction.x < 0:
			apply_facing_left(true)
		elif direction.x > 0:
			apply_facing_left(false)
			
	pass
	

func apply_facing_left(is_facing_left: bool) -> void:
	var direction_x := -1.0 if is_facing_left else 1.0

	attack_1.flip(direction_x)
	attack_2.flip(direction_x)
	attack_3.flip(direction_x)
	sprite_2d.flip_h = is_facing_left
	ledgedetec.position.x = abs(ledgedetec.position.x) * direction_x
	ledgedetec.target_position.x = abs(ledgedetec.target_position.x) * direction_x
	ledgegrabcolider.scale.x = direction_x


func toggle_rope() -> void:
	if rope.active:
		rope.detach()
		current_rope_target = null
		return

	var target := get_closest_attachable()

	if target == null:
		print("No rope target nearby.")
		return

	current_rope_target = target

	var target_attach_point: Node2D = target

	if target.has_method("get_rope_attach_point"):
		target_attach_point = target.get_rope_attach_point()

	rope.attach(
		self,
		current_rope_target,
		rope_origin,
		target_attach_point
	)

	print("Attached rope to: ", current_rope_target.name)

func get_closest_attachable() -> Node2D:
	var closest: Node2D = null
	var closest_distance := INF

	for body in nearby_attachables:
		if body == null:
			continue

		if not is_instance_valid(body):
			continue

		var distance := global_position.distance_to(body.global_position)

		if distance < closest_distance:
			closest_distance = distance
			closest = body

	return closest


func take_damage(
	amount: float,
	damage_source_position: Vector2 = Vector2.ZERO,
	damage_source: Node = null,
	knockout_damage: float = 0.0
) -> void:
	# A defeated player ignores further damage so the death overlay is the only reaction.
	if dead:
		return

	var previous_hp := hp
	hp = maxf(hp - amount, 0.0)
	var damage_taken := previous_hp - hp
	DamageEvents.emit_damage_dealt(damage_taken, damage_source, self)
	PlayerHud.set_hp(hp)

	if hp <= 0:
		_defeat()
		return

	apply_knockout(knockout_damage)
	if not is_downed:
		apply_knockback(damage_source_position)


func _defeat() -> void:
	# Called once when hp hits 0. Stops movement, freezes input, and lets GameOverScreen react.
	if dead:
		return

	dead = true
	velocity = Vector2.ZERO
	knockback_timer = 0.0
	set_physics_process(false)
	set_process(false)
	set_process_unhandled_input(false)
	player_defeated.emit()


func heal(amount: float) -> void:
	if dead or amount <= 0.0:
		return
	hp = minf(hp + amount, max_hp)
	PlayerHud.set_hp(hp)


func restore_full_health() -> void:
	if dead:
		return
	heal(max_hp - hp)


func apply_knockout(amount: float) -> void:
	if dead or amount <= 0.0 or max_knockout <= 0.0:
		return

	knockout_amount = clampf(knockout_amount + amount, 0.0, max_knockout)
	knockout_active = knockout_amount > 0.0
	sync_knockout_bar()

	if knockout_amount >= max_knockout:
		enter_downed_state()


func update_knockout(delta: float) -> void:
	if not knockout_active:
		return

	var decay_rate := downed_decay_per_second if is_downed else knockout_decay_per_second
	knockout_amount = move_toward(knockout_amount, 0.0, maxf(decay_rate, 0.0) * maxf(delta, 0.0))
	sync_knockout_bar()

	if knockout_amount > 0.0:
		return

	knockout_active = false
	if is_downed:
		exit_downed_state()
	sync_knockout_bar()


func enter_downed_state() -> void:
	if is_downed:
		return

	is_downed = true
	knockback_timer = 0.0
	velocity.x = 0.0
	var downed_state := $States.get_node_or_null("Downed") as PlayerState
	if downed_state != null:
		change_state(downed_state)


func exit_downed_state() -> void:
	is_downed = false
	if current_state is PlayerStateDowned:
		if is_on_floor():
			change_state($States/Idle)
		else:
			change_state($States/Fall)


func sync_knockout_bar() -> void:
	if PlayerHud.has_method("set_knockout"):
		PlayerHud.call("set_knockout", knockout_amount, knockout_active)


func update_player_needs(delta: float) -> void:
	if not player_needs_enabled:
		return

	var game_hours := _get_game_hours_for_real_seconds(delta)
	if game_hours <= 0.0:
		return

	if active_spot_action != &"eat":
		apply_hunger_delta(hunger_growth_per_game_hour * game_hours)
	if active_spot_action != &"sleep":
		apply_sleep_need_delta(sleep_need_growth_per_game_hour * game_hours)


func update_passive_healing(delta: float) -> void:
	if passive_healing_per_game_day <= 0.0 or hp <= 0.0 or hp >= max_hp:
		return

	var game_hours := _get_game_hours_for_real_seconds(delta)
	if game_hours <= 0.0:
		return

	heal((passive_healing_per_game_day / 24.0) * game_hours)


func apply_hunger_delta(delta: float) -> float:
	var previous_value := hunger
	hunger = clampf(hunger + delta, 0.0, 100.0)
	if PlayerHud.has_method("set_hunger"):
		PlayerHud.call("set_hunger", hunger)
	return hunger - previous_value


func apply_sleep_need_delta(delta: float) -> float:
	var previous_value := sleep_need
	sleep_need = clampf(sleep_need + delta, 0.0, 100.0)
	if PlayerHud.has_method("set_sleep_need"):
		PlayerHud.call("set_sleep_need", sleep_need)
	return sleep_need - previous_value


func can_eat() -> bool:
	return hunger > 0.0


func can_sleep() -> bool:
	return sleep_need > 0.0


func begin_spot_action(spot: Node, action_name: StringName) -> void:
	active_spot = spot
	active_spot_action = action_name
	_on_spot_action_started(spot, action_name)


func end_spot_action(spot: Node, action_name: StringName, completed: bool) -> void:
	if active_spot != spot or active_spot_action != action_name:
		return

	_on_spot_action_finished(spot, action_name, completed)
	active_spot = null
	active_spot_action = &""


func _on_spot_action_started(_spot: Node, _action_name: StringName) -> void:
	# Animation hook: start player work/eat/sleep animations here.
	pass


func _on_spot_action_finished(_spot: Node, _action_name: StringName, _completed: bool) -> void:
	# Animation hook: stop or swap back from player work/eat/sleep animations here.
	pass


func _get_game_hours_for_real_seconds(real_seconds: float) -> float:
	var world_time := get_tree().root.get_node_or_null("WorldTime")
	if world_time == null:
		return 0.0

	var real_seconds_per_day := float(world_time.get("real_seconds_per_day"))
	if real_seconds_per_day <= 0.0:
		return 0.0

	return (maxf(real_seconds, 0.0) / real_seconds_per_day) * 24.0


func update_mana_charge(delta: float) -> void:
	if is_downed:
		return

	if current_state is PlayerAttack1 or current_state is PlayerAttack2 or current_state is PlayerAttack3 or current_state is PlayerSpecialAttack:
		return

	if Input.is_action_pressed("attack"):
		charge_mana(mana_charge_rate * delta)


func charge_mana(amount: float) -> void:
	mana_amount = minf(mana_amount + amount, mana_2_amount)
	PlayerHud.set_mana(mana_amount)


func update_mana_2_charge(delta: float) -> void:
	if mana_2_amount > max_mana:
		mana_2_amount = max_mana
		sync_mana_2_bar()
		return

	if is_equal_approx(mana_2_amount, max_mana):
		return

	mana_2_amount = move_toward(mana_2_amount, max_mana, mana_2_charge_rate * delta)
	sync_mana_2_bar()


func sync_mana_2_bar() -> void:
	mana_2_amount = clampf(mana_2_amount, 0.0, max_mana)

	if mana_amount > mana_2_amount:
		mana_amount = mana_2_amount

	PlayerHud.set_mana_2(mana_2_amount)
	PlayerHud.set_mana(mana_amount)


func spend_mana_2(amount: float) -> void:
	mana_2_amount = maxf(mana_2_amount - amount, 0.0)
	sync_mana_2_bar()


func clear_mana_charge() -> void:
	mana_amount = 0.0
	PlayerHud.set_mana(mana_amount)


func apply_knockback(damage_source_position: Vector2) -> void:
	var knockback_direction := signf(global_position.x - damage_source_position.x)
	if knockback_direction == 0.0:
		knockback_direction = -1.0 if sprite_2d.flip_h else 1.0

	velocity = Vector2(knockback_force.x * knockback_direction, knockback_force.y)
	knockback_timer = knockback_time


func force_flee_from(threat: Node2D, duration: float = 1.2, speed: float = 700.0) -> void:
	if dead:
		return

	var threat_position := global_position
	if threat != null and is_instance_valid(threat):
		threat_position = threat.global_position

	var flee_direction := signf(global_position.x - threat_position.x)
	if flee_direction == 0.0:
		flee_direction = -1.0 if sprite_2d.flip_h else 1.0

	apply_facing_left(flee_direction < 0.0)
	velocity.x = flee_direction * maxf(speed, 0.0)
	knockback_timer = maxf(knockback_timer, maxf(duration, 0.0))


func _on_rope_detector_body_entered(body: Node2D) -> void:
	track_rope_attachable(body)


func _on_rope_detector_body_exited(body: Node2D) -> void:
	untrack_rope_attachable(body)


func track_rope_attachable(attachable: Node2D) -> void:
	if not attachable.is_in_group("rope_attachable"):
		return

	if not nearby_attachables.has(attachable):
		nearby_attachables.append(attachable)


func untrack_rope_attachable(attachable: Node2D) -> void:
	if nearby_attachables.has(attachable):
		nearby_attachables.erase(attachable)
