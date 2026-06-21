class_name CharacterStatsOverlay extends CanvasLayer

@export var toggle_action: StringName = &"stats"
@export var starts_visible: bool = false
@export var refresh_interval_seconds: float = 0.25
@export var pause_panel_max_screen_ratio: Vector2 = Vector2(0.86, 0.82)
@export var pause_panel_min_size: Vector2 = Vector2(260.0, 180.0)
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
@onready var scroll: ScrollContainer = get_node_or_null("%StatsScroll") as ScrollContainer
@onready var stats_label: Label = get_node_or_null("%StatsText") as Label

var refresh_timer: float = 0.0
var pause_overlay_visible: bool = false
var visible_before_pause: bool = false


func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not DebugToolsConfig.CHARACTER_STATS_OVERLAY_ENABLED:
		visible = false
		set_process(false)
		set_process_unhandled_input(false)
		return

	_ensure_scroll_layout()
	visible = starts_visible
	set_process(visible)
	set_process_unhandled_input(true)
	_update_stats_text()


func _unhandled_input(event: InputEvent) -> void:
	if pause_overlay_visible:
		return

	if toggle_action == &"" or not event.is_action_pressed(toggle_action):
		return

	_set_overlay_visible(not visible)


func show_pause_overlay() -> void:
	if not DebugToolsConfig.CHARACTER_STATS_OVERLAY_ENABLED:
		return
	if pause_overlay_visible:
		return

	visible_before_pause = visible
	pause_overlay_visible = true
	_set_overlay_visible(true)


func hide_pause_overlay() -> void:
	if not pause_overlay_visible:
		return

	pause_overlay_visible = false
	_set_overlay_visible(visible_before_pause)


func _set_overlay_visible(next_visible: bool) -> void:
	visible = next_visible
	set_process(next_visible)
	refresh_timer = 0.0
	if next_visible:
		_update_stats_text()


func _process(delta: float) -> void:
	refresh_timer -= delta
	if refresh_timer > 0.0:
		return

	refresh_timer = refresh_interval_seconds
	_update_stats_text()


func _ensure_scroll_layout() -> void:
	if stats_label != null:
		stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	if panel == null or stats_label == null:
		return

	if scroll == null:
		scroll = ScrollContainer.new()
		scroll.name = "StatsScroll"
		scroll.mouse_filter = Control.MOUSE_FILTER_PASS
		panel.get_parent().add_child(scroll)

	if stats_label.get_parent() != scroll:
		stats_label.reparent(scroll)

	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	stats_label.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _update_stats_text() -> void:
	if stats_label == null:
		return

	var lines: Array[String] = []
	if pause_overlay_visible:
		lines.append("PAUSED")
	lines.append("SCENE STATS")

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
		_append_active_state_details(lines, npc)
		_append_value_lines(lines, _get_character_values(npc))

	_append_offscreen_npc_lines(lines)


func _append_active_state_details(lines: Array[String], npc: Node) -> void:
	var machine := _get_machine(npc)
	if machine == null or machine.current_state == null:
		return

	var state := machine.current_state
	if String(state.name) != "Talk":
		return

	var remaining = _get_property_if_present(state, &"talk_timer")
	var talk_range_value = _get_property_if_present(state, &"talk_range")
	var break_distance = _get_property_if_present(state, &"maximum_talk_distance")
	if remaining == null or talk_range_value == null or break_distance == null:
		return

	lines.append(
		"talk: %.1fs left | range %.0fpx | break %.0fpx"
		% [float(remaining), float(talk_range_value), float(break_distance)]
	)


func _append_offscreen_npc_lines(lines: Array[String]) -> void:
	# Location records keep remote NPC activity and stats inspectable without loading their scene.
	var locations := get_node_or_null("/root/NpcLocations")
	if locations == null or not locations.has_method("get_all_locations"):
		return

	var records: Dictionary = locations.call("get_all_locations")
	var npc_ids := records.keys()
	npc_ids.sort()
	for npc_id_key in npc_ids:
		var npc_id := String(npc_id_key)
		if locations.has_method("is_npc_live") and bool(locations.call("is_npc_live", npc_id)):
			continue

		var record = records[npc_id_key]
		if not (record is Dictionary):
			continue

		var display_name := String(record.get("node_name", npc_id)).to_upper()
		lines.append("")
		lines.append("%s [%s] (OFFSCREEN)" % [display_name, npc_id])
		lines.append("location: %s" % String(record.get("scene_path", "")).get_file())

		var activity = record.get("activity", {})
		if activity is Dictionary and not activity.is_empty():
			lines.append("state: %s (simulated)" % String(activity.get("state_name", "--")))
			lines.append("activity: %s" % String(activity.get("spot_id", "--")))
			var destination_scene := String(activity.get("target_scene_path", ""))
			if not destination_scene.is_empty():
				lines.append("destination: %s" % destination_scene.get_file())
		else:
			lines.append("state: simulated idle")

		var node_state = record.get("node_state", {})
		if node_state is Dictionary:
			var social_stats = node_state.get("social_stats", {})
			if social_stats is Dictionary:
				_append_value_lines(lines, social_stats)


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

	var viewport_size := get_viewport().get_visible_rect().size
	var max_size := Vector2(
		maxf(viewport_size.x * pause_panel_max_screen_ratio.x, pause_panel_min_size.x),
		maxf(viewport_size.y * pause_panel_max_screen_ratio.y, pause_panel_min_size.y)
	)
	var desired_size := Vector2(
		float(longest_line * 7 + 36),
		float(line_count * 14 + 40)
	)
	var panel_size := Vector2(
		clampf(desired_size.x, pause_panel_min_size.x, max_size.x),
		clampf(desired_size.y, pause_panel_min_size.y, max_size.y)
	)

	if pause_overlay_visible:
		panel.position = (viewport_size - panel_size) * 0.5
	else:
		panel.position = Vector2(14.0, 88.0)

	panel.size = panel_size

	if scroll != null:
		scroll.position = panel.position + Vector2(12.0, 12.0)
		scroll.size = panel_size - Vector2(24.0, 24.0)
		stats_label.custom_minimum_size = Vector2(scroll.size.x - 8.0, 0.0)
		stats_label.size = Vector2(scroll.size.x - 8.0, maxf(desired_size.y, scroll.size.y))
	else:
		stats_label.position = panel.position + Vector2(8.0, 8.0)
		stats_label.size = panel_size - Vector2(16.0, 16.0)


func _record_watchdog_marker(source: StringName, detail: String = "") -> void:
	var watchdog := get_node_or_null("/root/PerformanceWatchdog")
	if watchdog != null and watchdog.has_method("record_marker"):
		watchdog.call("record_marker", source, detail)
