extends Node

signal activity_started(npc_id: StringName, spot_id: StringName)
signal activity_finished(npc_id: StringName, spot_id: StringName)

const SPOT_DATA_DIRECTORY := "res://data/npc_spots"
const PLAYER_SOCIAL_TARGET_ID := "__player__"

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
	state["kind"] = "work"
	state["minimum"] = lower
	state["maximum"] = upper
	state["daily_growth"] = daily_growth
	state["value"] = clampf(float(state.get("value", initial_value)), lower, upper)
	spot_runtime_states[state_key] = state
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

		var next_value := clampf(
			float(state.get("value", 0.0)) + float(state.get("daily_growth", 0.0)),
			float(state.get("minimum", 0.0)),
			float(state.get("maximum", 100.0))
		)
		set_spot_value(StringName(String(spot_id_key)), next_value)

	_queue_simulation()


func _on_world_hour_changed(_hour: int, _snapshot: Dictionary) -> void:
	# Scheduled windows commonly open on the hour, so dispatch eligible owners immediately.
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
	if simulation_queued:
		return

	simulation_queued = true
	call_deferred("_run_queued_simulation")


func _run_queued_simulation() -> void:
	simulation_queued = false
	simulate_now()


func _process(delta: float) -> void:
	simulation_timer -= delta
	if simulation_timer > 0.0:
		return

	simulation_timer = maxf(simulation_interval_seconds, 0.1)
	simulate_now()


func simulate_now() -> void:
	# Only saved records are simulated; unloaded NPC scenes never need a running state machine.
	var locations := get_node_or_null("/root/NpcLocations")
	var world_time := get_node_or_null("/root/WorldTime")
	if locations == null or world_time == null:
		return
	if not locations.has_method("get_all_locations") or not world_time.has_method("get_snapshot"):
		return

	var snapshot: Dictionary = world_time.call("get_snapshot")
	var total_hours := float(snapshot.get("total_hours", 0.0))
	var hour := float(snapshot.get("time_of_day_hours", snapshot.get("hour", 0.0)))
	var records: Dictionary = locations.call("get_all_locations")
	_rebuild_spot_claims(records)

	for npc_id_key in records.keys():
		var npc_id := StringName(String(npc_id_key))
		var record = records[npc_id_key]
		if not (record is Dictionary):
			continue

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
			_try_start_activity(npc_id, record, total_hours, hour, locations, records)


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
	if locations == null or not locations.has_method("get_all_locations"):
		return

	var records: Dictionary = locations.call("get_all_locations")
	for npc_id_key in records.keys():
		var record = records[npc_id_key]
		if not (record is Dictionary):
			continue

		var npc_id := String(npc_id_key)
		var updated_record: Dictionary = record.duplicate(true)
		_apply_sleep_skip_body_values(
			updated_record,
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
			_wake_live_npc_after_sleep_skip(live_npc)

	_queue_simulation()


func _apply_sleep_skip_body_values(
	record: Dictionary,
	elapsed_game_hours: float,
	end_total_hours: float,
	options: Dictionary
) -> void:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		return

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
		social_stats[hunger_name] = clampf(
			float(social_stats.get(hunger_name, 0.0)) + hunger_rate * elapsed_game_hours,
			0.0,
			100.0
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

	node_state["social_stats"] = social_stats
	record["node_state"] = node_state
	record["last_simulated_total_hours"] = end_total_hours
	_clear_sleep_activity_after_skip(record)


func _clear_sleep_activity_after_skip(record: Dictionary) -> void:
	var activity = record.get("activity", {})
	if activity is Dictionary and String(activity.get("state_name", "")) == "Sleep":
		record["activity"] = {}

	var pending = record.get("pending_travel", {})
	if not (pending is Dictionary) or pending.is_empty():
		return
	if String(pending.get("requested_state_name", "")) == "Sleep":
		record["pending_travel"] = {}
		return

	var pending_activity = pending.get("activity", {})
	if pending_activity is Dictionary and String(pending_activity.get("state_name", "")) == "Sleep":
		record["pending_travel"] = {}


func _wake_live_npc_after_sleep_skip(live_npc: Node) -> void:
	if live_npc == null or not is_instance_valid(live_npc):
		return

	var machine := live_npc.get_node_or_null("NpcStateMachine")
	if machine == null or not machine.has_method("request_state"):
		return

	var current_state = machine.get("current_state")
	if current_state == null:
		return
	if not ["Sleep", "Collapse", "Rest"].has(String(current_state.name)):
		return

	machine.call("request_state", &"Idle", null, "player_sleep_skip", 100)


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
	var state_text := String(state_name)
	if value_name == "sleep_need":
		return state_text == "Sleep" or state_text == "Collapse"
	if value_name == "hunger":
		return state_text == "Eat"
	if value_name == "boredom":
		return state_text == "Work" or state_text == "Recreation"
	if value_name == "talk_need":
		return state_text == "Talk"

	return false


func register_live_spot(spot_id: StringName, spot: Node2D) -> void:
	if spot_id == &"" or spot == null:
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


func resume_live_activity(npc_id: StringName, npc: Node) -> void:
	# Reconnects a spawned NPC to the real spot and normal state machine for the loaded scene.
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_npc_location"):
		return

	var record: Dictionary = locations.call("get_npc_location", String(npc_id))
	var pending_travel = record.get("pending_travel", {})
	if pending_travel is Dictionary and not pending_travel.is_empty():
		_resume_pending_travel(npc_id, npc, pending_travel, locations)
		return

	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return

	var spot_id := StringName(String(activity.get("spot_id", "")))
	var spot := live_spots.get(spot_id, null) as Node2D
	if spot == null or not is_instance_valid(spot):
		return

	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition == null:
		return

	var machine := npc.get_node_or_null("NpcStateMachine")
	if machine == null:
		return
	if _npc_is_following_activity(machine, definition, spot):
		return
	if locations.has_method("is_npc_available_for_scheduled_activity"):
		if not bool(locations.call(
			"is_npc_available_for_scheduled_activity",
			String(npc_id),
			definition.state_name,
			definition.priority
		)):
			return

	var assignment_method := definition.get_assignment_method()
	if assignment_method != &"" and machine.has_method(assignment_method):
		if bool(machine.call(assignment_method, spot, definition.priority)):
			return
	elif machine.has_method("request_state"):
		machine.call("request_state", definition.state_name, spot, "world_activity", definition.priority)
		return

	if machine.has_method("request_state"):
		machine.call("request_state", definition.state_name, spot, "world_activity", definition.priority)


func _npc_is_following_activity(
	machine: Node,
	definition: NpcSpotDefinition,
	spot: Node2D
) -> bool:
	var current_state = machine.get("current_state")
	if current_state != null and String(current_state.name) == String(definition.state_name):
		return true
	if current_state == null or String(current_state.name) != "MoveToTarget":
		return false

	return (
		machine.get("move_target") == spot
		and String(machine.get("state_after_move")) == String(definition.state_name)
	)


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
		state["kind"] = String(definition.spot_value_name)
		state["minimum"] = lower
		state["maximum"] = upper
		state["done_threshold"] = definition.spot_value_done_threshold
		state["daily_growth"] = definition.spot_value_daily_growth
		state["value"] = clampf(
			float(state.get("value", definition.spot_value_initial)),
			lower,
			upper
		)
		spot_runtime_states[state_key] = state

	_repair_stalled_linked_spot_cycles()


func _repair_stalled_linked_spot_cycles() -> void:
	# Linked spot cycles can get stranded by old saves or interrupted transitions.
	# When every phase in a cycle is already "done", restore the configured starting phase.
	var repaired_any := false
	var visited_cycles: Dictionary = {}
	for definition_value in spot_definitions.values():
		var definition := definition_value as NpcSpotDefinition
		if definition == null or definition.next_spot_id_when_done == &"":
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
	var best_definition: NpcSpotDefinition
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
		"minimum_npc_favor": 20.0,
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
	var minimum_favor := float(settings.get("minimum_npc_favor", 20.0))
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
			var favor := float(relationships.call(
				"get_favor_by_id",
				owner_id,
				target_relationship_id,
				50.0
			))
			if favor <= minimum_favor:
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

	var definition := _find_best_definition(npc_id, record, hour)
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

	var activity := {
		"spot_id": String(definition.spot_id),
		"state_name": String(definition.state_name),
		"value_name": String(definition.value_name),
		"target_scene_path": definition.scene_path,
		"target_position": definition.position,
		"last_total_hours": total_hours,
		"return_scene_path": String(record.get("scene_path", "")),
		"return_position": record.get("last_position", Vector2.ZERO),
	}

	var live_npc: Node2D
	if locations.has_method("get_live_npc"):
		live_npc = locations.call("get_live_npc", String(npc_id)) as Node2D
	if live_npc != null and String(record.get("scene_path", "")) != definition.scene_path:
		var departure_door := _find_departure_door(definition.scene_path, live_npc)
		if departure_door == null or not locations.has_method("prepare_scheduled_travel"):
			return

		var pending_travel := {
			"mode": "start",
			"target_scene_path": definition.scene_path,
			"target_position": definition.position,
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
			activity_started.emit(npc_id, definition.spot_id)
		return

	if not locations.has_method("begin_scheduled_activity"):
		return
	if not bool(locations.call(
		"begin_scheduled_activity",
		String(npc_id),
		activity,
		definition.scene_path,
		definition.position
	)):
		return

	_claim_spot(definition.spot_id)
	activity_started.emit(npc_id, definition.spot_id)


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
		if definition == null or not definition.is_active_at(hour):
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
	var definition := spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition == null or not definition.is_active_at(hour):
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return
	if not _spot_runtime_is_available(definition):
		_finish_activity(npc_id, record, activity, spot_id, locations)
		return

	var value_name := String(definition.value_name)
	if (
		definition.finish_when_npc_value_sated
		and not value_name.is_empty()
		and _get_saved_stat(record, value_name) <= 0.0
	):
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
		_set_saved_stat(
			record,
			value_name,
			_get_saved_stat(record, value_name) + definition.value_delta_per_game_hour * elapsed_game_hours
		)
	_apply_spot_runtime_progress(definition, elapsed_game_hours)

	record["activity"] = activity
	record["last_position"] = definition.position
	if locations.has_method("update_simulated_record"):
		locations.call("update_simulated_record", String(npc_id), record)

	if (
		(
			definition.finish_when_npc_value_sated
			and not value_name.is_empty()
			and _get_saved_stat(record, value_name) <= 0.0
		)
		or not _spot_runtime_is_available(definition)
	):
		_finish_activity(npc_id, record, activity, spot_id, locations)


func _finish_activity(
	npc_id: StringName,
	record: Dictionary,
	activity: Dictionary,
	spot_id: StringName,
	locations: Node
) -> void:
	if String(activity.get("state_name", "")) == "Sleep":
		_set_saved_stat(record, "tired", 0.0)
		if locations.has_method("update_simulated_record"):
			locations.call("update_simulated_record", String(npc_id), record)

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

	if locations.has_method("finish_scheduled_activity"):
		locations.call(
			"finish_scheduled_activity",
			String(npc_id),
			return_scene_path,
			return_position
		)
	activity_finished.emit(npc_id, spot_id)


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
	var best_definition: NpcSpotDefinition = null
	var best_urgency := -INF
	for definition_value in spot_definitions.values():
		var definition := definition_value as NpcSpotDefinition
		if definition == null or not definition.allows_npc_id(npc_id):
			continue
		if not _spot_has_capacity(definition):
			continue
		if not _spot_runtime_is_available(definition):
			continue
		if not definition.is_active_at(hour):
			continue
		if definition.value_name != &"":
			if (
				definition.require_npc_value_threshold
				and not _saved_stat_exists(record, String(definition.value_name))
			):
				continue
			var current_value := _get_saved_stat(record, String(definition.value_name))
			var effective_threshold := _get_effective_need_threshold(definition, hour)
			var urgency := _get_definition_urgency(definition)
			if definition.require_npc_value_threshold:
				if current_value < effective_threshold:
					continue
				if definition.need_maximum >= 0.0 and current_value > definition.need_maximum:
					continue
				urgency = current_value - effective_threshold
			if (
				best_definition == null
				or definition.priority > best_definition.priority
				or (
					definition.priority == best_definition.priority
					and urgency > best_urgency
				)
				or (
					definition.priority == best_definition.priority
					and is_equal_approx(urgency, best_urgency)
					and String(definition.spot_id) < String(best_definition.spot_id)
				)
			):
				best_definition = definition
				best_urgency = urgency
			continue
		if best_definition == null or definition.priority > best_definition.priority:
			best_definition = definition
			best_urgency = 0.0

	return best_definition


func _variant_array_has_string(values, expected: String) -> bool:
	if not (values is Array):
		return false
	for value in values:
		if String(value) == expected:
			return true
	return false


func _get_effective_need_threshold(definition: NpcSpotDefinition, hour: float) -> float:
	# A mutable spot can lower its need threshold as its backlog approaches maximum.
	var threshold := _get_timed_need_threshold(definition, hour)
	if (
		definition.spot_value_name == &""
		or definition.need_threshold_at_spot_value_maximum < 0.0
	):
		return threshold

	var state = spot_runtime_states.get(String(definition.spot_id), {})
	if not (state is Dictionary):
		return threshold

	var minimum := float(state.get("minimum", definition.spot_value_minimum))
	var maximum := float(state.get("maximum", definition.spot_value_maximum))
	if is_equal_approx(minimum, maximum):
		return threshold

	var current := float(state.get("value", definition.spot_value_initial))
	var backlog_ratio := clampf(inverse_lerp(minimum, maximum, current), 0.0, 1.0)
	return lerpf(
		threshold,
		definition.need_threshold_at_spot_value_maximum,
		backlog_ratio
	)


func _get_timed_need_threshold(definition: NpcSpotDefinition, hour: float) -> float:
	# Meal-style windows can temporarily lower a need threshold without making the spot inactive.
	for window in definition.timed_need_thresholds:
		if not (window is Dictionary):
			continue
		var window_dictionary: Dictionary = window
		if not _time_window_contains_hour(window_dictionary, hour):
			continue
		return float(window_dictionary.get(
			"need_threshold",
			window_dictionary.get("threshold", definition.need_threshold)
		))

	return definition.need_threshold


func _time_window_contains_hour(window: Dictionary, hour: float) -> bool:
	var start_hour := fposmod(float(window.get("start_hour", window.get("start", 0.0))), 24.0)
	var end_hour := fposmod(float(window.get("end_hour", window.get("end", 24.0))), 24.0)
	var normalized_hour := fposmod(hour, 24.0)

	if is_equal_approx(start_hour, end_hour):
		return true
	if start_hour < end_hour:
		return normalized_hour >= start_hour and normalized_hour < end_hour

	return normalized_hour >= start_hour or normalized_hour < end_hour


func _get_definition_urgency(definition: NpcSpotDefinition) -> float:
	# For work-gated activities, backlog is the urgency when NPC need is not the gate.
	if definition.spot_value_name == &"":
		return 0.0

	var state = spot_runtime_states.get(String(definition.spot_id), {})
	if not (state is Dictionary):
		return 0.0

	var minimum := float(state.get("minimum", definition.spot_value_minimum))
	var maximum := float(state.get("maximum", definition.spot_value_maximum))
	if is_equal_approx(minimum, maximum):
		return 0.0

	var current := float(state.get("value", definition.spot_value_initial))
	return clampf(inverse_lerp(minimum, maximum, current), 0.0, 1.0) * 100.0


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
	if definition.capacity <= 0:
		return true
	return int(spot_claim_counts.get(definition.spot_id, 0)) < definition.capacity


func _spot_runtime_is_available(definition: NpcSpotDefinition) -> bool:
	if definition.spot_value_name == &"":
		return true
	var state = spot_runtime_states.get(String(definition.spot_id), {})
	if not (state is Dictionary):
		return false
	return float(state.get("value", 0.0)) > float(
		state.get("done_threshold", definition.spot_value_done_threshold)
	)


func _apply_spot_runtime_progress(
	definition: NpcSpotDefinition,
	game_hours: float
) -> void:
	if definition.spot_value_name == &"" or game_hours <= 0.0:
		return
	apply_spot_value_delta(
		definition.spot_id,
		definition.spot_value_delta_per_game_hour * game_hours
	)


func _saved_stat_exists(record: Dictionary, value_name: String) -> bool:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return false
	var social_stats = node_state.get("social_stats", {})
	return social_stats is Dictionary and social_stats.has(value_name)


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
