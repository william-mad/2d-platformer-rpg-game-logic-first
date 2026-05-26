class_name PlayerStateDash extends PlayerState

@export var dash_speed: float = 5000.0
@export var dash_duration: float = 0.08
@export var double_tap_window: float = 0.25
@export var cooldown_time: float = 0.15

var dash_timer: float = 0.0
var dash_direction: float = 1.0
var last_tap_direction: float = 0.0
var last_tap_time_msec: int = -100000
var cooldown_end_msec: int = 0


func init() -> void:
	print("init ", name)


func enter() -> void:
	print("enter ", name)
	dash_timer = dash_duration
	cooldown_end_msec = Time.get_ticks_msec() + int(cooldown_time * 1000.0)
	player.animation_player.play("run")
	player.velocity.x = dash_direction * dash_speed
	player.ledgegrabcolider.disabled = true
	next_state = null


func exit() -> void:
	print("exit ", name)

	if player.direction.x == 0.0:
		player.velocity.x = 0.0
	else:
		player.velocity.x = player.direction.x * player.move_speed


func handle_input(_event: InputEvent) -> PlayerState:
	if _event.is_action_released("attack"):
		clear_attack_charge()

	return null


func process(delta: float) -> PlayerState:
	dash_timer -= delta

	if dash_timer > 0.0:
		return null

	if player.is_on_floor():
		if player.direction.x != 0:
			return run

		return idle

	return fall


func physics_process(_delta: float) -> PlayerState:
	player.velocity.x = dash_direction * dash_speed

	return null


func get_dash_state_from_input(_event: InputEvent) -> PlayerState:
	var tap_direction := get_tap_direction(_event)

	if tap_direction == 0.0:
		return null

	var now := Time.get_ticks_msec()

	if now < cooldown_end_msec:
		return null

	var is_double_tap := tap_direction == last_tap_direction and now - last_tap_time_msec <= int(double_tap_window * 1000.0)
	last_tap_direction = tap_direction
	last_tap_time_msec = now

	if not is_double_tap:
		return null

	dash_direction = tap_direction
	last_tap_time_msec = -100000
	return self


func get_tap_direction(_event: InputEvent) -> float:
	if _event is InputEventKey and _event.echo:
		return 0.0

	if _event.is_action_pressed("left"):
		return -1.0

	if _event.is_action_pressed("right"):
		return 1.0

	return 0.0
