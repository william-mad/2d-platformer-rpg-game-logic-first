class_name NpcScheduleWindowPolicy extends RefCounted

const START_POLICY_HARD: StringName = &"hard"
const START_POLICY_FLEXIBLE: StringName = &"flexible"
const COMPLETION_POLICY_STOP_AT_WINDOW_END: StringName = &"stop_at_window_end"
const COMPLETION_POLICY_FINISH_CURRENT: StringName = &"finish_current"
const PHASE_CLOSED: StringName = &"closed"
const PHASE_ON_TIME: StringName = &"on_time"
const PHASE_LATE: StringName = &"late"

const HOURS_PER_DAY: float = 24.0
const MINUTES_PER_HOUR: float = 60.0
const MAXIMUM_SAFE_PRIORITY: int = 1000000
const MAXIMUM_OVERTIME_GAME_MINUTES: float = 240.0


static func evaluate_definition(
	definition: NpcSpotDefinition,
	total_game_hours: float
) -> Dictionary:
	var base_priority := definition.priority if definition != null else 0
	var spot_id := definition.spot_id if definition != null else &""
	var closed := _decision_template(spot_id, base_priority)
	if definition == null or not is_finite(total_game_hours):
		return closed
	if definition.active_time_windows.is_empty():
		var day_index := int(floor(total_game_hours / HOURS_PER_DAY))
		var day_start := float(day_index) * HOURS_PER_DAY
		return _open_decision(
			spot_id,
			base_priority,
			START_POLICY_HARD,
			-1,
			day_start,
			day_start + HOURS_PER_DAY,
			day_start,
			total_game_hours,
			0.0,
			COMPLETION_POLICY_STOP_AT_WINDOW_END,
			0.0
		)

	for window_index in definition.active_time_windows.size():
		var window_value: Variant = definition.active_time_windows[window_index]
		if not (window_value is Dictionary):
			continue
		var window: Dictionary = window_value
		var occurrence := _get_containing_occurrence(
			window,
			total_game_hours
		)
		if occurrence.is_empty():
			continue
		var start_policy := canonicalize_start_policy(window.get(
			"start_policy",
			START_POLICY_HARD
		))
		if start_policy not in [START_POLICY_HARD, START_POLICY_FLEXIBLE]:
			continue
		var completion_policy := canonicalize_completion_policy(window.get(
			"completion_policy",
			COMPLETION_POLICY_STOP_AT_WINDOW_END
		))
		if completion_policy not in [
			COMPLETION_POLICY_STOP_AT_WINDOW_END,
			COMPLETION_POLICY_FINISH_CURRENT,
		]:
			continue
		var grace_hours := 0.0
		var late_priority_bonus := 0.0
		var maximum_overtime_hours := 0.0
		if start_policy == START_POLICY_FLEXIBLE:
			grace_hours = maxf(
				float(window.get("grace_game_minutes", 0.0)) / MINUTES_PER_HOUR,
				0.0
			)
			late_priority_bonus = maxf(
				float(window.get("late_priority_bonus", 0.0)),
				0.0
			)
		if completion_policy == COMPLETION_POLICY_FINISH_CURRENT:
			maximum_overtime_hours = clampf(
				float(window.get("maximum_overtime_game_minutes", 0.0))
					/ MINUTES_PER_HOUR,
				0.0,
				MAXIMUM_OVERTIME_GAME_MINUTES / MINUTES_PER_HOUR
			)
		return _open_decision(
			spot_id,
			base_priority,
			start_policy,
			window_index,
			float(occurrence["start_total_hours"]),
			float(occurrence["end_total_hours"]),
			minf(
				float(occurrence["start_total_hours"]) + grace_hours,
				float(occurrence["end_total_hours"])
			),
			total_game_hours,
			late_priority_bonus,
			completion_policy,
			maximum_overtime_hours
		)
	return closed


static func canonicalize_start_policy(value: Variant) -> StringName:
	return StringName(String(value).strip_edges().to_lower())


static func canonicalize_completion_policy(value: Variant) -> StringName:
	return StringName(String(value).strip_edges().to_lower())


static func evaluate_active_activity(
	definition: NpcSpotDefinition,
	activity: Dictionary,
	total_game_hours: float
) -> Dictionary:
	var result := _continuation_template()
	if definition == null or not is_finite(total_game_hours):
		return result
	if definition.active_time_windows.is_empty():
		result["may_continue"] = true
		result["reason_code"] = &"inside_window"
		return result

	var occurrence_key := String(_activity_schedule_value(
		activity, "schedule_occurrence_key", ""
	)).strip_edges()
	var window_index := int(_activity_schedule_value(
		activity, "schedule_window_index", -1
	))
	var window_end_total_hours := float(_activity_schedule_value(
		activity, "schedule_window_end_total_hours", NAN
	))
	var completion_policy := canonicalize_completion_policy(
		_activity_schedule_value(
			activity,
			"schedule_completion_policy",
			COMPLETION_POLICY_STOP_AT_WINDOW_END
		)
	)
	var maximum_overtime_hours := float(_activity_schedule_value(
		activity, "schedule_maximum_overtime_game_hours", 0.0
	))
	var overtime_end_total_hours := float(_activity_schedule_value(
		activity,
		"schedule_overtime_end_total_hours",
		window_end_total_hours + maximum_overtime_hours
	))
	var activity_spot_id := String(activity.get("spot_id", "")).strip_edges()
	if (
		occurrence_key.is_empty()
		or activity_spot_id != String(definition.spot_id)
		or not occurrence_key.begins_with("%s:" % String(definition.spot_id))
		or window_index < 0
		or window_index >= definition.active_time_windows.size()
		or not is_finite(window_end_total_hours)
		or completion_policy not in [
			COMPLETION_POLICY_STOP_AT_WINDOW_END,
			COMPLETION_POLICY_FINISH_CURRENT,
		]
		or not is_finite(maximum_overtime_hours)
		or maximum_overtime_hours < 0.0
		or not is_finite(overtime_end_total_hours)
		or overtime_end_total_hours < window_end_total_hours
	):
		return result

	maximum_overtime_hours = clampf(
		maximum_overtime_hours,
		0.0,
		MAXIMUM_OVERTIME_GAME_MINUTES / MINUTES_PER_HOUR
	)
	if completion_policy == COMPLETION_POLICY_STOP_AT_WINDOW_END:
		overtime_end_total_hours = window_end_total_hours
	else:
		overtime_end_total_hours = minf(
			overtime_end_total_hours,
			window_end_total_hours + maximum_overtime_hours
		)
	result.merge({
		"completion_policy": completion_policy,
		"occurrence_key": occurrence_key,
		"window_end_total_hours": window_end_total_hours,
		"overtime_end_total_hours": overtime_end_total_hours,
	}, true)
	if total_game_hours < window_end_total_hours:
		result["may_continue"] = true
		result["reason_code"] = &"inside_window"
		return result
	if completion_policy == COMPLETION_POLICY_STOP_AT_WINDOW_END:
		result["reason_code"] = &"window_closed"
		return result

	result["in_overtime"] = true
	result["overtime_game_hours"] = maxf(
		total_game_hours - window_end_total_hours,
		0.0
	)
	result["overtime_remaining_game_hours"] = maxf(
		overtime_end_total_hours - total_game_hours,
		0.0
	)
	if total_game_hours >= overtime_end_total_hours:
		result["reason_code"] = &"overtime_expired"
		return result
	result["may_continue"] = true
	result["reason_code"] = &"finishing_current_activity"
	return result


static func get_window_duration_hours(window: Dictionary) -> float:
	var start_hour := _normalized_hour(window.get(
		"start_hour",
		window.get("start", 0.0)
	))
	var end_hour := _normalized_hour(window.get(
		"end_hour",
		window.get("end", HOURS_PER_DAY)
	))
	if is_equal_approx(start_hour, end_hour):
		return HOURS_PER_DAY
	return fposmod(end_hour - start_hour, HOURS_PER_DAY)


static func _get_containing_occurrence(
	window: Dictionary,
	total_game_hours: float
) -> Dictionary:
	var start_hour := _normalized_hour(window.get(
		"start_hour",
		window.get("start", 0.0)
	))
	var duration := get_window_duration_hours(window)
	if duration <= 0.0 or not is_finite(duration):
		return {}
	var occurrence_day: float = floorf(
		(total_game_hours - start_hour) / HOURS_PER_DAY
	)
	var start_total_hours: float = occurrence_day * HOURS_PER_DAY + start_hour
	var end_total_hours: float = start_total_hours + duration
	if total_game_hours < start_total_hours or total_game_hours >= end_total_hours:
		return {}
	return {
		"start_total_hours": start_total_hours,
		"end_total_hours": end_total_hours,
	}


static func _open_decision(
	spot_id: StringName,
	base_priority: int,
	start_policy: StringName,
	window_index: int,
	window_start_total_hours: float,
	window_end_total_hours: float,
	grace_end_total_hours: float,
	total_game_hours: float,
	late_priority_bonus: float,
	completion_policy: StringName,
	maximum_overtime_hours: float
) -> Dictionary:
	var flexible := start_policy == START_POLICY_FLEXIBLE
	var late := flexible and total_game_hours > grace_end_total_hours
	var phase := PHASE_LATE if late else PHASE_ON_TIME
	var lateness := (
		maxf(total_game_hours - grace_end_total_hours, 0.0)
		if late
		else 0.0
	)
	var late_span := maxf(window_end_total_hours - grace_end_total_hours, 0.0)
	var bonus_progress := (
		clampf(lateness / late_span, 0.0, 1.0)
		if late and late_span > 0.0
		else 0.0
	)
	var interpolated_bonus := late_priority_bonus * bonus_progress
	var effective_priority := roundi(clampf(
		float(base_priority) + interpolated_bonus,
		-float(MAXIMUM_SAFE_PRIORITY),
		float(MAXIMUM_SAFE_PRIORITY)
	))
	var occurrence_day := int(floor(window_start_total_hours / HOURS_PER_DAY))
	return {
		"eligible": true,
		"phase": phase,
		"start_policy": start_policy,
		"window_index": window_index,
		"occurrence_key": "%s:%d:%d" % [
			String(spot_id),
			occurrence_day,
			window_index,
		],
		"window_start_total_hours": window_start_total_hours,
		"grace_end_total_hours": grace_end_total_hours,
		"window_end_total_hours": window_end_total_hours,
		"evaluated_total_game_hours": total_game_hours,
		"lateness_game_hours": lateness,
		"effective_priority": effective_priority,
		"completion_policy": completion_policy,
		"maximum_overtime_game_hours": maximum_overtime_hours,
		"overtime_end_total_hours": window_end_total_hours + maximum_overtime_hours,
		"may_interrupt_busy_live_npc": (
			start_policy == START_POLICY_HARD or late
		),
	}


static func _decision_template(
	spot_id: StringName,
	base_priority: int
) -> Dictionary:
	return {
		"eligible": false,
		"phase": PHASE_CLOSED,
		"start_policy": START_POLICY_HARD,
		"window_index": -1,
		"occurrence_key": "",
		"window_start_total_hours": 0.0,
		"grace_end_total_hours": 0.0,
		"window_end_total_hours": 0.0,
		"evaluated_total_game_hours": 0.0,
		"lateness_game_hours": 0.0,
		"effective_priority": base_priority,
		"completion_policy": COMPLETION_POLICY_STOP_AT_WINDOW_END,
		"maximum_overtime_game_hours": 0.0,
		"overtime_end_total_hours": 0.0,
		"may_interrupt_busy_live_npc": false,
		"spot_id": spot_id,
	}


static func _continuation_template() -> Dictionary:
	return {
		"may_continue": false,
		"reason_code": &"invalid_occurrence",
		"completion_policy": COMPLETION_POLICY_STOP_AT_WINDOW_END,
		"occurrence_key": "",
		"window_end_total_hours": 0.0,
		"overtime_end_total_hours": 0.0,
		"in_overtime": false,
		"overtime_game_hours": 0.0,
		"overtime_remaining_game_hours": 0.0,
	}


static func _activity_schedule_value(
	activity: Dictionary,
	key: String,
	fallback: Variant
) -> Variant:
	if activity.has(key):
		return activity[key]
	var metadata_value: Variant = activity.get("metadata", {})
	if metadata_value is Dictionary and metadata_value.has(key):
		return metadata_value[key]
	return fallback


static func _normalized_hour(value: Variant) -> float:
	return fposmod(float(value), HOURS_PER_DAY)
