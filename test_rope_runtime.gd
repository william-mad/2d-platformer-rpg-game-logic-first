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
	_test_drag_speed_scales_with_weight()
	_test_elastic_give_is_smooth_and_never_moves_positions_directly()
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
	rope.passive_swing_damping = 0.8
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

	var npc_scene_paths := [
		"res://scenes/creatures/mom_npc.tscn",
		"res://scenes/creatures/npc/stateful_social_npc.tscn",
	]
	for scene_path in npc_scene_paths:
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
	rope.stretch_margin = give
	rope.elastic_return_speed = return_speed
	rope.overstretch_recovery_speed = maxf(return_speed, 240.0)
	get_root().add_child(rope)
	_fixture_nodes.append(rope)
	_expect(rope.attach(start, end), "test rope attaches to valid endpoints")
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
