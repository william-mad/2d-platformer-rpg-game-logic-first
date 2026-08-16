class_name WorldTimeAmbientAudio extends AudioStreamPlayer

## Loops ambient audio while the WorldTime clock is inside an authored daily window.

@export_range(0.0, 24.0, 0.01, "suffix:h") var start_hour: float = 6.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var end_hour: float = 13.0
@export_range(0.0, 1.0, 0.01) var volume_ratio: float = 0.5
@export_range(0.0, 60.0, 0.5, "suffix:s") var fade_seconds: float = 12.0
@export var allowed_scene_paths: PackedStringArray = []

var _world_time: Node
var _scene_active: bool = true
var _last_scene_path: String = ""
var _active_in_window: bool = false
var _fade_tween: Tween


func _ready() -> void:
	volume_linear = 0.0
	_scene_active = allowed_scene_paths.is_empty()
	finished.connect(_on_finished)
	_world_time = get_node_or_null("/root/WorldTime")
	if _world_time == null or not _world_time.has_method("get_snapshot"):
		stop()
		push_warning("WorldTimeAmbientAudio requires the WorldTime autoload.")
		return
	var callback := Callable(self, "_on_world_time_hour_changed")
	if (
		_world_time.has_signal(&"hour_changed")
		and not _world_time.is_connected(&"hour_changed", callback)
	):
		_world_time.connect(&"hour_changed", callback)
	_sync_to_snapshot(_world_time.call("get_snapshot"))
	call_deferred("_refresh_scene_membership")


func _process(_delta: float) -> void:
	if not allowed_scene_paths.is_empty():
		_refresh_scene_membership()


func _exit_tree() -> void:
	_kill_fade()
	stop()
	stream = null
	if _world_time == null or not is_instance_valid(_world_time):
		return
	var callback := Callable(self, "_on_world_time_hour_changed")
	if (
		_world_time.has_signal(&"hour_changed")
		and _world_time.is_connected(&"hour_changed", callback)
	):
		_world_time.disconnect(&"hour_changed", callback)


func _on_world_time_hour_changed(_hour: int, snapshot: Dictionary) -> void:
	_sync_to_snapshot(snapshot)


func _on_finished() -> void:
	if _active_in_window and stream != null:
		play()


func _refresh_scene_membership() -> void:
	var current_scene := get_tree().current_scene
	if current_scene == null or current_scene.scene_file_path.is_empty():
		return
	_apply_scene_path(current_scene.scene_file_path)


func _apply_scene_path(scene_path: String) -> void:
	if scene_path == _last_scene_path:
		return
	_last_scene_path = scene_path
	var next_scene_active := (
		allowed_scene_paths.is_empty() or allowed_scene_paths.has(scene_path)
	)
	if next_scene_active == _scene_active:
		return
	_scene_active = next_scene_active
	if _world_time != null and is_instance_valid(_world_time):
		_sync_to_snapshot(_world_time.call("get_snapshot"))


func _sync_to_snapshot(snapshot: Dictionary) -> void:
	_active_in_window = _scene_active and _hour_is_inside_window(
		float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))
	)
	if _active_in_window:
		if stream == null:
			return
		if not playing:
			volume_linear = 0.0
			play()
		_fade_to(clampf(volume_ratio, 0.0, 1.0), false)
	elif playing:
		_fade_to(0.0, true)
	else:
		volume_linear = 0.0


func _fade_to(target_volume: float, stop_after_fade: bool) -> void:
	_kill_fade()
	var duration := maxf(fade_seconds, 0.0)
	if duration <= 0.0:
		volume_linear = target_volume
		if stop_after_fade:
			stop()
		return
	_fade_tween = create_tween()
	_fade_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_fade_tween.tween_property(self, "volume_linear", target_volume, duration)
	if stop_after_fade:
		_fade_tween.tween_callback(stop)


func _kill_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null


func _hour_is_inside_window(hour: float) -> bool:
	var normalized_hour := fposmod(hour, 24.0)
	var normalized_start := fposmod(start_hour, 24.0)
	var normalized_end := fposmod(end_hour, 24.0)
	if is_equal_approx(normalized_start, normalized_end):
		return true
	if normalized_start < normalized_end:
		return normalized_hour >= normalized_start and normalized_hour < normalized_end
	return normalized_hour >= normalized_start or normalized_hour < normalized_end
