class_name PlayerNpcTalkInteractor extends Area2D

signal interaction_started(player: Node2D, npc: Node2D, interaction_id: StringName)
signal interaction_applied(player: Node2D, npc: Node2D, interaction_id: StringName)
signal interaction_blocked(player: Node2D, npc: Node2D, interaction_id: StringName, reason: String)

const MENU_CLOSED := &""
const MENU_INTERACTION := &"interaction"
const MENU_TALK := &"talk"
const MENU_GOSSIP := &"gossip"
const MENU_NPC_PROMPT := &"npc_prompt"

@export_group("Interaction")
@export var interaction_action: StringName = &"up"
@export var interaction_id: StringName = &"talk"
@export var cooldown_seconds: float = 0.35
@export var max_distance: float = 120.0
@export var npc_groups: Array[StringName] = [&"npc"]

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
	"Friendly check-in",
	"Tell a joke",
	"Comfort",
	"Gossip",
	"Awkward question"
]
@export_range(1, 5, 1) var gossip_talk_option_number: int = 4
@export var talk_option_deltas: Array[Dictionary] = [
	{
		"talk_need": -35.0,
		"boredom": -8.0,
		"trust": 2.0
	},
	{
		"boredom": -20.0,
		"curiosity": 5.0,
		"trust": 1.0
	},
	{
		"sadness": -15.0,
		"lonely": -10.0,
		"trust": 4.0
	},
	{
		"curiosity": 10.0,
		"suspicion": 5.0,
		"talk_need": -20.0
	},
	{
		"trust": -3.0,
		"suspicion": 7.0,
		"boredom": -5.0
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


func _ready() -> void:
	player = get_parent() as Node2D
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


func _process(delta: float) -> void:
	cooldown = maxf(cooldown - delta, 0.0)

	if _menu_is_open():
		_tick_menu_timer(delta)
		if not _menu_is_open():
			return

		_update_open_menu()
		if not _menu_is_open():
			return

		if _handle_menu_navigation_input():
			return

		_handle_menu_option_input()
		return

	if cooldown > 0.0:
		return

	if not Input.is_action_just_pressed(interaction_action):
		return
	if _player_is_at_active_work_spot():
		return

	_try_open_interaction_menu()


func _player_is_at_active_work_spot() -> bool:
	# Work has contextual priority when Up could otherwise trigger work and talk together.
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return false
	for spot_node in player.get_tree().get_nodes_in_group("npc_work_spot"):
		var spot := spot_node as Area2D
		if spot == null or not is_instance_valid(spot):
			continue
		if not spot.has_method("can_player_work"):
			continue
		if not bool(spot.call("can_player_work", player)):
			continue
		if spot.overlaps_body(player):
			return true
	return false


func _try_open_interaction_menu() -> void:
	var target_npc := _get_closest_npc()
	if target_npc == null:
		return

	var block_reason := _get_block_reason(target_npc)
	if not block_reason.is_empty():
		interaction_blocked.emit(player, target_npc, interaction_id, block_reason)
		return
	menu_target_npc = target_npc
	active_menu = MENU_INTERACTION
	_begin_target_menu_hold(target_npc)
	_show_interaction_menu("")
	cooldown = cooldown_seconds


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
	if timeout_seconds >= 0.0:
		menu_timer = timeout_seconds
		_begin_target_menu_hold(npc, timeout_seconds)
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
	menu_target_can_trade = (
		menu_target_npc != null
		and menu_target_npc.has_method("can_trade_with_player")
		and bool(menu_target_npc.call("can_trade_with_player", player))
	)
	var options := PackedStringArray(["Talk"])
	interaction_menu_actions = [&"talk"]
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
	_show_menu("Talk: %s" % npc_label, talk_option_texts, feedback)


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
		var page_text := "Up: next page %d/%d" % [gossip_page_index + 1, page_count]
		page_feedback = page_text if page_feedback.is_empty() else "%s | %s" % [page_feedback, page_text]

	_show_menu("Gossip about: %s" % npc_label, options, page_feedback)


func _show_menu(title: String, options: PackedStringArray, feedback: String) -> void:
	_ensure_menu_ui()
	if menu_layer == null or menu_panel == null or menu_title_label == null:
		return

	menu_layer.visible = true
	menu_panel.visible = true
	menu_timer = maxf(menu_choice_timeout_seconds, 0.0)
	_begin_target_menu_hold(menu_target_npc)
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

	if selected_action == &"trade":
		var target := menu_target_npc
		_close_menu()
		if target != null and target.has_method("try_open_trade") and bool(target.call("try_open_trade", player)):
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

	if selected_index == _get_gossip_talk_option_index():
		_open_gossip_menu()
		return

	var option_delta := _get_talk_option_delta(selected_index)
	var selected_interaction_id := StringName("talk_option_%d" % [selected_index + 1])
	interaction_started.emit(player, menu_target_npc, selected_interaction_id)
	_apply_interaction_effects(menu_target_npc, option_delta, set_values, selected_interaction_id)
	interaction_applied.emit(player, menu_target_npc, selected_interaction_id)
	_finish_menu_attempt("", true)
	cooldown = cooldown_seconds


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
	interaction_started.emit(player, menu_target_npc, selected_interaction_id)
	_apply_interaction_effects(menu_target_npc, option_delta, set_values, selected_interaction_id)
	_call_gossip_hook(menu_target_npc, gossip_subject, option_delta)
	interaction_applied.emit(player, menu_target_npc, selected_interaction_id)
	_finish_menu_attempt("", true)
	cooldown = cooldown_seconds


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
	var receiver := _get_event_receiver(target_npc)
	var machine := _get_machine(target_npc)

	if receiver != null and not effect_delta.is_empty():
		receiver.call("apply_social_event", effect_delta, player, false)
	elif machine != null and not effect_delta.is_empty():
		machine.apply_value_delta(effect_delta, player)

	if machine != null:
		for value_key in effect_set_values.keys():
			machine.set_value(
				StringName(String(value_key)),
				float(effect_set_values[value_key]),
				player,
				evaluate_set_value_reactions
			)

		if request_talk_state:
			var talk_started := machine.request_talk(player)
			if talk_started and skip_requested_talk_state_need_payout:
				machine.mark_next_talk_need_payout_applied()

	if target_npc.has_method("on_player_npc_interaction"):
		target_npc.call(
			"on_player_npc_interaction",
			player,
			effect_interaction_id,
			effect_delta,
			effect_set_values
		)


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


func _handle_menu_navigation_input() -> bool:
	if active_menu != MENU_GOSSIP:
		return false
	if not InputMap.has_action(interaction_action):
		return false
	if not Input.is_action_just_pressed(interaction_action):
		return false

	var page_count := _get_gossip_page_count()
	if page_count <= 1:
		return false

	gossip_page_index = (gossip_page_index + 1) % page_count
	_show_gossip_menu("")
	return true


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
	if not _menu_target_is_still_valid():
		if active_menu == MENU_NPC_PROMPT:
			_finish_npc_prompt(false, "target_left")
			return
		_finish_menu_attempt("target_left", true)


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
	if active_menu == MENU_CLOSED:
		return true
	if player == null or not is_instance_valid(player):
		return false
	if menu_target_npc == null or not is_instance_valid(menu_target_npc):
		return false
	if not _is_valid_npc_candidate(menu_target_npc):
		return false

	return player.global_position.distance_to(menu_target_npc.global_position) <= max_distance


func _menu_is_open() -> bool:
	return active_menu != MENU_CLOSED


func _close_menu(release_target_hold: bool = true) -> void:
	if release_target_hold and menu_target_npc != null and is_instance_valid(menu_target_npc):
		_end_target_menu_hold(menu_target_npc)

	active_menu = MENU_CLOSED
	menu_timer = 0.0
	current_menu_option_count = 0
	menu_target_npc = null
	_clear_prompt_state()
	if menu_layer != null and is_instance_valid(menu_layer):
		menu_layer.visible = false
	if menu_panel != null and is_instance_valid(menu_panel):
		menu_panel.visible = false


func _clear_prompt_state() -> void:
	prompt_id = &""
	prompt_callback_target = null
	prompt_accept_method = &""
	prompt_decline_method = &""
	prompt_completed = false


func _begin_target_menu_hold(target_npc: Node2D, hold_seconds: float = -1.0) -> void:
	if target_npc == null or not is_instance_valid(target_npc):
		return

	var hold_duration := menu_choice_timeout_seconds if hold_seconds < 0.0 else hold_seconds
	if target_npc.has_method("begin_player_interaction_hold"):
		target_npc.call("begin_player_interaction_hold", player, hold_duration)
		return

	var machine := _get_machine(target_npc)
	if machine != null and machine.has_method("begin_player_interaction_hold"):
		machine.call("begin_player_interaction_hold", player, hold_duration)


func _end_target_menu_hold(target_npc: Node2D) -> void:
	if target_npc == null or not is_instance_valid(target_npc):
		return

	if target_npc.has_method("end_player_interaction_hold"):
		target_npc.call("end_player_interaction_hold", player)
		return

	var machine := _get_machine(target_npc)
	if machine != null and machine.has_method("end_player_interaction_hold"):
		machine.call("end_player_interaction_hold", player)


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
	if _target_is_ignoring_player_interaction(target_npc):
		return "npc_ignoring_player"

	if not _npc_id_is_allowed(target_npc):
		return "npc_id_not_allowed"

	if not _npc_has_required_tags(target_npc):
		return "missing_required_tags"

	if target_npc.has_method("can_receive_player_interaction"):
		if not bool(target_npc.call("can_receive_player_interaction", player, interaction_id)):
			return "npc_gate_rejected"

	return ""


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

	if target.has_method("get_relationship_id"):
		return String(target.call("get_relationship_id"))
	if target.has_meta("relationship_id"):
		return String(target.get_meta("relationship_id"))
	if target.is_inside_tree():
		return String(target.get_path())

	return "instance:%s" % target.get_instance_id()


func _get_relationship_system() -> Node:
	if not is_inside_tree():
		return null

	return get_node_or_null("/root/Relationships")


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


func _on_body_exited(body: Node2D) -> void:
	# Removes bodies that leave the interaction area.
	nearby_npcs.erase(body)
	if close_menu_when_target_exits and body == menu_target_npc:
		if active_menu == MENU_NPC_PROMPT:
			_finish_npc_prompt(false, "target_left")
			return
		_close_menu()
