class_name NpcMemoryObserver extends Node

const ActionSession = preload("res://scripts/systems/npc_action_session.gd")
const Identity = preload("res://scripts/systems/npc_identity.gd")
const MemoryPolicy = preload("res://scripts/systems/npc_behavior/npc_memory_policy.gd")
const PlayerInteractionMemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_player_interaction_memory_policy.gd"
)

const TERMINAL_DEDUPE_GAME_HOURS: float = 0.05
const MAXIMUM_TERMINAL_DEDUPE_KEYS: int = 64

var _machine: NpcStateMachine
var _memory: NpcShortTermMemory
var _recent_terminal_events: Dictionary = {}
var _damage_events_ref: WeakRef


func _ready() -> void:
	_connect_damage_events()


func _exit_tree() -> void:
	_disconnect_damage_events()
	_machine = null
	_memory = null


func bind(
	machine: NpcStateMachine,
	memory: NpcShortTermMemory
) -> void:
	_disconnect_damage_events()
	_machine = machine
	_memory = memory
	_connect_damage_events()


func observe_damage_dealt(
	amount: float,
	attacker: Node,
	target: Node
) -> Dictionary:
	if _memory == null or _machine == null:
		return {"accepted": false, "reason": "observer_unbound"}
	var remembering_npc := _machine.npc
	if (
		remembering_npc == null
		or not is_instance_valid(remembering_npc)
		or target != remembering_npc
	):
		return {"accepted": false, "reason": "unrelated_damage_target"}
	if amount <= 0.0:
		return {"accepted": false, "reason": "no_actual_damage"}
	if attacker == null or not is_instance_valid(attacker):
		return {"accepted": false, "reason": "invalid_damage_attacker"}
	if attacker == remembering_npc:
		return {"accepted": false, "reason": "self_damage"}
	if _is_monster_actor(attacker):
		return {"accepted": false, "reason": "monster_damage_excluded"}

	var attacker_kind: StringName = &""
	if attacker.is_in_group("player"):
		attacker_kind = &"player"
	elif attacker.is_in_group("npc"):
		attacker_kind = &"npc"
	else:
		return {"accepted": false, "reason": "unsupported_damage_attacker"}
	var attacker_id := PlayerInteractionMemoryPolicy.get_stable_actor_id(attacker)
	var remembering_id := PlayerInteractionMemoryPolicy.get_stable_actor_id(
		remembering_npc
	)
	if attacker_id == &"" or remembering_id == &"":
		return {"accepted": false, "reason": "missing_stable_actor_identity"}
	if attacker_id == remembering_id:
		return {"accepted": false, "reason": "self_damage_identity"}

	var remaining_hp := _machine.get_value(&"hp", 0.0)
	return _memory.remember_event(MemoryPolicy.EVENT_HARMED_BY_ACTOR, {
		"source": "damage_event",
		"reason_code": "damage_received",
		"subject_id": attacker_id,
		"target_id": remembering_id,
		"logical_action": "Harm",
		"now_game_hours": _get_current_game_hours(),
		"metadata": {
			"damage_amount": amount,
			"attacker_kind": attacker_kind,
			"remaining_hp": remaining_hp,
			"caused_death": remaining_hp <= 0.0,
		},
	})


func observe_action_terminal(
	session_descriptor: Dictionary,
	intent_descriptor: Dictionary,
	classification: StringName,
	terminal_reason: StringName
) -> Dictionary:
	if _memory == null or classification not in [
		&"failure",
		&"target_unavailable",
		&"movement_failure",
		&"intention_target_lost",
	]:
		return {"accepted": false, "reason": "neutral_terminal_classification"}
	var session_id := String(session_descriptor.get("session_id", "")).strip_edges()
	if session_id.is_empty() or String(session_descriptor.get("status", "")) != "failed":
		return {"accepted": false, "reason": "non_authoritative_terminal"}
	var event_type := _event_type_for_terminal_classification(classification)
	if event_type == &"":
		return {"accepted": false, "reason": "unsupported_terminal_classification"}
	var now_game_hours := _get_current_game_hours()
	var terminal_key := "%s|%s" % [session_id, String(event_type)]
	if _terminal_event_was_seen(terminal_key, now_game_hours):
		return {"accepted": false, "reason": "duplicate_terminal_event"}

	var matching_intent := (
		intent_descriptor
		if (
			not intent_descriptor.is_empty()
			and String(intent_descriptor.get("action_session_id", "")).strip_edges()
				== session_id
			and not bool(intent_descriptor.get("lifecycle_only", false))
		)
		else {}
	)
	if classification == &"intention_target_lost" and matching_intent.is_empty():
		return {"accepted": false, "reason": "missing_goal_intention"}
	var logical_action := StringName(String(session_descriptor.get("action_kind", "")))
	var target_id := String(session_descriptor.get("target_persistent_id", "")).strip_edges()
	if target_id.is_empty():
		target_id = String(session_descriptor.get("spot_id", "")).strip_edges()
	if classification in [&"target_unavailable", &"intention_target_lost"] and target_id.is_empty():
		return {"accepted": false, "reason": "missing_target_identity"}
	var remembering_id := _remembering_npc_id()
	if remembering_id.is_empty():
		return {"accepted": false, "reason": "missing_stable_actor_identity"}
	if not target_id.is_empty() and not Identity.is_stable_id(target_id):
		return {"accepted": false, "reason": "unstable_target_identity"}
	var memory_reason_code := String(
		matching_intent.get("reason_code", "")
	).strip_edges()
	if memory_reason_code.is_empty():
		memory_reason_code = String(terminal_reason)

	var result := _memory.remember_event(event_type, {
		"source": String(matching_intent.get(
			"source",
			session_descriptor.get("source", "gameplay")
		)),
		"reason_code": memory_reason_code,
		"subject_id": remembering_id,
		"target_id": target_id,
		"place_id": String(session_descriptor.get(
			"scene_path",
			session_descriptor.get("spot_id", "")
		)),
		"logical_action": String(logical_action),
		"intent_id": String(matching_intent.get("intent_id", "")),
		"action_session_id": session_id,
		"now_game_hours": now_game_hours,
		"metadata": {
			"terminal_classification": String(classification),
			"terminal_reason": String(terminal_reason),
			"session_phase": String(session_descriptor.get("phase", "")),
			"session_source": String(session_descriptor.get("source", "")),
		},
	})
	if bool(result.get("accepted", false)):
		_remember_terminal_key(terminal_key, now_game_hours)
	return result


func observe_conversation_refused(
	refusing_npc: Node2D,
	action_session_id: String,
	reason_code: StringName,
	source: StringName = &"social_ai",
	metadata: Dictionary = {}
) -> Dictionary:
	if String(metadata.get("decision_kind", "")) != "social_decline":
		return {"accepted": false, "reason": "not_social_decline"}
	if (
		_memory == null
		or refusing_npc == null
		or not is_instance_valid(refusing_npc)
		or not refusing_npc.is_in_group("npc")
	):
		return {"accepted": false, "reason": "invalid_npc_partner"}
	var subject_id := Identity.get_stable_actor_id(refusing_npc)
	var remembering_id := _remembering_npc_id()
	if subject_id.is_empty() or remembering_id.is_empty() or subject_id == remembering_id:
		return {"accepted": false, "reason": "invalid_partner_identity"}
	return _memory.remember_event(MemoryPolicy.EVENT_CONVERSATION_REFUSED, {
		"source": String(source),
		"reason_code": String(reason_code),
		"subject_id": subject_id,
		"target_id": remembering_id,
		"logical_action": "Talk",
		"action_session_id": action_session_id,
		"now_game_hours": _get_current_game_hours(),
		"metadata": metadata.duplicate(true),
	})


func observe_conversation_completed(
	partner: Node2D,
	session_descriptor: Dictionary
) -> Dictionary:
	var partner_is_npc := (
		partner != null
		and is_instance_valid(partner)
		and partner.is_in_group("npc")
	)
	var partner_is_player := (
		partner != null
		and is_instance_valid(partner)
		and partner.is_in_group("player")
	)
	if (
		_memory == null
		or not (partner_is_npc or partner_is_player)
	):
		return {"accepted": false, "reason": "invalid_social_partner"}
	var session_id := String(session_descriptor.get("session_id", "")).strip_edges()
	if session_id.is_empty():
		return {"accepted": false, "reason": "missing_social_session"}
	var now_game_hours := _get_current_game_hours()
	var terminal_key := "%s|%s" % [
		session_id,
		String(MemoryPolicy.EVENT_CONVERSATION_COMPLETED),
	]
	if _terminal_event_was_seen(terminal_key, now_game_hours):
		return {"accepted": false, "reason": "duplicate_terminal_event"}
	# The live session may contain a scene-path fallback for identity-free actors.
	# Episodic memory is persisted, so derive its partner directly from the stable
	# identity resolver instead of trusting that transient session field.
	var partner_id := Identity.get_stable_actor_id(partner)
	var remembering_id := _remembering_npc_id()
	if partner_id.is_empty() or remembering_id.is_empty() or partner_id == remembering_id:
		return {"accepted": false, "reason": "invalid_partner_identity"}
	var result := _memory.remember_event(MemoryPolicy.EVENT_CONVERSATION_COMPLETED, {
		"source": String(session_descriptor.get("source", "social_ai")),
		"reason_code": "conversation_completed",
		"subject_id": partner_id,
		"target_id": remembering_id,
		"logical_action": "Talk",
		"action_session_id": session_id,
		"now_game_hours": now_game_hours,
		"metadata": {
			"session_phase": String(session_descriptor.get("phase", "")),
		},
	})
	if bool(result.get("accepted", false)):
		_remember_terminal_key(terminal_key, now_game_hours)
	return result


func observe_intention_target_lost(
	session_descriptor: Dictionary,
	intent_descriptor: Dictionary,
	lost_target: Node2D
) -> Dictionary:
	if lost_target == null or not is_instance_valid(lost_target):
		return {"accepted": false, "reason": "invalid_lost_target"}
	var lost_id := ActionSession.get_persistent_id(lost_target)
	var intent_target := String(intent_descriptor.get("target_persistent_id", "")).strip_edges()
	var session_target := String(
		session_descriptor.get("target_persistent_id", "")
	).strip_edges()
	if lost_id.is_empty() or lost_id != intent_target or lost_id != session_target:
		return {"accepted": false, "reason": "unrelated_lost_target"}
	var terminal := session_descriptor.duplicate(true)
	terminal["status"] = "failed"
	terminal["reason"] = "intention_target_lost"
	return observe_action_terminal(
		terminal,
		intent_descriptor,
		&"intention_target_lost",
		&"intention_target_lost"
	)


func clear_terminal_dedupe() -> void:
	_recent_terminal_events.clear()


func _event_type_for_terminal_classification(classification: StringName) -> StringName:
	match classification:
		&"failure": return MemoryPolicy.EVENT_ACTION_FAILED
		&"target_unavailable": return MemoryPolicy.EVENT_TARGET_UNAVAILABLE
		&"movement_failure": return MemoryPolicy.EVENT_MOVEMENT_FAILED
		&"intention_target_lost": return MemoryPolicy.EVENT_INTENTION_TARGET_LOST
	return &""


func _terminal_event_was_seen(key: String, now_game_hours: float) -> bool:
	_prune_terminal_keys(now_game_hours)
	return (
		_recent_terminal_events.has(key)
		and now_game_hours - float(_recent_terminal_events[key])
			<= TERMINAL_DEDUPE_GAME_HOURS
	)


func _remember_terminal_key(key: String, now_game_hours: float) -> void:
	_recent_terminal_events[key] = now_game_hours
	_prune_terminal_keys(now_game_hours)
	if _recent_terminal_events.size() <= MAXIMUM_TERMINAL_DEDUPE_KEYS:
		return
	var keys := _recent_terminal_events.keys()
	keys.sort_custom(
		func(a, b) -> bool:
			var a_time := float(_recent_terminal_events[a])
			var b_time := float(_recent_terminal_events[b])
			if not is_equal_approx(a_time, b_time):
				return a_time < b_time
			return String(a) < String(b)
	)
	while keys.size() > MAXIMUM_TERMINAL_DEDUPE_KEYS:
		_recent_terminal_events.erase(keys.pop_front())


func _prune_terminal_keys(now_game_hours: float) -> void:
	for key in _recent_terminal_events.keys():
		if (
			now_game_hours - float(_recent_terminal_events[key])
			> TERMINAL_DEDUPE_GAME_HOURS
		):
			_recent_terminal_events.erase(key)


func _remembering_npc_id() -> String:
	if _machine == null:
		return ""
	var bound_npc := _machine.npc
	return Identity.get_stable_actor_id(bound_npc)


func _get_current_game_hours() -> float:
	if _memory == null or not _memory.is_inside_tree():
		return 0.0
	var world_time := _memory.get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_total_hours"):
		return maxf(float(world_time.call("get_total_hours")), 0.0)
	return 0.0


func _connect_damage_events() -> void:
	if not is_inside_tree() or _machine == null or _memory == null:
		return
	var damage_events := get_node_or_null("/root/DamageEvents")
	if damage_events == null or not damage_events.has_signal(&"damage_dealt"):
		return
	var callback := Callable(self, "_on_damage_dealt")
	if not damage_events.is_connected(&"damage_dealt", callback):
		damage_events.connect(&"damage_dealt", callback)
	_damage_events_ref = weakref(damage_events)


func _disconnect_damage_events() -> void:
	if _damage_events_ref == null:
		return
	var damage_events = _damage_events_ref.get_ref()
	var callback := Callable(self, "_on_damage_dealt")
	if (
		damage_events != null
		and is_instance_valid(damage_events)
		and damage_events.has_signal(&"damage_dealt")
		and damage_events.is_connected(&"damage_dealt", callback)
	):
		damage_events.disconnect(&"damage_dealt", callback)
	_damage_events_ref = null


func _on_damage_dealt(amount: float, attacker: Node, target: Node) -> void:
	observe_damage_dealt(amount, attacker, target)


func _is_monster_actor(actor: Node) -> bool:
	for group_name in [&"monster", &"monsters", &"enemy", &"enemies"]:
		if actor.is_in_group(group_name):
			return true
	return false
