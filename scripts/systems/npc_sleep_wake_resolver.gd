class_name NpcSleepWakeResolver
extends RefCounted

const NpcRouteLocationCoordinator = preload(
	"res://scripts/systems/npc_route_location_coordinator.gd"
)


static func finalize_sleep_skip_record(
	npc_id: String,
	record: Dictionary,
	start_total_hours: float,
	end_total_hours: float,
	runtime
) -> bool:
	record["last_simulated_total_hours"] = end_total_hours
	var slept_during_skip := clear_sleep_activity_after_skip(record, runtime)
	if not slept_during_skip:
		slept_during_skip = move_record_to_sleep_definition_for_skip(
			npc_id,
			record,
			start_total_hours,
			end_total_hours,
			runtime
		)
	if slept_during_skip:
		record["skip_next_activity_start_after_sleep"] = true
	return slept_during_skip


static func clear_sleep_activity_after_skip(record: Dictionary, runtime) -> bool:
	var moved_to_sleep_wake_destination := false
	var activity = record.get("activity", {})
	if activity is Dictionary and String(activity.get("state_name", "")) == "Sleep":
		moved_to_sleep_wake_destination = move_record_to_sleep_skip_wake_destination(
			record,
			activity,
			runtime
		)
		record["activity"] = {}
		NpcRouteLocationCoordinator.clear_finish_replan_marker(record)

	var pending = record.get("pending_travel", {})
	if not (pending is Dictionary) or pending.is_empty():
		return moved_to_sleep_wake_destination
	if String(pending.get("requested_state_name", "")) == "Sleep":
		moved_to_sleep_wake_destination = move_record_to_sleep_skip_wake_destination(
			record,
			get_sleep_activity_from_pending(pending),
			runtime
		) or moved_to_sleep_wake_destination
		record["pending_travel"] = {}
		return moved_to_sleep_wake_destination

	var pending_activity = pending.get("activity", {})
	if pending_activity is Dictionary and String(pending_activity.get("state_name", "")) == "Sleep":
		moved_to_sleep_wake_destination = move_record_to_sleep_skip_wake_destination(
			record,
			pending_activity,
			runtime
		) or moved_to_sleep_wake_destination
		record["pending_travel"] = {}

	return moved_to_sleep_wake_destination


static func get_sleep_activity_from_pending(pending: Dictionary) -> Dictionary:
	var pending_activity = pending.get("activity", {})
	if pending_activity is Dictionary and not pending_activity.is_empty():
		return pending_activity

	return pending


static func move_record_to_sleep_skip_wake_destination(
	record: Dictionary,
	sleep_activity: Dictionary,
	runtime
) -> bool:
	var destination := get_sleep_skip_wake_destination(record, sleep_activity, runtime)
	if destination.is_empty():
		return false

	return move_record_to_destination(record, destination)


static func move_record_to_destination(record: Dictionary, destination: Dictionary) -> bool:
	var scene_path := String(destination.get("scene_path", ""))
	var position = destination.get("position", null)
	if scene_path.is_empty() or not (position is Vector2):
		return false

	record["activity"] = {}
	record["pending_travel"] = {}
	NpcRouteLocationCoordinator.clear_finish_replan_marker(record)
	record["scene_path"] = scene_path
	record["previous_scene_path"] = ""
	record["last_position"] = position
	record["spawn_random"] = false
	record["social_visit_target_id"] = ""
	record["last_travel_msec"] = Time.get_ticks_msec()
	return true


static func get_sleep_skip_wake_destination(
	record: Dictionary,
	sleep_activity: Dictionary,
	runtime
) -> Dictionary:
	var definition := get_sleep_activity_definition(sleep_activity, runtime)
	if definition != null:
		var wake_spot_destination := get_wake_spot_destination(definition, runtime)
		if not wake_spot_destination.is_empty():
			return wake_spot_destination

		var explicit_wake_destination := get_explicit_wake_destination(definition)
		if not explicit_wake_destination.is_empty():
			return explicit_wake_destination

		if definition.wake_at_home_position:
			var home_destination := get_record_home_destination(record)
			if not home_destination.is_empty():
				return home_destination

	var sleep_spot_destination := get_activity_target_destination(sleep_activity, runtime)
	if not sleep_spot_destination.is_empty():
		return sleep_spot_destination

	var fallback_home_destination := get_record_home_destination(record)
	if not fallback_home_destination.is_empty():
		return fallback_home_destination

	return get_activity_return_destination(record, sleep_activity)


static func move_record_to_sleep_definition_for_skip(
	npc_id: String,
	record: Dictionary,
	start_total_hours: float,
	end_total_hours: float,
	runtime
) -> bool:
	var definition := find_sleep_definition_during_skip(
		StringName(npc_id),
		record,
		start_total_hours,
		end_total_hours,
		runtime
	)
	if definition == null:
		return false

	return move_record_to_destination(record, {
		"scene_path": definition.scene_path,
		"position": definition.position,
	})


static func find_sleep_definition_during_skip(
	npc_id: StringName,
	record: Dictionary,
	start_total_hours: float,
	end_total_hours: float,
	runtime
) -> NpcSpotDefinition:
	if runtime._record_is_disabled(record):
		return null

	var best_definition: NpcSpotDefinition = null
	for definition_value in runtime.spot_definitions.values():
		var definition := definition_value as NpcSpotDefinition
		if definition == null or String(definition.state_name) != "Sleep":
			continue
		if not definition.allows_npc_id(npc_id):
			continue
		if not definition_is_active_during_interval(definition, start_total_hours, end_total_hours):
			continue
		if (
			best_definition == null
			or definition.priority > best_definition.priority
			or (
				definition.priority == best_definition.priority
				and String(definition.spot_id) < String(best_definition.spot_id)
			)
		):
			best_definition = definition

	return best_definition


static func definition_is_active_during_interval(
	definition: NpcSpotDefinition,
	start_total_hours: float,
	end_total_hours: float
) -> bool:
	if end_total_hours <= start_total_hours:
		return false
	if definition.active_time_windows.is_empty():
		return true

	var first_day := int(floor(start_total_hours / 24.0)) - 1
	var last_day := int(floor(end_total_hours / 24.0)) + 1
	for day in range(first_day, last_day + 1):
		for window in definition.active_time_windows:
			if not (window is Dictionary):
				continue
			if window_overlaps_interval(window, day, start_total_hours, end_total_hours):
				return true

	return false


static func window_overlaps_interval(
	window: Dictionary,
	day: int,
	start_total_hours: float,
	end_total_hours: float
) -> bool:
	var start_hour := fposmod(float(window.get("start_hour", window.get("start", 0.0))), 24.0)
	var end_hour := fposmod(float(window.get("end_hour", window.get("end", 24.0))), 24.0)
	if is_equal_approx(start_hour, end_hour):
		return true

	var window_start := float(day) * 24.0 + start_hour
	var window_end := float(day) * 24.0 + end_hour
	if start_hour > end_hour:
		window_end += 24.0

	return window_start < end_total_hours and window_end > start_total_hours


static func get_sleep_activity_definition(
	sleep_activity: Dictionary,
	runtime
) -> NpcSpotDefinition:
	var spot_id := StringName(String(sleep_activity.get("spot_id", "")))
	if spot_id == &"":
		return null

	return runtime.spot_definitions.get(spot_id, null) as NpcSpotDefinition


static func get_wake_spot_destination(
	definition: NpcSpotDefinition,
	runtime
) -> Dictionary:
	if definition == null or definition.wake_spot_id == &"":
		return {}

	var wake_definition := runtime.spot_definitions.get(
		definition.wake_spot_id,
		null
	) as NpcSpotDefinition
	if wake_definition == null:
		push_warning(
			"NPC spot '%s' wake spot '%s' does not exist."
			% [String(definition.spot_id), String(definition.wake_spot_id)]
		)
		return {}

	return {
		"scene_path": wake_definition.scene_path,
		"position": wake_definition.position,
	}


static func get_explicit_wake_destination(definition: NpcSpotDefinition) -> Dictionary:
	if definition == null or definition.wake_scene_path.is_empty():
		return {}

	return {
		"scene_path": definition.wake_scene_path,
		"position": definition.wake_position,
	}


static func get_record_home_destination(record: Dictionary) -> Dictionary:
	var scene_path := String(record.get("home_scene_path", ""))
	if scene_path.is_empty():
		scene_path = String(record.get("scene_path", ""))

	var position = record.get("home_position", null)
	if scene_path.is_empty() or not (position is Vector2):
		return {}

	return {
		"scene_path": scene_path,
		"position": position,
	}


static func get_activity_target_destination(activity: Dictionary, runtime) -> Dictionary:
	var scene_path := String(activity.get("target_scene_path", ""))
	var position = activity.get("target_position", null)

	if scene_path.is_empty():
		var definition := get_sleep_activity_definition(activity, runtime)
		if definition != null:
			scene_path = definition.scene_path
			position = definition.position

	if scene_path.is_empty() or not (position is Vector2):
		return {}

	return {
		"scene_path": scene_path,
		"position": position,
	}


static func get_activity_return_destination(
	record: Dictionary,
	activity: Dictionary
) -> Dictionary:
	var scene_path := String(activity.get("return_scene_path", record.get("scene_path", "")))
	if scene_path.is_empty():
		scene_path = String(record.get("scene_path", ""))

	var position = activity.get("return_position", record.get("last_position", Vector2.ZERO))
	if not (position is Vector2):
		position = Vector2.ZERO
	if scene_path.is_empty():
		return {}

	return {
		"scene_path": scene_path,
		"position": position,
	}
