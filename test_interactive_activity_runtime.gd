extends SceneTree

const PROBE_SCENE := preload(
	"res://tests/fixtures/probe_interactive_activity_module.tscn"
)
const HOST_SCENE := preload(
	"res://scenes/activities/interactive_activity_host.tscn"
)

var failures: Array[String] = []
var release_count: int = 0
var finish_signal_count: int = 0
var cancel_signal_count: int = 0
var local_shutdown_signal_count: int = 0
var latest_runner_result: Dictionary = {}
var tracked_player: Node


func _initialize() -> void:
	await process_frame
	var gameplay_flow := root.get_node_or_null("GameplayFlow")
	if gameplay_flow == null:
		push_error("Interactive activity runtime test requires GameplayFlow.")
		quit(1)
		return

	var original_scene := current_scene
	var world := Node2D.new()
	world.name = "InteractiveActivityRuntimeWorld"
	root.add_child(world)
	current_scene = world
	_add_floor(world)

	var hidden_authority := Node2D.new()
	hidden_authority.name = "HiddenAuthority"
	hidden_authority.visible = false
	world.add_child(hidden_authority)
	var presentation_parent := Node.new()
	presentation_parent.name = "VisiblePresentationParent"
	world.add_child(presentation_parent)

	var player_scene := load("res://player/player.tscn") as PackedScene
	var player := player_scene.instantiate()
	tracked_player = player
	player.name = "InteractiveActivityPlayer"
	player.position = Vector2(0.0, -8.0)
	world.add_child(player)
	await _settle_player(player)
	_expect(player.is_on_floor(), "grounded available player fixture settles")
	player.change_state(player.get_node("States/Idle"))

	gameplay_flow.player_control_claim_changed.connect(_on_player_claim_changed)
	var runner := InteractiveActivityRunner.new()
	runner.name = "InteractiveActivityRunner"
	hidden_authority.add_child(runner)
	runner.result_changed.connect(_on_runner_result_changed)
	runner.activity_finished.connect(_on_runner_finished)
	runner.activity_cancelled.connect(_on_runner_cancelled)
	runner.local_shutdown.connect(_on_runner_local_shutdown)

	var first_definition := _make_definition(&"probe_one", "Probe One")
	var second_definition := _make_definition(&"probe_two", "Probe Two")
	var single_definitions: Array[InteractiveActivityDefinition] = [first_definition]
	var context := {"session_id": "interactive-session-one", "source": "runtime_test"}
	var rope_target := Node2D.new()
	rope_target.name = "ExternalActivityRopeTarget"
	rope_target.position = Vector2(64.0, -8.0)
	rope_target.add_to_group(&"rope_attachable")
	world.add_child(rope_target)
	_expect(
		player.rope.attach(player, rope_target, player.rope_origin, rope_target),
		"player preparation fixture attaches through the existing Rope API"
	)
	player.mana_amount = 25.0
	player.direction = Vector2.RIGHT
	player.velocity.x = 120.0
	var prepare_result := runner.prepare_activity(
		player,
		single_definitions,
		context,
		presentation_parent,
		Vector2(80.0, 120.0)
	)
	_expect(bool(prepare_result.get("accepted", false)), "grounded player can be prepared")
	var first_token := runner.get_player_claim_token()
	_expect(first_token != 0, "runner receives a nonzero exact player-control token")
	var claim: Dictionary = gameplay_flow.get_player_control_claim(player)
	var owner_ref := claim.get("owner") as WeakRef
	_expect(
		int(claim.get("token_id", 0)) == first_token
		and owner_ref != null
		and owner_ref.get_ref() == runner,
		"GameplayFlow records the runner as exact claim owner"
	)
	_expect(
		not gameplay_flow.is_world_progression_locked(),
		"interactive preparation acquires no world-progression lock"
	)
	_expect(
		player.active_spot_action == &"" and player.active_spot == null,
		"interactive preparation creates no player spot action"
	)
	_expect(
		is_zero_approx(player.mana_amount)
		and player.direction == Vector2.ZERO
		and is_zero_approx(player.velocity.x)
		and not player.rope.active,
		"player preparation detaches rope and clears charge and horizontal intent"
	)
	var first_host := runner.get_presentation_host()
	_expect(first_host != null, "preparation instances the presentation host")
	_expect(
		first_host.get_parent() == presentation_parent,
		"visible host is parented under the supplied presentation parent"
	)
	_expect(
		not hidden_authority.is_ancestor_of(first_host),
		"visible host is not parented below the hidden authority"
	)
	_expect(
		first_host.get_active_module() != null and not first_host.is_selecting(),
		"single definition is configured for direct start"
	)
	_expect(runner.commit_activity(), "prepared single activity commits")
	_expect(
		first_host.get_active_module().is_running(),
		"single definition starts directly on commit"
	)

	var input_source := runner.get_input_source()
	var captured_actions := input_source.profile.get_captured_actions()
	_expect(
		captured_actions.has(&"crouch")
		and captured_actions.has(&"attack")
		and captured_actions.has(&"attach_rope")
		and captured_actions.has(&"inventory")
		and captured_actions.has(&"stats"),
		"activity profile consumes movement, attack, rope, inventory, and stats input"
	)
	_expect(
		not captured_actions.has(&"pause")
		and input_source.profile.is_pass_through_action(&"pause"),
		"pause remains delegated to the existing pause system"
	)
	input_source._input(_action_event(&"right", true))
	input_source._input(_action_event(&"up", true))
	input_source._input(_action_event(&"attack", true))
	var snapshot := input_source.get_snapshot()
	var expected_movement := Vector2(1.0, -1.0).normalized()
	_expect(
		(snapshot.get("movement", Vector2.ZERO) as Vector2).is_equal_approx(expected_movement),
		"input snapshot exposes normalized directional movement"
	)
	_expect(
		bool((snapshot.get("pressed", {}) as Dictionary).get("confirm", false)),
		"input snapshot exposes confirm pressed this frame"
	)
	_expect(
		runner.consume_player_interaction_input(player),
		"runner delegates shared up-interaction consumption to the input source"
	)
	first_host.get_active_module().publish_result({
		"score": 3.0,
		"details": {"probe_update": true},
	})
	_expect(
		float(latest_runner_result.get("score", 0.0)) == 3.0,
		"probe result changes reach the runner"
	)
	first_host.get_active_module()._process(0.01)
	_expect(
		runner.state == InteractiveActivityRunner.STATE_FINISHING,
		"probe finish request begins terminal cleanup"
	)
	_expect(
		runner.get_presentation_host() == null,
		"terminal cleanup removes presentation before claim handoff"
	)
	_expect(
		gameplay_flow.is_player_control_claimed(player),
		"held activity input briefly retains the claim"
	)
	input_source._input(_action_event(&"right", false))
	input_source._input(_action_event(&"up", false))
	input_source._input(_action_event(&"attack", false))
	runner._process(0.0)
	_expect(runner.state == InteractiveActivityRunner.STATE_CLOSED, "neutral handoff closes runner")
	_expect(not gameplay_flow.is_player_control_claimed(player), "normal finish releases exact claim")
	_expect(release_count == 1, "normal finish releases the player claim once")
	var first_result := runner.get_result()
	_expect(
		String(first_result.get("status", "")) == "completed"
		and float(first_result.get("score", 0.0)) == 12.5
		and bool((first_result.get("details", {}) as Dictionary).get("probe_confirmed", false)),
		"probe standardized result reaches the runner"
	)
	runner.finish_activity(&"repeat_finish")
	runner.cancel_activity(&"repeat_cancel")
	runner.shutdown_local(&"repeat_shutdown")
	_expect(release_count == 1, "repeated terminal calls are harmless")

	var multiple_definitions: Array[InteractiveActivityDefinition] = [
		first_definition,
		second_definition,
	]
	var second_prepare := runner.prepare_activity(
		player,
		multiple_definitions,
		{"session_id": "interactive-session-two"},
		presentation_parent,
		Vector2.ZERO
	)
	_expect(bool(second_prepare.get("accepted", false)), "runner can prepare a newer session")
	var second_token := runner.get_player_claim_token()
	_expect(second_token != 0 and second_token != first_token, "new session owns a new exact token")
	_expect(runner.commit_activity(), "multiple-definition activity commits")
	var second_host := runner.get_presentation_host()
	_expect(
		second_host != null
		and second_host.is_selecting()
		and second_host.get_active_module() == null,
		"multiple definitions enter selection mode without instancing a module"
	)
	var stale_result := first_result.duplicate(true)
	stale_result["session_id"] = "interactive-session-one"
	runner._on_host_finish_requested(stale_result)
	_expect(
		runner.state == InteractiveActivityRunner.STATE_RUNNING
		and runner.get_player_claim_token() == second_token,
		"stale module callback cannot terminate the newer session"
	)
	_expect(second_host.select_definition(1), "selection instances the chosen definition")
	_expect(
		second_host.get_active_module() != null
		and second_host.get_active_module().is_running(),
		"selected probe module starts"
	)
	runner.cancel_activity(&"test_cancel")
	_expect(not gameplay_flow.is_player_control_claimed(player), "cancellation releases exact claim")
	_expect(release_count == 2 and cancel_signal_count == 1, "cancellation releases and emits once")
	runner.cancel_activity(&"repeat_cancel")
	_expect(release_count == 2 and cancel_signal_count == 1, "repeated cancellation is harmless")

	var third_prepare := runner.prepare_activity(
		player,
		single_definitions,
		{"session_id": "interactive-session-three"},
		presentation_parent,
		Vector2.ZERO
	)
	_expect(bool(third_prepare.get("accepted", false)), "local-shutdown fixture prepares")
	_expect(runner.commit_activity(), "local-shutdown fixture commits")
	var successful_finishes_before_shutdown := finish_signal_count
	runner.shutdown_local(&"scene_unloaded")
	_expect(not gameplay_flow.is_player_control_claimed(player), "local shutdown releases exact claim")
	_expect(
		String(runner.get_result().get("status", "")) == "local_shutdown",
		"local shutdown reports a non-success terminal status"
	)
	_expect(
		finish_signal_count == successful_finishes_before_shutdown
		and local_shutdown_signal_count == 1,
		"local resumable shutdown does not claim successful activity completion"
	)
	_expect(release_count == 3, "local shutdown releases its claim once")

	var invalid_host_root := Node.new()
	var invalid_host_scene := PackedScene.new()
	_expect(
		invalid_host_scene.pack(invalid_host_root) == OK,
		"invalid-host failure fixture packs"
	)
	invalid_host_root.free()
	runner.host_scene = invalid_host_scene
	var presentation_children_before := presentation_parent.get_child_count()
	var failed_prepare := runner.prepare_activity(
		player,
		single_definitions,
		{"session_id": "interactive-failed-prepare"},
		presentation_parent,
		Vector2.ZERO
	)
	_expect(not bool(failed_prepare.get("accepted", false)), "invalid host rejects preparation")
	_expect(
		runner.get_player_claim_token() == 0
		and not gameplay_flow.is_player_control_claimed(player),
		"failed preparation leaks no player claim"
	)
	_expect(
		presentation_parent.get_child_count() == presentation_children_before,
		"failed preparation leaks no presentation host"
	)
	_expect(release_count == 4, "partial preparation releases its acquired claim once")
	runner.host_scene = HOST_SCENE

	var always_show := _make_launch_options(
		InteractiveActivityLaunchOptions.SelectionPolicy.ALWAYS_SHOW
	)
	var releases_before_policy_tests := release_count
	var always_prepare := runner.prepare_activity(
		player,
		single_definitions,
		{"session_id": "interactive-always-single"},
		presentation_parent,
		Vector2.ZERO,
		always_show
	)
	_expect(bool(always_prepare.get("accepted", false)), "ALWAYS_SHOW single prepares")
	var always_host := runner.get_presentation_host()
	_expect(
		always_host != null
		and always_host.get_active_module() == null,
		"ALWAYS_SHOW does not instance a single module before commit"
	)
	_expect(runner.commit_activity(), "ALWAYS_SHOW single commits")
	_expect(
		always_host.is_selecting()
		and always_host.get_active_module() == null,
		"ALWAYS_SHOW displays selection and starts no module before confirmation"
	)
	var always_input := runner.get_input_source()
	always_input._input(_action_event(&"attack", true))
	always_host._process(0.0)
	var confirmed_module := always_host.get_active_module()
	_expect(
		confirmed_module != null
		and confirmed_module.is_running()
		and not always_host.is_selecting(),
		"menu confirmation instances and starts exactly one module"
	)
	always_input.clear_one_frame_states()
	always_input._input(_action_event(&"attack", true))
	always_host._process(0.0)
	_expect(
		always_host.get_active_module() == confirmed_module,
		"repeated confirm cannot instance a duplicate module"
	)
	always_input._input(_action_event(&"attack", false))
	runner.cancel_activity(&"always_single_cancel")
	_expect(
		release_count == releases_before_policy_tests + 1,
		"cancellation after ALWAYS_SHOW confirmation releases one exact claim"
	)

	var direct_single := _make_launch_options(
		InteractiveActivityLaunchOptions.SelectionPolicy.DIRECT_IF_SINGLE
	)
	var direct_prepare := runner.prepare_activity(
		player,
		single_definitions,
		{"session_id": "interactive-direct-single"},
		presentation_parent,
		Vector2.ZERO,
		direct_single
	)
	_expect(bool(direct_prepare.get("accepted", false)), "DIRECT_IF_SINGLE prepares")
	var direct_host := runner.get_presentation_host()
	_expect(
		direct_host != null
		and direct_host.get_active_module() != null
		and not direct_host.is_selecting(),
		"DIRECT_IF_SINGLE preconfigures one module without selection"
	)
	_expect(runner.commit_activity(), "DIRECT_IF_SINGLE commits")
	_expect(
		direct_host.get_active_module().is_running(),
		"DIRECT_IF_SINGLE starts its sole module"
	)
	runner.cancel_activity(&"direct_single_cancel")

	for policy in [
		InteractiveActivityLaunchOptions.SelectionPolicy.ALWAYS_SHOW,
		InteractiveActivityLaunchOptions.SelectionPolicy.DIRECT_IF_SINGLE,
	]:
		var multi_options := _make_launch_options(policy)
		var multi_prepare := runner.prepare_activity(
			player,
			multiple_definitions,
			{"session_id": "interactive-policy-multi-%d" % int(policy)},
			presentation_parent,
			Vector2.ZERO,
			multi_options
		)
		_expect(
			bool(multi_prepare.get("accepted", false))
			and runner.commit_activity(),
			"selection policy %d prepares and commits multiple definitions" % int(policy)
		)
		var policy_host := runner.get_presentation_host()
		_expect(
			policy_host != null
			and policy_host.is_selecting()
			and policy_host.get_active_module() == null,
			"selection policy %d displays multiple definitions" % int(policy)
		)
		var claims_before_menu_cancel := release_count
		runner.cancel_activity(&"menu_cancel")
		_expect(
			release_count == claims_before_menu_cancel + 1,
			"menu cancellation releases exactly one claim for policy %d" % int(policy)
		)

	_expect(
		release_count == releases_before_policy_tests + 4,
		"selection policies do not change one-claim-per-session ownership"
	)
	var policy_source := FileAccess.get_file_as_string(
		"res://scripts/activities/interactive_activity_launch_options.gd"
	)
	_expect(
		policy_source.find("Magic") == -1
		and policy_source.find("Mana") == -1
		and policy_source.find("Lesson") == -1,
		"selection policy remains generic"
	)

	_expect(
		not gameplay_flow.is_world_progression_locked(),
		"framework never acquires a world-progression lock"
	)
	_expect(finish_signal_count == 1, "successful finish signal emits exactly once")
	gameplay_flow.player_control_claim_changed.disconnect(_on_player_claim_changed)
	current_scene = original_scene
	world.queue_free()
	await process_frame
	await process_frame

	if failures.is_empty():
		print("INTERACTIVE_ACTIVITY_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _make_definition(
	activity_id: StringName,
	display_name: String
) -> InteractiveActivityDefinition:
	var definition := InteractiveActivityDefinition.new()
	definition.id = activity_id
	definition.display_name = display_name
	definition.description = "Runtime probe activity."
	definition.module_scene = PROBE_SCENE
	definition.input_profile = InteractiveActivityInputProfile.new()
	definition.metadata = {"presentation_mount": "world"}
	return definition


func _make_launch_options(
	policy: InteractiveActivityLaunchOptions.SelectionPolicy
) -> InteractiveActivityLaunchOptions:
	var options := InteractiveActivityLaunchOptions.new()
	options.selection_policy = policy
	return options


func _action_event(action: StringName, pressed: bool) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	return event


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


func _settle_player(player: CharacterBody2D) -> void:
	var frames := 0
	while not player.is_on_floor() and frames < 120:
		await physics_frame
		frames += 1


func _on_player_claim_changed(player: Node, claimed: bool, _token_id: int) -> void:
	if player == tracked_player and not claimed:
		release_count += 1


func _on_runner_result_changed(result: Dictionary) -> void:
	latest_runner_result = result.duplicate(true)


func _on_runner_finished(result: Dictionary) -> void:
	finish_signal_count += 1
	latest_runner_result = result.duplicate(true)


func _on_runner_cancelled(_reason: StringName, result: Dictionary) -> void:
	cancel_signal_count += 1
	latest_runner_result = result.duplicate(true)


func _on_runner_local_shutdown(_reason: StringName, result: Dictionary) -> void:
	local_shutdown_signal_count += 1
	latest_runner_result = result.duplicate(true)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
