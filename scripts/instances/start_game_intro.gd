class_name StartGameIntro extends Node2D

signal intro_started
signal intro_step_requested(step_name: StringName)
signal intro_about_to_finish(next_scene_path: String)
signal intro_finished(next_scene_path: String)

@export_file("*.tscn") var next_scene_path: String = "res://scenes/testscenes/realtest1.tscn"
@export_range(0.0, 10.0, 0.1, "suffix:s") var minimum_duration_seconds: float = 1.25
@export var auto_advance: bool = true
@export var allow_skip: bool = true
@export var skip_actions: Array[String] = ["ui_accept"]
@export var intro_animation_name: StringName = &"intro"
@export var outro_animation_name: StringName = &"outro"

@onready var intro_animation_player: AnimationPlayer = get_node_or_null("%IntroAnimationPlayer") as AnimationPlayer
@onready var programmed_intro_behaviours: Node = get_node_or_null("%ProgrammedIntroBehaviours")

var _advance_started: bool = false


func _ready() -> void:
	if has_node("/root/PlayerHud"):
		PlayerHud.visible = false

	set_process_input(allow_skip)
	intro_started.emit()
	_preload_next_scene()
	_play_intro_animation()
	_run_programmed_intro_behaviours()

	if auto_advance:
		_advance_after_minimum_duration()


func _input(event: InputEvent) -> void:
	if not allow_skip or _advance_started:
		return

	for action in skip_actions:
		if InputMap.has_action(action) and event.is_action_pressed(action):
			get_viewport().set_input_as_handled()
			advance_to_game()
			return


func request_intro_step(step_name: StringName) -> void:
	if step_name == &"":
		return

	intro_step_requested.emit(step_name)


func advance_to_game() -> void:
	if _advance_started:
		return

	var normalized_path := next_scene_path.strip_edges()
	if normalized_path.is_empty():
		push_warning("StartGameIntro next scene path is empty.")
		return

	_advance_started = true
	set_process_input(false)
	intro_about_to_finish.emit(normalized_path)
	if _can_play_animation(outro_animation_name):
		await _play_outro_animation()
	intro_finished.emit(normalized_path)

	if _change_scene_with_loader(normalized_path):
		return

	get_tree().change_scene_to_file(normalized_path)


func _advance_after_minimum_duration() -> void:
	await get_tree().create_timer(maxf(minimum_duration_seconds, 0.0)).timeout
	if not is_inside_tree():
		return

	advance_to_game()


func _play_intro_animation() -> void:
	if _can_play_animation(intro_animation_name):
		intro_animation_player.play(intro_animation_name)


func _play_outro_animation() -> void:
	intro_animation_player.play(outro_animation_name)
	await intro_animation_player.animation_finished


func _can_play_animation(animation_name: StringName) -> bool:
	return (
		intro_animation_player != null
		and animation_name != &""
		and intro_animation_player.has_animation(animation_name)
	)


func _run_programmed_intro_behaviours() -> void:
	request_intro_step(&"setup")

	if programmed_intro_behaviours == null:
		return

	for child in programmed_intro_behaviours.get_children():
		if child.has_method("run_intro"):
			child.call("run_intro", self)


func _preload_next_scene() -> void:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("preload_scene"):
		scene_loader.call("preload_scene", next_scene_path)


func _change_scene_with_loader(scene_path: String) -> bool:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("change_scene"):
		return false

	return bool(scene_loader.call("change_scene", scene_path))
