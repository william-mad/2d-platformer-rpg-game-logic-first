extends SceneTree

const AnimationControllerScript = preload("res://scenes/creatures/npc/npc_animation_controller.gd")
const StateMachineScript = preload("res://scenes/creatures/npc/npc_state_machine.gd")
const WorkStateScript = preload("res://scenes/creatures/npc/states/work.gd")

var _failures: Array[String] = []


class TestNpc:
	extends CharacterBody2D

	var direction: int = 1


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
	npc.queue_free()


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
	var player := mom.get_node_or_null("AnimationPlayer") as AnimationPlayer
	var enabled_flip_tracks := 0
	if player != null:
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
	var authored_follow := mom.get_node_or_null("NpcStateMachine/TravelFollow")
	if authored_follow != null:
		authored_follow.set("show_follow_debug_paths", true)
	root.add_child(mom)
	await process_frame

	var machine := mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
	var player := mom.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_expect(
		machine != null and machine.current_state != null and String(machine.current_state.name) == "TravelFollow",
		"a recreated active companion enters TravelFollow immediately"
	)
	_expect(
		player != null and player.current_animation == &"run" and player.is_playing(),
		"a recreated active companion keeps the TravelFollow run animation"
	)

	# PlayerRuntime repeats this request after the destination player and NPC registry settle.
	# It must not leave the already-active follow state displaying an autoplayed idle clip.
	var request_failure_count := 0
	if machine != null:
		machine.state_request_failed.connect(func(_state_name: StringName, _reason: String) -> void:
			request_failure_count += 1
		)
	var history_size := machine.state_history.size() if machine != null else -1
	runtime.call("_enable_live_companion_follow", mom)
	runtime.call("_enable_live_companion_follow", mom)
	await process_frame
	_expect(
		player != null and player.current_animation == &"run" and player.is_playing(),
		"the deferred companion restore preserves the TravelFollow run animation"
	)
	_expect(request_failure_count == 0, "repeated follow activation emits no state rejection")
	_expect(
		machine != null and machine.state_history.size() == history_size,
		"repeated follow activation does not re-enter or duplicate TravelFollow"
	)
	var overlays := mom.find_children(
		"TravelFollowDebugOverlay", "NpcFollowDebugOverlay", false, false
	)
	_expect(overlays.size() == 1, "initial TravelFollow can attach one opt-in debug overlay after ready")

	mom.queue_free()
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


func _add_animation(library: AnimationLibrary, animation_name: StringName) -> void:
	var animation := Animation.new()
	animation.length = 1.0
	library.add_animation(animation_name, animation)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
