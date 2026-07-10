extends Node

signal activity_started(npc_id: StringName, spot_id: StringName)
signal activity_finished(npc_id: StringName, spot_id: StringName)

const SPOT_DATA_DIRECTORY := "res://data/npc_spots"
const PLAYER_SOCIAL_TARGET_ID := "__player__"
const DEFAULT_SLEEP_SKIP_WAKE_HUNGER_MAX := 60.0
const DEFAULT_PASSIVE_HEALING_PER_GAME_DAY := 10.0
const DEFAULT_STARVATION_DAMAGE_PER_GAME_DAY := 5.0
const MEAL_STAGE_PREP_WORK := "prep_work"
const MEAL_STAGE_FOOD := "food"
const MEAL_STAGE_CLEANUP_WORK := "cleanup_work"
const MEAL_OWNER_PREP := "prep"
const MEAL_OWNER_FOOD := "food"
const MEAL_OWNER_CLEANUP := "cleanup"
const MEAL_CYCLE_EPSILON := 0.001
const INVITE_PLAYER_STATE := &"InvitePlayer"
const MagicLessonRemoteInvitationScene := preload("res://scripts/instances/magic_lesson_remote_invitation.gd")

@export var simulation_interval_seconds: float = 10.0
@export var simulated_talk_need_drop: float = 40.0
@export var simulated_partner_talk_need_drop: float = 25.0
@export var simulated_talk_boredom_drop: float = 10.0

var spot_definitions: Dictionary = {}
var live_spots: Dictionary = {}
var spot_claim_counts: Dictionary = {}
var spot_runtime_states: Dictionary = {}
var simulation_timer: float = 0.0
var simulation_queued: bool = false
var social_rng := RandomNumberGenerator.new()
var simulation_tick_skip_logged: bool = false


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
		_process_meal_cycle_schedule_until_snapshot(world_time.call("get_snapshot"))

	var locations := get_node_or_null("/root/NpcLocations")
	if locations != null and locations.has_signal(&"npc_registered"):
		var registered_callback := Callable(self, "_on_npc_registered")
		if not locations.is_connected(&"npc_registered", registered_callback):
			locations.connect(&"npc_registered", registered_callback)


func get_save_data() -> Dictionary:
	return {"spot_runtime_states": spot_runtime_states.duplicate(true)}


func apply_save_data(data: Dictionary) -> void:
	spot_runtime_states.clear()
	var saved_states = data.get("spot_runtime_states", {})
	if saved_states is Dictionary:
		spot_runtime_states = saved_states.duplicate(true)
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
			and previous_value > done_threshold
			and next_value <= done_threshold
		):
			_deplete_meal_cycle_food(spot_id)
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


func _queue_simulation() -> void:
	if _world_simulation_debug_disabled():
		_log_world_simulation_disabled("queue")
		return
	if simulation_queued:
		return

	simulation_queued = true
	call_deferred("_run_queued_simulation")


func _run_queued_simulation() -> void:
	if _world_simulation_debug_disabled():
		_log_world_simulation_disabled("queued")
		simulation_queued = false
		return
	simulation_queued = false
	simulate_now()


func _process(delta: float) -> void:
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
	if _world_simulation_debug_disabled():
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

	var snapshot: Dictionary = world_time.call("get_snapshot")
	var total_hours := float(snapshot.get("total_hours", 0.0))
	var hour := float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))
	_process_meal_cycle_schedule_until_snapshot(snapshot)
	locations.call("synchronize_live_records")
	var records: Dictionary = locations.call("get_records_snapshot")
	_breadcrumb("npc_world:simulate_start", "hour=%.3f records=%d" % [hour, records.size()])
	_rebuild_spot_claims(records)

	for npc_id_key in records.keys():
		var npc_id := StringName(String(npc_id_key))
		var record = records[npc_id_key]
		if not (record is Dictionary):
			continue
		var record_dictionary: Dictionary = record
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
		var current_activity = record.get("activity", {})
		if not npc_is_live:
			var paused_state_name := &""
			if current_activity is Dictionary and not current_activity.is_empty():
				paused_state_name = StringName(String(current_activity.get("state_name", "")))
			_simulate_offscreen_passive_values(record, total_hours, paused_state_name)
			if locations.has_method("update_simulated_record"):
				locations.call("update_simulated_record", String(npc_id), record)

		var pending_travel = record.get("pending_travel", {})
		if pending_travel is Dictionary and not pending_travel.is_empty():
			_update_pending_travel(npc_id, record, pending_travel, hour, locations)
			continue

		var activity = record.get("activity", {})
		if activity is Dictionary and not activity.is_empty():
			_update_activity(npc_id, record, activity, total_hours, hour, locations)
		else:
			if _consume_sleep_skip_wake_pause(npc_id, record, locations):
				continue
			_try_start_activity(npc_id, record, total_hours, hour, locations, records)
	_breadcrumb("npc_world:simulate_end", "hour=%.3f" % hour)


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
			"energy": 100.0,
		}
	for value_key in reset_values.keys():
		var value_name := String(value_key)
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
		machine.call("request_state", &"Idle", null, "player_sleep_skip_wake", 1000)
		return

	var current_state = machine.get("current_state")
	if current_state == null:
		return
	if not ["Sleep", "Collapse", "Rest"].has(String(current_state.name)):
		return

	machine.call("request_state", &"Idle", null, "player_sleep_skip", 100)


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
	paused_state_name: StringName
) -> void:
	var last_total_hours := float(record.get("last_simulated_total_hours", total_hours))
	var elapsed_game_hours := maxf(total_hours - last_total_hours, 0.0)
	record["last_simulated_total_hours"] = total_hours
	if elapsed_game_hours <= 0.0:
		return

	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		return

	var profile = node_state.get("world_simulation_profile", {})
	if not (profile is Dictionary):
		profile = {}
	var tired_settings = profile.get("tired", {})
	if not (tired_settings is Dictionary):
		tired_settings = {}
	var tired_value_name := String(tired_settings.get("value_name", "tired"))
	if not tired_value_name.is_empty() and not social_stats.has(tired_value_name):
		social_stats[tired_value_name] = 0.0
		node_state["social_stats"] = social_stats
		record["node_state"] = node_state
	if not bool(profile.get("passive_needs_enabled", true)):
		return

	var rates = profile.get("rates_per_game_hour", {})
	if not (rates is Dictionary) or rates.is_empty():
		rates = {
			"sleep_need": 5.1,
			"hunger": 7.0,
			"boredom": 8.0,
			"talk_need": 24.0,
		}
	var talk_need_before_growth := float(social_stats.get("talk_need", 0.0))
	var talk_need_rate := float(rates.get("talk_need", 0.0))
	var hunger_before_growth := float(social_stats.get("hunger", 0.0))
	var hunger_rate := float(rates.get("hunger", 0.0))
	var hunger_paused := _passive_value_is_paused("hunger", paused_state_name)

	for value_key in rates.keys():
		var value_name := String(value_key)
		if not social_stats.has(value_name):
			continue
		if _passive_value_is_paused(value_name, paused_state_name):
			continue
		var current_value := float(social_stats.get(value_name, 0.0))
		var growth := float(rates[value_key]) * elapsed_game_hours
		if value_name == "talk_need":
			_apply_offscreen_talk_need_growth(social_stats, current_value, growth)
			continue
		var next_value := current_value + growth
		social_stats[value_name] = clampf(next_value, 0.0, 100.0)

	var starvation_applied := _apply_offscreen_starvation_damage(
		social_stats,
		profile,
		elapsed_game_hours,
		hunger_before_growth,
		hunger_rate,
		hunger_paused
	)
	if not starvation_applied:
		_apply_offscreen_passive_healing(social_stats, profile, elapsed_game_hours)
	_apply_offscreen_tired_change(
		social_stats,
		profile,
		paused_state_name,
		elapsed_game_hours
	)

	_apply_offscreen_loneliness_recovery(
		social_stats,
		profile,
		talk_need_before_growth,
		talk_need_rate,
		elapsed_game_hours,
		_passive_value_is_paused("talk_need", paused_state_name)
	)
	_apply_offscreen_emotion_decay(social_stats, profile, elapsed_game_hours)
	_decay_offscreen_relationships(record, profile, elapsed_game_hours)

	node_state["social_stats"] = social_stats
	record["node_state"] = node_state


func _apply_full_sleep_health_restore(
	record: Dictionary,
	social_stats: Dictionary,
	options: Dictionary
) -> void:
	if _record_is_disabled(record):
		return

	var health_value_name := String(options.get("health_value_name", "hp"))
	if health_value_name.is_empty() or not social_stats.has(health_value_name):
		return

	var full_health := clampf(float(options.get("full_sleep_hp", 100.0)), 0.0, 100.0)
	social_stats[health_value_name] = full_health


func _apply_offscreen_starvation_damage(
	social_stats: Dictionary,
	profile: Dictionary,
	elapsed_game_hours: float,
	hunger_before_growth: float,
	hunger_rate: float,
	hunger_paused: bool
) -> bool:
	if elapsed_game_hours <= 0.0 or hunger_paused:
		return false
	if not social_stats.has("hp") or not social_stats.has("hunger"):
		return false
	if float(social_stats.get("disabled", 0.0)) >= 1.0:
		return false

	var current_hp := float(social_stats.get("hp", 0.0))
	if current_hp <= 0.0:
		return false

	var damage_per_day := clampf(
		float(profile.get("starvation_damage_per_game_day", DEFAULT_STARVATION_DAMAGE_PER_GAME_DAY)),
		0.0,
		100.0
	)
	if damage_per_day <= 0.0:
		return false

	var starvation_hours := _get_offscreen_starvation_game_hours(
		elapsed_game_hours,
		hunger_before_growth,
		hunger_rate
	)
	if starvation_hours <= 0.0:
		return false

	var damage := (damage_per_day / 24.0) * starvation_hours
	social_stats["hp"] = maxf(current_hp - damage, 0.0)
	return true


func _get_offscreen_starvation_game_hours(
	elapsed_game_hours: float,
	hunger_before_growth: float,
	hunger_rate: float
) -> float:
	if hunger_before_growth >= 100.0:
		return elapsed_game_hours
	if hunger_rate <= 0.0:
		return 0.0

	var remaining_hunger := maxf(100.0 - hunger_before_growth, 0.0)
	var hours_to_starvation := remaining_hunger / hunger_rate
	return maxf(elapsed_game_hours - hours_to_starvation, 0.0)


func _apply_offscreen_passive_healing(
	social_stats: Dictionary,
	profile: Dictionary,
	elapsed_game_hours: float
) -> void:
	if elapsed_game_hours <= 0.0:
		return
	if not social_stats.has("hp"):
		return
	if float(social_stats.get("hunger", 0.0)) >= 100.0:
		return
	if float(social_stats.get("disabled", 0.0)) >= 1.0:
		return

	var current_hp := float(social_stats.get("hp", 0.0))
	if current_hp <= 0.0 or current_hp >= 100.0:
		return

	var healing_per_day := clampf(
		float(profile.get("passive_healing_per_game_day", DEFAULT_PASSIVE_HEALING_PER_GAME_DAY)),
		0.0,
		100.0
	)
	if healing_per_day <= 0.0:
		return

	social_stats["hp"] = minf(
		100.0,
		current_hp + (healing_per_day / 24.0) * elapsed_game_hours
	)


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
		locations.call("update_simulated_record", String(npc_id), record)
	return true


func _apply_offscreen_tired_change(
	social_stats: Dictionary,
	profile: Dictionary,
	state_name: StringName,
	game_hours: float
) -> void:
	# Scheduled actions build fatigue; idle off-screen NPCs can casually recover without an activity.
	var settings = profile.get("tired", {})
	if not (settings is Dictionary):
		settings = {}
	if not bool(settings.get("enabled", true)) or game_hours <= 0.0:
		return

	var value_name := String(settings.get("value_name", "tired"))
	if value_name.is_empty():
		return
	var state_text := String(state_name)
	var rate := 0.0
	if state_text.is_empty():
		var current_tired := float(social_stats.get(value_name, 0.0))
		var rest_threshold := float(settings.get("rest_threshold", 50.0))
		if current_tired < rest_threshold:
			return
		var rest_floor := float(settings.get("rest_floor", 40.0))
		social_stats[value_name] = maxf(
			current_tired
				- absf(float(settings.get("rest_recovery_per_game_hour", 100.0)))
				* game_hours,
			rest_floor
		)
		return
	elif state_text == "Rest":
		rate = -absf(float(settings.get("rest_recovery_per_game_hour", 100.0)))
	elif state_text == "Fight":
		rate = absf(float(settings.get("fight_growth_per_game_hour", 60.0)))
	else:
		var inactive_states = settings.get(
			"inactive_states",
			[&"Idle", &"Sleep", &"Collapse", &"DisabledDead"]
		)
		if _variant_array_has_string(inactive_states, state_text):
			return
		rate = absf(float(settings.get("action_growth_per_game_hour", 25.0)))

	var minimum_value := float(settings.get("rest_floor", 40.0)) if state_text == "Rest" else 0.0
	social_stats[value_name] = clampf(
		float(social_stats.get(value_name, 0.0)) + rate * game_hours,
		minimum_value,
		100.0
	)


func _apply_offscreen_talk_need_growth(
	social_stats: Dictionary,
	current_value: float,
	growth: float
) -> void:
	# Preserve every 100 -> 60 lonely cycle even when several game hours pass off-screen.
	var talk_need := clampf(current_value, 0.0, 100.0)
	var lonely_increases := 0
	if talk_need >= 100.0:
		talk_need = 60.0
		lonely_increases += 1

	var total := talk_need + maxf(growth, 0.0)
	if total >= 100.0:
		var overflow := total - 100.0
		lonely_increases += 1 + int(floor(overflow / 40.0))
		total = 60.0 + fposmod(overflow, 40.0)

	social_stats["talk_need"] = clampf(total, 0.0, 100.0)
	if lonely_increases <= 0 or not social_stats.has("lonely"):
		return

	social_stats["lonely"] = clampf(
		float(social_stats.get("lonely", 0.0)) + float(lonely_increases),
		0.0,
		100.0
	)


func _apply_offscreen_loneliness_recovery(
	social_stats: Dictionary,
	profile: Dictionary,
	initial_talk_need: float,
	talk_need_rate: float,
	elapsed_game_hours: float,
	talk_need_paused: bool
) -> void:
	# Recover only for the part of an unloaded interval spent below the threshold.
	var settings = profile.get("loneliness_recovery", {})
	if not (settings is Dictionary):
		settings = {}
	if not bool(settings.get("enabled", true)):
		return

	var lonely_name := String(settings.get("value_name", "lonely"))
	if lonely_name.is_empty() or not social_stats.has(lonely_name):
		return
	var threshold := float(settings.get("talk_need_below", 50.0))
	if initial_talk_need >= threshold:
		return

	var recovery_hours := elapsed_game_hours
	if not talk_need_paused and talk_need_rate > 0.0:
		recovery_hours = minf(
			recovery_hours,
			maxf((threshold - initial_talk_need) / talk_need_rate, 0.0)
		)
	if recovery_hours <= 0.0:
		return

	var full_recovery_hours := maxf(
		float(settings.get("full_recovery_game_hours", 5.0)),
		0.001
	)
	var current_loneliness := float(social_stats.get(lonely_name, 0.0))
	social_stats[lonely_name] = maxf(
		current_loneliness - (100.0 / full_recovery_hours) * recovery_hours,
		0.0
	)


func _apply_offscreen_emotion_decay(
	social_stats: Dictionary,
	profile: Dictionary,
	game_hours: float
) -> void:
	var anger_decay = profile.get("anger_decay", {})
	if anger_decay is Dictionary and bool(anger_decay.get("enabled", false)):
		var anger_name := String(anger_decay.get("value_name", "anger"))
		if social_stats.has(anger_name):
			var anger := float(social_stats[anger_name])
			var full_hours := maxf(float(anger_decay.get("full_decay_game_hours", 4.0)), 0.001)
			social_stats[anger_name] = maxf(anger - (100.0 / full_hours) * game_hours, 0.0)

	var fear_decay = profile.get("fear_decay", {})
	if not (fear_decay is Dictionary) or not bool(fear_decay.get("enabled", false)):
		return

	var fear_name := String(fear_decay.get("value_name", "fear"))
	if not social_stats.has(fear_name):
		return

	var fear := float(social_stats[fear_name])
	var panic_floor := float(fear_decay.get("panic_floor", 90.0))
	var stop_value := maxf(float(fear_decay.get("stop_value", 69.9)), 0.0)
	if fear <= stop_value:
		return
	if fear > panic_floor:
		var panic_hours := float(fear_decay.get("panic_cooldown_game_hours", 1.0 / 6.0))
		if panic_hours <= 0.0:
			fear = panic_floor
		else:
			fear = maxf(fear - ((100.0 - panic_floor) / panic_hours) * game_hours, panic_floor)
	else:
		var slow_rate := float(fear_decay.get("slow_decay_per_game_hour", 5.0))
		fear = maxf(fear - slow_rate * game_hours, stop_value)
	social_stats[fear_name] = fear


func _decay_offscreen_relationships(
	record: Dictionary,
	profile: Dictionary,
	game_hours: float
) -> void:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return
	var owner_id := String(node_state.get("relationship_id", record.get("npc_id", "")))
	if owner_id.is_empty():
		owner_id = String(record.get("npc_id", ""))
	if owner_id.is_empty():
		return

	var relationships := get_node_or_null("/root/Relationships")
	if relationships == null:
		return

	var anger_decay = profile.get("anger_decay", {})
	if anger_decay is Dictionary and bool(anger_decay.get("enabled", false)):
		var full_hours := maxf(float(anger_decay.get("full_decay_game_hours", 4.0)), 0.001)
		if relationships.has_method("decay_anger_for_id"):
			relationships.call("decay_anger_for_id", owner_id, (100.0 / full_hours) * game_hours)

	var fear_decay = profile.get("fear_decay", {})
	if fear_decay is Dictionary and bool(fear_decay.get("enabled", false)):
		if relationships.has_method("decay_fear_for_id"):
			relationships.call(
				"decay_fear_for_id",
				owner_id,
				game_hours,
				float(fear_decay.get("panic_floor", 90.0)),
				float(fear_decay.get("panic_cooldown_game_hours", 1.0 / 6.0)),
				float(fear_decay.get("slow_decay_per_game_hour", 5.0)),
				float(fear_decay.get("stop_value", 69.9))
			)


func _passive_value_is_paused(value_name: String, state_name: StringName) -> bool:
	var state_key := String(state_name).to_snake_case()
	if value_name == "sleep_need":
		return state_key == "sleep" or state_key == "collapse"
	if value_name == "hunger":
		return state_key == "eat"
	if value_name == "boredom":
		return state_key == "work" or state_key == "recreation" or state_key == "routine_task"
	if value_name == "talk_need":
		return state_key == "talk"

	return false


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

	var record: Dictionary = locations.call("get_npc_location", String(npc_id))
	var pending_travel = record.get("pending_travel", {})
	if pending_travel is Dictionary and not pending_travel.is_empty():
		_resume_pending_travel(npc_id, npc, pending_travel, locations)
		return

	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		_breadcrumb("npc_world:resume_live_no_activity", String(npc_id))
		return

	var spot_id := StringName(String(activity.get("spot_id", "")))
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition == null:
		_breadcrumb("npc_world:resume_live_missing_definition", "%s %s" % [String(npc_id), String(spot_id)])
		return
	var spot := _get_live_activity_spot(spot_id, definition, activity)
	if spot == null or not is_instance_valid(spot):
		_breadcrumb("npc_world:resume_live_missing_spot", "%s %s" % [String(npc_id), String(spot_id)])
		return
	if _debug_definition_disabled(definition):
		_breadcrumb("npc_world:resume_live_disabled_definition", "%s %s" % [String(npc_id), String(spot_id)])
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	var hour := _get_current_time_of_day_hours()
	if not _activity_can_continue(npc_id, record, definition, hour):
		_breadcrumb("npc_world:resume_live_finish_invalid", "%s %s" % [String(npc_id), String(spot_id)])
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return

	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		_breadcrumb("npc_world:resume_live_no_machine", String(npc_id))
		return
	if not _live_activity_can_continue(npc_id, npc, machine, definition, spot):
		_breadcrumb("npc_world:resume_live_finish_live_invalid", "%s %s" % [String(npc_id), String(spot_id)])
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	if not _npc_is_following_activity(machine, definition, spot):
		if locations.has_method("is_npc_available_for_scheduled_activity"):
			if not bool(locations.call(
				"is_npc_available_for_scheduled_activity",
				String(npc_id),
				definition.state_name,
				definition.priority
			)):
				_breadcrumb("npc_world:resume_live_unavailable", "%s %s" % [String(npc_id), String(spot_id)])
				return
	var accepted_invitation_running := _resume_accepted_invitation_activity(
		npc_id,
		npc,
		definition,
		spot,
		activity
	)
	if accepted_invitation_running:
		_breadcrumb("npc_world:resume_live_started_accepted_lesson", "%s %s" % [String(npc_id), String(spot_id)])
	if _npc_is_following_activity(machine, definition, spot):
		_breadcrumb("npc_world:resume_live_already_following", "%s %s" % [String(npc_id), String(spot_id)])
		return

	var assignment_method := definition.get_assignment_method()
	if assignment_method != &"" and machine.has_method(assignment_method):
		if bool(machine.call(assignment_method, spot, definition.priority)):
			_breadcrumb("npc_world:resume_live_assigned", "%s %s" % [String(npc_id), String(spot_id)])
			return
	elif machine.has_method("request_state"):
		machine.call("request_state", definition.state_name, spot, "world_activity", definition.priority)
		_breadcrumb("npc_world:resume_live_requested", "%s %s" % [String(npc_id), String(spot_id)])
		return

	if machine.has_method("request_state"):
		machine.call("request_state", definition.state_name, spot, "world_activity", definition.priority)
		_breadcrumb("npc_world:resume_live_requested", "%s %s" % [String(npc_id), String(spot_id)])


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

	if definition.state_name != &"Eat":
		return true
	if spot == null or not is_instance_valid(spot):
		return false
	if not spot.has_method("can_serve_npc_need"):
		return true

	var npc_2d := npc as Node2D
	if npc_2d == null:
		return false

	return bool(spot.call(
		"can_serve_npc_need",
		npc_2d,
		definition.state_name,
		StringName(value_name)
	))


func _resume_accepted_invitation_activity(
	_npc_id: StringName,
	npc: Node,
	definition: NpcSpotDefinition,
	spot: Node2D,
	activity: Dictionary
) -> bool:
	if definition == null or definition.state_name != INVITE_PLAYER_STATE:
		return false
	if String(activity.get("lesson_phase", "inviting")) != "running":
		return false
	if spot == null or not is_instance_valid(spot):
		return false
	if not spot.has_method("start_lesson"):
		return false

	var npc_2d := npc as Node2D
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if npc_2d == null or player == null:
		return false
	if spot.has_method("is_lesson_active_for"):
		if bool(spot.call("is_lesson_active_for", npc_2d, player)):
			return true

	spot.call("start_lesson", npc_2d, player)
	return true


func _npc_is_following_activity(
	machine: Node,
	definition: NpcSpotDefinition,
	spot: Node2D
) -> bool:
	var current_state = machine.get("current_state")
	if current_state != null and _state_names_match(StringName(current_state.name), definition.state_name):
		return true
	if current_state == null or String(current_state.name) != "MoveToTarget":
		return false

	return (
		machine.get("move_target") == spot
		and _state_names_match(StringName(machine.get("state_after_move")), definition.state_name)
	)


func _activity_can_continue(
	npc_id: StringName,
	record: Dictionary,
	definition: NpcSpotDefinition,
	hour: float
) -> bool:
	if definition == null:
		return false
	if not definition.is_active_at(hour):
		return false
	if not _spot_runtime_is_available(definition):
		return false
	if (
		_definition_is_meal_cycle_managed(definition)
		and not _meal_cycle_definition_can_start(definition, npc_id, hour)
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

	return true


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
	var directory := DirAccess.open(SPOT_DATA_DIRECTORY)
	if directory == null:
		return

	directory.list_dir_begin()
	var file_name := directory.get_next()
	while not file_name.is_empty():
		if not directory.current_is_dir() and file_name.get_extension().to_lower() == "tres":
			var resource_path := "%s/%s" % [SPOT_DATA_DIRECTORY, file_name]
			var definition := load(resource_path) as NpcSpotDefinition
			if definition != null and definition.is_valid_definition():
				if spot_definitions.has(definition.spot_id):
					push_warning("Duplicate simulated NPC spot id '%s'; keeping the first definition." % String(definition.spot_id))
				else:
					spot_definitions[definition.spot_id] = definition
		file_name = directory.get_next()
	directory.list_dir_end()


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
	if _record_has_non_social_pending_travel(record):
		return false
	if DebugToolsConfig.TROUBLESHOOTING_MODE and DebugToolsConfig.DEBUG_DISABLE_TALK_SEARCH:
		_breadcrumb("npc_world:social_seek_skip", String(npc_id))
		return false

	var settings := _get_social_seek_settings(record)
	if not bool(settings.get("enabled", true)):
		return false
	var seek_priority := int(settings.get("priority", 60))
	if blocking_priority > seek_priority:
		return false
	if _get_saved_stat(record, "talk_need") < float(settings.get("talk_need_threshold", 70.0)):
		return false

	var candidate := _choose_social_candidate(npc_id, record, records, locations, settings)
	if candidate.is_empty():
		return false

	var target_scene_path := String(candidate.get("scene_path", ""))
	var seeker_scene_path := String(record.get("scene_path", ""))
	if target_scene_path.is_empty() or seeker_scene_path.is_empty():
		return false
	if (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_CROSS_SCENE_TALK
		and target_scene_path != seeker_scene_path
	):
		_breadcrumb("npc_world:cross_scene_talk_skip", "%s -> %s" % [String(npc_id), target_scene_path.get_file()])
		return false
	var target_position = candidate.get("position", Vector2.ZERO)
	if not (target_position is Vector2):
		target_position = Vector2.ZERO
	var social_target_id := String(candidate.get("target_id", ""))

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if seeker_scene_path == target_scene_path:
		var live_target := _get_live_social_target(candidate, locations)
		if live_npc != null and live_target != null:
			return _request_live_social_seek(
				npc_id,
				live_npc,
				live_target,
				seek_priority,
				locations
			)
		if live_npc == null and live_target == null and social_target_id != PLAYER_SOCIAL_TARGET_ID:
			return _complete_simulated_conversation(
				npc_id,
				social_target_id,
				record,
				records,
				locations
			)
		if live_npc == null and locations.has_method("move_simulated_npc_for_social_visit"):
			return bool(locations.call(
				"move_simulated_npc_for_social_visit",
				String(npc_id),
				target_scene_path,
				target_position,
				social_target_id
			))
		return false

	if live_npc != null:
		var departure_door := _find_departure_door(target_scene_path, live_npc)
		if departure_door == null or not locations.has_method("prepare_scheduled_travel"):
			return false
		var pending_travel := {
			"mode": "social",
			"target_scene_path": target_scene_path,
			"target_position": target_position,
			"social_target_id": social_target_id,
			"requested_state_name": "LookForTalkTarget",
			"requested_priority": seek_priority,
		}
		return bool(locations.call(
			"prepare_scheduled_travel",
			String(npc_id),
			pending_travel,
			departure_door
		))

	if locations.has_method("move_simulated_npc_for_social_visit"):
		return bool(locations.call(
			"move_simulated_npc_for_social_visit",
			String(npc_id),
			target_scene_path,
			target_position,
			social_target_id
		))
	return false


func _record_has_non_social_pending_travel(record: Dictionary) -> bool:
	var pending = record.get("pending_travel", {})
	if not (pending is Dictionary) or pending.is_empty():
		return false

	var pending_mode := String(pending.get("mode", ""))
	var pending_state := String(pending.get("requested_state_name", ""))
	return pending_mode != "social" and not ["Talk", "LookForTalkTarget"].has(pending_state)


func _get_social_seek_settings(record: Dictionary) -> Dictionary:
	var node_state = record.get("node_state", {})
	if node_state is Dictionary:
		var profile = node_state.get("world_simulation_profile", {})
		if profile is Dictionary:
			var settings = profile.get("social_seeking", {})
			if settings is Dictionary and not settings.is_empty():
				return settings
	return {
		"enabled": true,
		"talk_need_threshold": 70.0,
		"priority": 60,
		"minimum_npc_favor": 10.0,
		"player_target_chance": 0.35,
	}


func _choose_social_candidate(
	npc_id: StringName,
	record: Dictionary,
	records: Dictionary,
	locations: Node,
	settings: Dictionary
) -> Dictionary:
	var seeker_scene_path := String(record.get("scene_path", ""))
	var local_candidates: Array[Dictionary] = []
	var remote_candidates: Array[Dictionary] = []
	var player := get_tree().get_first_node_in_group("player") as Node2D
	if player != null and is_instance_valid(player):
		var player_scene_path := String(locations.call("get_current_scene_path"))
		_add_social_candidate({
			"target_id": PLAYER_SOCIAL_TARGET_ID,
			"scene_path": player_scene_path,
			"position": player.global_position,
			"is_player": true,
		}, seeker_scene_path, local_candidates, remote_candidates)

	var relationships := get_node_or_null("/root/Relationships")
	var owner_id := _get_record_relationship_id(npc_id, record)
	var minimum_favor := float(settings.get("minimum_npc_favor", 10.0))
	for target_id_key in records.keys():
		var target_id := String(target_id_key)
		if target_id == String(npc_id):
			continue
		var target_record = records[target_id_key]
		if not (target_record is Dictionary) or _record_is_disabled(target_record):
			continue
		var target_relationship_id := _get_record_relationship_id(
			StringName(target_id),
			target_record
		)
		if relationships != null and relationships.has_method("get_favor_by_id"):
			var seeker_favor := float(relationships.call(
				"get_favor_by_id",
				owner_id,
				target_relationship_id,
				50.0
			))
			var target_favor := float(relationships.call(
				"get_favor_by_id",
				target_relationship_id,
				owner_id,
				50.0
			))
			if seeker_favor <= minimum_favor or target_favor <= minimum_favor:
				continue
		var target_position = target_record.get("last_position", Vector2.ZERO)
		if locations.has_method("get_live_npc"):
			var target_live := locations.call("get_live_npc", target_id) as Node2D
			if target_live != null:
				target_position = target_live.global_position
		_add_social_candidate({
			"target_id": target_id,
			"scene_path": String(target_record.get("scene_path", "")),
			"position": target_position,
			"is_player": false,
		}, seeker_scene_path, local_candidates, remote_candidates)

	var candidates := local_candidates if not local_candidates.is_empty() else remote_candidates
	if candidates.is_empty():
		return {}
	var preferred_target_id := String(record.get("social_visit_target_id", ""))
	for candidate in candidates:
		if not preferred_target_id.is_empty() and String(candidate.get("target_id", "")) == preferred_target_id:
			return candidate

	var player_chance := clampf(float(settings.get("player_target_chance", 0.35)), 0.0, 1.0)
	if social_rng.randf() < player_chance:
		for candidate in candidates:
			if bool(candidate.get("is_player", false)):
				return candidate
	return candidates[social_rng.randi_range(0, candidates.size() - 1)]


func _add_social_candidate(
	candidate: Dictionary,
	seeker_scene_path: String,
	local_candidates: Array[Dictionary],
	remote_candidates: Array[Dictionary]
) -> void:
	if String(candidate.get("scene_path", "")).is_empty():
		return
	if String(candidate.get("scene_path", "")) == seeker_scene_path:
		local_candidates.append(candidate)
	else:
		remote_candidates.append(candidate)


func _get_record_relationship_id(npc_id: StringName, record: Dictionary) -> String:
	var node_state = record.get("node_state", {})
	if node_state is Dictionary:
		var relationship_id := String(node_state.get("relationship_id", ""))
		if not relationship_id.is_empty():
			return relationship_id
	return String(npc_id)


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
	locations: Node
) -> bool:
	if npc == null or target == null or npc == target:
		return false
	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null or not machine.has_method("request_state"):
		return false
	var current_state = machine.get("current_state")
	if current_state != null and String(current_state.name) in ["Talk", "LookForTalkTarget"]:
		return true
	if locations.has_method("is_npc_available_for_scheduled_activity"):
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			&"LookForTalkTarget",
			seek_priority
		)):
			return false
	return bool(machine.call(
		"request_state",
		&"LookForTalkTarget",
		target,
		"social_seek",
		seek_priority
	))


func _complete_simulated_conversation(
	npc_id: StringName,
	target_id: String,
	record: Dictionary,
	records: Dictionary,
	locations: Node
) -> bool:
	if target_id.is_empty() or not records.has(target_id):
		return false
	var target_record = records[target_id]
	if not (target_record is Dictionary):
		return false
	_set_saved_stat(record, "talk_need", _get_saved_stat(record, "talk_need") - simulated_talk_need_drop)
	_set_saved_stat(record, "boredom", _get_saved_stat(record, "boredom") - simulated_talk_boredom_drop)
	_set_saved_stat(
		target_record,
		"talk_need",
		_get_saved_stat(target_record, "talk_need") - simulated_partner_talk_need_drop
	)
	record["social_visit_target_id"] = ""
	target_record["social_visit_target_id"] = ""
	records[String(npc_id)] = record
	records[target_id] = target_record
	if locations.has_method("update_simulated_record"):
		locations.call("update_simulated_record", String(npc_id), record)
		locations.call("update_simulated_record", target_id, target_record)
	return true


func _try_start_activity(
	npc_id: StringName,
	record: Dictionary,
	total_hours: float,
	hour: float,
	locations: Node,
	records: Dictionary
) -> void:
	if _record_is_disabled(record):
		return
	if (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_NPC_SCHEDULED_ACTIVITY_STARTS
	):
		_breadcrumb("npc_world:start_activity_skip", String(npc_id))
		return

	var definition := _find_best_definition(npc_id, record, hour)
	if _debug_definition_disabled(definition):
		_breadcrumb("npc_world:best_activity_disabled", "%s -> %s" % [String(npc_id), String(definition.spot_id)])
		definition = null
	_breadcrumb(
		"npc_world:best_activity",
		"%s -> %s" % [String(npc_id), String(definition.spot_id) if definition != null else "none"]
	)
	var blocking_priority := definition.priority if definition != null else -1
	if _try_start_social_seek(npc_id, record, records, locations, blocking_priority):
		return
	if definition == null:
		return

	if locations.has_method("is_npc_available_for_scheduled_activity"):
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			definition.state_name,
			definition.priority
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
		"spot_id": String(definition.spot_id),
		"state_name": String(definition.state_name),
		"value_name": String(definition.value_name),
		"target_scene_path": target_scene_path,
		"target_position": target_position,
		"last_total_hours": total_hours,
		"return_scene_path": String(record.get("scene_path", "")),
		"return_position": record.get("last_position", Vector2.ZERO),
	}
	if definition.state_name == INVITE_PLAYER_STATE:
		activity["lesson_phase"] = "inviting"
		activity["lesson_scene_path"] = definition.scene_path
		activity["lesson_position"] = definition.position

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if live_npc != null and String(record.get("scene_path", "")) != target_scene_path:
		var departure_door := _find_departure_door(target_scene_path, live_npc)
		if departure_door == null or not locations.has_method("prepare_scheduled_travel"):
			return

		var pending_travel := {
			"mode": "start",
			"target_scene_path": target_scene_path,
			"target_position": target_position,
			"requested_state_name": String(definition.state_name),
			"requested_priority": definition.priority,
			"activity": activity,
		}
		if bool(locations.call(
			"prepare_scheduled_travel",
			String(npc_id),
			pending_travel,
			departure_door
		)):
			_claim_spot(definition.spot_id)
			_breadcrumb("npc_world:start_activity_travel", "%s %s" % [String(npc_id), String(definition.spot_id)])
			activity_started.emit(npc_id, definition.spot_id)
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

	_claim_spot(definition.spot_id)
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
	_record: Dictionary,
	pending_travel: Dictionary,
	hour: float,
	locations: Node
) -> void:
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
		_commit_pending_travel_offscreen(npc_id, pending_travel, locations)
		return

	_resume_pending_travel(npc_id, live_npc, pending_travel, locations)


func _resume_pending_travel(
	npc_id: StringName,
	npc: Node2D,
	pending_travel: Dictionary,
	locations: Node
) -> void:
	var target_scene_path := String(pending_travel.get("target_scene_path", ""))
	var departure_door := _find_departure_door(target_scene_path, npc)
	if departure_door == null:
		if locations.has_method("cancel_pending_scheduled_travel"):
			locations.call("cancel_pending_scheduled_travel", String(npc_id))
		return
	if _npc_is_moving_to_door(npc, departure_door):
		return

	var requested_state_name := StringName(String(pending_travel.get("requested_state_name", "")))
	var requested_priority := int(pending_travel.get("requested_priority", 0))
	if locations.has_method("is_npc_available_for_scheduled_activity"):
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			requested_state_name,
			requested_priority
		)):
			return
	if locations.has_method("resume_pending_scheduled_travel"):
		locations.call("resume_pending_scheduled_travel", String(npc_id), departure_door)


func _commit_pending_travel_offscreen(
	npc_id: StringName,
	pending_travel: Dictionary,
	locations: Node
) -> void:
	var target_scene_path := String(pending_travel.get("target_scene_path", ""))
	var target_position = pending_travel.get("target_position", Vector2.ZERO)
	if not (target_position is Vector2):
		target_position = Vector2.ZERO

	if String(pending_travel.get("mode", "start")) == "finish":
		if locations.has_method("finish_scheduled_activity"):
			locations.call(
				"finish_scheduled_activity",
				String(npc_id),
				target_scene_path,
				target_position
			)
		return
	if String(pending_travel.get("mode", "start")) == "social":
		if locations.has_method("move_simulated_npc_for_social_visit"):
			locations.call(
				"move_simulated_npc_for_social_visit",
				String(npc_id),
				target_scene_path,
				target_position,
				String(pending_travel.get("social_target_id", ""))
			)
		return

	var activity = pending_travel.get("activity", {})
	if activity is Dictionary and not activity.is_empty():
		var spot_id := StringName(String(activity.get("spot_id", "")))
		var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
		if _debug_definition_disabled(definition):
			_breadcrumb("npc_world:commit_travel_disabled_definition", "%s %s" % [String(npc_id), String(spot_id)])
			return
		if locations.has_method("begin_scheduled_activity"):
			locations.call(
				"begin_scheduled_activity",
				String(npc_id),
				activity,
				target_scene_path,
				target_position
			)


func _update_activity(
	npc_id: StringName,
	record: Dictionary,
	activity: Dictionary,
	total_hours: float,
	hour: float,
	locations: Node
) -> void:
	var spot_id := StringName(String(activity.get("spot_id", "")))
	_breadcrumb("npc_world:update_activity", "%s %s" % [String(npc_id), String(spot_id)])
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if _debug_definition_disabled(definition):
		_breadcrumb("npc_world:update_disabled_definition", "%s %s" % [String(npc_id), String(spot_id)])
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	if not _activity_can_continue(npc_id, record, definition, hour):
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	var interrupt_definition := _find_invitation_interrupt_definition(
		npc_id,
		record,
		hour,
		definition
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

	if locations.has_method("is_npc_live") and bool(locations.call("is_npc_live", String(npc_id))):
		var live_npc: Node = null
		if locations.has_method("get_live_npc"):
			live_npc = locations.call("get_live_npc", String(npc_id)) as Node
		if live_npc != null:
			resume_live_activity(npc_id, live_npc)
		return

	var last_total_hours := float(activity.get("last_total_hours", total_hours))
	var elapsed_game_hours := maxf(total_hours - last_total_hours, 0.0)
	activity["last_total_hours"] = total_hours

	if elapsed_game_hours > 0.0 and not value_name.is_empty():
		if _definition_consumes_food_for_hunger(definition, value_name):
			_apply_offscreen_food_eat_progress(record, definition, value_name, elapsed_game_hours)
		else:
			_set_saved_stat(
				record,
				value_name,
				_get_saved_stat(record, value_name) + definition.value_delta_per_game_hour * elapsed_game_hours
			)
	if _activity_should_apply_spot_runtime_progress(npc_id, activity, definition, locations):
		_apply_spot_runtime_progress(definition, elapsed_game_hours, total_hours)

	record["activity"] = activity
	record["last_position"] = _get_activity_simulated_position(activity, definition)
	if locations.has_method("update_simulated_record"):
		locations.call("update_simulated_record", String(npc_id), record)

	var npc_value_sated := (
		definition.finish_when_npc_value_sated
		and not value_name.is_empty()
		and _get_saved_stat(record, value_name) <= 0.0
	)
	if npc_value_sated:
		_mark_meal_owner_sated_if_needed(definition, npc_id, StringName(value_name))
	if npc_value_sated or not _spot_runtime_is_available(definition):
		_finish_activity(npc_id, record, activity, spot_id, locations)


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
			locations.call("update_simulated_record", String(npc_id), record)
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	_consume_invitation_activity_availability(definition)

	var return_scene_path := String(activity.get("return_scene_path", record.get("scene_path", "")))
	var return_position = activity.get("return_position", record.get("last_position", Vector2.ZERO))
	if not (return_position is Vector2):
		return_position = Vector2.ZERO

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if live_npc != null and return_scene_path != String(record.get("scene_path", "")):
		var departure_door := _find_departure_door(return_scene_path, live_npc)
		if departure_door == null or not locations.has_method("prepare_scheduled_travel"):
			return

		var pending_travel := {
			"mode": "finish",
			"target_scene_path": return_scene_path,
			"target_position": return_position,
			"requested_state_name": "",
			"requested_priority": 100,
			"spot_id": String(spot_id),
		}
		locations.call(
			"prepare_scheduled_travel",
			String(npc_id),
			pending_travel,
			departure_door
		)
		return

	var finished := false
	if locations.has_method("finish_scheduled_activity"):
		finished = bool(locations.call(
			"finish_scheduled_activity",
			String(npc_id),
			return_scene_path,
			return_position
		))
	if finished:
		_detach_live_npc_from_finished_activity(live_npc, spot_id)
		activity_finished.emit(npc_id, spot_id)


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

	machine.call("request_state", &"Idle", null, "world_activity_finished", definition.priority)


func _find_departure_door(target_scene_path: String, npc: Node2D) -> Node2D:
	if target_scene_path.is_empty() or npc == null or not is_instance_valid(npc):
		return null

	var closest_door: Node2D
	var closest_distance := INF
	for door_node in get_tree().get_nodes_in_group("npc_travel_door"):
		var door := door_node as Node2D
		if door == null or not is_instance_valid(door):
			continue
		if String(door.get("target_scene_path")) != target_scene_path:
			continue
		if door.has_method("can_npc_use") and not bool(door.call("can_npc_use", npc)):
			continue

		var distance := npc.global_position.distance_squared_to(door.global_position)
		if distance < closest_distance:
			closest_distance = distance
			closest_door = door

	return closest_door


func _npc_is_moving_to_door(npc: Node2D, door: Node2D) -> bool:
	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return false
	var current_state = machine.get("current_state")
	if current_state == null or String(current_state.name) != "MoveToTarget":
		return false

	return machine.get("move_target") == door


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


func _find_invitation_interrupt_definition(
	npc_id: StringName,
	record: Dictionary,
	hour: float,
	current_definition: NpcSpotDefinition
) -> NpcSpotDefinition:
	if current_definition == null:
		return null
	if current_definition.state_name == INVITE_PLAYER_STATE:
		return null

	var best_definition := _find_best_definition(npc_id, record, hour)
	if best_definition == null:
		return null
	if _debug_definition_disabled(best_definition):
		_breadcrumb("npc_world:invitation_interrupt_disabled", "%s %s" % [String(npc_id), String(best_definition.spot_id)])
		return null
	if best_definition.spot_id == current_definition.spot_id:
		return null
	if best_definition.state_name != INVITE_PLAYER_STATE:
		return null
	if best_definition.priority <= current_definition.priority:
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
	spot_claim_counts.clear()
	for record_value in records.values():
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		var activity = record.get("activity", {})
		if activity is Dictionary and not activity.is_empty():
			_claim_spot(StringName(String(activity.get("spot_id", ""))))
			continue

		var pending = record.get("pending_travel", {})
		if not (pending is Dictionary) or pending.is_empty():
			continue
		var pending_activity = pending.get("activity", {})
		if pending_activity is Dictionary and not pending_activity.is_empty():
			_claim_spot(StringName(String(pending_activity.get("spot_id", ""))))


func _claim_spot(spot_id: StringName) -> void:
	if spot_id == &"":
		return
	spot_claim_counts[spot_id] = int(spot_claim_counts.get(spot_id, 0)) + 1


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
