extends Node

signal dialogue_session_started(session_id: StringName, dialogue_id: StringName)
signal dialogue_node_started(
	session_id: StringName,
	dialogue_id: StringName,
	node_id: StringName,
	speaker_id: StringName
)
signal dialogue_choice_committed(
	session_id: StringName,
	dialogue_id: StringName,
	choice_id: StringName,
	choice_data: DialogueChoice
)
signal dialogue_session_finished(result: Dictionary)

const UI_SCENE := preload("res://scenes/ui/modal_dialogue_ui.tscn")
const CLAIM_REASON := &"modal_dialogue"
const PLAYER_CONTROL_MODE := &"ui_only"
const TALK_ANIMATION := &"talk"
const IDLE_ANIMATION := &"idle"
const SESSION_MODE_WORLD := &"world"
const SESSION_MODE_MODAL := &"modal"
const SESSION_MODE_AUTONOMOUS_TALK := &"autonomous_talk"
const SESSION_MODE_PLAYER_TALK := &"player_talk"
const ALLOWED_PRIMARY_STATES := {
	"Idle": true,
	"Rest": true,
	"Recreation": true,
}

var world_progression_lock_token: int = 0
var npc_control_claim_token: int = 0
var player_control_claim_token: int = 0
var current_npc: Node2D
var current_player: Node2D
var current_definition: DialogueDefinition
var current_node: DialogueNode
var current_session_id: StringName = &""
var choice_committed: bool = false
var current_session_mode: StringName = &""
var selected_choice_ids: Array[StringName] = []
var last_session_result: Dictionary = {}

var _next_session_number: int = 1
var _cleanup_in_progress: bool = false
var _ui: ModalDialogueUI
var _modal_owner_ref: WeakRef
var _speaker_names: Dictionary = {}


func _ready() -> void:
	_ensure_ui()
	var gameplay_flow := _get_gameplay_flow()
	if gameplay_flow == null:
		return
	var npc_callback := Callable(self, "_on_npc_control_claim_changed")
	if not gameplay_flow.is_connected(&"npc_control_claim_changed", npc_callback):
		gameplay_flow.connect(&"npc_control_claim_changed", npc_callback)
	var player_callback := Callable(self, "_on_player_control_claim_changed")
	if not gameplay_flow.is_connected(&"player_control_claim_changed", player_callback):
		gameplay_flow.connect(&"player_control_claim_changed", player_callback)


func _process(_delta: float) -> void:
	if not is_dialogue_active() or _cleanup_in_progress:
		return
	var session_id := current_session_id
	if current_session_mode in [
		SESSION_MODE_MODAL,
		SESSION_MODE_AUTONOMOUS_TALK,
		SESSION_MODE_PLAYER_TALK,
	]:
		if not _modal_owner_is_live():
			_terminal_cleanup("modal_owner_removed", false, session_id)
			return
		if current_session_mode in [
			SESSION_MODE_AUTONOMOUS_TALK,
			SESSION_MODE_PLAYER_TALK,
		]:
			if not _participant_is_live(current_npc):
				_terminal_cleanup("npc_removed", false, session_id)
				return
			if not _talk_owned_session_is_live():
				_terminal_cleanup("talk_session_lost", false, session_id)
				return
		if player_control_claim_token != 0:
			if not _participant_is_live(current_player):
				_terminal_cleanup("player_removed", false, session_id)
				return
			if not _player_claim_is_exact(current_player, player_control_claim_token):
				_terminal_cleanup("token_lost", false, session_id)
				return
		if not _world_lock_is_exact(world_progression_lock_token):
			_terminal_cleanup("token_lost", false, session_id)
		return
	if not _participant_is_live(current_npc):
		_terminal_cleanup("npc_removed", false, session_id)
		return
	if not _participant_is_live(current_player):
		_terminal_cleanup("player_removed", false, session_id)
		return
	if not _all_tokens_are_current():
		_terminal_cleanup("token_lost", false, session_id)


func _exit_tree() -> void:
	if is_dialogue_active():
		_terminal_cleanup("controller_exit", false, current_session_id)


func begin_dialogue(player: Node, npc: Node, definition: Resource) -> Dictionary:
	var rejection_reason := _get_begin_rejection_reason(player, npc, definition)
	if not rejection_reason.is_empty():
		_debug_log("Dialogue rejected: reason=%s" % rejection_reason)
		return _dialogue_result(false, rejection_reason)

	current_session_id = _take_session_id()
	current_player = player as Node2D
	current_npc = npc as Node2D
	current_definition = definition as DialogueDefinition
	current_node = null
	choice_committed = false
	current_session_mode = SESSION_MODE_WORLD
	selected_choice_ids.clear()
	_modal_owner_ref = null
	_speaker_names.clear()
	_cleanup_in_progress = false

	var gameplay_flow := _get_gameplay_flow()
	world_progression_lock_token = int(gameplay_flow.call(
		"acquire_world_progression_lock", self, CLAIM_REASON
	))
	if world_progression_lock_token == 0:
		return _reject_started_session("world_lock_rejected")

	npc_control_claim_token = int(gameplay_flow.call(
		"acquire_npc_control_claim", self, current_npc, CLAIM_REASON, false
	))
	if npc_control_claim_token == 0:
		return _reject_started_session("npc_claim_rejected")

	player_control_claim_token = int(gameplay_flow.call(
		"acquire_player_control_claim",
		self,
		current_player,
		CLAIM_REASON,
		PLAYER_CONTROL_MODE
	))
	if player_control_claim_token == 0:
		return _reject_started_session("player_claim_rejected")

	var machine := _get_npc_machine(current_npc)
	if machine == null:
		return _reject_started_session("npc_state_machine_missing")
	if not bool(machine.call(
		"request_scripted_state",
		npc_control_claim_token,
		&"ScriptedHold",
		null,
		&"ScriptedHold",
		CLAIM_REASON
	)):
		return _reject_started_session("scripted_hold_rejected")
	if not bool(machine.call(
		"set_scripted_facing_target", npc_control_claim_token, current_player
	)):
		return _reject_started_session("scripted_facing_rejected")
	if not bool(machine.call(
		"set_scripted_hold_animation", npc_control_claim_token, TALK_ANIMATION
	)):
		return _reject_started_session("scripted_talk_animation_rejected")

	current_node = current_definition.get_node(current_definition.entry_node_id)
	_ui.configure_portrait_presentation(
		current_definition.dialogue_id,
		_get_npc_portrait_presentation(current_npc)
	)
	dialogue_session_started.emit(current_session_id, current_definition.dialogue_id)
	if not _display_current_node():
		return _reject_started_session("entry_node_display_rejected")

	_debug_log(
		"Dialogue accepted: session=%s dialogue=%s"
		% [String(current_session_id), String(current_definition.dialogue_id)]
	)
	_debug_log(
		"Dialogue session started: session=%s world=%d npc=%d player=%d"
		% [
			String(current_session_id),
			world_progression_lock_token,
			npc_control_claim_token,
			player_control_claim_token,
		]
	)
	return _dialogue_result(true, "")


## Scripted callers may omit player; in-world modal interactions pass one so the
## dialogue owns the same ui_only Player control claim as NPC dialogue.
func begin_modal_dialogue(
	owner: Object,
	definition: Resource,
	speaker_names: Dictionary = {},
	player: Node2D = null
) -> Dictionary:
	var rejection_reason := _get_modal_begin_rejection_reason(owner, definition, player)
	if not rejection_reason.is_empty():
		_debug_log("Dialogue rejected: reason=%s" % rejection_reason)
		return _dialogue_result(false, rejection_reason)

	current_session_id = _take_session_id()
	current_definition = definition as DialogueDefinition
	current_node = null
	current_npc = null
	current_player = player
	choice_committed = false
	current_session_mode = SESSION_MODE_MODAL
	selected_choice_ids.clear()
	_modal_owner_ref = weakref(owner)
	_speaker_names = speaker_names.duplicate()
	_cleanup_in_progress = false

	var gameplay_flow := _get_gameplay_flow()
	world_progression_lock_token = int(gameplay_flow.call(
		"acquire_world_progression_lock", self, CLAIM_REASON
	))
	if world_progression_lock_token == 0:
		return _reject_started_session("world_lock_rejected")
	if current_player != null:
		player_control_claim_token = int(gameplay_flow.call(
			"acquire_player_control_claim",
			self,
			current_player,
			CLAIM_REASON,
			PLAYER_CONTROL_MODE
		))
		if player_control_claim_token == 0:
			return _reject_started_session("player_claim_rejected")

	current_node = current_definition.get_node(current_definition.entry_node_id)
	_ui.configure_portrait_presentation(&"", {})
	dialogue_session_started.emit(current_session_id, current_definition.dialogue_id)
	if not _display_current_node():
		return _reject_started_session("entry_node_display_rejected")

	_debug_log(
		"Standalone modal dialogue accepted: session=%s dialogue=%s world=%d player=%d"
		% [
			String(current_session_id),
			String(current_definition.dialogue_id),
			world_progression_lock_token,
			player_control_claim_token,
		]
	)
	return _dialogue_result(true, "")


## Presents dialogue for a live autonomous Talk without claiming scripted NPC
## control. The Talk overlay remains the social-action authority throughout.
func begin_autonomous_talk_dialogue(
	owner: Object,
	player: Node,
	npc: Node,
	definition: Resource,
	speaker_names: Dictionary = {},
	portrait_presentation: Dictionary = {}
) -> Dictionary:
	return _begin_talk_owned_dialogue(
		SESSION_MODE_AUTONOMOUS_TALK,
		owner,
		player,
		npc,
		definition,
		speaker_names,
		portrait_presentation
	)


## Player-selected dialogue uses the same modal presentation while its existing
## Talk overlay remains the authority for approach, cancellation, and rewards.
func begin_player_talk_dialogue(
	owner: Object,
	player: Node,
	npc: Node,
	definition: Resource,
	speaker_names: Dictionary = {},
	portrait_presentation: Dictionary = {}
) -> Dictionary:
	return _begin_talk_owned_dialogue(
		SESSION_MODE_PLAYER_TALK,
		owner,
		player,
		npc,
		definition,
		speaker_names,
		portrait_presentation
	)


func _begin_talk_owned_dialogue(
	session_mode: StringName,
	owner: Object,
	player: Node,
	npc: Node,
	definition: Resource,
	speaker_names: Dictionary,
	portrait_presentation: Dictionary
) -> Dictionary:
	var rejection_reason := _get_talk_owned_begin_rejection_reason(
		owner, player, npc, definition
	)
	if not rejection_reason.is_empty():
		_debug_log("Talk-owned dialogue rejected: reason=%s" % rejection_reason)
		return _dialogue_result(false, rejection_reason)

	current_session_id = _take_session_id()
	current_definition = definition as DialogueDefinition
	current_node = null
	current_npc = npc as Node2D
	current_player = player as Node2D
	choice_committed = false
	current_session_mode = session_mode
	selected_choice_ids.clear()
	_modal_owner_ref = weakref(owner)
	_speaker_names = speaker_names.duplicate()
	_cleanup_in_progress = false

	var gameplay_flow := _get_gameplay_flow()
	world_progression_lock_token = int(gameplay_flow.call(
		"acquire_world_progression_lock", self, CLAIM_REASON
	))
	if world_progression_lock_token == 0:
		return _reject_started_session("world_lock_rejected")

	player_control_claim_token = int(gameplay_flow.call(
		"acquire_player_control_claim",
		self,
		current_player,
		CLAIM_REASON,
		PLAYER_CONTROL_MODE
	))
	if player_control_claim_token == 0:
		return _reject_started_session("player_claim_rejected")

	current_node = current_definition.get_node(current_definition.entry_node_id)
	_ui.configure_portrait_presentation(
		current_definition.dialogue_id,
		portrait_presentation
	)
	dialogue_session_started.emit(current_session_id, current_definition.dialogue_id)
	if not _display_current_node():
		return _reject_started_session("entry_node_display_rejected")

	_debug_log(
		"Talk-owned dialogue accepted: mode=%s session=%s dialogue=%s world=%d player=%d"
		% [
			String(current_session_mode),
			String(current_session_id),
			String(current_definition.dialogue_id),
			world_progression_lock_token,
			player_control_claim_token,
		]
	)
	return _dialogue_result(true, "")


func choose(choice_id: StringName) -> bool:
	if not is_dialogue_active() or _cleanup_in_progress or choice_committed:
		return false
	var session_id := current_session_id
	if current_node == null or current_definition == null:
		_terminal_cleanup("invalid_dialogue_node", false, session_id)
		return false
	var choice := current_node.get_choice(choice_id)
	if choice == null:
		return false

	# Commit before invoking an effect API so repeated input cannot apply it twice.
	choice_committed = true
	selected_choice_ids.append(choice.choice_id)
	if _ui != null:
		_ui.disable_input()
	dialogue_choice_committed.emit(
		session_id,
		current_definition.dialogue_id,
		choice.choice_id,
		choice
	)
	_debug_log(
		"Dialogue choice committed: session=%s choice=%s favor_delta=%.2f"
		% [String(session_id), String(choice.choice_id), choice.favor_delta]
	)

	if (
		current_session_mode in [
			SESSION_MODE_WORLD,
			SESSION_MODE_AUTONOMOUS_TALK,
			SESSION_MODE_PLAYER_TALK,
		]
		and not is_zero_approx(choice.favor_delta)
	):
		if not _participant_is_live(current_npc) or not _participant_is_live(current_player):
			_terminal_cleanup("participant_lost_before_choice_effect", false, session_id)
			return false
		if not current_npc.has_method("change_relationship_favor_for"):
			_terminal_cleanup("favor_api_missing", false, session_id)
			return false
		current_npc.call(
			"change_relationship_favor_for",
			current_player,
			choice.favor_delta,
			"dialogue:%s:%s" % [String(current_definition.dialogue_id), String(choice.choice_id)]
		)

	if choice.terminal:
		_terminal_cleanup("terminal_choice", true, session_id)
		return true

	var next_node := current_definition.get_node(choice.next_node_id)
	if next_node == null:
		_terminal_cleanup("invalid_next_node", false, session_id)
		return false
	current_node = next_node
	choice_committed = false
	if not _display_current_node():
		_terminal_cleanup("node_display_rejected", false, session_id)
		return false
	return true


func advance() -> bool:
	if not is_dialogue_active() or _cleanup_in_progress or choice_committed:
		return false
	var session_id := current_session_id
	if current_node == null or current_definition == null:
		_terminal_cleanup("invalid_dialogue_node", false, session_id)
		return false
	if not current_node.choices.is_empty():
		return false

	if current_node.terminal:
		_terminal_cleanup("terminal_node", true, session_id)
		return true
	var next_node := current_definition.get_node(current_node.next_node_id)
	if next_node == null:
		_terminal_cleanup("invalid_next_node", false, session_id)
		return false
	current_node = next_node
	if not _display_current_node():
		_terminal_cleanup("node_display_rejected", false, session_id)
		return false
	return true


func cancel_dialogue(reason: String = "player_cancelled") -> bool:
	if not is_dialogue_active():
		return false
	return _terminal_cleanup(reason, false, current_session_id)


func cancel_dialogue_session(
	expected_session_id: StringName,
	reason: String = "player_cancelled"
) -> bool:
	if expected_session_id == &"" or expected_session_id != current_session_id:
		return false
	return _terminal_cleanup(reason, false, expected_session_id)


func is_dialogue_active() -> bool:
	return current_session_id != &""


func set_session_input_enabled(expected_session_id: StringName, enabled: bool) -> bool:
	if (
		expected_session_id == &""
		or expected_session_id != current_session_id
		or _cleanup_in_progress
		or _ui == null
		or not is_instance_valid(_ui)
	):
		return false
	if enabled:
		return _ui.enable_input(expected_session_id)
	_ui.disable_input()
	return true


func set_session_ui_visible(expected_session_id: StringName, should_show: bool) -> bool:
	if (
		expected_session_id == &""
		or expected_session_id != current_session_id
		or _cleanup_in_progress
		or _ui == null
		or not is_instance_valid(_ui)
	):
		return false
	return _ui.set_session_visible(expected_session_id, should_show)


func dump_active_dialogue() -> Dictionary:
	var report := {
		"session_id": current_session_id,
		"dialogue_id": current_definition.dialogue_id if current_definition != null else &"",
		"node_id": current_node.node_id if current_node != null else &"",
		"speaker_id": current_node.speaker_id if current_node != null else &"",
		"session_mode": current_session_mode,
		"selected_choice_ids": selected_choice_ids.duplicate(),
		"npc_valid": _participant_is_live(current_npc),
		"player_valid": _participant_is_live(current_player),
		"world_lock_token": world_progression_lock_token,
		"npc_claim_token": npc_control_claim_token,
		"player_claim_token": player_control_claim_token,
		"choice_committed": choice_committed,
	}
	print("Active dialogue: %s" % str(report))
	return report


func _get_begin_rejection_reason(player: Node, npc: Node, definition: Resource) -> String:
	if is_dialogue_active():
		return "dialogue_already_active"
	if not _participant_is_live(player):
		return "invalid_player"
	if not _participant_is_live(npc):
		return "invalid_npc"
	var dialogue_definition := definition as DialogueDefinition
	if dialogue_definition == null:
		return "invalid_dialogue_definition"
	var definition_error := dialogue_definition.get_validation_error()
	if not definition_error.is_empty():
		return definition_error
	if not player.has_method("can_accept_player_control_claim"):
		return "player_claim_eligibility_missing"
	var player_gate = player.call("can_accept_player_control_claim", PLAYER_CONTROL_MODE)
	if not (player_gate is Dictionary) or not bool(player_gate.get("accepted", false)):
		return String(player_gate.get("reason", "player_claim_rejected")) if player_gate is Dictionary else "player_claim_rejected"
	if _ui == null or not is_instance_valid(_ui):
		return "dialogue_ui_missing"

	var machine := _get_npc_machine(npc)
	if machine == null:
		return "npc_state_machine_missing"
	var state_name := _get_primary_state_name(machine)
	var owns_existing_scripted_hold := (
		state_name == &"ScriptedHold" and _npc_is_claimed_by_this_controller(npc)
	)
	if not owns_existing_scripted_hold and machine.has_method("can_begin_player_interaction"):
		var npc_gate = machine.call("can_begin_player_interaction", player)
		if not (npc_gate is Dictionary) or not bool(npc_gate.get("accepted", false)):
			return String(npc_gate.get("reason", "npc_interaction_rejected")) if npc_gate is Dictionary else "npc_interaction_rejected"
	if float(machine.call("get_value", &"hp", 1.0)) <= 0.0:
		return "npc_dead"
	if float(machine.call("get_value", &"disabled", 0.0)) >= 1.0:
		return "npc_disabled"

	if state_name == &"ScriptedHold":
		if not owns_existing_scripted_hold:
			return "npc_scripted_controlled"
	elif not ALLOWED_PRIMARY_STATES.has(String(state_name)):
		return "npc_state_%s" % String(state_name).to_snake_case()

	var action_descriptor: Dictionary = machine.call("get_active_action_descriptor")
	if _descriptor_is_lesson_or_class_handoff(action_descriptor):
		return "npc_lesson_or_class_handoff"
	if _descriptor_is_scheduled(action_descriptor):
		return "npc_scheduled_activity"
	return ""


func _get_modal_begin_rejection_reason(
	owner: Object,
	definition: Resource,
	player: Node2D = null
) -> String:
	if is_dialogue_active():
		return "dialogue_already_active"
	if owner == null or not is_instance_valid(owner):
		return "invalid_modal_owner"
	if owner is Node and not (owner as Node).is_inside_tree():
		return "modal_owner_outside_tree"
	var dialogue_definition := definition as DialogueDefinition
	if dialogue_definition == null:
		return "invalid_dialogue_definition"
	var definition_error := dialogue_definition.get_validation_error()
	if not definition_error.is_empty():
		return definition_error
	if player != null:
		if not _participant_is_live(player):
			return "invalid_player"
		if not player.has_method("can_accept_player_control_claim"):
			return "player_claim_eligibility_missing"
		var player_gate = player.call("can_accept_player_control_claim", PLAYER_CONTROL_MODE)
		if not (player_gate is Dictionary) or not bool(player_gate.get("accepted", false)):
			return String(player_gate.get("reason", "player_claim_rejected")) if player_gate is Dictionary else "player_claim_rejected"
	if _get_gameplay_flow() == null:
		return "gameplay_flow_missing"
	if _ui == null or not is_instance_valid(_ui):
		return "dialogue_ui_missing"
	return ""


func _get_talk_owned_begin_rejection_reason(
	owner: Object,
	player: Node,
	npc: Node,
	definition: Resource
) -> String:
	if is_dialogue_active():
		return "dialogue_already_active"
	if owner == null or not is_instance_valid(owner):
		return "invalid_talk_owner"
	if owner is Node and not (owner as Node).is_inside_tree():
		return "talk_owner_outside_tree"
	if not _participant_is_live(player):
		return "invalid_player"
	if not _participant_is_live(npc):
		return "invalid_npc"
	var dialogue_definition := definition as DialogueDefinition
	if dialogue_definition == null:
		return "invalid_dialogue_definition"
	var definition_error := dialogue_definition.get_validation_error()
	if not definition_error.is_empty():
		return definition_error
	if not player.has_method("can_accept_player_control_claim"):
		return "player_claim_eligibility_missing"
	var player_gate = player.call("can_accept_player_control_claim", PLAYER_CONTROL_MODE)
	if not (player_gate is Dictionary) or not bool(player_gate.get("accepted", false)):
		return String(player_gate.get("reason", "player_claim_rejected")) if player_gate is Dictionary else "player_claim_rejected"
	var machine := _get_npc_machine(npc)
	if machine == null:
		return "npc_state_machine_missing"
	if not machine.has_method("is_talking_with") or not bool(machine.call("is_talking_with", player)):
		return "autonomous_talk_not_active"
	if not owner.has_method("is_talking_with") or not bool(owner.call("is_talking_with", player)):
		return "autonomous_talk_owner_mismatch"
	if _get_gameplay_flow() == null:
		return "gameplay_flow_missing"
	if _ui == null or not is_instance_valid(_ui):
		return "dialogue_ui_missing"
	return ""


func _display_current_node() -> bool:
	if current_node == null or current_session_id == &"" or _ui == null:
		return false
	var displayed := _ui.display_node(
		current_session_id, _get_current_speaker_display_name(), current_node
	)
	if displayed:
		dialogue_node_started.emit(
			current_session_id,
			current_definition.dialogue_id,
			current_node.node_id,
			current_node.speaker_id
		)
		_ui.reveal_portrait_presentation(current_session_id)
		_debug_log(
			"Dialogue node displayed: session=%s node=%s"
			% [String(current_session_id), String(current_node.node_id)]
		)
	return displayed


func _terminal_cleanup(
	reason: String,
	completed: bool,
	expected_session_id: StringName
) -> bool:
	if not is_dialogue_active() or expected_session_id != current_session_id:
		return false
	if _cleanup_in_progress:
		return true
	_cleanup_in_progress = true

	var session_id := current_session_id
	var dialogue_id := current_definition.dialogue_id if current_definition != null else &""
	var session_mode := current_session_mode
	var committed_choice_ids := selected_choice_ids.duplicate()
	var npc := current_npc
	var player := current_player
	var world_token := world_progression_lock_token
	var npc_token := npc_control_claim_token
	var player_token := player_control_claim_token
	if _ui != null and is_instance_valid(_ui):
		_ui.disable_input()
		_ui.hide_and_clear()

	var gameplay_flow := _get_gameplay_flow()
	var machine := _get_npc_machine(npc)
	if machine != null and _npc_claim_is_exact(npc, npc_token):
		machine.call("set_scripted_hold_animation", npc_token, IDLE_ANIMATION)
		machine.call("set_scripted_facing_target", npc_token, null)

	var player_released := false
	var npc_released := false
	var world_released := false
	if gameplay_flow != null:
		if player_token != 0 and _player_claim_is_exact(player, player_token):
			player_released = bool(gameplay_flow.call(
				"release_player_control_claim", player_token, self
			))
		if npc_token != 0 and _npc_claim_is_exact(npc, npc_token):
			npc_released = bool(gameplay_flow.call(
				"release_npc_control_claim", npc_token, self
			))
		if world_token != 0 and _world_lock_is_exact(world_token):
			world_released = bool(gameplay_flow.call(
				"release_world_progression_lock", world_token, self
			))

	world_progression_lock_token = 0
	npc_control_claim_token = 0
	player_control_claim_token = 0
	current_node = null
	current_definition = null
	current_npc = null
	current_player = null
	current_session_id = &""
	choice_committed = false
	current_session_mode = &""
	selected_choice_ids.clear()
	_modal_owner_ref = null
	_speaker_names.clear()
	_cleanup_in_progress = false
	last_session_result = {
		"session_id": session_id,
		"dialogue_id": dialogue_id,
		"session_mode": session_mode,
		"completed": completed,
		"reason": reason,
		"choice_ids": committed_choice_ids,
	}

	_debug_log(
		"Dialogue session %s: session=%s reason=%s"
		% ["completed" if completed else "cancelled", String(session_id), reason]
	)
	_debug_log(
		"Dialogue cleanup tokens released: session=%s world=%d:%s npc=%d:%s player=%d:%s"
		% [
			String(session_id),
			world_token,
			str(world_released),
			npc_token,
			str(npc_released),
			player_token,
			str(player_released),
		]
	)
	dialogue_session_finished.emit(last_session_result.duplicate(true))
	return true


func _reject_started_session(reason: String) -> Dictionary:
	var session_id := current_session_id
	_terminal_cleanup(reason, false, session_id)
	_debug_log("Dialogue rejected: reason=%s" % reason)
	return {
		"accepted": false,
		"reason": reason,
		"session_id": session_id,
	}


func _dialogue_result(accepted: bool, reason: String) -> Dictionary:
	return {
		"accepted": accepted,
		"reason": reason,
		"session_id": current_session_id if accepted else &"",
	}


func _take_session_id() -> StringName:
	var session_id := StringName("dialogue_session_%d" % _next_session_number)
	_next_session_number += 1
	if _next_session_number <= 0:
		_next_session_number = 1
	return session_id


func _ensure_ui() -> void:
	if _ui != null and is_instance_valid(_ui):
		return
	_ui = UI_SCENE.instantiate() as ModalDialogueUI
	if _ui == null:
		return
	_ui.name = "ModalDialogueUI"
	add_child(_ui)
	_ui.choice_requested.connect(_on_ui_choice_requested)
	_ui.advance_requested.connect(_on_ui_advance_requested)
	_ui.cancel_requested.connect(_on_ui_cancel_requested)


func _on_ui_choice_requested(session_id: StringName, choice_id: StringName) -> void:
	if session_id != current_session_id or _cleanup_in_progress:
		return
	choose(choice_id)


func _on_ui_advance_requested(session_id: StringName) -> void:
	if session_id != current_session_id or _cleanup_in_progress:
		return
	advance()


func _on_ui_cancel_requested(session_id: StringName) -> void:
	if session_id != current_session_id or _cleanup_in_progress:
		return
	cancel_dialogue("player_cancelled")


func _on_npc_control_claim_changed(_npc: Node, claimed: bool, token_id: int) -> void:
	if claimed or _cleanup_in_progress or not is_dialogue_active():
		return
	if token_id == npc_control_claim_token:
		_terminal_cleanup("npc_claim_lost", false, current_session_id)


func _on_player_control_claim_changed(_player: Node, claimed: bool, token_id: int) -> void:
	if claimed or _cleanup_in_progress or not is_dialogue_active():
		return
	if token_id == player_control_claim_token:
		_terminal_cleanup("player_claim_lost", false, current_session_id)


func _all_tokens_are_current() -> bool:
	return (
		_world_lock_is_exact(world_progression_lock_token)
		and _npc_claim_is_exact(current_npc, npc_control_claim_token)
		and _player_claim_is_exact(current_player, player_control_claim_token)
	)


func _world_lock_is_exact(token_id: int) -> bool:
	if token_id == 0:
		return false
	var gameplay_flow := _get_gameplay_flow()
	if gameplay_flow == null:
		return false
	var locks: Array = gameplay_flow.call("get_world_progression_locks")
	for lock_data in locks:
		if int(lock_data.get("token_id", 0)) != token_id:
			continue
		return _weak_ref_matches(lock_data.get("owner"), self)
	return false


func _npc_claim_is_exact(npc, token_id: int) -> bool:
	if token_id == 0 or npc == null or not is_instance_valid(npc):
		return false
	var gameplay_flow := _get_gameplay_flow()
	if gameplay_flow == null:
		return false
	var claim: Dictionary = gameplay_flow.call("get_npc_control_claim", npc)
	return (
		int(claim.get("token_id", 0)) == token_id
		and _weak_ref_matches(claim.get("owner"), self)
	)


func _player_claim_is_exact(player, token_id: int) -> bool:
	if token_id == 0 or player == null or not is_instance_valid(player):
		return false
	var gameplay_flow := _get_gameplay_flow()
	if gameplay_flow == null:
		return false
	var claim: Dictionary = gameplay_flow.call("get_player_control_claim", player)
	return (
		int(claim.get("token_id", 0)) == token_id
		and _weak_ref_matches(claim.get("owner"), self)
	)


func _npc_is_claimed_by_this_controller(npc) -> bool:
	if npc == null or not is_instance_valid(npc):
		return false
	var gameplay_flow := _get_gameplay_flow()
	if gameplay_flow == null:
		return false
	var claim: Dictionary = gameplay_flow.call("get_npc_control_claim", npc)
	return not claim.is_empty() and _weak_ref_matches(claim.get("owner"), self)


func _weak_ref_matches(value, expected: Object) -> bool:
	var reference := value as WeakRef
	return reference != null and reference.get_ref() == expected


func _modal_owner_is_live() -> bool:
	if _modal_owner_ref == null:
		return false
	var owner: Object = _modal_owner_ref.get_ref()
	if owner == null or not is_instance_valid(owner):
		return false
	return not (owner is Node) or (owner as Node).is_inside_tree()


func _get_gameplay_flow() -> Node:
	return get_node_or_null("/root/GameplayFlow")


func _get_npc_machine(npc) -> Node:
	if npc == null or not is_instance_valid(npc):
		return null
	if npc is NpcStateMachine:
		return npc
	return npc.get_node_or_null("NpcStateMachine")


func _get_npc_portrait_presentation(npc: Node) -> Dictionary:
	if npc == null or not is_instance_valid(npc):
		return {}
	for property_name in [
		&"player_talk_dialogue_profile",
		&"autonomous_dialogue_profile",
	]:
		if not NpcIdentity.has_property(npc, property_name):
			continue
		var profile = npc.get(property_name)
		if profile != null and profile.has_method("get_portrait_presentation"):
			return profile.call("get_portrait_presentation") as Dictionary
	return {}


func _get_primary_state_name(machine: Node) -> StringName:
	if machine == null:
		return &""
	var state = machine.get("current_state")
	return StringName(state.name) if state is Node else &""


func _descriptor_is_scheduled(descriptor: Dictionary) -> bool:
	if descriptor.is_empty():
		return false
	var text := "%s %s %s" % [
		String(descriptor.get("source", "")),
		String(descriptor.get("reason", "")),
		String(descriptor.get("reservation_purpose", "")),
	]
	text = text.to_lower()
	return text.contains("schedule") or text.contains("world_activity")


func _descriptor_is_lesson_or_class_handoff(descriptor: Dictionary) -> bool:
	if descriptor.is_empty():
		return false
	var text := "%s %s %s %s" % [
		String(descriptor.get("action_kind", "")),
		String(descriptor.get("source", "")),
		String(descriptor.get("reason", "")),
		String(descriptor.get("lesson_phase", "")),
	]
	text = text.to_lower()
	return text.contains("lesson") or text.contains("class") or text.contains("invite_player")


func _get_current_speaker_display_name() -> String:
	if current_node == null:
		return "Speaker"
	var speaker_id := current_node.speaker_id
	if current_session_mode in [
		SESSION_MODE_MODAL,
		SESSION_MODE_AUTONOMOUS_TALK,
		SESSION_MODE_PLAYER_TALK,
	]:
		var configured_name := String(_speaker_names.get(speaker_id, "")).strip_edges()
		if not configured_name.is_empty():
			return configured_name
		var fallback_name := String(speaker_id).replace("_", " ").capitalize()
		return fallback_name if not fallback_name.is_empty() else "Speaker"
	if speaker_id == &"player":
		return _get_participant_display_name(current_player, "Player")
	return _get_participant_display_name(current_npc, "NPC")


func _talk_owned_session_is_live() -> bool:
	if not _participant_is_live(current_npc) or not _participant_is_live(current_player):
		return false
	var owner: Object = _modal_owner_ref.get_ref() if _modal_owner_ref != null else null
	if owner == null or not is_instance_valid(owner):
		return false
	if not owner.has_method("is_talking_with"):
		return false
	return bool(owner.call("is_talking_with", current_player))


func _get_participant_display_name(participant: Node, fallback: String) -> String:
	if participant != null and is_instance_valid(participant):
		if participant.has_method("get_display_name"):
			return String(participant.call("get_display_name"))
		if not String(participant.name).is_empty():
			return String(participant.name)
	return fallback


func _participant_is_live(participant) -> bool:
	return (
		participant != null
		and is_instance_valid(participant)
		and participant.is_inside_tree()
	)


func _debug_log(message: String) -> void:
	if OS.is_debug_build():
		print(message)
