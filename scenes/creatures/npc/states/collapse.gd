class_name NpcStateCollapse extends NpcState

@export var collapse_duration: float = -1.0
@export var sleep_value_name: StringName = &"sleep_need"
@export var sleep_complete_delta: float = -70.0

var collapse_timer: float = 0.0


func enter() -> void:
	# Emergency sleep response: stop immediately and start the collapse timer.
	super.enter()
	stop_horizontal()
	collapse_timer = collapse_duration

	if collapse_timer < 0.0:
		collapse_timer = machine.default_collapse_time


func physics_process(delta: float) -> NpcState:
	# Collapse reduces sleep_need only after the full collapse duration finishes.
	stop_horizontal()

	if collapse_timer <= 0.0:
		return next_state

	collapse_timer -= delta
	if collapse_timer > 0.0:
		return next_state

	if sleep_value_name != &"":
		machine.apply_value_delta({String(sleep_value_name): sleep_complete_delta}, null, false)

	return get_state(&"Idle")
