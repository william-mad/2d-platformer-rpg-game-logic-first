class_name InteractiveActivityHost extends Node

signal result_changed(result: Dictionary)
signal finish_requested(result: Dictionary)
signal cancel_requested(reason: StringName, result: Dictionary)

var definitions: Array[InteractiveActivityDefinition] = []
var activity_context: Dictionary = {}
var activity_input: InteractiveActivityInputSource
var selected_index: int = 0
var selection_mode: bool = false
var started: bool = false
var launch_options: InteractiveActivityLaunchOptions
var active_module: InteractiveActivityModule
var latest_result: Dictionary = {}

@onready var world_mount: Node2D = $WorldMount
@onready var hud_mount: Control = $HudLayer/HudMount
@onready var selection_panel: PanelContainer = $HudLayer/HudMount/SelectionPanel
@onready var title_label: Label = $HudLayer/HudMount/SelectionPanel/Margin/VBox/Title
@onready var options_label: Label = $HudLayer/HudMount/SelectionPanel/Margin/VBox/Options
@onready var help_label: Label = $HudLayer/HudMount/SelectionPanel/Margin/VBox/Help


func _ready() -> void:
	set_process(false)
	selection_panel.visible = false


func _process(_delta: float) -> void:
	if not started or not selection_mode or activity_input == null:
		return
	if activity_input.was_role_pressed(&"up"):
		selected_index = wrapi(selected_index - 1, 0, definitions.size())
		_update_selection_menu()
	elif activity_input.was_role_pressed(&"down"):
		selected_index = wrapi(selected_index + 1, 0, definitions.size())
		_update_selection_menu()
	if activity_input.was_role_pressed(&"confirm"):
		if _instantiate_selected_module(selected_index):
			selection_mode = false
			selection_panel.visible = false
			active_module.start_activity()


func configure_host(
	supplied_definitions: Array[InteractiveActivityDefinition],
	context: Dictionary,
	input_source: InteractiveActivityInputSource,
	world_anchor: Vector2,
	supplied_launch_options: InteractiveActivityLaunchOptions = null
) -> bool:
	if input_source == null or supplied_definitions.is_empty():
		return false
	for definition in supplied_definitions:
		if definition == null or not definition.is_valid_definition():
			return false
	definitions.assign(supplied_definitions)
	activity_context = context.duplicate(true)
	activity_input = input_source
	launch_options = (
		supplied_launch_options
		if supplied_launch_options != null
		else InteractiveActivityLaunchOptions.new()
	)
	world_mount.global_position = world_anchor
	selected_index = 0
	selection_mode = launch_options.should_show_selection(definitions.size())
	started = false
	latest_result = {}
	if not activity_input.configure(definitions[0].get_input_profile()):
		return false
	if not selection_mode and not _instantiate_selected_module(0):
		return false
	_update_selection_menu()
	return true


func start_activity() -> bool:
	if started:
		return true
	if definitions.is_empty():
		return false
	started = true
	set_process(true)
	if selection_mode:
		selection_panel.visible = true
		_update_selection_menu()
		return true
	if active_module == null:
		return false
	active_module.start_activity()
	return true


func select_definition(index: int) -> bool:
	if not selection_mode or index < 0 or index >= definitions.size():
		return false
	if not _instantiate_selected_module(index):
		return false
	selected_index = index
	selection_mode = false
	selection_panel.visible = false
	if started:
		active_module.start_activity()
	return true


func stop_activity(reason: StringName) -> Dictionary:
	started = false
	set_process(false)
	selection_panel.visible = false
	if active_module != null:
		latest_result = active_module.stop_activity(reason)
	elif latest_result.is_empty():
		latest_result = _make_unselected_result("stopped", String(reason))
	return latest_result.duplicate(true)


func shutdown_host(reason: StringName) -> Dictionary:
	var result := stop_activity(reason)
	_remove_active_module()
	return result


func get_active_module() -> InteractiveActivityModule:
	return active_module


func is_selecting() -> bool:
	return selection_mode and started


func get_launch_options() -> InteractiveActivityLaunchOptions:
	return launch_options


func _instantiate_selected_module(index: int) -> bool:
	if index < 0 or index >= definitions.size():
		return false
	var definition := definitions[index]
	var instance := definition.module_scene.instantiate()
	var module := instance as InteractiveActivityModule
	if module == null:
		instance.free()
		return false

	_remove_active_module()
	var mount := _get_mount_for_definition(definition)
	mount.add_child(module)
	var module_context := activity_context.duplicate(true)
	module_context["activity_id"] = String(definition.id)
	module_context["activity_metadata"] = definition.metadata.duplicate(true)
	module_context["module_config"] = definition.module_config
	if not activity_input.configure(definition.get_input_profile()):
		module.queue_free()
		return false
	if not module.configure(module_context, activity_input):
		module.queue_free()
		return false
	active_module = module
	selected_index = index
	_connect_module_signals(module)
	latest_result = module.get_result()
	return true


func _get_mount_for_definition(definition: InteractiveActivityDefinition) -> Node:
	var requested_mount := String(definition.metadata.get("presentation_mount", ""))
	if requested_mount == "hud":
		return hud_mount
	return world_mount


func _connect_module_signals(module: InteractiveActivityModule) -> void:
	module.result_changed.connect(_on_module_result_changed)
	module.finish_requested.connect(_on_module_finish_requested)
	module.cancel_requested.connect(_on_module_cancel_requested)


func _disconnect_module_signals(module: InteractiveActivityModule) -> void:
	var result_callback := Callable(self, "_on_module_result_changed")
	var finish_callback := Callable(self, "_on_module_finish_requested")
	var cancel_callback := Callable(self, "_on_module_cancel_requested")
	if module.result_changed.is_connected(result_callback):
		module.result_changed.disconnect(result_callback)
	if module.finish_requested.is_connected(finish_callback):
		module.finish_requested.disconnect(finish_callback)
	if module.cancel_requested.is_connected(cancel_callback):
		module.cancel_requested.disconnect(cancel_callback)


func _remove_active_module() -> void:
	if active_module == null:
		return
	_disconnect_module_signals(active_module)
	if active_module.get_parent() != null:
		active_module.get_parent().remove_child(active_module)
	active_module.queue_free()
	active_module = null


func _on_module_result_changed(result: Dictionary) -> void:
	latest_result = result.duplicate(true)
	result_changed.emit(latest_result.duplicate(true))


func _on_module_finish_requested(result: Dictionary) -> void:
	latest_result = result.duplicate(true)
	finish_requested.emit(latest_result.duplicate(true))


func _on_module_cancel_requested(reason: StringName, result: Dictionary) -> void:
	latest_result = result.duplicate(true)
	cancel_requested.emit(reason, latest_result.duplicate(true))


func _update_selection_menu() -> void:
	if definitions.is_empty():
		title_label.text = "Choose an activity"
		options_label.text = ""
		return
	title_label.text = launch_options.get_menu_title()
	var lines: PackedStringArray = []
	var prompt := launch_options.menu_prompt.strip_edges()
	if not prompt.is_empty():
		lines.append(prompt)
		lines.append("")
	for index in definitions.size():
		var prefix := "> " if index == selected_index else "  "
		lines.append("%s%s" % [prefix, definitions[index].display_name])
	options_label.text = "\n".join(lines)
	help_label.text = launch_options.get_confirm_text()


func _make_unselected_result(status: String, finish_reason: String) -> Dictionary:
	var session_id := String(activity_context.get("session_id", ""))
	return InteractiveActivityModule.make_standard_result("", session_id, status, finish_reason)
