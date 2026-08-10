extends "res://test/native_scene_tree_test.gd"

const Profile = preload("res://scripts/resources/npc_character_profile.gd")
const StatefulNpcScene = preload(
	"res://scenes/creatures/npc/stateful_social_npc.tscn"
)


class StableNpcAttacker:
	extends CharacterBody2D

	var actor_id: StringName

	func _init(new_actor_id: StringName) -> void:
		actor_id = new_actor_id
		name = String(new_actor_id).to_pascal_case()
		add_to_group("npc")

	func get_npc_location_id() -> StringName:
		return actor_id


class StableStoryActor:
	extends CharacterBody2D

	var actor_id: StringName

	func _init(new_actor_id: StringName) -> void:
		actor_id = new_actor_id
		name = String(new_actor_id).to_pascal_case()

	func get_persistent_actor_id() -> StringName:
		return actor_id


class LessonRoutingMachine:
	extends Node

	var social_events: Array[Dictionary] = []
	var raw_value_write_count: int = 0

	func apply_social_event(
		delta: Dictionary,
		actor: Node2D = null,
		requires_visibility: bool = true,
		reason: String = "social_event",
		context: Dictionary = {}
	) -> bool:
		social_events.append({
			"delta": delta.duplicate(true),
			"actor": actor,
			"requires_visibility": requires_visibility,
			"reason": reason,
			"context": context.duplicate(true),
		})
		return true

	func apply_value_delta(
		_delta: Dictionary,
		_actor: Node2D = null,
		_evaluate_reactions: bool = true
	) -> bool:
		raw_value_write_count += 1
		return true


var _saved_relationships: Dictionary = {}


func before_each() -> void:
	var relationships := _relationships()
	assert_not_null(relationships, "Relationships autoload is available")
	if relationships == null:
		return
	_saved_relationships = relationships.get_save_data()
	relationships.clear_relationships()


func after_each() -> void:
	var relationships := _relationships()
	if relationships != null:
		relationships.apply_save_data(_saved_relationships)


func test_player_talk_writes_trust_toward_player_and_marks_met() -> void:
	var player := _player()
	var interactor := PlayerNpcTalkInteractor.new()
	player.add_child(interactor)
	var npc := _npc(&"routing_talk_npc")
	npc.social_stats["talk_need"] = 50.0
	add_child_autofree(player)
	add_child_autofree(npc)

	var legacy_trust := float(npc.social_stats.get("trust", 0.0))
	interactor.call(
		"_apply_interaction_effects",
		npc,
		{"trust": 5.0, "talk_need": -10.0},
		{},
		&"test_talk"
	)

	var relationship: Dictionary = _relationships().get_relationship(npc, player)
	assert_true(bool(relationship.get("met", false)), "successful talk marks NPC/player met")
	assert_eq(float(relationship.get("trust", -1.0)), 55.0, "trust is NPC toward Player")
	assert_eq(
		float(npc.social_stats.get("trust", -1.0)),
		legacy_trust,
		"directed trust does not leak into the NPC's legacy global value"
	)
	assert_eq(
		float(npc.social_stats.get("talk_need", -1.0)),
		40.0,
		"personal talk need still changes locally"
	)


func test_mixed_local_and_directed_event_keeps_one_transient_reaction_snapshot() -> void:
	var player := _player()
	var npc := _npc(&"routing_mixed_event_npc")
	add_child_autofree(player)
	add_child_autofree(npc)
	npc.npc_state_machine.value_reactions_enabled = false
	var legacy_favor := float(npc.npc_state_machine.values.get("favor", -1.0))
	var starting_hunger := float(npc.npc_state_machine.values.get("hunger", 0.0))

	assert_true(
		npc.apply_social_event(
			{"favor": -7.0, "hunger": 3.0}, player, false
		),
		"mixed event is handled"
	)
	assert_eq(
		float(_relationships().get_relationship(npc, player).get("favor", -1.0)),
		43.0,
		"directed favor is stored only on NPC toward Player"
	)
	assert_eq(
		float(npc.npc_state_machine.values.get("favor", -1.0)),
		legacy_favor,
		"directed favor is absent from machine values"
	)
	assert_eq(
		float(npc.npc_state_machine.values.get("hunger", -1.0)),
		starting_hunger + 3.0,
		"local value is still applied"
	)
	assert_eq(
		float(npc.npc_state_machine.last_changed_values.get("favor", 0.0)),
		-7.0,
		"reaction snapshot exposes the actual directed favor delta"
	)
	assert_eq(
		float(npc.npc_state_machine.last_changed_values.get("hunger", 0.0)),
		3.0,
		"reaction snapshot combines actual local changes in the same pass"
	)


func test_stable_ungrouped_story_actor_receives_directed_opinion() -> void:
	var npc := _npc(&"routing_story_owner_npc")
	var story_actor := StableStoryActor.new(&"routing_story_actor")
	add_child_autofree(npc)
	add_child_autofree(story_actor)
	npc.npc_state_machine.value_reactions_enabled = false
	var legacy_trust := float(npc.social_stats.get("trust", 0.0))
	assert_false(
		story_actor.is_in_group("npc") or story_actor.is_in_group("player"),
		"story actor deliberately has no social group"
	)

	assert_true(
		npc.apply_social_event({"trust": 6.0}, story_actor, false),
		"stable explicit identity is sufficient for directed routing"
	)
	assert_eq(
		float(_relationships().get_opinion_metric(
			npc, story_actor, &"trust"
		)),
		56.0,
		"NPC trust is stored toward the ungrouped story actor"
	)
	assert_eq(
		float(npc.social_stats.get("trust", -1.0)),
		legacy_trust,
		"directed story opinion never leaks into legacy local trust"
	)


func test_transient_non_social_actor_cannot_create_relationship_rows() -> void:
	var npc := _npc(&"routing_stable_owner_npc")
	var transient_slime := CharacterBody2D.new()
	transient_slime.name = "TransientSlime"
	transient_slime.add_to_group("monster")
	add_child_autofree(npc)
	add_child_autofree(transient_slime)
	npc.npc_state_machine.value_reactions_enabled = false
	var legacy_favor := float(npc.social_stats.get("favor", 0.0))
	var legacy_trust := float(npc.social_stats.get("trust", 0.0))
	var starting_hunger := float(npc.social_stats.get("hunger", 0.0))
	var starting_anger := float(npc.social_stats.get("anger", 0.0))

	assert_true(
		npc.apply_social_event({
			"favor": -7.0,
			"trust": -5.0,
			"hunger": 2.0,
			"anger": 3.0,
		}, transient_slime, false),
		"local need/mood values still make the event useful"
	)
	assert_true(
		_relationships().get_relationship(npc, transient_slime).is_empty(),
		"identity-free slime never creates a relationship row"
	)
	assert_true(
		_relationships().get_relationships_for(npc).is_empty(),
		"transient actor is absent from every persisted opinion row"
	)
	assert_eq(npc.get_favor(), legacy_favor, "transient actor cannot receive directed favor")
	assert_eq(
		float(npc.social_stats.get("trust", -1.0)),
		legacy_trust,
		"transient actor cannot receive directed trust"
	)
	assert_eq(
		float(npc.social_stats.get("hunger", -1.0)),
		starting_hunger + 2.0,
		"personal need remains local"
	)
	assert_eq(
		float(npc.social_stats.get("anger", -1.0)),
		starting_anger + 3.0,
		"broad mood remains local"
	)


func test_transient_runtime_relationship_rows_are_filtered_from_saves() -> void:
	var stable_npc := _npc(&"routing_persistent_npc")
	var stable_other := StableNpcAttacker.new(&"routing_persistent_other")
	var transient := CharacterBody2D.new()
	transient.name = "TransientCombatActor"
	transient.add_to_group("monster")
	add_child_autofree(stable_npc)
	add_child_autofree(stable_other)
	add_child_autofree(transient)
	var relationships := _relationships()

	# Keep legacy runtime compatibility: direct callers may still create an
	# exact live-node row for a transient combat actor.
	relationships.set_opinion_metric(
		stable_npc, transient, &"anger", 25.0, "test_transient_runtime"
	)
	relationships.set_opinion_metric(
		transient, stable_npc, &"fear", 30.0, "test_transient_runtime"
	)
	relationships.set_opinion_metric(
		stable_npc, stable_other, &"trust", 75.0, "test_stable_runtime"
	)
	var transient_id := String(relationships.get_relationship_id(transient))
	assert_false(
		NpcIdentity.is_stable_id(transient_id),
		"identity-free runtime actor resolves only to an unstable ID"
	)
	assert_true(
		relationships.has_relationship_by_id(
			String(stable_npc.get_relationship_id()), transient_id
		),
		"legacy direct API keeps the transient row during this runtime"
	)

	var saved_rows: Dictionary = relationships.get_save_data().get(
		"relationships", {}
	)
	assert_false(
		saved_rows.has(transient_id),
		"an unstable relationship owner is never serialized"
	)
	assert_false(
		saved_rows.get(
			String(stable_npc.get_relationship_id()), {}
		).has(transient_id),
		"an unstable relationship subject is never serialized"
	)
	assert_true(
		saved_rows.get(
			String(stable_npc.get_relationship_id()), {}
		).has(String(stable_other.get_npc_location_id())),
		"stable authored relationship rows remain saveable"
	)


func test_absolute_interaction_opinion_sets_only_npc_toward_player() -> void:
	var player := _player()
	var interactor := PlayerNpcTalkInteractor.new()
	player.add_child(interactor)
	var npc := _npc(&"routing_absolute_set_npc")
	add_child_autofree(player)
	add_child_autofree(npc)
	npc.npc_state_machine.value_reactions_enabled = false
	var legacy_trust := float(npc.social_stats.get("trust", 0.0))

	interactor.call(
		"_apply_interaction_effects",
		npc,
		{},
		{"trust": 87.0, "hunger": 33.0, "anger": 41.0},
		&"test_absolute_set"
	)
	var relationship: Dictionary = _relationships().get_relationship(
		npc, player
	)
	assert_eq(
		float(relationship.get("trust", -1.0)),
		87.0,
		"absolute trust sets NPC opinion toward Player"
	)
	assert_eq(
		float(npc.social_stats.get("trust", -1.0)),
		legacy_trust,
		"absolute directed trust never changes legacy local trust"
	)
	assert_eq(
		float(npc.social_stats.get("hunger", -1.0)),
		33.0,
		"absolute personal need keeps the machine set-value path"
	)
	assert_eq(
		float(npc.social_stats.get("anger", -1.0)),
		41.0,
		"ordinary absolute anger remains broad/local"
	)
	assert_eq(
		float(relationship.get("anger", -1.0)),
		0.0,
		"ordinary broad anger does not invent a directed opinion"
	)


func test_directed_only_clamped_choice_confirms_pending_player_talk_payout() -> void:
	var player := _player()
	var npc := _npc(&"routing_prepaid_talk_npc")
	add_child_autofree(player)
	add_child_autofree(npc)
	var machine := npc.npc_state_machine
	machine.value_reactions_enabled = false
	_relationships().set_opinion_metric(
		npc, player, &"trust", 100.0, "test_clamp_setup"
	)
	assert_true(
		machine.request_talk(player, -1, true, &"player"),
		"player Talk session starts"
	)
	assert_true(
		machine.mark_next_talk_need_payout_applied(),
		"skip-payout choice creates a pending marker"
	)

	# Trust is already clamped at 100, so there is no stored delta. The valid
	# directed choice still confirms that the player's interaction effect arrived.
	npc.apply_social_event({"trust": 5.0}, player, false)
	assert_true(
		machine.is_active_talk_payout_prepaid(),
		"directed-only clamped event confirms pending Talk payout"
	)
	assert_eq(
		float(_relationships().get_opinion_metric(npc, player, &"trust")),
		100.0,
		"clamped directed currency remains unchanged"
	)

	var ordinary_npc := _npc(&"routing_ordinary_talk_npc")
	add_child_autofree(ordinary_npc)
	var ordinary_machine := ordinary_npc.npc_state_machine
	ordinary_machine.value_reactions_enabled = false
	_relationships().set_opinion_metric(
		ordinary_npc, player, &"trust", 100.0, "test_ordinary_setup"
	)
	assert_true(
		ordinary_machine.request_talk(player, -1, true, &"player"),
		"ordinary player Talk session starts"
	)
	ordinary_npc.apply_social_event({"trust": 5.0}, player, false)
	assert_false(
		ordinary_machine.is_active_talk_payout_prepaid(),
		"without the skip-payout marker, Talk completion remains ordinary"
	)


func test_player_damage_routes_attacker_opinions_without_global_favor_leak() -> void:
	var player := _player()
	var npc := _npc(&"routing_damage_npc")
	npc.damage_favor_penalty = 1.0
	npc.damage_anger_multiplier = 1.0
	npc.damage_fear_multiplier = 1.0
	npc.damage_fear_health_threshold_percent = 100.0
	add_child_autofree(player)
	add_child_autofree(npc)
	npc.npc_state_machine.value_reactions_enabled = false

	var legacy_favor := npc.get_favor()
	var legacy_anger := float(npc.social_stats.get("anger", 0.0))
	npc.take_damage(10.0, player.global_position, player)
	var relationship: Dictionary = _relationships().get_relationship(npc, player)
	assert_eq(float(relationship.get("favor", -1.0)), 40.0, "damage lowers favor toward attacker once")
	assert_true(float(relationship.get("anger", 0.0)) > 0.0, "damage adds anger toward Player")
	assert_true(float(relationship.get("fear", 0.0)) > 0.0, "low-health damage adds fear toward Player")
	assert_eq(npc.get_favor(), legacy_favor, "player damage does not spend global favor")
	assert_eq(
		float(npc.social_stats.get("anger", -1.0)),
		legacy_anger,
		"player-targeted anger does not leak into broad anger"
	)

	npc.take_damage(5.0, Vector2.ZERO, null)
	assert_eq(npc.get_favor(), legacy_favor, "environment damage does not spend global favor")
	assert_eq(
		float(_relationships().get_relationship(npc, player).get("favor", -1.0)),
		40.0,
		"environment damage does not guess the Player as its subject"
	)

	var npc_attacker := StableNpcAttacker.new(&"routing_npc_attacker")
	add_child_autofree(npc_attacker)
	npc.take_damage(5.0, npc_attacker.global_position, npc_attacker)
	var npc_relationship: Dictionary = _relationships().get_relationship(
		npc, npc_attacker
	)
	assert_eq(
		float(npc_relationship.get("favor", -1.0)),
		45.0,
		"NPC damage lowers favor toward that NPC only"
	)
	assert_true(
		float(npc_relationship.get("anger", 0.0)) > 0.0,
		"NPC damage adds anger toward that NPC"
	)
	assert_true(
		float(npc_relationship.get("fear", 0.0)) > 0.0,
		"NPC damage adds fear toward that NPC"
	)
	assert_eq(
		float(_relationships().get_relationship(npc, player).get("favor", -1.0)),
		40.0,
		"one attacker's damage never changes another actor's opinion row"
	)


func test_one_damage_event_commits_all_attacker_opinions_once() -> void:
	var player := _player()
	var npc := _npc(&"routing_damage_transaction_npc")
	npc.damage_favor_penalty = 1.0
	npc.damage_anger_multiplier = 1.0
	npc.damage_fear_multiplier = 1.0
	npc.damage_fear_health_threshold_percent = 100.0
	add_child_autofree(player)
	add_child_autofree(npc)
	npc.npc_state_machine.value_reactions_enabled = false

	var emitted_changes: Array[Dictionary] = []
	var changed_callback := func(
		relationship_owner: Node,
		other: Node,
		changed_values: Dictionary,
		_relationship: Dictionary
	) -> void:
		if relationship_owner == npc and other == player:
			emitted_changes.append(changed_values.duplicate(true))
	_relationships().relationship_changed.connect(changed_callback)

	npc.take_damage(10.0, player.global_position, player)

	_relationships().relationship_changed.disconnect(changed_callback)
	assert_eq(
		emitted_changes.size(),
		1,
		"one hit is one directed-opinion transaction"
	)
	if emitted_changes.size() != 1:
		return
	var changed_values := emitted_changes[0]
	assert_true(changed_values.has("favor"), "damage transaction contains favor")
	assert_true(changed_values.has("anger"), "damage transaction contains anger")
	assert_true(changed_values.has("fear"), "low-health damage transaction contains fear")


func test_player_hits_reduce_only_directed_anger_for_melee_and_projectiles() -> void:
	var player := _player()
	var npc := _npc(&"routing_hit_relief_npc")
	add_child_autofree(player)
	add_child_autofree(npc)
	npc.npc_state_machine.values["anger"] = 73.0
	npc.social_stats["anger"] = 73.0
	_relationships().set_opinion_metric(
		npc, player, &"anger", 60.0, "test_setup"
	)

	var melee_state := MomNpcFightState.new()
	melee_state.npc = npc
	melee_state.fight_target = player
	melee_state.anger_drop_on_target_hit = 8.0
	add_child_autofree(melee_state)
	melee_state.call("_apply_melee_anger_hit_relief", player)
	assert_eq(
		float(_relationships().get_opinion_metric(npc, player, &"anger")),
		52.0,
		"melee hit calms anger toward the Player"
	)
	assert_eq(
		float(npc.npc_state_machine.values.get("anger", -1.0)),
		73.0,
		"melee hit does not reduce broad anger"
	)

	_relationships().set_opinion_metric(
		npc, player, &"anger", 60.0, "test_reset"
	)
	var projectile := NpcThrownAttack.new()
	projectile.source_npc = npc
	projectile.intended_target = player
	projectile.anger_drop_on_intended_target_hit = 8.0
	add_child_autofree(projectile)
	projectile.call("_apply_anger_hit_relief", player)
	assert_eq(
		float(_relationships().get_opinion_metric(npc, player, &"anger")),
		52.0,
		"projectile hit calms anger toward the Player"
	)
	assert_eq(
		float(npc.npc_state_machine.values.get("anger", -1.0)),
		73.0,
		"projectile hit does not reduce broad anger"
	)


func test_magic_lesson_fallback_uses_directional_social_event_boundary() -> void:
	var player := _player()
	var mom := Node2D.new()
	mom.name = "FallbackMom"
	mom.set_meta("relationship_id", "fallback_mom")
	var machine := LessonRoutingMachine.new()
	machine.name = "NpcStateMachine"
	mom.add_child(machine)
	var lesson := MagicLessonSpot.new()
	lesson.player_reward_meta = &""
	lesson.mom_reward_delta = {"trust": 4.0}
	lesson.active_mom = mom
	lesson.active_player = player
	add_child_autofree(player)
	add_child_autofree(mom)

	lesson.call("_apply_reward_once")
	assert_eq(machine.social_events.size(), 1, "lesson fallback routes one social event")
	assert_eq(machine.raw_value_write_count, 0, "lesson never bypasses opinion routing")
	if not machine.social_events.is_empty():
		var event: Dictionary = machine.social_events[0]
		assert_same(event.get("actor", null), player, "lesson trust is about its Player")
		assert_eq(event.get("reason", ""), "magic_lesson_reward", "lesson keeps a clear reason")
	lesson.free()


func test_favor_bar_and_body_color_show_npc_opinion_of_current_player() -> void:
	var player := _player()
	var npc := _npc(&"routing_presentation_npc")
	npc.social_stats["favor"] = 83.0
	var authored_body := npc.get_node("BodyVisual") as Polygon2D
	var authored_body_color := authored_body.color
	add_child_autofree(player)
	add_child_autofree(npc)

	assert_false(npc.favor_bar.visible, "no met NPC-to-Player row hides the favor bar")
	assert_eq(
		npc.body_visual.color,
		authored_body_color,
		"no player opinion restores the authored neutral body tint"
	)
	assert_null(
		npc.get_player_favor_for_presentation(),
		"legacy story favor is never presented as a Player opinion"
	)
	_relationships().set_opinion_metric(npc, player, &"favor", 15.0, "test")
	assert_true(npc.favor_bar.visible, "a met NPC-to-Player row reveals the favor bar")
	assert_eq(float(npc.favor_bar.value), 15.0, "favor bar reads NPC toward Player")
	assert_eq(
		npc.body_visual.color,
		Color(0.85, 0.18, 0.14, 1.0),
		"low player favor has a clear negative color"
	)
	_relationships().set_opinion_metric(npc, player, &"favor", 82.0, "test")
	assert_eq(float(npc.favor_bar.value), 82.0, "relationship signals refresh the favor bar")
	assert_eq(
		npc.body_visual.color,
		Color(0.25, 0.75, 0.35, 1.0),
		"high player favor has a clear positive color"
	)
	assert_eq(npc.get_favor(), 83.0, "presentation never rewrites legacy story currency")


func test_character_profile_snapshot_is_read_only_and_location_safe() -> void:
	var npc := _npc(&"routing_profile_npc")
	var profile := Profile.new()
	profile.display_name = "Mara"
	profile.subtitle = "Household anchor"
	profile.description = "Keeps the household moving."
	profile.accent_color = Color(0.65, 0.32, 0.46, 1.0)
	npc.character_profile = profile
	add_child_autofree(npc)

	var locations := root.get_node_or_null("NpcLocations")
	assert_not_null(locations, "NpcLocations autoload is available")
	if locations == null:
		return
	var record: Dictionary = locations.call(
		"_build_initial_record",
		"routing_profile_npc",
		npc,
		"res://test_scene.tscn",
		"res://scenes/creatures/npc/stateful_social_npc.tscn"
	)
	var snapshot: Dictionary = record.get("character_profile", {})
	assert_eq(snapshot.get("display_name", ""), "Mara", "location record keeps profile name")
	assert_eq(snapshot.get("subtitle", ""), "Household anchor", "location record keeps role")
	assert_eq(snapshot.get("accent_color", Color.BLACK), profile.accent_color, "location record keeps accent")
	var restored_record: Dictionary = locations.call(
		"_normalize_loaded_record", "routing_profile_npc", record
	)
	assert_eq(
		restored_record.get("character_profile", {}).get("description", ""),
		profile.description,
		"profile snapshot survives the location-record load boundary"
	)
	snapshot["display_name"] = "Mutated"
	assert_eq(
		npc.get_character_profile_snapshot().get("display_name", ""),
		"Mara",
		"callers cannot mutate the authored profile through its snapshot"
	)


func _relationships() -> Node:
	return root.get_node_or_null("Relationships")


func _player() -> CharacterBody2D:
	var player := CharacterBody2D.new()
	player.name = "Player"
	player.add_to_group("player")
	return player


func _npc(actor_id: StringName) -> SocialNpc:
	var npc := StatefulNpcScene.instantiate() as SocialNpc
	npc.name = String(actor_id).to_pascal_case()
	npc.location_id = actor_id
	npc.relationship_id = actor_id
	npc.display_name = npc.name
	npc.use_npc_location_tracking = false
	npc.listen_to_event_bus = false
	return npc
