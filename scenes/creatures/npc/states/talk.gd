class_name NpcStateTalk extends NpcState

@export var talk_duration: float = -1.0
@export var talk_value_name: StringName = &"talk_interest"
@export var talk_complete_delta: float = -25.0

var talk_timer: float = 0.0
var talk_partner: Node2D


func enter() -> void:
	super.enter()
	talk_partner = machine.talk_target if machine.talk_target != null else machine.get_active_target()
	talk_timer = talk_duration

	if talk_timer < 0.0:
		talk_timer = machine.default_talk_time

	stop_horizontal()
	_face_talk_partner()


func physics_process(delta: float) -> NpcState:
	stop_horizontal()
	_face_talk_partner()

	if talk_timer <= 0.0:
		return next_state

	talk_timer -= delta
	if talk_timer > 0.0:
		return next_state

	if talk_value_name != &"":
		machine.apply_value_delta({String(talk_value_name): talk_complete_delta}, talk_partner, false)

	return get_state(&"Idle")


func target_lost(lost_target: Node2D) -> NpcState:
	if lost_target == talk_partner:
		return get_state(&"Idle")

	return next_state


func _face_talk_partner() -> void:
	if talk_partner == null or not is_instance_valid(talk_partner) or npc == null:
		return

	face_x_direction(talk_partner.global_position.x - npc.global_position.x)
