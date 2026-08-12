class_name IntroBedArrival
extends CanvasLayer

@export var arrival_spawn_id: StringName = &"intro_bed"
@export_range(0.1, 6.0, 0.1, "suffix:s") var room_fade_seconds: float = 3.5
@export_range(0.0, 3.0, 0.1, "suffix:s") var player_fade_delay_seconds: float = 0.6
@export_range(0.1, 6.0, 0.1, "suffix:s") var player_fade_seconds: float = 3.0
@export_range(0.1, 10.0, 0.1, "suffix:s") var birds_fade_out_seconds: float = 6.0
@export_range(-80.0, -20.0, 1.0, "suffix:dB") var silent_volume_db: float = -60.0

@onready var overlay: ColorRect = %IntroBedArrivalOverlay
@onready var birds: AudioStreamPlayer = %IntroBedArrivalBirds

var _player: Player
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
	if _arrival_tween != null and _arrival_tween.is_valid():
		_arrival_tween.kill()
	if _birds_tween != null and _birds_tween.is_valid():
		_birds_tween.kill()


func _finish_player_arrival() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	_player.set_process(true)
	_player.set_physics_process(true)
	_player.set_process_unhandled_input(true)
	overlay.visible = false
