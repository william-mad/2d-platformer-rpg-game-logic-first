extends "res://test/native_scene_tree_test.gd"
# Unit tests for WorldTimeSystem's pure time math: daylight, periods, hours, wraparound.
# WorldTime is an autoload in the game, but these tests instantiate the script fresh so
# the math can be verified in isolation without touching the running clock.

var WorldTimeClass := preload("res://scripts/systems/world_time.gd")


func _make_clock() -> Node:
	var clock := WorldTimeClass.new()
	clock.sunrise_hour = 6.0
	clock.sunset_hour = 18.0
	clock.auto_advance = false
	return add_child_autofree(clock)


func test_midday_is_daylight_and_period_day() -> void:
	var clock := _make_clock()
	clock.set_time(0, 12.0)
	assert_true(clock.is_daylight(), "noon should be daylight")
	assert_eq(clock.get_period(), WorldTimeSystem.PERIOD_DAY, "noon should be PERIOD_DAY")


func test_midnight_is_not_daylight_and_period_night() -> void:
	var clock := _make_clock()
	clock.set_time(0, 0.0)
	assert_false(clock.is_daylight(), "midnight should not be daylight")
	assert_eq(clock.get_period(), WorldTimeSystem.PERIOD_NIGHT, "midnight should be PERIOD_NIGHT")


func test_get_hour_and_minute() -> void:
	var clock := _make_clock()
	clock.set_time(0, 7.5) # 07:30
	assert_eq(clock.get_hour(), 7, "07:30 -> hour 7")
	assert_eq(clock.get_minute(), 30, "07:30 -> minute 30")


func test_total_hours_includes_days() -> void:
	var clock := _make_clock()
	clock.set_time(2, 6.0) # day 2, 06:00
	assert_eq(clock.get_total_hours(), 54.0, "2 days + 6h = 54 total hours")


func test_set_time_wraps_past_24_hours_into_next_day() -> void:
	var clock := _make_clock()
	clock.set_time(0, 25.0) # 25 hours -> day 1, 01:00
	assert_eq(clock.day, 1, "25h wraps into day 1")
	assert_eq(clock.get_hour(), 1, "25h wraps to hour 1")


func test_daylight_progress_zero_at_sunrise() -> void:
	var clock := _make_clock()
	clock.set_time(0, 6.0) # exactly sunrise
	assert_true(clock.is_daylight(), "sunrise should count as daylight start")
	var progress: float = clock.get_daylight_progress()
	assert_true(is_equal_approx(progress, 0.0), "daylight progress should start at 0 at sunrise")


func test_dawn_classified_for_early_daylight() -> void:
	var clock := _make_clock()
	clock.set_time(0, 6.5) # very early daylight window
	# Dawn is the first 18% of daylight (12h daylight * 0.18 ~= 2.16h -> ends ~8.16)
	assert_eq(clock.get_period(), WorldTimeSystem.PERIOD_DAWN, "07:00 with sunrise 6 should be dawn")


func test_dusk_classified_for_late_daylight() -> void:
	var clock := _make_clock()
	clock.set_time(0, 17.5) # late daylight window (last 18% of a 12h daylight starts ~15.84)
	assert_eq(clock.get_period(), WorldTimeSystem.PERIOD_DUSK, "17:30 with sunset 18 should be dusk")


func test_reset_time_zeros_day_and_hour() -> void:
	var clock := _make_clock()
	clock.set_time(3, 14.0)
	clock.start_hour = 6.0
	clock.reset_time(false)
	assert_eq(clock.day, 0, "reset zeroes day")
	assert_eq(clock.time_of_day_hours, 6.0, "reset sets time to start_hour")


func test_snapshot_contains_required_keys() -> void:
	var clock := _make_clock()
	clock.set_time(1, 9.0)
	var snapshot: Dictionary = clock.get_snapshot()
	for required_key in ["day", "time_of_day_hours", "total_hours", "period", "hour", "minute", "is_daylight"]:
		assert_true(snapshot.has(required_key), "snapshot must include %s" % required_key)
