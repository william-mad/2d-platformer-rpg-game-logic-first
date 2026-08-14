class_name NpcActivitySelector
extends RefCounted

const ScheduleWindowPolicy = preload(
	"res://scripts/systems/npc_schedule_window_policy.gd"
)


static func find_best_definition(
	spot_definitions: Dictionary,
	npc_id: StringName,
	record: Dictionary,
	hour: float,
	runtime
) -> NpcSpotDefinition:
	var candidate := find_best_candidate(
		spot_definitions,
		npc_id,
		record,
		hour,
		runtime
	)
	return candidate.get("definition", null) as NpcSpotDefinition


static func find_best_candidate(
	spot_definitions: Dictionary,
	npc_id: StringName,
	record: Dictionary,
	total_game_hours: float,
	runtime
) -> Dictionary:
	var best_candidate: Dictionary = {}
	var hour := fposmod(total_game_hours, 24.0)
	for definition_value in spot_definitions.values():
		var definition := definition_value as NpcSpotDefinition
		if definition == null:
			continue
		var schedule_decision: Dictionary = {}
		if runtime._definition_is_meal_cycle_managed(definition):
			if not runtime._meal_cycle_definition_can_start(definition, npc_id, hour):
				continue
			schedule_decision = {
				"eligible": true,
				"phase": ScheduleWindowPolicy.PHASE_ON_TIME,
				"start_policy": ScheduleWindowPolicy.START_POLICY_HARD,
				"window_index": -1,
				"occurrence_key": "",
				"effective_priority": definition.priority,
				"may_interrupt_busy_live_npc": true,
				"meal_cycle_managed": true,
			}
		elif not definition.allows_npc_id(npc_id):
			continue
		else:
			schedule_decision = ScheduleWindowPolicy.evaluate_definition(
				definition,
				total_game_hours
			)
			if not bool(schedule_decision.get("eligible", false)):
				continue
		if not spot_has_capacity(definition, runtime):
			continue
		if not spot_runtime_is_available(definition, runtime):
			continue
		var urgency := 0.0
		if definition.value_name != &"":
			if (
				definition.require_npc_value_threshold
				and not saved_stat_exists(record, String(definition.value_name))
			):
				continue
			var current_value: float = float(runtime._get_saved_stat(
				record,
				String(definition.value_name)
			))
			var effective_threshold := get_effective_need_threshold(definition, hour, runtime)
			urgency = get_definition_urgency(definition, runtime)
			if definition.require_npc_value_threshold:
				if current_value < effective_threshold:
					continue
				if definition.need_maximum >= 0.0 and current_value > definition.need_maximum:
					continue
				urgency = current_value - effective_threshold
		var social_affinity := get_social_affinity_score(
			definition,
			npc_id,
			runtime
		)
		if not bool(social_affinity.get("group_compatible", true)):
			continue
		var candidate := {
			"definition": definition,
			"schedule_decision": schedule_decision.duplicate(true),
			"effective_priority": int(schedule_decision.get(
				"effective_priority",
				definition.priority
			)),
			"urgency": urgency,
			"social_affinity": social_affinity,
			"social_affinity_bonus": float(social_affinity.get(
				"social_bonus",
				0.0
			)),
		}
		if _candidate_comes_before(candidate, best_candidate):
			best_candidate = candidate
	return best_candidate


static func _candidate_comes_before(
	candidate: Dictionary,
	current_best: Dictionary
) -> bool:
	if current_best.is_empty():
		return true
	var candidate_priority := int(candidate.get("effective_priority", 0))
	var best_priority := int(current_best.get("effective_priority", 0))
	if candidate_priority != best_priority:
		return candidate_priority > best_priority
	var candidate_urgency := float(candidate.get("urgency", 0.0))
	var best_urgency := float(current_best.get("urgency", 0.0))
	var candidate_definition := candidate.get("definition", null) as NpcSpotDefinition
	var best_definition := current_best.get("definition", null) as NpcSpotDefinition
	if candidate_definition == null:
		return false
	if best_definition == null:
		return true
	if (
		candidate_definition.state_name == best_definition.state_name
		and candidate_definition.state_name in [&"Rest", &"Recreation"]
	):
		var candidate_location_score := candidate_urgency + float(
			candidate.get("social_affinity_bonus", 0.0)
		)
		var best_location_score := best_urgency + float(
			current_best.get("social_affinity_bonus", 0.0)
		)
		if not is_equal_approx(candidate_location_score, best_location_score):
			return candidate_location_score > best_location_score
	elif not is_equal_approx(candidate_urgency, best_urgency):
		return candidate_urgency > best_urgency
	return String(candidate_definition.spot_id) < String(best_definition.spot_id)


static func get_social_affinity_bonus(
	definition: NpcSpotDefinition,
	npc_id: StringName,
	runtime
) -> float:
	return float(get_social_affinity_score(
		definition,
		npc_id,
		runtime
	).get("social_bonus", 0.0))


static func get_social_affinity_score(
	definition: NpcSpotDefinition,
	npc_id: StringName,
	runtime
) -> Dictionary:
	if (
		definition == null
		or definition.state_name not in [&"Rest", &"Recreation"]
		or runtime == null
		or not runtime.has_method("score_activity_spot_social_affinity")
	):
		return {}
	var score = runtime.score_activity_spot_social_affinity(
		npc_id,
		definition.spot_id,
		definition.state_name
	)
	return score if score is Dictionary else {}


static func get_effective_need_threshold(
	definition: NpcSpotDefinition,
	hour: float,
	runtime
) -> float:
	var threshold := get_timed_need_threshold(definition, hour)
	if (
		definition.spot_value_name == &""
		or definition.need_threshold_at_spot_value_maximum < 0.0
	):
		return threshold

	var state = runtime.spot_runtime_states.get(String(definition.spot_id), {})
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


static func get_timed_need_threshold(definition: NpcSpotDefinition, hour: float) -> float:
	for window in definition.timed_need_thresholds:
		if not (window is Dictionary):
			continue
		var window_dictionary: Dictionary = window
		if not time_window_contains_hour(window_dictionary, hour):
			continue
		return float(window_dictionary.get(
			"need_threshold",
			window_dictionary.get("threshold", definition.need_threshold)
		))

	return definition.need_threshold


static func time_window_contains_hour(window: Dictionary, hour: float) -> bool:
	var start_hour := fposmod(float(window.get("start_hour", window.get("start", 0.0))), 24.0)
	var end_hour := fposmod(float(window.get("end_hour", window.get("end", 24.0))), 24.0)
	var normalized_hour := fposmod(hour, 24.0)

	if is_equal_approx(start_hour, end_hour):
		return true
	if start_hour < end_hour:
		return normalized_hour >= start_hour and normalized_hour < end_hour

	return normalized_hour >= start_hour or normalized_hour < end_hour


static func get_definition_urgency(definition: NpcSpotDefinition, runtime) -> float:
	if definition.spot_value_name == &"":
		return 0.0

	var state = runtime.spot_runtime_states.get(String(definition.spot_id), {})
	if not (state is Dictionary):
		return 0.0

	var minimum := float(state.get("minimum", definition.spot_value_minimum))
	var maximum := float(state.get("maximum", definition.spot_value_maximum))
	if is_equal_approx(minimum, maximum):
		return 0.0

	var current := float(state.get("value", definition.spot_value_initial))
	return clampf(inverse_lerp(minimum, maximum, current), 0.0, 1.0) * 100.0


static func spot_has_capacity(definition: NpcSpotDefinition, runtime) -> bool:
	if definition.capacity <= 0:
		return true
	return int(runtime.spot_claim_counts.get(definition.spot_id, 0)) < definition.capacity


static func spot_runtime_is_available(definition: NpcSpotDefinition, runtime) -> bool:
	if runtime._definition_is_meal_cycle_managed(definition):
		return runtime._meal_cycle_definition_is_available(definition)
	if definition.spot_value_name == &"":
		return true
	var state = runtime.spot_runtime_states.get(String(definition.spot_id), {})
	if not (state is Dictionary):
		return false
	return float(state.get("value", 0.0)) > float(
		state.get("done_threshold", definition.spot_value_done_threshold)
	)


static func saved_stat_exists(record: Dictionary, value_name: String) -> bool:
	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return false
	var social_stats = node_state.get("social_stats", {})
	return social_stats is Dictionary and social_stats.has(value_name)
