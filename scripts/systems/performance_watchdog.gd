class_name PerformanceWatchdogSystem extends CanvasLayer

@export var enabled: bool = true
@export var starts_visible: bool = true
@export var toggle_action: StringName = &""
@export_range(8.0, 250.0, 1.0, "suffix:ms") var spike_threshold_ms: float = 34.0
@export_range(0.05, 2.0, 0.05, "suffix:s") var hud_refresh_seconds: float = 0.25
@export_range(0.25, 5.0, 0.05, "suffix:s") var scene_scan_seconds: float = 1.0
@export var log_scene_summaries: bool = true
@export_range(1, 10, 1, "suffix:frames") var scene_summary_delay_frames: int = 2
@export_range(0.5, 10.0, 0.1, "suffix:s") var activity_window_seconds: float = 2.0
@export var track_event_bus: bool = true
@export var track_world_time: bool = true
@export var track_npc_state_machines: bool = true
@export var track_save_system: bool = true
@export var print_spikes: bool = false
@export var write_spike_log_file: bool = true
@export var write_periodic_samples: bool = true
@export var spike_log_file_path: String = "res://performance_watchdog.log"
@export var clear_spike_log_on_start: bool = true
@export_range(1.0, 30.0, 0.5, "suffix:s") var sample_log_seconds: float = 5.0
@export_range(0.25, 10.0, 0.25, "suffix:s") var spike_log_flush_seconds: float = 2.0
@export_range(4, 128, 1, "suffix:lines") var spike_log_batch_line_limit: int = 48
@export_range(0.0, 20.0, 0.5, "suffix:ms") var log_flush_marker_threshold_ms: float = 2.0

const MAX_RECENT_MARKERS := 18
const MAX_SPIKES := 8
const MAX_COUNT_LINES := 8
const MAX_LARGEST_TEXTURES := 4
const MAX_ACTIVE_NODE_NAMES := 8

var panel: ColorRect
var label: Label
var recent_markers: Array[Dictionary] = []
var recent_spikes: Array[Dictionary] = []
var activity_counts: Dictionary = {}
var connected_machines: Dictionary = {}

var hud_timer: float = 0.0
var scene_scan_timer: float = 0.0
var activity_window_timer: float = 0.0
var log_flush_timer: float = 0.0
var sample_log_timer: float = 0.0
var average_frame_ms: float = 0.0
var worst_frame_ms: float = 0.0
var sample_worst_frame_ms: float = 0.0
var frames_seen: int = 0
var run_started_msec: int = 0
var pending_log_lines: Array[String] = []
var last_scene_instance_id: int = -1
var pending_scene_summary_scene: Node
var pending_scene_summary_frames: int = -1


func _ready() -> void:
	layer = 120
	if not DebugToolsConfig.PERFORMANCE_WATCHDOG_ENABLED:
		enabled = false
		starts_visible = false
		write_spike_log_file = false
		print_spikes = false
		visible = false
		set_process(false)
		return

	visible = starts_visible
	run_started_msec = Time.get_ticks_msec()
	_prepare_log_file()
	set_process(enabled)
	if not enabled:
		return

	_build_hud()
	call_deferred("_connect_global_signals")
	call_deferred("_scan_scene_for_debug_targets")


func _process(delta: float) -> void:
	_watch_current_scene()
	_update_pending_scene_summary()

	var frame_ms := delta * 1000.0
	frames_seen += 1
	if frames_seen == 1:
		average_frame_ms = frame_ms
	else:
		average_frame_ms = lerpf(average_frame_ms, frame_ms, 0.06)

	worst_frame_ms = maxf(worst_frame_ms, frame_ms)
	sample_worst_frame_ms = maxf(sample_worst_frame_ms, frame_ms)

	if toggle_action != &"" and InputMap.has_action(toggle_action) and Input.is_action_just_pressed(toggle_action):
		visible = not visible

	activity_window_timer += delta
	if activity_window_timer >= activity_window_seconds:
		activity_window_timer = 0.0
		activity_counts.clear()

	scene_scan_timer -= delta
	if scene_scan_timer <= 0.0:
		scene_scan_timer = scene_scan_seconds
		_scan_scene_for_debug_targets()

	if frame_ms >= spike_threshold_ms:
		_record_spike(frame_ms)

	if write_periodic_samples and write_spike_log_file and sample_log_seconds > 0.0:
		sample_log_timer += delta
		if sample_log_timer >= sample_log_seconds:
			sample_log_timer = 0.0
			_record_sample(frame_ms)

	log_flush_timer -= delta
	if log_flush_timer <= 0.0:
		log_flush_timer = spike_log_flush_seconds
		_flush_log_lines()

	hud_timer -= delta
	if visible and hud_timer <= 0.0:
		hud_timer = hud_refresh_seconds
		_update_hud()
		worst_frame_ms = frame_ms


func _exit_tree() -> void:
	_flush_log_lines()


func record_marker(source: StringName, detail: String = "") -> void:
	if not enabled or not DebugToolsConfig.PERFORMANCE_WATCHDOG_ENABLED:
		return

	_record_marker(String(source), detail)


func _watch_current_scene() -> void:
	if not log_scene_summaries or get_tree() == null:
		return

	var current_scene := get_tree().current_scene
	var current_scene_id := 0
	if current_scene != null and is_instance_valid(current_scene):
		current_scene_id = current_scene.get_instance_id()

	if current_scene_id == last_scene_instance_id:
		return

	last_scene_instance_id = current_scene_id
	var scene_label := _get_scene_label()
	_record_marker("scene:changed", scene_label)

	if write_spike_log_file:
		_append_log_line("Scene changed t=%.2fs scene=%s" % [_get_run_time_seconds(), scene_label])

	if current_scene == null:
		pending_scene_summary_scene = null
		pending_scene_summary_frames = -1
		return

	pending_scene_summary_scene = current_scene
	pending_scene_summary_frames = maxi(scene_summary_delay_frames, 1)


func _update_pending_scene_summary() -> void:
	if not log_scene_summaries or pending_scene_summary_frames < 0:
		return

	if pending_scene_summary_scene == null or not is_instance_valid(pending_scene_summary_scene):
		pending_scene_summary_scene = null
		pending_scene_summary_frames = -1
		return

	pending_scene_summary_frames -= 1
	if pending_scene_summary_frames > 0:
		return

	var summary := _build_scene_summary(pending_scene_summary_scene)
	var line := _format_scene_summary_line(summary)
	if print_spikes:
		print(line)
	if write_spike_log_file:
		_append_log_line(line)

	pending_scene_summary_scene = null
	pending_scene_summary_frames = -1


func _build_scene_summary(scene_root: Node) -> Dictionary:
	var stats := {
		"time_seconds": _get_run_time_seconds(),
		"scene": _get_scene_label_for(scene_root),
		"nodes": 0,
		"scripted_nodes": 0,
		"process_nodes": 0,
		"physics_process_nodes": 0,
		"process_node_names": [],
		"physics_process_node_names": [],
		"autoload_process_names": [],
		"autoload_physics_process_names": [],
		"canvas_items": 0,
		"hidden_canvas_items": 0,
		"sprites": 0,
		"animated_sprites": 0,
		"texture_rects": 0,
		"tilemaps": 0,
		"collision_shapes": 0,
		"collision_polygons": 0,
		"areas": 0,
		"bodies": 0,
		"textures": {},
		"largest_textures": [],
	}

	_scan_scene_summary_node(scene_root, stats)
	_scan_autoload_process_nodes(scene_root, stats)
	var textures: Dictionary = stats.get("textures", {})
	stats["unique_textures"] = textures.size()
	stats.erase("textures")
	return stats


func _scan_scene_summary_node(node: Node, stats: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return

	_increment_stat(stats, "nodes")
	if node.get_script() != null:
		_increment_stat(stats, "scripted_nodes")
	if node.is_processing():
		_increment_stat(stats, "process_nodes")
		_add_limited_node_label(stats, "process_node_names", node)
	if node.is_physics_processing():
		_increment_stat(stats, "physics_process_nodes")
		_add_limited_node_label(stats, "physics_process_node_names", node)

	var canvas_item := node as CanvasItem
	if canvas_item != null:
		_increment_stat(stats, "canvas_items")
		if not canvas_item.is_visible_in_tree():
			_increment_stat(stats, "hidden_canvas_items")

	var sprite := node as Sprite2D
	if sprite != null:
		_increment_stat(stats, "sprites")
		_record_texture(sprite.texture, stats, sprite)

	var animated_sprite := node as AnimatedSprite2D
	if animated_sprite != null:
		_increment_stat(stats, "animated_sprites")
		_record_sprite_frames_textures(animated_sprite.sprite_frames, stats, animated_sprite)

	var texture_rect := node as TextureRect
	if texture_rect != null:
		_increment_stat(stats, "texture_rects")
		_record_texture(texture_rect.texture, stats, texture_rect)

	var tile_map := node as TileMap
	if tile_map != null:
		_increment_stat(stats, "tilemaps")
		_record_tile_set_textures(tile_map.tile_set, stats, tile_map)

	if node is CollisionShape2D:
		_increment_stat(stats, "collision_shapes")
	if node is CollisionPolygon2D:
		_increment_stat(stats, "collision_polygons")
	if node is Area2D:
		_increment_stat(stats, "areas")
	if node is PhysicsBody2D:
		_increment_stat(stats, "bodies")

	for child in node.get_children():
		_scan_scene_summary_node(child, stats)


func _scan_autoload_process_nodes(scene_root: Node, stats: Dictionary) -> void:
	if get_tree() == null or get_tree().root == null:
		return

	for child in get_tree().root.get_children():
		if child == scene_root:
			continue

		if child.is_processing():
			_add_limited_node_label(stats, "autoload_process_names", child)
		if child.is_physics_processing():
			_add_limited_node_label(stats, "autoload_physics_process_names", child)


func _record_sprite_frames_textures(sprite_frames: SpriteFrames, stats: Dictionary, owner_node: Node) -> void:
	if sprite_frames == null:
		return

	for animation_name in sprite_frames.get_animation_names():
		var frame_count := sprite_frames.get_frame_count(animation_name)
		for frame_index in range(frame_count):
			_record_texture(sprite_frames.get_frame_texture(animation_name, frame_index), stats, owner_node)


func _record_tile_set_textures(tile_set: TileSet, stats: Dictionary, owner_node: Node) -> void:
	if tile_set == null:
		return

	for index in range(tile_set.get_source_count()):
		var source_id := tile_set.get_source_id(index)
		var source := tile_set.get_source(source_id)
		if source == null:
			continue

		var texture := source.get("texture") as Texture2D
		_record_texture(texture, stats, owner_node)


func _record_texture(texture_value: Texture2D, stats: Dictionary, owner_node: Node) -> void:
	if texture_value == null:
		return

	var texture := _get_backing_texture(texture_value)
	if texture == null:
		return

	var texture_id := texture.get_instance_id()
	var textures: Dictionary = stats.get("textures", {})
	if textures.has(texture_id):
		return

	textures[texture_id] = true
	stats["textures"] = textures

	var width := texture.get_width()
	var height := texture.get_height()
	var path := texture.resource_path
	if path.is_empty():
		path = texture.resource_name

	var largest_textures: Array = stats.get("largest_textures", [])
	largest_textures.append({
		"pixels": width * height,
		"width": width,
		"height": height,
		"path": path,
		"owner": _get_node_label(owner_node),
	})
	largest_textures.sort_custom(Callable(self, "_sort_texture_rows_desc"))
	while largest_textures.size() > MAX_LARGEST_TEXTURES:
		largest_textures.pop_back()
	stats["largest_textures"] = largest_textures


func _get_backing_texture(texture: Texture2D) -> Texture2D:
	var atlas_texture := texture as AtlasTexture
	if atlas_texture != null and atlas_texture.atlas != null:
		return atlas_texture.atlas

	return texture


func _increment_stat(stats: Dictionary, key: String) -> void:
	stats[key] = int(stats.get(key, 0)) + 1


func _add_limited_node_label(stats: Dictionary, key: String, node: Node) -> void:
	var labels: Array = stats.get(key, [])
	if labels.size() >= MAX_ACTIVE_NODE_NAMES:
		return

	labels.append(_get_node_label(node))
	stats[key] = labels


func _sort_texture_rows_desc(first: Dictionary, second: Dictionary) -> bool:
	return int(first.get("pixels", 0)) > int(second.get("pixels", 0))


func _build_hud() -> void:
	var root := Control.new()
	root.name = "PerformanceWatchdogRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	panel = ColorRect.new()
	panel.name = "PerformanceWatchdogPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.position = Vector2(14.0, 118.0)
	panel.size = Vector2(520.0, 220.0)
	panel.color = Color(0.0, 0.0, 0.0, 0.58)
	root.add_child(panel)

	label = Label.new()
	label.name = "PerformanceWatchdogText"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.position = Vector2(8.0, 8.0)
	label.size = Vector2(504.0, 204.0)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.92, 1.0, 0.88, 0.98))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	panel.add_child(label)


func _connect_global_signals() -> void:
	if track_event_bus:
		var event_bus := get_node_or_null("/root/EventBus")
		if event_bus != null and event_bus.has_signal(&"event_emitted"):
			var callback := Callable(self, "_on_event_bus_event")
			if not event_bus.is_connected(&"event_emitted", callback):
				event_bus.connect(&"event_emitted", callback)

	if track_world_time:
		var world_time := get_node_or_null("/root/WorldTime")
		if world_time != null:
			_connect_signal_if_present(world_time, &"time_changed", "_on_world_time_changed")
			_connect_signal_if_present(world_time, &"hour_changed", "_on_world_time_hour_changed")
			_connect_signal_if_present(world_time, &"day_changed", "_on_world_time_day_changed")
			_connect_signal_if_present(world_time, &"period_changed", "_on_world_time_period_changed")

	if track_save_system:
		var save_system := get_node_or_null("/root/SaveSystem")
		if save_system != null:
			_connect_signal_if_present(save_system, &"save_finished", "_on_save_finished")
			_connect_signal_if_present(save_system, &"load_finished", "_on_load_finished")


func _connect_signal_if_present(target: Object, signal_name: StringName, method_name: StringName) -> void:
	if target == null or not target.has_signal(signal_name):
		return

	var callback := Callable(self, String(method_name))
	if not target.is_connected(signal_name, callback):
		target.connect(signal_name, callback)


func _scan_scene_for_debug_targets() -> void:
	if not track_npc_state_machines or get_tree() == null:
		return

	_prune_machine_connections()

	for npc_node in get_tree().get_nodes_in_group("social_npc"):
		var npc := npc_node as Node
		if npc == null or not is_instance_valid(npc):
			continue

		var machine := npc.get_node_or_null("NpcStateMachine") as NpcStateMachine
		_connect_machine(machine)


func _connect_machine(machine: NpcStateMachine) -> void:
	if machine == null or not is_instance_valid(machine):
		return

	var machine_id := machine.get_instance_id()
	if connected_machines.has(machine_id):
		return

	var state_callback := Callable(self, "_on_npc_state_changed").bind(machine)
	if not machine.state_changed.is_connected(state_callback):
		machine.state_changed.connect(state_callback)

	var values_callback := Callable(self, "_on_npc_values_changed").bind(machine)
	if not machine.values_changed.is_connected(values_callback):
		machine.values_changed.connect(values_callback)

	connected_machines[machine_id] = true
	_record_marker("watch:npc_machine_connected", _get_node_label(machine))


func _prune_machine_connections() -> void:
	for machine_id in connected_machines.keys():
		var object := instance_from_id(int(machine_id))
		if object == null or not is_instance_valid(object):
			connected_machines.erase(machine_id)


func _on_event_bus_event(event_name: StringName, payload: Dictionary) -> void:
	var scope := String(payload.get("scope", ""))
	var detail := scope
	if payload.has("event_name") and String(payload["event_name"]) != String(event_name):
		detail = "%s/%s" % [scope, String(payload["event_name"])]

	_record_marker("event:%s" % String(event_name), detail)


func _on_world_time_changed(_snapshot: Dictionary) -> void:
	_record_marker("time:changed")


func _on_world_time_hour_changed(hour: int, _snapshot: Dictionary) -> void:
	_record_marker("time:hour", str(hour))


func _on_world_time_day_changed(day: int, _snapshot: Dictionary) -> void:
	_record_marker("time:day", str(day))


func _on_world_time_period_changed(period: StringName, _snapshot: Dictionary) -> void:
	_record_marker("time:period", String(period))


func _on_save_finished(success: bool, save_path: String) -> void:
	_record_marker("save:finished", "%s %s" % ["ok" if success else "fail", save_path])


func _on_load_finished(success: bool, save_path: String) -> void:
	_record_marker("load:finished", "%s %s" % ["ok" if success else "fail", save_path])


func _on_npc_state_changed(
	state_name: StringName,
	previous_state_name: StringName,
	machine: NpcStateMachine
) -> void:
	_record_marker(
		"npc:state",
		"%s %s->%s" % [_get_machine_owner_label(machine), String(previous_state_name), String(state_name)]
	)


func _on_npc_values_changed(
	_values: Dictionary,
	changed_values: Dictionary,
	_actor: Node2D,
	machine: NpcStateMachine
) -> void:
	if changed_values.is_empty():
		_record_marker("npc:values_empty", _get_machine_owner_label(machine))
		return

	_record_marker(
		"npc:values",
		"%s %s" % [_get_machine_owner_label(machine), _format_keys(changed_values.keys(), 4)]
	)


func _record_marker(source: String, detail: String = "") -> void:
	var key := source
	activity_counts[key] = int(activity_counts.get(key, 0)) + 1

	recent_markers.push_front({
		"time_ms": Time.get_ticks_msec(),
		"source": source,
		"detail": detail,
	})

	while recent_markers.size() > MAX_RECENT_MARKERS:
		recent_markers.pop_back()


func _record_spike(frame_ms: float) -> void:
	var spike := {
		"time_ms": Time.get_ticks_msec(),
		"frame_ms": frame_ms,
		"scene": _get_scene_label(),
		"counts": activity_counts.duplicate(true),
		"markers": recent_markers.duplicate(true),
		"engine": _build_engine_snapshot(),
		"loader": _build_loader_snapshot(),
	}
	recent_spikes.push_front(spike)

	while recent_spikes.size() > MAX_SPIKES:
		recent_spikes.pop_back()

	var line := _format_spike_line(spike)
	if print_spikes:
		print(line)
	if write_spike_log_file:
		_append_log_line(line)


func _record_sample(current_frame_ms: float) -> void:
	var line := "Perf sample t=%.2fs frame %.1f ms avg %.1f ms sample_worst %.1f ms scene=%s counts=%s engine=%s loader=%s" % [
		_get_run_time_seconds(),
		current_frame_ms,
		average_frame_ms,
		sample_worst_frame_ms,
		_get_scene_label(),
		_format_counts(activity_counts, MAX_COUNT_LINES),
		_format_engine_snapshot(_build_engine_snapshot()),
		_format_loader_snapshot(_build_loader_snapshot()),
	]
	_append_log_line(line)
	sample_worst_frame_ms = current_frame_ms


func _build_engine_snapshot() -> Dictionary:
	return {
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"texture_mem_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"physics_2d_active": int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)),
		"physics_2d_pairs": int(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)),
	}


func _build_loader_snapshot() -> Dictionary:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("get_debug_status"):
		return {}

	var loader_status = scene_loader.call("get_debug_status")
	if loader_status is Dictionary:
		return loader_status

	return {}


func _update_hud() -> void:
	if label == null:
		return

	var lines: Array[String] = []
	lines.append("PERF WATCH  avg %.1f ms  worst %.1f ms  spikes %d" % [
		average_frame_ms,
		worst_frame_ms,
		recent_spikes.size(),
	])
	lines.append("scene: %s" % _get_scene_label())
	lines.append("activity %.1fs: %s" % [activity_window_seconds, _format_counts(activity_counts, MAX_COUNT_LINES)])

	if not recent_spikes.is_empty():
		var newest_spike: Dictionary = recent_spikes[0]
		lines.append("last spike: %.1f ms  %s" % [
			float(newest_spike.get("frame_ms", 0.0)),
			_format_age(int(newest_spike.get("time_ms", 0))),
		])
		lines.append("spike counts: %s" % _format_counts(newest_spike.get("counts", {}), MAX_COUNT_LINES))

	lines.append("recent:")
	for marker in recent_markers.slice(0, 6):
		lines.append("  %s %s" % [
			String(marker.get("source", "")),
			String(marker.get("detail", "")),
		])

	label.text = "\n".join(lines)
	_resize_panel(lines)


func _resize_panel(lines: Array[String]) -> void:
	if panel == null or label == null:
		return

	var longest_line := 0
	for line in lines:
		longest_line = maxi(longest_line, line.length())

	var width := clampf(float(longest_line * 7 + 24), 360.0, 760.0)
	var height := clampf(float(lines.size() * 15 + 22), 110.0, 360.0)
	panel.size = Vector2(width, height)
	label.size = Vector2(width - 16.0, height - 16.0)


func _format_spike_line(spike: Dictionary) -> String:
	return "Perf spike t=%.2fs %.1f ms scene=%s counts=%s engine=%s loader=%s recent=%s" % [
		(float(int(spike.get("time_ms", 0)) - run_started_msec) / 1000.0),
		float(spike.get("frame_ms", 0.0)),
		String(spike.get("scene", "")),
		_format_counts(spike.get("counts", {}), MAX_COUNT_LINES),
		_format_engine_snapshot(spike.get("engine", {})),
		_format_loader_snapshot(spike.get("loader", {})),
		_format_recent_markers(spike.get("markers", []), 5),
	]


func _format_scene_summary_line(summary: Dictionary) -> String:
	return (
		"Scene summary t=%.2fs scene=%s nodes=%d scripted=%d process=%d physics=%d "
		+ "canvas=%d hidden=%d sprites=%d animated=%d texture_rects=%d textures=%d "
		+ "tilemaps=%d collisions=%d areas=%d bodies=%d active=%s physics_active=%s "
		+ "globals=%s global_physics=%s largest=%s"
	) % [
		float(summary.get("time_seconds", 0.0)),
		String(summary.get("scene", "")),
		int(summary.get("nodes", 0)),
		int(summary.get("scripted_nodes", 0)),
		int(summary.get("process_nodes", 0)),
		int(summary.get("physics_process_nodes", 0)),
		int(summary.get("canvas_items", 0)),
		int(summary.get("hidden_canvas_items", 0)),
		int(summary.get("sprites", 0)),
		int(summary.get("animated_sprites", 0)),
		int(summary.get("texture_rects", 0)),
		int(summary.get("unique_textures", 0)),
		int(summary.get("tilemaps", 0)),
		int(summary.get("collision_shapes", 0)) + int(summary.get("collision_polygons", 0)),
		int(summary.get("areas", 0)),
		int(summary.get("bodies", 0)),
		_format_label_list(summary.get("process_node_names", [])),
		_format_label_list(summary.get("physics_process_node_names", [])),
		_format_label_list(summary.get("autoload_process_names", [])),
		_format_label_list(summary.get("autoload_physics_process_names", [])),
		_format_largest_textures(summary.get("largest_textures", [])),
	]


func _format_label_list(labels_value) -> String:
	if not (labels_value is Array):
		return "none"

	var labels: Array = labels_value
	if labels.is_empty():
		return "none"

	var rows: Array[String] = []
	for label_value in labels:
		rows.append(String(label_value))

	return "|".join(rows)


func _format_largest_textures(textures_value) -> String:
	if not (textures_value is Array):
		return "none"

	var textures: Array = textures_value
	if textures.is_empty():
		return "none"

	var rows: Array[String] = []
	for texture_info in textures:
		if not (texture_info is Dictionary):
			continue

		var texture_path := String(texture_info.get("path", ""))
		var texture_label := texture_path.get_file() if not texture_path.is_empty() else String(texture_info.get("owner", "texture"))
		rows.append("%dx%d %s" % [
			int(texture_info.get("width", 0)),
			int(texture_info.get("height", 0)),
			texture_label,
		])

	return " | ".join(rows)


func _format_engine_snapshot(snapshot_value) -> String:
	if not (snapshot_value is Dictionary):
		return "none"

	var snapshot: Dictionary = snapshot_value
	if snapshot.is_empty():
		return "none"

	return (
		"fps %.0f proc %.1fms phys %.1fms nodes %d res %d objs %d draw %d "
		+ "tex %.1fMB video %.1fMB 2d %d pairs %d"
	) % [
		float(snapshot.get("fps", 0.0)),
		float(snapshot.get("process_ms", 0.0)),
		float(snapshot.get("physics_ms", 0.0)),
		int(snapshot.get("nodes", 0)),
		int(snapshot.get("resources", 0)),
		int(snapshot.get("objects", 0)),
		int(snapshot.get("draw_calls", 0)),
		float(snapshot.get("texture_mem_mb", 0.0)),
		float(snapshot.get("video_mem_mb", 0.0)),
		int(snapshot.get("physics_2d_active", 0)),
		int(snapshot.get("physics_2d_pairs", 0)),
	]


func _format_loader_snapshot(snapshot_value) -> String:
	if not (snapshot_value is Dictionary):
		return "none"

	var snapshot: Dictionary = snapshot_value
	if snapshot.is_empty():
		return "none"

	var rows: Array[String] = []
	var loading := String(snapshot.get("loading", ""))
	if not loading.is_empty():
		rows.append("loading=%s" % loading.get_file())

	var preloads_value = snapshot.get("preloads", [])
	if preloads_value is Array and not preloads_value.is_empty():
		var preloads: Array = preloads_value
		rows.append("preloads=%s" % "|".join(preloads))

	var cache_size := int(snapshot.get("cache_size", 0))
	if cache_size > 0:
		rows.append("cache=%d" % cache_size)

	if rows.is_empty():
		return "idle"

	return " ".join(rows)


func _format_counts(counts_value, limit: int) -> String:
	if not (counts_value is Dictionary):
		return "none"

	var counts: Dictionary = counts_value
	if counts.is_empty():
		return "none"

	var rows: Array[String] = []
	for key in counts.keys():
		rows.append("%s:%d" % [String(key), int(counts[key])])

	rows.sort_custom(Callable(self, "_sort_count_rows_desc"))
	if rows.size() > limit:
		rows.resize(limit)

	return ", ".join(rows)


func _sort_count_rows_desc(first: String, second: String) -> bool:
	return _count_from_row(first) > _count_from_row(second)


func _count_from_row(row: String) -> int:
	var parts := row.split(":")
	if parts.size() < 2:
		return 0

	return int(parts[parts.size() - 1])


func _format_recent_markers(markers_value, limit: int) -> String:
	if not (markers_value is Array):
		return "none"

	var markers: Array = markers_value
	if markers.is_empty():
		return "none"

	var rows: Array[String] = []
	var count := mini(markers.size(), limit)
	for index in range(count):
		var marker = markers[index]
		if not (marker is Dictionary):
			continue

		rows.append("%s %s" % [
			String(marker.get("source", "")),
			String(marker.get("detail", "")),
		])

	return " | ".join(rows)


func _format_keys(keys: Array, limit: int) -> String:
	var rows: Array[String] = []
	var count := mini(keys.size(), limit)
	for index in range(count):
		rows.append(String(keys[index]))

	if keys.size() > limit:
		rows.append("+%d" % (keys.size() - limit))

	return ",".join(rows)


func _format_age(time_ms: int) -> String:
	var elapsed_ms := maxi(Time.get_ticks_msec() - time_ms, 0)
	return "%.1fs ago" % (float(elapsed_ms) / 1000.0)


func _get_run_time_seconds() -> float:
	return float(Time.get_ticks_msec() - run_started_msec) / 1000.0


func _get_scene_label() -> String:
	if get_tree() == null or get_tree().current_scene == null:
		return "none"

	return _get_scene_label_for(get_tree().current_scene)


func _get_scene_label_for(scene_node: Node) -> String:
	if scene_node == null:
		return "none"

	if not scene_node.scene_file_path.is_empty():
		return scene_node.scene_file_path.get_file()

	return scene_node.name


func _get_machine_owner_label(machine: NpcStateMachine) -> String:
	if machine == null or not is_instance_valid(machine):
		return "npc?"

	var owner_node := machine.get_parent()
	if owner_node != null:
		if owner_node.has_method("get_display_name"):
			return String(owner_node.call("get_display_name"))
		return String(owner_node.name)

	return String(machine.name)


func _get_node_label(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return "node?"

	if node.has_method("get_display_name"):
		return String(node.call("get_display_name"))

	return String(node.name)


func _prepare_log_file() -> void:
	if not write_spike_log_file or not clear_spike_log_on_start:
		return

	var file := FileAccess.open(spike_log_file_path, FileAccess.WRITE)
	if file == null:
		return

	file.store_line("Performance watchdog started")


func _append_log_line(line: String) -> void:
	pending_log_lines.append(line)
	if pending_log_lines.size() >= spike_log_batch_line_limit:
		_flush_log_lines()


func _flush_log_lines() -> void:
	if pending_log_lines.is_empty():
		return

	var line_count := pending_log_lines.size()
	var started_usec := Time.get_ticks_usec()
	var file := FileAccess.open(spike_log_file_path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(spike_log_file_path, FileAccess.WRITE)
	if file == null:
		return

	file.seek_end()
	for pending_line in pending_log_lines:
		file.store_line(pending_line)
	pending_log_lines.clear()

	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	if elapsed_ms >= log_flush_marker_threshold_ms:
		_record_marker("watch:log_flush", "%d lines %.1fms" % [line_count, elapsed_ms])
