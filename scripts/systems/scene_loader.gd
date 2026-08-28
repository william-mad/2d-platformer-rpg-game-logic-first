class_name SceneLoaderSystem extends CanvasLayer

signal scene_load_started(scene_path: String)
signal scene_load_finished(success: bool, scene_path: String)

@export var use_threaded_loading: bool = true
@export var use_sub_threads: bool = false
@export var show_loading_overlay: bool = true
@export var keep_loaded_scene_cache: bool = false
@export_range(0.1, 5.0, 0.1, "suffix:s") var preload_status_poll_seconds: float = 0.5

var cached_scenes: Dictionary = {}
var pending_preload_paths: Dictionary = {}
var loading_scene_path: String = ""
var loading_in_progress: bool = false
var preload_poll_timer: float = 0.0
var active_player_transition: Dictionary = {}

var overlay: ColorRect
var loading_label: Label


func _ready() -> void:
	layer = 115
	_build_overlay()
	visible = false
	set_process(false)


func _exit_tree() -> void:
	_cleanup_player_scene_transition(true, &"scene_loader_exit")


func preload_scene(scene_path: String) -> bool:
	var normalized_path := scene_path.strip_edges()
	if normalized_path.is_empty():
		return false

	if cached_scenes.has(normalized_path):
		return true

	if _debug_flag(&"DEBUG_DISABLE_SCENE_PRELOADS"):
		_breadcrumb("scene_loader:preload_skip", normalized_path)
		return false

	if not use_threaded_loading:
		return false

	_breadcrumb("scene_loader:preload_status", normalized_path)
	var status := ResourceLoader.load_threaded_get_status(normalized_path)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		return _cache_threaded_scene(normalized_path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		_track_preload(normalized_path)
		return true

	_breadcrumb("scene_loader:preload_request", normalized_path)
	var error := ResourceLoader.load_threaded_request(
		normalized_path,
		"PackedScene",
		use_sub_threads,
		ResourceLoader.CACHE_MODE_REUSE
	)
	if error != OK:
		_record_watchdog_marker(&"scene_loader:preload_failed", "%s request=%d" % [normalized_path.get_file(), error])
		return false

	_track_preload(normalized_path)
	_record_watchdog_marker(&"scene_loader:preload_start", normalized_path)
	return true


func change_scene(scene_path: String) -> bool:
	var normalized_path := scene_path.strip_edges()
	if normalized_path.is_empty() or loading_in_progress:
		return false

	loading_scene_path = normalized_path
	loading_in_progress = true
	_show_loading_overlay(0.0)
	_breadcrumb("scene_loader:start", normalized_path)
	_record_watchdog_marker(&"scene_loader:start", normalized_path)
	scene_load_started.emit(normalized_path)

	if _debug_flag(&"DEBUG_FORCE_BLOCKING_SCENE_LOADS") or not use_threaded_loading:
		_breadcrumb("scene_loader:force_blocking", normalized_path)
		call_deferred("_change_scene_blocking", normalized_path)
		return true

	if not preload_scene(normalized_path):
		call_deferred("_change_scene_blocking", normalized_path)
		return true

	set_process(true)
	return true


func is_scene_transition_in_progress() -> bool:
	return loading_in_progress or not active_player_transition.is_empty()


func request_player_scene_transition(
	player: Node,
	target_scene_path: String,
	target_spawn_id: StringName,
	reason: StringName = &"door"
) -> Dictionary:
	var normalized_path := target_scene_path.strip_edges()
	var validation_reason := _validate_player_scene_transition(player, normalized_path)
	if validation_reason != &"":
		_log_player_transition("rejected", normalized_path, target_spawn_id, validation_reason)
		return {"accepted": false, "reason": validation_reason}

	var runtime := get_node_or_null("/root/PlayerRuntime")
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	var world_lock_token := int(gameplay_flow.call(
		"acquire_world_progression_lock", self, reason
	))
	if world_lock_token == 0:
		_log_player_transition("rejected", normalized_path, target_spawn_id, &"world_lock_rejected")
		return {"accepted": false, "reason": &"world_lock_rejected"}

	var player_claim_token := int(gameplay_flow.call(
		"acquire_player_control_claim", self, player, reason, &"ui_only"
	))
	if player_claim_token == 0:
		gameplay_flow.call("release_world_progression_lock", world_lock_token, self)
		_log_player_transition("rejected", normalized_path, target_spawn_id, &"player_claim_rejected")
		return {"accepted": false, "reason": &"player_claim_rejected"}

	active_player_transition = {
		"target_scene": normalized_path,
		"target_spawn": target_spawn_id,
		"reason": reason,
		"world_lock_token": world_lock_token,
		"player_claim_token": player_claim_token,
	}
	runtime.call("capture_player", player, target_spawn_id, normalized_path)
	if not bool(runtime.call("has_pending_player_data")):
		_cleanup_player_scene_transition(true, &"player_capture_failed")
		_log_player_transition("rejected", normalized_path, target_spawn_id, &"player_capture_failed")
		return {"accepted": false, "reason": &"player_capture_failed"}

	if not change_scene(normalized_path):
		_cleanup_player_scene_transition(true, &"scene_load_rejected")
		_log_player_transition("rejected", normalized_path, target_spawn_id, &"scene_load_rejected")
		return {"accepted": false, "reason": &"scene_load_rejected"}

	_log_player_transition(
		"accepted", normalized_path, target_spawn_id, &"accepted",
		world_lock_token, player_claim_token
	)
	return {"accepted": true, "reason": &"accepted"}


func _process(delta: float) -> void:
	if not loading_in_progress:
		_poll_preloads(delta)
		if pending_preload_paths.is_empty():
			set_process(false)
		return

	if cached_scenes.has(loading_scene_path):
		_change_scene_to_cached(loading_scene_path)
		return

	var progress: Array = []
	var status := ResourceLoader.load_threaded_get_status(loading_scene_path, progress)
	var progress_value := float(progress[0]) if not progress.is_empty() else 0.0
	_show_loading_overlay(progress_value)

	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return

	if status == ResourceLoader.THREAD_LOAD_LOADED:
		if _cache_threaded_scene(loading_scene_path):
			_change_scene_to_cached(loading_scene_path)
			return

		_finish_scene_load(false, loading_scene_path)
		return

	if status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		_change_scene_blocking(loading_scene_path)


func get_debug_status() -> Dictionary:
	var preloads: Array[String] = []
	for scene_path in pending_preload_paths.keys():
		var progress: Array = []
		var status := ResourceLoader.load_threaded_get_status(String(scene_path), progress)
		var progress_value := float(progress[0]) if not progress.is_empty() else 0.0
		preloads.append("%s:%s:%d%%" % [
			String(scene_path).get_file(),
			_get_thread_status_label(status),
			int(round(clampf(progress_value, 0.0, 1.0) * 100.0)),
		])

	var transition_status := {
		"target_scene": "",
		"target_spawn": &"",
		"world_lock_token": 0,
		"player_claim_token": 0,
	}
	if not active_player_transition.is_empty():
		transition_status = {
			"target_scene": String(active_player_transition.get("target_scene", "")),
			"target_spawn": StringName(active_player_transition.get("target_spawn", &"")),
			"world_lock_token": int(active_player_transition.get("world_lock_token", 0)),
			"player_claim_token": int(active_player_transition.get("player_claim_token", 0)),
		}

	return {
		"loading": loading_scene_path if loading_in_progress else "",
		"preloads": preloads,
		"cache_size": cached_scenes.size(),
		"player_transition": transition_status,
	}


func _change_scene_to_cached(scene_path: String) -> void:
	var packed_scene := cached_scenes.get(scene_path, null) as PackedScene
	if packed_scene == null:
		_breadcrumb("scene_loader:packed_missing", scene_path)
		_finish_scene_load(false, scene_path)
		return

	_breadcrumb("scene_loader:change_packed_before", scene_path)
	var error := get_tree().change_scene_to_packed(packed_scene)
	_breadcrumb("scene_loader:change_packed_after", "%s error=%d" % [scene_path, error])
	if error != OK:
		push_warning("Could not change scene to loaded scene: %s" % scene_path)
		_finish_scene_load(false, scene_path)
		return

	if not keep_loaded_scene_cache:
		cached_scenes.erase(scene_path)

	_finish_scene_load(true, scene_path)


func _track_preload(scene_path: String) -> void:
	if scene_path.is_empty():
		return

	if not pending_preload_paths.has(scene_path):
		pending_preload_paths[scene_path] = -1.0
	set_process(true)


func _poll_preloads(delta: float) -> void:
	if pending_preload_paths.is_empty():
		return

	preload_poll_timer -= delta
	if preload_poll_timer > 0.0:
		return

	preload_poll_timer = preload_status_poll_seconds
	for scene_path_key in pending_preload_paths.keys():
		var scene_path := String(scene_path_key)
		var progress: Array = []
		var status := ResourceLoader.load_threaded_get_status(scene_path, progress)
		var progress_value := float(progress[0]) if not progress.is_empty() else 0.0

		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			_report_preload_progress(scene_path, progress_value)
			continue

		pending_preload_paths.erase(scene_path_key)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			_record_watchdog_marker(&"scene_loader:preload_ready", scene_path)
		elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_record_watchdog_marker(&"scene_loader:preload_failed", "%s %s" % [
				scene_path.get_file(),
				_get_thread_status_label(status),
			])


func _report_preload_progress(scene_path: String, progress: float) -> void:
	var previous_progress := float(pending_preload_paths.get(scene_path, -1.0))
	var clamped_progress := clampf(progress, 0.0, 1.0)
	if previous_progress >= 0.0 and clamped_progress < previous_progress + 0.25:
		return

	pending_preload_paths[scene_path] = clamped_progress
	_record_watchdog_marker(&"scene_loader:preload_progress", "%s %d%%" % [
		scene_path.get_file(),
		int(round(clamped_progress * 100.0)),
	])


func _change_scene_blocking(scene_path: String) -> void:
	_breadcrumb("scene_loader:change_file_before", scene_path)
	var error := get_tree().change_scene_to_file(scene_path)
	_breadcrumb("scene_loader:change_file_after", "%s error=%d" % [scene_path, error])
	if error != OK:
		push_warning("Could not change scene: %s" % scene_path)
		_finish_scene_load(false, scene_path)
		return

	_finish_scene_load(true, scene_path)


func _finish_scene_load(success: bool, scene_path: String) -> void:
	_breadcrumb("scene_loader:finish", "%s %s" % ["ok" if success else "fail", scene_path])
	_record_watchdog_marker(&"scene_loader:finish", "%s %s" % ["ok" if success else "fail", scene_path])
	pending_preload_paths.erase(scene_path)
	loading_in_progress = false
	loading_scene_path = ""
	visible = false
	set_process(not pending_preload_paths.is_empty())
	if not active_player_transition.is_empty():
		var target_spawn := StringName(active_player_transition.get("target_spawn", &""))
		_log_player_transition(
			"load_success" if success else "load_failure",
			scene_path,
			target_spawn,
			&"success" if success else &"failure"
		)
		_cleanup_player_scene_transition(not success, &"load_success" if success else &"load_failure")
	scene_load_finished.emit(success, scene_path)


func _validate_player_scene_transition(player: Node, target_scene_path: String) -> StringName:
	if player == null or not is_instance_valid(player):
		return &"player_invalid"
	if target_scene_path.is_empty():
		return &"target_scene_empty"
	if not active_player_transition.is_empty():
		return &"player_transition_active"
	if loading_in_progress:
		return &"scene_load_active"
	var runtime := get_node_or_null("/root/PlayerRuntime")
	if (
		runtime == null
		or not runtime.has_method("capture_player")
		or not runtime.has_method("clear_pending_player_transfer")
		or not runtime.has_method("has_pending_player_data")
	):
		return &"player_runtime_unavailable"
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if (
		gameplay_flow == null
		or not gameplay_flow.has_method("acquire_world_progression_lock")
		or not gameplay_flow.has_method("release_world_progression_lock")
		or not gameplay_flow.has_method("acquire_player_control_claim")
		or not gameplay_flow.has_method("release_player_control_claim")
	):
		return &"gameplay_flow_unavailable"
	if not player.has_method("can_accept_player_control_claim"):
		return &"player_claim_eligibility_unavailable"
	var eligibility = player.call("can_accept_player_control_claim", &"ui_only")
	if not (eligibility is Dictionary) or not bool(eligibility.get("accepted", false)):
		return StringName(String(
			eligibility.get("reason", "player_claim_rejected")
			if eligibility is Dictionary
			else "player_claim_rejected"
		))
	if not cached_scenes.has(target_scene_path) and not ResourceLoader.exists(
		target_scene_path, "PackedScene"
	):
		return &"target_scene_unavailable"
	return &""


func _cleanup_player_scene_transition(clear_pending_transfer: bool, outcome: StringName) -> void:
	if active_player_transition.is_empty():
		return
	var transaction := active_player_transition
	active_player_transition = {}
	var runtime := get_node_or_null("/root/PlayerRuntime")
	if clear_pending_transfer and runtime != null and runtime.has_method("clear_pending_player_transfer"):
		runtime.call("clear_pending_player_transfer")
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	var player_claim_token := int(transaction.get("player_claim_token", 0))
	var world_lock_token := int(transaction.get("world_lock_token", 0))
	var player_released := false
	var world_released := false
	if (
		player_claim_token != 0
		and gameplay_flow != null
		and gameplay_flow.has_method("release_player_control_claim")
	):
		player_released = bool(gameplay_flow.call(
			"release_player_control_claim", player_claim_token, self
		))
	if (
		world_lock_token != 0
		and gameplay_flow != null
		and gameplay_flow.has_method("release_world_progression_lock")
	):
		world_released = bool(gameplay_flow.call(
			"release_world_progression_lock", world_lock_token, self
		))
	if OS.is_debug_build():
		print("Player scene transition cleanup: outcome=%s player_claim=%d:%s world_lock=%d:%s" % [
			String(outcome), player_claim_token, str(player_released),
			world_lock_token, str(world_released),
		])


func _log_player_transition(
	event: String,
	target_scene_path: String,
	target_spawn_id: StringName,
	result: StringName,
	world_lock_token: int = 0,
	player_claim_token: int = 0
) -> void:
	if not OS.is_debug_build():
		return
	print("Player scene transition %s: target=%s spawn=%s result=%s world_lock=%d player_claim=%d" % [
		event,
		target_scene_path,
		String(target_spawn_id),
		String(result),
		world_lock_token,
		player_claim_token,
	])


func _cache_threaded_scene(scene_path: String) -> bool:
	_breadcrumb("scene_loader:threaded_get_before", scene_path)
	var resource := ResourceLoader.load_threaded_get(scene_path)
	var packed_scene := resource as PackedScene
	if packed_scene == null:
		_breadcrumb("scene_loader:threaded_get_failed", scene_path)
		return false

	pending_preload_paths.erase(scene_path)
	cached_scenes[scene_path] = packed_scene
	_breadcrumb("scene_loader:threaded_get_ok", scene_path)
	return true


func _get_thread_status_label(status: int) -> String:
	if status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		return "invalid"
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return "loading"
	if status == ResourceLoader.THREAD_LOAD_FAILED:
		return "failed"
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		return "loaded"

	return "status_%d" % status


func _build_overlay() -> void:
	var root := Control.new()
	root.name = "SceneLoaderRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	overlay = ColorRect.new()
	overlay.name = "SceneLoaderOverlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0.14902, 0.192157, 0.180392, 0.78)
	root.add_child(overlay)

	var center := CenterContainer.new()
	center.name = "SceneLoaderCenter"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	loading_label = Label.new()
	loading_label.name = "SceneLoaderLabel"
	loading_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	loading_label.add_theme_font_size_override("font_size", 18)
	loading_label.add_theme_color_override("font_color", Color(1.0, 0.945098, 0.823529, 1.0))
	loading_label.add_theme_color_override("font_shadow_color", Color(0.501961, 0.4, 0.278431, 0.5))
	loading_label.add_theme_constant_override("shadow_offset_x", 1)
	loading_label.add_theme_constant_override("shadow_offset_y", 1)
	loading_label.text = "LOADING"
	center.add_child(loading_label)


func _show_loading_overlay(progress: float) -> void:
	if not show_loading_overlay:
		visible = false
		return

	visible = true
	if loading_label == null:
		return

	var percent := int(round(clampf(progress, 0.0, 1.0) * 100.0))
	loading_label.text = "LOADING %d%%" % percent


func _record_watchdog_marker(source: StringName, detail: String = "") -> void:
	var watchdog := get_node_or_null("/root/PerformanceWatchdog")
	if watchdog != null and watchdog.has_method("record_marker"):
		watchdog.call("record_marker", source, detail)


func _debug_flag(flag_name: StringName) -> bool:
	if not DebugToolsConfig.TROUBLESHOOTING_MODE:
		return false
	match flag_name:
		&"DEBUG_DISABLE_SCENE_PRELOADS":
			return DebugToolsConfig.DEBUG_DISABLE_SCENE_PRELOADS
		&"DEBUG_FORCE_BLOCKING_SCENE_LOADS":
			return DebugToolsConfig.DEBUG_FORCE_BLOCKING_SCENE_LOADS
	return false


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
