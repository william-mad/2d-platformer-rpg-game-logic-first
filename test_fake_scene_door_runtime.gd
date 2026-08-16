extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	await process_frame
	var controller := root.get_node_or_null("DialogueController")
	var gameplay_flow := root.get_node_or_null("GameplayFlow")
	if controller == null:
		push_error("Fake scene door test requires DialogueController.")
		quit(1)
		return
	if gameplay_flow == null:
		push_error("Fake scene door test requires GameplayFlow.")
		quit(1)
		return
	if bool(controller.call("is_dialogue_active")):
		controller.call("cancel_dialogue", "fake_scene_door_test_setup")

	var original_scene := current_scene
	var packed := load("res://scenes/testscenes/realhometest.tscn") as PackedScene
	var home := packed.instantiate()
	home.name = "FakeSceneDoorRuntimeTest"
	root.add_child(home)
	current_scene = home
	await physics_frame
	await physics_frame

	var door := home.get_node_or_null("LockedSideRoomDoor") as Area2D
	var player := home.get_node_or_null("Player") as CharacterBody2D
	_expect(door != null and player != null, "real home contains the fake side-room door and Player")
	if door != null and player != null:
		var definition := door.get("dialogue_definition") as DialogueDefinition
		var shape := door.get_node_or_null("CollisionShape2D") as CollisionShape2D
		var rectangle := shape.shape as RectangleShape2D if shape != null else null
		_expect(door.position == Vector2(528.0, 368.0), "fake door aligns with the painted door before Bathroom")
		_expect(rectangle != null and rectangle.size == Vector2(64.0, 116.0), "fake door has a focused doorway interaction area")
		_expect(definition != null and definition.get_validation_error().is_empty(), "fake-door dialogue resource validates")

		door.call("_on_body_entered", player)
		_expect(bool(door.call("can_interact", player)), "Player can attempt the fake side-room door")
		var router := player.get_node_or_null("InteractionRouter") as InteractionRouter
		_expect(router != null and router.get_focused_interactable() == door, "interaction router focuses the fake side-room door")
		_expect(router != null and _press_interact(router), "Up on the fake side-room starts modal dialogue")
		if router != null:
			_release_interact(router)
		var locked_label := player.get_node_or_null("FloatingPlayerFeedback") as Label
		var locked_audio := player.get_node_or_null("LockedDoorCueAudio") as AudioStreamPlayer2D
		_expect(locked_label != null and locked_label.text == "Door locked.", "fake door uses the shared floating locked feedback")
		_expect(locked_audio != null and locked_audio.playing, "fake door plays the shared locked-door sound")
		_expect(bool(controller.call("is_dialogue_active")), "fake-door dialogue becomes active")
		var report: Dictionary = controller.call("dump_active_dialogue")
		_expect(StringName(report.get("dialogue_id", &"")) == &"locked_side_room", "fake door starts only its authored dialogue")
		_expect(int(report.get("player_claim_token", 0)) != 0, "fake-door dialogue owns a Player control token")
		_expect(bool(gameplay_flow.call("is_player_control_claimed", player)), "fake-door dialogue claims the interacting Player")
		var dialogue_ui := controller.get_node_or_null("ModalDialogueUI") as ModalDialogueUI
		_expect(
			dialogue_ui != null
			and dialogue_ui.dialogue_label.text == "she always locks this one...",
			"fake door displays the requested observation"
		)
		_expect(current_scene == home, "fake door never changes the current scene")

		Input.action_press(&"right")
		Input.action_press(&"attack")
		player._process(0.25)
		_expect(player.direction == Vector2.ZERO, "Player movement is suppressed while the door line is open")
		_expect(is_zero_approx(player.velocity.x), "claimed Player cannot retain horizontal movement")
		var attack_release := InputEventAction.new()
		attack_release.action = &"attack"
		attack_release.pressed = false
		var state_before_attack: Node = player.current_state
		player._unhandled_input(attack_release)
		_expect(player.current_state == state_before_attack, "Player attack input is suppressed while the door line is open")
		Input.action_release(&"right")
		Input.action_release(&"attack")

		_expect(bool(controller.call("advance")), "terminal fake-door dialogue closes normally")
		_expect(not bool(controller.call("is_dialogue_active")), "fake-door dialogue releases its modal session")
		_expect(not bool(gameplay_flow.call("is_player_control_claimed", player)), "closing the door line restores Player control")

	if bool(controller.call("is_dialogue_active")):
		controller.call("cancel_dialogue", "fake_scene_door_test_cleanup")
	Input.action_release(&"right")
	Input.action_release(&"attack")
	current_scene = original_scene
	if player != null and is_instance_valid(player):
		LockedDoorCue.clear(player)
	home.queue_free()
	await process_frame
	_finish()


func _press_interact(router: InteractionRouter) -> bool:
	var event := InputEventAction.new()
	event.action = &"up"
	event.pressed = true
	return router.route_input(event)


func _release_interact(router: InteractionRouter) -> void:
	var event := InputEventAction.new()
	event.action = &"up"
	event.pressed = false
	router.route_input(event)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _finish() -> void:
	if failures.is_empty():
		print("FAKE_SCENE_DOOR_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
