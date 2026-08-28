extends SceneTree

const DOOR_SCENE := preload("res://scenes/things/interior_door.tscn")

var failures: Array[String] = []


class TestNpc:
	extends CharacterBody2D

	var npc_id: StringName
	var state_name: StringName = &"walk"
	var movement_target: Vector2 = Vector2(320.0, 0.0)

	func _init(id: StringName) -> void:
		npc_id = id
		collision_layer = 4
		collision_mask = 1
		add_to_group("npc")
		var capsule := CapsuleShape2D.new()
		capsule.radius = 8.0
		capsule.height = 40.0
		var collision_shape := CollisionShape2D.new()
		collision_shape.position = Vector2(0.0, -20.0)
		collision_shape.shape = capsule
		add_child(collision_shape)

	func get_npc_location_id() -> StringName:
		return npc_id


func _initialize() -> void:
	await process_frame
	var world_simulation := root.get_node_or_null("NpcWorldSimulation")
	if world_simulation != null:
		world_simulation.set("simulation_timer", 9999.0)
	_validate_scene_structure_and_vertical_slice()
	_validate_permission_semantics()
	await _validate_player_interaction_and_cleanup()
	await _validate_npc_and_independent_passage()
	await _validate_turnaround_disappearance_and_timeout()
	await _validate_realhome_bathroom_privacy()
	await _validate_realhometest_player_slice()
	_validate_no_forbidden_integration_calls()
	_finish()


func _validate_scene_structure_and_vertical_slice() -> void:
	var door := DOOR_SCENE.instantiate() as InteriorDoor
	_expect(door != null, "InteriorDoor scene instantiates")
	if door == null:
		return
	_expect(door.get_node_or_null("DoorBarrier") is StaticBody2D, "door has a StaticBody2D barrier")
	_expect(door.get_node_or_null("DoorBarrier/CollisionShape2D") is CollisionShape2D, "barrier has a shape")
	_expect(door.get_node_or_null("RequestArea") is Area2D, "door has a request area")
	_expect(door.get_node_or_null("RequestArea/CollisionShape2D") is CollisionShape2D, "request area has a shape")
	_expect(door.get_node_or_null("ClearanceArea") is Area2D, "door has a clearance area")
	_expect(door.get_node_or_null("ClearanceArea/CollisionShape2D") is CollisionShape2D, "clearance area has a shape")
	_expect(door.get_node_or_null("VisualRoot") is Node2D, "door has a visual root")
	_expect(door.get_node_or_null("AnimationPlayer") is AnimationPlayer, "door has an animation player")
	_expect(
		door.get_interaction_action(null) == &"up",
		"InteriorDoor remains explicitly bound to Up"
	)

	var barrier := door.get_node("DoorBarrier") as StaticBody2D
	var request := door.get_node("RequestArea") as Area2D
	var clearance := door.get_node("ClearanceArea") as Area2D
	_expect(barrier.collision_layer == 1 and barrier.collision_mask == 6, "barrier blocks player and NPC bodies")
	_expect(request.collision_layer == 0 and request.collision_mask == 6, "request area listens only for actor bodies")
	_expect(clearance.collision_layer == 0 and clearance.collision_mask == 6, "clearance area listens only for actor bodies")
	var barrier_shape := (door.get_node("DoorBarrier/CollisionShape2D") as CollisionShape2D).shape as RectangleShape2D
	var request_shape := (door.get_node("RequestArea/CollisionShape2D") as CollisionShape2D).shape as RectangleShape2D
	var clearance_shape := (door.get_node("ClearanceArea/CollisionShape2D") as CollisionShape2D).shape as RectangleShape2D
	_expect(request_shape.size.x > barrier_shape.size.x, "request area grants before the barrier")
	_expect(clearance_shape.size.x > request_shape.size.x, "clearance area surrounds the request area")
	var animations := door.get_node("AnimationPlayer") as AnimationPlayer
	_expect(animations.has_animation(&"open") and animations.has_animation(&"close"), "door provides open and close animations")
	_expect(not (door.get_node("DoorBarrier/CollisionShape2D") as CollisionShape2D).disabled, "barrier starts active")
	door.free()

	var home_text := FileAccess.get_file_as_string("res://scenes/testscenes/realhometest.tscn")
	_expect(home_text.contains("path=\"res://scenes/things/interior_door.tscn\""), "realhometest references the reusable InteriorDoor")
	_expect(not home_text.contains("HallKitchenInteriorDoor"), "Hall/Kitchen divider no longer contains an InteriorDoor")
	_expect(home_text.contains("name=\"HallBathroomInteriorDoor\"") and home_text.contains("door_id = &\"hall_bathroom\""), "Hall/Bathroom door remains configured")
	_expect(home_text.contains("name=\"BedroomClassroomInteriorDoor\"") and home_text.contains("door_id = &\"bedroom_classroom\""), "Bedroom/Classroom door remains configured")
	_expect(home_text.count("[node name=\"RoomVisibilityProbe\"") == 1, "no second room visibility probe was introduced")
	_expect(home_text.contains("[connection signal=\"area_entered\" from=\"RoomVisibilityTriggers/Kitchen\" to=\"RoomVisibilityAnimation\" method=\"play\" unbinds=1 binds= [&\"kitchen\"]]"), "Kitchen visibility connection is preserved")
	_expect(home_text.contains("[connection signal=\"area_entered\" from=\"RoomVisibilityTriggers/Hall\" to=\"RoomVisibilityAnimation\" method=\"play\" unbinds=1 binds= [&\"hall\"]]"), "Hall visibility connection is preserved")
	_expect(home_text.contains("[connection signal=\"area_entered\" from=\"RoomVisibilityTriggers/Bedroom\" to=\"RoomVisibilityAnimation\" method=\"play\" unbinds=1 binds= [&\"bedroom\"]]"), "Bedroom visibility connection is preserved")
	_expect(home_text.contains("[connection signal=\"area_entered\" from=\"RoomVisibilityTriggers/Bathroom\" to=\"RoomVisibilityAnimation\" method=\"play\" unbinds=1 binds= [&\"bathroom\"]]"), "Bathroom visibility connection is preserved")
	_expect(home_text.contains("polygon = PackedVector2Array(-20, 115, 456, 115, 456, 4096, -20, 4096)"), "Kitchen visibility still ends at x=456")
	_expect(home_text.contains("polygon = PackedVector2Array(456, 115, 715, 115, 715, 4096, 456, 4096)"), "Hall visibility still begins at x=456")
	_expect(home_text.count("color = Color(0, 0, 0, 0.7)") == 9, "all nine inactive room overlays are 70 percent dark")


func _validate_permission_semantics() -> void:
	var door := DOOR_SCENE.instantiate() as InteriorDoor
	var mom := TestNpc.new(&"mom")
	mom.add_to_group("family")
	mom.set_meta("npc_tags", Array([&"mom", &"family"]))
	var stranger := TestNpc.new(&"stranger")

	_expect(door.can_npc_use(mom), "empty allow-list permits Mom")
	_expect(door.can_npc_use(stranger), "empty allow-list permits other NPCs")
	door.blocked_npc_ids = [&"mom"]
	_expect(not door.can_npc_use(mom), "blocked list wins over an empty allow-list")
	door.allowed_npc_ids = [&"mom"]
	_expect(not door.can_npc_use(mom), "blocked list wins over the allow-list")
	door.blocked_npc_ids = []
	_expect(door.can_npc_use(mom) and not door.can_npc_use(stranger), "nonempty allow-list restricts IDs")
	door.required_npc_tags = [&"mom", &"family"]
	_expect(door.can_npc_use(mom), "all required tags can come from groups and metadata")
	_expect(not door.can_npc_id_use(&"mom"), "ID-only permission cannot satisfy live tag gates")
	door.required_npc_tags = []
	_expect(door.can_npc_id_use(&"mom") and not door.can_npc_id_use(&"stranger"), "ID-only permission follows the allow-list")
	door.free()
	mom.free()
	stranger.free()


func _validate_player_interaction_and_cleanup() -> void:
	var door := _add_test_door()
	var granted_actors: Array[Node] = []
	var completed_actors: Array[Node] = []
	var opened_events: Array[StringName] = []
	var closed_events: Array[StringName] = []
	door.passage_granted.connect(func(actor: Node, _id: StringName) -> void: granted_actors.append(actor))
	door.passage_completed.connect(func(actor: Node, _id: StringName) -> void: completed_actors.append(actor))
	door.door_opened.connect(func(id: StringName) -> void: opened_events.append(id))
	door.door_closed.connect(func(id: StringName) -> void: closed_events.append(id))

	var player := CharacterBody2D.new()
	player.name = "InteriorDoorTestPlayer"
	player.collision_layer = 2
	player.collision_mask = 1
	player.add_to_group("player")
	_add_actor_collision(player)
	player.position = Vector2(-48.0, 0.0)
	root.add_child(player)

	door.call("_on_request_area_body_entered", player)
	await physics_frame
	_expect(not door.is_actor_granted(player), "player entering RequestArea does not open an interaction door")
	_expect(opened_events.is_empty(), "door stays visually closed before Up")
	_expect(not _has_exception(door, player), "player has no collision exception before Up")
	_expect(player.move_and_collide(Vector2(96.0, 0.0), true) != null, "closed barrier physically blocks the player")

	var direct_result: Dictionary = door.request_passage(player)
	_expect(bool(direct_result.get("accepted", false)), "the routed door request grants the waiting player")
	_expect(door.is_actor_granted(player), "the routed request grants passage to the waiting player")
	_expect(granted_actors == [player], "the routed request grants only the player")
	_expect(opened_events.size() == 1, "player grant opens the visual door once")
	_expect(_has_exception(door, player), "player and barrier receive reciprocal exceptions")
	_expect(not (door.get_node("DoorBarrier/CollisionShape2D") as CollisionShape2D).disabled, "grant does not disable the barrier")
	await physics_frame
	_expect(player.move_and_collide(Vector2(96.0, 0.0), true) == null, "authorized player can move normally through the barrier")

	var repeat_result: Dictionary = door.request_passage(player)
	_expect(bool(repeat_result.get("accepted")) and repeat_result.get("reason") == &"already_granted", "a repeated request is idempotent")
	_expect(granted_actors.size() == 1, "an idempotent request emits no duplicate grant")

	player.position.x = door.position.x + door.clearance_distance + 1.0
	door.call("_physics_process", 0.0)
	_expect(not door.is_actor_granted(player), "crossing beyond clearance completes player passage")
	_expect(completed_actors == [player], "player completion is reported once")
	_expect(not _has_exception(door, player), "player exception is removed after crossing")
	_expect(not (door.get_node("DoorBarrier/CollisionShape2D") as CollisionShape2D).disabled, "barrier remains active after passage")
	await create_timer(0.25).timeout
	_expect(closed_events.size() == 1, "door closes after the final grant clears")

	var held_input_player := CharacterBody2D.new()
	held_input_player.collision_layer = 2
	held_input_player.collision_mask = 1
	held_input_player.add_to_group("player")
	_add_actor_collision(held_input_player)
	held_input_player.position = Vector2(-48.0, 0.0)
	root.add_child(held_input_player)
	Input.action_press(&"up")
	door.call("_on_request_area_body_entered", held_input_player)
	Input.action_release(&"up")
	_expect(not door.is_actor_granted(held_input_player), "held input without a new routed press does not grant passage")
	door.call("_on_clearance_area_body_exited", held_input_player)

	door.queue_free()
	player.queue_free()
	held_input_player.queue_free()
	await process_frame


func _validate_npc_and_independent_passage() -> void:
	var door := _add_test_door()
	door.allowed_npc_ids = [&"mom"]
	var denied_actors: Array[Node] = []
	var opened_events: Array[StringName] = []
	var closed_events: Array[StringName] = []
	door.access_denied.connect(func(actor: Node, _id: StringName, _reason: StringName) -> void: denied_actors.append(actor))
	door.door_opened.connect(func(id: StringName) -> void: opened_events.append(id))
	door.door_closed.connect(func(id: StringName) -> void: closed_events.append(id))

	var mom := TestNpc.new(&"mom")
	mom.name = "InteriorDoorTestMom"
	mom.position = Vector2(-48.0, 0.0)
	root.add_child(mom)
	var state_before := mom.state_name
	var target_before := mom.movement_target
	door.call("_on_request_area_body_entered", mom)
	_expect(door.is_actor_granted(mom), "Mom receives automatic passage")
	_expect(_has_exception(door, mom), "Mom receives a reciprocal collision exception")
	_expect(mom.state_name == state_before and mom.movement_target == target_before, "door leaves Mom's state and target unchanged")

	var blocked := TestNpc.new(&"stranger")
	blocked.name = "InteriorDoorTestBlockedNpc"
	blocked.position = Vector2(-40.0, 0.0)
	root.add_child(blocked)
	door.call("_on_request_area_body_entered", blocked)
	await physics_frame
	_expect(not door.is_actor_granted(blocked), "unlisted NPC is denied")
	_expect(not _has_exception(door, blocked), "denied NPC receives no collision exception")
	_expect(denied_actors.size() == 1, "denied NPC emits access_denied once")
	door.request_passage(blocked)
	door.request_passage(blocked)
	_expect(denied_actors.size() == 1, "denial is suppressed while the NPC remains in RequestArea")
	_expect(opened_events.size() == 1 and bool(door.get("_door_is_open")), "denied NPC does not open the door independently")
	_expect(_has_exception(door, mom) and not _has_exception(door, blocked), "blocked NPC remains blocked while the visual door is open for Mom")
	_expect((door.get_node("DoorBarrier") as StaticBody2D).collision_layer == 1 and blocked.collision_mask & 1 != 0, "blocked NPC still physically collides with the barrier")
	_expect(mom.move_and_collide(Vector2(96.0, 0.0), true) == null, "Mom can move through without teleporting")
	_expect(blocked.move_and_collide(Vector2(80.0, 0.0), true) != null, "blocked NPC cannot cross while the visual door is open")
	_expect(mom.collision_layer & 4096 == 0, "Mom cannot activate room visibility triggers")
	door.call("_on_request_area_body_exited", blocked)
	door.call("_on_request_area_body_entered", blocked)
	_expect(denied_actors.size() == 2, "denial suppression resets after leaving RequestArea")

	var player := CharacterBody2D.new()
	player.collision_layer = 2
	player.collision_mask = 1
	player.add_to_group("player")
	_add_actor_collision(player)
	player.position = Vector2(48.0, 0.0)
	root.add_child(player)
	var player_result: Dictionary = door.request_passage(player)
	_expect(bool(player_result.get("accepted")), "a second authorized actor is granted independently")
	_expect(_has_exception(door, mom) and _has_exception(door, player), "two authorized actors hold independent exceptions")

	mom.position.x = door.position.x + door.clearance_distance + 1.0
	door.call("_physics_process", 0.0)
	_expect(not door.is_actor_granted(mom) and door.is_actor_granted(player), "Mom clearing does not remove the player's grant")
	_expect(not _has_exception(door, mom) and _has_exception(door, player), "only Mom's exception is removed")
	await create_timer(0.05).timeout
	_expect(closed_events.is_empty() and bool(door.get("_door_is_open")), "door stays open while one grant remains")

	player.position.x = door.position.x - door.clearance_distance - 1.0
	door.call("_physics_process", 0.0)
	_expect(not door.is_actor_granted(player), "second actor completes on its opposite side")
	await create_timer(0.25).timeout
	_expect(closed_events.size() == 1, "door closes only after both authorized actors clear")

	door.queue_free()
	mom.queue_free()
	blocked.queue_free()
	player.queue_free()
	await process_frame


func _validate_turnaround_disappearance_and_timeout() -> void:
	var door := _add_test_door()
	var cancellation_reasons: Array[StringName] = []
	door.passage_cancelled.connect(
		func(_actor: Node, _id: StringName, reason: StringName) -> void: cancellation_reasons.append(reason)
	)

	var mom := TestNpc.new(&"mom")
	mom.position = Vector2(-48.0, 0.0)
	root.add_child(mom)
	door.request_passage(mom)
	door.call("_on_clearance_area_body_exited", mom)
	_expect(not door.is_actor_granted(mom) and not _has_exception(door, mom), "turning back removes Mom's exception")
	_expect(cancellation_reasons == [&"turned_back"], "turnaround reports its cleanup reason")

	mom.position = Vector2(-48.0, 0.0)
	door.request_passage(mom)
	mom.queue_free()
	await process_frame
	_expect((door.get("_grants") as Dictionary).is_empty(), "a freed actor's grant is removed")
	_expect(cancellation_reasons.has(&"actor_freed"), "actor disappearance reports cleanup")

	var timeout_npc := TestNpc.new(&"mom")
	timeout_npc.position = Vector2(-48.0, 0.0)
	root.add_child(timeout_npc)
	door.passage_timeout_seconds = 0.01
	door.request_passage(timeout_npc)
	await create_timer(0.02).timeout
	door.call("_physics_process", 0.0)
	_expect(not door.is_actor_granted(timeout_npc) and not _has_exception(door, timeout_npc), "timeout removes the actor exception")
	_expect(cancellation_reasons.has(&"timeout"), "timeout reports its cleanup reason")
	await create_timer(0.25).timeout
	_expect(not bool(door.get("_door_is_open")), "door eventually closes after cancellation cleanup")

	door.queue_free()
	timeout_npc.queue_free()
	await process_frame


func _validate_realhome_bathroom_privacy() -> void:
	var home_scene := load("res://scenes/testscenes/realhometest.tscn") as PackedScene
	var home := home_scene.instantiate()
	home.name = "BathroomPrivacyRuntimeTest"
	root.add_child(home)
	await physics_frame
	await physics_frame

	var door := home.get_node_or_null("HallBathroomInteriorDoor") as InteriorDoor
	var privacy := home.get_node_or_null("BathroomPrivacy")
	var player := home.get_node_or_null("Player") as CharacterBody2D
	_expect(door != null and privacy != null, "realhometest wires bathroom privacy to its InteriorDoor")
	if door == null or privacy == null or player == null:
		home.queue_free()
		await process_frame
		return

	door.clearance_area.monitoring = false
	_expect(door.allow_player and door.can_actor_use(player), "bathroom starts available to the Player")

	var mom := TestNpc.new(&"mom")
	mom.name = "BathroomPrivacyTestMom"
	mom.position = Vector2(door.position.x - door.clearance_distance - 80.0, door.position.y)
	home.add_child(mom)
	await process_frame
	privacy.call("reconcile_from_live_state")
	_expect(door.allow_player, "live Hall-side reconciliation clears a stale bathroom lock")

	var entry_result: Dictionary = door.request_passage(mom)
	_expect(bool(entry_result.get("accepted", false)), "Mom is granted bathroom entry")
	mom.global_position.x = door.global_position.x + door.clearance_distance + 1.0
	door.call("_physics_process", 0.0)
	_expect(not door.allow_player and not door.can_actor_use(player), "Mom completing passage into Bathroom disables Player access")
	_expect(door.can_actor_use(mom), "disabled Player access does not disable Mom's access")

	var exit_result: Dictionary = door.request_passage(mom)
	_expect(bool(exit_result.get("accepted", false)), "Mom remains authorized to leave the locked bathroom")
	mom.global_position.x = door.global_position.x - door.clearance_distance - 1.0
	door.call("_physics_process", 0.0)
	_expect(door.allow_player and door.can_actor_use(player), "Mom completing passage into Hall restores Player access")

	door.allow_player = false
	privacy.call("reconcile_from_live_state")
	_expect(door.allow_player, "Hall-side live state cannot leave a stale bathroom lock")
	mom.global_position.x = door.global_position.x + door.clearance_distance + 80.0
	privacy.call("reconcile_from_live_state")
	_expect(not door.allow_player, "live initialization reconciliation locks when Mom is already inside Bathroom")
	mom.queue_free()
	await process_frame
	await process_frame
	_expect(door.allow_player, "removing live Mom reconciles away a stale bathroom lock")

	home.queue_free()
	await process_frame


func _validate_realhometest_player_slice() -> void:
	var home_scene := load("res://scenes/testscenes/realhometest.tscn") as PackedScene
	var home := home_scene.instantiate()
	home.name = "InteriorDoorRealHomeRuntimeTest"
	root.add_child(home)
	await physics_frame
	await physics_frame

	var door := home.get_node("HallBathroomInteriorDoor") as InteriorDoor
	var bedroom_door := home.get_node("BedroomClassroomInteriorDoor") as InteriorDoor
	var outside_door := home.get_node("OutsideDoor") as Area2D
	var stove := home.get_node("KitchenStove") as Area2D
	var meal_storage := home.get_node("MealIngredientStorage") as Node2D
	var meal_spot := home.get_node("MomMealCycleSpot") as Area2D
	var meal_definition := meal_spot.get("world_definition") as NpcSpotDefinition
	var meal_seats: Array[Node] = [
		home.get_node("MomMealSeat"),
		home.get_node("DadMealSeat"),
		home.get_node("MaidMealSeat"),
		home.get_node("PlayerMealSeat"),
	]
	var table_cleanup_spot := home.get_node("MealTableCleanupSpot") as Area2D
	var table_cleanup_definition := table_cleanup_spot.get("world_definition") as NpcSpotDefinition
	var sleep_spot := home.get_node("PlayerSleepSpot") as Area2D
	var shower_spot := home.get_node("MomShowerRoutineSpot") as Area2D
	var player := home.get_node("Player") as CharacterBody2D
	var room_visibility_probe := home.get_node("Player/RoomVisibilityProbe") as Area2D
	var visibility_animation := home.get_node("RoomVisibilityAnimation") as AnimationPlayer
	var barrier_shape := door.get_node("DoorBarrier/CollisionShape2D") as CollisionShape2D
	var granted_actors: Array[Node] = []
	var visibility_events: Array[StringName] = []
	door.passage_granted.connect(func(actor: Node, _id: StringName) -> void: granted_actors.append(actor))
	visibility_animation.animation_started.connect(func(animation_name: StringName) -> void: visibility_events.append(animation_name))

	_expect(door.position == Vector2(715.0, 368.0) and door.door_id == &"hall_bathroom", "Hall/Bathroom door remains at its boundary")
	_expect(bedroom_door.position == Vector2(-582.0, 368.0) and bedroom_door.door_id == &"bedroom_classroom", "Bedroom/Classroom door remains at its boundary")
	_expect(is_equal_approx(player.position.x, 680.0), "player starts near the Hall/Bathroom door")
	_expect(room_visibility_probe.collision_layer == 4096 and room_visibility_probe.collision_mask == 0, "only the player probe advertises room visibility")
	_expect(door.request_area.overlaps_body(player), "realhometest player starts inside the InteriorDoor request area")
	_expect(not outside_door.overlaps_body(player), "InteriorDoor start position does not overlap the outside transition door")
	_expect(not stove.overlaps_body(player), "InteriorDoor start position does not overlap the stove interaction")
	_expect(stove.position == Vector2(414.0, 363.0), "kitchen cooking interaction remains against the right wall")
	_expect(
		((stove.get_node("CollisionShape2D") as CollisionShape2D).shape as RectangleShape2D).size.x == 72.0,
		"kitchen cooking interaction remains squeezed to 72 pixels"
	)
	_expect(meal_spot.position == Vector2(327.0, 347.0), "Mom meal-cycle spot sits on the counter left of the kitchen stove")
	_expect(
		((meal_spot.get_node("CollisionShape2D") as CollisionShape2D).shape as RectangleShape2D).size
		== Vector2(68.0, 44.0),
		"counter preparation and its cleanup half retain the edited 68 by 44 spot size"
	)
	_expect(
		meal_definition != null
		and meal_definition.scene_path == "res://scenes/testscenes/realhometest.tscn"
		and meal_definition.position == meal_spot.position
		and meal_spot.get("eat_world_definition") == null
		and float(meal_definition.meal_cycle_cleanup_share) == 50.0,
		"meal preparation stays at the counter with one 50-point cleanup half"
	)
	var expected_seat_ids := [&"mom_eat", &"dad_meal_eat", &"maid_meal_eat", &"player_meal_eat"]
	var expected_seat_positions := [
		Vector2(60.0, 347.0),
		Vector2(95.0, 347.0),
		Vector2(130.0, 347.0),
		Vector2(165.0, 347.0),
	]
	for seat_index in meal_seats.size():
		var seat := meal_seats[seat_index] as Area2D
		var seat_definition := seat.get("world_definition") as NpcSpotDefinition
		_expect(
			seat_definition != null
			and seat_definition.spot_id == expected_seat_ids[seat_index]
			and seat.position == expected_seat_positions[seat_index]
			and seat_definition.position == seat.position
			and seat_definition.capacity == 1
			and seat_definition.meal_cycle_controller_spot_id == &"mom_eat_prep",
			"%s is a distinct controller-linked table seat" % seat.name
		)
	_expect(
		table_cleanup_definition != null
		and table_cleanup_spot.position == Vector2(105.0, 347.0)
		and table_cleanup_definition.position == table_cleanup_spot.position
		and table_cleanup_definition.meal_cycle_controller_spot_id == &"mom_eat_prep"
		and float(table_cleanup_definition.meal_cycle_cleanup_share) == 50.0,
		"table cleanup contributes the other 50 points at the table"
	)
	_expect(
		not _collision_rect(meal_spot.get_node("CollisionShape2D")).intersects(
			_collision_rect(stove.get_node("CollisionShape2D"))
		),
		"Mom meal-cycle and stove interaction boxes do not intersect"
	)
	_expect(meal_storage.position == Vector2(264.0, 371.0), "meal storage barrel sits left of the meal-cycle spot")
	_expect(
		meal_storage.get("controller_definition") == meal_definition
		and bool(meal_storage.call("is_infinite_storage"))
		and int(meal_storage.call("get_batches_per_prep")) == 4,
		"meal storage represents the household's four-batch infinite pantry"
	)
	_expect(
		meal_storage.get_node_or_null("Barrel/Sprite2D") is Sprite2D
		and (meal_storage.get_node("Barrel/Sprite2D") as Sprite2D).texture != null,
		"meal storage reuses the existing barrel artwork"
	)
	_expect(
		meal_storage.z_index
		+ (meal_storage.get_node("InfiniteLabel") as Label).z_index
		< player.z_index,
		"meal storage and its foremost decoration draw behind characters"
	)
	_expect(
		not meal_storage.has_method("interact")
		and not meal_storage.has_method("get_inventory"),
		"meal storage exposes no character inventory transfer interaction"
	)
	_expect(not _collision_rect(door.get_node("RequestArea/CollisionShape2D")).intersects(_collision_rect(stove.get_node("CollisionShape2D"))), "Bathroom door and stove interaction boxes do not intersect")
	_expect(not _collision_rect(door.get_node("RequestArea/CollisionShape2D")).intersects(_collision_rect(outside_door.get_node("CollisionShape2D"))), "Bathroom and outside-door Up boxes do not intersect")
	_expect(not _collision_rect(door.get_node("RequestArea/CollisionShape2D")).intersects(_collision_rect(shower_spot.get_node("CollisionShape2D"))), "Bathroom door and shower interaction boxes do not intersect")
	_expect(not _collision_rect(bedroom_door.get_node("RequestArea/CollisionShape2D")).intersects(_collision_rect(sleep_spot.get_node("CollisionShape2D"))), "Bedroom door and sleep interaction boxes do not intersect")
	_expect(not door.is_actor_granted(player), "live door remains closed until real Up input")
	await _press_interact()
	_expect(door.is_actor_granted(player), "realhometest Up input grants the actual player")
	_expect(granted_actors == [player], "live scene grant targets the actual player body")
	_expect(_has_exception(door, player), "live player and barrier have reciprocal exceptions")

	Input.action_press(&"right")
	for _frame in range(120):
		await physics_frame
		if player.global_position.x > 775.0:
			break
	Input.action_release(&"right")
	await process_frame
	_expect(player.global_position.x > 770.0, "actual player controller walks through the Hall/Bathroom doorway")
	_expect(visibility_events.has(&"bathroom"), "existing Bathroom visibility activates after the player crosses")
	_expect(not barrier_shape.disabled, "live door keeps its barrier active after passage")
	_expect(not bool(player.call("is_gameplay_control_claimed")), "InteriorDoor does not claim live player control")
	await physics_frame
	_expect(not door.is_actor_granted(player), "live player grant completes after clearing into Bathroom")
	await create_timer(0.45).timeout
	_expect(not bool(door.get("_door_is_open")), "live door closes behind the player")

	Input.action_press(&"left")
	for _frame in range(90):
		await physics_frame
		if player.global_position.x < 735.0:
			break
	Input.action_release(&"left")
	_expect(player.global_position.x > 722.0, "closed live door blocks the player returning from Bathroom")
	await _press_interact()
	_expect(door.is_actor_granted(player), "live door grants again from the Bathroom side")
	Input.action_press(&"left")
	for _frame in range(120):
		await physics_frame
		if player.global_position.x < 655.0:
			break
	Input.action_release(&"left")
	_expect(player.global_position.x < 660.0, "actual player returns through the doorway into Hall")
	_expect(visibility_events.has(&"hall"), "existing Hall visibility activates on the return crossing")
	await physics_frame
	_expect(not door.is_actor_granted(player), "return passage cleans up independently")
	_expect(door.request_area.overlaps_body(player), "Hall-side player remains in range to reopen the door")
	await create_timer(0.45).timeout

	Input.action_press(&"right")
	for _frame in range(90):
		await physics_frame
		if player.global_position.x > 695.0:
			break
	await physics_frame
	_expect(door.request_area.overlaps_body(player), "Hall approach enters the InteriorDoor request zone")
	_expect(not outside_door.overlaps_body(player), "Interior and outside Up interaction zones do not overlap")
	_expect(
		not stove.overlaps_body(player),
		"Interior door Up and stove Charm interactions remain separate"
	)
	await _press_interact()
	_expect(door.is_actor_granted(player), "pressing Up while pushing against the door grants reliably")
	for _frame in range(120):
		await physics_frame
		if player.global_position.x > 775.0:
			break
	Input.action_release(&"right")
	_expect(player.global_position.x > 770.0, "third live crossing succeeds without locking the player in")

	meal_definition = null
	table_cleanup_definition = null
	meal_seats.clear()
	home.queue_free()
	await process_frame


func _validate_no_forbidden_integration_calls() -> void:
	var script_text := FileAccess.get_file_as_string("res://scripts/instances/interior_door.gd")
	for forbidden_text in [
		"SceneLoader", "PlayerRuntime", "GameplayFlow", "change_scene", "request_state",
		"claim_player", "claim_scripted_control", "set_physics_process(false)", "get_tree().paused",
	]:
		_expect(not script_text.contains(forbidden_text), "InteriorDoor has no forbidden integration: %s" % forbidden_text)


func _add_test_door() -> InteriorDoor:
	var door := DOOR_SCENE.instantiate() as InteriorDoor
	door.name = "InteriorDoorRuntimeTest"
	door.door_id = &"runtime_test"
	door.position = Vector2.ZERO
	door.close_delay_seconds = 0.01
	root.add_child(door)
	door.request_area.monitoring = false
	door.clearance_area.monitoring = false
	return door


func _press_interact() -> void:
	var press := InputEventAction.new()
	press.action = &"up"
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	var release := InputEventAction.new()
	release.action = &"up"
	release.pressed = false
	Input.parse_input_event(release)
	await process_frame


func _has_exception(door: InteriorDoor, actor: PhysicsBody2D) -> bool:
	var barrier := door.get_node("DoorBarrier") as StaticBody2D
	return barrier.get_collision_exceptions().has(actor) and actor.get_collision_exceptions().has(barrier)


func _add_actor_collision(actor: CharacterBody2D) -> void:
	var capsule := CapsuleShape2D.new()
	capsule.radius = 8.0
	capsule.height = 40.0
	var collision_shape := CollisionShape2D.new()
	collision_shape.position = Vector2(0.0, -20.0)
	collision_shape.shape = capsule
	actor.add_child(collision_shape)


func _collision_rect(node: Node) -> Rect2:
	var collision_shape := node as CollisionShape2D
	if collision_shape == null:
		return Rect2()
	var rectangle := collision_shape.shape as RectangleShape2D
	if rectangle == null:
		return Rect2()
	var shape_size := Vector2(
		rectangle.size.x * absf(collision_shape.global_scale.x),
		rectangle.size.y * absf(collision_shape.global_scale.y)
	)
	return Rect2(collision_shape.global_position - shape_size * 0.5, shape_size)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _finish() -> void:
	if failures.is_empty():
		print("INTERIOR_DOOR_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
