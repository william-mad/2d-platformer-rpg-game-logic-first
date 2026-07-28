class_name InteractiveActivityRunner extends Node

signal result_changed(result: Dictionary)
signal activity_finished(result: Dictionary)
signal activity_cancelled(reason: StringName, result: Dictionary)
signal local_shutdown(reason: StringName, result: Dictionary)

const STATE_IDLE := &"idle"
const STATE_PREPARED := &"prepared"
const STATE_RUNNING := &"running"
const STATE_FINISHING := &"finishing"
const STATE_CLOSED := &"closed"

@export var host_scene: PackedScene = preload(
	"res://scenes/activities/interactive_activity_host.tscn"
)
@export_range(0.0, 1.0, 0.01, "suffix:s") var neutral_handoff_timeout_seconds: float = 0.15

var state: StringName = STATE_IDLE
var player: Node
var claim_token: int = 0
var session_id: String = ""
var input_source: InteractiveActivityInputSource
var presentation_host: InteractiveActivityHost
var last_result: Dictionary = {}
var _terminal_kind: StringName = &""
var _terminal_reason: StringName = &""
var _neutral_deadline_msec: int = 0
var _terminal_emitted: bool = false
var _exiting_tree: bool = false


func _ready() -> void:
	set_process(false)


func _process(_delta: float) -> void:
	if state != STATE_FINISHING:
		return
	if (
		input_source == null
		or input_source.is_neutral()
		or Time.get_ticks_msec() >= _neutral_deadline_msec
	):
		_finalize_close()


func _exit_tree() -> void:
	_exiting_tree = true
	_shutdown_runtime_immediate()


func prepare_activity(
	new_player: Node,
	definitions: Array[InteractiveActivityDefinition],
	context: Dictionary,
	presentation_parent: Node,
	world_anchor: Vector2,
	launch_options: InteractiveActivityLaunchOptions = null
) -> Dictionary:
	if state not in [STATE_IDLE, STATE_CLOSED]:
		return _prepare_rejected("runner_not_idle")
	if (
		new_player == null
		or not is_instance_valid(new_player)
		or not new_player.is_inside_tree()
	):
		return _prepare_rejected("player_invalid")
	if (
		presentation_parent == null
		or not is_instance_valid(presentation_parent)
		or not presentation_parent.is_inside_tree()
	):
		return _prepare_rejected("presentation_parent_invalid")
	if definitions.is_empty():
		return _prepare_rejected("definitions_empty")
	for definition in definitions:
		if definition == null or not definition.is_valid_definition():
			return _prepare_rejected("definition_invalid")
	var requested_session_id := String(context.get("session_id", "")).strip_edges()
	if requested_session_id.is_empty():
		return _prepare_rejected("session_id_missing")
	if host_scene == null:
		return _prepare_rejected("host_scene_missing")

	_reset_for_prepare()
	player = new_player
	session_id = requested_session_id
	input_source = InteractiveActivityInputSource.new()
	input_source.name = "InteractiveActivityInputSource"
	add_child(input_source)

	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow == null or not gameplay_flow.has_method("acquire_player_control_claim"):
		return _abort_preparation("gameplay_flow_missing")
	claim_token = int(gameplay_flow.call(
		"acquire_player_control_claim",
		self,
		player,
		&"interactive_activity",
		&"ui_only"
	))
	if claim_token == 0:
		return _abort_preparation("player_control_claim_rejected")

	if player.has_method("prepare_for_external_activity"):
		var preparation = player.call(
			"prepare_for_external_activity", &"interactive_activity"
		)
		if preparation is Dictionary and not bool(preparation.get("accepted", false)):
			return _abort_preparation(String(
				preparation.get("reason", "player_preparation_rejected")
			))

	var host_instance := host_scene.instantiate()
	presentation_host = host_instance as InteractiveActivityHost
	if presentation_host == null:
		host_instance.free()
		return _abort_preparation("host_type_invalid")
	presentation_parent.add_child(presentation_host)
	if not presentation_host.configure_host(
		definitions,
		context,
		input_source,
		world_anchor,
		launch_options
	):
		return _abort_preparation("host_configuration_rejected")
	_connect_host_signals()
	input_source.set_activity_input_enabled(false)
	state = STATE_PREPARED
	return {
		"accepted": true,
		"reason": "",
		"session_id": session_id,
		"claim_token": claim_token,
	}


func commit_activity() -> bool:
	if state != STATE_PREPARED or presentation_host == null or input_source == null:
		return false
	input_source.set_activity_input_enabled(true)
	state = STATE_RUNNING
	if not presentation_host.start_activity():
		state = STATE_PREPARED
		cancel_activity(&"host_start_rejected")
		return false
	set_process(true)
	return true


func finish_activity(reason: StringName = &"completed") -> Dictionary:
	return _begin_terminal(&"finished", reason, {})


func cancel_activity(reason: StringName = &"cancelled") -> Dictionary:
	return _begin_terminal(&"cancelled", reason, {})


func shutdown_local(reason: StringName = &"local_shutdown") -> void:
	if state in [STATE_IDLE, STATE_CLOSED]:
		return
	_begin_terminal(&"local_shutdown", reason, {})
	_finalize_close()


func is_active() -> bool:
	return state in [STATE_PREPARED, STATE_RUNNING, STATE_FINISHING]


func get_result() -> Dictionary:
	return last_result.duplicate(true)


func get_player_claim_token() -> int:
	return claim_token


func get_presentation_host() -> InteractiveActivityHost:
	return presentation_host


func get_input_source() -> InteractiveActivityInputSource:
	return input_source


func consume_player_interaction_input(candidate_player: Node) -> bool:
	return (
		candidate_player == player
		and input_source != null
		and input_source.consume_player_interaction_input(candidate_player)
	)


func _begin_terminal(
	terminal_kind: StringName,
	reason: StringName,
	provided_result: Dictionary
) -> Dictionary:
	if state in [STATE_FINISHING, STATE_CLOSED]:
		return get_result()
	if state not in [STATE_PREPARED, STATE_RUNNING]:
		return get_result()

	state = STATE_FINISHING
	_terminal_kind = terminal_kind
	_terminal_reason = reason
	if input_source != null:
		input_source.begin_neutral_handoff()
	var module_result := {}
	if presentation_host != null:
		module_result = presentation_host.stop_activity(reason)
	var source_result := provided_result if not provided_result.is_empty() else module_result
	last_result = _standardize_result(source_result, terminal_kind, reason)
	_destroy_presentation(reason)
	_neutral_deadline_msec = (
		Time.get_ticks_msec() + int(maxf(neutral_handoff_timeout_seconds, 0.0) * 1000.0)
	)
	set_process(true)
	if input_source == null or input_source.is_neutral():
		_finalize_close()
	return get_result()


func _on_host_result_changed(result: Dictionary) -> void:
	if not _result_matches_current_session(result) or state != STATE_RUNNING:
		return
	last_result = _standardize_result(result, &"running", &"")
	result_changed.emit(last_result.duplicate(true))


func _on_host_finish_requested(result: Dictionary) -> void:
	if not _result_matches_current_session(result) or state != STATE_RUNNING:
		return
	var finish_reason := String(result.get("finish_reason", "")).strip_edges()
	if finish_reason.is_empty():
		finish_reason = "module_finished"
	_begin_terminal(
		&"finished",
		StringName(finish_reason),
		result
	)


func _on_host_cancel_requested(reason: StringName, result: Dictionary) -> void:
	if not _result_matches_current_session(result) or state != STATE_RUNNING:
		return
	_begin_terminal(&"cancelled", reason, result)


func _result_matches_current_session(result: Dictionary) -> bool:
	return (
		not session_id.is_empty()
		and String(result.get("session_id", "")).strip_edges() == session_id
	)


func _standardize_result(
	source: Dictionary,
	terminal_kind: StringName,
	reason: StringName
) -> Dictionary:
	var activity_id := String(source.get("activity_id", ""))
	var status := String(source.get("status", ""))
	if terminal_kind == &"finished":
		status = "completed"
	elif terminal_kind == &"cancelled":
		status = "cancelled"
	elif terminal_kind == &"local_shutdown":
		status = "local_shutdown"
	elif status.is_empty():
		status = String(terminal_kind)
	var result := InteractiveActivityModule.make_standard_result(
		activity_id,
		session_id,
		status,
		String(reason)
	)
	for key in result.keys():
		if source.has(key):
			result[key] = source[key]
	result["session_id"] = session_id
	result["status"] = status
	result["finish_reason"] = String(reason)
	var details = source.get("details", {})
	result["details"] = details.duplicate(true) if details is Dictionary else {}
	return result


func _connect_host_signals() -> void:
	if presentation_host == null:
		return
	presentation_host.result_changed.connect(_on_host_result_changed)
	presentation_host.finish_requested.connect(_on_host_finish_requested)
	presentation_host.cancel_requested.connect(_on_host_cancel_requested)


func _disconnect_host_signals() -> void:
	if presentation_host == null:
		return
	var result_callback := Callable(self, "_on_host_result_changed")
	var finish_callback := Callable(self, "_on_host_finish_requested")
	var cancel_callback := Callable(self, "_on_host_cancel_requested")
	if presentation_host.result_changed.is_connected(result_callback):
		presentation_host.result_changed.disconnect(result_callback)
	if presentation_host.finish_requested.is_connected(finish_callback):
		presentation_host.finish_requested.disconnect(finish_callback)
	if presentation_host.cancel_requested.is_connected(cancel_callback):
		presentation_host.cancel_requested.disconnect(cancel_callback)


func _destroy_presentation(
	reason: StringName,
	detach_immediately: bool = true
) -> void:
	if presentation_host == null:
		return
	_disconnect_host_signals()
	presentation_host.shutdown_host(reason)
	if detach_immediately and presentation_host.get_parent() != null:
		presentation_host.get_parent().remove_child(presentation_host)
	presentation_host.queue_free()
	presentation_host = null


func _finalize_close() -> void:
	if state != STATE_FINISHING:
		return
	_release_claim_once()
	if input_source != null:
		input_source.force_neutral()
	state = STATE_CLOSED
	set_process(false)
	if _terminal_emitted:
		return
	_terminal_emitted = true
	match _terminal_kind:
		&"finished":
			activity_finished.emit(last_result.duplicate(true))
		&"cancelled":
			activity_cancelled.emit(_terminal_reason, last_result.duplicate(true))
		&"local_shutdown":
			local_shutdown.emit(_terminal_reason, last_result.duplicate(true))


func _abort_preparation(reason: String) -> Dictionary:
	if presentation_host != null:
		_destroy_presentation(StringName(reason))
	if input_source != null:
		input_source.force_neutral()
		if input_source.get_parent() == self:
			remove_child(input_source)
		input_source.queue_free()
		input_source = null
	_release_claim_once()
	player = null
	session_id = ""
	state = STATE_IDLE
	return _prepare_rejected(reason)


func _prepare_rejected(reason: String) -> Dictionary:
	return {
		"accepted": false,
		"reason": reason,
		"session_id": session_id,
		"claim_token": 0,
	}


func _release_claim_once() -> void:
	if claim_token == 0:
		return
	var token_to_release := claim_token
	claim_token = 0
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if gameplay_flow != null and gameplay_flow.has_method("release_player_control_claim"):
		gameplay_flow.call("release_player_control_claim", token_to_release, self)


func _reset_for_prepare() -> void:
	_shutdown_runtime_immediate()
	state = STATE_IDLE
	player = null
	session_id = ""
	last_result = {}
	_terminal_kind = &""
	_terminal_reason = &""
	_neutral_deadline_msec = 0
	_terminal_emitted = false


func _shutdown_runtime_immediate() -> void:
	if presentation_host != null:
		_destroy_presentation(&"runner_shutdown", not _exiting_tree)
	_release_claim_once()
	if input_source != null:
		input_source.force_neutral()
		if input_source.get_parent() == self:
			remove_child(input_source)
		input_source.queue_free()
		input_source = null
	set_process(false)
