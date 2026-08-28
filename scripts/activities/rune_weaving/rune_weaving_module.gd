class_name RuneWeavingModule
extends InteractiveActivityModule

const TARGET_NEUTRAL_COLOR := Color(0.35, 0.62, 0.95, 0.9)
const TARGET_ACTIVE_COLOR := Color(1.0, 0.78, 0.28, 1.0)
const TARGET_COMPLETED_COLOR := Color(0.3, 0.95, 0.62, 1.0)
const TARGET_GLOW_COLOR := Color(0.42, 0.7, 1.0, 0.24)
const FEEDBACK_NORMAL_COLOR := Color(0.74, 0.9, 1.0, 1.0)
const FEEDBACK_SUCCESS_COLOR := Color(0.42, 1.0, 0.66, 1.0)
const FEEDBACK_MISTAKE_COLOR := Color(1.0, 0.42, 0.52, 1.0)

@export var default_config: RuneWeavingConfig

var config: RuneWeavingConfig
var completed_runes: int = 0
var total_correct_nodes: int = 0
var total_mistakes: int = 0
var current_streak: int = 0
var best_streak: int = 0
var fastest_rune_completion: float = 0.0
var highest_node_count_reached: int = 0
var _configured: bool = false
var _preview_active: bool = false
var _preview_remaining: float = 0.0
var _sequence_hidden_after_preview: bool = false
var _round_transition_active: bool = false
var _round_transition_remaining: float = 0.0
var _rune_elapsed: float = 0.0
var _rune_had_mistake: bool = false
var _feedback_remaining: float = 0.0
var _current_targets: PackedVector2Array = PackedVector2Array()
var _target_visual_nodes: Array[Node2D] = []
var _last_published_signature: String = ""
var _session_seed: int = 0
var _rng := RandomNumberGenerator.new()

@onready var field_background: ColorRect = %FieldBackground
@onready var preview_line: Line2D = %PreviewLine
@onready var completed_line: Line2D = %CompletedLine
@onready var target_visuals: Node2D = %TargetVisuals
@onready var cursor: ActivityCursor = %ActivityCursor
@onready var target_controller: SequentialTargetController = %SequentialTargetController
@onready var preview_label: Label = %PreviewLabel
@onready var progress_label: Label = %ProgressLabel
@onready var streak_label: Label = %StreakLabel
@onready var score_label: Label = %ScoreLabel
@onready var feedback_label: Label = %FeedbackLabel


func _ready() -> void:
	target_controller.target_activated.connect(_on_target_activated)
	target_controller.incorrect_activation.connect(_on_incorrect_activation)
	target_controller.sequence_completed.connect(_on_sequence_completed)


func configure(
	context: Dictionary,
	input_source: InteractiveActivityInputSource
) -> bool:
	if not super.configure(context, input_source):
		return false
	var supplied_config := context.get("module_config") as RuneWeavingConfig
	config = supplied_config if supplied_config != null else default_config
	if config == null or not config.is_valid_config():
		return false
	if not cursor.configure(config.get_cursor_config()):
		return false
	cursor.set_input_source(input_source)
	cursor.set_movement_bounds(config.get_cursor_bounds())
	_configure_field_visuals()
	_session_seed = hash(String(context.get("session_id", "")))
	_configured = true
	_reset_runtime_state()
	_sync_result(false)
	return true


func start_activity() -> void:
	if not _configured or _stopped or _running:
		return
	_reset_runtime_state()
	cursor.set_movement_enabled(true)
	super.start_activity()
	_sync_result(false)


func stop_activity(reason: StringName) -> Dictionary:
	if _stopped:
		return get_result()
	cursor.set_movement_enabled(false)
	_sync_result(false)
	return super.stop_activity(reason)


func get_activity_cursor() -> ActivityCursor:
	return cursor


func get_target_controller() -> SequentialTargetController:
	return target_controller


func get_current_targets() -> PackedVector2Array:
	return PackedVector2Array(_current_targets)


func is_preview_active() -> bool:
	return _preview_active


func is_sequence_hidden() -> bool:
	return _sequence_hidden_after_preview and not _preview_active


func _physics_process(delta: float) -> void:
	if not _running or not _configured:
		return
	var safe_delta := maxf(delta, 0.0)
	_update_feedback_timer(safe_delta)
	_update_cursor_guidance(safe_delta)

	if _round_transition_active:
		_round_transition_remaining -= safe_delta
		if _round_transition_remaining <= 0.0:
			_begin_next_rune()
		_sync_result(true)
		return

	if _preview_active:
		_preview_remaining -= safe_delta
		if _preview_remaining <= 0.0:
			_preview_active = false
			_update_sequence_visibility()
			_show_feedback("Weave the remembered path", FEEDBACK_NORMAL_COLOR)
		_sync_result(true)
		return

	_rune_elapsed += safe_delta
	if activity_input != null and activity_input.was_role_pressed(&"confirm"):
		_result["attempts"] = int(_result.get("attempts", 0)) + 1
		target_controller.try_activate(cursor.get_cursor_position())
	_sync_result(true)


func _reset_runtime_state() -> void:
	_rng.seed = _session_seed
	completed_runes = 0
	total_correct_nodes = 0
	total_mistakes = 0
	current_streak = 0
	best_streak = 0
	fastest_rune_completion = 0.0
	highest_node_count_reached = 0
	_round_transition_active = false
	_round_transition_remaining = 0.0
	_feedback_remaining = 0.0
	_result["score"] = 0.0
	_result["attempts"] = 0
	_result["successes"] = 0
	_result["failures"] = 0
	_result["elapsed_seconds"] = 0.0
	_last_published_signature = ""
	cursor.reset_cursor(Vector2.ZERO)
	_begin_next_rune()


func _begin_next_rune() -> void:
	_round_transition_active = false
	_round_transition_remaining = 0.0
	_rune_elapsed = 0.0
	_rune_had_mistake = false
	var node_count := config.get_node_count(completed_runes)
	highest_node_count_reached = maxi(highest_node_count_reached, node_count)
	_current_targets = _generate_pattern(node_count)
	if not target_controller.configure(_current_targets, config.activation_radius):
		return
	_preview_remaining = config.get_preview_duration(completed_runes)
	_preview_active = _preview_remaining > 0.0
	_sequence_hidden_after_preview = config.should_hide_sequence_after_preview(
		completed_runes
	)
	cursor.reset_cursor(Vector2.ZERO)
	cursor.set_movement_enabled(true)
	_rebuild_target_visuals()
	_update_sequence_visibility()
	_show_feedback(
		"Study the rune" if _preview_active else "Weave the path",
		FEEDBACK_NORMAL_COLOR
	)
	_sync_result(true)


func _generate_pattern(node_count: int) -> PackedVector2Array:
	var bounds := config.get_target_bounds()
	var columns := floori(bounds.size.x / config.minimum_target_spacing) + 1
	var rows := floori(bounds.size.y / config.minimum_target_spacing) + 1
	var x_start := -float(columns - 1) * config.minimum_target_spacing * 0.5
	var y_start := -float(rows - 1) * config.minimum_target_spacing * 0.5
	var candidates: Array[Vector2] = []
	for row in rows:
		for column in columns:
			candidates.append(Vector2(
				x_start + float(column) * config.minimum_target_spacing,
				y_start + float(row) * config.minimum_target_spacing
			))
	for index in range(candidates.size() - 1, 0, -1):
		var swap_index := _rng.randi_range(0, index)
		var temporary := candidates[index]
		candidates[index] = candidates[swap_index]
		candidates[swap_index] = temporary
	var pattern := PackedVector2Array()
	for index in mini(node_count, candidates.size()):
		pattern.append(candidates[index])
	return pattern


func _on_target_activated(target_index: int, target_position: Vector2) -> void:
	total_correct_nodes += 1
	if config.snap_cursor_to_activated_node:
		cursor.reset_cursor(target_position)
	_update_completed_line()
	_update_target_visuals()
	_show_feedback("Node %d linked" % (target_index + 1), FEEDBACK_SUCCESS_COLOR, true)
	_sync_result(true)


func _on_incorrect_activation(
	_attempted_position: Vector2,
	_required_index: int,
	_required_position: Vector2,
	_distance: float
) -> void:
	total_mistakes += 1
	_rune_had_mistake = true
	current_streak = 0
	_result["failures"] = total_mistakes
	_result["score"] = maxf(
		0.0,
		float(_result.get("score", 0.0)) - config.mistake_penalty
	)
	_show_feedback("Mistake — find the next node", FEEDBACK_MISTAKE_COLOR, true)
	_sync_result(true)


func _on_sequence_completed() -> void:
	completed_runes += 1
	_result["successes"] = completed_runes
	if _rune_had_mistake:
		current_streak = 0
	else:
		current_streak += 1
	best_streak = maxi(best_streak, current_streak)
	if fastest_rune_completion <= 0.0 or _rune_elapsed < fastest_rune_completion:
		fastest_rune_completion = _rune_elapsed

	var par_time := (
		float(target_controller.get_target_count()) * config.target_seconds_per_node
	)
	var speed_ratio := clampf(
		(par_time - _rune_elapsed) / maxf(par_time, 0.001),
		0.0,
		1.0
	)
	var streak_factor := (
		1.0 + float(maxi(current_streak - 1, 0)) * config.streak_multiplier
	)
	var completion_score := (
		config.base_completion_score + config.speed_bonus * speed_ratio
	) * streak_factor
	_result["score"] = float(_result.get("score", 0.0)) + completion_score
	_round_transition_active = true
	_round_transition_remaining = config.round_transition_delay
	cursor.set_movement_enabled(false)
	_update_target_visuals()
	_show_feedback("Rune complete!", FEEDBACK_SUCCESS_COLOR, true)
	_sync_result(true)


func _configure_field_visuals() -> void:
	var bounds := config.get_cursor_bounds()
	field_background.position = bounds.position
	field_background.size = bounds.size


func _rebuild_target_visuals() -> void:
	for visual in _target_visual_nodes:
		if visual != null and is_instance_valid(visual):
			visual.queue_free()
	_target_visual_nodes.clear()
	for index in _current_targets.size():
		var visual := Node2D.new()
		visual.name = "Target%d" % (index + 1)
		visual.position = _current_targets[index]

		var glow := Polygon2D.new()
		glow.name = "Glow"
		glow.polygon = _make_circle_polygon(16.0)
		glow.color = TARGET_GLOW_COLOR
		visual.add_child(glow)

		var core := Polygon2D.new()
		core.name = "Core"
		core.polygon = _make_circle_polygon(8.0)
		core.color = TARGET_NEUTRAL_COLOR
		visual.add_child(core)

		var order_label := Label.new()
		order_label.name = "Order"
		order_label.position = Vector2(-12.0, -13.0)
		order_label.size = Vector2(24.0, 26.0)
		order_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		order_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		order_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		order_label.text = str(index + 1)
		order_label.add_theme_font_size_override("font_size", 13)
		visual.add_child(order_label)

		target_visuals.add_child(visual)
		_target_visual_nodes.append(visual)
	preview_line.points = _current_targets
	completed_line.clear_points()
	_update_target_visuals()


func _update_sequence_visibility() -> void:
	var show_order := not _sequence_hidden_after_preview or _preview_active
	preview_line.visible = show_order
	for visual in _target_visual_nodes:
		var order_label := visual.get_node_or_null("Order") as Label
		if order_label != null:
			order_label.visible = show_order
	_update_target_visuals()


func _update_completed_line() -> void:
	completed_line.clear_points()
	var completed_count := mini(
		target_controller.get_current_index(),
		_current_targets.size()
	)
	for index in completed_count:
		completed_line.add_point(_current_targets[index])


func _update_target_visuals() -> void:
	var current_index := target_controller.get_current_index()
	var show_active := not _sequence_hidden_after_preview or _preview_active
	for index in _target_visual_nodes.size():
		var visual := _target_visual_nodes[index]
		var core := visual.get_node_or_null("Core") as Polygon2D
		var glow := visual.get_node_or_null("Glow") as Polygon2D
		if core == null or glow == null:
			continue
		if index < current_index:
			core.color = TARGET_COMPLETED_COLOR
			glow.color = Color(0.3, 0.95, 0.62, 0.3)
		elif index == current_index and show_active:
			core.color = TARGET_ACTIVE_COLOR
			glow.color = Color(1.0, 0.78, 0.28, 0.34)
		else:
			core.color = TARGET_NEUTRAL_COLOR
			glow.color = TARGET_GLOW_COLOR


func _make_circle_polygon(radius: float, point_count: int = 24) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in point_count:
		points.append(Vector2.from_angle(TAU * float(index) / float(point_count)) * radius)
	return points


func _show_feedback(
	message: String,
	color: Color,
	tint_cursor: bool = false
) -> void:
	feedback_label.text = message
	feedback_label.modulate = color
	_feedback_remaining = config.feedback_duration
	if tint_cursor:
		cursor.modulate = color


func _update_feedback_timer(delta: float) -> void:
	if _feedback_remaining <= 0.0:
		return
	_feedback_remaining -= delta
	if _feedback_remaining <= 0.0:
		cursor.modulate = Color.WHITE
		feedback_label.modulate = FEEDBACK_NORMAL_COLOR


func _update_cursor_guidance(delta: float) -> void:
	var can_activate := (
		not _preview_active
		and not _round_transition_active
		and target_controller.has_pending_target()
		and cursor.get_cursor_position().distance_to(
			target_controller.get_current_target_position()
		) <= config.activation_radius
	)
	var target_scale := Vector2.ONE * (1.12 if can_activate else 1.0)
	var response_weight := 1.0 - exp(-12.0 * maxf(delta, 0.0))
	cursor.scale = cursor.scale.lerp(target_scale, response_weight)
	if _feedback_remaining > 0.0:
		return
	cursor.modulate = Color(0.72, 1.0, 0.84, 1.0) if can_activate else Color.WHITE
	feedback_label.modulate = FEEDBACK_NORMAL_COLOR
	if _preview_active:
		feedback_label.text = "Study the rune"
	elif _round_transition_active:
		feedback_label.text = "Rune complete!"
	elif can_activate:
		feedback_label.text = "Z: Link node"
	else:
		feedback_label.text = "Move to the next node"


func _sync_result(emit_if_changed: bool) -> void:
	_result["failures"] = total_mistakes
	_result["successes"] = completed_runes
	_result["details"] = {
		"completed_runes": completed_runes,
		"total_correct_nodes": total_correct_nodes,
		"total_mistakes": total_mistakes,
		"best_streak": best_streak,
		"fastest_rune_completion": fastest_rune_completion,
		"highest_node_count_reached": highest_node_count_reached,
		"current_streak": current_streak,
		"current_node_count": target_controller.get_target_count(),
		"current_target_index": target_controller.get_current_index(),
		"preview_active": _preview_active,
		"sequence_hidden": is_sequence_hidden(),
	}
	preview_label.text = (
		"Preview  %.1fs" % maxf(_preview_remaining, 0.0)
		if _preview_active
		else ("Order hidden" if is_sequence_hidden() else "Order visible")
	)
	progress_label.text = "Rune %d   Node %d / %d" % [
		completed_runes + 1,
		mini(target_controller.get_current_index() + 1, target_controller.get_target_count()),
		target_controller.get_target_count(),
	]
	streak_label.text = "Streak  %d" % current_streak
	score_label.text = "Score  %d" % int(round(float(_result.get("score", 0.0))))
	var signature := "%d|%d|%d|%d|%d|%s|%s" % [
		int(round(float(_result.get("score", 0.0)))),
		int(_result.get("attempts", 0)),
		completed_runes,
		total_correct_nodes,
		total_mistakes,
		str(_preview_active),
		str(_round_transition_active),
	]
	if emit_if_changed and signature != _last_published_signature:
		result_changed.emit(get_result())
	_last_published_signature = signature
