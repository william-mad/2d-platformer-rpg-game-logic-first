class_name GameSettingsSystem extends Node

signal master_volume_changed(linear_value: float)
signal fullscreen_changed(enabled: bool)

const AUDIO_SECTION := "audio"
const DISPLAY_SECTION := "display"
const MASTER_VOLUME_KEY := "master_volume"
const FULLSCREEN_KEY := "fullscreen"
const SILENT_DB := -80.0

@export var settings_path: String = "user://game_settings.cfg"

var master_volume: float = 1.0
var fullscreen: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	fullscreen = _window_is_fullscreen()
	load_settings()


func load_settings() -> void:
	var config := ConfigFile.new()
	var load_error := config.load(settings_path)
	if load_error != OK and load_error != ERR_FILE_NOT_FOUND:
		push_warning("Could not read game settings: %s" % error_string(load_error))

	master_volume = clampf(
		float(config.get_value(AUDIO_SECTION, MASTER_VOLUME_KEY, master_volume)),
		0.0,
		1.0
	)
	fullscreen = bool(config.get_value(
		DISPLAY_SECTION,
		FULLSCREEN_KEY,
		fullscreen
	))
	_apply_master_volume()
	_apply_fullscreen()


func save_settings() -> bool:
	var config := ConfigFile.new()
	config.set_value(AUDIO_SECTION, MASTER_VOLUME_KEY, master_volume)
	config.set_value(DISPLAY_SECTION, FULLSCREEN_KEY, fullscreen)
	var save_error := config.save(settings_path)
	if save_error != OK:
		push_warning("Could not save game settings: %s" % error_string(save_error))
		return false
	return true


func set_master_volume(linear_value: float, persist: bool = true) -> void:
	var next_value := clampf(linear_value, 0.0, 1.0)
	if is_equal_approx(master_volume, next_value):
		if persist:
			save_settings()
		return
	master_volume = next_value
	_apply_master_volume()
	master_volume_changed.emit(master_volume)
	if persist:
		save_settings()


func get_master_volume() -> float:
	return master_volume


func set_fullscreen(enabled: bool, persist: bool = true) -> void:
	if fullscreen == enabled:
		if persist:
			save_settings()
		return
	fullscreen = enabled
	_apply_fullscreen()
	fullscreen_changed.emit(fullscreen)
	if persist:
		save_settings()


func is_fullscreen() -> bool:
	return fullscreen


func _apply_master_volume() -> void:
	var master_bus := AudioServer.get_bus_index("Master")
	if master_bus < 0:
		return
	AudioServer.set_bus_volume_db(
		master_bus,
		linear_to_db(master_volume) if master_volume > 0.0 else SILENT_DB
	)


func _apply_fullscreen() -> void:
	if DisplayServer.get_name().to_lower() == "headless":
		return
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN
		if fullscreen
		else DisplayServer.WINDOW_MODE_WINDOWED
	)


func _window_is_fullscreen() -> bool:
	if DisplayServer.get_name().to_lower() == "headless":
		return false
	var mode := DisplayServer.window_get_mode()
	return mode in [
		DisplayServer.WINDOW_MODE_FULLSCREEN,
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
	]
