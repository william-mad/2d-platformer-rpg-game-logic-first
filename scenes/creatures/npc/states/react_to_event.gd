class_name NpcStateReactToEvent extends NpcState

@export var reaction_duration: float = -1.0
@export var negative_favor_speed_multiplier: float = 1.5

var reaction_timer: float = 0.0
var reaction_target: Node2D
var reaction_velocity_x: float = 0.0


func enter() -> void:
	# Short attention/recoil state for a specific event actor, not normal sight.
	super.enter()
	reaction_target = machine.get_active_action_target()
	reaction_velocity_x = 0.0
	reaction_timer = reaction_duration

	if reaction_timer < 0.0:
		reaction_timer = machine.default_reaction_time

	_prepare_reaction()


func physics_process(delta: float) -> NpcState:
	if npc == null:
		return get_state(&"Idle")

	reaction_timer -= delta
	npc.velocity.x = reaction_velocity_x

	if reaction_timer <= 0.0:
		return get_state(&"Idle")

	return next_state


func target_lost(lost_target: Node2D) -> NpcState:
	if lost_target == reaction_target:
		return get_state(&"Idle")

	return next_state


func _prepare_reaction() -> void:
	if reaction_target == null or not is_instance_valid(reaction_target) or npc == null:
		stop_horizontal()
		return

	var x_direction_to_actor := reaction_target.global_position.x - npc.global_position.x
	if x_direction_to_actor == 0.0:
		stop_horizontal()
		return

	var favor_delta := machine.get_last_delta(&"favor")
	var direction_to_actor := signf(x_direction_to_actor)

	# Negative favor events make the NPC step away; positive/neutral events make it face the actor.
	if favor_delta < 0.0:
		var flee_direction := -direction_to_actor
		face_x_direction(flee_direction)
		reaction_velocity_x = (
			flee_direction
			* machine.get_effective_walk_speed()
			* negative_favor_speed_multiplier
		)
	else:
		face_x_direction(direction_to_actor)
		reaction_velocity_x = 0.0
