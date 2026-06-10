class_name RealTest1TimeView extends Node2D

@export_group("World Time")
@export var use_world_time: bool = true
@export var poll_world_time_visuals: bool = true
@export_range(0.0, 5.0, 0.05, "suffix:s") var world_time_poll_seconds: float = 0.25

@export_group("Sun")
@export var sun_path_node_path: NodePath = ^"SunPath"
@export var sun_follow_path: NodePath = ^"SunPath/SunFollow"
@export var sun_disc_path: NodePath = ^"SunPath/SunFollow/SunDisc"
@export var sun_glow_path: NodePath = ^"SunPath/SunFollow/SunGlow"
@export var dawn_position: Vector2 = Vector2(-260.0, 145.0)
@export var dusk_position: Vector2 = Vector2(420.0, 145.0)
@export_range(0.0, 420.0, 1.0, "suffix:px") var arc_height: float = 180.0
@export_range(3, 80, 1) var arc_samples: int = 32
@export_range(8.0, 96.0, 1.0, "suffix:px") var sun_radius: float = 28.0
@export_range(12.0, 160.0, 1.0, "suffix:px") var sun_glow_radius: float = 70.0
@export var sun_day_color: Color = Color(1.0, 0.85, 0.32, 1.0)
@export var sun_horizon_color: Color = Color(1.0, 0.43, 0.18, 1.0)
@export var sun_glow_color: Color = Color(1.0, 0.68, 0.16, 0.28)

@export_group("Scene Gradient")
@export var gradient_overlay_path: NodePath = ^"TimeGradientLayer/GradientOverlay"
@export var day_top_color: Color = Color(0.35, 0.62, 1.0, 0.10)
@export var day_bottom_color: Color = Color(1.0, 0.96, 0.66, 0.08)
@export var dawn_top_color: Color = Color(1.0, 0.45, 0.22, 0.18)
@export var dawn_bottom_color: Color = Color(1.0, 0.77, 0.31, 0.12)
@export var night_top_color: Color = Color(0.02, 0.04, 0.16, 0.44)
@export var night_bottom_color: Color = Color(0.07, 0.10, 0.24, 0.30)
@export var horizon_glow_color: Color = Color(1.0, 0.62, 0.22, 0.11)

var sun_path: Path2D
var sun_follow: PathFollow2D
var sun_disc: Polygon2D
var sun_glow: Polygon2D
var gradient_overlay: ColorRect
var gradient_material: ShaderMaterial
var world_time_poll_timer: float = 0.0


func _ready() -> void:
	_cache_nodes()
	_build_sun_path()
	_build_sun_visuals()
	_build_gradient_overlay()
	_connect_world_time()
	_update_from_current_time()
	set_process(use_world_time and poll_world_time_visuals)


func _process(delta: float) -> void:
	if not use_world_time or not poll_world_time_visuals:
		set_process(false)
		return

	if not has_node("/root/WorldTime"):
		return

	world_time_poll_timer -= delta
	if world_time_poll_seconds > 0.0 and world_time_poll_timer > 0.0:
		return

	world_time_poll_timer = world_time_poll_seconds
	_update_from_time_snapshot(WorldTime.get_snapshot())


func _cache_nodes() -> void:
	sun_path = get_node_or_null(sun_path_node_path) as Path2D
	sun_follow = get_node_or_null(sun_follow_path) as PathFollow2D
	sun_disc = get_node_or_null(sun_disc_path) as Polygon2D
	sun_glow = get_node_or_null(sun_glow_path) as Polygon2D
	gradient_overlay = get_node_or_null(gradient_overlay_path) as ColorRect


func _build_sun_path() -> void:
	if sun_path == null:
		return

	var curve := Curve2D.new()
	var safe_samples := maxi(arc_samples, 3)
	for index in range(safe_samples):
		var progress := float(index) / float(safe_samples - 1)
		curve.add_point(_get_sun_arc_position(progress))

	sun_path.curve = curve


func _build_sun_visuals() -> void:
	if sun_disc != null:
		sun_disc.polygon = _make_circle_polygon(sun_radius, 48)
		sun_disc.color = sun_day_color

	if sun_glow != null:
		sun_glow.polygon = _make_circle_polygon(sun_glow_radius, 64)
		sun_glow.color = sun_glow_color


func _build_gradient_overlay() -> void:
	if gradient_overlay == null:
		return

	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;

uniform vec4 top_color : source_color = vec4(0.35, 0.62, 1.0, 0.10);
uniform vec4 bottom_color : source_color = vec4(1.0, 0.96, 0.66, 0.08);
uniform vec4 horizon_color : source_color = vec4(1.0, 0.62, 0.22, 0.18);
uniform float horizon_strength = 0.0;
uniform float horizon_y = 0.72;

void fragment() {
	float y = clamp(UV.y, 0.0, 1.0);
	float blend = smoothstep(0.0, 1.0, y);
	vec4 base_color = mix(top_color, bottom_color, blend);
	float horizon_band = 1.0 - smoothstep(0.0, 0.42, abs(y - horizon_y));
	vec4 horizon_mix = horizon_color * horizon_band * horizon_strength;
	COLOR = vec4(
		mix(base_color.rgb, horizon_color.rgb, horizon_band * horizon_strength),
		clamp(base_color.a + horizon_mix.a, 0.0, 1.0)
	);
}
"""
	gradient_material = ShaderMaterial.new()
	gradient_material.shader = shader
	gradient_overlay.material = gradient_material


func _connect_world_time() -> void:
	if not use_world_time or not has_node("/root/WorldTime"):
		return

	var callback := Callable(self, "_on_world_time_changed")
	if not WorldTime.time_changed.is_connected(callback):
		WorldTime.time_changed.connect(callback)


func _update_from_current_time() -> void:
	if use_world_time and has_node("/root/WorldTime"):
		_update_from_time_snapshot(WorldTime.get_snapshot())
		return

	_update_from_time_snapshot({
		"is_daylight": true,
		"daylight_progress": 0.0,
		"period": &"dawn",
	})


func _on_world_time_changed(snapshot: Dictionary) -> void:
	_update_from_time_snapshot(snapshot)


func _update_from_time_snapshot(snapshot: Dictionary) -> void:
	var daylight_progress := float(snapshot.get("daylight_progress", 0.0))
	var night_progress := float(snapshot.get("night_progress", 0.0))
	var is_daylight := bool(snapshot.get("is_daylight", true))
	var noon_strength := sin(clampf(daylight_progress, 0.0, 1.0) * PI)

	_update_sun(is_daylight, daylight_progress, noon_strength)
	_update_gradient(StringName(snapshot.get("period", &"day")), noon_strength, is_daylight, night_progress)


func _update_sun(is_daylight: bool, daylight_progress: float, noon_strength: float) -> void:
	if sun_follow == null:
		return

	sun_follow.visible = is_daylight
	sun_follow.progress_ratio = clampf(daylight_progress, 0.0, 1.0)

	if sun_disc != null:
		sun_disc.color = sun_horizon_color.lerp(sun_day_color, noon_strength)

	if sun_glow != null:
		var glow_alpha := lerpf(0.16, sun_glow_color.a, noon_strength)
		sun_glow.color = Color(sun_glow_color.r, sun_glow_color.g, sun_glow_color.b, glow_alpha)


func _update_gradient(
	period: StringName,
	noon_strength: float,
	is_daylight: bool,
	night_progress: float
) -> void:
	if gradient_material == null:
		return

	var top_color := night_top_color
	var bottom_color := night_bottom_color
	var horizon_strength := 0.0

	if is_daylight:
		var horizon_mix := 1.0 - noon_strength
		top_color = day_top_color.lerp(dawn_top_color, horizon_mix)
		bottom_color = day_bottom_color.lerp(dawn_bottom_color, horizon_mix)
		horizon_strength = horizon_mix * 0.85
	elif period == &"night":
		top_color = night_top_color
		bottom_color = night_bottom_color
		var night_edge_strength := maxf(
			1.0 - clampf(night_progress / 0.16, 0.0, 1.0),
			clampf((night_progress - 0.84) / 0.16, 0.0, 1.0)
		)
		horizon_strength = night_edge_strength * 0.45

	gradient_material.set_shader_parameter("top_color", top_color)
	gradient_material.set_shader_parameter("bottom_color", bottom_color)
	gradient_material.set_shader_parameter("horizon_color", horizon_glow_color)
	gradient_material.set_shader_parameter("horizon_strength", horizon_strength)


func _get_sun_arc_position(progress: float) -> Vector2:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	var x := lerpf(dawn_position.x, dusk_position.x, clamped_progress)
	var baseline_y := lerpf(dawn_position.y, dusk_position.y, clamped_progress)
	var y := baseline_y - sin(clamped_progress * PI) * arc_height
	return Vector2(x, y)


func _make_circle_polygon(radius: float, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	var safe_segments := maxi(segments, 3)

	for index in range(safe_segments):
		var angle := TAU * float(index) / float(safe_segments)
		points.append(Vector2(cos(angle), sin(angle)) * radius)

	return points
