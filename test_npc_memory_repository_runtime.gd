extends "res://test/native_scene_tree_test.gd"

const MemoryEvent = preload(
	"res://scripts/systems/npc_behavior/npc_memory_event.gd"
)
const MemoryPolicy = preload(
	"res://scripts/systems/npc_behavior/npc_memory_policy.gd"
)
const FeedbackFormatter = preload(
	"res://scripts/systems/npc_behavior/npc_behavior_feedback_formatter.gd"
)


func test_registration_validates_identity_and_isolates_npcs() -> void:
	var repository := _repository()
	assert_false(
		bool(repository.register_live_memory("", _memory(), 10.0).accepted),
		"empty identity is rejected"
	)
	assert_false(
		bool(repository.register_live_memory(
			"/root/Scene/Mom",
			_memory(),
			10.0
		).accepted),
		"scene-tree identity is rejected"
	)
	assert_false(
		bool(repository.register_live_memory(
			"npc:12345",
			_memory(),
			10.0
		).accepted),
		"generated instance identity is rejected"
	)
	var mom_memory := _memory()
	var dad_memory := _memory()
	var mom := repository.register_live_memory("mom", mom_memory, 10.0)
	var dad := repository.register_live_memory("dad", dad_memory, 10.0)
	assert_false(String(mom.ownership_token).is_empty(), "registration returns a token")
	assert_true(repository.has_live_owner("mom"), "valid identity has a live owner")
	assert_eq(
		repository.get_live_owner_descriptor("mom").generation,
		1,
		"the safe descriptor exposes generation"
	)
	assert_false(
		repository.get_live_owner_descriptor("mom").has("memory_component"),
		"the descriptor does not expose a mutable memory object"
	)
	mom_memory.remember(_event("mom_only", 10.0, &"mom_subject"))
	dad_memory.remember(_event("dad_only", 10.0, &"dad_subject"))
	assert_false(
		_snapshot_has_id(
			repository.get_snapshot_for_npc("dad", 10.0),
			"mom_only"
		),
		"different persistent IDs remain isolated"
	)
	assert_true(bool(dad.accepted), "the second persistent ID also registers")
	assert_true(repository.clear_npc_memory("mom", &"test"), "one NPC can clear")
	assert_true(
		repository.get_snapshot_for_npc("mom", 10.0).is_empty(),
		"per-NPC clear removes its live and cached memory"
	)
	assert_eq(
		repository.get_snapshot_for_npc("dad", 10.0).size(),
		1,
		"per-NPC clear does not affect another identity"
	)


func test_unregister_then_recreate_restores_memory_for_stable_id() -> void:
	var repository := _repository()
	var first := _memory()
	var first_registration := repository.register_live_memory("mom", first, 10.0)
	first.remember(_event("first", 10.0, &"subject_a"))
	assert_true(
		repository.unregister_live_memory(
			"mom",
			String(first_registration.ownership_token),
			&"test",
			10.1
		),
		"the current owner captures on exit"
	)

	var replacement := _memory()
	var replacement_registration := repository.register_live_memory(
		"mom",
		replacement,
		10.1
	)
	assert_true(
		bool(replacement_registration.accepted),
		"the replacement becomes the live owner"
	)
	assert_not_null(
		replacement.get_memory_by_id("first"),
		"the replacement receives the cached memory"
	)


func test_duplicate_overlap_captures_old_then_rejects_stale_exit() -> void:
	var repository := _repository()
	var old_memory := _memory()
	var old_registration := repository.register_live_memory(
		"mom",
		old_memory,
		10.0
	)
	old_memory.remember(_event("old", 10.0, &"old_subject"))

	var new_memory := _memory()
	new_memory.remember(_event("new", 10.05, &"new_subject"))
	var new_registration := repository.register_live_memory(
		"mom",
		new_memory,
		10.05
	)
	assert_true(
		int(new_registration.generation) > int(old_registration.generation),
		"duplicate takeover increments the ownership generation"
	)
	assert_not_null(
		new_memory.get_memory_by_id("old"),
		"duplicate takeover captures and restores the outgoing owner"
	)
	old_memory.remember(_event("stale_late", 10.06, &"stale_subject"))
	assert_false(
		repository.unregister_live_memory(
			"mom",
			String(old_registration.ownership_token),
			&"test",
			10.06
		),
		"the old token cannot unregister the new generation"
	)
	var live_snapshot := repository.get_snapshot_for_npc("mom", 10.06)
	assert_eq(live_snapshot.size(), 2, "the current live component is authoritative")
	assert_false(
		_snapshot_has_id(live_snapshot, "stale_late"),
		"stale-owner changes cannot overwrite current memory"
	)
	assert_true(
		repository.unregister_live_memory(
			"mom",
			String(new_registration.ownership_token),
			&"test",
			10.07
		),
		"the current generation can unregister"
	)


func test_same_component_registration_is_idempotent() -> void:
	var repository := _repository()
	var memory := _memory()
	var first := repository.register_live_memory("mom", memory, 10.0)
	memory.remember(_event("kept", 10.0, &"subject"))
	var second := repository.register_live_memory("mom", memory, 10.1)
	assert_eq(
		second.result,
		"already_registered",
		"registering the same component is a no-op"
	)
	assert_eq(
		second.ownership_token,
		first.ownership_token,
		"idempotent registration keeps its ownership token"
	)
	assert_eq(
		memory.get_recent_memories().size(),
		1,
		"idempotent registration does not re-import or duplicate memory"
	)


func test_live_lookup_wins_over_cached_fallback() -> void:
	var repository := _repository()
	var memory := _memory()
	var registration := repository.register_live_memory("mom", memory, 10.0)
	memory.remember(_event("cached", 10.0, &"cached_subject"))
	assert_true(
		repository.capture_live_memory(
			"mom",
			String(registration.ownership_token),
			10.0
		),
		"an explicit fallback capture succeeds"
	)
	memory.remember(_event("live_only", 10.1, &"live_subject"))
	var snapshot := repository.get_snapshot_for_npc("mom", 10.1)
	assert_true(
		_snapshot_has_id(snapshot, "live_only"),
		"lookup reads the current live component instead of stale cache"
	)


func test_restore_merges_with_preexisting_live_memory_once() -> void:
	var repository := _repository()
	var source := _memory()
	var source_registration := repository.register_live_memory(
		"mom",
		source,
		10.0
	)
	source.remember(_event("cached_equivalent", 10.0, &"same_subject"))
	source.remember(_event("cached_unique", 10.0, &"cached_subject"))
	repository.unregister_live_memory(
		"mom",
		String(source_registration.ownership_token),
		&"test",
		10.0
	)

	var destination := _memory()
	destination.remember(_event("live_equivalent", 10.05, &"same_subject"))
	destination.remember(_event("live_unique", 10.05, &"live_subject"))
	var changes := {"count": 0}
	destination.memory_changed.connect(func() -> void: changes.count += 1)
	repository.register_live_memory("mom", destination, 10.05)
	var restored := destination.export_snapshot(10.05)
	assert_eq(restored.size(), 3, "unique cached and live memories are preserved")
	var equivalent := destination.find_recent_at(
		MemoryPolicy.EVENT_ACTION_FAILED,
		10.05,
		&"same_subject",
		&"target",
		&"Action"
	)
	assert_eq(equivalent.size(), 1, "normal dedupe semantics merge equivalents")
	assert_eq(
		equivalent[0].occurrence_count,
		2,
		"the merge preserves both observations"
	)
	assert_eq(changes.count, 1, "restore emits one summarized memory change")


func test_restore_preserves_timestamps_counts_metadata_and_capacity() -> void:
	var repository := _repository()
	var source := _memory()
	var registration := repository.register_live_memory("mom", source, 10.0)
	var detailed := _event("detailed", 10.0, &"detailed_subject")
	detailed.occurrence_count = 3
	detailed.importance = 0.9
	detailed.metadata = {"nested": {"value": 7}}
	source.remember(detailed)
	var low := _event("low", 10.05, &"low_subject")
	low.importance = 0.1
	source.remember(low)
	repository.unregister_live_memory(
		"mom",
		String(registration.ownership_token),
		&"test",
		10.1
	)
	var external_copy := repository.get_snapshot_for_npc("mom", 10.1)
	external_copy[0].metadata.nested.value = 99

	var replacement := _memory()
	replacement.maximum_memories = 1
	repository.register_live_memory("mom", replacement, 10.1)
	var restored := replacement.get_memory_by_id("detailed")
	assert_not_null(restored, "deterministic capacity keeps the higher-count event")
	if restored != null:
		assert_eq(restored.created_game_hours, 10.0, "creation time is unchanged")
		assert_eq(restored.last_updated_game_hours, 10.0, "update time is unchanged")
		assert_eq(restored.occurrence_count, 3, "occurrence count is unchanged")
		assert_eq(
			restored.metadata.nested.value,
			7,
			"repository snapshots remain deeply copied"
		)
	assert_eq(
		replacement.get_recent_memories().size(),
		1,
		"normal capacity is enforced during restoration"
	)


func test_restored_memory_still_drives_existing_policies_and_feedback() -> void:
	var repository := _repository()
	var source := _memory()
	var registration := repository.register_live_memory("mom", source, 10.0)
	source.remember(_typed_event(
		"refusal",
		MemoryPolicy.EVENT_CONVERSATION_REFUSED,
		10.0,
		{
			"subject_id": "partner",
			"target_id": "mom",
			"logical_action": "Talk",
		}
	))
	source.remember(_typed_event(
		"target_failure",
		MemoryPolicy.EVENT_TARGET_UNAVAILABLE,
		10.0,
		{
			"subject_id": "mom",
			"target_id": "table",
			"logical_action": "Eat",
		}
	))
	repository.unregister_live_memory(
		"mom",
		String(registration.ownership_token),
		&"test",
		10.05
	)
	var replacement := _memory()
	repository.register_live_memory("mom", replacement, 10.05)

	var social := NpcSocialMemoryPolicy.new().evaluate_candidate(
		replacement,
		&"partner",
		10.05,
		{"remembering_npc_id": "mom"}
	)
	assert_false(bool(social.allowed), "restored refusal still suppresses its partner")
	var target := NpcTargetMemoryPolicy.new().evaluate_candidate(
		replacement,
		&"Eat",
		&"table",
		&"",
		10.05,
		{"remembering_npc_id": "mom"}
	)
	assert_false(bool(target.allowed), "restored failure still suppresses its target")
	var feedback := FeedbackFormatter.format_label(
		&"Idle",
		&"",
		{"memory": replacement.get_debug_descriptor(10.05)}
	)
	assert_true(
		feedback.contains("remembers:"),
		"restored memory uses the existing feedback formatter"
	)


func test_cached_expiry_uses_game_hours_without_simulation() -> void:
	var repository := _repository()
	var memory := _memory()
	var registration := repository.register_live_memory("mom", memory, 10.0)
	memory.remember(_event("expires", 10.0, &"subject"))
	repository.unregister_live_memory(
		"mom",
		String(registration.ownership_token),
		&"test",
		10.0
	)
	assert_eq(
		repository.get_snapshot_for_npc("mom", 10.49).size(),
		1,
		"cached memory remains before its game-hour expiry"
	)
	assert_true(
		repository.get_snapshot_for_npc("mom", 10.5).is_empty(),
		"cached memory expires on lookup without offscreen processing"
	)
	assert_false(
		repository.is_processing(),
		"repository requires no per-frame pruning or offscreen reasoning"
	)


func test_dead_weak_registration_is_cleaned_without_losing_cache() -> void:
	var repository := _repository()
	var memory := NpcShortTermMemory.new()
	var registration := repository.register_live_memory("mom", memory, 10.0)
	memory.remember(_event("cached", 10.0, &"subject"))
	repository.capture_live_memory(
		"mom",
		String(registration.ownership_token),
		10.0
	)
	memory.free()
	var debug := repository.get_debug_descriptor(10.1)
	assert_eq(debug.live_npc_count, 0, "dead weak owners are discarded")
	assert_eq(
		repository.get_snapshot_for_npc("mom", 10.1).size(),
		1,
		"the last explicit cache remains available"
	)
	var replacement := _memory()
	assert_true(
		bool(repository.register_live_memory(
			"mom",
			replacement,
			10.1
		).accepted),
		"a replacement can claim a dead weak owner"
	)


func test_clear_all_clears_live_cache_and_blocks_stale_generation() -> void:
	var repository := _repository()
	var old_memory := _memory()
	var old_registration := repository.register_live_memory(
		"mom",
		old_memory,
		10.0
	)
	old_memory.remember(_event("old", 10.0, &"old_subject"))
	var current_memory := _memory()
	var current_registration := repository.register_live_memory(
		"mom",
		current_memory,
		10.1
	)
	current_memory.remember(_event("current", 10.1, &"current_subject"))

	repository.clear_all_runtime_memory(&"new_game")
	assert_true(current_memory.get_recent_memories().is_empty(), "live memory clears")
	assert_true(
		repository.get_snapshot_for_npc("mom", 10.1).is_empty(),
		"cached fallback clears"
	)
	assert_false(
		repository.unregister_live_memory(
			"mom",
			String(old_registration.ownership_token),
			&"test",
			10.1
		),
		"a stale pre-reset generation cannot recreate cached data"
	)
	assert_true(
		repository.unregister_live_memory(
			"mom",
			String(current_registration.ownership_token),
			&"test",
			10.1
		),
		"the current empty owner can still exit cleanly"
	)
	assert_true(
		repository.get_snapshot_for_npc("mom", 10.1).is_empty(),
		"current exit after reset only captures an empty snapshot"
	)
	var later := _memory()
	repository.register_live_memory("mom", later, 10.1)
	assert_true(
		later.get_recent_memories().is_empty(),
		"a later instance cannot restore pre-reset memory"
	)


func test_runtime_export_import_is_versioned_and_merges_live_owner() -> void:
	var source_repository := _repository()
	var source_memory := _memory()
	source_repository.register_live_memory("mom", source_memory, 10.0)
	source_memory.remember(_event("imported", 10.0, &"imported_subject"))
	var cached_memory := _memory()
	var cached_registration := source_repository.register_live_memory(
		"dad",
		cached_memory,
		10.0
	)
	cached_memory.remember(_event("cached_export", 10.0, &"cached_subject"))
	source_repository.unregister_live_memory(
		"dad",
		String(cached_registration.ownership_token),
		&"test",
		10.0
	)
	var state := source_repository.export_runtime_state(10.0)
	assert_eq(state.version, 1, "runtime payload declares its schema version")
	assert_eq(
		(state.npc_memories as Dictionary).size(),
		2,
		"export includes both live and cached NPCs"
	)
	assert_true(
		source_repository.has_live_owner("mom"),
		"export does not unregister the live owner"
	)
	state.npc_memories["malformed"] = "bad entry"
	state.npc_memories["/root/runtime_id"] = {
		"revision": 1,
		"snapshot": [],
	}

	var destination_repository := _repository()
	var destination_memory := _memory()
	destination_memory.remember(_event("live", 10.0, &"live_subject"))
	destination_repository.register_live_memory("mom", destination_memory, 10.0)
	var unrelated := _memory()
	unrelated.remember(_event("unrelated", 10.0, &"other_subject"))
	destination_repository.register_live_memory("other", unrelated, 10.0)
	var result := destination_repository.import_runtime_state(state, 10.0)
	assert_true(bool(result.accepted), "supported payload imports")
	assert_eq(result.malformed_count, 1, "malformed NPC entry is skipped")
	assert_eq(
		destination_memory.get_recent_memories().size(),
		2,
		"matching live owner merges imported and existing memories"
	)
	assert_eq(
		unrelated.get_recent_memories().size(),
		1,
		"import leaves an unrelated live NPC untouched"
	)
	assert_false(
		bool(destination_repository.import_runtime_state(
			{"version": 999, "npc_memories": {}},
			10.0
		).accepted),
		"unsupported runtime versions are rejected"
	)


func _repository() -> NpcMemoryRuntimeRepositoryService:
	var repository := NpcMemoryRuntimeRepositoryService.new()
	add_child_autofree(repository)
	return repository


func _memory() -> NpcShortTermMemory:
	var memory := NpcShortTermMemory.new()
	add_child_autofree(memory)
	return memory


func _event(
	memory_id: String,
	now_game_hours: float,
	subject_id: StringName
) -> NpcMemoryEvent:
	var event := MemoryEvent.create(
		MemoryPolicy.EVENT_ACTION_FAILED,
		{
			"source": "repository_test",
			"reason_code": "test",
			"subject_id": subject_id,
			"target_id": "target",
			"logical_action": "Action",
		},
		now_game_hours
	)
	event.memory_id = memory_id
	return event


func _typed_event(
	memory_id: String,
	event_type: StringName,
	now_game_hours: float,
	context: Dictionary
) -> NpcMemoryEvent:
	var full_context := {
		"source": "repository_test",
		"reason_code": "test",
	}
	full_context.merge(context, true)
	var event := MemoryEvent.create(event_type, full_context, now_game_hours)
	event.memory_id = memory_id
	return event


func _snapshot_has_id(snapshot: Array, memory_id: String) -> bool:
	for entry in snapshot:
		if entry is Dictionary and String(entry.get("memory_id", "")) == memory_id:
			return true
	return false
