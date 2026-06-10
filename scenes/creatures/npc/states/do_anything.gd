class_name NpcStateDoAnything extends NpcState

@export var talk_need_threshold: float = 40.0
@export var require_relationship_favor_for_npcs: bool = true
@export_range(0.0, 100.0, 0.1) var minimum_relationship_favor: float = 20.0
@export var hunger_threshold: float = 35.0
@export var sleep_need_threshold: float = 35.0
@export var fallback_state_name: StringName = &"Work"

var picked_action: bool = false


func enter() -> void:
	# Defers choice by one frame so entering this state fully settles first.
	super.enter()
	stop_horizontal()
	picked_action = false
	call_deferred("_pick_action")


func physics_process(_delta: float) -> NpcState:
	# This state chooses another action; it does not move on its own.
	stop_horizontal()
	return next_state


func _pick_action() -> void:
	# Chooses a useful fallback action when boredom is very high but not capped.
	if picked_action or machine == null:
		return

	if machine.current_state != self:
		return

	picked_action = true

	var talk_target := machine.get_active_target()
	if (
		talk_target != null
		and machine.get_value(&"talk_need") >= talk_need_threshold
		and machine.can_talk_to_target(
			talk_target,
			minimum_relationship_favor,
			require_relationship_favor_for_npcs
		)
	):
		if machine.request_talk(talk_target):
			return

	if (
		machine.get_value(&"hunger") >= hunger_threshold
		and machine.get_state(&"Eat") != null
	):
		if machine.request_state(&"Eat", null, "do_anything:eat", 20):
			return

	if (
		machine.get_value(&"sleep_need") >= sleep_need_threshold
		and machine.get_state(&"Rest") != null
	):
		if machine.request_state(&"Rest", null, "do_anything:rest", 20):
			return

	if fallback_state_name != &"":
		machine.request_state(fallback_state_name, null, "do_anything:fallback", 20)
