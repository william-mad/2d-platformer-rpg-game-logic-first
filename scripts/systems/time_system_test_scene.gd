class_name TimeSystemTestScene extends Node2D

signal time_advanced(time_of_day_hours: float, day_progress: float)

@export_group("Time")
@export_range(1.0, 600.0, 0.1, "suffix:s") var real_seconds_per_day: float = 48.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var start_hour: float = 6.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var sunrise_hour: float = 6.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var sunset_hour: float = 18.0
@export var auto_advance: bool = true

@export_group("Sun Arc")
@export var sun_path: NodePath = ^"Sun"
@export var arc_guide_path: NodePath = ^"SunArcGuide"
@export var dawn_position: Vector2 = Vector2(70.0, 335.0)
@export var dusk_position: Vector2 = Vector2(650.0, 335.0)
@export_range(0.0, 420.0, 1.0, "suffix:px") var arc_height: float = 245.0
@export_range(8.0, 96.0, 1.0, "suffix:px") var sun_radius: float = 30.0
@export_range(12.0, 140.0, 1.0, "suffix:px") var sun_glow_radius: float = 62.0
@export var sun_day_color: Color = Color(1.0, 0.82, 0.28, 1.0)
@export var sun_horizon_color: Color = Color(1.0, 0.38, 0.16, 1.0)
@export var sun_glow_color: Color = Color(1.0, 0.70, 0.20, 0.24)

@export_group("Scene Tint")
@export var sky_path: NodePath = ^"Sky"
@export var horizon_glow_path: NodePath = ^"HorizonGlow"
@export var time_readout_path: NodePath = ^"UILayer/TimePanel/TimeReadout"
@export var day_sky_color: Color = Color(0.28, 0.58, 0.95, 1.0)
@export var dawn_sky_color: Color = Color(0.95, 0.48, 0.30, 1.0)
@export var night_sky_color: Color = Color(0.05, 0.07, 0.17, 1.0)

var elapsed_real_seconds: float = 0.0
var day_count: int = 0

var sun: Node2D
var sun_disc: Polygon2D
var sun_glow: Polygon2D
var arc_guide: Line2D
var sky: Polygon2D
var horizon_glow: Polygon2D
var time_readout: Label


func _ready() -> void:
	_cache_nodes()
	_build_sun_visuals()
	_draw_arc_guide()
	_update_time_visuals()


func _process(delta: float) -> void:
	if auto_advance:
		advance_time(delta)


func advance_time(delta: float) -> void:
	elapsed_real_seconds = maxf(elapsed_real_seconds + delta, 0.0)
	_update_time_visuals()


func set_elapsed_real_seconds(value: float) -> void:
	elapsed_real_seconds = maxf(value, 0.0)
	_update_time_visuals()


func get_time_of_day_hours() -> float:
	return fposmod(start_hour + (elapsed_real_seconds / _safe_real_seconds_per_day()) * 24.0, 24.0)


func get_day_progress() -> float:
	return get_time_of_day_hours() / 24.0


func _cache_nodes() -> void:
	sun = get_node_or_null(sun_path) as Node2D
	arc_guide = get_node_or_null(arc_guide_path) as Line2D
	sky = get_node_or_null(sky_path) as Polygon2D
	horizon_glow = get_node_or_null(horizon_glow_path) as Polygon2D
	time_readout = get_node_or_null(time_readout_path) as Label

	if sun == null:
		return

	sun_disc = sun.get_node_or_null("SunDisc") as Polygon2D
	sun_glow = sun.get_node_or_null("SunGlow") as Polygon2D


func _build_sun_visuals() -> void:
	if sun_disc != null:
		sun_disc.polygon = _make_circle_polygon(sun_radius, 48)
		sun_disc.color = sun_day_color

	if sun_glow != null:
		sun_glow.polygon = _make_circle_polygon(sun_glow_radius, 64)
		sun_glow.color = sun_glow_color


func _draw_arc_guide() -> void:
	if arc_guide == null:
		return

	arc_guide.clear_points()

	var point_count := 25
	for index in range(point_count):
		var progress := float(index) / float(point_count - 1)
		arc_guide.add_point(_get_daylight_arc_position(progress))


func _update_time_visuals() -> void:
	var total_days := start_hour / 24.0 + elapsed_real_seconds / _safe_real_seconds_per_day()
	day_count = int(floor(total_days))

	var time_of_day := get_time_of_day_hours()
	var daylight := _is_daylight_hour(time_of_day)
	var daylight_progress := _get_daylight_progress(time_of_day)

	_update_sun(daylight, daylight_progress, time_of_day)
	_update_sky(daylight, daylight_progress, time_of_day)
	_update_readout(daylight, daylight_progress, time_of_day)

	time_advanced.emit(time_of_day, get_day_progress())


func _update_sun(daylight: bool, daylight_progress: float, time_of_day: float) -> void:
	if sun == null:
		return

	if daylight:
		var noon_strength := sin(daylight_progress * PI)
		sun.visible = true
		sun.position = _get_daylight_arc_position(daylight_progress)

		if sun_disc != null:
			sun_disc.color = sun_horizon_color.lerp(sun_day_color, noon_strength)

		if sun_glow != null:
			var glow_alpha := lerpf(0.18, sun_glow_color.a, noon_strength)
			sun_glow.color = Color(sun_glow_color.r, sun_glow_color.g, sun_glow_color.b, glow_alpha)
	else:
		sun.visible = false
		sun.position = _get_night_arc_position(_get_night_progress(time_of_day))


func _update_sky(daylight: bool, daylight_progress: float, time_of_day: float) -> void:
	var sky_color := night_sky_color
	var horizon_alpha := 0.0

	if daylight:
		var noon_strength := sin(daylight_progress * PI)
		sky_color = dawn_sky_color.lerp(day_sky_color, noon_strength)
		horizon_alpha = lerpf(0.42, 0.12, noon_strength)
	else:
		var night_progress := _get_night_progress(time_of_day)
		var sunset_fade := 1.0 - clampf(night_progress / 0.14, 0.0, 1.0)
		var sunrise_fade := clampf((night_progress - 0.86) / 0.14, 0.0, 1.0)
		var rim_strength := maxf(sunset_fade, sunrise_fade)
		sky_color = night_sky_color.lerp(dawn_sky_color, rim_strength * 0.5)
		horizon_alpha = rim_strength * 0.26

	if sky != null:
		sky.color = sky_color

	if horizon_glow != null:
		horizon_glow.color = Color(sun_horizon_color.r, sun_horizon_color.g, sun_horizon_color.b, horizon_alpha)


func _update_readout(daylight: bool, daylight_progress: float, time_of_day: float) -> void:
	if time_readout == null:
		return

	var total_minutes := int(floor(time_of_day * 60.0)) % (24 * 60)
	var hour := int(total_minutes / 60)
	var minute := int(total_minutes % 60)
	var sun_line := "sun: %.0f%% daylight arc" % (daylight_progress * 100.0)

	if not daylight:
		sun_line = "sun: below horizon"

	time_readout.text = "\n".join([
		"Time System Test",
		"day: %d" % day_count,
		"time: %02d:%02d" % [hour, minute],
		"elapsed: %.1fs" % elapsed_real_seconds,
		sun_line,
	])


func _get_daylight_arc_position(progress: float) -> Vector2:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	var x := lerpf(dawn_position.x, dusk_position.x, clamped_progress)
	var baseline_y := lerpf(dawn_position.y, dusk_position.y, clamped_progress)
	var y := baseline_y - sin(clamped_progress * PI) * arc_height

	return Vector2(x, y)


func _get_night_arc_position(progress: float) -> Vector2:
	var clamped_progress := clampf(progress, 0.0, 1.0)
	var x := lerpf(dusk_position.x, dawn_position.x, clamped_progress)
	var below_horizon_y := maxf(dawn_position.y, dusk_position.y) + sun_glow_radius + 52.0
	var y := below_horizon_y + sin(clamped_progress * PI) * 70.0

	return Vector2(x, y)


func _get_daylight_progress(time_of_day: float) -> float:
	return clampf(fposmod(time_of_day - sunrise_hour, 24.0) / _daylight_length_hours(), 0.0, 1.0)


func _get_night_progress(time_of_day: float) -> float:
	var night_length := maxf(24.0 - _daylight_length_hours(), 0.001)

	return clampf(fposmod(time_of_day - sunset_hour, 24.0) / night_length, 0.0, 1.0)


func _is_daylight_hour(time_of_day: float) -> bool:
	var daylight_length := _daylight_length_hours()
	if daylight_length >= 24.0:
		return true

	return fposmod(time_of_day - sunrise_hour, 24.0) <= daylight_length


func _daylight_length_hours() -> float:
	var length := fposmod(sunset_hour - sunrise_hour, 24.0)
	if is_zero_approx(length):
		return 24.0

	return length


func _safe_real_seconds_per_day() -> float:
	return maxf(real_seconds_per_day, 0.001)


func _make_circle_polygon(radius: float, segments: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	var safe_segments := maxi(segments, 3)

	for index in range(safe_segments):
		var angle := TAU * float(index) / float(safe_segments)
		points.append(Vector2(cos(angle), sin(angle)) * radius)

	return points
