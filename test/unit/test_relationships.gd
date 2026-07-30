extends "res://test/native_scene_tree_test.gd"
# Unit tests for the Relationships autoload's favor clamping and save round-trip.
# Most public favor methods need live Node arguments, so these tests focus on the
# pure save/restore path (apply_save_data / get_save_data) where favor clamping and
# relationship normalization actually live, plus the min/max favor configuration.

var RelationshipsClass := preload("res://scripts/systems/relationships.gd")

var relationships: Node


func before_each() -> void:
	relationships = RelationshipsClass.new()
	relationships.default_favor = 50.0
	relationships.min_favor = 0.0
	relationships.max_favor = 100.0
	add_child_autofree(relationships)


func test_empty_save_data_round_trips_cleanly() -> void:
	relationships.apply_save_data({})
	assert_true(relationships.relationships.is_empty(), "empty save leaves relationships empty")


func test_loaded_favor_is_clamped_to_max() -> void:
	# A tampered or migrated save with favor > max must clamp on load.
	var saved := {
		"npc_a": {
			"npc_b": {
				"favor": 150.0,
				"met": true,
				"meet_count": 1
			}
		}
	}
	relationships.apply_save_data({"relationships": saved})
	var restored: Dictionary = relationships.get_relationship_by_id("npc_a", "npc_b")
	assert_eq(float(restored.get("favor", -1.0)), 100.0, "favor above max clamps to 100")


func test_loaded_favor_is_clamped_to_min() -> void:
	var saved := {
		"npc_a": {
			"npc_b": {
				"favor": -25.0
			}
		}
	}
	relationships.apply_save_data({"relationships": saved})
	var restored: Dictionary = relationships.get_relationship_by_id("npc_a", "npc_b")
	assert_eq(float(restored.get("favor", -1.0)), 0.0, "favor below min clamps to 0")


func test_loaded_relationship_defaults_missing_favor() -> void:
	# A relationship entry with no favor field should fall back to default_favor.
	var saved := {"npc_a": {"npc_b": {"met": true}}}
	relationships.apply_save_data({"relationships": saved})
	var restored: Dictionary = relationships.get_relationship_by_id("npc_a", "npc_b")
	assert_eq(float(restored.get("favor", -1.0)), 50.0, "missing favor falls back to default 50")


func test_save_round_trip_preserves_favor() -> void:
	var saved := {"npc_a": {"npc_b": {"favor": 73.0, "met": true, "meet_count": 3}}}
	relationships.apply_save_data({"relationships": saved})
	var round_tripped: Dictionary = relationships.get_save_data()
	var restored: Dictionary = round_tripped["relationships"]["npc_a"]["npc_b"]
	assert_eq(float(restored["favor"]), 73.0, "favor survives a save round-trip")
	assert_eq(int(restored["meet_count"]), 3, "meet_count survives a save round-trip")


func test_empty_other_id_is_skipped() -> void:
	# Blank/whitespace ids must not pollute the store with empty keys.
	var saved := {"npc_a": {"   ": {"favor": 10.0}}}
	relationships.apply_save_data({"relationships": saved})
	assert_true(not relationships.relationships.has("npc_a") or not relationships.relationships["npc_a"].has("   "),
		"whitespace-only other_id is skipped")


func test_get_relationship_for_unknown_ids_is_empty() -> void:
	var restored: Dictionary = relationships.get_relationship_by_id("nobody", "noone")
	assert_true(restored.is_empty(), "unknown id pair returns empty dict")


func test_get_favor_by_id_reads_stored_value_with_normalized_ids() -> void:
	relationships.relationships = {"npc_a": {"npc_b": {"favor": 73.0}}}
	assert_eq(
		relationships.get_favor_by_id(" npc_a ", " npc_b "),
		73.0,
		"favor lookup reads the stored scalar with normalized ids"
	)


func test_get_favor_by_id_preserves_missing_fallback() -> void:
	assert_eq(
		relationships.get_favor_by_id("npc_a", "npc_b", 12.0),
		12.0,
		"missing relationship returns the supplied fallback"
	)
	assert_eq(
		relationships.get_favor_by_id("npc_a", "npc_b"),
		50.0,
		"negative fallback uses the configured default favor"
	)


func test_get_favor_by_id_defaults_malformed_entry_without_favor() -> void:
	relationships.relationships = {"npc_a": {"npc_b": {"met": true}}}
	assert_eq(
		relationships.get_favor_by_id("npc_a", "npc_b", 12.0),
		50.0,
		"stored entries without favor use default favor instead of the missing fallback"
	)
