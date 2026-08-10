extends "res://test/native_scene_tree_test.gd"

const Identity = preload("res://scripts/systems/npc_identity.gd")
const ActivityIdentity = preload(
	"res://scripts/systems/npc_activity_identity.gd"
)
const ActionSession = preload("res://scripts/systems/npc_action_session.gd")
const InteractionMemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_player_interaction_memory_policy.gd"
)
const RelationshipsScript = preload(
	"res://scripts/systems/relationships.gd"
)
const SocialPlanner = preload("res://scripts/systems/npc_social_planner.gd")
const LocationsScript = preload("res://scripts/systems/npc_locations.gd")


class StableActor:
	extends Node2D

	var location_id: StringName
	var relationship_id: StringName

	func _init(
		new_location_id: StringName,
		new_relationship_id: StringName
	) -> void:
		location_id = new_location_id
		relationship_id = new_relationship_id

	func get_npc_location_id() -> StringName:
		return location_id

	func get_relationship_id() -> StringName:
		return relationship_id


class LegacyActor:
	extends Node

	var legacy_id: String

	func _init(new_legacy_id: String) -> void:
		legacy_id = new_legacy_id

	func get_relationship_id() -> String:
		return legacy_id


class CombinedSpot:
	extends Node2D

	var spot_id: StringName = &"work_spot"
	var eat_world_definition: Dictionary = {"spot_id": "food_spot"}

	func get_world_spot_id() -> StringName:
		return spot_id


func test_player_identity_is_canonical_across_all_public_resolvers() -> void:
	var player := Node2D.new()
	player.name = "Player"
	player.add_to_group("player")
	player.set_meta("relationship_id", "scene_specific_player")
	add_child_autofree(player)
	var relationships := _relationships()

	assert_eq(
		Identity.get_stable_actor_id(player),
		"__player__",
		"player group overrides scene-specific identity"
	)
	assert_eq(
		ActivityIdentity.get_persistent_npc_id(player),
		"__player__",
		"activity descriptors use the canonical player identity"
	)
	assert_eq(
		ActionSession.get_persistent_id(player),
		"__player__",
		"action sessions use the canonical player identity"
	)
	assert_eq(
		InteractionMemoryPolicy.get_stable_actor_id(player),
		&"__player__",
		"memory uses the canonical player identity"
	)
	assert_eq(
		relationships.get_relationship_id(player),
		"__player__",
		"relationships use the canonical player identity"
	)
	var aliases := Identity.get_actor_aliases(player)
	assert_true(
		aliases.has("scene_specific_player"),
		"scene-specific player identity remains available as a migration alias"
	)
	assert_true(
		aliases.has(String(player.get_path())),
		"the current player path remains available as a migration alias"
	)
	assert_false(
		aliases.has("__player__"),
		"canonical identity is never returned as its own alias"
	)


func test_authored_actor_and_spot_ids_share_one_resolution_contract() -> void:
	var actor := StableActor.new(&"npc_location", &"old_relationship_alias")
	add_child_autofree(actor)
	var spot := CombinedSpot.new()
	add_child_autofree(spot)
	var relationships := _relationships()
	var locations := add_child_autofree(LocationsScript.new())

	assert_eq(
		Identity.get_stable_actor_id(actor),
		"npc_location",
		"world location identity is the canonical authored NPC identity"
	)
	assert_eq(
		ActivityIdentity.get_persistent_npc_id(actor),
		"npc_location",
		"activity NPC identity delegates to the shared resolver"
	)
	assert_eq(
		ActionSession.get_persistent_id(actor),
		"npc_location",
		"action target identity delegates to the shared resolver"
	)
	assert_eq(
		locations.get_npc_id(actor),
		"npc_location",
		"world location records delegate to the shared resolver"
	)
	var actor_aliases := Identity.get_actor_aliases(actor)
	assert_true(
		actor_aliases.has("old_relationship_alias"),
		"an older authored relationship ID remains a migration alias"
	)
	assert_false(
		actor_aliases.has("npc_location"),
		"the canonical NPC ID is omitted from aliases"
	)
	relationships.apply_save_data({"relationships": {
		"other_npc": {
			"old_relationship_alias": {
				"favor": 63.0,
				"updated_at_msec": 3,
			},
		},
	}})
	assert_eq(
		relationships.get_relationship_id(actor),
		"npc_location",
		"relationships adopt the canonical authored NPC identity"
	)
	assert_true(
		relationships.has_relationship_by_id(
			"other_npc", "old_relationship_alias"
		),
		"ordinary identity lookup does not migrate a legacy row"
	)
	assert_eq(
		relationships.register_actor_identity(actor),
		"npc_location",
		"cold actor registration resolves the same canonical identity"
	)
	assert_eq(
		float(relationships.get_relationship_by_id(
			"other_npc",
			"npc_location"
		).favor),
		63.0,
		"older authored relationship IDs migrate when the live NPC resolves"
	)
	assert_eq(
		ActivityIdentity.get_persistent_spot_id(spot, &"Work"),
		"work_spot",
		"regular spot identity remains unchanged"
	)
	assert_eq(
		ActivityIdentity.get_persistent_spot_id(spot, &"Eat"),
		"food_spot",
		"combined spot Eat override remains unchanged"
	)


func test_generated_and_path_shaped_ids_are_not_save_stable() -> void:
	assert_false(
		Identity.is_stable_id("/root/Town/Npc"),
		"absolute node paths are transient"
	)
	assert_false(
		Identity.is_stable_id("root\\Town\\Npc"),
		"backslash paths are transient"
	)
	assert_false(
		Identity.is_stable_id("@Node2D@12345"),
		"Godot generated node names are transient"
	)
	assert_false(
		Identity.is_stable_id("npc:12345"),
		"generated NPC instance aliases are transient"
	)
	assert_true(
		Identity.is_stable_id("mom"),
		"authored stable IDs remain valid"
	)


func test_legacy_nonpersistent_relationship_fallbacks_remain_available() -> void:
	var path_actor := Node.new()
	path_actor.name = "UnidentifiedNpc"
	add_child_autofree(path_actor)
	var relationships := _relationships()
	assert_eq(
		relationships.get_relationship_id(path_actor),
		String(path_actor.get_path()),
		"unidentified live actors retain their scene-path relationship key"
	)
	assert_eq(
		ActionSession.get_persistent_id(path_actor),
		String(path_actor.get_path()),
		"live exact-target action fallback remains scene-path compatible"
	)

	var legacy_actor := LegacyActor.new("npc:123456")
	assert_eq(
		Identity.get_actor_id(legacy_actor, true),
		"npc:123456",
		"an actor's existing transient method identity remains authoritative"
	)
	assert_eq(
		relationships.get_relationship_id(legacy_actor),
		"npc:123456",
		"relationships preserve custom legacy fallbacks"
	)
	legacy_actor.free()


func test_location_records_adopt_exact_aliases_and_scrub_save_only_ids() -> void:
	var locations := add_child_autofree(LocationsScript.new())
	var actor := StableActor.new(&"npc_location", &"old_relationship_alias")
	actor.name = "CanonicalNpc"
	# Registration queues an autoload handoff; keep this lightweight actor alive
	# until the test process exits so that deferred validation is meaningful.
	root.add_child(actor)
	locations.apply_save_data({"records": {
		"npc_location": {
			"npc_id": "npc_location",
			"node_name": "CanonicalNpc",
			"scene_path": "",
			"node_state": {"location_id": "npc_location"},
			"legacy_marker": "older_canonical",
			"last_simulated_total_hours": 5.0,
		},
		"old_relationship_alias": {
			"npc_id": "old_relationship_alias",
			"node_name": "CanonicalNpc",
			"scene_path": "",
			"node_state": {
				"location_id": "old_relationship_alias",
				"relationship_id": "old_relationship_alias",
			},
			"action": {
				"session_id": "legacy-action",
				"action_kind": "Talk",
				"source": "social_ai",
				"status": "active",
				"target_persistent_id": "/root/OldScene/Partner",
			},
			"legacy_marker": "preserved",
			"last_simulated_total_hours": 12.0,
		},
		"/root/OldScene/UnresolvedNpc": {
			"npc_id": "/root/OldScene/UnresolvedNpc",
			"scene_path": "",
		},
		"pending_owner": {
			"npc_id": "pending_owner",
			"scene_path": "",
			"node_state": {},
			"action": {
				"session_id": "unsafe-pending",
				"action_kind": "Talk",
				"target_persistent_id": "/root/OldScene/Partner",
			},
			"pending_travel": {
				"action_session_id": "unsafe-pending",
				"activity": {
					"session_id": "unsafe-pending",
					"state_name": "Talk",
					"target_npc_id": "/root/OldScene/Partner",
				},
			},
		},
	}})

	assert_true(locations.register_npc(actor), "canonical actor registers")
	assert_false(
		locations.npc_records.has("old_relationship_alias"),
		"the exact legacy alias record is removed"
	)
	var adopted: Dictionary = locations.call(
		"get_record_snapshot",
		"npc_location"
	)
	assert_eq(
		String(adopted.get("legacy_marker", "")),
		"preserved",
		"saved state follows the actor onto its canonical record key"
	)

	var save_data: Dictionary = locations.call("get_save_data")
	var saved_records: Dictionary = save_data.get("records", {})
	assert_true(saved_records.has("npc_location"), "canonical record is saved")
	assert_false(
		saved_records.has("/root/OldScene/UnresolvedNpc"),
		"an unresolved transient owner record is not written back"
	)
	var saved_action: Dictionary = saved_records.npc_location.get("action", {})
	assert_true(
		saved_action.is_empty(),
		"a target-dependent action with a transient target is not restored"
	)
	assert_true(
		(saved_records.pending_owner.get("action", {}) as Dictionary).is_empty(),
		"unsafe offscreen actions are omitted as complete descriptors"
	)
	assert_true(
		(
			saved_records.pending_owner.get("pending_travel", {})
			as Dictionary
		).is_empty(),
		"the matching unsafe pending handoff cannot regenerate the action"
	)
	locations.get_save_data()
	assert_eq(
		locations._last_omitted_unstable_save_signature,
		"/root/OldScene/UnresolvedNpc",
		"repeat saves retain one stable warning signature"
	)


func test_rejected_registration_does_not_commit_alias_adoption() -> void:
	var locations := add_child_autofree(LocationsScript.new())
	var actor := StableActor.new(&"canonical_rejected", &"rejected_alias")
	actor.name = "RejectedNpc"
	add_child_autofree(actor)
	locations.apply_save_data({"records": {
		"rejected_alias": {
			"npc_id": "rejected_alias",
			"node_name": "RejectedNpc",
			"scene_path": "res://different_scene.tscn",
			"node_state": {"relationship_id": "rejected_alias"},
			"legacy_marker": "must_remain",
		},
	}})

	assert_false(
		locations.register_npc(actor),
		"scene-mismatched registration is rejected"
	)
	assert_true(
		locations.npc_records.has("rejected_alias"),
		"the alias record remains after a rejected registration"
	)
	assert_false(
		locations.npc_records.has("canonical_rejected"),
		"a rejected registration cannot create the canonical record"
	)


func test_main_authored_social_npcs_have_persistence_safe_ids() -> void:
	var mom_scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var main_scene := load("res://scenes/testscenes/realtest1.tscn") as PackedScene
	assert_not_null(mom_scene, "Mom scene loads")
	assert_not_null(main_scene, "main social scene loads")
	if mom_scene == null or main_scene == null:
		return
	var mom := mom_scene.instantiate()
	var main := main_scene.instantiate()
	var talk_partner := main.get_node_or_null("TalkPartnerNpc")
	assert_eq(
		Identity.get_stable_actor_id(mom),
		"mom",
		"Mom has an authored persistence identity"
	)
	assert_not_null(talk_partner, "main-scene talk partner exists")
	if talk_partner != null:
		assert_eq(
			Identity.get_stable_actor_id(talk_partner),
			"talk_partner_npc",
			"the authored talk partner has a persistence identity"
		)
	mom.free()
	main.free()


func test_offscreen_decay_falls_back_when_canonical_record_key_is_unstable() -> void:
	var relationships := root.get_node_or_null("Relationships")
	var simulation := root.get_node_or_null("NpcWorldSimulation")
	assert_not_null(relationships, "Relationships autoload is available")
	assert_not_null(simulation, "NpcWorldSimulation autoload is available")
	if relationships == null or simulation == null:
		return
	relationships.clear_relationships()
	relationships.apply_save_data({"relationships": {
		"legacy_owner": {
			"partner": {"anger": 100.0, "updated_at_msec": 1},
		},
	}})
	simulation.call(
		"_decay_offscreen_relationships",
		{
			"npc_id": "/root/LegacyScene/Npc",
			"node_state": {"relationship_id": "legacy_owner"},
		},
		{
			"anger_decay": {
				"enabled": true,
				"full_decay_game_hours": 4.0,
			},
		},
		1.0,
		&"/root/LegacyScene/Npc"
	)
	assert_eq(
		float(relationships.relationships.legacy_owner.partner.anger),
		75.0,
		"failed alias migration decays the exact legacy relationship owner"
	)
	relationships.clear_relationships()


func test_legacy_player_path_rows_migrate_on_save_load() -> void:
	var relationships := _relationships()
	var old_player_path := "/root/OldHome/Player"
	var old_guard_path := "/root/OldHome/Guard"
	relationships.apply_save_data({"relationships": {
		old_player_path: {
			"mom": {
				"owner_name": "Player",
				"owner_path": old_player_path,
				"other_name": "Mom",
				"favor": 61.0,
				"updated_at_msec": 20,
			},
		},
		"mom": {
			old_player_path: {
				"owner_name": "Mom",
				"other_name": "Player",
				"other_path": old_player_path,
				"favor": 72.0,
				"updated_at_msec": 30,
			},
			old_guard_path: {
				"owner_name": "Mom",
				"other_name": "Guard",
				"other_path": old_guard_path,
				"favor": 44.0,
			},
		},
	}})

	assert_eq(
		float(relationships.get_relationship_by_id("__player__", "mom").favor),
		61.0,
		"legacy player owner path migrates to the canonical key"
	)
	var toward_player: Dictionary = relationships.get_relationship_by_id(
		"mom",
		"__player__"
	)
	assert_eq(
		float(toward_player.favor),
		72.0,
		"legacy player target path migrates to the canonical key"
	)
	assert_eq(
		toward_player.other_id,
		"__player__",
		"embedded relationship identity is normalized with its key"
	)
	assert_true(
		relationships.has_relationship_by_id("mom", old_guard_path),
		"unrelated path-keyed NPC rows are preserved"
	)
	assert_false(
		relationships.relationships.has(old_player_path),
		"migrated outer player path is removed"
	)
	assert_eq(
		int(relationships.get_save_data().version),
		3,
		"new saves identify the canonical directed-opinion schema"
	)


func test_migration_merges_alias_collisions_by_latest_relationship_update() -> void:
	var relationships := _relationships()
	var old_player_path := "/root/Home/Player"
	relationships.apply_save_data({"relationships": {
		"mom": {
			"__player__": {
				"favor": 25.0,
				"updated_at_msec": 10,
			},
			old_player_path: {
				"other_name": "Player",
				"other_path": old_player_path,
				"favor": 85.0,
				"updated_at_msec": 50,
			},
		},
	}})
	assert_eq(
		float(relationships.get_relationship_by_id("mom", "__player__").favor),
		85.0,
		"the newest duplicate row survives canonical migration"
	)
	assert_eq(
		relationships.get_relationships_for_id("mom").size(),
		1,
		"canonical and legacy aliases do not leave duplicate social state"
	)

	# With equal timestamps the already canonical row is authoritative even if
	# it appears after a legacy alias in the input dictionary.
	relationships.apply_save_data({"relationships": {
		"mom": {
			old_player_path: {
				"other_name": "Player",
				"other_path": old_player_path,
				"favor": 15.0,
				"updated_at_msec": 50,
			},
			"__player__": {
				"favor": 91.0,
				"updated_at_msec": 50,
			},
		},
	}})
	assert_eq(
		float(relationships.get_relationship_by_id("mom", "__player__").favor),
		91.0,
		"canonical row wins a migration timestamp tie"
	)


func test_live_actor_alias_migration_handles_metadata_unknown_at_load() -> void:
	var relationships := _relationships()
	var player := Node2D.new()
	player.name = "Player"
	player.add_to_group("player")
	player.set_meta("relationship_id", "scene_player_alias")
	add_child_autofree(player)
	var live_path := String(player.get_path())
	# Minimal old rows have no saved name/path evidence, so the loader leaves
	# them alone until the matching live actor supplies an exact alias.
	relationships.apply_save_data({"relationships": {
		"mom": {
			live_path: {"favor": 67.0, "updated_at_msec": 5},
			"scene_player_alias": {"favor": 76.0, "updated_at_msec": 9},
		},
	}})
	assert_true(
		relationships.has_relationship_by_id("mom", live_path),
		"ambiguous minimal path row remains conservative during load"
	)
	assert_eq(
		relationships.get_relationship_id(player),
		"__player__",
		"live player resolves canonically"
	)
	assert_true(
		relationships.has_relationship_by_id("mom", live_path),
		"ordinary player identity lookup leaves ambiguous aliases untouched"
	)
	assert_eq(
		relationships.register_actor_identity(player),
		"__player__",
		"cold player registration migrates exact live aliases"
	)
	assert_eq(
		float(relationships.get_relationship_by_id("mom", "__player__").favor),
		76.0,
		"live aliases merge into the canonical row using newest state"
	)
	assert_eq(
		relationships.get_relationships_for_id("mom").size(),
		1,
		"path and scene-specific aliases are removed after live migration"
	)


func test_explicit_alias_migration_is_exact_bidirectional_and_conservative() -> void:
	var relationships := _relationships()
	var unrelated_path := "/root/Town/Guard"
	relationships.apply_save_data({"relationships": {
		"old_npc_alias": {
			"partner": {"favor": 64.0, "updated_at_msec": 20},
		},
		"partner": {
			"old_npc_alias": {"favor": 82.0, "updated_at_msec": 40},
			"npc_location": {"favor": 25.0, "updated_at_msec": 10},
			unrelated_path: {"favor": 51.0},
		},
	}})
	var migration: Dictionary = relationships.migrate_relationship_alias(
		"old_npc_alias",
		"npc_location"
	)
	assert_true(bool(migration.accepted), "explicit stable migration is accepted")
	assert_eq(int(migration.migrated_rows), 2, "both directed axes migrate")
	assert_eq(
		float(relationships.get_relationship_by_id(
			"npc_location",
			"partner"
		).favor),
		64.0,
		"relationship rows owned by the alias move to the canonical owner"
	)
	assert_eq(
		float(relationships.get_relationship_by_id(
			"partner",
			"npc_location"
		).favor),
		82.0,
		"newer alias target state wins the canonical collision"
	)
	assert_true(
		relationships.has_relationship_by_id("partner", unrelated_path),
		"unrelated path-keyed rows are untouched"
	)
	assert_false(
		bool(relationships.migrate_relationship_alias(
			"some_alias",
			"/root/UnstableNpc"
		).accepted),
		"an unstable destination cannot become canonical"
	)
	assert_eq(
		String(relationships.migrate_relationship_alias(
			"old_npc_alias",
			"npc_location"
		).reason),
		"already_migrated",
		"repeated planner passes use the cached no-op path"
	)


func test_offscreen_planner_migrates_saved_relationship_aliases_to_record_ids() -> void:
	var relationships := _relationships()
	relationships.apply_save_data({"relationships": {
		"old_owner_alias": {
			"old_target_alias": {"favor": 88.0, "updated_at_msec": 8},
		},
		"old_target_alias": {
			"old_owner_alias": {"favor": 77.0, "updated_at_msec": 7},
		},
	}})
	var planner := SocialPlanner.new()
	var owner_id := String(planner.call(
		"_get_record_relationship_id",
		&"owner_location",
		{"node_state": {"relationship_id": "old_owner_alias"}},
		relationships
	))
	var target_id := String(planner.call(
		"_get_record_relationship_id",
		&"target_location",
		{"node_state": {"relationship_id": "old_target_alias"}},
		relationships
	))
	assert_eq(owner_id, "owner_location", "record key is the canonical owner ID")
	assert_eq(target_id, "target_location", "record key is the canonical target ID")
	assert_eq(
		float(relationships.get_relationship_by_id(
			owner_id,
			target_id
		).favor),
		88.0,
		"offline directed favor follows both migrated record identities"
	)
	assert_eq(
		float(relationships.get_relationship_by_id(
			target_id,
			owner_id
		).favor),
		77.0,
		"reverse directed favor follows both migrated record identities"
	)


func _relationships() -> Node:
	return add_child_autofree(RelationshipsScript.new())
