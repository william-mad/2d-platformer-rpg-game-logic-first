class_name WorldTimeSystem extends Node

signal time_changed(snapshot: Dictionary)
signal hour_changed(hour: int, snapshot: Dictionary)
signal day_changed(day: int, snapshot: Dictionary)
signal period_changed(period: StringName, snapshot: Dictionary)

const EVENT_TIME_CHANGED: StringName = &"time_changed"
const EVENT_HOUR_CHANGED: StringName = &"hour_changed"
const EVENT_DAY_CHANGED: StringName = &"day_changed"
const EVENT_PERIOD_CHANGED: StringName = &"period_changed"

const PERIOD_DAWN: StringName = &"dawn"
const PERIOD_DAY: StringName = &"day"
const PERIOD_DUSK: StringName = &"dusk"
const PERIOD_NIGHT: StringName = &"night"

@export_group("Clock")
@export_range(1.0, 3600.0, 0.1, "suffix:s") var real_seconds_per_day: float = 1800.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var start_hour: float = 6.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var sunrise_hour: float = 6.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var sunset_hour: float = 18.0
@export var auto_advance: bool = true

@export_group("Events")
@export var emit_event_bus_events: bool = true
@export var emit_time_event_bus_events: bool = false
@export var emit_time_changed_every_process_frame: bool = false
@export_range(0.0, 300.0, 0.1, "suffix:s") var time_changed_emit_interval_seconds: float = 30.0
@export_range(1, 60, 1, "suffix:min") var time_event_minute_interval: int = 15

var day: int = 0
var time_of_day_hours: float = 6.0

var last_hour: int = -1
var last_day: int = -1
var last_period: StringName = &""
var last_time_event_bucket: int = -1
var time_changed_emit_elapsed_seconds: float = 0.0


func _ready() -> void:
	reset_time(false)


func _process(delta: float) -> void:
	if auto_advance and not _is_world_progression_locked():
		advance_real_seconds(delta)


func reset_time(emit_changes: bool = true) -> void:
	day = 0
	time_of_day_hours = start_hour
	_refresh_change_trackers()
	if emit_changes:
		_emit_time_changes(true)


func advance_real_seconds(delta: float) -> void:
	time_changed_emit_elapsed_seconds += maxf(delta, 0.0)
	var hours_to_advance := (delta / _safe_real_seconds_per_day()) * 24.0
	set_total_hours(get_total_hours() + hours_to_advance)


func set_time(new_day: int, new_time_of_day_hours: float) -> void:
	day = max(new_day, 0)
	time_of_day_hours = clampf(new_time_of_day_hours, 0.0, 24.0)

	if time_of_day_hours >= 24.0:
		day += int(floor(time_of_day_hours / 24.0))
		time_of_day_hours = fposmod(time_of_day_hours, 24.0)

	_emit_time_changes()


func set_total_hours(total_hours: float) -> void:
	var safe_total_hours := maxf(total_hours, 0.0)
	day = int(floor(safe_total_hours / 24.0))
	time_of_day_hours = fposmod(safe_total_hours, 24.0)
	_emit_time_changes()


func set_time_of_day_hours(new_time_of_day_hours: float) -> void:
	set_time(day, new_time_of_day_hours)


func get_total_hours() -> float:
	return float(day * 24) + time_of_day_hours


func get_day_progress() -> float:
	return time_of_day_hours / 24.0


func is_daylight() -> bool:
	var daylight_length := _daylight_length_hours()
	if daylight_length >= 24.0:
		return true

	return fposmod(time_of_day_hours - sunrise_hour, 24.0) <= daylight_length


func get_daylight_progress() -> float:
	return clampf(fposmod(time_of_day_hours - sunrise_hour, 24.0) / _daylight_length_hours(), 0.0, 1.0)


func get_night_progress() -> float:
	var night_length := maxf(24.0 - _daylight_length_hours(), 0.001)
	return clampf(fposmod(time_of_day_hours - sunset_hour, 24.0) / night_length, 0.0, 1.0)


func get_period() -> StringName:
	if is_daylight():
		var daylight_progress := get_daylight_progress()
		if daylight_progress < 0.18:
			return PERIOD_DAWN
		if daylight_progress > 0.82:
			return PERIOD_DUSK
		return PERIOD_DAY

	return PERIOD_NIGHT


func get_hour() -> int:
	return int(floor(time_of_day_hours)) % 24


func get_minute() -> int:
	return int(floor(fposmod(time_of_day_hours, 1.0) * 60.0)) % 60


func get_snapshot() -> Dictionary:
	# Other systems should read this shape instead of reaching into this node's internals.
	return {
		"day": day,
		"time_of_day_hours": time_of_day_hours,
		"total_hours": get_total_hours(),
		"day_progress": get_day_progress(),
		"daylight_progress": get_daylight_progress(),
		"night_progress": get_night_progress(),
		"is_daylight": is_daylight(),
		"period": get_period(),
		"hour": get_hour(),
		"minute": get_minute(),
		"sunrise_hour": sunrise_hour,
		"sunset_hour": sunset_hour,
	}


func get_save_data() -> Dictionary:
	return {
		"day": day,
		"time_of_day_hours": time_of_day_hours,
	}


func apply_save_data(data: Dictionary) -> void:
	if data.is_empty():
		reset_time()
		return

	set_time(int(data.get("day", day)), float(data.get("time_of_day_hours", time_of_day_hours)))


func _emit_time_changes(force_all: bool = false) -> void:
	var snapshot := get_snapshot()
	var current_day := int(snapshot["day"])
	var current_hour := int(snapshot["hour"])
	var current_period := StringName(snapshot["period"])
	var minute_bucket := _get_time_event_bucket(current_hour, int(snapshot["minute"]))

	if (
		force_all
		or emit_time_changed_every_process_frame
		or time_changed_emit_interval_seconds <= 0.0
		or time_changed_emit_elapsed_seconds >= time_changed_emit_interval_seconds
	):
		time_changed_emit_elapsed_seconds = 0.0
		time_changed.emit(snapshot)

	if force_all or current_day != last_day:
		last_day = current_day
		day_changed.emit(current_day, snapshot)
		_emit_event_bus(EVENT_DAY_CHANGED, snapshot)

	if force_all or current_hour != last_hour:
		last_hour = current_hour
		hour_changed.emit(current_hour, snapshot)
		_emit_event_bus(EVENT_HOUR_CHANGED, snapshot)

	if force_all or current_period != last_period:
		last_period = current_period
		period_changed.emit(current_period, snapshot)
		_emit_event_bus(EVENT_PERIOD_CHANGED, snapshot)

	if force_all or minute_bucket != last_time_event_bucket:
		last_time_event_bucket = minute_bucket
		_emit_event_bus(EVENT_TIME_CHANGED, snapshot)


func _emit_event_bus(event_name: StringName, snapshot: Dictionary) -> void:
	if not emit_event_bus_events:
		return
	if event_name == EVENT_TIME_CHANGED and not emit_time_event_bus_events:
		return

	var event_bus := get_node_or_null("/root/EventBus")
	if event_bus == null or not event_bus.has_method("emit_global_event"):
		return

	event_bus.call("emit_global_event", event_name, {
		"world_time": snapshot,
		"day": snapshot["day"],
		"time_of_day_hours": snapshot["time_of_day_hours"],
		"period": snapshot["period"],
		"hour": snapshot["hour"],
		"minute": snapshot["minute"],
	})


func _refresh_change_trackers() -> void:
	last_day = day
	last_hour = get_hour()
	last_period = get_period()
	last_time_event_bucket = _get_time_event_bucket(last_hour, get_minute())


func _get_time_event_bucket(hour: int, minute: int) -> int:
	var interval := maxi(time_event_minute_interval, 1)
	return hour * 60 + int(floor(float(minute) / float(interval))) * interval


func _daylight_length_hours() -> float:
	var length := fposmod(sunset_hour - sunrise_hour, 24.0)
	if is_zero_approx(length):
		return 24.0

	return length


func _safe_real_seconds_per_day() -> float:
	return maxf(real_seconds_per_day, 0.001)


func _is_world_progression_locked() -> bool:
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	return (
		gameplay_flow != null
		and gameplay_flow.has_method("is_world_progression_locked")
		and bool(gameplay_flow.call("is_world_progression_locked"))
	)
