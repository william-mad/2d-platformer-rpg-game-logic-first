extends "res://test/native_scene_tree_test.gd"

const ActivitySelector = preload("res://scripts/systems/npc_activity_selector.gd")
const AffinityPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_activity_social_affinity_policy.gd"
)
const MemoryEvent = preload(
	"res://scripts/systems/npc_behavior/npc_memory_event.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const MachineScene = preload(
	"res://scenes/creatures/npc/npc_state_machine.tscn"
)


class TestActor:
	extends CharacterBody2D

	var persistent_id: StringName
	var relationship_id: StringName

	func _init(new_id: StringName, new_relationship_id: StringName = &"") -> void:
		persistent_id = new_id
		relationship_id = new_relationship_id if new_relationship_id != &"" else new_id

	func get_npc_location_id() -> StringName:
		return persistent_id

	func get_relationship_id() -> StringName:
		return relationship_id


class FakeRelationships:
	extends Node

	var rows: Dictionary = {}

	func set_row(owner_id: String, other_id: String, row: Dictionary) -> void:
		rows["%s|%s" % [owner_id, other_id]] = row.duplicate(true)

	func get_relationship_by_id(owner_id: String, other_id: String) -> Dictionary:
		return rows.get("%s|%s" % [owner_id, other_id], {}).duplicate(true)


class FakeLocations:
	extends Node

	var records: Dictionary = {}
	var live_npcs: Dictionary = {}

	func get_record_snapshot(npc_id: String) -> Dictionary:
		return records.get(npc_id, {}).duplicate(true)

	func get_live_npc(npc_id: String) -> Node:
		return live_npcs.get(npc_id, null) as Node


class FakeActivityRuntime:
	extends RefCounted

	var spot_claim_counts: Dictionary = {}
	var spot_runtime_states: Dictionary = {}
	var social_bonuses: Dictionary = {}
	var incompatible_spots: Dictionary = {}

	func _definition_is_meal_cycle_managed(_definition: NpcSpotDefinition) -> bool:
		return false

	func _get_saved_stat(record: Dictionary, value_name: String, fallback: float = 0.0) -> float:
		var node_state = record.get("node_state", {})
		var stats = node_state.get("social_stats", {}) if node_state is Dictionary else {}
		return float(stats.get(value_name, fallback)) if stats is Dictionary else fallback

	func score_activity_spot_social_affinity(
		_npc_id: StringName,
		spot_id: StringName,
		_activity_kind: StringName
	) -> Dictionary:
		return {
			"social_bonus": float(social_bonuses.get(spot_id, 0.0)),
			"group_compatible": not bool(incompatible_spots.get(spot_id, false)),
		}


var _reservation_snapshot: Dictionary = {}
var _relationship_snapshot: Dictionary = {}


func before_each() -> void:
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	var relationships := root.get_node_or_null("Relationships")
	_reservation_snapshot = (
		simulator.spot_reservations.duplicate(true)
		if simulator != null
		else {}
	)
	_relationship_snapshot = relationships.get_save_data() if relationships != null else {}


func after_each() -> void:
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	var relationships := root.get_node_or_null("Relationships")
	if simulator != null:
		simulator.spot_reservations = _reservation_snapshot.duplicate(true)
		simulator.call("_sync_spot_claim_count_cache")
	if relationships != null:
		relationships.apply_save_data(_relationship_snapshot)


func test_high_favor_recreation_can_beat_a_comparable_empty_spot() -> void:
	var fixture := _policy_fixture()
	fixture.relationships.set_row("requester", "friend", {"favor": 100.0})
	fixture.locations.records["friend"] = {
		"pending_travel": {},
		"action": {
			"session_id": "friend-session",
			"status": "active",
			"phase": "executing",
		},
	}
	var occupied := _score(
		fixture,
		&"requester",
		&"Recreation",
		[_reservation("friend", "shared")]
	)
	var empty := _score(fixture, &"requester", &"Recreation", [])
	assert_true(
		float(occupied.social_bonus) > float(empty.social_bonus),
		"high directed favor makes the occupied recreation location more attractive"
	)
	fixture.locations.records["friend"]["action"]["phase"] = "moving_to_target"
	var approaching := _score(
		fixture,
		&"requester",
		&"Recreation",
		[_reservation("friend", "shared")]
	)
	assert_eq(
		float(approaching.social_bonus),
		0.0,
		"a reservation held while approaching is capacity, not social occupancy"
	)

	var runtime := FakeActivityRuntime.new()
	runtime.spot_claim_counts[&"z_shared"] = 1
	runtime.social_bonuses[&"z_shared"] = occupied.social_bonus
	var definitions := {
		&"a_empty": _definition(&"a_empty", &"Recreation", &"boredom", 2),
		&"z_shared": _definition(&"z_shared", &"Recreation", &"boredom", 2),
	}
	var selected := ActivitySelector.find_best_definition(
		definitions,
		&"requester",
		_record({"boredom": 80.0}),
		12.0,
		runtime
	)
	assert_same(selected, definitions[&"z_shared"], "offscreen selection uses the same bonus")


func test_neutral_occupant_provides_no_social_bonus() -> void:
	var fixture := _policy_fixture()
	fixture.relationships.set_row("requester", "neutral", {"favor": 50.0})
	var score := _score(
		fixture,
		&"requester",
		&"Recreation",
		[_reservation("neutral", "shared")]
	)
	assert_eq(float(score.social_bonus), 0.0, "neutral favor does not attract")


func test_high_anger_fear_and_recent_refusal_prevent_attraction() -> void:
	var fixture := _policy_fixture()
	fixture.relationships.set_row(
		"requester",
		"angry_target",
		{"favor": 100.0, "anger": 70.0}
	)
	fixture.relationships.set_row(
		"requester",
		"feared_target",
		{"favor": 100.0, "fear": 70.0}
	)
	assert_eq(
		float(_score(
			fixture, &"requester", &"Recreation", [_reservation("angry_target", "shared")]
		).social_bonus),
		0.0,
		"strong directed anger eliminates the attraction"
	)
	assert_eq(
		float(_score(
			fixture, &"requester", &"Recreation", [_reservation("feared_target", "shared")]
		).social_bonus),
		0.0,
		"strong directed fear eliminates the attraction"
	)

	fixture.relationships.set_row("requester", "refuser", {"favor": 100.0})
	var memory := add_child_autofree(NpcShortTermMemory.new()) as NpcShortTermMemory
	memory.remember(MemoryEvent.create(MemoryPolicy.EVENT_CONVERSATION_REFUSED, {
		"subject_id": "refuser",
		"target_id": "requester",
		"logical_action": "Talk",
	}, 10.0))
	var refused := _score(
		fixture,
		&"requester",
		&"Recreation",
		[_reservation("refuser", "shared")],
		memory,
		10.1
	)
	assert_eq(float(refused.social_bonus), 0.0, "the existing refusal memory suppresses attraction")


func test_rest_social_weight_is_weaker_than_recreation() -> void:
	var relationship := {"favor": 80.0}
	var rest := AffinityPolicy.score_relationship(&"Rest", relationship)
	var recreation := AffinityPolicy.score_relationship(&"Recreation", relationship)
	assert_true(float(rest.social_bonus) < float(recreation.social_bonus))
	assert_eq(float(rest.social_bonus), 12.0, "Rest uses the weaker +20 maximum curve")
	assert_eq(float(recreation.social_bonus), 21.0, "Recreation uses the +35 maximum curve")


func test_strongest_liked_participant_drives_group_attraction() -> void:
	var fixture := _policy_fixture()
	fixture.relationships.set_row("alice", "bob", {"favor": 90.0})
	fixture.relationships.set_row("alice", "mom", {"favor": 55.0})
	_set_present_shared_activity(fixture, "bob", "friends", "bob", 4)
	_set_present_shared_activity(fixture, "mom", "friends", "bob", 4)
	var score := _score(
		fixture,
		&"alice",
		&"Recreation",
		[_reservation("bob", "shared"), _reservation("mom", "shared")]
	)
	assert_eq(score.best_participant_id, &"bob")
	assert_eq(float(score.social_bonus), 28.0, "Bob's directed favor score wins")
	assert_eq(score.joining_session_id, "friends")


func test_multiple_liked_participants_do_not_stack_social_bonus() -> void:
	var fixture := _policy_fixture()
	fixture.relationships.set_row("alice", "bob", {"favor": 80.0})
	fixture.relationships.set_row("alice", "mom", {"favor": 80.0})
	var score := _score(
		fixture,
		&"alice",
		&"Recreation",
		[_reservation("bob", "shared"), _reservation("mom", "shared")]
	)
	assert_eq(float(score.social_bonus), 21.0, "two +21 relationships remain +21")
	assert_eq(score.best_participant_id, &"bob", "ties use stable participant IDs")


func test_strong_group_hostility_vetoes_a_liked_participant() -> void:
	var fixture := _policy_fixture()
	fixture.relationships.set_row("alice", "bob", {"favor": 90.0})
	fixture.relationships.set_row("alice", "mom", {"favor": 55.0, "anger": 95.0})
	var score := _score(
		fixture,
		&"alice",
		&"Recreation",
		[_reservation("bob", "shared"), _reservation("mom", "shared")]
	)
	assert_false(bool(score.group_compatible), "Mom's hostility vetoes the group")
	assert_eq(score.veto_participant_id, &"mom")
	assert_eq(float(score.social_bonus), 0.0)
	assert_eq(score.joining_session_id, "")
	var runtime := FakeActivityRuntime.new()
	runtime.incompatible_spots[&"hostile_group"] = true
	var definitions := {
		&"hostile_group": _definition(
			&"hostile_group", &"Recreation", &"boredom", 4
		),
	}
	assert_null(ActivitySelector.find_best_definition(
		definitions,
		&"alice",
		_record({"boredom": 80.0}),
		12.0,
		runtime
	), "an incompatible group is not a joinable offscreen destination")


func test_relationship_direction_is_requester_to_occupant() -> void:
	var fixture := _policy_fixture()
	fixture.relationships.set_row("requester", "occupant", {"favor": 50.0})
	fixture.relationships.set_row("occupant", "requester", {"favor": 100.0})
	var reverse_only := _score(
		fixture,
		&"requester",
		&"Recreation",
		[_reservation("occupant", "shared")]
	)
	assert_eq(float(reverse_only.social_bonus), 0.0, "occupant opinion is not read")
	fixture.relationships.set_row("requester", "occupant", {"favor": 100.0})
	fixture.relationships.set_row("occupant", "requester", {"favor": 0.0})
	var forward := _score(
		fixture,
		&"requester",
		&"Recreation",
		[_reservation("occupant", "shared")]
	)
	assert_eq(float(forward.social_bonus), 35.0, "requester opinion drives attraction")


func test_capacity_one_remains_exclusive() -> void:
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	assert_not_null(simulator)
	if simulator == null:
		return
	var spot := _spot(&"affinity_capacity_one", &"Recreation", 1)
	var first: Dictionary = simulator.try_claim_spot(
		&"first", "capacity-one-a", spot.spot_id, &"activity"
	)
	var second: Dictionary = simulator.try_claim_spot(
		&"second", "capacity-one-b", spot.spot_id, &"activity"
	)
	assert_true(bool(first.accepted), "the first occupant reserves the default-sized spot")
	assert_false(bool(second.accepted), "capacity one rejects a second occupant")
	var second_npc := add_child_autofree(TestActor.new(&"second")) as TestActor
	assert_false(
		spot.can_serve_npc_casual_activity(second_npc, &"Recreation"),
		"full exclusive spots are filtered before target selection"
	)


func test_capacity_above_one_allows_compatible_shared_use() -> void:
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	assert_not_null(simulator)
	if simulator == null:
		return
	var spot := _spot(&"affinity_capacity_two", &"Rest", 2)
	assert_true(bool(simulator.try_claim_spot(
		&"first", "capacity-two-a", spot.spot_id, &"activity"
	).accepted))
	var second_npc := add_child_autofree(TestActor.new(&"second")) as TestActor
	assert_true(
		spot.can_serve_npc_casual_activity(second_npc, &"Rest"),
		"one remaining seat keeps the compatible spot selectable"
	)
	assert_true(bool(simulator.try_claim_spot(
		&"second", "capacity-two-b", spot.spot_id, &"activity"
	).accepted))
	assert_false(bool(simulator.try_claim_spot(
		&"third", "capacity-two-c", spot.spot_id, &"activity"
	).accepted), "the explicit capacity is still enforced")


func test_shared_choice_targets_the_location_and_never_enters_follow() -> void:
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	var relationships := root.get_node_or_null("Relationships")
	assert_not_null(simulator)
	assert_not_null(relationships)
	if simulator == null or relationships == null:
		return
	var shared_spot := _spot(&"affinity_shared_choice", &"Recreation", 2)
	_spot(&"affinity_empty_choice", &"Recreation", 2)
	assert_true(bool(simulator.try_claim_spot(
		&"friend", "friend-recreation", shared_spot.spot_id, &"activity"
	).accepted))
	relationships.set_opinion_metric_by_id(
		"chooser", "friend", &"favor", 100.0, "test"
	)
	var fixture := _machine_fixture(&"chooser")
	var recreation_state := fixture.machine.get_state(&"Recreation") as NpcStateRecreation
	recreation_state.choice_rng.seed = 1
	fixture.machine.replace_values({
		"hp": 100.0,
		"disabled": 0.0,
		"knockout": 0.0,
		"sleep_need": 0.0,
		"hunger": 0.0,
		"tired": 0.0,
		"boredom": 80.0,
		"talk_need": 0.0,
	}, null, {}, false)
	assert_true(fixture.machine.evaluate_value_reactions(null, {}), "recreation need starts")
	assert_same(
		fixture.machine.get_recreation_target(),
		shared_spot,
		"the chosen action target is the shared activity location"
	)
	assert_eq(fixture.machine.active_action.action_kind, &"Recreation")
	assert_false(
		String(fixture.machine.current_state.name) == "TravelFollow",
		"the occupant never becomes a movement/follow target"
	)


func test_existing_solo_rest_and_recreation_still_work() -> void:
	var rest_spot := _spot(&"affinity_solo_rest", &"Rest", 1)
	var recreation_spot := _spot(&"affinity_solo_recreation", &"Recreation", 1)
	var resting := _machine_fixture(&"solo_rest")
	var recreating := _machine_fixture(&"solo_recreation")
	assert_true(resting.machine.assign_rest_target(rest_spot), "solo Rest still starts")
	assert_same(resting.machine.get_rest_target(), rest_spot)
	assert_true(
		recreating.machine.assign_recreation_target(recreation_spot),
		"solo Recreation still starts"
	)
	assert_same(recreating.machine.get_recreation_target(), recreation_spot)


func _policy_fixture() -> Dictionary:
	return {
		"locations": add_child_autofree(FakeLocations.new()) as FakeLocations,
		"relationships": add_child_autofree(FakeRelationships.new()) as FakeRelationships,
	}


func _score(
	fixture: Dictionary,
	requester_id: StringName,
	activity_kind: StringName,
	reservations: Array[Dictionary],
	memory: NpcShortTermMemory = null,
	now_game_hours: float = 10.0
) -> Dictionary:
	return AffinityPolicy.score_reserved_participants(
		requester_id,
		activity_kind,
		reservations,
		fixture.locations,
		fixture.relationships,
		memory,
		now_game_hours
	)


func _reservation(npc_id: String, spot_id: String) -> Dictionary:
	return {
		"npc_id": npc_id,
		"spot_id": spot_id,
		"session_id": "%s-session" % npc_id,
		"purpose": "activity",
	}


func _set_present_shared_activity(
	fixture: Dictionary,
	npc_id: String,
	shared_session_id: String,
	leader_id: String,
	capacity: int
) -> void:
	fixture.locations.records[npc_id] = {
		"pending_travel": {},
		"action": {
			"session_id": "%s-session" % npc_id,
			"status": "active",
			"phase": "executing",
			"metadata": {
				"shared_activity_session_id": shared_session_id,
				"shared_activity_type": "Recreation",
				"shared_activity_leader_id": leader_id,
				"shared_activity_spot_id": "shared",
				"shared_activity_capacity": capacity,
			},
		},
	}


func _definition(
	spot_id: StringName,
	state_name: StringName,
	value_name: StringName,
	capacity: int
) -> NpcSpotDefinition:
	var definition := NpcSpotDefinition.new()
	definition.spot_id = spot_id
	definition.scene_path = "res://scenes/testscenes/realtest1.tscn"
	definition.state_name = state_name
	definition.value_name = value_name
	definition.need_threshold = 50.0
	definition.priority = 10
	definition.capacity = capacity
	return definition


func _record(stats: Dictionary) -> Dictionary:
	return {"node_state": {"social_stats": stats.duplicate(true)}}


func _spot(
	spot_id: StringName,
	activity_kind: StringName,
	capacity: int
) -> NpcCasualSpot:
	var spot := NpcCasualSpot.new()
	spot.name = String(spot_id)
	spot.spot_id = spot_id
	spot.activity_state_name = activity_kind
	spot.reservation_capacity = capacity
	return add_child_autofree(spot) as NpcCasualSpot


func _machine_fixture(npc_id: StringName) -> Dictionary:
	var actor := TestActor.new(npc_id)
	actor.name = String(npc_id)
	actor.add_to_group("npc")
	var machine := MachineScene.instantiate() as NpcStateMachine
	machine.active = false
	actor.add_child(machine)
	add_child_autofree(actor)
	machine.bind_npc(actor)
	machine.initialize_states()
	machine.state_history = [machine.get_state(&"Idle")]
	return {"npc": actor, "machine": machine}
