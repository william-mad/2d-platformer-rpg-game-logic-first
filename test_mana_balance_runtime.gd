extends SceneTree

const MANA_BALANCE_SCENE := preload(
	"res://scenes/activities/mana_balance/mana_balance_module.tscn"
)

var failures: Array[String] = []
var result_change_count: int = 0
var player_claim_signal_count: int = 0
var xp_signal_count: int = 0
var npc_finish_signal_count: int = 0


func _initialize() -> void:
	await process_frame
	var world := Node.new()
	root.add_child(world)
	var source := InteractiveActivityInputSource.new()
	world.add_child(source)
	source.configure(InteractiveActivityInputProfile.new())
	source.set_activity_input_enabled(true)

	var invalid_module := MANA_BALANCE_SCENE.instantiate() as ManaBalanceModule
	world.add_child(invalid_module)
	var invalid_config := _make_config()
	invalid_config.warning_radius = invalid_config.perfect_radius
	_expect(
		not invalid_module.configure(
			_make_context("invalid-config", invalid_config),
			source
		),
		"invalid configuration is rejected"
	)
	invalid_module.queue_free()
	await process_frame

	var module := MANA_BALANCE_SCENE.instantiate() as ManaBalanceModule
	world.add_child(module)
	var config := _make_config()
	config.required_concentration = 10.0
	_expect(
		module.configure(_make_context("rules-session", config), source),
		"valid Mana Balance configuration is accepted"
	)
	module.result_changed.connect(_on_result_changed)
	module.start_activity()
	_expect(
		module.is_running()
		and is_zero_approx(module.get_concentration())
		and int(module.get_result().get("successes", -1)) == 0,
		"start resets and begins runtime state"
	)
	var orb := module.get_controlled_orb()
	orb.set_movement_enabled(false)
	orb.reset_orb(Vector2.ZERO)
	module._physics_process(0.4)
	var filled_concentration := module.get_concentration()
	_expect(
		is_equal_approx(filled_concentration, 0.4),
		"perfect-zone time fills concentration"
	)
	orb.reset_orb(Vector2(config.perfect_radius + 1.0, 0.0))
	module._physics_process(0.4)
	var warning_concentration := module.get_concentration()
	_expect(
		is_equal_approx(warning_concentration, 0.3),
		"warning-zone time drains concentration slowly"
	)
	orb.reset_orb(Vector2(config.warning_radius + 1.0, 0.0))
	module._physics_process(0.4)
	var failure_concentration := module.get_concentration()
	_expect(
		is_zero_approx(failure_concentration)
		and filled_concentration - warning_concentration
			< warning_concentration - failure_concentration,
		"failure-zone time drains faster than warning-zone time"
	)

	orb.reset_orb(Vector2.ZERO)
	module._physics_process(0.51)
	_expect(
		is_equal_approx(module.get_current_multiplier(), 2.0),
		"uninterrupted perfect hold increases the multiplier"
	)
	orb.reset_orb(Vector2(config.perfect_radius + 1.0, 0.0))
	module._physics_process(0.01)
	_expect(
		is_equal_approx(module.get_current_multiplier(), 1.0),
		"leaving the perfect zone resets the multiplier streak"
	)

	result_change_count = 0
	orb.reset_orb(Vector2.ZERO)
	for _index in 25:
		module._physics_process(0.001)
	_expect(
		result_change_count < 25,
		"result_changed is not emitted every physics frame"
	)
	var first_stop := module.stop_activity(&"rules_complete")
	var repeated_stop := module.stop_activity(&"ignored_repeat")
	_expect(first_stop == repeated_stop, "stop is idempotent")
	_expect(_has_standard_result_fields(first_stop), "final result contains all standard fields")

	var gameplay_flow := root.get_node_or_null("GameplayFlow")
	var progression := root.get_node_or_null("ProgressionSystem")
	var npc_simulation := root.get_node_or_null("NpcWorldSimulation")
	if gameplay_flow != null:
		gameplay_flow.player_control_claim_changed.connect(_on_player_claim_changed)
	if progression != null:
		progression.global_xp_changed.connect(_on_xp_changed)
		progression.skill_xp_changed.connect(_on_skill_xp_changed)
		progression.reward_applied.connect(_on_reward_applied)
	if npc_simulation != null:
		npc_simulation.activity_finished.connect(_on_npc_activity_finished)

	var success_module := MANA_BALANCE_SCENE.instantiate() as ManaBalanceModule
	world.add_child(success_module)
	var success_config := _make_config()
	success_config.required_concentration = 0.5
	success_config.maximum_force_strength = 100.0
	_expect(
		success_module.configure(
			_make_context("success-session", success_config),
			source
		),
		"success fixture configures"
	)
	success_module.start_activity()
	var success_orb := success_module.get_controlled_orb()
	success_orb.set_movement_enabled(false)
	success_orb.reset_orb(Vector2.ZERO)
	success_module._physics_process(0.5)
	var first_success_result := success_module.get_result()
	_expect(
		int(first_success_result.get("successes", 0)) == 1
		and int(first_success_result.get("attempts", 0)) == 1,
		"reaching required concentration registers exactly one success"
	)
	_expect(
		is_equal_approx(float(first_success_result.get("score", 0.0)), 200.0),
		"success score uses the earned multiplier"
	)
	_expect(
		success_orb.get_orb_position() == Vector2.ZERO
		and success_orb.get_orb_velocity() == Vector2.ZERO,
		"success reset recenters the orb and clears velocity"
	)
	success_module._physics_process(0.1)
	_expect(
		int(success_module.get_result().get("successes", 0)) == 1,
		"success reset cannot duplicate a success"
	)
	success_module._physics_process(1.0)
	success_orb.set_movement_enabled(false)
	success_orb.reset_orb(Vector2.ZERO)
	success_module._physics_process(0.5)
	success_module._physics_process(1.0)
	success_orb.set_movement_enabled(false)
	success_orb.reset_orb(Vector2.ZERO)
	success_module._physics_process(0.5)
	_expect(
		is_equal_approx(success_module.get_current_force_strength(), 100.0),
		"current strength increases and remains capped"
	)
	var score_before_terminal := float(success_module.get_result().get("score", 0.0))
	var terminal_result := success_module.stop_activity(&"lesson_completed")
	var repeated_terminal_result := success_module.stop_activity(&"repeat")
	_expect(
		float(repeated_terminal_result.get("score", 0.0)) == score_before_terminal
		and int(repeated_terminal_result.get("successes", 0))
			== int(terminal_result.get("successes", 0)),
		"repeated terminal calls do not duplicate successes or score"
	)
	_expect(
		player_claim_signal_count == 0,
		"module does not acquire or release player claims"
	)
	_expect(xp_signal_count == 0, "module does not award XP")
	_expect(npc_finish_signal_count == 0, "module does not finish NPC activities")

	var module_source := FileAccess.get_file_as_string(
		"res://scripts/activities/mana_balance/mana_balance_module.gd"
	)
	_expect(
		module_source.find("GameplayFlow") == -1
		and module_source.find("ProgressionSystem") == -1
		and module_source.find("NpcWorldSimulation") == -1
		and module_source.find("Input.") == -1,
		"module remains independent from authority, rewards, scheduling, and global input"
	)

	if gameplay_flow != null:
		gameplay_flow.player_control_claim_changed.disconnect(_on_player_claim_changed)
	if progression != null:
		progression.global_xp_changed.disconnect(_on_xp_changed)
		progression.skill_xp_changed.disconnect(_on_skill_xp_changed)
		progression.reward_applied.disconnect(_on_reward_applied)
	if npc_simulation != null:
		npc_simulation.activity_finished.disconnect(_on_npc_activity_finished)
	world.queue_free()
	await process_frame

	if failures.is_empty():
		print("MANA_BALANCE_RUNTIME_OK")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _make_context(session_id: String, config: ManaBalanceConfig) -> Dictionary:
	return {
		"session_id": session_id,
		"activity_id": "mana_balance",
		"module_config": config,
	}


func _make_config() -> ManaBalanceConfig:
	var config := ManaBalanceConfig.new()
	config.orb_acceleration = 100.0
	config.orb_drag = 20.0
	config.orb_maximum_speed = 200.0
	config.arena_size = Vector2(160.0, 120.0)
	config.starting_force_strength = 90.0
	config.force_increase_per_success = 8.0
	config.maximum_force_strength = 120.0
	config.force_change_interval = 10.0
	config.perfect_radius = 10.0
	config.warning_radius = 25.0
	config.concentration_fill_rate = 1.0
	config.warning_drain_rate = 0.25
	config.failure_drain_rate = 0.75
	config.required_concentration = 3.0
	config.multiplier_seconds_per_step = 0.25
	config.maximum_multiplier = 3.0
	config.base_success_score = 100.0
	config.reset_delay_seconds = 0.2
	return config


func _has_standard_result_fields(result: Dictionary) -> bool:
	var required_keys := [
		"activity_id",
		"session_id",
		"status",
		"finish_reason",
		"elapsed_seconds",
		"score",
		"attempts",
		"successes",
		"failures",
		"details",
	]
	for key in required_keys:
		if not result.has(key):
			return false
	var details: Dictionary = result.get("details", {})
	return (
		details.has("best_multiplier")
		and details.has("longest_perfect_hold")
		and details.has("final_force_strength")
		and details.has("final_concentration")
	)


func _on_result_changed(_result: Dictionary) -> void:
	result_change_count += 1


func _on_player_claim_changed(_player: Node, _claimed: bool, _token_id: int) -> void:
	player_claim_signal_count += 1


func _on_xp_changed(
	_current_xp: int,
	_delta: int,
	_source_id: StringName,
	_context: Dictionary
) -> void:
	xp_signal_count += 1


func _on_skill_xp_changed(
	_domain_id: StringName,
	_current_xp: int,
	_delta: int,
	_source_id: StringName,
	_context: Dictionary
) -> void:
	xp_signal_count += 1


func _on_reward_applied(_reward_id: StringName, _context: Dictionary) -> void:
	xp_signal_count += 1


func _on_npc_activity_finished(_npc_id: StringName, _spot_id: StringName) -> void:
	npc_finish_signal_count += 1


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
