class_name NpcStateValueDisplay extends Label

@export var target_npc_path: NodePath
@export var display_title: String = "NPC State Machine"
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

var machine: NpcStateMachine
var last_changed_values: Dictionary = {}


func _ready() -> void:
	call_deferred("_setup")


func _setup() -> void:
	# The display reads directly from the machine, so it works with any NPC that has this component.
	var target_node := get_node_or_null(target_npc_path)
	if target_node == null:
		text = "NPC values\nTarget not found"
		return

	machine = _get_machine(target_node)
	if machine == null:
		text = "NPC values\nMachine not found"
		return

	var values_callback := Callable(self, "_on_values_changed")
	if not machine.values_changed.is_connected(values_callback):
		machine.values_changed.connect(values_callback)

	var state_callback := Callable(self, "_on_state_changed")
	if not machine.state_changed.is_connected(state_callback):
		machine.state_changed.connect(state_callback)

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

	text = "\n".join(lines)


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
