extends "res://test/native_scene_tree_test.gd"

const ActionSession = preload("res://scripts/systems/npc_action_session.gd")
const BehaviorIntent = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_intent.gd"
)
const FeedbackFormatter = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_feedback_formatter.gd"
)
const MemoryEvent = preload(
	"res://scripts/systems/npc_behavior/npc_memory_event.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const MemoryScene = preload(
	"res://scenes/creatures/npc/npc_state_machine.tscn"
)
const SocialMemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_social_memory_policy.gd"
)
const SocialPlanner = preload(
	"res://scripts/systems/npc_social_planner.gd"
)
const WorldSimulation = preload(
	"res://scripts/systems/npc_world_simulation.gd"
)

var _previous_total_hours: float = 0.0
var _previous_auto_advance: bool = false


class TestNpc:
	extends CharacterBody2D

	var persistent_id: StringName

	func _init(new_id: StringName) -> void:
		persistent_id = new_id

	func get_npc_location_id() -> StringName:
		return persistent_id


class LocalLocations:
	extends Node

	var live_npcs: Dictionary = {}

	func get_live_npc(npc_id: String) -> Node:
		return live_npcs.get(npc_id, null) as Node

	func get_current_scene_path() -> String:
		return "res://town.tscn"


func before_each() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		_previous_total_hours = world_time.get_total_hours()
		_previous_auto_advance = world_time.auto_advance
		world_time.auto_advance = false
		world_time.set_total_hours(10.0)


func after_each() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		world_time.auto_advance = _previous_auto_advance
		world_time.set_total_hours(_previous_total_hours)


func test_policy_filters_only_matching_unresolved_refusal() -> void:
	var policy := SocialMemoryPolicy.new()
	var memory := _memory()
	assert_true(
		bool(policy.evaluate_candidate(memory, &"mom", 10.0).allowed),
		"no memory allows an NPC candidate"
	)
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_COMPLETED, &"dad", 10.0)
	_remember(memory, MemoryPolicy.EVENT_ACTION_FAILED, &"mom", 10.0)
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"dad", 10.0)
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"mom", 10.1, {"remembering_npc_id": "child"}
		).allowed),
		"generic failures and memories about other partners do not suppress"
	)
	var refusal_result := _remember(
		memory,
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		&"mom",
		10.0,
		{"metadata": {"feedback_text": "arbitrary localized words"}}
	)
	var decision := policy.evaluate_candidate(
		memory, &"mom", 10.07, {"remembering_npc_id": "child"}
	)
	assert_false(bool(decision.allowed), "the exact recent refuser is suppressed")
	assert_eq(
		decision.reason_code,
		&"recent_conversation_refusal",
		"suppression has a stable structured reason"
	)
	assert_eq(decision.subject_id, &"mom", "the refuser keeps its persistent ID")
	assert_true(
		float(decision.remaining_retry_hours) > 0.17
		and float(decision.remaining_retry_hours) < 0.19,
		"remaining retry time uses total game hours"
	)
	assert_true(
		memory.resolve_memory(String(refusal_result.memory.memory_id), &"test"),
		"the refusal can be explicitly resolved"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"mom", 10.08, {"remembering_npc_id": "child"}
		).allowed),
		"resolved refusal memories explicitly do not suppress"
	)


func test_harm_and_completed_conversation_have_independent_short_cooldowns() -> void:
	var policy := SocialMemoryPolicy.new()
	var memory := _memory()
	_remember(
		memory,
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		&"mom",
		10.0,
		{"logical_action": "Harm"}
	)
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_COMPLETED, &"dad", 10.0)
	var harm := policy.evaluate_candidate(
		memory, &"mom", 10.2, {"remembering_npc_id": "child"}
	)
	var repeat := policy.evaluate_candidate(
		memory, &"dad", 10.1, {"remembering_npc_id": "child"}
	)
	assert_eq(harm.reason_code, &"recently_harmed_by_candidate", "harm blocks its actor")
	assert_eq(harm.memory_event_type, MemoryPolicy.EVENT_HARMED_BY_ACTOR, "harm type is explicit")
	assert_eq(repeat.reason_code, &"recently_talked_with_candidate", "completion avoids a repeat")
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"mom", 10.51, {"remembering_npc_id": "child"}
		).allowed),
		"harm stops controlling social choice after 0.5 game hours"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"dad", 10.126, {"remembering_npc_id": "child"}
		).allowed),
		"conversation completion stops controlling choice after 0.125 game hours"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"mom", 10.51, {"remembering_npc_id": "someone_else"}
		).allowed),
		"the same event remains scoped to the remembering NPC"
	)


func test_multiple_blockers_choose_latest_expiry_then_severity_and_memory_id() -> void:
	var policy := SocialMemoryPolicy.new()
	var memory := _memory()
	_remember(
		memory,
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		&"mom",
		10.0,
		{"logical_action": "Harm"}
	)
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"mom", 10.3)
	var latest := policy.evaluate_candidate(
		memory, &"mom", 10.31, {"remembering_npc_id": "child"}
	)
	assert_eq(
		latest.reason_code,
		&"recent_conversation_refusal",
		"latest retry expiry controls even when an earlier blocker is more severe"
	)

	var equal_memory := _memory()
	_remember(
		equal_memory,
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		&"mom",
		10.0,
		{"logical_action": "Harm"}
	)
	_remember(equal_memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"mom", 10.25)
	_remember(equal_memory, MemoryPolicy.EVENT_CONVERSATION_COMPLETED, &"mom", 10.375)
	var equal_expiry := policy.evaluate_candidate(
		equal_memory, &"mom", 10.4, {"remembering_npc_id": "child"}
	)
	assert_eq(
		equal_expiry.reason_code,
		&"recently_harmed_by_candidate",
		"equal retry expiry uses harm, refusal, completed severity order"
	)
	var by_id: Array[Dictionary] = [
		{"retry_game_hours": 11.0, "reason_code": &"recent_conversation_refusal", "memory_id": "z"},
		{"retry_game_hours": 11.0, "reason_code": &"recent_conversation_refusal", "memory_id": "a"},
	]
	by_id.sort_custom(SocialMemoryPolicy._blocker_precedes)
	assert_eq(by_id[0].memory_id, "a", "equal blockers use stable memory-ID order")


func test_policy_uses_last_update_and_keeps_longer_memory() -> void:
	var world_time := root.get_node("WorldTime") as WorldTimeSystem
	var policy := SocialMemoryPolicy.new()
	var memory := _memory()
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"mom", 10.0)
	world_time.set_total_hours(10.2)
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"mom", 10.2)
	var merged := memory.find_recent(
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		&"mom"
	)[0]
	assert_eq(merged.occurrence_count, 2, "a genuine repeat merges once")
	assert_false(
		bool(policy.evaluate_candidate(
			memory, &"mom", 10.3, {"remembering_npc_id": "child"}
		).allowed),
		"the merged memory's last update restarts the short delay"
	)
	world_time.set_total_hours(10.46)
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"mom", 10.46, {"remembering_npc_id": "child"}
		).allowed),
		"the candidate returns after the independent 0.25-hour delay"
	)
	assert_true(
		memory.has_recent(MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"mom"),
		"the 1.5-hour memory remains after behavior suppression expires"
	)


func test_policy_query_is_read_only_and_text_independent() -> void:
	var policy := SocialMemoryPolicy.new()
	var memory := _memory()
	_remember(
		memory,
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		&"mom",
		10.0,
		{"metadata": {"feedback_text": "first text"}}
	)
	var before := _memory_snapshot(memory)
	var first := policy.evaluate_candidate(
		memory, &"mom", 10.1, {"remembering_npc_id": "child"}
	)
	var second_memory := _memory()
	_remember(
		second_memory,
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		&"mom",
		10.0,
		{"metadata": {"feedback_text": "entirely different text"}}
	)
	var second := policy.evaluate_candidate(
		second_memory, &"mom", 10.1, {"remembering_npc_id": "child"}
	)
	assert_eq(_memory_snapshot(memory), before, "policy evaluation does not mutate memory")
	assert_eq(first.allowed, second.allowed, "feedback wording has no policy authority")
	assert_eq(
		first.remaining_retry_hours,
		second.remaining_retry_hours,
		"feedback wording cannot alter retry timing"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			memory, &"", 10.1, {"remembering_npc_id": "child"}
		).allowed),
		"a missing candidate ID fails safely without broad suppression"
	)


func test_planner_selects_alternative_without_reordering_allowed_candidates() -> void:
	var planner := SocialPlanner.new()
	var memory := _memory()
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"mom", 10.0)
	var locations := add_child_autofree(LocalLocations.new()) as LocalLocations
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var seeker := _record()
	seeker["social_visit_target_id"] = "mom"
	var records := {
		"child": seeker,
		"mom": _record(),
		"dad": _record(),
	}
	planner.begin_simulation_pass()
	var selected := planner.choose_candidate(
		&"child",
		seeker,
		records,
		locations,
		_settings(),
		null,
		null,
		rng,
		Callable(),
		memory,
		10.1,
		{"remembering_npc_id": "child"}
	)
	assert_eq(selected.target_id, "dad", "an allowed alternative is selected")
	var descriptor := planner.get_last_selection_descriptor()
	assert_eq(descriptor.candidates_considered, 2, "both valid NPC candidates were considered")
	assert_eq(descriptor.suppressed_by_refusal_count, 1, "only Mom was suppressed")
	assert_eq(descriptor.selected_candidate_id, "dad", "the allowed selection is observable")
	assert_true(bool(descriptor.alternative_selected), "alternative selection is explicit")
	assert_false(
		bool(descriptor.all_candidates_suppressed),
		"alternative selection does not install blocked-all feedback"
	)


func test_all_suppressed_is_non_mutating_and_reports_earliest_retry() -> void:
	var planner := SocialPlanner.new()
	var memory := _memory()
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"mom", 10.0)
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"dad", 10.1)
	var locations := add_child_autofree(LocalLocations.new()) as LocalLocations
	var rng := RandomNumberGenerator.new()
	var seeker := _record()
	var records := {
		"child": seeker,
		"mom": _record(),
		"dad": _record(),
	}
	var memory_before := _memory_snapshot(memory)
	var talk_need_before := float(seeker.node_state.social_stats.talk_need)
	planner.begin_simulation_pass()
	var selected := planner.choose_candidate(
		&"child",
		seeker,
		records,
		locations,
		_settings(),
		null,
		null,
		rng,
		Callable(),
		memory,
		10.1,
		{"remembering_npc_id": "child"}
	)
	var descriptor := planner.get_last_selection_descriptor()
	assert_true(selected.is_empty(), "no suppressed target is selected")
	assert_eq(
		descriptor.reason_code,
		&"no_social_target_due_to_recent_memory",
		"all-suppressed has a stable planner result"
	)
	assert_true(bool(descriptor.all_candidates_suppressed), "all-suppressed is explicit")
	assert_eq(descriptor.earliest_retry_game_hours, 10.25, "earliest retry uses the shortest delay")
	assert_true(
		float(descriptor.remaining_retry_hours) > 0.149
		and float(descriptor.remaining_retry_hours) < 0.151,
		"remaining retry is reported"
	)
	assert_eq(_memory_snapshot(memory), memory_before, "candidate search creates no memory")
	assert_eq(
		float(seeker.node_state.social_stats.talk_need),
		talk_need_before,
		"candidate search does not reduce social need"
	)
	var reservation := planner.reserve_pair(
		"child", seeker, "mom", records.mom, locations, 60
	)
	assert_true(
		bool(reservation.accepted),
		"no reservation was claimed while all candidates were suppressed"
	)
	planner.begin_simulation_pass()
	var selected_after_retry := planner.choose_candidate(
		&"child",
		seeker,
		records,
		locations,
		_settings(),
		null,
		null,
		rng,
		Callable(),
		memory,
		10.26,
		{"remembering_npc_id": "child"}
	)
	assert_eq(
		selected_after_retry.target_id,
		"mom",
		"the earliest previously suppressed candidate becomes selectable"
	)


func test_persistent_identity_and_requester_independence() -> void:
	var policy := SocialMemoryPolicy.new()
	var child_memory := _memory()
	var sibling_memory := _memory()
	_remember(child_memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"mom:anna", 10.0)
	assert_false(
		bool(policy.evaluate_candidate(
			child_memory,
			&"mom:anna",
			10.1,
			{"remembering_npc_id": "child"}
		).allowed),
		"the same persistent identity remains suppressed across node replacement"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			child_memory,
			&"mom:anne",
			10.1,
			{"remembering_npc_id": "child"}
		).allowed),
		"similar display identities remain distinct"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			sibling_memory,
			&"mom:anna",
			10.1,
			{"remembering_npc_id": "sibling"}
		).allowed),
		"different requesters have independent memory"
	)
	assert_true(
		bool(policy.evaluate_candidate(
			child_memory,
			&"merchant",
			10.1,
			{"remembering_npc_id": "child"}
		).allowed),
		"stale unrelated identities do not block a valid candidate"
	)


func test_world_boundary_submits_nothing_when_all_candidates_suppressed() -> void:
	var fixture := _full_npc_fixture(&"child")
	fixture.machine.active = true
	var memory := fixture.memory as NpcShortTermMemory
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"mom", 10.0)
	_remember(memory, MemoryPolicy.EVENT_CONVERSATION_REFUSED, &"dad", 10.0)
	var controller := fixture.controller as NpcBehaviorController
	var existing_intent := BehaviorIntent.create(
		&"Eat",
		&"Eat",
		&"schedule",
		&"scheduled_meal",
		50,
		&"",
		"",
		5.0
	)
	controller.commit_candidate(existing_intent)
	var accepted_before: int = controller.accepted_at_usec
	var locations := add_child_autofree(LocalLocations.new()) as LocalLocations
	locations.live_npcs["child"] = fixture.npc
	var seeker := _record()
	var records := {
		"child": seeker,
		"mom": _record(),
		"dad": _record(),
	}
	var world := add_child_autofree(WorldSimulation.new()) as Node
	var planner: NpcSocialPlanner = world.get("_social_planner")
	planner.begin_simulation_pass()
	var started := bool(world.call(
		"_try_start_social_seek",
		&"child",
		seeker,
		records,
		locations,
		-1
	))
	assert_false(started, "all-suppressed creates no social start")
	assert_eq(
		controller.current_intent.intent_id,
		existing_intent.intent_id,
		"the current accepted intention is unchanged"
	)
	assert_eq(
		controller.accepted_at_usec,
		accepted_before,
		"commitment timing does not restart"
	)
	assert_null(
		fixture.machine.get("_proposed_action"),
		"no proposed social action is created or consumed"
	)
	assert_null(
		fixture.machine.active_action,
		"no social action session is created"
	)
	assert_true(
		controller.get_feedback_descriptor().get(
			"rejected_intent",
			{}
		).is_empty(),
		"memory filtering installs no commitment-rejection feedback"
	)
	assert_eq(
		String(fixture.machine.current_state.name),
		"Idle",
		"the machine does not repeatedly enter social search"
	)
	var descriptor: Dictionary = world.call(
		"get_social_selection_debug_descriptor",
		&"child"
	)
	assert_eq(
		descriptor.reason_code,
		&"no_social_target_due_to_recent_memory",
		"world observability exposes the planner result"
	)
	assert_true(
		String(fixture.label.text).contains("social: waiting after refusal"),
		"StateLabel shows one concise temporary policy line"
	)


func test_policy_does_not_interrupt_established_action_or_talk_feedback() -> void:
	var fixture := _full_npc_fixture(&"child")
	var partner := TestNpc.new(&"mom")
	partner.name = "MomReplacement"
	partner.add_to_group("npc")
	add_child_autofree(partner)
	var session := ActionSession.create(
		"child",
		&"LookForTalkTarget",
		&"social_ai",
		partner,
		{"session_id": "social:active", "status": "active", "phase": "approaching"}
	)
	fixture.machine.replace_active_action(session, "test")
	_remember(
		fixture.memory,
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		&"mom",
		10.0
	)
	var before: NpcActionSession = fixture.machine.active_action
	var decision := SocialMemoryPolicy.new().evaluate_candidate(
		fixture.memory,
		&"mom",
		10.1,
		{"remembering_npc_id": "child"}
	)
	assert_false(bool(decision.allowed), "a future selection would be suppressed")
	assert_same(
		fixture.machine.active_action,
		before,
		"querying policy cannot cancel an established approach/session"
	)
	assert_eq(
		fixture.machine.active_action.phase,
		&"approaching",
		"same-session movement phase continues"
	)
	var formatted := FeedbackFormatter.format_label(
		&"MoveToTarget",
		&"Talk",
		{
			"intent": {
				"logical_action_kind": "Eat",
				"feedback_text": "Hungry",
				"source": "need",
				"priority": 50,
			},
			"rejected_intent": {
				"feedback_text": "Wants to talk",
				"priority": 40,
			},
			"social_selection": {
				"all_candidates_suppressed": true,
				"reason_code": "no_social_target_due_to_recent_refusal",
			},
			"memory": {
				"recent": [{"debug_feedback_text": "Mom refused to talk"}],
			},
		}
	)
	assert_true(formatted.contains("+ Talk"), "Talk overlay feedback remains visible")
	assert_true(formatted.contains("blocked:"), "commitment rejection feedback remains visible")
	assert_true(formatted.contains("social: waiting"), "social policy feedback is adjacent")
	assert_true(formatted.contains("remembers:"), "memory feedback is not replaced")


func test_feedback_expires_after_retry_window() -> void:
	var world_time := root.get_node("WorldTime") as WorldTimeSystem
	var fixture := _full_npc_fixture(&"child")
	fixture.machine.set_social_selection_feedback({
		"all_candidates_suppressed": true,
		"reason_code": "no_social_target_due_to_recent_refusal",
		"earliest_retry_game_hours": 10.25,
		"remaining_retry_hours": 0.25,
	})
	assert_false(
		fixture.machine.get_feedback_descriptor().get(
			"social_selection",
			{}
		).is_empty(),
		"active suppression is exposed"
	)
	world_time.set_total_hours(10.26)
	assert_true(
		fixture.machine.get_feedback_descriptor().get(
			"social_selection",
			{}
		).is_empty(),
		"large game-time jumps clear expired debug feedback deterministically"
	)
	fixture.machine.set_social_selection_feedback({
		"all_candidates_suppressed": false,
		"selected_candidate_id": "__player__",
	})
	assert_false(
		String(fixture.machine.call("_format_debug_label_text")).contains(
			"waiting after refusal"
		),
		"player Talk and successful alternatives do not show blocked-all feedback"
	)


func test_live_seen_target_rule_filters_npcs_and_canonical_player() -> void:
	var fixture := _full_npc_fixture(&"child")
	var mom := TestNpc.new(&"mom")
	mom.add_to_group("npc")
	add_child_autofree(mom)
	var player := Node2D.new()
	player.add_to_group("player")
	add_child_autofree(player)
	_remember(
		fixture.memory,
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		&"mom",
		10.0
	)
	_remember(
		fixture.memory,
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		&"__player__",
		10.0,
		{"logical_action": "Harm"}
	)
	var social_rule := {
		"state": "Talk",
		"behavior_source": "social_ai",
		"target_groups": [&"npc", &"player"],
		"min_relationship_favor": 10.0,
	}
	assert_false(
		bool(fixture.machine.call("_rule_allows_target", social_rule, mom)),
		"the immediate live NPC candidate path applies the same policy"
	)
	assert_false(
		bool(fixture.machine.call("_rule_allows_target", social_rule, player)),
		"autonomous social Talk uses the canonical player memory identity"
	)
	var player_initiated_rule := social_rule.duplicate(true)
	player_initiated_rule["behavior_source"] = "player_interaction"
	assert_true(
		bool(fixture.machine.call(
			"_rule_allows_target",
			player_initiated_rule,
			player
		)),
		"non-social-AI interaction remains governed by its separate policy"
	)
	var completed: Dictionary = fixture.observer.observe_conversation_completed(player, {
		"session_id": "social:player:completed",
		"target_persistent_id": "scene_specific_player_id",
		"source": "social_ai",
		"phase": "completed",
	})
	assert_true(bool(completed.accepted), "completed player Talk creates normal memory")
	assert_eq(
		completed.memory.subject_id,
		"__player__",
		"player conversation memory ignores scene-specific player identity"
	)
	var planner := SocialPlanner.new()
	var locations := add_child_autofree(LocalLocations.new()) as LocalLocations
	var rng := RandomNumberGenerator.new()
	planner.begin_simulation_pass()
	var selected := planner.choose_candidate(
		&"child",
		_record(),
		{"child": _record()},
		locations,
		_settings(),
		null,
		player,
		rng,
		Callable(),
		fixture.memory,
		10.1,
		{"remembering_npc_id": "child"}
	)
	assert_true(selected.is_empty(), "blocked player is excluded before selection")
	var descriptor := planner.get_last_selection_descriptor()
	assert_eq(descriptor.suppressed_count, 1, "player contributes to suppression counts")
	assert_eq(
		descriptor.suppressed_by_reason.get("recently_harmed_by_candidate", 0),
		1,
		"diagnostics identify harm without exposing an actor name"
	)


func test_identity_free_social_partner_remains_live_only_and_is_not_remembered() -> void:
	var fixture := _full_npc_fixture(&"child")
	var legacy_partner := Node2D.new()
	legacy_partner.name = "LegacyPartner"
	legacy_partner.add_to_group("npc")
	add_child_autofree(legacy_partner)
	var memory_count_before: int = fixture.memory.get_recent_memories().size()
	assert_false(
		String(fixture.machine.call(
			"_get_social_candidate_id",
			legacy_partner
		)).is_empty(),
		"identity-free legacy NPCs retain a transient live handshake ID"
	)
	var memory_decision: Dictionary = fixture.machine.call(
		"get_autonomous_social_memory_decision",
		legacy_partner
	)
	assert_true(bool(memory_decision.allowed), "missing stable identity does not block live Talk")
	assert_eq(memory_decision.candidate_id, &"", "transient IDs are excluded from memory queries")
	var completed: Dictionary = fixture.observer.observe_conversation_completed(
		legacy_partner,
		{"session_id": "social:legacy:completed", "source": "social_ai"}
	)
	assert_false(bool(completed.accepted), "transient partner identity is not persisted")
	assert_eq(completed.reason, "invalid_partner_identity", "memory rejection is explicit")
	var refused: Dictionary = fixture.observer.observe_conversation_refused(
		legacy_partner,
		"social:legacy:refused",
		&"declined",
		&"social_ai",
		{"decision_kind": "social_decline"}
	)
	assert_false(bool(refused.accepted), "transient refusal identity is not persisted")
	assert_eq(
		fixture.memory.get_recent_memories().size(),
		memory_count_before,
		"identity-free social events leave episodic memory unchanged"
	)


func test_world_retry_descriptor_never_bypasses_candidate_rediscovery() -> void:
	var fixture := _full_npc_fixture(&"child")
	fixture.machine.active = true
	var memory := fixture.memory as NpcShortTermMemory
	_remember(
		memory,
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		&"mom",
		10.0
	)
	var locations := add_child_autofree(LocalLocations.new()) as LocalLocations
	locations.live_npcs["child"] = fixture.npc
	var seeker := _record()
	var records := {
		"child": seeker,
		"mom": _record(),
	}
	var world := add_child_autofree(WorldSimulation.new()) as Node
	var planner: NpcSocialPlanner = world.get("_social_planner")
	planner.begin_simulation_pass()
	assert_false(
		bool(world.call(
			"_try_start_social_seek",
			&"child",
			seeker,
			records,
			locations,
			-1
		)),
		"the refusing-only pool is all-suppressed"
	)
	var first_descriptor: Dictionary = world.call(
		"get_social_selection_debug_descriptor",
		&"child"
	)
	assert_true(
		bool(first_descriptor.all_candidates_suppressed),
		"the first pass publishes its retry descriptor"
	)

	var removed_records := {"child": seeker}
	assert_false(
		bool(world.call(
			"_try_start_social_seek",
			&"child",
			seeker,
			removed_records,
			locations,
			-1
		)),
		"removing the old partner still produces no session"
	)
	var removed_descriptor: Dictionary = world.call(
		"get_social_selection_debug_descriptor",
		&"child"
	)
	assert_eq(
		removed_descriptor.get("candidates_considered", -1),
		0,
		"removed partner is absent from the newly enumerated pool"
	)
	assert_false(
		bool(removed_descriptor.get("all_candidates_suppressed", false)),
		"an obsolete retry descriptor is not reused"
	)

	var changed_records := {
		"child": seeker,
		"mom": _record(),
		"dad": _record(),
	}
	assert_false(
		bool(world.call(
			"_try_start_social_seek",
			&"child",
			seeker,
			changed_records,
			locations,
			-1
		)),
		"the synthetic fixture has no live Dad to execute the selected request"
	)
	var changed_descriptor: Dictionary = world.call(
		"get_social_selection_debug_descriptor",
		&"child"
	)
	assert_eq(
		changed_descriptor.selected_candidate_id,
		"dad",
		"a newly available alternative is discovered before Mom's retry"
	)
	assert_eq(
		int(changed_descriptor.suppressed_by_refusal_count),
		1,
		"the refusal policy still blocks only Mom"
	)
	assert_null(
		fixture.machine.active_action,
		"candidate checking creates no live action session"
	)
	var participant_reservations: Dictionary = planner.get(
		"_participant_reservations"
	)
	assert_true(
		participant_reservations.is_empty(),
		"the rejected synthetic execution leaves no social reservation"
	)


func _memory() -> NpcShortTermMemory:
	var memory := NpcShortTermMemory.new()
	add_child_autofree(memory)
	return memory


func _remember(
	memory: NpcShortTermMemory,
	event_type: StringName,
	subject_id: StringName,
	now_game_hours: float,
	extra: Dictionary = {}
) -> Dictionary:
	var context := {
		"subject_id": subject_id,
		"target_id": "child",
		"logical_action": "Talk",
	}
	context.merge(extra, true)
	return memory.remember(MemoryEvent.create(event_type, context, now_game_hours))


func _memory_snapshot(memory: NpcShortTermMemory) -> Array:
	var snapshot: Array = []
	for event in memory.get_recent_memories():
		snapshot.append(event.to_dict())
	return snapshot


func _record() -> Dictionary:
	return {
		"scene_path": "res://town.tscn",
		"previous_scene_path": "",
		"pending_travel": {},
		"activity": {},
		"social_visit_target_id": "",
		"social_session_id": "",
		"node_state": {
			"relationship_id": "",
			"social_stats": {
				"disabled": 0.0,
				"hp": 100.0,
				"knockout": 0.0,
				"talk_need": 90.0,
			},
		},
	}


func _settings() -> Dictionary:
	return {
		"priority": 60,
		"minimum_npc_favor": 10.0,
	}


func _full_npc_fixture(npc_id: StringName) -> Dictionary:
	var npc := TestNpc.new(npc_id)
	npc.name = String(npc_id)
	npc.add_to_group("npc")
	var label := Label.new()
	label.name = "StateLabel"
	npc.add_child(label)
	var machine := MemoryScene.instantiate() as NpcStateMachine
	machine.active = false
	machine.debug_label_path = NodePath("StateLabel")
	npc.add_child(machine)
	add_child_autofree(npc)
	machine.bind_npc(npc)
	machine.state_history = [machine.get_state(&"Idle")]
	machine.current_state.enter()
	return {
		"npc": npc,
		"machine": machine,
		"controller": machine.behavior_controller,
		"memory": machine.short_term_memory,
		"observer": machine.memory_observer,
		"label": label,
	}
