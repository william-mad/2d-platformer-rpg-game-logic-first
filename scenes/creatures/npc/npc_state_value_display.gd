class_name NpcStateValueDisplay extends Label

const SocialStateSchema = preload("res://scripts/systems/npc_social_state_schema.gd")
const NpcIdentity = preload("res://scripts/systems/npc_identity.gd")

@export var target_npc_path: NodePath
@export var display_title: String = "NPC State Machine"
@export var show_relationships: bool = true
@export var max_relationship_rows: int = 4
@export var value_order: Array[String] = [
	"anger",
	"hunger",
	"energy",
	"sleep_need",
	"boredom",
	"bored",
	"talk_need",
	"lonely",
	"sadness",
	"curiosity",
	"hp",
	"knockout",
	"disabled"
]

var target_npc: Node
var target_npc_id: String = ""
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
	target_npc_id = NpcIdentity.get_stable_actor_id(target_npc)

	machine = _get_machine(target_npc)
	if machine == null:
		text = "NPC values\nMachine not found"
		return

	var values_callback := Callable(self, "_on_values_changed")
	if not machine.values_changed.is_connected(values_callback):
		machine.values_changed.connect(values_callback)

	var values_replaced_callback := Callable(self, "_on_values_replaced")
	if not machine.values_replaced.is_connected(values_replaced_callback):
		machine.values_replaced.connect(values_replaced_callback)

	var state_callback := Callable(self, "_on_state_changed")
	if not machine.state_changed.is_connected(state_callback):
		machine.state_changed.connect(state_callback)

	_setup_relationship_signals()
	_update_display()


func _on_values_changed(
	changed_values: Dictionary,
	_actor: Node2D
) -> void:
	last_changed_values = changed_values.duplicate(true)
	_update_display()


func _on_values_replaced(
	_values_snapshot: Dictionary,
	_actor: Node2D
) -> void:
	last_changed_values.clear()
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
		if not machine.values.has(key) or not _is_declared_local_value(key):
			continue

		written_keys.append(key)
		lines.append(_format_value_line(key, machine.values[key]))

	for value_key in machine.values.keys():
		var key := String(value_key)
		if written_keys.has(key) or not _is_declared_local_value(key):
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


func _on_relationship_met(
	relationship_owner: Node,
	_other: Node,
	relationship: Dictionary
) -> void:
	_update_if_owner_is_target(relationship_owner, relationship)


func _on_relationship_changed(
	relationship_owner: Node,
	_other: Node,
	_changed_values: Dictionary,
	relationship: Dictionary
) -> void:
	_update_if_owner_is_target(relationship_owner, relationship)


func _update_if_owner_is_target(
	relationship_owner: Node,
	relationship: Dictionary
) -> void:
	if relationship_owner == target_npc:
		_update_display()
	elif (
		relationship_owner == null
		and not target_npc_id.is_empty()
		and String(relationship.get("owner_id", "")) == target_npc_id
	):
		_update_display()


func _append_relationship_lines(lines: Array[String]) -> void:
	var relationships := _get_relationship_system()
	if relationships == null or target_npc == null:
		return

	var owner_id := NpcIdentity.get_stable_actor_id(target_npc)
	if (
		owner_id.is_empty()
		or not relationships.has_method("get_relationships_for_id")
	):
		return
	# Debug presentation is read-only. The node-based compatibility API may migrate
	# legacy aliases, while this stable-ID snapshot never mutates relationship state.
	var npc_relationships = relationships.call(
		"get_relationships_for_id", owner_id
	)
	if not (npc_relationships is Dictionary):
		return

	lines.append("")
	lines.append("relationships:")

	if npc_relationships.is_empty():
		lines.append("none")
		return

	var relationship_rows: Array = []
	for relationship_id in npc_relationships.keys():
		var relationship = npc_relationships[relationship_id]
		if relationship is Dictionary and bool(relationship.get("met", false)):
			relationship_rows.append(relationship)

	if relationship_rows.is_empty():
		lines.append("none")
		return

	relationship_rows.sort_custom(Callable(self, "_sort_relationship_rows"))

	var row_count := mini(relationship_rows.size(), max_relationship_rows)
	for index in range(row_count):
		lines.append(_format_relationship_line(relationship_rows[index]))


func _sort_relationship_rows(first, second) -> bool:
	return _get_relationship_subject_label(first).to_lower() < (
		_get_relationship_subject_label(second).to_lower()
	)


func _format_relationship_line(relationship: Dictionary) -> String:
	var owner_label := String(relationship.get("owner_name", "NPC")).strip_edges()
	if owner_label.is_empty() and target_npc != null:
		owner_label = String(target_npc.name)
	var subject_label := _get_relationship_subject_label(relationship)
	var metric_parts: Array[String] = []
	for definition in SocialStateSchema.get_definitions_for_scope(
		SocialStateSchema.SCOPE_DIRECTED_OPINION
	):
		var metric_id := String(definition.get("id", ""))
		if metric_id.is_empty() or not relationship.has(metric_id):
			continue
		metric_parts.append("%s %s" % [
			String(definition.get("label", metric_id.capitalize())),
			_format_value(relationship[metric_id]),
		])
	return "%s -> %s | %s" % [
		owner_label,
		subject_label,
		" / ".join(metric_parts) if not metric_parts.is_empty() else "no opinion values",
	]


func _get_relationship_subject_label(relationship: Dictionary) -> String:
	var label := String(relationship.get("other_name", "")).strip_edges()
	if not label.is_empty():
		return label
	var subject_id := String(relationship.get("other_id", "")).strip_edges()
	if NpcIdentity.is_player_id(subject_id):
		return "Player"
	if not subject_id.is_empty():
		return subject_id.replace("_", " ").capitalize()
	return "Character"


func _format_value_line(key: String, value) -> String:
	var definition := SocialStateSchema.get_definition(StringName(key))
	var label := String(definition.get("label", key.capitalize()))
	var scope := StringName(definition.get("scope", &""))
	var scope_label := "mood" if scope == SocialStateSchema.SCOPE_BROAD_MOOD else "local"
	var line := "%s %s: %s" % [scope_label, label, _format_value(value)]

	if last_changed_values.has(key):
		var delta := float(last_changed_values[key])
		var sign_text := "+" if delta > 0.0 else ""
		line += "  (%s%s)" % [sign_text, _format_value(delta)]

	return line


func _is_declared_local_value(key: String) -> bool:
	var definition := SocialStateSchema.get_definition(StringName(key))
	return (
		not definition.is_empty()
		and StringName(definition.get("scope", &""))
			!= SocialStateSchema.SCOPE_DIRECTED_OPINION
		and bool(
			definition.get("presentation", {}).get("show_in_debug", false)
		)
	)


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
