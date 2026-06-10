class_name CharacterStatsOverlay extends CanvasLayer

@export var toggle_action: StringName = &"stats"
@export var starts_visible: bool = false
@export var refresh_interval_seconds: float = 0.25
@export var show_player_stats: bool = true
@export var show_npc_stats: bool = true
@export var show_need_spots: bool = true
@export var max_decimal_places: int = 1
@export var stat_order: Array[String] = [
	"hp",
	"hunger",
	"sleep_need",
	"boredom",
	"talk_need",
	"lonely",
	"bored",
	"love",
	"favor",
	"trust",
	"fear",
	"anger",
	"sadness",
	"suspicion",
	"curiosity",
	"energy",
	"disabled"
]

@onready var panel: ColorRect = get_node_or_null("%StatsPanel") as ColorRect
@onready var stats_label: Label = get_node_or_null("%StatsText") as Label

var refresh_timer: float = 0.0


func _ready() -> void:
	layer = 90
	visible = starts_visible
	set_process(visible)
	set_process_unhandled_input(true)
	_update_stats_text()


func _unhandled_input(event: InputEvent) -> void:
	if toggle_action == &"" or not event.is_action_pressed(toggle_action):
		return

	visible = not visible
	set_process(visible)
	refresh_timer = 0.0
	if visible:
		_update_stats_text()


func _process(delta: float) -> void:
	refresh_timer -= delta
	if refresh_timer > 0.0:
		return

	refresh_timer = refresh_interval_seconds
	_update_stats_text()


func _update_stats_text() -> void:
	if stats_label == null:
		return

	var lines: Array[String] = ["SCENE STATS"]

	if show_player_stats:
		_append_player_lines(lines)

	if show_npc_stats:
		_append_npc_lines(lines)

	if show_need_spots:
		_append_need_spot_lines(lines)

	if lines.size() == 1:
		lines.append("no tracked characters")

	stats_label.text = "\n".join(lines)
	_resize_panel_to_text()
	_record_watchdog_marker(&"ui:stats_overlay", "%d lines" % lines.size())


func _append_player_lines(lines: Array[String]) -> void:
	var player := _get_first_group_node("player")
	if player == null:
		return

	lines.append("")
	lines.append("PLAYER")
	lines.append("state: %s" % _get_current_state_name(player))

	var player_values := {
		"hp": _get_property_if_present(player, &"hp"),
		"max_hp": _get_property_if_present(player, &"max_hp"),
		"mana": _get_property_if_present(player, &"mana_amount"),
		"mana_2": _get_property_if_present(player, &"mana_2_amount"),
	}
	_append_value_lines(lines, player_values)


func _append_npc_lines(lines: Array[String]) -> void:
	var npcs := get_tree().get_nodes_in_group("social_npc")
	npcs.sort_custom(Callable(self, "_sort_nodes_by_display_name"))

	for npc_node in npcs:
		var npc := npc_node as Node
		if npc == null or not is_instance_valid(npc):
			continue

		lines.append("")
		lines.append(_get_character_label(npc))
		lines.append("state: %s" % _get_current_state_name(npc))
		_append_value_lines(lines, _get_character_values(npc))


func _append_need_spot_lines(lines: Array[String]) -> void:
	var spots := get_tree().get_nodes_in_group("npc_need_spot")
	var spot_lines: Array[String] = []

	for spot_node in spots:
		var spot := spot_node as Node
		if spot == null or not is_instance_valid(spot):
			continue

		if not spot.has_method("is_work_spot") or not bool(spot.call("is_work_spot")):
			continue

		if not spot.has_method("get_work_needed"):
			continue

		var spot_name := String(spot.name)
		var work_needed := float(spot.call("get_work_needed"))
		spot_lines.append("%s work_needed: %s" % [spot_name, _format_value(work_needed)])

	if spot_lines.is_empty():
		return

	lines.append("")
	lines.append("WORK SPOTS")
	lines.append_array(spot_lines)


func _append_value_lines(lines: Array[String], values: Dictionary) -> void:
	var written_keys: Array[String] = []

	for key in stat_order:
		if not values.has(key):
			continue

		var value = values[key]
		if value == null:
			continue

		written_keys.append(key)
		lines.append("%s: %s" % [key, _format_value(value)])

	for value_key in values.keys():
		var key := String(value_key)
		if written_keys.has(key):
			continue

		var value = values[value_key]
		if value == null:
			continue

		lines.append("%s: %s" % [key, _format_value(value)])


func _get_character_values(character: Node) -> Dictionary:
	var machine := _get_machine(character)
	if machine != null:
		return machine.values.duplicate(true)

	var stats = _get_property_if_present(character, &"social_stats")
	if stats is Dictionary:
		return stats.duplicate(true)

	return {}


func _get_character_label(character: Node) -> String:
	var display_text := String(character.name)
	if character.has_method("get_display_name"):
		display_text = String(character.call("get_display_name"))

	var id_text := ""
	if character.has_method("get_npc_location_id"):
		id_text = String(character.call("get_npc_location_id"))
	elif character.has_meta("npc_location_id"):
		id_text = String(character.get_meta("npc_location_id"))

	if id_text.is_empty() or id_text == display_text:
		return display_text.to_upper()

	return "%s [%s]" % [display_text.to_upper(), id_text]


func _get_current_state_name(character: Node) -> String:
	var machine := _get_machine(character)
	if machine != null and machine.current_state != null:
		return String(machine.current_state.name)

	var current_state = _get_property_if_present(character, &"current_state")
	if current_state is Node:
		return String(current_state.name)

	return "--"


func _get_machine(character: Node) -> NpcStateMachine:
	var machine := character as NpcStateMachine
	if machine != null:
		return machine

	return character.get_node_or_null("NpcStateMachine") as NpcStateMachine


func _get_first_group_node(group_name: StringName) -> Node:
	var nodes := get_tree().get_nodes_in_group(group_name)
	if nodes.is_empty():
		return null

	var node := nodes[0] as Node
	if node == null or not is_instance_valid(node):
		return null

	return node


func _get_property_if_present(object: Object, property_name: StringName):
	for property in object.get_property_list():
		if String(property.get("name", "")) == String(property_name):
			return object.get(property_name)

	return null


func _sort_nodes_by_display_name(first: Node, second: Node) -> bool:
	return _get_character_label(first) < _get_character_label(second)


func _format_value(value) -> String:
	if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
		return String(value)

	if typeof(value) == TYPE_BOOL:
		return "true" if bool(value) else "false"

	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return str(value)

	var number := float(value)
	if is_equal_approx(number, roundf(number)):
		return str(int(roundf(number)))

	var decimals := clampi(max_decimal_places, 0, 4)
	var step := pow(10.0, -decimals)
	return str(snappedf(number, step))


func _resize_panel_to_text() -> void:
	if panel == null or stats_label == null:
		return

	var line_count := maxi(stats_label.text.count("\n") + 1, 1)
	var longest_line := 0
	for line in stats_label.text.split("\n"):
		longest_line = maxi(longest_line, String(line).length())

	var width := clampf(float(longest_line * 6 + 24), 180.0, 420.0)
	var height := clampf(float(line_count * 12 + 24), 60.0, 560.0)
	panel.size = Vector2(width, height)
	stats_label.size = Vector2(width - 16.0, height - 16.0)


func _record_watchdog_marker(source: StringName, detail: String = "") -> void:
	var watchdog := get_node_or_null("/root/PerformanceWatchdog")
	if watchdog != null and watchdog.has_method("record_marker"):
		watchdog.call("record_marker", source, detail)
