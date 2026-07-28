class_name ProbeInteractiveActivityModule extends InteractiveActivityModule


func _process(delta: float) -> void:
	super._process(delta)
	if not is_running() or activity_input == null:
		return
	if activity_input.was_role_pressed(&"confirm"):
		request_finish({
			"score": 12.5,
			"attempts": 1,
			"successes": 1,
			"details": {"probe_confirmed": true},
		})


func stop_activity(reason: StringName) -> Dictionary:
	if String(_result.get("status", "")) not in ["completed", "cancelled"]:
		_result["score"] = 7.5
		_result["attempts"] = 1
		_result["successes"] = 1
		_result["details"] = {"probe_stopped": true}
	return super.stop_activity(reason)
