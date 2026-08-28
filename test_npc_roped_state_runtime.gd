extends SceneTree

const ATTACHED_REASON := "rope_attached_by_player"
const FIRST_DRAG_REASON := "rope_first_drag_by_player"
const CONTINUED_DRAG_REASON := "rope_continued_drag_by_player"

var _failures: Array[String] = []


class RopeAwareNpc:
	extends CharacterBody2D

	signal rope_status_changed(is_roped: bool, is_being_dragged: bool)

	var can_break_free_from_rope: bool = false
	var rope_weight: float = 2.0
	var max_knockout: float = 100.0
	var knockout: float = 0.0
	var apply_knockout_calls: int = 0
	var direction: int = 1
	var attached_ropes: Array[Rope] = []
	var _is_roped: bool = false
	var _is_dragged: bool = false

	func set_rope_status(is_roped_now: bool, is_dragged_now: bool) -> void:
		_is_roped = is_roped_now
		_is_dragged = is_roped_now and is_dragged_now
		rope_status_changed.emit(_is_roped, _is_dragged)

	func is_roped() -> bool:
		return _is_roped

	func is_being_dragged_by_rope() -> bool:
		return _is_dragged

	func get_attached_ropes() -> Array[Rope]:
		return attached_ropes if _is_roped else []

	func try_break_free_from_rope() -> bool:
		return false

	func get_knockout() -> float:
		return knockout

	func apply_knockout(
		amount: float,
		actor: Node2D = null,
		evaluate_reactions: bool = true
	) -> void:
		apply_knockout_calls += 1
		knockout = clampf(knockout + maxf(amount, 0.0), 0.0, max_knockout)
		var machine := get_node_or_null("NpcStateMachine") as NpcStateMachine
		if machine != null:
			machine.set_value(&"knockout", knockout, actor, evaluate_reactions)

	func get_npc_location_id() -> StringName:
		return &"roped_state_test_npc"


class WeightedRopeBody:
	extends CharacterBody2D

	var rope_weight: float = 1.0


class TestableRopedState:
	extends NpcStateRoped

	var test_grounded: bool = true

	func is_grounded_for_rope_behavior() -> bool:
		return test_grounded


class PriorityFightState:
	extends NpcState

	func can_exit_to(_new_state: NpcState, outgoing_priority: int) -> bool:
		return outgoing_priority >= 95


class HardOverrideState:
	extends NpcState

	var locked: bool = true

	func can_exit_to(_new_state: NpcState, outgoing_priority: int) -> bool:
		return not locked or outgoing_priority >= 1000


class RecordingAnimationController:
	extends Node

	var fixed_requests: Array[StringName] = []
	var normal_requests: Array[StringName] = []
	var latest_facing: float = 0.0

	func bind_npc(_npc: Node2D) -> void:
		pass

	func request_animation(
		requested_name: StringName,
		_required: bool = true
	) -> bool:
		normal_requests.append(requested_name)
		return true

	func request_fixed_animation(
		requested_name: StringName,
		_required: bool = true
	) -> bool:
		fixed_requests.append(requested_name)
		return true

	func face_x_direction(x_direction: float) -> bool:
		latest_facing = signf(x_direction)
		return true


class RecordingMachine:
	extends NpcStateMachine

	var directed_events: Array[Dictionary] = []

	func apply_explicit_directed_social_event(
		local_stat_delta: Dictionary,
		directed_opinion: Dictionary,
		actor: Node2D,
		requires_actor_visibility: bool = true,
		event_reason: String = "social_event",
		event_context: Dictionary = {},
		_evaluate_reactions: bool = true
	) -> Dictionary:
		directed_events.append({
			"local": local_stat_delta.duplicate(true),
			"opinion": directed_opinion.duplicate(true),
			"actor": actor,
			"requires_visibility": requires_actor_visibility,
			"reason": event_reason,
			"context": event_context.duplicate(true),
		})
		return {"applied": true, "relationship": {}}


func _initialize() -> void:
	await process_frame
	_test_scene_registration()
	await _test_fixed_animation_stability()
	await _test_reaction_air_and_hard_landing_phases()
	await _test_rope_session_behavior()

	if _failures.is_empty():
		print("test_npc_roped_state_runtime.gd passed.")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	quit(1)


func _test_scene_registration() -> void:
	var packed := load("res://scenes/creatures/npc/npc_state_machine.tscn") as PackedScene
	_expect(packed != null, "NPC state-machine scene loads")
	if packed == null:
		return
	var instance := packed.instantiate()
	var roped := instance.get_node_or_null("Roped") as NpcStateRoped
	_expect(roped != null, "the reusable state-machine scene registers Roped")
	if roped != null:
		_expect(roped.animation_name == &"walk", "Roped uses walking as its struggle stand-in")
		_expect(
			roped.reaction_delay_seconds > 0.0
			and roped.dragged_animation_name == &"walk"
			and roped.struggle_speed_multiplier < 1.0
			and roped.airborne_dangle_animation_name != &""
			and roped.hard_air_drag_acceleration_threshold > 0.0,
			"the reusable phases ship with restrained hold-position presentation"
		)
		_expect(
			not roped.stop_horizontal_on_enter,
			"Roped reverses smoothly instead of snapping horizontal velocity on entry"
		)
		_expect(
			float(roped.attached_opinion_delta.get("anger", 0.0)) > 0.0
			and float(roped.dragged_opinion_delta.get("anger", 0.0)) > 0.0
			and float(roped.continued_drag_opinion_delta.get("anger", 0.0)) > 0.0,
			"the reusable average configuration increases directed anger"
		)
	instance.free()


func _test_fixed_animation_stability() -> void:
	var npc := CharacterBody2D.new()
	npc.name = "FixedAnimationNpc"
	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	npc.add_child(player)
	var library := AnimationLibrary.new()
	var idle_animation := Animation.new()
	idle_animation.length = 1.0
	idle_animation.loop_mode = Animation.LOOP_LINEAR
	library.add_animation(&"idle", idle_animation)
	var walk_animation := Animation.new()
	walk_animation.length = 1.0
	walk_animation.loop_mode = Animation.LOOP_LINEAR
	library.add_animation(&"walk", walk_animation)
	player.add_animation_library(&"", library)

	var controller := NpcAnimationController.new()
	controller.name = "NpcAnimationController"
	controller.grounded_locomotion_enabled = true
	npc.add_child(controller)
	root.add_child(npc)
	await process_frame

	_expect(
		controller.request_fixed_animation(&"walk"),
		"fixed effort animation accepts the walk stand-in"
	)
	controller._physics_process(0.016)
	_expect(
		player.current_animation == &"walk",
		"fixed effort animation stays walking at zero measured speed"
	)
	npc.queue_free()
	await process_frame


func _test_reaction_air_and_hard_landing_phases() -> void:
	var world := Node2D.new()
	world.name = "RopedPhaseTestWorld"

	var player := CharacterBody2D.new()
	player.name = "Player"
	player.add_to_group(&"player")
	world.add_child(player)

	var npc := RopeAwareNpc.new()
	npc.name = "RopedPhaseNpc"
	world.add_child(npc)
	var animation_controller := RecordingAnimationController.new()
	animation_controller.name = "NpcAnimationController"
	npc.add_child(animation_controller)

	var anchor := WeightedRopeBody.new()
	anchor.position = Vector2(100.0, 0.0)
	world.add_child(anchor)
	var attached_rope := Rope.new()
	attached_rope.extra_length = 0.0
	attached_rope.maximum_tension = 100000.0
	world.add_child(attached_rope)
	_expect(
		attached_rope.attach(npc, anchor),
		"the phase fixture attaches a real rope"
	)
	npc.attached_ropes = [attached_rope]

	var machine := RecordingMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	machine.auto_move_and_slide = false
	machine.passive_needs_enabled = false
	machine.value_reactions_enabled = true
	machine.walk_speed = 40.0
	npc.add_child(machine)

	var behavior_controller := NpcBehaviorController.new()
	behavior_controller.name = "NpcBehaviorController"
	machine.add_child(behavior_controller)
	var idle := NpcState.new()
	idle.name = "Idle"
	machine.add_child(idle)
	var roped := TestableRopedState.new()
	roped.name = "Roped"
	roped.animation_name = &"walk"
	roped.reaction_delay_seconds = 0.5
	roped.reaction_animation_name = &"rope_react"
	roped.dragged_animation_name = &"run"
	roped.airborne_dangle_animation_name = &"rope_dangle"
	roped.struggle_acceleration = 80.0
	roped.hard_air_drag_acceleration_threshold = 3000.0
	roped.minimum_hard_drag_airtime = 0.08
	machine.add_child(roped)
	var downed := NpcStateDowned.new()
	downed.name = "Downed"
	downed.animation_name = &"downed"
	machine.add_child(downed)

	var reaction_sessions: Array[int] = []
	var reaction_dragged_samples: Array[bool] = []
	var downed_entries: Array[StringName] = []
	roped.rope_reaction_started.connect(
		func(session_id: int) -> void:
			reaction_sessions.append(session_id)
			reaction_dragged_samples.append(roped.dragged)
	)
	machine.state_changed.connect(
		func(new_state_name: StringName, _previous_state_name: StringName) -> void:
			if new_state_name == &"Downed":
				downed_entries.append(new_state_name)
	)
	root.add_child(world)
	await process_frame
	machine.set_physics_process(false)
	behavior_controller.set_process(false)
	machine.active = true
	_expect(machine.request_state(&"Idle"), "phase fixture enters Idle")
	_expect(
		is_zero_approx(roped.measure_air_drag_acceleration(
			Vector2.ZERO,
			Vector2(0.0, 60.0),
			0.05
		)),
		"ordinary configured gravity is removed from hard-drag acceleration"
	)
	# The remaining fixture drives velocity manually, so it also disables gravity.
	machine.gravity = 0.0

	# A normal run cancelled by the reaction phase is authored intent, not a rope
	# impact, even if the body leaves the floor on that same frame.
	npc.velocity.x = 161.0
	npc.set_rope_status(true, true)
	roped.set_physics_process(false)
	await process_frame
	_expect(machine.is_primary_state(&"Roped"), "phase fixture enters Roped")
	_expect(
		reaction_sessions.size() == 1
		and reaction_dragged_samples == [true]
		and animation_controller.fixed_requests == [&"rope_react"],
		"a new rope session exposes one reaction hook with its initial drag status"
	)
	roped.physics_process(0.016)
	roped.test_grounded = false
	roped._physics_process(0.016)
	roped.physics_process(0.07)
	roped._physics_process(0.07)
	roped.test_grounded = true
	roped._physics_process(0.016)
	_expect(
		machine.is_primary_state(&"Roped") and npc.apply_knockout_calls == 0,
		"the reaction phase's own stop cannot masquerade as a hard rope yank"
	)
	npc.set_rope_status(true, false)

	npc.velocity = Vector2.ZERO
	roped.physics_process(0.2)
	roped._physics_process(0.2)
	_expect(
		is_zero_approx(npc.velocity.x)
		and roped.get_roped_phase() == NpcStateRoped.RopedPhase.REACTION
		and animation_controller.fixed_requests.back() == &"rope_react"
		and not animation_controller.fixed_requests.has(&"walk"),
		"the initial reaction delay remains passive and does not start walking early"
	)
	roped.test_grounded = false
	npc.velocity = Vector2(23.0, 45.0)
	var reaction_air_velocity := npc.velocity
	roped.physics_process(0.5)
	roped._physics_process(0.5)
	_expect(
		npc.velocity == reaction_air_velocity
		and roped.get_roped_phase() == NpcStateRoped.RopedPhase.DANGLING,
		"airborne time pauses the reaction and dangles without authored movement"
	)
	roped.test_grounded = true
	roped._physics_process(0.01)
	_expect(
		roped.get_roped_phase() == NpcStateRoped.RopedPhase.REACTION,
		"a normal landing resumes the unfinished reaction window"
	)
	roped.physics_process(0.26)
	roped._physics_process(0.26)
	_expect(
		roped.get_roped_phase() == NpcStateRoped.RopedPhase.REACTION,
		"the resumed reaction still respects its remaining delay"
	)
	roped.physics_process(0.02)
	roped._physics_process(0.02)
	_expect(
		roped.get_roped_phase() == NpcStateRoped.RopedPhase.REACTION
		and animation_controller.fixed_requests.back() == &"rope_react",
		"a slack rope remains passive after the initial reaction window"
	)
	roped.physics_process(0.25)
	_expect(
		is_zero_approx(npc.velocity.x),
		"slack attachment does not author struggle movement (got %.2f)"
		% npc.velocity.x
	)

	npc.set_rope_status(true, true)
	_expect(
		roped.get_roped_phase() == NpcStateRoped.RopedPhase.HARD_STRUGGLE
		and animation_controller.fixed_requests.back() == &"run",
		"load-bearing hard struggle switches to the running stand-in"
	)
	var hard_animation_request_count := animation_controller.fixed_requests.size()
	roped.physics_process(0.016)
	_expect(
		animation_controller.fixed_requests.size() == hard_animation_request_count,
		"hard struggle does not restart its running animation every frame"
	)

	# Air always removes authored struggle. A large acceleration while slack must
	# not arm the landing knockdown.
	npc.set_rope_status(true, false)
	roped.test_grounded = false
	npc.velocity = Vector2(123.0, 45.0)
	var airborne_velocity := npc.velocity
	roped.physics_process(0.05)
	var dangle_request_count := animation_controller.fixed_requests.size()
	_expect(
		npc.velocity == airborne_velocity
		and roped.get_roped_phase() == NpcStateRoped.RopedPhase.DANGLING
		and animation_controller.fixed_requests.back() == &"rope_dangle",
		"airborne attachment dangles without authored struggle and exposes its animation hook"
	)
	roped.physics_process(0.05)
	_expect(
		animation_controller.fixed_requests.size() == dangle_request_count,
		"the dangle animation is stable instead of restarting each frame"
	)
	roped._physics_process(0.05)
	npc.velocity.x = 500.0
	roped._physics_process(0.05)
	roped.test_grounded = true
	roped._physics_process(0.016)
	_expect(
		machine.is_primary_state(&"Roped") and npc.apply_knockout_calls == 0,
		"air acceleration while the rope is slack does not cause a hard landing"
	)
	# Load bearing alone is not enough: an ordinary dragged airborne change below
	# the acceleration threshold must also land normally.
	npc.set_rope_status(true, true)
	npc.velocity = Vector2.ZERO
	roped._physics_process(0.016)
	roped.test_grounded = false
	npc.velocity.x = 50.0
	roped.physics_process(0.05)
	roped._physics_process(0.05)
	roped.physics_process(0.05)
	roped._physics_process(0.05)
	roped.test_grounded = true
	roped._physics_process(0.016)
	_expect(
		machine.is_primary_state(&"Roped") and npc.apply_knockout_calls == 0,
		"dragged airborne motion below the impact threshold does not cause Downed"
	)

	# Reattach while already airborne. The first solver frame is allowed to contain
	# the only large yank, and must still arm exactly one real Downed handoff.
	npc.set_rope_status(false, false)
	await process_frame
	roped.test_grounded = false
	npc.velocity = Vector2.ZERO
	npc.set_rope_status(true, true)
	roped.set_physics_process(false)
	await process_frame
	# Capture zero as this frame's authored proposal, then stand in for Rope's
	# post-intent solver correction. This specifically exercises the post sampler.
	roped.physics_process(0.05)
	npc.velocity.x = 400.0
	roped._physics_process(0.05)
	roped.physics_process(0.05)
	roped._physics_process(0.05)
	roped.test_grounded = true
	roped._physics_process(0.016)
	_expect(
		machine.is_primary_state(&"Downed")
		and machine.get_value(&"knockout") >= 100.0
		and npc.apply_knockout_calls == 1
		and downed_entries.size() == 1,
		"a first-frame hard yank fills knockout and enters Downed exactly once"
	)
	_expect(
		not animation_controller.normal_requests.is_empty()
		and animation_controller.normal_requests.back() == &"downed",
		"the existing Downed state owns the editable landing animation"
	)
	npc.velocity = Vector2(90.0, 17.0)
	downed.physics_process(0.016)
	_expect(
		is_zero_approx(npc.velocity.x)
		and is_equal_approx(npc.velocity.y, 17.0)
		and npc.rope_weight == 2.0
		and not npc.get_attached_ropes().is_empty(),
		"Downed authors no struggle while leaving the attached body and its weight intact"
	)
	roped._physics_process(0.1)
	await process_frame
	_expect(
		machine.is_primary_state(&"Downed")
		and npc.apply_knockout_calls == 1
		and downed_entries.size() == 1,
		"the consumed hard landing cannot retrigger while Downed"
	)

	world.queue_free()
	await process_frame


func _test_rope_session_behavior() -> void:
	var world := Node2D.new()
	world.name = "RopedStateTestWorld"

	var player := CharacterBody2D.new()
	player.name = "Player"
	player.position = Vector2(-200.0, 0.0)
	player.add_to_group(&"player")
	world.add_child(player)

	var npc := RopeAwareNpc.new()
	npc.name = "RopeAwareNpc"
	world.add_child(npc)
	var animation_controller := RecordingAnimationController.new()
	animation_controller.name = "NpcAnimationController"
	npc.add_child(animation_controller)

	var rope_anchor := WeightedRopeBody.new()
	rope_anchor.name = "RopeAnchor"
	rope_anchor.position = Vector2(100.0, 0.0)
	world.add_child(rope_anchor)
	var attached_rope := Rope.new()
	attached_rope.name = "AttachedRope"
	attached_rope.extra_length = 0.0
	attached_rope.elasticity = 1.0
	attached_rope.elastic_return_speed = 0.0
	attached_rope.maximum_tension = 100000.0
	world.add_child(attached_rope)
	_expect(
		attached_rope.attach(npc, rope_anchor),
		"the weighted struggle fixture attaches a real rope"
	)
	npc.attached_ropes = [attached_rope]

	var machine := RecordingMachine.new()
	machine.name = "NpcStateMachine"
	machine.active = false
	machine.auto_move_and_slide = false
	machine.passive_needs_enabled = false
	machine.value_reactions_enabled = false
	machine.walk_speed = 40.0
	npc.add_child(machine)

	var behavior_controller := NpcBehaviorController.new()
	behavior_controller.name = "NpcBehaviorController"
	machine.add_child(behavior_controller)

	var idle := NpcState.new()
	idle.name = "Idle"
	machine.add_child(idle)

	var fight := PriorityFightState.new()
	fight.name = "Fight"
	machine.add_child(fight)

	var roped := TestableRopedState.new()
	roped.name = "Roped"
	roped.animation_name = &"walk"
	roped.stop_horizontal_on_enter = false
	roped.reaction_delay_seconds = 0.0
	roped.struggle_acceleration = 80.0
	roped.attached_opinion_delta = {"favor": -1.0}
	roped.dragged_opinion_delta = {"fear": 2.0}
	roped.continued_drag_opinion_delta = {"anger": 0.5}
	roped.continued_drag_interval_seconds = 1.0
	machine.add_child(roped)

	var downed := HardOverrideState.new()
	downed.name = "Downed"
	machine.add_child(downed)

	root.add_child(world)
	await process_frame

	# Drive only the events relevant to this state; the machine's normal physics
	# loop and Roped's wall-clock callback are disabled for a deterministic test.
	machine.set_physics_process(false)
	roped.set_physics_process(false)
	behavior_controller.set_process(false)
	machine.active = true
	_expect(not roped.is_physics_processing(), "detached Roped has no background physics cost")

	_expect(
		machine.request_state(&"Fight", player, "test_fight", 94),
		"fixture enters a Fight-level state"
	)
	_expect(machine.is_primary_state(&"Fight"), "Fight is current before attachment")

	npc.set_rope_status(true, false)
	_expect(roped.is_physics_processing(), "a rope session enables Roped's session timer")
	roped.set_physics_process(false)
	_expect(roped.attached, "attachment is tracked before Roped becomes current")
	_expect(not roped.dragged, "attached-only remains distinct from dragged")
	_expect(
		_count_reason(machine.directed_events, ATTACHED_REASON) == 1,
		"initial attachment opinion is sent once"
	)
	await process_frame
	_expect(machine.is_primary_state(&"Roped"), "attaching enters Roped")
	_expect(machine.current_state_priority == 95, "Roped enters at priority 95")
	_expect(
		animation_controller.fixed_requests == [&"idle"],
		"slack Roped attachment requests one stable passive animation on entry"
	)

	npc.set_rope_status(true, false)
	_expect(
		_count_reason(machine.directed_events, ATTACHED_REASON) == 1,
		"repeated attached status does not replay the attachment event"
	)

	npc.set_rope_status(true, true)
	_expect(roped.dragged, "dragged status is exposed inside the same state")
	_expect(
		animation_controller.fixed_requests == [&"idle", &"walk"],
		"load-bearing tension switches passive attachment to hard struggle"
	)
	_expect(
		_count_reason(machine.directed_events, FIRST_DRAG_REASON) == 1,
		"first-drag opinion is sent once"
	)
	npc.set_rope_status(true, true)
	_expect(
		_count_reason(machine.directed_events, FIRST_DRAG_REASON) == 1,
		"repeated dragged status does not replay first drag"
	)

	# Going slack pauses/resets the continued-drag cooldown without creating a
	# second first-drag event in the same uninterrupted rope session.
	npc.set_rope_status(true, false)
	npc.set_rope_status(true, true)
	roped._physics_process(0.75)
	roped._physics_process(0.24)
	_expect(
		_count_reason(machine.directed_events, CONTINUED_DRAG_REASON) == 0,
		"continued dragging does not update opinions before its cooldown"
	)
	roped._physics_process(0.02)
	_expect(
		_count_reason(machine.directed_events, CONTINUED_DRAG_REASON) == 1,
		"continued dragging applies once when the cooldown elapses"
	)
	roped._physics_process(0.01)
	_expect(
		_count_reason(machine.directed_events, CONTINUED_DRAG_REASON) == 1,
		"continued dragging is cooldown-gated rather than frame-based"
	)
	_expect(
		_count_reason(machine.directed_events, FIRST_DRAG_REASON) == 1,
		"returning from slack does not replay first drag"
	)

	var fight_replaced_roped := machine.request_state(
		&"Fight", player, "ordinary_fight_request", 94
	)
	_expect(not fight_replaced_roped, "ordinary Fight priority cannot replace active Roped")
	_expect(machine.is_primary_state(&"Roped"), "Roped retains primary ownership")
	_expect(
		not machine.request_state(&"Downed", player, "weak_hard_override", 0),
		"hard-override names still require their conventional priority"
	)
	var interaction_gate := machine.can_begin_player_interaction(player)
	_expect(
		not bool(interaction_gate.get("accepted", false))
		and String(interaction_gate.get("reason", "")) == "npc_roped",
		"ordinary player Talk interaction cannot replace active Roped"
	)
	var ownership_gate := machine.get_scheduled_activity_ownership_gate()
	_expect(
		bool(ownership_gate.get("protected", false)),
		"Roped's emergency intent protects it from schedule replacement"
	)

	# Airborne motion remains entirely with gravity/the rope. Once grounded after
	# displacement, private intent gently corrects toward the last slack point.
	npc.velocity = Vector2(100.0, 17.0)
	roped.test_grounded = false
	roped.physics_process(0.25)
	_expect(
		npc.velocity == Vector2(100.0, 17.0),
		"Roped does not inject struggle force into an airborne rope swing"
	)
	roped.test_grounded = true
	npc.position.x = 20.0
	var position_before_struggle := npc.position
	roped.physics_process(0.25)
	_expect(
		is_equal_approx(npc.velocity.x, -14.0),
		"position hold applies a capped correction toward the last slack point"
	)
	_expect(
		is_equal_approx(npc.velocity.y, 17.0) and npc.position == position_before_struggle,
		"Roped authors only horizontal velocity intent and never moves the body directly"
	)
	# Simulate the previous frame having yanked the physical body hard toward the
	# anchor. The next authored velocity must continue from private struggle
	# intent, not turn that yank into voluntary NPC movement.
	npc.velocity.x = 550.0
	roped.physics_process(0.25)
	_expect(
		is_equal_approx(npc.velocity.x, -14.0),
		"a prior rope yank cannot become fresh NPC position-hold intent"
	)
	_expect(
		animation_controller.latest_facing < 0.0,
		"a displaced NPC faces back toward the held point"
	)

	# Repeated dash intent used to feed the shared rope result back into Roped and
	# rapidly approach the unrestricted dash speed. A real taut 1:2 rope should
	# keep resolving the same mass-weighted speed every frame instead.
	rope_anchor.position.x = 121.0
	var weighted_dash_speed := 0.0
	for _frame in range(8):
		roped.physics_process(1.0 / 60.0)
		_expect(
			is_equal_approx(npc.velocity.x, -14.0),
			"repeated rope solves never become fresh NPC movement intent"
		)
		rope_anchor.velocity = Rope.constrain_attached_velocity(
			rope_anchor,
			Vector2(1650.0, 0.0),
			1.0 / 60.0
		)
		npc.velocity = Rope.constrain_attached_velocity(
			npc,
			npc.velocity,
			1.0 / 60.0
		)
		weighted_dash_speed = rope_anchor.velocity.x
	_expect(
		absf(weighted_dash_speed - 540.6667) <= 0.01
		and absf(npc.velocity.x - weighted_dash_speed) <= 0.01,
		"Mom's weight and gentle position hold resist a dash without running away"
	)
	roped.physics_process(1.0 / 60.0)
	rope_anchor.velocity = Rope.constrain_attached_velocity(
		rope_anchor,
		Vector2.ZERO,
		1.0 / 60.0
	)
	npc.velocity = Rope.constrain_attached_velocity(
		npc,
		npc.velocity,
		1.0 / 60.0
	)
	_expect(
		rope_anchor.velocity.x < -5.0
		and absf(npc.velocity.x - rope_anchor.velocity.x) <= 0.01,
		"position holding applies bounded reciprocal resistance"
	)

	npc.position.x = -20.0
	rope_anchor.position.x = -121.0
	roped.physics_process(0.25)
	_expect(
		npc.velocity.x > 0.0 and animation_controller.latest_facing > 0.0,
		"position holding reverses only after the NPC crosses the held point"
	)
	npc.position.x = -2.0
	rope_anchor.position.x = -103.0
	roped.physics_process(0.25)
	_expect(
		is_zero_approx(npc.velocity.x)
		and animation_controller.latest_facing > 0.0,
		"the hold-position deadzone settles without flickering facing"
	)

	npc.attached_ropes.clear()
	npc.velocity.x = 50.0
	roped.physics_process(0.25)
	_expect(
		is_zero_approx(npc.velocity.x),
		"a transient missing endpoint stops private intent without adopting solved coasting"
	)
	npc.attached_ropes = [attached_rope]
	rope_anchor.position.x = 100.0

	roped.dragged_animation_name = &"custom_struggle"
	roped.physics_process(0.016)
	_expect(
		animation_controller.fixed_requests.back() == &"custom_struggle",
		"dragged animation is an editable hook with walk as the shipped stand-in"
	)
	var fixed_request_count := animation_controller.fixed_requests.size()
	roped.physics_process(0.016)
	_expect(
		animation_controller.fixed_requests.size() == fixed_request_count,
		"stable struggle presentation is not restarted every frame"
	)

	_expect(
		machine.request_state(&"Downed", player, "test_hard_override", 99),
		"a priority-99 hard override can replace Roped"
	)
	await process_frame
	_expect(machine.is_primary_state(&"Downed"), "Roped waits while the hard override is active")
	npc.set_rope_status(true, true)
	_expect(
		_count_reason(machine.directed_events, ATTACHED_REASON) == 1
		and _count_reason(machine.directed_events, FIRST_DRAG_REASON) == 1,
		"a temporary override does not replay session one-shots"
	)

	# A real recovery path can enter Idle with a very high priority. Roped must
	# still reacquire based on Idle's outgoing rules, not that historical priority.
	downed.locked = false
	_expect(
		machine.request_state(&"Idle", null, "test_hard_recovery", 1000),
		"hard override recovers to Idle"
	)
	await process_frame
	_expect(machine.is_primary_state(&"Roped"), "Roped reacquires while still attached")
	_expect(
		_count_reason(machine.directed_events, ATTACHED_REASON) == 1
		and _count_reason(machine.directed_events, FIRST_DRAG_REASON) == 1,
		"reacquiring Roped preserves the uninterrupted session"
	)

	var first_session_id := _first_session_id(machine.directed_events)
	npc.set_rope_status(false, false)
	_expect(not roped.attached and not roped.dragged, "detach ends both rope statuses")
	await process_frame
	_expect(machine.is_primary_state(&"Idle"), "detach leaves Roped for Idle")

	npc.set_rope_status(true, false)
	_expect(
		_count_reason(machine.directed_events, ATTACHED_REASON) == 2,
		"reattachment starts a fresh attachment event"
	)
	await process_frame
	_expect(machine.is_primary_state(&"Roped"), "reattachment enters Roped again")
	npc.set_rope_status(true, true)
	_expect(
		_count_reason(machine.directed_events, FIRST_DRAG_REASON) == 2,
		"reattachment permits one new first-drag event"
	)
	var latest_session_id := _latest_session_id(machine.directed_events)
	_expect(
		first_session_id > 0 and latest_session_id > first_session_id,
		"detach and reattach use a new rope-session id"
	)

	world.queue_free()
	await process_frame


func _count_reason(events: Array[Dictionary], reason: String) -> int:
	var count := 0
	for event in events:
		if String(event.get("reason", "")) == reason:
			count += 1
	return count


func _first_session_id(events: Array[Dictionary]) -> int:
	for event in events:
		if String(event.get("reason", "")) != ATTACHED_REASON:
			continue
		var context: Dictionary = event.get("context", {})
		return int(context.get("rope_session_id", 0))
	return 0


func _latest_session_id(events: Array[Dictionary]) -> int:
	var latest := 0
	for event in events:
		var context: Dictionary = event.get("context", {})
		latest = maxi(latest, int(context.get("rope_session_id", 0)))
	return latest


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
