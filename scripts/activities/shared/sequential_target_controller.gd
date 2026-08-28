class_name SequentialTargetController
extends Node

signal target_activated(target_index: int, target_position: Vector2)
signal incorrect_activation(
	attempted_position: Vector2,
	required_index: int,
	required_position: Vector2,
	distance: float
)
signal sequence_reset(target_count: int)
signal sequence_completed()

var activation_radius: float = 24.0
var _targets: PackedVector2Array = PackedVector2Array()
var _current_index: int = 0


func configure(targets: PackedVector2Array, radius: float) -> bool:
	if targets.is_empty() or radius <= 0.0:
		return false
	activation_radius = radius
	reset(targets)
	return true


func reset(targets: PackedVector2Array = PackedVector2Array()) -> void:
	if not targets.is_empty():
		_targets = PackedVector2Array(targets)
	_current_index = 0
	sequence_reset.emit(_targets.size())


func clear() -> void:
	_targets = PackedVector2Array()
	_current_index = 0
	sequence_reset.emit(0)


func try_activate(cursor_position: Vector2) -> bool:
	if not has_pending_target():
		return false
	var required_position := _targets[_current_index]
	var distance := cursor_position.distance_to(required_position)
	if distance > activation_radius:
		incorrect_activation.emit(
			cursor_position,
			_current_index,
			required_position,
			distance
		)
		return false

	var activated_index := _current_index
	_current_index += 1
	target_activated.emit(activated_index, required_position)
	if _current_index >= _targets.size():
		sequence_completed.emit()
	return true


func has_pending_target() -> bool:
	return not _targets.is_empty() and _current_index < _targets.size()


func is_complete() -> bool:
	return not _targets.is_empty() and _current_index >= _targets.size()


func get_current_index() -> int:
	return _current_index


func get_target_count() -> int:
	return _targets.size()


func get_targets() -> PackedVector2Array:
	return PackedVector2Array(_targets)


func get_current_target_position() -> Vector2:
	if not has_pending_target():
		return Vector2.ZERO
	return _targets[_current_index]
