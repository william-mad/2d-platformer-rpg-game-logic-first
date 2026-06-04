class_name NpcFavorEventArea extends Area2D

@export var target_npc_path: NodePath
@export var stat_delta: Dictionary = {
	"favor": 10.0
}
@export var requires_npc_detection: bool = true
@export var trigger_once: bool = false
@export var cooldown_seconds: float = 1.0
@export var zone_color: Color = Color(0.2, 0.8, 0.25, 0.35)

@onready var zone_visual: Polygon2D = get_node_or_null("%ZoneVisual") as Polygon2D

var applied_bodies: Dictionary = {}
var cooldowns: Dictionary = {}


func _ready() -> void:
	if zone_visual != null:
		zone_visual.color = zone_color


func _physics_process(delta: float) -> void:
	_tick_cooldowns(delta)

	for body in get_overlapping_bodies():
		if body.is_in_group("player"):
			_try_apply_to_player(body)


func _try_apply_to_player(player: Node2D) -> void:
	var body_id := player.get_instance_id()
	if trigger_once and bool(applied_bodies.get(body_id, false)):
		return

	if float(cooldowns.get(body_id, 0.0)) > 0.0:
		return

	var target_npc := get_node_or_null(target_npc_path)
	if target_npc == null:
		return

	var event_receiver := _get_event_receiver(target_npc)
	if event_receiver == null:
		return

	if requires_npc_detection and target_npc.has_method("can_see") and not bool(target_npc.call("can_see", player)):
		return

	if bool(event_receiver.call("apply_social_event", stat_delta, player, requires_npc_detection)):
		applied_bodies[body_id] = true
		cooldowns[body_id] = cooldown_seconds


func _get_event_receiver(target_node: Node) -> Node:
	if target_node.has_method("apply_social_event"):
		return target_node

	return target_node.get_node_or_null("NpcStateMachine")


func _tick_cooldowns(delta: float) -> void:
	for body_id in cooldowns.keys():
		var next_time := float(cooldowns[body_id]) - delta
		if next_time <= 0.0:
			cooldowns.erase(body_id)
		else:
			cooldowns[body_id] = next_time
