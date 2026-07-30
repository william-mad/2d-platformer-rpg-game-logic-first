class_name NpcBehaviorFeedbackFormatter extends RefCounted


static func format_label(
	primary_state: StringName,
	overlay_state: StringName,
	feedback: Dictionary
) -> String:
	var state_line := String(primary_state)
	var intent = feedback.get("intent", {})
	if intent is Dictionary and not intent.is_empty():
		var logical_action := String(intent.get("logical_action_kind", ""))
		if not logical_action.is_empty() and logical_action != String(primary_state):
			state_line += " \u2192 %s" % logical_action
	if overlay_state != &"":
		state_line += " + %s" % String(overlay_state)

	var lines: Array[String] = [state_line]
	if intent is Dictionary and not intent.is_empty():
		lines.append("%s \u00b7 %s \u00b7 p%d" % [
			_get_feedback_text(intent),
			String(intent.get("source", "manual")),
			int(intent.get("priority", 0)),
		])
		var rejected = feedback.get("rejected_intent", {})
		if rejected is Dictionary and not rejected.is_empty():
			lines.append("blocked: %s \u00b7 p%d" % [
				_get_feedback_text(rejected),
				int(rejected.get("priority", 0)),
			])
		else:
			var remaining := float(feedback.get("remaining_commitment_seconds", 0.0))
			if remaining > 0.05:
				lines.append("hold %.1fs" % remaining)
	var social_selection = feedback.get("social_selection", {})
	if (
		social_selection is Dictionary
		and bool(social_selection.get("all_candidates_suppressed", false))
		and String(social_selection.get("reason_code", ""))
			== "no_social_target_due_to_recent_refusal"
	):
		lines.append("social: waiting after refusal")
	var target_selection = feedback.get("target_selection", {})
	if (
		target_selection is Dictionary
		and bool(target_selection.get("all_suppressed", false))
		and String(target_selection.get("reason_code", ""))
			== "all_targets_recently_failed"
	):
		var target_action := String(
			target_selection.get("logical_action", "")
		).strip_edges()
		lines.append(
			"%s targets recently failed"
			% (target_action if not target_action.is_empty() else "Activity")
		)
	var memory = feedback.get("memory", {})
	if memory is Dictionary:
		var recent = memory.get("recent", [])
		if recent is Array and not recent.is_empty() and recent[0] is Dictionary:
			var memory_text := String(
				recent[0].get("debug_feedback_text", "")
			).strip_edges()
			if not memory_text.is_empty():
				lines.append("remembers: %s" % memory_text)
	return "\n".join(lines)


static func _get_feedback_text(intent: Dictionary) -> String:
	var explicit_text := String(intent.get("feedback_text", "")).strip_edges()
	if not explicit_text.is_empty():
		return explicit_text
	var legacy_reason := String(intent.get("reason", "")).strip_edges()
	if not legacy_reason.is_empty():
		return _humanize(legacy_reason)
	var reason_code := String(intent.get("reason_code", "")).strip_edges()
	if not reason_code.is_empty():
		return _humanize(reason_code)
	var logical_action := String(intent.get("logical_action_kind", "")).strip_edges()
	return _humanize(logical_action) if not logical_action.is_empty() else "Current intention"


static func _humanize(value: String) -> String:
	var words := value.replace("_", " ").strip_edges()
	if words.is_empty():
		return words
	return words.left(1).to_upper() + words.substr(1)
