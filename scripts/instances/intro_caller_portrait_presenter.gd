class_name IntroCallerPortraitPresenter
extends Control

@export var dialogue_id: StringName = &"intro_phone_call"
@export var caller_speaker_id: StringName = &"caller"
@export var player_speaker_id: StringName = &"player"
@export_range(0.1, 1.5, 0.05, "suffix:s") var entry_duration: float = 0.55
@export_range(20.0, 35.0, 1.0, "suffix:px") var player_speaking_retreat: float = 28.0
@export_range(0.05, 0.5, 0.01, "suffix:s") var speaker_transition_seconds: float = 0.14
@export_range(0.0, 64.0, 1.0, "suffix:px") var offscreen_margin: float = 16.0

@onready var portrait_sprite: Control = %DialogueSlideSprite
@onready var frame_timer: Timer = %DialogueSlideTimer
@onready var portrait_frames: Array[TextureRect] = [
	%DialogueSlideFrame1,
	%DialogueSlideFrame2,
	%DialogueSlideFrame3,
	%DialogueSlideFrame4,
	%DialogueSlideFrame5,
]

var active_session_id: StringName = &""
var current_speaker_id: StringName = &""
var _active_x: float = 0.0
var _frame_index: int = 0
var _entering: bool = false
var _motion_tween: Tween


func _ready() -> void:
	visible = false
	_active_x = portrait_sprite.position.x
	_show_frame(0)
	frame_timer.timeout.connect(_on_frame_timer_timeout)
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if dialogue_controller == null:
		return
	dialogue_controller.dialogue_session_started.connect(_on_dialogue_session_started)
	dialogue_controller.dialogue_node_started.connect(_on_dialogue_node_started)
	dialogue_controller.dialogue_session_finished.connect(_on_dialogue_session_finished)


func _exit_tree() -> void:
	frame_timer.stop()
	if _motion_tween != null and _motion_tween.is_valid():
		_motion_tween.kill()


func _on_dialogue_session_started(
	session_id: StringName,
	started_dialogue_id: StringName
) -> void:
	if started_dialogue_id != dialogue_id:
		return
	active_session_id = session_id
	current_speaker_id = &""
	visible = true
	_frame_index = 0
	_show_frame(_frame_index)
	# The caller's slot is right-aligned, so one portrait width puts the art just
	# beyond the right edge without making it cross the entire screen.
	portrait_sprite.position.x = portrait_sprite.size.x + offscreen_margin
	_entering = true
	_start_motion(_active_x, entry_duration, Callable(self, "_on_entry_finished"))
	frame_timer.start()


func _on_dialogue_node_started(
	session_id: StringName,
	started_dialogue_id: StringName,
	_node_id: StringName,
	speaker_id: StringName
) -> void:
	if session_id != active_session_id or started_dialogue_id != dialogue_id:
		return
	current_speaker_id = speaker_id
	if _entering:
		return
	_move_for_speaker(speaker_id)


func _on_dialogue_session_finished(result: Dictionary) -> void:
	if StringName(result.get("session_id", &"")) != active_session_id:
		return
	active_session_id = &""
	current_speaker_id = &""
	_entering = false
	frame_timer.stop()
	if _motion_tween != null and _motion_tween.is_valid():
		_motion_tween.kill()


func _on_frame_timer_timeout() -> void:
	_frame_index += 1
	if _frame_index >= portrait_frames.size():
		frame_timer.stop()
		return
	_show_frame(_frame_index)
	if _frame_index == portrait_frames.size() - 1:
		frame_timer.stop()


func _on_entry_finished() -> void:
	_entering = false
	_move_for_speaker(current_speaker_id)


func _move_for_speaker(speaker_id: StringName) -> void:
	var target_x := _active_x
	if speaker_id == player_speaker_id:
		target_x += player_speaking_retreat
	elif speaker_id != caller_speaker_id:
		target_x += player_speaking_retreat
	_start_motion(target_x, speaker_transition_seconds)


func _start_motion(
	target_x: float,
	duration: float,
	finished_callback: Callable = Callable()
) -> void:
	if _motion_tween != null and _motion_tween.is_valid():
		_motion_tween.kill()
	_motion_tween = create_tween()
	_motion_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_motion_tween.tween_property(portrait_sprite, "position:x", target_x, duration)
	if finished_callback.is_valid():
		_motion_tween.finished.connect(finished_callback, CONNECT_ONE_SHOT)


func _show_frame(frame_index: int) -> void:
	for index in range(portrait_frames.size()):
		portrait_frames[index].visible = index == frame_index
