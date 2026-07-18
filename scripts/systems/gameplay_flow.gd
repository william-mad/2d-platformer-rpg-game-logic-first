extends Node

signal world_progression_lock_changed(locked: bool)
signal world_progression_unlocked()
signal npc_control_claim_changed(npc: Node, claimed: bool, token_id: int)

var _next_world_progression_lock_token: int = 1
var _world_progression_locks: Dictionary = {}
var _next_npc_control_claim_token: int = 1
var _npc_control_claims: Dictionary = {}
var _npc_control_claim_tokens_by_instance_id: Dictionary = {}
var _logged_npc_control_claim_rejections: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	_cleanup_orphaned_world_progression_locks()
	_cleanup_orphaned_npc_control_claims()


func acquire_world_progression_lock(owner: Object, reason: StringName) -> int:
	var was_locked := is_world_progression_locked()
	var token_id := _take_next_world_progression_lock_token()
	_world_progression_locks[token_id] = {
		"token_id": token_id,
		"owner": weakref(owner),
		"reason": reason,
	}

	if not was_locked:
		world_progression_lock_changed.emit(true)

	return token_id


func release_world_progression_lock(token_id: int, expected_owner: Object = null) -> bool:
	if not _world_progression_locks.has(token_id):
		return false

	var lock_data: Dictionary = _world_progression_locks[token_id]
	var owner_ref := lock_data.get("owner") as WeakRef
	var lock_owner: Object = owner_ref.get_ref() if owner_ref != null else null
	if expected_owner != null and lock_owner != expected_owner:
		return false

	_world_progression_locks.erase(token_id)
	_emit_world_progression_unlocked_if_needed()
	return true


func is_world_progression_locked() -> bool:
	return not _world_progression_locks.is_empty()


func get_world_progression_locks() -> Array:
	var locks: Array = []
	var token_ids := _world_progression_locks.keys()
	token_ids.sort()
	for token_id in token_ids:
		var lock_data: Dictionary = _world_progression_locks[token_id]
		locks.append({
			"token_id": int(token_id),
			"owner": lock_data.get("owner") as WeakRef,
			"reason": StringName(lock_data.get("reason", &"")),
		})
	return locks


func dump_world_progression_locks() -> void:
	var locks := get_world_progression_locks()
	if locks.is_empty():
		print("World progression locks: none")
		return

	print("World progression locks (%d):" % locks.size())
	for lock_data in locks:
		var owner_ref := lock_data.get("owner") as WeakRef
		var owner_valid := owner_ref != null and owner_ref.get_ref() != null
		print(
			"  token=%d reason=%s owner_valid=%s"
			% [
				int(lock_data.get("token_id", 0)),
				String(lock_data.get("reason", &"")),
				str(owner_valid),
			]
		)


func _take_next_world_progression_lock_token() -> int:
	while (
		_next_world_progression_lock_token == 0
		or _world_progression_locks.has(_next_world_progression_lock_token)
	):
		_next_world_progression_lock_token += 1

	var token_id := _next_world_progression_lock_token
	_next_world_progression_lock_token += 1
	if _next_world_progression_lock_token == 0:
		_next_world_progression_lock_token = 1
	return token_id


func _cleanup_orphaned_world_progression_locks() -> void:
	var orphaned_token_ids: Array[int] = []
	for token_id in _world_progression_locks.keys():
		var lock_data: Dictionary = _world_progression_locks[token_id]
		var owner_ref := lock_data.get("owner") as WeakRef
		if owner_ref == null or owner_ref.get_ref() == null:
			orphaned_token_ids.append(int(token_id))

	if orphaned_token_ids.is_empty():
		return

	for token_id in orphaned_token_ids:
		_world_progression_locks.erase(token_id)

	push_warning(
		"GameplayFlow cleaned up %d orphaned world-progression lock(s)."
		% orphaned_token_ids.size()
	)
	_emit_world_progression_unlocked_if_needed()


func _emit_world_progression_unlocked_if_needed() -> void:
	if is_world_progression_locked():
		return
	world_progression_lock_changed.emit(false)
	world_progression_unlocked.emit()


func acquire_npc_control_claim(
	owner: Object,
	npc: Node,
	reason: StringName,
	allow_emergency_interrupts: bool = false
) -> int:
	if owner == null or not is_instance_valid(owner) or npc == null or not is_instance_valid(npc):
		return 0

	var npc_instance_id := int(npc.get_instance_id())
	var existing_token := int(_npc_control_claim_tokens_by_instance_id.get(npc_instance_id, 0))
	if existing_token != 0 and _npc_control_claims.has(existing_token):
		var existing_claim: Dictionary = _npc_control_claims[existing_token]
		var existing_owner_ref := existing_claim.get("owner") as WeakRef
		var existing_owner: Object = (
			existing_owner_ref.get_ref() if existing_owner_ref != null else null
		)
		if existing_owner == owner:
			return existing_token
		_warn_npc_control_claim_rejected(npc, existing_token)
		return 0

	var token_id := _take_next_npc_control_claim_token()
	_npc_control_claims[token_id] = {
		"token_id": token_id,
		"owner": weakref(owner),
		"npc": weakref(npc),
		"npc_instance_id": npc_instance_id,
		"npc_persistent_id": _get_npc_persistent_id(npc),
		"reason": reason,
		"allow_emergency_interrupts": allow_emergency_interrupts,
	}
	_npc_control_claim_tokens_by_instance_id[npc_instance_id] = token_id
	_logged_npc_control_claim_rejections.erase(npc_instance_id)
	npc_control_claim_changed.emit(npc, true, token_id)
	return token_id


func release_npc_control_claim(token_id: int, expected_owner: Object = null) -> bool:
	if not _npc_control_claims.has(token_id):
		return false

	var claim: Dictionary = _npc_control_claims[token_id]
	var owner_ref := claim.get("owner") as WeakRef
	var claim_owner: Object = owner_ref.get_ref() if owner_ref != null else null
	if expected_owner != null and claim_owner != expected_owner:
		return false

	_remove_npc_control_claim(token_id)
	return true


func is_npc_control_claimed(npc: Node) -> bool:
	if npc == null or not is_instance_valid(npc):
		return false
	var token_id := int(_npc_control_claim_tokens_by_instance_id.get(npc.get_instance_id(), 0))
	return token_id != 0 and _npc_control_claims.has(token_id)


func get_npc_control_claim(npc: Node) -> Dictionary:
	if npc == null or not is_instance_valid(npc):
		return {}
	var token_id := int(_npc_control_claim_tokens_by_instance_id.get(npc.get_instance_id(), 0))
	if token_id == 0 or not _npc_control_claims.has(token_id):
		return {}
	return _npc_control_claims[token_id].duplicate()


func dump_npc_control_claims() -> void:
	if _npc_control_claims.is_empty():
		print("NPC control claims: none")
		return

	print("NPC control claims (%d):" % _npc_control_claims.size())
	var token_ids := _npc_control_claims.keys()
	token_ids.sort()
	for token_id in token_ids:
		var claim: Dictionary = _npc_control_claims[token_id]
		var owner_ref := claim.get("owner") as WeakRef
		var npc_ref := claim.get("npc") as WeakRef
		print(
			"  token=%d npc_id=%s reason=%s owner_valid=%s npc_valid=%s emergencies=%s"
			% [
				int(token_id),
				String(claim.get("npc_persistent_id", &"")),
				String(claim.get("reason", &"")),
				str(owner_ref != null and owner_ref.get_ref() != null),
				str(npc_ref != null and npc_ref.get_ref() != null),
				str(bool(claim.get("allow_emergency_interrupts", false))),
			]
		)


func _take_next_npc_control_claim_token() -> int:
	while (
		_next_npc_control_claim_token == 0
		or _npc_control_claims.has(_next_npc_control_claim_token)
	):
		_next_npc_control_claim_token += 1
	var token_id := _next_npc_control_claim_token
	_next_npc_control_claim_token += 1
	if _next_npc_control_claim_token == 0:
		_next_npc_control_claim_token = 1
	return token_id


func _remove_npc_control_claim(token_id: int) -> void:
	if not _npc_control_claims.has(token_id):
		return
	var claim: Dictionary = _npc_control_claims[token_id]
	var npc_instance_id := int(claim.get("npc_instance_id", 0))
	var npc_ref := claim.get("npc") as WeakRef
	var claimed_npc := npc_ref.get_ref() as Node if npc_ref != null else null
	_npc_control_claims.erase(token_id)
	if int(_npc_control_claim_tokens_by_instance_id.get(npc_instance_id, 0)) == token_id:
		_npc_control_claim_tokens_by_instance_id.erase(npc_instance_id)
	_logged_npc_control_claim_rejections.erase(npc_instance_id)
	npc_control_claim_changed.emit(claimed_npc, false, token_id)


func _cleanup_orphaned_npc_control_claims() -> void:
	var orphaned_token_ids: Array[int] = []
	for token_id in _npc_control_claims.keys():
		var claim: Dictionary = _npc_control_claims[token_id]
		var owner_ref := claim.get("owner") as WeakRef
		var npc_ref := claim.get("npc") as WeakRef
		if (
			owner_ref == null
			or owner_ref.get_ref() == null
			or npc_ref == null
			or npc_ref.get_ref() == null
		):
			orphaned_token_ids.append(int(token_id))

	if orphaned_token_ids.is_empty():
		return
	for token_id in orphaned_token_ids:
		_remove_npc_control_claim(token_id)
	if OS.is_debug_build():
		push_warning(
			"GameplayFlow cleaned up %d orphaned NPC control claim(s)."
			% orphaned_token_ids.size()
		)


func _warn_npc_control_claim_rejected(npc: Node, existing_token: int) -> void:
	if not OS.is_debug_build():
		return
	var npc_instance_id := int(npc.get_instance_id())
	if _logged_npc_control_claim_rejections.has(npc_instance_id):
		return
	_logged_npc_control_claim_rejections[npc_instance_id] = true
	push_warning(
		"NPC control claim rejected for '%s'; token %d already owns the NPC."
		% [String(_get_npc_persistent_id(npc)), existing_token]
	)


func _get_npc_persistent_id(npc: Node) -> StringName:
	if npc == null or not is_instance_valid(npc):
		return &""
	if npc.has_method("get_npc_location_id"):
		var location_id := String(npc.call("get_npc_location_id")).strip_edges()
		if not location_id.is_empty():
			return StringName(location_id)
	if npc.has_meta("npc_location_id"):
		var metadata_id := String(npc.get_meta("npc_location_id")).strip_edges()
		if not metadata_id.is_empty():
			return StringName(metadata_id)
	return StringName("%s:%d" % [npc.name, npc.get_instance_id()])
