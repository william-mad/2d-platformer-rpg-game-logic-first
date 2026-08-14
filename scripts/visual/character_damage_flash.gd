class_name CharacterDamageFlash extends RefCounted

const DAMAGE_FLASH_SHADER: Shader = preload(
	"res://scripts/visual/character_damage_flash.gdshader"
)

var _tween: Tween
var _entries: Array[Dictionary] = []


func play(
	host: Node,
	visuals: Array[CanvasItem],
	peak_color: Color,
	fade_color: Color,
	peak_seconds: float,
	fade_seconds: float
) -> void:
	stop()
	if host == null or not is_instance_valid(host) or not host.is_inside_tree():
		return

	for visual: CanvasItem in visuals:
		if visual == null or not is_instance_valid(visual):
			continue
		var flash_material := ShaderMaterial.new()
		flash_material.shader = DAMAGE_FLASH_SHADER
		_entries.append({
			"visual": weakref(visual),
			"original_material": visual.material,
			"flash_material": flash_material,
		})
		visual.material = flash_material

	if _entries.is_empty():
		return

	_set_parameter(&"flash_color", peak_color)
	_set_parameter(&"flash_strength", 1.0)
	_tween = host.create_tween()
	_tween.tween_method(
		Callable(self, "_set_color"),
		peak_color,
		fade_color,
		maxf(peak_seconds, 0.01)
	)
	_tween.tween_method(
		Callable(self, "_set_strength"),
		1.0,
		0.0,
		maxf(fade_seconds, 0.01)
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(Callable(self, "_finish"))


func stop() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	_restore_materials()


func _set_color(color: Color) -> void:
	_set_parameter(&"flash_color", color)


func _set_strength(strength: float) -> void:
	_set_parameter(&"flash_strength", clampf(strength, 0.0, 1.0))


func _set_parameter(parameter_name: StringName, value: Variant) -> void:
	for entry: Dictionary in _entries:
		var flash_material := entry.get("flash_material") as ShaderMaterial
		if flash_material != null:
			flash_material.set_shader_parameter(parameter_name, value)


func _finish() -> void:
	_tween = null
	_restore_materials()


func _restore_materials() -> void:
	for entry: Dictionary in _entries:
		var visual_reference := entry.get("visual") as WeakRef
		var visual := visual_reference.get_ref() as CanvasItem if visual_reference != null else null
		var flash_material := entry.get("flash_material") as ShaderMaterial
		if (
			visual != null
			and is_instance_valid(visual)
			and visual.material == flash_material
		):
			visual.material = entry.get("original_material") as Material
	_entries.clear()
