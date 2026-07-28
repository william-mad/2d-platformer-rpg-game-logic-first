class_name InteractiveActivityModule extends Node

signal result_changed(result: Dictionary)
signal finish_requested(result: Dictionary)
signal cancel_requested(reason: StringName, result: Dictionary)

var activity_context: Dictionary = {}
var activity_input: InteractiveActivityInputSource
var _result: Dictionary = {}
var _running: bool = false
var _stopped: bool = false


func _process(delta: float) -> void:
	if not _running:
		return
	_result["elapsed_seconds"] = (
		float(_result.get("elapsed_seconds", 0.0)) + maxf(delta, 0.0)
	)


func configure(
	context: Dictionary,
	input_source: InteractiveActivityInputSource
) -> bool:
	if input_source == null:
		return false
	var session_id := String(context.get("session_id", "")).strip_edges()
	var activity_id := String(context.get("activity_id", "")).strip_edges()
	if session_id.is_empty() or activity_id.is_empty():
		return false
	activity_context = context.duplicate(true)
	activity_input = input_source
	_result = make_standard_result(activity_id, session_id, "prepared", "")
	_running = false
	_stopped = false
	return true


func start_activity() -> void:
	if _stopped or _running:
		return
	_running = true
	_result["status"] = "running"
	result_changed.emit(get_result())


func stop_activity(reason: StringName) -> Dictionary:
	if _stopped:
		return get_result()
	_stopped = true
	_running = false
	if String(_result.get("status", "")) not in ["completed", "cancelled"]:
		_result["status"] = "stopped"
	_result["finish_reason"] = String(reason)
	return get_result()


func get_result() -> Dictionary:
	return _result.duplicate(true)


func publish_result(changes: Dictionary = {}) -> Dictionary:
	_apply_result_changes(changes)
	var snapshot := get_result()
	result_changed.emit(snapshot)
	return snapshot


func request_finish(changes: Dictionary = {}) -> void:
	if _stopped:
		return
	_apply_result_changes(changes)
	_result["status"] = "completed"
	_running = false
	_stopped = true
	finish_requested.emit(get_result())


func request_cancel(reason: StringName, changes: Dictionary = {}) -> void:
	if _stopped:
		return
	_apply_result_changes(changes)
	_result["status"] = "cancelled"
	_result["finish_reason"] = String(reason)
	_running = false
	_stopped = true
	cancel_requested.emit(reason, get_result())


func is_running() -> bool:
	return _running


func _apply_result_changes(changes: Dictionary) -> void:
	for key in changes:
		if String(key) == "details" and changes[key] is Dictionary:
			var merged_details: Dictionary = _result.get("details", {}).duplicate(true)
			merged_details.merge(changes[key], true)
			_result["details"] = merged_details
		else:
			_result[key] = changes[key]


static func make_standard_result(
	activity_id: String,
	session_id: String,
	status: String,
	finish_reason: String
) -> Dictionary:
	return {
		"activity_id": activity_id,
		"session_id": session_id,
		"status": status,
		"finish_reason": finish_reason,
		"elapsed_seconds": 0.0,
		"score": 0.0,
		"attempts": 0,
		"successes": 0,
		"failures": 0,
		"details": {},
	}
