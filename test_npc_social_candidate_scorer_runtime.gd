extends "res://test/native_scene_tree_test.gd"

const MemoryEvent = preload(
	"res://scripts/systems/npc_behavior/npc_memory_event.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const MemoryScene = preload(
	"res://scenes/creatures/npc/npc_state_machine.tscn"
)
const Scorer = preload(
	"res://scripts/systems/npc_behavior/npc_social_candidate_scorer.gd"
)
const SocialPlanner = preload(
	"res://scripts/systems/npc_social_planner.gd"
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


class LocalLocations:
	extends Node

	var live_npcs: Dictionary = {}

	func get_live_npc(npc_id: String) -> Node:
		return live_npcs.get(npc_id, null) as Node

	func get_current_scene_path() -> String:
		return "res://town.tscn"


class FakeRelationships:
	extends Node

	var rows: Dictionary = {}

	func set_row(owner_id: String, other_id: String, row: Dictionary) -> void:
		rows["%s|%s" % [owner_id, other_id]] = row.duplicate(true)

	func get_relationship_by_id(owner_id: String, other_id: String) -> Dictionary:
		return rows.get(
			"%s|%s" % [owner_id, other_id],
			{}
		).duplicate(true)

	func get_favor_by_id(owner_id: String, other_id: String, fallback: float = 50.0) -> float:
		return float(get_relationship_by_id(owner_id, other_id).get(
			"favor",
			fallback
		))

	func get_relationship_id(actor: Node) -> String:
		if actor != null and actor.has_method("get_relationship_id"):
			return String(actor.call("get_relationship_id"))
		if actor != null and actor.has_meta("relationship_id"):
			return String(actor.get_meta("relationship_id"))
		return ""


class AvailableMachine:
	extends Node

	var current_state: Node

	func _init() -> void:
		name = "NpcStateMachine"
		current_state = Node.new()
		current_state.name = "Idle"
		add_child(current_state)

	func is_socially_engaged() -> bool:
		return false

	func can_begin_player_interaction(_actor: Node) -> Dictionary:
		return {"accepted": true}


func test_higher_directed_favor_wins_over_neutral() -> void:
	var fixture := _planner_fixture()
	fixture.relationships.set_row("seeker_rel", "liked_rel", {"favor": 85.0})
	var records := {
		"seeker": _record("seeker_rel"),
		"neutral": _record("neutral_rel"),
		"liked": _record("liked_rel"),
	}
	var selected := _choose(fixture, records.seeker, records)
	assert_eq(selected.target_id, "liked", "requester's higher directed favor wins")
	fixture.relationships.set_row("liked_rel", "seeker_rel", {"favor": 11.0})
	selected = _choose(fixture, records.seeker, records)
	assert_eq(
		selected.target_id,
		"liked",
		"candidate's weaker opinion does not replace requester-directed scoring"
	)


func test_love_helps_while_fear_and_anger_reduce_bounded_score() -> void:
	var scorer := Scorer.new()
	var loved := scorer.score_candidate(&"a", &"b", {
		"relationship": {"favor": 50.0, "love": 100.0},
	})
	var afraid := scorer.score_candidate(&"a", &"b", {
		"relationship": {"favor": 50.0, "fear": 100.0},
	})
	var angry := scorer.score_candidate(&"a", &"b", {
		"relationship": {"favor": 50.0, "anger": 100.0},
	})
	assert_true(loved.total_score > 0.0, "directed love is a moderate positive")
	assert_true(afraid.total_score < 0.0, "directed fear is a negative")
	assert_true(angry.total_score < afraid.total_score, "anger is the stronger negative")
	var extreme := scorer.score_candidate(&"a", &"b", {
		"relationship": {
			"favor": 10000.0,
			"love": 10000.0,
			"fear": -10000.0,
			"anger": -10000.0,
		},
	})
	assert_true(float(extreme.total_score) <= 100.0, "malformed extremes remain bounded")


func test_authored_preference_matters_but_cannot_bypass_memory() -> void:
	var fixture := _planner_fixture()
	fixture.relationships.set_row("seeker_rel", "preferred_rel", {"favor": 30.0})
	var seeker := _record("seeker_rel")
	seeker.social_visit_target_id = "preferred"
	var records := {
		"seeker": seeker,
		"preferred": _record("preferred_rel"),
		"neutral": _record("neutral_rel"),
	}
	assert_eq(
		_choose(fixture, seeker, records).target_id,
		"preferred",
		"the documented bonus can overcome a modest favor difference"
	)
	var memory := _memory()
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"preferred", &"Talk")
	assert_eq(
		_choose(fixture, seeker, records, memory).target_id,
		"neutral",
		"authored preference never bypasses refusal eligibility"
	)
	var blocked := _decision_for(
		fixture.planner.get_last_selection_descriptor(),
		"preferred"
	)
	assert_false(blocked.has("total_score"), "blocked preference never reaches scoring")


func test_all_social_memory_types_filter_before_scoring() -> void:
	var fixture := _planner_fixture()
	var memory := _memory()
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"refuser", &"Talk")
	_remember(memory, MemoryPolicy.EVENT_HARMED_BY_ACTOR, &"attacker", &"Harm")
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_COMPLETED, &"recent", &"Talk")
	var records := {
		"seeker": _record("seeker_rel"),
		"refuser": _record("refuser_rel"),
		"attacker": _record("attacker_rel"),
		"recent": _record("recent_rel"),
		"allowed": _record("allowed_rel"),
	}
	assert_eq(_choose(fixture, records.seeker, records, memory).target_id, "allowed")
	var descriptor: Dictionary = fixture.planner.get_last_selection_descriptor()
	assert_eq(descriptor.suppressed_count, 3, "all three existing policies remain hard filters")
	for blocked_id in ["refuser", "attacker", "recent"]:
		assert_false(
			_decision_for(descriptor, blocked_id).has("total_score"),
			"%s was removed before scoring" % blocked_id
		)


func test_player_uses_directed_relationship_and_canonical_memory_identity() -> void:
	var fixture := _planner_fixture()
	var player := TestActor.new(&"scene_player", &"player_rel")
	player.add_to_group("player")
	add_child_autofree(player)
	fixture.player = player
	fixture.relationships.set_row("seeker_rel", "player_rel", {"favor": 90.0})
	var records := {
		"seeker": _record("seeker_rel"),
		"neutral": _record("neutral_rel"),
	}
	assert_eq(
		_choose(fixture, records.seeker, records).target_id,
		"__player__",
		"player has no universal bonus but can win through directed favor"
	)
	var memory := _memory()
	_remember(memory, MemoryPolicy.EVENT_HARMED_BY_ACTOR, &"__player__", &"Harm")
	assert_eq(
		_choose(fixture, records.seeker, records, memory).target_id,
		"neutral",
		"canonical player harm remains a pre-score exclusion"
	)


func test_distance_breaks_close_scores_without_overwhelming_relationship() -> void:
	var fixture := _planner_fixture()
	var requester := _live_actor(&"seeker", &"seeker_rel", Vector2.ZERO)
	var near := _live_actor(&"near", &"near_rel", Vector2(16.0, 0.0))
	var far := _live_actor(&"far", &"far_rel", Vector2(1024.0, 0.0))
	fixture.locations.live_npcs = {"seeker": requester, "near": near, "far": far}
	var records := {
		"seeker": _record("seeker_rel"),
		"near": _record("near_rel"),
		"far": _record("far_rel"),
	}
	assert_eq(_choose(fixture, records.seeker, records).target_id, "near", "distance breaks neutral tie")
	fixture.relationships.set_row("seeker_rel", "far_rel", {"favor": 85.0})
	assert_eq(
		_choose(fixture, records.seeker, records).target_id,
		"far",
		"clear relationship strength exceeds even a large capped distance cost"
	)


func test_equal_offscreen_candidates_use_stable_id_not_input_order() -> void:
	var fixture := _planner_fixture()
	var records := {
		"seeker": _record("seeker_rel"),
		"zeta": _record("zeta_rel", Vector2.ZERO),
		"alpha": _record("alpha_rel", Vector2(50000.0, 0.0)),
	}
	assert_eq(
		_choose(fixture, records.seeker, records).target_id,
		"alpha",
		"offscreen positions are ignored and stable ID resolves equality"
	)
	var reversed := {
		"seeker": records.seeker,
		"alpha": records.alpha,
		"zeta": records.zeta,
	}
	assert_eq(_choose(fixture, records.seeker, reversed).target_id, "alpha")


func test_live_path_shares_scorer_and_selection_does_not_mutate_ownership() -> void:
	var global_relationships := root.get_node_or_null("Relationships")
	assert_not_null(global_relationships, "live parity needs relationship autoload")
	if global_relationships == null:
		return
	var original: Dictionary = global_relationships.get_save_data()
	global_relationships.apply_save_data({"relationships": {
		"live_seeker_rel": {
			"liked_rel": {"favor": 90.0},
			"neutral_rel": {"favor": 50.0},
		},
	}})
	var requester := _live_actor(
		&"live_seeker",
		&"live_seeker_rel",
		Vector2.ZERO,
		false
	)
	var machine := MemoryScene.instantiate() as NpcStateMachine
	machine.active = false
	requester.add_child(machine)
	machine.bind_npc(requester)
	var neutral := _live_actor(&"neutral", &"neutral_rel", Vector2(10.0, 0.0))
	var liked := _live_actor(&"liked", &"liked_rel", Vector2(500.0, 0.0))
	var ranked := machine.select_ranked_autonomous_social_target([neutral, liked])
	assert_same(ranked.target_node, liked, "live ranking uses the shared directed formula")
	machine.perceived_targets = [liked]
	var live_rule := {
		"state": "Talk",
		"behavior_source": "social_ai",
		"target_groups": [&"npc", &"player"],
		"min_relationship_favor": 10.0,
		"requires_target": true,
	}
	assert_same(
		machine.call("_get_rule_request_actor", neutral, live_rule),
		liked,
		"live seen-target rule ranks actor and perception candidates together"
	)
	assert_null(machine.active_action, "ranking creates no action session")
	assert_null(machine.behavior_controller.current_intent, "ranking submits no intention")

	var fixture := _planner_fixture()
	var records := {"seeker": _record("seeker_rel"), "partner": _record("partner_rel")}
	_choose(fixture, records.seeker, records)
	assert_true(fixture.planner.get("_participant_reservations").is_empty(), "selection reserves nothing")
	var reservation: Dictionary = fixture.planner.reserve_pair(
		"seeker", records.seeker, "partner", records.partner, fixture.locations, 60
	)
	assert_true(bool(reservation.accepted), "existing reservation owner still commits the pair")
	var session_before: Dictionary = fixture.planner.get("_sessions").duplicate(true)
	Scorer.new().score_candidate(&"seeker", &"other", {"relationship": {"favor": 100.0}})
	assert_eq(fixture.planner.get("_sessions"), session_before, "later scoring cannot retarget a session")
	global_relationships.apply_save_data(original)


func _planner_fixture() -> Dictionary:
	var planner := SocialPlanner.new()
	planner.begin_simulation_pass()
	var locations := add_child_autofree(LocalLocations.new()) as LocalLocations
	var relationships := add_child_autofree(FakeRelationships.new()) as FakeRelationships
	return {
		"planner": planner,
		"locations": locations,
		"relationships": relationships,
		"player": null,
	}


func _choose(
	fixture: Dictionary,
	seeker: Dictionary,
	records: Dictionary,
	memory: NpcShortTermMemory = null
) -> Dictionary:
	fixture.planner.begin_simulation_pass()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	return fixture.planner.choose_candidate(
		&"seeker",
		seeker,
		records,
		fixture.locations,
		{"priority": 60, "minimum_npc_favor": 10.0},
		fixture.relationships,
		fixture.player,
		rng,
		Callable(),
		memory,
		10.1,
		{"remembering_npc_id": "seeker"}
	)


func _record(
	relationship_id: String,
	position: Vector2 = Vector2.ZERO
) -> Dictionary:
	return {
		"scene_path": "res://town.tscn",
		"previous_scene_path": "",
		"last_position": position,
		"activity": {},
		"pending_travel": {},
		"social_visit_target_id": "",
		"social_session_id": "",
		"node_state": {
			"relationship_id": relationship_id,
			"social_stats": {
				"hp": 100.0,
				"disabled": 0.0,
				"knockout": 0.0,
				"talk_need": 90.0,
			},
		},
	}


func _memory() -> NpcShortTermMemory:
	return add_child_autofree(NpcShortTermMemory.new()) as NpcShortTermMemory


func _remember(
	memory: NpcShortTermMemory,
	event_type: StringName,
	subject_id: StringName,
	logical_action: StringName
) -> void:
	memory.remember(MemoryEvent.create(event_type, {
		"subject_id": subject_id,
		"target_id": "seeker",
		"logical_action": logical_action,
	}, 10.0))


func _decision_for(descriptor: Dictionary, candidate_id: String) -> Dictionary:
	for decision in descriptor.get("candidate_decisions", []):
		if String(decision.get("candidate_id", "")) == candidate_id:
			return decision
	return {}


func _live_actor(
	persistent_id: StringName,
	relationship_id: StringName,
	position: Vector2,
	attach_available_machine: bool = true
) -> TestActor:
	var actor := TestActor.new(persistent_id, relationship_id)
	actor.name = String(persistent_id)
	actor.position = position
	actor.add_to_group("npc")
	if attach_available_machine:
		actor.add_child(AvailableMachine.new())
	add_child_autofree(actor)
	return actor
