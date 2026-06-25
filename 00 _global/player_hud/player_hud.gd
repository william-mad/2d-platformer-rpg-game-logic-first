extends CanvasLayer

@onready var hpbar: TextureProgressBar = $"Control/hp margin cont/NinePatchRect/hpbar"
@onready var mana_bar: TextureProgressBar = $"Control/mana margin cont/mana_2/mana"
@onready var mana_2_bar: TextureProgressBar = $"Control/mana margin cont/mana_2"
@onready var control_root: Control = $Control

var hunger_bar: ProgressBar
var sleep_need_bar: ProgressBar


func setup_hp(max_hp: float, current_hp: float) -> void:
	hpbar.max_value = max_hp
	set_hp(current_hp)


func set_hp(current_hp: float) -> void:
	var next_value := clampf(current_hp, 0.0, hpbar.max_value)
	if is_equal_approx(hpbar.value, next_value):
		return

	hpbar.value = next_value


func setup_mana(max_mana: float, current_mana: float, current_mana_2: float) -> void:
	mana_bar.max_value = max_mana
	mana_2_bar.max_value = max_mana
	set_mana(current_mana)
	set_mana_2(current_mana_2)


func set_mana(current_mana: float) -> void:
	var next_value := clampf(current_mana, 0.0, mana_bar.max_value)
	if is_equal_approx(mana_bar.value, next_value):
		return

	mana_bar.value = next_value


func set_mana_2(current_mana_2: float) -> void:
	var next_value := clampf(current_mana_2, 0.0, mana_2_bar.max_value)
	if is_equal_approx(mana_2_bar.value, next_value):
		return

	mana_2_bar.value = next_value


func setup_needs(max_need: float, current_hunger: float, current_sleep_need: float) -> void:
	_ensure_need_bars()
	hunger_bar.max_value = max_need
	sleep_need_bar.max_value = max_need
	set_hunger(current_hunger)
	set_sleep_need(current_sleep_need)


func set_hunger(current_hunger: float) -> void:
	_ensure_need_bars()
	hunger_bar.value = clampf(current_hunger, 0.0, hunger_bar.max_value)


func set_sleep_need(current_sleep_need: float) -> void:
	_ensure_need_bars()
	sleep_need_bar.value = clampf(current_sleep_need, 0.0, sleep_need_bar.max_value)


func _ensure_need_bars() -> void:
	if hunger_bar != null and is_instance_valid(hunger_bar):
		return

	hunger_bar = _create_need_bar("HungerNeedBar", "Hunger", 76.0, Color(0.97, 0.46, 0.16, 1.0))
	sleep_need_bar = _create_need_bar("SleepNeedBar", "Sleep", 100.0, Color(0.25, 0.55, 1.0, 1.0))


func _create_need_bar(
	bar_name: String,
	label_text: String,
	y_offset: float,
	fill_color: Color
) -> ProgressBar:
	var label := Label.new()
	label.name = "%sLabel" % bar_name
	label.position = Vector2(0.0, y_offset - 1.0)
	label.size = Vector2(54.0, 18.0)
	label.text = label_text
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	control_root.add_child(label)

	var bar := ProgressBar.new()
	bar.name = bar_name
	bar.position = Vector2(56.0, y_offset)
	bar.size = Vector2(112.0, 14.0)
	bar.max_value = 100.0
	bar.show_percentage = false
	bar.add_theme_color_override("fill", fill_color)
	bar.add_theme_color_override("background", Color(0.0, 0.0, 0.0, 0.62))
	control_root.add_child(bar)
	return bar
