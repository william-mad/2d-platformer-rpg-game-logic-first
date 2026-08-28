extends "res://test/native_scene_tree_test.gd"


class StableNpcTarget:
	extends CharacterBody2D

	var actor_id: StringName

	func _init(new_actor_id: StringName) -> void:
		actor_id = new_actor_id

	func get_npc_location_id() -> StringName:
		return actor_id

	func take_damage(
		_amount: float,
		_source_position: Vector2 = Vector2.ZERO,
		_source: Node = null,
		_knockout_damage: float = 0.0
	) -> void:
		pass


class HealthContractNpc:
	extends CharacterBody2D

	var hp: float = 50.0
	var authored_max_hp: float = 200.0
	var maximum_health_queries: int = 0

	func get_hp() -> float:
		return hp

	func get_max_hp() -> float:
		maximum_health_queries += 1
		return authored_max_hp


class FightHealthLookupProbe:
	extends NpcStateFight

	var reflective_lookup_count: int = 0

	func _get_node_float_property(
		_node: Node,
		_property_name: StringName,
		fallback: float
	) -> float:
		reflective_lookup_count += 1
		return fallback


func test_player_directed_anger_starts_sustains_and_calms_fight() -> void:
	var fixture := _create_combat_fixture("PlayerDirectedAngerProbe")
	var npc := fixture.get("npc") as SocialNpc
	var machine := fixture.get("machine") as NpcStateMachine
	var attacker := fixture.get("attacker") as CharacterBody2D
	if npc == null or machine == null or attacker == null:
		return
	var relationships := npc.get_node_or_null("/root/Relationships")
	assert_not_null(relationships, "relationship system is available")
	if relationships == null:
		return

	relationships.call("set_anger", npc, attacker, 100.0, "player_directed_probe")
	assert_eq(machine.get_value(&"anger"), 0.0, "directed anger does not leak into broad anger")
	machine.notify_target_seen(attacker)
	assert_true(machine.is_primary_state(&"Fight"), "player-directed anger starts Fight on sight")
	assert_false(
		_state_tick_requests(machine, &"Idle"),
		"player-directed anger sustains Fight beyond its first tick"
	)

	relationships.call("set_anger", npc, attacker, 60.0, "player_directed_calm")
	assert_true(
		_state_tick_requests(machine, &"Idle"),
		"Fight ends when player-directed anger reaches the calm threshold"
	)


func test_player_damage_crossing_directed_anger_threshold_sustains_fight() -> void:
	var fixture := _create_combat_fixture("PlayerDamageAngerProbe")
	var npc := fixture.get("npc") as SocialNpc
	var machine := fixture.get("machine") as NpcStateMachine
	var attacker := fixture.get("attacker") as CharacterBody2D
	if npc == null or machine == null or attacker == null:
		return

	npc.damage_anger_multiplier = 100.0
	npc.damage_fear_multiplier = 0.0
	npc.take_damage(1.0, attacker.global_position, attacker)
	assert_true(machine.is_primary_state(&"Fight"), "threshold-crossing player damage starts Fight")
	assert_false(
		_state_tick_requests(machine, &"Idle"),
		"damage-started player Fight reads its directed anger"
	)


func test_directed_anger_starts_fight_but_broad_mood_anger_does_not_target_player() -> void:
	var npc_fixture := _create_combat_fixture("NpcDirectedAngerProbe")
	var npc := npc_fixture.get("npc") as SocialNpc
	var machine := npc_fixture.get("machine") as NpcStateMachine
	if npc == null or machine == null:
		return
	var target := StableNpcTarget.new(&"directed_anger_npc_target")
	target.name = "DirectedAngerNpcTarget"
	target.add_to_group("npc")
	target.global_position = npc.global_position + Vector2(48.0, 0.0)
	add_child_autofree(target)
	var relationships := npc.get_node_or_null("/root/Relationships")
	assert_not_null(relationships, "relationship system is available")
	if relationships == null:
		return

	relationships.call("set_anger", npc, target, 100.0, "npc_directed_probe")
	machine.notify_target_seen(target)
	assert_true(machine.is_primary_state(&"Fight"), "NPC-directed anger still starts Fight")
	assert_false(
		_state_tick_requests(machine, &"Idle"),
		"NPC-directed anger still sustains Fight"
	)

	var broad_fixture := _create_combat_fixture("BroadAngerDirectionProbe")
	var broad_npc := broad_fixture.get("npc") as SocialNpc
	var broad_machine := broad_fixture.get("machine") as NpcStateMachine
	var broad_target := broad_fixture.get("attacker") as CharacterBody2D
	if broad_npc == null or broad_machine == null or broad_target == null:
		return
	broad_machine.set_value(&"anger", 100.0, broad_target, false)
	assert_eq(
		broad_npc.get_relationship_anger_for(broad_target, 0.0),
		0.0,
		"the Player has no directed anger before the sight check"
	)
	broad_machine.select_combat_target(broad_target)
	assert_false(
		broad_machine.evaluate_persistent_combat_reactions(),
		"persistent broad mood anger does not acquire the selected Player as its subject"
	)
	broad_machine.notify_target_seen(broad_target)
	assert_false(
		broad_machine.is_primary_state(&"Fight"),
		"broad mood anger does not become anger directed at the seen Player"
	)
	assert_true(
		broad_machine.request_state(&"Fight", broad_target, "broad_anger_sustain_probe", 94),
		"the fixture can enter Fight directly"
	)
	assert_true(
		_state_tick_requests(broad_machine, &"Idle"),
		"broad mood anger does not sustain a person-directed Fight"
	)

	var fear_fixture := _create_combat_fixture("BroadAngerFearProbe")
	var fear_npc := fear_fixture.get("npc") as SocialNpc
	var fear_machine := fear_fixture.get("machine") as NpcStateMachine
	var fear_target := fear_fixture.get("attacker") as CharacterBody2D
	if fear_npc == null or fear_machine == null or fear_target == null:
		return
	fear_machine.set_value(&"anger", 100.0, fear_target, false)
	fear_npc.change_relationship_fear_for(fear_target, 100.0, "broad_anger_fear_probe")
	fear_machine.notify_target_seen(fear_target)
	assert_true(
		fear_machine.is_primary_state(&"Flee"),
		"broad mood anger does not override directed fear of the Player"
	)


func test_directed_anger_and_fear_preserve_combat_precedence_and_health_gate() -> void:
	var fixture := _create_combat_fixture("DirectedCombatPrecedenceProbe")
	var npc := fixture.get("npc") as SocialNpc
	var machine := fixture.get("machine") as NpcStateMachine
	var attacker := fixture.get("attacker") as CharacterBody2D
	if npc == null or machine == null or attacker == null:
		return
	var relationships := npc.get_node_or_null("/root/Relationships")
	assert_not_null(relationships, "relationship system is available")
	if relationships == null:
		return

	relationships.call("set_anger", npc, attacker, 100.0, "precedence_probe")
	relationships.call("set_fear", npc, attacker, 100.0, "precedence_probe")
	machine.notify_target_seen(attacker)
	assert_true(machine.is_primary_state(&"Fight"), "directed anger wins over fear at the Fight threshold")

	var low_health_fixture := _create_combat_fixture("DirectedAngerLowHealthProbe")
	var low_health_npc := low_health_fixture.get("npc") as SocialNpc
	var low_health_machine := low_health_fixture.get("machine") as NpcStateMachine
	var low_health_attacker := low_health_fixture.get("attacker") as CharacterBody2D
	if low_health_npc == null or low_health_machine == null or low_health_attacker == null:
		return
	low_health_machine.set_value(&"hp", 10.0, low_health_attacker, false)
	relationships.call(
		"set_anger", low_health_npc, low_health_attacker, 100.0, "health_gate_probe"
	)
	low_health_machine.notify_target_seen(low_health_attacker)
	assert_false(
		low_health_machine.is_primary_state(&"Fight"),
		"directed anger does not bypass the existing low-health Fight gate"
	)


func test_damage_does_not_resubmit_blocked_or_terminal_combat_states() -> void:
	var fixture := _create_combat_fixture("DamageTransitionProbe")
	var npc := fixture.get("npc") as SocialNpc
	var machine := fixture.get("machine") as NpcStateMachine
	var attacker := fixture.get("attacker") as CharacterBody2D
	if npc == null or machine == null or attacker == null:
		return

	npc.change_relationship_anger_for(attacker, 70.0, "transition_probe_setup")
	assert_true(
		machine.request_state(&"Fight", attacker, "probe_start", 94),
		"healthy angry NPC starts Fight"
	)
	var rejected_requests: Array[String] = []
	machine.state_request_failed.connect(
		func(state_name: StringName, reason: String) -> void:
			rejected_requests.append("%s:%s" % [String(state_name), reason])
	)

	npc.take_damage(1.0, attacker.global_position, attacker)
	machine.notify_target_seen(attacker)
	assert_true(
		rejected_requests.is_empty(),
		"damage and repeated sight do not re-request an already-active Fight"
	)

	machine.set_value(&"hp", 49.0, attacker, false)
	npc.change_relationship_fear_for(attacker, 100.0, "probe_setup")
	npc.take_damage(1.0, attacker.global_position, attacker)
	assert_true(
		machine.is_primary_state(&"Fight"),
		"healthy Fight keeps control when a Flee request cannot interrupt it"
	)
	assert_true(
		rejected_requests.is_empty(),
		"blocked fear reaction is filtered before it becomes cannot_exit_Fight"
	)

	machine.set_value(&"hp", 10.0, attacker, false)
	assert_true(
		machine.can_transition_to_state(&"Flee", 90),
		"low-health Fight still permits the directed-fear Flee transition"
	)
	machine.set_value(&"hp", 48.0, attacker, false)
	npc.take_damage(100.0, attacker.global_position, attacker)
	assert_true(
		machine.is_primary_state(&"DisabledDead"),
		"lethal damage commits DisabledDead"
	)
	assert_true(
		rejected_requests.is_empty(),
		"lethal damage does not request Flee or DisabledDead again"
	)


func test_favor_loss_does_not_build_an_impossible_reaction_during_fight() -> void:
	var fixture := _create_combat_fixture("FavorReactionFightProbe")
	var npc := fixture.get("npc") as SocialNpc
	var machine := fixture.get("machine") as NpcStateMachine
	var attacker := fixture.get("attacker") as CharacterBody2D
	if npc == null or machine == null or attacker == null:
		return

	# Enter Fight directly below the directed-anger start threshold. This isolates
	# the favor-loss rule that requested ReactToEvent repeatedly in the runtime log.
	npc.change_relationship_anger_for(attacker, 70.0, "favor_probe_setup")
	assert_true(
		machine.request_state(&"Fight", attacker, "favor_probe_start", 94),
		"fixture enters Fight"
	)
	var rejected_requests: Array[String] = []
	machine.state_request_failed.connect(
		func(state_name: StringName, reason: String) -> void:
			rejected_requests.append("%s:%s" % [String(state_name), reason])
	)

	npc.take_damage(1.0, attacker.global_position, attacker)

	assert_true(
		machine.is_primary_state(&"Fight"),
		"favor loss cannot disturb active Fight ownership"
	)
	assert_true(
		rejected_requests.is_empty(),
		"blocked favor reaction is filtered before requesting ReactToEvent"
	)


func test_event_reaction_state_is_suppressed_only_during_fight() -> void:
	var idle_fixture := _create_combat_fixture("IdleEventReactionProbe")
	var idle_npc := idle_fixture.get("npc") as SocialNpc
	var idle_machine := idle_fixture.get("machine") as NpcStateMachine
	var idle_actor := idle_fixture.get("attacker") as CharacterBody2D
	if idle_npc == null or idle_machine == null or idle_actor == null:
		return
	idle_npc.event_bus_reactions = _event_reaction_rules()
	idle_npc.call(
		"_on_event_bus_event",
		&"fight_efficiency_probe",
		_event_payload(idle_npc, idle_actor)
	)
	assert_true(
		idle_machine.is_primary_state(&"ReactToEvent"),
		"the existing event reaction still starts normally outside Fight"
	)

	var fight_fixture := _create_combat_fixture("FightEventReactionProbe")
	var fight_npc := fight_fixture.get("npc") as SocialNpc
	var fight_machine := fight_fixture.get("machine") as NpcStateMachine
	var fight_actor := fight_fixture.get("attacker") as CharacterBody2D
	if fight_npc == null or fight_machine == null or fight_actor == null:
		return
	fight_npc.change_relationship_anger_for(fight_actor, 70.0, "event_probe_setup")
	assert_true(
		fight_machine.request_state(&"Fight", fight_actor, "event_probe_start", 94),
		"fixture enters Fight"
	)
	fight_npc.event_bus_reactions = _event_reaction_rules()
	var rejected_requests: Array[String] = []
	fight_machine.state_request_failed.connect(
		func(state_name: StringName, reason: String) -> void:
			rejected_requests.append("%s:%s" % [String(state_name), reason])
	)
	var relationships := fight_npc.get_node_or_null("/root/Relationships")
	assert_not_null(relationships, "relationship system is available")
	if relationships == null:
		return
	var trust_before := float(relationships.call(
		"get_opinion_metric", fight_npc, fight_actor, &"trust"
	))
	fight_npc.call(
		"_on_event_bus_event",
		&"fight_efficiency_probe",
		_event_payload(fight_npc, fight_actor)
	)
	assert_true(
		fight_machine.is_primary_state(&"Fight"),
		"ReactToEvent presentation does not interrupt active Fight"
	)
	assert_true(
		rejected_requests.is_empty(),
		"Fight does not build or reject the redundant event reaction request"
	)
	assert_eq(
		float(relationships.call(
			"get_opinion_metric", fight_npc, fight_actor, &"trust"
		)),
		trust_before - 4.0,
		"the event's directed social consequence still applies during Fight"
	)
	assert_eq(
		fight_machine.get_value(&"anger"),
		8.0,
		"the event's local mood consequence still applies during Fight"
	)


func test_fight_health_uses_live_maximum_health_contract_without_reflection() -> void:
	var npc := HealthContractNpc.new()
	var fight := FightHealthLookupProbe.new()
	npc.add_child(fight)
	add_child_autofree(npc)
	fight.npc = npc

	assert_eq(
		float(fight.call("_get_npc_health_percent")),
		25.0,
		"Fight calculates health from the direct maximum-health contract"
	)
	assert_eq(
		fight.reflective_lookup_count,
		0,
		"the direct contract avoids scanning the NPC property list"
	)
	npc.authored_max_hp = 100.0
	assert_eq(
		float(fight.call("_get_npc_health_percent")),
		50.0,
		"runtime maximum-health changes remain visible without stale caching"
	)


func test_low_health_fight_does_not_reenter_every_physics_step() -> void:
	var fixture := _create_combat_fixture("LowHealthFightProbe")
	var npc := fixture.get("npc") as SocialNpc
	var machine := fixture.get("machine") as NpcStateMachine
	var attacker := fixture.get("attacker") as CharacterBody2D
	if npc == null or machine == null or attacker == null:
		return

	npc.change_relationship_anger_for(attacker, 100.0, "low_health_probe_setup")
	assert_true(
		machine.request_state(&"Fight", attacker, "probe_start", 94),
		"healthy angry NPC starts Fight"
	)
	var state_changes: Array[String] = []
	var active_session_ids: Dictionary = {}
	var rejection_count := {"value": 0}
	machine.state_changed.connect(
		func(state_name: StringName, previous_name: StringName) -> void:
			state_changes.append("%s>%s" % [
				String(previous_name),
				String(state_name),
			])
	)
	machine.action_session_changed.connect(func(descriptor: Dictionary) -> void:
		var session_id := String(descriptor.get("session_id", "")).strip_edges()
		if (
			not session_id.is_empty()
			and String(descriptor.get("status", "")) == "active"
		):
			active_session_ids[session_id] = true
	)
	machine.state_request_failed.connect(
		func(_state_name: StringName, _reason: String) -> void:
			rejection_count.value += 1
	)

	machine.set_value(&"hp", 10.0, attacker, true)
	for _step in 8:
		var state_at_start := machine.current_state
		var requested := state_at_start.physics_process(1.0 / 60.0)
		if requested != null and machine.current_state == state_at_start:
			machine.change_state(requested, "state_tick")
		if machine.is_primary_state(&"Idle"):
			machine._run_idle_value_reaction_check()

	print(
		"LOW_HEALTH_FIGHT_PROBE state_changes=%d active_sessions=%d rejections=%d current=%s"
		% [
			state_changes.size(),
			active_session_ids.size(),
			rejection_count.value,
			String(machine.current_state.name),
		]
	)
	assert_false(
		machine.is_primary_state(&"Fight"),
		"NPC below the Fight health stop remains out of Fight"
	)
	assert_true(
		state_changes.size() <= 2,
		"low-health handling does not oscillate states every physics step"
	)
	assert_true(
		active_session_ids.size() <= 1,
		"low-health handling does not create replacement Fight sessions"
	)


func _create_combat_fixture(label: String) -> Dictionary:
	var packed := load(
		"res://scenes/creatures/npc/stateful_social_npc.tscn"
	) as PackedScene
	assert_not_null(packed, "stateful combat NPC scene loads")
	if packed == null:
		return {}
	var npc := packed.instantiate() as SocialNpc
	npc.name = label
	npc.relationship_id = StringName(label)
	npc.location_id = &""
	npc.use_npc_location_tracking = false
	npc.listen_to_event_bus = false
	add_child_autofree(npc)
	var machine := npc.get_node_or_null(
		"NpcStateMachine"
	) as NpcStateMachine
	assert_not_null(machine, "combat NPC has a state machine")
	if machine == null:
		return {}
	var attacker := CharacterBody2D.new()
	attacker.name = "%sAttacker" % label
	attacker.add_to_group("player")
	attacker.set_collision_layer_value(2, true)
	attacker.global_position = npc.global_position + Vector2(48.0, 0.0)
	add_child_autofree(attacker)
	return {
		"npc": npc,
		"machine": machine,
		"attacker": attacker,
	}


func _state_tick_requests(machine: NpcStateMachine, state_name: StringName) -> bool:
	if machine == null or machine.current_state == null:
		return false
	var requested := machine.current_state.physics_process(1.0 / 60.0)
	return requested != null and StringName(requested.name) == state_name


func _event_reaction_rules() -> Dictionary:
	return {
		"fight_efficiency_probe": {
			"scope": "local",
			"radius": 160.0,
			"stat_delta": {"anger": 8.0, "trust": -4.0},
			"state_request": "ReactToEvent",
			"priority": 55,
		}
	}


func _event_payload(npc: SocialNpc, actor: Node2D) -> Dictionary:
	return {
		"event_name": &"fight_efficiency_probe",
		"npc_event": true,
		"scope": &"local",
		"position": npc.global_position,
		"has_position": true,
		"radius": 160.0,
		"actor": actor,
		"source": actor,
		"tags": [],
	}
