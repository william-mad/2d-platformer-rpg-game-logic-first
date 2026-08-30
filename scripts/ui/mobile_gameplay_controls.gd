class_name MobileGameplayControls
extends Control

const JOYSTICK_RADIUS := 70.0
const JOYSTICK_DEADZONE := 0.28
const BUTTON_RADIUS := 34.0
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
		if touch.pressed:
			_begin_touch(touch.index, touch.position)
		else:
			_end_touch(touch.index)
		get_viewport().set_input_as_handled()
		return

	var drag := event as InputEventScreenDrag
	if drag != null and drag.index == _joystick_touch_id:
		_update_joystick(drag.position)
		get_viewport().set_input_as_handled()


func refresh_for_platform() -> void:
	_refresh_visibility()


func get_joystick_center() -> Vector2:
	return Vector2(104.0, size.y - 104.0)


func get_action_button_center(action: StringName) -> Vector2:
	match action:
		&"attack":
			return Vector2(size.x - 62.0, size.y - 70.0)
		&"attach_rope":
			return Vector2(size.x - 140.0, size.y - 70.0)
		&"charm":
			return Vector2(size.x - 100.0, size.y - 145.0)
		_:
			return Vector2.ZERO


func get_joystick_vector() -> Vector2:
	return _joystick_vector


func _refresh_visibility() -> void:
	visible = force_enabled or show_on_desktop or OS.has_feature("mobile")
	if not visible:
		_release_all_actions()
	queue_redraw()


func _begin_touch(touch_id: int, position: Vector2) -> void:
	if _touch_actions.has(touch_id):
		return

	if position.distance_to(get_joystick_center()) <= JOYSTICK_RADIUS * 1.25:
		_joystick_touch_id = touch_id
		_touch_actions[touch_id] = []
		_update_joystick(position)
		return

	for action in ACTION_LABELS:
		if position.distance_to(get_action_button_center(action)) <= BUTTON_RADIUS * 1.25:
			_touch_actions[touch_id] = [action]
			_press_action(action)
			queue_redraw()
			return


func _end_touch(touch_id: int) -> void:
	if touch_id == _joystick_touch_id:
		_joystick_touch_id = -1
		_joystick_vector = Vector2.ZERO
	for action in _touch_actions.get(touch_id, []):
		_release_action(StringName(action))
	_touch_actions.erase(touch_id)
	queue_redraw()


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

	var base_color := Color(0.035, 0.055, 0.09, 0.58)
	var edge_color := Color(0.82, 0.9, 1.0, 0.72)
	var active_color := Color(0.2, 0.7, 1.0, 0.78)
	var joystick_center := get_joystick_center()
	draw_circle(joystick_center, JOYSTICK_RADIUS, base_color)
	draw_arc(joystick_center, JOYSTICK_RADIUS, 0.0, TAU, 48, edge_color, 2.0, true)
	draw_circle(
		joystick_center + _joystick_vector * (JOYSTICK_RADIUS * 0.55),
		27.0,
		active_color if _joystick_touch_id >= 0 else Color(0.72, 0.8, 0.9, 0.6)
	)
	_draw_direction_markers(joystick_center, edge_color)

	var font := ThemeDB.fallback_font
	for action in ACTION_LABELS:
		var center := get_action_button_center(action)
		var is_active := int(_action_touch_counts.get(action, 0)) > 0
		draw_circle(center, BUTTON_RADIUS, active_color if is_active else base_color)
		draw_arc(center, BUTTON_RADIUS, 0.0, TAU, 32, edge_color, 2.0, true)
		var label: String = ACTION_LABELS[action]
		var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 24)
		draw_string(font, center - label_size * 0.5 + Vector2(0.0, -1.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color.WHITE)
		var caption: String = ACTION_CAPTIONS[action]
		var caption_size := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 9)
		draw_string(font, center + Vector2(-caption_size.x * 0.5, 20.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.88, 0.93, 1.0, 0.9))


func _draw_direction_markers(center: Vector2, color: Color) -> void:
	var distance := 50.0
	var half_width := 7.0
	var depth := 8.0
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
