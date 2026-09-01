class_name IntroSequenceController
extends Node

signal phase_changed(previous_phase: StringName, current_phase: StringName)
signal phone_interaction_enabled
signal phone_answered
signal dialogue_requested(dialogue_controller: Node, portrait_presentation: Control)
signal exit_requested(next_scene_path: String)

enum Phase {
	FADE_IN,
	WAIT_FOR_PHONE,
	PHONE_INTERACTION,
	ANSWER_TRANSITION,
	DIALOGUE,
	EXIT,
}

const INTRO_LOCK_REASON := &"phone_call_intro"

@export_file("*.tscn") var next_scene_path: String = "res://scenes/levels/intro_walk_interlude.tscn"
@export_category("Opening Pace")
@export_range(0.0, 2.0, 0.05, "suffix:s") var visual_start_delay_seconds: float = 0.5
@export_range(0.5, 8.0, 0.1, "suffix:s") var fade_in_seconds: float = 4.0
@export_range(0.0, 4.0, 0.1) var opening_blur_strength: float = 3.0
@export_range(1.0, 16.0, 0.1, "suffix:s") var ambience_fade_in_seconds: float = 10.5
@export_range(-80.0, -20.0, 1.0, "suffix:dB") var ambience_start_volume_db: float = -36.0
@export_range(0.0, 5.0, 0.05, "suffix:s") var establishing_hold_seconds: float = 1.5
@export_category("Establishing Illustration")
@export var establishing_frames: Array[Texture2D] = []
@export_range(0.2, 3.0, 0.05, "suffix:s") var establishing_frame_seconds: float = 0.5

@export_category("Transitions")
@export_range(0.05, 2.0, 0.05, "suffix:s") var answer_transition_seconds: float = 0.35
@export_range(0.1, 3.0, 0.05, "suffix:s") var exit_fade_seconds: float = 0.6
@export_range(0.05, 1.0, 0.05, "suffix:s") var dialogue_backdrop_mute_seconds: float = 0.3
@export var dialogue_definition: DialogueDefinition
@export var dialogue_speaker_names: Dictionary = {
	&"caller": "Mom",
	&"player": "Player",
}

@onready var fade_overlay: ColorRect = %FadeOverlay
@onready var establishing_illustration: TextureRect = %EstablishingIllustration
@onready var opening_blur_overlay: ColorRect = %OpeningBlurOverlay
@onready var dialogue_backdrop_mute: ColorRect = %DialogueBackdropMute
@onready var phone_minigame_host: Control = %PhoneMinigameHost
@onready var portrait_presentation: Control = %PortraitPresentation
@onready var opening_visual_delay_timer: Timer = %OpeningVisualDelayTimer
@onready var establishing_timer: Timer = %EstablishingTimer
@onready var establishing_frame_timer: Timer = %EstablishingFrameTimer
@onready var city_ambience: AudioStreamPlayer = %CityAmbience
@onready var phone_ringing: AudioStreamPlayer = %PhoneRinging

var current_phase: Phase = Phase.FADE_IN
var last_dialogue_result: Dictionary = {}

var _world_progression_lock_token: int = 0
var _dialogue_session_id: StringName = &""
var _active_tween: Tween
var _ambience_tween: Tween
var _backdrop_tween: Tween
var _exit_started: bool = false
var _ambience_target_volume_db: float = -8.0
var _visual_reveal_complete: bool = false
var _ambience_fade_complete: bool = false
var _establishing_frame_index: int = 0


func _ready() -> void:
	var player_hud := get_node_or_null("/root/PlayerHud")
	if player_hud != null:
		player_hud.visible = false

	phone_minigame_host.visible = false
	portrait_presentation.visible = false
	fade_overlay.modulate.a = 1.0
	opening_blur_overlay.visible = true
	_set_opening_blur_strength(opening_blur_strength)
	dialogue_backdrop_mute.modulate.a = 0.0
	_ambience_target_volume_db = city_ambience.volume_db
	city_ambience.volume_db = ambience_start_volume_db

	opening_visual_delay_timer.timeout.connect(_start_fade_in)
	establishing_timer.timeout.connect(_on_establishing_timer_timeout)
	establishing_frame_timer.timeout.connect(_advance_establishing_frame)
	city_ambience.finished.connect(_on_city_ambience_finished)
	phone_ringing.finished.connect(_on_phone_ringing_finished)
	phone_minigame_host.connect(&"answered", _on_phone_minigame_answered)
	_bind_dialogue_signals()

	_acquire_intro_lock()
	_preload_next_scene()
	_set_phase(Phase.FADE_IN)
	_start_establishing_illustration_loop()
	_start_ambience_fade_in()
	if visual_start_delay_seconds > 0.0:
		opening_visual_delay_timer.start(visual_start_delay_seconds)
	else:
		_start_fade_in()


func _start_establishing_illustration_loop() -> void:
	if establishing_frames.is_empty():
		return
	_establishing_frame_index = 0
	establishing_illustration.texture = establishing_frames[_establishing_frame_index]
	if establishing_frames.size() > 1:
		establishing_frame_timer.start(establishing_frame_seconds)


func _advance_establishing_frame() -> void:
	if establishing_frames.is_empty():
		establishing_frame_timer.stop()
		return
	_establishing_frame_index = (_establishing_frame_index + 1) % establishing_frames.size()
	establishing_illustration.texture = establishing_frames[_establishing_frame_index]


func _exit_tree() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	if _ambience_tween != null and _ambience_tween.is_valid():
		_ambience_tween.kill()
	if _backdrop_tween != null and _backdrop_tween.is_valid():
		_backdrop_tween.kill()
	_cancel_owned_dialogue()
	_release_intro_lock()


func complete_dialogue() -> bool:
	if current_phase != Phase.DIALOGUE or _exit_started:
		return false
	_begin_exit()
	return true


func get_phase_name() -> StringName:
	return _phase_name(current_phase)


func _start_fade_in() -> void:
	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_active_tween.set_parallel(true)
	_active_tween.tween_property(fade_overlay, "modulate:a", 0.0, fade_in_seconds)
	_active_tween.tween_method(
		_set_opening_blur_strength,
		opening_blur_strength,
		0.0,
		fade_in_seconds
	)
	_active_tween.finished.connect(_on_fade_in_finished, CONNECT_ONE_SHOT)


func _on_fade_in_finished() -> void:
	if current_phase != Phase.FADE_IN:
		return
	opening_blur_overlay.visible = false
	_visual_reveal_complete = true
	_set_phase(Phase.WAIT_FOR_PHONE)
	_try_begin_pre_ring_hold()


func _start_ambience_fade_in() -> void:
	city_ambience.volume_db = ambience_start_volume_db
	city_ambience.play()
	_ambience_tween = create_tween()
	_ambience_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_ambience_tween.tween_property(
		city_ambience,
		"volume_db",
		_ambience_target_volume_db,
		ambience_fade_in_seconds
	)
	_ambience_tween.finished.connect(_on_ambience_fade_in_finished, CONNECT_ONE_SHOT)


func _on_ambience_fade_in_finished() -> void:
	_ambience_fade_complete = true
	_try_begin_pre_ring_hold()


func _try_begin_pre_ring_hold() -> void:
	if (
		current_phase != Phase.WAIT_FOR_PHONE
		or not _visual_reveal_complete
		or not _ambience_fade_complete
		or not establishing_timer.is_stopped()
	):
		return
	establishing_timer.start(establishing_hold_seconds)


func _on_establishing_timer_timeout() -> void:
	if current_phase != Phase.WAIT_FOR_PHONE:
		return
	phone_ringing.play()
	_enable_phone_interaction()


func _on_city_ambience_finished() -> void:
	if is_inside_tree():
		city_ambience.play()


func _set_opening_blur_strength(value: float) -> void:
	var shader_material := opening_blur_overlay.material as ShaderMaterial
	if shader_material != null:
		shader_material.set_shader_parameter(&"blur_strength", value)


func _on_phone_ringing_finished() -> void:
	# The incoming-call screen starts with the first ring. Audio completion is
	# only responsible for repeating the ring, never for unlocking the scene.
	if current_phase == Phase.WAIT_FOR_PHONE:
		_enable_phone_interaction()
	if current_phase == Phase.WAIT_FOR_PHONE or current_phase == Phase.PHONE_INTERACTION:
		phone_ringing.play()


func _enable_phone_interaction() -> void:
	_set_phase(Phase.PHONE_INTERACTION)
	phone_minigame_host.modulate.a = 1.0
	phone_minigame_host.visible = true
	phone_minigame_host.call("activate")
	phone_interaction_enabled.emit()


func _on_phone_minigame_answered() -> void:
	_answer_phone()


func _answer_phone() -> void:
	if current_phase != Phase.PHONE_INTERACTION:
		return
	phone_ringing.stop()
	_set_phase(Phase.ANSWER_TRANSITION)
	phone_answered.emit()

	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_active_tween.tween_property(
		phone_minigame_host,
		"modulate:a",
		0.0,
		answer_transition_seconds
	)
	_active_tween.finished.connect(_enter_dialogue_phase, CONNECT_ONE_SHOT)


func _enter_dialogue_phase() -> void:
	if current_phase != Phase.ANSWER_TRANSITION:
		return
	phone_minigame_host.call("show_dialogue_background")
	phone_minigame_host.visible = true
	phone_minigame_host.modulate.a = 0.0
	_set_phase(Phase.DIALOGUE)
	_backdrop_tween = create_tween()
	_backdrop_tween.set_parallel(true)
	_backdrop_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_backdrop_tween.tween_property(
		phone_minigame_host,
		"modulate:a",
		1.0,
		dialogue_backdrop_mute_seconds
	)
	_backdrop_tween.tween_property(
		dialogue_backdrop_mute,
		"modulate:a",
		1.0,
		dialogue_backdrop_mute_seconds
	)

	var dialogue_controller := get_node_or_null("/root/DialogueController")
	dialogue_requested.emit(dialogue_controller, portrait_presentation)
	if dialogue_definition == null:
		push_warning("Phone-call intro dialogue definition is not configured.")
		return
	_start_configured_dialogue(dialogue_controller)


func _start_configured_dialogue(dialogue_controller: Node) -> void:
	if dialogue_controller == null or not dialogue_controller.has_method("begin_modal_dialogue"):
		push_warning("Phone-call intro could not find the shared DialogueController.")
		return
	var result = dialogue_controller.call(
		"begin_modal_dialogue",
		self,
		dialogue_definition,
		dialogue_speaker_names
	)
	if not (result is Dictionary) or not bool(result.get("accepted", false)):
		var reason := String(result.get("reason", "rejected")) if result is Dictionary else "invalid_result"
		push_warning("Phone-call intro dialogue was rejected: %s." % reason)
		return
	_dialogue_session_id = StringName(result.get("session_id", &""))


func _on_dialogue_session_finished(result: Dictionary) -> void:
	if StringName(result.get("session_id", &"")) != _dialogue_session_id:
		return
	_dialogue_session_id = &""
	last_dialogue_result = result.duplicate(true)
	if bool(result.get("completed", false)):
		complete_dialogue()


func _begin_exit() -> void:
	_exit_started = true
	_set_phase(Phase.EXIT)
	portrait_presentation.visible = false
	phone_ringing.stop()

	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_active_tween.tween_property(fade_overlay, "modulate:a", 1.0, exit_fade_seconds)
	_active_tween.finished.connect(_handoff_to_next_scene, CONNECT_ONE_SHOT)


func _handoff_to_next_scene() -> void:
	var normalized_path := next_scene_path.strip_edges()
	if normalized_path.is_empty():
		push_warning("Phone-call intro next scene path is empty.")
		return

	exit_requested.emit(normalized_path)
	_release_intro_lock()
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null or not scene_loader.has_method("change_scene"):
		push_warning("Phone-call intro could not find the shared SceneLoader.")
		return
	if not bool(scene_loader.call("change_scene", normalized_path)):
		push_warning("Phone-call intro SceneLoader handoff was rejected.")


func _bind_dialogue_signals() -> void:
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if dialogue_controller == null or not dialogue_controller.has_signal(&"dialogue_session_finished"):
		return
	var callback := Callable(self, "_on_dialogue_session_finished")
	if not dialogue_controller.is_connected(&"dialogue_session_finished", callback):
		dialogue_controller.connect(&"dialogue_session_finished", callback)


func _cancel_owned_dialogue() -> void:
	if _dialogue_session_id == &"":
		return
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if (
		dialogue_controller != null
		and dialogue_controller.has_method("is_dialogue_active")
		and bool(dialogue_controller.call("is_dialogue_active"))
		and StringName(dialogue_controller.get("current_session_id")) == _dialogue_session_id
	):
		dialogue_controller.call("cancel_dialogue", "intro_removed")
	_dialogue_session_id = &""


func _acquire_intro_lock() -> void:
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null or not gameplay_flow.has_method("acquire_world_progression_lock"):
		return
	_world_progression_lock_token = int(gameplay_flow.call(
		"acquire_world_progression_lock",
		self,
		INTRO_LOCK_REASON
	))


func _release_intro_lock() -> void:
	if _world_progression_lock_token == 0:
		return
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow != null and gameplay_flow.has_method("release_world_progression_lock"):
		gameplay_flow.call(
			"release_world_progression_lock",
			_world_progression_lock_token,
			self
		)
	_world_progression_lock_token = 0


func _preload_next_scene() -> void:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("preload_scene"):
		scene_loader.call("preload_scene", next_scene_path)


func _set_phase(next_phase: Phase) -> void:
	var previous_phase := current_phase
	current_phase = next_phase
	phase_changed.emit(_phase_name(previous_phase), _phase_name(current_phase))


func _phase_name(phase: Phase) -> StringName:
	match phase:
		Phase.FADE_IN:
			return &"FADE_IN"
		Phase.WAIT_FOR_PHONE:
			return &"WAIT_FOR_PHONE"
		Phase.PHONE_INTERACTION:
			return &"PHONE_INTERACTION"
		Phase.ANSWER_TRANSITION:
			return &"ANSWER_TRANSITION"
		Phase.DIALOGUE:
			return &"DIALOGUE"
		Phase.EXIT:
			return &"EXIT"
	return &""
