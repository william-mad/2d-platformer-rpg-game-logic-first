class_name DialoguePortraitAnimationProfile
extends Resource

## Transparent, full-canvas eye frames layered over the base portrait.
@export var blink_frames: Array[Texture2D] = []
## Zero-based frame indices. A negative index clears the overlay for that step.
@export var blink_sequence: PackedInt32Array = PackedInt32Array([0, 1, 2, 3, 4, 3, 2, 1, 0])
@export_range(0.5, 10.0, 0.05, "suffix:s") var blink_interval_seconds: float = 2.0
@export_range(0.01, 0.5, 0.005, "suffix:s") var blink_frame_seconds: float = 0.045

## Transparent, full-canvas mouth frames layered over the base portrait.
@export var talk_frames: Array[Texture2D] = []
## The final negative index intentionally makes the mouth overlay disappear.
@export var talk_sequence: PackedInt32Array = PackedInt32Array([0, 1, 2, 1, 3, 4, -1])
@export_range(0.01, 0.5, 0.005, "suffix:s") var talk_frame_seconds: float = 0.09
@export_range(0.1, 10.0, 0.1, "suffix:s") var talk_duration_seconds: float = 3.0


func get_validation_error() -> String:
	var blink_error := _get_sequence_validation_error(
		blink_frames, blink_sequence, false, "blink"
	)
	if not blink_error.is_empty():
		return blink_error
	return _get_sequence_validation_error(
		talk_frames, talk_sequence, true, "talk"
	)


func get_blink_texture(sequence_index: int) -> Texture2D:
	return _get_sequence_texture(blink_frames, blink_sequence, sequence_index)


func get_talk_texture(sequence_index: int) -> Texture2D:
	return _get_sequence_texture(talk_frames, talk_sequence, sequence_index)


func _get_sequence_validation_error(
	frames: Array[Texture2D],
	sequence: PackedInt32Array,
	allow_clear_step: bool,
	label: String
) -> String:
	if frames.is_empty():
		return "portrait_animation_%s_frames_empty" % label
	for frame in frames:
		if frame == null:
			return "portrait_animation_%s_frame_missing" % label
	if sequence.is_empty():
		return "portrait_animation_%s_sequence_empty" % label
	for frame_index in sequence:
		if frame_index < 0:
			if allow_clear_step:
				continue
			return "portrait_animation_%s_sequence_clear_not_allowed" % label
		if frame_index >= frames.size():
			return "portrait_animation_%s_sequence_frame_out_of_range" % label
	return ""


func _get_sequence_texture(
	frames: Array[Texture2D],
	sequence: PackedInt32Array,
	sequence_index: int
) -> Texture2D:
	if sequence_index < 0 or sequence_index >= sequence.size():
		return null
	var frame_index := sequence[sequence_index]
	if frame_index < 0 or frame_index >= frames.size():
		return null
	return frames[frame_index]
