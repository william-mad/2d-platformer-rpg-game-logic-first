extends SceneTree

const AnimationControllerScript = preload("res://scenes/creatures/npc/npc_animation_controller.gd")
const StateMachineScript = preload("res://scenes/creatures/npc/npc_state_machine.gd")
const WorkStateScript = preload("res://scenes/creatures/npc/states/work.gd")

var _failures: Array[String] = []


class TestNpc:
	extends CharacterBody2D

	var direction: int = 1


class TestLocomotionController:
	extends NpcAnimationController

	var sampled_horizontal_speed: float = 0.0
	var test_grounded: bool = true

	func _get_actual_horizontal_speed() -> float:
		return sampled_horizontal_speed

	func _is_grounded_for_locomotion() -> bool:
		return test_grounded


class WorkSpot:
	extends Node2D

	func can_serve_npc_need(
		_npc: Node2D,
		_requested_state: StringName,
		_requested_value: StringName = &""
	) -> bool:
		return true

	func has_work_needed() -> bool:
		return true

	func get_routine_task_animation_name() -> StringName:
		return &"meal_prep_1"


func _initialize() -> void:
	await process_frame
	_test_controller_resolution_and_facing()
	_test_fixed_unflipped_activity_facing()
	_test_grounded_locomotion_phases_and_cleanup()
	_test_missing_locomotion_clips_fail_soft()
	_test_work_entry_plays_only_resolved_clip()
	_test_placeholder_rejection_is_latched()
	_test_complex_scene_wiring_and_mom_tracks()
	await _test_mom_follow_animation_after_scene_recreation()
	await process_frame

	if _failures.is_empty():
		print("NPC animation controller runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_controller_resolution_and_facing() -> void:
	var setup := _make_animated_npc()
	var npc: TestNpc = setup["npc"]
	var player: AnimationPlayer = setup["player"]
	var controller: NpcAnimationController = setup["controller"]
	var sprite: Sprite2D = setup["sprite"]
	var tracked_animation: Animation = setup["tracked_animation"]

	_expect(
		not controller.grounded_locomotion_enabled,
		"grounded locomotion is opt-in and disabled for existing NPC controllers"
	)
	_expect(
		controller.request_animation(&"work"),
		"semantic work request is accepted through the alias map"
	)
	_expect(player.current_animation == &"work_1", "work alias resolves to the available character clip")
	_expect(
		not controller.request_animation(&"missing_required_clip"),
		"missing required clip reports rejected playback"
	)
	_expect(controller.face_x_direction(-1.0), "controller accepts horizontal facing")
	_expect(npc.direction == -1, "controller owns the NPC direction value")
	_expect(sprite.flip_h, "controller owns Sprite2D.flip_h")
	_expect(
		not tracked_animation.track_is_enabled(0),
		"controller disables animation tracks that compete for flip_h"
	)
	npc.velocity.x = 161.0
	_expect(
		is_zero_approx(controller._get_actual_horizontal_speed()),
		"locomotion samples real movement instead of unachieved commanded velocity"
	)
	npc.queue_free()


func _test_fixed_unflipped_activity_facing() -> void:
	var setup := _make_animated_npc()
	var npc: TestNpc = setup["npc"]
	var player: AnimationPlayer = setup["player"]
	var controller: NpcAnimationController = setup["controller"]
	var sprite: Sprite2D = setup["sprite"]
	controller.force_unflipped_animation_names = PackedStringArray([
		"meal_prep_1",
		"work_1",
	])

	controller.face_x_direction(-1.0)
	_expect(sprite.flip_h, "ordinary presentation can still face left")
	_expect(controller.request_animation(&"meal_prep_1"), "meal-prep presentation starts")
	_expect(
		not sprite.flip_h,
		"starting meal prep restores its authored unflipped orientation"
	)
	controller.face_x_direction(-1.0)
	_expect(
		not sprite.flip_h,
		"facing updates do not invert a protected meal-prep presentation"
	)

	_expect(controller.request_animation(&"talk"), "Talk presentation starts normally")
	controller.face_x_direction(-1.0)
	_expect(
		player.current_animation == &"talk" and sprite.flip_h,
		"Talk remains free to flip toward its partner"
	)
	npc.queue_free()


func _test_grounded_locomotion_phases_and_cleanup() -> void:
	var setup := _make_locomotion_npc(true, true, true)
	var npc: TestNpc = setup["npc"]
	var player: AnimationPlayer = setup["player"]
	var controller: TestLocomotionController = setup["controller"]
	var started: Array[StringName] = []
	player.animation_started.connect(func(animation_name: StringName) -> void:
		started.append(animation_name)
	)

	controller.sampled_horizontal_speed = 77.0
	_expect(controller.request_animation(&"walk"), "walking request activates locomotion")
	_expect(
		player.current_animation == &"walk"
		and controller.get_locomotion_phase() == NpcAnimationController.LocomotionPhase.WALK,
		"walking speed displays the Walk loop"
	)
	_expect(
		is_equal_approx(player.speed_scale, 1.0),
		"Walk playback matches its reference speed"
	)

	controller.sampled_horizontal_speed = 130.0
	controller._post_movement_animation_update(1.0 / 60.0)
	_expect(
		player.current_animation == &"run_start"
		and controller.get_locomotion_phase() == NpcAnimationController.LocomotionPhase.RUN_START,
		"crossing the run-enter threshold starts RunStart"
	)
	var run_start_count := started.count(&"run_start")
	controller.request_animation(&"run")
	controller.request_animation(&"walk")
	controller._post_movement_animation_update(1.0 / 60.0)
	_expect(
		started.count(&"run_start") == run_start_count,
		"repeated Walk and Run requests do not restart RunStart"
	)

	controller._on_animation_finished(&"run_start")
	_expect(
		player.current_animation == &"run"
		and controller.get_locomotion_phase() == NpcAnimationController.LocomotionPhase.RUN,
		"finishing RunStart enters the Run loop while speed stays high"
	)

	controller.sampled_horizontal_speed = 90.0
	controller._post_movement_animation_update(1.0 / 60.0)
	_expect(
		player.current_animation == &"walk"
		and controller.get_locomotion_phase() == NpcAnimationController.LocomotionPhase.WALK,
		"dropping below run-exit returns directly to Walk"
	)

	controller.sampled_horizontal_speed = 0.0
	controller._post_movement_animation_update(1.0 / 60.0)
	var idle_start_count := started.count(&"idle")
	controller._post_movement_animation_update(1.0 / 60.0)
	_expect(
		player.current_animation == &"idle"
		and controller.get_locomotion_phase() == NpcAnimationController.LocomotionPhase.NONE,
		"stopping locomotion displays Idle"
	)
	_expect(
		started.count(&"idle") == idle_start_count,
		"staying stopped does not restart Idle every frame"
	)
	_expect(is_equal_approx(player.speed_scale, 1.0), "Idle resets shared playback speed")

	controller.sampled_horizontal_speed = 77.0
	controller.request_animation(&"walk")
	controller.sampled_horizontal_speed = 1000.0
	controller._post_movement_animation_update(1.0 / 60.0)
	_expect(
		is_equal_approx(player.speed_scale, controller.run_start_max_speed_scale),
		"RunStart playback remains inside its narrow maximum clamp"
	)
	controller._on_animation_finished(&"run_start")
	_expect(
		is_equal_approx(player.speed_scale, controller.run_max_speed_scale),
		"extreme catch-up speed clamps the Run loop"
	)

	_expect(controller.request_animation(&"talk"), "non-locomotion request interrupts Run")
	_expect(
		player.current_animation == &"talk"
		and controller.get_locomotion_phase() == NpcAnimationController.LocomotionPhase.NONE,
		"Talk immediately releases grounded locomotion ownership"
	)
	_expect(
		is_equal_approx(player.speed_scale, 1.0),
		"Talk cannot inherit the Run playback scale"
	)
	npc.queue_free()


func _test_missing_locomotion_clips_fail_soft() -> void:
	var no_start_setup := _make_locomotion_npc(true, false, true)
	var no_start_npc: TestNpc = no_start_setup["npc"]
	var no_start_player: AnimationPlayer = no_start_setup["player"]
	var no_start_controller: TestLocomotionController = no_start_setup["controller"]
	no_start_controller.sampled_horizontal_speed = 77.0
	_expect(no_start_controller.request_animation(&"walk"), "Walk works without RunStart")
	no_start_controller.sampled_horizontal_speed = 130.0
	no_start_controller._post_movement_animation_update(1.0 / 60.0)
	_expect(
		no_start_player.current_animation == &"run",
		"missing RunStart falls through directly to Run"
	)
	no_start_npc.queue_free()

	var no_run_setup := _make_locomotion_npc(true, true, false)
	var no_run_npc: TestNpc = no_run_setup["npc"]
	var no_run_player: AnimationPlayer = no_run_setup["player"]
	var no_run_controller: TestLocomotionController = no_run_setup["controller"]
	no_run_controller.sampled_horizontal_speed = 130.0
	_expect(no_run_controller.request_animation(&"run"), "missing Run accepts Walk fallback")
	_expect(
		no_run_player.current_animation == &"walk"
		and no_run_controller.get_locomotion_phase() == NpcAnimationController.LocomotionPhase.WALK,
		"missing Run remains on the clamped Walk loop"
	)
	no_run_npc.queue_free()

	var no_walk_setup := _make_locomotion_npc(false, true, true)
	var no_walk_npc: TestNpc = no_walk_setup["npc"]
	var no_walk_player: AnimationPlayer = no_walk_setup["player"]
	var no_walk_controller: TestLocomotionController = no_walk_setup["controller"]
	no_walk_controller.sampled_horizontal_speed = 130.0
	_expect(
		not no_walk_controller.request_animation(&"run"),
		"missing required Walk rejects grounded locomotion safely"
	)
	_expect(
		is_equal_approx(no_walk_player.speed_scale, 1.0),
		"failed locomotion request leaves shared playback speed clean"
	)
	no_walk_npc.queue_free()


func _test_work_entry_plays_only_resolved_clip() -> void:
	var setup := _make_animated_npc()
	var npc: TestNpc = setup["npc"]
	var player: AnimationPlayer = setup["player"]
	var controller: NpcAnimationController = setup["controller"]
	controller.animation_aliases = {"work": "work_1"}

	var machine := StateMachineScript.new() as NpcStateMachine
	machine.name = "NpcStateMachine"
	machine.active = false
	var work := WorkStateScript.new() as NpcStateWork
	work.name = "Work"
	work.animation_name = &"work"
	work.stop_horizontal_on_enter = true
	var idle := NpcState.new()
	idle.name = "Idle"
	machine.add_child(work)
	machine.add_child(idle)
	npc.add_child(machine)
	machine.bind_npc(npc)
	machine.initialize_states()

	var spot := WorkSpot.new()
	spot.name = "WorkSpot"
	npc.add_child(spot)
	machine.work_target = spot
	var started: Array[StringName] = []
	player.animation_started.connect(func(animation_name: StringName) -> void:
		started.append(animation_name)
	)
	player.stop()
	work.enter()

	_expect(player.current_animation == &"meal_prep_1", "Work resolves the spot-specific clip before playback")
	_expect(started.size() == 1, "Work entry sends one animation request")
	if started.size() == 1:
		_expect(started[0] == &"meal_prep_1", "Work does not play generic work before the spot clip")
	npc.queue_free()


func _test_placeholder_rejection_is_latched() -> void:
	var npc := TestNpc.new()
	npc.name = "PlaceholderNpc"
	root.add_child(npc)
	var controller := AnimationControllerScript.new() as NpcAnimationController
	controller.name = "NpcAnimationController"
	npc.add_child(controller)
	controller.bind_npc(npc)
	_expect(not controller.request_animation(&"idle"), "placeholder without AnimationPlayer rejects playback")
	_expect(not controller.request_animation(&"idle"), "repeated placeholder request remains safely rejected")
	_expect(
		bool(controller.get("_warned_missing_animation_player")),
		"placeholder latches its missing-player development warning"
	)
	npc.queue_free()


func _test_complex_scene_wiring_and_mom_tracks() -> void:
	var stateful_scene := load("res://scenes/creatures/npc/stateful_social_npc.tscn") as PackedScene
	var stateful := stateful_scene.instantiate()
	_expect(
		stateful.get_node_or_null("NpcAnimationController") != null,
		"generic StatefulSocialNpc explicitly contains an animation controller"
	)
	stateful.free()

	var mom_scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := mom_scene.instantiate()
	_expect(mom.get_node_or_null("NpcAnimationController") != null, "Mom contains an animation controller")
	var mom_controller := mom.get_node_or_null("NpcAnimationController") as NpcAnimationController
	_expect(
		mom_controller != null and mom_controller.grounded_locomotion_enabled,
		"Mom opts into reusable grounded locomotion"
	)
	_expect(
		mom_controller != null
		and is_equal_approx(mom_controller.walk_min_speed_scale, 0.6)
		and is_equal_approx(mom_controller.walk_max_speed_scale, 1.6),
		"Mom uses the widened 0.60-1.60 Walk playback range"
	)
	var player := mom.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var enabled_flip_tracks := 0
	if player != null:
		_validate_mom_locomotion_clip(
			player,
			&"walk",
			"walk_1_mom.png",
			Animation.LOOP_LINEAR,
			0.8333333
		)
		_validate_mom_locomotion_clip(
			player,
			&"run_start",
			"run_start_1_mom.png",
			Animation.LOOP_NONE,
			0.5
		)
		_validate_mom_locomotion_clip(
			player,
			&"run",
			"run_1_mom.png",
			Animation.LOOP_LINEAR,
			0.75
		)
		var visited: Dictionary = {}
		for animation_name in player.get_animation_list():
			var animation := player.get_animation(animation_name)
			if animation == null or visited.has(animation.get_instance_id()):
				continue
			visited[animation.get_instance_id()] = true
			for track_index in animation.get_track_count():
				if (
					String(animation.track_get_path(track_index)).ends_with(":flip_h")
					and animation.track_is_enabled(track_index)
				):
					enabled_flip_tracks += 1
	_expect(enabled_flip_tracks == 0, "Mom has no enabled animation track writing Sprite2D.flip_h")
	mom.free()


func _test_mom_follow_animation_after_scene_recreation() -> void:
	var runtime := root.get_node_or_null("PlayerRuntime")
	_expect(runtime != null, "PlayerRuntime is available for companion animation validation")
	if runtime == null:
		return
	var original_travel_session: Dictionary = runtime.get("travel_session").duplicate(true)
	runtime.set("travel_session", {
		"active": true,
		"companion_npc_id": "mom",
		"origin_scene_path": "res://scene_transition_animation_source.tscn",
		"origin_spawn_id": "from_companion_route",
		"destination_scene_path": "res://scene_transition_animation_destination.tscn",
		"departure_total_hours": 0.0,
		"travel_policy_id": "default_companion",
		"ending": false,
	})

	var mom_scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := mom_scene.instantiate()
	var travel_target := Node2D.new()
	travel_target.name = "AnimationTestTravelTarget"
	travel_target.global_position = Vector2(300.0, 0.0)
	root.add_child(travel_target)
	travel_target.add_to_group(&"player")
	var authored_follow := mom.get_node_or_null("NpcStateMachine/TravelFollow")
	if authored_follow != null:
		authored_follow.set("show_follow_debug_paths", true)
	root.add_child(mom)
	await process_frame
	runtime.call("_activate_live_companion_context", mom, travel_target, true)
	await process_frame

	var machine := mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
	var player := mom.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var controller := mom.get_node_or_null("NpcAnimationController") as NpcAnimationController
	_expect(
		machine != null and machine.current_state != null and String(machine.current_state.name) == "TravelFollow",
		"a recreated active companion enters TravelFollow immediately"
	)
	_expect(
		controller != null and controller.get_latest_requested_animation() == &"run",
		"TravelFollow preserves its logical Run request"
	)
	_expect(
		player != null and player.current_animation == &"idle" and player.is_playing(),
		"a stopped companion uses locomotion Idle instead of faking movement"
	)

	# PlayerRuntime may repeat context activation after the destination player and
	# NPC registry settle. It must not leave the already-active follow state
	# displaying an autoplayed idle clip.
	var request_failure_count := 0
	if machine != null:
		machine.state_request_failed.connect(func(_state_name: StringName, _reason: String) -> void:
			request_failure_count += 1
		)
	var history_size := machine.state_history.size() if machine != null else -1
	var animation_before_reactivation := player.current_animation if player != null else &""
	var animation_position_before_reactivation := (
		player.current_animation_position if player != null else -1.0
	)
	runtime.call("_activate_live_companion_context", mom, travel_target, false)
	runtime.call("_activate_live_companion_context", mom, travel_target, false)
	_expect(
		controller != null
		and controller.get_latest_requested_animation() == &"run"
		and player != null
		and player.current_animation == animation_before_reactivation
		and is_equal_approx(
			player.current_animation_position,
			animation_position_before_reactivation
		),
		"repeated context activation preserves Run intent without restarting presentation"
	)
	await process_frame
	_expect(
		controller != null
		and controller.get_latest_requested_animation() == &"run"
		and player != null
		and player.current_animation in [&"idle", &"walk", &"run_start", &"run"]
		and player.is_playing(),
		"post-movement presentation remains within the grounded locomotion set"
	)
	_expect(request_failure_count == 0, "repeated follow activation emits no state rejection")
	_expect(
		machine != null and machine.state_history.size() == history_size,
		"repeated follow activation does not re-enter or duplicate TravelFollow"
	)
	await physics_frame
	await process_frame
	var overlays := mom.find_children(
		"NpcPlatformTraversalDebugOverlay", "NpcPlatformTraversalDebugOverlay", false, false
	)
	var traversal := mom.get_node_or_null("NpcPlatformTraversal") as NpcPlatformTraversal
	_expect(
		overlays.size() == 1,
		"initial TravelFollow can attach one opt-in debug overlay after ready: follow_session=%s traversal=%s"
		% [
			authored_follow.get_traversal_session_id() if authored_follow != null else -1,
			traversal.get_debug_snapshot() if traversal != null else {},
		]
	)

	mom.queue_free()
	travel_target.queue_free()
	await process_frame
	runtime.set("travel_session", original_travel_session)

	var idle_mom := mom_scene.instantiate()
	idle_mom.set("location_id", &"")
	root.add_child(idle_mom)
	await process_frame
	var idle_machine := idle_mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
	var idle_player := idle_mom.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_expect(
		idle_machine != null
		and idle_machine.current_state != null
		and String(idle_machine.current_state.name) == "Idle",
		"a normal recreated Mom still enters Idle"
	)
	_expect(
		idle_player != null and idle_player.current_animation == &"idle" and idle_player.is_playing(),
		"the state machine still starts Mom's idle animation without scene autoplay"
	)
	idle_mom.queue_free()
	await process_frame


func _validate_mom_locomotion_clip(
	player: AnimationPlayer,
	animation_name: StringName,
	expected_texture_file: String,
	expected_loop_mode: int,
	expected_length: float
) -> void:
	_expect(player.has_animation(animation_name), "Mom contains canonical %s animation" % animation_name)
	if not player.has_animation(animation_name):
		return
	var animation := player.get_animation(animation_name)
	_expect(
		animation.loop_mode == expected_loop_mode,
		"Mom %s has the expected loop mode" % animation_name
	)
	_expect(
		is_equal_approx(animation.length, expected_length),
		"Mom %s has the expected authored duration" % animation_name
	)

	var texture: Texture2D
	var hframes := 0
	var vframes := 0
	var sprite_position := Vector2.ZERO
	var frame_values: Array[int] = []
	var frame_track_is_discrete := false
	for track_index in animation.get_track_count():
		var track_path := String(animation.track_get_path(track_index))
		match track_path:
			"Sprite2D:texture":
				texture = animation.track_get_key_value(track_index, 0) as Texture2D
			"Sprite2D:hframes":
				hframes = int(animation.track_get_key_value(track_index, 0))
			"Sprite2D:vframes":
				vframes = int(animation.track_get_key_value(track_index, 0))
			"Sprite2D:position":
				sprite_position = animation.track_get_key_value(track_index, 0) as Vector2
			"Sprite2D:frame":
				frame_track_is_discrete = (
					animation.value_track_get_update_mode(track_index) == Animation.UPDATE_DISCRETE
					and animation.track_get_interpolation_type(track_index)
					== Animation.INTERPOLATION_NEAREST
				)
				for key_index in animation.track_get_key_count(track_index):
					frame_values.append(
						int(animation.track_get_key_value(track_index, key_index))
					)

	_expect(
		texture != null and texture.resource_path.ends_with("/%s" % expected_texture_file),
		"Mom %s uses %s" % [animation_name, expected_texture_file]
	)
	_expect(
		hframes == 6 and vframes == 1,
		"Mom %s uses one row of six 100x200 frames" % animation_name
	)
	_expect(
		sprite_position == Vector2(1.0, -101.0),
		"Mom %s preserves the locomotion feet baseline" % animation_name
	)
	_expect(
		frame_values == [0, 1, 2, 3, 4, 5],
		"Mom %s plays all six frames once per cycle" % animation_name
	)
	_expect(
		frame_track_is_discrete,
		"Mom %s uses discrete nearest-neighbor frame updates" % animation_name
	)


func _make_locomotion_npc(
	include_walk: bool,
	include_run_start: bool,
	include_run: bool
) -> Dictionary:
	var npc := TestNpc.new()
	npc.name = "LocomotionNpc"
	root.add_child(npc)
	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	npc.add_child(sprite)
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	npc.add_child(player)
	var library := AnimationLibrary.new()
	_add_animation(library, &"idle")
	_add_animation(library, &"talk")
	_add_animation(library, &"work")
	if include_walk:
		_add_animation(library, &"walk", Animation.LOOP_LINEAR)
	if include_run_start:
		_add_animation(library, &"run_start")
	if include_run:
		_add_animation(library, &"run", Animation.LOOP_LINEAR)
	player.add_animation_library(&"", library)

	var controller := TestLocomotionController.new()
	controller.name = "NpcAnimationController"
	controller.grounded_locomotion_enabled = true
	npc.add_child(controller)
	controller.bind_npc(npc)
	return {
		"npc": npc,
		"sprite": sprite,
		"player": player,
		"controller": controller,
	}


func _make_animated_npc() -> Dictionary:
	var npc := TestNpc.new()
	npc.name = "AnimatedNpc"
	root.add_child(npc)
	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	npc.add_child(sprite)
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	npc.add_child(player)
	var library := AnimationLibrary.new()
	_add_animation(library, &"work_1")
	_add_animation(library, &"meal_prep_1")
	_add_animation(library, &"talk")
	var tracked := Animation.new()
	tracked.length = 1.0
	var track_index := tracked.add_track(Animation.TYPE_VALUE)
	tracked.track_set_path(track_index, NodePath("Sprite2D:flip_h"))
	tracked.track_insert_key(track_index, 0.0, false)
	library.add_animation(&"tracked", tracked)
	player.add_animation_library(&"", library)
	var controller := AnimationControllerScript.new() as NpcAnimationController
	controller.name = "NpcAnimationController"
	controller.animation_aliases = {"work": "work_1"}
	npc.add_child(controller)
	controller.bind_npc(npc)
	return {
		"npc": npc,
		"sprite": sprite,
		"player": player,
		"controller": controller,
		"tracked_animation": tracked,
	}


func _add_animation(
	library: AnimationLibrary,
	animation_name: StringName,
	loop_mode: int = Animation.LOOP_NONE
) -> void:
	var animation := Animation.new()
	animation.length = 1.0
	animation.loop_mode = loop_mode
	library.add_animation(animation_name, animation)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
