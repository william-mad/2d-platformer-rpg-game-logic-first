class_name NpcReprimandCoordinator extends RefCounted

const ConfrontationPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_confrontation_policy.gd"
)
const OutcomeResolver = preload(
	"res://scripts/systems/npc_behavior/npc_reprimand_outcome_resolver.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const PlayerInteractionMemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_player_interaction_memory_policy.gd"
)
const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")

const PURPOSE_REPRIMAND: StringName = &"reprimand"
const TALK_SOURCE: StringName = &"reprimand"
const TALK_PRIORITY: int = 88
const FIGHT_PRIORITY: int = 94
const FLEE_PRIORITY: int = 90

var _npc: Node2D
var _machine: NpcStateMachine
var _profile: NpcPlayerTalkDialogueProfile
var _policy := ConfrontationPolicy.new()
var _resolver := OutcomeResolver.new()
var _rng := RandomNumberGenerator.new()
var _pending_context: Dictionary = {}
var _active_context: Dictionary = {}
var _active_dialogue_session_id: StringName = &""
var _active_talk_session_id: String = ""
var _active_talk_ref: WeakRef
var _committed_outcome: StringName = &""
var _last_dialogue_ids: Dictionary = {}
var _transition_deferred: bool = false
var _escalating: bool = false


func bind(
	npc: Node2D,
	machine: NpcStateMachine,
	profile: NpcPlayerTalkDialogueProfile
) -> void:
	shutdown()
	_npc = npc
	_machine = machine
	_profile = profile
	_rng.randomize()
	if _machine != null:
		var state_callback := Callable(self, "_on_state_changed")
		if not _machine.state_changed.is_connected(state_callback):
			_machine.state_changed.connect(state_callback)
	var dialogue_controller := _get_dialogue_controller()
	if dialogue_controller != null:
		var choice_callback := Callable(self, "_on_dialogue_choice_committed")
		if not dialogue_controller.dialogue_choice_committed.is_connected(choice_callback):
			dialogue_controller.dialogue_choice_committed.connect(choice_callback)
		var finish_callback := Callable(self, "_on_dialogue_session_finished")
		if not dialogue_controller.dialogue_session_finished.is_connected(finish_callback):
			dialogue_controller.dialogue_session_finished.connect(finish_callback)


func shutdown() -> void:
	_cancel_active_dialogue("reprimand_owner_exit")
	if _machine != null and is_instance_valid(_machine):
		var state_callback := Callable(self, "_on_state_changed")
		if _machine.state_changed.is_connected(state_callback):
			_machine.state_changed.disconnect(state_callback)
	var dialogue_controller := _get_dialogue_controller()
	if dialogue_controller != null:
		var choice_callback := Callable(self, "_on_dialogue_choice_committed")
		if dialogue_controller.dialogue_choice_committed.is_connected(choice_callback):
			dialogue_controller.dialogue_choice_committed.disconnect(choice_callback)
		var finish_callback := Callable(self, "_on_dialogue_session_finished")
		if dialogue_controller.dialogue_session_finished.is_connected(finish_callback):
			dialogue_controller.dialogue_session_finished.disconnect(finish_callback)
	_pending_context.clear()
	_clear_active()
	_npc = null
	_machine = null
	_profile = null


func consider_direct_damage(
	amount: float,
	offender: Node2D,
	remaining_hp: float,
	maximum_hp: float
) -> Dictionary:
	if (
		not _is_bound()
		or _profile == null
		or amount <= 0.0
		or not _is_valid_offender(offender)
	):
		return {"handled": false, "decision": ConfrontationPolicy.DECISION_IGNORE}
	var current_context := _get_current_reprimand_context(offender)
	var offense_count := _get_prior_harm_occurrence_count(offender) + 1
	if not current_context.is_empty():
		offense_count = maxi(int(current_context.get("offense_count", 1)) + 1, offense_count)
	var reason := (
		ConfrontationPolicy.REASON_REPEATED_OFFENSE
		if offense_count > 1
		else ConfrontationPolicy.REASON_ATTACKED_ME
	)
	var severity := _damage_severity(amount, maximum_hp, remaining_hp)
	var context := _make_context(
		reason,
		offender,
		_npc,
		severity,
		offense_count,
		{
			"event_name": "damage_dealt",
			"damage_amount": amount,
			"remaining_hp": remaining_hp,
			"victim_id": _actor_id(_npc),
			"offender_id": _actor_id(offender),
		}
	)
	var during_reprimand := _schedule_is_reprimand_talk() or not _active_context.is_empty()
	context["during_reprimand"] = during_reprimand
	context["dialogue_available"] = _has_dialogue(reason)
	var decision := _policy.decide(context, _relationship_snapshot(offender))
	return _apply_confrontation_decision(decision, context, during_reprimand)


func consider_witnessed_damage(payload: Dictionary) -> Dictionary:
	if not _is_bound() or _profile == null:
		return {"handled": false, "decision": ConfrontationPolicy.DECISION_IGNORE}
	var offender := payload.get("attacker", payload.get("actor", null)) as Node2D
	var victim := payload.get("target", null) as Node2D
	if (
		not _is_valid_offender(offender)
		or victim == null
		or not is_instance_valid(victim)
		or victim == _npc
		or not victim.is_in_group("npc")
	):
		return {"handled": false, "decision": ConfrontationPolicy.DECISION_IGNORE}
	var current_context := _get_current_reprimand_context(offender)
	var offense_count := maxi(int(current_context.get("offense_count", 0)) + 1, 1)
	var amount := maxf(float(payload.get("amount", 0.0)), 0.0)
	var victim_max_hp := _get_numeric_property(victim, &"max_hp", 100.0)
	var reason := ConfrontationPolicy.REASON_ATTACKED_FRIEND
	var context := _make_context(
		reason,
		offender,
		victim,
		_damage_severity(amount, victim_max_hp, victim_max_hp - amount),
		offense_count,
		{
			"event_name": String(payload.get("event_name", "damage_dealt")),
			"damage_amount": amount,
			"victim_id": _actor_id(victim),
			"offender_id": _actor_id(offender),
			"emitted_at_msec": int(payload.get("emitted_at_msec", 0)),
		}
	)
	var during_reprimand := _schedule_is_reprimand_talk() or not _active_context.is_empty()
	context["during_reprimand"] = during_reprimand
	context["dialogue_available"] = _has_dialogue(reason)
	var relationship := _relationship_snapshot(offender)
	relationship["victim_favor"] = _get_relationship_metric(
		&"get_relationship_favor_for", victim, 0.0
	)
	var decision := _policy.decide(context, relationship)
	return _apply_confrontation_decision(decision, context, during_reprimand)


func consider_false_monster_alarm(payload: Dictionary) -> Dictionary:
	if not _is_bound() or _profile == null:
		return {"handled": false, "decision": ConfrontationPolicy.DECISION_IGNORE}
	var offender := payload.get("actor", null) as Node2D
	if not _is_valid_offender(offender) or not offender.is_in_group("player"):
		return {"handled": false, "decision": ConfrontationPolicy.DECISION_IGNORE}

	var current_context := _get_current_reprimand_context(offender)
	var offense_count := maxi(int(current_context.get("offense_count", 0)) + 1, 1)
	var reason := ConfrontationPolicy.REASON_FALSE_MONSTER_ALARM
	var position_value = payload.get("position", Vector2.ZERO)
	var event_position: Vector2 = (
		position_value if position_value is Vector2 else Vector2.ZERO
	)
	var context := _make_context(
		reason,
		offender,
		_npc,
		15.0,
		offense_count,
		{
			"event_name": String(payload.get("event_name", "monster_bell_rung")),
			"emitted_at_msec": int(payload.get("emitted_at_msec", 0)),
			"event_position": event_position,
			"radius": float(payload.get("radius", 0.0)),
			"offender_id": _actor_id(offender),
		}
	)
	var during_reprimand := _schedule_is_reprimand_talk() or not _active_context.is_empty()
	context["during_reprimand"] = during_reprimand
	context["dialogue_available"] = _has_dialogue(reason)
	var decision := _policy.decide(context, _relationship_snapshot(offender))
	return _apply_confrontation_decision(decision, context, during_reprimand)


func try_begin_pending_reprimand() -> bool:
	_transition_deferred = false
	if not _is_bound() or _pending_context.is_empty():
		return false
	if _machine.is_primary_state(&"ReactToEvent"):
		return false
	if _machine.is_primary_state(&"Fight") or _machine.is_primary_state(&"Flee"):
		_pending_context.clear()
		return false
	var dialogue_controller := _get_dialogue_controller()
	if dialogue_controller != null and bool(dialogue_controller.call("is_dialogue_active")):
		return false
	var offender := _pending_context.get("offender", null) as Node2D
	if not _is_valid_offender(offender):
		_pending_context.clear()
		return false
	var context := _pending_context.duplicate(true)
	_pending_context.clear()
	var accepted := _machine.request_talk(
		offender,
		TALK_PRIORITY,
		false,
		TALK_SOURCE,
		context
	)
	return accepted


func handle_talk_started(
	partner: Node2D,
	talk_state: NpcStateTalk
) -> bool:
	if (
		not _is_bound()
		or talk_state == null
		or talk_state.terminal_source != String(TALK_SOURCE)
	):
		return false
	var context := _machine.get_active_talk_context()
	if StringName(String(context.get("purpose", &""))) != PURPOSE_REPRIMAND:
		talk_state.cancel_talk_session("reprimand_context_missing")
		return true
	if partner == null or not is_instance_valid(partner) or partner != context.get("offender", null):
		talk_state.cancel_talk_session("reprimand_offender_mismatch")
		return true
	if _profile == null:
		talk_state.cancel_talk_session("reprimand_profile_missing")
		return true
	var reason := StringName(String(context.get("reason", &"")))
	var previous_id := StringName(String(_last_dialogue_ids.get(reason, &"")))
	var definition := _profile.instantiate_reprimand_response(
		reason,
		_rng,
		previous_id,
		{
			"offender_name": _display_name(partner),
			"victim_name": _display_name(context.get("victim", null) as Node),
		}
	)
	if definition == null:
		talk_state.cancel_talk_session("reprimand_dialogue_unavailable")
		return true
	var dialogue_controller := _get_dialogue_controller()
	if dialogue_controller == null:
		talk_state.cancel_talk_session("reprimand_dialogue_controller_missing")
		return true
	var result: Dictionary = dialogue_controller.call(
		"begin_autonomous_talk_dialogue",
		talk_state,
		partner,
		_npc,
		definition,
		_profile.get_speaker_names(),
		_profile.get_portrait_presentation()
	)
	if not bool(result.get("accepted", false)):
		talk_state.cancel_talk_session(
			"reprimand_dialogue_start_%s" % String(result.get("reason", "rejected"))
		)
		return true

	_active_context = context.duplicate(true)
	_active_dialogue_session_id = StringName(result.get("session_id", &""))
	_active_talk_session_id = talk_state.terminal_session_id
	_active_talk_ref = weakref(talk_state)
	_committed_outcome = &""
	_last_dialogue_ids[reason] = definition.dialogue_id
	if talk_state.wait_for_external_completion():
		return true
	_cancel_active_dialogue("reprimand_talk_wait_rejected")
	return true


func handle_talk_cancelled(talk_state: NpcStateTalk, reason: String) -> bool:
	if not _talk_matches_active(talk_state):
		return false
	_cancel_active_dialogue("reprimand_talk_cancelled_%s" % reason)
	return true


func has_pending_reprimand() -> bool:
	return not _pending_context.is_empty()


func has_active_reprimand() -> bool:
	return not _active_context.is_empty() or (
		_machine != null
		and _machine.get_active_interaction_source() == TALK_SOURCE
	)


func get_active_context() -> Dictionary:
	return _get_current_reprimand_context(null)


func _apply_confrontation_decision(
	decision: Dictionary,
	context: Dictionary,
	during_reprimand: bool
) -> Dictionary:
	var decision_name := StringName(String(decision.get(
		"decision", ConfrontationPolicy.DECISION_IGNORE
	)))
	match decision_name:
		ConfrontationPolicy.DECISION_REPRIMAND:
			if during_reprimand:
				_active_context = context.duplicate(true)
			else:
				_pending_context = context.duplicate(true)
				_schedule_pending_transition()
			return {"handled": true, "decision": decision_name}
		ConfrontationPolicy.DECISION_FIGHT:
			_pending_context.clear()
			_escalate_to_state(&"Fight", context, "reprimand_hostility_escalated", FIGHT_PRIORITY)
			return {"handled": true, "decision": decision_name}
		ConfrontationPolicy.DECISION_FLEE:
			_pending_context.clear()
			_escalate_to_state(&"Flee", context, "reprimand_threat_flee", FLEE_PRIORITY)
			return {"handled": true, "decision": decision_name}
	return {"handled": false, "decision": decision_name}


func _on_state_changed(state_name: StringName, previous_state_name: StringName) -> void:
	if _pending_context.is_empty():
		return
	if state_name in [&"Fight", &"Flee", &"DisabledDead", &"Downed"]:
		_pending_context.clear()
		return
	if previous_state_name == &"ReactToEvent" or state_name == &"Idle":
		_schedule_pending_transition()


func _schedule_pending_transition() -> void:
	if _transition_deferred or _npc == null or not is_instance_valid(_npc):
		return
	if _machine != null and _machine.is_primary_state(&"ReactToEvent"):
		return
	_transition_deferred = true
	_npc.call_deferred("_try_begin_pending_reprimand")


func _on_dialogue_choice_committed(
	session_id: StringName,
	_dialogue_id: StringName,
	_choice_id: StringName,
	choice_data: DialogueChoice
) -> void:
	if session_id != _active_dialogue_session_id or choice_data == null:
		return
	var outcome := StringName(String(choice_data.consequences.get(
		"reprimand_outcome", &""
	)))
	if outcome != &"" and _committed_outcome == &"":
		_committed_outcome = outcome


func _on_dialogue_session_finished(result: Dictionary) -> void:
	if (
		_active_dialogue_session_id == &""
		or StringName(result.get("session_id", &"")) != _active_dialogue_session_id
	):
		if not _pending_context.is_empty():
			_schedule_pending_transition()
		return
	if _escalating:
		return
	var talk_state := _get_active_talk_state()
	var offender := _active_context.get("offender", null) as Node2D
	var context := _active_context.duplicate(true)
	var outcome := _committed_outcome
	var talk_session_id := _active_talk_session_id
	var talk_matches := _talk_matches_active(talk_state)
	_clear_active()
	if not talk_matches or not _is_valid_offender(offender):
		return
	if not bool(result.get("completed", false)):
		talk_state.cancel_talk_session(
			"reprimand_dialogue_%s" % String(result.get("reason", "cancelled"))
		)
		return
	if outcome == &"":
		talk_state.cancel_talk_session("reprimand_outcome_missing")
		return

	var resolved := _resolver.resolve(
		context, outcome, _relationship_snapshot(offender)
	)
	if not bool(resolved.get("accepted", false)):
		talk_state.cancel_talk_session("reprimand_outcome_unsupported")
		return
	_apply_outcome_relationship_delta(
		offender,
		resolved.get("relationship_delta", {}),
		context
	)
	var resolution := StringName(String(resolved.get(
		"resolution", OutcomeResolver.RESOLUTION_RESUME
	)))
	_record_reprimand_memory(
		offender, context, outcome, resolution, talk_session_id
	)
	match resolution:
		OutcomeResolver.RESOLUTION_FIGHT:
			talk_state.cancel_talk_session("reprimand_outcome_fight")
			_request_state_transition(&"Fight", offender, "reprimand_outcome_fight", FIGHT_PRIORITY)
		OutcomeResolver.RESOLUTION_FLEE:
			talk_state.cancel_talk_session("reprimand_outcome_flee")
			_request_state_transition(&"Flee", offender, "reprimand_outcome_flee", FLEE_PRIORITY)
		OutcomeResolver.RESOLUTION_RESUME:
			talk_state.complete_talk_with(offender, "reprimand_resolved")
		_:
			talk_state.cancel_talk_session("reprimand_continuation_unavailable")


func _apply_outcome_relationship_delta(
	offender: Node2D,
	delta_value,
	context: Dictionary
) -> void:
	if not (delta_value is Dictionary) or delta_value.is_empty():
		return
	# This dialogue has already provided the visible reaction. Commit directed
	# relationship consequences through the NPC's existing relationship API so a
	# favor delta cannot start ReactToEvent beneath the Talk it is resolving.
	var outcome_reason := "reprimand:%s" % String(context.get("reason", &""))
	for metric_value in delta_value.keys():
		var metric := StringName(String(metric_value))
		var method_name := StringName("change_relationship_%s_for" % String(metric))
		if _npc.has_method(method_name):
			_npc.call(method_name, offender, float(delta_value[metric_value]), outcome_reason)


func _record_reprimand_memory(
	offender: Node2D,
	context: Dictionary,
	outcome: StringName,
	resolution: StringName,
	talk_session_id: String
) -> void:
	if _machine.memory_observer == null:
		return
	_machine.memory_observer.observe_reprimand(
		offender,
		context,
		outcome,
		resolution,
		talk_session_id
	)


func _escalate_to_state(
	state_name: StringName,
	context: Dictionary,
	reason: String,
	priority: int
) -> void:
	var offender := context.get("offender", null) as Node2D
	if not _is_valid_offender(offender):
		return
	_escalating = true
	var talk_state := _get_active_talk_state()
	_cancel_active_dialogue(reason)
	if talk_state != null and is_instance_valid(talk_state):
		talk_state.cancel_talk_session(reason)
	_clear_active()
	_request_state_transition(state_name, offender, reason, priority)
	_escalating = false


func _request_state_transition(
	state_name: StringName,
	offender: Node2D,
	reason: String,
	priority: int
) -> bool:
	if not _is_bound() or not _is_valid_offender(offender):
		return false
	if state_name == &"Fight" and not _machine.can_start_fight_with(offender):
		return false
	if not _machine.can_transition_to_state(state_name, priority):
		return false
	return _machine.request_state(state_name, offender, reason, priority)


func _make_context(
	reason: StringName,
	offender: Node2D,
	victim: Node2D,
	severity: float,
	offense_count: int,
	source_event: Dictionary
) -> Dictionary:
	return {
		"purpose": PURPOSE_REPRIMAND,
		"reason": reason,
		"initiator": _npc,
		"offender": offender,
		"target": offender,
		"victim": victim,
		"source_event": source_event.duplicate(true),
		"severity": clampf(severity, 0.0, 100.0),
		"offense_count": maxi(offense_count, 1),
		# Confrontations are NPC-initiated and must not be blocked by the same
		# recent-harm memory which caused the NPC to seek the offender out.
		"bypass_social_talk_refusal": true,
	}


func _get_current_reprimand_context(offender: Node2D) -> Dictionary:
	var context := _active_context
	if context.is_empty() and _machine != null:
		var machine_context := _machine.get_active_talk_context()
		if StringName(String(machine_context.get("purpose", &""))) == PURPOSE_REPRIMAND:
			context = machine_context
	if context.is_empty():
		context = _pending_context
	if context.is_empty():
		return {}
	if offender != null and context.get("offender", null) != offender:
		return {}
	return context.duplicate(true)


func _get_prior_harm_occurrence_count(offender: Node2D) -> int:
	if _machine == null or _machine.short_term_memory == null:
		return 0
	var offender_id := PlayerInteractionMemoryPolicy.get_stable_actor_id(offender)
	var npc_id := PlayerInteractionMemoryPolicy.get_stable_actor_id(_npc)
	var memories := _machine.short_term_memory.find_recent(
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		offender_id,
		npc_id,
		&"Harm"
	)
	return memories[0].occurrence_count if not memories.is_empty() else 0


func _relationship_snapshot(offender: Node2D) -> Dictionary:
	return {
		"favor": _get_relationship_metric(&"get_relationship_favor_for", offender, 50.0),
		"anger": _get_relationship_metric(&"get_relationship_anger_for", offender, 0.0),
		"fear": _get_relationship_metric(&"get_relationship_fear_for", offender, 0.0),
		"fight_threshold": _get_numeric_property(
			_npc, &"npc_relationship_fight_anger_threshold", 100.0
		),
		"flee_threshold": _get_numeric_property(
			_npc, &"npc_relationship_flee_fear_threshold", 70.0
		),
	}


func _get_relationship_metric(
	method_name: StringName,
	other: Node,
	fallback: float
) -> float:
	if _npc == null or not _npc.has_method(method_name):
		return fallback
	return float(_npc.call(method_name, other, fallback))


func _has_dialogue(reason: StringName) -> bool:
	return _profile != null and _profile.has_reprimand_response(reason)


func _damage_severity(amount: float, maximum_hp: float, remaining_hp: float) -> float:
	var safe_max_hp := maxf(maximum_hp, 1.0)
	var damage_percent := (maxf(amount, 0.0) / safe_max_hp) * 100.0
	var low_health_pressure := (
		clampf((1.0 - (maxf(remaining_hp, 0.0) / safe_max_hp)) * 20.0, 0.0, 20.0)
	)
	return clampf((damage_percent * 2.0) + low_health_pressure, 0.0, 100.0)


func _schedule_is_reprimand_talk() -> bool:
	return (
		_machine != null
		and _machine.get_active_interaction_source() == TALK_SOURCE
	)


func _get_active_talk_state() -> NpcStateTalk:
	if _active_talk_ref != null:
		var active_ref := _active_talk_ref.get_ref() as NpcStateTalk
		if active_ref != null and is_instance_valid(active_ref):
			return active_ref
	if _schedule_is_reprimand_talk():
		return _machine.interaction_overlay as NpcStateTalk
	return null


func _talk_matches_active(talk_state: NpcStateTalk) -> bool:
	return (
		talk_state != null
		and is_instance_valid(talk_state)
		and not _active_talk_session_id.is_empty()
		and talk_state.terminal_session_id == _active_talk_session_id
	)


func _cancel_active_dialogue(reason: String) -> void:
	if _active_dialogue_session_id == &"":
		return
	var dialogue_controller := _get_dialogue_controller()
	if dialogue_controller != null:
		dialogue_controller.call(
			"cancel_dialogue_session", _active_dialogue_session_id, reason
		)


func _clear_active() -> void:
	_active_context.clear()
	_active_dialogue_session_id = &""
	_active_talk_session_id = ""
	_active_talk_ref = null
	_committed_outcome = &""


func _get_dialogue_controller() -> Node:
	if _npc == null or not is_instance_valid(_npc):
		return null
	return _npc.get_node_or_null("/root/DialogueController")


func _is_bound() -> bool:
	return (
		_npc != null
		and is_instance_valid(_npc)
		and _machine != null
		and is_instance_valid(_machine)
	)


func _is_valid_offender(offender: Node2D) -> bool:
	return (
		offender != null
		and is_instance_valid(offender)
		and offender != _npc
	)


func _actor_id(actor: Node) -> String:
	return NpcIdentity.get_stable_actor_id(actor) if actor != null else ""


func _display_name(actor: Node) -> String:
	if actor == null or not is_instance_valid(actor):
		return "someone"
	if NpcIdentity.has_property(actor, &"display_name"):
		var authored_name := String(actor.get("display_name")).strip_edges()
		if not authored_name.is_empty():
			return authored_name
	return actor.name


func _get_numeric_property(actor: Object, property_name: StringName, fallback: float) -> float:
	if actor == null or not NpcIdentity.has_property(actor, property_name):
		return fallback
	var value = actor.get(property_name)
	return float(value) if value is float or value is int else fallback
