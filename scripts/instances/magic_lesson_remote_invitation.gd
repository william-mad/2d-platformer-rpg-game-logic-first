class_name MagicLessonRemoteInvitation extends Node2D

signal lesson_invitation_started(mom: Node2D, player: Node2D)
signal lesson_declined(mom: Node2D, player: Node2D)
signal lesson_cancelled(reason: StringName)

const STATE_IDLE := &"idle"
const STATE_INVITING := &"inviting"
const STATE_ACCEPTED := &"accepted"
const STATE_DECLINED := &"declined"
const STATE_CANCELLED := &"cancelled"

var spot_id: StringName = &""
var lesson_id: StringName = &"mom_magic_lesson"
var world_definition: NpcSpotDefinition
var lesson_scene_path: String = ""
var lesson_position: Vector2 = Vector2.ZERO
var prompt_title: String = "Study magic with Mom?"
var prompt_options: PackedStringArray = ["Yes", "Not now"]
var prompt_timeout_seconds: float = 20.0
var mark_spot_unavailable_after_attempt: bool = true

var state: StringName = STATE_IDLE
var active_mom: Node2D
var active_player: Node2D
var completed_day: int = -1
var skipped_day: int = -1
var _scene_spot_config_loaded: bool = false
var _scene_spot_config_key: String = ""
var _cached_scene_spot_enabled: bool = true
var _scene_spot_config_load_count: int = 0


func configure(definition: NpcSpotDefinition, activity: Dictionary = {}) -> void:
	world_definition = definition
	if definition != null:
		spot_id = definition.spot_id
		lesson_id = definition.spot_id
		lesson_scene_path = definition.scene_path
		lesson_position = definition.position
		var target_position = activity.get("target_position", definition.position)
		if target_position is Vector2:
			global_position = target_position
	if activity.has("lesson_scene_path"):
		lesson_scene_path = String(activity.get("lesson_scene_path", lesson_scene_path))
	var activity_position = activity.get("lesson_position", lesson_position)
	if activity_position is Vector2:
		lesson_position = activity_position
	var next_config_key := _get_scene_spot_config_key()
	if next_config_key != _scene_spot_config_key:
		_scene_spot_config_key = next_config_key
		_scene_spot_config_loaded = false
		_cached_scene_spot_enabled = true
	_apply_scene_spot_config()


func can_start_lesson(mom: Node2D, player: Node2D) -> bool:
	if _magic_lesson_disabled():
		return false
	if mom == null or player == null:
		return false
	if not is_instance_valid(mom) or not is_instance_valid(player):
		return false
	if state == STATE_INVITING:
		return mom == active_mom and player == active_player
	if state == STATE_ACCEPTED:
		return false
	if _attempt_already_used_today():
		return false
	if not _world_spot_is_available():
		return false

	return mom.is_inside_tree() and player.is_inside_tree() and is_inside_tree()


func begin_invitation(mom: Node2D, player: Node2D) -> bool:
	if not can_start_lesson(mom, player):
		return false
	if state == STATE_INVITING and mom == active_mom and player == active_player:
		return true

	var interactor := _get_player_prompt_interactor(player)
	if interactor == null or not interactor.has_method("show_npc_prompt"):
		return false

	active_mom = mom
	active_player = player
	state = STATE_INVITING

	var shown := bool(interactor.call(
		"show_npc_prompt",
		mom,
		lesson_id,
		prompt_title,
		prompt_options,
		self,
		&"accept_lesson",
		&"decline_lesson",
		prompt_timeout_seconds
	))
	if not shown:
		_clear_participants()
		state = STATE_IDLE
		return false

	lesson_invitation_started.emit(mom, player)
	return true


func accept_lesson(mom: Node2D, player: Node2D, _prompt_id: StringName = &"") -> bool:
	if state != STATE_INVITING:
		return false
	if mom != active_mom or player != active_player:
		return false
	if lesson_scene_path.is_empty():
		cancel_lesson(&"missing_lesson_scene")
		return false

	state = STATE_ACCEPTED
	_set_activity_phase(&"running")
	_move_activity_to_lesson_scene()
	_move_player_to_lesson_scene(player)
	return true


func decline_lesson(mom: Node2D, player: Node2D, _prompt_id: StringName = &"") -> void:
	if state != STATE_INVITING:
		return
	if mom != active_mom or player != active_player:
		return

	skipped_day = _get_current_day()
	state = STATE_DECLINED
	lesson_declined.emit(mom, player)
	_mark_attempt_consumed()
	_finish_scheduled_activity()
	_clear_participants()
	call_deferred("queue_free")


func cancel_lesson(reason: StringName) -> void:
	if state == STATE_IDLE or state == STATE_ACCEPTED or state == STATE_DECLINED:
		return

	state = STATE_CANCELLED
	lesson_cancelled.emit(reason)
	_finish_scheduled_activity()
	_clear_participants()
	call_deferred("queue_free")


func is_invitation_pending_for(mom: Node2D, player: Node2D) -> bool:
	return state == STATE_INVITING and mom == active_mom and player == active_player


func is_lesson_active_for(mom: Node2D, player: Node2D) -> bool:
	return state == STATE_ACCEPTED and mom == active_mom and player == active_player


func lesson_is_done_for(_mom: Node2D, _player: Node2D) -> bool:
	var current_day := _get_current_day()
	return (
		(state == STATE_DECLINED and skipped_day == current_day)
		or (completed_day == current_day)
	)


func is_lesson_spot_enabled() -> bool:
	return not _magic_lesson_disabled()


func _move_activity_to_lesson_scene() -> void:
	if active_mom == null or not is_instance_valid(active_mom):
		return

	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_npc_location"):
		return

	var npc_id := _get_mom_location_id()
	if npc_id.is_empty():
		return

	var record: Dictionary = locations.call("get_npc_location", npc_id)
	var activity = record.get("activity", {})
	if not (activity is Dictionary) or activity.is_empty():
		return

	var updated_activity: Dictionary = activity.duplicate(true)
	updated_activity["lesson_phase"] = "running"
	updated_activity["target_scene_path"] = lesson_scene_path
	updated_activity["target_position"] = lesson_position
	updated_activity["lesson_scene_path"] = lesson_scene_path
	updated_activity["lesson_position"] = lesson_position
	updated_activity["last_total_hours"] = _get_current_total_hours()

	if locations.has_method("begin_scheduled_activity"):
		locations.call(
			"begin_scheduled_activity",
			npc_id,
			updated_activity,
			lesson_scene_path,
			lesson_position
		)


func _move_player_to_lesson_scene(player: Node2D) -> void:
	var runtime := get_node_or_null("/root/PlayerRuntime")
	if runtime != null and runtime.has_method("capture_player"):
		runtime.call("capture_player", player, &"")

	var scene_loader := get_node_or_null("/root/SceneLoader")
	if scene_loader != null and scene_loader.has_method("change_scene"):
		if bool(scene_loader.call("change_scene", lesson_scene_path)):
			return

	get_tree().change_scene_to_file(lesson_scene_path)


func _set_activity_phase(phase: StringName) -> void:
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("set_scheduled_activity_field"):
		return

	var npc_id := _get_mom_location_id()
	if npc_id.is_empty():
		return

	locations.call("set_scheduled_activity_field", npc_id, &"lesson_phase", String(phase))
	locations.call("set_scheduled_activity_field", npc_id, &"last_total_hours", _get_current_total_hours())


func _finish_scheduled_activity() -> void:
	if active_mom == null or not is_instance_valid(active_mom):
		return

	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("finish_scheduled_activity"):
		return

	var npc_id := _get_mom_location_id()
	if npc_id.is_empty():
		return

	locations.call(
		"finish_scheduled_activity",
		npc_id,
		_get_current_scene_path(),
		active_mom.global_position
	)


func _mark_attempt_consumed() -> void:
	if not mark_spot_unavailable_after_attempt:
		return

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("set_spot_value") and world_definition != null:
		simulator.call("set_spot_value", spot_id, world_definition.spot_value_done_threshold, false)


func _world_spot_is_available() -> bool:
	if world_definition == null:
		return true

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("get_spot_value"):
		return world_definition.spot_value_initial > world_definition.spot_value_done_threshold

	return (
		float(simulator.call("get_spot_value", spot_id, world_definition.spot_value_initial))
		> world_definition.spot_value_done_threshold
	)


func _get_player_prompt_interactor(player: Node2D) -> Node:
	if player == null or not is_instance_valid(player):
		return null
	if player.has_method("show_npc_prompt"):
		return player

	return player.get_node_or_null("NpcTalkInteractor")


func _get_mom_location_id() -> String:
	if active_mom == null or not is_instance_valid(active_mom):
		return ""
	if active_mom.has_method("get_npc_location_id"):
		return String(active_mom.call("get_npc_location_id"))
	if active_mom.has_meta("npc_location_id"):
		return String(active_mom.get_meta("npc_location_id"))

	return ""


func _clear_participants() -> void:
	active_mom = null
	active_player = null


func _attempt_already_used_today() -> bool:
	var current_day := _get_current_day()
	return completed_day == current_day or skipped_day == current_day


func _get_current_day() -> int:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		return int(snapshot.get("day", 0))

	return 0


func _get_current_total_hours() -> float:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		return float(snapshot.get(
			"total_hours",
			float(snapshot.get("day", 0)) * 24.0 + float(snapshot.get(
				"time_of_day_hours",
				snapshot.get("hour", 0.0)
			))
		))

	return 0.0


func _get_current_scene_path() -> String:
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return ""

	return current_scene.scene_file_path


func _magic_lesson_disabled() -> bool:
	if not _scene_spot_enabled():
		return true
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_MAGIC_LESSON_ACTIVITY
	)


func _scene_spot_enabled() -> bool:
	_ensure_scene_spot_config_loaded()
	return _cached_scene_spot_enabled


func _node_matches_lesson_spot(node: Node) -> bool:
	if node == null:
		return false
	var value = _get_property_if_present(node, &"spot_id")
	if value == null:
		return false

	return String(value) == String(spot_id)


func _apply_scene_spot_config() -> void:
	_ensure_scene_spot_config_loaded()


func _ensure_scene_spot_config_loaded() -> void:
	if _scene_spot_config_loaded:
		return

	_scene_spot_config_loaded = true
	_cached_scene_spot_enabled = true
	var scene_path := _get_scene_spot_config_scene_path()
	if scene_path.is_empty():
		return

	_scene_spot_config_load_count += 1
	var packed_scene := load(scene_path) as PackedScene
	if packed_scene == null:
		return

	var root := packed_scene.instantiate()
	if root == null:
		return

	var spot := _find_scene_lesson_spot(root)
	if spot != null:
		var enabled = _get_property_if_present(spot, &"lesson_enabled")
		if enabled != null:
			_cached_scene_spot_enabled = bool(enabled)
		var title = _get_property_if_present(spot, &"prompt_title")
		if title != null:
			prompt_title = String(title)
		var options = _get_property_if_present(spot, &"prompt_options")
		if options is PackedStringArray:
			prompt_options = options
		var timeout = _get_property_if_present(spot, &"prompt_timeout_seconds")
		if timeout != null:
			prompt_timeout_seconds = float(timeout)
		var consume = _get_property_if_present(spot, &"mark_spot_unavailable_after_attempt")
		if consume != null:
			mark_spot_unavailable_after_attempt = bool(consume)
	root.free()


func _get_scene_spot_config_scene_path() -> String:
	if not lesson_scene_path.is_empty():
		return lesson_scene_path
	if world_definition != null:
		return world_definition.scene_path

	return ""


func _get_scene_spot_config_key() -> String:
	return "%s|%s" % [_get_scene_spot_config_scene_path(), String(spot_id)]


func _find_scene_lesson_spot(node: Node) -> Node:
	if _node_matches_lesson_spot(node):
		return node

	for child in node.get_children():
		var found := _find_scene_lesson_spot(child)
		if found != null:
			return found

	return null


func _get_property_if_present(object: Object, property_name: StringName):
	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return object.get(property_name)

	return null
