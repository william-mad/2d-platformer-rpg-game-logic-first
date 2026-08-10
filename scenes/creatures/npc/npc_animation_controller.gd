class_name NpcAnimationController extends Node

const DEFAULT_ANIMATION_ALIASES := {
	"move": "walk",
	"walking": "walk",
	"fighting": "run",
	"fleeing": "run",
	"working": "work",
	"eating": "eat",
	"resting": "rest",
	"sleeping": "sleep",
	"talking": "talk",
}

enum LocomotionPhase {
	NONE,
	WALK,
	RUN_START,
	RUN,
}

enum LocomotionIntent {
	NONE,
	WALK,
	RUN,
}

@export_group("Nodes")
@export var animation_player_path: NodePath
@export var sprite_path: NodePath
@export var facing_scale_paths: Array[NodePath] = [NodePath("SightPivot")]

@export_group("Resolution")
@export var animation_aliases: Dictionary = {}
@export var disable_flip_h_animation_tracks: bool = true
@export var force_unflipped_animation_names: PackedStringArray = PackedStringArray()

@export_group("Ground Locomotion")
@export var grounded_locomotion_enabled: bool = false
@export var walk_animation_name: StringName = &"walk"
@export var run_start_animation_name: StringName = &"run_start"
@export var run_animation_name: StringName = &"run"
@export var locomotion_idle_animation_name: StringName = &"idle"
@export_range(0.0, 100.0, 0.5, "suffix:px/s") var locomotion_stop_speed: float = 4.0
@export_range(0.0, 3000.0, 1.0, "suffix:px/s") var run_enter_speed: float = 120.0
@export_range(0.0, 3000.0, 1.0, "suffix:px/s") var run_exit_speed: float = 100.0
@export_range(1.0, 3000.0, 1.0, "suffix:px/s") var walk_reference_speed: float = 77.0
@export_range(1.0, 3000.0, 1.0, "suffix:px/s") var run_reference_speed: float = 161.0

@export_group("Ground Locomotion Playback")
@export_range(0.01, 4.0, 0.01) var walk_min_speed_scale: float = 0.70
@export_range(0.01, 4.0, 0.01) var walk_max_speed_scale: float = 1.35
@export_range(0.01, 4.0, 0.01) var run_start_min_speed_scale: float = 0.90
@export_range(0.01, 4.0, 0.01) var run_start_max_speed_scale: float = 1.20
@export_range(0.01, 4.0, 0.01) var run_min_speed_scale: float = 0.85
@export_range(0.01, 4.0, 0.01) var run_max_speed_scale: float = 1.60

var npc: Node2D
var animation_player: AnimationPlayer
var sprite: Sprite2D

var _warned_missing_animation_player: bool = false
var _warned_missing_animations: Dictionary = {}
var _facing_base_scales: Dictionary = {}
var _facing_tracks_sanitized: bool = false
var _connected_animation_player: AnimationPlayer

var _latest_requested_animation: StringName = &""
var _latest_resolved_animation: StringName = &""
var _locomotion_intent: LocomotionIntent = LocomotionIntent.NONE
var _locomotion_phase: LocomotionPhase = LocomotionPhase.NONE
var _walk_clip_name: StringName = &""
var _run_start_clip_name: StringName = &""
var _run_clip_name: StringName = &""
var _locomotion_idle_clip_name: StringName = &""


func _ready() -> void:
	# The state machine moves at the default priority. Presentation samples the
	# completed CharacterBody2D motion afterward.
	process_physics_priority = 1
	bind_npc(get_parent() as Node2D)


func _exit_tree() -> void:
	_reset_playback_speed()
	_disconnect_animation_signals()


func _physics_process(delta: float) -> void:
	_post_movement_animation_update(delta)


func bind_npc(bound_npc: Node2D) -> void:
	_reset_playback_speed()
	_disconnect_animation_signals()
	npc = bound_npc
	animation_player = null
	sprite = null
	_facing_base_scales.clear()
	_facing_tracks_sanitized = false
	_latest_requested_animation = &""
	_latest_resolved_animation = &""
	_locomotion_intent = LocomotionIntent.NONE
	_locomotion_phase = LocomotionPhase.NONE
	_clear_locomotion_clip_cache()
	_resolve_nodes()
	_refresh_locomotion_clip_cache()


func request_animation(requested_name: StringName, required: bool = true) -> bool:
	if requested_name == &"":
		_reject_animation_request()
		return false
	_resolve_nodes()
	if animation_player == null:
		_reject_animation_request()
		if required:
			_warn_missing_animation_player_once(requested_name)
		return false

	if grounded_locomotion_enabled:
		var requested_locomotion_intent := _get_requested_locomotion_intent(requested_name)
		if requested_locomotion_intent != LocomotionIntent.NONE:
			return _accept_locomotion_request(
				requested_name,
				requested_locomotion_intent,
				required
			)

	var resolved_name := resolve_animation_name(requested_name)
	if resolved_name == &"":
		_reject_animation_request()
		if required:
			_warn_missing_animation_once(requested_name)
		return false

	_store_accepted_request(requested_name, resolved_name, LocomotionIntent.NONE)
	_cancel_ground_locomotion_visual()
	if _visual_override_owns_playback():
		return true
	return _play_resolved_animation(resolved_name)


## Plays an authored loop without converting it to idle/run from measured speed.
## This is useful for effort animations such as pushing, bracing, or struggling
## while a constraint keeps the body nearly stationary.
func request_fixed_animation(
	requested_name: StringName,
	required: bool = true
) -> bool:
	if requested_name == &"":
		_reject_animation_request()
		return false
	_resolve_nodes()
	if animation_player == null:
		_reject_animation_request()
		if required:
			_warn_missing_animation_player_once(requested_name)
		return false

	var resolved_name := resolve_animation_name(requested_name)
	if resolved_name == &"":
		_reject_animation_request()
		if required:
			_warn_missing_animation_once(requested_name)
		return false

	_store_accepted_request(requested_name, resolved_name, LocomotionIntent.NONE)
	_cancel_ground_locomotion_visual()
	if _visual_override_owns_playback():
		return true
	return _play_resolved_animation(resolved_name)


func resolve_animation_name(requested_name: StringName) -> StringName:
	_resolve_nodes()
	if animation_player == null or requested_name == &"":
		return &""

	for candidate in _get_animation_candidates(requested_name):
		if animation_player.has_animation(candidate):
			return candidate
	return &""


func face_x_direction(x_direction: float) -> bool:
	if npc == null or not is_instance_valid(npc) or is_zero_approx(x_direction):
		return false
	_resolve_nodes()
	var direction := int(signf(x_direction))
	var accepted := _set_property_if_present(npc, &"direction", direction)

	if sprite != null:
		sprite.flip_h = (
			false
			if _current_animation_forces_unflipped()
			else direction < 0
		)
		accepted = true

	for facing_path in facing_scale_paths:
		var facing_node := npc.get_node_or_null(facing_path) as Node2D
		if facing_node == null:
			continue
		var path_key := String(facing_path)
		if not _facing_base_scales.has(path_key):
			_facing_base_scales[path_key] = Vector2(
				absf(facing_node.scale.x),
				facing_node.scale.y
			)
		var base_scale: Vector2 = _facing_base_scales[path_key]
		facing_node.scale = Vector2(base_scale.x * direction, base_scale.y)
		accepted = true
	return accepted


func get_latest_requested_animation() -> StringName:
	return _latest_requested_animation


func get_locomotion_phase() -> LocomotionPhase:
	return _locomotion_phase


func _post_movement_animation_update(delta: float) -> void:
	if not grounded_locomotion_enabled:
		if _locomotion_phase != LocomotionPhase.NONE:
			_cancel_ground_locomotion_visual()
		return
	if _visual_override_owns_playback():
		return
	if _locomotion_intent == LocomotionIntent.NONE:
		if _locomotion_phase != LocomotionPhase.NONE:
			_cancel_ground_locomotion_visual()
		return
	_update_ground_locomotion(delta, true)


func _accept_locomotion_request(
	requested_name: StringName,
	requested_intent: LocomotionIntent,
	required: bool
) -> bool:
	_refresh_locomotion_clip_cache()
	if _walk_clip_name == &"":
		_reject_animation_request()
		if required:
			_warn_missing_animation_once(walk_animation_name)
		return false

	var resolved_name := _walk_clip_name
	if requested_intent == LocomotionIntent.RUN:
		if _run_clip_name != &"":
			resolved_name = _run_clip_name
		elif required:
			_warn_missing_animation_once(run_animation_name)

	_store_accepted_request(requested_name, resolved_name, requested_intent)
	if _visual_override_owns_playback():
		return true
	return _resume_latest_requested_visual(true)


func _store_accepted_request(
	requested_name: StringName,
	resolved_name: StringName,
	requested_intent: LocomotionIntent
) -> void:
	_latest_requested_animation = requested_name
	_latest_resolved_animation = resolved_name
	_locomotion_intent = requested_intent


func _reject_animation_request() -> void:
	_latest_requested_animation = &""
	_latest_resolved_animation = &""
	_locomotion_intent = LocomotionIntent.NONE
	_cancel_ground_locomotion_visual()


func _resume_latest_requested_visual(allow_run_start: bool = false) -> bool:
	if animation_player == null or _latest_requested_animation == &"":
		_reset_playback_speed()
		return false
	if _visual_override_owns_playback():
		return true
	if grounded_locomotion_enabled and _locomotion_intent != LocomotionIntent.NONE:
		_refresh_locomotion_clip_cache()
		return _update_ground_locomotion(0.0, allow_run_start)

	_cancel_ground_locomotion_visual()
	if _latest_resolved_animation == &"":
		_reset_playback_speed()
		return false
	return _play_resolved_animation(_latest_resolved_animation)


func _update_ground_locomotion(
	_delta: float,
	allow_run_start: bool = true
) -> bool:
	if (
		not grounded_locomotion_enabled
		or _locomotion_intent == LocomotionIntent.NONE
		or animation_player == null
	):
		_cancel_ground_locomotion_visual()
		return false

	var actual_speed := _get_actual_horizontal_speed()
	if actual_speed <= maxf(locomotion_stop_speed, 0.0):
		return _play_locomotion_idle()

	match _locomotion_phase:
		LocomotionPhase.RUN_START:
			_set_run_start_speed_scale(actual_speed)
			return true
		LocomotionPhase.RUN:
			if actual_speed < maxf(run_exit_speed, locomotion_stop_speed):
				return _play_walk(actual_speed)
			return _play_run(actual_speed)
		LocomotionPhase.WALK:
			if actual_speed >= maxf(run_enter_speed, run_exit_speed):
				if allow_run_start and _is_grounded_for_locomotion():
					return _play_run_start(actual_speed)
				return _play_run(actual_speed)
			return _play_walk(actual_speed)
		_:
			# Locomotion becoming active at an already-high speed is not an
			# acceleration transition, so it enters the loop directly.
			if actual_speed >= maxf(run_enter_speed, run_exit_speed):
				return _play_run(actual_speed)
			return _play_walk(actual_speed)


func _play_locomotion_idle() -> bool:
	_locomotion_phase = LocomotionPhase.NONE
	_reset_playback_speed()
	if _locomotion_idle_clip_name == &"":
		_refresh_locomotion_clip_cache()
	if _locomotion_idle_clip_name == &"":
		_warn_missing_animation_once(locomotion_idle_animation_name)
		return false
	return _play_resolved_animation(_locomotion_idle_clip_name)


func _play_walk(actual_speed: float) -> bool:
	if _walk_clip_name == &"":
		_refresh_locomotion_clip_cache()
	if _walk_clip_name == &"":
		_cancel_ground_locomotion_visual()
		_warn_missing_animation_once(walk_animation_name)
		return false

	_locomotion_phase = LocomotionPhase.WALK
	animation_player.speed_scale = _get_clamped_speed_scale(
		actual_speed,
		walk_reference_speed,
		walk_min_speed_scale,
		walk_max_speed_scale
	)
	return _play_resolved_animation(_walk_clip_name)


func _play_run_start(actual_speed: float) -> bool:
	if _run_clip_name == &"":
		_warn_missing_animation_once(run_animation_name)
		return _play_walk(actual_speed)
	if _run_start_clip_name == &"":
		_warn_missing_animation_once(run_start_animation_name)
		return _play_run(actual_speed)

	_locomotion_phase = LocomotionPhase.RUN_START
	_set_run_start_speed_scale(actual_speed)
	return _play_resolved_animation(_run_start_clip_name)


func _play_run(actual_speed: float) -> bool:
	if _run_clip_name == &"":
		_warn_missing_animation_once(run_animation_name)
		return _play_walk(actual_speed)

	_locomotion_phase = LocomotionPhase.RUN
	animation_player.speed_scale = _get_clamped_speed_scale(
		actual_speed,
		run_reference_speed,
		run_min_speed_scale,
		run_max_speed_scale
	)
	return _play_resolved_animation(_run_clip_name)


func _set_run_start_speed_scale(actual_speed: float) -> void:
	if animation_player == null:
		return
	animation_player.speed_scale = _get_clamped_speed_scale(
		actual_speed,
		run_reference_speed,
		run_start_min_speed_scale,
		run_start_max_speed_scale
	)


func _get_clamped_speed_scale(
	actual_speed: float,
	reference_speed: float,
	minimum_scale: float,
	maximum_scale: float
) -> float:
	var safe_reference := maxf(reference_speed, 0.001)
	var safe_minimum := minf(minimum_scale, maximum_scale)
	var safe_maximum := maxf(minimum_scale, maximum_scale)
	return clampf(actual_speed / safe_reference, safe_minimum, safe_maximum)


func _get_actual_horizontal_speed() -> float:
	var body := npc as CharacterBody2D
	if body == null:
		return 0.0
	return absf(body.get_real_velocity().x)


func _is_grounded_for_locomotion() -> bool:
	var body := npc as CharacterBody2D
	return body != null and body.is_on_floor()


func _get_requested_locomotion_intent(requested_name: StringName) -> LocomotionIntent:
	for candidate in _get_animation_candidates(requested_name):
		if candidate == run_animation_name:
			return LocomotionIntent.RUN
		if candidate == walk_animation_name:
			return LocomotionIntent.WALK
	return LocomotionIntent.NONE


func _refresh_locomotion_clip_cache() -> void:
	if animation_player == null:
		_clear_locomotion_clip_cache()
		return
	_walk_clip_name = resolve_animation_name(walk_animation_name)
	_run_start_clip_name = resolve_animation_name(run_start_animation_name)
	_run_clip_name = resolve_animation_name(run_animation_name)
	_locomotion_idle_clip_name = resolve_animation_name(locomotion_idle_animation_name)


func _clear_locomotion_clip_cache() -> void:
	_walk_clip_name = &""
	_run_start_clip_name = &""
	_run_clip_name = &""
	_locomotion_idle_clip_name = &""


func _play_resolved_animation(resolved_name: StringName) -> bool:
	if animation_player == null or resolved_name == &"":
		_reset_playback_speed()
		return false
	if not animation_player.has_animation(resolved_name):
		_reset_playback_speed()
		_warn_missing_animation_once(resolved_name)
		return false
	if sprite != null and _animation_forces_unflipped(resolved_name):
		sprite.flip_h = false
	if (
		animation_player.current_animation == resolved_name
		and animation_player.is_playing()
	):
		return true

	animation_player.play(resolved_name)
	return true


func _current_animation_forces_unflipped() -> bool:
	var displayed_animation := _latest_resolved_animation
	if animation_player != null and animation_player.current_animation != &"":
		displayed_animation = animation_player.current_animation
	return _animation_forces_unflipped(displayed_animation)


func _animation_forces_unflipped(animation_name: StringName) -> bool:
	return (
		animation_name != &""
		and force_unflipped_animation_names.has(String(animation_name))
	)


func _cancel_ground_locomotion_visual() -> void:
	_locomotion_phase = LocomotionPhase.NONE
	_reset_playback_speed()


func _reset_playback_speed() -> void:
	if animation_player != null:
		animation_player.speed_scale = 1.0


func _visual_override_owns_playback() -> bool:
	return false


func _on_animation_finished(finished_animation: StringName) -> void:
	if (
		_locomotion_phase != LocomotionPhase.RUN_START
		or finished_animation != _run_start_clip_name
		or _visual_override_owns_playback()
		or _locomotion_intent == LocomotionIntent.NONE
	):
		return

	var actual_speed := _get_actual_horizontal_speed()
	if actual_speed <= maxf(locomotion_stop_speed, 0.0):
		_play_locomotion_idle()
	elif actual_speed >= maxf(run_exit_speed, locomotion_stop_speed):
		_play_run(actual_speed)
	else:
		_play_walk(actual_speed)


func _resolve_nodes() -> void:
	if npc == null or not is_instance_valid(npc):
		return
	if animation_player == null:
		animation_player = _get_npc_node(animation_player_path, "AnimationPlayer") as AnimationPlayer
	if sprite == null:
		sprite = _get_npc_node(sprite_path, "Sprite2D") as Sprite2D
	if animation_player != null:
		_connect_animation_signals()
		if disable_flip_h_animation_tracks and not _facing_tracks_sanitized:
			_disable_conflicting_facing_tracks()
			_facing_tracks_sanitized = true


func _connect_animation_signals() -> void:
	if animation_player == null or _connected_animation_player == animation_player:
		return
	_disconnect_animation_signals()
	_connected_animation_player = animation_player
	var finished_callable := Callable(self, "_on_animation_finished")
	if not animation_player.animation_finished.is_connected(finished_callable):
		animation_player.animation_finished.connect(finished_callable)


func _disconnect_animation_signals() -> void:
	if _connected_animation_player == null or not is_instance_valid(_connected_animation_player):
		_connected_animation_player = null
		return
	var finished_callable := Callable(self, "_on_animation_finished")
	if _connected_animation_player.animation_finished.is_connected(finished_callable):
		_connected_animation_player.animation_finished.disconnect(finished_callable)
	_connected_animation_player = null


func _get_npc_node(configured_path: NodePath, fallback_name: String) -> Node:
	if String(configured_path) != "":
		return npc.get_node_or_null(configured_path)
	var fallback := npc.get_node_or_null(fallback_name)
	if fallback != null:
		return fallback
	return npc.get_node_or_null("%%%s" % fallback_name)


func _get_animation_candidates(requested_name: StringName) -> Array[StringName]:
	var candidates: Array[StringName] = []
	var alias_key := String(requested_name)
	var alias_value = animation_aliases.get(
		alias_key,
		DEFAULT_ANIMATION_ALIASES.get(alias_key, null)
	)
	if alias_value is Array:
		for value in alias_value:
			_append_animation_candidate(candidates, value)
	elif alias_value is PackedStringArray:
		for value in alias_value:
			_append_animation_candidate(candidates, value)
	elif alias_value != null:
		_append_animation_candidate(candidates, alias_value)
	_append_animation_candidate(candidates, requested_name)
	return candidates


func _append_animation_candidate(candidates: Array[StringName], value) -> void:
	var candidate := StringName(String(value).strip_edges())
	if candidate != &"" and not candidates.has(candidate):
		candidates.append(candidate)


func _disable_conflicting_facing_tracks() -> void:
	var visited_animations: Dictionary = {}
	for animation_name in animation_player.get_animation_list():
		var animation := animation_player.get_animation(animation_name)
		if animation == null:
			continue
		var animation_id := animation.get_instance_id()
		if visited_animations.has(animation_id):
			continue
		visited_animations[animation_id] = true
		for track_index in animation.get_track_count():
			if String(animation.track_get_path(track_index)).ends_with(":flip_h"):
				animation.track_set_enabled(track_index, false)


func _warn_missing_animation_player_once(requested_name: StringName) -> void:
	if _warned_missing_animation_player or not OS.is_debug_build():
		return
	_warned_missing_animation_player = true
	push_warning(
		"NPC animation rejected: npc=%s animation=%s reason=AnimationPlayer_missing"
		% [_get_npc_label(), String(requested_name)]
	)


func _warn_missing_animation_once(requested_name: StringName) -> void:
	var warning_key := String(requested_name)
	if _warned_missing_animations.has(warning_key) or not OS.is_debug_build():
		return
	_warned_missing_animations[warning_key] = true
	push_warning(
		"NPC animation rejected: npc=%s animation=%s reason=clip_missing"
		% [_get_npc_label(), warning_key]
	)


func _get_npc_label() -> String:
	if npc == null or not is_instance_valid(npc):
		return "<missing>"
	if npc.has_method("get_npc_location_id"):
		var npc_id := String(npc.call("get_npc_location_id")).strip_edges()
		if not npc_id.is_empty():
			return "%s(%s)" % [npc.name, npc_id]
	return npc.name


func _set_property_if_present(object: Object, property_name: StringName, value) -> bool:
	if object == null:
		return false
	for property in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			object.set(property_name, value)
			return true
	return false
