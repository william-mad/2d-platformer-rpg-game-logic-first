extends GutTest
# Unit tests for NpcStateMachine's rule engine. These are the most regression-prone
# functions in the project: time windows, threshold/delta matching, alias resolution,
# and one-shot threshold effects. They are private (_-prefixed) but callable directly,
# which keeps the tests focused on the pure logic without needing a full NPC scene.

var NpcStateMachineClass := preload("res://scenes/creatures/npc/npc_state_machine.gd")

var machine: Node


func before_each() -> void:
	machine = NpcStateMachineClass.new()
	add_child_autofree(machine)


# --- _time_window_matches -------------------------------------------------------

func test_time_window_inside_normal_range() -> void:
	# 09:00 to 17:00
	var window := {"start_hour": 9.0, "end_hour": 17.0}
	assert_true(machine._time_window_matches(window, 12.0), "12:00 is inside 9-17")
	assert_false(machine._time_window_matches(window, 8.0), "08:00 is before 9-17")
	assert_false(machine._time_window_matches(window, 17.0), "17:00 is exclusive end")


func test_time_window_wraparound_overnight() -> void:
	# The classic sleep rule: 22:00 to 06:00, crossing midnight.
	var window := {"start_hour": 22.0, "end_hour": 6.0}
	assert_true(machine._time_window_matches(window, 23.0), "23:00 is inside overnight window")
	assert_true(machine._time_window_matches(window, 2.0), "02:00 is inside overnight window")
	assert_false(machine._time_window_matches(window, 12.0), "noon is outside overnight window")


func test_time_window_equal_start_end_matches_anything() -> void:
	# When start == end, the rule treats the window as "always".
	var window := {"start_hour": 6.0, "end_hour": 6.0}
	assert_true(machine._time_window_matches(window, 3.0), "equal start/end matches any hour")


# --- _rule_matches --------------------------------------------------------------

func test_rule_at_least_matches_when_value_high_enough() -> void:
	var rule := {"at_least": 70.0}
	assert_true(machine._rule_matches(rule, 75.0, 0.0, false), "75 >= 70 should match")
	assert_false(machine._rule_matches(rule, 69.0, 0.0, false), "69 < 70 should not match")


func test_rule_at_most_matches_when_value_low_enough() -> void:
	var rule := {"at_most": 99.0}
	assert_true(machine._rule_matches(rule, 50.0, 0.0, false), "50 <= 99 should match")
	assert_false(machine._rule_matches(rule, 100.0, 0.0, false), "100 > 99 should not match")


func test_rule_bounded_range_requires_both_bounds() -> void:
	# Sleep-bed style rule: 71..99
	var rule := {"at_least": 71.0, "at_most": 99.0}
	assert_true(machine._rule_matches(rule, 80.0, 0.0, false), "80 is inside 71-99")
	assert_false(machine._rule_matches(rule, 70.0, 0.0, false), "70 is below the range")
	assert_false(machine._rule_matches(rule, 100.0, 0.0, false), "100 is above the range")


func test_rule_delta_at_most_requires_value_changed_and_delta_condition() -> void:
	# favor_dropped style rule: delta_at_most -1.0 (favor fell by at least 1)
	var rule := {"delta_at_most": -1.0}
	assert_true(machine._rule_matches(rule, 40.0, -5.0, true), "favor fell by 5 matches")
	assert_false(machine._rule_matches(rule, 40.0, -5.0, false), "delta rule needs value_changed=true")
	assert_false(machine._rule_matches(rule, 40.0, 2.0, true), "positive delta does not match delta_at_most")


func test_rule_truthy_handles_nonzero() -> void:
	var rule := {"truthy": true}
	assert_true(machine._rule_matches(rule, 1.0, 0.0, false), "1.0 is truthy")
	assert_false(machine._rule_matches(rule, 0.0, 0.0, false), "0.0 is not truthy")


func test_rule_only_when_changed_gate() -> void:
	var rule := {"at_least": 70.0, "only_when_changed": true}
	assert_true(machine._rule_matches(rule, 75.0, 5.0, true), "changed value matches")
	assert_false(machine._rule_matches(rule, 75.0, 0.0, false), "unchanged value is blocked by only_when_changed")


# --- _threshold_effect_matches --------------------------------------------------

func test_threshold_effect_fires_on_crossing_up() -> void:
	var effect := {"at_least": 100.0}
	# previous 99, current 100 -> crossed into the cap from below.
	assert_true(machine._threshold_effect_matches(effect, 99.0, 100.0), "crossing into 100 from below fires")


func test_threshold_effect_does_not_fire_if_already_at_cap() -> void:
	var effect := {"at_least": 100.0}
	# previous 100, current 100 -> never crossed.
	assert_false(machine._threshold_effect_matches(effect, 100.0, 100.0), "staying at cap does not fire")


func test_threshold_effect_does_not_fire_if_dropping_below() -> void:
	var effect := {"at_least": 100.0}
	# previous 100, current 95 -> moving away from cap.
	assert_false(machine._threshold_effect_matches(effect, 100.0, 95.0), "dropping below cap does not fire")


# --- _canonical_value_key aliasing ----------------------------------------------

func test_alias_sleepiness_resolves_to_sleep_need() -> void:
	# Old save data / scene exports may still use "sleepiness"; it must map to "sleep_need".
	assert_eq(machine._canonical_value_key("sleepiness"), "sleep_need", "sleepiness aliases sleep_need")


func test_alias_work_need_resolves_to_boredom() -> void:
	assert_eq(machine._canonical_value_key("work_need"), "boredom", "work_need aliases boredom")


func test_alias_talk_interest_resolves_to_talk_need() -> void:
	assert_eq(machine._canonical_value_key("talk_interest"), "talk_need", "talk_interest aliases talk_need")


func test_non_alias_key_passes_through() -> void:
	assert_eq(machine._canonical_value_key("favor"), "favor", "favor is canonical and unchanged")


func test_replace_values_reuses_dictionary_and_preserves_canonical_alias_value() -> void:
	var values_reference: Dictionary = machine.values
	machine.replace_values({"sleepiness": 10.0, "sleep_need": 40.0, "favor": 80.0}, null, {}, false)

	values_reference["reference_observer"] = true
	assert_true(machine.values.has("reference_observer"), "replace_values keeps the values dictionary instance")
	assert_eq(machine.values.get("sleep_need"), 40.0, "canonical key wins over its alias")
	assert_false(machine.values.has("sleepiness"), "alias key is removed during normalization")
	assert_false(machine.values.has("hunger"), "replacement removes keys omitted from the new values")


# --- _variant_to_float ----------------------------------------------------------

func test_variant_to_float_handles_int_float_string() -> void:
	assert_eq(machine._variant_to_float(5), 5.0, "int 5 -> 5.0")
	assert_eq(machine._variant_to_float(5.5), 5.5, "float passes through")
	assert_eq(machine._variant_to_float("12.5"), 12.5, "string parses to float")
	assert_eq(machine._variant_to_float(true), 1.0, "true -> 1.0")
	assert_eq(machine._variant_to_float(false), 0.0, "false -> 0.0")
