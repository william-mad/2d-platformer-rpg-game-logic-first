class_name NpcSocialStateSchema extends RefCounted

## Canonical meaning for every value currently exposed by SocialNpc. Runtime
## systems may consume only a subset, but presentation no longer has to infer
## whether a number is personal or directed at another actor.

const SCOPE_PERSONAL_NEED: StringName = &"personal_need"
const SCOPE_BROAD_MOOD: StringName = &"broad_mood"
const SCOPE_DIRECTED_OPINION: StringName = &"directed_opinion"
const SCOPE_PHYSICAL_STATE: StringName = &"physical_state"

const PERSISTENCE_NPC_LOCATION: StringName = &"npc_location_record"
const PERSISTENCE_RELATIONSHIPS: StringName = &"relationship_save"

const DIRECTED_OPINION_METRIC_IDS: Array[StringName] = [
	&"favor",
	&"trust",
	&"love",
	&"lust",
	&"shame",
	&"anger",
	&"fear",
	&"suspicion",
]

const VALUE_ORDER: Array[StringName] = [
	&"hp",
	&"knockout",
	&"disabled",
	&"hunger",
	&"sleep_need",
	&"tired",
	&"boredom",
	&"talk_need",
	&"lonely",
	&"curiosity",
	&"sadness",
	&"energy",
	&"bored",
	&"favor",
	&"trust",
	&"love",
	&"lust",
	&"shame",
	&"anger",
	&"fear",
	&"suspicion",
]

const PRESENTATION_CONDITION: Dictionary = {
	"section": &"condition",
	"format": &"meter",
	"requires_subject": false,
	"show_in_character_page": true,
	"show_in_debug": true,
}
const PRESENTATION_BOOLEAN_CONDITION: Dictionary = {
	"section": &"condition",
	"format": &"boolean",
	"requires_subject": false,
	"show_in_character_page": true,
	"show_in_debug": true,
}
const PRESENTATION_NEED: Dictionary = {
	"section": &"needs",
	"format": &"meter",
	"requires_subject": false,
	"show_in_character_page": true,
	"show_in_debug": true,
}
const PRESENTATION_MOOD: Dictionary = {
	"section": &"mood",
	"format": &"meter",
	"requires_subject": false,
	"show_in_character_page": true,
	"show_in_debug": true,
}
const PRESENTATION_POSITIVE_OPINION: Dictionary = {
	"section": &"opinions",
	"format": &"meter",
	"requires_subject": true,
	"show_in_character_page": true,
	"show_in_debug": true,
	"polarity": 1,
}
const PRESENTATION_NEGATIVE_OPINION: Dictionary = {
	"section": &"opinions",
	"format": &"meter",
	"requires_subject": true,
	"show_in_character_page": true,
	"show_in_debug": true,
	"polarity": -1,
}

const VALUE_DEFINITIONS: Dictionary = {
	&"hp": {
		"label": "Health",
		"scope": SCOPE_PHYSICAL_STATE,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 100.0,
		"behavior_consumers": [&"damage", &"healing", &"death"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"passive_healing_and_starvation",
		"presentation": PRESENTATION_CONDITION,
	},
	&"knockout": {
		"label": "Knockout",
		"scope": SCOPE_PHYSICAL_STATE,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"downed_state"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"real_time_recovery",
		"presentation": PRESENTATION_CONDITION,
	},
	&"disabled": {
		"label": "Disabled",
		"scope": SCOPE_PHYSICAL_STATE,
		"minimum": 0.0,
		"maximum": 1.0,
		"default": 0.0,
		"behavior_consumers": [&"disabled_dead_state"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"none",
		"presentation": PRESENTATION_BOOLEAN_CONDITION,
	},
	&"hunger": {
		"label": "Hunger",
		"scope": SCOPE_PERSONAL_NEED,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 25.0,
		"behavior_consumers": [&"eat", &"starvation"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"grows_with_game_time",
		"presentation": PRESENTATION_NEED,
	},
	&"sleep_need": {
		"label": "Sleep need",
		"scope": SCOPE_PERSONAL_NEED,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"sleep", &"collapse"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"grows_with_game_time_and_recovers_during_sleep",
		"presentation": PRESENTATION_NEED,
	},
	&"tired": {
		"label": "Tiredness",
		"scope": SCOPE_PERSONAL_NEED,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"rest"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"state_dependent_fatigue_and_rest",
		"presentation": PRESENTATION_NEED,
	},
	&"boredom": {
		"label": "Boredom",
		"scope": SCOPE_PERSONAL_NEED,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"recreation"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"grows_with_game_time_and_recovers_during_activity",
		"presentation": PRESENTATION_NEED,
	},
	&"talk_need": {
		"label": "Social need",
		"scope": SCOPE_PERSONAL_NEED,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"social_planning", &"talk"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"grows_with_game_time_and_recovers_during_talk",
		"presentation": PRESENTATION_NEED,
	},
	&"lonely": {
		"label": "Loneliness",
		"scope": SCOPE_PERSONAL_NEED,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"social_need_overflow", &"loneliness_recovery"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"recovers_while_social_need_is_low",
		"presentation": PRESENTATION_NEED,
	},
	&"curiosity": {
		"label": "Curiosity",
		"scope": SCOPE_BROAD_MOOD,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"story_authored",
		"presentation": PRESENTATION_MOOD,
	},
	&"sadness": {
		"label": "Sadness",
		"scope": SCOPE_BROAD_MOOD,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"story_authored",
		"presentation": PRESENTATION_MOOD,
	},
	&"energy": {
		"label": "Energy",
		"scope": SCOPE_BROAD_MOOD,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 100.0,
		"behavior_consumers": [],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"story_authored",
		"presentation": PRESENTATION_MOOD,
	},
	&"bored": {
		"label": "Bored mood",
		"scope": SCOPE_BROAD_MOOD,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"story_authored",
		"presentation": PRESENTATION_MOOD,
	},
	# Existing undirected anger is a broad mood. Explicit actor-targeted anger
	# uses the directed-opinion definition below instead of inferring a subject.
	&"anger": {
		"label": "Anger",
		"scope": SCOPE_BROAD_MOOD,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"broad_reaction_mood"],
		"persistence": PERSISTENCE_NPC_LOCATION,
		"decay": &"passive_game_time_decay",
		"presentation": PRESENTATION_MOOD,
	},
}

const DIRECTED_OPINION_DEFINITIONS: Dictionary = {
	&"favor": {
		"label": "Favor",
		"scope": SCOPE_DIRECTED_OPINION,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 50.0,
		"behavior_consumers": [&"social_candidate_selection", &"social_acceptance", &"trade_pricing", &"dialogue"],
		"persistence": PERSISTENCE_RELATIONSHIPS,
		"decay": &"none",
		"presentation": PRESENTATION_POSITIVE_OPINION,
	},
	&"trust": {
		"label": "Trust",
		"scope": SCOPE_DIRECTED_OPINION,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 50.0,
		"behavior_consumers": [&"story_currency"],
		"persistence": PERSISTENCE_RELATIONSHIPS,
		"decay": &"none",
		"presentation": PRESENTATION_POSITIVE_OPINION,
	},
	&"love": {
		"label": "Love",
		"scope": SCOPE_DIRECTED_OPINION,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"social_candidate_selection", &"story_currency"],
		"persistence": PERSISTENCE_RELATIONSHIPS,
		"decay": &"none",
		"presentation": PRESENTATION_POSITIVE_OPINION,
	},
	&"lust": {
		"label": "Lust",
		"scope": SCOPE_DIRECTED_OPINION,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [],
		"persistence": PERSISTENCE_RELATIONSHIPS,
		"decay": &"none",
		"presentation": PRESENTATION_POSITIVE_OPINION,
	},
	&"shame": {
		"label": "Shame",
		"scope": SCOPE_DIRECTED_OPINION,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [],
		"persistence": PERSISTENCE_RELATIONSHIPS,
		"decay": &"none",
		"presentation": PRESENTATION_NEGATIVE_OPINION,
	},
	&"anger": {
		"label": "Anger",
		"scope": SCOPE_DIRECTED_OPINION,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"social_candidate_selection", &"social_acceptance", &"fight"],
		"persistence": PERSISTENCE_RELATIONSHIPS,
		"decay": &"passive_game_time_decay",
		"presentation": PRESENTATION_NEGATIVE_OPINION,
	},
	&"fear": {
		"label": "Fear",
		"scope": SCOPE_DIRECTED_OPINION,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"social_candidate_selection", &"social_acceptance", &"flee"],
		"persistence": PERSISTENCE_RELATIONSHIPS,
		"decay": &"panic_then_passive_game_time_decay",
		"presentation": PRESENTATION_NEGATIVE_OPINION,
	},
	&"suspicion": {
		"label": "Suspicion",
		"scope": SCOPE_DIRECTED_OPINION,
		"minimum": 0.0,
		"maximum": 100.0,
		"default": 0.0,
		"behavior_consumers": [&"story_currency"],
		"persistence": PERSISTENCE_RELATIONSHIPS,
		"decay": &"none",
		"presentation": PRESENTATION_NEGATIVE_OPINION,
	},
}


static func get_all_definitions() -> Dictionary:
	var definitions := VALUE_DEFINITIONS.duplicate(true)
	for metric_id in DIRECTED_OPINION_METRIC_IDS:
		if not definitions.has(metric_id):
			definitions[metric_id] = DIRECTED_OPINION_DEFINITIONS[metric_id].duplicate(true)
	return definitions


static func get_definition(value_id: StringName) -> Dictionary:
	var definition = VALUE_DEFINITIONS.get(value_id, {})
	if not (definition is Dictionary) or definition.is_empty():
		definition = DIRECTED_OPINION_DEFINITIONS.get(value_id, {})
	return definition.duplicate(true) if definition is Dictionary else {}


static func get_definitions_for_scope(scope: StringName) -> Array[Dictionary]:
	var definitions: Array[Dictionary] = []
	if scope == SCOPE_DIRECTED_OPINION:
		for metric_id in DIRECTED_OPINION_METRIC_IDS:
			var opinion_definition: Dictionary = (
				DIRECTED_OPINION_DEFINITIONS[metric_id].duplicate(true)
			)
			opinion_definition["id"] = metric_id
			definitions.append(opinion_definition)
		return definitions
	for value_id in VALUE_ORDER:
		var definition = VALUE_DEFINITIONS.get(value_id, {})
		if not (definition is Dictionary) or StringName(definition.get("scope", &"")) != scope:
			continue
		var copy: Dictionary = definition.duplicate(true)
		copy["id"] = value_id
		definitions.append(copy)
	return definitions


static func get_directed_opinion_metrics() -> PackedStringArray:
	var metrics := PackedStringArray()
	for metric_id in DIRECTED_OPINION_METRIC_IDS:
		metrics.append(String(metric_id))
	return metrics


static func is_directed_opinion_metric(value_id: StringName) -> bool:
	return DIRECTED_OPINION_METRIC_IDS.has(value_id)


static func get_default_value(value_id: StringName) -> float:
	return float(get_definition(value_id).get("default", 0.0))


static func get_minimum_value(value_id: StringName) -> float:
	return float(get_definition(value_id).get("minimum", 0.0))


static func get_maximum_value(value_id: StringName) -> float:
	return float(get_definition(value_id).get("maximum", 100.0))


static func get_directed_opinion_definition(metric_id: StringName) -> Dictionary:
	var definition = DIRECTED_OPINION_DEFINITIONS.get(metric_id, {})
	return definition.duplicate(true) if definition is Dictionary else {}


static func get_directed_opinion_default(metric_id: StringName) -> float:
	return float(DIRECTED_OPINION_DEFINITIONS.get(metric_id, {}).get("default", 0.0))


static func get_directed_opinion_minimum(metric_id: StringName) -> float:
	return float(DIRECTED_OPINION_DEFINITIONS.get(metric_id, {}).get("minimum", 0.0))


static func get_directed_opinion_maximum(metric_id: StringName) -> float:
	return float(DIRECTED_OPINION_DEFINITIONS.get(metric_id, {}).get("maximum", 100.0))


## Separates legacy mixed value deltas without inventing an opinion subject.
## The caller must provide an explicit actor before applying directed_opinion.
## Broad anger stays local; actor-targeted anger uses Relationships explicitly.
static func split_value_delta(delta: Dictionary) -> Dictionary:
	var local_values: Dictionary = {}
	var directed_opinion: Dictionary = {}
	for raw_key in delta.keys():
		var value_id := StringName(String(raw_key))
		if value_id in [
			&"favor",
			&"love",
			&"lust",
			&"shame",
			&"trust",
			&"suspicion",
			&"fear",
		]:
			directed_opinion[value_id] = delta[raw_key]
		else:
			local_values[value_id] = delta[raw_key]
	return {
		"local_values": local_values,
		"directed_opinion": directed_opinion,
	}
