class_name IntroBedArrival
extends CanvasLayer

@export var arrival_spawn_id: StringName = &"intro_bed"
@export_range(0.1, 6.0, 0.1, "suffix:s") var room_fade_seconds: float = 3.5
@export_range(0.0, 3.0, 0.1, "suffix:s") var player_fade_delay_seconds: float = 0.6
@export_range(0.1, 6.0, 0.1, "suffix:s") var player_fade_seconds: float = 3.0
@export_range(0.1, 10.0, 0.1, "suffix:s") var birds_fade_out_seconds: float = 6.0
@export_range(-80.0, -20.0, 1.0, "suffix:dB") var silent_volume_db: float = -60.0
@export_category("Post-arrival Dialogue")
@export var epilogue_dialogue_definition: DialogueDefinition
@export var epilogue_speaker_names: Dictionary = {
	&"mom": "Mom",
	&"player": "Player",
}

@onready var overlay: ColorRect = %IntroBedArrivalOverlay
@onready var birds: AudioStreamPlayer = %IntroBedArrivalBirds
@onready var portrait_presenter: IntroMemoryPortraitPresenter = %MemoryPortraitPresentation

var _player: Player
var last_dialogue_result: Dictionary = {}
var _dialogue_session_id: StringName = &""
var _arrival_tween: Tween
var _birds_tween: Tween


func _ready() -> void:
	_player = get_tree().get_first_node_in_group(&"player") as Player
	if (
		_player == null
		or StringName(_player.get_meta(&"arrival_spawn_id", &"")) != arrival_spawn_id
	):
		visible = false
		return
	_player.remove_meta(&"arrival_spawn_id")
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if dialogue_controller != null:
		dialogue_controller.dialogue_session_finished.connect(_on_dialogue_session_finished)
	var room_animation := get_parent().get_node_or_null("RoomVisibilityAnimation") as AnimationPlayer
	if room_animation != null and room_animation.has_animation(&"bedroom"):
		room_animation.play(&"bedroom")

	_player.set_process(false)
	_player.set_physics_process(false)
	_player.set_process_unhandled_input(false)
	_player.velocity = Vector2.ZERO
	_player.modulate.a = 0.0
	overlay.modulate.a = 1.0
	visible = true
	birds.play()

	_arrival_tween = create_tween()
	_arrival_tween.set_parallel(true)
	_arrival_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_arrival_tween.tween_property(
		overlay, "modulate:a", 0.0, room_fade_seconds
	)
	var player_track := _arrival_tween.tween_property(
		_player, "modulate:a", 1.0, player_fade_seconds
	)
	player_track.set_delay(player_fade_delay_seconds)
	player_track.finished.connect(_finish_player_arrival, CONNECT_ONE_SHOT)

	_birds_tween = create_tween()
	_birds_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_birds_tween.tween_property(
		birds, "volume_db", silent_volume_db, birds_fade_out_seconds
	)
	_birds_tween.finished.connect(birds.stop, CONNECT_ONE_SHOT)


func _exit_tree() -> void:
	_cancel_owned_dialogue()
	if _arrival_tween != null and _arrival_tween.is_valid():
		_arrival_tween.kill()
	if _birds_tween != null and _birds_tween.is_valid():
		_birds_tween.kill()


func _finish_player_arrival() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	overlay.visible = false
	_start_epilogue_dialogue()


func _start_epilogue_dialogue() -> void:
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if (
		dialogue_controller == null
		or not dialogue_controller.has_method("begin_modal_dialogue")
		or epilogue_dialogue_definition == null
	):
		_restore_player_control()
		return
	var result = dialogue_controller.call(
		"begin_modal_dialogue",
		self,
		epilogue_dialogue_definition,
		epilogue_speaker_names
	)
	if not (result is Dictionary) or not bool(result.get("accepted", false)):
		push_warning("Intro post-arrival dialogue was rejected.")
		_restore_player_control()
		return
	_dialogue_session_id = StringName(result.get("session_id", &""))
	portrait_presenter.reveal_session(_dialogue_session_id)


func _on_dialogue_session_finished(result: Dictionary) -> void:
	if StringName(result.get("session_id", &"")) != _dialogue_session_id:
		return
	_dialogue_session_id = &""
	last_dialogue_result = result.duplicate(true)
	_restore_player_control()


func _restore_player_control() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	_player.set_process(true)
	_player.set_physics_process(true)
	_player.set_process_unhandled_input(true)


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
		dialogue_controller.call("cancel_dialogue", "intro_bed_arrival_removed")
	_dialogue_session_id = &""
