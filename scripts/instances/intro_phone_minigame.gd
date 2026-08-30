class_name IntroPhoneMinigame
extends Control

signal answered

@export_category("Input")
@export var left_action: StringName = &"left"
@export var right_action: StringName = &"right"
@export var up_action: StringName = &"up"
@export var down_action: StringName = &"crouch"
@export var grab_action: StringName = &"attack"

@export_category("Feel")
@export_range(20.0, 300.0, 5.0, "suffix:px/s") var hand_speed: float = 105.0
@export_range(0.1, 1.0, 0.05) var held_hand_speed_multiplier: float = 0.45
@export_range(4.0, 64.0, 1.0, "suffix:px") var grab_radius: float = 28.0
@export_range(24.0, 96.0, 1.0, "suffix:px") var touch_grab_radius: float = 44.0
@export_range(24.0, 160.0, 1.0, "suffix:px") var slider_travel_pixels: float = 80.0
@export_range(0.5, 1.0, 0.01) var slider_success_threshold: float = 0.85
@export_range(0.05, 1.0, 0.01, "suffix:s") var snap_back_duration: float = 0.18
@export_range(0.0, 8.0, 0.25, "suffix:px") var held_shake_amplitude: float = 2.25
@export var hand_start_position: Vector2 = Vector2(150.0, 105.0)
@export_range(0.0, 2.0, 0.05, "suffix:s") var hand_reveal_delay: float = 0.85
@export_range(0.0, 1.0, 0.05, "suffix:s") var hand_reveal_fade_duration: float = 0.3

@export_category("Blur")
@export_range(0.5, 4.0, 0.1) var blur_strength: float = 2.6
@export_range(0.2, 3.0, 0.05, "suffix:s") var blur_in_duration: float = 1.25
@export_range(0.0, 2.0, 0.05, "suffix:s") var blur_hold_duration: float = 0.4
@export_range(0.2, 3.0, 0.05, "suffix:s") var blur_out_duration: float = 1.5
@export_range(0.5, 8.0, 0.1, "suffix:s") var blur_interval_min: float = 2.5
@export_range(0.5, 8.0, 0.1, "suffix:s") var blur_interval_max: float = 4.0

@onready var phone_panel: Control = %PhoneInteractionPanel
@onready var phone_background_frame_a: TextureRect = %PhoneBackgroundFrameA
@onready var phone_background_frame_b: TextureRect = %PhoneBackgroundFrameB
@onready var slider_track_frame_a: TextureRect = %SliderTrackFrameA
@onready var slider_track_frame_b: TextureRect = %SliderTrackFrameB
@onready var answer_handle: Sprite2D = %AnswerHandle
@onready var hand_sprite: Sprite2D = %HandSprite
@onready var blur_overlay: ColorRect = %PhoneBlurOverlay
@onready var phone_flash_timer: Timer = %PhoneFlashTimer
@onready var blur_cycle_timer: Timer = %BlurCycleTimer
@onready var hand_reveal_timer: Timer = %PhoneHandRevealTimer
@onready var answer_feedback: AudioStreamPlayer = %AnswerFeedback

var _active: bool = false
var _hand_input_enabled: bool = false
var _grabbed: bool = false
var _completed: bool = false
var _hand_position: Vector2
var _handle_start_position: Vector2
var _handle_base_x: float = 0.0
var _grab_offset_x: float = 0.0
var _shake_time: float = 0.0
var _snap_back_tween: Tween
var _blur_tween: Tween
var _hand_reveal_tween: Tween
var _random := RandomNumberGenerator.new()
var _direct_touch_enabled: bool = false
var _touch_drag_id: int = -1
var _touch_grab_offset_x: float = 0.0


func _ready() -> void:
	_handle_start_position = answer_handle.position
	_direct_touch_enabled = OS.has_feature("mobile")
	phone_flash_timer.timeout.connect(_on_phone_flash_timer_timeout)
	blur_cycle_timer.timeout.connect(_on_blur_cycle_timer_timeout)
	hand_reveal_timer.timeout.connect(_reveal_hand)
	set_process_input(true)
	set_process(false)
	_reset_visual_state()


func activate() -> void:
	_completed = false
	_grabbed = false
	_touch_drag_id = -1
	_active = true
	_hand_input_enabled = false
	_shake_time = 0.0
	_hand_position = hand_start_position
	hand_sprite.position = _hand_position.round()
	hand_sprite.modulate.a = 0.0
	hand_sprite.visible = false
	_set_handle_base_x(_handle_start_position.x)
	_show_flash_frame_a(true)
	_set_blur_strength(0.0)
	phone_flash_timer.start()
	_schedule_next_blur()
	set_process(true)
	if _direct_touch_enabled:
		# On a phone, the player's real finger is the hand. Do not draw or wait for
		# the artificial cursor; the green answer handle can be grabbed directly.
		hand_reveal_timer.stop()
	else:
		if hand_reveal_delay > 0.0:
			hand_reveal_timer.start(hand_reveal_delay)
		else:
			_reveal_hand()


func deactivate() -> void:
	_active = false
	_hand_input_enabled = false
	_grabbed = false
	_touch_drag_id = -1
	set_process(false)
	phone_flash_timer.stop()
	blur_cycle_timer.stop()
	hand_reveal_timer.stop()
	_kill_snap_back_tween()
	_kill_blur_tween()
	_kill_hand_reveal_tween()
	_set_blur_strength(0.0)


func _input(event: InputEvent) -> void:
	if not _direct_touch_enabled or not _active or _completed:
		return

	var touch := event as InputEventScreenTouch
	if touch != null:
		if touch.pressed:
			if _touch_drag_id < 0:
				var local_position := _viewport_to_phone_panel(touch.position)
				if _touch_overlaps_handle(local_position):
					_begin_touch_drag(touch.index, local_position)
					get_viewport().set_input_as_handled()
		else:
			if touch.index == _touch_drag_id:
				_touch_drag_id = -1
				_release_handle()
				get_viewport().set_input_as_handled()
		return

	var drag := event as InputEventScreenDrag
	if drag != null and drag.index == _touch_drag_id:
		_update_touch_drag(_viewport_to_phone_panel(drag.position))
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _active or _completed or not _hand_input_enabled:
		return

	var direction := Input.get_vector(
		left_action,
		right_action,
		up_action,
		down_action
	)
	var speed_multiplier := held_hand_speed_multiplier if _grabbed else 1.0
	_hand_position += direction * hand_speed * speed_multiplier * delta
	_hand_position = _hand_position.clamp(
		Vector2.ZERO,
		phone_panel.size
	)
	# Preserve smooth logical movement but keep the pixel-art texture on whole
	# pixels so it cannot shimmer or appear to stretch between samples.
	hand_sprite.position = _hand_position.round()

	if _grabbed:
		if Input.is_action_just_released(grab_action) or not Input.is_action_pressed(grab_action):
			_release_handle()
			return
		_handle_base_x = clampf(
			hand_sprite.position.x + _grab_offset_x,
			_handle_start_position.x,
			_get_handle_end_x()
		)
		_shake_time += delta
		_apply_handle_visual(true)
		if get_slider_progress() >= slider_success_threshold:
			_complete_answer()
		return

	if Input.is_action_just_pressed(grab_action) and _hand_overlaps_handle():
		_begin_grab()


func get_slider_progress() -> float:
	return clampf(
		(_handle_base_x - _handle_start_position.x) / slider_travel_pixels,
		0.0,
		1.0
	)


func is_handle_grabbed() -> bool:
	return _grabbed


func _begin_touch_drag(touch_id: int, local_position: Vector2) -> void:
	_kill_snap_back_tween()
	_touch_drag_id = touch_id
	_grabbed = true
	_touch_grab_offset_x = _handle_base_x - local_position.x
	_shake_time = 0.0


func _update_touch_drag(local_position: Vector2) -> void:
	_handle_base_x = clampf(
		local_position.x + _touch_grab_offset_x,
		_handle_start_position.x,
		_get_handle_end_x()
	)
	_shake_time += get_process_delta_time()
	_apply_handle_visual(true)
	if get_slider_progress() >= slider_success_threshold:
		_complete_answer()


func _touch_overlaps_handle(local_position: Vector2) -> bool:
	return local_position.distance_to(
		Vector2(_handle_base_x, _handle_start_position.y)
	) <= touch_grab_radius


func _viewport_to_phone_panel(viewport_position: Vector2) -> Vector2:
	return phone_panel.get_global_transform_with_canvas().affine_inverse() * viewport_position


func _begin_grab() -> void:
	_kill_snap_back_tween()
	_grabbed = true
	_grab_offset_x = _handle_base_x - hand_sprite.position.x
	hand_sprite.modulate.a = 0.55


func _release_handle() -> void:
	_grabbed = false
	hand_sprite.modulate.a = 1.0
	_kill_snap_back_tween()
	_snap_back_tween = create_tween()
	_snap_back_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_snap_back_tween.tween_method(
		_set_handle_base_x,
		_handle_base_x,
		_handle_start_position.x,
		snap_back_duration
	)


func _complete_answer() -> void:
	if _completed:
		return
	_completed = true
	_active = false
	_hand_input_enabled = false
	_grabbed = false
	_touch_drag_id = -1
	_handle_base_x = _get_handle_end_x()
	_apply_handle_visual(false)
	hand_sprite.modulate.a = 0.55
	set_process(false)
	phone_flash_timer.stop()
	blur_cycle_timer.stop()
	hand_reveal_timer.stop()
	_kill_snap_back_tween()
	_kill_blur_tween()
	_kill_hand_reveal_tween()
	_set_blur_strength(0.0)
	if answer_feedback.stream != null:
		answer_feedback.play()
	answered.emit()


func _hand_overlaps_handle() -> bool:
	return hand_sprite.position.distance_to(
		Vector2(_handle_base_x, _handle_start_position.y)
	) <= grab_radius


func _get_handle_end_x() -> float:
	return _handle_start_position.x + slider_travel_pixels


func _set_handle_base_x(value: float) -> void:
	_handle_base_x = clampf(
		value,
		_handle_start_position.x,
		_get_handle_end_x()
	)
	_apply_handle_visual(false)


func _apply_handle_visual(with_shake: bool) -> void:
	var shake := Vector2.ZERO
	if with_shake and held_shake_amplitude > 0.0:
		shake = Vector2(
			sin(_shake_time * 47.0),
			cos(_shake_time * 61.0)
		) * held_shake_amplitude
	answer_handle.position = Vector2(
		_handle_base_x + shake.x,
		_handle_start_position.y + shake.y
	)


func _reset_visual_state() -> void:
	_hand_position = hand_start_position
	hand_sprite.position = _hand_position.round()
	hand_sprite.modulate.a = 0.0
	hand_sprite.visible = false
	_touch_drag_id = -1
	_handle_base_x = _handle_start_position.x
	_apply_handle_visual(false)
	_show_flash_frame_a(true)
	_set_blur_strength(0.0)


func _reveal_hand() -> void:
	if not _active or _completed or _direct_touch_enabled:
		return
	hand_sprite.visible = true
	hand_sprite.modulate.a = 0.0
	_kill_hand_reveal_tween()
	if hand_reveal_fade_duration <= 0.0:
		hand_sprite.modulate.a = 1.0
		_hand_input_enabled = true
		return
	_hand_reveal_tween = create_tween()
	_hand_reveal_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_hand_reveal_tween.tween_property(
		hand_sprite,
		"modulate:a",
		1.0,
		hand_reveal_fade_duration
	)
	_hand_reveal_tween.finished.connect(_enable_hand_input, CONNECT_ONE_SHOT)


func _enable_hand_input() -> void:
	if _active and not _completed and not _direct_touch_enabled:
		_hand_input_enabled = true


func _on_phone_flash_timer_timeout() -> void:
	if not _active:
		phone_flash_timer.stop()
		return
	_show_flash_frame_a(not phone_background_frame_a.visible)


func _show_flash_frame_a(show_frame_a: bool) -> void:
	phone_background_frame_a.visible = show_frame_a
	phone_background_frame_b.visible = not show_frame_a
	slider_track_frame_a.visible = show_frame_a
	slider_track_frame_b.visible = not show_frame_a


func _schedule_next_blur() -> void:
	if not _active or _completed:
		return
	blur_cycle_timer.start(_random.randf_range(
		minf(blur_interval_min, blur_interval_max),
		maxf(blur_interval_min, blur_interval_max)
	))


func _on_blur_cycle_timer_timeout() -> void:
	if not _active or _completed:
		return
	_kill_blur_tween()
	_blur_tween = create_tween()
	_blur_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_blur_tween.tween_method(_set_blur_strength, 0.0, blur_strength, blur_in_duration)
	if blur_hold_duration > 0.0:
		_blur_tween.tween_interval(blur_hold_duration)
	_blur_tween.tween_method(_set_blur_strength, blur_strength, 0.0, blur_out_duration)
	_blur_tween.finished.connect(_schedule_next_blur, CONNECT_ONE_SHOT)


func _set_blur_strength(value: float) -> void:
	var shader_material := blur_overlay.material as ShaderMaterial
	if shader_material != null:
		shader_material.set_shader_parameter(&"blur_strength", value)


func _kill_snap_back_tween() -> void:
	if _snap_back_tween != null and _snap_back_tween.is_valid():
		_snap_back_tween.kill()


func _kill_blur_tween() -> void:
	if _blur_tween != null and _blur_tween.is_valid():
		_blur_tween.kill()


func _kill_hand_reveal_tween() -> void:
	if _hand_reveal_tween != null and _hand_reveal_tween.is_valid():
		_hand_reveal_tween.kill()
