class_name NpcConfrontationPolicy extends RefCounted

const DECISION_IGNORE: StringName = &"ignore"
const DECISION_REPRIMAND: StringName = &"reprimand"
const DECISION_FLEE: StringName = &"flee"
const DECISION_FIGHT: StringName = &"fight"

const REASON_ATTACKED_ME: StringName = &"attacked_me"
const REASON_ATTACKED_FRIEND: StringName = &"attacked_friend"
const REASON_REPEATED_OFFENSE: StringName = &"repeated_offense"
const REASON_FALSE_MONSTER_ALARM: StringName = &"false_monster_alarm"

const DEFAULT_FRIEND_FAVOR_THRESHOLD: float = 60.0
const DEFAULT_IMMEDIATE_THREAT_SEVERITY: float = 80.0
const DEFAULT_ACTIVE_CONFRONTATION_SEVERITY: float = 55.0
const DEFAULT_ESCALATION_OFFENSE_COUNT: int = 4


func decide(context: Dictionary, relationship: Dictionary = {}) -> Dictionary:
	var result := {
		"decision": DECISION_IGNORE,
		"reason": StringName(String(context.get("reason", &""))),
	}
	var offender := context.get("offender", null) as Node
	if offender == null or not is_instance_valid(offender):
		return result
	# The first authored confrontation content is Player-facing. Monsters and
	# unsupported actors remain on the existing immediate combat/reaction paths.
	if not offender.is_in_group("player"):
		return result

	var severity := clampf(float(context.get("severity", 0.0)), 0.0, 100.0)
	var offense_count := maxi(int(context.get("offense_count", 1)), 1)
	var anger := float(relationship.get("anger", 0.0))
	var fear := float(relationship.get("fear", 0.0))
	var fight_threshold := float(relationship.get("fight_threshold", 100.0))
	var flee_threshold := float(relationship.get("flee_threshold", 70.0))
	var during_reprimand := bool(context.get("during_reprimand", false))

	if anger >= fight_threshold:
		result["decision"] = DECISION_FIGHT
		return result
	if result["reason"] == REASON_ATTACKED_FRIEND:
		var victim_favor := float(relationship.get("victim_favor", 0.0))
		if victim_favor < float(relationship.get(
			"friend_favor_threshold", DEFAULT_FRIEND_FAVOR_THRESHOLD
		)):
			return result
	if fear >= flee_threshold and anger < fight_threshold:
		result["decision"] = DECISION_FLEE
		return result
	if (
		severity >= DEFAULT_IMMEDIATE_THREAT_SEVERITY
		or (
			during_reprimand
			and (
				severity >= DEFAULT_ACTIVE_CONFRONTATION_SEVERITY
				or offense_count >= DEFAULT_ESCALATION_OFFENSE_COUNT
			)
		)
	):
		result["decision"] = DECISION_FIGHT
		return result

	if not bool(context.get("dialogue_available", false)):
		return result

	result["decision"] = DECISION_REPRIMAND
	return result
