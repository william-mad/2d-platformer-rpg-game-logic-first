class_name PlayerSleepSpot extends Area2D

@export var player_group: StringName = &"player"
@export var interaction_action: StringName = &"up"
@export var interaction_priority: int = 100
@export var interaction_prompt: String = "Sleep"
@export_range(0.05, 30.0, 0.05, "suffix:s") var sleep_duration_seconds: float = 4.0
@export_range(0.0, 100.0, 0.1) var sleep_need_drop: float = 100.0
@export var owner_debug_text: String = "owners:player"

@export_group("Overnight Skip")
@export var advance_world_to_wake_time: bool = true
@export_range(0.0, 24.0, 0.01, "suffix:h") var wake_hour: float = 6.0
@export var always_advance_to_next_day: bool = true
@export var simulate_npcs_overnight: bool = true
@export var player_hunger_grows_while_sleeping: bool = true

@export_group("Fade")
@export var sleep_fade_color: Color = Color(0.0, 0.0, 0.0, 1.0)
@export_range(0.0, 5.0, 0.05, "suffix:s") var fade_out_seconds: float = 0.45
@export_range(0.0, 5.0, 0.05, "suffix:s") var black_hold_seconds: float = 0.25
@export_range(0.0, 5.0, 0.05, "suffix:s") var fade_in_seconds: float = 0.65
@export var fade_canvas_layer: int = 140

@onready var label: Label = get_node_or_null("%Label") as Label

var nearby_players: Array[Node2D] = []
var active_player: Node2D
var sleep_timer: float = 0.0
var sleep_transition_running: bool = false
var sleep_overlay_layer: CanvasLayer
var sleep_overlay: ColorRect


func _ready() -> void:
	add_to_group("player_sleep_spot")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	_update_label()


func _process(delta: float) -> void:
	if active_player != null:
		if sleep_transition_running:
			_stop_player_horizontal(active_player)
			return
		_update_sleep_action(delta)


func can_interact(actor: Node) -> bool:
	var player := actor as Node2D
	if player == null or not nearby_players.has(player) or active_player != null:
		return false
	return not player.has_method("can_sleep") or bool(player.call("can_sleep"))


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	_start_sleep(actor as Node2D)
	return true


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return interaction_prompt


func _start_sleep(player: Node2D) -> void:
	active_player = player
	sleep_timer = maxf(sleep_duration_seconds, 0.05)
	sleep_transition_running = false
	if active_player.has_method("begin_spot_action"):
		active_player.call("begin_spot_action", self, &"sleep")
	_update_label()


func _update_sleep_action(delta: float) -> void:
	if active_player == null or not is_instance_valid(active_player) or not nearby_players.has(active_player):
		_cancel_sleep()
		return

	_stop_player_horizontal(active_player)
	sleep_timer -= delta
	if sleep_timer > 0.0:
		_update_label()
		return

	sleep_transition_running = true
	_run_sleep_transition(active_player)


func _cancel_sleep() -> void:
	if sleep_transition_running:
		return
	if active_player != null and is_instance_valid(active_player) and active_player.has_method("end_spot_action"):
		active_player.call("end_spot_action", self, &"sleep", false)
	_clear_sleep()


func _clear_sleep() -> void:
	active_player = null
	sleep_timer = 0.0
	sleep_transition_running = false
	_update_label()


func _update_label() -> void:
	if label == null:
		return

	var value_text := "Sleep"
	if sleep_transition_running:
		value_text = "Morning"
	if active_player != null and sleep_duration_seconds > 0.0:
		var progress := 1.0 - clampf(sleep_timer / sleep_duration_seconds, 0.0, 1.0)
		if not sleep_transition_running:
			value_text = "Sleep %d%%" % int(round(progress * 100.0))

	label.text = "%s\n%s" % [owner_debug_text, value_text]


func _on_body_entered(body: Node2D) -> void:
	if body == null or not body.is_in_group(String(player_group)):
		return
	if not nearby_players.has(body):
		nearby_players.append(body)
	if body.has_method("register_interaction_candidate"):
		body.call("register_interaction_candidate", self)


func _on_body_exited(body: Node2D) -> void:
	nearby_players.erase(body)
	if body.has_method("unregister_interaction_candidate"):
		body.call("unregister_interaction_candidate", self)
	if body == active_player and not sleep_transition_running:
		_cancel_sleep()


func _stop_player_horizontal(player: Node2D) -> void:
	var player_body := player as CharacterBody2D
	if player_body != null:
		player_body.velocity.x = 0.0


func _run_sleep_transition(slept_player: Node2D) -> void:
	_update_label()
	await _fade_sleep_overlay(1.0, fade_out_seconds)
	if black_hold_seconds > 0.0:
		await get_tree().create_timer(black_hold_seconds).timeout

	var sleep_skip := _get_sleep_skip_totals()
	var skipped_game_hours := float(sleep_skip.get("skipped_game_hours", 0.0))
	_apply_player_sleep_results(slept_player, skipped_game_hours)
	_restore_live_character_health_after_sleep(slept_player)
	_simulate_npc_sleep_skip(sleep_skip)
	_apply_world_sleep_time(sleep_skip)

	await get_tree().process_frame
	await _fade_sleep_overlay(0.0, fade_in_seconds)
	_remove_sleep_overlay()

	if slept_player != null and is_instance_valid(slept_player) and slept_player.has_method("end_spot_action"):
		slept_player.call("end_spot_action", self, &"sleep", true)
	_clear_sleep()


func _get_sleep_skip_totals() -> Dictionary:
	var world_time := get_node_or_null("/root/WorldTime")
	if not advance_world_to_wake_time or world_time == null or not world_time.has_method("get_total_hours"):
		return {
			"start_total_hours": 0.0,
			"end_total_hours": 0.0,
			"skipped_game_hours": 0.0,
		}

	var start_total_hours := float(world_time.call("get_total_hours"))
	var current_day := int(floor(start_total_hours / 24.0))
	var normalized_wake_hour := fposmod(wake_hour, 24.0)
	var end_total_hours := float(current_day + 1) * 24.0 + normalized_wake_hour
	if not always_advance_to_next_day:
		var today_wake_hours := float(current_day) * 24.0 + normalized_wake_hour
		end_total_hours = today_wake_hours if today_wake_hours > start_total_hours else end_total_hours
	if end_total_hours <= start_total_hours:
		end_total_hours += 24.0

	return {
		"start_total_hours": start_total_hours,
		"end_total_hours": end_total_hours,
		"skipped_game_hours": maxf(end_total_hours - start_total_hours, 0.0),
	}


func _apply_player_sleep_results(player: Node2D, skipped_game_hours: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	if player_hunger_grows_while_sleeping and skipped_game_hours > 0.0 and player.has_method("apply_hunger_delta"):
		var hunger_rate := float(_get_object_property(player, &"hunger_growth_per_game_hour", 0.0))
		player.call("apply_hunger_delta", hunger_rate * skipped_game_hours)
	if player.has_method("apply_sleep_need_delta"):
		player.call("apply_sleep_need_delta", -absf(sleep_need_drop))
	if player.has_method("restore_full_health"):
		player.call("restore_full_health")


func _restore_live_character_health_after_sleep(slept_player: Node2D) -> void:
	var restored_instance_ids := {}
	_restore_character_health(slept_player, restored_instance_ids)

	var tree := get_tree()
	if tree == null:
		return

	for group_name in [&"player", &"npc", &"social_npc"]:
		for body in tree.get_nodes_in_group(group_name):
			_restore_character_health(body, restored_instance_ids)

	var current_scene := tree.current_scene
	if current_scene != null:
		_restore_character_health_recursive(current_scene, restored_instance_ids)


func _restore_character_health_recursive(root: Node, restored_instance_ids: Dictionary) -> void:
	if root == null:
		return

	_restore_character_health(root, restored_instance_ids)
	for child in root.get_children():
		_restore_character_health_recursive(child, restored_instance_ids)


func _restore_character_health(candidate: Node, restored_instance_ids: Dictionary) -> void:
	if candidate == null or not is_instance_valid(candidate):
		return

	var instance_id := candidate.get_instance_id()
	if restored_instance_ids.has(instance_id):
		return
	restored_instance_ids[instance_id] = true

	if candidate.has_method("restore_full_health"):
		candidate.call("restore_full_health")
		return

	var max_hp = _get_object_property(candidate, &"max_hp", null)
	if max_hp == null:
		return

	var max_hp_value := maxf(float(max_hp), 0.0)
	if max_hp_value <= 0.0:
		return

	var current_hp := _get_character_hp(candidate)
	if current_hp <= 0.0 or current_hp >= max_hp_value:
		return

	if candidate.has_method("heal"):
		candidate.call("heal", max_hp_value - current_hp)
		return

	if _has_object_property(candidate, &"hp"):
		candidate.set("hp", max_hp_value)
		if candidate.has_method("update_hp_bar"):
			candidate.call("update_hp_bar")


func _get_character_hp(candidate: Node) -> float:
	if candidate.has_method("get_hp"):
		return float(candidate.call("get_hp"))

	var hp = _get_object_property(candidate, &"hp", 0.0)
	return float(hp)


func _simulate_npc_sleep_skip(sleep_skip: Dictionary) -> void:
	if not simulate_npcs_overnight:
		return
	var skipped_game_hours := float(sleep_skip.get("skipped_game_hours", 0.0))
	if skipped_game_hours <= 0.0:
		return

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("simulate_player_sleep_skip"):
		return

	simulator.call(
		"simulate_player_sleep_skip",
		float(sleep_skip.get("start_total_hours", 0.0)),
		float(sleep_skip.get("end_total_hours", 0.0)),
		{}
	)


func _apply_world_sleep_time(sleep_skip: Dictionary) -> void:
	if not advance_world_to_wake_time:
		return
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time == null or not world_time.has_method("set_total_hours"):
		return

	var end_total_hours := float(sleep_skip.get("end_total_hours", 0.0))
	if end_total_hours > 0.0:
		world_time.call("set_total_hours", end_total_hours)


func _fade_sleep_overlay(target_alpha: float, duration: float) -> void:
	var overlay := _ensure_sleep_overlay()
	if overlay == null:
		return

	var target_color := sleep_fade_color
	target_color.a = clampf(target_alpha, 0.0, 1.0)
	if duration <= 0.0:
		overlay.color = target_color
		return

	var tween := create_tween()
	tween.tween_property(overlay, "color", target_color, duration)
	await tween.finished


func _ensure_sleep_overlay() -> ColorRect:
	if sleep_overlay != null and is_instance_valid(sleep_overlay):
		return sleep_overlay

	sleep_overlay_layer = CanvasLayer.new()
	sleep_overlay_layer.name = "PlayerSleepFadeLayer"
	sleep_overlay_layer.layer = fade_canvas_layer
	get_tree().root.add_child(sleep_overlay_layer)

	sleep_overlay = ColorRect.new()
	sleep_overlay.name = "PlayerSleepFade"
	sleep_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sleep_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	var initial_color := sleep_fade_color
	initial_color.a = 0.0
	sleep_overlay.color = initial_color
	sleep_overlay_layer.add_child(sleep_overlay)
	return sleep_overlay


func _remove_sleep_overlay() -> void:
	if sleep_overlay_layer != null and is_instance_valid(sleep_overlay_layer):
		sleep_overlay_layer.queue_free()
	sleep_overlay_layer = null
	sleep_overlay = null


func _get_object_property(object: Object, property_name: StringName, fallback):
	if object == null:
		return fallback
	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return object.get(property_name)

	return fallback


func _has_object_property(object: Object, property_name: StringName) -> bool:
	if object == null:
		return false

	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return true

	return false
