class_name Player extends CharacterBody2D

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
#endregion

#region //playerstats:
@export var max_hp : float = 20
var hp : float = 20
var mana_charge_rate : float = 100
var max_mana : float = 300
var mana_amount: float = 0.0
@export var mana_2_starts_full: bool = true
@export var mana_2_charge_rate: float = 50.0
var mana_2_amount: float = 0.0
var dash: bool = false
var double_jump: bool = false
var ground_slam: bool = false
var transformation: bool = false
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
	rope_detector.body_entered.connect(_on_rope_detector_body_entered)
	rope_detector.body_exited.connect(_on_rope_detector_body_exited)
	PlayerHud.visible = true
	hp = max_hp
	PlayerHud.setup_hp(max_hp, hp)
	mana_amount = 0.0
	mana_2_amount = max_mana if mana_2_starts_full else 0.0
	PlayerHud.setup_mana(max_mana, mana_amount, mana_2_amount)
	sync_mana_2_bar()
	#initialize states
	initialize_states()
	pass
	
func _unhandled_input( event: InputEvent) -> void:
	change_state(current_state.handle_input( event ))
	#REMOVEEEEE later for propper attack state.
	if event.is_action_pressed("attach_rope"):
		toggle_rope()

	
	pass


func _process(_delta: float) -> void:
	update_direction()
	update_mana_2_charge(_delta)
	update_mana_charge(_delta)
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
	print(states)
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
		attack_1.flip(direction.x)
		attack_2.flip(direction.x)
		attack_3.flip(direction.x)
		if direction.x < 0:
			ledgedetec.position.x = -abs(ledgedetec.position.x)
			ledgedetec.target_position.x = -abs(ledgedetec.target_position.x)
			ledgegrabcolider.scale.x = -1
			sprite_2d.flip_h = true
		elif direction.x > 0:
			sprite_2d.flip_h = false
			ledgedetec.position.x = abs(ledgedetec.position.x)
			ledgedetec.target_position.x = abs(ledgedetec.target_position.x)
			ledgegrabcolider.scale.x = 1
			
	pass
	

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


func take_damage(amount: float, damage_source_position: Vector2 = Vector2.ZERO) -> void:
	hp = maxf(hp - amount, 0.0)
	PlayerHud.set_hp(hp)

	if hp <= 0:
		print("player defeated")
		return

	apply_knockback(damage_source_position)


func heal(amount: float) -> void:
	hp = minf(hp + amount, max_hp)
	PlayerHud.set_hp(hp)


func update_mana_charge(delta: float) -> void:
	if current_state is PlayerAttack1 or current_state is PlayerAttack2 or current_state is PlayerAttack3 or current_state is PlayerSpecialAttack:
		return

	if Input.is_action_pressed("attack"):
		charge_mana(mana_charge_rate * delta)


func charge_mana(amount: float) -> void:
	mana_amount = minf(mana_amount + amount, mana_2_amount)
	PlayerHud.set_mana(mana_amount)


func update_mana_2_charge(delta: float) -> void:
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
