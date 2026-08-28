class_name PauseMenu extends CanvasLayer

signal resume_requested
signal load_slot_requested(slot: String)
signal return_to_title_requested

const ViewModel = preload("res://scripts/ui/character_social_view_model.gd")
const METRIC_BAR_SCENE: PackedScene = preload(
	"res://ui/pause/character_metric_bar.tscn"
)

const PAGE_LANDING := &"landing"
const PAGE_CHARACTERS := &"characters"
const PAGE_SAVE := &"save"
const PAGE_LOAD := &"load"
const PAGE_OPTIONS := &"options"

const FOCUS_COLOR := Color(0.721569, 0.368627, 0.262745, 1.0)
const OPTION_LABEL_COLOR := Color(0.14902, 0.192157, 0.180392, 1.0)
const FILLED_FOCUS_COLOR := Color(1.0, 0.945098, 0.823529, 1.0)
const POSITIVE_METRIC_COLOR := Color(0.54, 0.87, 0.68, 1.0)
const NEGATIVE_METRIC_COLOR := Color(0.9, 0.36, 0.3, 1.0)
const CONDITION_METRIC_COLOR := Color(0.78, 0.68, 0.42, 1.0)
const NEED_METRIC_COLOR := Color(0.93, 0.66, 0.24, 1.0)
const MOOD_METRIC_COLOR := Color(0.42, 0.67, 0.94, 1.0)

@onready var resume_button: Button = %ResumeButton
@onready var characters_button: Button = %CharactersButton
@onready var save_button: Button = %SaveButton
@onready var load_button: Button = %LoadButton
@onready var options_button: Button = %OptionsButton
@onready var title_button: Button = %TitleButton
@onready var page_title: Label = %PageTitle

@onready var landing_view: Control = %LandingView
@onready var characters_view: Control = %CharactersView
@onready var save_view: Control = %SaveView
@onready var load_view: Control = %LoadView
@onready var options_view: Control = %OptionsView

@onready var owner_list: VBoxContainer = %OwnerList
@onready var no_known_characters: Label = %NoKnownCharacters
@onready var owner_name: Label = %OwnerName
@onready var owner_subtitle: Label = %OwnerSubtitle
@onready var owner_runtime: Label = %OwnerRuntime
@onready var owner_description: Label = %OwnerDescription
@onready var portrait: TextureRect = %Portrait
@onready var portrait_placeholder: Label = %PortraitPlaceholder
@onready var previous_subject_button: Button = %PreviousSubjectButton
@onready var next_subject_button: Button = %NextSubjectButton
@onready var subject_page_label: Label = %SubjectPageLabel
@onready var direction_label: Label = %DirectionLabel
@onready var opinion_status: Label = %OpinionStatus
@onready var opinion_metrics: VBoxContainer = %OpinionMetrics
@onready var characteristic_metrics: VBoxContainer = %CharacteristicMetrics

@onready var save_slots: VBoxContainer = %SaveSlots
@onready var save_status: Label = %SaveStatus
@onready var load_slots: VBoxContainer = %LoadSlots
@onready var load_status: Label = %LoadStatus

@onready var volume_label: Label = %VolumeLabel
@onready var master_volume_slider: HSlider = %MasterVolumeSlider
@onready var master_volume_value: Label = %MasterVolumeValue
@onready var fullscreen_toggle: CheckButton = %FullscreenToggle
@onready var title_confirmation: Control = %TitleConfirmation
@onready var cancel_title_button: Button = %CancelTitleButton
@onready var confirm_title_button: Button = %ConfirmTitleButton

var current_page: StringName = PAGE_LANDING
var social_view_model := ViewModel.new()
var selected_owner_id := ""
var subject_ids: Array[String] = []
var subject_index: int = 0
var owner_buttons: Array[Button] = []
var save_slot_buttons: Array[Button] = []
var load_slot_buttons: Array[Button] = []
var _owner_button_group := ButtonGroup.new()
var _save_system: Object
var _game_settings: Object
var _syncing_options := false
var _services_overridden := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_bind_default_services()
	_connect_controls()
	_configure_static_focus_navigation()
	_configure_focus_cues()
	_show_page(PAGE_LANDING, false)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var key_event := event as InputEventKey
	if key_event != null and key_event.echo:
		return
	if title_confirmation.visible:
		var wants_to_cancel := event.is_action_pressed(&"ui_cancel")
		if InputMap.has_action(&"pause"):
			wants_to_cancel = wants_to_cancel or event.is_action_pressed(&"pause")
		if wants_to_cancel:
			_hide_title_confirmation()
			get_viewport().set_input_as_handled()
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused in owner_buttons:
		if _move_owner_focus(focused as Button, event):
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"ui_right") and _is_navigation_control(focused):
		if _focus_page_content():
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_left") and _should_return_to_navigation(focused):
		_defer_focus(_get_page_navigation_button())
		get_viewport().set_input_as_handled()


func _move_owner_focus(button: Button, event: InputEvent) -> bool:
	var index := owner_buttons.find(button)
	if index < 0:
		return false
	if event.is_action_pressed(&"ui_up"):
		_defer_focus(owner_buttons[wrapi(index - 1, 0, owner_buttons.size())])
		return true
	if event.is_action_pressed(&"ui_down"):
		_defer_focus(owner_buttons[wrapi(index + 1, 0, owner_buttons.size())])
		return true
	if event.is_action_pressed(&"ui_left"):
		_defer_focus(characters_button)
		return true
	if event.is_action_pressed(&"ui_right") and not previous_subject_button.disabled:
		_defer_focus(previous_subject_button)
		return true
	return false


func show_menu() -> void:
	_bind_default_services()
	visible = true
	title_confirmation.visible = false
	_show_page(PAGE_LANDING, false)
	_sync_options_controls()
	_defer_focus(resume_button)


func hide_menu() -> void:
	title_confirmation.visible = false
	visible = false


func is_open() -> bool:
	return visible


func show_characters_page() -> void:
	_show_page(PAGE_CHARACTERS)
	_refresh_characters()


func show_save_page() -> void:
	_show_page(PAGE_SAVE)
	_refresh_save_slots()
	_focus_first_button(save_slot_buttons, save_button)


func show_load_page() -> void:
	_show_page(PAGE_LOAD)
	_refresh_load_slots()
	_focus_first_enabled_button(load_slot_buttons, load_button)


func show_options_page() -> void:
	_show_page(PAGE_OPTIONS)
	_sync_options_controls()
	_defer_focus(master_volume_slider)


func set_services_for_testing(
	relationships: Object,
	locations: Object,
	save_system: Object = null,
	game_settings: Object = null
) -> void:
	_services_overridden = true
	social_view_model.configure(relationships, locations)
	_save_system = save_system
	_game_settings = game_settings


func get_known_owner_ids() -> Array[String]:
	return social_view_model.get_known_owner_ids()


func get_subject_ids() -> Array[String]:
	return subject_ids.duplicate()


func get_selected_owner_id() -> String:
	return selected_owner_id


func get_selected_subject_id() -> String:
	if subject_ids.is_empty() or subject_index < 0 or subject_index >= subject_ids.size():
		return ""
	return subject_ids[subject_index]


func get_direction_text() -> String:
	return direction_label.text if direction_label != null else ""


func get_opinion_status_text() -> String:
	return opinion_status.text if opinion_status != null else ""


func get_save_slot_button_count() -> int:
	return save_slot_buttons.size()


func get_load_slot_button_count() -> int:
	return load_slot_buttons.size()


func get_current_page() -> StringName:
	return current_page


func select_owner(owner_id: String) -> void:
	if not social_view_model.get_known_owner_ids().has(owner_id):
		return
	selected_owner_id = owner_id
	subject_ids = social_view_model.get_subject_ids(selected_owner_id)
	subject_index = 0
	_update_owner_button_states()
	_refresh_character_detail()


func browse_subject(offset: int) -> void:
	if subject_ids.size() <= 1 or offset == 0:
		return
	subject_index = wrapi(subject_index + offset, 0, subject_ids.size())
	_refresh_character_detail()


func _bind_default_services() -> void:
	if _services_overridden:
		return
	var relationships := get_node_or_null("/root/Relationships")
	var locations := get_node_or_null("/root/NpcLocations")
	social_view_model.configure(relationships, locations)
	_save_system = get_node_or_null("/root/SaveSystem")
	_game_settings = get_node_or_null("/root/GameSettings")


func _connect_controls() -> void:
	resume_button.pressed.connect(func() -> void: resume_requested.emit())
	characters_button.pressed.connect(show_characters_page)
	save_button.pressed.connect(show_save_page)
	load_button.pressed.connect(show_load_page)
	options_button.pressed.connect(show_options_page)
	title_button.pressed.connect(_show_title_confirmation)
	cancel_title_button.pressed.connect(_hide_title_confirmation)
	confirm_title_button.pressed.connect(_confirm_return_to_title)
	previous_subject_button.pressed.connect(browse_subject.bind(-1))
	next_subject_button.pressed.connect(browse_subject.bind(1))
	master_volume_slider.value_changed.connect(_on_master_volume_changed)
	fullscreen_toggle.toggled.connect(_on_fullscreen_toggled)


func _show_page(page: StringName, focus_navigation: bool = true) -> void:
	current_page = page
	landing_view.visible = page == PAGE_LANDING
	characters_view.visible = page == PAGE_CHARACTERS
	save_view.visible = page == PAGE_SAVE
	load_view.visible = page == PAGE_LOAD
	options_view.visible = page == PAGE_OPTIONS
	match page:
		PAGE_CHARACTERS:
			page_title.text = "Characters"
		PAGE_SAVE:
			page_title.text = "Save"
		PAGE_LOAD:
			page_title.text = "Load"
		PAGE_OPTIONS:
			page_title.text = "Options"
		_:
			page_title.text = "Pause Menu"
	if focus_navigation:
		_focus_page_navigation(page)


func _show_title_confirmation() -> void:
	title_confirmation.visible = true
	_defer_focus(cancel_title_button)


func _hide_title_confirmation() -> void:
	title_confirmation.visible = false
	_defer_focus(title_button)


func _confirm_return_to_title() -> void:
	title_confirmation.visible = false
	return_to_title_requested.emit()


func _focus_page_navigation(page: StringName) -> void:
	match page:
		PAGE_CHARACTERS:
			_defer_focus(characters_button)
		PAGE_SAVE:
			_defer_focus(save_button)
		PAGE_LOAD:
			_defer_focus(load_button)
		PAGE_OPTIONS:
			_defer_focus(options_button)
		_:
			_defer_focus(resume_button)


func _refresh_characters() -> void:
	social_view_model.refresh()
	var known_ids := social_view_model.get_known_owner_ids()
	_clear_container(owner_list)
	owner_buttons.clear()
	_owner_button_group = ButtonGroup.new()
	for owner_id in known_ids:
		var profile := social_view_model.get_actor_profile(owner_id)
		var button := Button.new()
		button.name = "Character_%s" % _safe_node_name(owner_id)
		button.text = String(profile.get("display_name", owner_id))
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.toggle_mode = true
		button.button_group = _owner_button_group
		button.tooltip_text = "View this character's opinions"
		button.set_meta("actor_id", owner_id)
		button.pressed.connect(select_owner.bind(owner_id))
		owner_list.add_child(button)
		owner_buttons.append(button)
	_configure_owner_focus_navigation()

	no_known_characters.visible = known_ids.is_empty()
	if known_ids.is_empty():
		selected_owner_id = ""
		subject_ids.clear()
		subject_index = 0
		_show_empty_character_state()
		return
	if not known_ids.has(selected_owner_id):
		selected_owner_id = known_ids[0]
	select_owner(selected_owner_id)
	_defer_focus(owner_buttons[known_ids.find(selected_owner_id)])


func _show_empty_character_state() -> void:
	owner_name.text = "NO KNOWN CHARACTERS"
	owner_subtitle.text = ""
	owner_runtime.text = ""
	owner_description.text = "Meet someone before their character page becomes available."
	portrait.texture = null
	portrait_placeholder.visible = true
	direction_label.text = "OWNER  →  SUBJECT"
	opinion_status.text = "No opinion recorded"
	subject_page_label.text = "0 / 0"
	previous_subject_button.disabled = true
	next_subject_button.disabled = true
	_clear_container(opinion_metrics)
	_clear_container(characteristic_metrics)


func _refresh_character_detail() -> void:
	if selected_owner_id.is_empty() or subject_ids.is_empty():
		_show_empty_character_state()
		return
	var owner_profile := social_view_model.get_actor_profile(selected_owner_id)
	owner_name.text = String(owner_profile.get("display_name", selected_owner_id)).to_upper()
	owner_subtitle.text = String(owner_profile.get("subtitle", "Known character"))
	owner_description.text = String(owner_profile.get(
		"description", "No profile notes yet."
	))
	if owner_description.text.is_empty():
		owner_description.text = "No profile notes yet."
	_apply_portrait(owner_profile)
	_apply_runtime_summary(social_view_model.get_owner_runtime_summary(selected_owner_id))

	var subject_id := get_selected_subject_id()
	var opinion := social_view_model.get_opinion(selected_owner_id, subject_id)
	direction_label.text = String(opinion.get("direction", "OWNER  →  SUBJECT"))
	subject_page_label.text = "%d / %d" % [subject_index + 1, subject_ids.size()]
	previous_subject_button.disabled = subject_ids.size() <= 1
	next_subject_button.disabled = subject_ids.size() <= 1
	_refresh_opinion_metrics(opinion, owner_profile)
	_refresh_characteristic_metrics(
		social_view_model.get_owner_characteristics(selected_owner_id)
	)


func _apply_portrait(profile: Dictionary) -> void:
	portrait.texture = null
	var portrait_path := String(profile.get("portrait_path", "")).strip_edges()
	if not portrait_path.is_empty() and ResourceLoader.exists(portrait_path, "Texture2D"):
		portrait.texture = load(portrait_path) as Texture2D
	portrait_placeholder.visible = portrait.texture == null
	var accent = profile.get("accent_color", POSITIVE_METRIC_COLOR)
	portrait_placeholder.add_theme_color_override(
		"font_color", accent if accent is Color else POSITIVE_METRIC_COLOR
	)


func _apply_runtime_summary(summary: Dictionary) -> void:
	if summary.is_empty():
		owner_runtime.text = "Location unknown"
		return
	var parts: Array[String] = ["LIVE" if bool(summary.get("live", false)) else "OFFSCREEN"]
	var state_name := String(summary.get("state_name", "")).strip_edges()
	var scene_name := String(summary.get("scene_name", "")).strip_edges()
	if not state_name.is_empty():
		parts.append(state_name)
	if not scene_name.is_empty():
		parts.append(scene_name)
	owner_runtime.text = " | ".join(PackedStringArray(parts))


func _refresh_opinion_metrics(opinion: Dictionary, owner_profile: Dictionary) -> void:
	_clear_container(opinion_metrics)
	if not bool(opinion.get("recorded", false)):
		opinion_status.text = "No opinion recorded"
		opinion_status.visible = true
		return
	var metrics = opinion.get("metrics", [])
	if not (metrics is Array) or metrics.is_empty():
		opinion_status.text = "Opinion recorded; no metrics available"
		opinion_status.visible = true
		return
	opinion_status.text = "Recorded opinion"
	opinion_status.visible = true
	var accent = owner_profile.get("accent_color", POSITIVE_METRIC_COLOR)
	var positive_color: Color = accent if accent is Color else POSITIVE_METRIC_COLOR
	for metric in metrics:
		if not (metric is Dictionary):
			continue
		var polarity := int(metric.get("polarity", 0))
		_add_metric_bar(
			opinion_metrics,
			metric,
			NEGATIVE_METRIC_COLOR if polarity < 0 else positive_color
		)


func _refresh_characteristic_metrics(metrics: Array[Dictionary]) -> void:
	_clear_container(characteristic_metrics)
	if metrics.is_empty():
		var empty := Label.new()
		empty.text = "No characteristic snapshot available."
		empty.theme_type_variation = &"MutedLabel"
		characteristic_metrics.add_child(empty)
		return
	for metric in metrics:
		var section := String(metric.get("section", ""))
		var color := CONDITION_METRIC_COLOR
		if section == "needs":
			color = NEED_METRIC_COLOR
		elif section == "mood":
			color = MOOD_METRIC_COLOR
		_add_metric_bar(characteristic_metrics, metric, color)


func _add_metric_bar(parent: VBoxContainer, metric: Dictionary, color: Color) -> void:
	var row := METRIC_BAR_SCENE.instantiate() as CharacterMetricBar
	if row == null:
		return
	parent.add_child(row)
	row.configure(metric, color)


func _update_owner_button_states() -> void:
	for button in owner_buttons:
		button.button_pressed = String(button.get_meta("actor_id", "")) == selected_owner_id


func _refresh_save_slots() -> void:
	_clear_container(save_slots)
	save_slot_buttons.clear()
	save_status.text = ""
	if _save_system == null:
		save_status.text = "Save system unavailable."
		return
	var slots := _get_save_slots()
	var summaries := _get_save_summaries()
	for index in slots.size():
		var slot := slots[index]
		var summary: Dictionary = summaries[index] if index < summaries.size() else {}
		var button := Button.new()
		button.name = "Save_%s" % _safe_node_name(slot)
		button.custom_minimum_size = Vector2(0, 48)
		button.text = _format_save_summary(summary, "Empty - select to save")
		button.pressed.connect(_on_save_slot_pressed.bind(slot))
		save_slots.add_child(button)
		save_slot_buttons.append(button)
	_configure_vertical_button_navigation(save_slot_buttons, save_button)


func _refresh_load_slots() -> void:
	_clear_container(load_slots)
	load_slot_buttons.clear()
	load_status.text = ""
	if _save_system == null:
		load_status.text = "Save system unavailable."
		return
	var slots := _get_save_slots()
	var summaries := _get_save_summaries()
	for index in slots.size():
		var slot := slots[index]
		var summary: Dictionary = summaries[index] if index < summaries.size() else {}
		var button := Button.new()
		button.name = "Load_%s" % _safe_node_name(slot)
		button.custom_minimum_size = Vector2(0, 48)
		button.text = _format_save_summary(summary, "Empty")
		button.disabled = not (
			bool(summary.get("exists", false))
			and bool(summary.get("valid", false))
		)
		button.pressed.connect(_on_load_slot_pressed.bind(slot))
		load_slots.add_child(button)
		load_slot_buttons.append(button)
	_configure_vertical_button_navigation(load_slot_buttons, load_button)


func _on_save_slot_pressed(slot: String) -> void:
	if _save_system == null or not _save_system.has_method("save_game"):
		save_status.text = "Save system unavailable."
		return
	var success := bool(_save_system.call("save_game", slot))
	var status_text := "Game saved." if success else "Save failed."
	_refresh_save_slots()
	_refresh_load_slots()
	save_status.text = status_text


func _on_load_slot_pressed(slot: String) -> void:
	load_slot_requested.emit(slot)


func _get_save_slots() -> Array[String]:
	var result: Array[String] = []
	if _save_system == null or not _save_system.has_method("get_save_slots"):
		return result
	var slots = _save_system.call("get_save_slots")
	if slots is Array or slots is PackedStringArray:
		for slot in slots:
			result.append(String(slot))
	return result


func _get_save_summaries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _save_system == null or not _save_system.has_method("get_save_summaries"):
		return result
	var summaries = _save_system.call("get_save_summaries")
	if summaries is Array:
		for summary in summaries:
			result.append(summary.duplicate(true) if summary is Dictionary else {})
	return result


func _format_save_summary(summary: Dictionary, empty_label: String) -> String:
	if _save_system != null and _save_system.has_method("format_save_summary"):
		return String(_save_system.call("format_save_summary", summary, empty_label))
	return String(summary.get("display_name", "Save File")) + " - " + empty_label


func _sync_options_controls() -> void:
	_syncing_options = true
	if _game_settings != null:
		if _game_settings.has_method("get_master_volume"):
			master_volume_slider.value = float(
				_game_settings.call("get_master_volume")
			) * 100.0
		if _game_settings.has_method("is_fullscreen"):
			fullscreen_toggle.button_pressed = bool(
				_game_settings.call("is_fullscreen")
			)
	master_volume_value.text = "%d%%" % roundi(master_volume_slider.value)
	_syncing_options = false


func _on_master_volume_changed(value: float) -> void:
	master_volume_value.text = "%d%%" % roundi(value)
	if (
		not _syncing_options
		and _game_settings != null
		and _game_settings.has_method("set_master_volume")
	):
		_game_settings.call("set_master_volume", value / 100.0)


func _on_fullscreen_toggled(enabled: bool) -> void:
	if (
		not _syncing_options
		and _game_settings != null
		and _game_settings.has_method("set_fullscreen")
	):
		_game_settings.call("set_fullscreen", enabled)


func _focus_first_button(buttons: Array[Button], fallback: Button) -> void:
	if not buttons.is_empty():
		_defer_focus(buttons[0])
	elif fallback != null:
		_defer_focus(fallback)


func _focus_first_enabled_button(buttons: Array[Button], fallback: Button) -> void:
	for button in buttons:
		if not button.disabled:
			_defer_focus(button)
			return
	if fallback != null:
		_defer_focus(fallback)


func _configure_static_focus_navigation() -> void:
	previous_subject_button.focus_neighbor_right = previous_subject_button.get_path_to(
		next_subject_button
	)
	next_subject_button.focus_neighbor_left = next_subject_button.get_path_to(
		previous_subject_button
	)
	master_volume_slider.focus_neighbor_top = master_volume_slider.get_path_to(options_button)
	master_volume_slider.focus_neighbor_bottom = master_volume_slider.get_path_to(fullscreen_toggle)
	fullscreen_toggle.focus_neighbor_top = fullscreen_toggle.get_path_to(master_volume_slider)
	fullscreen_toggle.focus_neighbor_left = fullscreen_toggle.get_path_to(options_button)
	fullscreen_toggle.focus_neighbor_bottom = fullscreen_toggle.get_path_to(options_button)


func _configure_focus_cues() -> void:
	for button in [
		resume_button,
		characters_button,
		save_button,
		load_button,
		options_button,
		title_button,
		fullscreen_toggle,
		cancel_title_button,
		confirm_title_button,
	]:
		_register_focus_button(button)
	master_volume_slider.focus_entered.connect(_on_volume_focus_entered)
	master_volume_slider.focus_exited.connect(_on_volume_focus_exited)


func _register_focus_button(button: Button) -> void:
	if button == null or button.has_meta("focus_cue_registered"):
		return
	button.set_meta("focus_cue_registered", true)
	var cue := Label.new()
	cue.name = "FocusCue"
	cue.text = "›"
	cue.visible = false
	cue.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cue.z_index = 1
	cue.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	cue.offset_left = 7.0
	cue.offset_right = 21.0
	cue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cue.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cue.add_theme_color_override(
		"font_color",
		FOCUS_COLOR if button is CheckButton else FILLED_FOCUS_COLOR
	)
	button.add_child(cue)
	button.set_meta("focus_cue_label", cue)
	button.focus_entered.connect(_on_focus_button_entered.bind(button))
	button.focus_exited.connect(_on_focus_button_exited.bind(button))


func _on_focus_button_entered(button: Button) -> void:
	var cue := button.get_meta("focus_cue_label") as Label
	if cue != null:
		cue.visible = true


func _on_focus_button_exited(button: Button) -> void:
	var cue := button.get_meta("focus_cue_label") as Label
	if cue != null:
		cue.visible = false


func _on_volume_focus_entered() -> void:
	volume_label.text = "▶  MASTER VOLUME"
	volume_label.add_theme_color_override("font_color", FOCUS_COLOR)


func _on_volume_focus_exited() -> void:
	volume_label.text = "MASTER VOLUME"
	volume_label.add_theme_color_override("font_color", OPTION_LABEL_COLOR)


func _configure_owner_focus_navigation() -> void:
	if owner_buttons.is_empty():
		return
	for index in owner_buttons.size():
		var button := owner_buttons[index]
		var previous := owner_buttons[wrapi(index - 1, 0, owner_buttons.size())]
		var next := owner_buttons[wrapi(index + 1, 0, owner_buttons.size())]
		button.focus_neighbor_top = button.get_path_to(previous)
		button.focus_neighbor_bottom = button.get_path_to(next)
		button.focus_neighbor_left = button.get_path_to(characters_button)
		button.focus_neighbor_right = button.get_path_to(previous_subject_button)
	previous_subject_button.focus_neighbor_left = previous_subject_button.get_path_to(
		owner_buttons[0]
	)


func _configure_vertical_button_navigation(buttons: Array[Button], nav_button: Button) -> void:
	for index in buttons.size():
		var button := buttons[index]
		var previous: Control = nav_button if index == 0 else buttons[index - 1]
		var next: Control = nav_button if index == buttons.size() - 1 else buttons[index + 1]
		button.focus_neighbor_top = button.get_path_to(previous)
		button.focus_neighbor_bottom = button.get_path_to(next)
		button.focus_neighbor_left = button.get_path_to(nav_button)


func _focus_page_content() -> bool:
	match current_page:
		PAGE_CHARACTERS:
			if not owner_buttons.is_empty():
				_defer_focus(owner_buttons[0])
				return true
		PAGE_SAVE:
			if not save_slot_buttons.is_empty():
				_defer_focus(save_slot_buttons[0])
				return true
		PAGE_LOAD:
			for button in load_slot_buttons:
				if not button.disabled:
					_defer_focus(button)
					return true
		PAGE_OPTIONS:
			_defer_focus(master_volume_slider)
			return true
	return false


func _get_page_navigation_button() -> Button:
	match current_page:
		PAGE_CHARACTERS:
			return characters_button
		PAGE_SAVE:
			return save_button
		PAGE_LOAD:
			return load_button
		PAGE_OPTIONS:
			return options_button
		_:
			return resume_button


func _is_navigation_control(control: Control) -> bool:
	return control in [
		resume_button,
		characters_button,
		save_button,
		load_button,
		options_button,
		title_button,
	]


func _should_return_to_navigation(control: Control) -> bool:
	return (
		control in owner_buttons
		or control in save_slot_buttons
		or control in load_slot_buttons
		or control == fullscreen_toggle
	)


func _defer_focus(control: Control) -> void:
	if control == null:
		return
	call_deferred("_grab_focus_if_valid", weakref(control))


func _grab_focus_if_valid(control_ref: WeakRef) -> void:
	if control_ref == null:
		return
	var control := control_ref.get_ref() as Control
	if (
		control != null
		and is_instance_valid(control)
		and control.is_inside_tree()
		and control.visible
		and control.focus_mode != Control.FOCUS_NONE
	):
		control.grab_focus()


func _clear_container(container: Node) -> void:
	if container == null:
		return
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _safe_node_name(value: String) -> String:
	return value.validate_node_name().replace(" ", "_")
