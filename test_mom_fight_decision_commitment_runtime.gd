extends "res://test/native_scene_tree_test.gd"


class FacingProbeMachine:
	extends NpcStateMachine

	var faced_directions: Array[float] = []

	func face_x_direction(x_direction: float) -> void:
		faced_directions.append(signf(x_direction))


class PlayerSpeedProbe:
	extends CharacterBody2D

	var move_speed: float = 520.0


class DecisionCostProbe:
	extends MomNpcFightState

	var bystander_queries: int = 0
	var movement_metric_queries: int = 0

	func _get_attack_blocking_bystander_for_mode(_attack_mode: int) -> Node2D:
		bystander_queries += 1
		return null

	func _get_melee_reach_distance() -> float:
		movement_metric_queries += 1
		return 100.0

	func _get_fight_move_speed() -> float:
		movement_metric_queries += 1
		return 700.0


class MeleeDashProbe:
	extends MomNpcFightState

	var melee_attack_count: int = 0

	func _get_melee_reach_distance() -> float:
		return 100.0

	func _get_attack_blocking_bystander_for_mode(_attack_mode: int) -> Node2D:
		return null

	func _do_melee_attack(
		_swing_angle_degrees: float,
		_can_queue_hit_followup: bool = true
	) -> void:
		melee_attack_count += 1


func test_authored_mom_scene_uses_the_stable_fight_state() -> void:
	var packed := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	assert_not_null(packed, "Mom NPC scene loads")
	if packed == null:
		return
	var mom := packed.instantiate()
	var fight := mom.get_node_or_null("NpcStateMachine/Fight") as MomNpcFightState
	assert_not_null(fight, "Mom scene uses the specialized Fight state")
	if fight != null:
		assert_true(
			fight.combat_decision_commitment_seconds > 0.0,
			"Mom's authored Fight state enables short decision commitment"
		)
	mom.free()


func test_small_range_jitter_does_not_toggle_chase_every_frame() -> void:
	var fixture := _create_fight_probe()
	var npc := fixture.get("npc") as CharacterBody2D
	var target := fixture.get("target") as CharacterBody2D
	var fight := fixture.get("fight") as MomNpcFightState
	if npc == null or target == null or fight == null:
		return

	var movement_states: Array[bool] = []
	for distance in [259.0, 261.0, 259.0, 261.0, 259.0, 261.0, 259.0, 261.0]:
		target.global_position = npc.global_position + Vector2(distance, 0.0)
		fight.call("_update_chase")
		movement_states.append(not is_zero_approx(npc.velocity.x))
		_advance_commitment_if_supported(fight, 1.0 / 60.0)

	assert_true(
		_count_bool_transitions(movement_states) <= 1,
		"tiny range jitter keeps one short chase/hold decision instead of stop-starting every frame"
	)
	_advance_commitment_if_supported(fight, 2.0 / 60.0)
	target.global_position = npc.global_position + Vector2(261.0, 0.0)
	fight.call("_update_chase")
	assert_true(
		is_zero_approx(npc.velocity.x),
		"range decisions refresh shortly after the commitment window"
	)


func test_small_target_crossing_does_not_flip_facing_every_frame() -> void:
	var fixture := _create_fight_probe()
	var npc := fixture.get("npc") as CharacterBody2D
	var target := fixture.get("target") as CharacterBody2D
	var fight := fixture.get("fight") as MomNpcFightState
	var machine := fixture.get("machine") as FacingProbeMachine
	if npc == null or target == null or fight == null or machine == null:
		return

	for distance in [4.0, -4.0, 4.0, -4.0, 4.0, -4.0, 4.0, -4.0]:
		target.global_position = npc.global_position + Vector2(distance, 0.0)
		fight.call("_face_fight_target")
		_advance_commitment_if_supported(fight, 1.0 / 60.0)

	assert_true(
		_count_float_transitions(machine.faced_directions) <= 1,
		"tiny target crossings retain facing briefly instead of flipping every frame"
	)
	target.global_position = npc.global_position + Vector2(-40.0, 0.0)
	fight.call("_face_fight_target")
	assert_eq(
		machine.faced_directions.back(),
		-1.0,
		"facing can flip after the short hold when the target is outside the deadzone"
	)


func test_repeated_frames_reuse_the_committed_safety_and_movement_snapshot() -> void:
	var cost_probe := DecisionCostProbe.new()
	var fixture := _create_fight_probe(cost_probe)
	var npc := fixture.get("npc") as CharacterBody2D
	var target := fixture.get("target") as CharacterBody2D
	if npc == null or target == null:
		return

	target.global_position = npc.global_position + Vector2(300.0, 0.0)
	for _frame in 8:
		cost_probe.call("_update_chase")
		_advance_commitment_if_supported(cost_probe, 1.0 / 60.0)

	assert_true(
		cost_probe.bystander_queries <= 1,
		"bystander safety discovery is reused during the decision window"
	)
	assert_true(
		cost_probe.movement_metric_queries <= 2,
		"collision reach and target speed are cached during the decision window"
	)


func test_authored_mom_fight_chase_uses_her_run_speed_not_the_players() -> void:
	var packed := load("res://scenes/creatures/mom_npc.tscn") as PackedScene
	var mom := packed.instantiate() if packed != null else null
	assert_not_null(mom, "Mom NPC scene instantiates for its live Fight tuning")
	if mom == null:
		return

	var machine := mom.get_node_or_null("NpcStateMachine") as NpcStateMachine
	var fight := mom.get_node_or_null("NpcStateMachine/Fight") as MomNpcFightState
	var target := PlayerSpeedProbe.new()
	assert_not_null(machine, "Mom has her authored state machine")
	assert_not_null(fight, "Mom has her authored Fight state")
	if machine == null or fight == null:
		target.free()
		mom.free()
		return

	fight.npc = mom
	fight.machine = machine
	fight.fight_target = target
	var chase_speed := float(fight.call("_get_fight_move_speed"))
	assert_true(
		is_equal_approx(chase_speed, machine.get_effective_run_speed() * 1.15),
		"authored Fight chase derives from Mom's 161 run speed"
	)
	assert_true(chase_speed < target.move_speed * 0.5, "Mom no longer mirrors the player's speed")
	assert_true(
		chase_speed * fight.melee_dash_speed_multiplier > target.move_speed,
		"Mom's authored committed dash is faster than the player while ordinary chase is not"
	)
	target.free()
	mom.free()


func test_melee_dash_has_windup_fixed_direction_and_one_end_strike() -> void:
	var dash_probe := MeleeDashProbe.new()
	var fixture := _create_fight_probe(dash_probe)
	var npc := fixture.get("npc") as CharacterBody2D
	var target := fixture.get("target") as CharacterBody2D
	if npc == null or target == null:
		return

	dash_probe.match_target_move_speed = false
	dash_probe.melee_dash_windup_seconds = 0.55
	dash_probe.melee_dash_seconds = 0.28
	dash_probe.melee_dash_speed_multiplier = 3.5
	# This is the ordinary live sequence: a projectile has left the shared attack
	# cooldown running by the time Mom crosses into the melee-chase gap.
	dash_probe.attack_cooldown_timer = 1.0
	target.global_position = npc.global_position + Vector2(200.0, 0.0)
	dash_probe.call("_configure_combat_decision_commitment")
	dash_probe.call("_refresh_combat_decision")
	dash_probe.call("_update_attack", 0.0)

	assert_eq(
		dash_probe.active_attack_mode,
		MomNpcFightState.MomAttackMode.MELEE_DASH,
		"the melee chase gap starts the existing Fight state's dash mode"
	)
	dash_probe.call("_update_chase")
	assert_true(is_zero_approx(npc.velocity.x), "the long dash wind-up stays stationary")

	# Moving behind Mom during commitment must not redirect the already-telegraphed dash.
	target.global_position = npc.global_position + Vector2(-200.0, 0.0)
	dash_probe.call("_update_attack", 0.56)
	dash_probe.call("_update_chase")
	assert_true(npc.velocity.x > 0.0, "the dash keeps its originally committed direction")
	assert_true(
		absf(npc.velocity.x) > dash_probe.combat_decision.move_speed,
		"the dash is faster than Mom's reduced ordinary chase"
	)
	assert_eq(dash_probe.melee_attack_count, 0, "the dash does not strike early")

	dash_probe.call("_update_attack", 0.28)
	assert_eq(dash_probe.melee_attack_count, 1, "the dash strikes exactly once at its end")
	assert_eq(
		dash_probe.active_attack_mode,
		MomNpcFightState.MomAttackMode.NONE,
		"the dash returns to the existing Fight flow"
	)
	assert_true(is_zero_approx(npc.velocity.x), "the committed dash stops after striking")


func _create_fight_probe(fight_override: MomNpcFightState = null) -> Dictionary:
	var npc := CharacterBody2D.new()
	npc.name = "MomFightDecisionProbe"
	var machine := FacingProbeMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	var fight := fight_override if fight_override != null else MomNpcFightState.new()
	fight.name = "Fight"
	machine.add_child(fight)
	npc.add_child(machine)
	add_child_autofree(npc)

	var target := CharacterBody2D.new()
	target.name = "MomFightDecisionTarget"
	target.add_to_group("player")
	add_child_autofree(target)

	fight.npc = npc
	fight.machine = machine
	fight.fight_target = target
	return {
		"npc": npc,
		"machine": machine,
		"fight": fight,
		"target": target,
	}


func _advance_commitment_if_supported(fight: MomNpcFightState, delta: float) -> void:
	if fight.has_method("_advance_combat_decision_commitment"):
		fight.call("_advance_combat_decision_commitment", delta)


func _count_bool_transitions(values: Array[bool]) -> int:
	var transitions := 0
	for index in range(1, values.size()):
		if values[index] != values[index - 1]:
			transitions += 1
	return transitions


func _count_float_transitions(values: Array[float]) -> int:
	var transitions := 0
	for index in range(1, values.size()):
		if not is_equal_approx(values[index], values[index - 1]):
			transitions += 1
	return transitions
