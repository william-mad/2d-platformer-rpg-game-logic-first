class_name UiThemeShowcase extends Control

const SKY_TEXTURE := preload(
	"res://images/backgrounds/ChatGPT Image 21 de mai. de 2026, 15_17_54.png"
)
const VILLAGE_TEXTURE := preload("res://images/backgrounds/houses bg.png")
const ALEGREYA_SC := preload("res://fonts/theme_showcase/AlegreyaSC-Bold.ttf")
const PIXELIFY_SANS := preload("res://fonts/theme_showcase/PixelifySans-Variable.ttf")
const CORMORANT_SC := preload("res://fonts/theme_showcase/CormorantSC-SemiBold.ttf")
const MEDIEVAL_SHARP := preload("res://fonts/theme_showcase/MedievalSharp.ttf")
const SILKSCREEN := preload("res://fonts/theme_showcase/Silkscreen-Regular.ttf")

const PRESETS: Array[Dictionary] = [
	{
		"name": "SUNLIT VILLAGE",
		"mood": "warm • nostalgic • storybook",
		"note": "A bright, human-scale fantasy UI",
		"title_font": ALEGREYA_SC,
		"ui_font": PIXELIFY_SANS,
		"small_font": PIXELIFY_SANS,
		"panel": "#EAD9AD",
		"surface": "#DCCB9E",
		"text": "#26312E",
		"muted": "#5A655E",
		"primary": "#C56A4A",
		"accent": "#668060",
		"selected_bg": "#B85E43",
		"selected_text": "#FFF1D2",
		"border": "#806647",
		"backdrop": "#6B4D2E",
		"backdrop_alpha": 0.18,
	},
	{
		"name": "FIRST LOVE AT DUSK",
		"mood": "romantic • dreamy • evening",
		"note": "Soft drama without losing pixel clarity",
		"title_font": CORMORANT_SC,
		"ui_font": PIXELIFY_SANS,
		"small_font": PIXELIFY_SANS,
		"panel": "#252D46",
		"surface": "#313A56",
		"text": "#F2E2C9",
		"muted": "#B8B7C8",
		"primary": "#C77B8B",
		"accent": "#9286B7",
		"selected_bg": "#C77B8B",
		"selected_text": "#172033",
		"border": "#7E7096",
		"backdrop": "#172033",
		"backdrop_alpha": 0.56,
	},
	{
		"name": "FOREST FOLKTALE",
		"mood": "rustic • magical • old-world",
		"note": "A stronger folklore and village identity",
		"title_font": MEDIEVAL_SHARP,
		"ui_font": PIXELIFY_SANS,
		"small_font": SILKSCREEN,
		"panel": "#293A2D",
		"surface": "#334836",
		"text": "#E9DCB8",
		"muted": "#B2B69A",
		"primary": "#813F47",
		"accent": "#C39A4A",
		"selected_bg": "#813F47",
		"selected_text": "#F4E7C2",
		"border": "#6F8C5B",
		"backdrop": "#17251F",
		"backdrop_alpha": 0.5,
	},
	{
		"name": "COLORFUL PIXEL ADVENTURE",
		"mood": "playful • readable • game-like",
		"note": "The clearest and most energetic direction",
		"title_font": PIXELIFY_SANS,
		"ui_font": SILKSCREEN,
		"small_font": SILKSCREEN,
		"panel": "#344650",
		"surface": "#283740",
		"text": "#F0E3BE",
		"muted": "#B5C4C6",
		"primary": "#D7794E",
		"accent": "#7DB2C6",
		"selected_bg": "#D7794E",
		"selected_text": "#FFF2D0",
		"border": "#7DB2C6",
		"backdrop": "#202B36",
		"backdrop_alpha": 0.45,
	},
]

var current_index := 0

var backdrop_tint: ColorRect
var showcase_panel: PanelContainer
var inner_surface: PanelContainer
var theme_name_label: Label
var counter_label: Label
var mood_label: Label
var title_label: Label
var full_title_label: Label
var note_label: Label
var section_labels: Array[Label] = []
var muted_labels: Array[Label] = []
var title_buttons: Array[Button] = []
var navigation_buttons: Array[Button] = []
var volume_label: Label
var volume_bar: ProgressBar
var fullscreen_toggle: CheckButton
var control_action_labels: Array[Label] = []
var control_key_labels: Array[Label] = []
var palette_row: HBoxContainer
var footer_label: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_showcase()
	show_theme(current_index)


func _unhandled_input(event: InputEvent) -> void:
	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
		return
	if event.is_action_pressed(&"ui_left"):
		show_theme(current_index - 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_right"):
		show_theme(current_index + 1)
		get_viewport().set_input_as_handled()


func show_theme(index: int) -> void:
	current_index = wrapi(index, 0, PRESETS.size())
	_apply_preset(PRESETS[current_index])


func _build_showcase() -> void:
	_build_background()
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	showcase_panel = PanelContainer.new()
	showcase_panel.custom_minimum_size = Vector2(690, 0)
	center.add_child(showcase_panel)

	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 14)
	showcase_panel.add_child(margin)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 6)
	margin.add_child(page)
	_build_header(page)
	_build_title_block(page)
	page.add_child(_separator())
	_build_body(page)
	_build_palette(page)
	footer_label = _label("← / →  SWITCH THEME     •     preview only — gameplay is untouched", 12)
	footer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(footer_label)


func _build_background() -> void:
	var sky := TextureRect.new()
	sky.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sky.texture = SKY_TEXTURE
	sky.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(sky)

	var village := TextureRect.new()
	village.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	village.texture = VILLAGE_TEXTURE
	village.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	village.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	village.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(village)

	backdrop_tint = ColorRect.new()
	backdrop_tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop_tint)


func _build_header(parent: VBoxContainer) -> void:
	var header := HBoxContainer.new()
	header.custom_minimum_size = Vector2(0, 32)
	header.add_theme_constant_override("separation", 8)
	parent.add_child(header)

	var previous := Button.new()
	previous.custom_minimum_size = Vector2(90, 30)
	previous.focus_mode = Control.FOCUS_NONE
	previous.text = "◀  PREV"
	previous.pressed.connect(func() -> void: show_theme(current_index - 1))
	header.add_child(previous)
	navigation_buttons.append(previous)

	theme_name_label = _label("THEME", 17)
	theme_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	theme_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	theme_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(theme_name_label)
	section_labels.append(theme_name_label)

	counter_label = _label("1 / 4", 12)
	counter_label.custom_minimum_size = Vector2(46, 0)
	counter_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	counter_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(counter_label)
	muted_labels.append(counter_label)

	var next := Button.new()
	next.custom_minimum_size = Vector2(90, 30)
	next.focus_mode = Control.FOCUS_NONE
	next.text = "NEXT  ▶"
	next.pressed.connect(func() -> void: show_theme(current_index + 1))
	header.add_child(next)
	navigation_buttons.append(next)


func _build_title_block(parent: VBoxContainer) -> void:
	var title_block := VBoxContainer.new()
	title_block.add_theme_constant_override("separation", 0)
	parent.add_child(title_block)

	mood_label = _label("mood", 11)
	mood_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_block.add_child(mood_label)
	muted_labels.append(mood_label)

	title_label = _label("E.B.F.L.", 46)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_block.add_child(title_label)

	full_title_label = _label("EVERY BOY'S FIRST LOVE", 15)
	full_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_block.add_child(full_title_label)

	note_label = _label("Theme note", 11)
	note_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_block.add_child(note_label)
	muted_labels.append(note_label)


func _build_body(parent: VBoxContainer) -> void:
	var body := HBoxContainer.new()
	body.custom_minimum_size = Vector2(0, 196)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	parent.add_child(body)

	var menu_column := VBoxContainer.new()
	menu_column.custom_minimum_size = Vector2(278, 0)
	menu_column.add_theme_constant_override("separation", 6)
	body.add_child(menu_column)
	var menu_heading := _label("TITLE MENU", 14)
	menu_column.add_child(menu_heading)
	section_labels.append(menu_heading)
	for text in ["▶  START NEW STORY", "LOAD GAME", "OPTIONS"]:
		var button := Button.new()
		button.custom_minimum_size = Vector2(0, 38)
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = true
		button.button_pressed = title_buttons.is_empty()
		button.text = text
		menu_column.add_child(button)
		title_buttons.append(button)
	var menu_hint := _label("↑ / ↓ choose     •     Z select", 11)
	menu_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_column.add_child(menu_hint)
	muted_labels.append(menu_hint)

	inner_surface = PanelContainer.new()
	inner_surface.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(inner_surface)
	var options_margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		options_margin.add_theme_constant_override("margin_%s" % side, 10)
	inner_surface.add_child(options_margin)
	var options := VBoxContainer.new()
	options.add_theme_constant_override("separation", 4)
	options_margin.add_child(options)

	var options_heading := _label("PAUSE / OPTIONS", 14)
	options.add_child(options_heading)
	section_labels.append(options_heading)
	volume_label = _label("MASTER VOLUME                                      72%", 12)
	options.add_child(volume_label)
	volume_bar = ProgressBar.new()
	volume_bar.custom_minimum_size = Vector2(0, 20)
	volume_bar.show_percentage = false
	volume_bar.value = 72.0
	options.add_child(volume_bar)
	fullscreen_toggle = CheckButton.new()
	fullscreen_toggle.custom_minimum_size = Vector2(0, 26)
	fullscreen_toggle.focus_mode = Control.FOCUS_NONE
	fullscreen_toggle.button_pressed = true
	fullscreen_toggle.text = "FULLSCREEN"
	options.add_child(fullscreen_toggle)
	var controls_heading := _label("CONTROLS", 13)
	options.add_child(controls_heading)
	section_labels.append(controls_heading)
	var controls := GridContainer.new()
	controls.columns = 4
	controls.add_theme_constant_override("h_separation", 10)
	controls.add_theme_constant_override("v_separation", 2)
	options.add_child(controls)
	for binding in [
		["MOVE", "← / →", "JUMP", "SPACE"],
		["ATTACK", "Z", "ROPE", "X"],
		["INTERACT", "C", "INVENTORY", "I"],
		["PAUSE", "ESC", "STATS", "P"],
	]:
		for item_index in binding.size():
			var label := _label(String(binding[item_index]), 11)
			if item_index % 2 == 0:
				label.custom_minimum_size.x = 76
				control_action_labels.append(label)
			else:
				label.custom_minimum_size.x = 48
				control_key_labels.append(label)
			controls.add_child(label)


func _build_palette(parent: VBoxContainer) -> void:
	palette_row = HBoxContainer.new()
	palette_row.custom_minimum_size = Vector2(0, 28)
	palette_row.add_theme_constant_override("separation", 6)
	parent.add_child(palette_row)


func _apply_preset(preset: Dictionary) -> void:
	var title_font := preset["title_font"] as Font
	var ui_font := preset["ui_font"] as Font
	var small_font := preset["small_font"] as Font
	var panel := _color(preset, "panel")
	var surface := _color(preset, "surface")
	var text := _color(preset, "text")
	var muted := _color(preset, "muted")
	var primary := _color(preset, "primary")
	var accent := _color(preset, "accent")
	var selected_bg := _color(preset, "selected_bg")
	var selected_text := _color(preset, "selected_text")
	var border := _color(preset, "border")
	var backdrop := _color(preset, "backdrop")
	backdrop.a = float(preset["backdrop_alpha"])
	backdrop_tint.color = backdrop

	theme_name_label.text = String(preset["name"])
	counter_label.text = "%d / %d" % [current_index + 1, PRESETS.size()]
	mood_label.text = String(preset["mood"])
	note_label.text = String(preset["note"])
	showcase_panel.add_theme_stylebox_override("panel", _style(panel, border, 3, 9))
	inner_surface.add_theme_stylebox_override("panel", _style(surface, border, 1, 6))

	_apply_label(title_label, title_font, 46, primary)
	_apply_label(full_title_label, ui_font, 15, text)
	for label in section_labels:
		_apply_label(label, ui_font, label.get_theme_font_size("font_size"), accent)
	for label in muted_labels:
		_apply_label(label, small_font, label.get_theme_font_size("font_size"), muted)
	_apply_label(volume_label, ui_font, 12, text)
	for label in control_action_labels:
		_apply_label(label, small_font, 11, muted)
	for label in control_key_labels:
		_apply_label(label, small_font, 11, text)
	_apply_label(footer_label, small_font, 12, muted)

	for index in title_buttons.size():
		var button := title_buttons[index]
		_apply_button(button, ui_font, 15, text, selected_text, surface, border, selected_bg, accent)
		button.button_pressed = index == 0
	for button in navigation_buttons:
		_apply_button(button, small_font, 11, text, selected_text, surface, border, primary, accent)

	fullscreen_toggle.add_theme_font_override("font", ui_font)
	fullscreen_toggle.add_theme_font_size_override("font_size", 12)
	fullscreen_toggle.add_theme_color_override("font_color", text)
	fullscreen_toggle.add_theme_color_override("font_hover_color", accent)
	fullscreen_toggle.add_theme_color_override("font_pressed_color", primary)
	volume_bar.add_theme_stylebox_override("background", _style(panel.darkened(0.2), border, 1, 3))
	volume_bar.add_theme_stylebox_override("fill", _style(accent, accent, 0, 3))
	_rebuild_palette(preset, ui_font)


func _apply_label(label: Label, font: Font, font_size: int, color: Color) -> void:
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)


func _apply_button(
	button: Button,
	font: Font,
	font_size: int,
	normal_text: Color,
	selected_text: Color,
	normal_bg: Color,
	border: Color,
	selected_bg: Color,
	accent: Color
) -> void:
	button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", font_size)
	button.add_theme_color_override("font_color", normal_text)
	button.add_theme_color_override("font_hover_color", selected_text)
	button.add_theme_color_override("font_pressed_color", selected_text)
	button.add_theme_stylebox_override("normal", _style(normal_bg, border, 2, 4))
	button.add_theme_stylebox_override("hover", _style(selected_bg.lightened(0.08), accent, 2, 4))
	button.add_theme_stylebox_override("pressed", _style(selected_bg, accent, 2, 4))


func _rebuild_palette(preset: Dictionary, font: Font) -> void:
	for child in palette_row.get_children():
		child.queue_free()
	for swatch in [
		["PANEL", "panel"],
		["SURFACE", "surface"],
		["PRIMARY", "primary"],
		["ACCENT", "accent"],
		["SELECT", "selected_bg"],
	]:
		var color := _color(preset, String(swatch[1]))
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(108, 28)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.add_theme_stylebox_override("panel", _style(color, color.lightened(0.18), 1, 3))
		palette_row.add_child(panel)
		var label := _label(String(swatch[0]), 10)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_apply_label(
			label,
			font,
			10,
			Color("#F8F3E8") if color.get_luminance() < 0.45 else Color("#1B2020")
		)
		panel.add_child(label)


func _label(text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	return label


func _separator() -> HSeparator:
	var separator := HSeparator.new()
	separator.custom_minimum_size.y = 2
	return separator


func _style(
	background: Color,
	border: Color,
	border_width: int,
	radius: int
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_right = radius
	style.corner_radius_bottom_left = radius
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	return style


func _color(preset: Dictionary, key: String) -> Color:
	return Color.from_string(String(preset[key]), Color.WHITE)
