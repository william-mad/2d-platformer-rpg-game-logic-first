class_name NpcMemoryRuntimeBinding extends Node

const REPOSITORY_PATH: String = "/root/NpcMemoryRuntimeRepository"
const Identity = preload("res://scripts/systems/npc_identity.gd")

var ownership_token: String = ""
var generation: int = 0

var _npc_id: String = ""
var _memory: NpcShortTermMemory
var _machine: NpcStateMachine
var _repository: Node


func _ready() -> void:
	call_deferred("_register_if_possible")


func _exit_tree() -> void:
	if (
		_repository != null
		and is_instance_valid(_repository)
		and not _npc_id.is_empty()
		and not ownership_token.is_empty()
		and _repository.has_method("unregister_live_memory")
	):
		_repository.call(
			"unregister_live_memory",
			_npc_id,
			ownership_token
		)
	ownership_token = ""
	generation = 0


func bind(
	machine: NpcStateMachine,
	memory: NpcShortTermMemory
) -> Dictionary:
	_machine = machine
	_memory = memory
	return _register_if_possible()


func get_registration_descriptor() -> Dictionary:
	return {
		"npc_id": _npc_id,
		"ownership_token": ownership_token,
		"generation": generation,
		"registered": not ownership_token.is_empty(),
	}


func _register_if_possible() -> Dictionary:
	if _machine == null:
		_machine = get_parent() as NpcStateMachine
	if _machine == null:
		return {"accepted": false, "reason": "missing_state_machine"}
	if _memory == null:
		_memory = _machine.get_node_or_null(
			"NpcShortTermMemory"
		) as NpcShortTermMemory
	if _memory == null:
		return {"accepted": false, "reason": "missing_memory"}

	var npc := _machine.npc
	if npc == null or not is_instance_valid(npc):
		return {"accepted": false, "reason": "missing_npc"}
	var stable_id := _resolve_stable_npc_id(npc)
	if stable_id.is_empty():
		return {"accepted": false, "reason": "missing_stable_npc_id"}
	_repository = get_node_or_null(REPOSITORY_PATH)
	if _repository == null or not _repository.has_method("register_live_memory"):
		return {"accepted": false, "reason": "missing_repository"}

	if (
		stable_id == _npc_id
		and not ownership_token.is_empty()
	):
		var same_registration = _repository.call(
			"register_live_memory",
			stable_id,
			_memory
		)
		if same_registration is Dictionary:
			_apply_registration_result(stable_id, same_registration)
			return same_registration

	if not ownership_token.is_empty() and not _npc_id.is_empty():
		_repository.call(
			"unregister_live_memory",
			_npc_id,
			ownership_token
		)
		ownership_token = ""
		generation = 0

	var result = _repository.call(
		"register_live_memory",
		stable_id,
		_memory
	)
	if result is Dictionary:
		_apply_registration_result(stable_id, result)
		return result
	return {"accepted": false, "reason": "invalid_repository_result"}


func _apply_registration_result(
	stable_id: String,
	result: Dictionary
) -> void:
	if not bool(result.get("accepted", false)):
		return
	_npc_id = stable_id
	ownership_token = String(result.get("ownership_token", ""))
	generation = int(result.get("generation", 0))


func _resolve_stable_npc_id(npc: Node) -> String:
	return Identity.get_stable_actor_id(npc)
