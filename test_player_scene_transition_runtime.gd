extends SceneTree

const DESTINATION_A := "res://transaction_test_destination_a.tscn"
const DESTINATION_B := "res://transaction_test_destination_b.tscn"
const FAILED_DESTINATION := "res://transaction_test_failed_destination.tscn"
const MISSING_SPAWN_DESTINATION := "res://transaction_test_missing_spawn.tscn"

var _failures: Array[String] = []


class TestPlayer:
	extends Node2D

	var saved_value: int = 0
	var gameplay_claimed: bool = false
	var gameplay_claim_token: int = 0
	var input_poll_count: int = 0

	func _ready() -> void:
		add_to_group(&"player")
		var gameplay_flow := get_node_or_null("/root/GameplayFlow")
		if gameplay_flow != null:
			gameplay_flow.player_control_claim_changed.connect(_on_player_control_claim_changed)
		call_deferred("_apply_pending_runtime")

	func _apply_pending_runtime() -> void:
		var scene_root := get_parent()
		if scene_root != null:
			for sibling in scene_root.get_children():
				if sibling.has_method("get_spawn_id"):
					sibling.add_to_group(&"player_spawn")
		var runtime := get_node_or_null("/root/PlayerRuntime")
		if runtime != null:
			runtime.call("apply_to_player", self)

	func _process(_delta: float) -> void:
		if not gameplay_claimed:
			input_poll_count += 1

	func can_accept_player_control_claim(control_mode: StringName) -> Dictionary:
		if control_mode != &"ui_only":
			return {"accepted": false, "reason": "unknown_control_mode"}
		if gameplay_claimed:
			return {"accepted": false, "reason": "already_control_claimed"}
		return {"accepted": true, "reason": ""}

	func get_save_data() -> Dictionary:
		return {"saved_value": saved_value}

	func apply_save_data(data: Dictionary) -> void:
		saved_value = int(data.get("saved_value", 0))

	func _on_player_control_claim_changed(
		player: Node, claimed: bool, token_id: int
	) -> void:
		if player != self:
			return
		gameplay_claimed = claimed
		gameplay_claim_token = token_id if claimed else 0


class TestNpc:
	extends Node2D

	var npc_id: StringName = &"permission_test_npc"

	func get_npc_location_id() -> StringName:
		return npc_id


func _initialize() -> void:
	await process_frame
	var loader := root.get_node_or_null("SceneLoader")
	var runtime := root.get_node_or_null("PlayerRuntime")
	var gameplay_flow := root.get_node_or_null("GameplayFlow")
	if loader == null or runtime == null or gameplay_flow == null:
		push_error("Player scene transition runtime test requires transition autoloads.")
		quit(1)
		return

	var original_cache: Dictionary = loader.cached_scenes.duplicate()
	var original_preloads: Dictionary = loader.pending_preload_paths.duplicate()
	var original_use_threaded: bool = loader.use_threaded_loading
	var original_show_overlay: bool = loader.show_loading_overlay
	var original_scene := current_scene
	var simulator := root.get_node_or_null("NpcWorldSimulation")
	var simulator_was_processing := simulator != null and simulator.is_processing()
	if simulator != null:
		simulator.set_process(false)

	runtime.call("clear_pending_player_transfer")
	loader.cached_scenes[DESTINATION_A] = _make_destination(
		"DestinationA", &"spawn_a", Vector2(120.0, 45.0), Vector2.ZERO
	)
	loader.cached_scenes[DESTINATION_B] = _make_destination(
		"DestinationB", &"spawn_b", Vector2(-80.0, 30.0), Vector2.ZERO
	)
	loader.cached_scenes[FAILED_DESTINATION] = null
	loader.cached_scenes[MISSING_SPAWN_DESTINATION] = _make_destination(
		"MissingSpawnDestination", &"different_spawn", Vector2(90.0, 90.0), Vector2(17.0, 19.0)
	)
	loader.use_threaded_loading = true
	loader.show_loading_overlay = true

	var source := Node2D.new()
	source.name = "TransitionTestSource"
	root.add_child(source)
	current_scene = source
	var player := TestPlayer.new()
	player.name = "Player"
	player.saved_value = 37
	source.add_child(player)
	await process_frame

	var first_door := DoorTransition.new()
	first_door.name = "FocusedDoorTransition"
	first_door.target_scene_path = DESTINATION_A
	first_door.target_spawn_id = &"spawn_a"
	first_door.active_player = player
	first_door.player_inside = true
	source.add_child(first_door)
	first_door.load_target_scene()
	_expect(first_door.player_transition_accepted, "DoorTransition accepts the first request")
	_expect(player.gameplay_claimed, "accepted transition suppresses player gameplay input")
	_expect(bool(gameplay_flow.call("is_world_progression_locked")), "accepted transition locks world progression")
	_expect(loader.visible, "loading overlay is visible only after acceptance")
	var first_status: Dictionary = loader.call("get_debug_status").get("player_transition", {})
	_expect(String(first_status.get("target_scene", "")) == DESTINATION_A, "debug status exposes target scene")
	_expect(String(first_status.get("target_spawn", "")) == "spawn_a", "debug status exposes target spawn")
	_expect(int(first_status.get("world_lock_token", 0)) != 0, "debug status exposes world token")
	_expect(int(first_status.get("player_claim_token", 0)) != 0, "debug status exposes player token")

	var competing_door := NpcTravelDoor.new()
	competing_door.name = "CompetingNpcTravelDoor"
	competing_door.target_scene_path = DESTINATION_B
	competing_door.target_spawn_id = &"spawn_b"
	competing_door.active_player = player
	competing_door.player_inside = true
	source.add_child(competing_door)
	competing_door.load_target_scene()
	_expect(not competing_door.player_transition_accepted, "second door request is rejected while loading")
	_expect(runtime.pending_target_spawn_id == &"spawn_a", "rejected request cannot overwrite pending transfer")
	_expect(String(loader.loading_scene_path) == DESTINATION_A, "rejected request cannot replace active load")

	await _wait_for_scene("DestinationA")
	var destination_player := _get_current_test_player()
	_expect(destination_player != null, "DoorTransition changes to its destination scene")
	if destination_player != null:
		_expect(destination_player.saved_value == 37, "destination player consumes captured runtime data")
		_expect(destination_player.global_position == Vector2(120.0, 45.0), "destination player uses target spawn")
	_expect(not bool(gameplay_flow.call("is_world_progression_locked")), "successful transition releases world lock")
	_expect(loader.active_player_transition.is_empty(), "successful transition clears transaction state")
	_expect(not runtime.call("has_pending_player_data"), "destination consumes pending player data")

	var npc_door := NpcTravelDoor.new()
	npc_door.name = "FocusedNpcTravelDoor"
	npc_door.target_scene_path = DESTINATION_B
	npc_door.target_spawn_id = &"spawn_b"
	npc_door.active_player = destination_player
	npc_door.player_inside = true
	current_scene.add_child(npc_door)
	var permission_npc := TestNpc.new()
	permission_npc.npc_id = &"allowed_npc"
	permission_npc.add_to_group(&"resident")
	current_scene.add_child(permission_npc)
	npc_door.allowed_npc_ids = [&"allowed_npc"]
	npc_door.required_npc_tags = [&"resident"]
	_expect(npc_door.can_npc_use(permission_npc), "live NPC permission API remains reusable")
	_expect(not npc_door.can_npc_id_use(&"allowed_npc"), "ID-only permission API still conservatively rejects tag gates")
	_expect(npc_door.cooldowns.is_empty(), "player transition does not touch NPC cooldowns")
	npc_door.load_target_scene()
	_expect(npc_door.player_transition_accepted, "NpcTravelDoor player path accepts transaction")
	await _wait_for_scene("DestinationB")
	destination_player = _get_current_test_player()
	_expect(destination_player != null, "NpcTravelDoor changes only its player to the destination")
	if destination_player != null:
		_expect(destination_player.global_position == Vector2(-80.0, 30.0), "NpcTravelDoor uses target spawn")
	_expect(not bool(gameplay_flow.call("is_world_progression_locked")), "NpcTravelDoor success releases world lock")

	var failed_door := DoorTransition.new()
	failed_door.name = "FailedDoorTransition"
	failed_door.target_scene_path = FAILED_DESTINATION
	failed_door.target_spawn_id = &"failed_spawn"
	failed_door.active_player = destination_player
	failed_door.player_inside = true
	current_scene.add_child(failed_door)
	var scene_before_failure := current_scene
	failed_door.load_target_scene()
	_expect(failed_door.player_transition_accepted, "load failure test begins after validation")
	await _wait_for_loader_idle()
	_expect(current_scene == scene_before_failure, "failed load leaves player in original scene")
	_expect(not failed_door.player_transition_accepted, "failed load permits a later retry")
	_expect(not runtime.call("has_pending_player_data"), "failed load clears pending player data")
	_expect(runtime.pending_target_spawn_id == &"", "failed load clears pending spawn")
	_expect(not bool(gameplay_flow.call("is_world_progression_locked")), "failed load releases world lock")
	if destination_player != null:
		_expect(not destination_player.gameplay_claimed, "failed load restores player controls")

	var invalid_door := DoorTransition.new()
	invalid_door.name = "InvalidDoorTransition"
	invalid_door.target_scene_path = "res://definitely_missing_transition_scene.tscn"
	invalid_door.target_spawn_id = &"invalid_spawn"
	invalid_door.active_player = destination_player
	invalid_door.player_inside = true
	current_scene.add_child(invalid_door)
	invalid_door.load_target_scene()
	_expect(not invalid_door.player_transition_accepted, "unavailable scene rejects before mutation")
	_expect(current_scene == scene_before_failure, "unavailable scene does not change scene")
	_expect(not runtime.call("has_pending_player_data"), "unavailable scene creates no pending transfer")
	_expect(not loader.visible, "rejected transition does not show loading overlay")

	var missing_spawn_door := DoorTransition.new()
	missing_spawn_door.name = "MissingSpawnDoorTransition"
	missing_spawn_door.target_scene_path = MISSING_SPAWN_DESTINATION
	missing_spawn_door.target_spawn_id = &"missing_spawn"
	missing_spawn_door.active_player = destination_player
	missing_spawn_door.player_inside = true
	current_scene.add_child(missing_spawn_door)
	missing_spawn_door.load_target_scene()
	_expect(missing_spawn_door.player_transition_accepted, "missing spawn does not reject valid scene load")
	await _wait_for_scene("MissingSpawnDestination")
	var fallback_player := _get_current_test_player()
	_expect(fallback_player != null, "missing-spawn scene still creates its player")
	if fallback_player != null:
		_expect(fallback_player.global_position == Vector2(17.0, 19.0), "missing spawn preserves authored fallback position")
	_expect(not bool(gameplay_flow.call("is_world_progression_locked")), "missing-spawn success releases tokens")

	runtime.call("clear_pending_player_transfer")
	loader.cached_scenes = original_cache
	loader.pending_preload_paths = original_preloads
	loader.use_threaded_loading = original_use_threaded
	loader.show_loading_overlay = original_show_overlay
	if simulator != null:
		simulator.set_process(simulator_was_processing)
	if current_scene != null and current_scene != original_scene:
		current_scene.queue_free()
	current_scene = original_scene
	await process_frame

	if _failures.is_empty():
		print("PLAYER_SCENE_TRANSITION_RUNTIME_OK")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _make_destination(
	scene_name: String,
	spawn_id: StringName,
	spawn_position: Vector2,
	player_position: Vector2
) -> PackedScene:
	var scene_root := Node2D.new()
	scene_root.name = scene_name
	var spawn := PlayerSpawn.new()
	spawn.name = "PlayerSpawn"
	spawn.spawn_id = spawn_id
	spawn.position = spawn_position
	spawn.add_to_group(&"player_spawn", true)
	scene_root.add_child(spawn)
	spawn.owner = scene_root
	var player := TestPlayer.new()
	player.name = "Player"
	player.position = player_position
	scene_root.add_child(player)
	player.owner = scene_root
	var packed := PackedScene.new()
	_expect(packed.pack(scene_root) == OK, "%s packs for transition validation" % scene_name)
	scene_root.free()
	return packed


func _wait_for_scene(expected_name: String) -> void:
	for _frame in range(20):
		await process_frame
		if current_scene != null and current_scene.name == expected_name:
			return
	_expect(false, "scene transition reaches %s" % expected_name)


func _wait_for_loader_idle() -> void:
	var loader := root.get_node_or_null("SceneLoader")
	for _frame in range(20):
		await process_frame
		if loader != null and not loader.loading_in_progress:
			return
	_expect(false, "failed scene load returns loader to idle")


func _get_current_test_player() -> TestPlayer:
	if current_scene == null:
		return null
	return current_scene.get_node_or_null("Player") as TestPlayer


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
