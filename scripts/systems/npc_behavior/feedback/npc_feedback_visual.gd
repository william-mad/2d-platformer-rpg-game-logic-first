class_name NpcFeedbackVisual extends Node2D

@onready var panel: PanelContainer = %Panel
@onready var icon: TextureRect = %Icon
@onready var label: Label = %Label


func _ready() -> void:
	visible = false
	call_deferred("_center_panel")


func set_content(text: String, texture: Texture2D = null) -> void:
	if label == null or icon == null:
		return
	if label.text != text:
		label.text = text
	icon.texture = texture
	icon.visible = texture != null
	call_deferred("_center_panel")


func clear_content() -> void:
	if label == null or icon == null:
		visible = false
		return
	if label.text != "":
		label.text = ""
	icon.texture = null
	icon.visible = false
	visible = false


func _center_panel() -> void:
	if panel == null:
		return
	panel.position = Vector2(
		-floorf(panel.size.x * 0.5),
		-floorf(panel.size.y * 0.5)
	)
