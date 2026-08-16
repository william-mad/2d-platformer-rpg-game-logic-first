extends SceneTree

const FEEDBACK_SCRIPT := preload("res://scripts/instances/locked_door_feedback.gd")
const INTERIOR_DOOR_SCENE := preload("res://scenes/things/interior_door.tscn")

var failures: Array[String] = []


class TestPlayer:
	extends CharacterBody2D

	var interaction_router: InteractionRouter

	func _init() -> void:
		name = "LockedDoorFeedbackTestPlayer"
		add_to_group(&"player")
		interaction_router = InteractionRouter.new()
		interaction_router.name = "InteractionRouter"
		add_child(interaction_router)

	func register_interaction_candidate(candidate: Node) -> bool:
		return interaction_router.register_candidate(candidate)

	func unregister_interaction_candidate(candidate: Node) -> void:
		interaction_router.unregister_candidate(candidate)

	func refresh_interaction_candidate(candidate: Node = null) -> void:
		interaction_router.notify_candidate_changed(candidate)


func _initialize() -> void:
	await process_frame
	var world := Node2D.new()
	world.name = "LockedDoorFeedbackRuntimeTest"
	root.add_child(world)

	var player := TestPlayer.new()
	world.add_child(player)
	await process_frame

	await _validate_reusable_feedback_api(player)
	await _validate_travel_door_feedback(world, player)
	await _validate_interior_door_feedback(world, player)
	_validate_realhome_wiring()

	world.queue_free()
	await process_frame
	_finish()


func _validate_reusable_feedback_api(player: TestPlayer) -> void:
	var label := LockedDoorCue.show(player)
	var audio := player.get_node_or_null("LockedDoorCueAudio") as AudioStreamPlayer2D
	var cutoff := audio.get_node_or_null("Cutoff") as Timer if audio != null else null
	_expect(label != null and label.text == "Door locked.", "shared locked-door cue has a one-call default API")
	_expect(player.get_node_or_null("FloatingPlayerFeedback") == label, "shared feedback attaches to the target actor")
	_expect(audio != null and audio.stream == LockedDoorCue.DEFAULT_SOUND and audio.playing, "shared locked-door cue plays the authored lock sound")
	_expect(cutoff != null and is_equal_approx(cutoff.wait_time, 0.5), "shared lock sound is capped at half a second")
	await create_timer(0.55).timeout
	_expect(not is_instance_valid(audio), "shared lock sound stops after its half-second cutoff")
	LockedDoorCue.clear(player)
	_expect(not is_instance_valid(label), "shared feedback can be cleared without component ownership")


func _validate_travel_door_feedback(world: Node2D, player: TestPlayer) -> void:
	var door := NpcTravelDoor.new()
	door.name = "LockedTravelDoor"
	door.owner_ids = [&"mom"]
	world.add_child(door)

	var feedback = FEEDBACK_SCRIPT.new()
	feedback.name = "TravelDoorLockedFeedback"
	feedback.door_path = NodePath("../LockedTravelDoor")
	feedback.interaction_area_path = NodePath("../LockedTravelDoor")
	world.add_child(feedback)
	await process_frame
	feedback.call("_on_interaction_area_body_entered", player)

	_expect(bool(feedback.call("can_interact", player)), "private NpcTravelDoor exposes a locked feedback attempt")
	_expect(_press(player.interaction_router), "locked travel-door attempt is consumed")
	_release(player.interaction_router)
	var label := player.get_node_or_null("FloatingPlayerFeedback") as Label
	var audio := player.get_node_or_null("LockedDoorCueAudio") as AudioStreamPlayer2D
	_expect(label != null and label.text == "Door locked.", "locked travel door shows floating text")
	_expect(audio != null and audio.playing, "locked travel door plays the shared lock sound")
	_expect(not door.player_transition_accepted, "locked feedback starts no scene transition")
	await create_timer(1.1).timeout
	_expect(player.get_node_or_null("FloatingPlayerFeedback") == null, "floating locked text fades and frees itself")

	door.owner_ids = [&"mom", &"player"]
	player.refresh_interaction_candidate(feedback)
	_expect(not bool(feedback.call("can_interact", player)), "feedback candidate disables itself when travel access is restored")
	feedback.call("_on_interaction_area_body_exited", player)
	feedback.queue_free()
	door.queue_free()
	await process_frame


func _validate_interior_door_feedback(world: Node2D, player: TestPlayer) -> void:
	var door := INTERIOR_DOOR_SCENE.instantiate() as InteriorDoor
	door.name = "LockedInteriorDoor"
	door.allow_player = false
	world.add_child(door)

	var feedback = FEEDBACK_SCRIPT.new()
	feedback.name = "InteriorDoorLockedFeedback"
	feedback.door_path = NodePath("../LockedInteriorDoor")
	feedback.interaction_area_path = NodePath("../LockedInteriorDoor/RequestArea")
	world.add_child(feedback)
	await process_frame
	feedback.call("_on_interaction_area_body_entered", player)

	_expect(bool(feedback.call("can_interact", player)), "locked InteriorDoor exposes a feedback attempt")
	_expect(_press(player.interaction_router), "locked InteriorDoor attempt is consumed")
	_release(player.interaction_router)
	_expect(player.get_node_or_null("FloatingPlayerFeedback") is Label, "locked InteriorDoor shows floating text")
	_expect(not door.is_actor_granted(player), "feedback never grants InteriorDoor passage")

	door.allow_player = true
	player.refresh_interaction_candidate(feedback)
	_expect(not bool(feedback.call("can_interact", player)), "feedback candidate disables itself when InteriorDoor access returns")
	feedback.call("_on_interaction_area_body_exited", player)
	feedback.queue_free()
	door.queue_free()
	await process_frame


func _validate_realhome_wiring() -> void:
	var home_text := FileAccess.get_file_as_string("res://scenes/testscenes/realhometest.tscn")
	_expect(home_text.contains("name=\"BathroomLockedDoorFeedback\""), "real home wires bathroom locked feedback")
	_expect(home_text.contains("name=\"MomBedroomLockedDoorFeedback\""), "real home wires bedroom locked feedback")


func _press(router: InteractionRouter) -> bool:
	var event := InputEventAction.new()
	event.action = &"up"
	event.pressed = true
	return router.route_input(event)


func _release(router: InteractionRouter) -> void:
	var event := InputEventAction.new()
	event.action = &"up"
	event.pressed = false
	router.route_input(event)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _finish() -> void:
	if failures.is_empty():
		print("LOCKED_DOOR_FEEDBACK_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
