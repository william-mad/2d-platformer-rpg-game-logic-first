class_name NpcStateCollapse extends NpcState

@export var collapse_duration: float = -1.0
@export var sleep_value_name: StringName = &"sleep_need"
@export_range(0.0, 100.0, 0.1) var wake_sleep_need: float = 70.0
@export_range(0.1, 100.0, 0.1, "suffix:/h") var sleep_recovery_per_game_hour: float = 12.5

var collapse_timer: float = 0.0
var sleep_recovery_per_real_second: float = 0.0


func enter() -> void:
	# Exhaustion collapse is forced sleep in place; it does not use a bed or reservation.
	super.enter()
	stop_horizontal()
	_set_perception_enabled(false)

	var current_sleep_need := _get_sleep_need()
	var recovery_needed := maxf(current_sleep_need - wake_sleep_need, 0.0)
	if recovery_needed <= 0.0:
		collapse_timer = 0.0
		sleep_recovery_per_real_second = 0.0
		return

	var recovery_seconds := collapse_duration
	if recovery_seconds < 0.0:
		var recovery_game_hours := recovery_needed / maxf(sleep_recovery_per_game_hour, 0.001)
		recovery_seconds = machine.get_real_seconds_for_game_hours(
			recovery_game_hours,
			machine.default_collapse_time
		)
	collapse_timer = maxf(recovery_seconds, 0.001)
	sleep_recovery_per_real_second = recovery_needed / collapse_timer


func exit() -> void:
	_set_perception_enabled(true)
	sleep_recovery_per_real_second = 0.0


func physics_process(delta: float) -> NpcState:
	# Wake is value-driven, not timer-driven: external increases can extend recovery safely.
	stop_horizontal()
	var current_sleep_need := _get_sleep_need()
	if current_sleep_need <= wake_sleep_need:
		return get_state(&"Idle")

	if delta <= 0.0 or sleep_recovery_per_real_second <= 0.0:
		return next_state

	var recovery := minf(
		sleep_recovery_per_real_second * delta,
		current_sleep_need - wake_sleep_need
	)
	machine.apply_value_delta({String(sleep_value_name): -recovery}, null, false)
	collapse_timer = maxf(collapse_timer - delta, 0.0)
	if _get_sleep_need() <= wake_sleep_need:
		return get_state(&"Idle")

	return next_state


func _get_sleep_need() -> float:
	if machine == null or sleep_value_name == &"":
		return 0.0
	return machine.get_value(sleep_value_name)


func _set_perception_enabled(enabled: bool) -> void:
	if npc != null and npc.has_method("set_npc_perception_enabled"):
		npc.call("set_npc_perception_enabled", enabled)
