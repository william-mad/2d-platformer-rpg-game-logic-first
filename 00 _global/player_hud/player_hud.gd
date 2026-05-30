extends CanvasLayer

@onready var hpbar: TextureProgressBar = $"Control/hp margin cont/NinePatchRect/hpbar"
@onready var mana_bar: TextureProgressBar = $"Control/mana margin cont/mana_2/mana"
@onready var mana_2_bar: TextureProgressBar = $"Control/mana margin cont/mana_2"


func setup_hp(max_hp: float, current_hp: float) -> void:
	hpbar.max_value = max_hp
	set_hp(current_hp)


func set_hp(current_hp: float) -> void:
	hpbar.value = clampf(current_hp, 0.0, hpbar.max_value)


func setup_mana(max_mana: float, current_mana: float, current_mana_2: float) -> void:
	mana_bar.max_value = max_mana
	mana_2_bar.max_value = max_mana
	set_mana(current_mana)
	set_mana_2(current_mana_2)


func set_mana(current_mana: float) -> void:
	mana_bar.value = clampf(current_mana, 0.0, mana_bar.max_value)


func set_mana_2(current_mana_2: float) -> void:
	mana_2_bar.value = clampf(current_mana_2, 0.0, mana_2_bar.max_value)
