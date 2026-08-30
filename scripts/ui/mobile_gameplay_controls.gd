class_name MobileGameplayControls
extends Control

const REFERENCE_PHONE_SURFACE := Vector2(754.0, 496.0)
const JOYSTICK_RADIUS := 76.0
const JOYSTICK_DEADZONE := 0.28
const BUTTON_RADIUS := 42.0
const MENU_TOUCH_SIZE := Vector2(104.0, 48.0)
const MOBILE_INTERACTION_MENU_POSITION := Vector2(18.0, 100.0)
const MOBILE_INTERACTION_MENU_MIN_SIZE := Vector2(380.0, 310.0)
const MOBILE_INTERACTION_OPTION_HEIGHT := 48.0
const MOBILE_INTERACTION_TITLE_FONT_SIZE := 20
const MOBILE_INTERACTION_OPTION_FONT_SIZE := 18
const MOBILE_INTERACTION_FEEDBACK_FONT_SIZE := 14
const MOBILE_MENU_EDGE_MARGIN := 12.0
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
var _interaction_interactor_ref: WeakRef


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process_input(true)
	visibility_changed.connect(_on_visibility_changed)
	resized.connect(queue_redraw)
	if not get_viewport().size_changed.is_connected(_on_surface_changed):
		get_viewport().size_changed.connect(_on_surface_changed)
	_configure_mobile_window_scaling()
	_refresh_visibility()


func _process(_delta: float) -> void:
	if not visible or not (force_enabled or OS.has_feature("mobile")):
		return
	_refresh_interaction_menu_mobile_ui()


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
		# Interaction menus use normal canvas coordinates and remain fully inside
		# the phone surface. Keep that hit test in the original event space.
		if touch.pressed and _handle_interaction_menu_touch(touch.position):
			get_viewport().set_input_as_handled()
			return

		# Gameplay controls are drawn in this Control's local coordinates. Convert
		# the stretched-window input before comparing it with phone-anchored shapes.
		var local_touch := make_input_local(touch) as InputEventScreenTouch
		var local_position := local_touch.position if local_touch != null else touch.position
		if touch.pressed and _is_menu_touch(local_position):
			_request_pause_menu()
			get_viewport().set_input_as_handled()
			return

		var consumed := false
		if touch.pressed:
			consumed = _begin_touch(touch.index, local_position)
		else:
			consumed = _end_touch(touch.index)
		if consumed:
			get_viewport().set_input_as_handled()
		return

	var drag := event as InputEventScreenDrag
	if drag != null and drag.index == _joystick_touch_id:
		var local_drag := make_input_local(drag) as InputEventScreenDrag
		_update_joystick(local_drag.position if local_drag != null else drag.position)
		get_viewport().set_input_as_handled()


func refresh_for_platform() -> void:
	_configure_mobile_window_scaling()
	_refresh_visibility()
	queue_redraw()


func _on_surface_changed() -> void:
	queue_redraw()
	if visible:
		_refresh_interaction_menu_mobile_ui()


func _rect_from_points(point_a: Vector2, point_b: Vector2) -> Rect2:
	return Rect2(
		Vector2(minf(point_a.x, point_b.x), minf(point_a.y, point_b.y)),
		Vector2(absf(point_b.x - point_a.x), absf(point_b.y - point_a.y))
	)


func _get_phone_local_rect() -> Rect2:
	var window_size := Vector2(DisplayServer.window_get_size())
	if window_size.x <= 0.0 or window_size.y <= 0.0:
		return Rect2(Vector2.ZERO, size)
	var local_to_screen := (
		get_viewport().get_screen_transform() * get_global_transform_with_canvas()
	)
	var inverse := local_to_screen.affine_inverse()
	return _rect_from_points(inverse * Vector2.ZERO, inverse * window_size)


func _get_phone_canvas_rect() -> Rect2:
	var fallback := get_viewport().get_visible_rect()
	var window_size := Vector2(DisplayServer.window_get_size())
	if window_size.x <= 0.0 or window_size.y <= 0.0:
		return fallback
	var inverse := get_viewport().get_screen_transform().affine_inverse()
	return _rect_from_points(inverse * Vector2.ZERO, inverse * window_size)


func _get_control_scale() -> float:
	var screen_rect := _get_phone_local_rect()
	if screen_rect.size.y <= 0.0:
		return 1.0
	return clampf(screen_rect.size.y / REFERENCE_PHONE_SURFACE.y, 0.8, 1.35)


func get_joystick_center() -> Vector2:
	var screen_rect := _get_phone_local_rect()
	var ui_scale := _get_control_scale()
	return Vector2(
		screen_rect.position.x + screen_rect.size.x - 96.0 * ui_scale,
		screen_rect.position.y + screen_rect.size.y - 104.0 * ui_scale
	)


func get_action_button_center(action: StringName) -> Vector2:
	var screen_rect := _get_phone_local_rect()
	var ui_scale := _get_control_scale()
	var left := screen_rect.position.x
	var bottom := screen_rect.position.y + screen_rect.size.y
	match action:
		&"attack":
			return Vector2(left + 56.0 * ui_scale, bottom - 66.0 * ui_scale)
		&"attach_rope":
			return Vector2(left + 142.0 * ui_scale, bottom - 66.0 * ui_scale)
		&"charm":
			return Vector2(left + 99.0 * ui_scale, bottom - 152.0 * ui_scale)
		_:
			return Vector2.ZERO


func get_menu_button_center() -> Vector2:
	var screen_rect := _get_phone_local_rect()
	var ui_scale := _get_control_scale()
	return Vector2(
		screen_rect.position.x + screen_rect.size.x * 0.5,
		screen_rect.position.y + 34.0 * ui_scale
	)


func get_joystick_vector() -> Vector2:
	return _joystick_vector


func _configure_mobile_window_scaling() -> void:
	if not OS.has_feature("mobile"):
		return
	var window := get_tree().root
	# The game world keeps whole-integer scaling and nearest filtering. Controls
	# compensate for the resulting window transform separately, so their anchors
	# follow the actual phone surface instead of the virtual game rectangle.
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	window.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_INTEGER


func _refresh_visibility() -> void:
	visible = force_enabled or show_on_desktop or OS.has_feature("mobile")
	if not visible:
		_release_all_actions()
	queue_redraw()


func _is_menu_touch(position: Vector2) -> bool:
	var ui_scale := _get_control_scale()
	var touch_size := MENU_TOUCH_SIZE * ui_scale
	var center := get_menu_button_center()
	return Rect2(center - touch_size * 0.5, touch_size).has_point(position)


func _request_pause_menu() -> void:
	_release_all_actions()
	var pause_system := get_node_or_null("/root/PauseSystem")
	if pause_system != null and pause_system.has_method("open_pause_menu"):
		pause_system.call("open_pause_menu")


func _get_npc_talk_interactor() -> PlayerNpcTalkInteractor:
	if _interaction_interactor_ref != null:
		var cached := _interaction_interactor_ref.get_ref() as PlayerNpcTalkInteractor
		if cached != null and is_instance_valid(cached) and cached.is_inside_tree():
			return cached

	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		_interaction_interactor_ref = null
		return null
	var found := _find_npc_talk_interactor(player)
	_interaction_interactor_ref = weakref(found) if found != null else null
	return found


func _find_npc_talk_interactor(node: Node) -> PlayerNpcTalkInteractor:
	if node is PlayerNpcTalkInteractor:
		return node as PlayerNpcTalkInteractor
	for child in node.get_children():
		var found := _find_npc_talk_interactor(child)
		if found != null:
			return found
	return null


func _refresh_interaction_menu_mobile_ui() -> void:
	var interactor := _get_npc_talk_interactor()
	if interactor == null:
		return

	var screen_rect := _get_phone_canvas_rect()
	if screen_rect.size.x <= 0.0 or screen_rect.size.y <= 0.0:
		return
	var available_size := Vector2(
		maxf(screen_rect.size.x - MOBILE_MENU_EDGE_MARGIN * 2.0, 1.0),
		maxf(screen_rect.size.y - MOBILE_MENU_EDGE_MARGIN * 2.0, 1.0)
	)
	var fit_scale := minf(
		1.0,
		minf(
			available_size.x / MOBILE_INTERACTION_MENU_MIN_SIZE.x,
			available_size.y / MOBILE_INTERACTION_MENU_MIN_SIZE.y
		)
	)
	var target_size := MOBILE_INTERACTION_MENU_MIN_SIZE * fit_scale
	var minimum_position := screen_rect.position + Vector2.ONE * MOBILE_MENU_EDGE_MARGIN
	var maximum_position := screen_rect.position + screen_rect.size - Vector2.ONE * MOBILE_MENU_EDGE_MARGIN - target_size
	var preferred_position := screen_rect.position + MOBILE_INTERACTION_MENU_POSITION * fit_scale
	var target_position := Vector2(
		clampf(preferred_position.x, minimum_position.x, maximum_position.x),
		clampf(preferred_position.y, minimum_position.y, maximum_position.y)
	)

	# These values also cover menus that have not been lazily created yet.
	interactor.menu_position = target_position
	interactor.menu_minimum_size = target_size

	var panel := interactor.menu_panel
	if panel == null or not is_instance_valid(panel):
		return
	panel.position = target_position
	panel.custom_minimum_size = target_size
	panel.size = target_size

	var margin := panel.get_child(0) as MarginContainer if panel.get_child_count() > 0 else null
	if margin != null:
		margin.add_theme_constant_override("margin_left", maxi(8, roundi(16.0 * fit_scale)))
		margin.add_theme_constant_override("margin_top", maxi(6, roundi(12.0 * fit_scale)))
		margin.add_theme_constant_override("margin_right", maxi(8, roundi(16.0 * fit_scale)))
		margin.add_theme_constant_override("margin_bottom", maxi(6, roundi(12.0 * fit_scale)))
		var stack := margin.get_child(0) as VBoxContainer if margin.get_child_count() > 0 else null
		if stack != null:
			stack.add_theme_constant_override("separation", maxi(3, roundi(6.0 * fit_scale)))

	if interactor.menu_title_label != null:
		interactor.menu_title_label.add_theme_font_size_override(
			"font_size", maxi(14, roundi(MOBILE_INTERACTION_TITLE_FONT_SIZE * fit_scale))
		)
		interactor.menu_title_label.custom_minimum_size.y = maxf(22.0, 28.0 * fit_scale)
		interactor.menu_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	for option_label in interactor.menu_option_labels:
		if option_label == null:
			continue
		option_label.custom_minimum_size.y = maxf(34.0, MOBILE_INTERACTION_OPTION_HEIGHT * fit_scale)
		option_label.add_theme_font_size_override(
			"font_size", maxi(13, roundi(MOBILE_INTERACTION_OPTION_FONT_SIZE * fit_scale))
		)
		option_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	if interactor.menu_feedback_label != null:
		interactor.menu_feedback_label.add_theme_font_size_override(
			"font_size", maxi(11, roundi(MOBILE_INTERACTION_FEEDBACK_FONT_SIZE * fit_scale))
		)


func _handle_interaction_menu_touch(position: Vector2) -> bool:
	var interactor := _get_npc_talk_interactor()
	if interactor == null or interactor.active_menu == &"":
		return false
	_refresh_interaction_menu_mobile_ui()

	var panel := interactor.menu_panel
	if panel == null or not is_instance_valid(panel) or not panel.visible:
		return false
	var panel_rect := panel.get_global_rect()
	if not panel_rect.has_point(position):
		return false

	var option_count := mini(
		interactor.current_menu_option_count,
		interactor.menu_option_labels.size()
	)
	for index in range(option_count):
		var option_label := interactor.menu_option_labels[index]
		if option_label == null or not option_label.visible:
			continue
		var label_rect := option_label.get_global_rect()
		var touch_rect := Rect2(
			Vector2(panel_rect.position.x, label_rect.position.y - 3.0),
			Vector2(panel_rect.size.x, label_rect.size.y + 6.0)
		)
		if touch_rect.has_point(position):
			_select_interaction_menu_option(interactor, index)
			return true

	return true


func _select_interaction_menu_option(
	interactor: PlayerNpcTalkInteractor,
	selected_index: int
) -> void:
	if selected_index < 0 or selected_index >= interactor.current_menu_option_count:
		return
	match interactor.active_menu:
		&"interaction":
			interactor.call("_handle_interaction_option", selected_index)
		&"talk":
			interactor.call("_handle_talk_option", selected_index)
		&"gossip":
			interactor.call("_handle_gossip_option", selected_index)
		&"npc_prompt":
			interactor.call("_handle_npc_prompt_option", selected_index)


func _begin_touch(touch_id: int, position: Vector2) -> bool:
	if _touch_actions.has(touch_id):
		return true

	var ui_scale := _get_control_scale()
	var joystick_radius := JOYSTICK_RADIUS * ui_scale
	if position.distance_to(get_joystick_center()) <= joystick_radius * 1.15:
		_joystick_touch_id = touch_id
		_touch_actions[touch_id] = []
		_update_joystick(position)
		return true

	var button_radius := BUTTON_RADIUS * ui_scale
	for action in ACTION_LABELS:
		if position.distance_to(get_action_button_center(action)) <= button_radius * 1.2:
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
	var joystick_radius := JOYSTICK_RADIUS * _get_control_scale()
	var offset := position - get_joystick_center()
	_joystick_vector = offset.limit_length(joystick_radius) / joystick_radius
	var next_actions: Array[StringName] = []
	if _joystick_vector.x <= -JOYSTICK_DEADZONE:
		next_actions.append(&"left")
	elif _joystick_vector.x >= JOYSTICK_DEADZONE:
		next_actions.append(&"right")
	if _joystick_vector.y <= -JOYSTICK_DEADZONE:
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

	var ui_scale := _get_control_scale()
	var joystick_radius := JOYSTICK_RADIUS * ui_scale
	var guide_color := Color(0.82, 0.9, 1.0, 0.34)
	var label_color := Color(0.94, 0.97, 1.0, 0.86)
	var caption_color := Color(0.86, 0.91, 0.98, 0.68)
	var active_color := Color(0.38, 0.78, 1.0, 0.98)
	var joystick_center := get_joystick_center()
	draw_arc(
		joystick_center,
		joystick_radius,
		0.0,
		TAU,
		64,
		guide_color,
		maxf(1.0, 2.0 * ui_scale),
		true
	)
	_draw_direction_markers(joystick_center, label_color, ui_scale)

	var thumb_center := joystick_center + _joystick_vector * (joystick_radius * 0.52)
	draw_arc(
		thumb_center,
		22.0 * ui_scale,
		0.0,
		TAU,
		32,
		active_color if _joystick_touch_id >= 0 else guide_color,
		maxf(1.0, 2.0 * ui_scale),
		true
	)

	var font := ThemeDB.fallback_font
	var action_font_size := maxi(24, roundi(32.0 * ui_scale))
	var caption_font_size := maxi(9, roundi(10.0 * ui_scale))
	for action in ACTION_LABELS:
		var center := get_action_button_center(action)
		var is_active := int(_action_touch_counts.get(action, 0)) > 0
		var label: String = ACTION_LABELS[action]
		var label_size := font.get_string_size(
			label, HORIZONTAL_ALIGNMENT_LEFT, -1, action_font_size
		)
		draw_string(
			font,
			center - label_size * 0.5 + Vector2(0.0, -2.0 * ui_scale),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			action_font_size,
			active_color if is_active else label_color
		)
		var caption: String = ACTION_CAPTIONS[action]
		var caption_size := font.get_string_size(
			caption, HORIZONTAL_ALIGNMENT_LEFT, -1, caption_font_size
		)
		draw_string(
			font,
			center + Vector2(-caption_size.x * 0.5, 24.0 * ui_scale),
			caption,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			caption_font_size,
			caption_color
		)

	var menu_center := get_menu_button_center()
	var menu_label := "MENU"
	var menu_font_size := maxi(12, roundi(15.0 * ui_scale))
	var menu_size := font.get_string_size(
		menu_label, HORIZONTAL_ALIGNMENT_LEFT, -1, menu_font_size
	)
	draw_string(
		font,
		menu_center - menu_size * 0.5 + Vector2(0.0, 5.0 * ui_scale),
		menu_label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		menu_font_size,
		label_color
	)


func _draw_direction_markers(center: Vector2, color: Color, ui_scale: float) -> void:
	var distance := 56.0 * ui_scale
	var half_width := 8.0 * ui_scale
	var depth := 10.0 * ui_scale
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
