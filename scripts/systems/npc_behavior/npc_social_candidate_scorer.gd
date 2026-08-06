class_name NpcSocialCandidateScorer extends RefCounted

const NEUTRAL_FAVOR: float = 50.0
const MIN_RELATIONSHIP_VALUE: float = 0.0
const MAX_RELATIONSHIP_VALUE: float = 100.0

const FAVOR_MAX_ABSOLUTE_CONTRIBUTION: float = 30.0
const LOVE_MAX_CONTRIBUTION: float = 15.0
const FEAR_MAX_PENALTY: float = 15.0
const ANGER_MAX_PENALTY: float = 30.0

const AUTHORED_PREFERENCE_BONUS: float = 20.0
const DISTANCE_PIXELS_PER_POINT: float = 128.0
const MAX_DISTANCE_PENALTY: float = 10.0
const MIN_TOTAL_SCORE: float = -100.0
const MAX_TOTAL_SCORE: float = 100.0


func score_candidate(
	requester_id: StringName,
	candidate_id: StringName,
	context: Dictionary
) -> Dictionary:
	var relationship = context.get("relationship", {})
	if not (relationship is Dictionary):
		relationship = {}
	var favor := _bounded_value(
		relationship.get("favor", NEUTRAL_FAVOR),
		NEUTRAL_FAVOR
	)
	var love := _bounded_value(relationship.get("love", 0.0), 0.0)
	var fear := _bounded_value(relationship.get("fear", 0.0), 0.0)
	var anger := _bounded_value(relationship.get("anger", 0.0), 0.0)

	var favor_contribution := (
		((favor - NEUTRAL_FAVOR) / NEUTRAL_FAVOR)
		* FAVOR_MAX_ABSOLUTE_CONTRIBUTION
	)
	var love_contribution := (
		(love / MAX_RELATIONSHIP_VALUE) * LOVE_MAX_CONTRIBUTION
	)
	var fear_contribution := -(
		(fear / MAX_RELATIONSHIP_VALUE) * FEAR_MAX_PENALTY
	)
	var anger_contribution := -(
		(anger / MAX_RELATIONSHIP_VALUE) * ANGER_MAX_PENALTY
	)
	var relationship_score := (
		favor_contribution
		+ love_contribution
		+ fear_contribution
		+ anger_contribution
	)
	var preference_bonus := (
		AUTHORED_PREFERENCE_BONUS
		if bool(context.get("is_authored_preference", false))
		else 0.0
	)
	var has_live_distance := bool(context.get("has_live_distance", false))
	var live_distance := 0.0
	var distance_penalty := 0.0
	if has_live_distance:
		live_distance = maxf(float(context.get("live_distance", 0.0)), 0.0)
		if is_finite(live_distance):
			distance_penalty = -minf(
				live_distance / DISTANCE_PIXELS_PER_POINT,
				MAX_DISTANCE_PENALTY
			)
		else:
			has_live_distance = false
			live_distance = 0.0

	return {
		"requester_id": requester_id,
		"candidate_id": candidate_id,
		"total_score": clampf(
			relationship_score + preference_bonus + distance_penalty,
			MIN_TOTAL_SCORE,
			MAX_TOTAL_SCORE
		),
		"relationship_score": relationship_score,
		"authored_preference_bonus": preference_bonus,
		"preference_bonus": preference_bonus,
		"distance_penalty": distance_penalty,
		"has_live_distance": has_live_distance,
		"live_distance": live_distance,
		"components": {
			"favor": favor_contribution,
			"love": love_contribution,
			"fear": fear_contribution,
			"anger": anger_contribution,
		},
	}


static func _bounded_value(value: Variant, fallback: float) -> float:
	var numeric := float(value)
	if not is_finite(numeric):
		return fallback
	return clampf(numeric, MIN_RELATIONSHIP_VALUE, MAX_RELATIONSHIP_VALUE)
