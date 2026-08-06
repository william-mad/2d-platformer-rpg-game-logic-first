extends SceneTree

const SocialPlanner = preload("res://scripts/systems/npc_social_planner.gd")
const WorldSimulation = preload("res://scripts/systems/npc_world_simulation.gd")

var _failures: Array[String] = []


class LocalMachine:
	extends Node

	var social_feedback: Dictionary = {}

	func set_social_selection_feedback(descriptor: Dictionary) -> void:
		social_feedback = descriptor.duplicate(true)


class LocalLocations:
	extends Node

	var live_npcs: Dictionary = {}
	var authoritative_records: Dictionary = {}

	func get_live_npc(npc_id: String) -> Node:
		return live_npcs.get(npc_id, null) as Node

	func get_record_snapshot(npc_id: String) -> Dictionary:
		var record = authoritative_records.get(npc_id, {})
		return record.duplicate(true) if record is Dictionary else {}

	func record_schedule_start(npc_id: String, record: Dictionary) -> void:
		var authoritative := record.duplicate(true)
		authoritative["activity"] = {
			"state_name": "Work",
			"spot_id": "test_spot",
		}
		authoritative_records[npc_id] = authoritative


class RecordingWorld:
	extends WorldSimulation

	var phase_events: Array[String] = []
	var schedule_spots: Array[String] = []
	var primary_spot_claimed: bool = false
	var blocking_priorities: Dictionary = {}
	var observed_social_blockers: Dictionary = {}
	var used_social_participants: Dictionary = {}
	var previewable_social_seekers := {
		"a": true,
		"b": true,
		"c": true,
	}

	func _prepare_idle_activity_plan(
		npc_id: StringName,
		_record_value: Dictionary,
		_total_hours: float,
		_locations: Node
	) -> Dictionary:
		return {
			"blocking_priority": int(blocking_priorities.get(String(npc_id), -1)),
			"definition": NpcSpotDefinition.new(),
			"npc_id": npc_id,
			"selected_spot": "fallback" if primary_spot_claimed else "primary",
		}

	func _try_start_social_seek(
		npc_id: StringName,
		_record_value: Dictionary,
		_records: Dictionary,
		_locations: Node,
		blocking_priority: int
	) -> bool:
		phase_events.append("social:%s" % String(npc_id))
		observed_social_blockers[String(npc_id)] = blocking_priority
		if npc_id == &"a":
			used_social_participants["a"] = true
			used_social_participants["b"] = true
			return true
		return false

	func _preview_social_seek(
		npc_id: StringName,
		_record_value: Dictionary,
		_records: Dictionary,
		_locations: Node,
		_blocking_priority: int
	) -> bool:
		return previewable_social_seekers.has(String(npc_id))

	func _social_participant_was_used_this_pass(npc_id: StringName) -> bool:
		return used_social_participants.has(String(npc_id))

	func _start_planned_scheduled_activity(
		npc_id: StringName,
		_record_value: Dictionary,
		_total_hours: float,
		_hour: float,
		_locations: Node,
		_plan: Dictionary
	) -> void:
		phase_events.append("schedule:%s" % String(npc_id))
		var selected_spot := String(_plan.get("selected_spot", ""))
		schedule_spots.append("%s:%s" % [String(npc_id), selected_spot])
		if selected_spot == "primary":
			primary_spot_claimed = true
		if _locations != null and _locations.has_method("record_schedule_start"):
			_locations.call("record_schedule_start", String(npc_id), _record_value)


func _initialize() -> void:
	await process_frame
	_test_record_order_does_not_change_pair_allocation()
	_test_only_competing_social_seekers_are_deferred_and_sorted()
	_test_world_profiles_are_validated_without_a_live_npc()
	_test_world_descriptor_freshness_and_clear()
	await process_frame

	if _failures.is_empty():
		print("NPC social allocation-order runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_record_order_does_not_change_pair_allocation() -> void:
	var canonical := _allocate_pairs(["a", "b", "c", "d"])
	var reversed := _allocate_pairs(["d", "c", "b", "a"])
	var interleaved := _allocate_pairs(["c", "a", "d", "b"])
	_expect(canonical == ["a:b", "c:d"], "sorted allocation produces the expected stable pairs")
	_expect(reversed == canonical, "reversed record insertion order preserves pair allocation")
	_expect(interleaved == canonical, "permuted record insertion order preserves pair allocation")


func _allocate_pairs(insertion_order: Array[String]) -> Array[String]:
	var world := WorldSimulation.new()
	var planner := SocialPlanner.new()
	var locations := LocalLocations.new()
	var records: Dictionary = {}
	for npc_id in insertion_order:
		records[npc_id] = _record()
	var settings := {
		"priority": 60,
		"minimum_npc_favor": 10.0,
	}
	var rng := RandomNumberGenerator.new()
	var pairs: Array[String] = []
	planner.begin_simulation_pass()
	var ordered_keys: Array = world.call(
		"_get_ordered_social_seeker_ids",
		records
	)
	for npc_id_value in ordered_keys:
		var npc_id := String(npc_id_value)
		var candidate := planner.choose_candidate(
			StringName(npc_id),
			records[npc_id_value],
			records,
			locations,
			settings,
			null,
			null,
			rng
		)
		if candidate.is_empty():
			continue
		var target_id := String(candidate.get("target_id", ""))
		var reservation := planner.reserve_pair(
			npc_id,
			records[npc_id_value],
			target_id,
			records[target_id],
			locations,
			60,
			null,
			records
		)
		if bool(reservation.get("accepted", false)):
			pairs.append("%s:%s" % [npc_id, target_id])
	planner.end_simulation_pass()
	world.free()
	locations.free()
	return pairs


func _test_only_competing_social_seekers_are_deferred_and_sorted() -> void:
	var world := RecordingWorld.new()
	root.add_child(world)
	var locations := LocalLocations.new()
	var records: Dictionary = {}
	var deferred_seekers: Array[Dictionary] = []
	for npc_id in ["d", "ordinary", "protected", "b", "a", "c"]:
		var talk_need := 0.0 if npc_id == "ordinary" else 90.0
		records[npc_id] = _record(talk_need)
	world.blocking_priorities = {
		"d": 50,
		"c": 50,
		"protected": 80,
	}
	var target_npc := Node2D.new()
	var target_machine := LocalMachine.new()
	target_machine.name = "NpcStateMachine"
	target_npc.add_child(target_machine)
	root.add_child(target_npc)
	locations.live_npcs["b"] = target_npc
	world.call("_publish_social_selection_descriptor", &"b", target_machine, {
		"all_candidates_suppressed": true,
		"reason_code": &"no_social_target_due_to_recent_memory",
	})
	world.call("_publish_social_selection_descriptor", &"a", null, {
		"selected_candidate_id": "b",
	})
	for npc_id in ["d", "ordinary", "protected"]:
		world.call(
			"_route_idle_activity_for_social_arbitration",
			StringName(npc_id), records[npc_id], 10.0, 10.0,
			locations, records, deferred_seekers
		)
	world.phase_events.append("active:later_record_update")
	for npc_id in ["b", "a", "c"]:
		world.call(
			"_route_idle_activity_for_social_arbitration",
			StringName(npc_id), records[npc_id], 10.0, 10.0,
			locations, records, deferred_seekers
		)
	world.call(
		"_process_deferred_social_seekers",
		deferred_seekers, 10.0, 10.0, locations, records
	)
	_expect(
		world.phase_events.slice(0, 4) == [
			"schedule:d",
			"schedule:ordinary",
			"schedule:protected",
			"active:later_record_update",
		],
		"nonviable, ordinary, and schedule-protected NPCs retain inline record order"
	)
	_expect(
		world.phase_events.slice(4, 7) == [
			"social:a", "social:b", "social:c",
		],
		"only globally competing social seekers are sorted by stable ID"
	)
	_expect(
		world.phase_events.slice(7) == [
			"schedule:c",
		],
		"failed seekers retain record order while both members of a social pair skip schedules"
	)
	_expect(
		world.schedule_spots == [
			"d:primary", "ordinary:fallback", "protected:fallback", "c:fallback",
		],
		"a seeker with no candidate keeps its original primary-spot precedence"
	)
	_expect(
		int(world.observed_social_blockers.get("c", -1)) == 50,
		"social uses the blocker captured at the seeker's original record position"
	)
	_expect(
		not world.observed_social_blockers.has("protected"),
		"a higher-priority schedule starts inline instead of speculatively blocking social"
	)
	_expect(
		not (records["ordinary"] as Dictionary).get("activity", {}).is_empty(),
		"inline offscreen schedule commits refresh the working arbitration snapshot"
	)
	_expect(
		world.get_social_selection_debug_descriptor(&"b").is_empty()
			and target_machine.social_feedback.is_empty(),
		"a seeker later used as a social target clears stale selection feedback"
	)
	_expect(
		String(world.get_social_selection_debug_descriptor(&"a").get(
			"selected_candidate_id", ""
		)) == "b",
		"a successful seeker retains its selected-target developer descriptor"
	)
	target_npc.queue_free()
	world.queue_free()
	locations.free()


func _test_world_descriptor_freshness_and_clear() -> void:
	var world := WorldSimulation.new()
	world.name = "SocialDescriptorTestWorld"
	root.add_child(world)
	var locations := LocalLocations.new()
	var npc := Node2D.new()
	var machine := LocalMachine.new()
	machine.name = "NpcStateMachine"
	npc.add_child(machine)
	root.add_child(npc)
	locations.live_npcs["mom"] = npc
	world.set("_social_planning_pass_id", 7)
	world.call("_publish_social_selection_descriptor", &"mom", machine, {
		"reason_code": &"no_social_target",
	})
	var published := world.get_social_selection_debug_descriptor(&"mom")
	_expect(int(published.get("simulation_pass_id", -1)) == 7, "world descriptor records its simulation pass")
	_expect(float(published.get("evaluated_game_hours", -1.0)) >= 0.0, "world descriptor records game time")
	_expect(int(published.get("published_at_usec", 0)) > 0, "world descriptor records publication time")
	world.call("_clear_social_selection_descriptor", &"mom", locations)
	_expect(world.get_social_selection_debug_descriptor(&"mom").is_empty(), "inactive planning clears the cached descriptor")
	_expect(machine.social_feedback.is_empty(), "inactive planning clears live feedback")
	world.call("_publish_social_selection_descriptor", &"mom", machine, {
		"reason_code": &"no_social_target",
	})
	world.call("_prune_social_selection_descriptors", {}, locations)
	_expect(
		world.get_social_selection_debug_descriptor(&"mom").is_empty(),
		"record pruning removes the world descriptor"
	)
	_expect(
		machine.social_feedback.is_empty(),
		"record pruning also clears a surviving live machine"
	)
	npc.queue_free()
	locations.free()
	world.queue_free()


func _test_world_profiles_are_validated_without_a_live_npc() -> void:
	var world := WorldSimulation.new()
	var malformed_record := _record()
	malformed_record.node_state["world_simulation_profile"] = "invalid"
	world.call("_validate_social_world_profile", &"mom", malformed_record)
	var issues: Array[Dictionary] = (
		world.get_social_world_profile_validation_issues(&"mom")
	)
	var found_invalid_profile := false
	for issue in issues:
		if StringName(String(issue.get("code", ""))) == (
			&"invalid_world_simulation_profile"
		):
			found_invalid_profile = true
	_expect(
		found_invalid_profile,
		"saved/offscreen world profiles are validated without a live state machine"
	)
	issues.clear()
	_expect(
		not world.get_social_world_profile_validation_issues(&"mom").is_empty(),
		"world profile validation exposes an owned structured issue snapshot"
	)
	var invalid_settings_record := _record()
	invalid_settings_record.node_state["world_simulation_profile"] = {
		"social_seeking": {
			"enabled": "yes",
			"talk_need_threshold": 200.0,
			"priority": [],
			"minimum_npc_favor": -1.0,
		},
	}
	var sanitized_settings: Dictionary = world.call(
		"_get_social_seek_settings", invalid_settings_record
	)
	_expect(
		sanitized_settings == {
			"enabled": true,
			"talk_need_threshold": 70.0,
			"priority": 60,
			"minimum_npc_favor": 10.0,
		},
		"invalid saved social fields fall back independently to safe defaults"
	)
	invalid_settings_record.node_state.world_simulation_profile = {
		"social_seeking": {},
		"talk_handshake": "invalid",
	}
	world.call(
		"_validate_social_world_profile", &"mom", invalid_settings_record
	)
	var refreshed_issues := world.get_social_world_profile_validation_issues(
		&"mom"
	)
	var found_invalid_section := false
	for issue in refreshed_issues:
		if StringName(String(issue.get("code", ""))) == (
			&"invalid_social_settings_section"
		):
			found_invalid_section = true
	_expect(
		found_invalid_section,
		"validation cache refreshes when another persisted social section changes"
	)
	world.free()


func _record(talk_need: float = 90.0) -> Dictionary:
	return {
		"scene_path": "res://town.tscn",
		"last_position": Vector2.ZERO,
		"activity": {},
		"pending_travel": {},
		"node_state": {
			"social_stats": {
				"disabled": 0.0,
				"knockout": 0.0,
				"talk_need": talk_need,
			}
		},
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
