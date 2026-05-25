extends CanvasLayer

@onready var hpbar: TextureProgressBar = $"Control/hp margin cont/NinePatchRect/hpbar"


func setup_hp(max_hp: float, current_hp: float) -> void:
	hpbar.max_value = max_hp
	set_hp(current_hp)


func set_hp(current_hp: float) -> void:
	hpbar.value = clampf(current_hp, 0.0, hpbar.max_value)
