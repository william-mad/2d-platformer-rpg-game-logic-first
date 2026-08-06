extends "res://test/native_scene_tree_test.gd"

const MemoryEvent = preload(
	"res://scripts/systems/npc_behavior/npc_memory_event.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const InteractionPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_player_interaction_memory_policy.gd"
)

var _previous_total_hours: float = 0.0
var _previous_auto_advance: bool = false
var _original_relationships: Dictionary = {}
var _tracked_npc_ids: Array[String] = []


func before_each() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		_previous_total_hours = world_time.get_total_hours()
		_previous_auto_advance = world_time.auto_advance
		world_time.auto_advance = false
		world_time.set_total_hours(10.0)
	var relationships := root.get_node_or_null("Relationships")
	if relationships != null:
		_original_relationships = relationships.call("get_save_data")
		relationships.call("clear_relationships")
	_tracked_npc_ids.clear()


func after_each() -> void:
	var repository := root.get_node_or_null("NpcMemoryRuntimeRepository")
	if repository != null:
		for npc_id in _tracked_npc_ids:
			repository.call("clear_npc_memory", npc_id, &"test_cleanup")
	var relationships := root.get_node_or_null("Relationships")
	if relationships != null:
		relationships.call("apply_save_data", _original_relationships)
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	if world_time != null:
		world_time.auto_advance = _previous_auto_advance
		world_time.set_total_hours(_previous_total_hours)


func test_authoritative_player_and_npc_damage_create_actor_directed_memory() -> void:
	var fixture := _combat_fixture("harm_damage_roles")
	var npc: SocialNpc = fixture.npc
	var memory: NpcShortTermMemory = fixture.memory
	var player := _actor("HarmPlayer", &"harm_player", &"player")
	npc.take_damage(1.0, player.global_position, player)
	var player_memories := memory.find_recent_at(
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		10.0,
		&"__player__",
		&"harm_damage_roles",
		&"Harm"
	)
	assert_eq(player_memories.size(), 1, "actual player damage creates one harm memory")
	if not player_memories.is_empty():
		var harm := player_memories[0]
		assert_eq(harm.subject_id, &"__player__", "player memory uses canonical identity")
		assert_eq(harm.target_id, &"harm_damage_roles", "memory target is harmed NPC")
		assert_eq(harm.logical_action, &"Harm", "harm uses the canonical action role")
		assert_eq(harm.metadata.damage_amount, 1.0, "actual damage amount is copied")
		assert_eq(harm.metadata.attacker_kind, &"player", "player kind is structured")
		assert_eq(harm.metadata.remaining_hp, 99.0, "remaining HP is copied")
		assert_false(bool(harm.metadata.caused_death), "minor damage is nonlethal")
		assert_false(_contains_object(harm.metadata), "metadata contains no objects")

	var npc_attacker := _actor("HarmNpc", &"harm_npc_attacker", &"npc")
	npc.take_damage(1.0, npc_attacker.global_position, npc_attacker)
	var npc_memories := memory.find_recent_at(
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		10.0,
		&"harm_npc_attacker",
		&"harm_damage_roles",
		&"Harm"
	)
	assert_eq(npc_memories.size(), 1, "actual NPC damage creates directed memory")
	if not npc_memories.is_empty():
		assert_eq(
			npc_memories[0].metadata.attacker_kind,
			&"npc",
			"NPC attacker kind is structured"
		)

	var npc_only_fixture := _combat_fixture("harm_npc_only_scope")
	var npc_only_attacker := _actor(
		"NpcOnlyAttacker",
		&"npc_only_attacker",
		&"npc"
	)
	var unharmed_player := _actor(
		"UnharmedPlayer",
		&"unharmed_player",
		&"player"
	)
	npc_only_fixture.npc.take_damage(
		1.0,
		npc_only_attacker.global_position,
		npc_only_attacker
	)
	if not npc_only_fixture.machine.is_primary_state(&"Idle"):
		npc_only_fixture.machine.request_state(
			&"Idle",
			null,
			"test_reaction_complete",
			1000
		)
	assert_true(
		bool(npc_only_fixture.machine.can_begin_player_interaction(
			unharmed_player
		).accepted),
		"harm by another NPC does not block player interaction"
	)


func test_rejected_damage_sources_do_not_create_false_memory() -> void:
	var fixture := _combat_fixture("harm_damage_rejections")
	var npc: SocialNpc = fixture.npc
	var machine: NpcStateMachine = fixture.machine
	var memory: NpcShortTermMemory = fixture.memory
	var player := _actor("ZeroPlayer", &"zero_player", &"player")
	npc.take_damage(0.0, player.global_position, player)
	npc.take_damage(1.0, Vector2.ZERO, null)
	var monster := _actor("HarmMonster", &"harm_monster", &"monster")
	npc.take_damage(1.0, monster.global_position, monster)
	npc.take_damage(1.0, npc.global_position, npc)
	assert_true(memory.get_recent_memories().is_empty(), "unsupported damage stays silent")
	machine.request_state(&"Idle", null, "test_reaction_complete", 1000)
	assert_true(
		bool(machine.can_begin_player_interaction(player).accepted),
		"excluded damage cannot create false player-directed refusal"
	)

	machine.set_value(&"hp", 0.0, null, false)
	npc.take_damage(5.0, player.global_position, player)
	assert_true(
		memory.get_recent_memories().is_empty(),
		"positive attempted damage with no HP loss creates no memory"
	)


func test_damage_binding_is_idempotent_and_real_hits_merge_once_each() -> void:
	var fixture := _combat_fixture("harm_damage_dedupe")
	var npc: SocialNpc = fixture.npc
	var machine: NpcStateMachine = fixture.machine
	var memory: NpcShortTermMemory = fixture.memory
	var observer: NpcMemoryObserver = fixture.observer
	var player := _actor("DedupePlayer", &"dedupe_player", &"player")
	observer.bind(machine, memory)
	observer.bind(machine, memory)
	npc.take_damage(1.0, player.global_position, player)
	var harms := memory.find_recent_at(
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		10.0,
		&"__player__",
		&"harm_damage_dedupe",
		&"Harm"
	)
	assert_eq(harms.size(), 1, "one authoritative hit is observed once")
	assert_eq(harms[0].occurrence_count, 1, "one hit has one occurrence")
	npc.take_damage(1.0, player.global_position, player)
	harms = memory.find_recent_at(
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		10.0,
		&"__player__",
		&"harm_damage_dedupe",
		&"Harm"
	)
	assert_eq(harms.size(), 1, "successive real hits merge semantically")
	assert_eq(harms[0].occurrence_count, 2, "two real hits count as two occurrences")


func test_interaction_policy_is_actor_specific_shorter_and_read_only() -> void:
	var memory := NpcShortTermMemory.new()
	add_child_autofree(memory)
	var policy := InteractionPolicy.new()
	var default_player := CharacterBody2D.new()
	default_player.add_to_group("player")
	add_child_autofree(default_player)
	assert_eq(
		InteractionPolicy.get_stable_actor_id(default_player),
		&"__player__",
		"the live player has a stable canonical fallback identity"
	)
	var no_harm := policy.evaluate_actor(
		memory,
		&"player_one",
		10.0,
		{"remembering_npc_id": "policy_npc"}
	)
	assert_true(bool(no_harm.allowed), "no harm memory allows interaction")
	memory.remember(_harm_event(
		"policy_harm",
		10.0,
		&"player_one",
		&"policy_npc"
	))
	var before := memory.export_snapshot(10.0)
	var blocked := policy.evaluate_actor(
		memory,
		&"player_one",
		10.2,
		{"remembering_npc_id": "policy_npc"}
	)
	assert_false(bool(blocked.allowed), "recent matching player harm blocks")
	assert_eq(blocked.reason_code, &"recently_harmed_by_actor", "reason is stable")
	assert_eq(blocked.memory_id, "policy_harm", "decision exposes copied memory ID")
	assert_true(
		is_equal_approx(float(blocked.remaining_retry_hours), 0.3),
		"interaction delay is half a game hour from last harm"
	)
	assert_true(bool(policy.evaluate_actor(
		memory,
		&"player_two",
		10.2,
		{"remembering_npc_id": "policy_npc"}
	).allowed), "another player identity remains allowed")
	assert_eq(
		memory.export_snapshot(10.0),
		before,
		"policy evaluation does not mutate memory"
	)
	var after_delay := policy.evaluate_actor(
		memory,
		&"player_one",
		10.51,
		{"remembering_npc_id": "policy_npc"}
	)
	assert_true(bool(after_delay.allowed), "short behavioural delay expires")
	assert_eq(
		memory.find_recent_at(
			MemoryPolicy.EVENT_HARMED_BY_ACTOR,
			10.51,
			&"player_one"
		).size(),
		1,
		"longer episodic memory remains stored after interaction returns"
	)


func test_resolved_expired_and_repeated_harm_policy_boundaries() -> void:
	var memory := NpcShortTermMemory.new()
	add_child_autofree(memory)
	var policy := InteractionPolicy.new()
	memory.remember(_harm_event("repeat_harm", 10.0, &"player", &"policy_npc"))
	memory.remember(_harm_event("repeat_harm_2", 10.1, &"player", &"policy_npc"))
	var repeated := policy.evaluate_actor(
		memory,
		&"player",
		10.55,
		{"remembering_npc_id": "policy_npc"}
	)
	assert_false(bool(repeated.allowed), "merged repeat refreshes refusal from last update")
	assert_eq(repeated.occurrence_count, 2, "repeat decision reports occurrence count")
	assert_true(memory.resolve_memory("repeat_harm", &"test"), "memory resolves")
	assert_true(bool(policy.evaluate_actor(
		memory,
		&"player",
		10.55,
		{"remembering_npc_id": "policy_npc"}
	).allowed), "resolved harm does not block")

	var expired_memory := NpcShortTermMemory.new()
	add_child_autofree(expired_memory)
	expired_memory.remember(_harm_event(
		"expired_harm",
		8.0,
		&"player",
		&"policy_npc"
	))
	assert_true(bool(policy.evaluate_actor(
		expired_memory,
		&"player",
		10.1,
		{"remembering_npc_id": "policy_npc"}
	).allowed), "expired harm does not block")


func test_state_machine_gate_preserves_precedence_and_cooldown_independence() -> void:
	var fixture := _combat_fixture("harm_interaction_gate")
	var npc: SocialNpc = fixture.npc
	var machine: NpcStateMachine = fixture.machine
	var memory: NpcShortTermMemory = fixture.memory
	var player := _actor("GatePlayer", &"gate_player", &"player")
	var other_player := _actor("OtherPlayer", &"other_player", &"player")
	npc.take_damage(1.0, player.global_position, player)
	assert_false(machine.is_primary_state(&"Fight"), "minor harm does not request Fight")
	assert_false(machine.is_primary_state(&"Flee"), "minor harm does not request Flee")
	assert_eq(
		machine.can_begin_player_interaction(player).reason,
		"npc_emergency_reaction",
		"existing immediate reaction retains precedence"
	)
	machine.request_state(&"Idle", null, "test_reaction_complete", 1000)
	var gate := machine.can_begin_player_interaction(player)
	assert_false(bool(gate.accepted), "matching player is temporarily refused")
	assert_eq(gate.reason, "npc_recently_harmed_by_player", "gate reason is stable")
	assert_false(
		bool(machine.can_begin_player_interaction(other_player).accepted),
		"all live representations of the canonical player share the harm gate"
	)

	machine.start_player_interaction_cooldown(player, 7.0)
	var cooldown_before := machine.player_interaction_cooldown_timer
	assert_eq(
		machine.can_begin_player_interaction(player).reason,
		"npc_ignoring_player",
		"existing real-time cooldown retains precedence"
	)
	assert_eq(
		machine.player_interaction_cooldown_timer,
		cooldown_before,
		"memory polling does not start or extend real-time cooldown"
	)
	machine.player_interaction_cooldown_timer = 0.0
	machine.player_interaction_cooldown_actor = null
	machine.scripted_control_claim_token = 1
	assert_eq(
		machine.can_begin_player_interaction(player).reason,
		"npc_scripted_controlled",
		"scripted ownership retains precedence over harm memory"
	)
	machine.scripted_control_claim_token = 0
	machine.set_value(&"hp", 0.0, null, false)
	assert_eq(
		machine.can_begin_player_interaction(player).reason,
		"npc_dead",
		"death retains precedence over harm memory"
	)
	assert_eq(memory.get_recent_memories().size(), 1, "hard gates do not mutate harm memory")


func test_existing_fight_and_flee_thresholds_remain_authoritative() -> void:
	var fight_fixture := _combat_fixture("harm_existing_fight")
	var fighter: SocialNpc = fight_fixture.npc
	var fight_machine: NpcStateMachine = fight_fixture.machine
	var player := _actor("FightPlayer", &"fight_player", &"player")
	fighter.take_damage(25.0, player.global_position, player)
	assert_true(fight_machine.is_primary_state(&"Fight"), "severe anger still starts Fight")
	assert_eq(
		fight_machine.can_begin_player_interaction(player).reason,
		"npc_fighting",
		"Fight hard block precedes harm-memory refusal"
	)

	var flee_fixture := _combat_fixture("harm_existing_flee")
	var fleeing_npc: SocialNpc = flee_fixture.npc
	var flee_machine: NpcStateMachine = flee_fixture.machine
	var feared_player := _actor("FearedPlayer", &"feared_player", &"player")
	flee_machine.set_value(&"hp", 49.0, feared_player, false)
	fleeing_npc.change_relationship_fear_for(
		feared_player,
		100.0,
		"test_setup"
	)
	fleeing_npc.take_damage(1.0, feared_player.global_position, feared_player)
	assert_true(flee_machine.is_primary_state(&"Flee"), "existing directed fear still starts Flee")
	assert_eq(
		flee_machine.can_begin_player_interaction(feared_player).reason,
		"npc_fleeing",
		"Flee hard block precedes harm-memory refusal"
	)


func test_runtime_replacement_preserves_policy_without_replaying_feedback() -> void:
	var world_time := root.get_node_or_null("WorldTime") as WorldTimeSystem
	var first := _combat_fixture("harm_runtime_continuity")
	var player := _actor("ContinuityPlayer", &"continuity_player", &"player")
	first.npc.take_damage(1.0, player.global_position, player)
	var old_memory: NpcShortTermMemory = first.memory
	root.remove_child(first.npc)

	if world_time != null:
		world_time.set_total_hours(10.1)
	var replacement := _combat_fixture("harm_runtime_continuity")
	assert_eq(
		replacement.memory.find_recent_at(
			MemoryPolicy.EVENT_HARMED_BY_ACTOR,
			10.1,
			&"__player__"
		).size(),
		1,
		"scene replacement restores valid harm memory"
	)
	assert_eq(
		replacement.machine.can_begin_player_interaction(player).reason,
		"npc_recently_harmed_by_player",
		"matching player remains blocked after replacement"
	)
	assert_true(
		replacement.presenter.get_current_cue_descriptor().is_empty(),
		"snapshot restoration emits no historical harm cue"
	)
	replacement.npc.take_damage(1.0, player.global_position, player)
	assert_eq(
		old_memory.get_recent_memories().size(),
		1,
		"old observer cannot process replacement damage"
	)

	# The second real hit merges into the restored memory at 10.1. Its refusal
	# ends at 10.6 while the refreshed episodic record remains until 11.1.
	if world_time != null:
		world_time.set_total_hours(10.61)
	replacement.machine.request_state(
		&"Idle",
		null,
		"test_reaction_complete",
		1000
	)
	assert_true(
		bool(replacement.machine.can_begin_player_interaction(player).accepted),
		"interaction delay expires after replacement"
	)
	assert_false(
		replacement.memory.get_recent_memories().is_empty(),
		"harm memory still exists after behavioural delay"
	)
	root.remove_child(replacement.npc)
	if world_time != null:
		world_time.set_total_hours(11.11)
	var after_expiry := _combat_fixture("harm_runtime_continuity")
	assert_true(
		after_expiry.memory.get_recent_memories().is_empty(),
		"expired harm memory is not restored"
	)
	after_expiry.npc.take_damage(1.0, player.global_position, player)
	assert_eq(
		after_expiry.presenter.get_current_cue_descriptor().cue_code,
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		"new harm after restoration displays normally"
	)


func _combat_fixture(npc_id: String) -> Dictionary:
	if not _tracked_npc_ids.has(npc_id):
		_tracked_npc_ids.append(npc_id)
	var packed := load(
		"res://scenes/creatures/npc/stateful_social_npc.tscn"
	) as PackedScene
	assert_not_null(packed, "stateful NPC scene loads")
	if packed == null:
		return {}
	var npc := packed.instantiate() as SocialNpc
	npc.name = npc_id
	npc.relationship_id = StringName(npc_id)
	npc.location_id = StringName(npc_id)
	npc.use_npc_location_tracking = false
	npc.listen_to_event_bus = false
	npc.show_name_tag = false
	add_child_autofree(npc)
	var machine := npc.get_node_or_null("NpcStateMachine") as NpcStateMachine
	assert_not_null(machine, "stateful NPC has state machine")
	return {
		"npc": npc,
		"machine": machine,
		"memory": machine.short_term_memory if machine != null else null,
		"observer": machine.memory_observer if machine != null else null,
		"presenter": machine.feedback_presenter if machine != null else null,
	}


func _actor(
	actor_name: String,
	actor_id: StringName,
	group_name: StringName
) -> CharacterBody2D:
	var actor := CharacterBody2D.new()
	actor.name = actor_name
	actor.set_meta("relationship_id", String(actor_id))
	actor.add_to_group(group_name)
	if group_name == &"player":
		actor.set_collision_layer_value(2, true)
	actor.global_position = Vector2(48.0, 0.0)
	add_child_autofree(actor)
	return actor


func _harm_event(
	memory_id: String,
	now_game_hours: float,
	attacker_id: StringName,
	target_id: StringName
) -> NpcMemoryEvent:
	var event := MemoryEvent.create(
		MemoryPolicy.EVENT_HARMED_BY_ACTOR,
		{
			"source": "damage_event",
			"reason_code": "damage_received",
			"subject_id": attacker_id,
			"target_id": target_id,
			"logical_action": "Harm",
			"metadata": {
				"damage_amount": 1.0,
				"attacker_kind": &"player",
				"remaining_hp": 99.0,
				"caused_death": false,
			},
		},
		now_game_hours
	)
	event.memory_id = memory_id
	return event


func _contains_object(value) -> bool:
	if value is Object:
		return true
	if value is Dictionary:
		for nested in value.values():
			if _contains_object(nested):
				return true
	if value is Array:
		for nested in value:
			if _contains_object(nested):
				return true
	return false
