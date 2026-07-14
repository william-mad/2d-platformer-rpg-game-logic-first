extends CanvasLayer

@onready var hpbar: TextureProgressBar = $"Control/hp margin cont/NinePatchRect/hpbar"
@onready var mana_bar: TextureProgressBar = $"Control/mana margin cont/mana_2/mana"
@onready var mana_2_bar: TextureProgressBar = $"Control/mana margin cont/mana_2"
@onready var control_root: Control = $Control
@onready var knockout_icon: TextureRect = $Control/KnockoutIcon
@onready var inventory_screen: PlayerInventoryScreen = $PlayerInventoryScreen
@onready var trade_screen: TradeScreen = $TradeScreen

const INVENTORY_ACTION: StringName = &"inventory"

const LEVEL_LABEL_SIZE := Vector2(48.0, 18.0)
const LEVEL_LABEL_POSITION := Vector2(304.0, 7.0)
const LEVEL_XP_BAR_HEIGHT := 3.0
const NEED_BAR_X := 336.0
const NEED_BAR_SIZE := Vector2(118.0, 6.0)
const NEED_ROW_GAP := 21.0
const KNOCKOUT_BAR_X := 54.0
const KNOCKOUT_BAR_Y := 98.0
const KNOCKOUT_BAR_SIZE := Vector2(218.0, 6.0)
const MANA_ATTACK_NORMAL_COLOR := Color(0.28, 0.62, 1.0, 1.0)
const MANA_ATTACK_SPECIAL_1_COLOR := Color(0.14, 0.92, 0.72, 1.0)
const MANA_ATTACK_SPECIAL_2_COLOR := Color(1.0, 0.72, 0.18, 1.0)
const MANA_ATTACK_SPECIAL_3_COLOR := Color(1.0, 0.22, 0.58, 1.0)

var hunger_bar: TextureProgressBar
var sleep_need_bar: TextureProgressBar
var knockout_bar: TextureProgressBar
var level_label: Label
var level_xp_back: ColorRect
var level_xp_fill: ColorRect
var current_mana_attack_tier := -1
var inventory_previous_pause_state: bool = false
var bound_player_inventory: InventoryModel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_unhandled_input(true)
	_ensure_progression_widgets()
	_connect_progression_system()
	_refresh_progression_widgets()
	_update_mana_attack_color(mana_bar.value)
	trade_screen.close_requested.connect(close_trade_screen)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(INVENTORY_ACTION):
		return
	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
		return
	if _is_game_over_active():
		return
	if inventory_screen.is_open():
		get_viewport().set_input_as_handled()
		close_inventory()
		return
	if trade_screen.is_open():
		return
	# A pre-existing pause belongs to another modal owner.
	if get_tree().paused or not inventory_screen.has_bound_inventory():
		return
	get_viewport().set_input_as_handled()
	open_inventory()


func bind_player_inventory(inventory: InventoryModel, player_owner: Node2D = null) -> void:
	bound_player_inventory = inventory
	inventory_screen.bind_inventory(inventory, player_owner)


func unbind_player_inventory(inventory: InventoryModel) -> void:
	if not inventory_screen.is_bound_to(inventory):
		return
	if inventory_screen.is_open():
		close_inventory()
	if trade_screen.is_open():
		close_trade_screen()
	inventory_screen.unbind_inventory(inventory)
	bound_player_inventory = null


func open_inventory() -> void:
	if get_tree().paused or inventory_screen.is_open() or not inventory_screen.has_bound_inventory():
		return
	inventory_previous_pause_state = get_tree().paused
	inventory_screen.open_screen()
	_set_inventory_pause(true)


func close_inventory() -> void:
	if not inventory_screen.is_open():
		return
	inventory_screen.close_screen()
	_set_inventory_pause(inventory_previous_pause_state)


func open_trade_screen(merchant: MerchantComponent) -> bool:
	if get_tree().paused or trade_screen.is_open() or inventory_screen.is_open() or bound_player_inventory == null:
		return false
	inventory_previous_pause_state = get_tree().paused
	if not trade_screen.open_screen(bound_player_inventory, merchant):
		merchant.clear_trade_player()
		return false
	_set_inventory_pause(true)
	return true


func close_trade_screen() -> void:
	if not trade_screen.is_open():
		return
	trade_screen.close_screen()
	_set_inventory_pause(inventory_previous_pause_state)


func _set_inventory_pause(should_pause: bool) -> void:
	var pause_system := get_node_or_null("/root/PauseSystem")
	if pause_system != null and pause_system.has_method("set_paused"):
		pause_system.call("set_paused", should_pause, false)
	else:
		get_tree().paused = should_pause


func _is_game_over_active() -> bool:
	var game_over_screen := get_node_or_null("/root/GameOverScreen")
	return (
		game_over_screen != null
		and game_over_screen.has_method("is_game_over_active")
		and bool(game_over_screen.call("is_game_over_active"))
	)


func setup_hp(max_hp: float, current_hp: float) -> void:
	hpbar.max_value = max_hp
	set_hp(current_hp)


func set_hp(current_hp: float) -> void:
	var next_value := clampf(current_hp, 0.0, hpbar.max_value)
	if is_equal_approx(hpbar.value, next_value):
		return

	hpbar.value = next_value


func setup_knockout(
	max_knockout: float,
	current_knockout: float,
	active: bool = false,
	downed: bool = false
) -> void:
	_ensure_knockout_bar()
	knockout_bar.max_value = maxf(max_knockout, 1.0)
	set_knockout(current_knockout, active, downed)


func set_knockout(current_knockout: float, active: bool = true, downed: bool = false) -> void:
	_ensure_knockout_bar()
	knockout_bar.value = clampf(current_knockout, 0.0, knockout_bar.max_value)
	knockout_bar.visible = active and knockout_bar.value > 0.0
	knockout_icon.visible = downed


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

	var top_offset := 39.0
	hunger_bar = _create_need_bar(
		"HungerNeedBar",
		top_offset,
		Color(1.0, 0.57, 0.16, 1.0)
	)
	sleep_need_bar = _create_need_bar(
		"SleepNeedBar",
		top_offset + NEED_ROW_GAP,
		Color(0.42, 0.55, 1.0, 1.0)
	)


func _create_need_bar(
	bar_name: String,
	y_offset: float,
	fill_color: Color
) -> TextureProgressBar:
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


func _ensure_knockout_bar() -> void:
	if knockout_bar != null and is_instance_valid(knockout_bar):
		return

	knockout_bar = TextureProgressBar.new()
	knockout_bar.name = "KnockoutBar"
	knockout_bar.position = Vector2(KNOCKOUT_BAR_X, KNOCKOUT_BAR_Y)
	knockout_bar.size = KNOCKOUT_BAR_SIZE
	knockout_bar.custom_minimum_size = KNOCKOUT_BAR_SIZE
	knockout_bar.max_value = 100.0
	knockout_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	knockout_bar.rounded = true
	knockout_bar.texture_under = _make_status_texture(
		KNOCKOUT_BAR_SIZE,
		Color(0.015, 0.014, 0.018, 0.86),
		Color(0.08, 0.075, 0.09, 0.86)
	)
	knockout_bar.texture_progress = _make_status_texture(
		KNOCKOUT_BAR_SIZE,
		Color(1.0, 0.48, 0.14, 1.0),
		Color(1.0, 0.91, 0.24, 1.0)
	)
	knockout_bar.visible = false
	control_root.add_child(knockout_bar)


func _make_need_texture(left_color: Color, right_color: Color) -> GradientTexture2D:
	return _make_status_texture(NEED_BAR_SIZE, left_color, right_color)


func _make_status_texture(size: Vector2, left_color: Color, right_color: Color) -> GradientTexture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	gradient.colors = PackedColorArray([left_color, right_color])

	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = int(size.x)
	texture.height = int(size.y)
	texture.fill_from = Vector2(0.0, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	return texture


func _ensure_progression_widgets() -> void:
	if level_label != null and is_instance_valid(level_label):
		return

	level_label = Label.new()
	level_label.name = "LevelLabel"
	level_label.position = LEVEL_LABEL_POSITION
	level_label.size = LEVEL_LABEL_SIZE
	level_label.text = "Lv 1"
	level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	level_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level_label.add_theme_font_size_override("font_size", 12)
	level_label.add_theme_color_override("font_color", Color(0.92, 0.78, 1.0, 1.0))
	level_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	level_label.add_theme_constant_override("shadow_offset_x", 1)
	level_label.add_theme_constant_override("shadow_offset_y", 1)
	control_root.add_child(level_label)

	level_xp_back = ColorRect.new()
	level_xp_back.name = "LevelXPBarBack"
	level_xp_back.anchor_right = 1.0
	level_xp_back.anchor_top = 1.0
	level_xp_back.anchor_bottom = 1.0
	level_xp_back.offset_left = -control_root.offset_left
	level_xp_back.offset_top = -LEVEL_XP_BAR_HEIGHT - control_root.offset_bottom
	level_xp_back.offset_right = -control_root.offset_right
	level_xp_back.offset_bottom = -control_root.offset_bottom
	level_xp_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	level_xp_back.color = Color(0.08, 0.02, 0.12, 0.82)
	control_root.add_child(level_xp_back)

	level_xp_fill = ColorRect.new()
	level_xp_fill.name = "LevelXPBarFill"
	level_xp_fill.anchor_bottom = 1.0
	level_xp_fill.offset_bottom = 0.0
	level_xp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	level_xp_fill.color = Color(0.66, 0.18, 1.0, 0.95)
	level_xp_back.add_child(level_xp_fill)


func _connect_progression_system() -> void:
	var progression := get_node_or_null("/root/ProgressionSystem")
	if progression == null:
		return

	var xp_callback := Callable(self, "_on_progression_xp_changed")
	if progression.has_signal(&"global_xp_changed") and not progression.is_connected(&"global_xp_changed", xp_callback):
		progression.connect(&"global_xp_changed", xp_callback)

	var level_callback := Callable(self, "_on_progression_level_changed")
	if progression.has_signal(&"global_level_changed") and not progression.is_connected(&"global_level_changed", level_callback):
		progression.connect(&"global_level_changed", level_callback)


func _on_progression_xp_changed(
	_current_xp: int,
	_delta: int,
	_source_id: StringName,
	_context: Dictionary
) -> void:
	_refresh_progression_widgets()


func _on_progression_level_changed(_current_level: int, _previous_level: int) -> void:
	_refresh_progression_widgets()


func _refresh_progression_widgets() -> void:
	_ensure_progression_widgets()

	var level := 1
	var progress_ratio := 0.0
	var progression := get_node_or_null("/root/ProgressionSystem")
	if progression != null:
		level = int(progression.call("get_global_level"))
		var current_xp := int(progression.call("get_global_xp"))
		var current_level_xp := int(progression.call("get_xp_required_for_level", level))
		var next_level_xp := int(progression.call("get_xp_required_for_level", level + 1))
		if next_level_xp > current_level_xp:
			progress_ratio = clampf(
				float(current_xp - current_level_xp) / float(next_level_xp - current_level_xp),
				0.0,
				1.0
			)
		else:
			progress_ratio = 1.0

	level_label.text = "Lv %d" % level
	level_xp_fill.anchor_right = progress_ratio
	level_xp_fill.offset_right = 0.0
