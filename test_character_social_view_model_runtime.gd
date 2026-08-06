extends "res://test/native_scene_tree_test.gd"

const ViewModel = preload("res://scripts/ui/character_social_view_model.gd")


class RelationshipStub:
	extends RefCounted

	var rows: Dictionary = {}
	var directory: Dictionary = {}

	func get_relationships_for_id(owner_id: String) -> Dictionary:
		return (rows.get(owner_id, {}) as Dictionary).duplicate(true)

	func get_relationship_by_id(owner_id: String, subject_id: String) -> Dictionary:
		return (
			(rows.get(owner_id, {}) as Dictionary).get(subject_id, {})
			as Dictionary
		).duplicate(true)

	func get_known_actor_directory_snapshot(viewer_id: String = "") -> Dictionary:
		var result: Dictionary = {}
		for actor_id in directory.keys():
			if actor_id == viewer_id or _is_connected_to(viewer_id, String(actor_id)):
				result[actor_id] = (directory[actor_id] as Dictionary).duplicate(true)
		return result

	func get_known_character_ids_snapshot(
		viewer_id: String = "",
		include_player: bool = false
	) -> PackedStringArray:
		var ids := PackedStringArray()
		for actor_id in directory.keys():
			var id := String(actor_id)
			if id == viewer_id or (not include_player and id == "__player__"):
				continue
			if _is_connected_to(viewer_id, id):
				ids.append(id)
		ids.sort()
		return ids

	func _is_connected_to(viewer_id: String, actor_id: String) -> bool:
		if viewer_id.is_empty():
			return true
		var toward_actor = (rows.get(viewer_id, {}) as Dictionary).get(actor_id, {})
		var toward_viewer = (rows.get(actor_id, {}) as Dictionary).get(viewer_id, {})
		return (
			toward_actor is Dictionary and bool(toward_actor.get("met", false))
		) or (
			toward_viewer is Dictionary and bool(toward_viewer.get("met", false))
		)


class LocationStub:
	extends RefCounted

	var records: Dictionary = {}
	var live_ids: Dictionary = {}
	var synchronize_count := 0

	func synchronize_live_records() -> void:
		synchronize_count += 1

	func get_records_snapshot() -> Dictionary:
		return records.duplicate(true)

	func get_record_snapshot(actor_id: String) -> Dictionary:
		return (records.get(actor_id, {}) as Dictionary).duplicate(true)

	func is_npc_live(actor_id: String) -> bool:
		return bool(live_ids.get(actor_id, false))


func test_known_owners_require_stable_met_connection_to_player() -> void:
	var relationships := RelationshipStub.new()
	relationships.rows = {
		"mom": {"__player__": _row("mom", "__player__")},
		"guard": {"__player__": _row("guard", "__player__", false)},
		"stranger": {"mom": _row("stranger", "mom")},
		"/root/TransientNpc": {
			"__player__": _row("/root/TransientNpc", "__player__"),
		},
	}
	relationships.directory = {
		"__player__": {"display_name": "Player"},
		"mom": {"display_name": "Mom"},
		"guard": {"display_name": "Guard"},
		"stranger": {"display_name": "Stranger"},
		"/root/TransientNpc": {"display_name": "Transient"},
	}
	var locations := LocationStub.new()
	locations.records = {
		"mom": _record("Mom"),
		"guard": _record("Guard"),
		"stranger": _record("Stranger"),
	}
	var model := ViewModel.new(relationships, locations)
	model.refresh()
	assert_eq(model.get_known_owner_ids(), ["mom"], "only real, stable player connection is known")
	assert_true(locations.synchronize_count > 0, "live records synchronize before snapshot inspection")


func test_subject_carousel_starts_with_player_and_grows_deterministically() -> void:
	var relationships := RelationshipStub.new()
	relationships.rows = {
		"mom": {"__player__": _row("mom", "__player__")},
		"guard": {"__player__": _row("guard", "__player__")},
		"alchemist": {"__player__": _row("alchemist", "__player__")},
	}
	relationships.directory = {
		"__player__": {"display_name": "Player"},
		"mom": {"display_name": "Mom"},
		"guard": {"display_name": "Guard"},
		"alchemist": {"display_name": "Alchemist"},
	}
	var locations := LocationStub.new()
	locations.records = {
		"mom": _record("Mom"),
		"guard": _record("Guard"),
		"alchemist": _record("Alchemist"),
	}
	var model := ViewModel.new(relationships, locations)
	model.refresh()
	assert_eq(
		model.get_known_owner_ids(),
		["alchemist", "guard", "mom"],
		"owner roster sorts deterministically by presentation name"
	)
	assert_eq(
		model.get_subject_ids("mom"),
		["__player__", "alchemist", "guard"],
		"Player is always first and the selected owner is excluded"
	)

	relationships.rows["bard"] = {"__player__": _row("bard", "__player__")}
	relationships.directory["bard"] = {"display_name": "Bard"}
	locations.records["bard"] = _record("Bard")
	model.refresh()
	assert_eq(
		model.get_subject_ids("mom"),
		["__player__", "alchemist", "bard", "guard"],
		"subject pages expand automatically when another character becomes known"
	)


func test_direction_is_explicit_and_missing_opinion_does_not_invent_metrics() -> void:
	var relationships := RelationshipStub.new()
	var mom_player := _row("mom", "__player__")
	mom_player.merge({
		"favor": 72.0,
		"trust": 81.0,
		"love": 65.0,
		"anger": 4.0,
		"fear": 2.0,
		"suspicion": 7.0,
	}, true)
	relationships.rows = {
		"mom": {"__player__": mom_player},
		"guard": {"__player__": _row("guard", "__player__")},
	}
	relationships.directory = {
		"__player__": {"display_name": "Player"},
		"mom": {"display_name": "Mom"},
		"guard": {"display_name": "Guard"},
	}
	var locations := LocationStub.new()
	locations.records = {
		"mom": _record("Mom"),
		"guard": _record("Guard"),
	}
	var model := ViewModel.new(relationships, locations)
	model.refresh()
	var toward_player: Dictionary = model.get_opinion("mom", "__player__")
	assert_true(bool(toward_player.recorded), "a met directed row is recorded")
	assert_eq(toward_player.direction, "MOM  ->  PLAYER", "direction names owner and subject")
	assert_eq(toward_player.metrics.size(), 6, "schema-backed directed metrics are exposed")

	var toward_guard: Dictionary = model.get_opinion("mom", "guard")
	assert_false(bool(toward_guard.recorded), "missing directed row is not treated as neutral")
	assert_eq(toward_guard.direction, "MOM  ->  GUARD", "missing page still names its direction")
	assert_true((toward_guard.metrics as Array).is_empty(), "missing opinion has no synthesized bars")


func test_owner_characteristics_keep_broad_mood_but_filter_legacy_opinions() -> void:
	var relationships := RelationshipStub.new()
	relationships.rows = {
		"mom": {"__player__": _row("mom", "__player__")},
	}
	relationships.directory = {
		"__player__": {"display_name": "Player"},
		"mom": {"display_name": "Mom"},
	}
	var locations := LocationStub.new()
	locations.records = {
		"mom": _record("Mom", {
			"hunger": 31.0,
			"sadness": 12.0,
			"anger": 18.0,
			"favor": 99.0,
			"love": 88.0,
			"trust": 77.0,
			"suspicion": 66.0,
		}),
	}
	var model := ViewModel.new(relationships, locations)
	model.refresh()
	var ids: Array[String] = []
	for metric in model.get_owner_characteristics("mom"):
		ids.append(String(metric.id))
	assert_true(ids.has("hunger"), "personal need remains owner-only")
	assert_true(ids.has("sadness"), "broad mood remains owner-only")
	assert_true(ids.has("anger"), "broad local anger remains a mood")
	for directed_key in ["favor", "love", "trust", "suspicion"]:
		assert_false(ids.has(directed_key), "legacy local %s is not presented as an opinion" % directed_key)


func _row(owner_id: String, other_id: String, met: bool = true) -> Dictionary:
	return {
		"owner_id": owner_id,
		"other_id": other_id,
		"owner_name": owner_id.replace("_", " ").capitalize(),
		"other_name": "Player" if other_id == "__player__" else other_id.capitalize(),
		"met": met,
	}


func _record(display_name: String, values: Dictionary = {}) -> Dictionary:
	return {
		"node_name": display_name,
		"character_profile": {
			"display_name": display_name,
			"subtitle": "Known character",
			"description": "Profile for %s." % display_name,
			"portrait_path": "",
			"accent_color": Color(0.5, 0.8, 0.65),
		},
		"node_state": {"social_stats": values.duplicate(true)},
		"scene_path": "res://scenes/testscenes/realhometest.tscn",
	}
