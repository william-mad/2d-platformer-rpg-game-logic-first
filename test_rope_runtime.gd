extends SceneTree

const STEP: float = 1.0 / 60.0

var _failures: Array[String] = []
var _fixture_nodes: Array[Node] = []


class TestBody:
	extends CharacterBody2D

	var rope_weight: float = 1.0
	var rope_attach_point: Marker2D

	func _init(weight: float = 1.0, attach_offset: Vector2 = Vector2.ZERO) -> void:
		rope_weight = weight
		rope_attach_point = Marker2D.new()
		rope_attach_point.position = attach_offset
		add_child(rope_attach_point)

	func get_rope_attach_point() -> Node2D:
		return rope_attach_point


class TestNpcWithoutWeight:
	extends CharacterBody2D


func _initialize() -> void:
	await process_frame
	_test_equal_opposite_pull_stays_balanced()
	_test_immovable_anchor_preserves_a_swing()
	_test_grounded_tension_does_not_add_lift()
	_test_passive_swing_settles_toward_the_anchor()
	_test_active_swing_input_builds_momentum_with_leverage()
	_test_tap_and_hold_throw_states()
	_test_throw_arc_widens_with_charge()
	await _test_charged_throw_attaches_and_adjusts_terrain_rope()
	_test_two_end_attachment_and_length_rules()
	_test_either_endpoint_input_undoes_a_two_end_rope()
	_test_second_end_is_tap_only()
	_test_active_rope_updates_during_second_end_hold()
	await _test_slime_death_undoes_the_whole_rope()
	await _test_freed_endpoint_preserves_other_attachment()
	_test_rope_input_map_contract()
	await _test_s_throw_targets_movable_attachables_only()
	_test_player_free_npc_swing()
	_test_payload_hoist_and_impulse_policy()
	_test_drag_speed_scales_with_weight()
	_test_elastic_give_is_smooth_and_never_moves_positions_directly()
	_test_tension_color_progression_and_reset()
	await _test_maximum_tension_snaps_cleanly_with_feedback()
	_test_npc_rope_status_notifications()
	_test_closest_target_uses_the_attachment_point()
	_test_npc_default_weight_and_scene_contract()

	if _failures.is_empty():
		print("Rope runtime tests passed.")
		quit(0)
		return

	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_equal_opposite_pull_stays_balanced() -> void:
	var direct_pair := Rope.solve_weighted_velocity_pair(
		Vector2(-180.0, 0.0),
		Vector2(180.0, 0.0),
		Vector2.RIGHT,
		10.0,
		10.0
	)
	_expect_vector_close(
		direct_pair[0],
		Vector2.ZERO,
		0.001,
		"equal opposite endpoints leave the first character still"
	)
	_expect_vector_close(
		direct_pair[1],
		Vector2.ZERO,
		0.001,
		"equal opposite endpoints leave the second character still"
	)

	var left := _make_body(Vector2(-100.0, 0.0), 10.0)
	var payload := _make_body(Vector2.ZERO, 10.0)
	var right := _make_body(Vector2(100.0, 0.0), 10.0)
	var left_rope := _make_rope(left, payload, 10.0, 0.0)
	var right_rope := _make_rope(right, payload, 10.0, 0.0)
	left.position.x = -110.0
	right.position.x = 110.0

	Rope.constrain_attached_velocity(left, Vector2(-180.0, 0.0), STEP)
	Rope.constrain_attached_velocity(right, Vector2(180.0, 0.0), STEP)
	var payload_velocity := Rope.constrain_attached_velocity(
		payload,
		Vector2.ZERO,
		STEP
	)
	var left_velocity := Rope.constrain_attached_velocity(
		left,
		Vector2(-180.0, 0.0),
		STEP
	)
	var right_velocity := Rope.constrain_attached_velocity(
		right,
		Vector2(180.0, 0.0),
		STEP
	)

	_expect(
		absf(payload_velocity.x) <= 0.001,
		"equal ropes on opposite sides do not drift their shared payload"
	)
	_expect(
		absf(left_velocity.x) <= 0.25 and absf(right_velocity.x) <= 0.25,
		"equal opposite pullers settle instead of stretching through the payload"
	)
	left_rope.detach()
	right_rope.detach()
	_clear_fixture()


func _test_immovable_anchor_preserves_a_swing() -> void:
	var pair := Rope.solve_weighted_velocity_pair(
		Vector2(140.0, 220.0),
		Vector2.ZERO,
		Vector2.UP,
		1.0,
		1.0,
		false,
		true
	)
	_expect_close(
		pair[0].x,
		140.0,
		0.001,
		"an anchor leaves tangential character speed untouched"
	)
	_expect_close(
		pair[0].y,
		0.0,
		0.001,
		"an anchor removes only outward radial character speed"
	)
	_expect_vector_close(
		pair[1],
		Vector2.ZERO,
		0.001,
		"an immovable anchor never receives velocity"
	)

	var actor := _make_body(Vector2(0.0, 100.0), 1.0)
	var anchor := StaticBody2D.new()
	anchor.position = Vector2.ZERO
	get_root().add_child(anchor)
	_fixture_nodes.append(anchor)
	var rope := _make_rope(actor, anchor, 4.0, 0.0)
	actor.position.y = 104.0
	actor.velocity = Vector2(160.0, 0.0)
	var anchor_position := anchor.position
	var maximum_distance := 0.0
	var maximum_horizontal_travel := 0.0
	var minimum_height := actor.position.y

	for _frame in range(90):
		actor.velocity += Vector2(0.0, 240.0) * STEP
		actor.velocity = Rope.constrain_attached_velocity(
			actor,
			actor.velocity,
			STEP
		)
		actor.position += actor.velocity * STEP
		maximum_distance = maxf(
			maximum_distance,
			actor.position.distance_to(anchor.position)
		)
		maximum_horizontal_travel = maxf(
			maximum_horizontal_travel,
			absf(actor.position.x)
		)
		minimum_height = minf(minimum_height, actor.position.y)

	_expect_vector_close(
		anchor.position,
		anchor_position,
		0.0,
		"the swing simulation never moves its StaticBody anchor"
	)
	_expect(
		maximum_horizontal_travel > 40.0 and minimum_height < 100.0,
		"tangential velocity carries the character along a visible arc"
	)
	_expect(
		maximum_distance <= rope.get_hard_length() + 0.5,
		"the swing stays inside the configured give margin"
	)
	rope.detach()
	_clear_fixture()


func _test_grounded_tension_does_not_add_lift() -> void:
	var intended := Vector2(-120.0, 20.0)
	var rope_solved := Vector2(-45.0, -180.0)
	var grounded_result := Rope._limit_grounded_rope_lift(
		intended,
		rope_solved,
		true
	)
	_expect_close(
		grounded_result.x,
		rope_solved.x,
		0.001,
		"ground support does not discard horizontal rope resistance"
	)
	_expect_close(
		grounded_result.y,
		0.0,
		0.001,
		"rope tension cannot add upward velocity while grounded"
	)

	var downward_result := Rope._limit_grounded_rope_lift(
		intended,
		Vector2(-45.0, 5.0),
		true
	)
	_expect_close(
		downward_result.y,
		5.0,
		0.001,
		"ground support leaves non-lifting vertical rope response unchanged"
	)

	var jumping_result := Rope._limit_grounded_rope_lift(
		Vector2(0.0, -700.0),
		Vector2(30.0, -760.0),
		true
	)
	_expect_close(
		jumping_result.y,
		-700.0,
		0.001,
		"ground support does not strengthen an intentional jump"
	)
	var airborne_result := Rope._limit_grounded_rope_lift(
		intended,
		rope_solved,
		false
	)
	_expect_vector_close(
		airborne_result,
		rope_solved,
		0.001,
		"airborne rope tension remains free to create a swing"
	)


func _test_passive_swing_settles_toward_the_anchor() -> void:
	var actor := _make_body(Vector2(80.0, 60.0), 1.0)
	var anchor := StaticBody2D.new()
	anchor.position = Vector2.ZERO
	get_root().add_child(anchor)
	_fixture_nodes.append(anchor)
	var rope := _make_rope(actor, anchor, 4.0, 80.0)
	actor.position = Vector2(83.2, 62.4)

	var starting_horizontal_offset := absf(actor.position.x)
	var minimum_horizontal_offset := starting_horizontal_offset
	var maximum_distance := 0.0

	for _frame in range(240):
		actor.velocity += Vector2(0.0, 240.0) * STEP
		var velocity_before_air_control := actor.velocity
		var no_input_velocity := Vector2(0.0, actor.velocity.y)
		actor.velocity = rope.preserve_passive_swing_velocity(
			actor,
			no_input_velocity,
			velocity_before_air_control,
			STEP
		)
		actor.velocity = Rope.constrain_attached_velocity(
			actor,
			actor.velocity,
			STEP
		)
		actor.position += actor.velocity * STEP
		minimum_horizontal_offset = minf(
			minimum_horizontal_offset,
			absf(actor.position.x)
		)
		maximum_distance = maxf(
			maximum_distance,
			actor.position.distance_to(anchor.position)
		)

	_expect(
		minimum_horizontal_offset < starting_horizontal_offset * 0.2,
		"gravity carries a no-input swing beneath its anchor"
	)
	_expect(
		absf(actor.position.x) < starting_horizontal_offset * 0.35,
		"passive damping lets the no-input swing settle near the middle"
	)
	_expect(
		maximum_distance <= rope.get_hard_length() + 0.5,
		"the passive swing remains inside the configured give margin"
	)
	rope.detach()
	_clear_fixture()


func _test_active_swing_input_builds_momentum_with_leverage() -> void:
	var actor := _make_body(Vector2(0.0, 100.0), 1.0)
	var anchor := StaticBody2D.new()
	anchor.position = Vector2.ZERO
	get_root().add_child(anchor)
	_fixture_nodes.append(anchor)
	var rope := _make_rope(actor, anchor, 4.0, 80.0)
	actor.position = Vector2(0.0, 104.0)

	var assisted_velocity := rope.apply_anchored_swing_control(
		actor,
		Vector2(260.0, 0.0),
		Vector2(400.0, 0.0),
		1.0,
		STEP
	)
	_expect(
		assisted_velocity.x >= 400.0,
		"same-direction swing input never overwrites momentum with a slower speed"
	)

	var starting_velocity := rope.apply_anchored_swing_control(
		actor,
		Vector2(260.0, 0.0),
		Vector2.ZERO,
		1.0,
		STEP
	)
	_expect(
		starting_velocity.x > 0.0 and starting_velocity.x < 260.0,
		"swing input builds momentum through acceleration instead of instant speed"
	)

	actor.position = Vector2(73.54, 73.54)
	var diagonal_tangent := Vector2(-1.0, 1.0).normalized()
	var diagonal_before := -diagonal_tangent * 400.0
	var diagonal_active := rope.apply_anchored_swing_control(
		actor,
		Vector2(260.0, diagonal_before.y),
		diagonal_before,
		1.0,
		STEP
	)
	var diagonal_neutral := rope.apply_anchored_swing_control(
		actor,
		Vector2(0.0, diagonal_before.y),
		diagonal_before,
		0.0,
		STEP
	)
	_expect(
		absf(diagonal_active.dot(diagonal_tangent)) >= 400.0
		and (
			absf(diagonal_active.dot(diagonal_tangent))
			> absf(diagonal_neutral.dot(diagonal_tangent))
		),
		"matching input adds momentum on the arc instead of slowing the swing"
	)

	actor.position = Vector2(104.0, 0.0)
	var gravity_velocity := Vector2(0.0, 25.0)
	var side_velocity := rope.apply_anchored_swing_control(
		actor,
		Vector2(260.0, 25.0),
		gravity_velocity,
		1.0,
		STEP
	)
	var constrained_side_velocity := Rope.constrain_attached_velocity(
		actor,
		side_velocity,
		STEP
	)
	_expect_close(
		side_velocity.y,
		gravity_velocity.y,
		0.001,
		"horizontal input has no tangential leverage at a horizontal rope angle"
	)
	_expect(
		constrained_side_velocity.y > 0.0,
		"gravity pulls a side-held player back down instead of allowing floating"
	)
	rope.detach()
	_clear_fixture()

	var movable_actor := _make_body(Vector2.ZERO, 1.0)
	var movable_target := _make_body(Vector2(100.0, 0.0), 2.0)
	var movable_rope := _make_rope(movable_actor, movable_target, 4.0, 80.0)
	movable_target.position.x = 104.0
	var normal_air_velocity := Vector2(260.0, 15.0)
	var movable_result := movable_rope.apply_anchored_swing_control(
		movable_actor,
		normal_air_velocity,
		Vector2(400.0, 15.0),
		1.0,
		STEP
	)
	_expect_vector_close(
		movable_result,
		normal_air_velocity,
		0.001,
		"anchored swing input never changes movable-object dragging controls"
	)
	movable_rope.detach()
	_clear_fixture()


func _test_tap_and_hold_throw_states() -> void:
	var actor := _make_body(Vector2.ZERO, 1.0)
	var nearby := _make_body(Vector2(40.0, 0.0), 2.0)
	nearby.add_to_group(&"rope_attachable")
	var rope := _make_unattached_rope(actor)
	rope.track_attachable(nearby)

	_expect(
		rope.begin_endpoint_gesture(Rope.END_X, 1.0),
		"an inactive rope starts a pending X gesture"
	)
	rope._physics_process(rope.quick_attach_seconds * 0.5)
	_expect(
		rope.release_endpoint_gesture(Rope.END_X)
		and rope.end_body == nearby,
		"a quick release still attaches the closest nearby object"
	)
	rope.detach()

	var nearby_position := nearby.position
	var nearby_velocity := nearby.velocity
	_expect(
		rope.begin_endpoint_gesture(Rope.END_X, 1.0),
		"a detached rope can begin a charged throw"
	)
	rope._physics_process(rope.quick_attach_seconds + 0.05)
	_expect(
		rope.is_throw_spinning() and not rope.active,
		"holding X crosses into a visual-only spin without attaching"
	)
	_expect_vector_close(
		nearby.position,
		nearby_position,
		0.0,
		"the charge animation never moves a nearby object"
	)
	_expect_vector_close(
		nearby.velocity,
		nearby_velocity,
		0.0,
		"the charge animation never changes a nearby object's velocity"
	)
	rope.cancel_pending_throw()

	_expect(
		rope.begin_endpoint_gesture(Rope.END_X, 1.0),
		"a missed terrain throw begins"
	)
	rope._physics_process(rope.full_charge_seconds)
	_expect(
		rope.release_endpoint_gesture(Rope.END_X),
		"a charged release still animates when no terrain is in its path"
	)
	rope._physics_process(2.0)
	_expect(
		not rope.active and not rope.has_pending_throw(),
		"a missed terrain throw returns to an inactive clean state"
	)
	_clear_fixture()


func _test_two_end_attachment_and_length_rules() -> void:
	var player := _make_body(Vector2.ZERO, 1.0)
	var x_target := _make_body(Vector2(40.0, 0.0), 2.0)
	var s_target := _make_body(Vector2(70.0, 0.0), 2.0)
	x_target.add_to_group(&"rope_attachable")
	s_target.add_to_group(&"rope_attachable")
	var rope := _make_unattached_rope(player)
	rope.track_attachable(x_target)
	rope.track_attachable(s_target)

	_expect(
		rope.toggle_closest_endpoint(Rope.END_X),
		"quick X attaches its named endpoint"
	)
	_expect(
		rope.start_body == player
		and rope.end_body == x_target
		and rope.is_player_endpoint(),
		"with only X attached the player physically holds S"
	)
	var one_end_length := rope.get_rest_length()
	var player_position := player.position
	var x_position := x_target.position
	var s_position := s_target.position

	_expect(
		rope.toggle_closest_endpoint(Rope.END_S),
		"quick S attaches the remaining endpoint"
	)
	_expect(
		rope.start_body == s_target
		and rope.end_body == x_target
		and not rope.is_player_endpoint(),
		"both attached ends remove the player from the constraint"
	)
	_expect_close(
		rope.get_rest_length(),
		one_end_length,
		0.001,
		"attaching the second end preserves the existing rope length"
	)

	rope.adjust_length(false, true, 0.5)
	_expect_close(
		rope.get_rest_length(),
		one_end_length,
		0.001,
		"Down cannot extend a rope whose two ends are externally attached"
	)
	rope.adjust_length(true, true, 0.25)
	var shortened_length := maxf(
		rope.minimum_rope_length,
		one_end_length - rope.reel_in_speed * 0.25
	)
	_expect_close(
		rope.get_rest_length(),
		shortened_length,
		0.001,
		"Up still shortens a fully attached rope while ignored Down is held"
	)
	_expect_vector_close(
		player.position,
		player_position,
		0.0,
		"endpoint rebinding never snaps the player"
	)
	_expect_vector_close(
		x_target.position,
		x_position,
		0.0,
		"endpoint rebinding never snaps the X target"
	)
	_expect_vector_close(
		s_target.position,
		s_position,
		0.0,
		"endpoint rebinding never snaps the S target"
	)

	_expect(
		rope.detach_endpoint(Rope.END_S)
		and rope.start_body == player
		and rope.end_body == x_target
		and rope.is_player_endpoint(),
		"detaching S returns only S to the player"
	)
	_expect_close(
		rope.get_rest_length(),
		shortened_length,
		0.001,
		"detaching one end preserves the rope length"
	)
	_expect(
		rope.detach_endpoint(Rope.END_X) and not rope.active,
		"detaching the final external end deactivates the constraint"
	)
	_clear_fixture()


func _test_either_endpoint_input_undoes_a_two_end_rope() -> void:
	for pressed_end in [Rope.END_X, Rope.END_S]:
		var player := _make_body(Vector2.ZERO, 1.0)
		var x_target := _make_body(Vector2(40.0, 0.0), 2.0)
		var s_target := _make_body(Vector2(70.0, 0.0), 2.0)
		x_target.add_to_group(&"rope_attachable")
		s_target.add_to_group(&"rope_attachable")
		var rope := _make_unattached_rope(player)
		rope.track_attachable(x_target)
		rope.track_attachable(s_target)
		rope.toggle_closest_endpoint(Rope.END_X)
		rope.toggle_closest_endpoint(Rope.END_S)
		var x_position := x_target.position
		var s_position := s_target.position

		_expect(
			rope.undo_from_endpoint_input(pressed_end),
			"pressing either attached endpoint accepts the undo command"
		)
		_expect(
			not rope.active
			and rope.get_attached_endpoint_count() == 0
			and not rope.is_player_endpoint(),
			"pressing X or S with both ends deployed undoes the whole rope"
		)
		_expect_vector_close(
			x_target.position,
			x_position,
			0.0,
			"undoing a two-end rope does not move its X target"
		)
		_expect_vector_close(
			s_target.position,
			s_position,
			0.0,
			"undoing a two-end rope does not move its S target"
		)
		_clear_fixture()


func _test_second_end_is_tap_only() -> void:
	var player := _make_body(Vector2.ZERO, 1.0)
	var nearby := _make_body(Vector2(40.0, 0.0), 2.0)
	nearby.add_to_group(&"rope_attachable")
	var rope := _make_unattached_rope(player)
	rope.track_attachable(nearby)
	_expect(
		rope.toggle_closest_endpoint(Rope.END_X),
		"the first endpoint can attach before the second gesture"
	)
	_expect(
		rope.begin_endpoint_gesture(Rope.END_S, 1.0),
		"the remaining endpoint accepts an S gesture"
	)
	rope._physics_process(rope.full_charge_seconds + 0.1)
	_expect(
		not rope.is_throw_spinning(),
		"once one end is attached, the remaining end cannot be thrown"
	)
	rope.cancel_pending_throw()
	rope.detach()
	_clear_fixture()


func _test_active_rope_updates_during_second_end_hold() -> void:
	var player := _make_body(Vector2.ZERO, 1.0)
	var rigid_target := RigidBody2D.new()
	rigid_target.position = Vector2(40.0, 0.0)
	rigid_target.mass = 2.0
	rigid_target.add_to_group(&"rope_attachable")
	get_root().add_child(rigid_target)
	_fixture_nodes.append(rigid_target)
	var rope := _make_unattached_rope(player)
	rope.track_attachable(rigid_target)
	rope.toggle_closest_endpoint(Rope.END_X)

	rigid_target.position.x = rope.get_hard_length() + 30.0
	rigid_target.linear_velocity = Vector2(200.0, 0.0)
	rope.begin_endpoint_gesture(Rope.END_S, 1.0)
	rope._physics_process(STEP)
	_expect(
		rigid_target.linear_velocity.x < 200.0,
		"holding the tap-only second end does not freeze rigid rope physics"
	)
	_expect(
		rope.line != null and rope.line.get_point_count() >= 2,
		"holding the tap-only second end keeps the active rope visual updated"
	)
	rope.cancel_pending_throw()
	rope.detach()
	_clear_fixture()


func _test_slime_death_undoes_the_whole_rope() -> void:
	var player := _make_body(Vector2.ZERO, 1.0)
	var anchor := StaticBody2D.new()
	anchor.position = Vector2(160.0, 0.0)
	get_root().add_child(anchor)
	_fixture_nodes.append(anchor)

	var slime_scene := load("res://scenes/monsters/slime.tscn") as PackedScene
	var slime := slime_scene.instantiate() as Slime
	slime.position = Vector2(80.0, 0.0)
	slime.death_fade_delay_seconds = 0.0
	slime.death_fade_seconds = 0.05
	get_root().add_child(slime)
	_fixture_nodes.append(slime)

	var rope := _make_unattached_rope(player)
	_expect(
		rope.complete_thrown_end(Rope.END_X, anchor, anchor.position),
		"the death regression establishes a terrain endpoint"
	)
	rope.track_attachable(slime)
	_expect(
		rope.toggle_closest_endpoint(Rope.END_S)
		and not rope.is_player_endpoint(),
		"the death regression attaches the slime as the external S endpoint"
	)

	slime.die()
	_expect(
		not rope.active
		and rope.get_attached_endpoint_count() == 0
		and not rope.is_attached_to(player),
		"a dying attached slime undoes the whole rope instead of substituting the player"
	)
	await create_timer(0.1).timeout
	await process_frame
	_clear_fixture()


func _test_freed_endpoint_preserves_other_attachment() -> void:
	var player := _make_body(Vector2.ZERO, 1.0)
	var x_target := _make_body(Vector2(40.0, 0.0), 2.0)
	var s_target := _make_body(Vector2(70.0, 0.0), 2.0)
	x_target.add_to_group(&"rope_attachable")
	s_target.add_to_group(&"rope_attachable")
	var rope := _make_unattached_rope(player)
	rope.track_attachable(x_target)
	rope.track_attachable(s_target)
	rope.toggle_closest_endpoint(Rope.END_X)
	rope.toggle_closest_endpoint(Rope.END_S)
	var preserved_length := rope.get_rest_length()

	s_target.queue_free()
	await process_frame
	rope._physics_process(STEP)
	_expect(
		rope.active
		and rope.start_body == player
		and rope.end_body == x_target,
		"a freed S target returns only S to the player"
	)
	_expect_close(
		rope.get_rest_length(),
		preserved_length,
		0.001,
		"a surviving endpoint keeps its rope length when the other target is freed"
	)
	rope.detach()
	_clear_fixture()


func _test_rope_input_map_contract() -> void:
	_expect(
		InputMap.has_action(&"attach_rope_npc"),
		"the second rope endpoint has its own input action"
	)
	var s_is_second_endpoint := false
	for event in InputMap.action_get_events(&"attach_rope_npc"):
		var key_event := event as InputEventKey
		if key_event != null and key_event.physical_keycode == KEY_S:
			s_is_second_endpoint = true
			break
	_expect(s_is_second_endpoint, "S controls the movable/NPC rope endpoint")

	var s_still_crouches := false
	for event in InputMap.action_get_events(&"crouch"):
		var key_event := event as InputEventKey
		if key_event != null and key_event.physical_keycode == KEY_S:
			s_still_crouches = true
			break
	_expect(
		not s_still_crouches,
		"S no longer crouches or pays rope out"
	)


func _test_s_throw_targets_movable_attachables_only() -> void:
	var player := _make_body(Vector2.ZERO, 1.0)
	var rope := _make_unattached_rope(player)

	var terrain := StaticBody2D.new()
	terrain.position = Vector2(320.0, 0.0)
	terrain.collision_layer = 1
	var terrain_shape := CollisionShape2D.new()
	var terrain_rectangle := RectangleShape2D.new()
	terrain_rectangle.size = Vector2(12.0, 800.0)
	terrain_shape.shape = terrain_rectangle
	terrain.add_child(terrain_shape)
	get_root().add_child(terrain)
	_fixture_nodes.append(terrain)

	var npc := TestBody.new(2.0)
	npc.position = Vector2(220.0, 0.0)
	npc.add_to_group(&"rope_attachable")
	npc.collision_layer = 4
	npc.collision_mask = 0
	var npc_shape := CollisionShape2D.new()
	var npc_rectangle := RectangleShape2D.new()
	npc_rectangle.size = Vector2(16.0, 800.0)
	npc_shape.shape = npc_rectangle
	npc.add_child(npc_shape)
	get_root().add_child(npc)
	_fixture_nodes.append(npc)
	await physics_frame

	_expect(
		not rope.is_valid_throw_target(Rope.END_S, terrain),
		"S throws reject immovable terrain"
	)
	_expect(
		not rope.is_valid_throw_target(Rope.END_X, npc),
		"X throws reject movable attachables"
	)
	_expect(
		rope.is_valid_throw_target(Rope.END_S, npc),
		"S recognizes a movable rope attachable"
	)
	_expect(
		rope.begin_endpoint_gesture(Rope.END_S, 1.0),
		"an unattached S endpoint begins a charged throw"
	)
	rope._physics_process(rope.full_charge_seconds)
	_expect(
		rope.release_endpoint_gesture(Rope.END_S),
		"a charged S release launches its endpoint"
	)
	rope._physics_process(2.0)
	_expect(
		rope.active
		and rope.start_body == npc
		and rope.end_body == player
		and not rope.has_terrain_anchor(),
		"S attaches to the movable NPC and never to terrain"
	)
	rope.detach()

	terrain.position = Vector2(120.0, 0.0)
	await physics_frame
	rope.begin_endpoint_gesture(Rope.END_S, 1.0)
	rope._physics_process(rope.full_charge_seconds)
	rope.release_endpoint_gesture(Rope.END_S)
	rope._physics_process(2.0)
	_expect(
		not rope.active,
		"terrain blocks an S throw as a miss instead of becoming transparent"
	)
	_clear_fixture()


func _test_player_free_npc_swing() -> void:
	var player := _make_body(Vector2(80.0, 60.0), 1.0)
	var npc := _make_body(Vector2(80.0, 60.0), 2.0)
	npc.add_to_group(&"rope_attachable")
	var anchor := StaticBody2D.new()
	anchor.position = Vector2.ZERO
	get_root().add_child(anchor)
	_fixture_nodes.append(anchor)
	var rope := _make_unattached_rope(player)
	rope.track_attachable(npc)

	_expect(
		rope.complete_thrown_end(Rope.END_X, anchor, anchor.position),
		"X can establish the terrain endpoint"
	)
	_expect(
		rope.toggle_closest_endpoint(Rope.END_S),
		"S can replace the player with an NPC endpoint"
	)
	_expect(
		rope.start_body == npc
		and rope.end_body == anchor
		and not rope.is_attached_to(player),
		"terrain-to-NPC rope physics is independent of player movement"
	)

	npc.position = Vector2(83.2, 62.4)
	var player_position := player.position
	var starting_horizontal_offset := absf(npc.position.x)
	var minimum_horizontal_offset := starting_horizontal_offset
	var maximum_distance := 0.0
	for _frame in range(240):
		npc.velocity += Vector2(0.0, 240.0) * STEP
		var velocity_after_gravity := npc.velocity
		var ai_velocity := Vector2(0.0, npc.velocity.y)
		npc.velocity = Rope.finalize_attached_body_velocity(
			npc,
			ai_velocity,
			velocity_after_gravity,
			STEP
		)
		npc.position += npc.velocity * STEP
		minimum_horizontal_offset = minf(
			minimum_horizontal_offset,
			absf(npc.position.x)
		)
		maximum_distance = maxf(
			maximum_distance,
			npc.position.distance_to(anchor.position)
		)

	_expect(
		minimum_horizontal_offset < starting_horizontal_offset * 0.2,
		"an AI-controlled NPC swings beneath the terrain anchor"
	)
	_expect(
		maximum_distance <= rope.get_hard_length() + 0.5,
		"the independent NPC swing respects rope give"
	)
	_expect_vector_close(
		player.position,
		player_position,
		0.0,
		"the independent rope never changes player movement"
	)
	rope.detach()
	_clear_fixture()


func _test_payload_hoist_and_impulse_policy() -> void:
	var player := _make_body(Vector2(0.0, 100.0), 1.0)
	var npc := _make_body(Vector2(0.0, 100.0), 2.0)
	npc.add_to_group(&"rope_attachable")
	var anchor := StaticBody2D.new()
	anchor.position = Vector2.ZERO
	get_root().add_child(anchor)
	_fixture_nodes.append(anchor)
	var rope := _make_unattached_rope(player)
	rope.track_attachable(npc)
	rope.complete_thrown_end(Rope.END_X, anchor, anchor.position)
	_expect(
		Rope._body_has_grounded_lift_protection(player, [rope]),
		"a player-held endpoint keeps grounded lift protection"
	)
	rope.toggle_closest_endpoint(Rope.END_S)
	_expect(
		not Rope._body_has_grounded_lift_protection(npc, [rope]),
		"an external NPC payload is allowed to leave the floor"
	)
	rope.adjust_length(true, false, 1.0)
	var hoist_velocity := Rope.constrain_attached_velocity(
		npc,
		Vector2.ZERO,
		STEP
	)
	_expect(
		hoist_velocity.y < 0.0,
		"shortening a terrain-to-NPC rope produces smooth upward hoist velocity"
	)
	rope.detach()
	_clear_fixture()

	var airborne_npc := _make_body(Vector2(0.0, 100.0), 2.0)
	var impulse_anchor := StaticBody2D.new()
	impulse_anchor.position = Vector2.ZERO
	get_root().add_child(impulse_anchor)
	_fixture_nodes.append(impulse_anchor)
	var impulse_rope := _make_rope(
		airborne_npc,
		impulse_anchor,
		4.0,
		80.0
	)
	airborne_npc.position.y = 104.0
	var jump_velocity := Rope.finalize_attached_body_velocity(
		airborne_npc,
		Vector2(-300.0, -400.0),
		Vector2(120.0, 50.0),
		STEP
	)
	_expect_vector_close(
		jump_velocity,
		Vector2(-300.0, -400.0),
		0.001,
		"an intentional vertical jump or knockback is not erased by swing preservation"
	)
	var horizontal_intent_velocity := Rope.finalize_attached_body_velocity(
		airborne_npc,
		Vector2(-300.0, 0.0),
		Vector2.ZERO,
		STEP
	)
	_expect(
		horizontal_intent_velocity.x < 0.0
		and horizontal_intent_velocity.x > -300.0,
		"horizontal NPC intent builds pendulum momentum without an instant speed snap"
	)
	impulse_rope.detach()
	_clear_fixture()


func _test_throw_arc_widens_with_charge() -> void:
	var short_arc := Rope.sample_ballistic_throw_arc(
		Vector2.ZERO,
		1.0,
		260.0,
		48.0,
		900.0,
		0.9,
		600.0,
		28
	)
	var full_arc := Rope.sample_ballistic_throw_arc(
		Vector2.ZERO,
		1.0,
		930.0,
		48.0,
		900.0,
		0.9,
		600.0,
		28
	)
	var short_reach := short_arc[short_arc.size() - 1].length()
	var full_reach := full_arc[full_arc.size() - 1].length()
	_expect(
		full_reach > short_reach + 200.0,
		"the displayed throw arc grows substantially with charge"
	)
	_expect(
		full_reach <= 600.001,
		"the charged throw preview never exceeds maximum rope length"
	)


func _test_charged_throw_attaches_and_adjusts_terrain_rope() -> void:
	var actor := _make_body(Vector2.ZERO, 1.0)
	var rope := _make_unattached_rope(actor)
	rope.pay_out_speed = 180.0
	_expect_close(
		rope.reel_in_speed,
		75.0,
		0.001,
		"terrain rope uses the slower default reel-in rate"
	)

	var movable_decoy := CharacterBody2D.new()
	movable_decoy.position = Vector2(105.0, 0.0)
	movable_decoy.collision_layer = 1
	movable_decoy.collision_mask = 0
	var decoy_shape := CollisionShape2D.new()
	var decoy_rectangle := RectangleShape2D.new()
	decoy_rectangle.size = Vector2(12.0, 800.0)
	decoy_shape.shape = decoy_rectangle
	movable_decoy.add_child(decoy_shape)
	get_root().add_child(movable_decoy)
	_fixture_nodes.append(movable_decoy)

	var wall := StaticBody2D.new()
	wall.position = Vector2(210.0, 0.0)
	wall.collision_layer = 1
	wall.collision_mask = 0
	var wall_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(20.0, 800.0)
	wall_shape.shape = rectangle
	wall.add_child(wall_shape)
	get_root().add_child(wall)
	_fixture_nodes.append(wall)
	await physics_frame

	_expect(
		rope.begin_endpoint_gesture(Rope.END_X, 1.0),
		"terrain throw begins"
	)
	rope._physics_process(rope.full_charge_seconds)
	_expect(
		rope.release_endpoint_gesture(Rope.END_X),
		"a charged X release launches the visual endpoint"
	)
	rope._physics_process(2.0)
	_expect(
		rope.active and rope.has_terrain_anchor() and rope.end_body == wall,
		"the first immovable terrain hit becomes the anchor, never a movable body"
	)

	var actor_position := actor.position
	var wall_position := wall.position
	var original_length := rope.get_rest_length()
	rope.adjust_length(true, false, 0.25)
	_expect_close(
		rope.get_rest_length(),
		maxf(rope.minimum_rope_length, original_length - 18.75),
		0.001,
		"Up-style pull shortens terrain rope at its configured rate"
	)
	rope.adjust_length(false, true, 0.25)
	_expect_close(
		rope.get_rest_length(),
		minf(rope.max_length, maxf(
			rope.minimum_rope_length,
			original_length - 18.75
		) + 45.0),
		0.001,
		"Down-style payout extends terrain rope at its configured rate"
	)
	_expect_vector_close(
		actor.position,
		actor_position,
		0.0,
		"length controls never snap the player position"
	)
	_expect_vector_close(
		wall.position,
		wall_position,
		0.0,
		"length controls never move terrain"
	)

	var anchor_point := rope.end_visual_point
	rope.detach()
	await process_frame
	_expect(
		not is_instance_valid(anchor_point),
		"detaching removes the rope-owned terrain anchor"
	)
	_clear_fixture()


func _test_drag_speed_scales_with_weight() -> void:
	var payload_weights := [5.0, 10.0, 30.0]
	var expected_speeds := [-160.0, -120.0, -60.0]
	var measured_speeds: Array[float] = []

	for index in range(payload_weights.size()):
		var payload_weight: float = payload_weights[index]
		var result := Rope.solve_weighted_velocity_pair(
			Vector2(-240.0, 0.0),
			Vector2.ZERO,
			Vector2.RIGHT,
			10.0,
			payload_weight
		)
		measured_speeds.append(result[0].x)
		_expect_close(
			result[0].x,
			expected_speeds[index],
			0.001,
			"drag speed follows weight multiplied by intended speed"
		)
		_expect_close(
			result[1].x,
			expected_speeds[index],
			0.001,
			"the dragged body shares the constrained radial speed"
		)

	_expect(
		absf(measured_speeds[0]) > absf(measured_speeds[1])
		and absf(measured_speeds[1]) > absf(measured_speeds[2]),
		"heavier payloads reduce character speed monotonically"
	)


func _test_elastic_give_is_smooth_and_never_moves_positions_directly() -> void:
	var sample_distances := [99.0, 105.0, 110.0, 115.0]
	var reductions: Array[float] = []
	for distance in sample_distances:
		var start := _make_body(Vector2.ZERO, 1.0)
		var end := _make_body(Vector2(100.0, 0.0), 1.0)
		var rope := _make_rope(start, end, 20.0, 0.0)
		_expect_close(
			rope.get_hard_length() - rope.get_rest_length(),
			rope.elasticity,
			0.001,
			"editable elasticity is the rope's available give distance"
		)
		end.position.x = distance
		var solved_end := Rope.constrain_attached_velocity(
			end,
			Vector2(60.0, 0.0),
			STEP
		)
		reductions.append(60.0 - solved_end.x)
		rope.detach()
		_clear_fixture()

	_expect_close(reductions[0], 0.0, 0.001, "slack rope applies no tension")
	_expect(
		reductions[1] > reductions[0]
		and reductions[2] > reductions[1]
		and reductions[3] > reductions[2],
		"tension rises smoothly through the give margin"
	)

	var start := _make_body(Vector2.ZERO, 1.0)
	var end := _make_body(Vector2(100.0, 0.0), 1.0)
	var rope := _make_rope(start, end, 20.0, 60.0)
	end.position.x = 125.0
	var start_before := start.position
	var end_before := end.position
	var recovery_velocity := Rope.constrain_attached_velocity(
		end,
		Vector2.ZERO,
		STEP
	)
	_expect_vector_close(
		start.position,
		start_before,
		0.0,
		"rope solving never snaps the first endpoint"
	)
	_expect_vector_close(
		end.position,
		end_before,
		0.0,
		"rope solving never snaps the second endpoint"
	)
	_expect(
		recovery_velocity.x < 0.0,
		"an overstretched rope recovers through inward velocity"
	)

	end.position.x = 119.5
	Rope.constrain_attached_velocity(
		end,
		Vector2(600.0, 0.0),
		STEP
	)
	var capped_start_velocity := Rope.constrain_attached_velocity(
		start,
		Vector2.ZERO,
		STEP
	)
	var capped_end_velocity := Rope.constrain_attached_velocity(
		end,
		Vector2(600.0, 0.0),
		STEP
	)
	var predicted_distance := (
		end.position.x
		+ (capped_end_velocity.x - capped_start_velocity.x) * STEP
	)
	_expect(
		predicted_distance <= rope.get_hard_length() + 0.001,
		"high speed is capped before it can cross the give boundary"
	)
	rope.detach()
	_clear_fixture()

	var stiff_start := _make_body(Vector2.ZERO, 1.0)
	var stiff_end := _make_body(Vector2(100.0, 0.0), 1.0)
	var stiff_rope := _make_rope(stiff_start, stiff_end, 10.0, 60.0)
	stiff_rope.maximum_tension = 100.0
	stiff_end.position.x = 108.0
	stiff_rope._physics_process(STEP)
	var stiff_tension := stiff_rope.get_current_tension()
	var still_tension := stiff_tension
	stiff_end.velocity = Vector2(240.0, 0.0)
	stiff_rope._physics_process(STEP)
	var moving_tension := stiff_rope.get_current_tension()
	stiff_rope.detach()
	_clear_fixture()

	var elastic_start := _make_body(Vector2.ZERO, 1.0)
	var elastic_end := _make_body(Vector2(100.0, 0.0), 1.0)
	var elastic_rope := _make_rope(elastic_start, elastic_end, 40.0, 60.0)
	elastic_rope.maximum_tension = 100.0
	elastic_end.position.x = 108.0
	elastic_rope._physics_process(STEP)
	var elastic_tension := elastic_rope.get_current_tension()
	_expect(
		stiff_tension > elastic_tension,
		"less elasticity produces more tension at the same extension"
	)
	_expect(
		moving_tension > still_tension,
		"outward speed raises projected rope tension before the next step"
	)
	elastic_rope.detach()
	_clear_fixture()


func _test_tension_color_progression_and_reset() -> void:
	var start := _make_body(Vector2.ZERO, 1.0)
	var end := _make_body(Vector2(100.0, 0.0), 1.0)
	var rope := _make_rope(start, end, 20.0, 60.0)
	rope.maximum_tension = 10.0

	_expect_color_close(
		rope.get_tension_color(0.0),
		rope.tension_green,
		0.001,
		"zero tension uses muted green"
	)
	_expect_color_close(
		rope.get_tension_color(0.4),
		rope.tension_yellow,
		0.001,
		"the first urgency stop is yellow"
	)
	_expect_color_close(
		rope.get_tension_color(0.7),
		rope.tension_red,
		0.001,
		"the second urgency stop is red"
	)
	_expect_color_close(
		rope.get_tension_color(1.0),
		rope.tension_purple,
		0.001,
		"maximum visible urgency is vibrant purple"
	)

	end.position.x = 115.0
	rope._physics_process(STEP)
	_expect_color_close(
		rope.line.default_color,
		rope.get_tension_color(),
		0.001,
		"the visible rope line receives its live tension color"
	)
	rope.detach()
	_expect_close(
		rope.get_current_tension(),
		0.0,
		0.001,
		"detaching clears measured rope tension"
	)
	_expect_color_close(
		rope.line.default_color,
		rope.tension_green,
		0.001,
		"detaching resets the reused rope line to muted green"
	)
	_expect(
		rope.attach(start, end),
		"a detached rope can rebind after its tension color resets"
	)
	_expect_color_close(
		rope.line.default_color,
		rope.tension_green,
		0.001,
		"rebinding starts from the safe green color"
	)
	rope.detach()
	_clear_fixture()


func _test_maximum_tension_snaps_cleanly_with_feedback() -> void:
	var player := _make_body(Vector2.ZERO, 1.0)
	var payload := _make_body(Vector2(80.0, 0.0), 2.0)
	payload.add_to_group(&"rope_attachable")
	var anchor := StaticBody2D.new()
	anchor.position = Vector2(160.0, 0.0)
	get_root().add_child(anchor)
	_fixture_nodes.append(anchor)
	var rope := _make_unattached_rope(player)
	rope.track_attachable(payload)
	var snap_events: Array[Dictionary] = []
	rope.rope_snapped.connect(
		func(world_midpoint: Vector2, tension: float) -> void:
			snap_events.append({
				"midpoint": world_midpoint,
				"tension": tension,
			})
	)

	rope.complete_thrown_end(Rope.END_X, anchor, anchor.position)
	rope.toggle_closest_endpoint(Rope.END_S)
	rope.detach()
	_expect(
		snap_events.is_empty(),
		"ordinary detachment never emits the tension snap hook"
	)

	rope.complete_thrown_end(Rope.END_X, anchor, anchor.position)
	rope.toggle_closest_endpoint(Rope.END_S)
	rope.elasticity = 20.0
	rope.maximum_tension = 0.25
	rope.snap_flash_seconds = 0.05
	payload.position.x = -5.0
	rope._physics_process(STEP)
	_expect(
		rope.active,
		"the rope remains attached while tension is exactly at its maximum"
	)
	_expect_color_close(
		rope.line.default_color,
		rope.tension_purple,
		0.001,
		"the rope reaches full purple before an overload snaps it"
	)

	payload.position.x = -10.0
	var player_position := player.position
	var payload_position := payload.position
	var anchor_position := anchor.position
	var expected_midpoint := (payload.position + anchor.position) * 0.5

	rope._physics_process(STEP)
	_expect(
		not rope.active
		and rope.get_attached_endpoint_count() == 0
		and not rope.is_attached_to(player),
		"exceeding maximum tension undoes both ends without substituting the player"
	)
	_expect_vector_close(
		player.position,
		player_position,
		0.0,
		"snapping never moves the player"
	)
	_expect_vector_close(
		payload.position,
		payload_position,
		0.0,
		"snapping never moves the payload"
	)
	_expect_vector_close(
		anchor.position,
		anchor_position,
		0.0,
		"snapping never moves the anchor"
	)
	_expect(
		snap_events.size() == 1
		and float(snap_events[0].get("tension", 0.0)) > rope.maximum_tension,
		"an overload emits exactly one snap hook with the exceeded tension"
	)
	_expect_vector_close(
		snap_events[0].get("midpoint", Vector2.ZERO),
		expected_midpoint,
		0.001,
		"the snap hook is emitted at the rope midpoint"
	)
	var snap_flash := rope.get_node_or_null("RopeSnapFlash") as Node2D
	_expect(
		snap_flash != null and snap_flash.visible,
		"a short snap indicator appears at the rope midpoint"
	)
	if snap_flash != null:
		_expect_vector_close(
			snap_flash.global_position,
			expected_midpoint,
			0.001,
			"the snap indicator is centered on the broken rope"
		)
	await create_timer(0.1).timeout
	await process_frame
	_clear_fixture()


func _test_npc_rope_status_notifications() -> void:
	var actor := _make_body(Vector2.ZERO, 1.0)
	var npc := SocialNpc.new()
	npc.position = Vector2(100.0, 0.0)
	_fixture_nodes.append(npc)
	var status_events: Array[Vector2i] = []
	npc.rope_status_changed.connect(
		func(is_roped: bool, is_being_dragged: bool) -> void:
			status_events.append(Vector2i(
				int(is_roped),
				int(is_being_dragged)
			))
	)
	var rope := _make_rope(actor, npc, 20.0, 60.0)
	_expect(
		status_events == [Vector2i(1, 0)]
		and npc.is_roped()
		and not npc.is_being_dragged_by_rope(),
		"an NPC reports a slack attachment as roped but not dragged"
	)

	var slack_event_count := status_events.size()
	rope._physics_process(STEP)
	_expect(
		status_events.size() == slack_event_count,
		"an unchanged slack rope does not spam NPC status signals"
	)
	npc.position.x = 102.0
	rope._physics_process(STEP)
	_expect(
		status_events.back() == Vector2i(1, 1)
		and npc.is_being_dragged_by_rope(),
		"a taut load-bearing rope reports that the NPC is being dragged"
	)
	var taut_event_count := status_events.size()
	rope._physics_process(STEP)
	_expect(
		status_events.size() == taut_event_count,
		"steady rope load emits only one dragged transition"
	)
	npc.position.x = 100.0
	rope._physics_process(STEP)
	_expect(
		status_events.back() == Vector2i(1, 0),
		"a rope returning to slack keeps the NPC roped and clears dragged"
	)

	var actor_position := actor.position
	var npc_position := npc.position
	var snap_count := 0
	rope.rope_snapped.connect(
		func(_midpoint: Vector2, _tension: float) -> void:
			snap_count += 1
	)
	_expect(
		not npc.try_break_free_from_rope() and rope.active,
		"an NPC without break-free permission cannot detach its rope"
	)
	npc.can_break_free_from_rope = true
	_expect(
		npc.try_break_free_from_rope()
		and not rope.active
		and status_events.back() == Vector2i(0, 0),
		"an allowed future struggle can explicitly release the whole rope"
	)
	_expect_vector_close(
		actor.position,
		actor_position,
		0.0,
		"an NPC-requested release never moves the other endpoint"
	)
	_expect_vector_close(
		npc.position,
		npc_position,
		0.0,
		"an NPC-requested release never snaps the NPC position"
	)
	_expect(
		snap_count == 0,
		"an NPC-requested release is not reported as a tension snap"
	)

	var second_actor := _make_body(Vector2(200.0, 0.0), 1.0)
	var first_rope := _make_rope(actor, npc, 20.0, 60.0)
	var second_rope := _make_rope(second_actor, npc, 20.0, 60.0)
	var attached_event_count := status_events.size()
	first_rope.detach()
	_expect(
		npc.is_roped()
		and status_events.size() == attached_event_count,
		"detaching one of several ropes does not falsely release the NPC"
	)
	second_rope.detach()
	_expect(
		not npc.is_roped()
		and status_events.back() == Vector2i(0, 0),
		"the NPC reports release only after its final rope detaches"
	)
	_clear_fixture()

	var player := _make_body(Vector2.ZERO, 1.0)
	var rebind_npc := SocialNpc.new()
	rebind_npc.position = Vector2(40.0, 0.0)
	rebind_npc.add_to_group(&"rope_attachable")
	_fixture_nodes.append(rebind_npc)
	var other_endpoint := SocialNpc.new()
	other_endpoint.position = Vector2(90.0, 0.0)
	other_endpoint.add_to_group(&"rope_attachable")
	_fixture_nodes.append(other_endpoint)
	var rebind_events: Array[Vector2i] = []
	var other_endpoint_events: Array[Vector2i] = []
	rebind_npc.rope_status_changed.connect(
		func(is_roped: bool, is_being_dragged: bool) -> void:
			rebind_events.append(Vector2i(
				int(is_roped),
				int(is_being_dragged)
			))
	)
	other_endpoint.rope_status_changed.connect(
		func(is_roped: bool, is_being_dragged: bool) -> void:
			other_endpoint_events.append(Vector2i(
				int(is_roped),
				int(is_being_dragged)
			))
	)
	var controlled_rope := _make_unattached_rope(player)
	controlled_rope.extra_length = 0.0
	controlled_rope.track_attachable(rebind_npc)
	controlled_rope.track_attachable(other_endpoint)
	_expect(
		controlled_rope.toggle_closest_endpoint(Rope.END_X),
		"the notification rebind fixture attaches its first endpoint"
	)
	rebind_npc.position.x = 42.0
	controlled_rope._physics_process(STEP)
	_expect(
		rebind_events.back() == Vector2i(1, 1),
		"the notification rebind fixture begins under rope load"
	)
	var first_attachment_event_count := rebind_events.size()
	_expect(
		controlled_rope.toggle_closest_endpoint(Rope.END_S),
		"the notification rebind fixture attaches its second endpoint"
	)
	_expect(
		rebind_npc.is_roped()
		and rebind_npc.is_being_dragged_by_rope()
		and rebind_events.size() == first_attachment_event_count,
		"adding the second end does not falsely release or unload the NPC"
	)
	_expect(
		other_endpoint_events == [Vector2i(1, 1)]
		and float(other_endpoint.get_rope_status().get(
			"strongest_tension",
			0.0
		)) > 0.0,
		"a new endpoint receives the freshly measured rebind load"
	)
	controlled_rope.detach()
	_clear_fixture()

	var reacting_actor := _make_body(Vector2.ZERO, 1.0)
	var reacting_npc := SocialNpc.new()
	reacting_npc.position = Vector2(100.0, 0.0)
	reacting_npc.can_break_free_from_rope = true
	_fixture_nodes.append(reacting_npc)
	var reacting_events: Array[Vector2i] = []
	reacting_npc.rope_status_changed.connect(
		func(is_roped: bool, is_being_dragged: bool) -> void:
			reacting_events.append(Vector2i(
				int(is_roped),
				int(is_being_dragged)
			))
			if is_being_dragged:
				reacting_npc.try_break_free_from_rope()
	)
	var reacting_rope := _make_rope(
		reacting_actor,
		reacting_npc,
		20.0,
		60.0
	)
	reacting_npc.position.x = 102.0
	reacting_rope._physics_process(STEP)
	_expect(
		not reacting_rope.active
		and reacting_events == [
			Vector2i(1, 0),
			Vector2i(1, 1),
			Vector2i(0, 0),
		],
		"an NPC can safely break free from inside its dragged signal"
	)
	_clear_fixture()


func _test_closest_target_uses_the_attachment_point() -> void:
	var actor := _make_body(Vector2.ZERO, 1.0)
	var misleading_origin := _make_body(
		Vector2(5.0, 0.0),
		1.0,
		Vector2(100.0, 0.0)
	)
	var true_closest := _make_body(Vector2(20.0, 0.0), 1.0)
	misleading_origin.add_to_group(&"rope_attachable")
	true_closest.add_to_group(&"rope_attachable")

	var rope := Rope.new()
	var line := Line2D.new()
	line.name = "Line2D"
	rope.add_child(line)
	get_root().add_child(rope)
	_fixture_nodes.append(rope)
	rope.configure(actor, actor, null)
	rope.track_attachable(misleading_origin)
	rope.track_attachable(true_closest)

	_expect(
		rope.find_closest_attachable() == true_closest,
		"X selects the closest real attachment point, not the closest body origin"
	)
	_clear_fixture()


func _test_npc_default_weight_and_scene_contract() -> void:
	var actor := _make_body(Vector2.ZERO, 1.0)
	var npc := TestNpcWithoutWeight.new()
	npc.position = Vector2(100.0, 0.0)
	npc.add_to_group(&"npc")
	get_root().add_child(npc)
	_fixture_nodes.append(npc)
	var rope := _make_rope(actor, npc, 10.0, 0.0)
	npc.position.x = 110.0

	Rope.constrain_attached_velocity(actor, Vector2(-240.0, 0.0), STEP)
	var npc_velocity := Rope.constrain_attached_velocity(
		npc,
		Vector2.ZERO,
		STEP
	)
	var actor_velocity := Rope.constrain_attached_velocity(
		actor,
		Vector2(-240.0, 0.0),
		STEP
	)
	_expect_close(
		actor_velocity.x,
		-80.0,
		0.001,
		"an NPC without a weight uses twice the player's weight"
	)
	_expect_close(
		npc_velocity.x,
		-80.0,
		0.001,
		"the default NPC weight participates in momentum sharing"
	)
	rope.detach()
	_clear_fixture()

	var attachable_scene_paths := [
		"res://scenes/creatures/mom_npc.tscn",
		"res://scenes/creatures/npc/stateful_social_npc.tscn",
		"res://scenes/monsters/slime.tscn",
	]
	for scene_path in attachable_scene_paths:
		var packed_scene := load(scene_path) as PackedScene
		_expect(packed_scene != null, "%s loads" % scene_path)
		if packed_scene == null:
			continue
		var scene_root := packed_scene.instantiate() as CharacterBody2D
		_expect(scene_root != null, "%s has a CharacterBody2D root" % scene_path)
		if scene_root == null:
			continue
		_expect(
			scene_root.is_in_group(&"rope_attachable"),
			"%s is rope attachable" % scene_path
		)
		_expect(
			scene_root.get_node_or_null("RopeAttachPoint") is Marker2D,
			"%s provides a rope attachment marker" % scene_path
		)
		_expect_close(
			float(scene_root.get("rope_weight")),
			2.0,
			0.001,
			"%s defaults to average NPC weight" % scene_path
		)
		scene_root.free()


func _make_body(
	body_position: Vector2,
	weight: float,
	attach_offset: Vector2 = Vector2.ZERO
) -> TestBody:
	var body := TestBody.new(weight, attach_offset)
	body.position = body_position
	get_root().add_child(body)
	_fixture_nodes.append(body)
	return body


func _make_rope(
	start: Node2D,
	end: Node2D,
	give: float,
	return_speed: float
) -> Rope:
	var rope := Rope.new()
	var line := Line2D.new()
	line.name = "Line2D"
	rope.add_child(line)
	rope.extra_length = 0.0
	rope.elasticity = give
	rope.elastic_return_speed = return_speed
	rope.overstretch_recovery_speed = maxf(return_speed, 240.0)
	get_root().add_child(rope)
	_fixture_nodes.append(rope)
	_expect(rope.attach(start, end), "test rope attaches to valid endpoints")
	return rope


func _make_unattached_rope(actor: Node2D) -> Rope:
	var rope := Rope.new()
	var line := Line2D.new()
	line.name = "Line2D"
	rope.add_child(line)
	var preview := Line2D.new()
	preview.name = "ThrowPreview"
	rope.add_child(preview)
	var throw_end := Polygon2D.new()
	throw_end.name = "ThrowEnd"
	rope.add_child(throw_end)
	get_root().add_child(rope)
	_fixture_nodes.append(rope)
	rope.configure(actor, actor, null)
	return rope


func _clear_fixture() -> void:
	for node in _fixture_nodes:
		if is_instance_valid(node):
			node.free()
	_fixture_nodes.clear()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _expect_close(
	actual: float,
	expected: float,
	tolerance: float,
	message: String
) -> void:
	_expect(
		absf(actual - expected) <= tolerance,
		"%s (expected %.4f, got %.4f)" % [message, expected, actual]
	)


func _expect_vector_close(
	actual: Vector2,
	expected: Vector2,
	tolerance: float,
	message: String
) -> void:
	_expect(
		actual.distance_to(expected) <= tolerance,
		"%s (expected %s, got %s)" % [message, expected, actual]
	)


func _expect_color_close(
	actual: Color,
	expected: Color,
	tolerance: float,
	message: String
) -> void:
	_expect(
		absf(actual.r - expected.r) <= tolerance
		and absf(actual.g - expected.g) <= tolerance
		and absf(actual.b - expected.b) <= tolerance
		and absf(actual.a - expected.a) <= tolerance,
		"%s (expected %s, got %s)" % [message, expected, actual]
	)
