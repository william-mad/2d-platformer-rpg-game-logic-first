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

@export_group("Nodes")
@export var animation_player_path: NodePath
@export var sprite_path: NodePath
@export var facing_scale_paths: Array[NodePath] = [NodePath("SightPivot")]

@export_group("Resolution")
@export var animation_aliases: Dictionary = {}
@export var disable_flip_h_animation_tracks: bool = true

var npc: Node2D
var animation_player: AnimationPlayer
var sprite: Sprite2D

var _warned_missing_animation_player: bool = false
var _warned_missing_animations: Dictionary = {}
var _facing_base_scales: Dictionary = {}
var _facing_tracks_sanitized: bool = false


func _ready() -> void:
	bind_npc(get_parent() as Node2D)


func bind_npc(bound_npc: Node2D) -> void:
	npc = bound_npc
	animation_player = null
	sprite = null
	_facing_base_scales.clear()
	_facing_tracks_sanitized = false
	_resolve_nodes()


func request_animation(requested_name: StringName, required: bool = true) -> bool:
	if requested_name == &"":
		return false
	_resolve_nodes()
	if animation_player == null:
		if required:
			_warn_missing_animation_player_once(requested_name)
		return false

	var resolved_name := resolve_animation_name(requested_name)
	if resolved_name == &"":
		if required:
			_warn_missing_animation_once(requested_name)
		return false
	if animation_player.current_animation == resolved_name and animation_player.is_playing():
		return true

	animation_player.play(resolved_name)
	return true


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
		sprite.flip_h = direction < 0
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


func _resolve_nodes() -> void:
	if npc == null or not is_instance_valid(npc):
		return
	if animation_player == null:
		animation_player = _get_npc_node(animation_player_path, "AnimationPlayer") as AnimationPlayer
	if sprite == null:
		sprite = _get_npc_node(sprite_path, "Sprite2D") as Sprite2D
	if animation_player != null and disable_flip_h_animation_tracks and not _facing_tracks_sanitized:
		_disable_conflicting_facing_tracks()
		_facing_tracks_sanitized = true


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
