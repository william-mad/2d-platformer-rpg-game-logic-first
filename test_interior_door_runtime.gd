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
	_expect(home_text.contains("polygon = PackedVector2Array(-20, -4096, 456, -4096, 456, 4096, -20, 4096)"), "Kitchen visibility still ends at x=456")
	_expect(home_text.contains("polygon = PackedVector2Array(456, -4096, 715, -4096, 715, 4096, 456, 4096)"), "Hall visibility still begins at x=456")
	_expect(home_text.count("color = Color(0, 0, 0, 0.7)") == 5, "all five inactive room overlays are 70 percent dark")


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

	Input.action_press(&"up")
	await process_frame
	await process_frame
	Input.action_release(&"up")
	_expect(door.is_actor_granted(player), "Up grants passage to the waiting player")
	_expect(granted_actors == [player], "Up grants only the player")
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
	_expect(door.is_actor_granted(held_input_player), "Up held while entering the request area still grants passage")
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
	_expect(not _collision_rect(door.get_node("RequestArea/CollisionShape2D")).intersects(_collision_rect(stove.get_node("CollisionShape2D"))), "Bathroom door and stove Up boxes do not intersect")
	_expect(not _collision_rect(door.get_node("RequestArea/CollisionShape2D")).intersects(_collision_rect(outside_door.get_node("CollisionShape2D"))), "Bathroom and outside-door Up boxes do not intersect")
	_expect(not _collision_rect(door.get_node("RequestArea/CollisionShape2D")).intersects(_collision_rect(shower_spot.get_node("CollisionShape2D"))), "Bathroom door and shower interaction boxes do not intersect")
	_expect(not _collision_rect(bedroom_door.get_node("RequestArea/CollisionShape2D")).intersects(_collision_rect(sleep_spot.get_node("CollisionShape2D"))), "Bedroom door and sleep interaction boxes do not intersect")
	_expect(not door.is_actor_granted(player), "live door remains closed until real Up input")
	Input.action_press(&"up")
	await process_frame
	await process_frame
	Input.action_release(&"up")
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
	Input.action_press(&"up")
	await process_frame
	await process_frame
	Input.action_release(&"up")
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
	_expect(not stove.overlaps_body(player), "Interior door and stove Up interactions remain separate")
	Input.action_press(&"up")
	await process_frame
	await process_frame
	Input.action_release(&"up")
	_expect(door.is_actor_granted(player), "pressing Up while pushing against the door grants reliably")
	for _frame in range(120):
		await physics_frame
		if player.global_position.x > 775.0:
			break
	Input.action_release(&"right")
	_expect(player.global_position.x > 770.0, "third live crossing succeeds without locking the player in")

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
