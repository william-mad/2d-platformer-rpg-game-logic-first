extends SceneTree

const SOURCE_SCENE := "res://scenes/testscenes/realtest1.tscn"
const DESTINATION_SCENE := "res://scenes/testscenes/realhometest.tscn"
const FAILED_DESTINATION := "res://companion_transition_expected_failure.tscn"

var _failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var simulation := root.get_node_or_null("NpcWorldSimulation")
	if simulation != null:
		simulation.set_process(false)
	var loader := root.get_node_or_null("SceneLoader")
	var runtime := root.get_node_or_null("PlayerRuntime")
	var locations := root.get_node_or_null("NpcLocations")
	if loader == null or runtime == null or locations == null:
		push_error("Companion scene-transition test requires runtime autoloads.")
		quit(1)
		return
	loader.use_threaded_loading = false
	loader.show_loading_overlay = false
	runtime.set("travel_session", runtime.call("_empty_travel_session"))

	_expect(change_scene_to_file(SOURCE_SCENE) == OK, "source scene begins loading")
	await _wait_for_scene(SOURCE_SCENE)
	await _wait_frames(6)
	var player := get_first_node_in_group(&"player")
	var source_mom := locations.call("get_live_npc", "mom") as Node2D
	_expect(player != null, "source scene has a player")
	_expect(source_mom != null, "source scene has Mom")
	if player == null or source_mom == null:
		_finish()
		return

	var travel_component := source_mom.get_node_or_null("TravelCompanion") as TravelCompanionComponent
	_expect(travel_component != null, "Mom has her travel policy component")
	var start_result: Dictionary = runtime.call(
		"start_travel",
		source_mom,
		player,
		travel_component.travel_policy if travel_component != null else null
	)
	_expect(bool(start_result.get("success", false)), "Mom starts companion travel")
	await physics_frame
	var source_machine := source_mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
	_expect(
		source_machine != null and source_machine.active_action == null,
		"entering follow clears the prior activity only after its state exits"
	)
	var source_record: Dictionary = locations.call("get_record_snapshot", "mom")
	_expect(
		(source_record.get("action", {}) as Dictionary).is_empty()
		and (source_record.get("activity", {}) as Dictionary).is_empty(),
		"the traveling record contains no stale scheduled action"
	)
	_expect_follow_presentation(source_mom, "source")

	loader.cached_scenes[FAILED_DESTINATION] = null
	loader.use_threaded_loading = true
	var failed_transition: Dictionary = loader.call(
		"request_player_scene_transition",
		player,
		FAILED_DESTINATION,
		&"missing_companion_test_spawn",
		&"companion_expected_failure"
	)
	_expect(bool(failed_transition.get("accepted", false)), "companion failure regression reaches the loader")
	for _frame in range(60):
		await process_frame
		if not loader.loading_in_progress:
			break
	loader.use_threaded_loading = false
	_expect(current_scene != null and current_scene.scene_file_path == SOURCE_SCENE, "failed load keeps the source scene")
	_expect(
		String(runtime.travel_session.get("destination_scene_path", "")) == SOURCE_SCENE,
		"failed load rolls the companion destination back to the source scene"
	)
	var rolled_back_record: Dictionary = locations.call("get_record_snapshot", "mom")
	_expect(
		String(rolled_back_record.get("scene_path", "")) == SOURCE_SCENE,
		"failed load rolls the persistent companion record back to the source scene"
	)
	_expect(not bool(runtime.get("_pending_companion_restore")), "failed load cancels companion restore retries")
	_expect_follow_presentation(source_mom, "source after failed load")

	var transition_result: Dictionary = loader.call(
		"request_player_scene_transition",
		player,
		DESTINATION_SCENE,
		&"from_realtest1",
		&"companion_animation_test"
	)
	_expect(bool(transition_result.get("accepted", false)), "player transition is accepted")
	await _wait_for_scene(DESTINATION_SCENE)
	await _wait_frames(12)

	var destination_player := get_first_node_in_group(&"player") as Node2D
	var player_spawn := current_scene.get_node_or_null("PlayerSpawnFromYard") as Node2D
	_expect(destination_player != null, "destination recreates the player")
	_expect(player_spawn != null, "destination has its requested player spawn")
	if destination_player != null and player_spawn != null:
		_expect(
			destination_player.global_position.is_equal_approx(player_spawn.global_position),
			"destination player is placed at PlayerSpawnFromYard regardless of sibling ready order"
		)
	var destination_mom := locations.call("get_live_npc", "mom") as Node2D
	_expect(destination_mom != null, "destination recreates Mom")
	_expect(destination_mom != source_mom, "destination uses a fresh Mom instance")
	if destination_mom != null:
		_expect_follow_presentation(destination_mom, "destination")
		var overlays := destination_mom.find_children(
			"TravelFollowDebugOverlay", "NpcFollowDebugOverlay", false, false
		)
		_expect(overlays.is_empty(), "follow path diagnostics stay uninstantiated by default")
		var machine := destination_mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
		var travel_follow := machine.get_state(&"TravelFollow") if machine != null else null
		if travel_follow != null:
			travel_follow.set("show_follow_debug_paths", true)
		await physics_frame
		await physics_frame
		overlays = destination_mom.find_children(
			"TravelFollowDebugOverlay", "NpcFollowDebugOverlay", false, false
		)
		_expect(overlays.size() == 1, "follow path diagnostics can still be enabled on demand")
		await _wait_frames(4)
		_expect_follow_presentation(destination_mom, "settled destination")

	_finish()


func _expect_follow_presentation(mom: Node, label: String) -> void:
	var machine := mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
	var animation_player := mom.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_expect(
		machine != null
		and machine.current_state != null
		and String(machine.current_state.name) == "TravelFollow",
		"%s Mom is in TravelFollow" % label
	)
	_expect(
		animation_player != null
		and animation_player.current_animation == &"run"
		and animation_player.is_playing(),
		"%s Mom keeps the running follow animation" % label
	)


func _wait_for_scene(expected_path: String) -> void:
	for _frame in range(180):
		await process_frame
		if current_scene != null and current_scene.scene_file_path == expected_path:
			return
	_expect(false, "scene transition reaches %s" % expected_path)


func _wait_frames(count: int) -> void:
	for _frame in range(count):
		await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("COMPANION_FOLLOW_SCENE_TRANSITION_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)
