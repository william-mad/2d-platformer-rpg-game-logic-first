class_name NpcFeedbackPresenter extends Node

const VisualScene = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_visual.tscn"
)
const Visual = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_visual.gd"
)
const Cue = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_cue.gd"
)
const SocialConfigurationValidator = preload(
	"res://scripts/systems/npc_behavior/npc_social_configuration_validator.gd"
)

signal cue_started(descriptor: Dictionary)
signal cue_presented(descriptor: Dictionary)
signal cue_visibility_changed(descriptor: Dictionary, visible: bool)
signal cue_updated(descriptor: Dictionary)
signal cue_finished(descriptor: Dictionary)
signal cue_rejected(descriptor: Dictionary)

static var _emitted_configuration_warning_keys: Dictionary = {}

@export var player_feedback_enabled: bool = true
@export_range(1, 3, 1) var maximum_queue_size: int = 3
@export_range(32.0, 1024.0, 1.0, "suffix:px") var visibility_distance: float = 280.0
@export_range(0.1, 1.0, 0.05, "suffix:s") var visibility_check_interval_seconds: float = 0.2
@export var feedback_anchor_offset: Vector2 = Vector2(0.0, -134.0)
@export var require_nearby_player: bool = true
@export var icon_textures_by_key: Dictionary = {}

var current_cue: Cue
var queued_cues: Array[Cue] = []

var _npc: Node2D
var _visual: Visual
var _player_ref: WeakRef
var _suppression_sources: Dictionary = {}
var _cooldown_expiry_usec_by_key: Dictionary = {}
var _current_absolute_elapsed_seconds: float = 0.0
var _current_visible_elapsed_seconds: float = 0.0
var _current_has_been_presented: bool = false
var _current_currently_visible: bool = false
var _visibility_check_elapsed_seconds: float = 0.0
var _visual_attach_pending: bool = false
var _configuration_validation_issues: Array[Dictionary] = []


func _ready() -> void:
	set_process(false)
	_configuration_validation_issues = (
		SocialConfigurationValidator.validate_default_feedback_catalog(
			icon_textures_by_key
		)
	)
	if OS.is_debug_build():
		for issue in _configuration_validation_issues:
			var issue_key := _get_configuration_issue_key(issue)
			if _emitted_configuration_warning_keys.has(issue_key):
				continue
			_emitted_configuration_warning_keys[issue_key] = true
			push_warning("NPC feedback configuration [%s] %s: %s" % [
				String(issue.get("code", "invalid_configuration")),
				String(issue.get("path", "feedback_catalog")),
				String(issue.get("message", "Invalid feedback configuration.")),
			])


func get_configuration_validation_issues() -> Array[Dictionary]:
	return _configuration_validation_issues.duplicate(true)


static func _get_configuration_issue_key(issue: Dictionary) -> String:
	# JSON encoding avoids delimiter collisions while keeping the key stable
	# across presenter instances and independent of Dictionary insertion order.
	return JSON.stringify([
		String(issue.get("severity", "warning")),
		String(issue.get("code", "invalid_configuration")),
		String(issue.get("path", "feedback_catalog")),
		String(issue.get("message", "Invalid feedback configuration.")),
	])


func _exit_tree() -> void:
	_suppression_sources[&"scene_teardown"] = true
	if _visual != null and is_instance_valid(_visual):
		_visual.visible = false
		_visual.queue_free()
	_visual = null


func bind_npc(npc: Node2D) -> void:
	if npc == _npc and (
		(_visual != null and is_instance_valid(_visual))
		or _visual_attach_pending
	):
		if _visual != null and is_instance_valid(_visual):
			_visual.position = feedback_anchor_offset
			_update_visual_visibility()
		return
	if _visual != null and is_instance_valid(_visual):
		_set_current_visibility(false)
		_visual.queue_free()
	_visual = null
	_visual_attach_pending = false
	_npc = npc
	_player_ref = null
	if _npc == null or not is_instance_valid(_npc):
		return
	_visual_attach_pending = true
	call_deferred("_attach_visual_if_needed", _npc.get_instance_id())


func _attach_visual_if_needed(expected_npc_instance_id: int) -> void:
	_visual_attach_pending = false
	if (
		_npc == null
		or not is_instance_valid(_npc)
		or _npc.get_instance_id() != expected_npc_instance_id
		or not _npc.is_inside_tree()
	):
		return
	if _visual != null and is_instance_valid(_visual):
		return
	_visual = VisualScene.instantiate() as Visual
	_visual.name = "NpcFeedbackVisual"
	_visual.position = feedback_anchor_offset
	_npc.add_child(_visual)
	_apply_current_visual()
	_update_visual_visibility()


func submit_cue(cue: Cue) -> Dictionary:
	if cue == null or not cue.is_valid():
		return _reject(cue, &"invalid_cue")
	var submitted: Cue = cue.duplicate_cue()
	_cleanup_cooldowns()
	_prune_expired_queue()

	var matching_current: bool = (
		current_cue != null
		and current_cue.get_identity_key() == submitted.get_identity_key()
	)
	if matching_current:
		if submitted.replace_policy == Cue.REFRESH_EXISTING:
			var original_cue_id := current_cue.cue_id
			var original_created_at_usec := current_cue.created_at_usec
			var original_maximum_lifetime := (
				current_cue.maximum_lifetime_seconds
			)
			var was_presented := _current_has_been_presented
			var absolute_elapsed := _current_absolute_elapsed_seconds
			var visible_elapsed := _current_visible_elapsed_seconds
			current_cue = submitted
			current_cue.cue_id = original_cue_id
			current_cue.created_at_usec = original_created_at_usec
			current_cue.maximum_lifetime_seconds = (
				original_maximum_lifetime
			)
			_current_absolute_elapsed_seconds = absolute_elapsed
			_current_visible_elapsed_seconds = (
				0.0 if was_presented else visible_elapsed
			)
			_current_has_been_presented = was_presented
			_apply_current_visual()
			_update_visual_visibility()
			var updated := _current_descriptor()
			cue_updated.emit(updated.duplicate(true))
			return {"accepted": true, "result": "refreshed", "cue": updated}
		return _reject(submitted, &"duplicate_active")

	if _queue_contains_identity(submitted.get_identity_key()):
		return _reject(submitted, &"duplicate_queued")
	if _is_key_on_cooldown(submitted.get_cooldown_key()):
		return _reject(submitted, &"cooldown_active")

	if current_cue == null:
		_start_cue(submitted)
		return {
			"accepted": true,
			"result": "started",
			"cue": _current_descriptor(),
		}

	if (
		submitted.replace_policy != Cue.QUEUE
		and submitted.priority > current_cue.priority
	):
		_finish_current(&"replaced")
		_start_cue(submitted)
		return {
			"accepted": true,
			"result": "replaced",
			"cue": _current_descriptor(),
		}

	if _enqueue(submitted):
		return {
			"accepted": true,
			"result": "queued",
			"cue": submitted.to_descriptor(),
		}
	return _reject(submitted, &"queue_full")


func dismiss_current(reason: StringName = &"dismissed") -> bool:
	if current_cue == null:
		return false
	_finish_current(reason)
	_start_next_queued()
	return true


func clear_all(reason: StringName = &"cleared") -> void:
	if current_cue != null:
		_finish_current(reason)
	current_cue = null
	queued_cues.clear()
	_cooldown_expiry_usec_by_key.clear()
	_current_absolute_elapsed_seconds = 0.0
	_current_visible_elapsed_seconds = 0.0
	_current_has_been_presented = false
	_current_currently_visible = false
	_visibility_check_elapsed_seconds = 0.0
	if _visual != null and is_instance_valid(_visual):
		_visual.clear_content()
	set_process(false)


func is_code_on_cooldown(cue_code: StringName) -> bool:
	_cleanup_cooldowns()
	var prefix := String(cue_code)
	for key_value in _cooldown_expiry_usec_by_key.keys():
		var key := String(key_value)
		if key == prefix or key.begins_with("%s:" % prefix):
			return true
	return false


func get_current_cue_descriptor() -> Dictionary:
	return _current_descriptor()


func get_queue_descriptor() -> Array[Dictionary]:
	var descriptors: Array[Dictionary] = []
	for cue in queued_cues:
		descriptors.append(cue.to_descriptor())
	return descriptors


func set_feedback_suppressed(source: StringName, suppressed: bool) -> void:
	if source == &"":
		return
	if suppressed:
		_suppression_sources[source] = true
	else:
		_suppression_sources.erase(source)
	_update_visual_visibility()


func get_debug_descriptor() -> Dictionary:
	_cleanup_cooldowns()
	return {
		"current_cue": _current_descriptor(),
		"queue_length": queued_cues.size(),
		"cooldown_count": _cooldown_expiry_usec_by_key.size(),
		"visible": (
			_visual != null
			and is_instance_valid(_visual)
			and _visual.is_visible_in_tree()
		),
		"suppression_sources": _suppression_sources.keys().duplicate(),
		"visual_instance_id": (
			_visual.get_instance_id()
			if _visual != null and is_instance_valid(_visual)
			else 0
		),
	}


func _process(delta: float) -> void:
	if current_cue == null:
		_start_next_queued()
		if current_cue == null:
			set_process(false)
			return
	var safe_delta := maxf(delta, 0.0)
	_current_absolute_elapsed_seconds += safe_delta
	if (
		_current_currently_visible
		and _visual != null
		and is_instance_valid(_visual)
		and _visual.is_visible_in_tree()
	):
		_current_visible_elapsed_seconds += safe_delta
	_visibility_check_elapsed_seconds += safe_delta
	if (
		_visibility_check_elapsed_seconds
		>= maxf(visibility_check_interval_seconds, 0.1)
	):
		_visibility_check_elapsed_seconds = 0.0
		_update_visual_visibility()
	if _current_visible_elapsed_seconds >= current_cue.duration_seconds:
		_finish_current(&"duration_elapsed")
		_start_next_queued()
		return
	if (
		_current_absolute_elapsed_seconds
		< current_cue.maximum_lifetime_seconds
	):
		return
	_finish_current(
		&"maximum_lifetime_elapsed"
		if _current_has_been_presented
		else &"unseen_lifetime_expired"
	)
	_start_next_queued()


func _start_cue(cue: Cue) -> void:
	current_cue = cue
	_current_absolute_elapsed_seconds = 0.0
	_current_visible_elapsed_seconds = 0.0
	_current_has_been_presented = false
	_current_currently_visible = false
	_visibility_check_elapsed_seconds = 0.0
	_apply_current_visual()
	set_process(true)
	var descriptor := _current_descriptor()
	cue_started.emit(descriptor.duplicate(true))
	_update_visual_visibility()


func _finish_current(reason: StringName) -> void:
	if current_cue == null:
		return
	_set_current_visibility(false)
	var descriptor := current_cue.to_descriptor()
	descriptor["finish_reason"] = reason
	descriptor["elapsed_seconds"] = _current_visible_elapsed_seconds
	descriptor["has_been_presented"] = _current_has_been_presented
	descriptor["visible_elapsed_seconds"] = _current_visible_elapsed_seconds
	descriptor["absolute_elapsed_seconds"] = (
		_current_absolute_elapsed_seconds
	)
	descriptor["currently_visible"] = false
	current_cue = null
	_current_absolute_elapsed_seconds = 0.0
	_current_visible_elapsed_seconds = 0.0
	_current_has_been_presented = false
	_current_currently_visible = false
	if _visual != null and is_instance_valid(_visual):
		_visual.clear_content()
	cue_finished.emit(descriptor.duplicate(true))


func _start_next_queued() -> void:
	_prune_expired_queue()
	if current_cue != null or queued_cues.is_empty():
		if current_cue == null and queued_cues.is_empty():
			set_process(false)
		return
	queued_cues.sort_custom(_cue_before)
	var next: Cue = queued_cues.pop_front()
	_start_cue(next)


func _enqueue(cue: Cue) -> bool:
	var limit := clampi(maximum_queue_size, 1, 3)
	if queued_cues.size() < limit:
		queued_cues.append(cue)
		queued_cues.sort_custom(_cue_before)
		set_process(true)
		return true
	var discard_index := _find_discardable_queue_index(cue)
	if discard_index < 0:
		return false
	queued_cues.remove_at(discard_index)
	queued_cues.append(cue)
	queued_cues.sort_custom(_cue_before)
	return true


func _find_discardable_queue_index(incoming: Cue) -> int:
	var index_to_discard := -1
	for index in queued_cues.size():
		var queued := queued_cues[index]
		if (
			queued.category in [Cue.CATEGORY_PROBLEM, Cue.CATEGORY_EMERGENCY]
			and incoming.category
				not in [Cue.CATEGORY_PROBLEM, Cue.CATEGORY_EMERGENCY]
		):
			continue
		if queued.priority >= incoming.priority:
			continue
		if (
			index_to_discard < 0
			or _cue_is_less_valuable(queued, queued_cues[index_to_discard])
		):
			index_to_discard = index
	return index_to_discard


func _prune_expired_queue() -> void:
	var now_usec := Time.get_ticks_usec()
	for index in range(queued_cues.size() - 1, -1, -1):
		var cue := queued_cues[index]
		var age_seconds := maxf(
			float(now_usec - cue.created_at_usec) / 1000000.0,
			0.0
		)
		if (
			age_seconds
			>= cue.maximum_lifetime_seconds
		):
			queued_cues.remove_at(index)
			var descriptor := cue.to_descriptor()
			descriptor["rejection_reason"] = &"queued_lifetime_expired"
			descriptor["queued_age_seconds"] = age_seconds
			cue_rejected.emit(descriptor.duplicate(true))


func _queue_contains_identity(identity_key: String) -> bool:
	for queued in queued_cues:
		if queued.get_identity_key() == identity_key:
			return true
	return false


func _begin_cooldown(cue: Cue) -> void:
	if cue.cooldown_seconds <= 0.0:
		return
	_cooldown_expiry_usec_by_key[cue.get_cooldown_key()] = (
		Time.get_ticks_usec()
		+ int(cue.cooldown_seconds * 1000000.0)
	)
	_trim_cooldowns()


func _is_key_on_cooldown(key: String) -> bool:
	var expiry := int(_cooldown_expiry_usec_by_key.get(key, 0))
	if expiry <= Time.get_ticks_usec():
		_cooldown_expiry_usec_by_key.erase(key)
		return false
	return true


func _cleanup_cooldowns() -> void:
	var now_usec := Time.get_ticks_usec()
	for key in _cooldown_expiry_usec_by_key.keys():
		if int(_cooldown_expiry_usec_by_key.get(key, 0)) <= now_usec:
			_cooldown_expiry_usec_by_key.erase(key)


func _trim_cooldowns() -> void:
	const MAXIMUM_COOLDOWNS: int = 24
	if _cooldown_expiry_usec_by_key.size() <= MAXIMUM_COOLDOWNS:
		return
	var ordered: Array[Dictionary] = []
	for key in _cooldown_expiry_usec_by_key.keys():
		ordered.append({
			"key": String(key),
			"expiry": int(_cooldown_expiry_usec_by_key[key]),
		})
	ordered.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			if int(a.expiry) != int(b.expiry):
				return int(a.expiry) < int(b.expiry)
			return String(a.key) < String(b.key)
	)
	while ordered.size() > MAXIMUM_COOLDOWNS:
		var removed: Dictionary = ordered.pop_front()
		_cooldown_expiry_usec_by_key.erase(String(removed.key))


func _apply_current_visual() -> void:
	if _visual == null or not is_instance_valid(_visual):
		return
	if current_cue == null:
		_visual.clear_content()
		return
	var texture := _resolve_icon(current_cue.icon_key)
	_visual.set_content(_resolve_display_text(current_cue), texture)


func _resolve_display_text(cue: Cue) -> String:
	var key := String(cue.text_key)
	if key.is_empty():
		return cue.fallback_text
	var translated := String(TranslationServer.translate(key))
	return cue.fallback_text if translated == key else translated


func _resolve_icon(icon_key: StringName) -> Texture2D:
	if icon_key == &"":
		return null
	var value: Variant = icon_textures_by_key.get(String(icon_key))
	return value as Texture2D if value is Texture2D else null


func _update_visual_visibility() -> void:
	var next_visible := _can_show_current()
	if _visual != null and is_instance_valid(_visual):
		_visual.visible = next_visible
		next_visible = (
			_visual.is_inside_tree()
			and _visual.is_visible_in_tree()
		)
	else:
		next_visible = false
	_set_current_visibility(next_visible)


func _set_current_visibility(visible: bool) -> void:
	if current_cue == null:
		_current_currently_visible = false
		return
	if visible == _current_currently_visible:
		return
	_current_currently_visible = visible
	if visible and not _current_has_been_presented:
		_current_has_been_presented = true
		_begin_cooldown(current_cue)
		var presented := _current_descriptor()
		cue_presented.emit(presented.duplicate(true))
	var descriptor := _current_descriptor()
	cue_visibility_changed.emit(descriptor.duplicate(true), visible)


func _can_show_current() -> bool:
	if (
		not player_feedback_enabled
		or current_cue == null
		or _visual == null
		or not is_instance_valid(_visual)
		or not _visual.is_inside_tree()
		or _npc == null
		or not is_instance_valid(_npc)
		or not _npc.is_inside_tree()
		or not _suppression_sources.is_empty()
	):
		return false
	var scene_loader := get_node_or_null("/root/SceneLoader")
	if (
		scene_loader != null
		and bool(scene_loader.get("loading_in_progress"))
	):
		return false
	var dialogue := get_node_or_null("/root/DialogueController")
	if (
		dialogue != null
		and dialogue.has_method("is_dialogue_active")
		and bool(dialogue.call("is_dialogue_active"))
	):
		return false
	if not require_nearby_player:
		return true
	var player := _get_live_player()
	if player == null:
		return false
	var current_scene := _npc.get_tree().current_scene
	if (
		current_scene != null
		and (
			not current_scene.is_ancestor_of(_npc)
			or not current_scene.is_ancestor_of(player)
		)
	):
		return false
	return _npc.global_position.distance_to(player.global_position) <= visibility_distance


func _get_live_player() -> Node2D:
	if _player_ref != null:
		var cached = _player_ref.get_ref()
		if cached is Node2D and is_instance_valid(cached) and cached.is_inside_tree():
			return cached
	if _npc == null or not _npc.is_inside_tree():
		return null
	var player := _npc.get_tree().get_first_node_in_group("player") as Node2D
	_player_ref = weakref(player) if player != null else null
	return player


func _current_descriptor() -> Dictionary:
	if current_cue == null:
		return {}
	var descriptor := current_cue.to_descriptor()
	descriptor["elapsed_seconds"] = _current_visible_elapsed_seconds
	descriptor["remaining_seconds"] = maxf(
		current_cue.duration_seconds - _current_visible_elapsed_seconds,
		0.0
	)
	descriptor["has_been_presented"] = _current_has_been_presented
	descriptor["visible_elapsed_seconds"] = _current_visible_elapsed_seconds
	descriptor["absolute_elapsed_seconds"] = (
		_current_absolute_elapsed_seconds
	)
	descriptor["maximum_lifetime_seconds"] = (
		current_cue.maximum_lifetime_seconds
	)
	descriptor["currently_visible"] = _current_currently_visible
	return descriptor


func _reject(cue: Cue, reason: StringName) -> Dictionary:
	var descriptor := cue.to_descriptor() if cue != null else {}
	descriptor["rejection_reason"] = reason
	cue_rejected.emit(descriptor.duplicate(true))
	return {
		"accepted": false,
		"reason": reason,
		"cue": descriptor,
	}


static func _cue_before(a: Cue, b: Cue) -> bool:
	if a.priority != b.priority:
		return a.priority > b.priority
	if a.created_at_usec != b.created_at_usec:
		return a.created_at_usec < b.created_at_usec
	return a.cue_id < b.cue_id


static func _cue_is_less_valuable(a: Cue, b: Cue) -> bool:
	if a.priority != b.priority:
		return a.priority < b.priority
	if a.created_at_usec != b.created_at_usec:
		return a.created_at_usec > b.created_at_usec
	return a.cue_id > b.cue_id
