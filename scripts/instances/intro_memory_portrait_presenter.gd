class_name IntroMemoryPortraitPresenter
extends Control

@export var dialogue_id: StringName = &"intro_memory_montage"
@export var portrait_speaker_id: StringName = &"mom"
@export var player_speaker_id: StringName = &"player"
@export_range(0.1, 1.5, 0.05, "suffix:s") var entry_duration: float = 0.65
@export_range(20.0, 35.0, 1.0, "suffix:px") var player_speaking_retreat: float = 28.0
@export_range(0.05, 0.5, 0.01, "suffix:s") var speaker_transition_seconds: float = 0.16
@export_range(0.0, 64.0, 1.0, "suffix:px") var offscreen_margin: float = 16.0

@onready var portrait_sprite: Control = %MemoryDialoguePortrait
@onready var backdrop_mute: ColorRect = %MemoryDialogueBackdropMute
@onready var blink_overlay: TextureRect = get_node_or_null(
	"%DialoguePortraitBlinkOverlay"
) as TextureRect
@onready var talk_overlay: TextureRect = get_node_or_null(
	"%DialoguePortraitTalkOverlay"
) as TextureRect

var active_session_id: StringName = &""
var current_speaker_id: StringName = &""
var portrait_animation: DialoguePortraitAnimationProfile
var _active_x: float = 0.0
var _entering: bool = false
var _reveal_enabled: bool = false
var _motion_tween: Tween
var _backdrop_tween: Tween
var _blink_interval_elapsed: float = 0.0
var _blink_frame_elapsed: float = 0.0
var _blink_sequence_index: int = -1
var _talk_total_elapsed: float = 0.0
var _talk_frame_elapsed: float = 0.0
var _talk_sequence_index: int = -1
var _talking: bool = false


func _ready() -> void:
	visible = false
	backdrop_mute.visible = false
	_active_x = portrait_sprite.position.x
	_reset_portrait_animation()
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if dialogue_controller == null:
		return
	dialogue_controller.dialogue_session_started.connect(_on_dialogue_session_started)
	dialogue_controller.dialogue_node_started.connect(_on_dialogue_node_started)
	dialogue_controller.dialogue_session_finished.connect(_on_dialogue_session_finished)


func _process(delta: float) -> void:
	if (
		portrait_animation == null
		or active_session_id == &""
		or not visible
	):
		return
	_update_blink_animation(delta)
	_update_talk_animation(delta)


func _exit_tree() -> void:
	_kill_tweens()


func _on_dialogue_session_started(
	session_id: StringName,
	started_dialogue_id: StringName
) -> void:
	if started_dialogue_id != dialogue_id:
		return
	active_session_id = session_id
	current_speaker_id = &""
	_reveal_enabled = false
	_reset_portrait_animation()


func _on_dialogue_node_started(
	session_id: StringName,
	started_dialogue_id: StringName,
	_node_id: StringName,
	speaker_id: StringName
) -> void:
	if session_id != active_session_id or started_dialogue_id != dialogue_id:
		return
	current_speaker_id = speaker_id
	if speaker_id == portrait_speaker_id:
		_start_talk_animation()
	else:
		_stop_talk_animation()
	if not _reveal_enabled:
		return
	if speaker_id == portrait_speaker_id and not visible:
		_enter_portrait()
		return
	if visible and not _entering:
		_move_for_speaker(speaker_id)


func _on_dialogue_session_finished(result: Dictionary) -> void:
	if StringName(result.get("session_id", &"")) != active_session_id:
		return
	active_session_id = &""
	current_speaker_id = &""
	_entering = false
	_reveal_enabled = false
	_kill_tweens()
	_reset_portrait_animation()
	visible = false
	backdrop_mute.visible = false


func configure_portrait_animation(
	animation: DialoguePortraitAnimationProfile
) -> void:
	portrait_animation = animation
	_reset_portrait_animation()


func get_portrait_animation_report() -> Dictionary:
	return {
		"configured": portrait_animation != null,
		"blink_sequence_index": _blink_sequence_index,
		"blink_texture": blink_overlay.texture if blink_overlay != null else null,
		"talking": _talking,
		"talk_elapsed": _talk_total_elapsed,
		"talk_sequence_index": _talk_sequence_index,
		"talk_texture": talk_overlay.texture if talk_overlay != null else null,
	}


func reveal_session(session_id: StringName) -> bool:
	if session_id == &"" or session_id != active_session_id:
		return false
	_reveal_enabled = true
	if current_speaker_id == portrait_speaker_id and not visible:
		_enter_portrait()
	elif visible and not _entering:
		_move_for_speaker(current_speaker_id)
	return true


func _enter_portrait() -> void:
	visible = true
	backdrop_mute.visible = true
	backdrop_mute.modulate.a = 0.0
	portrait_sprite.position.x = portrait_sprite.size.x + offscreen_margin
	_entering = true
	_start_motion(_active_x, entry_duration, Callable(self, "_on_entry_finished"))
	_backdrop_tween = create_tween()
	_backdrop_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_backdrop_tween.tween_property(backdrop_mute, "modulate:a", 1.0, entry_duration)


func _on_entry_finished() -> void:
	_entering = false
	_move_for_speaker(current_speaker_id)


func _move_for_speaker(speaker_id: StringName) -> void:
	var target_x := _active_x
	if speaker_id == player_speaker_id or speaker_id != portrait_speaker_id:
		target_x += player_speaking_retreat
	_start_motion(target_x, speaker_transition_seconds)


func _update_blink_animation(delta: float) -> void:
	if blink_overlay == null or portrait_animation.blink_sequence.is_empty():
		return
	_blink_interval_elapsed += delta
	if _blink_sequence_index < 0:
		if _blink_interval_elapsed < portrait_animation.blink_interval_seconds:
			return
		_blink_interval_elapsed = 0.0
		_blink_frame_elapsed = 0.0
		_blink_sequence_index = 0
		blink_overlay.texture = portrait_animation.get_blink_texture(0)
		return

	_blink_frame_elapsed += delta
	while _blink_frame_elapsed >= portrait_animation.blink_frame_seconds:
		_blink_frame_elapsed -= portrait_animation.blink_frame_seconds
		_blink_sequence_index += 1
		if _blink_sequence_index >= portrait_animation.blink_sequence.size():
			_blink_sequence_index = -1
			blink_overlay.texture = portrait_animation.get_blink_texture(0)
			return
		blink_overlay.texture = portrait_animation.get_blink_texture(
			_blink_sequence_index
		)


func _update_talk_animation(delta: float) -> void:
	if not _talking or talk_overlay == null:
		return
	_talk_total_elapsed += delta
	if _talk_total_elapsed >= portrait_animation.talk_duration_seconds:
		_stop_talk_animation()
		return

	_talk_frame_elapsed += delta
	while _talk_frame_elapsed >= portrait_animation.talk_frame_seconds:
		_talk_frame_elapsed -= portrait_animation.talk_frame_seconds
		_talk_sequence_index += 1
		if _talk_sequence_index >= portrait_animation.talk_sequence.size():
			_talk_sequence_index = 0
		talk_overlay.texture = portrait_animation.get_talk_texture(
			_talk_sequence_index
		)


func _start_talk_animation() -> void:
	if (
		portrait_animation == null
		or talk_overlay == null
		or portrait_animation.talk_sequence.is_empty()
	):
		return
	_talking = true
	_talk_total_elapsed = 0.0
	_talk_frame_elapsed = 0.0
	_talk_sequence_index = 0
	talk_overlay.texture = portrait_animation.get_talk_texture(0)


func _stop_talk_animation() -> void:
	_talking = false
	_talk_total_elapsed = 0.0
	_talk_frame_elapsed = 0.0
	_talk_sequence_index = -1
	if talk_overlay != null:
		talk_overlay.texture = null


func _reset_portrait_animation() -> void:
	_blink_interval_elapsed = 0.0
	_blink_frame_elapsed = 0.0
	_blink_sequence_index = -1
	_stop_talk_animation()
	if blink_overlay != null:
		blink_overlay.texture = (
			portrait_animation.get_blink_texture(0)
			if portrait_animation != null
			else null
		)


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


func _kill_tweens() -> void:
	for tween in [_motion_tween, _backdrop_tween]:
		if tween != null and tween.is_valid():
			tween.kill()
