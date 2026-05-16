class_name Player extends CharacterBody2D

#onready variables:

@onready var sprite_2d: Sprite2D = $Sprite2D
@onready var colider_stand: CollisionShape2D = $colider_stand
@onready var colider_crouch: CollisionShape2D = $colider_crouch
@onready var small_platform_detection: RayCast2D = $"small platform detection"
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var attack_1: Attack_1 = %Attack_1





#export variables
@export var move_speed : float = 700


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

func _ready() -> void:
	#initialize states
	initialize_states()
	pass
	
func _unhandled_input( event: InputEvent) -> void:
	change_state(current_state.handle_input( event ))
	#REMOVEEEEE later for propper attack state.
	if event.is_action_pressed("attack"):
		attack_1.activate()
	pass


func _process(_delta: float) -> void:
	update_direction()
	change_state(current_state.process(_delta))
	
	
func _physics_process(_delta: float) -> void:
	velocity.y += gravity * _delta * gravity_multiplier
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
		if direction.x < 0:
			sprite_2d.flip_h = true
		elif direction.x > 0:
			sprite_2d.flip_h = false
			
	pass
	
	
