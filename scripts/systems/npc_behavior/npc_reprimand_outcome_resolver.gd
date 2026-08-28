class_name NpcReprimandOutcomeResolver extends RefCounted

const OUTCOME_APOLOGIZE: StringName = &"apologize"
const OUTCOME_EXCUSE: StringName = &"excuse"
const OUTCOME_JUSTIFY: StringName = &"justify"
const OUTCOME_DEFIANT: StringName = &"defiant"
const OUTCOME_THREATEN: StringName = &"threaten"

const RESOLUTION_RESUME: StringName = &"resume"
const RESOLUTION_CONTINUE: StringName = &"continue_confrontation"
const RESOLUTION_FIGHT: StringName = &"fight"
const RESOLUTION_FLEE: StringName = &"flee"


func resolve(
	context: Dictionary,
	semantic_outcome: StringName,
	relationship: Dictionary = {}
) -> Dictionary:
	var severity := clampf(float(context.get("severity", 0.0)), 0.0, 100.0)
	var victim_is_self: bool = (
		context.get("victim", null) == context.get("initiator", null)
	)
	var result := {
		"accepted": true,
		"semantic_outcome": semantic_outcome,
		"resolution": RESOLUTION_RESUME,
		"relationship_delta": {},
	}

	match semantic_outcome:
		OUTCOME_APOLOGIZE:
			result["relationship_delta"] = {
				"favor": 1.0,
				"trust": 2.0,
				"anger": -8.0,
			}
		OUTCOME_EXCUSE:
			result["relationship_delta"] = {
				"trust": -1.0,
				"anger": -2.0,
			}
		OUTCOME_JUSTIFY:
			result["relationship_delta"] = {
				"trust": 1.0 if victim_is_self and severity < 45.0 else -1.0,
				"anger": -4.0 if victim_is_self and severity < 45.0 else 1.0,
			}
		OUTCOME_DEFIANT:
			result["relationship_delta"] = {
				"favor": -6.0,
				"trust": -5.0,
				"anger": 20.0,
			}
			result["resolution"] = RESOLUTION_FIGHT
		OUTCOME_THREATEN:
			result["relationship_delta"] = {
				"favor": -10.0,
				"trust": -10.0,
				"anger": 30.0,
				"fear": 10.0,
			}
			var current_fear := float(relationship.get("fear", 0.0)) + 10.0
			var current_anger := float(relationship.get("anger", 0.0)) + 30.0
			var flee_threshold := float(relationship.get("flee_threshold", 70.0))
			var fight_threshold := float(relationship.get("fight_threshold", 100.0))
			result["resolution"] = (
				RESOLUTION_FLEE
				if current_fear >= flee_threshold and current_anger < fight_threshold
				else RESOLUTION_FIGHT
			)
		_:
			result["accepted"] = false
			result["resolution"] = RESOLUTION_CONTINUE

	return result
