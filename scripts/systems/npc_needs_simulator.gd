class_name NpcNeedsSimulator
extends RefCounted


const DEFAULT_PASSIVE_HEALING_PER_GAME_DAY := 10.0
const DEFAULT_STARVATION_DAMAGE_PER_GAME_DAY := 5.0


func advance_needs(
	record: Dictionary,
	elapsed_game_hours: float,
	paused_state_name: StringName,
	need_multipliers: Dictionary = {}
) -> bool:
	if elapsed_game_hours <= 0.0:
		return false

	var node_state = record.get("node_state", {})
	if not (node_state is Dictionary):
		return false
	var social_stats = node_state.get("social_stats", {})
	if not (social_stats is Dictionary):
		return false

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
		return false

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
		var multiplier := float(need_multipliers.get(value_name, 1.0))
		var growth := float(rates[value_key]) * elapsed_game_hours * multiplier
		if value_name == "talk_need":
			_apply_talk_need_growth(social_stats, current_value, growth)
			continue
		var next_value := current_value + growth
		social_stats[value_name] = clampf(next_value, 0.0, 100.0)

	hunger_rate *= float(need_multipliers.get("hunger", 1.0))
	var starvation_applied := _apply_starvation_damage(
		social_stats,
		profile,
		elapsed_game_hours,
		hunger_before_growth,
		hunger_rate,
		hunger_paused
	)
	if not starvation_applied:
		_apply_passive_healing(social_stats, profile, elapsed_game_hours)
	_apply_tired_change(social_stats, profile, paused_state_name, elapsed_game_hours)
	if float(need_multipliers.get("talk_need", 1.0)) > 0.0:
		_apply_loneliness_recovery(
		social_stats,
		profile,
		talk_need_before_growth,
		talk_need_rate * float(need_multipliers.get("talk_need", 1.0)),
		elapsed_game_hours,
		_passive_value_is_paused("talk_need", paused_state_name)
		)
	if float(need_multipliers.get("talk_need", 1.0)) > 0.0:
		_apply_emotion_decay(social_stats, profile, elapsed_game_hours)

	node_state["social_stats"] = social_stats
	record["node_state"] = node_state
	return true


func _apply_starvation_damage(
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
	var starvation_hours := _get_starvation_game_hours(
		elapsed_game_hours, hunger_before_growth, hunger_rate
	)
	if starvation_hours <= 0.0:
		return false
	var damage := (damage_per_day / 24.0) * starvation_hours
	social_stats["hp"] = maxf(current_hp - damage, 0.0)
	return true


func _get_starvation_game_hours(
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


func _apply_passive_healing(
	social_stats: Dictionary,
	profile: Dictionary,
	elapsed_game_hours: float
) -> void:
	if elapsed_game_hours <= 0.0 or not social_stats.has("hp"):
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


func _apply_tired_change(
	social_stats: Dictionary,
	profile: Dictionary,
	state_name: StringName,
	game_hours: float
) -> void:
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
				- absf(float(settings.get("rest_recovery_per_game_hour", 100.0))) * game_hours,
			rest_floor
		)
		return
	elif state_text == "Rest":
		rate = -absf(float(settings.get("rest_recovery_per_game_hour", 100.0)))
	elif state_text == "Fight":
		rate = absf(float(settings.get("fight_growth_per_game_hour", 60.0)))
	else:
		var inactive_states = settings.get(
			"inactive_states", [&"Idle", &"Sleep", &"Collapse", &"DisabledDead"]
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


func _apply_talk_need_growth(
	social_stats: Dictionary,
	current_value: float,
	growth: float
) -> void:
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
		float(social_stats.get("lonely", 0.0)) + float(lonely_increases), 0.0, 100.0
	)


func _apply_loneliness_recovery(
	social_stats: Dictionary,
	profile: Dictionary,
	initial_talk_need: float,
	talk_need_rate: float,
	elapsed_game_hours: float,
	talk_need_paused: bool
) -> void:
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
			recovery_hours, maxf((threshold - initial_talk_need) / talk_need_rate, 0.0)
		)
	if recovery_hours <= 0.0:
		return
	var full_recovery_hours := maxf(
		float(settings.get("full_recovery_game_hours", 5.0)), 0.001
	)
	var current_loneliness := float(social_stats.get(lonely_name, 0.0))
	social_stats[lonely_name] = maxf(
		current_loneliness - (100.0 / full_recovery_hours) * recovery_hours, 0.0
	)


func _apply_emotion_decay(
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


func _variant_array_has_string(values, expected: String) -> bool:
	if not (values is Array):
		return false
	for value in values:
		if String(value) == expected:
			return true
	return false
