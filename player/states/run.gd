class_name PlayerStateRun extends PlayerState

@export var run_animation: StringName = &"run"
@export_range(0.0, 2.0, 0.05, "suffix:s") var idle_to_walk_delay: float = 1.0

var is_running: bool = false
var idle_to_walk_at_msec: int = 0


func init() -> void:
	pass



func enter() -> void:
	enable_running()
	player.animation_player.play(run_animation)
	player.ledgegrabcolider.disabled = true
	pass



func exit() -> void:
	pass


func handle_input(_event : InputEvent) -> PlayerState:
	var requested_dash := get_dash_state_from_input(_event)

	if requested_dash != null:
		return requested_dash
	
	if _event.is_action_pressed("charm") and can_hide():
		return hidden
	
	if _event.is_action_released("attack"):
		return get_attack_release_state()
		
	if _event.is_action_pressed( "jump" ):
		return jump
	
	if _event.is_action_pressed("crouch"):
		return crouch
	
	return next_state


func process(_delta: float) -> PlayerState:
	if player.direction.x == 0:
		return idle
	return next_state

func physics_update_before_move(_delta: float) -> void:
	player.velocity.x = player.direction.x * player.move_speed


func physics_update_after_move(_delta: float) -> PlayerState:
	#player going down is falling:
	if player.velocity.y > 0.5:
		return fall

	return next_state


func enable_running() -> void:
	is_running = true
	idle_to_walk_at_msec = 0


func begin_idle_to_walk_countdown() -> void:
	if not is_running:
		return
	idle_to_walk_at_msec = Time.get_ticks_msec() + int(idle_to_walk_delay * 1000.0)


func update_idle_to_walk_countdown() -> void:
	if is_running and idle_to_walk_at_msec > 0 and Time.get_ticks_msec() >= idle_to_walk_at_msec:
		clear_running()


func cancel_idle_to_walk_countdown() -> void:
	idle_to_walk_at_msec = 0


func clear_running() -> void:
	is_running = false
	idle_to_walk_at_msec = 0
