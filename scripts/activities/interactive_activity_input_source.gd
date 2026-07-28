class_name InteractiveActivityInputSource extends Node

var profile: InteractiveActivityInputProfile
var _accepting_input: bool = false
var _release_only: bool = false
var _held_actions: Dictionary = {}
var _pressed_actions: Dictionary = {}
var _released_actions: Dictionary = {}
var _transient_process_frame: int = -1


func _ready() -> void:
	set_process_input(true)
	set_process(true)


func _process(_delta: float) -> void:
	if (
		_transient_process_frame >= 0
		and Engine.get_process_frames() > _transient_process_frame
	):
		clear_one_frame_states()


func _input(event: InputEvent) -> void:
	if not _accepting_input and not _release_only:
		return
	if event is InputEventKey and event.echo:
		return
	if profile == null:
		return

	var captured := false
	for action in profile.get_captured_actions():
		var pressed := event.is_action_pressed(action)
		var released := event.is_action_released(action)
		if not pressed and not released:
			continue
		captured = true
		if released:
			_held_actions.erase(action)
			_released_actions[action] = true
			_transient_process_frame = Engine.get_process_frames()
		elif _accepting_input:
			_held_actions[action] = true
			_pressed_actions[action] = true
			_transient_process_frame = Engine.get_process_frames()
		if captured and is_inside_tree():
			get_viewport().set_input_as_handled()


func configure(new_profile: InteractiveActivityInputProfile) -> bool:
	if new_profile == null or not new_profile.is_valid_profile():
		return false
	profile = new_profile
	clear_all_states()
	return true


func set_activity_input_enabled(enabled: bool) -> void:
	_accepting_input = enabled
	_release_only = false
	if not enabled:
		clear_one_frame_states()


func begin_neutral_handoff() -> void:
	_accepting_input = false
	_release_only = true
	clear_one_frame_states()


func force_neutral() -> void:
	_accepting_input = false
	_release_only = false
	clear_all_states()


func is_accepting_input() -> bool:
	return _accepting_input


func get_movement_vector() -> Vector2:
	if profile == null:
		return Vector2.ZERO
	var movement := Vector2(
		float(is_role_held(&"right")) - float(is_role_held(&"left")),
		float(is_role_held(&"down")) - float(is_role_held(&"up"))
	)
	return movement.normalized() if movement.length_squared() > 1.0 else movement


func is_role_held(role: StringName) -> bool:
	return _action_state(_held_actions, role)


func was_role_pressed(role: StringName) -> bool:
	return _action_state(_pressed_actions, role)


func was_role_released(role: StringName) -> bool:
	return _action_state(_released_actions, role)


func get_snapshot() -> Dictionary:
	var held := {}
	var pressed := {}
	var released := {}
	if profile != null:
		for role_value in profile.get_role_actions().keys():
			var role := StringName(role_value)
			held[String(role)] = is_role_held(role)
			pressed[String(role)] = was_role_pressed(role)
			released[String(role)] = was_role_released(role)
	return {
		"movement": get_movement_vector(),
		"held": held,
		"pressed": pressed,
		"released": released,
	}


func is_neutral() -> bool:
	return _held_actions.is_empty()


func consume_player_interaction_input(_player: Node) -> bool:
	if profile == null or (not _accepting_input and not _release_only):
		return false
	var up_action := profile.get_action_for_role(&"up")
	return bool(_held_actions.get(up_action, false)) or bool(
		_pressed_actions.get(up_action, false)
	)


func clear_one_frame_states() -> void:
	_pressed_actions.clear()
	_released_actions.clear()
	_transient_process_frame = -1


func clear_all_states() -> void:
	_held_actions.clear()
	clear_one_frame_states()


func _action_state(states: Dictionary, role: StringName) -> bool:
	if profile == null:
		return false
	var action := profile.get_action_for_role(role)
	return action != &"" and bool(states.get(action, false))
