extends Node

signal activity_started(npc_id: StringName, spot_id: StringName)
signal activity_finished(npc_id: StringName, spot_id: StringName)
signal scheduled_activity_committed(npc_id: StringName, activity: Dictionary)
signal scheduled_activity_entered_overtime(
	npc_id: StringName,
	activity: Dictionary,
	continuation_decision: Dictionary
)

const SPOT_DATA_DIRECTORY := "res://data/npc_spots"
const PLAYER_SOCIAL_TARGET_ID := "__player__"
const DEFAULT_SLEEP_SKIP_WAKE_HUNGER_MAX := 60.0
const STORED_ONLY_VALUE_KEYS := {
	"curiosity": true,
	"sadness": true,
	"energy": true,
	"suspicion": true,
}
const MEAL_STAGE_PREP_WORK := "prep_work"
const MEAL_STAGE_FOOD := "food"
const MEAL_STAGE_CLEANUP_WORK := "cleanup_work"
const MEAL_OWNER_PREP := "prep"
const MEAL_OWNER_FOOD := "food"
const MEAL_OWNER_CLEANUP := "cleanup"
const MEAL_CYCLE_EPSILON := 0.001
const INVITE_PLAYER_STATE := &"InvitePlayer"
const MagicLessonRemoteInvitationScene := preload("res://scripts/instances/magic_lesson_remote_invitation.gd")
const NpcActivityIdentity = preload("res://scripts/systems/npc_activity_identity.gd")
const NpcScheduleWindowPolicy = preload(
	"res://scripts/systems/npc_schedule_window_policy.gd"
)
const NpcActionSessionModel = preload("res://scripts/systems/npc_action_session.gd")
const NpcBehaviorIntentModel = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_intent.gd"
)
const NpcSocialConfigurationValidator = preload(
	"res://scripts/systems/npc_behavior/npc_social_configuration_validator.gd"
)
const NpcRouteBridge = preload("res://scripts/systems/npc_scene_route_bridge.gd")
const NpcRouteLocationCoordinator = preload(
	"res://scripts/systems/npc_route_location_coordinator.gd"
)
const SCHEDULE_METADATA_KEYS := [
	"schedule_phase",
	"schedule_occurrence_key",
	"schedule_window_index",
	"schedule_window_start_total_hours",
	"schedule_grace_end_total_hours",
	"schedule_window_end_total_hours",
	"schedule_lateness_game_hours",
	"schedule_base_priority",
	"schedule_effective_priority",
	"schedule_completion_policy",
	"schedule_maximum_overtime_game_hours",
	"schedule_overtime_end_total_hours",
]

@export var simulation_interval_seconds: float = 10.0
@export var simulated_talk_need_drop: float = 40.0
@export var simulated_partner_talk_need_drop: float = 25.0
@export var simulated_talk_boredom_drop: float = 10.0
@export_range(0.0, 24.0, 0.01, "suffix:h") var recent_refusal_retry_delay_game_hours: float = 0.25
@export_range(0.0, 24.0, 0.01, "suffix:h") var recent_harm_social_delay_game_hours: float = 0.5
@export_range(0.0, 24.0, 0.001, "suffix:h") var recent_conversation_repeat_delay_game_hours: float = 0.125
@export var performance_profiling_enabled: bool = false

const PERFORMANCE_PROFILE_REPORT_WINDOW_CALLS := 30
var spot_definitions: Dictionary = {}
var live_spots: Dictionary = {}
# Authoritative reservation_id -> owned reservation record ledger.
var spot_reservations: Dictionary = {}
# Compatibility cache only. It is always rebuilt from spot_reservations.
var spot_claim_counts: Dictionary = {}
var spot_runtime_states: Dictionary = {}
var simulation_timer: float = 0.0
var simulation_queued: bool = false
var simulation_dirty_while_locked: bool = false
var social_rng := RandomNumberGenerator.new()
var _social_planner := NpcSocialPlanner.new()
var _social_planning_suppressed: bool = false
var _social_seek_preview_only: bool = false
var _social_selection_debug_by_npc: Dictionary = {}
var _social_planning_pass_id: int = 0
var _schedule_decision_debug_by_npc: Dictionary = {}
var _schedule_overtime_last_observed_by_session: Dictionary = {}
var _schedule_overtime_last_observed_live_by_session: Dictionary = {}
var _schedule_overtime_sessions_emitted: Dictionary = {}
var _needs_simulator := NpcNeedsSimulator.new()
var simulation_tick_skip_logged: bool = false
var _performance_profile_call_count: int = 0
var _performance_profile_total_usec: int = 0
var _performance_profile_max_total_usec: int = 0
var _performance_profile_synchronize_usec: int = 0
var _performance_profile_snapshot_usec: int = 0
var _performance_profile_preparation_usec: int = 0
var _performance_profile_needs_usec: int = 0
var _performance_profile_activity_usec: int = 0
var _performance_profile_schedule_usec: int = 0
var _performance_profile_travel_usec: int = 0
var _performance_profile_social_usec: int = 0
var _performance_profile_apply_usec: int = 0
var _performance_profile_records_total: int = 0
var _performance_profile_records_simulated: int = 0
var _performance_profile_live_records: int = 0
var _performance_profile_disabled_records: int = 0
var _performance_profile_candidate_evaluations: int = 0
var _performance_profile_records_applied: int = 0
var _performance_profile_social_usec_in_pass: int = 0
var _performance_profile_candidate_evaluations_in_pass: int = 0
var _performance_profile_apply_usec_in_pass: int = 0
var _performance_profile_records_applied_in_pass: int = 0
var _logged_reservation_warnings: Dictionary = {}
var _validated_social_world_profile_signatures: Dictionary = {}
var _social_world_profile_validation_issues_by_npc: Dictionary = {}


func _ready() -> void:
	social_rng.randomize()
	_load_spot_definitions()
	_initialize_definition_runtime_states()
	simulation_timer = simulation_interval_seconds
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_signal(&"day_changed"):
		var callback := Callable(self, "_on_world_day_changed")
		if not world_time.is_connected(&"day_changed", callback):
			world_time.connect(&"day_changed", callback)
	if world_time != null and world_time.has_signal(&"hour_changed"):
		var hour_callback := Callable(self, "_on_world_hour_changed")
		if not world_time.is_connected(&"hour_changed", hour_callback):
			world_time.connect(&"hour_changed", hour_callback)
	if world_time != null and world_time.has_method("get_snapshot"):
		if not _defer_simulation_while_world_progression_locked():
			_process_meal_cycle_schedule_until_snapshot(world_time.call("get_snapshot"))

	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow != null and gameplay_flow.has_signal(&"world_progression_unlocked"):
		var unlock_callback := Callable(self, "_on_world_progression_unlocked")
		if not gameplay_flow.is_connected(&"world_progression_unlocked", unlock_callback):
			gameplay_flow.connect(&"world_progression_unlocked", unlock_callback)

	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_signal(&"npc_registered"):
		var registered_callback := Callable(self, "_on_npc_registered")
		if not locations.is_connected(&"npc_registered", registered_callback):
			locations.connect(&"npc_registered", registered_callback)


func get_save_data() -> Dictionary:
	return {
		"spot_runtime_states": spot_runtime_states.duplicate(true),
		"spot_reservations": spot_reservations.duplicate(true),
	}


func apply_save_data(data: Dictionary) -> void:
	spot_runtime_states.clear()
	spot_reservations.clear()
	var saved_states = data.get("spot_runtime_states", {})
	if saved_states is Dictionary:
		spot_runtime_states = saved_states.duplicate(true)
	var saved_reservations = data.get("spot_reservations", {})
	if saved_reservations is Dictionary:
		for reservation_key in saved_reservations.keys():
			var normalized := _normalize_reservation_record(
				StringName(String(reservation_key)),
				saved_reservations[reservation_key]
			)
			if not normalized.is_empty():
				spot_reservations[String(normalized["reservation_id"])] = normalized
	elif data.has("spot_claim_counts") and OS.is_debug_build():
		print("NPC reservation repair: ignored anonymous legacy spot claim counts.")
	_sync_spot_claim_count_cache()
	_initialize_definition_runtime_states()


func register_work_spot_state(
	spot_id: StringName,
	initial_value: float,
	minimum: float,
	maximum: float,
	daily_growth: float
) -> float:
	if spot_id == &"":
		return clampf(initial_value, minimum, maximum)

	var state_key := String(spot_id)
	var lower := minf(minimum, maximum)
	var upper := maxf(minimum, maximum)
	var state = spot_runtime_states.get(state_key, {})
	if not (state is Dictionary):
		state = {}
	if bool(state.get("meal_cycle_enabled", false)):
		state["kind"] = "meal_cycle"
	else:
		state["kind"] = "work"
	state["minimum"] = lower
	state["maximum"] = upper
	state["daily_growth"] = daily_growth
	state["value"] = clampf(float(state.get("value", initial_value)), lower, upper)
	spot_runtime_states[state_key] = state
	if bool(state.get("meal_cycle_enabled", false)):
		_notify_meal_cycle_state(StringName(state_key))
	return float(state["value"])


func set_work_spot_value(spot_id: StringName, value: float) -> void:
	set_spot_value(spot_id, value)


func get_spot_value(spot_id: StringName, fallback: float = 0.0) -> float:
	var state_key := String(spot_id)
	var state = spot_runtime_states.get(state_key, {})
	if not (state is Dictionary):
		return fallback

	return float(state.get("value", fallback))


func apply_spot_value_delta(spot_id: StringName, delta: float) -> float:
	var previous_value := get_spot_value(spot_id)
	set_spot_value(spot_id, previous_value + delta)
	return get_spot_value(spot_id) - previous_value


func set_spot_value(spot_id: StringName, value: float, allow_cycle_transition: bool = true) -> void:
	var state_key := String(spot_id)
	var state = spot_runtime_states.get(state_key, {})
	if not (state is Dictionary):
		return

	var previous_value := float(state.get("value", 0.0))
	var next_value := clampf(
		value,
		float(state.get("minimum", 0.0)),
		float(state.get("maximum", 100.0))
	)
	var done_threshold := float(state.get("done_threshold", 0.0))
	if absf(next_value - done_threshold) <= 0.001:
		next_value = done_threshold
	state["value"] = next_value
	spot_runtime_states[state_key] = state
	_notify_live_spot_value(spot_id, next_value)

	if _spot_state_is_meal_cycle_managed(state):
		if (
			allow_cycle_transition
			and bool(state.get("meal_cycle_enabled", false))
			and previous_value > done_threshold
			and next_value <= done_threshold
		):
			_advance_meal_cycle_work_complete(spot_id)
		elif (
			allow_cycle_transition
			and state.has("meal_cycle_controller_id")
		):
			_apply_meal_cycle_food_value_changed(spot_id, next_value)
		elif bool(state.get("meal_cycle_enabled", false)):
			_notify_meal_cycle_state(spot_id)
		else:
			_notify_meal_cycle_state(StringName(String(state.get("meal_cycle_controller_id", ""))))
		return

	if not allow_cycle_transition:
		return

	if previous_value > done_threshold and next_value <= done_threshold:
		_activate_linked_spot(spot_id)


func _activate_linked_spot(completed_spot_id: StringName) -> void:
	var definition := spot_definitions.get(completed_spot_id, null) as NpcSpotDefinition
	if definition == null or definition.next_spot_id_when_done == &"":
		return
	if not spot_runtime_states.has(String(definition.next_spot_id_when_done)):
		push_warning(
			"NPC spot '%s' completed but linked spot '%s' does not exist."
			% [String(completed_spot_id), String(definition.next_spot_id_when_done)]
		)
		return

	set_spot_value(
		definition.next_spot_id_when_done,
		definition.next_spot_value_when_done,
		false
	)
	_queue_simulation()


func _notify_live_spot_value(spot_id: StringName, value: float) -> void:
	var live_spot := live_spots.get(spot_id, null) as Node
	if live_spot == null or not is_instance_valid(live_spot):
		return
	if live_spot.has_method("apply_world_spot_value"):
		live_spot.call("apply_world_spot_value", spot_id, value)
		return
	if live_spot.has_method("apply_world_work_needed"):
		live_spot.call("apply_world_work_needed", value)


func _on_world_day_changed(_day: int, _snapshot: Dictionary) -> void:
	if _defer_simulation_while_world_progression_locked():
		return
	for spot_id_key in spot_runtime_states.keys():
		var state = spot_runtime_states[spot_id_key]
		if not (state is Dictionary):
			continue
		if _spot_state_is_meal_cycle_managed(state):
			continue

		var next_value := clampf(
			float(state.get("value", 0.0)) + float(state.get("daily_growth", 0.0)),
			float(state.get("minimum", 0.0)),
			float(state.get("maximum", 100.0))
		)
		set_spot_value(StringName(String(spot_id_key)), next_value)

	_queue_simulation()


func _on_world_hour_changed(_hour: int, snapshot: Dictionary) -> void:
	# Scheduled windows commonly open on the hour, so dispatch eligible owners immediately.
	if _defer_simulation_while_world_progression_locked():
		return
	if _world_simulation_debug_disabled():
		_log_world_simulation_disabled("hour_changed")
		return
	_process_meal_cycle_schedule_until_snapshot(snapshot)
	_queue_simulation()


func _on_npc_registered(_npc_id: String, npc: Node, _scene_path: String) -> void:
	var machine := npc.get_node_or_null("NpcStateMachine") if npc != null else null
	if machine == null or not machine.has_signal(&"state_changed"):
		return

	var callback := Callable(self, "_on_npc_state_changed")
	if not machine.is_connected(&"state_changed", callback):
		machine.connect(&"state_changed", callback)
	_queue_simulation()


func _on_npc_state_changed(state_name: StringName, _previous_state_name: StringName) -> void:
	# A routine that ended inside an active window should not wait for the fallback poll.
	if state_name == &"Idle":
		_queue_simulation()


func _on_world_progression_unlocked() -> void:
	if not simulation_dirty_while_locked:
		return
	simulation_dirty_while_locked = false
	_queue_simulation()


func _defer_simulation_while_world_progression_locked(mark_dirty: bool = true) -> bool:
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	var locked := (
		gameplay_flow != null
		and gameplay_flow.has_method("is_world_progression_locked")
		and bool(gameplay_flow.call("is_world_progression_locked"))
	)
	if locked and mark_dirty:
		simulation_dirty_while_locked = true
	return locked


func _queue_simulation() -> void:
	if _defer_simulation_while_world_progression_locked():
		return
	if _world_simulation_debug_disabled():
		_log_world_simulation_disabled("queue")
		return
	if simulation_queued:
		return

	simulation_queued = true
	call_deferred("_run_queued_simulation")


func _run_queued_simulation() -> void:
	if _defer_simulation_while_world_progression_locked():
		simulation_queued = false
		return
	if _world_simulation_debug_disabled():
		_log_world_simulation_disabled("queued")
		simulation_queued = false
		return
	simulation_queued = false
	simulate_now()


func _process(delta: float) -> void:
	if _defer_simulation_while_world_progression_locked(false):
		return
	if _world_simulation_debug_disabled():
		_log_world_simulation_disabled("process")
		return

	simulation_timer -= delta
	if simulation_timer > 0.0:
		return

	simulation_timer = maxf(simulation_interval_seconds, 0.1)
	simulate_now()


func simulate_now() -> void:
	# Only saved records are simulated; unloaded NPC scenes never need a running state machine.
	if _defer_simulation_while_world_progression_locked():
		return
	if _world_simulation_debug_disabled():
		_clear_all_social_selection_descriptors()
		_log_world_simulation_disabled("simulate_now")
		return

	var locations := get_node_or_null("/root/NpcLocations")
	var world_time := get_node_or_null("/root/WorldTime")
	if locations == null or world_time == null:
		return
	if (
		not locations.has_method("synchronize_live_records")
		or not locations.has_method("get_records_snapshot")
		or not world_time.has_method("get_snapshot")
	):
		return

	var profiling_enabled := performance_profiling_enabled
	var profile_total_start_usec := Time.get_ticks_usec() if profiling_enabled else 0
	var profile_synchronize_usec := 0
	var profile_snapshot_usec := 0
	var profile_preparation_usec := 0
	var profile_needs_usec := 0
	var profile_activity_usec := 0
	var profile_schedule_usec := 0
	var profile_travel_usec := 0
	var profile_records_simulated := 0
	var profile_live_records := 0
	var profile_disabled_records := 0
	if profiling_enabled:
		_performance_profile_social_usec_in_pass = 0
		_performance_profile_candidate_evaluations_in_pass = 0
		_performance_profile_apply_usec_in_pass = 0
		_performance_profile_records_applied_in_pass = 0

	var snapshot: Dictionary = world_time.call("get_snapshot")
	var total_hours := float(snapshot.get("total_hours", 0.0))
	var hour := float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))
	_process_meal_cycle_schedule_until_snapshot(snapshot)
	var profile_stage_start_usec := Time.get_ticks_usec() if profiling_enabled else 0
	locations.call("synchronize_live_records")
	if profiling_enabled:
		profile_synchronize_usec = Time.get_ticks_usec() - profile_stage_start_usec
		profile_stage_start_usec = Time.get_ticks_usec()
	var records: Dictionary = locations.call("get_records_snapshot")
	_prune_social_world_profile_validation(records)
	_social_planning_pass_id += 1
	_social_planner.begin_simulation_pass()
	_prune_social_selection_descriptors(records, locations)
	if profiling_enabled:
		profile_snapshot_usec = Time.get_ticks_usec() - profile_stage_start_usec
		profile_stage_start_usec = Time.get_ticks_usec()
	_breadcrumb("npc_world:simulate_start", "hour=%.3f records=%d" % [hour, records.size()])
	_rebuild_spot_claims(records)
	if profiling_enabled:
		profile_preparation_usec = Time.get_ticks_usec() - profile_stage_start_usec

	var deferred_social_seekers: Array[Dictionary] = []
	for npc_id_key in records.keys():
		var npc_id := StringName(String(npc_id_key))
		var player_runtime := get_node_or_null("/root/PlayerRuntime")
		if player_runtime != null and player_runtime.has_method("is_active_companion") and bool(player_runtime.call("is_active_companion", String(npc_id))):
			_clear_social_selection_descriptor(npc_id, locations)
			continue
		var record = records[npc_id_key]
		if not (record is Dictionary):
			_clear_social_selection_descriptor(npc_id, locations)
			continue
		if profiling_enabled:
			profile_records_simulated += 1
			if _record_is_disabled(record):
				profile_disabled_records += 1
		var record_dictionary: Dictionary = record
		if profiling_enabled:
			profile_stage_start_usec = Time.get_ticks_usec()
		_validate_social_world_profile(npc_id, record_dictionary)
		if profiling_enabled:
			profile_preparation_usec += (
				Time.get_ticks_usec() - profile_stage_start_usec
			)
		var activity_label := ""
		var activity_value = record_dictionary.get("activity", {})
		if activity_value is Dictionary:
			activity_label = String(activity_value.get("spot_id", ""))
		var pending_label := ""
		var pending_value = record_dictionary.get("pending_travel", {})
		if pending_value is Dictionary:
			pending_label = String(pending_value.get("mode", ""))
		_breadcrumb(
			"npc_world:evaluate_npc",
			"%s activity=%s pending=%s" % [
				String(npc_id),
				activity_label,
				pending_label,
			]
		)

		var npc_is_live := (
			locations.has_method("is_npc_live")
			and bool(locations.call("is_npc_live", String(npc_id)))
		)
		if profiling_enabled and npc_is_live:
			profile_live_records += 1
		var current_activity = record.get("activity", {})
		if not npc_is_live:
			var paused_state_name := &""
			if current_activity is Dictionary and not current_activity.is_empty():
				paused_state_name = StringName(String(current_activity.get("state_name", "")))
			if profiling_enabled:
				profile_stage_start_usec = Time.get_ticks_usec()
			_simulate_offscreen_passive_values(
				record,
				total_hours,
				paused_state_name,
				npc_id
			)
			if profiling_enabled:
				profile_needs_usec += Time.get_ticks_usec() - profile_stage_start_usec
			if locations.has_method("update_simulated_record"):
				_apply_simulated_record_update(locations, String(npc_id), record)

		var pending_travel = record.get("pending_travel", {})
		if pending_travel is Dictionary and not pending_travel.is_empty():
			_clear_social_selection_descriptor(npc_id, locations)
			if profiling_enabled:
				profile_stage_start_usec = Time.get_ticks_usec()
			_update_pending_travel(npc_id, record, pending_travel, hour, locations)
			if profiling_enabled:
				profile_travel_usec += Time.get_ticks_usec() - profile_stage_start_usec
			continue

		var activity = record.get("activity", {})
		if activity is Dictionary and not activity.is_empty():
			_clear_social_selection_descriptor(npc_id, locations)
			if profiling_enabled:
				profile_stage_start_usec = Time.get_ticks_usec()
			_update_activity(npc_id, record, activity, total_hours, hour, locations)
			if profiling_enabled:
				profile_activity_usec += Time.get_ticks_usec() - profile_stage_start_usec
		else:
			if _consume_sleep_skip_wake_pause(npc_id, record, locations):
				_clear_social_selection_descriptor(npc_id, locations)
				continue
			if profiling_enabled:
				profile_stage_start_usec = Time.get_ticks_usec()
			var inline_social_usec_before := (
				_performance_profile_social_usec_in_pass
			)
			_route_idle_activity_for_social_arbitration(
				npc_id,
				record,
				total_hours,
				hour,
				locations,
				records,
				deferred_social_seekers
			)
			if profiling_enabled:
				var inline_elapsed_usec := (
					Time.get_ticks_usec() - profile_stage_start_usec
				)
				var inline_social_usec := maxi(
					_performance_profile_social_usec_in_pass
						- inline_social_usec_before,
					0
				)
				profile_schedule_usec += maxi(
					inline_elapsed_usec - inline_social_usec,
					0
				)
	if profiling_enabled:
		profile_stage_start_usec = Time.get_ticks_usec()
	var deferred_social_usec_before := _performance_profile_social_usec_in_pass
	_process_deferred_social_seekers(
		deferred_social_seekers,
		total_hours,
		hour,
		locations,
		records
	)
	if profiling_enabled:
		var deferred_elapsed_usec := Time.get_ticks_usec() - profile_stage_start_usec
		var deferred_social_usec := maxi(
			_performance_profile_social_usec_in_pass
				- deferred_social_usec_before,
			0
		)
		profile_schedule_usec += maxi(
			deferred_elapsed_usec - deferred_social_usec,
			0
		)
	_breadcrumb("npc_world:simulate_end", "hour=%.3f" % hour)
	if profiling_enabled:
		_record_performance_profile(
			Time.get_ticks_usec() - profile_total_start_usec,
			profile_synchronize_usec,
			profile_snapshot_usec,
			profile_preparation_usec,
			profile_needs_usec,
			profile_activity_usec,
			profile_schedule_usec,
			profile_travel_usec,
			records.size(),
			profile_records_simulated,
			profile_live_records,
			profile_disabled_records
		)
	_social_planner.end_simulation_pass()


func _apply_simulated_record_update(locations: Node, npc_id: String, record: Dictionary) -> void:
	var profile_start_usec := Time.get_ticks_usec() if performance_profiling_enabled else 0
	locations.call("update_simulated_record", npc_id, record)
	if performance_profiling_enabled:
		_performance_profile_apply_usec_in_pass += Time.get_ticks_usec() - profile_start_usec
		_performance_profile_records_applied_in_pass += 1


func _record_performance_profile(
	total_usec: int,
	synchronize_usec: int,
	snapshot_usec: int,
	preparation_usec: int,
	needs_usec: int,
	activity_usec: int,
	schedule_usec: int,
	travel_usec: int,
	records_total: int,
	records_simulated: int,
	live_records: int,
	disabled_records: int
) -> void:
	_performance_profile_call_count += 1
	_performance_profile_total_usec += total_usec
	_performance_profile_max_total_usec = max(_performance_profile_max_total_usec, total_usec)
	_performance_profile_synchronize_usec += synchronize_usec
	_performance_profile_snapshot_usec += snapshot_usec
	_performance_profile_preparation_usec += preparation_usec
	_performance_profile_needs_usec += needs_usec
	_performance_profile_activity_usec += activity_usec
	_performance_profile_schedule_usec += schedule_usec
	_performance_profile_travel_usec += travel_usec
	_performance_profile_social_usec += _performance_profile_social_usec_in_pass
	_performance_profile_apply_usec += _performance_profile_apply_usec_in_pass
	_performance_profile_records_total += records_total
	_performance_profile_records_simulated += records_simulated
	_performance_profile_live_records += live_records
	_performance_profile_disabled_records += disabled_records
	_performance_profile_candidate_evaluations += _performance_profile_candidate_evaluations_in_pass
	_performance_profile_records_applied += _performance_profile_records_applied_in_pass

	if _performance_profile_call_count < PERFORMANCE_PROFILE_REPORT_WINDOW_CALLS:
		return

	var slowest_stage_name := "synchronize"
	var slowest_stage_usec := _performance_profile_synchronize_usec
	if _performance_profile_snapshot_usec > slowest_stage_usec:
		slowest_stage_name = "snapshot"
		slowest_stage_usec = _performance_profile_snapshot_usec
	if _performance_profile_preparation_usec > slowest_stage_usec:
		slowest_stage_name = "prepare"
		slowest_stage_usec = _performance_profile_preparation_usec
	if _performance_profile_needs_usec > slowest_stage_usec:
		slowest_stage_name = "needs"
		slowest_stage_usec = _performance_profile_needs_usec
	if _performance_profile_activity_usec > slowest_stage_usec:
		slowest_stage_name = "activity"
		slowest_stage_usec = _performance_profile_activity_usec
	if _performance_profile_schedule_usec > slowest_stage_usec:
		slowest_stage_name = "schedule"
		slowest_stage_usec = _performance_profile_schedule_usec
	if _performance_profile_travel_usec > slowest_stage_usec:
		slowest_stage_name = "travel"
		slowest_stage_usec = _performance_profile_travel_usec
	if _performance_profile_social_usec > slowest_stage_usec:
		slowest_stage_name = "social"
		slowest_stage_usec = _performance_profile_social_usec
	if _performance_profile_apply_usec > slowest_stage_usec:
		slowest_stage_name = "apply"
		slowest_stage_usec = _performance_profile_apply_usec

	var calls := float(_performance_profile_call_count)
	print_debug((
		"NPC world simulation profile (%d calls): total avg=%.3fms max=%.3fms "
		+ "sync=%.3f snapshot=%.3f prepare=%.3f needs=%.3f activity=%.3f "
		+ "schedule=%.3f travel=%.3f social=%.3f apply=%.3f "
		+ "records=%.1f simulated=%.1f live=%.1f disabled=%.1f candidates=%.1f applied=%.1f slowest=%s"
	) % [
			_performance_profile_call_count,
			_performance_profile_total_usec / calls / 1000.0,
			_performance_profile_max_total_usec / 1000.0,
			_performance_profile_synchronize_usec / calls / 1000.0,
			_performance_profile_snapshot_usec / calls / 1000.0,
			_performance_profile_preparation_usec / calls / 1000.0,
			_performance_profile_needs_usec / calls / 1000.0,
			_performance_profile_activity_usec / calls / 1000.0,
			_performance_profile_schedule_usec / calls / 1000.0,
			_performance_profile_travel_usec / calls / 1000.0,
			_performance_profile_social_usec / calls / 1000.0,
			_performance_profile_apply_usec / calls / 1000.0,
			_performance_profile_records_total / calls,
			_performance_profile_records_simulated / calls,
			_performance_profile_live_records / calls,
			_performance_profile_disabled_records / calls,
			_performance_profile_candidate_evaluations / calls,
			_performance_profile_records_applied / calls,
			slowest_stage_name,
		]
	)
	_reset_performance_profile()


func _reset_performance_profile() -> void:
	_performance_profile_call_count = 0
	_performance_profile_total_usec = 0
	_performance_profile_max_total_usec = 0
	_performance_profile_synchronize_usec = 0
	_performance_profile_snapshot_usec = 0
	_performance_profile_preparation_usec = 0
	_performance_profile_needs_usec = 0
	_performance_profile_activity_usec = 0
	_performance_profile_schedule_usec = 0
	_performance_profile_travel_usec = 0
	_performance_profile_social_usec = 0
	_performance_profile_apply_usec = 0
	_performance_profile_records_total = 0
	_performance_profile_records_simulated = 0
	_performance_profile_live_records = 0
	_performance_profile_disabled_records = 0
	_performance_profile_candidate_evaluations = 0
	_performance_profile_records_applied = 0


func simulate_player_sleep_skip(
	start_total_hours: float,
	end_total_hours: float,
	options: Dictionary = {}
) -> void:
	# Overnight player sleep refreshes body needs only; social stats/relationships are preserved.
	var elapsed_game_hours := maxf(end_total_hours - start_total_hours, 0.0)
	if elapsed_game_hours <= 0.0:
		return

	var locations := get_node_or_null("/root/NpcLocations")
	if (
		locations == null
		or not locations.has_method("synchronize_live_records")
		or not locations.has_method("get_record_ids_snapshot")
		or not locations.has_method("get_record_snapshot")
	):
		return

	locations.call("synchronize_live_records")
	var npc_ids: PackedStringArray = locations.call("get_record_ids_snapshot")
	for npc_id in npc_ids:
		var updated_record: Dictionary = locations.call("get_record_snapshot", npc_id)
		if updated_record.is_empty():
			continue

		var slept_during_skip := _apply_sleep_skip_body_values(
			npc_id,
			updated_record,
			start_total_hours,
			elapsed_game_hours,
			end_total_hours,
			options
		)

		if locations.has_method("apply_simulated_record"):
			locations.call("apply_simulated_record", npc_id, updated_record, true)
		elif locations.has_method("update_simulated_record"):
			locations.call("update_simulated_record", npc_id, updated_record)

		if locations.has_method("get_live_npc"):
			var live_npc := locations.call("get_live_npc", npc_id) as Node
			_wake_live_npc_after_sleep_skip(live_npc, slept_during_skip)

	_queue_simulation()


func simulate_companion_return_skip(
	start_total_hours: float,
	end_total_hours: float,
	companion_npc_id: String,
	travel_policy: TravelPolicy
) -> void:
	var elapsed_game_hours := maxf(end_total_hours - start_total_hours, 0.0)
	if elapsed_game_hours <= 0.0:
		return
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null:
		return
	locations.call("synchronize_live_records")
	var records: Dictionary = locations.call("get_records_snapshot")
	_social_planning_suppressed = true
	_social_planning_pass_id += 1
	_social_planner.begin_simulation_pass()
	var end_hour := fposmod(end_total_hours, 24.0)
	for npc_key in records.keys():
		var npc_id := String(npc_key)
		var record: Dictionary = records[npc_key]
		_clear_social_selection_descriptor(StringName(npc_id), locations)
		if npc_id == companion_npc_id:
			var multipliers := travel_policy.get_need_multipliers() if travel_policy != null else {}
			_needs_simulator.advance_needs(record, elapsed_game_hours, &"", multipliers)
			record["last_simulated_total_hours"] = end_total_hours
			locations.call("apply_simulated_record", npc_id, record, true)
			_simulate_live_companion_food(locations.call("get_live_npc", npc_id), travel_policy)
			continue
		_needs_simulator.advance_needs(record, elapsed_game_hours, &"")
		record["last_simulated_total_hours"] = end_total_hours
		var activity = record.get("activity", {})
		if activity is Dictionary and not activity.is_empty():
			_update_activity(StringName(npc_id), record, activity, end_total_hours, end_hour, locations)
		else:
			_try_start_activity(StringName(npc_id), record, end_total_hours, end_hour, locations, records)
		locations.call("apply_simulated_record", npc_id, record, true)
	_social_planner.end_simulation_pass()
	_social_planning_suppressed = false


func _simulate_live_companion_food(live_npc: Node, travel_policy: TravelPolicy) -> void:
	if live_npc == null or travel_policy == null or not travel_policy.inventory_eating_enabled:
		return
	var machine := live_npc.get_node_or_null("NpcStateMachine") as NpcStateMachine
	if machine == null or String(machine.current_state.name if machine.current_state != null else "") == "Fight":
		return
	var inventory: InventoryModel = live_npc.call("get_inventory")
	var food_service := FoodConsumptionService.new()
	var safety := 0
	while machine.get_value(&"hunger") >= 70.0 and safety < 8:
		var food_id := food_service.select_best_available_food(inventory)
		if food_id == &"" or not food_service.consume_for_npc(inventory, live_npc, food_id).success:
			break
		safety += 1


func _apply_sleep_skip_body_values(
	npc_id: String,
	record: Dictionary,
	start_total_hours: float,
	elapsed_game_hours: float,
	end_total_hours: float,
	options: Dictionary
) -> bool:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return _finalize_sleep_skip_record(npc_id, record, start_total_hours, end_total_hours)
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		return _finalize_sleep_skip_record(npc_id, record, start_total_hours, end_total_hours)

	var profile = node_state.get("world_simulation_profile", {})
	if not (profile is Dictionary):
		profile = {}
	var rates = profile.get("rates_per_game_hour", {})
	if not (rates is Dictionary):
		rates = {}

	var hunger_name := String(options.get("hunger_value_name", "hunger"))
	if not hunger_name.is_empty() and social_stats.has(hunger_name):
		var hunger_rate := float(rates.get(
			hunger_name,
			options.get("fallback_hunger_growth_per_game_hour", 7.0)
		))
		var max_wake_hunger := clampf(
			float(options.get("max_wake_hunger", DEFAULT_SLEEP_SKIP_WAKE_HUNGER_MAX)),
			0.0,
			100.0
		)
		social_stats[hunger_name] = clampf(
			float(social_stats.get(hunger_name, 0.0)) + hunger_rate * elapsed_game_hours,
			0.0,
			max_wake_hunger
		)

	var reset_values = options.get("body_reset_values", {})
	if not (reset_values is Dictionary) or reset_values.is_empty():
		reset_values = {
			"sleep_need": 0.0,
			"tired": 0.0,
		}
	for value_key in reset_values.keys():
		var value_name := String(value_key)
		if STORED_ONLY_VALUE_KEYS.has(value_name):
			continue
		if value_name.is_empty() or not social_stats.has(value_name):
			continue
		social_stats[value_name] = clampf(float(reset_values[value_key]), 0.0, 100.0)

	_apply_full_sleep_health_restore(record, social_stats, options)
	node_state["social_stats"] = social_stats
	record["node_state"] = node_state
	return _finalize_sleep_skip_record(npc_id, record, start_total_hours, end_total_hours)


func _finalize_sleep_skip_record(
	npc_id: String,
	record: Dictionary,
	start_total_hours: float,
	end_total_hours: float
) -> bool:
	return NpcSleepWakeResolver.finalize_sleep_skip_record(
		npc_id,
		record,
		start_total_hours,
		end_total_hours,
		self
	)


func _clear_sleep_activity_after_skip(record: Dictionary) -> bool:
	return NpcSleepWakeResolver.clear_sleep_activity_after_skip(record, self)


func _get_sleep_activity_from_pending(pending: Dictionary) -> Dictionary:
	return NpcSleepWakeResolver.get_sleep_activity_from_pending(pending)


func _move_record_to_sleep_skip_wake_destination(
	record: Dictionary,
	sleep_activity: Dictionary
) -> bool:
	return NpcSleepWakeResolver.move_record_to_sleep_skip_wake_destination(
		record,
		sleep_activity,
		self
	)


func _move_record_to_destination(record: Dictionary, destination: Dictionary) -> bool:
	return NpcSleepWakeResolver.move_record_to_destination(record, destination)


func _get_sleep_skip_wake_destination(
	record: Dictionary,
	sleep_activity: Dictionary
) -> Dictionary:
	return NpcSleepWakeResolver.get_sleep_skip_wake_destination(record, sleep_activity, self)


func _move_record_to_sleep_definition_for_skip(
	npc_id: String,
	record: Dictionary,
	start_total_hours: float,
	end_total_hours: float
) -> bool:
	return NpcSleepWakeResolver.move_record_to_sleep_definition_for_skip(
		npc_id,
		record,
		start_total_hours,
		end_total_hours,
		self
	)


func _find_sleep_definition_during_skip(
	npc_id: StringName,
	record: Dictionary,
	start_total_hours: float,
	end_total_hours: float
) -> NpcSpotDefinition:
	return NpcSleepWakeResolver.find_sleep_definition_during_skip(
		npc_id,
		record,
		start_total_hours,
		end_total_hours,
		self
	)


func _definition_is_active_during_interval(
	definition: NpcSpotDefinition,
	start_total_hours: float,
	end_total_hours: float
) -> bool:
	return NpcSleepWakeResolver.definition_is_active_during_interval(
		definition,
		start_total_hours,
		end_total_hours
	)


func _window_overlaps_interval(
	window: Dictionary,
	day: int,
	start_total_hours: float,
	end_total_hours: float
) -> bool:
	return NpcSleepWakeResolver.window_overlaps_interval(
		window,
		day,
		start_total_hours,
		end_total_hours
	)


func _get_sleep_activity_definition(sleep_activity: Dictionary) -> NpcSpotDefinition:
	return NpcSleepWakeResolver.get_sleep_activity_definition(sleep_activity, self)


func _get_wake_spot_destination(definition: NpcSpotDefinition) -> Dictionary:
	return NpcSleepWakeResolver.get_wake_spot_destination(definition, self)


func _get_explicit_wake_destination(definition: NpcSpotDefinition) -> Dictionary:
	return NpcSleepWakeResolver.get_explicit_wake_destination(definition)


func _get_record_home_destination(record: Dictionary) -> Dictionary:
	return NpcSleepWakeResolver.get_record_home_destination(record)


func _get_activity_target_destination(activity: Dictionary) -> Dictionary:
	return NpcSleepWakeResolver.get_activity_target_destination(activity, self)


func _get_activity_return_destination(
	record: Dictionary,
	activity: Dictionary
) -> Dictionary:
	return NpcSleepWakeResolver.get_activity_return_destination(record, activity)


func _wake_live_npc_after_sleep_skip(live_npc: Node, slept_during_skip: bool = false) -> void:
	if live_npc == null or not is_instance_valid(live_npc):
		return

	var machine := live_npc.get_node_or_null("NpcStateMachine")
	if machine == null or not machine.has_method("request_state"):
		return

	if slept_during_skip:
		var sleep_skip_state = machine.get("current_state")
		if (
			sleep_skip_state != null
			and String(sleep_skip_state.name) != "Idle"
			and machine.has_method("suppress_next_idle_value_reaction")
		):
			machine.call("suppress_next_idle_value_reaction")
		_prepare_live_npc_after_sleep_skip(live_npc, machine)
		var wake_accepted := bool(machine.call(
			"request_state", &"Idle", null, "player_sleep_skip_wake", 1000
		))
		if not wake_accepted:
			_breadcrumb("npc_world:sleep_skip_wake_reject", live_npc.name)
		return

	var current_state = machine.get("current_state")
	if current_state == null:
		return
	if not ["Sleep", "Collapse", "Rest"].has(String(current_state.name)):
		return

	var idle_accepted := bool(machine.call(
		"request_state", &"Idle", null, "player_sleep_skip", 100
	))
	if not idle_accepted:
		_breadcrumb("npc_world:sleep_skip_idle_reject", live_npc.name)


func _prepare_live_npc_after_sleep_skip(live_npc: Node, machine: Node) -> void:
	if live_npc is CharacterBody2D:
		(live_npc as CharacterBody2D).velocity = Vector2.ZERO

	machine.set("move_target", null)
	machine.set("sleep_target", null)
	machine.set("state_after_move", &"Idle")
	if machine.has_method("set_target"):
		machine.call("set_target", null)


func _simulate_offscreen_passive_values(
	record: Dictionary,
	total_hours: float,
	paused_state_name: StringName,
	canonical_npc_id: StringName = &""
) -> void:
	var last_total_hours := float(record.get("last_simulated_total_hours", total_hours))
	var elapsed_game_hours := maxf(total_hours - last_total_hours, 0.0)
	record["last_simulated_total_hours"] = total_hours
	if not _needs_simulator.advance_needs(record, elapsed_game_hours, paused_state_name):
		return

	var node_state = record.get("node_state", {})
	var profile = node_state.get("world_simulation_profile", {})
	if not (profile is Dictionary):
		profile = {}
	_decay_offscreen_relationships(
		record,
		profile,
		elapsed_game_hours,
		canonical_npc_id
	)


func _apply_full_sleep_health_restore(
	record: Dictionary,
	social_stats: Dictionary,
	options: Dictionary
) -> void:
	if _record_is_disabled(record):
		return

	var health_value_name := String(options.get("health_value_name", "hp"))
	if (
		health_value_name.is_empty()
		or STORED_ONLY_VALUE_KEYS.has(health_value_name)
		or not social_stats.has(health_value_name)
	):
		return

	var full_health := clampf(float(options.get("full_sleep_hp", 100.0)), 0.0, 100.0)
	social_stats[health_value_name] = full_health


func _consume_sleep_skip_wake_pause(
	npc_id: StringName,
	record: Dictionary,
	locations: Node
) -> bool:
	if not bool(record.get("skip_next_activity_start_after_sleep", false)):
		return false

	record.erase("skip_next_activity_start_after_sleep")
	if locations != null and locations.has_method("apply_simulated_record"):
		locations.call("apply_simulated_record", String(npc_id), record, false)
	elif locations != null and locations.has_method("update_simulated_record"):
		_apply_simulated_record_update(locations, String(npc_id), record)
	return true


func _decay_offscreen_relationships(
	record: Dictionary,
	profile: Dictionary,
	game_hours: float,
	canonical_npc_id: StringName = &""
) -> void:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return
	var owner_id := String(canonical_npc_id).strip_edges()
	if owner_id.is_empty():
		owner_id = String(record.get("npc_id", "")).strip_edges()
	var legacy_owner_id := String(node_state.get("relationship_id", "")).strip_edges()
	if owner_id.is_empty():
		# Compatibility for hand-built/legacy records that have not yet passed
		# through NpcLocations, which supplies the canonical record key above.
		owner_id = legacy_owner_id
	if owner_id.is_empty():
		return

	var relationships := get_node_or_null("/root/Relationships")
	if relationships == null:
		return
	var decay_owner_id := owner_id
	if (
		not legacy_owner_id.is_empty()
		and legacy_owner_id != owner_id
		and relationships.has_method("migrate_relationship_alias")
	):
		var migration_result = relationships.call(
			"migrate_relationship_alias",
			legacy_owner_id,
			owner_id
		)
		if (
			migration_result is Dictionary
			and not bool(migration_result.get("accepted", false))
		):
			# Raw hand-built/legacy location records can still carry a transient
			# key. When it cannot be canonicalized, decay the exact relationship
			# owner already stored in the record instead of silently doing nothing.
			decay_owner_id = legacy_owner_id

	var anger_decay = profile.get("anger_decay", {})
	if anger_decay is Dictionary and bool(anger_decay.get("enabled", false)):
		var full_hours := maxf(float(anger_decay.get("full_decay_game_hours", 4.0)), 0.001)
		if relationships.has_method("decay_anger_for_id"):
			relationships.call(
				"decay_anger_for_id",
				decay_owner_id,
				(100.0 / full_hours) * game_hours
			)

	var fear_decay = profile.get("fear_decay", {})
	if fear_decay is Dictionary and bool(fear_decay.get("enabled", false)):
		if relationships.has_method("decay_fear_for_id"):
			relationships.call(
				"decay_fear_for_id",
				decay_owner_id,
				game_hours,
				float(fear_decay.get("panic_floor", 90.0)),
				float(fear_decay.get("panic_cooldown_game_hours", 1.0 / 6.0)),
				float(fear_decay.get("slow_decay_per_game_hour", 5.0)),
				float(fear_decay.get("stop_value", 69.9))
			)


func register_live_spot(spot_id: StringName, spot: Node2D) -> void:
	if spot_id == &"" or spot == null:
		return
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if _debug_definition_disabled(definition):
		_breadcrumb("npc_world:register_spot_skip", String(spot_id))
		return
	var existing := live_spots.get(spot_id, null) as Node2D
	if existing != null and is_instance_valid(existing) and existing != spot:
		push_warning("Duplicate live NPC spot id '%s'; keeping the first spot." % String(spot_id))
		return

	live_spots[spot_id] = spot
	_validate_live_spot_alignment(spot_id, spot)


func unregister_live_spot(spot_id: StringName, spot: Node2D) -> void:
	if spot_id == &"" or live_spots.get(spot_id, null) != spot:
		return

	live_spots.erase(spot_id)


func _get_live_activity_spot(
	spot_id: StringName,
	definition: NpcSpotDefinition,
	activity: Dictionary
) -> Node2D:
	var live_spot := live_spots.get(spot_id, null) as Node2D
	if live_spot != null and is_instance_valid(live_spot):
		return live_spot
	if definition == null or definition.state_name != INVITE_PLAYER_STATE:
		return null
	if String(activity.get("lesson_phase", "inviting")) != "inviting":
		return null

	return _get_or_create_remote_invitation_spot(spot_id, definition, activity)


func _get_or_create_remote_invitation_spot(
	spot_id: StringName,
	definition: NpcSpotDefinition,
	activity: Dictionary
) -> Node2D:
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return null

	for node in get_tree().get_nodes_in_group("magic_lesson_remote_invitation"):
		var remote := node as MagicLessonRemoteInvitation
		if remote == null or not is_instance_valid(remote):
			continue
		if String(remote.spot_id) != String(spot_id):
			continue
		remote.configure(definition, activity)
		return remote

	var remote := MagicLessonRemoteInvitationScene.new() as MagicLessonRemoteInvitation
	if remote == null:
		return null
	remote.name = "RemoteMagicLessonInvitation_%s" % String(spot_id)
	remote.add_to_group("magic_lesson_remote_invitation")
	remote.configure(definition, activity)
	scene_root.add_child(remote)
	return remote


func resume_live_activity(npc_id: StringName, npc: Node) -> void:
	# Reconnects a spawned NPC to the real spot and normal state machine for the loaded scene.
	if (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_NPC_LIVE_ACTIVITY_RESUME
	):
		_breadcrumb("npc_world:resume_live_skip", String(npc_id))
		return

	_breadcrumb("npc_world:resume_live_start", String(npc_id))
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_npc_location"):
		_breadcrumb("npc_world:resume_live_no_locations", String(npc_id))
		return
	if (
		npc == null
		or not is_instance_valid(npc)
		or npc.is_queued_for_deletion()
		or not locations.has_method("get_live_npc")
		or locations.call("get_live_npc", String(npc_id)) != npc
	):
		_breadcrumb("npc_world:resume_live_stale_body", String(npc_id))
		return

	var record: Dictionary = locations.call("get_npc_location", String(npc_id))
	var pending_travel = record.get("pending_travel", {})
	if pending_travel is Dictionary and not pending_travel.is_empty():
		_resume_pending_travel(npc_id, npc, pending_travel, locations)
		return

	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		_breadcrumb("npc_world:resume_live_no_activity", String(npc_id))
		return
	if NpcRouteLocationCoordinator.record_has_finish_replan_marker(record, activity):
		_breadcrumb("npc_world:resume_live_finish_replan", String(npc_id))
		_finish_activity(
			npc_id,
			record,
			activity,
			StringName(String(activity.get("spot_id", ""))),
			locations
		)
		return

	var spot_id := StringName(String(activity.get("spot_id", "")))
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition == null:
		_breadcrumb("npc_world:resume_live_missing_definition", "%s %s" % [String(npc_id), String(spot_id)])
		_rollback_committed_live_activity(
			npc_id, activity, spot_id, locations, "spot_definition_missing"
		)
		return
	var spot := _get_live_activity_spot(spot_id, definition, activity)
	if spot == null or not is_instance_valid(spot):
		_breadcrumb("npc_world:resume_live_missing_spot", "%s %s" % [String(npc_id), String(spot_id)])
		_rollback_committed_live_activity(npc_id, activity, spot_id, locations, "live_spot_missing")
		return
	if _debug_definition_disabled(definition):
		_breadcrumb("npc_world:resume_live_disabled_definition", "%s %s" % [String(npc_id), String(spot_id)])
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	var total_hours := _get_current_total_hours()
	var hour := fposmod(total_hours, 24.0)
	if not _activity_can_continue(
		npc_id, record, definition, activity, total_hours, hour
	):
		_breadcrumb("npc_world:resume_live_finish_invalid", "%s %s" % [String(npc_id), String(spot_id)])
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return

	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		_breadcrumb("npc_world:resume_live_no_machine", String(npc_id))
		_rollback_committed_live_activity(
			npc_id, activity, spot_id, locations, "state_machine_missing"
		)
		return
	if not _live_activity_can_continue(npc_id, npc, machine, definition, spot):
		_breadcrumb("npc_world:resume_live_finish_live_invalid", "%s %s" % [String(npc_id), String(spot_id)])
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	var activity_descriptor := _get_activity_descriptor(definition, spot, activity)
	if not _npc_is_following_activity(machine, definition, spot, activity):
		if locations.has_method("is_npc_available_for_scheduled_activity"):
			if not bool(locations.call(
				"is_npc_available_for_scheduled_activity",
				String(npc_id),
				definition.state_name,
				int(activity.get("priority", definition.priority)),
				activity_descriptor
			)):
				_breadcrumb("npc_world:resume_live_unavailable", "%s %s" % [String(npc_id), String(spot_id)])
				_rollback_committed_live_activity(
					npc_id, activity, spot_id, locations, "npc_unavailable"
				)
				return
	var lesson_resume_result := _resume_accepted_invitation_activity(
		npc_id,
		npc,
		definition,
		spot,
		activity
	)
	var lesson_controller_started := false
	if bool(lesson_resume_result.get("handled", false)):
		if not bool(lesson_resume_result.get("accepted", false)):
			_rollback_committed_live_activity(
				npc_id,
				activity,
				spot_id,
				locations,
				String(lesson_resume_result.get("reason", "lesson_start_rejected"))
			)
			return
		lesson_controller_started = true
		_breadcrumb("npc_world:resume_live_started_accepted_lesson", "%s %s" % [String(npc_id), String(spot_id)])
	if _npc_is_following_activity(machine, definition, spot, activity):
		_breadcrumb("npc_world:resume_live_already_following", "%s %s" % [String(npc_id), String(spot_id)])
		return

	var assignment_result := _request_live_activity_assignment(
		machine,
		definition,
		spot,
		activity
	)
	if bool(assignment_result.get("accepted", false)):
		_breadcrumb("npc_world:resume_live_assigned", "%s %s" % [String(npc_id), String(spot_id)])
		return
	var assignment_reason := String(assignment_result.get("reason", "assignment_rejected"))
	if lesson_controller_started:
		_cancel_started_lesson_after_assignment_failure(spot, activity)
	_rollback_committed_live_activity(
		npc_id,
		activity,
		spot_id,
		locations,
		assignment_reason
	)


func _cancel_started_lesson_after_assignment_failure(
	spot: Node2D,
	activity: Dictionary
) -> void:
	if spot == null or not is_instance_valid(spot):
		return
	var session_id := NpcActionSessionModel._descriptor_session_id(activity)
	if session_id.is_empty():
		return
	if _method_accepts_argument_count(spot, &"cancel_lesson", 2):
		spot.call("cancel_lesson", &"live_assignment_failed", session_id)


func _rollback_committed_live_activity(
	npc_id: StringName,
	activity: Dictionary,
	spot_id: StringName,
	locations: Node,
	reason: String
) -> void:
	var rolled_back := false
	if locations != null and locations.has_method("rollback_scheduled_activity"):
		rolled_back = bool(locations.call(
			"rollback_scheduled_activity",
			String(npc_id),
			activity,
			reason
		))
	if rolled_back:
		release_scheduled_activity_claim(
			spot_id,
			reason,
			NpcActionSessionModel._descriptor_session_id(activity),
			npc_id
		)
	_log_activity_transaction(
		npc_id,
		activity,
		spot_id,
		"rollback" if rolled_back else "rollback_failed",
		reason
	)


func _live_activity_can_continue(
	npc_id: StringName,
	npc: Node,
	machine: Node,
	definition: NpcSpotDefinition,
	spot: Node2D
) -> bool:
	if definition == null:
		return false

	var value_name := String(definition.value_name)
	if (
		definition.finish_when_npc_value_sated
		and not value_name.is_empty()
		and machine.has_method("get_value")
		and float(machine.call("get_value", StringName(value_name))) <= 0.0
	):
		_mark_meal_owner_sated_if_needed(definition, npc_id, StringName(value_name))
		return false

	if definition.state_name == INVITE_PLAYER_STATE:
		if spot == null or not is_instance_valid(spot):
			return false
		if spot.has_method("is_lesson_spot_enabled"):
			if not bool(spot.call("is_lesson_spot_enabled")):
				return false
		if not spot.has_method("can_start_lesson"):
			return true
		var inviter_2d := npc as Node2D
		var player := get_tree().get_first_node_in_group("player") as Node2D
		if inviter_2d == null or player == null:
			return false
		return bool(spot.call("can_start_lesson", inviter_2d, player))

	if spot == null or not is_instance_valid(spot):
		return false

	var npc_2d := npc as Node2D
	if npc_2d == null:
		return false
	if spot.has_method("can_serve_npc_need"):
		return bool(spot.call(
			"can_serve_npc_need",
			npc_2d,
			definition.state_name,
			StringName(value_name)
		))
	if spot.has_method("can_serve_npc_casual_activity"):
		return bool(spot.call(
			"can_serve_npc_casual_activity",
			npc_2d,
			definition.state_name
		))
	return true


func _resume_accepted_invitation_activity(
	npc_id: StringName,
	npc: Node,
	definition: NpcSpotDefinition,
	spot: Node2D,
	activity: Dictionary
) -> Dictionary:
	if definition == null or definition.state_name != INVITE_PLAYER_STATE:
		return {"handled": false}
	var lesson_phase := String(activity.get("lesson_phase", "inviting"))
	if lesson_phase not in ["handoff", "accepted", "running"]:
		return {"handled": false}
	if spot == null or not is_instance_valid(spot):
		return {"handled": true, "accepted": false, "reason": "lesson_spot_missing"}
	if not spot.has_method("start_lesson"):
		return {"handled": true, "accepted": false, "reason": "lesson_start_method_missing"}

	var npc_2d := npc as Node2D
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if npc_2d == null or player == null:
		return {"handled": true, "accepted": false, "reason": "lesson_participant_missing"}
	var session_id := NpcActionSessionModel._descriptor_session_id(activity)
	if session_id.is_empty():
		return {"handled": true, "accepted": false, "reason": "lesson_session_missing"}
	if spot.has_method("is_lesson_active_for"):
		if bool(spot.call("is_lesson_active_for", npc_2d, player)):
			var owned_session := (
				String(spot.call("get_active_lesson_session_id"))
				if spot.has_method("get_active_lesson_session_id")
				else ""
			)
			if owned_session == session_id:
				return {"handled": true, "accepted": true, "reason": "already_running"}
			return {"handled": true, "accepted": false, "reason": "local_session_mismatch"}

	if lesson_phase == "running" and OS.is_debug_build():
		push_warning("Magic lesson phase is running without a local controller; attempting resumable startup: npc=%s session=%s" % [
			String(npc_id), session_id
		])
	var start_result = spot.call("start_lesson", npc_2d, player, session_id)
	if start_result is Dictionary:
		return {
			"handled": true,
			"accepted": bool(start_result.get("accepted", false)),
			"reason": String(start_result.get("reason", "lesson_start_rejected")),
		}
	return {
		"handled": true,
		"accepted": bool(start_result),
		"reason": "legacy_lesson_start_result",
		"npc_id": String(npc_id),
	}


func _npc_is_following_activity(
	machine: Node,
	definition: NpcSpotDefinition,
	spot: Node2D,
	activity: Dictionary = {}
) -> bool:
	if machine == null or definition == null:
		return false
	var requested_descriptor := _get_activity_descriptor(definition, spot, activity)
	if machine.has_method("is_following_activity_descriptor"):
		return bool(machine.call("is_following_activity_descriptor", requested_descriptor))

	# Compatibility for older/simple machines still requires the exact live target.
	var current_state = machine.get("current_state")
	if current_state != null and _state_names_match(StringName(current_state.name), definition.state_name):
		return _get_legacy_machine_activity_target(machine, definition.state_name) == spot
	if current_state == null or String(current_state.name) != "MoveToTarget":
		return false
	return (
		_get_property_if_present(machine, &"move_target", null) == spot
		and _state_names_match(
			StringName(_get_property_if_present(machine, &"state_after_move", &"")),
			definition.state_name
		)
	)


func _get_activity_descriptor(
	definition: NpcSpotDefinition,
	spot: Node2D = null,
	activity: Dictionary = {}
) -> Dictionary:
	if definition == null:
		return {}
	var action_kind := StringName(String(activity.get("state_name", definition.state_name)))
	var spot_id := StringName(String(activity.get("spot_id", definition.spot_id)))
	var scene_path := String(activity.get("target_scene_path", definition.scene_path))
	var descriptor := NpcActivityIdentity.describe(
		action_kind,
		spot,
		spot_id,
		scene_path,
		String(activity.get("activity_id", "")),
		String(activity.get("request_id", ""))
	)
	var session_id := NpcActionSessionModel._descriptor_session_id(activity)
	if not session_id.is_empty():
		descriptor["session_id"] = session_id
		descriptor["action_session_id"] = session_id
	if activity.has("priority"):
		descriptor["priority"] = int(activity["priority"])
	for schedule_key in SCHEDULE_METADATA_KEYS:
		if activity.has(schedule_key):
			descriptor[schedule_key] = activity[schedule_key]
	return descriptor


func _get_pending_travel_activity_descriptor(
	pending_travel: Dictionary,
	locations: Node
) -> Dictionary:
	var nested_activity = pending_travel.get("activity", {})
	if nested_activity is Dictionary and not nested_activity.is_empty():
		var nested_spot_id := StringName(String(nested_activity.get("spot_id", "")))
		var nested_definition := spot_definitions.get(nested_spot_id, null) as NpcSpotDefinition
		if nested_definition != null:
			var nested_spot := live_spots.get(nested_spot_id, null) as Node2D
			return _get_activity_descriptor(nested_definition, nested_spot, nested_activity)

	var requested_state := StringName(String(pending_travel.get("requested_state_name", "")))
	var target_npc_id := String(pending_travel.get("social_target_id", "")).strip_edges()
	var live_target: Node2D
	if target_npc_id == PLAYER_SOCIAL_TARGET_ID:
		live_target = get_tree().get_first_node_in_group("player") as Node2D
	elif not target_npc_id.is_empty() and locations != null and locations.has_method("get_live_npc"):
		live_target = locations.call("get_live_npc", target_npc_id) as Node2D

	return NpcActivityIdentity.describe(
		requested_state,
		live_target,
		StringName(String(pending_travel.get("spot_id", ""))),
		String(pending_travel.get("target_scene_path", "")),
		String(pending_travel.get("activity_id", "")),
		String(pending_travel.get("request_id", "")),
		target_npc_id
	)


func accept_scheduled_activity_proposal(
	npc_id: StringName,
	activity: Dictionary,
	target_scene_path: String,
	live_npc: Node,
	requires_live_assignment: bool,
	locations: Node
) -> Dictionary:
	var spot_id := StringName(String(activity.get("spot_id", "")))
	var session_id := NpcActionSessionModel._descriptor_session_id(activity)
	var purpose := StringName(String(activity.get("reservation_purpose", "activity")))
	var pending_reservation := _pending_activity_reservation_matches(
		npc_id,
		activity,
		locations
	)
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	var validation_reason := _validate_activity_proposal(
		npc_id,
		activity,
		target_scene_path,
		definition
	)
	if not validation_reason.is_empty():
		return _reject_activity_proposal(
			npc_id, activity, spot_id, validation_reason, "", false, pending_reservation
		)

	var claim_result := try_claim_spot(npc_id, session_id, spot_id, purpose)
	if not bool(claim_result.get("accepted", false)):
		return _reject_activity_proposal(
			npc_id,
			activity,
			spot_id,
			String(claim_result.get("status", "spot_capacity_unavailable")),
			"",
			false,
			pending_reservation
		)
	var reservation_id := String(claim_result.get("reservation_id", ""))
	var claimed_new := String(claim_result.get("status", "")) == "claimed"
	_add_descriptor_reservation_id(activity, reservation_id)
	_log_activity_transaction(
		npc_id,
		activity,
		spot_id,
		"reserved",
		String(claim_result.get("status", "claimed"))
	)

	if not requires_live_assignment:
		_log_activity_transaction(npc_id, activity, spot_id, "accepted", "offscreen_validated")
		return {
			"accepted": true,
			"reason": "offscreen_validated",
			"spot_id": String(spot_id),
			"live_assigned": false,
		}

	if live_npc == null or not is_instance_valid(live_npc):
		return _reject_activity_proposal(
			npc_id, activity, spot_id, "live_npc_invalid", reservation_id, claimed_new, pending_reservation
		)
	var spot := _get_live_activity_spot(spot_id, definition, activity)
	if spot == null or not is_instance_valid(spot):
		return _reject_activity_proposal(
			npc_id, activity, spot_id, "live_spot_missing", reservation_id, claimed_new, pending_reservation
		)
	var machine := live_npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return _reject_activity_proposal(
			npc_id, activity, spot_id, "state_machine_missing", reservation_id, claimed_new, pending_reservation
		)
	if not _live_activity_can_continue(npc_id, live_npc, machine, definition, spot):
		return _reject_activity_proposal(
			npc_id, activity, spot_id, "live_target_rejected", reservation_id, claimed_new, pending_reservation
		)

	var descriptor := _get_activity_descriptor(definition, spot, activity)
	if not _npc_is_following_activity(machine, definition, spot, activity):
		if locations == null or not locations.has_method("is_npc_available_for_scheduled_activity"):
			return _reject_activity_proposal(
				npc_id, activity, spot_id, "availability_check_missing", reservation_id, claimed_new, pending_reservation
			)
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			definition.state_name,
			int(activity.get("priority", definition.priority)),
			descriptor
		)):
			return _reject_activity_proposal(
				npc_id, activity, spot_id, "npc_unavailable", reservation_id, claimed_new, pending_reservation
			)

	var assignment_result := _request_live_activity_assignment(
		machine,
		definition,
		spot,
		activity
	)
	if not bool(assignment_result.get("accepted", false)):
		return _reject_activity_proposal(
			npc_id,
			activity,
			spot_id,
			String(assignment_result.get("reason", "assignment_rejected")),
			reservation_id,
			claimed_new,
			pending_reservation
		)

	_log_activity_transaction(npc_id, activity, spot_id, "accepted", "live_assignment_accepted")
	return {
		"accepted": true,
		"reason": "live_assignment_accepted",
		"spot_id": String(spot_id),
		"live_assigned": true,
	}


func confirm_scheduled_activity_proposal(npc_id: StringName, activity: Dictionary) -> void:
	var spot_id := StringName(String(activity.get("spot_id", "")))
	_log_activity_transaction(npc_id, activity, spot_id, "committed", "record_committed")
	_clear_schedule_decision_debug(npc_id)
	var session_id := NpcActionSessionModel._descriptor_session_id(activity)
	if not session_id.is_empty():
		_schedule_overtime_last_observed_by_session[session_id] = _get_current_total_hours()
		var locations := get_node_or_null("/root/NpcLocations")
		_schedule_overtime_last_observed_live_by_session[session_id] = (
			locations != null
			and locations.has_method("is_npc_live")
			and bool(locations.call("is_npc_live", String(npc_id)))
		)
	scheduled_activity_committed.emit(npc_id, activity.duplicate(true))


func release_scheduled_activity_claim(
	spot_id: StringName,
	reason: String = "released",
	session_id: String = "",
	npc_id: StringName = &""
) -> bool:
	var released := 0
	for reservation_id in spot_reservations.keys().duplicate():
		var reservation: Dictionary = spot_reservations[reservation_id]
		if String(reservation.get("spot_id", "")) != String(spot_id):
			continue
		if not session_id.is_empty() and String(reservation.get("session_id", "")) != session_id:
			continue
		if npc_id != &"" and String(reservation.get("npc_id", "")) != String(npc_id):
			continue
		if release_spot_reservation(String(reservation_id), npc_id, session_id):
			released += 1
	if OS.is_debug_build():
		print("NPC activity claim release: session=%s spot=%s reason=%s released=%d" % [
			session_id, String(spot_id), reason, released
		])
	return released > 0


func _validate_activity_proposal(
	npc_id: StringName,
	activity: Dictionary,
	target_scene_path: String,
	definition: NpcSpotDefinition
) -> String:
	if activity.is_empty():
		return "activity_empty"
	var spot_id := StringName(String(activity.get("spot_id", "")))
	if spot_id == &"":
		return "spot_id_missing"
	if definition == null:
		return "spot_definition_missing"
	if _debug_definition_disabled(definition):
		return "spot_definition_disabled"
	if target_scene_path.is_empty():
		return "target_scene_missing"
	var activity_scene := String(activity.get("target_scene_path", target_scene_path))
	if activity_scene.is_empty() or activity_scene != target_scene_path:
		return "target_scene_mismatch"
	var requested_state := StringName(String(activity.get("state_name", "")))
	if requested_state == &"" or not _state_names_match(requested_state, definition.state_name):
		return "activity_state_mismatch"
	if (
		_definition_is_meal_cycle_managed(definition)
		and not _meal_cycle_definition_can_start(
			definition,
			npc_id,
			_get_current_time_of_day_hours()
		)
	):
		return "meal_cycle_unavailable"
	if not _definition_is_meal_cycle_managed(definition) and not definition.allows_npc_id(npc_id):
		return "npc_not_allowed_for_spot"
	if not _spot_runtime_is_available(definition):
		return "spot_runtime_unavailable"
	return ""


func _request_live_activity_assignment(
	machine: Node,
	definition: NpcSpotDefinition,
	spot: Node2D,
	activity: Dictionary
) -> Dictionary:
	if (
		_npc_is_following_activity(machine, definition, spot, activity)
		and not machine.has_method("request_action_from_descriptor")
	):
		return {"accepted": true, "reason": "already_following"}

	if machine.has_method("request_action_from_descriptor"):
		var action_descriptor := activity.duplicate(true)
		action_descriptor["action_kind"] = String(definition.state_name)
		action_descriptor["source"] = String(activity.get("source", "schedule"))
		action_descriptor["priority"] = int(activity.get(
			"priority",
			definition.priority
		))
		action_descriptor["status"] = "proposed"
		action_descriptor["scene_path"] = String(activity.get(
			"target_scene_path", definition.scene_path
		))
		var session_accepted := bool(machine.call(
			"request_action_from_descriptor", action_descriptor, spot
		))
		if session_accepted:
			return {"accepted": true, "reason": "action_session_accepted"}
		var session_reason := "assignment_rejected"
		if machine.has_method("get_last_state_request_failure_reason"):
			session_reason = String(machine.call("get_last_state_request_failure_reason"))
			if session_reason.is_empty():
				session_reason = "assignment_rejected"
		return {"accepted": false, "reason": session_reason}

	var accepted := false
	var assignment_method := definition.get_assignment_method()
	if assignment_method != &"":
		if not machine.has_method(assignment_method):
			return {"accepted": false, "reason": "assignment_method_missing"}
		accepted = bool(machine.call(
			assignment_method,
			spot,
			int(activity.get("priority", definition.priority))
		))
	else:
		if not machine.has_method("request_state"):
			return {"accepted": false, "reason": "state_request_method_missing"}
		accepted = bool(machine.call(
			"request_state",
			definition.state_name,
			spot,
			"world_activity",
			int(activity.get("priority", definition.priority))
		))

	if accepted:
		return {"accepted": true, "reason": "assignment_accepted"}
	var reason := "assignment_rejected"
	if machine.has_method("get_last_state_request_failure_reason"):
		var machine_reason := String(machine.call("get_last_state_request_failure_reason"))
		if not machine_reason.is_empty():
			reason = machine_reason
	return {"accepted": false, "reason": reason}


func _pending_activity_reservation_matches(
	npc_id: StringName,
	activity: Dictionary,
	locations: Node
) -> bool:
	if locations == null or not locations.has_method("get_npc_location"):
		return false
	var record = locations.call("get_npc_location", String(npc_id))
	if not (record is Dictionary):
		return false
	var pending = record.get("pending_travel", {})
	if not (pending is Dictionary):
		return false
	var pending_activity = pending.get("activity", {})
	if not (pending_activity is Dictionary):
		return false
	return (
		String(pending_activity.get("spot_id", "")) == String(activity.get("spot_id", ""))
		and String(pending_activity.get("state_name", "")) == String(activity.get("state_name", ""))
	)


func _reject_activity_proposal(
	npc_id: StringName,
	activity: Dictionary,
	spot_id: StringName,
	reason: String,
	reservation_id: String,
	claimed_new: bool,
	clear_pending: bool
) -> Dictionary:
	if claimed_new and not reservation_id.is_empty():
		release_spot_reservation(
			reservation_id,
			npc_id,
			NpcActionSessionModel._descriptor_session_id(activity)
		)
	_log_activity_transaction(npc_id, activity, spot_id, "rejected", reason)
	if claimed_new:
		_log_activity_transaction(npc_id, activity, spot_id, "rollback", reason)
	return {
		"accepted": false,
		"reason": reason,
		"spot_id": String(spot_id),
		"live_assigned": false,
		"clear_pending": clear_pending,
	}


func _log_activity_transaction(
	npc_id: StringName,
	activity: Dictionary,
	spot_id: StringName,
	result: String,
	reason: String
) -> void:
	_breadcrumb(
		"npc_world:activity_transaction",
		"%s session=%s spot=%s result=%s reason=%s" % [
			String(npc_id), NpcActionSessionModel._descriptor_session_id(activity),
			String(spot_id), result, reason
		]
	)
	if OS.is_debug_build():
		print(
			"NPC activity transaction: npc=%s session=%s proposed=%s scene=%s spot=%s result=%s reason=%s" % [
				String(npc_id),
				NpcActionSessionModel._descriptor_session_id(activity),
				String(activity.get("state_name", "unknown")),
				String(activity.get("target_scene_path", "")),
				String(spot_id),
				result,
				reason,
			]
		)


func _get_legacy_machine_activity_target(machine: Node, state_name: StringName) -> Node2D:
	var property_name := &"target"
	match String(state_name):
		"Work":
			property_name = &"work_target"
		"Eat":
			property_name = &"eat_target"
		"Rest":
			property_name = &"rest_target"
		"Recreation":
			property_name = &"recreation_target"
		"RoutineTask":
			property_name = &"routine_task_target"
		"Sleep":
			property_name = &"sleep_target"
		"Talk":
			property_name = &"talk_target"
		"InvitePlayer":
			if _has_property(machine, &"invitation_spot"):
				property_name = &"invitation_spot"
			elif _has_property(machine, &"assigned_invitation_spot"):
				property_name = &"assigned_invitation_spot"
	var value = _get_property_if_present(machine, property_name, null)
	return value as Node2D


func _get_property_if_present(object: Object, property_name: StringName, fallback):
	if not _has_property(object, property_name):
		return fallback
	return object.get(property_name)


func _has_property(object: Object, property_name: StringName) -> bool:
	if object == null:
		return false
	for property in object.get_property_list():
		if StringName(property.get("name", &"")) == property_name:
			return true
	return false


func _activity_can_continue(
	npc_id: StringName,
	record: Dictionary,
	definition: NpcSpotDefinition,
	activity: Dictionary,
	total_game_hours: float,
	hour: float
) -> bool:
	if definition == null:
		return false
	if not _spot_runtime_is_available(definition):
		return false
	if _definition_is_meal_cycle_managed(definition):
		if (
			not definition.is_active_at(hour)
			or not _meal_cycle_definition_can_start(definition, npc_id, hour)
		):
			return false

	var value_name := String(definition.value_name)
	if (
		definition.finish_when_npc_value_sated
		and not value_name.is_empty()
		and _get_saved_stat(record, value_name) <= 0.0
	):
		_mark_meal_owner_sated_if_needed(definition, npc_id, StringName(value_name))
		return false

	var continuation := NpcScheduleWindowPolicy.evaluate_active_activity(
		definition,
		activity,
		total_game_hours
	)
	if StringName(String(continuation.get("reason_code", ""))) == &"invalid_occurrence":
		var action_metadata_value: Variant = activity.get("metadata", {})
		var has_occurrence_context: bool = (
			activity.has("schedule_occurrence_key")
			or (
				action_metadata_value is Dictionary
				and action_metadata_value.has("schedule_occurrence_key")
			)
		)
		if not has_occurrence_context:
			# Restored records created before occurrence metadata existed retain
			# their legacy stop-at-window-end behavior.
			return definition.is_active_at(hour)
		return false
	return bool(continuation.get("may_continue", false))


func get_spot_definition(spot_id: StringName) -> NpcSpotDefinition:
	return spot_definitions.get(spot_id, null) as NpcSpotDefinition


func get_arrival_position(from_scene_path: String, fallback: Vector2) -> Vector2:
	# The door pointing back to the source scene is the arrival door in the loaded destination.
	for door_node in get_tree().get_nodes_in_group("npc_travel_door"):
		var door := door_node as Node2D
		if door == null or not is_instance_valid(door):
			continue
		if String(door.get("target_scene_path")) != from_scene_path:
			continue
		if door.has_method("get_npc_arrival_position"):
			return door.call("get_npc_arrival_position") as Vector2

	return fallback


func _load_spot_definitions() -> void:
	spot_definitions.clear()
	for file_name: String in ResourceLoader.list_directory(SPOT_DATA_DIRECTORY):
		if file_name.ends_with("/") or file_name.get_extension().to_lower() != "tres":
			continue
		var resource_path := SPOT_DATA_DIRECTORY.path_join(file_name)
		var definition := load(resource_path) as NpcSpotDefinition
		if definition != null and definition.is_valid_definition():
			if spot_definitions.has(definition.spot_id):
				push_warning("Duplicate simulated NPC spot id '%s'; keeping the first definition." % String(definition.spot_id))
			else:
				spot_definitions[definition.spot_id] = definition
		elif definition != null:
			push_warning(
				"Invalid NPC spot definition '%s': %s" % [
					resource_path,
					"; ".join(definition.get_validation_errors()),
				]
			)

	if spot_definitions.is_empty():
		push_error(
			"NPC world simulation found no valid spot definitions in resource directory: %s"
			% SPOT_DATA_DIRECTORY
		)


func _initialize_definition_runtime_states() -> void:
	for definition_value in spot_definitions.values():
		var definition := definition_value as NpcSpotDefinition
		if definition == null or definition.spot_value_name == &"":
			continue

		var state_key := String(definition.spot_id)
		var state = spot_runtime_states.get(state_key, {})
		if not (state is Dictionary):
			state = {}
		var lower := minf(definition.spot_value_minimum, definition.spot_value_maximum)
		var upper := maxf(definition.spot_value_minimum, definition.spot_value_maximum)
		var previous_kind := String(state.get("kind", ""))
		var next_kind := String(definition.spot_value_name)
		var stored_value := float(state.get("value", definition.spot_value_initial))
		if not previous_kind.is_empty() and previous_kind != next_kind:
			stored_value = definition.spot_value_initial
		state["kind"] = String(definition.spot_value_name)
		state["minimum"] = lower
		state["maximum"] = upper
		state["done_threshold"] = definition.spot_value_done_threshold
		state["daily_growth"] = definition.spot_value_daily_growth
		state["value"] = clampf(stored_value, lower, upper)
		spot_runtime_states[state_key] = state

	_initialize_meal_cycle_runtime_states()
	_repair_stalled_linked_spot_cycles()


func get_meal_cycle_state(spot_id: StringName) -> Dictionary:
	return NpcMealCycleRuntime.get_meal_cycle_state(self, spot_id)


func supply_meal_cycle_recipe_batches(
	controller_spot_id: StringName,
	source_inventory: InventoryModel,
	requested_batches: int
) -> InventoryResult:
	return NpcMealCycleRuntime.supply_meal_cycle_recipe_batches(
		self,
		controller_spot_id,
		source_inventory,
		requested_batches
	)


func mark_meal_owner_sated(
	spot_id: StringName,
	owner_id: StringName,
	value_name: StringName = &"hunger"
) -> bool:
	return NpcMealCycleRuntime.mark_meal_owner_sated(self, spot_id, owner_id, value_name)


func _initialize_meal_cycle_runtime_states() -> void:
	if _meal_cycle_debug_disabled():
		_breadcrumb("npc_world:meal_cycle_init_skip", "")
		return
	NpcMealCycleRuntime._initialize_meal_cycle_runtime_states(self)


func _process_meal_cycle_schedule_until_snapshot(snapshot: Dictionary) -> void:
	if _meal_cycle_debug_disabled():
		_breadcrumb("npc_world:meal_cycle_schedule_skip", "")
		return
	NpcMealCycleRuntime._process_meal_cycle_schedule_until_snapshot(self, snapshot)


func _collect_meal_cycle_schedule_events(
	controller: NpcSpotDefinition,
	previous_total_hours: float,
	current_total_hours: float
) -> Array[Dictionary]:
	return NpcMealCycleRuntime._collect_meal_cycle_schedule_events(
		controller,
		previous_total_hours,
		current_total_hours
	)


func _append_meal_cycle_schedule_event(
	events: Array[Dictionary],
	schedule: Dictionary,
	day: int,
	event_type: String,
	hour_key: String,
	order: int,
	previous_total_hours: float,
	current_total_hours: float
) -> void:
	NpcMealCycleRuntime._append_meal_cycle_schedule_event(
		events,
		schedule,
		day,
		event_type,
		hour_key,
		order,
		previous_total_hours,
		current_total_hours
	)


func _meal_cycle_event_comes_before(left: Dictionary, right: Dictionary) -> bool:
	return NpcMealCycleRuntime._meal_cycle_event_comes_before(left, right)


func _process_meal_cycle_schedule_event(
	controller: NpcSpotDefinition,
	event: Dictionary
) -> void:
	NpcMealCycleRuntime._process_meal_cycle_schedule_event(self, controller, event)


func _start_meal_cycle_prep(
	controller: NpcSpotDefinition,
	meal: String,
	event_total_hours: float
) -> void:
	NpcMealCycleRuntime._start_meal_cycle_prep(self, controller, meal, event_total_hours)


func _call_meal_cycle_food(
	controller: NpcSpotDefinition,
	meal: String,
	event_total_hours: float
) -> void:
	NpcMealCycleRuntime._call_meal_cycle_food(self, controller, meal, event_total_hours)


func _start_meal_cycle_cleanup(
	controller: NpcSpotDefinition,
	meal: String,
	event_total_hours: float
) -> void:
	NpcMealCycleRuntime._start_meal_cycle_cleanup(self, controller, meal, event_total_hours)


func _advance_meal_cycle_work_complete(controller_spot_id: StringName) -> void:
	if _meal_cycle_debug_disabled():
		_breadcrumb("npc_world:meal_cycle_advance_skip", String(controller_spot_id))
		return
	NpcMealCycleRuntime._advance_meal_cycle_work_complete(self, controller_spot_id)


func _deplete_meal_cycle_food(food_spot_id: StringName) -> void:
	if _meal_cycle_debug_disabled():
		_breadcrumb("npc_world:meal_cycle_food_deplete_skip", String(food_spot_id))
		return
	NpcMealCycleRuntime._deplete_meal_cycle_food(self, food_spot_id)


func _apply_meal_cycle_food_value_changed(
	food_spot_id: StringName,
	remaining_points: float
) -> void:
	NpcMealCycleRuntime._apply_meal_cycle_food_value_changed(
		self,
		food_spot_id,
		remaining_points
	)


func _apply_meal_cycle_work_progress(
	definition: NpcSpotDefinition,
	game_hours: float,
	total_hours: float
) -> void:
	if _meal_cycle_debug_disabled():
		_breadcrumb("npc_world:meal_cycle_progress_skip", String(definition.spot_id))
		return
	NpcMealCycleRuntime._apply_meal_cycle_work_progress(self, definition, game_hours, total_hours)


func _set_meal_cycle_controller_state(
	controller: NpcSpotDefinition,
	state: Dictionary
) -> void:
	NpcMealCycleRuntime._set_meal_cycle_controller_state(self, controller, state)


func _sync_meal_cycle_food_state(
	controller: NpcSpotDefinition,
	controller_state: Dictionary
) -> void:
	NpcMealCycleRuntime._sync_meal_cycle_food_state(self, controller, controller_state)


func _notify_meal_cycle_state(controller_spot_id: StringName) -> void:
	NpcMealCycleRuntime._notify_meal_cycle_state(self, controller_spot_id)


func _notify_live_spot_meal_cycle_state(
	spot: Node,
	controller_spot_id: StringName,
	state: Dictionary
) -> void:
	NpcMealCycleRuntime._notify_live_spot_meal_cycle_state(spot, controller_spot_id, state)


func _meal_cycle_definition_can_start(
	definition: NpcSpotDefinition,
	npc_id: StringName,
	hour: float
) -> bool:
	return NpcMealCycleRuntime._meal_cycle_definition_can_start(self, definition, npc_id, hour)


func _meal_cycle_definition_is_available(definition: NpcSpotDefinition) -> bool:
	return NpcMealCycleRuntime._meal_cycle_definition_is_available(self, definition)


func _record_breakfast_owner_flags(state: Dictionary) -> void:
	NpcMealCycleRuntime._record_breakfast_owner_flags(state)


func _get_meal_cycle_controller_definitions() -> Array[NpcSpotDefinition]:
	return NpcMealCycleRuntime._get_meal_cycle_controller_definitions(self)


func _definition_is_meal_cycle_managed(definition: NpcSpotDefinition) -> bool:
	return NpcMealCycleRuntime._definition_is_meal_cycle_managed(definition)


func _definition_is_meal_cycle_controller(definition: NpcSpotDefinition) -> bool:
	return NpcMealCycleRuntime._definition_is_meal_cycle_controller(definition)


func _definition_is_meal_cycle_food(definition: NpcSpotDefinition) -> bool:
	return NpcMealCycleRuntime._definition_is_meal_cycle_food(definition)


func _get_meal_cycle_controller_id_for_spot(spot_id: StringName) -> StringName:
	return NpcMealCycleRuntime._get_meal_cycle_controller_id_for_spot(self, spot_id)


func _get_meal_cycle_controller_id_for_definition(
	definition: NpcSpotDefinition
) -> StringName:
	return NpcMealCycleRuntime._get_meal_cycle_controller_id_for_definition(self, definition)


func _get_meal_cycle_controller_state(controller_id: StringName) -> Dictionary:
	return NpcMealCycleRuntime._get_meal_cycle_controller_state(self, controller_id)


func _get_meal_cycle_food_spot_id(controller: NpcSpotDefinition) -> StringName:
	return NpcMealCycleRuntime._get_meal_cycle_food_spot_id(controller)


func _get_meal_cycle_food_definition_owner_ids(
	controller: NpcSpotDefinition
) -> Array[StringName]:
	return NpcMealCycleRuntime._get_meal_cycle_food_definition_owner_ids(self, controller)


func _get_meal_cycle_reset_work_value(controller: NpcSpotDefinition) -> float:
	return NpcMealCycleRuntime._get_meal_cycle_reset_work_value(controller)


func _get_meal_cycle_owner_ids(
	state: Dictionary,
	owner_type: String
) -> Array[StringName]:
	return NpcMealCycleRuntime._get_meal_cycle_owner_ids(state, owner_type)


func _meal_cycle_owner_allows(
	state: Dictionary,
	owner_type: String,
	owner_id: StringName
) -> bool:
	return NpcMealCycleRuntime._meal_cycle_owner_allows(state, owner_type, owner_id)


func _string_names_to_strings(
	values: Array,
	fallback_values: Array
) -> Array[String]:
	return NpcMealCycleRuntime._string_names_to_strings(values, fallback_values)


func _normalize_meal_cycle_stage(stage: String) -> String:
	return NpcMealCycleRuntime._normalize_meal_cycle_stage(stage)


func _spot_state_is_meal_cycle_managed(state: Dictionary) -> bool:
	return NpcMealCycleRuntime._spot_state_is_meal_cycle_managed(state)


func _snapshot_total_hours(snapshot: Dictionary) -> float:
	if snapshot.has("total_hours"):
		return float(snapshot["total_hours"])
	return float(snapshot.get("day", 0)) * 24.0 + float(snapshot.get(
		"time_of_day_hours",
		snapshot.get("hour", 0.0)
	))


func _get_current_total_hours() -> float:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_method("get_snapshot"):
		return 0.0
	var snapshot: Dictionary = world_time.call("get_snapshot")
	return _snapshot_total_hours(snapshot)


func _get_current_time_of_day_hours() -> float:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_method("get_snapshot"):
		return 0.0
	var snapshot: Dictionary = world_time.call("get_snapshot")
	return float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))


func _repair_stalled_linked_spot_cycles() -> void:
	# Linked spot cycles can get stranded by old saves or interrupted transitions.
	# When every phase in a cycle is already "done", restore the configured starting phase.
	var repaired_any := false
	var visited_cycles: Dictionary = {}
	for definition_value in spot_definitions.values():
		var definition := definition_value as NpcSpotDefinition
		if (
			definition == null
			or definition.next_spot_id_when_done == &""
			or _definition_is_meal_cycle_managed(definition)
		):
			continue

		var cycle := _collect_linked_spot_cycle(definition.spot_id)
		if cycle.is_empty():
			continue

		var cycle_key := _get_spot_cycle_key(cycle)
		if visited_cycles.has(cycle_key):
			continue
		visited_cycles[cycle_key] = true

		if not _linked_spot_cycle_is_stalled(cycle):
			continue

		var recovery_definition := _choose_cycle_recovery_definition(cycle)
		if recovery_definition == null:
			continue

		set_spot_value(
			recovery_definition.spot_id,
			recovery_definition.spot_value_initial,
			false
		)
		repaired_any = true

	if repaired_any:
		_queue_simulation()


func _collect_linked_spot_cycle(start_spot_id: StringName) -> Array[NpcSpotDefinition]:
	var cycle: Array[NpcSpotDefinition] = []
	var seen: Dictionary = {}
	var current_id := start_spot_id
	while current_id != &"":
		var current_key := String(current_id)
		if seen.has(current_key):
			if current_id == start_spot_id:
				return cycle
			return []

		var definition := spot_definitions.get(current_id, null) as NpcSpotDefinition
		if (
			definition == null
			or definition.spot_value_name == &""
			or not spot_runtime_states.has(current_key)
		):
			return []

		seen[current_key] = true
		cycle.append(definition)
		current_id = definition.next_spot_id_when_done

	return []


func _get_spot_cycle_key(cycle: Array[NpcSpotDefinition]) -> String:
	var ids: PackedStringArray = []
	for definition in cycle:
		if definition != null:
			ids.append(String(definition.spot_id))
	ids.sort()
	return "|".join(ids)


func _linked_spot_cycle_is_stalled(cycle: Array[NpcSpotDefinition]) -> bool:
	for definition in cycle:
		if definition == null:
			return false
		var state = spot_runtime_states.get(String(definition.spot_id), {})
		if not (state is Dictionary):
			return false
		var value := float(state.get("value", definition.spot_value_initial))
		var done_threshold := float(state.get(
			"done_threshold",
			definition.spot_value_done_threshold
		))
		if value > done_threshold:
			return false

	return true


func _choose_cycle_recovery_definition(
	cycle: Array[NpcSpotDefinition]
) -> NpcSpotDefinition:
	var best_definition: NpcSpotDefinition = null
	var best_score := -999999.0
	for definition in cycle:
		if definition == null:
			continue
		if definition.spot_value_initial <= definition.spot_value_done_threshold:
			continue

		var score := definition.spot_value_initial
		if definition.spot_value_name == &"work_needed":
			score += 5000.0
		if definition.state_name == &"Work":
			score += 10000.0
		if best_definition == null or score > best_score:
			best_definition = definition
			best_score = score

	return best_definition


func _try_start_social_seek(
	npc_id: StringName,
	record: Dictionary,
	records: Dictionary,
	locations: Node,
	blocking_priority: int
) -> bool:
	var live_npc: Node2D
	var live_machine: Node
	if locations != null and locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if live_npc != null:
		live_machine = live_npc.get_node_or_null("NpcStateMachine")
	if _social_planning_suppressed:
		_publish_social_selection_descriptor(npc_id, live_machine, {})
		return false
	if _record_has_pending_travel(record):
		_publish_social_selection_descriptor(npc_id, live_machine, {})
		return false
	if DebugToolsConfig.TROUBLESHOOTING_MODE and DebugToolsConfig.DEBUG_DISABLE_TALK_SEARCH:
		_breadcrumb("npc_world:social_seek_skip", String(npc_id))
		_publish_social_selection_descriptor(npc_id, live_machine, {})
		return false

	var settings := _get_social_seek_settings(record)
	if not bool(settings.get("enabled", true)):
		_publish_social_selection_descriptor(npc_id, live_machine, {})
		return false
	var seek_priority := int(settings.get("priority", 60))
	if blocking_priority > seek_priority:
		_publish_social_selection_descriptor(npc_id, live_machine, {})
		return false
	if _get_saved_stat(record, "talk_need") < float(settings.get("talk_need_threshold", 70.0)):
		_publish_social_selection_descriptor(npc_id, live_machine, {})
		return false
	var short_term_memory: NpcShortTermMemory
	if live_npc != null:
		if (
			live_machine != null
			and live_machine.has_method("is_socially_engaged")
			and bool(live_machine.call("is_socially_engaged"))
		):
			_log_social_plan_result(npc_id, "", "", false, "already_socially_engaged")
			_publish_social_selection_descriptor(npc_id, live_machine, {})
			return false
		if live_machine != null:
			short_term_memory = live_machine.get_node_or_null(
				"NpcShortTermMemory"
			) as NpcShortTermMemory

	var clean_npc_id := String(npc_id)
	var now_game_hours := _get_current_total_hours()
	if short_term_memory == null:
		_publish_social_selection_descriptor(npc_id, live_machine, {})
	# Refusal retry times describe partner eligibility, not the candidate pool.
	# Re-enumerate at the normal social-planning cadence so a newly present or
	# newly available alternative can be selected immediately.

	var relationships := get_node_or_null("/root/Relationships")
	var player := get_tree().get_first_node_in_group("player") as Node2D
	var candidate_evaluated := Callable()
	if performance_profiling_enabled:
		candidate_evaluated = Callable(self, "_record_social_candidate_evaluation")
	var candidate := _social_planner.choose_candidate(
		npc_id,
		record,
		records,
		locations,
		settings,
		relationships,
		player,
		social_rng,
		candidate_evaluated,
		short_term_memory,
		now_game_hours,
		{
			"remembering_npc_id": (
				NpcActionSessionModel.get_persistent_id(live_npc)
				if live_npc != null
				else clean_npc_id
			),
			"recent_refusal_retry_delay_game_hours": (
				recent_refusal_retry_delay_game_hours
			),
			"recent_harm_social_delay_game_hours": (
				recent_harm_social_delay_game_hours
			),
			"recent_conversation_repeat_delay_game_hours": (
				recent_conversation_repeat_delay_game_hours
			),
		}
	)
	# A successful preview needs only the planner-owned candidate. Avoid copying
	# the diagnostic array until the sorted arbitration actually evaluates it.
	if _social_seek_preview_only and not candidate.is_empty():
		return true
	var selection_descriptor := _social_planner.get_last_selection_descriptor()
	_publish_social_selection_descriptor(
		npc_id,
		live_machine,
		selection_descriptor
	)
	if bool(selection_descriptor.get("all_candidates_suppressed", false)):
		_log_social_plan_result(
			npc_id,
			"",
			"",
			false,
			String(selection_descriptor.get(
				"reason_code",
				"no_social_target_due_to_recent_memory"
			))
		)
		return false
	if candidate.is_empty():
		return false

	var target_scene_path := String(candidate.get("scene_path", ""))
	var seeker_scene_path := String(record.get("scene_path", ""))
	if target_scene_path.is_empty() or seeker_scene_path.is_empty():
		return false
	if target_scene_path != seeker_scene_path:
		_log_social_plan_result(npc_id, "", "", false, "remote_social_visit_disabled")
		return false
	var target_position = candidate.get("position", Vector2.ZERO)
	if not (target_position is Vector2):
		target_position = Vector2.ZERO
	var social_target_id := String(candidate.get("target_id", ""))
	var target_record: Dictionary = {}
	if social_target_id != PLAYER_SOCIAL_TARGET_ID:
		var target_record_value = records.get(social_target_id, {})
		if not (target_record_value is Dictionary):
			_log_social_plan_result(npc_id, social_target_id, "", false, "target_record_missing")
			return false
		target_record = target_record_value
	var reservation := _social_planner.reserve_pair(
		String(npc_id),
		record,
		social_target_id,
		target_record,
		locations,
		seek_priority,
		player,
		records
	)
	if not bool(reservation.get("accepted", false)):
		_log_social_plan_result(
			npc_id,
			social_target_id,
			"",
			false,
			String(reservation.get("reason", "reservation_rejected"))
		)
		return false
	var session_id := String(reservation.get("session_id", ""))
	var accepted := false
	var rejection_reason := "social_request_rejected"

	if seeker_scene_path == target_scene_path:
		var live_target := _get_live_social_target(candidate, locations)
		if live_npc != null and live_target != null:
			accepted = _request_live_social_seek(
				npc_id,
				live_npc,
				live_target,
				seek_priority,
				locations,
				session_id,
				social_target_id
			)
			rejection_reason = "live_seek_rejected"
		elif live_npc == null and live_target == null and social_target_id != PLAYER_SOCIAL_TARGET_ID:
			accepted = _complete_simulated_conversation(
				npc_id,
				social_target_id,
				record,
				records,
				locations,
				session_id
			)
			rejection_reason = "simulated_conversation_commit_rejected"
		elif live_npc == null and locations.has_method("move_simulated_npc_for_social_visit"):
			accepted = _call_move_simulated_social_visit(
				locations, String(npc_id), target_scene_path, target_position,
				social_target_id, session_id
			)
			rejection_reason = "social_visit_move_rejected"
		else:
			rejection_reason = "same_scene_participant_not_live_together"

	_social_planner.finish_session(session_id, accepted)
	_log_social_plan_result(
		npc_id,
		social_target_id,
		session_id,
		accepted,
		"" if accepted else rejection_reason
	)
	return accepted


func _preview_social_seek(
	npc_id: StringName,
	record: Dictionary,
	records: Dictionary,
	locations: Node,
	blocking_priority: int
) -> bool:
	_social_seek_preview_only = true
	var social_planning_start_usec := (
		Time.get_ticks_usec() if performance_profiling_enabled else 0
	)
	var viable := _try_start_social_seek(
		npc_id,
		record,
		records,
		locations,
		blocking_priority
	)
	_social_seek_preview_only = false
	if performance_profiling_enabled:
		_performance_profile_social_usec_in_pass += (
			Time.get_ticks_usec() - social_planning_start_usec
		)
	return viable


func get_social_selection_debug_descriptor(
	npc_id: StringName = &""
) -> Dictionary:
	var clean_npc_id := String(npc_id)
	if clean_npc_id.is_empty():
		if _social_selection_debug_by_npc.size() != 1:
			return {}
		clean_npc_id = String(_social_selection_debug_by_npc.keys()[0])
	var descriptor: Dictionary = _social_selection_debug_by_npc.get(
		clean_npc_id,
		{}
	).duplicate(true)
	if descriptor.is_empty():
		return {}
	var retry_game_hours := float(descriptor.get(
		"earliest_retry_game_hours",
		0.0
	))
	if retry_game_hours > 0.0:
		var remaining_retry_hours := retry_game_hours - _get_current_total_hours()
		if remaining_retry_hours <= 0.0:
			return {}
		descriptor["remaining_retry_hours"] = remaining_retry_hours
	return descriptor


func _publish_social_selection_descriptor(
	npc_id: StringName,
	live_machine: Node,
	descriptor: Dictionary
) -> void:
	var clean_npc_id := String(npc_id)
	if descriptor.is_empty():
		_social_selection_debug_by_npc.erase(clean_npc_id)
	else:
		# The planner's public getter already handed this component an owned deep
		# copy. Stamp and retain that copy without cloning its candidate array again.
		var published_descriptor := descriptor
		if not published_descriptor.has("evaluated_game_hours"):
			published_descriptor["evaluated_game_hours"] = _get_current_total_hours()
		published_descriptor["simulation_pass_id"] = _social_planning_pass_id
		published_descriptor["published_at_usec"] = Time.get_ticks_usec()
		_social_selection_debug_by_npc[clean_npc_id] = published_descriptor
		descriptor = published_descriptor
	if (
		live_machine != null
		and live_machine.has_method("set_social_selection_feedback")
	):
		live_machine.call("set_social_selection_feedback", descriptor)


func _clear_social_selection_descriptor(
	npc_id: StringName,
	locations: Node
) -> void:
	var live_machine: Node
	if locations != null and locations.has_method("get_live_npc"):
		var live_npc := locations.call("get_live_npc", String(npc_id)) as Node
		if live_npc != null:
			live_machine = live_npc.get_node_or_null("NpcStateMachine")
	_publish_social_selection_descriptor(npc_id, live_machine, {})


func _prune_social_selection_descriptors(records: Dictionary, locations: Node) -> void:
	for cached_npc_id in _social_selection_debug_by_npc.keys():
		if not records.has(cached_npc_id) and not records.has(StringName(String(cached_npc_id))):
			_clear_social_selection_descriptor(
				StringName(String(cached_npc_id)),
				locations
			)


func _clear_all_social_selection_descriptors() -> void:
	var locations := get_node_or_null("/root/NpcLocations")
	for cached_npc_id in _social_selection_debug_by_npc.keys():
		_clear_social_selection_descriptor(
			StringName(String(cached_npc_id)),
			locations
		)


static func _get_ordered_social_seeker_ids(seekers_by_npc_id: Dictionary) -> Array:
	var ordered_ids: Array = seekers_by_npc_id.keys()
	ordered_ids.sort_custom(_social_seeker_id_precedes)
	return ordered_ids


static func _social_seeker_id_precedes(first, second) -> bool:
	return String(first) < String(second)


func _record_has_pending_travel(record: Dictionary) -> bool:
	var pending = record.get("pending_travel", {})
	return pending is Dictionary and not pending.is_empty()


func _get_social_seek_settings(record: Dictionary) -> Dictionary:
	var defaults := {
		"enabled": true,
		"talk_need_threshold": 70.0,
		"priority": 60,
		"minimum_npc_favor": 10.0,
	}
	var node_state = record.get("node_state", {})
	if node_state is Dictionary:
		var profile = node_state.get("world_simulation_profile", {})
		if profile is Dictionary:
			var settings = profile.get("social_seeking", {})
			if settings is Dictionary and not settings.is_empty():
				var merged := defaults.duplicate(true)
				if settings.get("enabled", null) is bool:
					merged["enabled"] = settings.enabled
				_merge_valid_social_number(
					merged, settings, "talk_need_threshold", 0.0, 100.0
				)
				_merge_valid_social_number(
					merged, settings, "priority", 0.0, 1000.0
				)
				_merge_valid_social_number(
					merged, settings, "minimum_npc_favor", 0.0, 100.0
				)
				return merged
	return defaults


static func _merge_valid_social_number(
	destination: Dictionary,
	source: Dictionary,
	key: String,
	minimum: float,
	maximum: float
) -> void:
	var value = source.get(key, null)
	if not (value is int or value is float):
		return
	var number := float(value)
	if not is_finite(number) or number < minimum or number > maximum:
		return
	destination[key] = value


func _validate_social_world_profile(
	npc_id: StringName,
	record: Dictionary
) -> void:
	var node_state = record.get("node_state", {})
	var profile: Variant = (
		node_state.get("world_simulation_profile", {})
		if node_state is Dictionary
		else {}
	)
	var social_profile_signature: Variant = profile
	if profile is Dictionary:
		var supplied_social_sections := {}
		for section_name in [
			"social_seeking",
			"talk_handshake",
			"social_acceptance",
			"memory",
		]:
			if profile.has(section_name):
				supplied_social_sections[section_name] = profile[section_name]
		social_profile_signature = supplied_social_sections
	var signature := "%s:%s" % [
		typeof(profile),
		JSON.stringify(social_profile_signature),
	]
	var cache_key := String(npc_id)
	if String(_validated_social_world_profile_signatures.get(
		cache_key, ""
	)) == signature:
		return
	var issues := NpcSocialConfigurationValidator.validate_world_profile(
		profile,
		cache_key,
		"npc.%s.world_simulation_profile" % cache_key
	)
	_validated_social_world_profile_signatures[cache_key] = signature
	_social_world_profile_validation_issues_by_npc[cache_key] = issues.duplicate(true)
	if not OS.is_debug_build():
		return
	for issue in issues:
		push_warning("NPC world social configuration [%s] %s: %s" % [
			String(issue.get("code", "invalid_configuration")),
			String(issue.get("path", "world_simulation_profile")),
			String(issue.get("message", "Invalid social configuration.")),
		])


func _prune_social_world_profile_validation(records: Dictionary) -> void:
	for cached_npc_id in _validated_social_world_profile_signatures.keys():
		if (
			records.has(cached_npc_id)
			or records.has(StringName(String(cached_npc_id)))
		):
			continue
		_validated_social_world_profile_signatures.erase(cached_npc_id)
		_social_world_profile_validation_issues_by_npc.erase(cached_npc_id)


func get_social_world_profile_validation_issues(
	npc_id: StringName
) -> Array[Dictionary]:
	var issues = _social_world_profile_validation_issues_by_npc.get(
		String(npc_id), []
	)
	return issues.duplicate(true) if issues is Array else []


func _record_social_candidate_evaluation() -> void:
	_performance_profile_candidate_evaluations_in_pass += 1


func _get_live_social_target(candidate: Dictionary, locations: Node) -> Node2D:
	var target_id := String(candidate.get("target_id", ""))
	if target_id == PLAYER_SOCIAL_TARGET_ID:
		var player := get_tree().get_first_node_in_group("player") as Node2D
		return player if player != null and is_instance_valid(player) else null
	if locations.has_method("get_live_npc"):
		return locations.call("get_live_npc", target_id) as Node2D
	return null


func _request_live_social_seek(
	npc_id: StringName,
	npc: Node2D,
	target: Node2D,
	seek_priority: int,
	locations: Node,
	session_id: String = "",
	target_npc_id: String = ""
) -> bool:
	if npc == null or target == null or npc == target:
		return false
	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null or not machine.has_method("request_state"):
		return false
	if machine.has_method("is_socially_engaged") and bool(machine.call("is_socially_engaged")):
		_log_social_plan_result(
			npc_id, target_npc_id, session_id, false, "already_socially_engaged"
		)
		return false
	if session_id.is_empty():
		session_id = NpcActionSessionModel.make_session_id(
			String(npc_id), &"social_ai", &"LookForTalkTarget"
		)
	if target_npc_id.is_empty():
		target_npc_id = NpcActivityIdentity.get_persistent_npc_id(target)
	var seek_descriptor := NpcActivityIdentity.describe(
		&"LookForTalkTarget", target, &"", "", "", session_id, target_npc_id
	)
	seek_descriptor["session_id"] = session_id
	seek_descriptor["action_session_id"] = session_id
	if machine.has_method("is_following_activity_descriptor"):
		if bool(machine.call("is_following_activity_descriptor", seek_descriptor)):
			return true
		var talk_descriptor := NpcActivityIdentity.describe(
			&"Talk", target, &"", "", "", session_id, target_npc_id
		)
		talk_descriptor["session_id"] = session_id
		talk_descriptor["action_session_id"] = session_id
		if bool(machine.call("is_following_activity_descriptor", talk_descriptor)):
			return true
	if locations.has_method("is_npc_available_for_scheduled_activity"):
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			&"LookForTalkTarget",
			seek_priority,
			seek_descriptor
		)):
			return false
	var social_metadata := {
		"target_persistent_id": target_npc_id,
		"social_session_id": session_id,
	}
	if machine.has_method("get_value"):
		social_metadata["current_value"] = float(machine.call("get_value", &"talk_need"))
	var social_intent := NpcBehaviorIntentModel.create(
		&"LookForTalkTarget",
		&"LookForTalkTarget",
		NpcBehaviorIntentModel.SOURCE_SOCIAL_AI,
		"live_social_seek",
		seek_priority,
		target_npc_id,
		session_id,
		0.0,
		0,
		social_metadata,
		NpcSocialPlanner.SOCIAL_SEEK_REASON_CODE,
		NpcSocialPlanner.SOCIAL_SEEK_FEEDBACK_TEXT,
		NpcSocialPlanner.SOCIAL_SEEK_ORIGIN_VALUE,
		false
	)
	if machine.has_method("request_behavior_intent"):
		return bool(machine.call(
			"request_behavior_intent", social_intent, target, {}
		))
	if machine.has_method("request_action_from_descriptor"):
		return bool(machine.call("request_action_from_descriptor", {
			"session_id": session_id,
			"action_session_id": session_id,
			"request_id": session_id,
			"action_kind": "LookForTalkTarget",
			"source": "social_ai",
			"target_persistent_id": target_npc_id,
			"target_npc_id": target_npc_id,
			"priority": seek_priority,
			"status": "proposed",
			"start_world_time": _get_current_total_hours(),
			"metadata": {
				"behavior_source": "social_ai",
				"behavior_reason_code": String(NpcSocialPlanner.SOCIAL_SEEK_REASON_CODE),
				"behavior_feedback_text": NpcSocialPlanner.SOCIAL_SEEK_FEEDBACK_TEXT,
				"behavior_origin_value": String(NpcSocialPlanner.SOCIAL_SEEK_ORIGIN_VALUE),
			},
		}, target))
	return bool(machine.call(
		"request_state", &"LookForTalkTarget", target, "social_seek", seek_priority
	))


func _complete_simulated_conversation(
	npc_id: StringName,
	target_id: String,
	record: Dictionary,
	records: Dictionary,
	locations: Node,
	session_id: String
) -> bool:
	if target_id.is_empty() or session_id.is_empty() or not records.has(target_id):
		return false
	var target_record = records[target_id]
	if not (target_record is Dictionary):
		return false
	var seeker_update := record.duplicate(true)
	var target_update: Dictionary = target_record.duplicate(true)
	var seeker_last_session := String(seeker_update.get("last_completed_social_session_id", ""))
	var target_last_session := String(target_update.get("last_completed_social_session_id", ""))
	if seeker_last_session == session_id or target_last_session == session_id:
		# A fully completed pair is idempotent. A one-sided marker is rejected rather than
		# applying the social reward a second time to one participant.
		return seeker_last_session == session_id and target_last_session == session_id

	seeker_update["social_session_id"] = session_id
	seeker_update["social_session_partner_id"] = target_id
	target_update["social_session_id"] = session_id
	target_update["social_session_partner_id"] = String(npc_id)
	_set_saved_stat(seeker_update, "talk_need", _get_saved_stat(seeker_update, "talk_need") - simulated_talk_need_drop)
	_set_saved_stat(seeker_update, "boredom", _get_saved_stat(seeker_update, "boredom") - simulated_talk_boredom_drop)
	_set_saved_stat(
		target_update,
		"talk_need",
		_get_saved_stat(target_update, "talk_need") - simulated_partner_talk_need_drop
	)
	seeker_update["social_visit_target_id"] = ""
	target_update["social_visit_target_id"] = ""
	seeker_update["last_completed_social_session_id"] = session_id
	target_update["last_completed_social_session_id"] = session_id
	seeker_update["social_session_id"] = ""
	seeker_update["social_session_partner_id"] = ""
	target_update["social_session_id"] = ""
	target_update["social_session_partner_id"] = ""
	if locations == null or not locations.has_method("update_simulated_social_pair"):
		return false
	if not bool(locations.call(
		"update_simulated_social_pair",
		String(npc_id),
		seeker_update,
		target_id,
		target_update
	)):
		return false
	record.clear()
	record.merge(seeker_update, true)
	target_record.clear()
	target_record.merge(target_update, true)
	records[String(npc_id)] = record
	records[target_id] = target_record
	return true


func _log_social_plan_result(
	npc_id: StringName,
	target_id: String,
	session_id: String,
	accepted: bool,
	reason: String
) -> void:
	if not OS.is_debug_build():
		return
	print(
		"[NpcSocial] npc=%s target=%s session=%s %s reason=%s" % [
			String(npc_id),
			target_id,
			session_id,
			"accepted" if accepted else "rejected",
			reason,
		]
	)


func _try_start_activity(
	npc_id: StringName,
	record: Dictionary,
	total_hours: float,
	hour: float,
	locations: Node,
	records: Dictionary
) -> void:
	var plan := _prepare_idle_activity_plan(npc_id, record, total_hours, locations)
	if plan.is_empty():
		return
	var social_planning_start_usec := Time.get_ticks_usec() if performance_profiling_enabled else 0
	var social_started := _try_start_social_seek(
		npc_id,
		record,
		records,
		locations,
		int(plan.get("blocking_priority", -1))
	)
	if performance_profiling_enabled:
		_performance_profile_social_usec_in_pass += Time.get_ticks_usec() - social_planning_start_usec
	if social_started:
		_clear_schedule_decision_debug(npc_id)
		return
	_start_planned_scheduled_activity(
		npc_id,
		record,
		total_hours,
		hour,
		locations,
		plan
	)


func _route_idle_activity_for_social_arbitration(
	npc_id: StringName,
	record: Dictionary,
	total_hours: float,
	hour: float,
	locations: Node,
	records: Dictionary,
	deferred_social_seekers: Array[Dictionary]
) -> void:
	# Preserve the normal per-record schedule/travel interleaving. Only an NPC
	# whose social need can actually compete with its current schedule is deferred
	# into the deterministic global arbitration phase.
	var plan := _prepare_idle_activity_plan(npc_id, record, total_hours, locations)
	if plan.is_empty():
		return
	if not _record_enters_social_arbitration(record):
		_clear_social_selection_descriptor(npc_id, locations)
		_start_planned_scheduled_activity(
			npc_id, record, total_hours, hour, locations, plan
		)
		if plan.get("definition", null) != null:
			_refresh_working_record(npc_id, record, locations, records)
		return
	var settings := _get_social_seek_settings(record)
	if int(plan.get("blocking_priority", -1)) > int(settings.get("priority", 60)):
		# This schedule would have blocked social at the NPC's original position in
		# the record loop. Commit it there so later activity/travel updates cannot
		# scramble its primary/fallback choice.
		_clear_social_selection_descriptor(npc_id, locations)
		_start_planned_scheduled_activity(
			npc_id, record, total_hours, hour, locations, plan
		)
		if plan.get("definition", null) != null:
			_refresh_working_record(npc_id, record, locations, records)
		return
	if not _preview_social_seek(
		npc_id,
		record,
		records,
		locations,
		int(plan.get("blocking_priority", -1))
	):
		# A seeker with no viable partner keeps the exact schedule position it had
		# before global arbitration was introduced. Only actual contention enters
		# the stable-ID sorted phase.
		_clear_social_selection_descriptor(npc_id, locations)
		_start_planned_scheduled_activity(
			npc_id, record, total_hours, hour, locations, plan
		)
		if plan.get("definition", null) != null:
			_refresh_working_record(npc_id, record, locations, records)
		return
	deferred_social_seekers.append({
		"npc_id": npc_id,
		"record": record,
		"blocking_priority": int(plan.get("blocking_priority", -1)),
	})


func _process_deferred_social_seekers(
	deferred_social_seekers: Array[Dictionary],
	total_hours: float,
	hour: float,
	locations: Node,
	records: Dictionary
) -> void:
	# Social allocation is a global contention problem. Eligible seekers are
	# considered by stable ID, while failed seekers fall back to schedules in their
	# original record order. Ordinary non-seekers were already handled inline.
	var entries_by_npc_id: Dictionary = {}
	for entry in deferred_social_seekers:
		var npc_id := StringName(String(entry.get("npc_id", "")))
		var record_value = entry.get("record", {})
		if npc_id == &"" or not (record_value is Dictionary):
			continue
		entries_by_npc_id[String(npc_id)] = entry

	var social_started_by_npc_id: Dictionary = {}
	for ordered_npc_id in _get_ordered_social_seeker_ids(entries_by_npc_id):
		var entry: Dictionary = entries_by_npc_id[ordered_npc_id]
		var npc_id := StringName(String(entry.get("npc_id", "")))
		var record: Dictionary = entry.get("record", {})
		var social_planning_start_usec := Time.get_ticks_usec() if performance_profiling_enabled else 0
		if _try_start_social_seek(
			npc_id,
			record,
			records,
			locations,
			int(entry.get("blocking_priority", -1))
		):
			social_started_by_npc_id[String(npc_id)] = true
		if performance_profiling_enabled:
			_performance_profile_social_usec_in_pass += Time.get_ticks_usec() - social_planning_start_usec

	for entry in deferred_social_seekers:
		var npc_id := StringName(String(entry.get("npc_id", "")))
		if social_started_by_npc_id.has(String(npc_id)):
			# Keep the successful seeker's selected-target descriptor available to
			# developer tooling. Live player feedback is filtered independently.
			_clear_schedule_decision_debug(npc_id)
			continue
		if _social_participant_was_used_this_pass(npc_id):
			# A deferred seeker that was consumed as somebody else's target did not
			# make its own selection, so any earlier descriptor is stale.
			_clear_schedule_decision_debug(npc_id)
			_clear_social_selection_descriptor(npc_id, locations)
			continue
		var record_value = entry.get("record", {})
		if npc_id == &"" or not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		var plan := _prepare_idle_activity_plan(
			npc_id,
			record,
			total_hours,
			locations
		)
		if plan.is_empty():
			continue
		_start_planned_scheduled_activity(
			npc_id,
			record,
			total_hours,
			hour,
			locations,
			plan
		)
		if plan.get("definition", null) != null:
			_refresh_working_record(npc_id, record, locations, records)


func _social_participant_was_used_this_pass(npc_id: StringName) -> bool:
	return _social_planner.was_participant_used_this_pass(String(npc_id))


func _refresh_working_record(
	npc_id: StringName,
	record: Dictionary,
	locations: Node,
	records: Dictionary
) -> void:
	if locations == null or not locations.has_method("get_record_snapshot"):
		return
	var authoritative_record = locations.call(
		"get_record_snapshot", String(npc_id)
	)
	if not (authoritative_record is Dictionary) or authoritative_record.is_empty():
		return
	record.clear()
	record.merge(authoritative_record, true)
	records[String(npc_id)] = record


func _record_enters_social_arbitration(record: Dictionary) -> bool:
	if _social_planning_suppressed or _record_has_pending_travel(record):
		return false
	if DebugToolsConfig.TROUBLESHOOTING_MODE and DebugToolsConfig.DEBUG_DISABLE_TALK_SEARCH:
		return false
	var settings := _get_social_seek_settings(record)
	return (
		bool(settings.get("enabled", true))
		and _get_saved_stat(record, "talk_need")
			>= float(settings.get("talk_need_threshold", 70.0))
	)


func _prepare_idle_activity_plan(
	npc_id: StringName,
	record: Dictionary,
	total_hours: float,
	locations: Node
) -> Dictionary:
	if _record_is_disabled(record):
		_clear_schedule_decision_debug(npc_id)
		_clear_social_selection_descriptor(npc_id, locations)
		return {}
	if (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_NPC_SCHEDULED_ACTIVITY_STARTS
	):
		_breadcrumb("npc_world:start_activity_skip", String(npc_id))
		_clear_schedule_decision_debug(npc_id)
		_clear_social_selection_descriptor(npc_id, locations)
		return {}

	var candidate := _find_best_candidate(npc_id, record, total_hours)
	var definition := candidate.get("definition", null) as NpcSpotDefinition
	var schedule_decision: Dictionary = candidate.get(
		"schedule_decision",
		{}
	).duplicate(true)
	if _debug_definition_disabled(definition):
		_breadcrumb("npc_world:best_activity_disabled", "%s -> %s" % [String(npc_id), String(definition.spot_id)])
		definition = null
		candidate = {}
		schedule_decision = {}
	_breadcrumb(
		"npc_world:best_activity",
		"%s -> %s" % [String(npc_id), String(definition.spot_id) if definition != null else "none"]
	)
	if definition == null:
		_clear_schedule_decision_debug(npc_id)
	else:
		_set_schedule_decision_debug(
			npc_id,
			definition,
			schedule_decision,
			locations,
			false
		)
		if _should_defer_flexible_live_start(
			npc_id,
			definition,
			schedule_decision,
			locations
		):
			_set_schedule_decision_debug(
				npc_id,
				definition,
				schedule_decision,
				locations,
				true
			)
			_clear_social_selection_descriptor(npc_id, locations)
			return {}
		if _live_schedule_start_has_protected_ownership(npc_id, locations):
			if _live_schedule_start_is_emergency_or_scripted(npc_id, locations):
				_clear_schedule_decision_debug(npc_id)
			_clear_social_selection_descriptor(npc_id, locations)
			return {}
	var effective_priority := int(candidate.get(
		"effective_priority",
		definition.priority if definition != null else -1
	))
	return {
		"candidate": candidate,
		"definition": definition,
		"schedule_decision": schedule_decision,
		"effective_priority": effective_priority,
		"blocking_priority": effective_priority if definition != null else -1,
	}


func _start_planned_scheduled_activity(
	npc_id: StringName,
	record: Dictionary,
	total_hours: float,
	hour: float,
	locations: Node,
	plan: Dictionary
) -> void:
	var candidate: Dictionary = plan.get("candidate", {})
	var definition := plan.get("definition", null) as NpcSpotDefinition
	var schedule_decision: Dictionary = plan.get("schedule_decision", {})
	var effective_priority := int(plan.get(
		"effective_priority",
		definition.priority if definition != null else -1
	))
	if definition == null:
		return
	var action_session_id := NpcActionSessionModel.make_session_id(
		String(npc_id), &"schedule", definition.state_name
	)

	if locations.has_method("is_npc_available_for_scheduled_activity"):
		var requested_spot := live_spots.get(definition.spot_id, null) as Node2D
		var requested_activity := _get_activity_descriptor(definition, requested_spot, {
			"session_id": action_session_id,
			"action_session_id": action_session_id,
			"activity_id": action_session_id,
			"state_name": String(definition.state_name),
			"spot_id": String(definition.spot_id),
			"target_scene_path": definition.scene_path,
		})
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			definition.state_name,
			effective_priority,
			requested_activity
		)):
			return

	var target_scene_path := definition.scene_path
	var target_position := definition.position
	if definition.state_name == INVITE_PLAYER_STATE:
		var invitation_destination := _get_invitation_activity_start_destination(
			record,
			definition,
			locations
		)
		target_scene_path = String(invitation_destination.get("scene_path", target_scene_path))
		var invitation_position = invitation_destination.get("position", target_position)
		if invitation_position is Vector2:
			target_position = invitation_position
	var activity := {
		"session_id": action_session_id,
		"action_session_id": action_session_id,
		"activity_id": action_session_id,
		"source": "schedule",
		"priority": effective_priority,
		"status": "proposed",
		"start_world_time": total_hours,
		"reservation_ids": [],
		"spot_id": String(definition.spot_id),
		"state_name": String(definition.state_name),
		"value_name": String(definition.value_name),
		"target_scene_path": target_scene_path,
		"target_position": target_position,
		"last_total_hours": total_hours,
		"return_scene_path": String(record.get("scene_path", "")),
		"return_position": record.get("last_position", Vector2.ZERO),
	}
	_apply_schedule_metadata_to_activity(
		activity,
		definition,
		schedule_decision,
		effective_priority
	)
	if definition.state_name == INVITE_PLAYER_STATE:
		activity["lesson_phase"] = "inviting"
		activity["lesson_scene_path"] = definition.scene_path
		activity["lesson_position"] = definition.position

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if (
		String(record.get("scene_path", "")) != target_scene_path
		and (
			live_npc != null
			or NpcRouteLocationCoordinator.supports_offscreen_route_transactions(
				locations
			)
		)
	):
		var pending_travel := {
			"mode": "start",
			"target_scene_path": target_scene_path,
			"target_position": target_position,
			"requested_state_name": String(definition.state_name),
			"requested_priority": effective_priority,
			"activity": activity,
		}
		var expected_route_edge_id := &""
		var departure_door: Node2D = null
		if live_npc != null:
			departure_door = _find_departure_door(target_scene_path, live_npc)
			if departure_door != null:
				var direct_validation := NpcSceneRouteBridge.validate_direct_route_wired_door(
					get_node_or_null("/root/NpcSceneRoutes"),
					departure_door,
					String(record.get("scene_path", "")),
					target_scene_path,
					npc_id
				)
				if not bool(direct_validation.get("accepted", false)):
					_breadcrumb(
						"npc_world:start_activity_direct_route_reject",
						"%s %s" % [
							String(npc_id),
							String(direct_validation.get("reason", "route_unavailable")),
						]
					)
					return
		if departure_door == null:
			var route_setup := _prepare_pending_scene_route(
				pending_travel,
				String(record.get("scene_path", "")),
				target_scene_path,
				npc_id
			)
			if not bool(route_setup.get("accepted", false)):
				_breadcrumb(
					"npc_world:start_activity_route_reject",
					"%s %s" % [String(npc_id), String(route_setup.get("reason", "route_unavailable"))]
				)
				return
			pending_travel = route_setup.get("pending_travel", pending_travel)
			expected_route_edge_id = StringName(String(route_setup.get("edge_id", "")))
			if live_npc != null:
				departure_door = _find_departure_door(
					String(route_setup.get("target_scene_path", "")),
					live_npc,
					expected_route_edge_id
				)
		if (
			live_npc != null
			and (departure_door == null or not locations.has_method("prepare_scheduled_travel"))
		):
			_breadcrumb("npc_world:start_activity_departure_missing", String(npc_id))
			return

		var claim_result := try_claim_spot(
			npc_id, action_session_id, definition.spot_id, &"activity"
		)
		if not bool(claim_result.get("accepted", false)):
			_log_activity_transaction(
				npc_id,
				activity,
				definition.spot_id,
				"rejected",
				String(claim_result.get("status", "spot_capacity_unavailable"))
			)
			return
		var reservation_id := String(claim_result.get("reservation_id", ""))
		var claimed_new := String(claim_result.get("status", "")) == "claimed"
		_add_descriptor_reservation_id(activity, reservation_id)
		pending_travel["activity"] = activity.duplicate(true)
		_log_activity_transaction(
			npc_id,
			activity,
			definition.spot_id,
			"reserved",
			String(claim_result.get("status", "scheduled_travel"))
		)
		var travel_accepted := false
		if live_npc != null:
			travel_accepted = bool(locations.call(
				"prepare_scheduled_travel",
				String(npc_id),
				pending_travel,
				departure_door
			))
		else:
			travel_accepted = NpcRouteLocationCoordinator.install_offscreen_start_route(
				locations,
				get_node_or_null("/root/NpcSceneRoutes"),
				npc_id,
				record,
				pending_travel
			)
		if travel_accepted:
			_log_activity_transaction(
				npc_id, activity, definition.spot_id, "accepted", "scheduled_travel"
			)
			_breadcrumb("npc_world:start_activity_travel", "%s %s" % [String(npc_id), String(definition.spot_id)])
			activity_started.emit(npc_id, definition.spot_id)
			if live_npc == null:
				var routed_record: Dictionary = locations.call(
					"get_record_snapshot", String(npc_id)
				)
				var routed_pending = routed_record.get("pending_travel", {})
				if routed_pending is Dictionary and not routed_pending.is_empty():
					_update_pending_travel(
						npc_id, routed_record, routed_pending, hour, locations
					)
		else:
			if claimed_new:
				release_spot_reservation(reservation_id, npc_id, action_session_id)
			_log_activity_transaction(
				npc_id, activity, definition.spot_id, "rollback", "scheduled_travel_rejected"
			)
		return

	if not locations.has_method("begin_scheduled_activity"):
		return
	if not bool(locations.call(
		"begin_scheduled_activity",
		String(npc_id),
		activity,
		target_scene_path,
		target_position
	)):
		return

	_breadcrumb("npc_world:start_activity", "%s %s" % [String(npc_id), String(definition.spot_id)])
	activity_started.emit(npc_id, definition.spot_id)


func _get_invitation_activity_start_destination(
	record: Dictionary,
	definition: NpcSpotDefinition,
	locations: Node
) -> Dictionary:
	var player_destination := _get_live_player_destination(locations)
	if not player_destination.is_empty():
		return player_destination

	var current_scene_path := String(record.get("scene_path", ""))
	if current_scene_path == definition.scene_path:
		var last_position = record.get("last_position", definition.position)
		if last_position is Vector2:
			return {
				"scene_path": current_scene_path,
				"position": last_position,
			}

	return {
		"scene_path": definition.scene_path,
		"position": definition.position,
	}


func _get_live_player_destination(locations: Node) -> Dictionary:
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player == null or not is_instance_valid(player):
		return {}

	var scene_path := ""
	var current_scene := get_tree().current_scene
	if current_scene != null:
		scene_path = current_scene.scene_file_path
	if scene_path.is_empty() and locations != null and locations.has_method("get_current_scene_path"):
		scene_path = String(locations.call("get_current_scene_path"))
	if scene_path.is_empty():
		return {}

	return {
		"scene_path": scene_path,
		"position": player.global_position,
	}


func _update_pending_travel(
	npc_id: StringName,
	record: Dictionary,
	pending_travel: Dictionary,
	hour: float,
	locations: Node
) -> void:
	_clear_schedule_decision_debug(npc_id)
	var mode := String(pending_travel.get("mode", "start"))
	if mode == "start":
		var pending_activity = pending_travel.get("activity", {})
		var spot_id := StringName(String(pending_activity.get("spot_id", "")))
		var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
		if definition == null or _debug_definition_disabled(definition) or not definition.is_active_at(hour):
			if locations.has_method("cancel_pending_scheduled_travel"):
				if definition != null and _debug_definition_disabled(definition):
					_breadcrumb("npc_world:pending_disabled_definition", "%s %s" % [String(npc_id), String(spot_id)])
				locations.call("cancel_pending_scheduled_travel", String(npc_id))
			return
		if (
			_definition_is_meal_cycle_managed(definition)
			and not _meal_cycle_definition_can_start(definition, npc_id, hour)
		):
			if locations.has_method("cancel_pending_scheduled_travel"):
				locations.call("cancel_pending_scheduled_travel", String(npc_id))
			return

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if live_npc == null:
		var offscreen_leg := _get_pending_scene_route_leg(
			pending_travel,
			String(record.get("scene_path", "")),
			npc_id
		)
		if not bool(offscreen_leg.get("accepted", false)):
			_rollback_pending_travel(
				npc_id,
				pending_travel,
				locations,
				String(offscreen_leg.get("reason", "route_validation_failed"))
			)
			return
		var explicit_arrival_position = null
		var final_scene_path := String(pending_travel.get("target_scene_path", ""))
		var loaded_scene_path := (
			String(locations.call("get_current_scene_path"))
			if locations.has_method("get_current_scene_path")
			else ""
		)
		var enters_loaded_intermediate := (
			String(offscreen_leg.get("target_scene_path", "")) == loaded_scene_path
			and int(offscreen_leg.get("hop_index", -1)) + 1
				< int(offscreen_leg.get("hop_count", 0))
		)
		if enters_loaded_intermediate:
			var advance_result := NpcSceneRouteBridge.advance_resolved_leg(
				get_node_or_null("/root/NpcSceneRoutes"),
				pending_travel,
				offscreen_leg,
				npc_id,
				String(record.get("scene_path", ""))
			)
			var advanced_pending = advance_result.get("pending_travel", {})
			var intermediate_committed := (
				bool(advance_result.get("accepted", false))
				and not bool(advance_result.get("complete", true))
				and advanced_pending is Dictionary
				and locations.has_method("_commit_pending_route_advance_offscreen")
				and bool(locations.call(
					"_commit_pending_route_advance_offscreen",
					String(npc_id),
					pending_travel,
					advanced_pending,
					String(record.get("scene_path", "")),
					String(offscreen_leg.get("target_scene_path", "")),
					advance_result.get("arrival_position", Vector2.ZERO)
				))
			)
			if not intermediate_committed:
				var rejection_reason := (
					"offscreen_route_commit_cas_rejected"
					if bool(advance_result.get("accepted", false))
					else String(advance_result.get(
						"reason", "offscreen_route_hop_rejected"
					))
				)
				_rollback_pending_travel(
					npc_id,
					pending_travel,
					locations,
					rejection_reason
				)
			return
		if final_scene_path == loaded_scene_path:
			var final_arrival := NpcSceneRouteBridge.resolve_final_arrival(
				get_node_or_null("/root/NpcSceneRoutes"), pending_travel, npc_id
			)
			if bool(final_arrival.get("accepted", false)):
				explicit_arrival_position = final_arrival.get(
					"target_arrival_position", null
				)
		_commit_pending_travel_offscreen(
			npc_id, pending_travel, locations, explicit_arrival_position
		)
		return

	_resume_pending_travel(
		npc_id,
		live_npc,
		pending_travel,
		locations,
		String(record.get("scene_path", ""))
	)


func _resume_pending_travel(
	npc_id: StringName,
	npc: Node2D,
	pending_travel: Dictionary,
	locations: Node,
	current_scene_path: String = ""
) -> void:
	if current_scene_path.is_empty() and locations.has_method("get_npc_location"):
		var current_record: Dictionary = locations.call("get_npc_location", String(npc_id))
		current_scene_path = String(current_record.get("scene_path", ""))
	var route_leg := _get_pending_scene_route_leg(
		pending_travel, current_scene_path, npc_id
	)
	if not bool(route_leg.get("accepted", false)):
		_rollback_pending_travel(
			npc_id,
			pending_travel,
			locations,
			String(route_leg.get("reason", "route_validation_failed"))
		)
		return
	var target_scene_path := String(route_leg.get("target_scene_path", ""))
	var expected_route_edge_id := StringName(String(route_leg.get("edge_id", "")))
	var active_departure := _get_active_departure_door(
		npc,
		target_scene_path,
		expected_route_edge_id,
		NpcActionSessionModel.pending_travel_session_id(pending_travel)
	)
	if active_departure != null:
		return
	var departure_door := _find_departure_door(
		target_scene_path, npc, expected_route_edge_id
	)
	if departure_door == null:
		_rollback_pending_travel(npc_id, pending_travel, locations, "departure_door_missing")
		return
	if expected_route_edge_id == &"":
		var direct_validation := NpcSceneRouteBridge.validate_direct_route_wired_door(
			get_node_or_null("/root/NpcSceneRoutes"),
			departure_door,
			current_scene_path,
			target_scene_path,
			npc_id
		)
		if not bool(direct_validation.get("accepted", false)):
			_rollback_pending_travel(
				npc_id,
				pending_travel,
				locations,
				String(direct_validation.get("reason", "route_execution_rejected"))
			)
			return

	var requested_state_name := StringName(String(pending_travel.get("requested_state_name", "")))
	var requested_priority := int(pending_travel.get("requested_priority", 0))
	if locations.has_method("is_npc_available_for_scheduled_activity"):
		var pending_descriptor := _get_pending_travel_activity_descriptor(pending_travel, locations)
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			requested_state_name,
			requested_priority,
			pending_descriptor
		)):
			_rollback_pending_travel(npc_id, pending_travel, locations, "npc_unavailable")
			return
	if not locations.has_method("resume_pending_scheduled_travel"):
		_rollback_pending_travel(npc_id, pending_travel, locations, "travel_resume_method_missing")
		return
	var resumed := bool(locations.call(
		"resume_pending_scheduled_travel",
		String(npc_id),
		departure_door
	))
	if not resumed:
		_rollback_pending_travel(npc_id, pending_travel, locations, "travel_assignment_rejected")


func _rollback_pending_travel(
	npc_id: StringName,
	pending_travel: Dictionary,
	locations: Node,
	reason: String
) -> void:
	if locations != null and locations.has_method("get_record_snapshot"):
		var latest_record = locations.call("get_record_snapshot", String(npc_id))
		if latest_record is Dictionary and not latest_record.is_empty():
			var latest_pending = latest_record.get("pending_travel", {})
			if not (latest_pending is Dictionary) or latest_pending != pending_travel:
				_breadcrumb(
					"npc_world:pending_travel_rollback_stale",
					"%s %s" % [String(npc_id), reason]
				)
				return
	var activity = pending_travel.get("activity", {})
	if activity is Dictionary and not activity.is_empty():
		_log_activity_transaction(
			npc_id,
			activity,
			StringName(String(activity.get("spot_id", ""))),
			"rollback",
			reason
		)
	if locations != null and locations.has_method("cancel_pending_scheduled_travel"):
		var finish_mode := String(pending_travel.get("mode", "start")) == "finish"
		var pending_session_id := NpcActionSessionModel.pending_travel_session_id(
			pending_travel
		)
		# Structural route failures must discard the invalid route so the next
		# simulation pass can replan. Only MoveToTarget's exact-session watchdog
		# requests an in-place movement retry.
		if (
			finish_mode
			and locations.has_method("discard_pending_finish_route_for_replan")
		):
			locations.call(
				"discard_pending_finish_route_for_replan",
				String(npc_id),
				reason,
				pending_session_id
			)
			return
		var terminal_cancel := not finish_mode
		if (
			not pending_session_id.is_empty()
			and _method_accepts_argument_count(
				locations, &"cancel_pending_scheduled_travel", 4
			)
		):
			locations.call(
				"cancel_pending_scheduled_travel",
				String(npc_id),
				reason,
				terminal_cancel,
				pending_session_id
			)
		elif _method_accepts_argument_count(locations, &"cancel_pending_scheduled_travel", 3):
			locations.call(
				"cancel_pending_scheduled_travel",
				String(npc_id),
				reason,
				terminal_cancel
			)
		elif _method_accepts_argument_count(locations, &"cancel_pending_scheduled_travel", 2):
			locations.call("cancel_pending_scheduled_travel", String(npc_id), reason)
		else:
			locations.call("cancel_pending_scheduled_travel", String(npc_id))


func _commit_pending_travel_offscreen(
	npc_id: StringName,
	pending_travel: Dictionary,
	locations: Node,
	explicit_arrival_position = null
) -> void:
	var target_scene_path := String(pending_travel.get("target_scene_path", ""))
	var target_position = pending_travel.get("target_position", Vector2.ZERO)
	if not (target_position is Vector2):
		target_position = Vector2.ZERO

	if String(pending_travel.get("mode", "start")) == "finish":
		if locations.has_method("finish_scheduled_activity"):
			var finish_session_id := String(pending_travel.get("action_session_id", ""))
			var finished := _call_finish_scheduled_activity(
				locations,
				String(npc_id),
				target_scene_path,
				target_position,
				finish_session_id,
				explicit_arrival_position
			)
			if not finished:
				_rollback_pending_travel(
					npc_id,
					pending_travel,
					locations,
					"offscreen_finish_commit_rejected"
				)
		return
	if String(pending_travel.get("mode", "start")) == "social":
		if locations.has_method("cancel_pending_scheduled_travel"):
			locations.call("cancel_pending_scheduled_travel", String(npc_id))
		return

	var activity = pending_travel.get("activity", {})
	if activity is Dictionary and not activity.is_empty():
		var spot_id := StringName(String(activity.get("spot_id", "")))
		var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
		if _debug_definition_disabled(definition):
			_breadcrumb("npc_world:commit_travel_disabled_definition", "%s %s" % [String(npc_id), String(spot_id)])
			_rollback_pending_travel(
				npc_id, pending_travel, locations, "spot_definition_disabled"
			)
			return
		if not locations.has_method("begin_scheduled_activity"):
			_rollback_pending_travel(
				npc_id, pending_travel, locations, "begin_activity_method_missing"
			)
			return
		var committed := false
		if (
			explicit_arrival_position is Vector2
			and _method_accepts_argument_count(
				locations, &"begin_scheduled_activity", 5
			)
		):
			committed = bool(locations.call(
				"begin_scheduled_activity",
				String(npc_id),
				activity,
				target_scene_path,
				target_position,
				explicit_arrival_position
			))
		else:
			committed = bool(locations.call(
				"begin_scheduled_activity",
				String(npc_id),
				activity,
				target_scene_path,
				target_position
			))
		if not committed:
			_rollback_pending_travel(
				npc_id, pending_travel, locations, "offscreen_activity_commit_rejected"
			)


func _update_activity(
	npc_id: StringName,
	record: Dictionary,
	activity: Dictionary,
	total_hours: float,
	hour: float,
	locations: Node
) -> void:
	_clear_schedule_decision_debug(npc_id)
	var spot_id := StringName(String(activity.get("spot_id", "")))
	_breadcrumb("npc_world:update_activity", "%s %s" % [String(npc_id), String(spot_id)])
	if NpcRouteLocationCoordinator.record_has_finish_replan_marker(record, activity):
		_breadcrumb("npc_world:update_activity_finish_replan", String(npc_id))
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if _debug_definition_disabled(definition):
		_breadcrumb("npc_world:update_disabled_definition", "%s %s" % [String(npc_id), String(spot_id)])
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	var npc_is_live := (
		locations.has_method("is_npc_live")
		and bool(locations.call("is_npc_live", String(npc_id)))
	)
	var continuation := NpcScheduleWindowPolicy.evaluate_active_activity(
		definition,
		activity,
		total_hours
	)
	var activity_can_continue := _activity_can_continue(
		npc_id, record, definition, activity, total_hours, hour
	)
	if not activity_can_continue:
		if not npc_is_live:
			_apply_offscreen_progress_until_overtime_deadline(
				npc_id,
				record,
				activity,
				definition,
				continuation,
				locations
			)
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	if not npc_is_live:
		_observe_schedule_overtime_transition(
			npc_id,
			activity,
			continuation,
			total_hours,
			false
		)
	var interrupt_definition := _find_invitation_interrupt_definition(
		npc_id,
		record,
		total_hours,
		definition,
		int(activity.get("priority", definition.priority))
	)
	if interrupt_definition != null:
		_finish_activity(npc_id, record, activity, spot_id, locations)
		_queue_simulation()
		return

	var value_name := String(definition.value_name)
	if (
		definition.finish_when_npc_value_sated
		and not value_name.is_empty()
		and _get_saved_stat(record, value_name) <= 0.0
	):
		_mark_meal_owner_sated_if_needed(definition, npc_id, StringName(value_name))
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return

	if npc_is_live:
		var live_npc: Node = null
		if locations.has_method("get_live_npc"):
			live_npc = locations.call("get_live_npc", String(npc_id)) as Node
		if live_npc != null:
			resume_live_activity(npc_id, live_npc)
			var machine := live_npc.get_node_or_null("NpcStateMachine")
			var session_id := NpcActionSessionModel._descriptor_session_id(activity)
			if (
				machine != null
				and machine.has_method("get_active_action_session_id")
				and String(machine.call("get_active_action_session_id")) == session_id
			):
				_observe_schedule_overtime_transition(
					npc_id,
					activity,
					continuation,
					total_hours,
					true
				)
		return

	_apply_offscreen_activity_progress(
		npc_id,
		record,
		activity,
		definition,
		total_hours,
		locations
	)

	var npc_value_sated := (
		definition.finish_when_npc_value_sated
		and not value_name.is_empty()
		and _get_saved_stat(record, value_name) <= 0.0
	)
	if npc_value_sated:
		_mark_meal_owner_sated_if_needed(definition, npc_id, StringName(value_name))
	if npc_value_sated or not _spot_runtime_is_available(definition):
		_finish_activity(npc_id, record, activity, spot_id, locations)


func _apply_offscreen_progress_until_overtime_deadline(
	npc_id: StringName,
	record: Dictionary,
	activity: Dictionary,
	definition: NpcSpotDefinition,
	continuation: Dictionary,
	locations: Node
) -> void:
	if StringName(String(continuation.get("reason_code", ""))) != &"overtime_expired":
		return
	if definition == null or not _spot_runtime_is_available(definition):
		return
	if _definition_is_meal_cycle_managed(definition):
		return
	var value_name := String(definition.value_name)
	if (
		definition.finish_when_npc_value_sated
		and not value_name.is_empty()
		and _get_saved_stat(record, value_name) <= 0.0
	):
		return
	var overtime_end := float(continuation.get("overtime_end_total_hours", 0.0))
	var last_total_hours := float(activity.get("last_total_hours", overtime_end))
	if overtime_end <= last_total_hours:
		return
	_apply_offscreen_activity_progress(
		npc_id,
		record,
		activity,
		definition,
		overtime_end,
		locations
	)


func _apply_offscreen_activity_progress(
	npc_id: StringName,
	record: Dictionary,
	activity: Dictionary,
	definition: NpcSpotDefinition,
	progress_end_total_hours: float,
	locations: Node
) -> void:
	var last_total_hours := float(activity.get(
		"last_total_hours",
		progress_end_total_hours
	))
	var elapsed_game_hours := maxf(
		progress_end_total_hours - last_total_hours,
		0.0
	)
	activity["last_total_hours"] = progress_end_total_hours
	var value_name := String(definition.value_name)
	if elapsed_game_hours > 0.0 and not value_name.is_empty():
		if _definition_consumes_food_for_hunger(definition, value_name):
			_apply_offscreen_food_eat_progress(
				record, definition, value_name, elapsed_game_hours
			)
		else:
			_set_saved_stat(
				record,
				value_name,
				_get_saved_stat(record, value_name)
					+ definition.value_delta_per_game_hour * elapsed_game_hours
			)
	if _activity_should_apply_spot_runtime_progress(
		npc_id, activity, definition, locations
	):
		_apply_spot_runtime_progress(
			definition,
			elapsed_game_hours,
			progress_end_total_hours
		)
	record["activity"] = activity
	record["last_position"] = _get_activity_simulated_position(activity, definition)
	if locations.has_method("update_simulated_record"):
		_apply_simulated_record_update(locations, String(npc_id), record)


func _observe_schedule_overtime_transition(
	npc_id: StringName,
	activity: Dictionary,
	continuation: Dictionary,
	total_game_hours: float,
	npc_is_live: bool
) -> void:
	var session_id := NpcActionSessionModel._descriptor_session_id(activity)
	if session_id.is_empty():
		return
	var had_previous := _schedule_overtime_last_observed_by_session.has(session_id)
	var previous_total_hours := float(
		_schedule_overtime_last_observed_by_session.get(session_id, total_game_hours)
	)
	var previous_was_live := bool(
		_schedule_overtime_last_observed_live_by_session.get(session_id, false)
	)
	_schedule_overtime_last_observed_by_session[session_id] = total_game_hours
	_schedule_overtime_last_observed_live_by_session[session_id] = npc_is_live
	if (
		not had_previous
		or not previous_was_live
		or not npc_is_live
		or _schedule_overtime_sessions_emitted.has(session_id)
		or not bool(continuation.get("may_continue", false))
		or not bool(continuation.get("in_overtime", false))
		or StringName(String(continuation.get("completion_policy", "")))
			!= NpcScheduleWindowPolicy.COMPLETION_POLICY_FINISH_CURRENT
	):
		return
	var window_end := float(continuation.get("window_end_total_hours", 0.0))
	if previous_total_hours >= window_end or total_game_hours < window_end:
		return
	_schedule_overtime_sessions_emitted[session_id] = true
	scheduled_activity_entered_overtime.emit(
		npc_id,
		activity.duplicate(true),
		continuation.duplicate(true)
	)


func _definition_consumes_food_for_hunger(
	definition: NpcSpotDefinition,
	value_name: String
) -> bool:
	return (
		definition != null
		and definition.state_name == &"Eat"
		and value_name == "hunger"
		and definition.spot_value_name != &""
	)


func _apply_offscreen_food_eat_progress(
	record: Dictionary,
	definition: NpcSpotDefinition,
	value_name: String,
	elapsed_game_hours: float
) -> void:
	var current_hunger := _get_saved_stat(record, value_name)
	if current_hunger <= 0.0:
		return

	var requested_hunger_drop := minf(
		current_hunger,
		absf(definition.value_delta_per_game_hour) * elapsed_game_hours
	)
	if requested_hunger_drop <= 0.0:
		return

	var supplied_food := _consume_spot_food_amount(definition, requested_hunger_drop)
	if supplied_food <= 0.0:
		return

	_set_saved_stat(record, value_name, current_hunger - supplied_food)


func _consume_spot_food_amount(
	definition: NpcSpotDefinition,
	requested_amount: float
) -> float:
	if definition == null or requested_amount <= 0.0:
		return 0.0
	if not spot_runtime_states.has(String(definition.spot_id)):
		return 0.0

	var available_food := get_spot_value(definition.spot_id, definition.spot_value_initial)
	var done_threshold := definition.spot_value_done_threshold
	var consumable_food := maxf(available_food - done_threshold, 0.0)
	if consumable_food <= 0.0:
		return 0.0

	var requested_food := minf(requested_amount, consumable_food)
	var actual_delta := apply_spot_value_delta(definition.spot_id, -requested_food)
	return minf(absf(actual_delta), requested_food)


func _activity_should_apply_spot_runtime_progress(
	_npc_id: StringName,
	_activity: Dictionary,
	definition: NpcSpotDefinition,
	_locations: Node
) -> bool:
	if definition == null:
		return false
	if _definition_consumes_food_for_hunger(definition, String(definition.value_name)):
		return false
	if definition.state_name == INVITE_PLAYER_STATE:
		return false

	return true


func _get_activity_simulated_position(
	activity: Dictionary,
	definition: NpcSpotDefinition
) -> Vector2:
	if definition == null:
		return Vector2.ZERO
	if definition.state_name != INVITE_PLAYER_STATE:
		return definition.position

	var position_key := "target_position"
	if String(activity.get("lesson_phase", "inviting")) == "running":
		position_key = "lesson_position"
	var position_value = activity.get(position_key, definition.position)
	if position_value is Vector2:
		return position_value

	return definition.position


func _mark_meal_owner_sated_if_needed(
	definition: NpcSpotDefinition,
	npc_id: StringName,
	value_name: StringName
) -> void:
	if not _definition_is_meal_cycle_food(definition):
		return
	mark_meal_owner_sated(definition.spot_id, npc_id, value_name)


func _finish_activity(
	npc_id: StringName,
	record: Dictionary,
	activity: Dictionary,
	spot_id: StringName,
	locations: Node
) -> void:
	_breadcrumb("npc_world:finish_activity", "%s %s" % [String(npc_id), String(spot_id)])
	if String(activity.get("state_name", "")) == "Sleep":
		_set_saved_stat(record, "tired", 0.0)
		if locations.has_method("update_simulated_record"):
			_apply_simulated_record_update(locations, String(npc_id), record)
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	_consume_invitation_activity_availability(definition)

	var return_scene_path := String(activity.get("return_scene_path", record.get("scene_path", "")))
	var return_position = activity.get("return_position", record.get("last_position", Vector2.ZERO))
	if not (return_position is Vector2):
		return_position = Vector2.ZERO

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	var finish_replan_required := (
		NpcRouteLocationCoordinator.record_has_finish_replan_marker(record, activity)
	)
	if (
		live_npc == null
		and return_scene_path != String(record.get("scene_path", ""))
		and NpcRouteLocationCoordinator.supports_offscreen_route_transactions(
			locations
		)
	):
		var offscreen_pending := {
			"mode": "finish",
			"target_scene_path": return_scene_path,
			"target_position": return_position,
			"requested_state_name": "",
			"requested_priority": 100,
			"spot_id": String(spot_id),
			"action_session_id": NpcActionSessionModel._descriptor_session_id(activity),
		}
		var offscreen_route_setup := _prepare_pending_scene_route(
			offscreen_pending,
			String(record.get("scene_path", "")),
			return_scene_path,
			npc_id
		)
		if not bool(offscreen_route_setup.get("accepted", false)):
			_breadcrumb(
				"npc_world:finish_activity_offscreen_replan_reject",
				"%s %s" % [
					String(npc_id),
					String(offscreen_route_setup.get("reason", "route_unavailable")),
				]
			)
			return
		offscreen_pending = offscreen_route_setup.get(
			"pending_travel", offscreen_pending
		)
		if not NpcRouteLocationCoordinator.install_offscreen_finish_route(
			locations,
			get_node_or_null("/root/NpcSceneRoutes"),
			npc_id,
			record,
			activity,
			offscreen_pending,
			finish_replan_required
		):
			_breadcrumb(
				"npc_world:finish_activity_offscreen_replan_cas_reject", String(npc_id)
			)
			return
		var installed_record: Dictionary = locations.call(
			"get_record_snapshot", String(npc_id)
		)
		var installed_pending = installed_record.get("pending_travel", {})
		if not (installed_pending is Dictionary) or installed_pending.is_empty():
			_breadcrumb(
				"npc_world:finish_activity_offscreen_replan_install_missing", String(npc_id)
			)
			return
		_update_pending_travel(
			npc_id,
			installed_record,
			installed_pending,
			_get_current_time_of_day_hours(),
			locations
		)
		return
	if live_npc != null and return_scene_path != String(record.get("scene_path", "")):
		var pending_travel := {
			"mode": "finish",
			"target_scene_path": return_scene_path,
			"target_position": return_position,
			"requested_state_name": "",
			"requested_priority": 100,
			"spot_id": String(spot_id),
			"action_session_id": NpcActionSessionModel._descriptor_session_id(activity),
		}
		var expected_route_edge_id := &""
		var departure_door := _find_departure_door(return_scene_path, live_npc)
		if departure_door != null:
			var direct_validation := NpcSceneRouteBridge.validate_direct_route_wired_door(
				get_node_or_null("/root/NpcSceneRoutes"),
				departure_door,
				String(record.get("scene_path", "")),
				return_scene_path,
				npc_id
			)
			if not bool(direct_validation.get("accepted", false)):
				_breadcrumb(
					"npc_world:finish_activity_direct_route_reject",
					"%s %s" % [
						String(npc_id),
						String(direct_validation.get("reason", "route_unavailable")),
					]
				)
				return
		if departure_door == null:
			var route_setup := _prepare_pending_scene_route(
				pending_travel,
				String(record.get("scene_path", "")),
				return_scene_path,
				npc_id
			)
			if not bool(route_setup.get("accepted", false)):
				_breadcrumb(
					"npc_world:finish_activity_route_reject",
					"%s %s" % [String(npc_id), String(route_setup.get("reason", "route_unavailable"))]
				)
				return
			pending_travel = route_setup.get("pending_travel", pending_travel)
			expected_route_edge_id = StringName(String(route_setup.get("edge_id", "")))
			departure_door = _find_departure_door(
				String(route_setup.get("target_scene_path", "")),
				live_npc,
				expected_route_edge_id
			)
		if departure_door == null or not locations.has_method("prepare_scheduled_travel"):
			_breadcrumb("npc_world:finish_activity_departure_missing", String(npc_id))
			return
		var finish_travel_accepted := bool(locations.call(
			"prepare_scheduled_travel",
			String(npc_id),
			pending_travel,
			departure_door
		))
		if not finish_travel_accepted:
			_breadcrumb(
				"npc_world:finish_activity_travel_reject",
				"%s %s" % [String(npc_id), String(spot_id)]
			)
		return

	var finished := false
	if locations.has_method("finish_scheduled_activity"):
		finished = _call_finish_scheduled_activity(
			locations,
			String(npc_id),
			return_scene_path,
			return_position,
			NpcActionSessionModel._descriptor_session_id(activity)
		)
	if finished:
		var session_id := NpcActionSessionModel._descriptor_session_id(activity)
		_schedule_overtime_last_observed_by_session.erase(session_id)
		_schedule_overtime_last_observed_live_by_session.erase(session_id)
		_schedule_overtime_sessions_emitted.erase(session_id)
		_detach_live_npc_from_finished_activity(live_npc, spot_id)
		activity_finished.emit(npc_id, spot_id)


func _call_finish_scheduled_activity(
	locations: Node,
	npc_id: String,
	return_scene_path: String,
	return_position: Vector2,
	session_id: String,
	explicit_arrival_position = null
) -> bool:
	# Older/simple location adapters expose the original three-argument method.
	if (
		explicit_arrival_position is Vector2
		and _method_accepts_argument_count(locations, &"finish_scheduled_activity", 5)
	):
		return bool(locations.call(
			"finish_scheduled_activity",
			npc_id,
			return_scene_path,
			return_position,
			session_id,
			explicit_arrival_position
		))
	if _method_accepts_argument_count(locations, &"finish_scheduled_activity", 4):
		return bool(locations.call(
			"finish_scheduled_activity",
			npc_id,
			return_scene_path,
			return_position,
			session_id
		))
	return bool(locations.call(
		"finish_scheduled_activity", npc_id, return_scene_path, return_position
	))


func _call_move_simulated_social_visit(
	locations: Node,
	npc_id: String,
	target_scene_path: String,
	target_position: Vector2,
	target_id: String,
	session_id: String
) -> bool:
	if _method_accepts_argument_count(locations, &"move_simulated_npc_for_social_visit", 5):
		return bool(locations.call(
			"move_simulated_npc_for_social_visit",
			npc_id, target_scene_path, target_position, target_id, session_id
		))
	return bool(locations.call(
		"move_simulated_npc_for_social_visit",
		npc_id, target_scene_path, target_position, target_id
	))


func _method_accepts_argument_count(
	object: Object,
	method_name: StringName,
	argument_count: int
) -> bool:
	if object == null:
		return false
	for method_info in object.get_method_list():
		if StringName(method_info.get("name", &"")) != method_name:
			continue
		var arguments = method_info.get("args", [])
		return arguments is Array and arguments.size() >= argument_count
	return false


func _consume_invitation_activity_availability(definition: NpcSpotDefinition) -> void:
	if definition == null:
		return
	if definition.state_name != INVITE_PLAYER_STATE:
		return
	if definition.spot_value_name == &"":
		return

	set_spot_value(definition.spot_id, definition.spot_value_done_threshold, false)


func _detach_live_npc_from_finished_activity(
	live_npc: Node2D,
	spot_id: StringName
) -> void:
	if live_npc == null or not is_instance_valid(live_npc):
		return

	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition == null:
		return
	var spot := live_spots.get(spot_id, null) as Node2D
	if spot == null or not is_instance_valid(spot):
		return

	var machine := live_npc.get_node_or_null("NpcStateMachine")
	if machine == null or not machine.has_method("request_state"):
		return
	if not _npc_is_following_activity(machine, definition, spot):
		return

	var idle_accepted := bool(machine.call(
		"request_state",
		&"Idle",
		null,
		"world_activity_finished",
		definition.priority
	))
	if not idle_accepted:
		_breadcrumb(
			"npc_world:finish_activity_idle_reject",
			"%s %s" % [live_npc.name, String(spot_id)]
		)


func _find_departure_door(
	target_scene_path: String,
	npc: Node2D,
	expected_route_edge_id: StringName = &""
) -> Node2D:
	if target_scene_path.is_empty() or npc == null or not is_instance_valid(npc):
		return null

	var closest_door: Node2D
	var closest_distance := INF
	for door_node in get_tree().get_nodes_in_group("npc_travel_door"):
		var door := door_node as Node2D
		if door == null or not is_instance_valid(door):
			continue
		if not _door_matches_departure(
			door, target_scene_path, expected_route_edge_id, npc
		):
			continue

		var distance := npc.global_position.distance_squared_to(door.global_position)
		if distance < closest_distance:
			closest_distance = distance
			closest_door = door

	return closest_door


func _get_active_departure_door(
	npc: Node2D,
	target_scene_path: String,
	expected_route_edge_id: StringName,
	expected_session_id: String = ""
) -> Node2D:
	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return null
	var current_state = machine.get("current_state")
	if current_state == null or String(current_state.name) != "MoveToTarget":
		return null
	if not expected_session_id.is_empty():
		if machine.has_method("is_action_session_current_for_execution"):
			if not bool(machine.call(
				"is_action_session_current_for_execution",
				expected_session_id,
				&"MoveToTarget"
			)):
				return null
		elif (
			not machine.has_method("get_active_action_session_id")
			or String(machine.call("get_active_action_session_id")).strip_edges()
				!= expected_session_id
		):
			return null
	var move_target := machine.get("move_target") as Node2D
	if not _door_matches_departure(
		move_target, target_scene_path, expected_route_edge_id, npc
	):
		return null
	return move_target


func _door_matches_departure(
	door: Node2D,
	target_scene_path: String,
	expected_route_edge_id: StringName,
	npc: Node2D
) -> bool:
	if door == null or not is_instance_valid(door):
		return false
	if not door.is_in_group(&"npc_travel_door"):
		return false
	if String(door.get("target_scene_path")) != target_scene_path:
		return false
	if expected_route_edge_id != &"":
		if not door.has_method("get_route_edge_id"):
			return false
		if StringName(String(door.call("get_route_edge_id"))) != expected_route_edge_id:
			return false
	if door.has_method("can_npc_use") and not bool(door.call("can_npc_use", npc)):
		return false
	return true


func _prepare_pending_scene_route(
	pending_travel: Dictionary,
	source_scene_path: String,
	target_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	return NpcRouteBridge.prepare_pending_route(
		get_node_or_null("/root/NpcSceneRoutes"),
		pending_travel,
		source_scene_path,
		target_scene_path,
		npc_id
	)


func _get_pending_scene_route_leg(
	pending_travel: Dictionary,
	current_scene_path: String,
	npc_id: StringName
) -> Dictionary:
	return NpcRouteBridge.resolve_pending_leg(
		get_node_or_null("/root/NpcSceneRoutes"),
		pending_travel,
		current_scene_path,
		npc_id
	)


func _find_best_definition(
	npc_id: StringName,
	record: Dictionary,
	hour: float
) -> NpcSpotDefinition:
	return NpcActivitySelector.find_best_definition(
		spot_definitions,
		npc_id,
		record,
		hour,
		self
	)


func _find_best_candidate(
	npc_id: StringName,
	record: Dictionary,
	total_game_hours: float
) -> Dictionary:
	return NpcActivitySelector.find_best_candidate(
		spot_definitions,
		npc_id,
		record,
		total_game_hours,
		self
	)


func _apply_schedule_metadata_to_activity(
	activity: Dictionary,
	definition: NpcSpotDefinition,
	decision: Dictionary,
	effective_priority: int
) -> void:
	if activity.is_empty() or definition == null or decision.is_empty():
		return
	var metadata := {
		"schedule_phase": String(decision.get("phase", "closed")),
		"schedule_occurrence_key": String(decision.get("occurrence_key", "")),
		"schedule_window_index": int(decision.get("window_index", -1)),
		"schedule_window_start_total_hours": float(decision.get(
			"window_start_total_hours",
			0.0
		)),
		"schedule_grace_end_total_hours": float(decision.get(
			"grace_end_total_hours",
			0.0
		)),
		"schedule_window_end_total_hours": float(decision.get(
			"window_end_total_hours",
			0.0
		)),
		"schedule_lateness_game_hours": float(decision.get(
			"lateness_game_hours",
			0.0
		)),
		"schedule_base_priority": definition.priority,
		"schedule_effective_priority": effective_priority,
		"schedule_completion_policy": String(decision.get(
			"completion_policy",
			NpcScheduleWindowPolicy.COMPLETION_POLICY_STOP_AT_WINDOW_END
		)),
		"schedule_maximum_overtime_game_hours": float(decision.get(
			"maximum_overtime_game_hours",
			0.0
		)),
		"schedule_overtime_end_total_hours": float(decision.get(
			"overtime_end_total_hours",
			decision.get("window_end_total_hours", 0.0)
		)),
	}
	for metadata_key in metadata:
		activity[metadata_key] = metadata[metadata_key]
	var action_metadata_value: Variant = activity.get("metadata", {})
	var action_metadata: Dictionary = (
		action_metadata_value.duplicate(true)
		if action_metadata_value is Dictionary
		else {}
	)
	action_metadata.merge(metadata, true)
	activity["metadata"] = action_metadata


func _should_defer_flexible_live_start(
	npc_id: StringName,
	definition: NpcSpotDefinition,
	decision: Dictionary,
	locations: Node
) -> bool:
	if (
		definition == null
		or StringName(String(decision.get("start_policy", "hard")))
			!= NpcScheduleWindowPolicy.START_POLICY_FLEXIBLE
		or StringName(String(decision.get("phase", "closed")))
			!= NpcScheduleWindowPolicy.PHASE_ON_TIME
		or bool(decision.get("may_interrupt_busy_live_npc", true))
	):
		return false
	var live_npc := _get_live_schedule_npc(npc_id, locations)
	if live_npc == null:
		return false
	var machine := live_npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return false
	if machine.has_method("is_socially_engaged") and bool(
		machine.call("is_socially_engaged")
	):
		return true
	var current_state = machine.get("current_state")
	if current_state == null or String(current_state.name) == "Idle":
		return false
	var spot := live_spots.get(definition.spot_id, null) as Node2D
	if machine.has_method("is_following_activity_descriptor"):
		var continuation_descriptor := _get_activity_descriptor(
			definition,
			spot,
			{
				"spot_id": String(definition.spot_id),
				"state_name": String(definition.state_name),
				"target_scene_path": definition.scene_path,
			}
		)
		if bool(machine.call(
			"is_following_activity_descriptor",
			continuation_descriptor
		)):
			return false
	return true


func _live_schedule_start_has_protected_ownership(
	npc_id: StringName,
	locations: Node
) -> bool:
	var live_npc := _get_live_schedule_npc(npc_id, locations)
	if live_npc == null:
		return false
	var machine := live_npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return false
	if machine.has_method("get_scheduled_activity_ownership_gate"):
		var gate: Dictionary = machine.call("get_scheduled_activity_ownership_gate")
		return bool(gate.get("protected", false))
	if machine.has_method("is_socially_engaged") and bool(
		machine.call("is_socially_engaged")
	):
		return true
	return _machine_schedule_start_is_emergency_or_scripted(machine)


func _live_schedule_start_is_emergency_or_scripted(
	npc_id: StringName,
	locations: Node
) -> bool:
	var live_npc := _get_live_schedule_npc(npc_id, locations)
	if live_npc == null:
		return false
	return _machine_schedule_start_is_emergency_or_scripted(
		live_npc.get_node_or_null("NpcStateMachine")
	)


func _machine_schedule_start_is_emergency_or_scripted(machine: Node) -> bool:
	if machine == null:
		return false
	if machine.has_method("get_scheduled_activity_ownership_gate"):
		var gate: Dictionary = machine.call("get_scheduled_activity_ownership_gate")
		return bool(gate.get("protected", false))
	if machine.has_method("has_scripted_control_claim") and bool(
		machine.call("has_scripted_control_claim")
	):
		return true
	var current_state = machine.get("current_state")
	var current_state_name := String(current_state.name) if current_state != null else ""
	if current_state_name in [
		"Fight",
		"Flee",
		"ReactToEvent",
		"Collapse",
		"Knockout",
		"DisabledDead",
		"Dead",
	]:
		return true
	return false


func _get_live_schedule_npc(
	npc_id: StringName,
	locations: Node
) -> Node:
	if locations == null or not locations.has_method("get_live_npc"):
		return null
	var live_npc = locations.call("get_live_npc", String(npc_id)) as Node
	if live_npc == null or not is_instance_valid(live_npc):
		return null
	return live_npc


func _set_schedule_decision_debug(
	npc_id: StringName,
	definition: NpcSpotDefinition,
	decision: Dictionary,
	locations: Node,
	deferred_for_flexible_grace: bool
) -> void:
	if definition == null or decision.is_empty():
		_clear_schedule_decision_debug(npc_id)
		return
	var current_state := &""
	var live_npc := _get_live_schedule_npc(npc_id, locations)
	if live_npc != null:
		var machine := live_npc.get_node_or_null("NpcStateMachine")
		var state = machine.get("current_state") if machine != null else null
		if state != null:
			current_state = StringName(state.name)
	var now_game_hours := float(decision.get(
		"evaluated_total_game_hours",
		0.0
	))
	_schedule_decision_debug_by_npc[String(npc_id)] = {
		"spot_id": definition.spot_id,
		"phase": StringName(String(decision.get("phase", "closed"))),
		"start_policy": StringName(String(decision.get("start_policy", "hard"))),
		"occurrence_key": String(decision.get("occurrence_key", "")),
		"window_index": int(decision.get("window_index", -1)),
		"effective_priority": int(decision.get(
			"effective_priority",
			definition.priority
		)),
		"current_state": current_state,
		"deferred_for_flexible_grace": deferred_for_flexible_grace,
		"grace_remaining_game_hours": maxf(
			float(decision.get("grace_end_total_hours", now_game_hours))
				- now_game_hours,
			0.0
		),
		"lateness_game_hours": float(decision.get(
			"lateness_game_hours",
			0.0
		)),
	}


func _clear_schedule_decision_debug(npc_id: StringName) -> void:
	_schedule_decision_debug_by_npc.erase(String(npc_id))


func get_schedule_decision_debug_descriptor(npc_id: StringName) -> Dictionary:
	var descriptor_value: Variant = _schedule_decision_debug_by_npc.get(
		String(npc_id),
		{}
	)
	return (
		descriptor_value.duplicate(true)
		if descriptor_value is Dictionary
		else {}
	)


func _find_invitation_interrupt_definition(
	npc_id: StringName,
	record: Dictionary,
	total_game_hours: float,
	current_definition: NpcSpotDefinition,
	current_effective_priority: int = -1000000
) -> NpcSpotDefinition:
	if current_definition == null:
		return null
	if current_definition.state_name == INVITE_PLAYER_STATE:
		return null
	if current_effective_priority <= -1000000:
		current_effective_priority = current_definition.priority

	var best_candidate := _find_best_candidate(
		npc_id,
		record,
		total_game_hours
	)
	var best_definition := best_candidate.get(
		"definition",
		null
	) as NpcSpotDefinition
	if best_definition == null:
		return null
	if _debug_definition_disabled(best_definition):
		_breadcrumb("npc_world:invitation_interrupt_disabled", "%s %s" % [String(npc_id), String(best_definition.spot_id)])
		return null
	if best_definition.spot_id == current_definition.spot_id:
		return null
	if best_definition.state_name != INVITE_PLAYER_STATE:
		return null
	if int(best_candidate.get(
		"effective_priority",
		best_definition.priority
	)) <= current_effective_priority:
		return null

	return best_definition


func _variant_array_has_string(values, expected: String) -> bool:
	if not (values is Array):
		return false
	for value in values:
		if String(value) == expected:
			return true
	return false


func _state_names_match(left_state_name: StringName, right_state_name: StringName) -> bool:
	if String(left_state_name) == String(right_state_name):
		return true

	return String(left_state_name).to_snake_case() == String(right_state_name).to_snake_case()


func _get_effective_need_threshold(definition: NpcSpotDefinition, hour: float) -> float:
	return NpcActivitySelector.get_effective_need_threshold(definition, hour, self)


func _get_timed_need_threshold(definition: NpcSpotDefinition, hour: float) -> float:
	return NpcActivitySelector.get_timed_need_threshold(definition, hour)


func _time_window_contains_hour(window: Dictionary, hour: float) -> bool:
	return NpcActivitySelector.time_window_contains_hour(window, hour)


func _get_definition_urgency(definition: NpcSpotDefinition) -> float:
	return NpcActivitySelector.get_definition_urgency(definition, self)


func _rebuild_spot_claims(records: Dictionary) -> void:
	repair_orphan_spot_reservations(records)


func make_spot_reservation_id(
	session_id: String,
	spot_id: StringName,
	purpose: StringName = &"activity"
) -> String:
	return "%s|%s|%s" % [session_id.strip_edges(), String(spot_id), String(purpose)]


func try_claim_spot(
	npc_id: StringName,
	session_id: String,
	spot_id: StringName,
	purpose: StringName = &"activity"
) -> Dictionary:
	var normalized_session_id := session_id.strip_edges()
	var normalized_purpose := purpose if purpose != &"" else &"activity"
	if npc_id == &"":
		return {"accepted": false, "status": "invalid_npc"}
	if normalized_session_id.is_empty():
		return {"accepted": false, "status": "invalid_session"}
	if spot_id == &"" or not _spot_exists_for_reservation(spot_id):
		return {"accepted": false, "status": "invalid_spot"}
	var reservation_id := make_spot_reservation_id(
		normalized_session_id, spot_id, normalized_purpose
	)
	if spot_reservations.has(reservation_id):
		var existing: Dictionary = spot_reservations[reservation_id]
		if (
			String(existing.get("npc_id", "")) == String(npc_id)
			and String(existing.get("session_id", "")) == normalized_session_id
			and String(existing.get("spot_id", "")) == String(spot_id)
		):
			return {
				"accepted": true,
				"status": "already_owned",
				"reservation_id": reservation_id,
				"reservation": existing.duplicate(true),
			}
		_warn_reservation_once(
			"conflict|%s" % reservation_id,
			"NPC reservation ID conflict: reservation=%s npc=%s session=%s" % [
				reservation_id, String(npc_id), normalized_session_id
			]
		)
		return {"accepted": false, "status": "reservation_id_conflict"}
	var capacity := _get_spot_reservation_capacity(spot_id)
	if capacity > 0 and get_spot_reservations(spot_id).size() >= capacity:
		_warn_reservation_once(
			"capacity|%s|%s" % [String(spot_id), normalized_session_id],
			"NPC spot capacity rejected: spot=%s npc=%s session=%s capacity=%d" % [
				String(spot_id), String(npc_id), normalized_session_id, capacity
			]
		)
		return {"accepted": false, "status": "spot_capacity_unavailable"}
	var reservation := {
		"reservation_id": reservation_id,
		"npc_id": String(npc_id),
		"session_id": normalized_session_id,
		"spot_id": String(spot_id),
		"purpose": String(normalized_purpose),
	}
	spot_reservations[reservation_id] = reservation
	_sync_spot_claim_count_cache()
	return {
		"accepted": true,
		"status": "claimed",
		"reservation_id": reservation_id,
		"reservation": reservation.duplicate(true),
	}


func release_spot_reservation(
	reservation_id: String,
	expected_npc_id: StringName = &"",
	expected_session_id: String = ""
) -> bool:
	var normalized_id := reservation_id.strip_edges()
	if normalized_id.is_empty() or not spot_reservations.has(normalized_id):
		return false
	var reservation: Dictionary = spot_reservations[normalized_id]
	if (
		expected_npc_id != &""
		and String(reservation.get("npc_id", "")) != String(expected_npc_id)
	):
		_warn_reservation_once(
			"wrong_npc|%s|%s" % [normalized_id, String(expected_npc_id)],
			"NPC reservation release rejected: reservation=%s expected_npc=%s owner_npc=%s" % [
				normalized_id, String(expected_npc_id), String(reservation.get("npc_id", ""))
			]
		)
		return false
	if (
		not expected_session_id.is_empty()
		and String(reservation.get("session_id", "")) != expected_session_id
	):
		_warn_reservation_once(
			"wrong_session|%s|%s" % [normalized_id, expected_session_id],
			"NPC reservation release rejected: reservation=%s expected_session=%s owner_session=%s" % [
				normalized_id, expected_session_id, String(reservation.get("session_id", ""))
			]
		)
		return false
	spot_reservations.erase(normalized_id)
	_sync_spot_claim_count_cache()
	return true


func release_session_spot_reservations(
	npc_id: StringName,
	session_id: String
) -> int:
	if npc_id == &"" or session_id.strip_edges().is_empty():
		return 0
	var reservation_ids: Array[String] = []
	for reservation_id in spot_reservations.keys():
		var reservation: Dictionary = spot_reservations[reservation_id]
		if (
			String(reservation.get("npc_id", "")) == String(npc_id)
			and String(reservation.get("session_id", "")) == session_id
		):
			reservation_ids.append(String(reservation_id))
	for reservation_id in reservation_ids:
		spot_reservations.erase(reservation_id)
	if not reservation_ids.is_empty():
		_sync_spot_claim_count_cache()
	return reservation_ids.size()


func session_owns_spot(
	npc_id: StringName,
	session_id: String,
	spot_id: StringName,
	purpose: StringName = &"activity"
) -> bool:
	var reservation_id := make_spot_reservation_id(session_id, spot_id, purpose)
	if not spot_reservations.has(reservation_id):
		return false
	var reservation: Dictionary = spot_reservations[reservation_id]
	return (
		String(reservation.get("npc_id", "")) == String(npc_id)
		and String(reservation.get("session_id", "")) == session_id
		and String(reservation.get("spot_id", "")) == String(spot_id)
	)


func get_spot_reservations(spot_id: StringName) -> Array[Dictionary]:
	var reservations: Array[Dictionary] = []
	for reservation_value in spot_reservations.values():
		if not (reservation_value is Dictionary):
			continue
		var reservation: Dictionary = reservation_value
		if String(reservation.get("spot_id", "")) == String(spot_id):
			reservations.append(reservation.duplicate(true))
	return reservations


func get_spot_reservation_diagnostics(spot_id: StringName) -> Dictionary:
	return {
		"spot_id": String(spot_id),
		"capacity": _get_spot_reservation_capacity(spot_id),
		"occupancy": get_spot_reservations(spot_id).size(),
		"reservations": get_spot_reservations(spot_id),
	}


func inspect_action_spot_reservations(
	npc_id: StringName,
	session_id: String,
	spot_id: StringName,
	referenced_ids,
	purpose: StringName = &"activity"
) -> Dictionary:
	var actual_ids: Array[String] = []
	for reservation_id in spot_reservations.keys():
		var reservation: Dictionary = spot_reservations[reservation_id]
		if (
			String(reservation.get("npc_id", "")) == String(npc_id)
			and String(reservation.get("session_id", "")) == session_id
		):
			actual_ids.append(String(reservation_id))
	var referenced: Array[String] = []
	if referenced_ids is Array or referenced_ids is PackedStringArray:
		for reservation_id in referenced_ids:
			referenced.append(String(reservation_id))
	var missing: Array[String] = []
	for reservation_id in referenced:
		if reservation_id.contains("|") and not spot_reservations.has(reservation_id):
			missing.append(reservation_id)
	var unreferenced: Array[String] = []
	for reservation_id in actual_ids:
		if reservation_id not in referenced:
			unreferenced.append(reservation_id)
	return {
		"session_id": session_id,
		"spot_id": String(spot_id),
		"expected_reservation_id": (
			make_spot_reservation_id(session_id, spot_id, purpose) if spot_id != &"" else ""
		),
		"owns_named_spot": (
			session_owns_spot(npc_id, session_id, spot_id, purpose) if spot_id != &"" else true
		),
		"actual_reservation_ids": actual_ids,
		"missing_reservation_ids": missing,
		"ledger_ids_absent_from_action": unreferenced,
	}


func debug_print_spot_reservations(spot_id: StringName) -> void:
	if not OS.is_debug_build():
		return
	var diagnostics := get_spot_reservation_diagnostics(spot_id)
	print("NPC spot reservations: spot=%s capacity=%d occupancy=%d owners=%s" % [
		String(spot_id),
		int(diagnostics.get("capacity", 0)),
		int(diagnostics.get("occupancy", 0)),
		str(diagnostics.get("reservations", [])),
	])


func repair_orphan_spot_reservations(records: Dictionary) -> void:
	var recognized: Dictionary = {}
	for npc_key in records.keys():
		var record_value = records[npc_key]
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		_collect_record_reservation_references(StringName(String(npc_key)), record, recognized)
	var removed := 0
	for reservation_id in spot_reservations.keys().duplicate():
		var normalized := _normalize_reservation_record(
			StringName(String(reservation_id)), spot_reservations[reservation_id]
		)
		if normalized.is_empty() or not recognized.has(String(reservation_id)):
			spot_reservations.erase(reservation_id)
			removed += 1
			continue
		var expected: Dictionary = recognized[String(reservation_id)]
		if (
			String(normalized.get("npc_id", "")) != String(expected.get("npc_id", ""))
			or String(normalized.get("session_id", "")) != String(expected.get("session_id", ""))
			or String(normalized.get("spot_id", "")) != String(expected.get("spot_id", ""))
		):
			spot_reservations.erase(reservation_id)
			removed += 1
	var restored := 0
	for reservation_id in recognized.keys():
		if spot_reservations.has(reservation_id):
			continue
		var expected: Dictionary = recognized[reservation_id]
		var claim_result := try_claim_spot(
			StringName(String(expected.get("npc_id", ""))),
			String(expected.get("session_id", "")),
			StringName(String(expected.get("spot_id", ""))),
			StringName(String(expected.get("purpose", "activity")))
		)
		if String(claim_result.get("status", "")) == "claimed":
			restored += 1
	_sync_spot_claim_count_cache()
	if OS.is_debug_build() and (removed > 0 or restored > 0):
		print("NPC reservation repair: restored=%d removed=%d active=%d" % [
			restored, removed, spot_reservations.size()
		])


func _collect_record_reservation_references(
	npc_id: StringName,
	record: Dictionary,
	recognized: Dictionary
) -> void:
	var descriptors: Array[Dictionary] = []
	for key in [&"action", &"activity"]:
		var value = record.get(key, {})
		if value is Dictionary and not value.is_empty():
			descriptors.append(value)
	var pending = record.get("pending_travel", {})
	if pending is Dictionary and not pending.is_empty():
		var pending_activity = pending.get("activity", {})
		if pending_activity is Dictionary and not pending_activity.is_empty():
			descriptors.append(pending_activity)
	for descriptor in descriptors:
		var status := String(descriptor.get("status", "active"))
		if status in ["completed", "failed", "cancelled", "cancelling"]:
			continue
		var session_id := NpcActionSessionModel._descriptor_session_id(descriptor)
		var spot_id := StringName(String(descriptor.get("spot_id", "")))
		if session_id.is_empty() or spot_id == &"":
			continue
		var purpose := StringName(String(descriptor.get("reservation_purpose", "activity")))
		var reservation_id := make_spot_reservation_id(session_id, spot_id, purpose)
		var listed_ids = descriptor.get("reservation_ids", [])
		var has_exact_id := false
		if listed_ids is Array or listed_ids is PackedStringArray:
			for listed_id in listed_ids:
				if String(listed_id) == reservation_id:
					has_exact_id = true
					break
		if not has_exact_id:
			continue
		recognized[reservation_id] = {
			"npc_id": String(npc_id),
			"session_id": session_id,
			"spot_id": String(spot_id),
			"purpose": String(purpose),
		}


func _normalize_reservation_record(reservation_id: StringName, value) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var record: Dictionary = value
	var npc_id := String(record.get("npc_id", "")).strip_edges()
	var session_id := String(record.get("session_id", "")).strip_edges()
	var spot_id := StringName(String(record.get("spot_id", "")))
	var purpose := StringName(String(record.get("purpose", "activity")))
	if npc_id.is_empty() or session_id.is_empty() or spot_id == &"":
		return {}
	var expected_id := make_spot_reservation_id(session_id, spot_id, purpose)
	if String(reservation_id) != expected_id:
		return {}
	return {
		"reservation_id": expected_id,
		"npc_id": npc_id,
		"session_id": session_id,
		"spot_id": String(spot_id),
		"purpose": String(purpose),
	}


func _spot_exists_for_reservation(spot_id: StringName) -> bool:
	if spot_definitions.has(spot_id):
		return true
	var live_spot = live_spots.get(spot_id, null)
	return live_spot != null and is_instance_valid(live_spot)


func _get_spot_reservation_capacity(spot_id: StringName) -> int:
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition != null:
		return maxi(definition.capacity, 0)
	var live_spot = live_spots.get(spot_id, null)
	if live_spot != null and is_instance_valid(live_spot):
		for property_info in live_spot.get_property_list():
			var property_name := StringName(String(property_info.get("name", "")))
			if property_name in [&"reservation_capacity", &"capacity"]:
				return maxi(int(live_spot.get(property_name)), 0)
	return 1


func _sync_spot_claim_count_cache() -> void:
	spot_claim_counts.clear()
	for reservation_value in spot_reservations.values():
		if not (reservation_value is Dictionary):
			continue
		var spot_id := StringName(String(reservation_value.get("spot_id", "")))
		if spot_id != &"":
			spot_claim_counts[spot_id] = int(spot_claim_counts.get(spot_id, 0)) + 1
	if OS.is_debug_build():
		for spot_id in spot_claim_counts.keys():
			assert(
				int(spot_claim_counts[spot_id]) == get_spot_reservations(spot_id).size(),
				"NPC spot claim cache diverged from the reservation ledger."
			)


func _add_descriptor_reservation_id(descriptor: Dictionary, reservation_id: String) -> void:
	if reservation_id.is_empty():
		return
	var normalized: Array[String] = []
	var values = descriptor.get("reservation_ids", [])
	if values is Array or values is PackedStringArray:
		for value in values:
			var existing_id := String(value).strip_edges()
			if not existing_id.is_empty() and existing_id not in normalized:
				normalized.append(existing_id)
	if reservation_id not in normalized:
		normalized.append(reservation_id)
	descriptor["reservation_ids"] = normalized


func _warn_reservation_once(key: String, message: String) -> void:
	if not OS.is_debug_build() or _logged_reservation_warnings.has(key):
		return
	_logged_reservation_warnings[key] = true
	push_warning(message)


func _spot_has_capacity(definition: NpcSpotDefinition) -> bool:
	return NpcActivitySelector.spot_has_capacity(definition, self)


func _spot_runtime_is_available(definition: NpcSpotDefinition) -> bool:
	if _debug_definition_disabled(definition):
		return false
	return NpcActivitySelector.spot_runtime_is_available(definition, self)


func _apply_spot_runtime_progress(
	definition: NpcSpotDefinition,
	game_hours: float,
	total_hours: float = -1.0
) -> void:
	if _debug_definition_disabled(definition):
		_breadcrumb("npc_world:runtime_progress_disabled", String(definition.spot_id) if definition != null else "")
		return
	if definition.spot_value_name == &"" or game_hours <= 0.0:
		return
	if _definition_is_meal_cycle_food(definition):
		return
	if _definition_is_meal_cycle_controller(definition):
		_apply_meal_cycle_work_progress(definition, game_hours, total_hours)
		return
	apply_spot_value_delta(
		definition.spot_id,
		definition.spot_value_delta_per_game_hour * game_hours
	)


func _meal_cycle_debug_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_NPC_MEAL_CYCLE_RUNTIME
	)


func _world_simulation_debug_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_NPC_WORLD_SIMULATION_TICK
	)


func _log_world_simulation_disabled(context: String) -> void:
	if simulation_tick_skip_logged:
		return
	_breadcrumb(
		"npc_world:tick_skip",
		"%s DEBUG_DISABLE_NPC_WORLD_SIMULATION_TICK" % context
	)
	simulation_tick_skip_logged = true


func _saved_stat_exists(record: Dictionary, value_name: String) -> bool:
	return NpcActivitySelector.saved_stat_exists(record, value_name)


func _validate_live_spot_alignment(spot_id: StringName, spot: Node2D) -> void:
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition == null or not spot.is_inside_tree():
		return

	var current_scene := get_tree().current_scene
	if current_scene != null and current_scene.scene_file_path != definition.scene_path:
		push_warning(
			"NPC spot '%s' is loaded in '%s' but its definition points to '%s'."
			% [String(spot_id), current_scene.scene_file_path, definition.scene_path]
		)
		return
	if spot.global_position.distance_to(definition.position) > 2.0:
		push_warning(
			"NPC spot '%s' position differs from its world definition (%s vs %s)."
			% [String(spot_id), str(spot.global_position), str(definition.position)]
		)


func _record_is_disabled(record: Dictionary) -> bool:
	return _get_saved_stat(record, "disabled") >= 1.0 or _get_saved_stat(record, "hp") <= 0.0


func _get_saved_stat(record: Dictionary, value_name: String) -> float:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return 0.0
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		return 0.0

	return float(social_stats.get(value_name, 0.0))


func _set_saved_stat(record: Dictionary, value_name: String, value: float) -> void:
	if STORED_ONLY_VALUE_KEYS.has(value_name):
		return
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		node_state = {}
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		social_stats = {}

	social_stats[value_name] = clampf(value, 0.0, 100.0)
	node_state["social_stats"] = social_stats
	record["node_state"] = node_state


func _debug_definition_disabled(definition: NpcSpotDefinition) -> bool:
	if definition == null:
		return false
	if not DebugToolsConfig.TROUBLESHOOTING_MODE:
		return false

	var definition_spot_id := definition.spot_id
	if (
		DebugToolsConfig.DEBUG_DISABLE_MAGIC_LESSON_ACTIVITY
		and (
			definition_spot_id == &"mom_magic_lesson"
			or definition.state_name == INVITE_PLAYER_STATE
		)
	):
		return true

	if definition.scene_path != "res://scenes/testscenes/realtest1.tscn":
		return false

	if DebugToolsConfig.DEBUG_DISABLE_REALTEST1_WORK_SPOT and definition_spot_id == &"mom_work":
		return true

	if not DebugToolsConfig.DEBUG_DISABLE_REALTEST1_MEAL_SPOT:
		return false
	if definition_spot_id == &"mom_eat" or definition_spot_id == &"mom_eat_prep":
		return true
	return definition.meal_cycle_id == &"mom_meal_cycle"


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
