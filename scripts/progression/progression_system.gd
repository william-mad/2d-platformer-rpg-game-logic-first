class_name GameProgressionSystem extends Node

signal global_xp_changed(current_xp: int, delta: int, source_id: StringName, context: Dictionary)
signal global_level_changed(current_level: int, previous_level: int)
signal skill_xp_changed(domain_id: StringName, current_xp: int, delta: int, source_id: StringName, context: Dictionary)
signal ability_unlocked(ability_id: StringName, definition: AbilityDefinition)
signal reward_applied(reward_id: StringName, context: Dictionary)

const SAVE_VERSION: int = 1

@export_file("*.tres") var level_curve_path: String = "res://data/progression/level_curve_default.tres"
@export_dir var skill_domains_dir: String = "res://data/progression/skill_domains"
@export_dir var abilities_dir: String = "res://data/progression/abilities"
@export_dir var xp_rewards_dir: String = "res://data/progression/xp_rewards"
@export var load_definitions_on_ready: bool = true

var level_curve: GlobalLevelCurve
var global_xp: int = 0
var global_level: int = 1
var skill_xp: Dictionary = {}

var skill_domain_definitions: Dictionary = {}
var ability_definitions: Dictionary = {}
var xp_reward_definitions: Dictionary = {}
var unlocked_ability_ids: Dictionary = {}
var claimed_reward_ids: Dictionary = {}

var _time_reward_pending_seconds: Dictionary = {}
var _reward_cooldown_until_msec: Dictionary = {}
var _warned_messages: Dictionary = {}
var _refreshing_auto_unlocks: bool = false


func _ready() -> void:
	if load_definitions_on_ready:
		load_definitions()
	_reset_level_to_curve_start_if_needed()
	refresh_auto_unlocks()


func load_definitions() -> void:
	skill_domain_definitions.clear()
	ability_definitions.clear()
	xp_reward_definitions.clear()

	if not level_curve_path.is_empty() and ResourceLoader.exists(level_curve_path):
		var loaded_curve := load(level_curve_path) as GlobalLevelCurve
		if loaded_curve != null:
			level_curve = loaded_curve
		else:
			_warn_once("level_curve.invalid", "Progression level curve is not a GlobalLevelCurve: %s" % level_curve_path)
	else:
		_warn_once("level_curve.missing", "Progression level curve is missing: %s" % level_curve_path)

	_load_definition_dir(skill_domains_dir, &"skill_domain")
	_load_definition_dir(abilities_dir, &"ability")
	_load_definition_dir(xp_rewards_dir, &"xp_reward")
	if not skill_domains_dir.is_empty() and skill_domain_definitions.is_empty():
		_warn_once(
			"dir.skill_domain.empty.%s" % skill_domains_dir,
			"Progression system found no valid skill domain definitions in resource directory: %s"
			% skill_domains_dir
		)
	if not abilities_dir.is_empty() and ability_definitions.is_empty():
		_warn_once(
			"dir.ability.empty.%s" % abilities_dir,
			"Progression system found no valid ability definitions in resource directory: %s"
			% abilities_dir
		)
	if not xp_rewards_dir.is_empty() and xp_reward_definitions.is_empty():
		_warn_once(
			"dir.xp_reward.empty.%s" % xp_rewards_dir,
			"Progression system found no valid XP reward definitions in resource directory: %s"
			% xp_rewards_dir
		)
	recalculate_level()
	refresh_auto_unlocks()


func reset_progression(emit_changes: bool = false) -> void:
	var previous_xp := global_xp
	var previous_level := global_level
	global_xp = 0
	global_level = _get_starting_level()
	skill_xp.clear()
	unlocked_ability_ids.clear()
	claimed_reward_ids.clear()
	_time_reward_pending_seconds.clear()
	_reward_cooldown_until_msec.clear()

	if emit_changes:
		if previous_xp != global_xp:
			global_xp_changed.emit(global_xp, global_xp - previous_xp, &"reset", {})
		if previous_level != global_level:
			global_level_changed.emit(global_level, previous_level)

	refresh_auto_unlocks()


func add_global_xp(amount: int, source_id: StringName = &"", context: Dictionary = {}) -> bool:
	var safe_amount := maxi(amount, 0)
	if safe_amount <= 0:
		return false

	global_xp += safe_amount
	global_xp_changed.emit(global_xp, safe_amount, source_id, context.duplicate(true))
	recalculate_level()
	refresh_auto_unlocks()
	return true


func get_global_xp() -> int:
	return global_xp


func get_global_level() -> int:
	return global_level


func get_xp_required_for_level(level: int) -> int:
	if level_curve == null:
		return 0

	return level_curve.get_xp_required_for_level(level)


func recalculate_level() -> void:
	var previous_level := global_level
	if level_curve == null:
		global_level = 1
	else:
		global_level = level_curve.get_level_for_xp(global_xp)

	if previous_level != global_level:
		global_level_changed.emit(global_level, previous_level)


func get_damage_multiplier() -> float:
	if level_curve == null:
		return 1.0

	return level_curve.get_damage_multiplier(global_level)


func get_max_hp_bonus() -> int:
	if level_curve == null:
		return 0

	return level_curve.get_max_hp_bonus(global_level)


func get_max_mana_bonus() -> int:
	if level_curve == null:
		return 0

	return level_curve.get_max_mana_bonus(global_level)


func add_skill_xp(domain_id: StringName, amount: int, source_id: StringName = &"", context: Dictionary = {}) -> bool:
	if not _is_known_domain(domain_id):
		_warn_unknown_domain(domain_id)
		return false

	var safe_amount := maxi(amount, 0)
	if safe_amount <= 0:
		return false

	var key := _id_key(domain_id)
	var current := int(skill_xp.get(key, 0))
	var updated := current + safe_amount
	skill_xp[key] = updated
	skill_xp_changed.emit(domain_id, updated, safe_amount, source_id, context.duplicate(true))
	refresh_auto_unlocks()
	return true


func get_skill_xp(domain_id: StringName) -> int:
	if not _is_known_domain(domain_id):
		_warn_unknown_domain(domain_id)
		return 0

	return int(skill_xp.get(_id_key(domain_id), 0))


func set_skill_xp(domain_id: StringName, amount: int) -> bool:
	if not _is_known_domain(domain_id):
		_warn_unknown_domain(domain_id)
		return false

	var key := _id_key(domain_id)
	var previous := int(skill_xp.get(key, 0))
	var updated := maxi(amount, 0)
	if previous == updated:
		return true

	skill_xp[key] = updated
	skill_xp_changed.emit(domain_id, updated, updated - previous, &"set", {})
	refresh_auto_unlocks()
	return true


func has_skill_xp(domain_id: StringName, amount: int) -> bool:
	return get_skill_xp(domain_id) >= maxi(amount, 0)


func can_unlock_ability(ability_id: StringName) -> bool:
	return get_locked_reason(ability_id).is_empty()


func unlock_ability(ability_id: StringName) -> bool:
	var key := _id_key(ability_id)
	if unlocked_ability_ids.has(key):
		return true
	if not can_unlock_ability(ability_id):
		return false

	unlocked_ability_ids[key] = true
	ability_unlocked.emit(ability_id, ability_definitions.get(key, null))
	if not _refreshing_auto_unlocks:
		refresh_auto_unlocks()
	return true


func is_ability_unlocked(ability_id: StringName) -> bool:
	return unlocked_ability_ids.has(_id_key(ability_id))


func get_locked_reason(ability_id: StringName) -> String:
	var key := _id_key(ability_id)
	if not ability_definitions.has(key):
		return "Unknown ability: %s" % key
	if unlocked_ability_ids.has(key):
		return ""

	var definition: AbilityDefinition = ability_definitions[key]
	if global_level < definition.required_global_level:
		return "Requires level %d" % definition.required_global_level
	if global_xp < definition.required_global_xp:
		return "Requires %d global XP" % definition.required_global_xp

	for raw_domain_id in definition.required_skill_xp.keys():
		var domain_id := StringName(String(raw_domain_id))
		if not _is_known_domain(domain_id):
			return "Unknown skill domain: %s" % String(domain_id)
		var required_amount := maxi(int(definition.required_skill_xp[raw_domain_id]), 0)
		if get_skill_xp(domain_id) < required_amount:
			return "Requires %s XP %d/%d" % [
				_get_domain_display_name(domain_id),
				get_skill_xp(domain_id),
				required_amount,
			]

	for prerequisite_id in definition.prerequisite_ability_ids:
		if not is_ability_unlocked(prerequisite_id):
			return "Requires ability: %s" % _get_ability_display_name(prerequisite_id)

	return ""


func refresh_auto_unlocks() -> void:
	if _refreshing_auto_unlocks:
		return

	_refreshing_auto_unlocks = true
	var changed := true
	while changed:
		changed = false
		for key in ability_definitions.keys():
			if unlocked_ability_ids.has(key):
				continue
			var definition: AbilityDefinition = ability_definitions[key]
			if definition.auto_unlock and get_locked_reason(definition.id).is_empty():
				unlocked_ability_ids[key] = true
				ability_unlocked.emit(definition.id, definition)
				changed = true
	_refreshing_auto_unlocks = false


func award_reward(reward_id: StringName, context: Dictionary = {}) -> bool:
	var definition := _get_reward_definition(reward_id)
	if definition == null:
		return false

	return _apply_reward(definition, 1, context)


func award_xp_reward(reward_id: StringName, context: Dictionary = {}) -> bool:
	return award_reward(reward_id, context)


func add_time_xp(reward_id: StringName, delta_seconds: float, context: Dictionary = {}) -> bool:
	var definition := _get_reward_definition(reward_id)
	if definition == null:
		return false
	if not definition.is_time_based():
		return award_reward(reward_id, context)

	var elapsed := maxf(delta_seconds, 0.0)
	if elapsed <= 0.0:
		return false

	var unit_seconds := definition.get_time_unit_seconds()
	if unit_seconds <= 0.0:
		return false

	var key := _id_key(reward_id)
	var pending := float(_time_reward_pending_seconds.get(key, 0.0)) + elapsed
	var units := int(floor(pending / unit_seconds))
	_time_reward_pending_seconds[key] = pending - float(units) * unit_seconds
	if units <= 0:
		return false

	return _apply_reward(definition, units, context)


func get_save_data() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"global_xp": global_xp,
		"global_level": global_level,
		"summary": get_save_summary_data(),
		"skill_xp": skill_xp.duplicate(true),
		"unlocked_ability_ids": _dictionary_keys_as_strings(unlocked_ability_ids),
		"claimed_reward_ids": _dictionary_keys_as_strings(claimed_reward_ids),
		"time_reward_pending_seconds": _time_reward_pending_seconds.duplicate(true),
	}


func get_save_summary_data() -> Dictionary:
	var current_level_xp := get_xp_required_for_level(global_level)
	var next_level_xp := get_xp_required_for_level(global_level + 1)
	var xp_into_level := maxi(global_xp - current_level_xp, 0)
	var xp_for_next_level := maxi(next_level_xp - current_level_xp, 0)
	var level_progress_ratio := 1.0
	if xp_for_next_level > 0:
		level_progress_ratio = clampf(float(xp_into_level) / float(xp_for_next_level), 0.0, 1.0)

	return {
		"global_level": global_level,
		"global_xp": global_xp,
		"current_level_xp": current_level_xp,
		"next_level_xp": next_level_xp,
		"xp_into_level": xp_into_level,
		"xp_for_next_level": xp_for_next_level,
		"level_progress_ratio": level_progress_ratio,
	}


func apply_save_data(data: Dictionary) -> void:
	if data.is_empty():
		reset_progression(false)
		return

	global_xp = maxi(int(data.get("global_xp", 0)), 0)
	global_level = maxi(int(data.get("global_level", _get_starting_level())), _get_starting_level())
	skill_xp.clear()
	unlocked_ability_ids.clear()
	claimed_reward_ids.clear()
	_time_reward_pending_seconds.clear()
	_reward_cooldown_until_msec.clear()

	var saved_skill_xp = data.get("skill_xp", {})
	if saved_skill_xp is Dictionary:
		for raw_domain_id in saved_skill_xp.keys():
			var domain_id := StringName(String(raw_domain_id))
			if not _is_known_domain(domain_id):
				_warn_unknown_domain(domain_id)
				continue
			skill_xp[_id_key(domain_id)] = maxi(int(saved_skill_xp[raw_domain_id]), 0)

	for ability_id in _variant_to_string_name_array(data.get("unlocked_ability_ids", [])):
		unlocked_ability_ids[_id_key(ability_id)] = true

	for reward_id in _variant_to_string_name_array(data.get("claimed_reward_ids", [])):
		claimed_reward_ids[_id_key(reward_id)] = true

	var saved_pending = data.get("time_reward_pending_seconds", {})
	if saved_pending is Dictionary:
		for raw_reward_id in saved_pending.keys():
			_time_reward_pending_seconds[String(raw_reward_id)] = maxf(float(saved_pending[raw_reward_id]), 0.0)

	recalculate_level()
	refresh_auto_unlocks()


func get_debug_snapshot() -> Dictionary:
	return {
		"global_xp": global_xp,
		"global_level": global_level,
		"damage_multiplier": get_damage_multiplier(),
		"max_hp_bonus": get_max_hp_bonus(),
		"max_mana_bonus": get_max_mana_bonus(),
		"skill_xp": skill_xp.duplicate(true),
		"unlocked_ability_ids": _dictionary_keys_as_strings(unlocked_ability_ids),
		"known_skill_domains": _dictionary_keys_as_strings(skill_domain_definitions),
		"known_abilities": _dictionary_keys_as_strings(ability_definitions),
		"known_rewards": _dictionary_keys_as_strings(xp_reward_definitions),
	}


func debug_print_snapshot() -> void:
	print(JSON.stringify(get_debug_snapshot(), "\t"))


func _apply_reward(definition: XPRewardDefinition, units: int, context: Dictionary) -> bool:
	var key := _id_key(definition.id)
	if definition.once_per_save and claimed_reward_ids.has(key):
		return false
	if _reward_is_on_cooldown(definition):
		return false

	var safe_units := maxi(units, 1)
	var awarded := false
	var context_copy := context.duplicate(true)
	context_copy["reward_id"] = key
	context_copy["units"] = safe_units

	var global_amount := definition.global_xp_amount * safe_units
	if global_amount > 0:
		awarded = add_global_xp(global_amount, definition.id, context_copy) or awarded

	var skill_amounts := _get_reward_skill_xp_amounts(definition, context_copy)
	for raw_domain_id in skill_amounts.keys():
		var domain_id := StringName(String(raw_domain_id))
		var amount := maxi(int(skill_amounts[raw_domain_id]), 0) * safe_units
		if amount > 0:
			awarded = add_skill_xp(domain_id, amount, definition.id, context_copy) or awarded

	if not awarded:
		return false

	if definition.once_per_save:
		claimed_reward_ids[key] = true
	if definition.cooldown_seconds > 0.0:
		_reward_cooldown_until_msec[key] = Time.get_ticks_msec() + int(definition.cooldown_seconds * 1000.0)

	reward_applied.emit(definition.id, context_copy)
	return true


func _get_reward_skill_xp_amounts(definition: XPRewardDefinition, context: Dictionary) -> Dictionary:
	var amounts := definition.skill_xp_amounts.duplicate(true)
	var context_tags := _collect_context_tags(context)
	for tag in context_tags:
		var tag_key := _id_key(tag)
		if not definition.tagged_skill_xp_amounts.has(tag_key):
			continue
		var tagged_amounts = definition.tagged_skill_xp_amounts[tag_key]
		if not (tagged_amounts is Dictionary):
			continue
		for raw_domain_id in tagged_amounts.keys():
			var domain_key := String(raw_domain_id)
			amounts[domain_key] = int(amounts.get(domain_key, 0)) + int(tagged_amounts[raw_domain_id])

	return amounts


func _collect_context_tags(context: Dictionary) -> Array[StringName]:
	var tags: Array[StringName] = []
	for key in ["tags", "attack_tags", "context_tags"]:
		var value = context.get(key, [])
		if value is Array:
			for raw_tag in value:
				var tag := StringName(String(raw_tag))
				if tag != &"" and not tags.has(tag):
					tags.append(tag)

	return tags


func _reward_is_on_cooldown(definition: XPRewardDefinition) -> bool:
	var key := _id_key(definition.id)
	if not _reward_cooldown_until_msec.has(key):
		return false

	return Time.get_ticks_msec() < int(_reward_cooldown_until_msec[key])


func _get_reward_definition(reward_id: StringName) -> XPRewardDefinition:
	var key := _id_key(reward_id)
	if xp_reward_definitions.has(key):
		return xp_reward_definitions[key]

	_warn_once("reward.%s" % key, "Unknown XP reward id: %s" % key)
	return null


func _load_definition_dir(dir_path: String, kind: StringName) -> void:
	if dir_path.is_empty():
		return

	for entry_name: String in ResourceLoader.list_directory(dir_path):
		var is_directory := entry_name.ends_with("/")
		var file_name := entry_name.trim_suffix("/") if is_directory else entry_name
		var path := dir_path.path_join(file_name)
		if is_directory:
			if not file_name.begins_with("."):
				_load_definition_dir(path, kind)
		elif file_name.get_extension().to_lower() in ["tres", "res"]:
			_load_definition_resource(path, kind)


func _load_definition_resource(path: String, kind: StringName) -> void:
	var resource := load(path)
	if resource == null:
		return

	match kind:
		&"skill_domain":
			var domain := resource as SkillDomainDefinition
			if domain != null and domain.is_valid_definition():
				skill_domain_definitions[_id_key(domain.id)] = domain
			else:
				_warn_once("domain.invalid.%s" % path, "Invalid skill domain definition: %s" % path)
		&"ability":
			var ability := resource as AbilityDefinition
			if ability != null and ability.is_valid_definition():
				ability_definitions[_id_key(ability.id)] = ability
			else:
				_warn_once("ability.invalid.%s" % path, "Invalid ability definition: %s" % path)
		&"xp_reward":
			var reward := resource as XPRewardDefinition
			if reward != null and reward.is_valid_definition():
				xp_reward_definitions[_id_key(reward.id)] = reward
			else:
				_warn_once("reward.invalid.%s" % path, "Invalid XP reward definition: %s" % path)


func _is_known_domain(domain_id: StringName) -> bool:
	return skill_domain_definitions.has(_id_key(domain_id))


func _warn_unknown_domain(domain_id: StringName) -> void:
	var key := _id_key(domain_id)
	_warn_once("domain.unknown.%s" % key, "Unknown skill XP domain: %s" % key)


func _get_domain_display_name(domain_id: StringName) -> String:
	var key := _id_key(domain_id)
	if skill_domain_definitions.has(key):
		var definition: SkillDomainDefinition = skill_domain_definitions[key]
		if not definition.display_name.is_empty():
			return definition.display_name

	return key


func _get_ability_display_name(ability_id: StringName) -> String:
	var key := _id_key(ability_id)
	if ability_definitions.has(key):
		var definition: AbilityDefinition = ability_definitions[key]
		if not definition.display_name.is_empty():
			return definition.display_name

	return key


func _reset_level_to_curve_start_if_needed() -> void:
	if global_level <= 0:
		global_level = _get_starting_level()


func _get_starting_level() -> int:
	if level_curve == null:
		return 1

	return maxi(level_curve.starting_level, 1)


func _dictionary_keys_as_strings(dictionary: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for key in dictionary.keys():
		keys.append(String(key))
	keys.sort()
	return keys


func _variant_to_string_name_array(value) -> Array[StringName]:
	var ids: Array[StringName] = []
	if not (value is Array):
		return ids

	for item in value:
		var id := StringName(String(item))
		if id != &"" and not ids.has(id):
			ids.append(id)

	return ids


func _id_key(id: StringName) -> String:
	return String(id)


func _warn_once(key: String, message: String) -> void:
	if _warned_messages.has(key):
		return

	_warned_messages[key] = true
	push_warning(message)
