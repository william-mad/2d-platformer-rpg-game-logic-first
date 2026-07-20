extends Node

@export var blackouts_path: NodePath = NodePath("../RoomBlackouts")

const CHARACTER_GROUPS: Array[StringName] = [&"player", &"npc", &"social_npc"]

var _tracked_sprites: Dictionary = {}
@onready var _blackouts := get_node_or_null(blackouts_path) as Node2D


func _process(_delta: float) -> void:
	if _blackouts == null:
		return
	_prune_freed_sprites()
	var visited_characters: Dictionary = {}
	for group_name in CHARACTER_GROUPS:
		for candidate in get_tree().get_nodes_in_group(group_name):
			var character := candidate as Node2D
			if character == null or not get_parent().is_ancestor_of(character):
				continue
			var character_id := character.get_instance_id()
			if visited_characters.has(character_id):
				continue
			visited_characters[character_id] = true
			# Sample just above the feet so a character standing exactly on a shared
			# floor edge belongs to the room they occupy, not the floor below.
			var visibility_sample := character.global_position + Vector2.UP * 0.5
			var should_be_black := _position_is_blacked_out(visibility_sample)
			var sprites: Array[CanvasItem] = []
			_collect_character_sprites(character, sprites)
			for sprite in sprites:
				_set_sprite_blackened(sprite, should_be_black)


func _exit_tree() -> void:
	for entry in _tracked_sprites.values():
		_restore_tracked_sprite(entry)
	_tracked_sprites.clear()


func _position_is_blacked_out(global_position: Vector2) -> bool:
	for child in _blackouts.get_children():
		var blackout := child as Polygon2D
		if blackout == null or not blackout.is_visible_in_tree():
			continue
		var local_position := blackout.to_local(global_position)
		if Geometry2D.is_point_in_polygon(local_position, blackout.polygon):
			return true
	return false


func _collect_character_sprites(root: Node, output: Array[CanvasItem]) -> void:
	for child in root.get_children():
		if child is Sprite2D or child is AnimatedSprite2D:
			output.append(child as CanvasItem)
		_collect_character_sprites(child, output)


func _set_sprite_blackened(sprite: CanvasItem, blackened: bool) -> void:
	if sprite == null or not is_instance_valid(sprite):
		return
	var sprite_id := sprite.get_instance_id()
	var entry: Dictionary = _tracked_sprites.get(sprite_id, {})
	if entry.is_empty():
		entry = {
			"sprite": weakref(sprite),
			"original_self_modulate": sprite.self_modulate,
			"blackened": false,
		}
	if blackened:
		if not bool(entry.get("blackened", false)):
			entry["original_self_modulate"] = sprite.self_modulate
		var original_color: Color = entry["original_self_modulate"]
		sprite.self_modulate = Color(0.0, 0.0, 0.0, original_color.a)
		entry["blackened"] = true
	elif bool(entry.get("blackened", false)):
		sprite.self_modulate = entry["original_self_modulate"]
		entry["blackened"] = false
	else:
		entry["original_self_modulate"] = sprite.self_modulate
	_tracked_sprites[sprite_id] = entry


func _prune_freed_sprites() -> void:
	for sprite_id in _tracked_sprites.keys():
		var entry: Dictionary = _tracked_sprites[sprite_id]
		var sprite_reference := entry.get("sprite") as WeakRef
		if sprite_reference == null or sprite_reference.get_ref() == null:
			_tracked_sprites.erase(sprite_id)


func _restore_tracked_sprite(entry: Dictionary) -> void:
	if not bool(entry.get("blackened", false)):
		return
	var sprite_reference := entry.get("sprite") as WeakRef
	if sprite_reference == null:
		return
	var sprite := sprite_reference.get_ref() as CanvasItem
	if sprite != null and is_instance_valid(sprite):
		sprite.self_modulate = entry.get("original_self_modulate", Color.WHITE)
