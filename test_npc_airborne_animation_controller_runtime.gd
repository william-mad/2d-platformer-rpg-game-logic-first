extends SceneTree

var _failures: Array[String] = []


class TestNpc:
	extends CharacterBody2D

	var direction: int = 1


class TestAirborneLocomotionController:
	extends NpcAirborneAnimationController

	var sampled_horizontal_speed: float = 0.0
	var test_grounded: bool = true

	func _get_actual_horizontal_speed() -> float:
		return sampled_horizontal_speed

	func _is_grounded_for_locomotion() -> bool:
		return test_grounded


func _initialize() -> void:
	await process_frame
	_test_velocity_driven_airborne_frames_and_resume()
	_test_mom_airborne_wiring_and_placeholder_frames()
	await _test_mom_damage_hop_uses_and_restores_airborne_animation()
	await process_frame

	if _failures.is_empty():
		print("NPC airborne animation controller runtime tests passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_velocity_driven_airborne_frames_and_resume() -> void:
	var npc := TestNpc.new()
	npc.name = "AirborneAnimationNpc"
	root.add_child(npc)

	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	sprite.hframes = 6
	npc.add_child(sprite)

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	npc.add_child(player)
	var library := AnimationLibrary.new()
	library.add_animation(&"idle", _make_empty_animation())
	library.add_animation(&"talk", _make_empty_animation())
	library.add_animation(&"walk", _make_empty_animation(Animation.LOOP_LINEAR))
	library.add_animation(&"run_start", _make_empty_animation())
	library.add_animation(&"run", _make_empty_animation())
	library.add_animation(&"jump_fall", _make_six_frame_airborne_animation())
	player.add_animation_library(&"", library)

	var controller := TestAirborneLocomotionController.new()
	controller.name = "NpcAnimationController"
	controller.grounded_locomotion_enabled = true
	npc.add_child(controller)
	controller.set_physics_process(false)
	controller.bind_npc(npc)

	player.play(&"idle")
	npc.velocity.y = 100.0
	controller._physics_process(0.0)
	_expect(
		not controller.is_airborne_animation_active(),
		"an ungrounded scene spawn does not look like a real ledge fall"
	)
	npc.velocity.y = -600.0
	controller._physics_process(0.0)
	_expect(controller.is_airborne_animation_active(), "rising starts the airborne visual override")
	_expect(player.assigned_animation == &"jump_fall", "airborne override selects jump_fall")
	_expect(not player.is_playing(), "jump_fall is paused so velocity owns its frame")
	_expect(sprite.frame == 0, "takeoff uses rising placeholder frame 0")

	controller._seek_airborne_pose(-300.0)
	_expect(sprite.frame == 1, "mid-rise uses rising placeholder frame 1")
	controller._seek_airborne_pose(-60.0)
	_expect(sprite.frame == 2, "near-apex rise uses rising placeholder frame 2")
	controller._seek_airborne_pose(0.0)
	_expect(sprite.frame == 3, "apex begins falling placeholder frame 3")
	controller._seek_airborne_pose(300.0)
	_expect(sprite.frame == 4, "mid-fall uses falling placeholder frame 4")
	controller._seek_airborne_pose(590.0)
	_expect(sprite.frame == 5, "late fall uses falling placeholder frame 5")

	var started: Array[StringName] = []
	player.animation_started.connect(func(animation_name: StringName) -> void:
		started.append(animation_name)
	)
	controller.sampled_horizontal_speed = 161.0
	_expect(controller.request_animation(&"run"), "ground animation requests remain accepted in the air")
	_expect(player.assigned_animation == &"jump_fall", "ground requests do not interrupt jump_fall")
	_expect(
		controller.get_latest_requested_animation() == &"run",
		"airborne controller stores the latest logical request"
	)
	_expect(controller.face_x_direction(-1.0), "airborne controller retains normal facing support")
	_expect(sprite.flip_h, "airborne animation retains horizontal flipping")
	controller._finish_airborne_override()
	_expect(
		player.current_animation == &"run"
		and player.is_playing()
		and controller.get_locomotion_phase()
		== NpcAnimationController.LocomotionPhase.RUN,
		"fast landing reevaluates Run intent and enters Run directly"
	)
	_expect(
		not started.has(&"run_start"),
		"landing at high speed does not replay RunStart"
	)
	_expect(sprite.flip_h, "landing does not reset facing")

	controller.sampled_horizontal_speed = 77.0
	controller.request_animation(&"walk")
	player.speed_scale = 1.35
	controller._begin_airborne_override(-300.0)
	_expect(
		is_equal_approx(player.speed_scale, 1.0),
		"airborne override resets grounded locomotion playback speed"
	)
	_expect(controller.request_animation(&"talk"), "Talk request is accepted while airborne")
	controller._finish_airborne_override()
	_expect(
		player.current_animation == &"talk" and player.is_playing(),
		"landing restores the newest non-locomotion request"
	)
	_expect(
		is_equal_approx(player.speed_scale, 1.0),
		"airborne non-locomotion restoration keeps playback speed clean"
	)

	npc.queue_free()


func _test_mom_airborne_wiring_and_placeholder_frames() -> void:
	var mom_scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := mom_scene.instantiate()
	var controller := mom.get_node_or_null("NpcAnimationController")
	var player := mom.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_expect(
		controller is NpcAirborneAnimationController,
		"Mom uses the reusable airborne animation controller"
	)
	_expect(player != null and player.has_animation(&"jump_fall"), "Mom contains a jump_fall clip")
	if player != null and player.has_animation(&"jump_fall"):
		var animation := player.get_animation(&"jump_fall")
		var frame_values: Array[int] = []
		var airborne_texture: Texture2D
		for track_index in animation.get_track_count():
			var track_path := String(animation.track_get_path(track_index))
			if track_path == "Sprite2D:frame":
				for key_index in animation.track_get_key_count(track_index):
					frame_values.append(int(animation.track_get_key_value(track_index, key_index)))
			elif track_path == "Sprite2D:texture" and animation.track_get_key_count(track_index) > 0:
				airborne_texture = animation.track_get_key_value(track_index, 0) as Texture2D
		_expect(frame_values == [8, 7, 6, 6, 7, 8], "Mom has three crouched rise and three crouched fall placeholder keys")
		_expect(
			airborne_texture != null
			and airborne_texture.resource_path.ends_with("/mom_actions_1.png"),
			"Mom's airborne placeholder uses the action sheet instead of the walk sheet"
		)
	mom.free()


func _test_mom_damage_hop_uses_and_restores_airborne_animation() -> void:
	var test_world := Node2D.new()
	test_world.name = "MomAirborneTestWorld"
	root.add_child(test_world)

	var floor_body := StaticBody2D.new()
	floor_body.position = Vector2(0.0, 10.0)
	var floor_shape := CollisionShape2D.new()
	var floor_rectangle := RectangleShape2D.new()
	floor_rectangle.size = Vector2(1000.0, 20.0)
	floor_shape.shape = floor_rectangle
	floor_body.add_child(floor_shape)
	test_world.add_child(floor_body)

	var mom_scene := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := mom_scene.instantiate() as SocialNpc
	mom.location_id = &""
	mom.relationship_id = &""
	test_world.add_child(mom)
	for _frame in 20:
		await physics_frame
		if mom.is_on_floor():
			break
	_expect(mom.is_on_floor(), "Mom settles on a real floor before the damage hop")

	var controller := mom.get_node("NpcAnimationController") as NpcAirborneAnimationController
	var player := mom.get_node("AnimationPlayer") as AnimationPlayer
	var sprite := mom.get_node("Sprite2D") as Sprite2D
	var ground_animation := player.current_animation
	var rising_pose_seen := false
	var falling_pose_seen := false
	var airborne_seen := false
	mom.start_damage_hop(Vector2(100.0, 0.0))
	for _frame in 60:
		await physics_frame
		if controller.is_airborne_animation_active():
			airborne_seen = true
			if mom.velocity.y < 0.0:
				rising_pose_seen = rising_pose_seen or sprite.frame in [6, 7, 8]
			else:
				falling_pose_seen = falling_pose_seen or sprite.frame in [6, 7, 8]
		elif airborne_seen and mom.is_on_floor():
			break

	_expect(airborne_seen, "Mom's existing damage hop activates jump_fall")
	_expect(rising_pose_seen, "Mom's damage hop displays a rising placeholder pose")
	_expect(falling_pose_seen, "Mom's damage hop displays a falling placeholder pose")
	_expect(
		mom.is_on_floor()
		and not controller.is_airborne_animation_active()
		and player.current_animation == ground_animation
		and player.is_playing(),
		"Mom restores her prior state animation after landing"
	)

	test_world.queue_free()
	await process_frame


func _make_empty_animation(loop_mode: int = Animation.LOOP_NONE) -> Animation:
	var animation := Animation.new()
	animation.length = 1.0
	animation.loop_mode = loop_mode
	return animation


func _make_six_frame_airborne_animation() -> Animation:
	var animation := Animation.new()
	animation.length = 1.0
	var frame_track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(frame_track, NodePath("Sprite2D:frame"))
	animation.value_track_set_update_mode(frame_track, Animation.UPDATE_DISCRETE)
	var frame_times := [0.0, 0.2, 0.4, 0.5, 0.7, 0.9]
	for frame_index in 6:
		animation.track_insert_key(frame_track, frame_times[frame_index], frame_index)
	return animation


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
