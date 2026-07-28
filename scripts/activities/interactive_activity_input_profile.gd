class_name InteractiveActivityInputProfile extends Resource

const ROLE_LEFT := &"left"
const ROLE_RIGHT := &"right"
const ROLE_UP := &"up"
const ROLE_DOWN := &"down"
const ROLE_CONFIRM := &"confirm"

@export_group("Activity controls")
@export var left_action: StringName = &"left"
@export var right_action: StringName = &"right"
@export var up_action: StringName = &"up"
@export var down_action: StringName = &"crouch"
@export var confirm_action: StringName = &"attack"

@export_group("Consumed while active")
@export var consumed_actions: Array[StringName] = [
	&"attach_rope",
	&"inventory",
	&"stats",
]
@export var pass_through_actions: Array[StringName] = [&"pause"]


func is_valid_profile() -> bool:
	for action in get_role_actions().values():
		if StringName(action) == &"" or not InputMap.has_action(StringName(action)):
			return false
	return true


func get_role_actions() -> Dictionary:
	return {
		ROLE_LEFT: left_action,
		ROLE_RIGHT: right_action,
		ROLE_UP: up_action,
		ROLE_DOWN: down_action,
		ROLE_CONFIRM: confirm_action,
	}


func get_action_for_role(role: StringName) -> StringName:
	return StringName(get_role_actions().get(role, &""))


func get_captured_actions() -> Array[StringName]:
	var actions: Array[StringName] = []
	for action_value in get_role_actions().values():
		_append_unique_captured_action(actions, StringName(action_value))
	for action in consumed_actions:
		_append_unique_captured_action(actions, action)
	return actions


func is_pass_through_action(action: StringName) -> bool:
	return pass_through_actions.has(action)


func _append_unique_captured_action(actions: Array[StringName], action: StringName) -> void:
	if action == &"" or is_pass_through_action(action) or actions.has(action):
		return
	actions.append(action)
