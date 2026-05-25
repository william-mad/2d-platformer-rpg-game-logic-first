class_name Damage_Area extends Area2D

@export var hit_sound_enabled: bool = true
@export var hit_sound_volume: float = 0.18
@export var hit_sound_pitch: float = 520.0
@export var hit_sound_length: float = 0.055

var hit_audio_player: AudioStreamPlayer2D


func _ready() -> void:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 22050.0
	generator.buffer_length = 0.08

	hit_audio_player = AudioStreamPlayer2D.new()
	hit_audio_player.stream = generator
	add_child(hit_audio_player)


func take_damage( attack ) -> void:
	print ("damage felt in damage area: ", attack.damage)
	play_hit_sound()
	var damage_owner := get_parent()

	if damage_owner != null and damage_owner.has_method("take_damage"):
		damage_owner.take_damage(attack.damage, attack.global_position)

	pass


func play_hit_sound() -> void:
	if not hit_sound_enabled or hit_audio_player == null:
		return

	hit_audio_player.stop()
	hit_audio_player.play()

	var playback := hit_audio_player.get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		return

	var frame_count := int(22050.0 * hit_sound_length)
	for i in range(frame_count):
		var progress := float(i) / float(frame_count)
		var envelope := 1.0 - progress
		var sample := sin(progress * TAU * hit_sound_pitch * hit_sound_length) * envelope * hit_sound_volume
		playback.push_frame(Vector2(sample, sample))
	
