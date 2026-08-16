class_name LockedDoorCue extends RefCounted

## Reusable locked-door presentation: floating text plus the shared lock sound.
## Basic use: LockedDoorCue.show(player)

const AUDIO_NODE_NAME: StringName = &"LockedDoorCueAudio"
const DEFAULT_SOUND: AudioStream = preload("res://sounds/locked door.mp3")
const DEFAULT_MESSAGE: String = "Door locked."
const DEFAULT_VOLUME_DB: float = 0.0
const DEFAULT_SOUND_SECONDS: float = 0.5


static func show(
	actor: Node2D,
	message: String = DEFAULT_MESSAGE,
	sound: AudioStream = DEFAULT_SOUND,
	volume_db: float = DEFAULT_VOLUME_DB,
	sound_seconds: float = DEFAULT_SOUND_SECONDS
) -> Label:
	return show_custom(
		actor,
		message,
		FloatingPlayerFeedback.DEFAULT_OFFSET,
		FloatingPlayerFeedback.DEFAULT_SIZE,
		FloatingPlayerFeedback.DEFAULT_COLOR,
		FloatingPlayerFeedback.DEFAULT_SECONDS,
		FloatingPlayerFeedback.DEFAULT_HOLD_SECONDS,
		FloatingPlayerFeedback.DEFAULT_RISE,
		sound,
		volume_db,
		sound_seconds
	)


static func show_custom(
	actor: Node2D,
	message: String,
	offset: Vector2,
	size: Vector2,
	color: Color,
	seconds: float,
	hold_seconds: float,
	rise: float,
	sound: AudioStream = DEFAULT_SOUND,
	volume_db: float = DEFAULT_VOLUME_DB,
	sound_seconds: float = DEFAULT_SOUND_SECONDS
) -> Label:
	var label := FloatingPlayerFeedback.show(
		actor, message, offset, size, color, seconds, hold_seconds, rise
	)
	_play_sound(actor, sound, volume_db, sound_seconds)
	return label


static func clear(actor: Node2D) -> void:
	FloatingPlayerFeedback.clear(actor)
	_clear_sound(actor)


static func _play_sound(
	actor: Node2D,
	sound: AudioStream,
	volume_db: float,
	sound_seconds: float
) -> void:
	if actor == null or not is_instance_valid(actor) or sound == null:
		return
	_clear_sound(actor)
	var audio := AudioStreamPlayer2D.new()
	audio.name = AUDIO_NODE_NAME
	audio.stream = sound
	audio.volume_db = volume_db
	actor.add_child(audio)
	var cutoff := Timer.new()
	cutoff.name = "Cutoff"
	cutoff.one_shot = true
	cutoff.wait_time = maxf(sound_seconds, 0.01)
	audio.add_child(cutoff)
	audio.finished.connect(audio.queue_free)
	cutoff.timeout.connect(audio.queue_free)
	audio.play()
	cutoff.start()


static func _clear_sound(actor: Node2D) -> void:
	if actor == null or not is_instance_valid(actor):
		return
	var existing := actor.get_node_or_null(NodePath(String(AUDIO_NODE_NAME)))
	if existing != null:
		existing.free()
