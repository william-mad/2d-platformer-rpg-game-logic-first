class_name SaveSpot extends Area2D

@export var save_slot: String = "slot_1"
@export var save_action: StringName = &"up"
@export var ready_text: String = "UP: SAVE"
@export var saved_text: String = "SAVED"
@export var missing_system_text: String = "No SaveSystem"
@export var feedback_seconds: float = 1.4

@onready var label: Label = get_node_or_null("%Label") as Label
@onready var zone_visual: Polygon2D = get_node_or_null("%ZoneVisual") as Polygon2D

var feedback_timer: float = 0.0


func _ready() -> void:
	_update_label(ready_text)


func _process(delta: float) -> void:
	if feedback_timer > 0.0:
		feedback_timer = maxf(feedback_timer - delta, 0.0)
		if is_zero_approx(feedback_timer):
			_update_label(ready_text)

	if Input.is_action_just_pressed(save_action) and _has_player_inside():
		_save_here()


func _save_here() -> void:
	# This is the only line a save point really needs: it asks the global save system to store the current scene.
	if not has_node("/root/SaveSystem"):
		_show_feedback(missing_system_text, false)
		return

	var success: bool = SaveSystem.save_current_game(save_slot)
	_show_feedback(saved_text if success else "Save failed", success)


func _show_feedback(message: String, success: bool) -> void:
	feedback_timer = feedback_seconds
	_update_label(message)

	if zone_visual == null:
		return

	zone_visual.color = Color(0.26, 0.82, 0.43, 0.48) if success else Color(0.9, 0.14, 0.1, 0.48)


func _update_label(message: String) -> void:
	if label != null:
		label.text = message

	if zone_visual != null and message == ready_text:
		zone_visual.color = Color(0.25, 0.68, 0.95, 0.38)


func _has_player_inside() -> bool:
	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			return true

	return false
