class_name NpcFeedbackAdapter extends Node

const Catalog = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_catalog.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const PlayerInteractionMemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_player_interaction_memory_policy.gd"
)
const ActionSession = preload("res://scripts/systems/npc_action_session.gd")
const Presenter = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_presenter.gd"
)

var _machine: NpcStateMachine
var _controller: NpcBehaviorController
var _memory: NpcShortTermMemory
var _presenter: Presenter
var _late_schedule_sessions_seen: Dictionary = {}
var _overtime_schedule_sessions_seen: Dictionary = {}


func bind(
	machine: NpcStateMachine,
	controller: NpcBehaviorController,
	memory: NpcShortTermMemory,
	presenter: Presenter
) -> void:
	_machine = machine
	_controller = controller
	_memory = memory
	_presenter = presenter
	if _presenter == null:
		return
	_presenter.player_feedback_enabled = (
		_machine == null or _machine.player_feedback_enabled
	)
	_presenter.bind_npc(_machine.npc if _machine != null else null)
	_bind_controller_signals()
	_bind_memory_signals()
	_bind_machine_signals()
	_bind_schedule_commit_signal()
	_bind_control_claim_signal()
	_refresh_state_suppression()


func _bind_controller_signals() -> void:
	if _controller == null:
		return
	if not _controller.intention_accepted.is_connected(_on_intention_accepted):
		_controller.intention_accepted.connect(_on_intention_accepted)
	if not _controller.intention_replaced.is_connected(_on_intention_replaced):
		_controller.intention_replaced.connect(_on_intention_replaced)


func _bind_memory_signals() -> void:
	if _memory == null:
		return
	if not _memory.memory_added.is_connected(_on_memory_added):
		_memory.memory_added.connect(_on_memory_added)
	if not _memory.memory_merged.is_connected(_on_memory_merged):
		_memory.memory_merged.connect(_on_memory_merged)


func _bind_machine_signals() -> void:
	if _machine == null:
		return
	if not _machine.state_changed.is_connected(_on_state_changed):
		_machine.state_changed.connect(_on_state_changed)
	if not _machine.policy_feedback_changed.is_connected(
		_on_policy_feedback_changed
	):
		_machine.policy_feedback_changed.connect(_on_policy_feedback_changed)
	if not _machine.activity_target_selection_committed.is_connected(
		_on_activity_target_selection_committed
	):
		_machine.activity_target_selection_committed.connect(
			_on_activity_target_selection_committed
		)


func _bind_control_claim_signal() -> void:
	var gameplay_flow := get_node_or_null("/root/GameplayFlow")
	if (
		gameplay_flow == null
		or not gameplay_flow.has_signal(&"npc_control_claim_changed")
	):
		return
	var callback := Callable(self, "_on_npc_control_claim_changed")
	if not gameplay_flow.is_connected(&"npc_control_claim_changed", callback):
		gameplay_flow.connect(&"npc_control_claim_changed", callback)


func _bind_schedule_commit_signal() -> void:
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if (
		simulator == null
		or not simulator.has_signal(&"scheduled_activity_committed")
	):
		return
	var callback := Callable(self, "_on_scheduled_activity_committed")
	if not simulator.is_connected(&"scheduled_activity_committed", callback):
		simulator.connect(&"scheduled_activity_committed", callback)
	if simulator.has_signal(&"scheduled_activity_entered_overtime"):
		var overtime_callback := Callable(
			self,
			"_on_scheduled_activity_entered_overtime"
		)
		if not simulator.is_connected(
			&"scheduled_activity_entered_overtime",
			overtime_callback
		):
			simulator.connect(
				&"scheduled_activity_entered_overtime",
				overtime_callback
			)


func _on_intention_accepted(intent: NpcBehaviorIntent) -> void:
	_submit_intention(intent)


func _on_intention_replaced(
	_previous: NpcBehaviorIntent,
	current: NpcBehaviorIntent
) -> void:
	_submit_intention(current)


func _on_scheduled_activity_committed(
	npc_id: StringName,
	activity: Dictionary
) -> void:
	if _presenter == null or _machine == null or _machine.npc == null:
		return
	if String(ActionSession.get_persistent_id(_machine.npc)) != String(npc_id):
		return
	var locations := get_node_or_null("/root/NpcLocations")
	if (
		locations != null
		and locations.has_method("get_live_npc")
		and locations.call("get_live_npc", String(npc_id)) != _machine.npc
	):
		return
	if String(activity.get("source", "schedule")) != "schedule":
		return
	if String(activity.get("schedule_phase", "")) != "late":
		return
	var session_id := ActionSession._descriptor_session_id(activity)
	if session_id.is_empty() or _late_schedule_sessions_seen.has(session_id):
		return
	var occurrence_key := String(activity.get(
		"schedule_occurrence_key",
		""
	)).strip_edges()
	if occurrence_key.is_empty():
		return
	_late_schedule_sessions_seen[session_id] = true
	var cue := Catalog.create_cue(&"schedule_running_late", {
		"source_session_id": session_id,
		"metadata": {
			"identity_key": "schedule_running_late:%s" % occurrence_key,
			"cooldown_key": "schedule_running_late",
			"spot_id": StringName(String(activity.get("spot_id", ""))),
			"schedule_occurrence_key": occurrence_key,
			"schedule_window_index": int(activity.get(
				"schedule_window_index",
				-1
			)),
			"schedule_lateness_game_hours": float(activity.get(
				"schedule_lateness_game_hours",
				0.0
			)),
			"schedule_effective_priority": int(activity.get(
				"schedule_effective_priority",
				activity.get("priority", 0)
			)),
		},
	})
	_presenter.submit_cue(cue)


func _on_scheduled_activity_entered_overtime(
	npc_id: StringName,
	activity: Dictionary,
	continuation_decision: Dictionary
) -> void:
	if _presenter == null or _machine == null or _machine.npc == null:
		return
	if String(ActionSession.get_persistent_id(_machine.npc)) != String(npc_id):
		return
	var locations := get_node_or_null("/root/NpcLocations")
	if (
		locations != null
		and locations.has_method("get_live_npc")
		and locations.call("get_live_npc", String(npc_id)) != _machine.npc
	):
		return
	if String(activity.get("source", "schedule")) != "schedule":
		return
	if String(continuation_decision.get("completion_policy", "")) != "finish_current":
		return
	if not bool(continuation_decision.get("may_continue", false)):
		return
	if String(continuation_decision.get("reason_code", "")) != "finishing_current_activity":
		return
	var session_id := ActionSession._descriptor_session_id(activity)
	if session_id.is_empty() or _overtime_schedule_sessions_seen.has(session_id):
		return
	if (
		_machine.has_method("get_active_action_session_id")
		and String(_machine.call("get_active_action_session_id")) != session_id
	):
		return
	_overtime_schedule_sessions_seen[session_id] = true
	var cue := Catalog.create_cue(&"schedule_finishing_up", {
		"source_session_id": session_id,
		"metadata": {
			"identity_key": "schedule_finishing_up:%s" % session_id,
			"cooldown_key": "schedule_finishing_up:%s" % session_id,
			"spot_id": StringName(String(activity.get("spot_id", ""))),
			"schedule_occurrence_key": String(activity.get(
				"schedule_occurrence_key",
				""
			)),
			"schedule_overtime_game_hours": float(continuation_decision.get(
				"overtime_game_hours",
				0.0
			)),
		},
	})
	_presenter.submit_cue(cue)


func _submit_intention(intent: NpcBehaviorIntent) -> void:
	if _presenter == null or intent == null or intent.lifecycle_only:
		return
	if intent.source == NpcBehaviorIntent.SOURCE_INTERNAL:
		return
	var cue_code := _intention_cue_code(intent)
	if cue_code == &"":
		return
	var stable_key := String(cue_code)
	var cue := Catalog.create_cue(cue_code, {
		"source_intent_id": intent.intent_id,
		"source_session_id": intent.action_session_id,
		"metadata": {
			"identity_key": stable_key,
			"cooldown_key": stable_key,
			"logical_action": intent.logical_action_kind,
			"reason_code": intent.reason_code,
			"source": intent.source,
		},
	})
	_presenter.submit_cue(cue)


func _intention_cue_code(intent: NpcBehaviorIntent) -> StringName:
	if intent.source == NpcBehaviorIntent.SOURCE_EMERGENCY:
		return (
			intent.reason_code
			if Catalog.has_code(intent.reason_code)
			else &"emergency"
		)
	if intent.source == NpcBehaviorIntent.SOURCE_NEED:
		match intent.logical_action_kind:
			&"Eat":
				return &"hunger_high" if intent.reason_code == &"hunger_high" else &""
			&"Rest":
				return &"tired_high" if intent.reason_code == &"tired_high" else &""
			&"Recreation":
				return &"boredom_high" if intent.reason_code == &"boredom_high" else &""
	if (
		intent.source == NpcBehaviorIntent.SOURCE_SOCIAL_AI
		and intent.logical_action_kind in [&"Talk", &"LookForTalkTarget"]
		and intent.reason_code == &"social_need_high"
	):
		return &"social_need_high"
	return &""


func _on_memory_added(descriptor: Dictionary) -> void:
	_submit_memory(descriptor)


func _on_memory_merged(descriptor: Dictionary) -> void:
	_submit_memory(descriptor)


func _submit_memory(descriptor: Dictionary) -> void:
	if _presenter == null:
		return
	var event_type := StringName(String(descriptor.get("event_type", "")))
	if event_type not in [
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		MemoryPolicy.EVENT_MOVEMENT_FAILED,
		MemoryPolicy.EVENT_INTENTION_TARGET_LOST,
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
	]:
		return
	if (
		event_type == MemoryPolicy.EVENT_HARMED_BY_ACTOR
		and not _memory_subject_is_current_player(descriptor)
	):
		return
	var memory_id := String(descriptor.get("memory_id", "")).strip_edges()
	if memory_id.is_empty():
		return
	var cooldown_key := _memory_cooldown_key(event_type, descriptor)
	var cue := Catalog.create_cue(event_type, {
		"source_memory_id": memory_id,
		"source_session_id": String(descriptor.get(
			"action_session_id",
			""
		)),
		"metadata": {
			"identity_key": "%s:memory:%s" % [
				String(event_type),
				memory_id,
			],
			"cooldown_key": cooldown_key,
			"subject_id": descriptor.get("subject_id", &""),
			"target_id": descriptor.get("target_id", &""),
			"logical_action": descriptor.get("logical_action", &""),
			"occurrence_count": int(descriptor.get("occurrence_count", 1)),
		},
	})
	_presenter.submit_cue(cue)


func _memory_cooldown_key(
	event_type: StringName,
	descriptor: Dictionary
) -> String:
	match event_type:
		MemoryPolicy.EVENT_CONVERSATION_REFUSED:
			return "%s:%s" % [
				String(event_type),
				String(descriptor.get("subject_id", "")),
			]
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE, \
		MemoryPolicy.EVENT_MOVEMENT_FAILED, \
		MemoryPolicy.EVENT_INTENTION_TARGET_LOST:
			return "%s:%s:%s" % [
				String(event_type),
				String(descriptor.get("logical_action", "")),
				String(descriptor.get("target_id", "")),
			]
		MemoryPolicy.EVENT_HARMED_BY_ACTOR:
			return "%s:%s" % [
				String(event_type),
				String(descriptor.get("subject_id", "")),
			]
	return String(event_type)


func _memory_subject_is_current_player(descriptor: Dictionary) -> bool:
	if _machine == null or _machine.npc == null or not _machine.npc.is_inside_tree():
		return false
	var subject_id := StringName(String(descriptor.get(
		"subject_id",
		""
	)).strip_edges())
	if subject_id == &"":
		return false
	for candidate in _machine.npc.get_tree().get_nodes_in_group("player"):
		var player := candidate as Node
		if (
			player != null
			and is_instance_valid(player)
			and PlayerInteractionMemoryPolicy.get_stable_actor_id(player)
				== subject_id
		):
			return true
	return false


func _on_policy_feedback_changed(
	policy_kind: StringName,
	descriptor: Dictionary
) -> void:
	if _presenter == null or descriptor.is_empty():
		return
	match policy_kind:
		&"social":
			if not bool(descriptor.get("all_candidates_suppressed", false)):
				return
			if (
				_controller != null
				and _controller.current_intent != null
				and _controller.current_intent.logical_action_kind
					not in [&"Talk", &"LookForTalkTarget"]
			):
				return
			_presenter.submit_cue(Catalog.create_cue(
				&"all_social_candidates_suppressed",
				{
					"metadata": {
						"identity_key": "all_social_candidates_suppressed",
						"cooldown_key": "all_social_candidates_suppressed",
						"reason_code": descriptor.get("reason_code", &""),
						"suppressed_count": int(descriptor.get(
							"suppressed_count",
							0
						)),
						"suppressed_by_reason": descriptor.get(
							"suppressed_by_reason",
							{}
						).duplicate(true),
					},
				}
			))
		&"target":
			if not bool(descriptor.get("all_suppressed", false)):
				return
			var logical_action := String(descriptor.get(
				"logical_action",
				""
			))
			var stable_key := "all_targets_recently_failed:%s" % logical_action
			_presenter.submit_cue(Catalog.create_cue(
				&"all_targets_recently_failed",
				{
					"metadata": {
						"identity_key": stable_key,
						"cooldown_key": stable_key,
						"logical_action": logical_action,
						"reason_code": descriptor.get("reason_code", &""),
					},
				}
			))


func _on_activity_target_selection_committed(
	descriptor: Dictionary
) -> void:
	if _presenter == null or descriptor.is_empty():
		return
	if (
		StringName(String(descriptor.get("reason_code", "")))
			!= &"alternative_target_selected"
		or int(descriptor.get("suppressed_count", 0)) <= 0
	):
		return
	var logical_action := String(descriptor.get(
		"logical_action",
		""
	)).strip_edges()
	var selected_target_id := String(descriptor.get(
		"selected_target_id",
		""
	)).strip_edges()
	var session_id := String(descriptor.get(
		"action_session_id",
		""
	)).strip_edges()
	var intent_id := String(descriptor.get("intent_id", "")).strip_edges()
	if (
		logical_action.is_empty()
		or selected_target_id.is_empty()
		or session_id.is_empty()
		or intent_id.is_empty()
	):
		return
	var stable_key := "trying_another_place:%s:%s" % [
		logical_action,
		selected_target_id,
	]
	_presenter.submit_cue(Catalog.create_cue(
		&"trying_another_place",
		{
			"source_intent_id": intent_id,
			"source_session_id": session_id,
			"metadata": {
				"identity_key": stable_key,
				"cooldown_key": stable_key,
				"logical_action": logical_action,
				"selected_target_id": selected_target_id,
				"suppressed_count": int(descriptor.get(
					"suppressed_count",
					0
				)),
			},
		}
	))


func _on_state_changed(
	_state_name: StringName,
	_previous_state_name: StringName
) -> void:
	_refresh_state_suppression()


func _refresh_state_suppression() -> void:
	if _machine == null or _presenter == null:
		return
	var current_name := (
		StringName(_machine.current_state.name)
		if _machine.current_state != null
		else &""
	)
	_presenter.set_feedback_suppressed(
		&"talk",
		_machine.interaction_overlay != null
	)
	_presenter.set_feedback_suppressed(
		&"incapacitated",
		current_name in [&"Downed", &"DisabledDead", &"Collapse"]
	)
	_presenter.set_feedback_suppressed(
		&"scripted_control",
		_machine.scripted_control_claim_token != 0
	)


func _on_npc_control_claim_changed(
	claimed_npc: Node,
	claimed: bool,
	_token_id: int
) -> void:
	if (
		_presenter == null
		or _machine == null
		or claimed_npc != _machine.npc
	):
		return
	_presenter.set_feedback_suppressed(&"scripted_control", claimed)
