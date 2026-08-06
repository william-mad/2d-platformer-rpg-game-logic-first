class_name NpcPlayerRelationshipPresentation extends RefCounted

const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")

var _owner_ref: WeakRef
var _relationships: Node


func bind(owner: Node, relationships: Node) -> void:
	unbind()
	if owner == null or not is_instance_valid(owner):
		return
	_owner_ref = weakref(owner)
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


func unbind() -> void:
	if _relationships != null and is_instance_valid(_relationships):
		var callbacks := {
			&"relationship_changed": Callable(
				self, "_on_relationship_changed"
			),
			&"relationship_met": Callable(self, "_on_relationship_met"),
			&"relationship_seen": Callable(self, "_on_relationship_met"),
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


func get_opinion_snapshot(player: Node) -> Dictionary:
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
	var owner_id := NpcIdentity.get_stable_actor_id(owner)
	var player_id := NpcIdentity.get_stable_actor_id(player)
	if (
		not NpcIdentity.is_stable_id(owner_id)
		or not NpcIdentity.is_player_id(player_id)
		or owner_id == player_id
	):
		return {"available": false}
	var relationship = _relationships.call(
		"get_relationship_by_id", owner_id, player_id
	)
	if (
		not (relationship is Dictionary)
		or relationship.is_empty()
		or not bool(relationship.get("met", false))
	):
		return {"available": false}
	return {
		"available": true,
		"favor": float(relationship.get("favor", 0.0)),
		"relationship": relationship.duplicate(true),
	}


func _on_relationship_changed(
	relationship_owner: Node,
	other: Node,
	changed_values: Dictionary,
	relationship: Dictionary
) -> void:
	if not changed_values.has("favor"):
		return
	if _is_current_player_row(relationship_owner, other, relationship):
		_request_refresh()


func _on_relationship_met(
	relationship_owner: Node,
	other: Node,
	relationship: Dictionary
) -> void:
	if _is_current_player_row(relationship_owner, other, relationship):
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
		if owner_id != NpcIdentity.get_stable_actor_id(owner):
			return false
	if other != null and is_instance_valid(other):
		return other.is_in_group("player")
	return NpcIdentity.is_player_id(
		String(relationship.get("other_id", ""))
	)


func _request_refresh() -> void:
	var owner := _get_owner()
	if (
		owner != null
		and owner.has_method("refresh_player_relationship_presentation")
	):
		owner.call("refresh_player_relationship_presentation")


func _get_owner() -> Node:
	if _owner_ref == null:
		return null
	var owner = _owner_ref.get_ref()
	return owner as Node if owner is Node and is_instance_valid(owner) else null
