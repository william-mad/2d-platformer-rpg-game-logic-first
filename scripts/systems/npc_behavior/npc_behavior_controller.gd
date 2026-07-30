class_name NpcBehaviorController extends Node

signal intention_accepted(intent: NpcBehaviorIntent)
signal intention_replaced(previous: NpcBehaviorIntent, current: NpcBehaviorIntent)
signal intention_refreshed(intent: NpcBehaviorIntent)
signal intention_cleared(intent: NpcBehaviorIntent, reason: StringName)
signal intention_rejected(candidate: NpcBehaviorIntent, reason: StringName)
signal commitment_changed(remaining_seconds: float)
signal feedback_refresh_requested
signal rejection_feedback_cleared

@export_range(0.0, 30.0, 0.1, "suffix:s") var minimum_autonomous_commitment_seconds: float = 2.0
@export_range(0, 1000, 1) var autonomous_interruption_margin: int = 15
@export_range(0.0, 10.0, 0.1, "suffix:s") var rejection_feedback_seconds: float = 2.0
@export_range(0.1, 2.0, 0.05, "suffix:s") var feedback_refresh_seconds: float = 0.25

var current_intent: NpcBehaviorIntent
var accepted_at_usec: int = 0
var last_rejected_candidate: NpcBehaviorIntent
var last_rejection_reason: StringName = &""
var rejected_at_usec: int = 0

var _commitment_expiry_reported: bool = true
var _rejection_generation: int = 0
var _feedback_refresh_elapsed: float = 0.0


func _process(delta: float) -> void:
	if current_intent == null or _commitment_expiry_reported:
		_feedback_refresh_elapsed = 0.0
		return
	var remaining := get_remaining_commitment_seconds()
	if remaining > 0.0:
		_feedback_refresh_elapsed += delta
		if _feedback_refresh_elapsed >= feedback_refresh_seconds:
			_feedback_refresh_elapsed = 0.0
			feedback_refresh_requested.emit()
		return
	_commitment_expiry_reported = true
	_feedback_refresh_elapsed = 0.0
	commitment_changed.emit(0.0)


func evaluate_candidate(candidate: NpcBehaviorIntent, now_usec: int = -1) -> Dictionary:
	var evaluated_at := _resolve_now_usec(now_usec)
	var result := _decision_result(candidate, evaluated_at)
	if candidate == null:
		result["reason"] = "invalid_candidate"
		return result
	if current_intent == null:
		result["accepted"] = true
		result["reason"] = "no_current_intent"
		return result
	if candidate.lifecycle_only:
		result["accepted"] = true
		result["reason"] = "lifecycle_bypass"
		return result
	if current_intent.is_same_logical_intention(candidate):
		result["accepted"] = true
		result["reason"] = "same_intention"
		return result
	if not NpcBehaviorIntent.is_autonomous_source(candidate.source):
		result["accepted"] = true
		result["reason"] = "source_bypasses_commitment"
		return result

	var remaining := get_remaining_commitment_seconds(evaluated_at)
	result["remaining_commitment_seconds"] = remaining
	if remaining <= 0.0:
		result["accepted"] = true
		result["reason"] = "commitment_expired"
		return result

	var required_priority := (
		current_intent.priority
		+ maxi(current_intent.interrupt_priority_margin, autonomous_interruption_margin)
	)
	result["required_interrupt_priority"] = required_priority
	if candidate.priority >= required_priority:
		result["accepted"] = true
		result["reason"] = "interrupt_margin_met"
		return result

	result["reason"] = "behavior_commitment_active"
	return result


func commit_candidate(candidate: NpcBehaviorIntent, now_usec: int = -1) -> void:
	if candidate == null:
		return
	var committed_at := _resolve_now_usec(now_usec)
	if candidate.lifecycle_only:
		if current_intent != null and current_intent.is_same_logical_intention(candidate):
			refresh_current_intent(candidate)
		return
	if current_intent != null and current_intent.is_same_logical_intention(candidate):
		refresh_current_intent(candidate)
		return

	var previous := current_intent
	current_intent = candidate
	accepted_at_usec = committed_at
	_commitment_expiry_reported = candidate.minimum_commitment_seconds <= 0.0
	if previous == null:
		intention_accepted.emit(candidate)
	else:
		intention_replaced.emit(previous, candidate)
	commitment_changed.emit(get_remaining_commitment_seconds(committed_at))


func refresh_current_intent(
	candidate: NpcBehaviorIntent,
	expected_session_id: String = ""
) -> bool:
	if current_intent == null or candidate == null:
		return false
	var expected_id := expected_session_id.strip_edges()
	if not expected_id.is_empty() and current_intent.action_session_id != expected_id:
		return false
	if not current_intent.is_same_logical_intention(candidate):
		return false
	current_intent = current_intent.refreshed_copy({
		"requested_primary_state": candidate.requested_primary_state,
		"logical_action_kind": candidate.logical_action_kind,
		"source": candidate.source,
		"reason": candidate.reason,
		"reason_code": candidate.reason_code,
		"feedback_text": candidate.feedback_text,
		"origin_value": candidate.origin_value,
		"lifecycle_only": false,
		"priority": candidate.priority,
		"target_persistent_id": candidate.target_persistent_id,
		"action_session_id": candidate.action_session_id,
		"minimum_commitment_seconds": candidate.minimum_commitment_seconds,
		"interrupt_priority_margin": candidate.interrupt_priority_margin,
		"metadata": candidate.metadata,
	})
	_commitment_expiry_reported = get_remaining_commitment_seconds() <= 0.0
	intention_refreshed.emit(current_intent)
	return true


func reject_candidate(candidate: NpcBehaviorIntent, reason: StringName) -> void:
	last_rejected_candidate = candidate
	last_rejection_reason = reason
	rejected_at_usec = Time.get_ticks_usec()
	_rejection_generation += 1
	var generation := _rejection_generation
	intention_rejected.emit(candidate, reason)
	if rejection_feedback_seconds <= 0.0 or not is_inside_tree():
		return
	get_tree().create_timer(rejection_feedback_seconds).timeout.connect(
		func() -> void:
			if generation != _rejection_generation:
				return
			clear_rejection_feedback()
	)


func clear_rejection_feedback() -> void:
	if last_rejected_candidate == null and last_rejection_reason == &"":
		return
	last_rejected_candidate = null
	last_rejection_reason = &""
	rejected_at_usec = 0
	rejection_feedback_cleared.emit()


func clear_intent_for_session(session_id: String, reason: StringName) -> bool:
	var clean_id := session_id.strip_edges()
	if (
		current_intent == null
		or clean_id.is_empty()
		or current_intent.action_session_id.strip_edges() != clean_id
	):
		return false
	var cleared := current_intent
	current_intent = null
	accepted_at_usec = 0
	_commitment_expiry_reported = true
	intention_cleared.emit(cleared, reason)
	commitment_changed.emit(0.0)
	return true


func get_remaining_commitment_seconds(now_usec: int = -1) -> float:
	if current_intent == null or accepted_at_usec <= 0:
		return 0.0
	var elapsed_seconds := float(_resolve_now_usec(now_usec) - accepted_at_usec) / 1000000.0
	return maxf(current_intent.minimum_commitment_seconds - elapsed_seconds, 0.0)


func get_current_intent_descriptor() -> Dictionary:
	return current_intent.to_descriptor() if current_intent != null else {}


func get_feedback_descriptor(now_usec: int = -1) -> Dictionary:
	return {
		"intent": get_current_intent_descriptor(),
		"remaining_commitment_seconds": get_remaining_commitment_seconds(now_usec),
		"rejected_intent": (
			last_rejected_candidate.to_descriptor()
			if last_rejected_candidate != null
			else {}
		),
		"rejection_reason": String(last_rejection_reason),
	}


func get_debug_summary(now_usec: int = -1) -> Dictionary:
	return {
		"current_intent": get_current_intent_descriptor(),
		"accepted_at_usec": accepted_at_usec,
		"remaining_commitment_seconds": get_remaining_commitment_seconds(now_usec),
		"last_rejected_candidate": (
			last_rejected_candidate.to_descriptor()
			if last_rejected_candidate != null
			else {}
		),
		"last_rejection_reason": String(last_rejection_reason),
		"rejected_at_usec": rejected_at_usec,
	}


func _decision_result(candidate: NpcBehaviorIntent, now_usec: int) -> Dictionary:
	return {
		"accepted": false,
		"reason": "rejected",
		"remaining_commitment_seconds": get_remaining_commitment_seconds(now_usec),
		"required_interrupt_priority": (
			current_intent.priority + autonomous_interruption_margin
			if current_intent != null
			else 0
		),
		"current_intent_id": current_intent.intent_id if current_intent != null else "",
		"current_session_id": (
			current_intent.action_session_id if current_intent != null else ""
		),
		"candidate_intent_id": candidate.intent_id if candidate != null else "",
		"candidate_session_id": candidate.action_session_id if candidate != null else "",
	}


func _resolve_now_usec(now_usec: int) -> int:
	return now_usec if now_usec >= 0 else Time.get_ticks_usec()
