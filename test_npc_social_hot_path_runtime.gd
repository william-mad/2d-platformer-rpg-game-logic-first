extends "res://test/native_scene_tree_test.gd"

const SocialWriteRouter = preload(
	"res://scripts/systems/npc_social_write_router.gd"
)
const RelationshipsScript = preload(
	"res://scripts/systems/relationships.gd"
)


class IdentityProbeActor:
	extends Node2D

	var actor_id: StringName
	var identity_calls: int = 0
	var property_list_scans: int = 0

	func _init(new_actor_id: StringName) -> void:
		actor_id = new_actor_id
		name = String(new_actor_id).to_pascal_case()

	func get_npc_location_id() -> StringName:
		identity_calls += 1
		return actor_id

	func _get_property_list() -> Array[Dictionary]:
		property_list_scans += 1
		return []

	func reset_probes() -> void:
		identity_calls = 0
		property_list_scans = 0


var _relationship_changed_count: int = 0
var _favor_changed_count: int = 0
var _fear_changed_count: int = 0
var _last_changed_values: Dictionary = {}
var _last_relationship: Dictionary = {}


func test_single_metric_write_resolves_each_actor_once_without_hot_path_migration() -> void:
	_reset_signal_probes()
	var owner := _actor(&"hot_path_owner")
	var target := _actor(&"hot_path_target")
	var relationships := _relationships()
	var owner_alias := String(owner.get_path())
	relationships.relationships = {
		"hot_path_owner": {
			"hot_path_target": _relationship_row(
				"hot_path_owner", "hot_path_target"
			),
		},
	}
	relationships.relationships[owner_alias] = {
		"legacy_sentinel": _relationship_row(
			owner_alias, "legacy_sentinel"
		),
	}
	relationships.relationship_changed.connect(
		Callable(self, "_on_relationship_changed")
	)
	owner.reset_probes()
	target.reset_probes()

	var routed: Dictionary = SocialWriteRouter.route_delta(
		owner,
		target,
		{"trust": 5.0},
		relationships,
		"hot_path_test"
	)

	assert_eq(owner.identity_calls, 1, "owner identity resolves once")
	assert_eq(target.identity_calls, 1, "target identity resolves once")
	assert_eq(owner.property_list_scans, 0, "owner uses no property reflection")
	assert_eq(target.property_list_scans, 0, "target uses no property reflection")
	assert_true(
		relationships.relationships.has(owner_alias),
		"ordinary opinion writes never migrate a live path alias"
	)
	assert_eq(
		_relationship_changed_count,
		1,
		"one metric produces one generic relationship update"
	)
	assert_eq(
		float(relationships.relationships.hot_path_owner.hot_path_target.trust),
		55.0,
		"the canonical relationship row receives the mutation"
	)
	assert_eq(
		float(routed.directed_changes.get("trust", 0.0)),
		5.0,
		"the router returns the actual directed change"
	)


func test_multi_metric_write_is_one_batched_relationship_transaction() -> void:
	_reset_signal_probes()
	var owner := _actor(&"batch_owner")
	var target := _actor(&"batch_target")
	var relationships := _relationships()
	relationships.relationships = {
		"batch_owner": {
			"batch_target": _relationship_row(
				"batch_owner", "batch_target"
			),
		},
	}
	relationships.relationship_changed.connect(
		Callable(self, "_on_relationship_changed")
	)
	relationships.favor_changed.connect(
		Callable(self, "_on_favor_changed")
	)
	relationships.fear_changed.connect(
		Callable(self, "_on_fear_changed")
	)
	owner.reset_probes()
	target.reset_probes()

	var routed: Dictionary = SocialWriteRouter.route_delta(
		owner,
		target,
		{"favor": -7.0, "trust": 6.0, "fear": 4.0},
		relationships,
		"batch_hot_path_test"
	)

	assert_eq(owner.identity_calls, 1, "batch resolves owner identity once")
	assert_eq(target.identity_calls, 1, "batch resolves target identity once")
	assert_eq(owner.property_list_scans, 0, "batch owner uses no reflection")
	assert_eq(target.property_list_scans, 0, "batch target uses no reflection")
	assert_eq(_relationship_changed_count, 1, "batch emits one generic update")
	assert_eq(_favor_changed_count, 1, "batch preserves one legacy favor signal")
	assert_eq(_fear_changed_count, 1, "batch preserves one legacy fear signal")
	assert_eq(_last_changed_values.size(), 3, "generic update contains every delta")
	assert_eq(float(_last_changed_values.get("favor", 0.0)), -7.0)
	assert_eq(float(_last_changed_values.get("trust", 0.0)), 6.0)
	assert_eq(float(_last_changed_values.get("fear", 0.0)), 4.0)
	assert_eq(float(_last_relationship.get("favor", -1.0)), 43.0)
	assert_eq(float(_last_relationship.get("trust", -1.0)), 56.0)
	assert_eq(float(_last_relationship.get("fear", -1.0)), 4.0)
	assert_eq(
		routed.directed_changes,
		_last_changed_values,
		"router and generic signal expose the same actual changes"
	)


func _actor(actor_id: StringName) -> IdentityProbeActor:
	return add_child_autofree(
		IdentityProbeActor.new(actor_id)
	) as IdentityProbeActor


func _relationships() -> Node:
	var relationships := RelationshipsScript.new()
	relationships.name = "HotPathRelationships"
	relationships.emit_event_bus_events = false
	return add_child_autofree(relationships)


func _relationship_row(owner_id: String, other_id: String) -> Dictionary:
	return {
		"owner_id": owner_id,
		"other_id": other_id,
		"favor": 50.0,
		"trust": 50.0,
		"fear": 0.0,
		"met": true,
	}


func _reset_signal_probes() -> void:
	_relationship_changed_count = 0
	_favor_changed_count = 0
	_fear_changed_count = 0
	_last_changed_values = {}
	_last_relationship = {}


func _on_relationship_changed(
	_relationship_owner: Node,
	_other: Node,
	changed_values: Dictionary,
	relationship: Dictionary
) -> void:
	_relationship_changed_count += 1
	_last_changed_values = changed_values
	_last_relationship = relationship


func _on_favor_changed(
	_relationship_owner: Node,
	_other: Node,
	_favor: float,
	_delta: float,
	_relationship: Dictionary
) -> void:
	_favor_changed_count += 1


func _on_fear_changed(
	_relationship_owner: Node,
	_other: Node,
	_fear: float,
	_delta: float,
	_relationship: Dictionary
) -> void:
	_fear_changed_count += 1
