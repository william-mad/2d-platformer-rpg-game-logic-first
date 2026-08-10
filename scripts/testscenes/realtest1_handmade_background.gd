class_name RealTest1HandmadeBackground extends Node

const MOUNTAIN_REPEAT_WIDTH: float = 1088.0

@export_range(0.0, 1.0, 0.01) var mountain_parallax_factor: float = 0.04
@export var mountains_path: NodePath = ^"MountainLayer/MountainStrip"

@onready var mountains: Node2D = get_node_or_null(mountains_path) as Node2D


func _ready() -> void:
	_update_mountain_parallax()


func _process(_delta: float) -> void:
	_update_mountain_parallax()


func _update_mountain_parallax() -> void:
	if mountains == null:
		return
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return
	var camera_offset := -camera.get_screen_center_position().x * mountain_parallax_factor
	mountains.position.x = fposmod(camera_offset, MOUNTAIN_REPEAT_WIDTH)
