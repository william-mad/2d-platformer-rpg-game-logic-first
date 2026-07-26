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
		"travel context activation clears the prior activity before follow coordination"
	)
	var source_record: Dictionary = locations.call("get_record_snapshot", "mom")
	_expect(
		(source_record.get("action", {}) as Dictionary).is_empty()
		and (source_record.get("activity", {}) as Dictionary).is_empty(),
		"the traveling record contains no stale scheduled action"
	)
	_expect_distance_selected_presentation(source_mom, player, "source")

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
	_expect_distance_selected_presentation(source_mom, player, "source after failed load")

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
		var spawn_settle_offset := destination_player.global_position - player_spawn.global_position
		_expect(
			is_zero_approx(spawn_settle_offset.x)
			and spawn_settle_offset.y >= 0.0
			and spawn_settle_offset.y <= 16.0,
			"destination player uses PlayerSpawnFromYard and only settles vertically onto its floor: player=%s spawn=%s"
			% [destination_player.global_position, player_spawn.global_position]
		)
	var destination_mom := locations.call("get_live_npc", "mom") as Node2D
	_expect(destination_mom != null, "destination recreates Mom")
	_expect(destination_mom != source_mom, "destination uses a fresh Mom instance")
	if destination_mom != null:
		var destination_machine := destination_mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
		var destination_traversal := destination_mom.get_node_or_null(
			"NpcPlatformTraversal"
		) as NpcPlatformTraversal
		_expect(
			destination_machine != null
			and destination_machine.current_state != null
			and String(destination_machine.current_state.name) == "Idle",
			"destination Mom settles into Idle near the companion spawn"
		)
		_expect(
			destination_traversal != null
			and not destination_traversal.has_owner()
			and int(destination_traversal.get_debug_snapshot()["session_serial"]) > 0,
			"scene restoration starts with a fresh unowned traversal context"
		)
		var overlays := destination_mom.find_children(
			"NpcPlatformTraversalDebugOverlay",
			"NpcPlatformTraversalDebugOverlay",
			false,
			false
		)
		_expect(overlays.is_empty(), "follow path diagnostics stay uninstantiated by default")
		var machine := destination_mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
		var travel_follow := machine.get_state(&"TravelFollow") if machine != null else null
		var destination_component := destination_mom.get_node_or_null(
			"TravelCompanion"
		) as TravelCompanionComponent
		if (
			travel_follow != null
			and destination_component != null
			and destination_player != null
		):
			destination_player.global_position.x = (
				destination_mom.global_position.x
				+ destination_component.follow_start_horizontal_distance
				+ 40.0
			)
			destination_component.set("_request_retry_timer", 0.0)
			destination_component.evaluate_follow_need()
			_expect(
				machine.current_state != null
				and String(machine.current_state.name) == "TravelFollow",
				"moving the destination player far activates Follow"
			)
			_expect(
				destination_traversal != null
				and destination_traversal.is_owned_by(
					travel_follow,
					travel_follow.get_traversal_session_id()
				),
				"restored TravelFollow owns its fresh traversal session"
			)
			travel_follow.set("show_follow_debug_paths", true)
		await physics_frame
		await physics_frame
		overlays = destination_mom.find_children(
			"NpcPlatformTraversalDebugOverlay",
			"NpcPlatformTraversalDebugOverlay",
			false,
			false
		)
		_expect(overlays.size() == 1, "follow path diagnostics can still be enabled on demand")
		if destination_component != null and destination_player != null:
			destination_player.global_position = destination_mom.global_position + Vector2(20.0, 0.0)
			destination_component.set("_request_retry_timer", 0.0)
		await _wait_frames(4)
		_expect(
			destination_machine != null
			and destination_machine.current_state != null
			and String(destination_machine.current_state.name) == "Idle",
			"settled destination Mom remains Idle instead of retaining Run"
		)
		_expect(
			destination_traversal != null and not destination_traversal.has_owner(),
			"restored Follow releases traversal after catching up"
		)

	_finish()


func _expect_distance_selected_presentation(mom: Node, player: Node2D, label: String) -> void:
	var machine := mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
	var animation_player := mom.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var animation_controller := mom.get_node_or_null(
		"NpcAnimationController"
	) as NpcAnimationController
	var component := mom.get_node_or_null("TravelCompanion") as TravelCompanionComponent
	var expected_state := "TravelFollow"
	if component != null and player != null:
		var horizontal_distance := absf(player.global_position.x - (mom as Node2D).global_position.x)
		var vertical_separation := absf(player.global_position.y - (mom as Node2D).global_position.y)
		if (
			horizontal_distance <= component.follow_start_horizontal_distance
			and vertical_separation <= component.follow_start_vertical_separation
		):
			expected_state = "Idle"
	_expect(
		machine != null
		and machine.current_state != null
		and String(machine.current_state.name) == expected_state,
		"%s Mom selects %s from companion distance" % [label, expected_state]
	)
	if expected_state == "TravelFollow":
		_expect(
			animation_controller != null
			and animation_controller.get_latest_requested_animation() == &"run"
			and animation_player != null
			and animation_player.current_animation in [&"idle", &"walk", &"run_start", &"run"]
			and animation_player.is_playing(),
			"%s Mom preserves Run intent with grounded locomotion presentation: state=%s animation=%s playing=%s velocity=%s"
			% [
				label,
				expected_state,
				String(animation_player.current_animation) if animation_player != null else "missing",
				animation_player.is_playing() if animation_player != null else false,
				(mom as CharacterBody2D).velocity if mom is CharacterBody2D else Vector2.ZERO,
			]
		)
	else:
		_expect(
			animation_controller != null
			and animation_controller.get_latest_requested_animation() == &"idle"
			and animation_player != null
			and animation_player.current_animation == &"idle",
			"%s Mom uses the idle animation while caught up" % label
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
