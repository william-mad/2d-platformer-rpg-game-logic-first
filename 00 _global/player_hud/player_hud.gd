extends CanvasLayer

@onready var hpbar: TextureProgressBar = $"Control/hp margin cont/NinePatchRect/hpbar"
@onready var mana_bar: TextureProgressBar = $"Control/mana margin cont/mana_2/mana"
@onready var mana_2_bar: TextureProgressBar = $"Control/mana margin cont/mana_2"
@onready var control_root: Control = $Control

const NEED_LABEL_X := 482.0
const NEED_BAR_X := 535.0
const NEED_BAR_SIZE := Vector2(118.0, 6.0)
const NEED_ROW_GAP := 18.0
const MANA_ATTACK_NORMAL_COLOR := Color(0.28, 0.62, 1.0, 1.0)
const MANA_ATTACK_SPECIAL_1_COLOR := Color(0.14, 0.92, 0.72, 1.0)
const MANA_ATTACK_SPECIAL_2_COLOR := Color(1.0, 0.72, 0.18, 1.0)
const MANA_ATTACK_SPECIAL_3_COLOR := Color(1.0, 0.22, 0.58, 1.0)

var hunger_bar: TextureProgressBar
var sleep_need_bar: TextureProgressBar
var current_mana_attack_tier := -1


func _ready() -> void:
	_update_mana_attack_color(mana_bar.value)


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
	_update_mana_attack_color(mana_bar.value)


func set_mana(current_mana: float) -> void:
	var next_value := clampf(current_mana, 0.0, mana_bar.max_value)
	if is_equal_approx(mana_bar.value, next_value):
		_update_mana_attack_color(next_value)
		return

	mana_bar.value = next_value
	_update_mana_attack_color(next_value)


func set_mana_2(current_mana_2: float) -> void:
	var next_value := clampf(current_mana_2, 0.0, mana_2_bar.max_value)
	if is_equal_approx(mana_2_bar.value, next_value):
		return

	mana_2_bar.value = next_value


func _update_mana_attack_color(current_mana: float) -> void:
	var next_tier := _get_mana_attack_tier(current_mana)
	if current_mana_attack_tier == next_tier:
		return

	current_mana_attack_tier = next_tier
	mana_bar.tint_progress = _get_mana_attack_color(next_tier)


func _get_mana_attack_tier(current_mana: float) -> int:
	var max_mana := mana_bar.max_value
	if max_mana <= 0.0:
		return 0

	var one_third_mana := max_mana / 3.0
	var two_thirds_mana := one_third_mana * 2.0

	if current_mana >= max_mana:
		return 3
	if current_mana >= two_thirds_mana:
		return 2
	if current_mana >= one_third_mana:
		return 1
	return 0


func _get_mana_attack_color(tier: int) -> Color:
	match tier:
		1:
			return MANA_ATTACK_SPECIAL_1_COLOR
		2:
			return MANA_ATTACK_SPECIAL_2_COLOR
		3:
			return MANA_ATTACK_SPECIAL_3_COLOR
		_:
			return MANA_ATTACK_NORMAL_COLOR


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

	var top_offset := 10.0
	hunger_bar = _create_need_bar(
		"HungerNeedBar",
		"Hunger",
		top_offset,
		Color(1.0, 0.57, 0.16, 1.0)
	)
	sleep_need_bar = _create_need_bar(
		"SleepNeedBar",
		"Sleepy",
		top_offset + NEED_ROW_GAP,
		Color(0.42, 0.55, 1.0, 1.0)
	)


func _create_need_bar(
	bar_name: String,
	label_text: String,
	y_offset: float,
	fill_color: Color
) -> TextureProgressBar:
	var label := Label.new()
	label.name = "%sLabel" % bar_name
	label.position = Vector2(NEED_LABEL_X, y_offset - 7.0)
	label.size = Vector2(47.0, 14.0)
	label.text = label_text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 8)
	label.add_theme_color_override("font_color", fill_color.lerp(Color.WHITE, 0.36))
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	control_root.add_child(label)

	var bar := TextureProgressBar.new()
	bar.name = bar_name
	bar.position = Vector2(NEED_BAR_X, y_offset)
	bar.size = NEED_BAR_SIZE
	bar.custom_minimum_size = NEED_BAR_SIZE
	bar.max_value = 100.0
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.rounded = true
	bar.texture_under = _make_need_texture(
		Color(0.015, 0.014, 0.018, 0.86),
		Color(0.08, 0.075, 0.09, 0.86)
	)
	bar.texture_progress = _make_need_texture(
		fill_color.darkened(0.16),
		fill_color.lerp(Color.WHITE, 0.30)
	)
	control_root.add_child(bar)
	return bar


func _make_need_texture(left_color: Color, right_color: Color) -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	gradient.colors = PackedColorArray([left_color, right_color])

	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = int(NEED_BAR_SIZE.x)
	texture.height = int(NEED_BAR_SIZE.y)
	texture.fill_from = Vector2(0.0, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture
