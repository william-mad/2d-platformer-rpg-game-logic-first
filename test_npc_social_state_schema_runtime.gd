extends "res://test/native_scene_tree_test.gd"

const Schema = preload("res://scripts/systems/npc_social_state_schema.gd")
const RelationshipsScript = preload("res://scripts/systems/relationships.gd")


class StableActor:
	extends Node

	var actor_id: StringName

	func _init(new_actor_id: StringName, actor_name: String) -> void:
		actor_id = new_actor_id
		name = actor_name

	func get_npc_location_id() -> StringName:
		return actor_id


func test_schema_declares_scope_lifecycle_consumers_and_presentation() -> void:
	var definitions := Schema.get_all_definitions()
	for value_id in Schema.VALUE_ORDER:
		assert_true(
			definitions.has(value_id),
			"schema declares exposed value %s" % String(value_id)
		)
		var definition: Dictionary = definitions[value_id]
		for field in [
			"scope",
			"behavior_consumers",
			"persistence",
			"decay",
			"presentation",
		]:
			assert_true(
				definition.has(field),
				"%s declares %s" % [String(value_id), field]
			)
	assert_eq(
		Schema.get_definition(&"anger").scope,
		Schema.SCOPE_BROAD_MOOD,
		"legacy undirected anger is explicitly a broad mood"
	)
	assert_eq(
		Schema.get_directed_opinion_definition(&"anger").scope,
		Schema.SCOPE_DIRECTED_OPINION,
		"explicit actor-targeted anger remains a directed opinion"
	)
	for metric_id in [&"favor", &"trust", &"love", &"anger", &"fear", &"suspicion"]:
		var opinion_definition := Schema.get_directed_opinion_definition(metric_id)
		assert_false(opinion_definition.is_empty(), "%s is a directed metric" % metric_id)
		assert_true(
			bool(opinion_definition.presentation.requires_subject),
			"%s presentation requires an explicit subject" % metric_id
		)


func test_value_delta_split_never_guesses_an_opinion_subject() -> void:
	var split := Schema.split_value_delta({
		"hunger": 4.0,
		"sadness": 2.0,
		"anger": 7.0,
		"favor": 3.0,
		"love": 1.0,
		"trust": -2.0,
		"suspicion": 5.0,
	})
	var local_values: Dictionary = split.local_values
	var directed_opinion: Dictionary = split.directed_opinion
	assert_eq(local_values.hunger, 4.0, "personal needs remain local")
	assert_eq(local_values.sadness, 2.0, "broad moods remain local")
	assert_eq(local_values.anger, 7.0, "broad anger remains local by default")
	assert_false(local_values.has("favor"), "directed favor is not stored locally")
	for metric_id in [&"favor", &"love", &"trust", &"suspicion"]:
		assert_true(
			directed_opinion.has(metric_id),
			"%s is held for an explicit opinion subject" % metric_id
		)
	assert_eq(split.size(), 2, "the pure split contains no inferred subject metadata")


func test_real_relationship_rows_contain_all_directed_social_currency() -> void:
	var relationships := _relationships()
	var mom := _actor(&"mom", "Mom")
	var friend := _actor(&"friend", "Friend")
	relationships.meet(mom, friend)
	var row: Dictionary = relationships.get_relationship(mom, friend)
	var stored_row: Dictionary = relationships.relationships.mom.friend

	for metric_id in Schema.get_directed_opinion_metrics():
		assert_true(row.has(metric_id), "real rows contain %s" % metric_id)
		assert_true(
			stored_row.has(metric_id),
			"authoritative rows store %s rather than synthesizing it on read" % metric_id
		)
	assert_eq(float(row.trust), 50.0, "new rows receive neutral directed trust")
	assert_eq(float(row.love), 0.0, "new rows receive neutral directed love")
	assert_eq(row.owner_id, "mom", "row preserves explicit opinion owner")
	assert_eq(row.other_id, "friend", "row preserves explicit opinion subject")


func test_generic_metric_writes_are_directional_and_clamped() -> void:
	var relationships := _relationships()
	var mom := _actor(&"mom", "Mom")
	var friend := _actor(&"friend", "Friend")

	assert_eq(
		relationships.set_opinion_metric(mom, friend, &"love", 72.0),
		72.0,
		"node API writes owner toward subject"
	)
	assert_eq(
		relationships.get_opinion_metric(friend, mom, &"love"),
		0.0,
		"reverse opinion remains independent"
	)
	assert_eq(
		relationships.set_opinion_metric_by_id(
			"friend",
			"mom",
			&"love",
			21.0,
			"test",
			{"owner_name": "Friend", "other_name": "Mom"}
		),
		21.0,
		"ID API writes the reverse direction explicitly"
	)
	assert_eq(
		relationships.change_opinion_metric_by_id(
			"mom", "friend", &"trust", 70.0
		),
		100.0,
		"generic changes clamp to the metric maximum"
	)
	assert_eq(
		relationships.set_opinion_metric_by_id(
			"mom", "friend", &"anger", 18.0
		),
		18.0,
		"explicit by-ID writes can target directed anger"
	)


func test_legacy_metric_apis_and_signals_remain_compatible() -> void:
	var relationships := _relationships()
	var mom := _actor(&"mom", "Mom")
	var friend := _actor(&"friend", "Friend")
	var signal_counts := {"favor": 0, "anger": 0, "fear": 0}
	relationships.favor_changed.connect(func(
		_owner: Node, _other: Node, _value: float, _delta: float, _row: Dictionary
	) -> void: signal_counts.favor += 1)
	relationships.anger_changed.connect(func(
		_owner: Node, _other: Node, _value: float, _delta: float, _row: Dictionary
	) -> void: signal_counts.anger += 1)
	relationships.fear_changed.connect(func(
		_owner: Node, _other: Node, _value: float, _delta: float, _row: Dictionary
	) -> void: signal_counts.fear += 1)

	assert_eq(relationships.set_favor(mom, friend, 66.0), 66.0)
	assert_eq(relationships.set_anger(mom, friend, 12.0), 12.0)
	assert_eq(relationships.set_fear(mom, friend, 18.0), 18.0)
	assert_eq(signal_counts.favor, 1, "legacy favor signal fires once")
	assert_eq(signal_counts.anger, 1, "legacy anger signal fires once")
	assert_eq(signal_counts.fear, 1, "legacy fear signal fires once")


func test_reads_normalize_copies_without_mutating_stored_rows() -> void:
	var relationships := _relationships()
	relationships.relationships = {
		"mom": {
			"friend": {
				"owner_id": "mom",
				"other_id": "friend",
				"favor": 140.0,
				"met": true,
			},
		},
	}
	var stored_before: Dictionary = relationships.relationships.duplicate(true)
	var row: Dictionary = relationships.get_relationship_by_id("mom", "friend")
	assert_eq(float(row.favor), 100.0, "read snapshots present bounded values")
	assert_eq(float(row.trust), 50.0, "read snapshots present schema defaults")
	relationships.get_relationships_for_id("mom")
	relationships.get_opinion_metric_by_id("mom", "friend", &"love")
	relationships.get_save_data()
	relationships.get_known_actor_directory_snapshot()
	assert_eq(
		relationships.relationships,
		stored_before,
		"relationship reads and snapshots never normalize storage in place"
	)


func test_zero_delta_generic_change_does_not_create_a_relationship() -> void:
	var relationships := _relationships()
	assert_eq(
		relationships.change_opinion_metric_by_id(
			"mom", "friend", &"trust", 0.0
		),
		50.0,
		"zero change returns the directed metric default"
	)
	assert_false(
		relationships.has_relationship_by_id("mom", "friend"),
		"zero change creates no row and cannot mark actors met"
	)


func test_legacy_save_migrates_and_round_trips_all_opinion_metrics() -> void:
	var relationships := _relationships()
	relationships.apply_save_data({
		"relationships": {
			"mom": {
				"friend": {
					"owner_id": "mom",
					"other_id": "friend",
					"favor": 140.0,
					"trust": -10.0,
					"love": 180.0,
					"anger": 130.0,
					"fear": -5.0,
					"suspicion": 120.0,
					"met": true,
				},
				"legacy_friend": {
					"favor": 61.0,
					"met": true,
				},
			},
		},
	})
	var row: Dictionary = relationships.get_relationship_by_id("mom", "friend")
	assert_eq(float(row.favor), 100.0, "favor is clamped on import")
	assert_eq(float(row.trust), 0.0, "trust is clamped on import")
	assert_eq(float(row.love), 100.0, "love is clamped on import")
	assert_eq(float(row.anger), 100.0, "anger is clamped on import")
	assert_eq(float(row.fear), 0.0, "fear is clamped on import")
	assert_eq(float(row.suspicion), 100.0, "suspicion is clamped on import")
	var legacy_row: Dictionary = relationships.get_relationship_by_id(
		"mom", "legacy_friend"
	)
	assert_eq(float(legacy_row.trust), 50.0, "legacy rows gain neutral trust")
	assert_eq(float(legacy_row.love), 0.0, "legacy rows gain neutral love")

	var saved: Dictionary = relationships.get_save_data()
	assert_eq(int(saved.version), 3, "directed opinion save schema is versioned")
	var restored := _relationships()
	restored.apply_save_data(saved)
	assert_eq(
		restored.get_relationship_by_id("mom", "friend"),
		row,
		"normalized opinion rows survive a save round trip"
	)


func test_known_character_snapshots_filter_unmet_transient_and_unrelated_rows() -> void:
	var relationships := _relationships()
	relationships.apply_save_data({"relationships": {
		"mom": {
			"__player__": {
				"owner_name": "Mom",
				"other_name": "Player",
				"met": true,
				"last_seen_msec": 8,
			},
			"sibling": {
				"owner_name": "Mom",
				"other_name": "Sibling",
				"met": true,
			},
		},
		"stranger": {
			"__player__": {
				"owner_name": "Stranger",
				"other_name": "Player",
				"met": false,
			},
		},
		"/root/TransientNpc": {
			"__player__": {"met": true},
		},
		"__player__": {
			"__player__": {"met": true},
		},
	}})

	var player_directory: Dictionary = relationships.get_known_actor_directory_snapshot(
		"__player__"
	)
	assert_true(player_directory.has("mom"), "reverse NPC to player rows reveal Mom")
	assert_true(player_directory.has("__player__"), "directory retains the viewer lookup")
	assert_false(player_directory.has("sibling"), "unrelated actors are filtered for viewer")
	assert_false(player_directory.has("stranger"), "unmet actors remain unknown")
	assert_false(
		player_directory.has("/root/TransientNpc"),
		"transient actor IDs never enter the character directory"
	)
	assert_eq(
		relationships.get_known_character_ids_snapshot("__player__"),
		PackedStringArray(["mom"]),
		"character roster excludes its viewer and player identity"
	)
	assert_eq(
		relationships.get_known_character_ids_snapshot("mom", true),
		PackedStringArray(["__player__", "sibling"]),
		"a character can enumerate every known opinion subject"
	)
	player_directory.mom.display_name = "Mutated"
	assert_eq(
		relationships.get_known_actor_directory_snapshot("__player__").mom.display_name,
		"Mom",
		"directory snapshots cannot mutate relationship storage"
	)


func _relationships() -> Node:
	var relationships := RelationshipsScript.new()
	relationships.emit_event_bus_events = false
	return add_child_autofree(relationships)


func _actor(actor_id: StringName, actor_name: String) -> StableActor:
	return add_child_autofree(StableActor.new(actor_id, actor_name)) as StableActor
