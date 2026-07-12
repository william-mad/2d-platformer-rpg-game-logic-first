class_name TravelCompanionComponent
extends Node

@export var can_travel_with_player: bool = true
@export var minimum_favor_required: float = 0.0
@export var travel_policy: TravelPolicy


func get_unavailable_reason(npc: Node, player: Node) -> String:
	if not can_travel_with_player:
		return "This NPC cannot travel."
	if npc == null or player == null:
		return "Traveler unavailable."
	var machine := npc.get_node_or_null("NpcStateMachine") as NpcStateMachine
	if machine == null or not npc.has_method("get_inventory"):
		return "Traveler is missing movement or inventory support."
	if machine.get_value(&"disabled") >= 1.0 or machine.get_value(&"hp") <= 0.0:
		return "Traveler is not able to leave."
	if String(machine.current_state.name if machine.current_state != null else "") in ["Downed", "DisabledDead"]:
		return "Traveler must recover first."
	if npc.has_method("get_relationship_favor_for"):
		if float(npc.call("get_relationship_favor_for", player, 0.0)) < minimum_favor_required:
			return "More favor is required."
	return ""

