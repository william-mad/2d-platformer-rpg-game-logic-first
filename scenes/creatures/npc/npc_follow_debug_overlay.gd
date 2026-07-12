class_name NpcFollowDebugOverlay
extends Node2D

var follower: CharacterBody2D
var recorder: PlayerBreadcrumbRecorder
var target_position: Vector2
var has_target: bool = false
var active_traversal: Dictionary = {}
var committed_plan: Dictionary = {}
var reposition_plan: Dictionary = {}
var give_up_target: Vector2 = Vector2.INF
var phase_label: String = "FOLLOWING"
var gravity_strength: float = 1200.0
var maximum_breadcrumbs: int = 40


func configure(character: CharacterBody2D, breadcrumb_recorder: PlayerBreadcrumbRecorder) -> void:
	follower = character
	recorder = breadcrumb_recorder
	top_level = true
	global_position = Vector2.ZERO
	z_index = 500
	queue_redraw()


func update_state(
	current_target: Vector2,
	target_valid: bool,
	traversal: Dictionary,
	plan: Dictionary,
	reposition: Dictionary,
	abandoned_target: Vector2,
	state_label: String,
	gravity_value: float
) -> void:
	target_position = current_target
	has_target = target_valid
	active_traversal = traversal.duplicate(true)
	committed_plan = plan.duplicate(true)
	reposition_plan = reposition.duplicate(true)
	give_up_target = abandoned_target
	phase_label = state_label
	gravity_strength = gravity_value
	queue_redraw()


func _draw() -> void:
	if follower == null or not is_instance_valid(follower):
		return
	_draw_breadcrumb_history()
	if has_target:
		draw_line(follower.global_position, target_position, Color(0.2, 1.0, 0.25, 0.9), 3.0)
		draw_circle(target_position, 8.0, Color(0.2, 1.0, 0.25, 0.95))
		draw_string(ThemeDB.fallback_font, target_position + Vector2(10.0, -8.0), "TARGET", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, Color.WHITE)
	_draw_active_traversal()
	_draw_committed_plan()
	_draw_reposition()
	if give_up_target != Vector2.INF:
		draw_circle(give_up_target, 11.0, Color(1.0, 0.1, 0.1, 0.75), false, 3.0)
		draw_line(give_up_target + Vector2(-8.0, -8.0), give_up_target + Vector2(8.0, 8.0), Color.RED, 3.0)
		draw_line(give_up_target + Vector2(-8.0, 8.0), give_up_target + Vector2(8.0, -8.0), Color.RED, 3.0)
	draw_string(
		ThemeDB.fallback_font,
		follower.global_position + Vector2(-50.0, -86.0),
		phase_label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		15,
		Color(1.0, 1.0, 1.0, 0.95)
	)


func _draw_breadcrumb_history() -> void:
	if recorder == null or not is_instance_valid(recorder):
		return
	var breadcrumbs := recorder.get_debug_breadcrumbs(maximum_breadcrumbs)
	# Recorder retains only the newest grounded point and newest completed
	# traversal. Traversals are drawn as arcs, never as straight history chords.
	for index in range(breadcrumbs.size() - 1, -1, -1):
		var breadcrumb: Dictionary = breadcrumbs[index]
		var position: Vector2 = breadcrumb.get("position", Vector2.ZERO)
		if bool(breadcrumb.get("completed_traversal", false)):
			var takeoff: Vector2 = breadcrumb.get("takeoff_position", position)
			var landing: Vector2 = breadcrumb.get("landing_position", position)
			_draw_traversal_curve(
				takeoff,
				landing,
				float(breadcrumb.get("peak_height", 24.0)),
				Color(1.0, 0.55, 0.05, 0.8),
				3.0
			)
			draw_circle(takeoff, 6.0, Color(1.0, 0.85, 0.1, 0.95))
			draw_circle(landing, 7.0, Color(1.0, 0.25, 0.8, 0.95))
		else:
			draw_circle(position, 3.5, Color(0.15, 0.65, 1.0, 0.8))


func _draw_active_traversal() -> void:
	if active_traversal.is_empty():
		return
	var takeoff: Vector2 = active_traversal.get("takeoff_position", Vector2.ZERO)
	var landing: Vector2 = active_traversal.get("landing_position", target_position)
	_draw_traversal_curve(
		takeoff,
		landing,
		float(active_traversal.get("peak_height", 24.0)),
		Color(1.0, 0.75, 0.0, 1.0),
		4.0
	)
	draw_string(ThemeDB.fallback_font, takeoff + Vector2(8.0, -8.0), "TAKEOFF", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color(1.0, 0.9, 0.2))
	draw_string(ThemeDB.fallback_font, landing + Vector2(8.0, 16.0), "PLAYER LANDING", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color(1.0, 0.35, 0.8))


func _draw_committed_plan() -> void:
	if committed_plan.is_empty():
		return
	var takeoff: Vector2 = committed_plan.get("takeoff_position", follower.global_position)
	var landing: Vector2 = committed_plan.get("landing_position", target_position)
	var velocity: Vector2 = committed_plan.get("velocity", Vector2.ZERO)
	var flight_time := float(committed_plan.get("flight_time", 0.0))
	draw_circle(takeoff, 9.0, Color(1.0, 1.0, 0.1, 0.9), false, 3.0)
	draw_circle(landing, 10.0, Color(0.95, 0.1, 0.95, 0.9), false, 3.0)
	if flight_time <= 0.0:
		return
	var previous := takeoff
	for sample_index in range(1, 13):
		var time := flight_time * (float(sample_index) / 12.0)
		var point := takeoff + velocity * time + Vector2(0.0, 0.5 * gravity_strength * time * time)
		draw_line(previous, point, Color(1.0, 0.1, 1.0, 0.95), 3.0)
		draw_circle(point, 2.5, Color.WHITE)
		previous = point


func _draw_reposition() -> void:
	if reposition_plan.is_empty():
		return
	var position: Vector2 = reposition_plan.get("position", follower.global_position)
	draw_dashed_line(follower.global_position, position, Color(0.1, 1.0, 1.0, 0.9), 3.0, 10.0)
	draw_circle(position, 9.0, Color(0.1, 1.0, 1.0, 0.9), false, 3.0)
	draw_string(ThemeDB.fallback_font, position + Vector2(10.0, -8.0), "REPOSITION", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color(0.2, 1.0, 1.0))


func _draw_traversal_curve(
	takeoff: Vector2,
	landing: Vector2,
	peak_height: float,
	color: Color,
	width: float
) -> void:
	var apex_y := minf(takeoff.y, landing.y) - maxf(peak_height, 24.0)
	var control := Vector2(
		(takeoff.x + landing.x) * 0.5,
		2.0 * apex_y - 0.5 * (takeoff.y + landing.y)
	)
	var previous := takeoff
	for sample_index in range(1, 17):
		var weight := float(sample_index) / 16.0
		var inverse := 1.0 - weight
		var point := (
			inverse * inverse * takeoff
			+ 2.0 * inverse * weight * control
			+ weight * weight * landing
		)
		draw_line(previous, point, color, width)
		previous = point
