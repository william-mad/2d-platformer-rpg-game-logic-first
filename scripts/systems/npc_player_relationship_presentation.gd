class_name NpcPlayerRelationshipPresentation extends RefCounted

const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")

var _owner_ref: WeakRef
var _relationships: Node
var _owner_id: String = ""
var _cached_opinion_snapshot: Dictionary = {"available": false}
var _cached_relationship_snapshot: Dictionary = {}
var _snapshot_initialized: bool = false


func bind(owner: Node, relationships: Node) -> void:
	unbind()
	if owner == null or not is_instance_valid(owner):
		return
	_owner_ref = weakref(owner)
	_owner_id = NpcIdentity.get_stable_actor_id(owner)
	_relationships = relationships
	if _relationships == null:
		return
	var changed_callback := Callable(self, "_on_relationship_changed")
	if (
		_relationships.has_signal(&"relationship_changed")
		and not _relationships.is_connected(
			&"relationship_changed", changed_callback
		)
	):
		_relationships.connect(&"relationship_changed", changed_callback)
	var met_callback := Callable(self, "_on_relationship_met")
	for signal_name in [&"relationship_met", &"relationship_seen"]:
		if (
			_relationships.has_signal(signal_name)
			and not _relationships.is_connected(signal_name, met_callback)
		):
			_relationships.connect(signal_name, met_callback)
	var replaced_callback := Callable(
		self, "_on_relationship_graph_replaced"
	)
	if (
		_relationships.has_signal(&"relationship_graph_replaced")
		and not _relationships.is_connected(
			&"relationship_graph_replaced", replaced_callback
		)
	):
		_relationships.connect(
			&"relationship_graph_replaced", replaced_callback
		)


func unbind() -> void:
	if _relationships != null and is_instance_valid(_relationships):
		var callbacks := {
			&"relationship_changed": Callable(
				self, "_on_relationship_changed"
			),
			&"relationship_met": Callable(self, "_on_relationship_met"),
			&"relationship_seen": Callable(self, "_on_relationship_met"),
			&"relationship_graph_replaced": Callable(
				self, "_on_relationship_graph_replaced"
			),
		}
		for signal_name in callbacks:
			var callback: Callable = callbacks[signal_name]
			if (
				_relationships.has_signal(signal_name)
				and _relationships.is_connected(signal_name, callback)
			):
				_relationships.disconnect(signal_name, callback)
	_relationships = null
	_owner_ref = null
	_owner_id = ""
	_cached_opinion_snapshot = {"available": false}
	_cached_relationship_snapshot = {}
	_snapshot_initialized = false


func get_opinion_snapshot(
	player: Node,
	include_relationship: bool = true
) -> Dictionary:
	var owner := _get_owner()
	if (
		owner == null
		or player == null
		or not is_instance_valid(player)
		or _relationships == null
		or not is_instance_valid(_relationships)
		or not _relationships.has_method("get_relationship_by_id")
	):
		return {"available": false}
	var player_id := NpcIdentity.get_stable_actor_id(player)
	if (
		not NpcIdentity.is_stable_id(_owner_id)
		or not NpcIdentity.is_player_id(player_id)
		or _owner_id == player_id
	):
		return {"available": false}
	if _snapshot_initialized:
		return _get_cached_opinion_result(include_relationship)
	var relationship = _relationships.call(
		"get_relationship_by_id", _owner_id, player_id
	)
	_update_cached_opinion_snapshot(
		relationship if relationship is Dictionary else {}
	)
	return _get_cached_opinion_result(include_relationship)


func _on_relationship_changed(
	relationship_owner: Node,
	other: Node,
	_changed_values: Dictionary,
	relationship: Dictionary
) -> void:
	if (
		_is_current_player_row(relationship_owner, other, relationship)
		and _update_cached_opinion_snapshot(relationship)
	):
		_request_refresh()


func _on_relationship_met(
	relationship_owner: Node,
	other: Node,
	relationship: Dictionary
) -> void:
	if (
		_is_current_player_row(relationship_owner, other, relationship)
		and _update_cached_opinion_snapshot(relationship)
	):
		_request_refresh()


func _is_current_player_row(
	relationship_owner: Node,
	other: Node,
	relationship: Dictionary
) -> bool:
	var owner := _get_owner()
	if owner == null:
		return false
	if relationship_owner != null and relationship_owner != owner:
		return false
	if relationship_owner == null:
		var owner_id := String(
			relationship.get("owner_id", "")
		).strip_edges()
		if owner_id != _owner_id:
			return false
	if other != null and is_instance_valid(other):
		return other.is_in_group("player")
	return NpcIdentity.is_player_id(
		String(relationship.get("other_id", ""))
	)


func _update_cached_opinion_snapshot(relationship: Dictionary) -> bool:
	var available := (
		not relationship.is_empty()
		and bool(relationship.get("met", false))
	)
	var favor := float(relationship.get("favor", 0.0)) if available else 0.0
	var changed := (
		not _snapshot_initialized
		or available != bool(
			_cached_opinion_snapshot.get("available", false)
		)
		or (
			available
			and not is_equal_approx(
				favor,
				float(_cached_opinion_snapshot.get("favor", 0.0))
			)
		)
	)
	_cached_opinion_snapshot = (
		{"available": true, "favor": favor}
		if available
		else {"available": false}
	)
	_cached_relationship_snapshot = relationship if available else {}
	_snapshot_initialized = true
	return changed


func _get_cached_opinion_result(include_relationship: bool) -> Dictionary:
	if not include_relationship:
		return _cached_opinion_snapshot
	if not bool(_cached_opinion_snapshot.get("available", false)):
		return {"available": false}
	return {
		"available": true,
		"favor": float(_cached_opinion_snapshot.get("favor", 0.0)),
		"relationship": _cached_relationship_snapshot.duplicate(true),
	}


func _on_relationship_graph_replaced() -> void:
	_cached_opinion_snapshot = {"available": false}
	_cached_relationship_snapshot = {}
	_snapshot_initialized = false
	_request_refresh()


func _request_refresh() -> void:
	var owner := _get_owner()
	if (
		owner != null
		and owner.has_method("refresh_player_relationship_presentation")
	):
		if _snapshot_initialized:
			owner.call(
				"refresh_player_relationship_presentation",
				_cached_opinion_snapshot
			)
		else:
			owner.call("refresh_player_relationship_presentation")


func _get_owner() -> Node:
	if _owner_ref == null:
		return null
	var owner = _owner_ref.get_ref()
	return owner as Node if owner is Node and is_instance_valid(owner) else null
