class_name PracticeDummy extends Node2D

@export var max_health: float = 100.0
@export var reset_after_seconds: float = 2.0
@export var invulnerable: bool = false
@export var count_player_practice: bool = true
@export var practice_session_timeout_seconds: float = 5.0
@export var attack_aim_offset: Vector2 = Vector2(0.0, -48.0)

@export_group("Hit Feedback")
@export var hit_flash_color: Color = Color(1.0, 0.92, 0.36, 1.0)
@export var knocked_down_flash_color: Color = Color(1.0, 0.45, 0.28, 1.0)
@export var hit_feedback_seconds: float = 0.16
@export var hit_bounce_pixels: float = 8.0

@export_group("Debug")
@export var debug_label_visible: bool = false

@onready var body_visual: Node2D = get_node_or_null("BodyVisual") as Node2D
@onready var debug_label: Label = get_node_or_null("DebugLabel") as Label

var current_health: float = 100.0
var player_practice_active: bool = false
var player_practice_session_seconds: float = 0.0
var player_practice_total_seconds: float = 0.0
var player_practice_today_seconds: float = 0.0
var player_practice_hits_total: int = 0
var player_practice_damage_total: float = 0.0
var last_player_hit_real_time: float = -1.0

var _reset_timer: float = 0.0
var _knocked_down: bool = false
var _player_practice_seconds_since_last_hit: float = 0.0
var _visual_rest_position: Vector2 = Vector2.ZERO
var _visual_rest_rotation: float = 0.0
var _hit_tween: Tween


func _ready() -> void:
	add_to_group("training_dummy")
	add_to_group("attack_target")
	current_health = maxf(max_health, 1.0)

	if body_visual != null:
		_visual_rest_position = body_visual.position
		_visual_rest_rotation = body_visual.rotation

	if debug_label != null:
		debug_label.visible = debug_label_visible
		_update_debug_label()

	_connect_world_time()


func _process(delta: float) -> void:
	_update_reset(delta)
	_update_player_practice(delta)


func take_damage(
	amount: float,
	damage_source_position: Vector2 = Vector2.ZERO,
	damage_source: Node = null,
	_knockout_damage: float = 0.0
) -> void:
	if amount <= 0.0:
		return

	var damage_taken := amount
	if not invulnerable:
		var previous_health := current_health
		current_health = maxf(current_health - amount, 0.0)
		damage_taken = previous_health - current_health
		_reset_timer = maxf(reset_after_seconds, 0.0)
		if current_health <= 0.0:
			_knocked_down = true

	if count_player_practice and _damage_source_is_player(damage_source):
		_register_player_hit(damage_taken)

	_play_hit_feedback(damage_source_position)
	_update_debug_label()


func get_attack_aim_position() -> Vector2:
	return global_position + attack_aim_offset


func get_current_health() -> float:
	return current_health


func get_player_practice_total_seconds() -> float:
	return player_practice_total_seconds


func get_player_practice_today_seconds() -> float:
	return player_practice_today_seconds


func get_player_practice_hits_total() -> int:
	return player_practice_hits_total


func consume_player_practice_seconds(amount: float) -> float:
	var consumed := clampf(amount, 0.0, player_practice_total_seconds)
	if consumed <= 0.0:
		return 0.0

	player_practice_total_seconds = maxf(player_practice_total_seconds - consumed, 0.0)
	player_practice_today_seconds = maxf(player_practice_today_seconds - consumed, 0.0)
	player_practice_session_seconds = maxf(player_practice_session_seconds - consumed, 0.0)
	_update_debug_label()
	return consumed


func is_training_dummy() -> bool:
	return true


func reset_dummy() -> void:
	current_health = maxf(max_health, 1.0)
	_reset_timer = 0.0
	_knocked_down = false
	_restore_visual()
	_update_debug_label()


func is_knocked_down() -> bool:
	return _knocked_down


func _update_reset(delta: float) -> void:
	if _reset_timer <= 0.0:
		return

	_reset_timer = maxf(_reset_timer - maxf(delta, 0.0), 0.0)
	if _reset_timer <= 0.0:
		reset_dummy()


func _update_player_practice(delta: float) -> void:
	if not player_practice_active:
		return

	var safe_delta := maxf(delta, 0.0)
	var timeout := maxf(practice_session_timeout_seconds, 0.0)
	if timeout <= 0.0:
		_close_player_practice_session()
		return

	var remaining_active_seconds := timeout - _player_practice_seconds_since_last_hit
	if remaining_active_seconds <= 0.0:
		_close_player_practice_session()
		return

	var counted_seconds := minf(safe_delta, remaining_active_seconds)
	_add_player_practice_seconds(counted_seconds)
	_player_practice_seconds_since_last_hit += safe_delta

	if _player_practice_seconds_since_last_hit >= timeout:
		_close_player_practice_session()

	_update_debug_label()


func _register_player_hit(damage_taken: float) -> void:
	player_practice_hits_total += 1
	player_practice_damage_total += maxf(damage_taken, 0.0)
	last_player_hit_real_time = float(Time.get_ticks_msec()) / 1000.0
	_player_practice_seconds_since_last_hit = 0.0

	if not player_practice_active:
		player_practice_active = true
		player_practice_session_seconds = 0.0


func _add_player_practice_seconds(seconds: float) -> void:
	if seconds <= 0.0:
		return

	player_practice_session_seconds += seconds
	player_practice_total_seconds += seconds
	player_practice_today_seconds += seconds


func _close_player_practice_session() -> void:
	player_practice_active = false
	_player_practice_seconds_since_last_hit = 0.0


func _damage_source_is_player(damage_source: Node) -> bool:
	var source := damage_source
	if source != null and source.has_method("get_damage_source"):
		var resolved_source := source.call("get_damage_source") as Node
		if resolved_source != null and resolved_source != source:
			source = resolved_source

	while source != null and is_instance_valid(source):
		if source.is_in_group("player"):
			return true
		source = source.get_parent()

	return false


func _play_hit_feedback(damage_source_position: Vector2) -> void:
	if body_visual == null:
		return

	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()

	var away_direction := signf(global_position.x - damage_source_position.x)
	if is_zero_approx(away_direction):
		away_direction = 1.0

	var flash_color := knocked_down_flash_color if _knocked_down else hit_flash_color
	var bounce := Vector2(away_direction * hit_bounce_pixels, -hit_bounce_pixels * 0.35)
	var tilt := deg_to_rad(8.0 * away_direction) if _knocked_down else deg_to_rad(3.0 * away_direction)
	var half_time := maxf(hit_feedback_seconds * 0.5, 0.01)

	body_visual.position = _visual_rest_position
	body_visual.rotation = _visual_rest_rotation
	body_visual.modulate = Color.WHITE

	_hit_tween = create_tween()
	_hit_tween.tween_property(body_visual, "modulate", flash_color, half_time)
	_hit_tween.parallel().tween_property(body_visual, "position", _visual_rest_position + bounce, half_time)
	_hit_tween.parallel().tween_property(body_visual, "rotation", _visual_rest_rotation + tilt, half_time)
	_hit_tween.tween_property(body_visual, "modulate", Color.WHITE, half_time)
	_hit_tween.parallel().tween_property(body_visual, "position", _visual_rest_position, half_time)
	_hit_tween.parallel().tween_property(body_visual, "rotation", _visual_rest_rotation, half_time)
	_hit_tween.tween_callback(Callable(self, "_clear_hit_tween"))


func _restore_visual() -> void:
	if body_visual == null:
		return

	if _hit_tween != null and _hit_tween.is_valid():
		_hit_tween.kill()
		_hit_tween = null

	body_visual.position = _visual_rest_position
	body_visual.rotation = _visual_rest_rotation
	body_visual.modulate = Color.WHITE


func _clear_hit_tween() -> void:
	_hit_tween = null


func _connect_world_time() -> void:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_signal(&"day_changed"):
		return

	var callback := Callable(self, "_on_world_day_changed")
	if not world_time.is_connected(&"day_changed", callback):
		world_time.connect(&"day_changed", callback)


func _on_world_day_changed(_day: int, _snapshot: Dictionary) -> void:
	player_practice_today_seconds = 0.0
	_update_debug_label()


func _update_debug_label() -> void:
	if debug_label == null:
		return

	debug_label.visible = debug_label_visible
	if not debug_label_visible:
		return

	debug_label.text = "hits:%d  active:%.1fs  total:%.1fs" % [
		player_practice_hits_total,
		player_practice_session_seconds,
		player_practice_total_seconds,
	]
