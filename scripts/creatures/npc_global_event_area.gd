class_name NpcGlobalEventArea extends Area2D

@export var target_npc_paths: Array[NodePath] = []
@export var interaction_action: StringName = &"charm"
@export var default_stat_delta: Dictionary = {
	"favor": 5.0
}
@export var npc_stat_deltas: Dictionary = {}
@export var trigger_once: bool = false
@export var cooldown_seconds: float = 1.0
@export var zone_color: Color = Color(0.45, 0.2, 0.95, 0.35)
@export var feedback_visible_time: float = 1.0
@export var feedback_fade_time: float = 0.6
@export var interaction_priority: int = 70
@export var interaction_prompt: String = "Interact"

@onready var zone_visual: Polygon2D = get_node_or_null("%ZoneVisual") as Polygon2D
@onready var feedback_label: Label = get_node_or_null("%FeedbackLabel") as Label

var applied_bodies: Dictionary = {}
var cooldowns: Dictionary = {}
var feedback_tween: Tween
var nearby_players: Array[Node2D] = []


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if zone_visual != null:
		zone_visual.color = zone_color
	if feedback_label != null:
		feedback_label.visible = false


func _process(delta: float) -> void:
	_tick_cooldowns(delta)


func can_interact(actor: Node) -> bool:
	var player := actor as Node2D
	if player == null or not nearby_players.has(player):
		return false
	var body_id := player.get_instance_id()
	if trigger_once and bool(applied_bodies.get(body_id, false)):
		return false
	if float(cooldowns.get(body_id, 0.0)) > 0.0:
		return false
	return _has_applicable_target()


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	return _try_apply_to_player(actor as Node2D)


func get_interaction_action(_actor: Node) -> StringName:
	return interaction_action


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return interaction_prompt


func _try_apply_to_player(player: Node2D) -> bool:
	var body_id := player.get_instance_id()

	var applied_summaries := _apply_to_designated_npcs(player)
	if not applied_summaries.is_empty():
		applied_bodies[body_id] = true
		cooldowns[body_id] = cooldown_seconds
		_show_feedback(_build_feedback_text(applied_summaries))
		return true
	return false


func _has_applicable_target() -> bool:
	for target_path in target_npc_paths:
		var target_npc := get_node_or_null(target_path)
		if (
			target_npc != null
			and _get_event_receiver(target_npc) != null
			and not _get_stat_delta_for_npc(target_npc, target_path).is_empty()
		):
			return true
	return false


func _apply_to_designated_npcs(player: Node2D) -> Array[String]:
	var applied_summaries: Array[String] = []

	for target_path in target_npc_paths:
		var target_npc := get_node_or_null(target_path)
		if target_npc == null:
			continue

		var event_receiver := _get_event_receiver(target_npc)
		if event_receiver == null:
			continue

		var stat_delta := _get_stat_delta_for_npc(target_npc, target_path)
		if stat_delta.is_empty():
			continue

		if bool(event_receiver.call("apply_social_event", stat_delta, player, false)):
			applied_summaries.append(_format_stat_delta(target_npc, stat_delta))

	return applied_summaries


func _get_stat_delta_for_npc(target_npc: Node, target_path) -> Dictionary:
	var path_key := String(target_path)
	if npc_stat_deltas.has(path_key) and npc_stat_deltas[path_key] is Dictionary:
		return npc_stat_deltas[path_key]

	var name_key := String(target_npc.name)
	if npc_stat_deltas.has(name_key) and npc_stat_deltas[name_key] is Dictionary:
		return npc_stat_deltas[name_key]

	return default_stat_delta


func _get_event_receiver(target_node: Node) -> Node:
	# This keeps older SocialNpc targets working while allowing direct machine targets too.
	if target_node.has_method("apply_social_event"):
		return target_node

	return target_node.get_node_or_null("NpcStateMachine")


func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	if not nearby_players.has(body):
		nearby_players.append(body)
	if body.has_method("register_interaction_candidate"):
		body.call("register_interaction_candidate", self)


func _on_body_exited(body: Node2D) -> void:
	nearby_players.erase(body)
	if body.has_method("unregister_interaction_candidate"):
		body.call("unregister_interaction_candidate", self)


func _format_stat_delta(target_npc: Node, stat_delta: Dictionary) -> String:
	var stat_text := ""

	for stat_key in stat_delta.keys():
		var amount := float(stat_delta[stat_key])
		var sign_text := "+" if amount > 0.0 else ""

		if not stat_text.is_empty():
			stat_text += ", "

		stat_text += "%s %s%s" % [
			String(stat_key),
			sign_text,
			_format_number(amount)
		]

	return "%s %s" % [target_npc.name, stat_text]


func _format_number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(int(value))

	return str(value)


func _build_feedback_text(applied_summaries: Array[String]) -> String:
	var feedback_text := ""

	for summary in applied_summaries:
		if not feedback_text.is_empty():
			feedback_text += "\n"

		feedback_text += summary

	return feedback_text


func _show_feedback(feedback_text: String) -> void:
	print(feedback_text)

	if feedback_label == null:
		return

	if feedback_tween != null and feedback_tween.is_valid():
		feedback_tween.kill()

	feedback_label.text = feedback_text
	feedback_label.visible = true
	feedback_label.modulate = Color(1, 1, 1, 1)

	feedback_tween = create_tween()
	feedback_tween.tween_interval(feedback_visible_time)
	feedback_tween.tween_property(feedback_label, "modulate:a", 0.0, feedback_fade_time)
	feedback_tween.tween_callback(Callable(self, "_hide_feedback_label"))


func _hide_feedback_label() -> void:
	if feedback_label != null:
		feedback_label.visible = false


func _tick_cooldowns(delta: float) -> void:
	for body_id in cooldowns.keys():
		var next_time := float(cooldowns[body_id]) - delta
		if next_time <= 0.0:
			cooldowns.erase(body_id)
		else:
			cooldowns[body_id] = next_time
