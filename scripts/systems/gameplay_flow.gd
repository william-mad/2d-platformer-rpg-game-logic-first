extends Node

const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")

signal world_progression_lock_changed(locked: bool)
signal world_progression_unlocked()
signal npc_control_claim_changed(npc: Node, claimed: bool, token_id: int)
signal player_control_claim_changed(player: Node, claimed: bool, token_id: int)

var _next_world_progression_lock_token: int = 1
var _world_progression_locks: Dictionary = {}
var _next_npc_control_claim_token: int = 1
var _npc_control_claims: Dictionary = {}
var _npc_control_claim_tokens_by_instance_id: Dictionary = {}
var _logged_npc_control_claim_rejections: Dictionary = {}
var _next_player_control_claim_token: int = 1
var _player_control_claims: Dictionary = {}
var _player_control_claim_tokens_by_instance_id: Dictionary = {}
var _logged_player_control_claim_rejections: Dictionary = {}
var _logged_player_control_invalid_states: Dictionary = {}
var _logged_player_control_unknown_modes: Dictionary = {}
var _logged_player_control_stale_releases: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	_cleanup_orphaned_world_progression_locks()
	_cleanup_orphaned_npc_control_claims()
	_cleanup_orphaned_player_control_claims()


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


func can_player_accept_world_interaction(player: Node) -> bool:
	return get_player_world_interaction_block_reason(player).is_empty()


func get_player_world_interaction_block_reason(player: Node) -> StringName:
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return &"invalid_player"
	if get_tree().paused:
		return &"full_pause"
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if (
		scene_loader != null
		and (
			bool(scene_loader.call("is_scene_transition_in_progress"))
			if scene_loader.has_method("is_scene_transition_in_progress")
			else bool(scene_loader.get("loading_in_progress"))
		)
	):
		return &"scene_transition_in_progress"
	if is_player_control_claimed(player):
		return &"player_control_claimed"
	if is_world_progression_locked():
		return &"world_progression_locked"
	if player.has_method("get_world_interaction_block_reason"):
		return StringName(player.call("get_world_interaction_block_reason"))
	if player.has_method("can_accept_player_control_claim"):
		var eligibility = player.call("can_accept_player_control_claim", &"ui_only")
		if eligibility is Dictionary and not bool(eligibility.get("accepted", false)):
			return StringName(eligibility.get("reason", &"player_unavailable"))
	return &""


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
	var actor_id := NpcIdentity.get_stable_actor_id(npc)
	if not actor_id.is_empty():
		return StringName(actor_id)
	return StringName("%s:%d" % [npc.name, npc.get_instance_id()])


func acquire_player_control_claim(
	owner: Object,
	player: Node,
	reason: StringName,
	control_mode: StringName = &"ui_only"
) -> int:
	if control_mode != &"ui_only":
		_warn_unknown_player_control_mode(control_mode)
		return 0
	if (
		owner == null
		or not is_instance_valid(owner)
		or player == null
		or not is_instance_valid(player)
	):
		return 0

	var player_instance_id := int(player.get_instance_id())
	var existing_token := int(
		_player_control_claim_tokens_by_instance_id.get(player_instance_id, 0)
	)
	if existing_token != 0 and _player_control_claims.has(existing_token):
		var existing_claim: Dictionary = _player_control_claims[existing_token]
		var existing_owner_ref := existing_claim.get("owner") as WeakRef
		var existing_owner: Object = (
			existing_owner_ref.get_ref() if existing_owner_ref != null else null
		)
		if existing_owner == owner:
			return existing_token
		_warn_player_control_claim_rejected(player, existing_token)
		return 0

	var eligibility := {
		"accepted": false,
		"reason": "missing_player_claim_eligibility",
	}
	if player.has_method("can_accept_player_control_claim"):
		var result = player.call("can_accept_player_control_claim", control_mode)
		if result is Dictionary:
			eligibility = result
	if not bool(eligibility.get("accepted", false)):
		_warn_player_control_invalid_state(
			player,
			String(eligibility.get("reason", "player_claim_rejected"))
		)
		return 0

	var token_id := _take_next_player_control_claim_token()
	_player_control_claims[token_id] = {
		"token_id": token_id,
		"owner": weakref(owner),
		"player": weakref(player),
		"player_instance_id": player_instance_id,
		"reason": reason,
		"control_mode": control_mode,
	}
	_player_control_claim_tokens_by_instance_id[player_instance_id] = token_id
	_logged_player_control_claim_rejections.erase(player_instance_id)
	_logged_player_control_invalid_states.erase(player_instance_id)
	player_control_claim_changed.emit(player, true, token_id)
	return token_id


func release_player_control_claim(token_id: int, expected_owner: Object = null) -> bool:
	if not _player_control_claims.has(token_id):
		_warn_stale_player_control_release(token_id, "missing_token")
		return false

	var claim: Dictionary = _player_control_claims[token_id]
	var owner_ref := claim.get("owner") as WeakRef
	var claim_owner: Object = owner_ref.get_ref() if owner_ref != null else null
	if expected_owner != null and claim_owner != expected_owner:
		_warn_stale_player_control_release(token_id, "owner_mismatch")
		return false

	_remove_player_control_claim(token_id)
	return true


func is_player_control_claimed(player: Node) -> bool:
	if player == null or not is_instance_valid(player):
		return false
	var token_id := int(
		_player_control_claim_tokens_by_instance_id.get(player.get_instance_id(), 0)
	)
	return token_id != 0 and _player_control_claims.has(token_id)


func get_player_control_claim(player: Node) -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {}
	var token_id := int(
		_player_control_claim_tokens_by_instance_id.get(player.get_instance_id(), 0)
	)
	if token_id == 0 or not _player_control_claims.has(token_id):
		return {}
	return _player_control_claims[token_id].duplicate()


func dump_player_control_claims() -> void:
	if _player_control_claims.is_empty():
		print("Player control claims: none")
		return

	print("Player control claims (%d):" % _player_control_claims.size())
	var token_ids := _player_control_claims.keys()
	token_ids.sort()
	for token_id in token_ids:
		var claim: Dictionary = _player_control_claims[token_id]
		var owner_ref := claim.get("owner") as WeakRef
		var player_ref := claim.get("player") as WeakRef
		print(
			"  token=%d reason=%s mode=%s owner_valid=%s player_valid=%s"
			% [
				int(token_id),
				String(claim.get("reason", &"")),
				String(claim.get("control_mode", &"")),
				str(owner_ref != null and owner_ref.get_ref() != null),
				str(player_ref != null and player_ref.get_ref() != null),
			]
		)


func _take_next_player_control_claim_token() -> int:
	while (
		_next_player_control_claim_token == 0
		or _player_control_claims.has(_next_player_control_claim_token)
	):
		_next_player_control_claim_token += 1
	var token_id := _next_player_control_claim_token
	_next_player_control_claim_token += 1
	if _next_player_control_claim_token == 0:
		_next_player_control_claim_token = 1
	return token_id


func _remove_player_control_claim(token_id: int) -> void:
	if not _player_control_claims.has(token_id):
		return
	var claim: Dictionary = _player_control_claims[token_id]
	var player_instance_id := int(claim.get("player_instance_id", 0))
	var player_ref := claim.get("player") as WeakRef
	var claimed_player := player_ref.get_ref() as Node if player_ref != null else null
	_player_control_claims.erase(token_id)
	if (
		int(_player_control_claim_tokens_by_instance_id.get(player_instance_id, 0))
		== token_id
	):
		_player_control_claim_tokens_by_instance_id.erase(player_instance_id)
	_logged_player_control_claim_rejections.erase(player_instance_id)
	_logged_player_control_invalid_states.erase(player_instance_id)
	_logged_player_control_stale_releases.erase(token_id)
	player_control_claim_changed.emit(claimed_player, false, token_id)


func _cleanup_orphaned_player_control_claims() -> void:
	var orphaned_token_ids: Array[int] = []
	for token_id in _player_control_claims.keys():
		var claim: Dictionary = _player_control_claims[token_id]
		var owner_ref := claim.get("owner") as WeakRef
		var player_ref := claim.get("player") as WeakRef
		if (
			owner_ref == null
			or owner_ref.get_ref() == null
			or player_ref == null
			or player_ref.get_ref() == null
		):
			orphaned_token_ids.append(int(token_id))

	if orphaned_token_ids.is_empty():
		return
	for token_id in orphaned_token_ids:
		_remove_player_control_claim(token_id)
	if OS.is_debug_build():
		push_warning(
			"GameplayFlow cleaned up %d orphaned player control claim(s)."
			% orphaned_token_ids.size()
		)


func _warn_player_control_claim_rejected(player: Node, existing_token: int) -> void:
	if not OS.is_debug_build():
		return
	var player_instance_id := int(player.get_instance_id())
	if _logged_player_control_claim_rejections.has(player_instance_id):
		return
	_logged_player_control_claim_rejections[player_instance_id] = true
	push_warning(
		"Player control claim rejected; token %d already owns player '%s'."
		% [existing_token, player.name]
	)


func _warn_player_control_invalid_state(player: Node, reason: String) -> void:
	if not OS.is_debug_build():
		return
	var player_instance_id := int(player.get_instance_id())
	var logged_reasons: Dictionary = _logged_player_control_invalid_states.get(
		player_instance_id, {}
	)
	if logged_reasons.has(reason):
		return
	logged_reasons[reason] = true
	_logged_player_control_invalid_states[player_instance_id] = logged_reasons
	push_warning(
		"Player control claim rejected for '%s': %s." % [player.name, reason]
	)


func _warn_unknown_player_control_mode(control_mode: StringName) -> void:
	if not OS.is_debug_build():
		return
	var warning_key := String(control_mode)
	if _logged_player_control_unknown_modes.has(warning_key):
		return
	_logged_player_control_unknown_modes[warning_key] = true
	push_warning("Unknown player control mode rejected: '%s'." % warning_key)


func _warn_stale_player_control_release(token_id: int, reason: String) -> void:
	if not OS.is_debug_build():
		return
	var warning_key := "%d|%s" % [token_id, reason]
	if _logged_player_control_stale_releases.has(warning_key):
		return
	_logged_player_control_stale_releases[warning_key] = true
	push_warning(
		"Stale player control claim release rejected: token=%d reason=%s."
		% [token_id, reason]
	)
