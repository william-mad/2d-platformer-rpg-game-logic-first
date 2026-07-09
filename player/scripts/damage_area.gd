class_name Damage_Area extends Area2D

const CombatLayers := preload("res://scripts/systems/combat_layers.gd")

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


func take_damage(attack) -> void:
	play_hit_sound()
	var damage_owner := get_parent()
	var damage_source := get_damage_source(attack)
	var attack_tags := get_attack_tags(attack)

	if damage_owner != null and damage_owner.has_method("take_damage"):
		if damage_owner.has_method("set_last_damage_tags"):
			damage_owner.call("set_last_damage_tags", attack_tags)
		damage_owner.take_damage(
			attack.damage,
			attack.global_position,
			damage_source,
			get_knockout_damage(attack)
		)

	pass


func get_damage_source(attack: Node) -> Node:
	if attack == null:
		return null

	if attack.has_method("get_damage_source"):
		var source := attack.get_damage_source() as Node
		if source != null:
			return source

	var attack_owner := attack.get_parent()
	return attack_owner if attack_owner != null else attack


func get_knockout_damage(attack: Node) -> float:
	if attack == null:
		return 0.0

	if attack.has_method("get_knockout_damage"):
		return maxf(float(attack.call("get_knockout_damage")), 0.0)

	var value = attack.get("knockout_damage")
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return maxf(float(value), 0.0)

	return 0.0


func get_attack_tags(attack: Node) -> Array[StringName]:
	var tags: Array[StringName] = []
	if attack == null:
		return tags

	if attack is CollisionObject2D:
		var collision_object := attack as CollisionObject2D
		if collision_object.collision_layer & CombatLayers.ATTACK_SPELL_DETECTION_LAYER:
			tags.append(&"magic")

	if attack.has_meta("progression_tags"):
		var meta_tags = attack.get_meta("progression_tags")
		if meta_tags is Array:
			for raw_tag in meta_tags:
				var tag := StringName(String(raw_tag))
				if tag != &"" and not tags.has(tag):
					tags.append(tag)

	return tags


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
	
