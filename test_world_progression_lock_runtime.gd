extends SceneTree

const NpcStateMachineScript := preload("res://scenes/creatures/npc/npc_state_machine.gd")

var failures: Array[String] = []


class CountingWorldSimulation:
	extends "res://scripts/systems/npc_world_simulation.gd"

	var simulation_pass_count: int = 0

	func simulate_now() -> void:
		if _defer_simulation_while_world_progression_locked():
			return
		simulation_pass_count += 1


func _initialize() -> void:
	await process_frame

	var gameplay_flow := root.get_node("GameplayFlow")
	var world_time := root.get_node("WorldTime")
	var pause_system := root.get_node("PauseSystem")
	var simulation := CountingWorldSimulation.new()
	simulation.name = "WorldProgressionLockTestSimulation"
	root.add_child(simulation)

	var npc_machine := NpcStateMachineScript.new()
	npc_machine.name = "WorldProgressionLockTestNpcStateMachine"
	npc_machine.active = false
	root.add_child(npc_machine)
	npc_machine.passive_needs_tick_seconds = 10.0
	npc_machine.passive_need_elapsed_seconds = 3.25

	var player_scene := load("res://player/player.tscn") as PackedScene
	var player := player_scene.instantiate() as Node
	player.name = "WorldProgressionLockTestPlayer"
	root.add_child(player)
	player.set("hunger", 20.0)
	player.set("sleep_need", 10.0)
	player.set("max_hp", 20.0)
	player.set("hp", 10.0)

	var owner_a := Node.new()
	owner_a.name = "WorldProgressionOwnerA"
	root.add_child(owner_a)
	var owner_b := Node.new()
	owner_b.name = "WorldProgressionOwnerB"
	root.add_child(owner_b)

	simulation.simulation_timer = 4.5
	var starting_total_hours := float(world_time.call("get_total_hours"))
	var token_a := int(gameplay_flow.call(
		"acquire_world_progression_lock", owner_a, &"runtime_test_a"
	))
	_expect(token_a != 0, "first lock token is nonzero")
	var inspected_locks: Array = gameplay_flow.call("get_world_progression_locks")
	_expect(inspected_locks.size() == 1, "lock inspection returns the active token")
	if inspected_locks.size() == 1:
		_expect(
			int(inspected_locks[0].get("token_id", 0)) == token_a
			and StringName(inspected_locks[0].get("reason", &"")) == &"runtime_test_a"
			and inspected_locks[0].get("owner") is WeakRef,
			"lock inspection includes token, reason, and owner WeakRef"
		)

	world_time.call("_process", 1.0)
	_expect_close(
		float(world_time.call("get_total_hours")),
		starting_total_hours,
		"automatic WorldTime progression is locked"
	)
	world_time.call("advance_real_seconds", 1.0)
	_expect(
		float(world_time.call("get_total_hours")) > starting_total_hours,
		"explicit WorldTime advancement remains available"
	)

	simulation._process(1.0)
	_expect_close(simulation.simulation_timer, 4.5, "simulation timer is preserved")
	simulation._queue_simulation()
	simulation._queue_simulation()
	simulation._run_queued_simulation()
	_expect(simulation.simulation_pass_count == 0, "deferred simulation cannot run while locked")
	_expect(simulation.simulation_dirty_while_locked, "locked simulation request sets one dirty flag")

	npc_machine._update_passive_needs(5.0)
	_expect_close(
		npc_machine.passive_need_elapsed_seconds,
		3.25,
		"NPC passive partial timer is preserved"
	)
	player.call("update_player_needs", 5.0)
	player.call("update_passive_healing", 5.0)
	_expect_close(float(player.get("hunger")), 20.0, "player hunger is locked")
	_expect_close(float(player.get("sleep_need")), 10.0, "player sleep need is locked")
	_expect_close(float(player.get("hp")), 10.0, "player passive healing is locked")
	_expect(not paused, "an event lock does not pause the SceneTree")
	_expect(player.is_physics_processing(), "player physics remains enabled")
	_expect(player.get_node_or_null("AnimationPlayer") != null, "player animation system remains available")

	var token_b := int(gameplay_flow.call(
		"acquire_world_progression_lock", owner_b, &"runtime_test_b"
	))
	_expect(token_b != 0 and token_b != token_a, "lock tokens are unique")
	_expect(
		not bool(gameplay_flow.call("release_world_progression_lock", token_a, owner_b)),
		"a different expected owner cannot release the token"
	)
	_expect(
		bool(gameplay_flow.call("release_world_progression_lock", token_a, owner_a)),
		"the matching owner releases its token"
	)
	_expect(
		not bool(gameplay_flow.call("release_world_progression_lock", token_a, owner_a)),
		"releasing an already released token is harmless"
	)
	_expect(bool(gameplay_flow.call("is_world_progression_locked")), "second token keeps progression locked")

	var auto_advance_before_pause := bool(world_time.get("auto_advance"))
	pause_system.call("set_paused", true, false)
	_expect(paused, "PauseSystem still pauses the SceneTree")
	var first_pause_token := int(pause_system.get("world_progression_lock_token"))
	pause_system.call("set_paused", true, false)
	var pause_token := int(pause_system.get("world_progression_lock_token"))
	_expect(pause_token != 0, "PauseSystem owns one token while paused")
	_expect(pause_token == first_pause_token, "repeated pause calls do not acquire duplicate tokens")
	pause_system.call("set_paused", false, false)
	_expect(not paused, "PauseSystem still unpauses the SceneTree")
	_expect(
		bool(world_time.get("auto_advance")) == auto_advance_before_pause,
		"PauseSystem does not overwrite WorldTime.auto_advance"
	)
	_expect(
		bool(gameplay_flow.call("is_world_progression_locked")),
		"closing pause does not release another owner's token"
	)

	_expect(
		bool(gameplay_flow.call("release_world_progression_lock", token_b, owner_b)),
		"final event token releases"
	)
	_expect(not bool(gameplay_flow.call("is_world_progression_locked")), "final release unlocks progression")
	_expect(simulation.simulation_queued, "dirty unlock queues one fresh simulation")
	_expect_close(simulation.simulation_timer, 4.5, "unlock does not reset the simulation timer")

	await process_frame
	await process_frame
	_expect(simulation.simulation_pass_count == 1, "dirty requests coalesce into exactly one simulation pass")
	_expect(not simulation.simulation_dirty_while_locked, "dirty flag clears on final unlock")

	npc_machine._update_passive_needs(1.0)
	_expect_close(
		npc_machine.passive_need_elapsed_seconds,
		4.25,
		"NPC passive timer resumes without catch-up"
	)
	player.call("update_player_needs", 1.0)
	player.call("update_passive_healing", 1.0)
	_expect(float(player.get("hunger")) > 20.0, "player hunger resumes without a reset")
	_expect(float(player.get("sleep_need")) > 10.0, "player sleep need resumes without a reset")
	_expect(float(player.get("hp")) > 10.0, "player passive healing resumes")

	var orphan_owner := Node.new()
	root.add_child(orphan_owner)
	gameplay_flow.call("acquire_world_progression_lock", orphan_owner, &"runtime_test_orphan")
	orphan_owner.queue_free()
	paused = true
	await process_frame
	await process_frame
	_expect(
		not bool(gameplay_flow.call("is_world_progression_locked")),
		"freed lock owners are cleaned up while the SceneTree is paused"
	)
	paused = false

	_finish()


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_close(actual: float, expected: float, label: String) -> void:
	if not is_equal_approx(actual, expected):
		failures.append("%s: expected %.4f, got %.4f" % [label, expected, actual])


func _finish() -> void:
	if failures.is_empty():
		print("WORLD_PROGRESSION_LOCK_RUNTIME_OK")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)
