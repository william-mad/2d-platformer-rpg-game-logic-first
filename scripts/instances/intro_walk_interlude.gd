class_name IntroWalkInterlude
extends Node2D

signal door_sequence_started
signal headlights_started
signal montage_started
signal exit_requested(next_scene_path: String, target_spawn_id: StringName)

const INTERLUDE_LOCK_REASON := &"intro_walk_interlude"
const GRAYSCALE_SHADER := preload("res://scripts/instances/intro_player_grayscale.gdshader")
const FINAL_MEMORY_ZOOM_SHADER := preload(
	"res://scripts/instances/intro_final_memory_zoom.gdshader"
)
const MEMORY_IMAGES: Array[Texture2D] = [
	preload("res://images/backgrounds/intro/fullscreen ilustration 3 (1).png"),
	preload("res://images/backgrounds/intro/fullscreen ilustration 3 (2).png"),
	preload("res://images/backgrounds/intro/fullscreen ilustration 3 (3).png"),
	preload("res://images/backgrounds/intro/fullscreen ilustration 3 (8).png"),
]
const MEMORY_IMAGE_FIRST_BEATS: Array[int] = [1, 10, 19, 28]
const BIRDS_FADE_IN_IMAGE_INDEX := 2

enum Phase {
	WALKING,
	SCRIPTED_APPROACH,
	HEADLIGHTS,
	IMPACT_ILLUSTRATION,
	BLACK_HUM,
	MONTAGE,
	EXIT,
}

@export_file("*.tscn") var next_scene_path: String = "res://scenes/testscenes/realhometest.tscn"
@export var target_spawn_id: StringName = &"intro_bed"

@export_category("Walking")
@export_range(30.0, 180.0, 5.0, "suffix:px/s") var slow_walk_speed: float = 90.0
@export_range(0.0, 4000.0, 1.0, "suffix:px") var camera_min_x: float = 377.0
@export_range(0.0, 4000.0, 1.0, "suffix:px") var camera_max_x: float = 3223.0
@export_range(0.0, 1000.0, 1.0, "suffix:px") var camera_y: float = 248.0

@export_category("Door Sequence")
@export_range(0.1, 10.0, 0.1, "suffix:s") var city_crossfade_seconds: float = 4.5
@export_range(0.1, 8.0, 0.1, "suffix:s") var door_close_delay_seconds: float = 1.2
@export_range(-80.0, -20.0, 1.0, "suffix:dB") var silent_volume_db: float = -60.0

@export_category("Headlight Event")
@export_range(10.0, 160.0, 5.0, "suffix:px/s") var scripted_walk_speed: float = 55.0
@export_range(0.1, 3.0, 0.05, "suffix:s") var headlight_start_delay_seconds: float = 0.9
@export_range(0.1, 3.0, 0.05, "suffix:s") var headlight_growth_seconds: float = 1.25
@export_range(1.0, 14.0, 0.25) var headlight_final_scale: float = 8.0
@export_range(20.0, 240.0, 1.0, "suffix:px") var headlight_spacing: float = 112.0
@export var headlights_color: Color = Color(1.0, 0.91, 0.62, 0.95)

@export_category("Impact and Montage")
@export_range(0.1, 2.0, 0.05, "suffix:s") var impact_crossfade_seconds: float = 0.45
@export_range(0.2, 6.0, 0.1, "suffix:s") var impact_hold_seconds: float = 2.5
@export_range(0.5, 8.0, 0.1, "suffix:s") var impact_fade_to_black_seconds: float = 4.0
@export_range(0.0, 4.0, 0.1, "suffix:s") var black_hum_hold_seconds: float = 1.25
@export_range(-40.0, 0.0, 1.0, "suffix:dB") var hum_volume_db: float = -14.0
@export_range(0.0, 30.0, 0.1, "suffix:s") var hum_loop_start_seconds: float = 2.0
@export_range(0.1, 60.0, 0.1, "suffix:s") var hum_loop_end_seconds: float = 18.0
@export_range(0.1, 3.0, 0.05, "suffix:s") var memory_image_fade_seconds: float = 0.8
@export_range(1.0, 16.0, 0.5, "suffix:s") var birds_fade_in_seconds: float = 8.0
@export_range(0.0, 48.0, 1.0, "suffix:px") var goddess_top_margin_pixels: float = 12.0
@export_category("Final Memory Framing")
@export_range(0.5, 12.0, 0.1, "suffix:s") var final_image_appearance_fade_seconds: float = 8.0
@export_range(1.0, 3.0, 0.05) var final_image_zoom_amount: float = 1.55
@export_range(0.5, 8.0, 0.1, "suffix:s") var final_image_zoom_in_seconds: float = 2.0
@export_range(0.5, 1.0, 0.01) var final_image_bottom_focus_y: float = 0.88
@export_range(0.0, 0.5, 0.01) var final_image_eye_focus_y: float = 0.14
@export_range(0.0, 3.0, 0.1, "suffix:s") var final_image_bottom_hold_seconds: float = 0.7
@export_range(1.0, 16.0, 0.25, "suffix:s") var final_image_pan_seconds: float = 4.8
@export_range(0.0, 3.0, 0.1, "suffix:s") var final_image_eye_hold_seconds: float = 0.7
@export_range(0.5, 8.0, 0.1, "suffix:s") var final_image_restore_seconds: float = 2.4

@export_category("Montage Dialogue")
@export var montage_dialogue_definition: DialogueDefinition
@export var montage_speaker_names: Dictionary = {&"memory": "..."}

@export_category("Exit")
@export_range(0.1, 4.0, 0.05, "suffix:s") var exit_fade_seconds: float = 2.0

@onready var world: Node2D = %World
@onready var player: Player = %Player
@onready var camera: Camera2D = %InterludeCamera
@onready var door_trigger: Area2D = %DoorTrigger
@onready var exit_trigger: Area2D = %ExitTrigger
@onready var door_close_timer: Timer = %DoorCloseTimer
@onready var headlight_start_timer: Timer = %HeadlightStartTimer
@onready var impact_hold_timer: Timer = %ImpactHoldTimer
@onready var black_hum_hold_timer: Timer = %BlackHumHoldTimer
@onready var hum_loop_timer: Timer = %HumLoopTimer
@onready var city_muffled: AudioStreamPlayer = %CityMuffled
@onready var city_loud: AudioStreamPlayer = %CityLoud
@onready var door_opening: AudioStreamPlayer = %DoorOpening
@onready var door_closing: AudioStreamPlayer = %DoorClosing
@onready var horn: AudioStreamPlayer = %Horn
@onready var hum: AudioStreamPlayer = %Hum
@onready var birds: AudioStreamPlayer = %Birds
@onready var headlight_stage: Node2D = %HeadlightStage
@onready var left_headlight: Sprite2D = %LeftHeadlight
@onready var right_headlight: Sprite2D = %RightHeadlight
@onready var impact_illustration: TextureRect = %ImpactIllustration
@onready var goddess_backdrop: TextureRect = %GoddessBackdrop
@onready var memory_image: TextureRect = %MemoryImage
@onready var memory_image_incoming: TextureRect = %MemoryImageIncoming
@onready var fade_overlay: ColorRect = %InterludeFadeOverlay

var current_phase: Phase = Phase.WALKING
var last_dialogue_result: Dictionary = {}

var _world_progression_lock_token: int = 0
var _dialogue_session_id: StringName = &""
var _door_sequence_started: bool = false
var _scripted_walk_active: bool = false
var _birds_started: bool = false
var _current_memory_image_index: int = -1
var _final_image_view_complete: bool = true
var _dialogue_finished_waiting_for_final_view: bool = false
var _final_view_locked_session_id: StringName = &""
var _loud_target_volume_db: float = -3.0
var _birds_target_volume_db: float = -7.0
var _player_visuals: Array[Sprite2D] = []
var _player_visual_base_positions: Array[Vector2] = []
var _city_crossfade_tween: Tween
var _headlight_tween: Tween
var _presentation_tween: Tween
var _memory_tween: Tween
var _final_image_tween: Tween
var _birds_tween: Tween
var _exit_tween: Tween
var _player_hud: CanvasLayer
var _player_hud_content: Control
var _mobile_controls: MobileGameplayControls
var _previous_player_hud_visible: bool = false
var _previous_player_hud_content_visible: bool = false
var _hud_visibility_captured: bool = false


func _ready() -> void:
	_configure_player_for_interlude()
	_loud_target_volume_db = city_loud.volume_db
	_birds_target_volume_db = birds.volume_db
	city_loud.volume_db = silent_volume_db
	hum.volume_db = hum_volume_db
	birds.volume_db = silent_volume_db
	fade_overlay.modulate.a = 0.0
	headlight_stage.visible = false
	impact_illustration.visible = false
	goddess_backdrop.visible = false
	memory_image.visible = false
	memory_image_incoming.visible = false
	memory_image.material = null

	door_trigger.body_entered.connect(_on_door_trigger_body_entered)
	exit_trigger.body_entered.connect(_on_exit_trigger_body_entered)
	door_close_timer.timeout.connect(_on_door_close_timer_timeout)
	headlight_start_timer.timeout.connect(_start_headlights)
	impact_hold_timer.timeout.connect(_fade_impact_to_black)
	black_hum_hold_timer.timeout.connect(_start_montage)
	hum_loop_timer.timeout.connect(_restart_hum_segment)
	city_muffled.finished.connect(_on_city_muffled_finished)
	city_loud.finished.connect(_on_city_loud_finished)
	hum.finished.connect(_on_hum_finished)
	birds.finished.connect(_on_birds_finished)
	_bind_dialogue_signals()

	_acquire_interlude_lock()
	_preload_next_scene()
	city_muffled.play()


func _process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	if _scripted_walk_active:
		player.global_position.x += scripted_walk_speed * delta
	camera.global_position = Vector2(
		clampf(player.global_position.x, camera_min_x, camera_max_x),
		camera_y
	).round()
	_snap_player_visuals_to_pixels()


func _exit_tree() -> void:
	_cancel_owned_dialogue()
	hum_loop_timer.stop()
	for tween in [
		_city_crossfade_tween,
		_headlight_tween,
		_presentation_tween,
		_memory_tween,
		_final_image_tween,
		_birds_tween,
		_exit_tween,
	]:
		if tween != null and tween.is_valid():
			tween.kill()
	_restore_player_and_hud_profile()
	_release_interlude_lock()


func _configure_player_for_interlude() -> void:
	player.set_intro_walk_movement_profile(true)
	player.set_process_unhandled_input(false)
	player.player_needs_enabled = false
	camera.position_smoothing_enabled = false
	var interaction_router := player.get_node_or_null("InteractionRouter")
	if interaction_router != null:
		interaction_router.process_mode = Node.PROCESS_MODE_DISABLED
	var debug_label := player.get_node_or_null("Label") as CanvasItem
	if debug_label != null:
		debug_label.visible = false
	var walk_state := player.get_node_or_null("States/Walk") as PlayerStateWalk
	if walk_state != null:
		walk_state.walk_speed = slow_walk_speed
	var grayscale_material := ShaderMaterial.new()
	grayscale_material.shader = GRAYSCALE_SHADER
	for sprite_path in ["Sprite2D", "MovementSprite"]:
		var sprite := player.get_node_or_null(sprite_path) as Sprite2D
		if sprite != null:
			sprite.material = grayscale_material
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			_player_visuals.append(sprite)
			_player_visual_base_positions.append(sprite.position)
	_configure_hud_for_walkable_intro()
	_snap_player_visuals_to_pixels()


func _configure_hud_for_walkable_intro() -> void:
	_player_hud = get_node_or_null("/root/PlayerHud") as CanvasLayer
	if _player_hud == null:
		return
	_player_hud_content = _player_hud.get_node_or_null("Control") as Control
	_mobile_controls = (
		_player_hud.get_node_or_null("MobileGameplayControls")
		as MobileGameplayControls
	)
	_previous_player_hud_visible = _player_hud.visible
	_previous_player_hud_content_visible = (
		_player_hud_content.visible if _player_hud_content != null else false
	)
	_hud_visibility_captured = true

	if not player.is_mobile_gameplay() or _mobile_controls == null:
		_player_hud.visible = false
		return

	if _player_hud_content != null:
		_player_hud_content.visible = false
	_mobile_controls.set_intro_movement_only(true)
	_player_hud.visible = true


func _hide_intro_mobile_controls() -> void:
	if _mobile_controls != null and is_instance_valid(_mobile_controls):
		_mobile_controls.set_intro_movement_only(false)
	if _player_hud != null and is_instance_valid(_player_hud):
		_player_hud.visible = false


func _restore_player_and_hud_profile() -> void:
	if player != null and is_instance_valid(player):
		player.set_intro_walk_movement_profile(false)
	if not _hud_visibility_captured:
		return
	if _mobile_controls != null and is_instance_valid(_mobile_controls):
		_mobile_controls.set_intro_movement_only(false)
	if _player_hud_content != null and is_instance_valid(_player_hud_content):
		_player_hud_content.visible = _previous_player_hud_content_visible
	if _player_hud != null and is_instance_valid(_player_hud):
		_player_hud.visible = _previous_player_hud_visible


func _snap_player_visuals_to_pixels() -> void:
	var pixel_compensation := player.global_position.round() - player.global_position
	for index in range(_player_visuals.size()):
		var sprite := _player_visuals[index]
		if sprite != null and is_instance_valid(sprite):
			sprite.position = _player_visual_base_positions[index] + pixel_compensation


func _on_door_trigger_body_entered(body: Node2D) -> void:
	if body != player or _door_sequence_started or player.direction.x <= 0.0:
		return
	_door_sequence_started = true
	door_trigger.set_deferred("monitoring", false)
	door_opening.play()
	_start_city_crossfade()
	door_close_timer.start(door_close_delay_seconds)
	door_sequence_started.emit()


func _start_city_crossfade() -> void:
	city_loud.volume_db = silent_volume_db
	city_loud.play()
	_city_crossfade_tween = create_tween()
	_city_crossfade_tween.set_parallel(true)
	_city_crossfade_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_city_crossfade_tween.tween_property(
		city_muffled, "volume_db", silent_volume_db, city_crossfade_seconds
	)
	_city_crossfade_tween.tween_property(
		city_loud, "volume_db", _loud_target_volume_db, city_crossfade_seconds
	)
	_city_crossfade_tween.finished.connect(city_muffled.stop, CONNECT_ONE_SHOT)


func _on_door_close_timer_timeout() -> void:
	if _door_sequence_started and current_phase == Phase.WALKING:
		door_closing.play()


func _on_exit_trigger_body_entered(body: Node2D) -> void:
	if (
		body != player
		or not _door_sequence_started
		or current_phase != Phase.WALKING
		or player.direction.x <= 0.0
	):
		return
	_begin_scripted_approach()


func _begin_scripted_approach() -> void:
	current_phase = Phase.SCRIPTED_APPROACH
	_hide_intro_mobile_controls()
	exit_trigger.set_deferred("monitoring", false)
	player.set_process(false)
	player.set_physics_process(false)
	player.velocity = Vector2.ZERO
	player.direction = Vector2.RIGHT
	player.apply_facing_left(false)
	var animation_player := player.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if animation_player != null and animation_player.has_animation(&"walk"):
		animation_player.play(&"walk")
	_scripted_walk_active = true
	headlight_start_timer.start(headlight_start_delay_seconds)


func _start_headlights() -> void:
	if current_phase != Phase.SCRIPTED_APPROACH:
		return
	current_phase = Phase.HEADLIGHTS
	var viewport_size := get_viewport_rect().size
	var center := Vector2(viewport_size.x * 0.5 + 135.0, viewport_size.y * 0.66)
	left_headlight.position = center + Vector2(-headlight_spacing * 0.5, 0.0)
	right_headlight.position = center + Vector2(headlight_spacing * 0.5, 0.0)
	for light in [left_headlight, right_headlight]:
		light.modulate = headlights_color
		light.scale = Vector2(0.08, 0.08)
	headlight_stage.modulate.a = 0.0
	headlight_stage.visible = true
	_headlight_tween = create_tween()
	_headlight_tween.set_parallel(true)
	_headlight_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_headlight_tween.tween_property(
		headlight_stage, "modulate:a", 1.0, headlight_growth_seconds * 0.35
	)
	for light in [left_headlight, right_headlight]:
		_headlight_tween.tween_property(
			light,
			"scale",
			Vector2.ONE * headlight_final_scale,
			headlight_growth_seconds
		)
	_headlight_tween.finished.connect(_show_impact_illustration, CONNECT_ONE_SHOT)
	headlights_started.emit()


func _show_impact_illustration() -> void:
	if current_phase != Phase.HEADLIGHTS:
		return
	current_phase = Phase.IMPACT_ILLUSTRATION
	_scripted_walk_active = false
	horn.play()
	impact_illustration.visible = true
	impact_illustration.modulate.a = 0.0
	_presentation_tween = create_tween()
	_presentation_tween.set_parallel(true)
	_presentation_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_presentation_tween.tween_property(
		world, "modulate:a", 0.0, impact_crossfade_seconds
	)
	_presentation_tween.tween_property(
		headlight_stage, "modulate:a", 0.0, impact_crossfade_seconds
	)
	_presentation_tween.tween_property(
		impact_illustration, "modulate:a", 1.0, impact_crossfade_seconds
	)
	_presentation_tween.tween_property(
		city_loud, "volume_db", silent_volume_db, impact_crossfade_seconds
	)
	_presentation_tween.finished.connect(_on_impact_crossfade_finished, CONNECT_ONE_SHOT)


func _on_impact_crossfade_finished() -> void:
	city_loud.stop()
	headlight_stage.visible = false
	impact_hold_timer.start(impact_hold_seconds)


func _fade_impact_to_black() -> void:
	if current_phase != Phase.IMPACT_ILLUSTRATION:
		return
	_start_hum_segment_loop()
	_presentation_tween = create_tween()
	_presentation_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_presentation_tween.tween_property(
		impact_illustration,
		"modulate:a",
		0.0,
		impact_fade_to_black_seconds
	)
	_presentation_tween.finished.connect(_on_impact_faded_to_black, CONNECT_ONE_SHOT)


func _on_impact_faded_to_black() -> void:
	current_phase = Phase.BLACK_HUM
	impact_illustration.visible = false
	black_hum_hold_timer.start(black_hum_hold_seconds)


func _start_montage() -> void:
	if current_phase != Phase.BLACK_HUM:
		return
	current_phase = Phase.MONTAGE
	_set_memory_image_immediate(0)
	goddess_backdrop.visible = true
	goddess_backdrop.modulate.a = 0.0
	memory_image.visible = true
	memory_image.modulate.a = 0.0
	_memory_tween = create_tween()
	_memory_tween.set_parallel(true)
	_memory_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_memory_tween.tween_property(
		goddess_backdrop, "modulate:a", 1.0, memory_image_fade_seconds
	)
	_memory_tween.tween_property(
		memory_image, "modulate:a", 1.0, memory_image_fade_seconds
	)
	_memory_tween.finished.connect(_start_montage_dialogue, CONNECT_ONE_SHOT)
	montage_started.emit()


func _start_montage_dialogue() -> void:
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if (
		dialogue_controller == null
		or not dialogue_controller.has_method("begin_modal_dialogue")
		or montage_dialogue_definition == null
	):
		push_warning("Intro montage could not start the shared modal dialogue.")
		return
	var result = dialogue_controller.call(
		"begin_modal_dialogue",
		self,
		montage_dialogue_definition,
		montage_speaker_names
	)
	if not (result is Dictionary) or not bool(result.get("accepted", false)):
		var reason := String(result.get("reason", "rejected")) if result is Dictionary else "invalid_result"
		push_warning("Intro montage dialogue was rejected: %s." % reason)
		return
	_dialogue_session_id = StringName(result.get("session_id", &""))


func _on_dialogue_node_started(
	session_id: StringName,
	dialogue_id: StringName,
	node_id: StringName,
	_speaker_id: StringName
) -> void:
	if (
		current_phase != Phase.MONTAGE
		or dialogue_id != &"intro_memory_montage"
		or (_dialogue_session_id != &"" and session_id != _dialogue_session_id)
	):
		return
	var beat_number := int(String(node_id).trim_prefix("memory_"))
	if beat_number <= 0:
		return
	var image_index := _get_memory_image_index_for_beat(beat_number)
	if image_index != _current_memory_image_index:
		if image_index == MEMORY_IMAGES.size() - 1:
			_final_view_locked_session_id = session_id
			_set_montage_dialogue_input_enabled(session_id, false)
			_set_montage_dialogue_visible(session_id, false)
		_crossfade_memory_image(image_index)
	if image_index >= BIRDS_FADE_IN_IMAGE_INDEX:
		_start_birds_fade_in()


func _get_memory_image_index_for_beat(beat_number: int) -> int:
	var result := 0
	for index in range(MEMORY_IMAGE_FIRST_BEATS.size()):
		if beat_number < MEMORY_IMAGE_FIRST_BEATS[index]:
			break
		result = index
	return result


static func calculate_goddess_cover_vertical_offset(
	viewport_size: Vector2,
	texture_size: Vector2,
	top_margin_pixels: float = 12.0
) -> float:
	if (
		viewport_size.x <= 0.0
		or viewport_size.y <= 0.0
		or texture_size.x <= 0.0
		or texture_size.y <= 0.0
	):
		return 0.0
	var cover_scale := maxf(
		viewport_size.x / texture_size.x,
		viewport_size.y / texture_size.y
	)
	var centered_image_top := (viewport_size.y - texture_size.y * cover_scale) * 0.5
	return maxf(0.0, top_margin_pixels - centered_image_top)


func _apply_memory_image_framing(image_rect: TextureRect, image_index: int) -> void:
	var vertical_offset := 0.0
	if image_index >= 0 and image_index < MEMORY_IMAGES.size() - 1:
		vertical_offset = calculate_goddess_cover_vertical_offset(
			get_viewport_rect().size,
			MEMORY_IMAGES[image_index].get_size(),
			goddess_top_margin_pixels
		)
	image_rect.offset_top = vertical_offset
	image_rect.offset_bottom = vertical_offset


func _set_memory_image_immediate(image_index: int) -> void:
	_current_memory_image_index = clampi(image_index, 0, MEMORY_IMAGES.size() - 1)
	memory_image.texture = MEMORY_IMAGES[_current_memory_image_index]
	_apply_memory_image_framing(memory_image, _current_memory_image_index)
	_reset_final_image_view()


func _crossfade_memory_image(image_index: int) -> void:
	var next_index := clampi(image_index, 0, MEMORY_IMAGES.size() - 1)
	if next_index == _current_memory_image_index:
		return
	if _memory_tween != null and _memory_tween.is_valid():
		_memory_tween.kill()
	_reset_final_image_view()
	var entering_final_image := next_index == MEMORY_IMAGES.size() - 1
	if entering_final_image:
		_final_image_view_complete = false
	memory_image_incoming.texture = MEMORY_IMAGES[next_index]
	_apply_memory_image_framing(memory_image_incoming, next_index)
	memory_image_incoming.modulate.a = 0.0
	memory_image_incoming.visible = true
	_memory_tween = create_tween()
	_memory_tween.set_parallel(true)
	_memory_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var fade_seconds := (
		final_image_appearance_fade_seconds
		if entering_final_image
		else memory_image_fade_seconds
	)
	if not entering_final_image:
		_memory_tween.tween_property(
			memory_image, "modulate:a", 0.0, fade_seconds
		)
	else:
		# Keep the previous image opaque underneath so the last picture never dips
		# through black or looks translucent while it slowly appears.
		memory_image.modulate.a = 1.0
	_memory_tween.tween_property(
		memory_image_incoming, "modulate:a", 1.0, fade_seconds
	)
	_memory_tween.finished.connect(
		_finish_memory_image_crossfade.bind(next_index),
		CONNECT_ONE_SHOT
	)


func _finish_memory_image_crossfade(image_index: int) -> void:
	memory_image.texture = MEMORY_IMAGES[image_index]
	_apply_memory_image_framing(memory_image, image_index)
	memory_image.modulate.a = 1.0
	memory_image_incoming.visible = false
	_current_memory_image_index = image_index
	if image_index == MEMORY_IMAGES.size() - 1:
		goddess_backdrop.visible = false
		_start_final_image_bottom_up_view()


func _start_final_image_bottom_up_view() -> void:
	if _final_image_tween != null and _final_image_tween.is_valid():
		_final_image_tween.kill()
	var shader_material := ShaderMaterial.new()
	shader_material.shader = FINAL_MEMORY_ZOOM_SHADER
	memory_image.material = shader_material
	memory_image.modulate.a = 1.0
	_final_image_view_complete = false
	shader_material.set_shader_parameter(&"zoom", 1.0)
	shader_material.set_shader_parameter(
		&"focus",
		Vector2(0.5, final_image_bottom_focus_y)
	)
	_final_image_tween = create_tween()
	_final_image_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_final_image_tween.tween_method(
		_set_final_image_zoom,
		1.0,
		final_image_zoom_amount,
		final_image_zoom_in_seconds
	)
	_final_image_tween.finished.connect(_on_final_image_zoomed_in, CONNECT_ONE_SHOT)


func _set_final_image_focus_y(value: float) -> void:
	var shader_material := memory_image.material as ShaderMaterial
	if shader_material != null:
		shader_material.set_shader_parameter(&"focus", Vector2(0.5, value))


func _set_final_image_zoom(value: float) -> void:
	var shader_material := memory_image.material as ShaderMaterial
	if shader_material != null:
		shader_material.set_shader_parameter(&"zoom", value)


func _reset_final_image_view() -> void:
	var shader_material := memory_image.material as ShaderMaterial
	if shader_material != null:
		shader_material.set_shader_parameter(&"zoom", 1.0)
		shader_material.set_shader_parameter(&"focus", Vector2(0.5, 0.5))
	memory_image.material = null


func _on_final_image_zoomed_in() -> void:
	_final_image_tween = create_tween()
	_final_image_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if final_image_bottom_hold_seconds > 0.0:
		_final_image_tween.tween_interval(final_image_bottom_hold_seconds)
	_final_image_tween.tween_method(
		_set_final_image_focus_y,
		final_image_bottom_focus_y,
		final_image_eye_focus_y,
		final_image_pan_seconds
	)
	if final_image_eye_hold_seconds > 0.0:
		_final_image_tween.tween_interval(final_image_eye_hold_seconds)
	_final_image_tween.finished.connect(_on_final_image_pan_finished, CONNECT_ONE_SHOT)


func _on_final_image_pan_finished() -> void:
	_final_image_tween = create_tween()
	_final_image_tween.set_parallel(true)
	_final_image_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_final_image_tween.tween_method(
		_set_final_image_focus_y,
		final_image_eye_focus_y,
		0.5,
		final_image_restore_seconds
	)
	_final_image_tween.tween_method(
		_set_final_image_zoom,
		final_image_zoom_amount,
		1.0,
		final_image_restore_seconds
	)
	_final_image_tween.finished.connect(_on_final_image_view_finished, CONNECT_ONE_SHOT)


func _on_final_image_view_finished() -> void:
	_reset_final_image_view()
	memory_image.modulate.a = 1.0
	_final_image_view_complete = true
	var locked_session_id := _final_view_locked_session_id
	_final_view_locked_session_id = &""
	if locked_session_id != &"":
		if not _complete_hidden_final_montage_node(locked_session_id):
			_set_montage_dialogue_visible(locked_session_id, true)
			_set_montage_dialogue_input_enabled(locked_session_id, true)
	if _dialogue_finished_waiting_for_final_view:
		_dialogue_finished_waiting_for_final_view = false
		_begin_exit()


func _set_montage_dialogue_input_enabled(session_id: StringName, enabled: bool) -> bool:
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if dialogue_controller == null or not dialogue_controller.has_method("set_session_input_enabled"):
		return false
	return bool(dialogue_controller.call("set_session_input_enabled", session_id, enabled))


func _set_montage_dialogue_visible(session_id: StringName, should_show: bool) -> bool:
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if dialogue_controller == null or not dialogue_controller.has_method("set_session_ui_visible"):
		return false
	return bool(dialogue_controller.call("set_session_ui_visible", session_id, should_show))


func _complete_hidden_final_montage_node(session_id: StringName) -> bool:
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if (
		dialogue_controller == null
		or not dialogue_controller.has_method("advance")
		or StringName(dialogue_controller.get("current_session_id")) != session_id
	):
		return false
	return bool(dialogue_controller.call("advance"))


func _start_birds_fade_in() -> void:
	if _birds_started:
		return
	_birds_started = true
	birds.volume_db = silent_volume_db
	birds.play()
	_birds_tween = create_tween()
	_birds_tween.set_parallel(true)
	_birds_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_birds_tween.tween_property(
		birds, "volume_db", _birds_target_volume_db, birds_fade_in_seconds
	)
	_birds_tween.tween_property(
		hum, "volume_db", silent_volume_db, birds_fade_in_seconds
	)


func _on_dialogue_session_finished(result: Dictionary) -> void:
	if StringName(result.get("session_id", &"")) != _dialogue_session_id:
		return
	_dialogue_session_id = &""
	last_dialogue_result = result.duplicate(true)
	if bool(result.get("completed", false)):
		if _final_image_view_complete:
			_begin_exit()
		else:
			_dialogue_finished_waiting_for_final_view = true


func _begin_exit() -> void:
	if current_phase == Phase.EXIT:
		return
	current_phase = Phase.EXIT
	fade_overlay.modulate.a = 0.0
	_exit_tween = create_tween()
	_exit_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_exit_tween.tween_property(fade_overlay, "modulate:a", 1.0, exit_fade_seconds)
	_exit_tween.finished.connect(_handoff_to_next_scene, CONNECT_ONE_SHOT)


func _handoff_to_next_scene() -> void:
	var normalized_path := next_scene_path.strip_edges()
	if normalized_path.is_empty():
		push_warning("Intro walking interlude next scene path is empty.")
		return
	exit_requested.emit(normalized_path, target_spawn_id)
	_release_interlude_lock()
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader == null:
		push_warning("Intro walking interlude could not find the shared SceneLoader.")
		return
	if scene_loader.has_method("request_player_scene_transition"):
		var result: Dictionary = scene_loader.call(
			"request_player_scene_transition",
			player,
			normalized_path,
			target_spawn_id,
			&"intro_montage_complete"
		)
		if bool(result.get("accepted", false)):
			return
	if not bool(scene_loader.call("change_scene", normalized_path)):
		push_warning("Intro walking interlude SceneLoader handoff was rejected.")


func _bind_dialogue_signals() -> void:
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if dialogue_controller == null:
		return
	dialogue_controller.dialogue_node_started.connect(_on_dialogue_node_started)
	dialogue_controller.dialogue_session_finished.connect(_on_dialogue_session_finished)


func _cancel_owned_dialogue() -> void:
	if _dialogue_session_id == &"":
		return
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if (
		dialogue_controller != null
		and dialogue_controller.has_method("is_dialogue_active")
		and bool(dialogue_controller.call("is_dialogue_active"))
		and StringName(dialogue_controller.get("current_session_id")) == _dialogue_session_id
	):
		dialogue_controller.call("cancel_dialogue", "intro_interlude_removed")
	_dialogue_session_id = &""


func _on_city_muffled_finished() -> void:
	if not _door_sequence_started and is_inside_tree():
		city_muffled.play()


func _on_city_loud_finished() -> void:
	if current_phase <= Phase.HEADLIGHTS and _door_sequence_started and is_inside_tree():
		city_loud.play()


func _on_hum_finished() -> void:
	if current_phase >= Phase.IMPACT_ILLUSTRATION and current_phase < Phase.EXIT and is_inside_tree():
		_restart_hum_segment()


func _start_hum_segment_loop() -> void:
	var loop_start := maxf(hum_loop_start_seconds, 0.0)
	var loop_end := maxf(hum_loop_end_seconds, loop_start + 0.1)
	hum.volume_db = hum_volume_db
	hum.play(loop_start)
	hum_loop_timer.start(loop_end - loop_start)


func _restart_hum_segment() -> void:
	if (
		current_phase < Phase.IMPACT_ILLUSTRATION
		or current_phase >= Phase.EXIT
		or not is_inside_tree()
	):
		hum_loop_timer.stop()
		return
	var loop_start := maxf(hum_loop_start_seconds, 0.0)
	var loop_end := maxf(hum_loop_end_seconds, loop_start + 0.1)
	if hum.playing:
		hum.seek(loop_start)
	else:
		hum.play(loop_start)
	hum_loop_timer.start(loop_end - loop_start)


func _on_birds_finished() -> void:
	if _birds_started and current_phase < Phase.EXIT and is_inside_tree():
		birds.play()


func _acquire_interlude_lock() -> void:
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null or not gameplay_flow.has_method("acquire_world_progression_lock"):
		return
	_world_progression_lock_token = int(gameplay_flow.call(
		"acquire_world_progression_lock", self, INTERLUDE_LOCK_REASON
	))


func _release_interlude_lock() -> void:
	if _world_progression_lock_token == 0:
		return
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow != null and gameplay_flow.has_method("release_world_progression_lock"):
		gameplay_flow.call(
			"release_world_progression_lock",
			_world_progression_lock_token,
			self
		)
	_world_progression_lock_token = 0


func _preload_next_scene() -> void:
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("preload_scene"):
		scene_loader.call("preload_scene", next_scene_path)
