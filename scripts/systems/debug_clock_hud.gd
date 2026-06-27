extends CanvasLayer

@export var debug_clock_enabled: bool = true
@export var panel_offset: Vector2 = Vector2(14.0, 14.0)
@export var event_lifetime_seconds: float = 2.4
@export var max_event_lines: int = 6
@export var clock_refresh_seconds: float = 0.25
@export var show_time_bus_events: bool = false

var clock_label: Label
var event_stack: VBoxContainer
var event_lines: Array[Dictionary] = []
var clock_refresh_timer: float = 0.0
var cached_player: Node


func _ready() -> void:
	layer = 100
	if not DebugToolsConfig.CLOCK_HP_EVENTS_HUD_ENABLED:
		debug_clock_enabled = false
		visible = false
		set_process(false)
		return

	visible = debug_clock_enabled
	set_process(debug_clock_enabled)
	if not debug_clock_enabled:
		return

	_build_ui()
	_connect_world_time()
	_connect_event_bus()
	_update_clock()


func _process(delta: float) -> void:
	clock_refresh_timer -= delta
	if clock_refresh_seconds <= 0.0 or clock_refresh_timer <= 0.0:
		clock_refresh_timer = clock_refresh_seconds
		_update_clock()

	_update_event_lines(delta)


func _build_ui() -> void:
	var root := Control.new()
	root.name = "DebugClockRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var panel_size := Vector2(178.0, 46.0)
	var panel := PanelContainer.new()
	panel.name = "DebugClockPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -panel_size.x - panel_offset.x
	panel.offset_top = panel_offset.y
	panel.offset_right = -panel_offset.x
	panel.offset_bottom = panel_offset.y + panel_size.y
	panel.add_theme_stylebox_override("panel", _make_debug_panel_style())
	root.add_child(panel)

	clock_label = Label.new()
	clock_label.name = "ClockAndHp"
	clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clock_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	clock_label.add_theme_font_size_override("font_size", 12)
	clock_label.add_theme_color_override("font_color", Color(0.94, 0.97, 1.0, 0.97))
	clock_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	clock_label.add_theme_constant_override("shadow_offset_x", 1)
	clock_label.add_theme_constant_override("shadow_offset_y", 1)
	panel.add_child(clock_label)

	event_stack = VBoxContainer.new()
	event_stack.name = "EventLines"
	event_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	event_stack.anchor_left = 1.0
	event_stack.anchor_right = 1.0
	event_stack.offset_left = -panel_size.x - panel_offset.x
	event_stack.offset_top = panel_offset.y + panel_size.y + 4.0
	event_stack.offset_right = -panel_offset.x
	event_stack.offset_bottom = panel_offset.y + panel_size.y + 80.0
	event_stack.add_theme_constant_override("separation", 1)
	root.add_child(event_stack)


func _make_debug_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.03, 0.04, 0.76)
	style.border_color = Color(0.72, 0.82, 0.94, 0.22)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 2
	style.corner_radius_bottom_left = 2
	style.corner_radius_bottom_right = 2
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.30)
	style.shadow_size = 2
	style.set_content_margin(SIDE_LEFT, 7.0)
	style.set_content_margin(SIDE_TOP, 5.0)
	style.set_content_margin(SIDE_RIGHT, 7.0)
	style.set_content_margin(SIDE_BOTTOM, 5.0)
	return style


func _connect_world_time() -> void:
	if not has_node("/root/WorldTime"):
		return

	var callback := Callable(self, "_on_world_time_changed")
	if not WorldTime.time_changed.is_connected(callback):
		WorldTime.time_changed.connect(callback)


func _connect_event_bus() -> void:
	if not has_node("/root/EventBus"):
		return

	var callback := Callable(self, "_on_event_bus_event")
	if not EventBus.event_emitted.is_connected(callback):
		EventBus.event_emitted.connect(callback)


func _on_world_time_changed(_snapshot: Dictionary) -> void:
	_update_clock()


func _on_event_bus_event(event_name: StringName, payload: Dictionary) -> void:
	if not show_time_bus_events and String(event_name) == "time_changed":
		return
	_add_event_line(event_name, payload)


func _update_clock() -> void:
	if clock_label == null:
		return

	var time_text := "Time --:--"
	var period_text := ""
	var day_text := "Day --"
	if has_node("/root/WorldTime"):
		var snapshot: Dictionary = WorldTime.get_snapshot()
		day_text = "Day %d" % int(snapshot.get("day", 0))
		time_text = "%02d:%02d" % [int(snapshot.get("hour", 0)), int(snapshot.get("minute", 0))]
		period_text = String(snapshot.get("period", &""))

	clock_label.text = "%s  %s\nHP %s  %s" % [
		day_text,
		time_text,
		_get_player_hp_text(),
		period_text,
	]


func _get_player_hp_text() -> String:
	var player := _get_player()
	if player == null:
		return "--/--"

	var hp = _get_property_if_present(player, &"hp")
	var max_hp = _get_property_if_present(player, &"max_hp")
	if hp == null or max_hp == null:
		return "--/--"

	return "%d/%d" % [int(round(float(hp))), int(round(float(max_hp)))]


func _add_event_line(event_name: StringName, payload: Dictionary) -> void:
	if event_stack == null:
		return

	var line := Label.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_theme_font_size_override("font_size", 12)
	line.add_theme_color_override("font_color", Color(0.62, 0.86, 1.0, 0.92))
	line.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	line.add_theme_constant_override("shadow_offset_x", 1)
	line.add_theme_constant_override("shadow_offset_y", 1)
	line.text = _format_event_text(event_name, payload)
	event_stack.add_child(line)
	event_lines.append({"label": line, "age": 0.0})

	while event_lines.size() > max_event_lines:
		var old_line: Dictionary = event_lines.pop_front()
		var old_label := old_line.get("label", null) as Label
		if old_label != null:
			old_label.queue_free()


func _update_event_lines(delta: float) -> void:
	for index in range(event_lines.size() - 1, -1, -1):
		var line_data: Dictionary = event_lines[index]
		var label := line_data.get("label", null) as Label
		if label == null:
			event_lines.remove_at(index)
			continue

		var age := float(line_data.get("age", 0.0)) + delta
		line_data["age"] = age
		event_lines[index] = line_data

		var alpha := 1.0 - clampf(age / maxf(event_lifetime_seconds, 0.001), 0.0, 1.0)
		label.modulate.a = alpha

		if age >= event_lifetime_seconds:
			label.queue_free()
			event_lines.remove_at(index)


func _format_event_text(event_name: StringName, payload: Dictionary) -> String:
	var event_text := String(event_name)
	if payload.has("period"):
		event_text += "  %s" % String(payload["period"])
	elif payload.has("hour") and payload.has("minute"):
		event_text += "  %02d:%02d" % [int(payload["hour"]), int(payload["minute"])]

	return event_text


func _get_player() -> Node:
	if cached_player != null and is_instance_valid(cached_player):
		return cached_player

	var player := get_tree().get_first_node_in_group("player") as Node
	if player == null or not is_instance_valid(player):
		return null

	cached_player = player
	return player


func _get_property_if_present(node: Object, property_name: StringName):
	for property in node.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return node.get(property_name)

	return null
