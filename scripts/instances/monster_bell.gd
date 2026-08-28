class_name MonsterBell extends Node2D

signal rung(actor: Node, payload: Dictionary)

@export_range(0.05, 2.0, 0.05, "suffix:s") var ring_cooldown_seconds: float = 0.45
@export_range(0.1, 2.0, 0.05, "suffix:s") var ring_sound_seconds: float = 0.65
@export_range(0.0, 1.0, 0.01) var ring_sound_volume: float = 0.22

@onready var bell_visual: Node2D = get_node_or_null("BellVisual") as Node2D
@onready var event_emitter: NpcRadiusEventEmitter = (
	get_node_or_null("NpcRadiusEventEmitter") as NpcRadiusEventEmitter
)

var ring_count: int = 0
var _last_ring_msec: int = -1000000
var _ring_audio: AudioStreamPlayer2D
var _swing_tween: Tween


func _ready() -> void:
	add_to_group(&"attack_target")
	add_to_group(&"monster_bell")
	_setup_ring_audio()


func take_damage(
	amount: float,
	damage_source_position: Vector2 = Vector2.ZERO,
	damage_source: Node = null,
	_knockout_damage: float = 0.0
) -> void:
	if amount <= 0.0:
		return
	var now_msec := Time.get_ticks_msec()
	if now_msec - _last_ring_msec < int(maxf(ring_cooldown_seconds, 0.05) * 1000.0):
		return
	_last_ring_msec = now_msec

	var actor := _resolve_responsible_actor(damage_source)
	var payload: Dictionary = {}
	if event_emitter != null:
		payload = event_emitter.emit_radius_event(
			actor,
			self,
			self,
			global_position,
			{
				"damage_source_position": damage_source_position,
				"false_alarm_reaction_priority": 45,
				"false_alarm_directed_opinion_delta": {
					"favor": -2.0,
					"trust": -1.0,
					"anger": 2.0,
				},
			}
		)
	ring_count += 1
	_play_ring_sound()
	_play_swing()
	rung.emit(actor, payload)


func can_be_targeted_by_monster() -> bool:
	return true


func get_current_health() -> float:
	# The alarm is a durable world prop, not a combatant monsters can destroy.
	return 1.0


func get_attack_aim_position() -> Vector2:
	return global_position + Vector2(0.0, -58.0)


func _resolve_responsible_actor(damage_source: Node) -> Node:
	var source := damage_source
	if source != null and source.has_method("get_damage_source"):
		var resolved := source.call("get_damage_source") as Node
		if resolved != null and resolved != source:
			source = resolved

	while source != null and is_instance_valid(source):
		if (
			source.is_in_group("player")
			or source.is_in_group("npc")
			or source.is_in_group("monster")
			or source.is_in_group("monsters")
		):
			return source
		source = source.get_parent()
	return null


func _setup_ring_audio() -> void:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 22050.0
	generator.buffer_length = maxf(ring_sound_seconds + 0.1, 0.2)
	_ring_audio = AudioStreamPlayer2D.new()
	_ring_audio.name = "BellAudio"
	_ring_audio.stream = generator
	_ring_audio.max_distance = event_emitter.radius if event_emitter != null else 1200.0
	add_child(_ring_audio)


func _play_ring_sound() -> void:
	if _ring_audio == null or ring_sound_volume <= 0.0:
		return
	_ring_audio.stop()
	_ring_audio.play()
	var playback := _ring_audio.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		return
	var mix_rate := 22050.0
	var duration := maxf(ring_sound_seconds, 0.1)
	var frame_count := int(mix_rate * duration)
	for frame in frame_count:
		var time := float(frame) / mix_rate
		var progress := time / duration
		var envelope := pow(1.0 - progress, 2.2)
		var sample := (
			sin(TAU * 720.0 * time)
			+ (sin(TAU * 1440.0 * time) * 0.48)
			+ (sin(TAU * 2165.0 * time) * 0.2)
		) * envelope * ring_sound_volume
		playback.push_frame(Vector2(sample, sample))


func _play_swing() -> void:
	if bell_visual == null:
		return
	if _swing_tween != null and _swing_tween.is_valid():
		_swing_tween.kill()
	bell_visual.rotation = -0.2
	_swing_tween = create_tween()
	_swing_tween.set_trans(Tween.TRANS_SINE)
	_swing_tween.set_ease(Tween.EASE_IN_OUT)
	_swing_tween.tween_property(bell_visual, "rotation", 0.17, 0.09)
	_swing_tween.tween_property(bell_visual, "rotation", -0.1, 0.11)
	_swing_tween.tween_property(bell_visual, "rotation", 0.05, 0.12)
	_swing_tween.tween_property(bell_visual, "rotation", 0.0, 0.14)
