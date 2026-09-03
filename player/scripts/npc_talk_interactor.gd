class_name PlayerNpcTalkInteractor extends Area2D

signal interaction_started(player: Node2D, npc: Node2D, interaction_id: StringName)
signal interaction_applied(player: Node2D, npc: Node2D, interaction_id: StringName)
signal interaction_blocked(player: Node2D, npc: Node2D, interaction_id: StringName, reason: String)

const MENU_CLOSED := &""
const MENU_INTERACTION := &"interaction"
const MENU_TALK := &"talk"
const MENU_GOSSIP := &"gossip"
const MENU_NPC_PROMPT := &"npc_prompt"
const DEFAULT_DIALOGUE_METADATA := &"default_dialogue_definition"
const DEFAULT_PLAYER_TALK_PROFILE := preload(
	"res://data/dialogue/generic_player_talk_dialogue_profile.tres"
)
const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")
const SocialStateSchema = preload(
	"res://scripts/systems/npc_social_state_schema.gd"
)
const FeedbackCatalog = preload(
	"res://scripts/systems/npc_behavior/feedback/npc_feedback_catalog.gd"
)
const FLIRT_LOVE_GAIN_LIMIT: float = 100.0
const CHOICE_OPINION_DELTA_KEY := &"player_talk_opinion_delta"
const CHOICE_INSULT_ACTION_KEY := &"player_talk_insult_action"
const INSULT_ACTION_CHALLENGE_FIGHT := &"challenge_fight"
const INSULT_CONFRONTATION_SOCIAL_REASONS := {
	"recently_talked_with_requester": true,
	"requester_favor_too_low": true,
	"requester_anger_too_high": true,
}

@export_group("Interaction")
@export var interaction_action: StringName = &"charm"
@export var interaction_id: StringName = &"talk"
@export var cooldown_seconds: float = 0.35
@export var max_distance: float = 120.0
@export var npc_groups: Array[StringName] = [&"npc"]
@export var interaction_priority: int = 60
@export var interaction_prompt: String = "Talk"

@export_group("Menus")
@export var option_actions: Array[StringName] = [
	&"option1",
	&"option2",
	&"option3",
	&"option4",
	&"option5"
]
@export var interaction_option_texts: PackedStringArray = [
	"Talk",
	"Trade",
	"Cancel"
]
@export var talk_option_texts: PackedStringArray = [
	"Casual",
	"Compliment",
	"Flirt",
	"Insult",
	"Gossip"
]
@export var talk_option_ids: Array[StringName] = [
	&"casual",
	&"compliment",
	&"flirt",
	&"insult",
	&"gossip",
]
## Checked once when the Talk menu opens. NPC profiles carry a readable
## unspecified/male/female tag; mobile does not poll identity every frame.
@export var player_flirt_gender_tags: Array[StringName] = [&"female", &"unspecified"]
@export_range(1, 5, 1) var gossip_talk_option_number: int = 5
@export var talk_option_deltas: Array[Dictionary] = [
	{
		"trust": 1.0
	},
	{
		"favor": 3.0,
		"trust": 2.0
	},
	{
		"favor": 2.0,
		"love": 1.0
	},
	{
		"favor": -6.0,
		"trust": -5.0,
		"anger": 12.0,
		"love": -1.0
	},
	{
		"trust": 1.0
	}
]
@export var close_menu_when_target_exits: bool = true
@export_range(0.0, 30.0, 0.1, "suffix:s") var menu_choice_timeout_seconds: float = 5.0
@export_range(0.0, 120.0, 0.1, "suffix:s") var npc_interaction_cooldown_seconds: float = 20.0
@export var menu_canvas_layer: int = 80
@export var menu_position: Vector2 = Vector2(24.0, 150.0)
@export var menu_minimum_size: Vector2 = Vector2(260.0, 150.0)

@export_group("Future Gates")
@export var allowed_npc_ids: Array[StringName] = []
@export var required_npc_tags: Array[StringName] = []

@export_group("Effects")
@export var request_talk_state: bool = true
@export var skip_requested_talk_state_need_payout: bool = true
@export var stat_delta: Dictionary = {
	"talk_need": -40.0,
	"boredom": -10.0
}
@export var set_values: Dictionary = {}
@export var evaluate_set_value_reactions: bool = false

var player: Node2D
var nearby_npcs: Array[Node2D] = []
var cooldown: float = 0.0
var active_menu: StringName = MENU_CLOSED
var menu_timer: float = 0.0
var menu_target_npc: Node2D
var gossip_candidates: Array[Dictionary] = []
var gossip_page_index: int = 0
var menu_layer: CanvasLayer
var menu_panel: PanelContainer
var menu_title_label: Label
var menu_feedback_label: Label
var menu_option_labels: Array[Label] = []
var current_menu_option_count: int = 0
var prompt_id: StringName = &""
var prompt_callback_target: Node
var prompt_accept_method: StringName = &""
var prompt_decline_method: StringName = &""
var prompt_completed: bool = false
var menu_target_can_trade: bool = false
var interaction_menu_actions: Array[StringName] = []
var talk_menu_source_indices: Array[int] = []
var menu_confrontation_only: bool = false
var menu_hold_machine: NpcStateMachine
var _player_talk_rng := RandomNumberGenerator.new()
var _last_player_talk_dialogue_ids: Dictionary = {}
var _active_player_talk: Dictionary = {}


func _ready() -> void:
	player = get_parent() as Node2D
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	interaction_blocked.connect(_on_interaction_blocked_feedback)
	_player_talk_rng.randomize()
	var dialogue_controller := get_node_or_null("/root/DialogueController")
	if dialogue_controller != null:
		var finished_callback := Callable(self, "_on_player_talk_dialogue_finished")
		if not dialogue_controller.dialogue_session_finished.is_connected(finished_callback):
			dialogue_controller.dialogue_session_finished.connect(finished_callback)
		var choice_callback := Callable(self, "_on_player_talk_choice_committed")
		if not dialogue_controller.dialogue_choice_committed.is_connected(choice_callback):
			dialogue_controller.dialogue_choice_committed.connect(choice_callback)


func _exit_tree() -> void:
	_cancel_active_player_talk("interactor_exit")
	if player != null and is_instance_valid(player) and player.has_method("unregister_interaction_candidate"):
		player.call("unregister_interaction_candidate", self)
	# The UI may disappear during a scene change; never leave its NPC paused behind.
	if menu_target_npc != null and is_instance_valid(menu_target_npc):
		_end_target_menu_hold(menu_target_npc)
	elif menu_hold_machine != null and is_instance_valid(menu_hold_machine):
		menu_hold_machine.end_player_interaction_hold(player)
	_unwatch_target_interaction_gate()


func _process(delta: float) -> void:
	cooldown = maxf(cooldown - delta, 0.0)
	if _player_gameplay_control_is_claimed():
		if _menu_is_open():
			close_for_scripted_handoff()
		return

	if _menu_is_open():
		_tick_menu_timer(delta)
		if not _menu_is_open():
			return

		_update_open_menu()
		if not _menu_is_open():
			return

		_handle_menu_option_input()
		return


func can_interact(actor: Node) -> bool:
	if actor != player or cooldown > 0.0 or _menu_is_open():
		return false
	if _player_gameplay_control_is_claimed():
		return false
	var target_npc := _get_closest_npc()
	if target_npc == null:
		return false
	var block_reason := _get_block_reason(target_npc)
	return (
		block_reason.is_empty()
		or FeedbackCatalog.is_player_interaction_refusal_presentable(
			StringName(block_reason)
		)
	)


func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	return _try_open_interaction_menu()


func get_interaction_action(_actor: Node) -> StringName:
	return interaction_action


func get_interaction_priority(_actor: Node) -> int:
	return interaction_priority


func get_interaction_prompt(_actor: Node) -> String:
	return interaction_prompt


func get_interaction_position(_actor: Node) -> Vector2:
	var target_npc := menu_target_npc if _menu_is_open() else _get_closest_npc()
	return target_npc.global_position if target_npc != null else global_position


func is_world_interaction_ui_open() -> bool:
	return _menu_is_open()


func consume_player_interaction_input(actor: Node) -> bool:
	if actor != player or not _menu_is_open():
		return false
	if active_menu == MENU_GOSSIP and _get_gossip_page_count() > 1:
		gossip_page_index = (gossip_page_index + 1) % _get_gossip_page_count()
		_show_gossip_menu("")
	return true


func _try_open_interaction_menu() -> bool:
	var target_npc := _get_closest_npc()
	if target_npc == null:
		return false

	var authoritative_gate := _get_authoritative_interaction_gate(target_npc)
	var block_reason := _get_block_reason_with_authoritative_gate(
		target_npc,
		authoritative_gate
	)
	if not block_reason.is_empty():
		interaction_blocked.emit(player, target_npc, interaction_id, block_reason)
		return false
	menu_target_npc = target_npc
	menu_confrontation_only = bool(authoritative_gate.get(
		"confrontation_only",
		false
	))
	active_menu = MENU_INTERACTION
	_show_interaction_menu("")
	cooldown = cooldown_seconds
	return _menu_is_open()


func _on_interaction_blocked_feedback(
	actor: Node2D,
	target_npc: Node2D,
	_blocked_interaction_id: StringName,
	reason: String
) -> void:
	if target_npc == null or not is_instance_valid(target_npc):
		return
	var machine := _get_machine(target_npc)
	if machine != null and machine.has_method("present_player_interaction_refusal"):
		machine.call(
			"present_player_interaction_refusal",
			StringName(reason),
			actor
		)


func show_npc_prompt(
	npc: Node2D,
	prompt_id_value: StringName,
	title: String,
	options: PackedStringArray,
	callback_target: Node,
	accept_method: StringName,
	decline_method: StringName,
	timeout_seconds: float = -1.0
) -> bool:
	if npc == null or not is_instance_valid(npc):
		return false
	if player == null or not is_instance_valid(player):
		return false
	if callback_target == null or not is_instance_valid(callback_target):
		return false
	if accept_method == &"" or decline_method == &"":
		return false
	if options.is_empty():
		return false
	if _menu_is_open():
		return (
			active_menu == MENU_NPC_PROMPT
			and menu_target_npc == npc
			and prompt_id == prompt_id_value
		)
	if not _is_valid_npc_candidate(npc):
		return false

	menu_target_npc = npc
	active_menu = MENU_NPC_PROMPT
	prompt_id = prompt_id_value
	prompt_callback_target = callback_target
	prompt_accept_method = accept_method
	prompt_decline_method = decline_method
	prompt_completed = false
	_show_menu(title, options, "")
	if active_menu != MENU_NPC_PROMPT:
		return false
	if timeout_seconds >= 0.0:
		menu_timer = timeout_seconds
		var hold_result := _begin_target_menu_hold(npc, timeout_seconds)
		if not bool(hold_result.get("accepted", false)):
			_invalidate_open_menu(String(hold_result.get("reason", "interaction_hold_rejected")))
			return false
	cooldown = cooldown_seconds
	return true


func show_magic_lesson_invite(mom: Node2D, lesson_spot: Node) -> bool:
	return show_npc_prompt(
		mom,
		&"mom_magic_lesson",
		"Study magic with Mom?",
		PackedStringArray(["Yes", "Not now"]),
		lesson_spot,
		&"accept_lesson",
		&"decline_lesson"
	)


func _show_interaction_menu(feedback: String = "") -> void:
	var npc_label := _get_npc_label(menu_target_npc)
	if menu_confrontation_only:
		menu_target_can_trade = false
		interaction_menu_actions = [&"talk", &"cancel"]
		_show_menu(
			"Confront: %s" % npc_label,
			PackedStringArray(["Talk", "Cancel"]),
			feedback
		)
		return
	menu_target_can_trade = (
		menu_target_npc != null
		and menu_target_npc.has_method("can_trade_with_player")
		and bool(menu_target_npc.call("can_trade_with_player", player))
	)
	var options := PackedStringArray(["Talk", "Actions"])
	interaction_menu_actions = [&"talk", &"actions"]
	if menu_target_can_trade:
		options.append("Trade")
		interaction_menu_actions.append(&"trade")
	if menu_target_npc != null and menu_target_npc.has_method("get_travel_unavailable_reason"):
		var runtime := get_node_or_null("/root/PlayerRuntime")
		var already_traveling := runtime != null and bool(runtime.call("is_active_companion", menu_target_npc))
		var travel_reason := String(menu_target_npc.call("get_travel_unavailable_reason", player))
		if already_traveling or travel_reason.is_empty():
			options.append("Stop Traveling Together" if already_traveling else "Travel Together")
			interaction_menu_actions.append(&"travel")
	options.append("Cancel")
	interaction_menu_actions.append(&"cancel")
	_show_menu("Interact: %s" % npc_label, options, feedback)


func _show_talk_menu(feedback: String = "") -> void:
	var npc_label := _get_npc_label(menu_target_npc)
	var profile := _get_player_talk_dialogue_profile(menu_target_npc)
	var options := PackedStringArray()
	talk_menu_source_indices.clear()
	var configured_count := mini(talk_option_texts.size(), talk_option_ids.size())
	for source_index in configured_count:
		var category := _get_talk_option_id(source_index)
		if (
			menu_confrontation_only
			and category != NpcPlayerTalkDialogueProfile.CATEGORY_INSULT
		):
			continue
		if (
			category == NpcPlayerTalkDialogueProfile.CATEGORY_FLIRT
			and profile != null
			and not profile.is_player_flirt_available(player_flirt_gender_tags)
		):
			continue
		options.append(talk_option_texts[source_index])
		talk_menu_source_indices.append(source_index)
	_show_menu("Talk: %s" % npc_label, options, feedback)


func _show_gossip_menu(feedback: String = "") -> void:
	var npc_label := _get_npc_label(menu_target_npc)
	var options := PackedStringArray()
	var page_start := gossip_page_index * option_actions.size()
	var page_end: int = mini(page_start + option_actions.size(), gossip_candidates.size())
	for index in range(page_start, page_end):
		options.append(_get_gossip_candidate_option_text(gossip_candidates[index]))

	var page_count := _get_gossip_page_count()
	var page_feedback := feedback
	if page_count > 1:
		var page_text := "C: next page %d/%d" % [gossip_page_index + 1, page_count]
		page_feedback = page_text if page_feedback.is_empty() else "%s | %s" % [page_feedback, page_text]

	_show_menu("Gossip about: %s" % npc_label, options, page_feedback)


func _show_menu(title: String, options: PackedStringArray, feedback: String) -> void:
	_ensure_menu_ui()
	if menu_layer == null or menu_panel == null or menu_title_label == null:
		_close_menu()
		return
	var hold_result := _begin_target_menu_hold(menu_target_npc)
	if not bool(hold_result.get("accepted", false)):
		_invalidate_open_menu(String(hold_result.get("reason", "interaction_hold_rejected")))
		return

	menu_layer.visible = true
	menu_panel.visible = true
	menu_timer = maxf(menu_choice_timeout_seconds, 0.0)
	menu_title_label.text = title
	if menu_feedback_label != null:
		menu_feedback_label.text = feedback
		menu_feedback_label.visible = not feedback.is_empty()

	var option_count: int = mini(options.size(), option_actions.size())
	current_menu_option_count = option_count
	for index in menu_option_labels.size():
		var label: Label = menu_option_labels[index]
		label.visible = index < option_count
		if index < option_count:
			label.text = "%d  %s" % [index + 1, options[index]]


func _ensure_menu_ui() -> void:
	if menu_layer != null and is_instance_valid(menu_layer):
		return

	menu_layer = CanvasLayer.new()
	menu_layer.name = "NpcInteractionMenuLayer"
	menu_layer.layer = menu_canvas_layer
	menu_layer.visible = false
	add_child(menu_layer)

	menu_panel = PanelContainer.new()
	menu_panel.name = "NpcInteractionPanel"
	menu_panel.position = menu_position
	menu_panel.custom_minimum_size = menu_minimum_size
	menu_layer.add_child(menu_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	menu_panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 4)
	margin.add_child(stack)

	menu_title_label = Label.new()
	menu_title_label.name = "Title"
	menu_title_label.add_theme_font_size_override("font_size", 14)
	stack.add_child(menu_title_label)

	for index in option_actions.size():
		var option_label := Label.new()
		option_label.name = "Option%d" % [index + 1]
		option_label.add_theme_font_size_override("font_size", 12)
		stack.add_child(option_label)
		menu_option_labels.append(option_label)

	menu_feedback_label = Label.new()
	menu_feedback_label.name = "Feedback"
	menu_feedback_label.add_theme_font_size_override("font_size", 11)
	menu_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu_feedback_label.visible = false
	stack.add_child(menu_feedback_label)


func _handle_menu_option_input() -> void:
	var selected_index := _get_pressed_option_index()
	if selected_index < 0:
		return

	if active_menu == MENU_INTERACTION:
		_handle_interaction_option(selected_index)
		return

	if active_menu == MENU_TALK:
		_handle_talk_option(selected_index)
		return

	if active_menu == MENU_GOSSIP:
		_handle_gossip_option(selected_index)
		return

	if active_menu == MENU_NPC_PROMPT:
		_handle_npc_prompt_option(selected_index)


func _handle_interaction_option(selected_index: int) -> void:
	if selected_index < 0 or selected_index >= interaction_menu_actions.size():
		return
	var selected_action := interaction_menu_actions[selected_index]
	if selected_action == &"talk":
		active_menu = MENU_TALK
		_show_talk_menu("")
		return
	if selected_action == &"actions":
		_show_interaction_menu("Actions: To be implemented.")
		return

	if selected_action == &"trade":
		var target := menu_target_npc
		_close_menu()
		if target != null and target.has_method("try_open_trade") and bool(target.call("try_open_trade", player)):
			_mark_player_npc_met(target, &"trade")
			interaction_started.emit(player, target, &"trade")
			interaction_applied.emit(player, target, &"trade")
		else:
			interaction_blocked.emit(player, target, &"trade", "trade_unavailable")
		cooldown = cooldown_seconds
		return

	if selected_action == &"travel":
		var target := menu_target_npc
		var result: Dictionary = target.call("try_toggle_travel_with_player", player)
		if bool(result.get("success", false)):
			_mark_player_npc_met(target, &"travel")
			interaction_applied.emit(player, target, &"travel")
			_finish_menu_attempt("", true)
		else:
			_show_interaction_menu(String(result.get("reason", "Travel unavailable.")))
		cooldown = cooldown_seconds
		return

	if selected_action == &"cancel":
		_close_menu()
		return

	var option_id := StringName("interaction_option_%d" % [selected_index + 1])
	interaction_blocked.emit(player, menu_target_npc, option_id, "not_implemented")
	_finish_menu_attempt("", true)


func _handle_talk_option(selected_index: int) -> void:
	if not _menu_target_is_still_valid():
		_close_menu()
		return

	var source_index := _get_talk_menu_source_index(selected_index)
	if source_index < 0:
		return

	if source_index == _get_gossip_talk_option_index():
		_open_gossip_menu()
		return

	var category := _get_talk_option_id(source_index)
	var selected_interaction_id := StringName("talk_%s" % String(category))
	if (
		category == NpcPlayerTalkDialogueProfile.CATEGORY_INSULT
		and _try_start_immediate_insult_fight(
			source_index,
			selected_interaction_id
		)
	):
		return
	_begin_player_talk_response(
		category,
		_get_talk_option_delta(source_index),
		selected_interaction_id
	)


func _handle_gossip_option(selected_index: int) -> void:
	if not _menu_target_is_still_valid():
		_close_menu()
		return

	var gossip_subject := _get_gossip_candidate_for_option(selected_index)
	if gossip_subject.is_empty():
		return

	var gossip_option_index := _get_gossip_talk_option_index()
	var option_delta := _get_talk_option_delta(gossip_option_index)
	var selected_interaction_id := &"talk_gossip"
	_begin_player_talk_response(
		&"gossip",
		option_delta,
		selected_interaction_id,
		gossip_subject
	)


func _handle_npc_prompt_option(selected_index: int) -> void:
	if selected_index < 0 or selected_index >= current_menu_option_count:
		return
	if not _menu_target_is_still_valid():
		_finish_npc_prompt(false, "target_left")
		return

	_finish_npc_prompt(selected_index == 0)


func _get_talk_option_delta(selected_index: int) -> Dictionary:
	if selected_index >= 0 and selected_index < talk_option_deltas.size():
		var option_delta = talk_option_deltas[selected_index]
		if option_delta is Dictionary:
			return option_delta.duplicate(true)

	return stat_delta.duplicate(true)


func _get_talk_option_id(selected_index: int) -> StringName:
	if selected_index >= 0 and selected_index < talk_option_ids.size():
		return talk_option_ids[selected_index]
	return StringName("option_%d" % [selected_index + 1])


func _get_talk_menu_source_index(visible_index: int) -> int:
	if visible_index < 0 or visible_index >= talk_menu_source_indices.size():
		return -1
	return talk_menu_source_indices[visible_index]


func _begin_player_talk_response(
	category: StringName,
	effect_delta: Dictionary,
	selected_interaction_id: StringName,
	gossip_subject: Dictionary = {}
) -> void:
	var target_npc := menu_target_npc
	if target_npc == null or not is_instance_valid(target_npc):
		_close_menu()
		return
	if not _active_player_talk.is_empty():
		interaction_blocked.emit(
			player, target_npc, selected_interaction_id, "player_talk_already_active"
		)
		return

	var profile := _get_player_talk_dialogue_profile(target_npc)
	var profile_error := profile.get_validation_error() if profile != null else "player_talk_profile_missing"
	if not profile_error.is_empty():
		interaction_blocked.emit(player, target_npc, selected_interaction_id, profile_error)
		_show_talk_menu("No responses are configured for this NPC.")
		return

	var context := {
		"npc_name": _get_npc_label(target_npc),
		"target_name": String(gossip_subject.get("label", "someone")),
	}
	var repeat_key := "%s|%s" % [String(_get_npc_id(target_npc)), String(category)]
	var previous_dialogue_id := StringName(_last_player_talk_dialogue_ids.get(repeat_key, &""))
	var current_love := -1.0
	var current_anger := -1.0
	if category == NpcPlayerTalkDialogueProfile.CATEGORY_FLIRT:
		current_love = _get_relationship_opinion_metric(target_npc, &"love", 0.0)
	elif category == NpcPlayerTalkDialogueProfile.CATEGORY_INSULT:
		current_anger = _get_relationship_opinion_metric(target_npc, &"anger", 0.0)
	var definition := profile.instantiate_response(
		category,
		_player_talk_rng,
		previous_dialogue_id,
		context,
		current_love,
		current_anger
	)
	if definition == null:
		interaction_blocked.emit(
			player, target_npc, selected_interaction_id, "player_talk_response_missing"
		)
		_show_talk_menu("That kind of conversation is unavailable.")
		return
	if not definition.get_validation_error().is_empty():
		interaction_blocked.emit(
			player, target_npc, selected_interaction_id, "player_talk_response_invalid"
		)
		_show_talk_menu("That response could not be opened.")
		return

	var machine := _get_machine(target_npc)
	var talk_state := machine.get_state(&"Talk") as NpcStateTalk if machine != null else null
	if talk_state == null:
		interaction_blocked.emit(
			player, target_npc, selected_interaction_id, "talk_state_missing"
		)
		_show_talk_menu("This NPC cannot begin a conversation.")
		return

	_active_player_talk = {
		"category": category,
		"definition": definition,
		"effect_delta": effect_delta.duplicate(true),
		"effect_set_values": set_values.duplicate(true),
		"gossip_subject": gossip_subject.duplicate(true),
		"interaction_id": selected_interaction_id,
		"profile": profile,
		"repeat_key": repeat_key,
		"talk_ref": weakref(talk_state),
		"talk_session_id": "",
		"target_ref": weakref(target_npc),
		"dialogue_session_id": &"",
		"choice_opinion_metrics": {},
		"insult_action": &"",
		"bypass_social_talk_refusal": (
			menu_confrontation_only
			and category == NpcPlayerTalkDialogueProfile.CATEGORY_INSULT
		),
		"love_gate": (
			NpcPlayerTalkDialogueProfile.get_flirt_love_gate_index(current_love)
			if current_love >= 0.0
			else -1
		),
		"portrait_love": current_love,
		"anger_gate": (
			NpcPlayerTalkDialogueProfile.get_insult_anger_gate_index(current_anger)
			if current_anger >= 0.0
			else -1
		),
		"portrait_anger": current_anger,
	}
	if not talk_state.talk_started.is_connected(_on_player_talk_started):
		talk_state.talk_started.connect(_on_player_talk_started)
	if not talk_state.talk_cancelled.is_connected(_on_player_talk_cancelled):
		talk_state.talk_cancelled.connect(_on_player_talk_cancelled)

	# This reserves the existing Talk action. Its normal completion path remains
	# responsible for talk_need, boredom, action-session, and memory rewards.
	var acceptance := _request_social_interaction_acceptance(target_npc, false)
	if not bool(acceptance.get("accepted", false)):
		_clear_active_player_talk()
		_reject_social_interaction(
			target_npc,
			selected_interaction_id,
			String(acceptance.get("reason", "talk_request_rejected"))
		)
		return

	if not _active_player_talk.is_empty():
		_active_player_talk["talk_session_id"] = talk_state.terminal_session_id
	if _menu_is_open():
		_end_target_menu_hold(target_npc)
		_close_menu(false)
	if (
		not _active_player_talk.is_empty()
		and talk_state.talk_started_handled
		and StringName(_active_player_talk.get("dialogue_session_id", &"")) == &""
	):
		_on_player_talk_started(target_npc, player)
	cooldown = cooldown_seconds


func _on_player_talk_started(_talker: Node2D, partner: Node2D) -> void:
	if _active_player_talk.is_empty() or partner != player:
		return
	var talk_state := _get_active_player_talk_state()
	var target_npc := _get_active_player_talk_target()
	if (
		talk_state == null
		or target_npc == null
		or not talk_state.is_talking_with(player)
		or talk_state.terminal_source != "player"
		or StringName(_active_player_talk.get("dialogue_session_id", &"")) != &""
	):
		return
	_active_player_talk["talk_session_id"] = talk_state.terminal_session_id
	if _menu_is_open():
		_end_target_menu_hold(target_npc)
		_close_menu(false)

	var profile := _active_player_talk.get("profile") as NpcPlayerTalkDialogueProfile
	var definition := _active_player_talk.get("definition") as DialogueDefinition
	var controller := get_node_or_null("/root/DialogueController")
	if controller == null or not controller.has_method("begin_player_talk_dialogue"):
		_fail_active_player_talk("dialogue_controller_missing")
		return
	var speaker_names := profile.get_speaker_names()
	speaker_names[profile.speaker_id] = _get_npc_label(target_npc)
	var result: Dictionary = controller.call(
		"begin_player_talk_dialogue",
		talk_state,
		player,
		target_npc,
		definition,
		speaker_names,
		_get_player_talk_portrait_presentation(
			target_npc,
			profile,
			StringName(_active_player_talk.get("category", &"")),
			float(_active_player_talk.get("portrait_love", -1.0)),
			float(_active_player_talk.get("portrait_anger", -1.0))
		)
	)
	if not bool(result.get("accepted", false)):
		_fail_active_player_talk(
			"dialogue_start_%s" % String(result.get("reason", "rejected"))
		)
		return

	var dialogue_session_id := StringName(result.get("session_id", &""))
	_active_player_talk["dialogue_session_id"] = dialogue_session_id
	_last_player_talk_dialogue_ids[String(_active_player_talk.get("repeat_key", ""))] = (
		definition.dialogue_id
	)
	interaction_started.emit(
		player,
		target_npc,
		StringName(_active_player_talk.get("interaction_id", &"talk"))
	)
	if not talk_state.wait_for_external_completion():
		controller.call(
			"cancel_dialogue_session", dialogue_session_id, "talk_wait_rejected"
		)


func _on_player_talk_choice_committed(
	session_id: StringName,
	dialogue_id: StringName,
	choice_id: StringName,
	choice_data: DialogueChoice
) -> void:
	if (
		_active_player_talk.is_empty()
		or choice_data == null
		or session_id != StringName(_active_player_talk.get("dialogue_session_id", &""))
	):
		return
	if (
		StringName(_active_player_talk.get("interaction_id", &"")) == &"talk_insult"
		and choice_data.consequences.has(CHOICE_INSULT_ACTION_KEY)
	):
		_active_player_talk["insult_action"] = StringName(String(
			choice_data.consequences.get(CHOICE_INSULT_ACTION_KEY, &"")
		))
	if not choice_data.consequences.has(CHOICE_OPINION_DELTA_KEY):
		return
	var raw_delta = choice_data.consequences.get(CHOICE_OPINION_DELTA_KEY, {})
	if not (raw_delta is Dictionary):
		return
	var opinion_delta: Dictionary = {}
	var resolved_metrics: Dictionary = _active_player_talk.get(
		"choice_opinion_metrics", {}
	).duplicate(true)
	for metric_value in raw_delta.keys():
		var metric := StringName(String(metric_value))
		if not SocialStateSchema.is_directed_opinion_metric(metric):
			continue
		var amount := float(raw_delta[metric_value])
		if not is_finite(amount):
			continue
		resolved_metrics[String(metric)] = true
		var is_flirt_love := (
			StringName(_active_player_talk.get("interaction_id", &"")) == &"talk_flirt"
			and metric == &"love"
		)
		if not is_zero_approx(amount) or is_flirt_love:
			opinion_delta[String(metric)] = amount
	_active_player_talk["choice_opinion_metrics"] = resolved_metrics
	if opinion_delta.is_empty():
		return

	var target_npc := _get_active_player_talk_target()
	if target_npc == null:
		return
	if StringName(_active_player_talk.get("interaction_id", &"")) == &"talk_flirt":
		opinion_delta = _apply_flirt_favor_modifier(target_npc, opinion_delta)
		opinion_delta = _limit_flirt_love_gain(
			target_npc,
			opinion_delta,
			&"talk_flirt"
		)
	if opinion_delta.is_empty():
		return
	var receiver := _get_event_receiver(target_npc)
	if receiver == null:
		return
	receiver.call(
		"apply_social_event",
		opinion_delta,
		player,
		false,
		"player_talk_dialogue_choice",
		{
			"source": "player_talk_dialogue_choice",
			"dialogue_id": String(dialogue_id),
			"choice_id": String(choice_id),
			"interaction_id": String(_active_player_talk.get("interaction_id", &"talk")),
		}
	)


func _on_player_talk_dialogue_finished(result: Dictionary) -> void:
	if _active_player_talk.is_empty():
		return
	var session_id := StringName(result.get("session_id", &""))
	if session_id != StringName(_active_player_talk.get("dialogue_session_id", &"")):
		return

	var talk_state := _get_active_player_talk_state()
	var target_npc := _get_active_player_talk_target()
	var talk_session_id := String(_active_player_talk.get("talk_session_id", ""))
	var interaction_id := StringName(_active_player_talk.get("interaction_id", &"talk"))
	var profile := _active_player_talk.get("profile") as NpcPlayerTalkDialogueProfile
	var insult_action := StringName(_active_player_talk.get("insult_action", &""))
	var effect_delta: Dictionary = _active_player_talk.get("effect_delta", {}).duplicate(true)
	var choice_opinion_metrics: Dictionary = _active_player_talk.get(
		"choice_opinion_metrics", {}
	).duplicate(true)
	for metric_value in choice_opinion_metrics.keys():
		effect_delta.erase(String(metric_value))
		effect_delta.erase(StringName(String(metric_value)))
	var effect_set_values: Dictionary = _active_player_talk.get(
		"effect_set_values", {}
	).duplicate(true)
	var gossip_subject: Dictionary = _active_player_talk.get(
		"gossip_subject", {}
	).duplicate(true)
	var talk_is_current := (
		talk_state != null
		and target_npc != null
		and talk_state.terminal_session_id == talk_session_id
		and talk_state.is_talking_with(player)
		and talk_state.is_waiting_for_external_completion()
	)
	_clear_active_player_talk()

	if bool(result.get("completed", false)) and talk_is_current:
		_apply_interaction_effects(
			target_npc, effect_delta, effect_set_values, interaction_id
		)
		if not gossip_subject.is_empty():
			_call_gossip_hook(target_npc, gossip_subject, effect_delta)
		var insult_fight_trigger := _get_completed_insult_fight_trigger(
			target_npc,
			profile,
			interaction_id,
			insult_action
		)
		if insult_fight_trigger != &"":
			talk_state.cancel_talk_session("player_insult_%s" % String(insult_fight_trigger))
			if not _request_insult_fight(
				target_npc,
				profile,
				insult_fight_trigger
			):
				interaction_blocked.emit(
					player,
					target_npc,
					interaction_id,
					"player_insult_fight_unavailable"
				)
		else:
			talk_state.complete_talk_with(player, "player_dialogue_completed")
		interaction_applied.emit(player, target_npc, interaction_id)
	elif talk_is_current:
		talk_state.cancel_talk_session(
			"dialogue_%s" % String(result.get("reason", "cancelled"))
		)

	if target_npc != null and is_instance_valid(target_npc):
		_start_target_interaction_cooldown(target_npc)
	cooldown = cooldown_seconds


func _on_player_talk_cancelled(
	_talker: Node2D,
	_partner: Node2D,
	reason: String
) -> void:
	if _active_player_talk.is_empty():
		return
	var target_npc := _get_active_player_talk_target()
	var interaction_id := StringName(_active_player_talk.get("interaction_id", &"talk"))
	var dialogue_session_id := StringName(
		_active_player_talk.get("dialogue_session_id", &"")
	)
	_clear_active_player_talk()
	var controller := get_node_or_null("/root/DialogueController")
	if dialogue_session_id != &"" and controller != null:
		controller.call(
			"cancel_dialogue_session",
			dialogue_session_id,
			"talk_cancelled_%s" % reason
		)
	if target_npc != null and is_instance_valid(target_npc):
		interaction_blocked.emit(player, target_npc, interaction_id, reason)
		_start_target_interaction_cooldown(target_npc)
	cooldown = cooldown_seconds


func _fail_active_player_talk(reason: String) -> void:
	var talk_state := _get_active_player_talk_state()
	var target_npc := _get_active_player_talk_target()
	var interaction_id := StringName(_active_player_talk.get("interaction_id", &"talk"))
	_clear_active_player_talk()
	if talk_state != null:
		talk_state.cancel_talk_session(reason)
	if target_npc != null and is_instance_valid(target_npc):
		interaction_blocked.emit(player, target_npc, interaction_id, reason)
		_start_target_interaction_cooldown(target_npc)
	cooldown = cooldown_seconds


func _cancel_active_player_talk(reason: String) -> void:
	if _active_player_talk.is_empty():
		return
	var talk_state := _get_active_player_talk_state()
	var dialogue_session_id := StringName(
		_active_player_talk.get("dialogue_session_id", &"")
	)
	_clear_active_player_talk()
	var controller := get_node_or_null("/root/DialogueController")
	if dialogue_session_id != &"" and controller != null:
		controller.call("cancel_dialogue_session", dialogue_session_id, reason)
	if talk_state != null:
		talk_state.cancel_talk_session(reason)


func _clear_active_player_talk() -> void:
	_active_player_talk.clear()


func _get_active_player_talk_state() -> NpcStateTalk:
	var reference := _active_player_talk.get("talk_ref", null) as WeakRef
	return reference.get_ref() as NpcStateTalk if reference != null else null


func _get_active_player_talk_target() -> Node2D:
	var reference := _active_player_talk.get("target_ref", null) as WeakRef
	return reference.get_ref() as Node2D if reference != null else null


func _get_player_talk_dialogue_profile(
	target_npc: Node
) -> NpcPlayerTalkDialogueProfile:
	if (
		target_npc != null
		and is_instance_valid(target_npc)
		and NpcIdentity.has_property(target_npc, &"player_talk_dialogue_profile")
	):
		var configured := target_npc.get(
			"player_talk_dialogue_profile"
		) as NpcPlayerTalkDialogueProfile
		if configured != null:
			return configured
	return DEFAULT_PLAYER_TALK_PROFILE as NpcPlayerTalkDialogueProfile


func _get_player_talk_portrait_presentation(
	target_npc: Node,
	profile: NpcPlayerTalkDialogueProfile,
	category: StringName = &"",
	current_love: float = -1.0,
	current_anger: float = -1.0
) -> Dictionary:
	var presentation := profile.get_portrait_presentation(
		category,
		current_love,
		current_anger
	)
	if presentation.get("portrait", null) is Texture2D:
		return presentation

	# A generic response profile may still reuse an NPC's autonomous portrait.
	# Normalize speaker IDs to the active response resource before presenting it.
	if (
		target_npc != null
		and is_instance_valid(target_npc)
		and NpcIdentity.has_property(target_npc, &"autonomous_dialogue_profile")
	):
		var autonomous_profile := target_npc.get(
			"autonomous_dialogue_profile"
		) as NpcAutonomousDialogueProfile
		if autonomous_profile != null and autonomous_profile.portrait != null:
			presentation["portrait"] = autonomous_profile.portrait
			return presentation
	if target_npc != null and target_npc.has_meta(&"dialogue_portrait"):
		var metadata_portrait := target_npc.get_meta(
			&"dialogue_portrait"
		) as Texture2D
		if metadata_portrait != null:
			presentation["portrait"] = metadata_portrait
	return presentation


func _get_gossip_talk_option_index() -> int:
	return clampi(gossip_talk_option_number - 1, 0, maxi(option_actions.size() - 1, 0))


func _open_gossip_menu() -> void:
	gossip_candidates = _build_gossip_candidates(menu_target_npc)
	gossip_page_index = 0
	if gossip_candidates.is_empty():
		interaction_blocked.emit(player, menu_target_npc, &"talk_gossip", "no_gossip_targets")
		_show_talk_menu("No known NPCs to gossip about.")
		return

	active_menu = MENU_GOSSIP
	_show_gossip_menu("")


func _build_gossip_candidates(target_npc: Node2D) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	if target_npc == null or not is_instance_valid(target_npc):
		return candidates

	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("get_relationships_for"):
		return candidates

	var known_relationships = relationships.call("get_relationships_for", target_npc)
	if not (known_relationships is Dictionary):
		return candidates

	var npc_relationship_id := _get_relationship_id_for_node(target_npc)
	var player_relationship_id := _get_relationship_id_for_node(player)
	for relationship_key in known_relationships.keys():
		var relationship_value = known_relationships[relationship_key]
		if not (relationship_value is Dictionary):
			continue

		var relationship: Dictionary = relationship_value.duplicate(true)
		if not bool(relationship.get("met", false)):
			continue

		var target_id := String(relationship.get("other_id", relationship_key)).strip_edges()
		if target_id.is_empty() or target_id == npc_relationship_id or target_id == player_relationship_id:
			continue

		var live_target := _resolve_gossip_target(relationship, target_id)
		if live_target == target_npc or live_target == player:
			continue
		if live_target != null and not live_target.is_in_group("npc"):
			continue

		candidates.append({
			"id": target_id,
			"label": _get_gossip_target_label(relationship, live_target, target_id),
			"favor": float(relationship.get("favor", 50.0)),
			"relationship": relationship,
			"node": live_target,
		})

	candidates.sort_custom(Callable(self, "_sort_gossip_candidates_by_label"))
	return candidates


func _get_gossip_candidate_for_option(selected_index: int) -> Dictionary:
	if selected_index < 0 or selected_index >= option_actions.size():
		return {}

	var candidate_index := (gossip_page_index * option_actions.size()) + selected_index
	if candidate_index < 0 or candidate_index >= gossip_candidates.size():
		return {}

	return gossip_candidates[candidate_index].duplicate(true)


func _get_gossip_page_count() -> int:
	if gossip_candidates.is_empty() or option_actions.is_empty():
		return 0

	return int(ceil(float(gossip_candidates.size()) / float(option_actions.size())))


func _get_gossip_candidate_option_text(candidate: Dictionary) -> String:
	var label := String(candidate.get("label", "NPC"))
	var favor := float(candidate.get("favor", 50.0))
	return "%s  favor %.0f" % [label, favor]


func _sort_gossip_candidates_by_label(first: Dictionary, second: Dictionary) -> bool:
	return String(first.get("label", "")) < String(second.get("label", ""))


func _apply_interaction_effects(
	target_npc: Node2D,
	effect_delta: Dictionary,
	effect_set_values: Dictionary,
	effect_interaction_id: StringName
) -> void:
	_mark_player_npc_met(target_npc, effect_interaction_id)
	if effect_interaction_id == &"talk_flirt":
		effect_delta = _apply_flirt_favor_modifier(target_npc, effect_delta)
	effect_delta = _limit_flirt_love_gain(
		target_npc,
		effect_delta,
		effect_interaction_id
	)
	var receiver := _get_event_receiver(target_npc)
	var machine := _get_machine(target_npc)
	var relationship_context := {
		"source": "player_talk_dialogue",
		"interaction_id": String(effect_interaction_id),
	}

	if receiver != null and not effect_delta.is_empty():
		receiver.call(
			"apply_social_event",
			effect_delta,
			player,
			false,
			"player_talk_dialogue",
			relationship_context
		)
	elif machine != null and not effect_delta.is_empty():
		machine.apply_value_delta(effect_delta, player)

	var split_set_values := SocialStateSchema.split_value_delta(
		effect_set_values
	)
	var local_set_values: Dictionary = split_set_values.get(
		"local_values", {}
	)
	if machine != null:
		for value_key in local_set_values.keys():
			machine.set_value(
				StringName(String(value_key)),
				float(local_set_values[value_key]),
				player,
				evaluate_set_value_reactions
			)

	var directed_set_values: Dictionary = split_set_values.get(
		"directed_opinion", {}
	)
	var relationships := _get_relationship_system()
	if (
		not directed_set_values.is_empty()
		and relationships != null
		and relationships.has_method("set_opinion_metric")
	):
		for value_key in directed_set_values.keys():
			relationships.call(
				"set_opinion_metric",
				target_npc,
				player,
				StringName(String(value_key)),
				float(directed_set_values[value_key]),
				"player_interaction_absolute",
				{"interaction_id": String(effect_interaction_id)}
			)

	if target_npc.has_method("on_player_npc_interaction"):
		target_npc.call(
			"on_player_npc_interaction",
			player,
			effect_interaction_id,
			effect_delta,
			effect_set_values
		)


func _limit_flirt_love_gain(
	target_npc: Node2D,
	effect_delta: Dictionary,
	effect_interaction_id: StringName
) -> Dictionary:
	var limited_delta := effect_delta.duplicate(true)
	if effect_interaction_id != &"talk_flirt" or not limited_delta.has("love"):
		return limited_delta
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("get_opinion_metric"):
		return limited_delta
	var requested_love_delta := float(limited_delta["love"])
	if requested_love_delta <= 0.0:
		return limited_delta
	var current_love := float(relationships.call(
		"get_opinion_metric",
		target_npc,
		player,
		&"love",
		0.0
	))
	var remaining_gain := FLIRT_LOVE_GAIN_LIMIT - current_love
	if remaining_gain <= 0.0:
		limited_delta.erase("love")
		return limited_delta
	limited_delta["love"] = minf(
		requested_love_delta,
		remaining_gain
	)
	if is_zero_approx(float(limited_delta["love"])):
		limited_delta.erase("love")
	return limited_delta


func _apply_flirt_favor_modifier(
	target_npc: Node2D,
	opinion_delta: Dictionary
) -> Dictionary:
	var modified_delta := opinion_delta.duplicate(true)
	if not modified_delta.has("love"):
		return modified_delta
	var current_favor := _get_relationship_opinion_metric(
		target_npc,
		&"favor",
		50.0
	)
	var resolved_love_delta := resolve_flirt_love_delta(
		float(modified_delta["love"]),
		current_favor
	)
	if is_zero_approx(resolved_love_delta):
		modified_delta.erase("love")
	else:
		modified_delta["love"] = resolved_love_delta
	return modified_delta


static func resolve_flirt_love_delta(authored_delta: float, favor: float) -> float:
	var safe_favor := clampf(favor, 0.0, 100.0)
	if safe_favor <= 10.0:
		return authored_delta - 2.0
	if safe_favor < 40.0:
		return authored_delta - 1.0
	if safe_favor > 70.0 and authored_delta > 0.0:
		return authored_delta * 2.0
	return authored_delta


func _get_relationship_opinion_metric(
	target_npc: Node2D,
	metric_id: StringName,
	fallback: float
) -> float:
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("get_opinion_metric"):
		return fallback
	return float(relationships.call(
		"get_opinion_metric",
		target_npc,
		player,
		metric_id,
		fallback
	))


func _try_start_immediate_insult_fight(
	source_option_index: int,
	selected_interaction_id: StringName
) -> bool:
	var target_npc := menu_target_npc
	if target_npc == null or not is_instance_valid(target_npc):
		return false
	var profile := _get_player_talk_dialogue_profile(target_npc)
	if profile == null:
		return false
	var current_anger := _get_relationship_opinion_metric(
		target_npc,
		&"anger",
		0.0
	)
	if not profile.should_auto_start_insult_fight(current_anger):
		return false

	var effect_delta := _get_talk_option_delta(source_option_index)
	# The skipped high-anger response behaves like the ladder's full-escalation
	# answer, while preserving any other authored Insult consequences.
	effect_delta["anger"] = 10.0
	effect_delta["favor"] = -4.0
	_end_target_menu_hold(target_npc)
	_close_menu(false)
	interaction_started.emit(player, target_npc, selected_interaction_id)
	_apply_interaction_effects(
		target_npc,
		effect_delta,
		set_values.duplicate(true),
		selected_interaction_id
	)
	var fight_started := _request_insult_fight(
		target_npc,
		profile,
		&"auto_fight"
	)
	interaction_applied.emit(player, target_npc, selected_interaction_id)
	if not fight_started:
		interaction_blocked.emit(
			player,
			target_npc,
			selected_interaction_id,
			"player_insult_fight_unavailable"
		)
	_start_target_interaction_cooldown(target_npc)
	cooldown = cooldown_seconds
	return true


func _get_completed_insult_fight_trigger(
	target_npc: Node2D,
	profile: NpcPlayerTalkDialogueProfile,
	interaction_id_value: StringName,
	insult_action: StringName
) -> StringName:
	if (
		interaction_id_value != &"talk_insult"
		or target_npc == null
		or profile == null
	):
		return &""
	var current_anger := _get_relationship_opinion_metric(
		target_npc,
		&"anger",
		0.0
	)
	if profile.should_auto_start_insult_fight(current_anger):
		return &"auto_fight"
	if (
		insult_action == INSULT_ACTION_CHALLENGE_FIGHT
		and profile.should_offer_insult_fight(current_anger)
	):
		return &"challenge_fight"
	return &""


func _request_insult_fight(
	target_npc: Node2D,
	profile: NpcPlayerTalkDialogueProfile,
	trigger: StringName
) -> bool:
	if (
		target_npc == null
		or not is_instance_valid(target_npc)
		or player == null
		or not is_instance_valid(player)
		or profile == null
	):
		return false
	var context := {
		"source": "player_talk_insult",
		"trigger": String(trigger),
		"anger": _get_relationship_opinion_metric(target_npc, &"anger", 0.0),
		"profile": profile,
	}
	# A custom NPC script can fully replace the default transition by implementing
	# this method. Returning false deliberately refuses/redirects the Fight.
	if target_npc.has_method("handle_player_insult_fight_request"):
		return bool(target_npc.call(
			"handle_player_insult_fight_request",
			player,
			trigger,
			context
		))

	var machine := _get_machine(target_npc)
	if machine == null:
		return false
	if machine.is_primary_state(&"Fight"):
		return true
	if not machine.can_start_fight_with(player):
		return false
	return machine.request_state(
		&"Fight",
		player,
		"player_insult_%s" % String(trigger),
		profile.insult_fight_priority
	)


func _request_social_interaction_acceptance(
	target_npc: Node2D,
	prepay_talk_reward: bool = skip_requested_talk_state_need_payout
) -> Dictionary:
	# The menu gate has already validated range and identity. Reserve Talk before any effects run.
	if target_npc == null or not is_instance_valid(target_npc):
		return {"accepted": false, "reason": "invalid_target"}
	if player == null or not is_instance_valid(player):
		return {"accepted": false, "reason": "invalid_player"}
	var block_reason := _get_block_reason(target_npc)
	if not block_reason.is_empty():
		return {"accepted": false, "reason": block_reason}
	if not request_talk_state:
		return {"accepted": true, "reason": ""}

	var machine := _get_machine(target_npc)
	if machine == null:
		# Legacy SocialNpc receivers without a state machine keep their existing direct-effect behavior.
		return {"accepted": true, "reason": ""}

	var bypass_social_talk_refusal := bool(_active_player_talk.get(
		"bypass_social_talk_refusal",
		false
	))
	var talk_context := {}
	if bypass_social_talk_refusal:
		talk_context = {
			"purpose": &"player_insult_confrontation",
			"bypass_social_talk_refusal": true,
		}
	if not machine.request_talk(
		player,
		-1,
		true,
		&"player",
		talk_context
	):
		var rejection_reason := "talk_request_rejected"
		if machine.has_method("get_last_state_request_failure_reason"):
			var machine_reason := String(machine.call("get_last_state_request_failure_reason"))
			if not machine_reason.is_empty():
				rejection_reason = machine_reason
		return {"accepted": false, "reason": rejection_reason}

	if prepay_talk_reward:
		machine.mark_next_talk_need_payout_applied()
	return {"accepted": true, "reason": ""}


func _reject_social_interaction(
	target_npc: Node2D,
	requested_action: StringName,
	rejection_reason: String
) -> void:
	if OS.is_debug_build():
		print(
			"Social interaction rejected: npc=%s action=%s reason=%s" % [
				_get_npc_label(target_npc),
				String(requested_action),
				rejection_reason,
			]
		)
	interaction_blocked.emit(player, target_npc, requested_action, rejection_reason)
	_finish_menu_attempt("", false)
	cooldown = cooldown_seconds


func _get_pressed_option_index() -> int:
	for index in option_actions.size():
		var action: StringName = option_actions[index]
		if action == &"":
			continue
		if not InputMap.has_action(action):
			continue
		if Input.is_action_just_pressed(action):
			return index

	return -1


func _tick_menu_timer(delta: float) -> void:
	if menu_timer <= 0.0:
		return

	menu_timer = maxf(menu_timer - delta, 0.0)
	if menu_timer > 0.0:
		return

	if active_menu == MENU_NPC_PROMPT:
		_finish_npc_prompt(false, "prompt_timeout")
		return

	_finish_menu_attempt("interaction_timeout", true)


func _update_open_menu() -> void:
	var invalidation_reason := _get_open_menu_invalidation_reason()
	if invalidation_reason.is_empty():
		return
	if invalidation_reason == "target_left":
		if active_menu == MENU_NPC_PROMPT:
			_finish_npc_prompt(false, "target_left")
			return
		_finish_menu_attempt("target_left", true)
		return

	_invalidate_open_menu(invalidation_reason)


func _finish_npc_prompt(accepted: bool, reason: String = "") -> void:
	if active_menu != MENU_NPC_PROMPT:
		_close_menu()
		return
	if prompt_completed:
		return

	prompt_completed = true
	var target_npc := menu_target_npc
	var callback_target := prompt_callback_target
	var callback_method := prompt_accept_method if accepted else prompt_decline_method
	var callback_prompt_id := prompt_id

	if (
		not reason.is_empty()
		and target_npc != null
		and is_instance_valid(target_npc)
	):
		interaction_blocked.emit(player, target_npc, callback_prompt_id, reason)

	if (
		callback_target != null
		and is_instance_valid(callback_target)
		and callback_method != &""
		and callback_target.has_method(callback_method)
		and target_npc != null
		and is_instance_valid(target_npc)
		and player != null
		and is_instance_valid(player)
	):
		callback_target.call(callback_method, target_npc, player, callback_prompt_id)
	if (
		accepted
		and reason.is_empty()
		and target_npc != null
		and is_instance_valid(target_npc)
	):
		_mark_player_npc_met(target_npc, callback_prompt_id)

	if target_npc != null and is_instance_valid(target_npc):
		_end_target_menu_hold(target_npc)
	_close_menu(false)
	cooldown = cooldown_seconds


func _finish_menu_attempt(reason: String, apply_npc_cooldown: bool) -> void:
	var target_npc := menu_target_npc
	if target_npc != null and is_instance_valid(target_npc):
		if not reason.is_empty():
			interaction_blocked.emit(player, target_npc, interaction_id, reason)
		if apply_npc_cooldown:
			_end_target_menu_hold(target_npc)
			_start_target_interaction_cooldown(target_npc)
		else:
			_end_target_menu_hold(target_npc)

	_close_menu(false)


func _menu_target_is_still_valid() -> bool:
	return _get_open_menu_invalidation_reason().is_empty()


func _get_open_menu_invalidation_reason() -> String:
	if active_menu == MENU_CLOSED:
		return ""
	if (
		menu_layer == null
		or not is_instance_valid(menu_layer)
		or menu_panel == null
		or not is_instance_valid(menu_panel)
	):
		return "interaction_ui_missing"
	if player == null or not is_instance_valid(player):
		return "invalid_player"
	if menu_target_npc == null or not is_instance_valid(menu_target_npc):
		return "target_left"
	if not _is_valid_npc_candidate(menu_target_npc):
		return "target_left"
	if player.global_position.distance_to(menu_target_npc.global_position) > max_distance:
		return "target_left"

	return _get_block_reason(menu_target_npc)


func _menu_is_open() -> bool:
	return active_menu != MENU_CLOSED


func _close_menu(release_target_hold: bool = true) -> void:
	if release_target_hold and menu_target_npc != null and is_instance_valid(menu_target_npc):
		_end_target_menu_hold(menu_target_npc)

	active_menu = MENU_CLOSED
	menu_timer = 0.0
	current_menu_option_count = 0
	talk_menu_source_indices.clear()
	menu_confrontation_only = false
	menu_target_npc = null
	_clear_prompt_state()
	if menu_layer != null and is_instance_valid(menu_layer):
		menu_layer.visible = false
	if menu_panel != null and is_instance_valid(menu_panel):
		menu_panel.visible = false
	_unwatch_target_interaction_gate()
	if (
		nearby_npcs.is_empty()
		and player != null
		and is_instance_valid(player)
		and player.has_method("unregister_interaction_candidate")
	):
		player.call("unregister_interaction_candidate", self)


func close_for_scripted_handoff() -> bool:
	if not _menu_is_open():
		return false
	if menu_target_npc != null and is_instance_valid(menu_target_npc):
		_end_target_menu_hold(menu_target_npc)
	elif menu_hold_machine != null and is_instance_valid(menu_hold_machine):
		menu_hold_machine.end_player_interaction_hold(player)
	_close_menu(false)
	cooldown = 0.0
	return true


func _try_begin_modal_dialogue(definition: DialogueDefinition) -> void:
	var target_npc := menu_target_npc
	if target_npc == null or not is_instance_valid(target_npc):
		_close_menu()
		return
	var controller := get_node_or_null("/root/DialogueController")
	if controller == null or not controller.has_method("begin_dialogue"):
		interaction_blocked.emit(player, target_npc, &"dialogue", "dialogue_controller_missing")
		_show_interaction_menu("Dialogue is unavailable.")
		return

	# The interaction menu owns a temporary NPC hold. End that hold without effects or
	# cooldown before the modal controller acquires its stronger tokenized ownership.
	close_for_scripted_handoff()
	var result: Dictionary = controller.call("begin_dialogue", player, target_npc, definition)
	if bool(result.get("accepted", false)):
		_mark_player_npc_met(target_npc, &"dialogue")
		interaction_started.emit(player, target_npc, &"dialogue")
		return

	var reason := String(result.get("reason", "dialogue_rejected"))
	interaction_blocked.emit(player, target_npc, &"dialogue", reason)
	if (
		player != null
		and is_instance_valid(player)
		and target_npc != null
		and is_instance_valid(target_npc)
		and _is_valid_npc_candidate(target_npc)
		and player.global_position.distance_to(target_npc.global_position) <= max_distance
	):
		menu_target_npc = target_npc
		active_menu = MENU_INTERACTION
		_show_interaction_menu("Dialogue unavailable: %s" % reason.replace("_", " "))
	cooldown = 0.0


func _get_dialogue_definition(target_npc: Node) -> DialogueDefinition:
	if target_npc == null or not is_instance_valid(target_npc):
		return null
	if not target_npc.has_meta(DEFAULT_DIALOGUE_METADATA):
		return null
	var definition := target_npc.get_meta(DEFAULT_DIALOGUE_METADATA) as DialogueDefinition
	if definition == null or not definition.get_validation_error().is_empty():
		return null
	return definition


func _player_gameplay_control_is_claimed() -> bool:
	return (
		player != null
		and is_instance_valid(player)
		and player.has_method("is_gameplay_control_claimed")
		and bool(player.call("is_gameplay_control_claimed"))
	)


func _clear_prompt_state() -> void:
	prompt_id = &""
	prompt_callback_target = null
	prompt_accept_method = &""
	prompt_decline_method = &""
	prompt_completed = false


func _begin_target_menu_hold(target_npc: Node2D, hold_seconds: float = -1.0) -> Dictionary:
	if target_npc == null or not is_instance_valid(target_npc):
		return {"accepted": false, "reason": "invalid_target"}

	var gate := _get_authoritative_interaction_gate(target_npc)
	if not bool(gate.get("accepted", false)):
		return gate

	var hold_duration := menu_choice_timeout_seconds if hold_seconds < 0.0 else hold_seconds
	if target_npc.has_method("begin_player_interaction_hold"):
		if not bool(target_npc.call("begin_player_interaction_hold", player, hold_duration)):
			return {"accepted": false, "reason": "interaction_hold_rejected"}
		_watch_target_interaction_gate(target_npc)
		return {"accepted": true, "reason": ""}

	var machine := _get_machine(target_npc)
	if machine != null and machine.has_method("begin_player_interaction_hold"):
		if not bool(machine.call(
			"begin_player_interaction_hold",
			player,
			hold_duration,
			bool(gate.get("confrontation_only", false))
		)):
			var retry_gate := _get_authoritative_interaction_gate(target_npc)
			if not bool(retry_gate.get("accepted", false)):
				return retry_gate
			return {"accepted": false, "reason": "interaction_hold_rejected"}
		_watch_target_interaction_gate(target_npc)
		return {"accepted": true, "reason": ""}

	return {"accepted": true, "reason": ""}


func _end_target_menu_hold(target_npc: Node2D) -> void:
	if target_npc == null or not is_instance_valid(target_npc):
		return

	if target_npc.has_method("end_player_interaction_hold"):
		target_npc.call("end_player_interaction_hold", player)
		return

	var machine := _get_machine(target_npc)
	if machine != null and machine.has_method("end_player_interaction_hold"):
		machine.call("end_player_interaction_hold", player)


func _watch_target_interaction_gate(target_npc: Node2D) -> void:
	var machine := _get_machine(target_npc)
	if machine == menu_hold_machine:
		return

	_unwatch_target_interaction_gate()
	menu_hold_machine = machine
	if menu_hold_machine == null:
		return
	if not menu_hold_machine.player_interaction_invalidated.is_connected(
		_on_target_interaction_invalidated
	):
		menu_hold_machine.player_interaction_invalidated.connect(
			_on_target_interaction_invalidated
		)


func _unwatch_target_interaction_gate() -> void:
	if menu_hold_machine != null and is_instance_valid(menu_hold_machine):
		if menu_hold_machine.player_interaction_invalidated.is_connected(
			_on_target_interaction_invalidated
		):
			menu_hold_machine.player_interaction_invalidated.disconnect(
				_on_target_interaction_invalidated
			)
	menu_hold_machine = null


func _on_target_interaction_invalidated(reason: String) -> void:
	if not _menu_is_open():
		return

	_invalidate_open_menu(reason)


func _invalidate_open_menu(reason: String) -> void:
	var target_npc := menu_target_npc
	if target_npc != null and is_instance_valid(target_npc):
		var blocked_interaction_id := prompt_id if active_menu == MENU_NPC_PROMPT else interaction_id
		interaction_blocked.emit(player, target_npc, blocked_interaction_id, reason)
		_end_target_menu_hold(target_npc)
	_close_menu(false)
	cooldown = cooldown_seconds


func _start_target_interaction_cooldown(target_npc: Node2D) -> void:
	if target_npc == null or not is_instance_valid(target_npc):
		return

	if target_npc.has_method("start_player_interaction_cooldown"):
		target_npc.call(
			"start_player_interaction_cooldown",
			player,
			npc_interaction_cooldown_seconds
		)
		return

	var machine := _get_machine(target_npc)
	if machine != null and machine.has_method("start_player_interaction_cooldown"):
		machine.call(
			"start_player_interaction_cooldown",
			player,
			npc_interaction_cooldown_seconds
		)


func _target_is_ignoring_player_interaction(target_npc: Node2D) -> bool:
	if target_npc == null or not is_instance_valid(target_npc):
		return false

	if target_npc.has_method("is_ignoring_player_interaction"):
		return bool(target_npc.call("is_ignoring_player_interaction", player))

	var machine := _get_machine(target_npc)
	if machine != null and machine.has_method("is_ignoring_player_interaction"):
		return bool(machine.call("is_ignoring_player_interaction", player))

	return false


func _get_closest_npc() -> Node2D:
	# Chooses the nearest tracked NPC body inside max_distance.
	var closest: Node2D = null
	var closest_distance := INF

	for npc in nearby_npcs:
		if not _is_valid_npc_candidate(npc):
			continue

		var distance := player.global_position.distance_to(npc.global_position)
		if distance > max_distance:
			continue

		if distance < closest_distance:
			closest_distance = distance
			closest = npc

	return closest


func _is_valid_npc_candidate(candidate: Node2D) -> bool:
	# Rejects missing/self bodies and accepts only configured NPC groups.
	if player == null or not is_instance_valid(player):
		return false

	if candidate == null or not is_instance_valid(candidate):
		return false

	if candidate == player:
		return false

	for group_name in npc_groups:
		if candidate.is_in_group(String(group_name)):
			return true

	return false


func _get_block_reason(target_npc: Node2D) -> String:
	# Central place for future gates like NPC id, tags, schedule, or custom methods.
	var authoritative_gate := _get_authoritative_interaction_gate(target_npc)
	return _get_block_reason_with_authoritative_gate(target_npc, authoritative_gate)


func _get_block_reason_with_authoritative_gate(
	target_npc: Node2D,
	authoritative_gate: Dictionary
) -> String:
	if not bool(authoritative_gate.get("accepted", false)):
		return String(authoritative_gate.get("reason", "npc_gate_rejected"))
	var favor_bypass := StringName(authoritative_gate.get(
		"favor_bypass",
		&""
	))
	if favor_bypass == &"all":
		return ""

	if (
		favor_bypass == &""
		and _target_is_ignoring_player_interaction(target_npc)
	):
		return "npc_ignoring_player"

	if not _npc_id_is_allowed(target_npc):
		return "npc_id_not_allowed"

	if not _npc_has_required_tags(target_npc):
		return "missing_required_tags"

	if target_npc.has_method("can_receive_player_interaction"):
		if not bool(target_npc.call("can_receive_player_interaction", player, interaction_id)):
			return "npc_gate_rejected"

	return ""


func _get_authoritative_interaction_gate(target_npc: Node2D) -> Dictionary:
	if target_npc == null or not is_instance_valid(target_npc):
		return {"accepted": false, "reason": "invalid_target"}

	var machine := _get_machine(target_npc)
	if machine == null or not machine.has_method("can_begin_player_interaction"):
		return {"accepted": true, "reason": ""}
	if menu_confrontation_only and target_npc == menu_target_npc:
		var active_confrontation_result = machine.call(
			"can_begin_player_interaction",
			player,
			true
		)
		if active_confrontation_result is Dictionary:
			var typed_confrontation: Dictionary = active_confrontation_result
			if bool(typed_confrontation.get("accepted", false)):
				typed_confrontation = typed_confrontation.duplicate(true)
				typed_confrontation["confrontation_only"] = true
				typed_confrontation["favor_bypass"] = &"confrontation"
			return typed_confrontation
		return {"accepted": bool(active_confrontation_result), "reason": ""}

	var result = machine.call("can_begin_player_interaction", player)
	if result is Dictionary:
		var typed_result: Dictionary = result
		if bool(typed_result.get("accepted", false)):
			return typed_result
		var refusal_reason := String(typed_result.get("reason", ""))
		var profile := _get_player_talk_dialogue_profile(target_npc)
		if (
			INSULT_CONFRONTATION_SOCIAL_REASONS.has(refusal_reason)
			and profile != null
			and profile.insult_escalation_enabled
		):
			var confrontation_result = machine.call(
				"can_begin_player_interaction",
				player,
				true
			)
			if (
				confrontation_result is Dictionary
				and bool(confrontation_result.get("accepted", false))
			):
				var accepted_confrontation: Dictionary = confrontation_result.duplicate(true)
				accepted_confrontation["confrontation_only"] = true
				accepted_confrontation["social_refusal_reason"] = refusal_reason
				accepted_confrontation["favor_bypass"] = &"confrontation"
				return accepted_confrontation
		return typed_result
	if bool(result):
		return {"accepted": true, "reason": ""}

	return {"accepted": false, "reason": "npc_gate_rejected"}


func _npc_id_is_allowed(target_npc: Node2D) -> bool:
	# Optional whitelist for interactions that should only work with named NPCs.
	if allowed_npc_ids.is_empty():
		return true

	var npc_id := _get_npc_id(target_npc)
	for allowed_id in allowed_npc_ids:
		if String(allowed_id) == String(npc_id):
			return true

	return false


func _npc_has_required_tags(target_npc: Node2D) -> bool:
	# Optional tag requirement for interactions like "family only" or "worker only".
	if required_npc_tags.is_empty():
		return true

	for required_tag in required_npc_tags:
		if _npc_has_tag(target_npc, required_tag):
			continue

		return false

	return true


func _npc_has_tag(target_npc: Node2D, tag: StringName) -> bool:
	# Checks both Godot groups and SocialNpc's npc_tags metadata.
	var tag_text := String(tag)
	if target_npc.is_in_group(tag_text):
		return true

	if not target_npc.has_meta("npc_tags"):
		return false

	var npc_tags = target_npc.get_meta("npc_tags")
	if not (npc_tags is Array):
		return false

	for npc_tag in npc_tags:
		if String(npc_tag) == tag_text:
			return true

	return false


func _get_npc_id(target_npc: Node2D) -> StringName:
	# Uses stable location ids when available, otherwise falls back to node name.
	if target_npc.has_method("get_npc_location_id"):
		return StringName(String(target_npc.call("get_npc_location_id")))

	if target_npc.has_meta("npc_location_id"):
		return StringName(String(target_npc.get_meta("npc_location_id")))

	return StringName(String(target_npc.name))


func _get_npc_label(target_npc: Node) -> String:
	if target_npc == null or not is_instance_valid(target_npc):
		return "NPC"

	if target_npc.has_method("get_display_name"):
		var display_name := String(target_npc.call("get_display_name"))
		if not display_name.is_empty():
			return display_name

	return String(target_npc.name)


func _resolve_gossip_target(relationship: Dictionary, target_id: String) -> Node2D:
	var other_path := String(relationship.get("other_path", ""))
	if not other_path.is_empty():
		var path_target := get_node_or_null(NodePath(other_path)) as Node2D
		if path_target != null and is_instance_valid(path_target):
			return path_target

	if not is_inside_tree():
		return null

	for candidate in get_tree().get_nodes_in_group("npc"):
		var candidate_node := candidate as Node2D
		if candidate_node == null or not is_instance_valid(candidate_node):
			continue
		if _get_relationship_id_for_node(candidate_node) == target_id:
			return candidate_node

	return null


func _get_gossip_target_label(relationship: Dictionary, target: Node, target_id: String) -> String:
	var relationship_name := String(relationship.get("other_name", ""))
	if not relationship_name.is_empty():
		return relationship_name

	if target != null and is_instance_valid(target):
		return _get_npc_label(target)

	return target_id


func _call_gossip_hook(target_npc: Node2D, gossip_subject: Dictionary, effect_delta: Dictionary) -> void:
	if target_npc == null or not is_instance_valid(target_npc):
		return
	if not target_npc.has_method("on_player_npc_gossip_interaction"):
		return

	target_npc.call(
		"on_player_npc_gossip_interaction",
		player,
		gossip_subject.duplicate(true),
		effect_delta.duplicate(true)
	)


func _get_relationship_id_for_node(target: Node) -> String:
	if target == null or not is_instance_valid(target):
		return ""

	var relationships := _get_relationship_system()
	if relationships != null and relationships.has_method("get_relationship_id"):
		return String(relationships.call("get_relationship_id", target))
	return NpcIdentity.get_actor_id(target, true)


func _get_relationship_system() -> Node:
	if not is_inside_tree():
		return null

	return get_node_or_null("/root/Relationships")


func _mark_player_npc_met(
	target_npc: Node,
	interaction_kind: StringName
) -> void:
	if (
		target_npc == null
		or not is_instance_valid(target_npc)
		or player == null
		or not is_instance_valid(player)
	):
		return
	# Persistence-backed character menus must never learn generated path/instance
	# identities. A successful interaction with a legacy identity-free actor still
	# runs normally; it simply cannot become a durable known-character entry.
	if (
		NpcIdentity.get_stable_actor_id(target_npc).is_empty()
		or NpcIdentity.get_stable_actor_id(player).is_empty()
	):
		return
	var relationships := _get_relationship_system()
	if relationships == null or not relationships.has_method("meet"):
		return
	var starting_favor := -1.0
	if NpcIdentity.has_property(target_npc, &"default_relationship_favor"):
		starting_favor = float(target_npc.get("default_relationship_favor"))
	relationships.call(
		"meet",
		target_npc,
		player,
		starting_favor,
		0.0,
		{
			"reason": "player_interaction:%s" % String(interaction_kind),
			"scope": "direct",
		}
	)


func _get_event_receiver(target_npc: Node) -> Node:
	# SocialNpc receives social events directly; plain machines can receive value deltas.
	if target_npc.has_method("apply_social_event"):
		return target_npc

	return _get_machine(target_npc)


func _get_machine(target_npc: Node) -> NpcStateMachine:
	# Accepts either the state machine itself or an NPC body with a child machine.
	var machine := target_npc as NpcStateMachine
	if machine != null:
		return machine

	return target_npc.get_node_or_null("NpcStateMachine") as NpcStateMachine


func _on_body_entered(body: Node2D) -> void:
	# Tracks nearby bodies; filtering happens when the player presses the action.
	if nearby_npcs.has(body):
		return

	nearby_npcs.append(body)
	if player != null and is_instance_valid(player) and player.has_method("register_interaction_candidate"):
		player.call("register_interaction_candidate", self)


func _on_body_exited(body: Node2D) -> void:
	# Removes bodies that leave the interaction area.
	nearby_npcs.erase(body)
	if (
		nearby_npcs.is_empty()
		and not _menu_is_open()
		and player != null
		and is_instance_valid(player)
		and player.has_method("unregister_interaction_candidate")
	):
		player.call("unregister_interaction_candidate", self)
	if close_menu_when_target_exits and body == menu_target_npc:
		if active_menu == MENU_NPC_PROMPT:
			_finish_npc_prompt(false, "target_left")
			return
		_close_menu()
