class_name NpcStateValueDisplay extends Label

@export var target_npc_path: NodePath
@export var display_title: String = "NPC State Machine"
@export var show_relationships: bool = true
@export var max_relationship_rows: int = 4
@export var value_order: Array[String] = [
	"favor",
	"love",
	"trust",
	"fear",
	"anger",
	"hunger",
	"energy",
	"sleepiness",
	"work_need",
	"talk_interest",
	"curiosity",
	"hp",
	"disabled"
]

var target_npc: Node
var machine: NpcStateMachine
var last_changed_values: Dictionary = {}


func _ready() -> void:
	call_deferred("_setup")


func _setup() -> void:
	# The display reads directly from the machine, so it works with any NPC that has this component.
	target_npc = get_node_or_null(target_npc_path)
	if target_npc == null:
		text = "NPC values\nTarget not found"
		return

	machine = _get_machine(target_npc)
	if machine == null:
		text = "NPC values\nMachine not found"
		return

	var values_callback := Callable(self, "_on_values_changed")
	if not machine.values_changed.is_connected(values_callback):
		machine.values_changed.connect(values_callback)

	var state_callback := Callable(self, "_on_state_changed")
	if not machine.state_changed.is_connected(state_callback):
		machine.state_changed.connect(state_callback)

	_setup_relationship_signals()
	_update_display()


func _on_values_changed(
	_values: Dictionary,
	changed_values: Dictionary,
	_actor: Node2D
) -> void:
	last_changed_values = changed_values.duplicate(true)
	_update_display()


func _on_state_changed(
	_state_name: StringName,
	_previous_state_name: StringName
) -> void:
	_update_display()


func _update_display() -> void:
	if machine == null:
		return

	# Keep this event-driven: refresh on state/value signals instead of polling every frame.
	var state_name := "None"
	if machine.current_state != null:
		state_name = machine.current_state.name

	var lines: Array[String] = [
		display_title,
		"state: %s" % state_name,
		""
	]

	var written_keys: Array[String] = []

	for key in value_order:
		if not machine.values.has(key):
			continue

		written_keys.append(key)
		lines.append(_format_value_line(key, machine.values[key]))

	for value_key in machine.values.keys():
		var key := String(value_key)
		if written_keys.has(key):
			continue

		lines.append(_format_value_line(key, machine.values[value_key]))

	if show_relationships:
		_append_relationship_lines(lines)

	text = "\n".join(lines)


func _setup_relationship_signals() -> void:
	if not show_relationships:
		return

	var relationships := _get_relationship_system()
	if relationships == null:
		return

	var met_callback := Callable(self, "_on_relationship_met")
	if relationships.has_signal(&"relationship_met") and not relationships.is_connected(&"relationship_met", met_callback):
		relationships.connect(&"relationship_met", met_callback)

	var changed_callback := Callable(self, "_on_relationship_changed")
	if relationships.has_signal(&"relationship_changed") and not relationships.is_connected(&"relationship_changed", changed_callback):
		relationships.connect(&"relationship_changed", changed_callback)

	var favor_callback := Callable(self, "_on_relationship_favor_changed")
	if relationships.has_signal(&"favor_changed") and not relationships.is_connected(&"favor_changed", favor_callback):
		relationships.connect(&"favor_changed", favor_callback)


func _on_relationship_met(relationship_owner: Node, _other: Node, _relationship: Dictionary) -> void:
	_update_if_owner_is_target(relationship_owner)


func _on_relationship_changed(
	relationship_owner: Node,
	_other: Node,
	_changed_values: Dictionary,
	_relationship: Dictionary
) -> void:
	_update_if_owner_is_target(relationship_owner)


func _on_relationship_favor_changed(
	relationship_owner: Node,
	_other: Node,
	_favor: float,
	_delta: float,
	_relationship: Dictionary
) -> void:
	_update_if_owner_is_target(relationship_owner)


func _update_if_owner_is_target(relationship_owner: Node) -> void:
	if relationship_owner == target_npc:
		_update_display()


func _append_relationship_lines(lines: Array[String]) -> void:
	var relationships := _get_relationship_system()
	if relationships == null or target_npc == null:
		return

	var npc_relationships = relationships.call("get_relationships_for", target_npc)
	if not (npc_relationships is Dictionary):
		return

	lines.append("")
	lines.append("relationships:")

	if npc_relationships.is_empty():
		lines.append("none")
		return

	var relationship_rows: Array = []
	for relationship_id in npc_relationships.keys():
		relationship_rows.append(npc_relationships[relationship_id])

	relationship_rows.sort_custom(Callable(self, "_sort_relationship_rows"))

	var row_count := mini(relationship_rows.size(), max_relationship_rows)
	for index in range(row_count):
		lines.append(_format_relationship_line(relationship_rows[index]))


func _sort_relationship_rows(first, second) -> bool:
	return String(first.get("other_name", "")) < String(second.get("other_name", ""))


func _format_relationship_line(relationship: Dictionary) -> String:
	return "%s favor: %s" % [
		String(relationship.get("other_name", "NPC")),
		_format_value(relationship.get("favor", 0.0))
	]


func _format_value_line(key: String, value) -> String:
	var line := "%s: %s" % [key, _format_value(value)]

	if last_changed_values.has(key):
		var delta := float(last_changed_values[key])
		var sign_text := "+" if delta > 0.0 else ""
		line += "  (%s%s)" % [sign_text, _format_value(delta)]

	return line


func _format_value(value) -> String:
	var number := float(value)
	if is_equal_approx(number, roundf(number)):
		return str(int(number))

	return str(snappedf(number, 0.1))


func _get_machine(target_node: Node) -> NpcStateMachine:
	var target_machine := target_node as NpcStateMachine
	if target_machine != null:
		return target_machine

	return target_node.get_node_or_null("NpcStateMachine") as NpcStateMachine


func _get_relationship_system() -> Node:
	return get_node_or_null("/root/Relationships")
