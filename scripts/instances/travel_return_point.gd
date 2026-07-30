class_name TravelReturnPoint
extends Area2D

@export var interaction_action: StringName = &"charm"
@export var option_actions: Array[StringName] = [&"option1", &"option2", &"option3", &"option4", &"option5"]
@export var preset_hours: Array[float] = [7.0, 13.0, 18.0, 22.0]
@export var interaction_priority: int = 90

var _player_inside := false
var _menu_open := false
var _targets: Array[float] = []
var _pending_confirmation := -1
var _layer: CanvasLayer
var _label: Label
var _active_player: Node2D
var _player_control_claim_token: int = 0


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(_delta: float) -> void:
	if not _menu_open:
		return
	for index in mini(option_actions.size(), _targets.size()):
		if InputMap.has_action(option_actions[index]) and Input.is_action_just_pressed(option_actions[index]):
			_select(index)
			return


func can_interact(actor: Node) -> bool:
	if actor == null or actor != _active_player or not _player_inside or _menu_open:
		return false
	var runtime := get_node_or_null("/root/PlayerRuntime")
	return runtime != null and bool(runtime.call("is_travel_active"))


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	return _open_menu(actor as Node2D)


func get_interaction_action(_actor: Node) -> StringName:
	return interaction_action


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return "Return"


func consume_player_interaction_input(actor: Node) -> bool:
	if not _menu_open or actor != _active_player:
		return false
	_close_menu()
	return true


func get_next_preset_total(current_total_hours: float, preset_hour: float) -> float:
	var day_start := floorf(current_total_hours / 24.0) * 24.0
	var candidate := day_start + clampf(preset_hour, 0.0, 23.999)
	if candidate <= current_total_hours + 0.0001:
		candidate += 24.0
	return candidate


func _open_menu(player: Node2D) -> bool:
	var runtime := get_node_or_null("/root/PlayerRuntime")
	var world_time := get_node_or_null("/root/WorldTime")
	if runtime == null or world_time == null or not bool(runtime.call("is_travel_active")):
		return false
	if not _acquire_player_control_claim(player):
		return false
	var current := float(world_time.call("get_total_hours"))
	_targets = [current]
	for preset in preset_hours:
		_targets.append(get_next_preset_total(current, preset))
	_pending_confirmation = -1
	_menu_open = true
	_build_menu(current)
	return true


func _build_menu(current: float) -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 90
	var panel := PanelContainer.new()
	panel.position = Vector2(28.0, 120.0)
	panel.custom_minimum_size = Vector2(360.0, 220.0)
	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.text = _menu_text(current)
	panel.add_child(_label)
	_layer.add_child(panel)
	add_child(_layer)


func _menu_text(current: float) -> String:
	var lines := PackedStringArray(["Return to the village", "Choose twice to confirm."])
	for index in _targets.size():
		var elapsed := _targets[index] - current
		var label := "Return now" if index == 0 else "Return at %02d:00" % int(preset_hours[index - 1])
		lines.append("%d. %s  (+%.1f hours)" % [index + 1, label, elapsed])
	lines.append("C: close")
	return "\n".join(lines)


func _select(index: int) -> void:
	if _pending_confirmation != index:
		_pending_confirmation = index
		_label.text += "\nConfirm option %d to return." % (index + 1)
		return
	var runtime := get_node_or_null("/root/PlayerRuntime")
	_close_menu()
	if runtime != null:
		runtime.call_deferred("return_to_origin", _targets[index])


func _close_menu() -> void:
	_menu_open = false
	_pending_confirmation = -1
	if _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	_layer = null
	_label = null
	_release_player_control_claim()


func _exit_tree() -> void:
	_release_player_control_claim()


func _acquire_player_control_claim(player: Node2D) -> bool:
	if _player_control_claim_token != 0:
		return player == _active_player
	if not is_inside_tree():
		return false
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null or not gameplay_flow.has_method("acquire_player_control_claim"):
		return false
	_player_control_claim_token = int(gameplay_flow.call(
		"acquire_player_control_claim", self, player, &"travel_return_menu", &"ui_only"
	))
	return _player_control_claim_token != 0


func _release_player_control_claim() -> void:
	if _player_control_claim_token == 0:
		return
	if not is_inside_tree():
		_player_control_claim_token = 0
		return
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow != null and gameplay_flow.has_method("release_player_control_claim"):
		gameplay_flow.call("release_player_control_claim", _player_control_claim_token, self)
	_player_control_claim_token = 0


func _on_body_entered(body: Node2D) -> void:
	if body.is_in_group(&"player"):
		_player_inside = true
		_active_player = body
		if body.has_method("register_interaction_candidate"):
			body.call("register_interaction_candidate", self)


func _on_body_exited(body: Node2D) -> void:
	if body.is_in_group(&"player"):
		if body.has_method("unregister_interaction_candidate"):
			body.call("unregister_interaction_candidate", self)
		_player_inside = false
		_close_menu()
		if body == _active_player:
			_active_player = null
