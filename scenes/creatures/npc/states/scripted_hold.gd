class_name NpcStateScriptedHold extends NpcState


func enter() -> void:
	begin_enter_without_animation()
	stop_horizontal()
	if machine == null:
		return
	var hold_animation := machine.get_scripted_hold_animation()
	if hold_animation != &"":
		play_animation(hold_animation)


func physics_process(_delta: float) -> NpcState:
	stop_horizontal()
	if machine == null or npc == null:
		return null
	var facing_target := machine.get_scripted_facing_target() as Node2D
	if facing_target != null and is_instance_valid(facing_target):
		face_x_direction(facing_target.global_position.x - npc.global_position.x)
	return null
