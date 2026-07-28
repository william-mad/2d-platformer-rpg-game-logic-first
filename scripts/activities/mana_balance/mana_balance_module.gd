class_name ManaBalanceModule
extends InteractiveActivityModule

const ZONE_PERFECT := &"perfect"
const ZONE_WARNING := &"warning"
const ZONE_FAILURE := &"failure"
const CURRENT_DIRECTIONS: Array[Vector2] = [
	Vector2.UP,
	Vector2(0.70710678, -0.70710678),
	Vector2.RIGHT,
	Vector2(0.70710678, 0.70710678),
	Vector2.DOWN,
	Vector2(-0.70710678, 0.70710678),
	Vector2.LEFT,
	Vector2(-0.70710678, -0.70710678),
]
const CURRENT_NAMES: Array[String] = [
	"N",
	"NE",
	"E",
	"SE",
	"S",
	"SW",
	"W",
	"NW",
]

@export var default_config: ManaBalanceConfig

var config: ManaBalanceConfig
var concentration: float = 0.0
var perfect_hold_seconds: float = 0.0
var current_multiplier: float = 1.0
var best_multiplier: float = 1.0
var longest_perfect_hold: float = 0.0
var current_force_strength: float = 0.0
var current_direction: Vector2 = Vector2.RIGHT
var current_zone: StringName = ZONE_PERFECT
var _configured: bool = false
var _resetting: bool = false
var _reset_remaining: float = 0.0
var _force_change_remaining: float = 0.0
var _direction_index: int = 0
var _last_published_signature: String = ""
var _rng := RandomNumberGenerator.new()

@onready var arena_background: ColorRect = %Background
@onready var warning_zone_visual: Polygon2D = %WarningZone
@onready var perfect_zone_visual: Polygon2D = %PerfectZone
@onready var orb: ControlledActivityOrb = %ControlledOrb
@onready var current_indicator: Line2D = %CurrentIndicator
@onready var current_label: Label = %CurrentLabel
@onready var concentration_bar: ProgressBar = %ConcentrationBar
@onready var multiplier_label: Label = %MultiplierLabel
@onready var success_label: Label = %SuccessLabel
@onready var score_label: Label = %ScoreLabel
@onready var status_label: Label = %StatusLabel


func configure(
	context: Dictionary,
	input_source: InteractiveActivityInputSource
) -> bool:
	if not super.configure(context, input_source):
		return false
	var supplied_config := context.get("module_config") as ManaBalanceConfig
	config = supplied_config if supplied_config != null else default_config
	if config == null or not config.is_valid_config():
		return false
	if orb == null or not orb.configure(config.get_orb_config()):
		return false
	orb.set_input_source(input_source)
	var half_size := config.arena_size * 0.5
	orb.set_movement_bounds(Rect2(-half_size, config.arena_size))
	_configure_visuals()
	_rng.seed = hash(String(context.get("session_id", "")))
	_configured = true
	_reset_runtime_state()
	_sync_result(false)
	return true


func start_activity() -> void:
	if not _configured or _stopped or _running:
		return
	_reset_runtime_state()
	orb.set_movement_enabled(true)
	super.start_activity()
	_sync_result(false)


func stop_activity(reason: StringName) -> Dictionary:
	if _stopped:
		return get_result()
	orb.set_movement_enabled(false)
	orb.set_external_force(Vector2.ZERO)
	_resetting = false
	_sync_result(false)
	return super.stop_activity(reason)


func get_concentration() -> float:
	return concentration


func get_current_multiplier() -> float:
	return current_multiplier


func get_current_force_strength() -> float:
	return current_force_strength


func get_current_zone() -> StringName:
	return current_zone


func get_controlled_orb() -> ControlledActivityOrb:
	return orb


func _physics_process(delta: float) -> void:
	if not _running or not _configured:
		return
	var safe_delta := maxf(delta, 0.0)
	if _resetting:
		_reset_remaining -= safe_delta
		if (
			_reset_remaining <= 0.0
			or activity_input.was_role_pressed(&"confirm")
		):
			_finish_success_reset()
		return

	_force_change_remaining -= safe_delta
	if _force_change_remaining <= 0.0:
		_choose_new_current_direction()
		_force_change_remaining = config.force_change_interval
	orb.set_external_force(current_direction * current_force_strength)
	_update_balance_rules(safe_delta)


func _reset_runtime_state() -> void:
	concentration = 0.0
	perfect_hold_seconds = 0.0
	current_multiplier = 1.0
	best_multiplier = 1.0
	longest_perfect_hold = 0.0
	current_force_strength = config.starting_force_strength
	current_zone = ZONE_PERFECT
	_resetting = false
	_reset_remaining = 0.0
	_force_change_remaining = config.force_change_interval
	_result["score"] = 0.0
	_result["attempts"] = 0
	_result["successes"] = 0
	_result["failures"] = 0
	_result["elapsed_seconds"] = 0.0
	_direction_index = _rng.randi_range(0, CURRENT_DIRECTIONS.size() - 1)
	_set_current_direction(_direction_index)
	orb.reset_orb(Vector2.ZERO)
	orb.set_external_force(current_direction * current_force_strength)
	_last_published_signature = ""
	_update_status("Hold the orb in the bright center.")


func _update_balance_rules(delta: float) -> void:
	var distance := orb.get_orb_position().length()
	if distance <= config.perfect_radius:
		current_zone = ZONE_PERFECT
		concentration += config.concentration_fill_rate * delta
		perfect_hold_seconds += delta
		longest_perfect_hold = maxf(longest_perfect_hold, perfect_hold_seconds)
		current_multiplier = clampf(
			1.0
			+ floor(perfect_hold_seconds / config.multiplier_seconds_per_step) * 0.5,
			1.0,
			config.maximum_multiplier
		)
		best_multiplier = maxf(best_multiplier, current_multiplier)
		_update_status("Perfect focus")
	elif distance <= config.warning_radius:
		current_zone = ZONE_WARNING
		concentration -= config.warning_drain_rate * delta
		_reset_multiplier_streak()
		_update_status("Drifting — guide it inward")
	else:
		current_zone = ZONE_FAILURE
		concentration -= config.failure_drain_rate * delta
		_reset_multiplier_streak()
		_update_status("Unstable — recover the orb")

	concentration = clampf(concentration, 0.0, config.required_concentration)
	if concentration >= config.required_concentration:
		_register_success()
	else:
		_sync_result(true)


func _reset_multiplier_streak() -> void:
	perfect_hold_seconds = 0.0
	current_multiplier = 1.0


func _register_success() -> void:
	var awarded_multiplier := current_multiplier
	_result["attempts"] = int(_result.get("attempts", 0)) + 1
	_result["successes"] = int(_result.get("successes", 0)) + 1
	_result["score"] = (
		float(_result.get("score", 0.0))
		+ config.base_success_score * awarded_multiplier
	)
	current_force_strength = minf(
		config.maximum_force_strength,
		current_force_strength + config.force_increase_per_success
	)
	concentration = 0.0
	_reset_multiplier_streak()
	_choose_new_current_direction()
	_force_change_remaining = config.force_change_interval
	_resetting = true
	_reset_remaining = config.reset_delay_seconds
	orb.set_movement_enabled(false)
	orb.set_external_force(Vector2.ZERO)
	orb.reset_orb(Vector2.ZERO)
	_update_status("Stabilized! Current strengthened.")
	_sync_result(true)


func _finish_success_reset() -> void:
	_resetting = false
	_reset_remaining = 0.0
	orb.reset_orb(Vector2.ZERO)
	orb.set_external_force(current_direction * current_force_strength)
	orb.set_movement_enabled(true)
	_update_status("Hold the orb in the bright center.")
	_sync_result(true)


func _choose_new_current_direction(force_any: bool = false) -> void:
	var previous_index := _direction_index
	var opposite_index := (previous_index + 4) % CURRENT_DIRECTIONS.size()
	var candidate := previous_index
	for _attempt in 8:
		candidate = _rng.randi_range(0, CURRENT_DIRECTIONS.size() - 1)
		if force_any or candidate != opposite_index:
			break
	if not force_any and candidate == opposite_index:
		candidate = (previous_index + 1) % CURRENT_DIRECTIONS.size()
	_direction_index = candidate
	_set_current_direction(_direction_index)


func _set_current_direction(index: int) -> void:
	_direction_index = wrapi(index, 0, CURRENT_DIRECTIONS.size())
	current_direction = CURRENT_DIRECTIONS[_direction_index]
	current_indicator.points = PackedVector2Array([
		Vector2.ZERO,
		current_direction * 62.0,
	])
	current_label.text = "Current: %s" % CURRENT_NAMES[_direction_index]


func _configure_visuals() -> void:
	var half_size := config.arena_size * 0.5
	arena_background.position = -half_size
	arena_background.size = config.arena_size
	warning_zone_visual.polygon = _make_circle_polygon(config.warning_radius)
	perfect_zone_visual.polygon = _make_circle_polygon(config.perfect_radius)
	concentration_bar.max_value = config.required_concentration
	concentration_bar.value = 0.0


func _make_circle_polygon(radius: float, point_count: int = 40) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in point_count:
		var angle := TAU * float(index) / float(point_count)
		points.append(Vector2.from_angle(angle) * radius)
	return points


func _update_status(message: String) -> void:
	status_label.text = message


func _sync_result(emit_if_changed: bool) -> void:
	_result["details"] = {
		"best_multiplier": best_multiplier,
		"longest_perfect_hold": longest_perfect_hold,
		"final_force_strength": current_force_strength,
		"final_concentration": concentration,
		"current_multiplier": current_multiplier,
		"current_zone": String(current_zone),
		"resetting": _resetting,
	}
	concentration_bar.value = concentration
	multiplier_label.text = "Multiplier  x%.1f" % current_multiplier
	success_label.text = "Stabilizations  %d" % int(_result.get("successes", 0))
	score_label.text = "Score  %d" % int(round(float(_result.get("score", 0.0))))
	var signature := "%s|%d|%.1f|%d|%d|%d|%s" % [
		String(current_zone),
		int(floor(concentration * 10.0)),
		current_multiplier,
		int(_result.get("score", 0.0)),
		int(_result.get("successes", 0)),
		int(_result.get("failures", 0)),
		str(_resetting),
	]
	if emit_if_changed and signature != _last_published_signature:
		result_changed.emit(get_result())
	_last_published_signature = signature
