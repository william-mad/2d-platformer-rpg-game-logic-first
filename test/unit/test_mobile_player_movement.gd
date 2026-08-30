extends "res://test/native_scene_tree_test.gd"

const PLAYER_SCENE := preload("res://player/player.tscn")
const INTRO_WALK_SCENE := preload("res://scenes/levels/intro_walk_interlude.tscn")
const ProgressionIds := preload("res://scripts/progression/progression_ids.gd")

var player: Player


func before_each() -> void:
	var progression := root.get_node_or_null("ProgressionSystem") as GameProgressionSystem
	if progression != null:
		progression.reset_progression(false)
	player = PLAYER_SCENE.instantiate() as Player
	player.force_mobile_gameplay = true
	add_child_autofree(player)
	player.set_process(false)
	player.set_physics_process(false)


func test_mobile_profile_uses_run_speed_on_ground_and_in_air() -> void:
	var idle := player.get_node("States/Idle") as PlayerStateIdle
	var walk := player.get_node("States/Walk") as PlayerStateWalk
	var run := player.get_node("States/Run") as PlayerStateRun
	var jump := player.get_node("States/Jump") as PlayerStateJump
	var fall := player.get_node("States/Fall") as PlayerStateFall
	player.direction = Vector2.RIGHT

	assert_same(idle.get_ground_movement_state(), run, "mobile ground movement should enter Run")
	assert_same(walk.process(0.0), run, "mobile Walk should immediately hand off to Run")
	assert_true(
		is_equal_approx(
			player.get_run_speed(),
			player.level_one_run_speed * player.mobile_run_speed_multiplier
		),
		"mobile movement should use the slightly faster run speed"
	)

	player.change_state(run)
	player.change_state(jump)
	assert_true(jump.is_using_running_profile(), "mobile jumping should retain the Run profile")
	assert_true(
		is_equal_approx(jump.get_air_movement_speed(), player.get_run_speed()),
		"mobile air control should use Run speed"
	)
	assert_true(
		jump.active_jump_velocity > jump.maximum_jump_velocity * sqrt(0.5),
		"mobile jump launch should be slightly stronger than the old level-one jump"
	)

	player.change_state(fall)
	assert_true(fall.is_using_running_profile(), "mobile falling should retain the Run profile")
	assert_true(
		is_equal_approx(fall.get_air_movement_speed(), player.get_run_speed()),
		"mobile falling should keep Run-speed air control"
	)


func test_intro_walk_profile_preserves_the_authored_walk() -> void:
	var idle := player.get_node("States/Idle") as PlayerStateIdle
	var walk := player.get_node("States/Walk") as PlayerStateWalk
	player.set_intro_walk_movement_profile(true)
	player.direction = Vector2.RIGHT

	assert_false(player.uses_mobile_run_profile(), "intro should suspend mobile run-only movement")
	assert_same(
		idle.get_ground_movement_state_for_profile(false),
		walk,
		"intro movement should still select Walk"
	)
	assert_true(
		is_equal_approx(player.get_run_speed(), player.level_one_run_speed),
		"intro should not inherit the mobile speed boost"
	)


func test_x_dash_is_direct_level_one_input_and_larger_on_mobile() -> void:
	var dash := player.get_node("States/Dash") as PlayerStateDash
	assert_true(InputMap.has_action(&"dash"), "the direct dash action should exist")
	assert_true(
		player.is_player_ability_unlocked(ProgressionIds.ABILITY_DASH),
		"dash should already be unlocked at level 1"
	)
	player.direction = Vector2.LEFT

	var left_event := InputEventAction.new()
	left_event.action = &"left"
	left_event.pressed = true
	assert_null(dash.get_dash_state_from_input(left_event), "a first direction press should not dash")
	assert_null(dash.get_dash_state_from_input(left_event), "double-tapping direction should not dash")

	var dash_event := InputEventAction.new()
	dash_event.action = &"dash"
	dash_event.pressed = true
	assert_same(dash.get_dash_state_from_input(dash_event), dash, "direct X action should request Dash")
	assert_eq(dash.dash_direction, -1.0, "dash should follow the held movement direction")
	assert_true(
		dash.get_effective_dash_speed() > dash.dash_speed,
		"mobile dash should start faster than the normal dash"
	)
	assert_true(
		dash.get_effective_dash_duration() > dash.dash_duration,
		"mobile dash should travel for longer than the normal dash"
	)


func test_mobile_rope_detector_is_disabled() -> void:
	assert_false(player.rope_detector.monitoring, "mobile gameplay should remove rope detection work")
	assert_false(player.rope_detector.monitorable, "mobile rope detector should not be targetable")


func test_walkable_intro_shows_only_arrows_then_hides_them_for_scripted_sequence() -> void:
	var intro := INTRO_WALK_SCENE.instantiate() as IntroWalkInterlude
	var intro_player := intro.get_node("World/Player") as Player
	intro.next_scene_path = ""
	intro_player.force_mobile_gameplay = true
	add_child_autofree(intro)
	var hud := root.get_node("PlayerHud") as CanvasLayer
	var hud_content := hud.get_node("Control") as Control
	var controls := hud.get_node("MobileGameplayControls") as MobileGameplayControls

	assert_true(hud.visible, "walkable intro should expose the mobile control layer")
	assert_false(hud_content.visible, "walkable intro should keep the normal HUD hidden")
	assert_true(
		controls.is_intro_movement_only(),
		"walkable intro should expose arrows without gameplay buttons"
	)
	assert_false(
		intro_player.uses_mobile_run_profile(),
		"walkable intro should keep its authored walking profile"
	)

	intro.call("_begin_scripted_approach")
	assert_false(hud.visible, "scripted intro sequence should hide the movement arrows")
	assert_false(
		controls.is_intro_movement_only(),
		"scripted intro sequence should release intro-only touch input"
	)
	intro.free()
