class_name NpcMealCycleRuntime
extends RefCounted

const MEAL_STAGE_PREP_WORK := "prep_work"
const MEAL_STAGE_FOOD := "food"
const MEAL_STAGE_CLEANUP_WORK := "cleanup_work"
const MEAL_OWNER_PREP := "prep"
const MEAL_OWNER_FOOD := "food"
const MEAL_OWNER_CLEANUP := "cleanup"
const MEAL_CYCLE_EPSILON := 0.001
const MEAL_SCHEMA_VERSION := 1


static func get_meal_cycle_state(runtime, spot_id: StringName) -> Dictionary:
	var controller_id := _get_meal_cycle_controller_id_for_spot(runtime, spot_id)
	if controller_id == &"":
		return {}
	var state = runtime.spot_runtime_states.get(String(controller_id), {})
	if not (state is Dictionary):
		return {}
	var state_dictionary: Dictionary = state
	return state_dictionary.duplicate(true)


static func supply_meal_cycle_recipe_batches(
	runtime,
	controller_spot_id: StringName,
	source_inventory: InventoryModel,
	requested_batches: int
) -> InventoryResult:
	if source_inventory == null:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"A source inventory is required."
		)
	if requested_batches <= 0:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_QUANTITY,
			"Requested meal recipe batches must be positive.",
			&"",
			requested_batches
		)
	var controller := runtime.spot_definitions.get(controller_spot_id, null) as NpcSpotDefinition
	if controller == null or not _definition_is_meal_cycle_controller(controller):
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"Meal-cycle controller '%s' was not found." % String(controller_spot_id)
		)
	if controller.meal_cycle_infinite_ingredient_storage:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"Meal-cycle controller '%s' draws ingredients from its configured storage."
			% String(controller_spot_id)
		)
	var recipe := _get_valid_meal_cycle_recipe(runtime, controller)
	if recipe == null:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"Meal-cycle controller '%s' has no valid configured recipe."
			% String(controller_spot_id)
		)
	var state := _get_meal_cycle_controller_state(runtime, controller_spot_id)
	if state.is_empty():
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"Meal-cycle controller '%s' has no runtime state." % String(controller_spot_id)
		)
	if String(state.get("stage", "")) == MEAL_STAGE_FOOD:
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"Ingredients cannot be supplied while communal food is being served."
		)

	var requested_inputs := _get_recipe_inputs_for_batches(recipe, requested_batches)
	if requested_inputs.is_empty():
		return InventoryResult.failed(
			InventoryResult.Code.INVALID_SAVE_DATA,
			"The configured meal recipe has no valid inputs."
		)
	var ingredient_inventory := _load_meal_ingredient_inventory(runtime, controller, state)
	var transfer_result := InventoryTransactionService.transfer_items(
		source_inventory,
		ingredient_inventory,
		requested_inputs
	)
	if not transfer_result.success:
		return transfer_result

	state["ingredient_inventory"] = ingredient_inventory.get_save_data()
	if (
		String(state.get("stage", "")) == MEAL_STAGE_PREP_WORK
		and bool(state.get("waiting_for_ingredients", false))
	):
		_attempt_activate_recipe_preparation(runtime, controller, state)
	_set_meal_cycle_controller_state(runtime, controller, state)
	return InventoryResult.succeeded(
		"Supplied %d meal recipe batch%s." % [
			requested_batches,
			"" if requested_batches == 1 else "es",
		]
	)


static func _initialize_meal_cycle_runtime_states(runtime) -> void:
	var current_total_hours: float = runtime._get_current_total_hours()
	for controller in _get_meal_cycle_controller_definitions(runtime):
		var state_key := String(controller.spot_id)
		var state = runtime.spot_runtime_states.get(state_key, {})
		if not (state is Dictionary):
			state = {}

		var lower := minf(controller.spot_value_minimum, controller.spot_value_maximum)
		var upper := maxf(controller.spot_value_minimum, controller.spot_value_maximum)
		var previous_schema_version := int(state.get("meal_schema_version", 0))
		var previous_stage := _normalize_meal_cycle_stage(String(
			state.get("stage", MEAL_STAGE_PREP_WORK)
		))
		var food_spot_id := _get_meal_cycle_food_spot_id(controller)
		var food_spot_ids := _get_meal_cycle_food_spot_ids(controller)
		var existing_food_state = runtime.spot_runtime_states.get(String(food_spot_id), {})
		var legacy_food_value := 0.0
		var legacy_food_limit := 0.0
		if existing_food_state is Dictionary:
			legacy_food_value = float(existing_food_state.get("value", 0.0))
			legacy_food_limit = float(existing_food_state.get("maximum", legacy_food_value))

		state["kind"] = "meal_cycle"
		state["meal_cycle_enabled"] = true
		state["meal_cycle_id"] = String(controller.meal_cycle_id)
		state["food_spot_id"] = String(food_spot_id)
		state["food_spot_ids"] = _string_names_to_strings(food_spot_ids, [])
		state["meal_schema_version"] = MEAL_SCHEMA_VERSION
		state["minimum"] = lower
		state["maximum"] = upper
		state["done_threshold"] = controller.spot_value_done_threshold
		state["daily_growth"] = 0.0
		state["value"] = clampf(
			float(state.get("value", controller.spot_value_initial)),
			lower,
			upper
		)
		state["stage"] = previous_stage
		state["meal"] = String(state.get("meal", ""))
		state["work_call_active"] = bool(state.get("work_call_active", false))
		state["meal_called"] = bool(state.get("meal_called", false))
		state["meal_window_open"] = bool(state.get(
			"meal_window_open",
			state.get("meal_called", false)
		))
		if (
			bool(state["meal_window_open"])
			and String(state.get("last_food_call_meal", "")).is_empty()
		):
			state["last_food_call_meal"] = String(state["meal"])
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
		state["food_owner_ids"] = _get_meal_cycle_food_owner_ids_for_meal(
			runtime,
			controller,
			String(state["meal"])
		)
		state["cleanup_owner_ids"] = _string_names_to_strings(
			controller.meal_cycle_cleanup_owner_ids,
			[]
		)
		state["cleanup_work_multiplier"] = controller.get_meal_cycle_work_multiplier_for_stage(
			MEAL_STAGE_CLEANUP_WORK
		)
		state["ingredient_storage_infinite"] = (
			controller.meal_cycle_infinite_ingredient_storage
		)
		state["ingredient_storage_batches_per_prep"] = (
			controller.meal_cycle_storage_batches_per_prep
			if controller.meal_cycle_infinite_ingredient_storage
			else 0
		)

		var owner_meal_data = state.get("owner_meal_data", {})
		if not (owner_meal_data is Dictionary):
			owner_meal_data = {}
		state["owner_meal_data"] = owner_meal_data

		var ingredient_inventory := _load_meal_ingredient_inventory(runtime, controller, state)
		state["ingredient_inventory"] = ingredient_inventory.get_save_data()
		state["ingredient_reservation_id"] = String(state.get(
			"ingredient_reservation_id",
			_make_meal_ingredient_reservation_id(controller.spot_id)
		))
		state["reserved_recipe_batches"] = maxi(
			int(state.get("reserved_recipe_batches", 0)),
			0
		)
		state["waiting_for_ingredients"] = bool(state.get("waiting_for_ingredients", false))

		var configured_recipe := _get_valid_meal_cycle_recipe(runtime, controller)
		var batch_remaining := maxf(float(state.get("meal_batch_remaining_points", 0.0)), 0.0)
		var batch_total := maxf(float(state.get("meal_batch_total_points", 0.0)), batch_remaining)
		if previous_stage == MEAL_STAGE_FOOD and bool(state.get("food_available", false)):
			if previous_schema_version <= 0 or batch_remaining <= 0.0:
				batch_remaining = maxf(
					float(state.get("food_value", legacy_food_value)),
					legacy_food_value
				)
				batch_total = maxf(
					float(state.get("food_limit", legacy_food_limit)),
					batch_remaining
				)
		else:
			batch_remaining = 0.0
			batch_total = 0.0
		state["meal_batch_remaining_points"] = batch_remaining
		state["meal_batch_total_points"] = batch_total
		_initialize_meal_cycle_cleanup_remaining(runtime, controller, state, previous_stage)

		if configured_recipe != null and previous_stage == MEAL_STAGE_PREP_WORK:
			var reservation_is_valid := _recipe_preparation_reservation_is_valid(
				ingredient_inventory,
				configured_recipe,
				StringName(String(state["ingredient_reservation_id"])),
				int(state["reserved_recipe_batches"])
			)
			if reservation_is_valid:
				state["work_call_active"] = true
				state["waiting_for_ingredients"] = false
			elif not String(state.get("meal", "")).is_empty():
				_release_recipe_preparation_reservation(runtime, controller, state)
				state["value"] = _get_meal_cycle_reset_work_value(controller)
				state["work_call_active"] = false
				state["waiting_for_ingredients"] = true
				state.erase("pending_work_completion_total_hours")
				if controller.meal_cycle_infinite_ingredient_storage:
					_restock_infinite_ingredient_storage(runtime, controller, state)
					_attempt_activate_recipe_preparation(runtime, controller, state)
				else:
					_warn_meal_cycle_once(
						runtime,
						"legacy_prep_%s" % String(controller.spot_id),
						(
							"Meal cycle '%s' restored active preparation without a valid "
							+ "ingredient reservation; it was reset to wait for ingredients."
						) % String(controller.spot_id)
					)
		elif controller.meal_cycle_recipe == null:
			state["waiting_for_ingredients"] = false
			state["reserved_recipe_batches"] = 0
		elif configured_recipe == null:
			state["work_call_active"] = false
			state["waiting_for_ingredients"] = true
			state.erase("pending_work_completion_total_hours")

		runtime.spot_runtime_states[state_key] = state
		_sync_meal_cycle_food_state(runtime, controller, state)
		_sync_meal_cycle_cleanup_states(runtime, controller, state)


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
	_release_recipe_preparation_reservation(runtime, controller, state)
	state["stage"] = MEAL_STAGE_PREP_WORK
	state["meal"] = meal
	state["food_owner_ids"] = _get_meal_cycle_food_owner_ids_for_meal(
		runtime,
		controller,
		meal
	)
	state["value"] = _get_meal_cycle_reset_work_value(controller)
	state["meal_window_open"] = false
	state["meal_called"] = false
	state["food_available"] = false
	state["meal_batch_total_points"] = 0.0
	state["meal_batch_remaining_points"] = 0.0
	state["cleanup_remaining_by_spot"] = {}
	state["food_ready_total_hours"] = -1.0
	state["stage_started_total_hours"] = event_total_hours
	state["cleanup_work_multiplier"] = controller.get_meal_cycle_work_multiplier_for_stage(
		MEAL_STAGE_CLEANUP_WORK
	)
	state.erase("pending_work_completion_total_hours")
	if controller.meal_cycle_recipe == null:
		state["work_call_active"] = true
		state["waiting_for_ingredients"] = false
	else:
		state["work_call_active"] = false
		state["waiting_for_ingredients"] = true
		_restock_infinite_ingredient_storage(runtime, controller, state)
		_attempt_activate_recipe_preparation(runtime, controller, state)
	_refresh_meal_call_state(runtime, controller, state)
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
	state["last_food_call_total_hours"] = event_total_hours
	state["last_food_call_meal"] = meal
	state["meal_call_instance_id"] = "%s@%.6f" % [meal, event_total_hours]
	state["food_owner_ids"] = _get_meal_cycle_food_owner_ids_for_meal(
		runtime,
		controller,
		meal
	)
	if String(state.get("meal", "")) == meal:
		state["meal_window_open"] = true
	_refresh_meal_call_state(runtime, controller, state)

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
	_release_recipe_preparation_reservation(runtime, controller, state)
	state["stage"] = MEAL_STAGE_CLEANUP_WORK
	state["meal"] = meal
	state["value"] = _get_meal_cycle_reset_work_value(controller)
	state["work_call_active"] = true
	state["meal_window_open"] = false
	state["food_available"] = false
	state["meal_batch_total_points"] = 0.0
	state["meal_batch_remaining_points"] = 0.0
	state["food_ready_total_hours"] = -1.0
	state["stage_started_total_hours"] = event_total_hours
	_reset_meal_cycle_cleanup_remaining(runtime, controller, state)
	state.erase("pending_work_completion_total_hours")
	_refresh_meal_call_state(runtime, controller, state)
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
		if controller.meal_cycle_recipe != null:
			if not _complete_recipe_preparation(
				runtime,
				controller,
				state,
				completed_total_hours
			):
				_set_meal_cycle_controller_state(runtime, controller, state)
			return
		state["stage"] = MEAL_STAGE_FOOD
		state["value"] = float(state.get("done_threshold", controller.spot_value_done_threshold))
		state["work_call_active"] = false
		state["food_available"] = true
		state["meal_batch_total_points"] = 0.0
		state["meal_batch_remaining_points"] = 0.0
		state["food_ready_total_hours"] = completed_total_hours
		state["stage_started_total_hours"] = completed_total_hours
		_refresh_meal_call_state(runtime, controller, state)
		_set_meal_cycle_controller_state(runtime, controller, state)
		return

	if stage == MEAL_STAGE_CLEANUP_WORK:
		if float(state.get("value", 0.0)) > float(state.get("done_threshold", 0.0)):
			_set_meal_cycle_controller_state(runtime, controller, state)
			return
		state["stage"] = MEAL_STAGE_PREP_WORK
		state["meal"] = ""
		state["value"] = _get_meal_cycle_reset_work_value(controller)
		state["work_call_active"] = false
		state["waiting_for_ingredients"] = false
		state["meal_window_open"] = false
		state["food_available"] = false
		state["meal_batch_total_points"] = 0.0
		state["meal_batch_remaining_points"] = 0.0
		state["cleanup_remaining_by_spot"] = {}
		state["food_ready_total_hours"] = -1.0
		state["stage_started_total_hours"] = completed_total_hours
		_refresh_meal_call_state(runtime, controller, state)
		_set_meal_cycle_controller_state(runtime, controller, state)
		return

	_set_meal_cycle_controller_state(runtime, controller, state)


static func _apply_meal_cycle_work_progress(
	runtime,
	definition: NpcSpotDefinition,
	game_hours: float,
	total_hours: float
) -> void:
	var controller_id := _get_meal_cycle_controller_id_for_definition(runtime, definition)
	var controller := runtime.spot_definitions.get(controller_id, null) as NpcSpotDefinition
	if controller == null:
		return
	var state := _get_meal_cycle_controller_state(runtime, controller_id)
	if state.is_empty():
		return

	var stage := String(state.get("stage", MEAL_STAGE_PREP_WORK))
	if stage == MEAL_STAGE_CLEANUP_WORK:
		var cleanup_remaining := _get_cleanup_remaining_by_spot(runtime, controller, state)
		var spot_key := String(definition.spot_id)
		if not cleanup_remaining.has(spot_key):
			return
		var previous_local_value := float(cleanup_remaining.get(spot_key, 0.0))
		if previous_local_value <= MEAL_CYCLE_EPSILON:
			return
		var requested_cleanup_delta := (
			definition.spot_value_delta_per_game_hour
			* game_hours
			* controller.get_meal_cycle_work_multiplier_for_stage(stage)
		)
		if requested_cleanup_delta >= 0.0:
			return
		var aggregate_before := _sum_cleanup_remaining(cleanup_remaining)
		var actual_cleanup_delta := maxf(
			requested_cleanup_delta,
			-previous_local_value
		)
		if (
			total_hours >= 0.0
			and aggregate_before + actual_cleanup_delta <= MEAL_CYCLE_EPSILON
		):
			var cleanup_fraction := clampf(
				previous_local_value / maxf(absf(requested_cleanup_delta), 0.001),
				0.0,
				1.0
			)
			state["pending_work_completion_total_hours"] = maxf(
				total_hours - game_hours + game_hours * cleanup_fraction,
				0.0
			)
			runtime.spot_runtime_states[String(controller_id)] = state
		_set_meal_cycle_cleanup_spot_value(
			runtime,
			definition.spot_id,
			previous_local_value + requested_cleanup_delta
		)
		return

	if stage != MEAL_STAGE_PREP_WORK or definition.spot_id != controller_id:
		return

	var previous_value := float(state.get("value", controller.spot_value_initial))
	if (
		stage == MEAL_STAGE_PREP_WORK
		and controller.meal_cycle_recipe != null
		and not _active_recipe_preparation_is_valid(runtime, controller, state)
	):
		_set_recipe_preparation_waiting(runtime, controller, state)
		_set_meal_cycle_controller_state(runtime, controller, state)
		return
	var requested_delta := (
		definition.spot_value_delta_per_game_hour
		* game_hours
		* definition.get_meal_cycle_work_multiplier_for_stage(stage)
	)
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

	runtime.apply_spot_value_delta(controller_id, requested_delta)


static func _set_meal_cycle_controller_state(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> void:
	runtime.spot_runtime_states[String(controller.spot_id)] = state
	_sync_meal_cycle_food_state(runtime, controller, state)
	_sync_meal_cycle_cleanup_states(runtime, controller, state)
	var controller_live_value := float(state.get("value", controller.spot_value_initial))
	if String(state.get("stage", "")) == MEAL_STAGE_CLEANUP_WORK:
		var cleanup_remaining = state.get("cleanup_remaining_by_spot", {})
		if cleanup_remaining is Dictionary:
			controller_live_value = float(cleanup_remaining.get(
				String(controller.spot_id),
				controller_live_value
			))
	runtime._notify_live_spot_value(controller.spot_id, controller_live_value)
	_notify_meal_cycle_state(runtime, controller.spot_id)


static func _refresh_meal_call_state(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> void:
	var was_called := bool(state.get("meal_called", false))
	var current_meal := String(state.get("meal", ""))
	var should_call := (
		String(state.get("stage", "")) == MEAL_STAGE_FOOD
		and bool(state.get("food_available", false))
		and bool(state.get("meal_window_open", false))
		and not current_meal.is_empty()
		and String(state.get("last_food_call_meal", "")) == current_meal
	)
	state["meal_called"] = should_call
	if should_call and not was_called:
		_record_meal_owner_call_flags(
			state,
			current_meal,
			String(state.get("meal_call_instance_id", ""))
		)


static func _sync_meal_cycle_food_state(
	runtime,
	controller: NpcSpotDefinition,
	controller_state: Dictionary
) -> void:
	var food_spot_ids := _get_meal_cycle_food_spot_ids(controller)
	if food_spot_ids.is_empty():
		return

	var food_spot_id := food_spot_ids[0]
	var food_definition := runtime.spot_definitions.get(food_spot_id, null) as NpcSpotDefinition
	var canonical_food_state = runtime.spot_runtime_states.get(String(food_spot_id), {})
	if not (canonical_food_state is Dictionary):
		canonical_food_state = {}

	var lower := 0.0
	var upper := 1.0
	var done_threshold := 0.0
	if food_definition != null:
		lower = minf(food_definition.spot_value_minimum, food_definition.spot_value_maximum)
		upper = maxf(food_definition.spot_value_minimum, food_definition.spot_value_maximum)
		done_threshold = food_definition.spot_value_done_threshold

	var food_is_available: bool = (
		String(controller_state.get("stage", "")) == MEAL_STAGE_FOOD
		and bool(controller_state.get("food_available", false))
	)
	var stage_started_total_hours := float(
		controller_state.get("stage_started_total_hours", -1.0)
	)
	var next_value := lower
	var dynamic_upper := upper
	if controller.meal_cycle_recipe != null:
		dynamic_upper = maxf(
			float(controller_state.get("meal_batch_total_points", 0.0)),
			lower
		)
		next_value = clampf(
			float(controller_state.get("meal_batch_remaining_points", 0.0)),
			lower,
			dynamic_upper
		)
	else:
		var previous_stage_started_total_hours := float(canonical_food_state.get(
			"meal_cycle_stage_started_total_hours",
			-1.0
		))
		var previous_active := bool(canonical_food_state.get("meal_cycle_food_active", false))
		var should_reset_food := (
			food_is_available
			and (
				not previous_active
				or not is_equal_approx(
					previous_stage_started_total_hours,
					stage_started_total_hours
				)
			)
		)
		if food_is_available:
			if should_reset_food:
				next_value = upper
			else:
				next_value = clampf(float(canonical_food_state.get("value", upper)), lower, upper)
	if food_is_available:
		food_is_available = next_value > done_threshold
	if not food_is_available:
		next_value = lower

	controller_state["food_available"] = food_is_available
	controller_state["food_value"] = next_value
	controller_state["food_limit"] = dynamic_upper
	controller_state["food_spot_id"] = String(food_spot_id)
	controller_state["food_spot_ids"] = _string_names_to_strings(food_spot_ids, [])
	if controller.meal_cycle_recipe != null:
		controller_state["meal_batch_remaining_points"] = next_value
	_refresh_meal_call_state(runtime, controller, controller_state)
	runtime.spot_runtime_states[String(controller.spot_id)] = controller_state

	for configured_food_spot_id in food_spot_ids:
		var configured_definition := runtime.spot_definitions.get(
			configured_food_spot_id,
			null
		) as NpcSpotDefinition
		if configured_definition == null:
			continue
		var configured_lower := minf(
			configured_definition.spot_value_minimum,
			configured_definition.spot_value_maximum
		)
		var configured_done_threshold := configured_definition.spot_value_done_threshold
		var food_key := String(configured_food_spot_id)
		var food_state = runtime.spot_runtime_states.get(food_key, {})
		if not (food_state is Dictionary):
			food_state = {}
		food_state["kind"] = "food_available"
		food_state["meal_cycle_controller_id"] = String(controller.spot_id)
		food_state["meal_cycle_id"] = String(controller.meal_cycle_id)
		food_state["minimum"] = configured_lower
		food_state["maximum"] = dynamic_upper
		food_state["done_threshold"] = configured_done_threshold
		food_state["daily_growth"] = 0.0
		food_state["value"] = clampf(next_value, configured_lower, dynamic_upper)
		food_state["meal_cycle_food_active"] = (
			food_is_available and next_value > configured_done_threshold
		)
		food_state["meal_cycle_stage_started_total_hours"] = stage_started_total_hours
		runtime.spot_runtime_states[food_key] = food_state
		runtime._notify_live_spot_value(
			configured_food_spot_id,
			float(food_state["value"])
		)


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

	_release_recipe_preparation_reservation(runtime, controller, state)
	state["stage"] = MEAL_STAGE_CLEANUP_WORK
	state["value"] = _get_meal_cycle_reset_work_value(controller)
	state["work_call_active"] = true
	state["meal_window_open"] = false
	state["food_available"] = false
	state["meal_batch_total_points"] = 0.0
	state["meal_batch_remaining_points"] = 0.0
	state["food_ready_total_hours"] = -1.0
	state["stage_started_total_hours"] = runtime._get_current_total_hours()
	_reset_meal_cycle_cleanup_remaining(runtime, controller, state)
	state["cleanup_work_multiplier"] = controller.get_meal_cycle_work_multiplier_for_stage(
		MEAL_STAGE_CLEANUP_WORK
	)
	state.erase("pending_work_completion_total_hours")
	_refresh_meal_call_state(runtime, controller, state)
	_set_meal_cycle_controller_state(runtime, controller, state)


static func _apply_meal_cycle_food_value_changed(
	runtime,
	food_spot_id: StringName,
	remaining_points: float
) -> void:
	var controller_id := _get_meal_cycle_controller_id_for_spot(runtime, food_spot_id)
	if controller_id == &"":
		return
	var controller := runtime.spot_definitions.get(controller_id, null) as NpcSpotDefinition
	if controller == null:
		return
	var state := _get_meal_cycle_controller_state(runtime, controller_id)
	if state.is_empty() or String(state.get("stage", "")) != MEAL_STAGE_FOOD:
		return
	var food_definition := runtime.spot_definitions.get(food_spot_id, null) as NpcSpotDefinition
	var done_threshold := (
		food_definition.spot_value_done_threshold if food_definition != null else 0.0
	)
	state["meal_batch_remaining_points"] = maxf(remaining_points, 0.0)
	state["food_value"] = maxf(remaining_points, 0.0)
	state["food_available"] = remaining_points > done_threshold
	_refresh_meal_call_state(runtime, controller, state)
	if not bool(state["food_available"]):
		_deplete_meal_cycle_food(runtime, food_spot_id)
		return
	_set_meal_cycle_controller_state(runtime, controller, state)


static func _set_meal_cycle_cleanup_spot_value(
	runtime,
	cleanup_spot_id: StringName,
	requested_value: float
) -> void:
	var controller_id := _get_meal_cycle_controller_id_for_spot(runtime, cleanup_spot_id)
	var controller := runtime.spot_definitions.get(controller_id, null) as NpcSpotDefinition
	if controller == null:
		return
	var state := _get_meal_cycle_controller_state(runtime, controller_id)
	if state.is_empty() or String(state.get("stage", "")) != MEAL_STAGE_CLEANUP_WORK:
		return

	var cleanup_remaining := _get_cleanup_remaining_by_spot(runtime, controller, state)
	var cleanup_capacities := _get_meal_cycle_cleanup_capacities(runtime, controller)
	var spot_key := String(cleanup_spot_id)
	if not cleanup_remaining.has(spot_key) or not cleanup_capacities.has(spot_key):
		return
	cleanup_remaining[spot_key] = clampf(
		requested_value,
		0.0,
		float(cleanup_capacities[spot_key])
	)
	state["cleanup_remaining_by_spot"] = cleanup_remaining
	state["value"] = _sum_cleanup_remaining(cleanup_remaining)
	runtime.spot_runtime_states[String(controller_id)] = state
	if float(state["value"]) <= float(state.get("done_threshold", 0.0)):
		_advance_meal_cycle_work_complete(runtime, controller_id)
		return
	_set_meal_cycle_controller_state(runtime, controller, state)


static func _initialize_meal_cycle_cleanup_remaining(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary,
	stage: String
) -> void:
	if stage != MEAL_STAGE_CLEANUP_WORK:
		state["cleanup_remaining_by_spot"] = {}
		return

	var capacities := _get_meal_cycle_cleanup_capacities(runtime, controller)
	var stored_remaining = state.get("cleanup_remaining_by_spot", {})
	var stored_is_complete := stored_remaining is Dictionary
	if stored_is_complete:
		for spot_key in capacities.keys():
			if not stored_remaining.has(spot_key):
				stored_is_complete = false
				break

	var normalized: Dictionary = {}
	if stored_is_complete:
		for spot_key in capacities.keys():
			normalized[spot_key] = clampf(
				float(stored_remaining.get(spot_key, 0.0)),
				0.0,
				float(capacities[spot_key])
			)
	else:
		var legacy_total := clampf(
			float(state.get("value", _get_meal_cycle_reset_work_value(controller))),
			0.0,
			_sum_cleanup_remaining(capacities)
		)
		var capacity_total := _sum_cleanup_remaining(capacities)
		for spot_key in capacities.keys():
			normalized[spot_key] = (
				legacy_total * float(capacities[spot_key]) / capacity_total
				if capacity_total > MEAL_CYCLE_EPSILON
				else 0.0
			)

	state["cleanup_remaining_by_spot"] = normalized
	state["value"] = _sum_cleanup_remaining(normalized)


static func _reset_meal_cycle_cleanup_remaining(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> void:
	var capacities := _get_meal_cycle_cleanup_capacities(runtime, controller)
	state["cleanup_remaining_by_spot"] = capacities.duplicate(true)
	state["value"] = _sum_cleanup_remaining(capacities)


static func _get_cleanup_remaining_by_spot(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> Dictionary:
	var remaining = state.get("cleanup_remaining_by_spot", {})
	if remaining is Dictionary and not remaining.is_empty():
		return remaining.duplicate(true)
	_initialize_meal_cycle_cleanup_remaining(
		runtime,
		controller,
		state,
		MEAL_STAGE_CLEANUP_WORK
	)
	return state.get("cleanup_remaining_by_spot", {}).duplicate(true)


static func _get_meal_cycle_cleanup_capacities(
	runtime,
	controller: NpcSpotDefinition
) -> Dictionary:
	var cleanup_spot_ids := _get_meal_cycle_cleanup_spot_ids(controller)
	var capacities: Dictionary = {}
	var unconfigured_ids: Array[StringName] = []
	var configured_total := 0.0
	for cleanup_spot_id in cleanup_spot_ids:
		var definition := runtime.spot_definitions.get(
			cleanup_spot_id,
			null
		) as NpcSpotDefinition
		if definition == null:
			continue
		var configured_share := maxf(definition.meal_cycle_cleanup_share, 0.0)
		if configured_share > MEAL_CYCLE_EPSILON:
			capacities[String(cleanup_spot_id)] = configured_share
			configured_total += configured_share
		else:
			unconfigured_ids.append(cleanup_spot_id)

	var reset_total := _get_meal_cycle_reset_work_value(controller)
	if capacities.is_empty() and unconfigured_ids.is_empty():
		capacities[String(controller.spot_id)] = reset_total
		return capacities
	if not unconfigured_ids.is_empty():
		var unconfigured_share := maxf(reset_total - configured_total, 0.0) / float(
			unconfigured_ids.size()
		)
		for cleanup_spot_id in unconfigured_ids:
			capacities[String(cleanup_spot_id)] = unconfigured_share
	return capacities


static func _sum_cleanup_remaining(values: Dictionary) -> float:
	var total := 0.0
	for value in values.values():
		total += maxf(float(value), 0.0)
	return total


static func _sync_meal_cycle_cleanup_states(
	runtime,
	controller: NpcSpotDefinition,
	controller_state: Dictionary
) -> void:
	var capacities := _get_meal_cycle_cleanup_capacities(runtime, controller)
	var remaining: Dictionary = {}
	if String(controller_state.get("stage", "")) == MEAL_STAGE_CLEANUP_WORK:
		remaining = _get_cleanup_remaining_by_spot(runtime, controller, controller_state)
	controller_state["cleanup_spot_ids"] = _string_names_to_strings(
		_get_meal_cycle_cleanup_spot_ids(controller),
		[]
	)
	controller_state["cleanup_remaining_by_spot"] = remaining
	runtime.spot_runtime_states[String(controller.spot_id)] = controller_state

	for spot_key in capacities.keys():
		var cleanup_spot_id := StringName(String(spot_key))
		if cleanup_spot_id == controller.spot_id:
			continue
		var cleanup_state = runtime.spot_runtime_states.get(spot_key, {})
		if not (cleanup_state is Dictionary):
			cleanup_state = {}
		cleanup_state["kind"] = "meal_cleanup_contribution"
		cleanup_state["meal_cycle_controller_id"] = String(controller.spot_id)
		cleanup_state["meal_cycle_id"] = String(controller.meal_cycle_id)
		cleanup_state["minimum"] = 0.0
		cleanup_state["maximum"] = float(capacities[spot_key])
		cleanup_state["done_threshold"] = 0.0
		cleanup_state["daily_growth"] = 0.0
		cleanup_state["value"] = float(remaining.get(spot_key, 0.0))
		runtime.spot_runtime_states[spot_key] = cleanup_state
		runtime._notify_live_spot_value(cleanup_spot_id, float(cleanup_state["value"]))


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

	var linked_spot_ids: Array[StringName] = []
	for raw_spot_id in state.get("food_spot_ids", []):
		var linked_id := StringName(String(raw_spot_id))
		if linked_id != &"" and not linked_spot_ids.has(linked_id):
			linked_spot_ids.append(linked_id)
	for raw_spot_id in state.get("cleanup_spot_ids", []):
		var linked_id := StringName(String(raw_spot_id))
		if linked_id != &"" and not linked_spot_ids.has(linked_id):
			linked_spot_ids.append(linked_id)
	var legacy_food_spot_id := StringName(String(state.get("food_spot_id", "")))
	if legacy_food_spot_id != &"" and not linked_spot_ids.has(legacy_food_spot_id):
		linked_spot_ids.append(legacy_food_spot_id)

	for linked_spot_id in linked_spot_ids:
		var linked_spot := runtime.live_spots.get(linked_spot_id, null) as Node
		if (
			linked_spot != null
			and is_instance_valid(linked_spot)
			and not notified_spots.has(linked_spot)
		):
			_notify_live_spot_meal_cycle_state(linked_spot, controller_spot_id, state)
			notified_spots.append(linked_spot)


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
			definition.allows_npc_id(npc_id)
			and _meal_cycle_owner_allows(state, MEAL_OWNER_FOOD, npc_id)
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
			and bool(state.get("meal_window_open", false))
			and bool(state.get("meal_called", false))
			and food_value > definition.spot_value_done_threshold
		)

	var stage := String(state.get("stage", ""))
	if stage == MEAL_STAGE_CLEANUP_WORK:
		var cleanup_remaining = state.get("cleanup_remaining_by_spot", {})
		return (
			cleanup_remaining is Dictionary
			and float(cleanup_remaining.get(String(definition.spot_id), 0.0))
				> definition.spot_value_done_threshold
			and bool(state.get("work_call_active", false))
		)
	if not _definition_is_meal_cycle_controller(definition):
		return false
	if stage != MEAL_STAGE_PREP_WORK:
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
	var food_limit := maxf(float(
		enriched_state.get("meal_batch_total_points", fallback_limit)
	), 0.0)
	if food_limit <= 0.0:
		food_limit = fallback_limit
	var food_value := (
		float(enriched_state.get("meal_batch_remaining_points", food_limit))
		if bool(enriched_state.get("food_available", false))
		else 0.0
	)
	if food_state is Dictionary:
		food_value = float(food_state.get("value", food_value))
		food_limit = float(food_state.get("maximum", food_limit))

	enriched_state["food_value"] = food_value
	enriched_state["food_limit"] = food_limit
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


static func _record_meal_owner_call_flags(
	state: Dictionary,
	meal: String,
	call_instance_id: String = ""
) -> void:
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
		if (
			not call_instance_id.is_empty()
			and String(meal_data.get("meal_call_instance_id", "")) == call_instance_id
		):
			continue
		meal_data[_get_has_had_meal_key(meal)] = false
		meal_data[_get_needs_meal_key(meal)] = true
		meal_data["called_for_meal"] = meal
		if not call_instance_id.is_empty():
			meal_data["meal_call_instance_id"] = call_instance_id
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


static func _get_valid_meal_cycle_recipe(
	runtime,
	controller: NpcSpotDefinition
) -> ProcessingRecipeDefinition:
	if controller == null or controller.meal_cycle_recipe == null:
		return null
	var catalog := ItemCatalog.new()
	if not catalog.load_definitions():
		_warn_meal_cycle_once(
			runtime,
			"catalog_%s" % String(controller.spot_id),
			"Meal cycle '%s' cannot use its recipe because the item catalog is invalid: %s"
			% [
				String(controller.spot_id),
				"; ".join(catalog.get_validation_errors()),
			]
		)
		return null
	var errors := controller.meal_cycle_recipe.validate(catalog)
	var edible_output_found := false
	for raw_item_id: Variant in controller.meal_cycle_recipe.output_items:
		var item_id := StringName(String(raw_item_id).strip_edges())
		var raw_quantity: Variant = controller.meal_cycle_recipe.output_items[raw_item_id]
		if (
			typeof(raw_quantity) == TYPE_INT
			and int(raw_quantity) > 0
			and catalog.get_food_value(item_id) > 0.0
		):
			edible_output_found = true
			break
	if not edible_output_found:
		errors.append("Recipe must produce edible output with a positive hunger value.")
	if not errors.is_empty():
		_warn_meal_cycle_once(
			runtime,
			"recipe_%s" % String(controller.spot_id),
			"Meal cycle '%s' has an invalid recipe and was disabled: %s"
			% [String(controller.spot_id), "; ".join(errors)]
		)
		return null
	return controller.meal_cycle_recipe


static func _load_meal_ingredient_inventory(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> InventoryModel:
	var inventory := InventoryModel.new()
	var save_value = state.get("ingredient_inventory", InventoryModel.get_empty_save_data())
	if not (save_value is Dictionary):
		save_value = InventoryModel.get_empty_save_data()
	var result := inventory.apply_save_data(save_value)
	if result.success:
		return inventory
	_warn_meal_cycle_once(
		runtime,
		"pantry_%s" % String(controller.spot_id),
		"Meal cycle '%s' had invalid ingredient inventory data; an empty pantry was restored: %s"
		% [String(controller.spot_id), result.message]
	)
	inventory.apply_save_data(InventoryModel.get_empty_save_data())
	return inventory


static func _restock_infinite_ingredient_storage(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> bool:
	if controller == null or not controller.meal_cycle_infinite_ingredient_storage:
		return false
	var recipe := _get_valid_meal_cycle_recipe(runtime, controller)
	if recipe == null:
		return false
	var batch_count := controller.meal_cycle_storage_batches_per_prep
	var requested_inputs := _get_recipe_inputs_for_batches(recipe, batch_count)
	if requested_inputs.is_empty():
		return false

	var inventory := InventoryModel.new()
	for raw_item_id: Variant in requested_inputs:
		var item_id := StringName(String(raw_item_id))
		var add_result := inventory.add(item_id, int(requested_inputs[raw_item_id]))
		if not add_result.success:
			_warn_meal_cycle_once(
				runtime,
				"storage_restock_%s" % String(controller.spot_id),
				"Meal cycle '%s' could not restock its configured ingredient storage: %s"
				% [String(controller.spot_id), add_result.message]
			)
			return false

	state["ingredient_inventory"] = inventory.get_save_data()
	return true


static func _make_meal_ingredient_reservation_id(controller_spot_id: StringName) -> StringName:
	return StringName("meal_cycle_prep:%s" % String(controller_spot_id))


static func _get_recipe_inputs_for_batches(
	recipe: ProcessingRecipeDefinition,
	batch_count: int
) -> Dictionary:
	if recipe == null or batch_count <= 0:
		return {}
	var requested: Dictionary = {}
	for raw_item_id: Variant in recipe.input_items:
		var item_key := String(raw_item_id).strip_edges()
		var raw_quantity: Variant = recipe.input_items[raw_item_id]
		if item_key.is_empty() or typeof(raw_quantity) != TYPE_INT or int(raw_quantity) <= 0:
			return {}
		var per_batch := int(raw_quantity)
		if batch_count > 9223372036854775807 / per_batch:
			return {}
		requested[item_key] = per_batch * batch_count
	return requested


static func _recipe_preparation_reservation_is_valid(
	inventory: InventoryModel,
	recipe: ProcessingRecipeDefinition,
	reservation_id: StringName,
	batch_count: int
) -> bool:
	if (
		inventory == null
		or recipe == null
		or reservation_id == &""
		or batch_count <= 0
		or not inventory.has_reservation(reservation_id)
	):
		return false
	var expected := _get_recipe_inputs_for_batches(recipe, batch_count)
	if expected.is_empty():
		return false
	var actual := inventory.get_reservation(reservation_id)
	if actual.size() != expected.size():
		return false
	for item_key: String in expected:
		if int(actual.get(item_key, 0)) != int(expected[item_key]):
			return false
	return true


static func _active_recipe_preparation_is_valid(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> bool:
	if not bool(state.get("work_call_active", false)):
		return false
	var recipe := _get_valid_meal_cycle_recipe(runtime, controller)
	if recipe == null:
		return false
	var inventory := _load_meal_ingredient_inventory(runtime, controller, state)
	return _recipe_preparation_reservation_is_valid(
		inventory,
		recipe,
		StringName(String(state.get("ingredient_reservation_id", ""))),
		int(state.get("reserved_recipe_batches", 0))
	)


static func _release_recipe_preparation_reservation(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> void:
	if controller == null or controller.meal_cycle_recipe == null:
		state["reserved_recipe_batches"] = 0
		return
	var inventory := _load_meal_ingredient_inventory(runtime, controller, state)
	var configured_id := _make_meal_ingredient_reservation_id(controller.spot_id)
	var stored_id := StringName(String(state.get("ingredient_reservation_id", configured_id)))
	for reservation_id: StringName in [stored_id, configured_id]:
		if reservation_id != &"" and inventory.has_reservation(reservation_id):
			inventory.release_reservation(reservation_id)
	state["ingredient_inventory"] = inventory.get_save_data()
	state["ingredient_reservation_id"] = String(configured_id)
	state["reserved_recipe_batches"] = 0


static func _attempt_activate_recipe_preparation(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> bool:
	if controller == null or controller.meal_cycle_recipe == null:
		return false
	var recipe := _get_valid_meal_cycle_recipe(runtime, controller)
	if recipe == null:
		state["work_call_active"] = false
		state["waiting_for_ingredients"] = true
		return false
	var inventory := _load_meal_ingredient_inventory(runtime, controller, state)
	var reservation_id := _make_meal_ingredient_reservation_id(controller.spot_id)
	var stored_id := StringName(String(state.get("ingredient_reservation_id", reservation_id)))
	if inventory.has_reservation(stored_id):
		inventory.release_reservation(stored_id)
	if stored_id != reservation_id and inventory.has_reservation(reservation_id):
		inventory.release_reservation(reservation_id)
	var processing_service := InventoryProcessingService.new()
	var batch_count := processing_service.get_maximum_batches(inventory, recipe)
	state["ingredient_reservation_id"] = String(reservation_id)
	state["reserved_recipe_batches"] = 0
	state["ingredient_inventory"] = inventory.get_save_data()
	if batch_count <= 0:
		state["work_call_active"] = false
		state["waiting_for_ingredients"] = true
		return false
	var requested_inputs := _get_recipe_inputs_for_batches(recipe, batch_count)
	var reserve_result := inventory.reserve_items(reservation_id, requested_inputs)
	if not reserve_result.success:
		_warn_meal_cycle_once(
			runtime,
			"reserve_%s" % String(controller.spot_id),
			"Meal cycle '%s' could not reserve preparation ingredients: %s"
			% [String(controller.spot_id), reserve_result.message]
		)
		state["work_call_active"] = false
		state["waiting_for_ingredients"] = true
		state["ingredient_inventory"] = inventory.get_save_data()
		return false
	state["ingredient_inventory"] = inventory.get_save_data()
	state["reserved_recipe_batches"] = batch_count
	state["work_call_active"] = true
	state["waiting_for_ingredients"] = false
	return true


static func _set_recipe_preparation_waiting(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary
) -> void:
	_release_recipe_preparation_reservation(runtime, controller, state)
	state["stage"] = MEAL_STAGE_PREP_WORK
	state["value"] = _get_meal_cycle_reset_work_value(controller)
	state["work_call_active"] = false
	state["waiting_for_ingredients"] = true
	state.erase("pending_work_completion_total_hours")


static func _get_recipe_meal_points(
	runtime,
	controller: NpcSpotDefinition,
	recipe: ProcessingRecipeDefinition,
	batch_count: int
) -> float:
	if recipe == null or batch_count <= 0:
		return 0.0
	var catalog := ItemCatalog.new()
	if not catalog.load_definitions():
		return 0.0
	var total_points := 0.0
	for raw_item_id: Variant in recipe.output_items:
		var item_id := StringName(String(raw_item_id).strip_edges())
		var raw_quantity: Variant = recipe.output_items[raw_item_id]
		if typeof(raw_quantity) != TYPE_INT or int(raw_quantity) <= 0:
			continue
		total_points += (
			catalog.get_food_value(item_id)
			* float(int(raw_quantity))
			* float(batch_count)
		)
	if total_points <= 0.0:
		_warn_meal_cycle_once(
			runtime,
			"points_%s" % String(controller.spot_id),
			"Meal cycle '%s' recipe completion produced no edible meal points."
			% String(controller.spot_id)
		)
	return total_points


static func _complete_recipe_preparation(
	runtime,
	controller: NpcSpotDefinition,
	state: Dictionary,
	completed_total_hours: float
) -> bool:
	var recipe := _get_valid_meal_cycle_recipe(runtime, controller)
	var inventory := _load_meal_ingredient_inventory(runtime, controller, state)
	var reservation_id := StringName(String(state.get("ingredient_reservation_id", "")))
	var batch_count := int(state.get("reserved_recipe_batches", 0))
	if (
		recipe == null
		or not _recipe_preparation_reservation_is_valid(
			inventory,
			recipe,
			reservation_id,
			batch_count
		)
	):
		_warn_meal_cycle_once(
			runtime,
			"complete_reservation_%s" % String(controller.spot_id),
			(
				"Meal cycle '%s' preparation completed without a valid ingredient "
				+ "reservation; no food was created."
			) % String(controller.spot_id)
		)
		_set_recipe_preparation_waiting(runtime, controller, state)
		return false
	var meal_points := _get_recipe_meal_points(
		runtime,
		controller,
		recipe,
		batch_count
	)
	if meal_points <= 0.0:
		_set_recipe_preparation_waiting(runtime, controller, state)
		return false
	var consume_result := inventory.consume_reservation(reservation_id)
	if not consume_result.success:
		_warn_meal_cycle_once(
			runtime,
			"consume_%s" % String(controller.spot_id),
			"Meal cycle '%s' could not consume its ingredient reservation: %s"
			% [String(controller.spot_id), consume_result.message]
		)
		state["ingredient_inventory"] = inventory.get_save_data()
		_set_recipe_preparation_waiting(runtime, controller, state)
		return false

	state["ingredient_inventory"] = inventory.get_save_data()
	state["reserved_recipe_batches"] = 0
	state["stage"] = MEAL_STAGE_FOOD
	state["value"] = float(state.get("done_threshold", controller.spot_value_done_threshold))
	state["work_call_active"] = false
	state["waiting_for_ingredients"] = false
	state["food_available"] = true
	state["meal_batch_total_points"] = meal_points
	state["meal_batch_remaining_points"] = meal_points
	state["food_ready_total_hours"] = completed_total_hours
	state["stage_started_total_hours"] = completed_total_hours
	_refresh_meal_call_state(runtime, controller, state)
	_set_meal_cycle_controller_state(runtime, controller, state)
	return true


static func _warn_meal_cycle_once(runtime, key: String, message: String) -> void:
	if runtime != null and runtime.has_method("_warn_reservation_once"):
		runtime.call("_warn_reservation_once", "meal_cycle:%s" % key, message)
		return
	push_warning(message)


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
		or _definition_is_meal_cycle_cleanup(definition)
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


static func _definition_is_meal_cycle_cleanup(definition: NpcSpotDefinition) -> bool:
	return (
		definition != null
		and definition.meal_cycle_id != &""
		and String(definition.meal_cycle_stage) == MEAL_STAGE_CLEANUP_WORK
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
	if definition.meal_cycle_controller_spot_id != &"":
		return definition.meal_cycle_controller_spot_id
	if not _definition_is_meal_cycle_food(definition) and not _definition_is_meal_cycle_cleanup(definition):
		return &""

	for controller in _get_meal_cycle_controller_definitions(runtime):
		if (
			controller.meal_cycle_id == definition.meal_cycle_id
			and (
				_get_meal_cycle_food_spot_ids(controller).has(definition.spot_id)
				or _get_meal_cycle_cleanup_spot_ids(controller).has(definition.spot_id)
			)
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


static func _get_meal_cycle_food_spot_ids(
	controller: NpcSpotDefinition
) -> Array[StringName]:
	var spot_ids: Array[StringName] = []
	if controller == null:
		return spot_ids
	if controller.meal_cycle_food_spot_id != &"":
		spot_ids.append(controller.meal_cycle_food_spot_id)
	for configured_id in controller.meal_cycle_food_spot_ids:
		if configured_id != &"" and not spot_ids.has(configured_id):
			spot_ids.append(configured_id)
	if spot_ids.is_empty() and controller.next_spot_id_when_done != &"":
		spot_ids.append(controller.next_spot_id_when_done)
	return spot_ids


static func _get_meal_cycle_cleanup_spot_ids(
	controller: NpcSpotDefinition
) -> Array[StringName]:
	var spot_ids: Array[StringName] = []
	if controller == null:
		return spot_ids
	for configured_id in controller.meal_cycle_cleanup_spot_ids:
		if configured_id != &"" and not spot_ids.has(configured_id):
			spot_ids.append(configured_id)
	if spot_ids.is_empty():
		spot_ids.append(controller.spot_id)
	elif not spot_ids.has(controller.spot_id):
		spot_ids.push_front(controller.spot_id)
	return spot_ids


static func _get_meal_cycle_food_definition_owner_ids(
	runtime,
	controller: NpcSpotDefinition
) -> Array[StringName]:
	var owner_ids: Array[StringName] = []
	for food_spot_id in _get_meal_cycle_food_spot_ids(controller):
		var food_definition := runtime.spot_definitions.get(
			food_spot_id,
			null
		) as NpcSpotDefinition
		if food_definition == null:
			continue
		for owner_id in food_definition.get_owner_ids():
			if not owner_ids.has(owner_id):
				owner_ids.append(owner_id)
	if not owner_ids.is_empty():
		return owner_ids
	return controller.get_owner_ids()


static func _get_meal_cycle_food_owner_ids_for_meal(
	runtime,
	controller: NpcSpotDefinition,
	meal: String
) -> Array[String]:
	var fallback_values: Array = controller.meal_cycle_food_owner_ids
	if fallback_values.is_empty():
		fallback_values = _get_meal_cycle_food_definition_owner_ids(runtime, controller)
	for schedule_value in controller.meal_cycle_schedule:
		if not (schedule_value is Dictionary):
			continue
		var schedule: Dictionary = schedule_value
		if String(schedule.get("meal", "")) != meal:
			continue
		var configured_values = schedule.get("food_owner_ids", [])
		if configured_values is Array and not configured_values.is_empty():
			return _string_names_to_strings(configured_values, fallback_values)
	return _string_names_to_strings(fallback_values, [])


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
