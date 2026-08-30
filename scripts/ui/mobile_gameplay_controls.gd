class_name MobileGameplayControls
extends Control

const JOYSTICK_RADIUS := 76.0
const JOYSTICK_DEADZONE := 0.28
const BUTTON_RADIUS := 42.0
const MENU_TOUCH_SIZE := Vector2(104.0, 48.0)
const ACTION_LABELS := {
	&"attack": "Z",
	&"attach_rope": "X",
	&"charm": "C",
}
const ACTION_CAPTIONS := {
	&"attack": "ATTACK",
	&"attach_rope": "ROPE",
	&"charm": "ACT",
}

@export var force_enabled := false
@export var show_on_desktop := false

var _joystick_touch_id := -1
var _joystick_vector := Vector2.ZERO
var _touch_actions: Dictionary = {}
var _action_touch_counts: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_input(true)
	visibility_changed.connect(_on_visibility_changed)
	resized.connect(queue_redraw)
	_configure_mobile_window_scaling()
	_refresh_visibility()


func _exit_tree() -> void:
	_release_all_actions()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if get_tree().paused:
		_release_all_actions()
		return

	var touch := event as InputEventScreenTouch
	if touch != null:
		# MENU is an invisible touch target with a text-only affordance. Route it
		# through the project's PauseSystem so mobile uses exactly the same pause
		# state and menu as the keyboard Escape action.
		if touch.pressed and _is_menu_touch(touch.position):
			_request_pause_menu()
			get_viewport().set_input_as_handled()
			return

		var consumed := false
		if touch.pressed:
			consumed = _begin_touch(touch.index, touch.position)
		else:
			consumed = _end_touch(touch.index)
		# Do not swallow touches that belong to dialogue buttons, menus, the intro
		# phone slider, inventory UI, or any other GUI. The old version marked every
		# phone touch as handled even when it missed the gameplay controls.
		if consumed:
			get_viewport().set_input_as_handled()
		return

	var drag := event as InputEventScreenDrag
	if drag != null and drag.index == _joystick_touch_id:
		_update_joystick(drag.position)
		get_viewport().set_input_as_handled()


func refresh_for_platform() -> void:
	_configure_mobile_window_scaling()
	_refresh_visibility()


func get_joystick_center() -> Vector2:
	# Keep the movement control tight to the right edge while leaving enough
	# clearance for a full thumb-sized drag radius.
	return Vector2(size.x - 96.0, size.y - 104.0)


func get_action_button_center(action: StringName) -> Vector2:
	# Compact left-thumb triangle: Z/X sit low, C sits above between them. The
	# hit areas stay generous even though the rendered controls are text-only.
	match action:
		&"attack":
			return Vector2(56.0, size.y - 66.0)
		&"attach_rope":
			return Vector2(142.0, size.y - 66.0)
		&"charm":
			return Vector2(99.0, size.y - 152.0)
		_:
			return Vector2.ZERO


func get_menu_button_center() -> Vector2:
	return Vector2(size.x * 0.5, 34.0)


func get_joystick_vector() -> Vector2:
	return _joystick_vector


func _configure_mobile_window_scaling() -> void:
	if not OS.has_feature("mobile"):
		return
	var window := get_tree().root
	# Keep the pixel-art game rendered through a fixed virtual viewport, but let
	# wide/tall phones expose extra world instead of pillarboxing it. Fractional
	# scaling fills the available mobile game surface without changing aspect.
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL


func _refresh_visibility() -> void:
	visible = force_enabled or show_on_desktop or OS.has_feature("mobile")
	if not visible:
		_release_all_actions()
	queue_redraw()


func _is_menu_touch(position: Vector2) -> bool:
	var center := get_menu_button_center()
	return Rect2(center - MENU_TOUCH_SIZE * 0.5, MENU_TOUCH_SIZE).has_point(position)


func _request_pause_menu() -> void:
	_release_all_actions()
	var pause_system := get_node_or_null("/root/PauseSystem")
	if pause_system != null and pause_system.has_method("open_pause_menu"):
		pause_system.call("open_pause_menu")


func _begin_touch(touch_id: int, position: Vector2) -> bool:
	if _touch_actions.has(touch_id):
		return true

	if position.distance_to(get_joystick_center()) <= JOYSTICK_RADIUS * 1.15:
		_joystick_touch_id = touch_id
		_touch_actions[touch_id] = []
		_update_joystick(position)
		return true

	for action in ACTION_LABELS:
		if position.distance_to(get_action_button_center(action)) <= BUTTON_RADIUS * 1.2:
			_touch_actions[touch_id] = [action]
			_press_action(action)
			queue_redraw()
			return true
	return false


func _end_touch(touch_id: int) -> bool:
	if not _touch_actions.has(touch_id) and touch_id != _joystick_touch_id:
		return false
	if touch_id == _joystick_touch_id:
		_joystick_touch_id = -1
		_joystick_vector = Vector2.ZERO
	for action in _touch_actions.get(touch_id, []):
		_release_action(StringName(action))
	_touch_actions.erase(touch_id)
	queue_redraw()
	return true


func _update_joystick(position: Vector2) -> void:
	var offset := position - get_joystick_center()
	_joystick_vector = offset.limit_length(JOYSTICK_RADIUS) / JOYSTICK_RADIUS
	var next_actions: Array[StringName] = []
	if _joystick_vector.x <= -JOYSTICK_DEADZONE:
		next_actions.append(&"left")
	elif _joystick_vector.x >= JOYSTICK_DEADZONE:
		next_actions.append(&"right")
	if _joystick_vector.y <= -JOYSTICK_DEADZONE:
		# Up doubles as jump so the complete platformer control set fits on a phone.
		next_actions.append(&"up")
		next_actions.append(&"jump")
	elif _joystick_vector.y >= JOYSTICK_DEADZONE:
		next_actions.append(&"crouch")

	var previous_actions: Array = _touch_actions.get(_joystick_touch_id, [])
	for action in previous_actions:
		if not next_actions.has(StringName(action)):
			_release_action(StringName(action))
	for action in next_actions:
		if not previous_actions.has(action):
			_press_action(action)
	_touch_actions[_joystick_touch_id] = next_actions
	queue_redraw()


func _press_action(action: StringName) -> void:
	var touch_count := int(_action_touch_counts.get(action, 0)) + 1
	_action_touch_counts[action] = touch_count
	if touch_count == 1:
		_emit_action(action, true)


func _release_action(action: StringName) -> void:
	var touch_count := maxi(int(_action_touch_counts.get(action, 0)) - 1, 0)
	if touch_count > 0:
		_action_touch_counts[action] = touch_count
		return
	_action_touch_counts.erase(action)
	_emit_action(action, false)


func _emit_action(action: StringName, pressed: bool) -> void:
	if not InputMap.has_action(action):
		return
	# Keep polling-based movement current immediately while also dispatching an
	# action event to the player's event-driven state machine.
	if pressed:
		Input.action_press(action)
	else:
		Input.action_release(action)
	var action_event := InputEventAction.new()
	action_event.action = action
	action_event.pressed = pressed
	action_event.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(action_event)


func _release_all_actions() -> void:
	for action in _action_touch_counts.keys():
		_emit_action(StringName(action), false)
	_action_touch_counts.clear()
	_touch_actions.clear()
	_joystick_touch_id = -1
	_joystick_vector = Vector2.ZERO
	queue_redraw()


func _on_visibility_changed() -> void:
	if not visible:
		_release_all_actions()


func _draw() -> void:
	if not visible:
		return

	# The control node itself remains completely transparent. Only lightweight
	# labels, arrows and outlines are rendered, so gameplay stays visible beneath
	# one full-height touch layer instead of opaque side panels.
	var guide_color := Color(0.82, 0.9, 1.0, 0.34)
	var label_color := Color(0.94, 0.97, 1.0, 0.86)
	var caption_color := Color(0.86, 0.91, 0.98, 0.68)
	var active_color := Color(0.38, 0.78, 1.0, 0.98)
	var joystick_center := get_joystick_center()
	draw_arc(joystick_center, JOYSTICK_RADIUS, 0.0, TAU, 64, guide_color, 2.0, true)
	_draw_direction_markers(joystick_center, label_color)

	var thumb_center := joystick_center + _joystick_vector * (JOYSTICK_RADIUS * 0.52)
	draw_arc(
		thumb_center,
		22.0,
		0.0,
		TAU,
		32,
		active_color if _joystick_touch_id >= 0 else guide_color,
		2.0,
		true
	)

	var font := ThemeDB.fallback_font
	for action in ACTION_LABELS:
		var center := get_action_button_center(action)
		var is_active := int(_action_touch_counts.get(action, 0)) > 0
		var label: String = ACTION_LABELS[action]
		var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 32)
		draw_string(
			font,
			center - label_size * 0.5 + Vector2(0.0, -2.0),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			32,
			active_color if is_active else label_color
		)
		var caption: String = ACTION_CAPTIONS[action]
		var caption_size := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 10)
		draw_string(
			font,
			center + Vector2(-caption_size.x * 0.5, 24.0),
			caption,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			10,
			caption_color
		)

	var menu_center := get_menu_button_center()
	var menu_label := "MENU"
	var menu_size := font.get_string_size(menu_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15)
	draw_string(
		font,
		menu_center - menu_size * 0.5 + Vector2(0.0, 5.0),
		menu_label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		15,
		label_color
	)


func _draw_direction_markers(center: Vector2, color: Color) -> void:
	var distance := 56.0
	var half_width := 8.0
	var depth := 10.0
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0.0, -distance - depth),
		center + Vector2(-half_width, -distance + depth),
		center + Vector2(half_width, -distance + depth),
	]), color)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(0.0, distance + depth),
		center + Vector2(-half_width, distance - depth),
		center + Vector2(half_width, distance - depth),
	]), color)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-distance - depth, 0.0),
		center + Vector2(-distance + depth, -half_width),
		center + Vector2(-distance + depth, half_width),
	]), color)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(distance + depth, 0.0),
		center + Vector2(distance - depth, -half_width),
		center + Vector2(distance - depth, half_width),
	]), color)
