extends SceneTree

const ROUTER_SCRIPT := preload("res://player/scripts/interaction_router.gd")
const INTERIOR_DOOR_SCENE := preload("res://scenes/things/interior_door.tscn")

var failures: Array[String] = []


class TestActor:
	extends CharacterBody2D

	var interaction_router: Node
	var world_interaction_block_reason: StringName = &""

	func register_interaction_candidate(candidate: Node) -> bool:
		return bool(interaction_router.call("register_candidate", candidate))

	func unregister_interaction_candidate(candidate: Node) -> void:
		interaction_router.call("unregister_candidate", candidate)

	func refresh_interaction_candidate(candidate: Node = null) -> void:
		interaction_router.call("notify_candidate_changed", candidate)

	func get_world_interaction_block_reason() -> StringName:
		return world_interaction_block_reason

	func can_accept_player_control_claim(_control_mode: StringName) -> Dictionary:
		return {"accepted": true, "reason": &""}


class TestCandidate:
	extends Node2D

	var priority: int = 0
	var eligible: bool = true
	var consumes: bool = true
	var dispatch_count: int = 0
	var prompt: String = "Test interaction"
	var focused: bool = false

	func _init(candidate_priority: int = 0, candidate_position := Vector2.ZERO) -> void:
		priority = candidate_priority
		position = candidate_position

	func can_interact(_actor: Node) -> bool:
		return eligible

	func interact(_actor: Node) -> bool:
		dispatch_count += 1
		return consumes

	func get_interaction_priority(_actor: Node) -> int:
		return priority

	func get_interaction_prompt(_actor: Node) -> String:
		return prompt

	func set_interaction_focused(_actor: Node, is_focused: bool) -> void:
		focused = is_focused


func _initialize() -> void:
	await process_frame
	var world := Node2D.new()
	world.name = "PlayerInteractionRouterRuntimeWorld"
	root.add_child(world)
	current_scene = world

	await _validate_priority_and_duplicate_registration(world)
	await _validate_distance_stability_and_freed_focus(world)
	await _validate_control_authority_blocks(world)
	await _validate_real_interior_door(world)

	world.queue_free()
	await process_frame
	_finish()


func _validate_priority_and_duplicate_registration(world: Node2D) -> void:
	var actor := _add_actor(world, "PriorityActor")
	var low := _add_candidate(world, "LowPriority", 10, Vector2(8.0, 0.0))
	var high := _add_candidate(world, "HighPriority", 20, Vector2(80.0, 0.0))

	_expect(actor.register_interaction_candidate(low), "valid low-priority candidate registers")
	_expect(actor.register_interaction_candidate(high), "valid high-priority candidate registers")
	_expect(actor.register_interaction_candidate(high), "duplicate registration is idempotent")
	var snapshot: Dictionary = actor.interaction_router.call("get_debug_snapshot")
	_expect(int(snapshot.get("candidate_count", -1)) == 2, "duplicate registration creates no duplicate candidate")
	_expect(
		actor.interaction_router.call("get_focused_interactable") == high,
		"highest priority wins even when farther away"
	)
	_expect(high.focused and not low.focused, "only the router-selected candidate receives prompt focus")
	_expect(
		String(actor.interaction_router.call("get_interaction_prompt")) == high.prompt,
		"the shared prompt getter follows router focus"
	)

	_expect(_press(actor.interaction_router), "a focused interaction press is handled")
	_expect(_press(actor.interaction_router), "a duplicate pressed event is swallowed")
	_expect(high.dispatch_count == 1, "one physical hold cannot dispatch twice before release")
	_release(actor.interaction_router)
	_expect(high.dispatch_count == 1, "selected candidate is dispatched exactly once")
	_expect(low.dispatch_count == 0, "one press does not dispatch a second candidate")

	high.consumes = false
	_expect(_press(actor.interaction_router), "a selected but rejecting candidate still owns its press")
	_release(actor.interaction_router)
	_expect(high.dispatch_count == 2, "the rejecting selected candidate is called only once")
	_expect(low.dispatch_count == 0, "a rejection does not fall through to another candidate")
	_expect(
		StringName(actor.interaction_router.call("get_debug_snapshot").get("last_block_reason"))
		== &"candidate_rejected",
		"a selected candidate rejection is inspectable"
	)

	actor.queue_free()
	low.queue_free()
	high.queue_free()
	await process_frame


func _validate_distance_stability_and_freed_focus(world: Node2D) -> void:
	var actor := _add_actor(world, "FocusActor")
	var first := _add_candidate(world, "FirstPeer", 10, Vector2(100.0, 0.0))
	var focused_peer := _add_candidate(world, "FocusedPeer", 10, Vector2(50.0, 0.0))
	actor.register_interaction_candidate(first)
	actor.register_interaction_candidate(focused_peer)
	_expect(
		actor.interaction_router.call("get_focused_interactable") == focused_peer,
		"distance breaks an equal-priority tie"
	)

	first.position = Vector2(45.0, 0.0)
	actor.interaction_router.call("refresh_focus")
	_expect(
		actor.interaction_router.call("get_focused_interactable") == focused_peer,
		"small distance changes do not make focus flicker"
	)
	first.position = Vector2(30.0, 0.0)
	actor.interaction_router.call("refresh_focus")
	_expect(
		actor.interaction_router.call("get_focused_interactable") == first,
		"a peer switches focus after clearing the distance margin"
	)

	var temporary_high := _add_candidate(world, "TemporaryHigh", 30, Vector2(500.0, 0.0))
	actor.register_interaction_candidate(temporary_high)
	_expect(
		actor.interaction_router.call("get_focused_interactable") == temporary_high,
		"a clearly higher-priority candidate takes focus"
	)
	temporary_high.queue_free()
	await process_frame
	_expect(
		actor.interaction_router.call("get_focused_interactable") == first,
		"freeing the focused candidate safely falls back to a live candidate"
	)
	var snapshot: Dictionary = actor.interaction_router.call("get_debug_snapshot")
	_expect(int(snapshot.get("candidate_count", -1)) == 2, "freed candidates are removed from the registry")

	actor.queue_free()
	first.queue_free()
	focused_peer.queue_free()
	await process_frame


func _validate_control_authority_blocks(world: Node2D) -> void:
	var actor := _add_actor(world, "AuthorityActor")
	var candidate := _add_candidate(world, "AuthorityCandidate", 10, Vector2.ZERO)
	actor.register_interaction_candidate(candidate)
	var gameplay_flow := root.get_node("GameplayFlow")
	var scene_loader := root.get_node("SceneLoader")
	var claim_owner := Node.new()
	claim_owner.name = "InteractionClaimOwner"
	world.add_child(claim_owner)

	var previous_paused := paused
	paused = true
	_expect(_press(actor.interaction_router), "a full-pause press is swallowed")
	_release(actor.interaction_router)
	_expect(candidate.dispatch_count == 0, "full pause blocks world dispatch")
	_expect(
		StringName(actor.interaction_router.call("get_debug_snapshot").get("last_block_reason"))
		== &"full_pause",
		"the full-pause block reason is inspectable"
	)
	paused = previous_paused

	var claim_token := int(gameplay_flow.call(
		"acquire_player_control_claim", claim_owner, actor, &"modal_dialogue", &"ui_only"
	))
	_expect(claim_token != 0, "test player receives an existing GameplayFlow control claim")
	_expect(_press(actor.interaction_router), "a claimed-player press is swallowed")
	_release(actor.interaction_router)
	_expect(candidate.dispatch_count == 0, "a player control claim blocks world dispatch")
	_expect(
		StringName(actor.interaction_router.call("get_debug_snapshot").get("last_block_reason"))
		== &"player_control_claimed",
		"the control-claim block reason is inspectable"
	)
	_expect(
		bool(gameplay_flow.call("release_player_control_claim", claim_token, claim_owner)),
		"test control claim releases cleanly"
	)

	actor.world_interaction_block_reason = &"player_spot_action_active"
	_expect(_press(actor.interaction_router), "an activity-owned press is swallowed")
	_release(actor.interaction_router)
	_expect(candidate.dispatch_count == 0, "an active player activity blocks world dispatch")
	_expect(
		StringName(actor.interaction_router.call("get_debug_snapshot").get("last_block_reason"))
		== &"player_spot_action_active",
		"the activity block reason is inspectable"
	)
	actor.world_interaction_block_reason = &""

	var previous_loading := bool(scene_loader.get("loading_in_progress"))
	scene_loader.set("loading_in_progress", true)
	_expect(_press(actor.interaction_router), "a transition-owned press is swallowed")
	_release(actor.interaction_router)
	_expect(candidate.dispatch_count == 0, "a scene transition blocks world dispatch")
	_expect(
		StringName(actor.interaction_router.call("get_debug_snapshot").get("last_block_reason"))
		== &"scene_transition_in_progress",
		"the scene-transition block reason is inspectable"
	)
	scene_loader.set("loading_in_progress", previous_loading)

	_expect(_press(actor.interaction_router), "dispatch resumes after authority blocks clear")
	_release(actor.interaction_router)
	_expect(candidate.dispatch_count == 1, "cleared authority state permits one dispatch")

	actor.queue_free()
	candidate.queue_free()
	claim_owner.queue_free()
	await process_frame


func _validate_real_interior_door(world: Node2D) -> void:
	var actor := _add_actor(world, "InteriorDoorActor")
	actor.position = Vector2(-48.0, 0.0)
	var door := INTERIOR_DOOR_SCENE.instantiate() as InteriorDoor
	door.name = "InteractionRouterInteriorDoor"
	door.position = Vector2.ZERO
	door.close_delay_seconds = 0.0
	door.allow_player = false
	world.add_child(door)
	door.call("_on_request_area_body_entered", actor)

	_expect(
		actor.interaction_router.call("get_focused_interactable") == null,
		"an inaccessible InteriorDoor is not focusable"
	)
	_expect(not _press(actor.interaction_router), "no candidate is dispatched through a denied door")
	_release(actor.interaction_router)
	_expect(not door.is_actor_granted(actor), "a denied InteriorDoor grants no passage")

	door.allow_player = true
	actor.refresh_interaction_candidate(door)
	_expect(
		actor.interaction_router.call("get_focused_interactable") == door,
		"an accessible InteriorDoor becomes the selected interactable"
	)
	_expect(_press(actor.interaction_router), "the real InteriorDoor interaction is routed")
	_release(actor.interaction_router)
	_expect(door.is_actor_granted(actor), "the routed InteriorDoor interaction grants passage")
	_expect(
		bool(actor.interaction_router.call("get_debug_snapshot").get("last_interaction_consumed")),
		"the real door reports a consumed interaction"
	)

	door.call("_on_request_area_body_exited", actor)
	_expect(
		actor.interaction_router.call("get_focused_interactable") == null,
		"leaving an InteriorDoor interaction area clears router focus"
	)
	door.queue_free()
	actor.queue_free()
	await process_frame


func _add_actor(world: Node2D, actor_name: String) -> TestActor:
	var actor := TestActor.new()
	actor.name = actor_name
	actor.add_to_group(&"player")
	var router := ROUTER_SCRIPT.new()
	router.name = "InteractionRouter"
	actor.interaction_router = router
	actor.add_child(router)
	world.add_child(actor)
	return actor


func _add_candidate(
	world: Node2D,
	candidate_name: String,
	priority: int,
	position: Vector2
) -> TestCandidate:
	var candidate := TestCandidate.new(priority, position)
	candidate.name = candidate_name
	world.add_child(candidate)
	return candidate


func _press(router: Node) -> bool:
	var event := InputEventAction.new()
	event.action = &"up"
	event.pressed = true
	return bool(router.call("route_input", event))


func _release(router: Node) -> void:
	var event := InputEventAction.new()
	event.action = &"up"
	event.pressed = false
	router.call("route_input", event)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _finish() -> void:
	if failures.is_empty():
		print("PLAYER_INTERACTION_ROUTER_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
