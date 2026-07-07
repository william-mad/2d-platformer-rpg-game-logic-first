class_name NpcMealCycleRuntime
extends RefCounted

const MEAL_STAGE_PREP_WORK := "prep_work"
const MEAL_STAGE_FOOD := "food"
const MEAL_STAGE_CLEANUP_WORK := "cleanup_work"
const MEAL_OWNER_PREP := "prep"
const MEAL_OWNER_FOOD := "food"
const MEAL_OWNER_CLEANUP := "cleanup"
const MEAL_CYCLE_EPSILON := 0.001


static func get_meal_cycle_state(runtime, spot_id: StringName) -> Dictionary:
	var controller_id := _get_meal_cycle_controller_id_for_spot(runtime, spot_id)
	if controller_id == &"":
		return {}
	var state = runtime.spot_runtime_states.get(String(controller_id), {})
	if not (state is Dictionary):
		return {}
	var state_dictionary: Dictionary = state
	return state_dictionary.duplicate(true)


static func _initialize_meal_cycle_runtime_states(runtime) -> void:
	var current_total_hours: float = runtime._get_current_total_hours()
	for controller in _get_meal_cycle_controller_definitions(runtime):
		var state_key := String(controller.spot_id)
		var state = runtime.spot_runtime_states.get(state_key, {})
		if not (state is Dictionary):
			state = {}

		var lower := minf(controller.spot_value_minimum, controller.spot_value_maximum)
		var upper := maxf(controller.spot_value_minimum, controller.spot_value_maximum)
		state["kind"] = "meal_cycle"
		state["meal_cycle_enabled"] = true
		state["meal_cycle_id"] = String(controller.meal_cycle_id)
		state["food_spot_id"] = String(_get_meal_cycle_food_spot_id(controller))
		state["minimum"] = lower
		state["maximum"] = upper
		state["done_threshold"] = controller.spot_value_done_threshold
		state["daily_growth"] = 0.0
		state["value"] = clampf(
			float(state.get("value", controller.spot_value_initial)),
			lower,
			upper
		)
		state["stage"] = _normalize_meal_cycle_stage(String(state.get("stage", MEAL_STAGE_PREP_WORK)))
		state["meal"] = String(state.get("meal", ""))
		state["work_call_active"] = bool(state.get("work_call_active", false))
		state["meal_called"] = bool(state.get("meal_called", false))
		state["food_available"] = bool(state.get("food_available", false))
		state["food_ready_total_hours"] = float(state.get("food_ready_total_hours", -1.0))
		state["last_schedule_total_hours"] = float(state.get(
			"last_schedule_total_hours",
			maxf(current_total_hours - MEAL_CYCLE_EPSILON, 0.0)
		))
		state["prep_owner_ids"] = _string_names_to_strings(
			controller.meal_cycle_prep_owner_ids,
			controller.get_owner_ids()
		)
		state["food_owner_ids"] = _string_names_to_strings(
			controller.meal_cycle_food_owner_ids,
			_get_meal_cycle_food_definition_owner_ids(runtime, controller)
		)
		state["cleanup_owner_ids"] = _string_names_to_strings(
			controller.meal_cycle_cleanup_owner_ids,
			[]
		)

		var owner_meal_data = state.get("owner_meal_data", {})
		if not (owner_meal_data is Dictionary):
			owner_meal_data = {}
		state["owner_meal_data"] = owner_meal_data

		runtime.spot_runtime_states[state_key] = state
		_sync_meal_cycle_food_state(runtime, controller, state)


static func _process_meal_cycle_schedule_until_snapshot(runtime, snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return

	var current_total_hours := _snapshot_total_hours(snapshot)
	for controller in _get_meal_cycle_controller_definitions(runtime):
		var state_key := String(controller.spot_id)
		var state = runtime.spot_runtime_states.get(state_key, {})
		if not (state is Dictionary):
			continue

		var previous_total_hours := float(state.get(
			"last_schedule_total_hours",
			maxf(current_total_hours - MEAL_CYCLE_EPSILON, 0.0)
		))
		if previous_total_hours > current_total_hours:
			previous_total_hours = maxf(current_total_hours - MEAL_CYCLE_EPSILON, 0.0)

		var events := _collect_meal_cycle_schedule_events(
			controller,
			previous_total_hours,
			current_total_hours
		)
		events.sort_custom(Callable(runtime, "_meal_cycle_event_comes_before"))
		for event in events:
			CrashBreadcrumbs.mark(
				"meal_cycle:event",
				"%s %s %.3f" % [
					String(controller.spot_id),
					String(event.get("type", "")),
					float(event.get("total_hours", 0.0)),
				]
			)
			_process_meal_cycle_schedule_event(runtime, controller, event)

		state = runtime.spot_runtime_states.get(state_key, {})
		if state is Dictionary:
			state["last_schedule_total_hours"] = current_total_hours
			runtime.spot_runtime_states[state_key] = state


static func _collect_meal_cycle_schedule_events(
	controller: NpcSpotDefinition,
	previous_total_hours: float,
	current_total_hours: float
) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if current_total_hours + MEAL_CYCLE_EPSILON < previous_total_hours:
		return events

	var first_day := maxi(int(floor(previous_total_hours / 24.0)) - 1, 0)
	var last_day := maxi(int(floor(current_total_hours / 24.0)) + 1, 0)
	for day in range(first_day, last_day + 1):
		for schedule_value in controller.meal_cycle_schedule:
			if not (schedule_value is Dictionary):
				continue
			var schedule: Dictionary = schedule_value
			_append_meal_cycle_schedule_event(
				events,
				schedule,
				day,
				"prep",
				"prep_hour",
				0,
				previous_total_hours,
				current_total_hours
			)
			_append_meal_cycle_schedule_event(
				events,
				schedule,
				day,
				"call",
				"call_hour",
				1,
				previous_total_hours,
				current_total_hours
			)
			_append_meal_cycle_schedule_event(
				events,
				schedule,
				day,
				"cleanup",
				"cleanup_hour",
				2,
				previous_total_hours,
				current_total_hours
			)

	return events


static func _append_meal_cycle_schedule_event(
	events: Array[Dictionary],
	schedule: Dictionary,
	day: int,
	event_type: String,
	hour_key: String,
	order: int,
	previous_total_hours: float,
	current_total_hours: float
) -> void:
	if not schedule.has(hour_key):
		return

	var event_hour := fposmod(float(schedule[hour_key]), 24.0)
	var event_total_hours := float(day * 24) + event_hour
	if event_total_hours <= previous_total_hours:
		return
	if event_total_hours > current_total_hours + MEAL_CYCLE_EPSILON:
		return

	events.append({
		"meal": String(schedule.get("meal", "")),
		"type": event_type,
		"order": order,
		"total_hours": event_total_hours,
	})


static func _meal_cycle_event_comes_before(left: Dictionary, right: Dictionary) -> bool:
	var left_hours := float(left.get("total_hours", 0.0))
	var right_hours := float(right.get("total_hours", 0.0))
	if not is_equal_approx(left_hours, right_hours):
		return left_hours < right_hours
	return int(left.get("order", 0)) < int(right.get("order", 0))


static func _process_meal_cycle_schedule_event(
	runtime,
	controller: NpcSpotDefinition,
	event: Dictionary
) -> void:
	var meal := String(event.get("meal", ""))
	var event_total_hours := float(event.get("total_hours", 0.0))
	match String(event.get("type", "")):
		"prep":
			_start_meal_cycle_prep(runtime, controller, meal, event_total_hours)
		"call":
			_call_meal_cycle_food(runtime, controller, meal, event_total_hours)
		"cleanup":
			_start_meal_cycle_cleanup(runtime, controller, meal, event_total_hours)


static func _start_meal_cycle_prep(
	runtime,
	controller: NpcSpotDefinition,
	meal: String,
	event_total_hours: float
) -> void:
	var state := _get_meal_cycle_controller_state(runtime, controller.spot_id)
	if state.is_empty():
		return

	CrashBreadcrumbs.mark("meal_cycle:prep", "%s %s" % [String(controller.spot_id), meal])
	state["stage"] = MEAL_STAGE_PREP_WORK
	state["meal"] = meal
	state["value"] = _get_meal_cycle_reset_work_value(controller)
	state["work_call_active"] = true
	state["meal_called"] = false
	state["food_available"] = false
	state["food_ready_total_hours"] = -1.0
	state["stage_started_total_hours"] = event_total_hours
	state.erase("pending_work_completion_total_hours")
	_set_meal_cycle_controller_state(runtime, controller, state)


static func _call_meal_cycle_food(
	runtime,
	controller: NpcSpotDefinition,
	meal: String,
	event_total_hours: float
) -> void:
	var state := _get_meal_cycle_controller_state(runtime, controller.spot_id)
	if state.is_empty():
		return

	CrashBreadcrumbs.mark("meal_cycle:call_food", "%s %s" % [String(controller.spot_id), meal])
	var ready_total_hours := float(state.get("food_ready_total_hours", event_total_hours))
	var can_call := (
		String(state.get("stage", "")) == MEAL_STAGE_FOOD
		and String(state.get("meal", "")) == meal
		and bool(state.get("food_available", false))
		and ready_total_hours <= event_total_hours + MEAL_CYCLE_EPSILON
	)
	state["meal_called"] = can_call
	state["last_food_call_total_hours"] = event_total_hours
	state["last_food_call_meal"] = meal
	if can_call:
		_record_meal_owner_call_flags(state, meal)

	_set_meal_cycle_controller_state(runtime, controller, state)


static func _start_meal_cycle_cleanup(
	runtime,
	controller: NpcSpotDefinition,
	meal: String,
	event_total_hours: float
) -> void:
	var state := _get_meal_cycle_controller_state(runtime, controller.spot_id)
	if state.is_empty():
		return
	if (
		String(state.get("stage", "")) == MEAL_STAGE_CLEANUP_WORK
		and String(state.get("meal", "")) == meal
	):
		return

	CrashBreadcrumbs.mark("meal_cycle:cleanup", "%s %s" % [String(controller.spot_id), meal])
	state["stage"] = MEAL_STAGE_CLEANUP_WORK
	state["meal"] = meal
	state["value"] = _get_meal_cycle_reset_work_value(controller)
	state["work_call_active"] = true
	state["meal_called"] = false
	state["food_available"] = false
	state["food_ready_total_hours"] = -1.0
	state["stage_started_total_hours"] = event_total_hours
	state.erase("pending_work_completion_total_hours")
	_set_meal_cycle_controller_state(runtime, controller, state)


static func _advance_meal_cycle_work_complete(runtime, controller_spot_id: StringName) -> void:
	var controller := runtime.spot_definitions.get(controller_spot_id, null) as NpcSpotDefinition
	if controller == null:
		return

	var state := _get_meal_cycle_controller_state(runtime, controller_spot_id)
	if state.is_empty():
		return

	var completed_total_hours := float(state.get(
		"pending_work_completion_total_hours",
		runtime._get_current_total_hours()
	))
	state.erase("pending_work_completion_total_hours")

	var stage := String(state.get("stage", MEAL_STAGE_PREP_WORK))
	if stage == MEAL_STAGE_PREP_WORK:
		state["stage"] = MEAL_STAGE_FOOD
		state["value"] = float(state.get("done_threshold", controller.spot_value_done_threshold))
		state["work_call_active"] = false
		state["food_available"] = true
		state["meal_called"] = false
		state["food_ready_total_hours"] = completed_total_hours
		state["stage_started_total_hours"] = completed_total_hours
		_set_meal_cycle_controller_state(runtime, controller, state)
		return

	if stage == MEAL_STAGE_CLEANUP_WORK:
		state["stage"] = MEAL_STAGE_PREP_WORK
		state["meal"] = ""
		state["value"] = _get_meal_cycle_reset_work_value(controller)
		state["work_call_active"] = false
		state["meal_called"] = false
		state["food_available"] = false
		state["food_ready_total_hours"] = -1.0
		state["stage_started_total_hours"] = completed_total_hours
		_set_meal_cycle_controller_state(runtime, controller, state)
		return

	_set_meal_cycle_controller_state(runtime, controller, state)


static func _apply_meal_cycle_work_progress(
	runtime,
	definition: NpcSpotDefinition,
	game_hours: float,
	total_hours: float
) -> void:
	var state := _get_meal_cycle_controller_state(runtime, definition.spot_id)
	if state.is_empty():
		return

	var previous_value := float(state.get("value", definition.spot_value_initial))
	var requested_delta := definition.spot_value_delta_per_game_hour * game_hours
	var done_threshold := float(state.get("done_threshold", definition.spot_value_done_threshold))
	if (
		total_hours >= 0.0
		and requested_delta < 0.0
		and previous_value > done_threshold
		and previous_value + requested_delta <= done_threshold
	):
		var progress_fraction := clampf(
			(previous_value - done_threshold) / maxf(absf(requested_delta), 0.001),
			0.0,
			1.0
		)
		state["pending_work_completion_total_hours"] = maxf(
			total_hours - game_hours + game_hours * progress_fraction,
			0.0
		)
		runtime.spot_runtime_states[String(definition.spot_id)] = state

	runtime.apply_spot_value_delta(definition.spot_id, requested_delta)


static func _set_meal_cycle_controller_state(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> void:
	runtime.spot_runtime_states[String(controller.spot_id)] = state
	_sync_meal_cycle_food_state(runtime, controller, state)
	runtime._notify_live_spot_value(controller.spot_id, float(state.get("value", controller.spot_value_initial)))
	_notify_meal_cycle_state(runtime, controller.spot_id)


static func _sync_meal_cycle_food_state(
	runtime,
	controller: NpcSpotDefinition,
	controller_state: Dictionary
) -> void:
	var food_spot_id := _get_meal_cycle_food_spot_id(controller)
	if food_spot_id == &"":
		return

	var food_definition := runtime.spot_definitions.get(food_spot_id, null) as NpcSpotDefinition
	var food_key := String(food_spot_id)
	var food_state = runtime.spot_runtime_states.get(food_key, {})
	if not (food_state is Dictionary):
		food_state = {}

	var lower := 0.0
	var upper := 1.0
	var done_threshold := 0.0
	if food_definition != null:
		lower = minf(food_definition.spot_value_minimum, food_definition.spot_value_maximum)
		upper = maxf(food_definition.spot_value_minimum, food_definition.spot_value_maximum)
		done_threshold = food_definition.spot_value_done_threshold

	var food_is_available := (
		String(controller_state.get("stage", "")) == MEAL_STAGE_FOOD
		and bool(controller_state.get("food_available", false))
	)
	var stage_started_total_hours := float(controller_state.get("stage_started_total_hours", -1.0))
	var previous_stage_started_total_hours := float(food_state.get(
		"meal_cycle_stage_started_total_hours",
		-1.0
	))
	var previous_active := bool(food_state.get("meal_cycle_food_active", false))
	var should_reset_food := (
		food_is_available
		and (
			not previous_active
			or not is_equal_approx(previous_stage_started_total_hours, stage_started_total_hours)
		)
	)
	var next_value := lower
	if food_is_available:
		if should_reset_food:
			next_value = upper
		else:
			next_value = clampf(float(food_state.get("value", upper)), lower, upper)
		food_is_available = next_value > done_threshold

	food_state["kind"] = "food_available"
	food_state["meal_cycle_controller_id"] = String(controller.spot_id)
	food_state["meal_cycle_id"] = String(controller.meal_cycle_id)
	food_state["minimum"] = lower
	food_state["maximum"] = upper
	food_state["done_threshold"] = done_threshold
	food_state["daily_growth"] = 0.0
	food_state["value"] = next_value
	food_state["meal_cycle_food_active"] = food_is_available
	food_state["meal_cycle_stage_started_total_hours"] = stage_started_total_hours
	controller_state["food_available"] = food_is_available
	controller_state["food_value"] = next_value
	controller_state["food_limit"] = upper
	runtime.spot_runtime_states[String(controller.spot_id)] = controller_state
	runtime.spot_runtime_states[food_key] = food_state
	runtime._notify_live_spot_value(food_spot_id, float(food_state["value"]))


static func _deplete_meal_cycle_food(runtime, food_spot_id: StringName) -> void:
	var controller_id := _get_meal_cycle_controller_id_for_spot(runtime, food_spot_id)
	if controller_id == &"":
		return
	var controller := runtime.spot_definitions.get(controller_id, null) as NpcSpotDefinition
	if controller == null:
		return

	var state := _get_meal_cycle_controller_state(runtime, controller_id)
	if state.is_empty():
		return
	if String(state.get("stage", "")) != MEAL_STAGE_FOOD:
		return

	state["stage"] = MEAL_STAGE_CLEANUP_WORK
	state["value"] = _get_meal_cycle_reset_work_value(controller)
	state["work_call_active"] = true
	state["meal_called"] = false
	state["food_available"] = false
	state["food_ready_total_hours"] = -1.0
	state["stage_started_total_hours"] = runtime._get_current_total_hours()
	state.erase("pending_work_completion_total_hours")
	_set_meal_cycle_controller_state(runtime, controller, state)


static func _notify_meal_cycle_state(runtime, controller_spot_id: StringName) -> void:
	if controller_spot_id == &"":
		return

	var state = runtime.spot_runtime_states.get(String(controller_spot_id), {})
	if not (state is Dictionary):
		return
	state = _get_meal_cycle_state_with_food_value(runtime, controller_spot_id, state)

	var notified_spots: Array[Node] = []
	var controller_spot := runtime.live_spots.get(controller_spot_id, null) as Node
	if controller_spot != null and is_instance_valid(controller_spot):
		_notify_live_spot_meal_cycle_state(controller_spot, controller_spot_id, state)
		notified_spots.append(controller_spot)

	var food_spot_id := StringName(String(state.get("food_spot_id", "")))
	var food_spot := runtime.live_spots.get(food_spot_id, null) as Node
	if (
		food_spot != null
		and is_instance_valid(food_spot)
		and not notified_spots.has(food_spot)
	):
		_notify_live_spot_meal_cycle_state(food_spot, controller_spot_id, state)


static func _notify_live_spot_meal_cycle_state(
	spot: Node,
	controller_spot_id: StringName,
	state: Dictionary
) -> void:
	if spot.has_method("apply_world_meal_cycle_state"):
		spot.call("apply_world_meal_cycle_state", controller_spot_id, state.duplicate(true))


static func _meal_cycle_definition_can_start(
	runtime,
	definition: NpcSpotDefinition,
	npc_id: StringName,
	_hour: float
) -> bool:
	if not _meal_cycle_definition_is_available(runtime, definition):
		return false

	var controller_id := _get_meal_cycle_controller_id_for_definition(runtime, definition)
	var state := _get_meal_cycle_controller_state(runtime, controller_id)
	if state.is_empty():
		return false

	if _definition_is_meal_cycle_food(definition):
		return (
			_meal_cycle_owner_allows(state, MEAL_OWNER_FOOD, npc_id)
			and not _meal_cycle_owner_has_had_current_meal(state, npc_id)
		)

	var stage := String(state.get("stage", ""))
	if stage == MEAL_STAGE_PREP_WORK:
		return _meal_cycle_owner_allows(state, MEAL_OWNER_PREP, npc_id)
	if stage == MEAL_STAGE_CLEANUP_WORK:
		return _meal_cycle_owner_allows(state, MEAL_OWNER_CLEANUP, npc_id)

	return false


static func _meal_cycle_definition_is_available(runtime, definition: NpcSpotDefinition) -> bool:
	var controller_id := _get_meal_cycle_controller_id_for_definition(runtime, definition)
	var state := _get_meal_cycle_controller_state(runtime, controller_id)
	if state.is_empty():
		return false

	if _definition_is_meal_cycle_food(definition):
		var food_value := _get_meal_cycle_food_value(runtime, definition, state)
		return (
			String(state.get("stage", "")) == MEAL_STAGE_FOOD
			and bool(state.get("food_available", false))
			and bool(state.get("meal_called", false))
			and food_value > definition.spot_value_done_threshold
		)

	if not _definition_is_meal_cycle_controller(definition):
		return false

	var stage := String(state.get("stage", ""))
	if stage != MEAL_STAGE_PREP_WORK and stage != MEAL_STAGE_CLEANUP_WORK:
		return false
	if not bool(state.get("work_call_active", false)):
		return false

	return float(state.get("value", 0.0)) > float(
		state.get("done_threshold", definition.spot_value_done_threshold)
	)


static func _get_meal_cycle_state_with_food_value(
	runtime,
	controller_spot_id: StringName,
	state: Dictionary
) -> Dictionary:
	var enriched_state := state.duplicate(true)
	var food_spot_id := StringName(String(enriched_state.get("food_spot_id", "")))
	if food_spot_id == &"":
		return enriched_state

	var food_definition := runtime.spot_definitions.get(food_spot_id, null) as NpcSpotDefinition
	var food_state = runtime.spot_runtime_states.get(String(food_spot_id), {})
	var fallback_limit := 100.0
	var done_threshold := 0.0
	if food_definition != null:
		fallback_limit = maxf(food_definition.spot_value_minimum, food_definition.spot_value_maximum)
		done_threshold = food_definition.spot_value_done_threshold
	var food_value := fallback_limit if bool(enriched_state.get("food_available", false)) else 0.0
	if food_state is Dictionary:
		food_value = float(food_state.get("value", food_value))

	enriched_state["food_value"] = food_value
	enriched_state["food_limit"] = fallback_limit
	enriched_state["food_available"] = (
		bool(enriched_state.get("food_available", false))
		and food_value > done_threshold
	)
	return enriched_state


static func _get_meal_cycle_food_value(
	runtime,
	definition: NpcSpotDefinition,
	state: Dictionary
) -> float:
	var food_spot_id := definition.spot_id
	var food_state = runtime.spot_runtime_states.get(String(food_spot_id), {})
	if food_state is Dictionary:
		return float(food_state.get("value", 0.0))

	return float(state.get("food_value", 0.0))


static func mark_meal_owner_sated(
	runtime,
	spot_id: StringName,
	owner_id: StringName,
	value_name: StringName = &"hunger"
) -> bool:
	if String(value_name) != "hunger":
		return false

	var controller_id := _get_meal_cycle_controller_id_for_spot(runtime, spot_id)
	if controller_id == &"":
		return false
	var controller := runtime.spot_definitions.get(controller_id, null) as NpcSpotDefinition
	if controller == null:
		return false

	var state := _get_meal_cycle_controller_state(runtime, controller_id)
	if state.is_empty():
		return false
	if String(state.get("stage", "")) != MEAL_STAGE_FOOD:
		return false
	if not bool(state.get("food_available", false)):
		return false
	var meal := String(state.get("meal", ""))
	if meal.is_empty():
		return false

	_set_owner_meal_flag(state, owner_id, meal, true)
	_set_meal_cycle_controller_state(runtime, controller, state)
	return true


static func _record_breakfast_owner_flags(state: Dictionary) -> void:
	_record_meal_owner_call_flags(state, "breakfast")


static func _record_meal_owner_call_flags(state: Dictionary, meal: String) -> void:
	if meal.is_empty():
		return

	var owner_data = state.get("owner_meal_data", {})
	if not (owner_data is Dictionary):
		owner_data = {}

	for owner_id in _get_meal_cycle_owner_ids(state, MEAL_OWNER_FOOD):
		var owner_key := String(owner_id)
		var meal_data = owner_data.get(owner_key, {})
		if not (meal_data is Dictionary):
			meal_data = {}
		meal_data[_get_has_had_meal_key(meal)] = false
		meal_data[_get_needs_meal_key(meal)] = true
		meal_data["called_for_meal"] = meal
		owner_data[owner_key] = meal_data

	state["owner_meal_data"] = owner_data


static func _set_owner_meal_flag(
	state: Dictionary,
	owner_id: StringName,
	meal: String,
	has_had_meal: bool
) -> void:
	var owner_data = state.get("owner_meal_data", {})
	if not (owner_data is Dictionary):
		owner_data = {}

	var owner_key := String(owner_id)
	var meal_data = owner_data.get(owner_key, {})
	if not (meal_data is Dictionary):
		meal_data = {}
	meal_data[_get_has_had_meal_key(meal)] = has_had_meal
	meal_data[_get_needs_meal_key(meal)] = not has_had_meal
	meal_data["last_completed_meal"] = meal if has_had_meal else ""
	owner_data[owner_key] = meal_data
	state["owner_meal_data"] = owner_data


static func _meal_cycle_owner_has_had_current_meal(
	state: Dictionary,
	owner_id: StringName
) -> bool:
	var meal := String(state.get("meal", ""))
	if meal.is_empty():
		return false

	var owner_data = state.get("owner_meal_data", {})
	if not (owner_data is Dictionary):
		return false
	var meal_data = owner_data.get(String(owner_id), {})
	if not (meal_data is Dictionary):
		return false

	return bool(meal_data.get(_get_has_had_meal_key(meal), false))


static func _get_has_had_meal_key(meal: String) -> String:
	return "has_had_%s" % meal.to_snake_case()


static func _get_needs_meal_key(meal: String) -> String:
	return "needs_%s" % meal.to_snake_case()


static func _get_meal_cycle_controller_definitions(runtime) -> Array[NpcSpotDefinition]:
	var controllers: Array[NpcSpotDefinition] = []
	for definition_value in runtime.spot_definitions.values():
		var definition := definition_value as NpcSpotDefinition
		if definition != null and _definition_is_meal_cycle_controller(definition):
			controllers.append(definition)
	return controllers


static func _definition_is_meal_cycle_managed(definition: NpcSpotDefinition) -> bool:
	return (
		_definition_is_meal_cycle_controller(definition)
		or _definition_is_meal_cycle_food(definition)
	)


static func _definition_is_meal_cycle_controller(definition: NpcSpotDefinition) -> bool:
	return (
		definition != null
		and definition.meal_cycle_id != &""
		and not definition.meal_cycle_schedule.is_empty()
	)


static func _definition_is_meal_cycle_food(definition: NpcSpotDefinition) -> bool:
	return (
		definition != null
		and definition.meal_cycle_id != &""
		and String(definition.meal_cycle_stage) == MEAL_STAGE_FOOD
	)


static func _get_meal_cycle_controller_id_for_spot(runtime, spot_id: StringName) -> StringName:
	if spot_id == &"":
		return &""
	var definition := runtime.spot_definitions.get(spot_id, null) as NpcSpotDefinition
	if definition != null:
		return _get_meal_cycle_controller_id_for_definition(runtime, definition)

	var state = runtime.spot_runtime_states.get(String(spot_id), {})
	if state is Dictionary and state.has("meal_cycle_controller_id"):
		return StringName(String(state["meal_cycle_controller_id"]))
	return &""


static func _get_meal_cycle_controller_id_for_definition(
	runtime,
	definition: NpcSpotDefinition
) -> StringName:
	if definition == null:
		return &""
	if _definition_is_meal_cycle_controller(definition):
		return definition.spot_id
	if not _definition_is_meal_cycle_food(definition):
		return &""

	for controller in _get_meal_cycle_controller_definitions(runtime):
		if (
			controller.meal_cycle_id == definition.meal_cycle_id
			and _get_meal_cycle_food_spot_id(controller) == definition.spot_id
		):
			return controller.spot_id

	return &""


static func _get_meal_cycle_controller_state(runtime, controller_id: StringName) -> Dictionary:
	if controller_id == &"":
		return {}
	var state = runtime.spot_runtime_states.get(String(controller_id), {})
	if state is Dictionary and bool(state.get("meal_cycle_enabled", false)):
		return state
	return {}


static func _get_meal_cycle_food_spot_id(controller: NpcSpotDefinition) -> StringName:
	if controller == null:
		return &""
	if controller.meal_cycle_food_spot_id != &"":
		return controller.meal_cycle_food_spot_id
	if controller.next_spot_id_when_done != &"":
		return controller.next_spot_id_when_done
	return &""


static func _get_meal_cycle_food_definition_owner_ids(
	runtime,
	controller: NpcSpotDefinition
) -> Array[StringName]:
	var food_definition := runtime.spot_definitions.get(
		_get_meal_cycle_food_spot_id(controller),
		null
	) as NpcSpotDefinition
	if food_definition != null:
		return food_definition.get_owner_ids()
	return controller.get_owner_ids()


static func _get_meal_cycle_reset_work_value(controller: NpcSpotDefinition) -> float:
	return clampf(
		controller.spot_value_initial,
		minf(controller.spot_value_minimum, controller.spot_value_maximum),
		maxf(controller.spot_value_minimum, controller.spot_value_maximum)
	)


static func _get_meal_cycle_owner_ids(
	state: Dictionary,
	owner_type: String
) -> Array[StringName]:
	var key := "%s_owner_ids" % owner_type
	var owner_values = state.get(key, [])
	var owner_ids: Array[StringName] = []
	if not (owner_values is Array):
		return owner_ids
	for owner_value in owner_values:
		var owner_text := String(owner_value).strip_edges()
		if owner_text.is_empty():
			continue
		var owner_id := StringName(owner_text)
		if not owner_ids.has(owner_id):
			owner_ids.append(owner_id)
	return owner_ids


static func _meal_cycle_owner_allows(
	state: Dictionary,
	owner_type: String,
	owner_id: StringName
) -> bool:
	var owner_ids := _get_meal_cycle_owner_ids(state, owner_type)
	if owner_ids.is_empty():
		return true

	for configured_id in owner_ids:
		if String(configured_id) == String(owner_id):
			return true

	return false


static func _string_names_to_strings(
	values: Array,
	fallback_values: Array
) -> Array[String]:
	var source_values := values if not values.is_empty() else fallback_values
	var strings: Array[String] = []
	for value in source_values:
		var text := String(value).strip_edges()
		if text.is_empty() or strings.has(text):
			continue
		strings.append(text)
	return strings


static func _normalize_meal_cycle_stage(stage: String) -> String:
	var normalized := stage.to_snake_case()
	if normalized == MEAL_STAGE_FOOD:
		return MEAL_STAGE_FOOD
	if normalized == MEAL_STAGE_CLEANUP_WORK:
		return MEAL_STAGE_CLEANUP_WORK
	return MEAL_STAGE_PREP_WORK


static func _spot_state_is_meal_cycle_managed(state: Dictionary) -> bool:
	return (
		bool(state.get("meal_cycle_enabled", false))
		or state.has("meal_cycle_controller_id")
	)


static func _snapshot_total_hours(snapshot: Dictionary) -> float:
	if snapshot.has("total_hours"):
		return float(snapshot["total_hours"])
	return float(snapshot.get("day", 0)) * 24.0 + float(snapshot.get(
		"time_of_day_hours",
		snapshot.get("hour", 0.0)
	))
