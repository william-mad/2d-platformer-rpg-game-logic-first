class_name MagicLessonSpot extends Node2D

signal lesson_invitation_started(mom: Node2D, player: Node2D)
signal lesson_started(mom: Node2D, player: Node2D)
signal lesson_completed(mom: Node2D, player: Node2D)
signal lesson_cancelled(reason: StringName)
signal lesson_declined(mom: Node2D, player: Node2D)

const STATE_IDLE := &"idle"
const STATE_INVITING := &"inviting"
const STATE_RUNNING := &"running"
const STATE_COMPLETED := &"completed"
const STATE_DECLINED := &"declined"
const STATE_CANCELLED := &"cancelled"

@export var spot_id: StringName = &"mom_magic_lesson"
@export var world_definition: NpcSpotDefinition
@export var lesson_id: StringName = &"mom_magic_lesson"
@export_range(0.5, 120.0, 0.1, "suffix:s") var lesson_duration_seconds: float = 6.0
@export_range(0.5, 60.0, 0.1, "suffix:s") var prompt_timeout_seconds: float = 20.0
@export var prompt_title: String = "Study magic with Mom?"
@export var prompt_options: PackedStringArray = ["Yes", "Not now"]
@export var mom_marker_path: NodePath = NodePath("MomLessonPosition")
@export var player_marker_path: NodePath = NodePath("PlayerLessonPosition")
@export var player_reward_meta: StringName = &"magic_xp"
@export var player_reward_amount: float = 1.0
@export var mom_reward_delta: Dictionary = {
	"trust": 2.0,
	"boredom": -8.0,
}
@export var mark_spot_unavailable_after_attempt: bool = true

var state: StringName = STATE_IDLE
var active_mom: Node2D
var active_player: Node2D
var lesson_timer: float = 0.0
var reward_applied: bool = false
var completed_day: int = -1
var skipped_day: int = -1


func _ready() -> void:
	add_to_group("magic_lesson_spot")
	if world_definition != null and spot_id == &"":
		spot_id = world_definition.spot_id
	if _magic_lesson_disabled():
		_breadcrumb("magic_lesson:disabled_ready", String(spot_id))
		set_process(false)
		return
	_register_live_spot()


func _exit_tree() -> void:
	_unlock_participants()
	_unregister_live_spot()


func _process(delta: float) -> void:
	if _magic_lesson_disabled():
		cancel_lesson(&"debug_disabled")
		set_process(false)
		return

	if state != STATE_RUNNING:
		if state == STATE_INVITING and not _participants_valid():
			cancel_lesson(&"invalid_participant")
		return

	if not _participants_valid():
		cancel_lesson(&"invalid_participant")
		return

	_hold_participants()
	lesson_timer -= delta
	if lesson_timer <= 0.0:
		complete_lesson()


func can_start_lesson(mom: Node2D, player: Node2D) -> bool:
	if _magic_lesson_disabled():
		_breadcrumb("magic_lesson:can_start_disabled", String(spot_id))
		return false
	if mom == null or player == null:
		return false
	if not is_instance_valid(mom) or not is_instance_valid(player):
		return false
	if state == STATE_INVITING or state == STATE_RUNNING:
		return mom == active_mom and player == active_player
	if _attempt_already_used_today():
		return false
	if not _world_spot_is_available():
		return false

	return mom.is_inside_tree() and player.is_inside_tree() and is_inside_tree()


func begin_invitation(mom: Node2D, player: Node2D) -> bool:
	if _magic_lesson_disabled():
		_breadcrumb("magic_lesson:begin_disabled", String(spot_id))
		return false
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
	reward_applied = false
	lesson_timer = 0.0

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

	start_lesson(mom, player)
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


func start_lesson(mom: Node2D, player: Node2D) -> void:
	if _magic_lesson_disabled():
		_breadcrumb("magic_lesson:start_disabled", String(spot_id))
		return
	active_mom = mom
	active_player = player
	state = STATE_RUNNING
	reward_applied = false
	lesson_timer = maxf(lesson_duration_seconds, 0.1)
	_place_participants()
	_lock_participants()
	lesson_started.emit(mom, player)


func complete_lesson() -> void:
	if state == STATE_COMPLETED:
		return

	_apply_reward_once()
	var completed_mom := active_mom
	var completed_player := active_player
	completed_day = _get_current_day()
	state = STATE_COMPLETED
	_unlock_participants()
	_mark_attempt_consumed()
	_finish_scheduled_activity()
	lesson_completed.emit(completed_mom, completed_player)
	_clear_participants()


func cancel_lesson(reason: StringName) -> void:
	if state == STATE_IDLE or state == STATE_COMPLETED or state == STATE_DECLINED:
		return

	state = STATE_CANCELLED
	_unlock_participants()
	lesson_cancelled.emit(reason)
	_finish_scheduled_activity()
	_clear_participants()


func is_invitation_pending_for(mom: Node2D, player: Node2D) -> bool:
	return state == STATE_INVITING and mom == active_mom and player == active_player


func is_lesson_active_for(mom: Node2D, player: Node2D) -> bool:
	return state == STATE_RUNNING and mom == active_mom and player == active_player


func lesson_is_done_for(_mom: Node2D, _player: Node2D) -> bool:
	var current_day := _get_current_day()
	return (
		(state == STATE_COMPLETED and completed_day == current_day)
		or (state == STATE_DECLINED and skipped_day == current_day)
	)


func get_lesson_state() -> StringName:
	return state


func _place_participants() -> void:
	var mom_position := _get_marker_position(mom_marker_path, global_position + Vector2(-28.0, 0.0))
	var player_position := _get_marker_position(player_marker_path, global_position + Vector2(28.0, 0.0))

	if active_mom != null and is_instance_valid(active_mom):
		if active_mom.has_method("set_npc_location_position"):
			active_mom.call("set_npc_location_position", mom_position)
		else:
			active_mom.global_position = mom_position
		_stop_body(active_mom)

	if active_player != null and is_instance_valid(active_player):
		active_player.global_position = player_position
		_stop_body(active_player)


func _lock_participants() -> void:
	if active_player != null and is_instance_valid(active_player):
		if active_player.has_method("begin_movement_lock"):
			active_player.call("begin_movement_lock", self, &"magic_lesson")
		elif active_player.has_method("begin_spot_action"):
			active_player.call("begin_spot_action", self, &"magic_lesson")


func _unlock_participants() -> void:
	if active_player != null and is_instance_valid(active_player):
		if active_player.has_method("end_movement_lock"):
			active_player.call("end_movement_lock", self, &"magic_lesson", state == STATE_COMPLETED)
		elif active_player.has_method("end_spot_action"):
			active_player.call("end_spot_action", self, &"magic_lesson", state == STATE_COMPLETED)


func _hold_participants() -> void:
	if active_mom != null and is_instance_valid(active_mom):
		_stop_body(active_mom)
	if active_player != null and is_instance_valid(active_player):
		_stop_body(active_player)


func _stop_body(body: Node) -> void:
	var character := body as CharacterBody2D
	if character != null:
		character.velocity.x = 0.0


func _apply_reward_once() -> void:
	if reward_applied:
		return
	reward_applied = true

	if active_player != null and is_instance_valid(active_player) and player_reward_meta != &"":
		var key := String(player_reward_meta)
		var previous_value := 0.0
		if active_player.has_meta(key):
			previous_value = float(active_player.get_meta(key))
		active_player.set_meta(key, previous_value + player_reward_amount)

	if active_mom != null and is_instance_valid(active_mom) and not mom_reward_delta.is_empty():
		if active_mom.has_method("apply_social_event"):
			active_mom.call("apply_social_event", mom_reward_delta, active_player, false)
		else:
			var machine := active_mom.get_node_or_null("NpcStateMachine")
			if machine != null and machine.has_method("apply_value_delta"):
				machine.call("apply_value_delta", mom_reward_delta, active_player)


func _mark_attempt_consumed() -> void:
	if not mark_spot_unavailable_after_attempt:
		return

	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("set_spot_value"):
		simulator.call("set_spot_value", spot_id, 0.0)


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


func _register_live_spot() -> void:
	if _magic_lesson_disabled():
		_breadcrumb("magic_lesson:register_disabled", String(spot_id))
		return
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("register_live_spot"):
		simulator.call("register_live_spot", spot_id, self)


func _unregister_live_spot() -> void:
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator != null and simulator.has_method("unregister_live_spot"):
		simulator.call("unregister_live_spot", spot_id, self)


func _get_player_prompt_interactor(player: Node2D) -> Node:
	if player == null or not is_instance_valid(player):
		return null
	if player.has_method("show_npc_prompt"):
		return player

	return player.get_node_or_null("NpcTalkInteractor")


func _get_marker_position(marker_path: NodePath, fallback: Vector2) -> Vector2:
	var marker := get_node_or_null(marker_path) as Node2D
	if marker == null:
		return fallback

	return marker.global_position


func _participants_valid() -> bool:
	return (
		active_mom != null
		and is_instance_valid(active_mom)
		and active_player != null
		and is_instance_valid(active_player)
	)


func _clear_participants() -> void:
	active_mom = null
	active_player = null
	lesson_timer = 0.0


func _attempt_already_used_today() -> bool:
	var current_day := _get_current_day()
	return completed_day == current_day or skipped_day == current_day


func _world_spot_is_available() -> bool:
	var simulator := get_node_or_null("/root/NpcWorldSimulation")
	if simulator == null or not simulator.has_method("get_spot_value"):
		return true

	return float(simulator.call("get_spot_value", spot_id, 1.0)) > 0.0


func _get_current_day() -> int:
	var world_time := get_node_or_null("/root/WorldTime")
	if world_time != null and world_time.has_method("get_snapshot"):
		var snapshot: Dictionary = world_time.call("get_snapshot")
		return int(snapshot.get("day", 0))

	return 0


func _get_current_scene_path() -> String:
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return ""

	return current_scene.scene_file_path


func _get_mom_location_id() -> String:
	if active_mom == null or not is_instance_valid(active_mom):
		return ""
	if active_mom.has_method("get_npc_location_id"):
		return String(active_mom.call("get_npc_location_id"))
	if active_mom.has_meta("npc_location_id"):
		return String(active_mom.get_meta("npc_location_id"))

	return ""


func _magic_lesson_disabled() -> bool:
	return (
		DebugToolsConfig.TROUBLESHOOTING_MODE
		and DebugToolsConfig.DEBUG_DISABLE_MAGIC_LESSON_ACTIVITY
	)


func _breadcrumb(source: String, detail: String = "") -> void:
	CrashBreadcrumbs.mark(source, detail)
