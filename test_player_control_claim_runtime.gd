extends SceneTree

var failures: Array[String] = []
var applied_interaction_count := 0


class MenuNpc:
	extends Node2D

	var hold_active := false
	var hold_begin_count := 0
	var hold_end_count := 0
	var cooldown_count := 0
	var effect_count := 0

	func begin_player_interaction_hold(_player: Node2D, _seconds: float = -1.0) -> bool:
		hold_active = true
		hold_begin_count += 1
		return true

	func end_player_interaction_hold(_player: Node2D) -> void:
		if not hold_active:
			return
		hold_active = false
		hold_end_count += 1

	func start_player_interaction_cooldown(_player: Node2D, _seconds: float) -> void:
		cooldown_count += 1

	func on_player_npc_interaction(
		_player: Node2D,
		_interaction_id: StringName,
		_delta: Dictionary,
		_set_values: Dictionary
	) -> void:
		effect_count += 1


func _initialize() -> void:
	await process_frame
	var gameplay_flow := root.get_node("GameplayFlow")
	var world_time := root.get_node("WorldTime")
	var scene_loader := root.get_node("SceneLoader")

	var world := Node2D.new()
	world.name = "PlayerControlClaimRuntimeWorld"
	root.add_child(world)
	current_scene = world
	_add_floor(world)

	var player_scene := load("res://player/player.tscn") as PackedScene
	var player = player_scene.instantiate()
	player.name = "ClaimRuntimePlayer"
	player.position = Vector2(0.0, -8.0)
	world.add_child(player)
	await _settle_player(player)
	_expect(player.is_on_floor(), "test player starts grounded")
	var idle_state = player.get_node("States/Idle")
	player.change_state(idle_state)

	var owner := Node.new()
	owner.name = "DialogueOwner"
	world.add_child(owner)
	var competitor := Node.new()
	competitor.name = "CompetingDialogueOwner"
	world.add_child(competitor)

	_test_ineligible_states(gameplay_flow, scene_loader, player, owner, world)
	await _settle_player(player)
	player.change_state(idle_state)

	var menu_npc := MenuNpc.new()
	menu_npc.name = "MenuNpc"
	menu_npc.position = Vector2(40.0, player.position.y)
	menu_npc.add_to_group(&"npc")
	world.add_child(menu_npc)
	var interactor = player.get_node("NpcTalkInteractor")
	interactor.nearby_npcs.append(menu_npc)
	interactor.interaction_applied.connect(_on_interaction_applied)
	interactor.call("_try_open_interaction_menu")
	_expect(interactor.active_menu != &"", "existing interaction menu opens")
	_expect(menu_npc.hold_active, "existing menu owns its NPC hold")

	var world_hours_before := float(world_time.call("get_total_hours"))
	var spot_action_before: StringName = player.active_spot_action
	var spot_before: Node = player.active_spot
	var token := int(gameplay_flow.call(
		"acquire_player_control_claim", owner, player, &"runtime_dialogue", &"ui_only"
	))
	_expect(token != 0, "grounded idle player receives a claim token")
	_expect(
		int(gameplay_flow.call(
			"acquire_player_control_claim", owner, player, &"same_owner", &"ui_only"
		)) == token,
		"same owner reacquires the existing token"
	)
	_expect(
		int(gameplay_flow.call(
			"acquire_player_control_claim", competitor, player, &"competitor", &"ui_only"
		)) == 0,
		"competing owner cannot take the player"
	)
	var inspected_claim: Dictionary = gameplay_flow.call("get_player_control_claim", player)
	_expect(inspected_claim.get("owner") is WeakRef, "claim stores owner as WeakRef")
	_expect(inspected_claim.get("player") is WeakRef, "claim stores player as WeakRef")
	_expect(
		StringName(inspected_claim.get("control_mode", &"")) == &"ui_only",
		"claim records ui_only mode"
	)
	_expect(player.is_gameplay_control_claimed(), "player stores the active claim")
	_expect(player.get_gameplay_control_mode() == &"ui_only", "player exposes ui_only mode")
	_expect(player.animation_player.current_animation == &"idle", "claimed player retains Idle animation")
	_expect(not paused, "player claim does not pause the SceneTree")
	_expect(not bool(gameplay_flow.call("is_world_progression_locked")), "claim does not lock world progression")
	_expect(not bool(gameplay_flow.call("is_npc_control_claimed", menu_npc)), "claim does not claim an NPC")
	_expect(player.active_spot_action == spot_action_before, "claim does not register a spot action")
	_expect(player.active_spot == spot_before, "claim does not change active spot data")

	_expect(interactor.active_menu == &"", "claim closes the old interaction menu")
	_expect(not menu_npc.hold_active, "handoff releases the old NPC hold")
	_expect(menu_npc.hold_end_count == 1, "handoff releases only one owned hold")
	_expect(menu_npc.cooldown_count == 0, "handoff starts no NPC cooldown")
	_expect(menu_npc.effect_count == 0 and applied_interaction_count == 0, "handoff applies no effects")
	_expect(is_zero_approx(interactor.cooldown), "handoff adds no local punitive cooldown")

	Input.action_press(&"right")
	Input.action_press(&"attack")
	player._process(0.25)
	_expect(player.direction == Vector2.ZERO, "movement polling is suppressed")
	_expect(is_zero_approx(player.velocity.x), "claimed horizontal velocity remains zero")
	var attack_release := InputEventAction.new()
	attack_release.action = &"attack"
	attack_release.pressed = false
	var state_before_blocked_input: Node = player.current_state
	player._unhandled_input(attack_release)
	_expect(player.current_state == state_before_blocked_input, "attack input cannot change state")
	_expect(is_zero_approx(player.mana_amount), "mana charge input is suppressed")

	Input.action_release(&"right")
	var grounded_y: float = player.position.y
	player.position.y -= 12.0
	player.velocity.y = 0.0
	await physics_frame
	_expect(player.position.y > grounded_y - 12.0, "gravity continues while claimed")
	await _settle_player(player)
	_expect(player.is_on_floor(), "collision continues while claimed")
	_expect(player.is_physics_processing(), "player physics processing remains enabled")

	world_time.call("_process", 1.0)
	_expect(
		float(world_time.call("get_total_hours")) > world_hours_before,
		"world time continues without a separate world lock"
	)
	_expect(
		not bool(gameplay_flow.call("release_player_control_claim", token, competitor)),
		"expected-owner validation rejects a competing release"
	)
	_expect(player.gameplay_control_claim_token == token, "failed release preserves the live token")

	Input.action_press(&"jump")
	_expect(
		bool(gameplay_flow.call("release_player_control_claim", token, owner)),
		"matching owner releases the claim"
	)
	_expect(not player.is_gameplay_control_claimed(), "player clears released claim state")
	_expect(player.current_state == idle_state, "grounded release leaves player Idle")
	Input.action_release(&"attack")
	Input.action_release(&"jump")
	player._unhandled_input(attack_release)
	_expect(player.current_state == idle_state, "held claim-time attack is not replayed")
	await process_frame
	await process_frame
	Input.action_press(&"right")
	player._process(0.05)
	_expect(player.direction.x > 0.0, "normal movement input resumes on the next frame")
	Input.action_release(&"right")
	player.direction = Vector2.ZERO
	player.change_state(idle_state)
	_expect(
		not bool(gameplay_flow.call("release_player_control_claim", token, owner)),
		"repeated release is harmless"
	)

	var orphan_owner := Node.new()
	orphan_owner.name = "OrphanDialogueOwner"
	world.add_child(orphan_owner)
	var orphan_token := int(gameplay_flow.call(
		"acquire_player_control_claim", orphan_owner, player, &"orphan_dialogue", &"ui_only"
	))
	_expect(orphan_token != 0, "second owner can claim after release")
	player.call("_on_player_control_claim_changed", player, false, token)
	_expect(
		player.gameplay_control_claim_token == orphan_token,
		"stale release notification cannot clear a newer claim"
	)
	_expect(is_zero_approx(player.velocity.x), "stale notification cannot change velocity")
	orphan_owner.queue_free()
	await process_frame
	await process_frame
	_expect(not bool(gameplay_flow.call("is_player_control_claimed", player)), "orphan claim is removed")
	_expect(not player.is_gameplay_control_claimed(), "orphan cleanup restores player control")
	_expect(player.current_state == idle_state, "orphan cleanup leaves grounded player Idle")

	Input.action_release(&"attack")
	Input.action_release(&"jump")
	Input.action_release(&"right")
	_finish()


func _test_ineligible_states(
	gameplay_flow: Node,
	scene_loader: Node,
	player,
	owner: Node,
	world: Node2D
) -> void:
	var state_before: Node = player.current_state
	player.is_downed = true
	_expect(_claim(gameplay_flow, owner, player) == 0, "Downed player rejects claim")
	_expect(player.current_state == state_before, "Downed rejection preserves state")
	player.is_downed = false

	player.position.y -= 40.0
	player.velocity.y = 0.0
	player.move_and_slide()
	_expect(not player.is_on_floor(), "airborne setup leaves the floor")
	state_before = player.current_state
	_expect(_claim(gameplay_flow, owner, player) == 0, "airborne player rejects claim")
	_expect(player.current_state == state_before, "airborne rejection preserves state")
	player.position.y = -1.0
	player.velocity = Vector2.ZERO
	player.move_and_slide()

	var movement_owner := Node.new()
	world.add_child(movement_owner)
	player.begin_movement_lock(movement_owner, &"work")
	state_before = player.current_state
	_expect(_claim(gameplay_flow, owner, player) == 0, "movement-locked player rejects claim")
	_expect(player.current_state == state_before, "movement-lock rejection preserves state")
	_expect(player.active_spot_action == &"work", "existing movement lock still owns its spot action")
	player.end_movement_lock(movement_owner, &"work", false)
	_expect(player.active_spot_action == &"", "existing movement-lock cleanup remains unchanged")

	var spot := Node.new()
	world.add_child(spot)
	player.begin_spot_action(spot, &"eat")
	state_before = player.current_state
	_expect(_claim(gameplay_flow, owner, player) == 0, "active spot action rejects claim")
	_expect(player.current_state == state_before, "spot-action rejection preserves state")
	player.end_spot_action(spot, &"eat", false)

	var previous_transition := bool(scene_loader.get("loading_in_progress"))
	scene_loader.set("loading_in_progress", true)
	_expect(_claim(gameplay_flow, owner, player) == 0, "scene transition rejects claim")
	scene_loader.set("loading_in_progress", previous_transition)

	player.dead = true
	_expect(_claim(gameplay_flow, owner, player) == 0, "dead player rejects claim")
	player.dead = false
	_expect(
		int(gameplay_flow.call(
			"acquire_player_control_claim", owner, player, &"unknown", &"unsupported"
		)) == 0,
		"unknown control mode rejects"
	)


func _claim(gameplay_flow: Node, owner: Node, player) -> int:
	return int(gameplay_flow.call(
		"acquire_player_control_claim", owner, player, &"eligibility_test", &"ui_only"
	))


func _add_floor(world: Node2D) -> void:
	var floor := StaticBody2D.new()
	floor.name = "Floor"
	floor.collision_layer = 1
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(800.0, 20.0)
	collision.shape = shape
	collision.position = Vector2(0.0, 10.0)
	floor.add_child(collision)
	world.add_child(floor)


func _settle_player(player) -> void:
	var frames := 0
	while not player.is_on_floor() and frames < 120:
		await physics_frame
		frames += 1


func _on_interaction_applied(_player: Node2D, _npc: Node2D, _id: StringName) -> void:
	applied_interaction_count += 1


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _finish() -> void:
	if failures.is_empty():
		print("PLAYER_CONTROL_CLAIM_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
